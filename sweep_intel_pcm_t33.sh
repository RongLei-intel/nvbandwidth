#!/usr/bin/env bash
set -euo pipefail

# Sweep Intel PCM/NVIDIA metrics for nvbandwidth testcase 33 over buffer sizes.
#
# Default command per buffer:
#   OUTDIR=<sweep_root>/buffer_<N>MiB BUFFER_SIZE=<N> TESTCASE=33 \
#     ./collect_pcm_nvsmi_nvbw.sh
#
# The per-buffer collector records Intel PCM memory/PCIe counters plus optional
# NVIDIA telemetry. This wrapper then parses those raw files and writes a compact
# cross-buffer summary.
#
# Useful examples:
#   bash sweep_intel_pcm_t33_buffersize.sh
#   BUFFER_SIZES="2 4 8 16" LOOP_COUNT=500 bash sweep_intel_pcm_t33_buffersize.sh
#   BUFFER_SIZES="1 2 4" SAMPLE_INTERVAL=1 NVIDIA_DMON_INTERVAL=1 bash sweep_intel_pcm_t33_buffersize.sh
#   PTR_CHASE_LOAD_BYTES_LIST="8 16 32" BUFFER_SIZES="2 4 8 16" bash sweep_intel_pcm_t33_buffersize.sh
#   USE_SCALED_LOOP_COUNT=1 BASE_LOOP_COUNT=5000 BASE_BUFFER_MIB=2 bash sweep_intel_pcm_t33_buffersize.sh
#   PCM_TOOLS="pcm-memory pcm-pcie" INCLUDE_NVIDIA_DMON=1 bash sweep_intel_pcm_t33_buffersize.sh
#
# Tunables passed through to collect_pcm_nvsmi_nvbw.sh:
#   NVBANDWIDTH_BIN, CUDA_VISIBLE_DEVICES, NUMA_NODE, CPU_BIND, TESTCASE,
#   TEST_SAMPLES, HOST_READ_PARALLELISM, LATENCY_STRIDE_LEN, EXTRA_NVBW_ARGS,
#   SKIP_VERIFICATION, VERBOSE_NVBW, SAMPLE_INTERVAL, NVIDIA_QUERY_INTERVAL,
#   NVIDIA_DMON_INTERVAL, PCM_TOOLS, INCLUDE_NVIDIA_QUERY,
#   INCLUDE_NVIDIA_DMON, INCLUDE_NVIDIA_PMON, INCLUDE_NVIDIA_APPS.
#
# Sweep-specific tunables:
#   BUFFER_SIZES="1 2 4 8 16 32 64 128"
#   OUTROOT=<dir>                 sweep root dir; default timestamped
#   RUN_LABEL=<name>              optional label added to OUTROOT and log filenames
#   RETRIES=2                     attempts per buffer
#   LOOP_COUNT=300                fixed loopCount for all buffers; set empty to use collect script default
#   USE_SCALED_LOOP_COUNT=0       set 1 to scale loopCount inversely with buffer size
#   BASE_LOOP_COUNT=5000          loopCount at BASE_BUFFER_MIB when USE_SCALED_LOOP_COUNT=1
#   BASE_BUFFER_MIB=2             base buffer for scaled loopCount
#   MIN_LOOP_COUNT=16             lower bound for scaled loopCount
#   AUTO_LOOP_COUNT=1             default: choose loopCount from TARGET_TRANSFER_MIB / BUFFER_SIZE
#   TARGET_TRANSFER_MIB=32768    target logical transferred MiB per nvbandwidth sample before testSamples/warmup
#   LOOP_COUNT=<N>                explicit fixed loopCount for all buffers; overrides auto/scaled mode
#   PTR_CHASE_LOAD_BYTES=          optional single --ptrChaseLoadBytes value; supported: 8, 16, 32; 32 requires sm_100+
#   PTR_CHASE_LOAD_BYTES_LIST="8 16 32" optional t33 pointer-chase load-size sweep list; overrides PTR_CHASE_LOAD_BYTES when set
#   COLLECT_SCRIPT=./collect_pcm_nvsmi_nvbw.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUFFER_SIZES="${BUFFER_SIZES:-1 2 4 8 16 32 64 128 256 512 1024}"
RETRIES="${RETRIES:-2}"
COLLECT_SCRIPT="${COLLECT_SCRIPT:-./collect_pcm_nvsmi_nvbw.sh}"
RUN_LABEL="${RUN_LABEL:-}"

if [[ -n "$RUN_LABEL" ]]; then
    OUTROOT_DEFAULT="intel_pcm_nvbw_t33_${RUN_LABEL}_sweep_$(date +%Y%m%d_%H%M%S)"
else
    OUTROOT_DEFAULT="intel_pcm_nvbw_t33_sweep_$(date +%Y%m%d_%H%M%S)"
fi
OUTROOT="${OUTROOT:-$OUTROOT_DEFAULT}"
SWEEP_INFO_FILE="$OUTROOT/sweep${RUN_LABEL:+_${RUN_LABEL}}.info"
DRIVER_LOG_BASENAME="driver${RUN_LABEL:+_${RUN_LABEL}}.log"

NVBANDWIDTH_BIN="${NVBANDWIDTH_BIN:-./nvbandwidth}"
TESTCASE="${TESTCASE:-33}"
CUDA_VISIBLE_DEVICES_VALUE="${CUDA_VISIBLE_DEVICES-0}"
NUMA_NODE_VALUE="${NUMA_NODE-0}"
CPU_BIND_VALUE="${CPU_BIND-1}"
TEST_SAMPLES_VALUE="${TEST_SAMPLES-}"
HOST_READ_PARALLELISM_VALUE="${HOST_READ_PARALLELISM-}"
LATENCY_STRIDE_LEN_VALUE="${LATENCY_STRIDE_LEN-}"
EXTRA_NVBW_ARGS_VALUE="${EXTRA_NVBW_ARGS-}"
PTR_CHASE_LOAD_BYTES_LIST="${PTR_CHASE_LOAD_BYTES_LIST-${PTR_CHASE_LOAD_BYTES-8 16 32}}"
SKIP_VERIFICATION="${SKIP_VERIFICATION:-1}"
VERBOSE_NVBW="${VERBOSE_NVBW:-0}"

SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
NVIDIA_QUERY_INTERVAL="${NVIDIA_QUERY_INTERVAL:-1}"
NVIDIA_DMON_INTERVAL="${NVIDIA_DMON_INTERVAL:-1}"
PCM_TOOLS="${PCM_TOOLS:-pcm-memory pcm-pcie}"
INCLUDE_NVIDIA_QUERY="${INCLUDE_NVIDIA_QUERY:-1}"
INCLUDE_NVIDIA_DMON="${INCLUDE_NVIDIA_DMON:-1}"
INCLUDE_NVIDIA_PMON="${INCLUDE_NVIDIA_PMON:-0}"
INCLUDE_NVIDIA_APPS="${INCLUDE_NVIDIA_APPS:-0}"

LOOP_COUNT_VALUE="${LOOP_COUNT-}"
USE_SCALED_LOOP_COUNT="${USE_SCALED_LOOP_COUNT:-0}"
BASE_LOOP_COUNT="${BASE_LOOP_COUNT:-5000}"
BASE_BUFFER_MIB="${BASE_BUFFER_MIB:-2}"
MIN_LOOP_COUNT="${MIN_LOOP_COUNT:-16}"
MAX_LOOP_COUNT="${MAX_LOOP_COUNT:-262144}"
TARGET_TRANSFER_MIB="${TARGET_TRANSFER_MIB:-32768}"
AUTO_LOOP_COUNT="${AUTO_LOOP_COUNT:-1}"

auto_loop_count() {
  local buffer_mib="$1"
  local loop_count
  # Ceiling division keeps small buffers alive long enough for PCM/NVIDIA sampling,
  # while preventing large buffers from inheriting a painfully large fixed loopCount.
  loop_count=$(( (TARGET_TRANSFER_MIB + buffer_mib - 1) / buffer_mib ))
  if (( loop_count < MIN_LOOP_COUNT )); then
    loop_count="$MIN_LOOP_COUNT"
  fi
  if (( loop_count > MAX_LOOP_COUNT )); then
    loop_count="$MAX_LOOP_COUNT"
  fi
  printf '%s\n' "$loop_count"
}

AUTO_LOOP_COUNT="${AUTO_LOOP_COUNT:-1}"

if [[ -x "$COLLECT_SCRIPT" ]]; then
  collect_cmd=("$COLLECT_SCRIPT")
elif [[ -r "$COLLECT_SCRIPT" ]]; then
  collect_cmd=(bash "$COLLECT_SCRIPT")
else
  echo "ERROR: collect script not found or unreadable: $COLLECT_SCRIPT" >&2
  exit 1
fi

if [[ -z "${BUFFER_SIZES//[[:space:]]/}" ]]; then
        echo "ERROR: BUFFER_SIZES is empty; provide values such as BUFFER_SIZES=\"1 2 4 8 16\"" >&2
        exit 1
fi

if [[ -z "${PTR_CHASE_LOAD_BYTES_LIST//[[:space:]]/}" ]]; then
    echo "ERROR: PTR_CHASE_LOAD_BYTES_LIST is empty; provide values such as PTR_CHASE_LOAD_BYTES_LIST=\"8 16 32\"" >&2
    exit 1
fi

for ptr_chase_load_bytes in $PTR_CHASE_LOAD_BYTES_LIST; do
    if [[ "$ptr_chase_load_bytes" != "8" && "$ptr_chase_load_bytes" != "16" && "$ptr_chase_load_bytes" != "32" ]]; then
        echo "ERROR: PTR_CHASE_LOAD_BYTES_LIST contains unsupported value '$ptr_chase_load_bytes'; supported: 8, 16, 32; 32 requires sm_100+" >&2
        exit 1
    fi
done

mkdir -p "$OUTROOT"

scaled_loop_count() {
  local buffer_mib="$1"
  local loop_count
  loop_count=$(( BASE_LOOP_COUNT * BASE_BUFFER_MIB / buffer_mib ))
  if (( loop_count < MIN_LOOP_COUNT )); then
    loop_count="$MIN_LOOP_COUNT"
  fi
  printf '%s\n' "$loop_count"
}

{
  echo "sweep_root=$OUTROOT"
  echo "buffer_sizes_MiB=$BUFFER_SIZES"
    echo "ptr_chase_load_bytes_list=$PTR_CHASE_LOAD_BYTES_LIST"
  echo "retries=$RETRIES"
  echo "collect_script=$COLLECT_SCRIPT"
  echo "nvbandwidth_bin=$NVBANDWIDTH_BIN"
  echo "testcase=$TESTCASE"
  echo "cuda_visible_devices=$CUDA_VISIBLE_DEVICES_VALUE"
  echo "numa_node=$NUMA_NODE_VALUE"
  echo "cpu_bind=$CPU_BIND_VALUE"
  echo "sample_interval=$SAMPLE_INTERVAL"
  echo "nvidia_query_interval=$NVIDIA_QUERY_INTERVAL"
  echo "nvidia_dmon_interval=$NVIDIA_DMON_INTERVAL"
  echo "pcm_tools=$PCM_TOOLS"
  echo "include_nvidia_query=$INCLUDE_NVIDIA_QUERY"
  echo "include_nvidia_dmon=$INCLUDE_NVIDIA_DMON"
  echo "include_nvidia_pmon=$INCLUDE_NVIDIA_PMON"
  echo "include_nvidia_apps=$INCLUDE_NVIDIA_APPS"
  echo "loop_count_fixed=$LOOP_COUNT_VALUE"
  echo "use_scaled_loop_count=$USE_SCALED_LOOP_COUNT"
  echo "base_loop_count=$BASE_LOOP_COUNT"
  echo "base_buffer_mib=$BASE_BUFFER_MIB"
  echo "min_loop_count=$MIN_LOOP_COUNT"
  echo "skip_verification=$SKIP_VERIFICATION"
  echo "verbose_nvbw=$VERBOSE_NVBW"
  echo "test_samples=$TEST_SAMPLES_VALUE"
  echo "host_read_parallelism=$HOST_READ_PARALLELISM_VALUE"
  echo "latency_stride_len=$LATENCY_STRIDE_LEN_VALUE"
  echo "extra_nvbw_args=$EXTRA_NVBW_ARGS_VALUE"
  echo "start_time=$(date --iso-8601=seconds)"
} | tee "$SWEEP_INFO_FILE"

failed=0

for ptr_chase_load_bytes in $PTR_CHASE_LOAD_BYTES_LIST; do
    for b in $BUFFER_SIZES; do
        ok=0

        loop_env=()
        if [[ -n "$LOOP_COUNT_VALUE" ]]; then
            loop_env=("LOOP_COUNT=$LOOP_COUNT_VALUE")
        elif [[ "$USE_SCALED_LOOP_COUNT" != "0" ]]; then
            loop_env=("LOOP_COUNT=$(scaled_loop_count "$b")")
        elif [[ "$AUTO_LOOP_COUNT" != "0" ]]; then
            loop_env=("LOOP_COUNT=$(auto_loop_count "$b")")
        else
            loop_env=()
        fi

        run_extra_nvbw_args="${EXTRA_NVBW_ARGS_VALUE:+$EXTRA_NVBW_ARGS_VALUE }--ptrChaseLoadBytes $ptr_chase_load_bytes"

        common_env=(
            "NVBANDWIDTH_BIN=$NVBANDWIDTH_BIN"
            "TESTCASE=$TESTCASE"
            "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES_VALUE"
            "NUMA_NODE=$NUMA_NODE_VALUE"
            "CPU_BIND=$CPU_BIND_VALUE"
            "TEST_SAMPLES=$TEST_SAMPLES_VALUE"
            "HOST_READ_PARALLELISM=$HOST_READ_PARALLELISM_VALUE"
            "LATENCY_STRIDE_LEN=$LATENCY_STRIDE_LEN_VALUE"
            "EXTRA_NVBW_ARGS=$run_extra_nvbw_args"
            "SKIP_VERIFICATION=$SKIP_VERIFICATION"
            "VERBOSE_NVBW=$VERBOSE_NVBW"
            "SAMPLE_INTERVAL=$SAMPLE_INTERVAL"
            "NVIDIA_QUERY_INTERVAL=$NVIDIA_QUERY_INTERVAL"
            "NVIDIA_DMON_INTERVAL=$NVIDIA_DMON_INTERVAL"
            "PCM_TOOLS=$PCM_TOOLS"
            "INCLUDE_NVIDIA_QUERY=$INCLUDE_NVIDIA_QUERY"
            "INCLUDE_NVIDIA_DMON=$INCLUDE_NVIDIA_DMON"
            "INCLUDE_NVIDIA_PMON=$INCLUDE_NVIDIA_PMON"
            "INCLUDE_NVIDIA_APPS=$INCLUDE_NVIDIA_APPS"
        )

        for attempt in $(seq 1 "$RETRIES"); do
            suffix=""
            if (( attempt > 1 )); then
                suffix="_retry${attempt}"
            fi
            outdir="$OUTROOT/buffer_${b}MiB_ptrload_${ptr_chase_load_bytes}B${suffix}"

            echo
            echo "===== PTR_CHASE_LOAD_BYTES=${ptr_chase_load_bytes} BUFFER_SIZE=${b} MiB attempt=${attempt}/${RETRIES} -> ${outdir} ====="
            echo "  ${loop_env[*]}"
            if [[ "$AUTO_LOOP_COUNT" != "0" && -z "$LOOP_COUNT_VALUE" && "$USE_SCALED_LOOP_COUNT" == "0" ]]; then
                echo "  auto target: ~${TARGET_TRANSFER_MIB} MiB logical transfer per sample, bounds=[${MIN_LOOP_COUNT}, ${MAX_LOOP_COUNT}]"
            fi
            echo "  EXTRA_NVBW_ARGS=$run_extra_nvbw_args"
            echo "  SAMPLE_INTERVAL=$SAMPLE_INTERVAL NVIDIA_DMON_INTERVAL=$NVIDIA_DMON_INTERVAL PCM_TOOLS=$PCM_TOOLS"

            set +e
            env OUTDIR="$outdir" BUFFER_SIZE="$b" "${common_env[@]}" "${loop_env[@]}" "${collect_cmd[@]}" 2>&1 | tee "$outdir/$DRIVER_LOG_BASENAME"
            rc=${PIPESTATUS[0]}
            set -e

            if [[ "$rc" -eq 0 ]]; then
                echo "PTR_CHASE_LOAD_BYTES=${ptr_chase_load_bytes} BUFFER_SIZE=${b} status=ok attempt=${attempt} outdir=${outdir} ${loop_env[*]}" | tee -a "$SWEEP_INFO_FILE"
                ok=1
                break
            fi

            echo "PTR_CHASE_LOAD_BYTES=${ptr_chase_load_bytes} BUFFER_SIZE=${b} status=failed attempt=${attempt} rc=${rc} outdir=${outdir} ${loop_env[*]}" | tee -a "$SWEEP_INFO_FILE"
        done

        if [[ "$ok" -ne 1 ]]; then
            failed=1
        fi
    done
done

{
  echo "end_time=$(date --iso-8601=seconds)"
  echo "failed=$failed"
} | tee -a "$SWEEP_INFO_FILE"

summary_csv="$OUTROOT/intel_pcm_summary.csv"
summary_md="$OUTROOT/intel_pcm_summary.md"

# Generate a compact cross-buffer summary from raw collector outputs:
#   - nvbandwidth SUM from nvbandwidth.out
#   - Memory bandwidth from pcm-memory.csv System.Read/System.Write/System.Memory
#   - PCIe bandwidth from pcm-pcie.csv PCIe Rd/Wr bytes per second
#   - Optional GPU PCIe telemetry from nvidia-smi dmon rxpci/txpci
# shellcheck disable=SC2086
python3 - "$OUTROOT" "$TESTCASE" "$PTR_CHASE_LOAD_BYTES_LIST" $BUFFER_SIZES <<'PY'
from collections import defaultdict
from pathlib import Path
import csv
import math
import re
import statistics
import sys

root = Path(sys.argv[1])
testcase = sys.argv[2]
ptr_chase_load_bytes_values = [int(x) for x in sys.argv[3].split()]
buffers = [int(x) for x in sys.argv[4:]]


def parse_float(value):
    if value is None:
        return None
    text = str(value).strip().replace(',', '')
    if not text or text in {'-', 'N/A', '[N/A]', 'NA'}:
        return None
    try:
        value = float(text)
    except ValueError:
        return None
    if math.isnan(value) or math.isinf(value):
        return None
    return value


def stats(values):
    vals = [float(v) for v in values if v is not None]
    if not vals:
        return None
    ordered = sorted(vals)
    p95_idx = min(len(ordered) - 1, max(0, math.ceil(0.95 * len(ordered)) - 1))
    return {
        'samples': len(vals),
        'avg': statistics.fmean(vals),
        'median': statistics.median(vals),
        'p95': ordered[p95_idx],
        'max': max(vals),
        'min': min(vals),
        'last': vals[-1],
    }


def stval(stat, key, digits=3):
    if not stat or stat.get(key) is None:
        return ''
    return f"{stat[key]:.{digits}f}"


def run_info_for(outdir):
    info = {}
    path = outdir / 'run.info'
    if not path.exists():
        return info
    for line in path.read_text(errors='replace').splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            info[key.strip()] = value.strip()
    return info


def retry_order(path):
    match = re.search(r'_retry(\d+)$', path.name)
    if match:
        return int(match.group(1))
    return 1


def dirs_for_combo(buffer_mib, ptr_chase_load_bytes):
    candidates = []
    for path in root.iterdir() if root.exists() else []:
        if not path.is_dir():
            continue
        if path.name == f'buffer_{buffer_mib}MiB_ptrload_{ptr_chase_load_bytes}B' or re.match(rf'^buffer_{buffer_mib}MiB_ptrload_{ptr_chase_load_bytes}B_retry\d+$', path.name):
            if (path / 'summary.txt').is_file() or (path / 'nvbandwidth.out').is_file() or (path / 'run.info').is_file():
                candidates.append(path)
    return sorted(candidates, key=lambda p: (retry_order(p), p.name))


def parse_nvbandwidth_sum(outdir):
    path = outdir / 'nvbandwidth.out'
    if not path.exists():
        return None
    sums = []
    for line in path.read_text(errors='replace').splitlines():
        match = re.match(r'^SUM\s+(\S+)\s+([-+0-9.eE]+)', line.strip())
        if match:
            name = match.group(1)
            value = parse_float(match.group(2))
            if value is not None:
                sums.append((name, value))
    for name, value in sums:
        if name == 'host_device_bandwidth_sm':
            return value
    return sums[-1][1] if sums else None


def load_pcm_memory(outdir):
    path = outdir / 'pcm-memory.csv'
    if not path.exists() or path.stat().st_size == 0:
        return {}, 0
    rows = list(csv.reader(path.open(newline='', errors='replace')))
    if len(rows) < 3:
        return {}, 0
    groups = [cell.strip() for cell in rows[0]]
    names = [cell.strip() for cell in rows[1]]
    metrics = defaultdict(list)
    sample_count = 0
    for row in rows[2:]:
        if len(row) < 3 or not row[0].strip():
            continue
        sample_has_value = False
        for idx, raw in enumerate(row):
            if idx >= len(names):
                continue
            name = names[idx]
            if not name or name in {'Date', 'Time'}:
                continue
            value = parse_float(raw)
            if value is None:
                continue
            group = groups[idx] if idx < len(groups) else ''
            key = f'{group}.{name}' if group else name
            # pcm-memory reports MB/s; convert to GB/s for summary output.
            metrics[key].append(value / 1000.0)
            sample_has_value = True
        if sample_has_value:
            sample_count += 1
    return metrics, sample_count


def load_pcm_pcie(outdir):
    path = outdir / 'pcm-pcie.csv'
    if not path.exists() or path.stat().st_size == 0:
        return {}, 0
    samples = []
    current = []
    header = None
    for row in csv.reader(path.open(newline='', errors='replace')):
        if not row:
            continue
        first = row[0].strip()
        if first == 'Skt':
            if current:
                samples.append(current)
                current = []
            header = [cell.strip() for cell in row]
            continue
        if header and first not in {'', '*'}:
            current.append(dict(zip(header, row)))
    if current:
        samples.append(current)

    totals = defaultdict(list)
    for sample in samples:
        sample_totals = defaultdict(float)
        for row in sample:
            for key in ['PCIe Rd (B)', 'PCIe Wr (B)']:
                value = parse_float(row.get(key))
                if value is not None:
                    sample_totals[key] += value
        if sample_totals:
            rd = sample_totals.get('PCIe Rd (B)', 0.0)
            wr = sample_totals.get('PCIe Wr (B)', 0.0)
            totals['PCIe Rd (B)'].append(rd / 1e9)
            totals['PCIe Wr (B)'].append(wr / 1e9)
            totals['PCIe Total (B)'].append((rd + wr) / 1e9)
    return totals, len(samples)


def load_nvidia_dmon(outdir):
    path = outdir / 'nvidia-dmon.out'
    if not path.exists() or path.stat().st_size == 0:
        return {}, 0
    per_timestamp = defaultdict(lambda: {'rxpci': 0.0, 'txpci': 0.0})
    rows = 0
    for line in path.read_text(errors='replace').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        if len(parts) < 24:
            continue
        timestamp = f'{parts[0]} {parts[1]}'
        rx = parse_float(parts[22])
        tx = parse_float(parts[23])
        if rx is not None:
            per_timestamp[timestamp]['rxpci'] += rx / 1000.0
        if tx is not None:
            per_timestamp[timestamp]['txpci'] += tx / 1000.0
        rows += 1
    agg = defaultdict(list)
    for item in per_timestamp.values():
        agg['rxpci'].append(item['rxpci'])
        agg['txpci'].append(item['txpci'])
        agg['pcie_total'].append(item['rxpci'] + item['txpci'])
    return agg, rows


rows = []
for ptr_chase_load_bytes in ptr_chase_load_bytes_values:
    for buffer_mib in buffers:
        candidates = dirs_for_combo(buffer_mib, ptr_chase_load_bytes)
        row = {
            'ptr_chase_load_bytes': ptr_chase_load_bytes,
            'buffer_MiB': buffer_mib,
            'status': 'missing',
            'result_dir': '',
        }
        if not candidates:
            rows.append(row)
            continue

        outdir = candidates[-1]
        info = run_info_for(outdir)
        nvbw_rc = info.get('nvbandwidth_rc') or info.get('workload_rc') or ''
        row.update({
            'status': 'ok' if nvbw_rc in {'', '0'} else f'rc={nvbw_rc}',
            'result_dir': str(outdir),
            'nvbandwidth_rc': nvbw_rc,
            'loop_count': info.get('loop_count', ''),
        })

        nvbw_sum = parse_nvbandwidth_sum(outdir)
        if nvbw_sum is not None:
            row['nvbandwidth_SUM_GBps'] = f'{nvbw_sum:.3f}'

        memory, memory_samples = load_pcm_memory(outdir)
        sys_mem_rd = stats(memory.get('System.Read', []))
        sys_mem_wr = stats(memory.get('System.Write', []))
        sys_mem_total = stats(memory.get('System.Memory', []))
        numa_node = info.get('numa_node', '')
        target_prefix = f'SKT{numa_node}' if numa_node != '' else ''
        target_mem_rd = stats(memory.get(f'{target_prefix}.Mem Read (MB/s)', [])) if target_prefix else None

        row.update({
            'system_mem_read_median_GBps': stval(sys_mem_rd, 'median'),
            'system_mem_read_p95_GBps': stval(sys_mem_rd, 'p95'),
            'system_mem_read_max_GBps': stval(sys_mem_rd, 'max'),
            'system_mem_write_median_GBps': stval(sys_mem_wr, 'median'),
            'system_mem_total_median_GBps': stval(sys_mem_total, 'median'),
            'target_socket_mem_read_median_GBps': stval(target_mem_rd, 'median'),
            'pcm_memory_samples': memory_samples,
        })

        pcie, pcie_samples = load_pcm_pcie(outdir)
        pcie_rd = stats(pcie.get('PCIe Rd (B)', []))
        pcie_wr = stats(pcie.get('PCIe Wr (B)', []))
        pcie_total = stats(pcie.get('PCIe Total (B)', []))
        row.update({
            'system_pcie_read_median_GBps': stval(pcie_rd, 'median'),
            'system_pcie_read_p95_GBps': stval(pcie_rd, 'p95'),
            'system_pcie_read_max_GBps': stval(pcie_rd, 'max'),
            'system_pcie_write_median_GBps': stval(pcie_wr, 'median'),
            'system_pcie_total_median_GBps': stval(pcie_total, 'median'),
            'system_pcie_total_p95_GBps': stval(pcie_total, 'p95'),
            'pcm_pcie_samples': pcie_samples,
        })

        dmon, dmon_rows = load_nvidia_dmon(outdir)
        dmon_rx = stats(dmon.get('rxpci', []))
        dmon_tx = stats(dmon.get('txpci', []))
        dmon_total = stats(dmon.get('pcie_total', []))
        row.update({
            'nvidia_rxpcie_median_GBps': stval(dmon_rx, 'median'),
            'nvidia_rxpcie_p95_GBps': stval(dmon_rx, 'p95'),
            'nvidia_txpcie_median_GBps': stval(dmon_tx, 'median'),
            'nvidia_txpcie_p95_GBps': stval(dmon_tx, 'p95'),
            'nvidia_pcie_total_median_GBps': stval(dmon_total, 'median'),
            'nvidia_pcie_total_p95_GBps': stval(dmon_total, 'p95'),
            'nvidia_dmon_rows': dmon_rows,
        })

        rows.append(row)

fieldnames = [
    'ptr_chase_load_bytes',
    'buffer_MiB',
    'status',
    'loop_count',
    'nvbandwidth_SUM_GBps',
    'system_mem_read_median_GBps',
    'system_mem_read_p95_GBps',
    'system_mem_read_max_GBps',
    'system_mem_write_median_GBps',
    'system_mem_total_median_GBps',
    'target_socket_mem_read_median_GBps',
    'system_pcie_read_median_GBps',
    'system_pcie_read_p95_GBps',
    'system_pcie_read_max_GBps',
    'system_pcie_write_median_GBps',
    'system_pcie_total_median_GBps',
    'system_pcie_total_p95_GBps',
    'nvidia_rxpcie_median_GBps',
    'nvidia_rxpcie_p95_GBps',
    'nvidia_txpcie_median_GBps',
    'nvidia_txpcie_p95_GBps',
    'nvidia_pcie_total_median_GBps',
    'nvidia_pcie_total_p95_GBps',
    'pcm_memory_samples',
    'pcm_pcie_samples',
    'nvidia_dmon_rows',
    'nvbandwidth_rc',
    'result_dir',
]

csv_path = root / 'intel_pcm_summary.csv'
with csv_path.open('w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)


def cell(row, key):
    value = row.get(key, '')
    return '' if value is None else str(value)


md_lines = [
    f'# Intel PCM/NVIDIA nvbandwidth testcase {testcase} sweep summary',
    '',
    '- Units: GB/s.',
    '- `System Mem Rd` comes from `pcm-memory.csv` / `System.Read`.',
    '- `System PCIe Rd` comes from `pcm-pcie.csv` / `PCIe Rd (B)`.',
    '- `NVIDIA rx+tx` comes from optional `nvidia-smi dmon` telemetry and may be blank if disabled or unsupported.',
    '',
    '| Ptr load bytes | Buffer MiB | LoopCount | Status | nvbandwidth SUM | System Mem Rd median | System Mem Rd p95 | System PCIe Rd median | System PCIe Rd p95 | NVIDIA rx+tx median | Samples mem/pcie | Result dir |',
    '| ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |',
]
for row in rows:
    samples = f"{cell(row, 'pcm_memory_samples')}/{cell(row, 'pcm_pcie_samples')}"
    md_lines.append(
        f"| {cell(row, 'ptr_chase_load_bytes')} | {cell(row, 'buffer_MiB')} | {cell(row, 'loop_count')} | {cell(row, 'status')} | {cell(row, 'nvbandwidth_SUM_GBps')} | "
        f"{cell(row, 'system_mem_read_median_GBps')} | {cell(row, 'system_mem_read_p95_GBps')} | "
        f"{cell(row, 'system_pcie_read_median_GBps')} | {cell(row, 'system_pcie_read_p95_GBps')} | "
        f"{cell(row, 'nvidia_pcie_total_median_GBps')} | {samples} | {cell(row, 'result_dir')} |"
    )

md_path = root / 'intel_pcm_summary.md'
md_path.write_text('\n'.join(md_lines) + '\n')

print(md_path)
print(csv_path)
print('\n'.join(md_lines[7:]))
PY

echo
echo "Done. Sweep root: $OUTROOT"
echo "Summary markdown: $summary_md"
echo "Summary CSV     : $summary_csv"

exit "$failed"
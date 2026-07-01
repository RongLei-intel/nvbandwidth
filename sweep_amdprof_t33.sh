#!/usr/bin/env bash
set -euo pipefail

# Sweep AMD uProf PCM for nvbandwidth testcase 33 over buffer sizes and pointer-chase load widths.
#
# Default command per run:
#   OUTDIR=<sweep_root>/buffer_<N>MiB_ptrload_<B>B BUFFER_SIZE=<N> TESTCASE=33 \
#     EXTRA_NVBW_ARGS="--ptrChaseLoadBytes <B>" ./collect_amdprof_mem_bw_t33.sh
#
# Useful examples:
#   bash sweep_amdprof_t33.sh
#   BUFFER_SIZES="2 4 8 16" LOOP_COUNT=500 bash sweep_amdprof_t33.sh
#   PTR_CHASE_LOAD_BYTES_LIST="8 16 32" BUFFER_SIZES="2 4 8 16" bash sweep_amdprof_t33.sh
#   SM_COPY_BYTES_LIST="8 16 32" BUFFER_SIZES="2 4 8 16" bash sweep_amdprof_t33.sh  # alias for t33 load-size sweep
#   PCM_WAIT_FOR_SIGNAL=1 SAMPLE_INTERVAL_MS=1 LOOP_COUNT=100 bash sweep_amdprof_t33.sh
#   USE_SCALED_LOOP_COUNT=1 BASE_LOOP_COUNT=5000 BASE_BUFFER_MIB=2 bash sweep_amdprof_t33.sh
#   TARGET_TRANSFER_MIB=32768 bash sweep_amdprof_t33.sh
#
# Tunables passed through to collect_amdprof_mem_bw_t33.sh:
#   AMDPROF_PCM, CUDA_VISIBLE_DEVICES, NUMA_NODE, CPU_BIND, TESTCASE,
#   TEST_SAMPLES, HOST_READ_PARALLELISM, LATENCY_STRIDE_LEN, EXTRA_NVBW_ARGS,
#   SKIP_VERIFICATION, VERBOSE_NVBW, PCM_METRICS, PCM_SCOPE,
#   PCM_AGGREGATE, SAMPLE_INTERVAL_MS, PROFILE_SECONDS, START_DELAY_MS,
#   PCM_WAIT_FOR_SIGNAL, PCM_SIGNAL_END, PCM_SIGNAL_READY_DELAY_MS,
#   COLLECT_POWER, COLLECT_PCIE, COLLECT_XGMI, HTML_REPORT.
#
# Sweep-specific tunables:
#   BUFFER_SIZES="1 2 4 8 16 32 64 128"
#   OUTROOT=<dir>                 sweep root dir; default timestamped
#   RUN_LABEL=<name>              optional label added to OUTROOT/log filenames
#   RETRIES=2                     attempts per combination
#   AUTO_LOOP_COUNT=1             default: choose loopCount from TARGET_TRANSFER_MIB / BUFFER_SIZE
#   TARGET_TRANSFER_MIB=32768     target logical transferred MiB per nvbandwidth sample
#   LARGE_BUFFER_MIB_THRESHOLD=1024  when BUFFER_SIZE >= threshold, use large-buffer auto-loop policy
#   LARGE_TARGET_TRANSFER_MIB=8192   target logical transferred MiB per sample for large buffers
#   LARGE_MIN_LOOP_COUNT=4           lower bound for large-buffer auto-loop count
#   LOOP_COUNT=<N>                fixed loopCount for all buffers; overrides auto/scaled mode
#   USE_SCALED_LOOP_COUNT=0       scale loopCount inversely with buffer size
#   BASE_LOOP_COUNT=5000          loopCount at BASE_BUFFER_MIB when USE_SCALED_LOOP_COUNT=1
#   BASE_BUFFER_MIB=2             base buffer for scaled loopCount
#   MIN_LOOP_COUNT=16             lower bound for scaled loopCount
#   MAX_LOOP_COUNT=262144         upper bound for scaled loopCount
#   COLLECT_SCRIPT=./collect_amdprof_mem_bw_t33.sh
#   PTR_CHASE_LOAD_BYTES=         optional single --ptrChaseLoadBytes value; supported: 8, 16, 32
#   PTR_CHASE_LOAD_BYTES_LIST="8 16 32" optional t33 load-size sweep list
#   SM_COPY_BYTES_LIST=           accepted as an alias for PTR_CHASE_LOAD_BYTES_LIST on t33

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUFFER_SIZES="${BUFFER_SIZES:-1 2 4 8 16 32 64 128 256 512 1024 2048}"
RETRIES="${RETRIES:-2}"
COLLECT_SCRIPT="${COLLECT_SCRIPT:-./collect_amdprof_mem_bw_t33.sh}"
RUN_LABEL="${RUN_LABEL:-}"

if [[ -n "$RUN_LABEL" ]]; then
    OUTROOT_DEFAULT="amdprof_nvbw_t33_${RUN_LABEL}_sweep_$(date +%Y%m%d_%H%M%S)"
else
    OUTROOT_DEFAULT="amdprof_nvbw_t33_sweep_$(date +%Y%m%d_%H%M%S)"
fi
OUTROOT="${OUTROOT:-$OUTROOT_DEFAULT}"
SWEEP_INFO_FILE="$OUTROOT/sweep${RUN_LABEL:+_${RUN_LABEL}}.info"
DRIVER_LOG_BASENAME="driver${RUN_LABEL:+_${RUN_LABEL}}.log"

TESTCASE="${TESTCASE:-33}"
CUDA_VISIBLE_DEVICES_VALUE="${CUDA_VISIBLE_DEVICES-0}"
NUMA_NODE_VALUE="${NUMA_NODE-0}"
CPU_BIND_VALUE="${CPU_BIND-1}"
TEST_SAMPLES_VALUE="${TEST_SAMPLES-}"
HOST_READ_PARALLELISM_VALUE="${HOST_READ_PARALLELISM-}"
LATENCY_STRIDE_LEN_VALUE="${LATENCY_STRIDE_LEN-}"
EXTRA_NVBW_ARGS_VALUE="${EXTRA_NVBW_ARGS-}"
PTR_CHASE_LOAD_BYTES_LIST="${PTR_CHASE_LOAD_BYTES_LIST-${SM_COPY_BYTES_LIST-${PTR_CHASE_LOAD_BYTES-8 16 32}}}"
SKIP_VERIFICATION="${SKIP_VERIFICATION:-1}"
VERBOSE_NVBW="${VERBOSE_NVBW:-0}"

PCM_METRICS="${PCM_METRICS:-memory,umc,ipc,l3,pcie}"
PCM_SCOPE="${PCM_SCOPE:-all}"
PCM_AGGREGATE="${PCM_AGGREGATE:-system,package}"
SAMPLE_INTERVAL_MS="${SAMPLE_INTERVAL_MS:-5}"
PROFILE_SECONDS="${PROFILE_SECONDS:-}"
START_DELAY_MS="${START_DELAY_MS:-0}"
PCM_WAIT_FOR_SIGNAL="${PCM_WAIT_FOR_SIGNAL:-1}"
PCM_SIGNAL_END="${PCM_SIGNAL_END:-1}"
PCM_SIGNAL_READY_DELAY_MS="${PCM_SIGNAL_READY_DELAY_MS:-200}"
COLLECT_POWER="${COLLECT_POWER:-0}"
COLLECT_PCIE="${COLLECT_PCIE:-0}"
COLLECT_XGMI="${COLLECT_XGMI:-0}"
HTML_REPORT="${HTML_REPORT:-0}"

LOOP_COUNT_VALUE="${LOOP_COUNT-}"
AUTO_LOOP_COUNT="${AUTO_LOOP_COUNT:-1}"
TARGET_TRANSFER_MIB="${TARGET_TRANSFER_MIB:-32768}"
LARGE_BUFFER_MIB_THRESHOLD="${LARGE_BUFFER_MIB_THRESHOLD:-1024}"
LARGE_TARGET_TRANSFER_MIB="${LARGE_TARGET_TRANSFER_MIB:-8192}"
LARGE_MIN_LOOP_COUNT="${LARGE_MIN_LOOP_COUNT:-4}"
USE_SCALED_LOOP_COUNT="${USE_SCALED_LOOP_COUNT:-0}"
BASE_LOOP_COUNT="${BASE_LOOP_COUNT:-5000}"
BASE_BUFFER_MIB="${BASE_BUFFER_MIB:-2}"
MIN_LOOP_COUNT="${MIN_LOOP_COUNT:-16}"
MAX_LOOP_COUNT="${MAX_LOOP_COUNT:-262144}"

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
    if (( loop_count > MAX_LOOP_COUNT )); then
        loop_count="$MAX_LOOP_COUNT"
    fi
    printf '%s\n' "$loop_count"
}

auto_loop_count() {
    local buffer_mib="$1"
    local target_transfer_mib="$TARGET_TRANSFER_MIB"
    local min_loop_count="$MIN_LOOP_COUNT"
    local loop_count

    if (( buffer_mib >= LARGE_BUFFER_MIB_THRESHOLD )); then
        target_transfer_mib="$LARGE_TARGET_TRANSFER_MIB"
        min_loop_count="$LARGE_MIN_LOOP_COUNT"
    fi

    loop_count=$(( (target_transfer_mib + buffer_mib - 1) / buffer_mib ))
    if (( loop_count < min_loop_count )); then
        loop_count="$min_loop_count"
    fi
    if (( loop_count > MAX_LOOP_COUNT )); then
        loop_count="$MAX_LOOP_COUNT"
    fi
    printf '%s\n' "$loop_count"
}

{
    echo "sweep_root=$OUTROOT"
    echo "buffer_sizes_MiB=$BUFFER_SIZES"
    echo "ptr_chase_load_bytes_list=$PTR_CHASE_LOAD_BYTES_LIST"
    echo "retries=$RETRIES"
    echo "collect_script=$COLLECT_SCRIPT"
    echo "testcase=$TESTCASE"
    echo "cuda_visible_devices=$CUDA_VISIBLE_DEVICES_VALUE"
    echo "numa_node=$NUMA_NODE_VALUE"
    echo "cpu_bind=$CPU_BIND_VALUE"
    echo "pcm_metrics=$PCM_METRICS"
    echo "pcm_scope=$PCM_SCOPE"
    echo "pcm_aggregate=$PCM_AGGREGATE"
    echo "sample_interval_ms=$SAMPLE_INTERVAL_MS"
    echo "profile_seconds=$PROFILE_SECONDS"
    echo "start_delay_ms=$START_DELAY_MS"
    echo "pcm_wait_for_signal=$PCM_WAIT_FOR_SIGNAL"
    echo "pcm_signal_end=$PCM_SIGNAL_END"
    echo "loop_count_fixed=$LOOP_COUNT_VALUE"
    echo "auto_loop_count=$AUTO_LOOP_COUNT"
    echo "target_transfer_mib=$TARGET_TRANSFER_MIB"
    echo "large_buffer_mib_threshold=$LARGE_BUFFER_MIB_THRESHOLD"
    echo "large_target_transfer_mib=$LARGE_TARGET_TRANSFER_MIB"
    echo "large_min_loop_count=$LARGE_MIN_LOOP_COUNT"
    echo "use_scaled_loop_count=$USE_SCALED_LOOP_COUNT"
    echo "base_loop_count=$BASE_LOOP_COUNT"
    echo "base_buffer_mib=$BASE_BUFFER_MIB"
    echo "min_loop_count=$MIN_LOOP_COUNT"
    echo "max_loop_count=$MAX_LOOP_COUNT"
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
        fi

        run_extra_nvbw_args="${EXTRA_NVBW_ARGS_VALUE:+$EXTRA_NVBW_ARGS_VALUE }--ptrChaseLoadBytes $ptr_chase_load_bytes"

        common_env=(
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
            "PCM_METRICS=$PCM_METRICS"
            "PCM_SCOPE=$PCM_SCOPE"
            "PCM_AGGREGATE=$PCM_AGGREGATE"
            "SAMPLE_INTERVAL_MS=$SAMPLE_INTERVAL_MS"
            "PROFILE_SECONDS=$PROFILE_SECONDS"
            "START_DELAY_MS=$START_DELAY_MS"
            "PCM_WAIT_FOR_SIGNAL=$PCM_WAIT_FOR_SIGNAL"
            "PCM_SIGNAL_END=$PCM_SIGNAL_END"
            "PCM_SIGNAL_READY_DELAY_MS=$PCM_SIGNAL_READY_DELAY_MS"
            "COLLECT_POWER=$COLLECT_POWER"
            "COLLECT_PCIE=$COLLECT_PCIE"
            "COLLECT_XGMI=$COLLECT_XGMI"
            "HTML_REPORT=$HTML_REPORT"
        )

        for attempt in $(seq 1 "$RETRIES"); do
            suffix=""
            if (( attempt > 1 )); then
                suffix="_retry${attempt}"
            fi
            outdir="$OUTROOT/buffer_${b}MiB_ptrload_${ptr_chase_load_bytes}B${suffix}"
            mkdir -p "$outdir"

            echo
            echo "===== PTR_CHASE_LOAD_BYTES=${ptr_chase_load_bytes} BUFFER_SIZE=${b} MiB attempt=${attempt}/${RETRIES} -> ${outdir} ====="
            echo "  ${loop_env[*]-}"
            if [[ "$AUTO_LOOP_COUNT" != "0" && -z "$LOOP_COUNT_VALUE" && "$USE_SCALED_LOOP_COUNT" == "0" ]]; then
                if (( b >= LARGE_BUFFER_MIB_THRESHOLD )); then
                    echo "  auto target (large buffer): ~${LARGE_TARGET_TRANSFER_MIB} MiB logical transfer per sample, bounds=[${LARGE_MIN_LOOP_COUNT}, ${MAX_LOOP_COUNT}]"
                else
                    echo "  auto target: ~${TARGET_TRANSFER_MIB} MiB logical transfer per sample, bounds=[${MIN_LOOP_COUNT}, ${MAX_LOOP_COUNT}]"
                fi
            fi
            echo "  EXTRA_NVBW_ARGS=$run_extra_nvbw_args"
            echo "  SAMPLE_INTERVAL_MS=$SAMPLE_INTERVAL_MS PCM_WAIT_FOR_SIGNAL=$PCM_WAIT_FOR_SIGNAL PCM_METRICS=$PCM_METRICS"

            set +e
            env OUTDIR="$outdir" BUFFER_SIZE="$b" "${common_env[@]}" "${loop_env[@]}" "${collect_cmd[@]}" 2>&1 | tee "$outdir/$DRIVER_LOG_BASENAME"
            rc=${PIPESTATUS[0]}
            set -e

            if [[ "$rc" -eq 0 ]]; then
                echo "PTR_CHASE_LOAD_BYTES=${ptr_chase_load_bytes} BUFFER_SIZE=${b} status=ok attempt=${attempt} outdir=${outdir} ${loop_env[*]-}" | tee -a "$SWEEP_INFO_FILE"
                ok=1
                break
            fi

            echo "PTR_CHASE_LOAD_BYTES=${ptr_chase_load_bytes} BUFFER_SIZE=${b} status=failed attempt=${attempt} rc=${rc} outdir=${outdir} ${loop_env[*]-}" | tee -a "$SWEEP_INFO_FILE"
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

summary_csv="$OUTROOT/amdprof_summary.csv"
summary_md="$OUTROOT/amdprof_summary.md"

# Generate a compact cross-buffer summary from collect_amdprof_mem_bw_t33.sh summaries.
# shellcheck disable=SC2086
python3 - "$OUTROOT" "$TESTCASE" "$PTR_CHASE_LOAD_BYTES_LIST" $BUFFER_SIZES <<'PY'
from pathlib import Path
import csv
import re
import sys

root = Path(sys.argv[1])
testcase = sys.argv[2]
ptr_chase_load_bytes_values = [int(x) for x in sys.argv[3].split()]
buffers = [int(x) for x in sys.argv[4:]]


def parse_kv(path):
    data = {}
    if not path.exists():
        return data
    for line in path.read_text(errors='replace').splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            data[key.strip()] = value.strip()
    return data


def retry_order(path):
    match = re.search(r'_retry(\d+)$', path.name)
    return int(match.group(1)) if match else 1


def dirs_for_combo(buffer_mib, ptr_chase_load_bytes):
    candidates = []
    for path in root.iterdir() if root.exists() else []:
        if not path.is_dir():
            continue
        if path.name == f'buffer_{buffer_mib}MiB_ptrload_{ptr_chase_load_bytes}B' or re.match(rf'^buffer_{buffer_mib}MiB_ptrload_{ptr_chase_load_bytes}B_retry\d+$', path.name):
            if (path / 'summary.txt').is_file() or (path / 'run.info').is_file():
                candidates.append(path)
    return sorted(candidates, key=lambda p: (retry_order(p), p.name))


def first_value(data, keys):
    for key in keys:
        value = data.get(key, '')
        if value and value != 'NOT_FOUND':
            return value
    return ''


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
        info = parse_kv(outdir / 'run.info')
        summary = parse_kv(outdir / 'summary.txt')
        rc = info.get('workload_rc') or info.get('nvbandwidth_rc') or ''
        row.update({
            'status': 'ok' if rc in {'', '0'} else f'rc={rc}',
            'result_dir': str(outdir),
            'workload_rc': rc,
            'loop_count': info.get('loop_count', ''),
            'nvbandwidth_SUM_GBps': first_value(summary, ['nvbandwidth_SUM_host_device_bandwidth_sm_GBps', 'nvbandwidth_SUM_GBps']),
            'system_mem_read_median_GBps': summary.get('system_total_mem_read_bw_GBps_median', ''),
            'system_mem_read_p95_GBps': summary.get('system_total_mem_read_bw_GBps_p95', ''),
            'system_mem_read_max_GBps': summary.get('system_total_mem_read_bw_GBps_max', ''),
            'system_mem_write_median_GBps': summary.get('system_total_mem_write_bw_GBps_median', ''),
            'system_mem_total_median_GBps': summary.get('system_total_mem_bw_GBps_median', ''),
            'target_package_mem_read_median_GBps': first_value(summary, ['target_package_total_mem_read_bw_GBps_median', 'target_package_est_mem_read_bw_GBps_median']),
            'system_pcie_read_median_GBps': summary.get('system_total_pcie_read_bw_GBps_median', ''),
            'system_pcie_read_p95_GBps': summary.get('system_total_pcie_read_bw_GBps_p95', ''),
            'system_pcie_read_max_GBps': summary.get('system_total_pcie_read_bw_GBps_max', ''),
            'system_pcie_write_median_GBps': summary.get('system_total_pcie_write_bw_GBps_median', ''),
            'system_pcie_total_median_GBps': summary.get('system_total_pcie_bw_GBps_median', ''),
            'timeseries_samples': summary.get('timeseries_samples', ''),
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
    'target_package_mem_read_median_GBps',
    'system_pcie_read_median_GBps',
    'system_pcie_read_p95_GBps',
    'system_pcie_read_max_GBps',
    'system_pcie_write_median_GBps',
    'system_pcie_total_median_GBps',
    'timeseries_samples',
    'workload_rc',
    'result_dir',
]

csv_path = root / 'amdprof_summary.csv'
with csv_path.open('w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)


def cell(row, key):
    value = row.get(key, '')
    return '' if value is None else str(value)


md_lines = [
    f'# AMD uProf PCM nvbandwidth testcase {testcase} sweep summary',
    '',
    '- Units: GB/s.',
    '- `Ptr load bytes` maps to nvbandwidth `--ptrChaseLoadBytes` for testcase 33.',
    '- `System Mem Rd` comes from AMDuProfPcm `Total Mem RdBw (GB/s)` / `System (Aggregated)`.',
    '- `System PCIe Rd` comes from AMDuProfPcm `Total PCIE Rd Bandwidth (GB/s)` / `System (Aggregated)`.',
    '',
    '| Ptr load bytes | Buffer MiB | LoopCount | Status | nvbandwidth SUM | System Mem Rd median | System Mem Rd p95 | System PCIe Rd median | System PCIe Rd p95 | Samples | Result dir |',
    '| ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |',
]
for row in rows:
    md_lines.append(
        f"| {cell(row, 'ptr_chase_load_bytes')} | {cell(row, 'buffer_MiB')} | {cell(row, 'loop_count')} | {cell(row, 'status')} | {cell(row, 'nvbandwidth_SUM_GBps')} | "
        f"{cell(row, 'system_mem_read_median_GBps')} | {cell(row, 'system_mem_read_p95_GBps')} | "
        f"{cell(row, 'system_pcie_read_median_GBps')} | {cell(row, 'system_pcie_read_p95_GBps')} | "
        f"{cell(row, 'timeseries_samples')} | {cell(row, 'result_dir')} |"
    )

md_path = root / 'amdprof_summary.md'
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

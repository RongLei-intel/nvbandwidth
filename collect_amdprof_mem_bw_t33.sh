#!/usr/bin/env bash
set -euo pipefail

# Collect and parse AMD uProf PCM memory bandwidth and related metrics for nvbandwidth testcase 33.
# Default workload:
#   CUDA_VISIBLE_DEVICES=0 numactl --membind=0 --physcpubind=1 ./nvbandwidth -t 33
#
# Default uProf metrics:
#   memory,umc,ipc,l3,pcie
#
# Tunables:
#   AMDPROF_PCM=AMDuProfPcm        AMD uProf PCM command
#   CUDA_VISIBLE_DEVICES=0         GPU selection
#   NUMA_NODE=0                    NUMA node for host memory binding; also used as target Package-N
#   CPU_BIND=1                     CPU/core binding for numactl --physcpubind
#   TESTCASE=33                    nvbandwidth testcase
#   BUFFER_SIZE=                   optional nvbandwidth --bufferSize value in MiB
#   LOOP_COUNT=                    optional nvbandwidth --loopCount value; empty means use nvbandwidth default
#   TEST_SAMPLES=                  optional nvbandwidth --testSamples value
#   HOST_READ_PARALLELISM=         optional nvbandwidth --hostReadParallelism chains per SM for testcase 33
#   LATENCY_STRIDE_LEN=            optional nvbandwidth --latencyStrideLen pointer-chase stride
#   VERBOSE_NVBW=0                 set 1 to add nvbandwidth --verbose
#   SKIP_VERIFICATION=0            set 1 to add --skipVerification
#   EXTRA_NVBW_ARGS="..."          extra nvbandwidth args, e.g. "-L 1000 -i 5"
#   PCM_METRICS=memory,umc,ipc,l3,pcie
#   PCM_SCOPE=all                  all => -a, otherwise passed as -c value, e.g. "numa=0" or "package=0"
#   PCM_AGGREGATE=system,package   report aggregate levels
#   SAMPLE_INTERVAL_MS=100         AMDuProfPcm -I interval
#   PROFILE_SECONDS=               optional AMDuProfPcm -d seconds; empty means stop when app exits
#   START_DELAY_MS=0               optional AMDuProfPcm --start-delay milliseconds
#   PCM_WAIT_FOR_SIGNAL=0          set 1 to add AMDuProfPcm --wait-for-signal and let nvbandwidth send SIGUSR1 start
#   PCM_SIGNAL_END=1               with PCM_WAIT_FOR_SIGNAL=1, let nvbandwidth send SIGINT end after testcase 33 active region
#   PCM_SIGNAL_READY_DELAY_MS=200  delay after starting AMDuProfPcm before launching workload in signal mode
#   COLLECT_POWER=0                set 1 to add --collect-power
#   COLLECT_PCIE=0                 set 1 to add --collect-pcie, in addition to pcie metric
#   COLLECT_XGMI=0                 set 1 to add --collect-xgmi
#   HTML_REPORT=0                  set 1 to add --html
#   OUTDIR=<dir>                   output directory

AMDPROF_PCM="${AMDPROF_PCM:-AMDuProfPcm}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
NUMA_NODE="${NUMA_NODE:-0}"
CPU_BIND="${CPU_BIND:-1}"
TESTCASE="${TESTCASE:-33}"
BUFFER_SIZE="${BUFFER_SIZE:-}"
LOOP_COUNT="${LOOP_COUNT:-}"
TEST_SAMPLES="${TEST_SAMPLES:-}"
HOST_READ_PARALLELISM="${HOST_READ_PARALLELISM:-512}"
LATENCY_STRIDE_LEN="${LATENCY_STRIDE_LEN:-8}"
VERBOSE_NVBW="${VERBOSE_NVBW:-0}"
SKIP_VERIFICATION="${SKIP_VERIFICATION:-0}"
EXTRA_NVBW_ARGS="${EXTRA_NVBW_ARGS:-}"
PCM_METRICS="${PCM_METRICS:-memory,umc,ipc,l3,pcie}"
PCM_SCOPE="${PCM_SCOPE:-all}"
PCM_AGGREGATE="${PCM_AGGREGATE:-system,package}"
SAMPLE_INTERVAL_MS="${SAMPLE_INTERVAL_MS:-100}"
PROFILE_SECONDS="${PROFILE_SECONDS:-}"
START_DELAY_MS="${START_DELAY_MS:-0}"
PCM_WAIT_FOR_SIGNAL="${PCM_WAIT_FOR_SIGNAL:-0}"
PCM_SIGNAL_END="${PCM_SIGNAL_END:-1}"
PCM_SIGNAL_READY_DELAY_MS="${PCM_SIGNAL_READY_DELAY_MS:-200}"
COLLECT_POWER="${COLLECT_POWER:-0}"
COLLECT_PCIE="${COLLECT_PCIE:-0}"
COLLECT_XGMI="${COLLECT_XGMI:-0}"
HTML_REPORT="${HTML_REPORT:-0}"
OUTDIR="${OUTDIR:-amdprof_nvbw_t${TESTCASE}_membw_$(date +%Y%m%d_%H%M%S)}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v "$AMDPROF_PCM" >/dev/null 2>&1; then
  echo "ERROR: $AMDPROF_PCM not found in PATH" >&2
  exit 127
fi

if ! command -v numactl >/dev/null 2>&1; then
  echo "ERROR: numactl not found" >&2
  exit 127
fi

if [[ ! -x ./nvbandwidth ]]; then
  echo "ERROR: ./nvbandwidth not found or not executable in $SCRIPT_DIR" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

nvbandwidth_args=(-t "$TESTCASE")
if [[ -n "$BUFFER_SIZE" ]]; then
    nvbandwidth_args+=(--bufferSize "$BUFFER_SIZE")
fi
if [[ -n "$LOOP_COUNT" ]]; then
  nvbandwidth_args+=(--loopCount "$LOOP_COUNT")
fi
if [[ -n "$TEST_SAMPLES" ]]; then
  nvbandwidth_args+=(--testSamples "$TEST_SAMPLES")
fi
if [[ -n "$HOST_READ_PARALLELISM" ]]; then
    nvbandwidth_args+=(--hostReadParallelism "$HOST_READ_PARALLELISM")
fi
if [[ -n "$LATENCY_STRIDE_LEN" ]]; then
    nvbandwidth_args+=(--latencyStrideLen "$LATENCY_STRIDE_LEN")
fi
if [[ "$VERBOSE_NVBW" != "0" ]]; then
    nvbandwidth_args+=(--verbose)
fi
if [[ "$SKIP_VERIFICATION" != "0" ]]; then
  nvbandwidth_args+=(--skipVerification)
fi
if [[ -n "$EXTRA_NVBW_ARGS" ]]; then
  # shellcheck disable=SC2206
  extra_args=( $EXTRA_NVBW_ARGS )
  nvbandwidth_args+=("${extra_args[@]}")
fi

scope_args=()
if [[ "$PCM_SCOPE" == "all" ]]; then
  scope_args=(-a)
elif [[ -n "$PCM_SCOPE" ]]; then
  scope_args=(-c "$PCM_SCOPE")
fi

aggregate_args=()
if [[ -n "$PCM_AGGREGATE" ]]; then
  aggregate_args=(-A "$PCM_AGGREGATE")
fi

duration_args=()
if [[ -n "$PROFILE_SECONDS" ]]; then
  duration_args=(-d "$PROFILE_SECONDS")
fi

start_delay_args=()
if [[ "$START_DELAY_MS" != "0" && -n "$START_DELAY_MS" ]]; then
  start_delay_args=(--start-delay "$START_DELAY_MS")
fi

extra_pcm_args=()
if [[ "$COLLECT_POWER" != "0" ]]; then
  extra_pcm_args+=(--collect-power)
fi
if [[ "$COLLECT_PCIE" != "0" ]]; then
  extra_pcm_args+=(--collect-pcie)
fi
if [[ "$COLLECT_XGMI" != "0" ]]; then
  extra_pcm_args+=(--collect-xgmi)
fi
if [[ "$HTML_REPORT" != "0" ]]; then
  extra_pcm_args+=(--html)
fi
if [[ "$PCM_WAIT_FOR_SIGNAL" != "0" ]]; then
    extra_pcm_args+=(--wait-for-signal)
fi

workload_cmd=(
  env "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}"
    "NVB_AMDPROF_SIGNAL_MARKERS=${PCM_WAIT_FOR_SIGNAL}"
    "NVB_AMDPROF_SIGNAL_END=${PCM_SIGNAL_END}"
  numactl "--membind=${NUMA_NODE}" "--physcpubind=${CPU_BIND}"
  ./nvbandwidth "${nvbandwidth_args[@]}"
)

pcm_cmd=(
  "$AMDPROF_PCM" profile
  -m "$PCM_METRICS"
  "${scope_args[@]}"
  "${aggregate_args[@]}"
  "${duration_args[@]}"
  "${start_delay_args[@]}"
  -I "$SAMPLE_INTERVAL_MS"
  -O "$OUTDIR"
  "${extra_pcm_args[@]}"
)

if [[ "$PCM_WAIT_FOR_SIGNAL" == "0" ]]; then
    pcm_cmd+=(-- "${workload_cmd[@]}")
fi

{
  printf '%q ' "${pcm_cmd[@]}"
  echo
} > "$OUTDIR/command.txt"

cat > "$OUTDIR/run.info" <<RUNINFO
outdir=$OUTDIR
amdprof_pcm=$AMDPROF_PCM
amdprof_command=${pcm_cmd[*]}
workload_command=${workload_cmd[*]}
nvbandwidth_args=${nvbandwidth_args[*]}
cuda_visible_devices=$CUDA_VISIBLE_DEVICES
numa_node=$NUMA_NODE
cpu_bind=$CPU_BIND
testcase=$TESTCASE
buffer_size=$BUFFER_SIZE
loop_count=$LOOP_COUNT
test_samples=$TEST_SAMPLES
host_read_parallelism=$HOST_READ_PARALLELISM
latency_stride_len=$LATENCY_STRIDE_LEN
verbose_nvbw=$VERBOSE_NVBW
skip_verification=$SKIP_VERIFICATION
extra_nvbw_args=$EXTRA_NVBW_ARGS
pcm_metrics=$PCM_METRICS
pcm_scope=$PCM_SCOPE
pcm_aggregate=$PCM_AGGREGATE
sample_interval_ms=$SAMPLE_INTERVAL_MS
profile_seconds=$PROFILE_SECONDS
start_delay_ms=$START_DELAY_MS
pcm_wait_for_signal=$PCM_WAIT_FOR_SIGNAL
pcm_signal_end=$PCM_SIGNAL_END
pcm_signal_ready_delay_ms=$PCM_SIGNAL_READY_DELAY_MS
collect_power=$COLLECT_POWER
collect_pcie=$COLLECT_PCIE
collect_xgmi=$COLLECT_XGMI
html_report=$HTML_REPORT
RUNINFO

echo "Collecting AMD uProf PCM metrics..."
echo "  output dir : $OUTDIR"
echo "  metrics    : $PCM_METRICS"
echo "  aggregate  : $PCM_AGGREGATE"
echo "  wait signal: $PCM_WAIT_FOR_SIGNAL"
echo "  workload   : ${workload_cmd[*]}"
echo

set +e
workload_rc=0
if [[ "$PCM_WAIT_FOR_SIGNAL" != "0" ]]; then
    "${pcm_cmd[@]}" > "$OUTDIR/amdprof_pcm.out" 2> "$OUTDIR/amdprof_pcm.err" &
    amdprof_pid=$!
    python3 - "$PCM_SIGNAL_READY_DELAY_MS" <<'PY'
import sys
import time
time.sleep(max(0, int(sys.argv[1])) / 1000.0)
PY
    workload_cmd=(
        env "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}"
        "NVB_AMDPROF_SIGNAL_MARKERS=${PCM_WAIT_FOR_SIGNAL}"
        "NVB_AMDPROF_SIGNAL_END=${PCM_SIGNAL_END}"
        "NVB_AMDPROF_SIGNAL_PID=${amdprof_pid}"
        numactl "--membind=${NUMA_NODE}" "--physcpubind=${CPU_BIND}"
        ./nvbandwidth "${nvbandwidth_args[@]}"
    )
    "${workload_cmd[@]}" > "$OUTDIR/nvbandwidth.out" 2> "$OUTDIR/nvbandwidth.err"
    workload_rc=$?
    wait "$amdprof_pid"
    amdprof_rc=$?
else
    "${pcm_cmd[@]}" > "$OUTDIR/amdprof_pcm.out" 2> "$OUTDIR/amdprof_pcm.err"
    amdprof_rc=$?
fi
set -e

echo "amdprof_rc=$amdprof_rc" >> "$OUTDIR/run.info"
echo "workload_rc=$workload_rc" >> "$OUTDIR/run.info"

if [[ "$amdprof_rc" -ne 0 ]]; then
  echo "ERROR: AMDuProfPcm failed with rc=$amdprof_rc" >&2
  echo "See: $OUTDIR/amdprof_pcm.out and $OUTDIR/amdprof_pcm.err" >&2
  exit "$amdprof_rc"
fi

if [[ "$workload_rc" -ne 0 ]]; then
    echo "ERROR: workload failed with rc=$workload_rc" >&2
    echo "See: $OUTDIR/amdprof_pcm.out and $OUTDIR/amdprof_pcm.err" >&2
    exit "$workload_rc"
fi

report_dir="$(find "$OUTDIR" -maxdepth 1 -type d -name 'AMDuProfPcm-*' | sort | tail -n 1)"
if [[ -z "$report_dir" || ! -f "$report_dir/report-timeseries.csv" ]]; then
  echo "ERROR: could not find AMDuProfPcm report-timeseries.csv under $OUTDIR" >&2
  exit 1
fi

echo "report_dir=$report_dir" >> "$OUTDIR/run.info"

# Keep convenient copies/symlinks at the top-level output dir.
ln -sfn "$(basename "$report_dir")/report-timeseries.csv" "$OUTDIR/report-timeseries.csv"
ln -sfn "$(basename "$report_dir")/report-cumulative.csv" "$OUTDIR/report-cumulative.csv"
[[ -f "$report_dir/report.json" ]] && ln -sfn "$(basename "$report_dir")/report.json" "$OUTDIR/report.json"
[[ -f "$report_dir/report.html" ]] && ln -sfn "$(basename "$report_dir")/report.html" "$OUTDIR/report.html"

python3 - "$OUTDIR" "$report_dir" "$NUMA_NODE" <<'PY' | tee "$OUTDIR/summary.txt"
from pathlib import Path
import csv
import math
import re
import statistics
import sys

outdir = Path(sys.argv[1])
report_dir = Path(sys.argv[2])
numa_node = int(sys.argv[3])
target_package = f"Package-{numa_node}"
target_package_aggr = f"Package (Aggregated)-{numa_node}"

def to_float(value):
    value = str(value).strip()
    if not value or value.upper() in {'NA', 'N/A', 'NAN', '-'}:
        return None
    value = value.replace('%', '').replace(',', '')
    try:
        x = float(value)
    except ValueError:
        return None
    if math.isnan(x) or math.isinf(x):
        return None
    return x

def ffill(row, n):
    out = []
    last = ''
    for i in range(n):
        v = row[i].strip() if i < len(row) else ''
        if v:
            last = v
        out.append(last)
    return out

def find_metric_header(rows):
    for i, row in enumerate(rows):
        joined = ','.join(row)
        if 'Total Mem RdBw (GB/s)' in joined and 'Retired Instructions' in joined:
            return i
    for i, row in enumerate(rows):
        joined = ','.join(row)
        if 'Total Mem RdBw (GB/s)' in joined:
            return i
    raise SystemExit('ERROR: could not locate metric header row in report-timeseries.csv')

def load_timeseries(path):
    rows = list(csv.reader(path.open(errors='replace')))
    header_i = find_metric_header(rows)
    n = max(len(rows[header_i]), len(rows[header_i - 1]), len(rows[header_i - 2]))
    metric_group = ffill(rows[header_i - 2], n)
    component = ffill(rows[header_i - 1], n)
    metric = [(rows[header_i][i].strip() if i < len(rows[header_i]) else '') for i in range(n)]
    columns = []
    for idx in range(n):
        columns.append({
            'idx': idx,
            'metric_group': metric_group[idx],
            'component': component[idx],
            'metric': metric[idx],
        })
    data = []
    for row in rows[header_i + 1:]:
        if not row or not any(cell.strip() for cell in row):
            continue
        # Metric data rows are mostly numeric; skip text sections after/before data if any.
        numeric_count = sum(1 for cell in row if to_float(cell) is not None)
        if numeric_count < 5:
            continue
        data.append(row)
    return columns, data

columns, data = load_timeseries(report_dir / 'report-timeseries.csv')
nv_output_path = outdir / 'nvbandwidth.out'
if not nv_output_path.exists():
    nv_output_path = outdir / 'amdprof_pcm.out'
nv_output = nv_output_path.read_text(errors='replace')
reported = None
for line in nv_output.splitlines():
    m = re.match(r'^SUM\s+host_device_bandwidth_sm\s+([0-9.]+)', line.strip())
    if m:
        reported = float(m.group(1))

def series_for(metric_name, component=None, group=None, component_contains=None, group_contains=None, metric_contains=None):
    matches = []
    for c in columns:
        if metric_name is not None and c['metric'] != metric_name:
            continue
        if metric_contains is not None and metric_contains.lower() not in c['metric'].lower():
            continue
        if component is not None and c['component'] != component:
            continue
        if component_contains is not None and component_contains.lower() not in c['component'].lower():
            continue
        if group is not None and c['metric_group'] != group:
            continue
        if group_contains is not None and group_contains.lower() not in c['metric_group'].lower():
            continue
        vals = []
        idx = c['idx']
        for row in data:
            if idx < len(row):
                x = to_float(row[idx])
                if x is not None:
                    vals.append(x)
        if vals:
            matches.append((c, vals))
    return matches

def summarize_values(vals):
    if not vals:
        return None
    vals_sorted = sorted(vals)
    p95_idx = min(len(vals_sorted) - 1, max(0, int(math.ceil(0.95 * len(vals_sorted))) - 1))
    return {
        'samples': len(vals),
        'avg': statistics.fmean(vals),
        'median': statistics.median(vals),
        'min': min(vals),
        'max': max(vals),
        'p95': vals_sorted[p95_idx],
    }

def print_summary_line(name, vals):
    s = summarize_values(vals)
    if not s:
        print(f'{name}=NOT_FOUND')
        return
    print(f'{name}_samples={s["samples"]}')
    print(f'{name}_avg={s["avg"]:.3f}')
    print(f'{name}_median={s["median"]:.3f}')
    print(f'{name}_max={s["max"]:.3f}')
    print(f'{name}_p95={s["p95"]:.3f}')

def first_series(metric_name, component=None, group_contains=None, component_contains=None):
    matches = series_for(metric_name, component=component, group_contains=group_contains, component_contains=component_contains)
    return matches[0][1] if matches else []

print('=== nvbandwidth output ===')
if reported is None:
    print('nvbandwidth_SUM_host_device_bandwidth_sm_GBps=NOT_FOUND')
else:
    print(f'nvbandwidth_SUM_host_device_bandwidth_sm_GBps={reported:.3f}')

print('\n=== AMDuProfPcm report ===')
print(f'report_dir={report_dir}')
print(f'target_numa_node={numa_node}')
print(f'target_package_component={target_package}')
print(f'timeseries_samples={len(data)}')

print('\n=== Memory bandwidth summary (GB/s) ===')
for label, metric, comp in [
    ('system_total_mem_bw_GBps', 'Total Mem Bw (GB/s)', 'System (Aggregated)'),
    ('system_total_mem_read_bw_GBps', 'Total Mem RdBw (GB/s)', 'System (Aggregated)'),
    ('system_total_mem_write_bw_GBps', 'Total Mem WrBw (GB/s)', 'System (Aggregated)'),
    ('target_package_total_mem_bw_GBps', 'Total Mem Bw (GB/s)', target_package),
    ('target_package_total_mem_read_bw_GBps', 'Total Mem RdBw (GB/s)', target_package),
    ('target_package_total_mem_write_bw_GBps', 'Total Mem WrBw (GB/s)', target_package),
    ('system_est_mem_bw_GBps', 'Total Est Mem Bw (GB/s)', 'System (Aggregated)'),
    ('system_est_mem_read_bw_GBps', 'Total Est Mem RdBw (GB/s)', 'System (Aggregated)'),
    ('system_est_mem_write_bw_GBps', 'Total Est Mem WrBw (GB/s)', 'System (Aggregated)'),
    ('target_package_est_mem_bw_GBps', 'Total Est Mem Bw (GB/s)', target_package_aggr),
    ('target_package_est_mem_read_bw_GBps', 'Total Est Mem RdBw (GB/s)', target_package_aggr),
    ('target_package_est_mem_write_bw_GBps', 'Total Est Mem WrBw (GB/s)', target_package_aggr),
]:
    vals = first_series(metric, component=comp)
    print_summary_line(label, vals)

print('\n=== PCIe bandwidth summary (GB/s) ===')
for label, metric, comp in [
    ('system_total_pcie_bw_GBps', 'Total PCIE Bandwidth (GB/s)', 'System (Aggregated)'),
    ('system_total_pcie_read_bw_GBps', 'Total PCIE Rd Bandwidth (GB/s)', 'System (Aggregated)'),
    ('system_total_pcie_write_bw_GBps', 'Total PCIE Wr Bandwidth (GB/s)', 'System (Aggregated)'),
    ('target_package_total_pcie_bw_GBps', 'Total PCIE Bandwidth (GB/s)', target_package),
    ('target_package_total_pcie_read_bw_GBps', 'Total PCIE Rd Bandwidth (GB/s)', target_package),
    ('target_package_total_pcie_write_bw_GBps', 'Total PCIE Wr Bandwidth (GB/s)', target_package),
]:
    vals = first_series(metric, component=comp)
    print_summary_line(label, vals)

print('\n=== CPU/IPС/L3 summary ===')
for label, metric, comp in [
    ('system_ipc_sys_user', 'IPC (Sys + User)', 'System (Aggregated)'),
    ('target_package_ipc_sys_user', 'IPC (Sys + User)', target_package_aggr),
    ('system_l3_miss_percent', 'L3 Miss %', 'System (Aggregated)'),
    ('target_package_l3_miss_percent', 'L3 Miss %', target_package_aggr),
    ('system_avg_l3_miss_latency_ns', 'Ave L3 Miss Latency (ns)', 'System (Aggregated)'),
    ('target_package_avg_l3_miss_latency_ns', 'Ave L3 Miss Latency (ns)', target_package_aggr),
]:
    vals = first_series(metric, component=comp)
    print_summary_line(label, vals)

# Print target package memory-channel read/write max/avg for quick channel balance checking.
print('\n=== Target package memory channels (GB/s) ===')
channel_matches = []
for c, vals in series_for(None, component=target_package, metric_contains='Mem Ch-'):
    if 'RdBw (GB/s)' in c['metric'] or 'WrBw (GB/s)' in c['metric']:
        s = summarize_values(vals)
        if s:
            channel_matches.append((c['metric'], s['avg'], s['max']))
if channel_matches:
    for metric, avg, mx in sorted(channel_matches):
        print(f'{metric}: avg={avg:.3f}, max={mx:.3f}')
else:
    print('target_package_memory_channels=NOT_FOUND')

print('\n=== Available matched bandwidth columns ===')
for c in columns:
    text = f'{c["metric_group"]} | {c["component"]} | {c["metric"]}'
    if any(k in c['metric'].lower() for k in ['bw', 'bandwidth']):
        print(text)
PY

echo
echo "Done. Files written under: $OUTDIR"
echo "  nvbandwidth/uProf stdout : $OUTDIR/amdprof_pcm.out"
[[ -f "$OUTDIR/nvbandwidth.out" ]] && echo "  nvbandwidth stdout       : $OUTDIR/nvbandwidth.out"
echo "  uProf stderr            : $OUTDIR/amdprof_pcm.err"
[[ -f "$OUTDIR/nvbandwidth.err" ]] && echo "  nvbandwidth stderr       : $OUTDIR/nvbandwidth.err"
echo "  timeseries CSV          : $OUTDIR/report-timeseries.csv"
echo "  cumulative CSV          : $OUTDIR/report-cumulative.csv"
echo "  parsed summary          : $OUTDIR/summary.txt"

#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CASE_POLICY_FILE="$SCRIPT_DIR/sweep_case_policy.sh"
if [[ -r "$CASE_POLICY_FILE" ]]; then
    source "$CASE_POLICY_FILE"
else
    echo "ERROR: case policy file not found: $CASE_POLICY_FILE" >&2
    exit 1
fi

# AMD collector defaults (overrideable via environment)
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
export NUMA_NODE="${NUMA_NODE:-0}"
export CPU_BIND="${CPU_BIND:-1}"
export SKIP_VERIFICATION="${SKIP_VERIFICATION:-1}"
export VERBOSE_NVBW="${VERBOSE_NVBW:-0}"
export PCM_METRICS="${PCM_METRICS:-memory,umc,ipc,l3,pcie}"
export PCM_SCOPE="${PCM_SCOPE:-all}"
export PCM_AGGREGATE="${PCM_AGGREGATE:-system,package}"
export SAMPLE_INTERVAL_MS="${SAMPLE_INTERVAL_MS:-5}"
export PCM_WAIT_FOR_SIGNAL="${PCM_WAIT_FOR_SIGNAL:-1}"
export PCM_SIGNAL_END="${PCM_SIGNAL_END:-1}"
export PCM_SIGNAL_READY_DELAY_MS="${PCM_SIGNAL_READY_DELAY_MS:-200}"
export COLLECT_POWER="${COLLECT_POWER:-0}"
export COLLECT_PCIE="${COLLECT_PCIE:-0}"
export COLLECT_XGMI="${COLLECT_XGMI:-0}"
export HTML_REPORT="${HTML_REPORT:-0}"
export AMDPROF_WAIT_TIMEOUT_SEC="${AMDPROF_WAIT_TIMEOUT_SEC:-10}"

# Load guard policy from JSON global section
max_seconds="$(json_query global.maxSeconds)"
min_run_time_seconds="$(json_query global.minRunTimeSeconds)"
if [[ -z "$min_run_time_seconds" ]]; then
    min_run_time_seconds=5
fi
min_mem_samples="$(json_query global.minPcmMemorySamples)"
min_pcie_samples="$(json_query global.minPcmPcieSamples)"
grow_factor="$(json_query global.growFactor)"
shrink_factor="$(json_query global.shrinkFactor)"
max_attempts_num="$(json_query global.maxAttempts)"
min_loop_count="$(json_query global.minLoopCount)"
max_loop_count="$(json_query global.maxLoopCount)"

export SWEEP_CASE_MAX_SECONDS="$max_seconds"
export SWEEP_CASE_MIN_RUN_TIME_SECONDS="$min_run_time_seconds"
export SWEEP_CASE_MIN_PCM_MEMORY_SAMPLES="$min_mem_samples"
export SWEEP_CASE_MIN_PCM_PCIE_SAMPLES="$min_pcie_samples"
export SWEEP_CASE_GROW_FACTOR="$grow_factor"
export SWEEP_CASE_SHRINK_FACTOR="$shrink_factor"
export SWEEP_CASE_MAX_ATTEMPTS="$max_attempts_num"
export SWEEP_CASE_MIN_LOOP_COUNT="$min_loop_count"
export SWEEP_CASE_MAX_LOOP_COUNT="$max_loop_count"

failed=0
json_expand_cases

amd_guard_evaluate() {
    local outdir="$1"
    local current_loop_count="$2"
    local run_rc="${3:-}"
    local case_name="${4:-}"

    python3 - "$outdir" "$current_loop_count" "$run_rc" "$case_name" <<'PY'
import os
import sys
from pathlib import Path

outdir = Path(sys.argv[1])
try:
    current_loop_count = int(sys.argv[2])
except ValueError:
    current_loop_count = 1
run_rc = sys.argv[3].strip() if len(sys.argv) > 3 else ''
case_name = sys.argv[4].strip() if len(sys.argv) > 4 else ''

def safe_int(value, default):
    try:
        return int(value)
    except (ValueError, TypeError):
        return default

def safe_float(value, default):
    try:
        return float(value)
    except (ValueError, TypeError):
        return default

max_seconds = safe_int(os.environ.get('SWEEP_CASE_MAX_SECONDS'), 120)
min_run_time = safe_float(os.environ.get('SWEEP_CASE_MIN_RUN_TIME_SECONDS'), 5.0)
min_mem_samples = safe_int(os.environ.get('SWEEP_CASE_MIN_PCM_MEMORY_SAMPLES'), 2)
min_pcie_samples = safe_int(os.environ.get('SWEEP_CASE_MIN_PCM_PCIE_SAMPLES'), 2)
grow_factor = max(2, safe_int(os.environ.get('SWEEP_CASE_GROW_FACTOR'), 2))
shrink_factor = max(2, safe_int(os.environ.get('SWEEP_CASE_SHRINK_FACTOR'), 2))
min_loop_count = safe_int(os.environ.get('SWEEP_CASE_MIN_LOOP_COUNT'), 1)
max_loop_count = safe_int(os.environ.get('SWEEP_CASE_MAX_LOOP_COUNT'), 1000000000)


def load_run_info():
    info = {}
    path = outdir / 'run.info'
    if not path.exists():
        return info
    for line in path.read_text(errors='replace').splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            info[key.strip()] = value.strip()
    return info


def load_summary():
    data = {}
    path = outdir / 'summary.txt'
    if not path.exists():
        return data
    for line in path.read_text(errors='replace').splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            data[key.strip()] = value.strip()
    return data


def parse_float(value):
    if value is None:
        return None
    text = str(value).strip().replace(',', '')
    if not text or text in {'-', 'N/A', '[N/A]', 'NA', 'NOT_FOUND'}:
        return None
    try:
        return float(text)
    except ValueError:
        return None


run_info = load_run_info()
summary = load_summary()

workload_rc = (run_info.get('workload_rc') or run_info.get('nvbandwidth_rc') or '').strip()

timeseries_samples = safe_int(summary.get('timeseries_samples', '0'), 0)

mem_read_median = parse_float(summary.get('system_total_mem_read_bw_GBps_median'))
mem_total_median = parse_float(summary.get('system_total_mem_bw_GBps_median'))
pcie_read_median = parse_float(summary.get('system_total_pcie_read_bw_GBps_median'))
pcie_total_median = parse_float(summary.get('system_total_pcie_bw_GBps_median'))

if mem_read_median is None:
    mem_read_median = parse_float(summary.get('system_total_mem_read_bw_GBps_avg'))
if mem_total_median is None:
    mem_total_median = parse_float(summary.get('system_total_mem_bw_GBps_avg'))
if pcie_read_median is None:
    pcie_read_median = parse_float(summary.get('system_total_pcie_read_bw_GBps_avg'))
if pcie_total_median is None:
    pcie_total_median = parse_float(summary.get('system_total_pcie_bw_GBps_avg'))

nvbw_bw = 0.0
for key, value in summary.items():
    if key.startswith('nvbandwidth_SUM'):
        nvbw_bw = max(nvbw_bw, parse_float(value) or 0.0)
is_fast_workload = nvbw_bw > 10.0
if nvbw_bw > 10.0:
    min_run_time = min(min_run_time, 2.0)

reasons = []
direction = ''

if workload_rc == '124' or run_rc == '124':
    reasons.append('timed out at runtime')
    direction = 'shrink'

if not summary:
    reasons.append('missing summary.txt')
    if not direction:
        direction = 'shrink'

if workload_rc and workload_rc not in {'124', ''} and run_rc not in {'124'}:
    if workload_rc not in {'', '0'}:
        reasons.append(f'workload_rc={workload_rc}')

if summary and not is_fast_workload:
    if timeseries_samples < min_mem_samples:
        reasons.append(f'timeseries_samples={timeseries_samples}<{min_mem_samples}')
        if not direction:
            direction = 'grow'
    if timeseries_samples < min_pcie_samples:
        reasons.append(f'timeseries_samples={timeseries_samples}<{min_pcie_samples}')
        if not direction:
            direction = 'grow'
    if min_run_time > 0:
        sample_interval_ms = safe_int(run_info.get('sample_interval_ms', '5'), 5)
        estimated_run_time = timeseries_samples * sample_interval_ms / 1000.0
        if estimated_run_time < min_run_time:
            reasons.append(f'estimated_run_time={estimated_run_time:.2f}s<{min_run_time}s')
            if not direction:
                direction = 'grow'
    if mem_read_median is None:
        reasons.append('system_mem_read_median_GBps missing')
    elif mem_read_median <= 0:
        reasons.append('system_mem_read_median_GBps=0')
    if mem_total_median is None:
        reasons.append('system_mem_total_median_GBps missing')
    elif mem_total_median <= 0:
        reasons.append('system_mem_total_median_GBps=0')
    if pcie_read_median is None:
        reasons.append('system_pcie_read_median_GBps missing')
    elif pcie_read_median <= 0.001:
        reasons.append('system_pcie_read_median_GBps<=0.001')

if not reasons:
    print('status=ok')
    sys.exit(0)

if not direction:
    direction = 'grow'

if direction == 'grow':
    next_loop_count = min(max_loop_count, max(min_loop_count, current_loop_count * grow_factor))
else:
    next_loop_count = max(min_loop_count, min(max_loop_count, max(1, current_loop_count // shrink_factor)))

if next_loop_count == current_loop_count:
    print('status=fail')
    print('reason=' + '; '.join(reasons) + '; loop_count_clamped')
else:
    print('status=retry')
    print(f'direction={direction}')
    print(f'next_loop_count={next_loop_count}')
    print('reason=' + '; '.join(reasons))
PY
}

run_case() {
    local case_name="$1"
    local testcase="$2"
    local buffer_unit="$3"
    local buffer_value="$4"
    local tune_arg="$5"
    local tune_flag="$6"
    local tune_value="$7"
    local loop_count="$8"
    local outdir="$9"

    if [[ -d "$outdir" ]]; then
        if [[ -f "$outdir/case.info" ]] && grep -q '\[ OK \]' "$outdir/case.info" 2>/dev/null; then
            echo "[SKIP] ${case_name} already completed, skipping"
            return 0
        else
            echo "[CLEAN] ${case_name} has partial/failed result, removing and re-running"
            rm -rf "$outdir"
        fi
    fi

    local attempt=1
    local previous_loop_count=""
    local loop_count_seen=()

    mkdir -p "$outdir"

    while true; do
        if (( max_attempts_num > 0 && attempt > max_attempts_num )); then
            echo "[FAIL] ${case_name} exceeded max attempts" | tee -a "$outdir/case.info"
            return 1
        fi

        rm -rf "$outdir"
        mkdir -p "$outdir"

        echo ""
        echo "===== ${case_name} attempt=${attempt}/${max_attempts_num} -> ${outdir} ====="
        echo "  testcase=${testcase} buffer=${buffer_value}${buffer_unit} tune=${tune_arg}=${tune_value}"
        echo "  LOOP_COUNT=${loop_count}"

        previous_loop_count="$loop_count"

        if [[ "$buffer_unit" == "KiB" ]]; then
            buf_size=""
            buf_size_kib="$buffer_value"
        else
            buf_size="$buffer_value"
            buf_size_kib=""
        fi

        extra_args="${tune_flag} ${tune_value}"

        set +e
        if command -v timeout >/dev/null 2>&1; then
            case_timeout_sec=$(( max_seconds + 30 ))
            if (( case_timeout_sec < 60 )); then
                case_timeout_sec=60
            fi
            timeout --kill-after=5s "${case_timeout_sec}s" \
                env \
                TESTCASE="$testcase" \
                LOOP_COUNT="$loop_count" \
                BUFFER_SIZE="$buf_size" \
                BUFFER_SIZE_KIB="$buf_size_kib" \
                EXTRA_NVBW_ARGS="$extra_args" \
                OUTDIR="$outdir" \
                CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
                NUMA_NODE="$NUMA_NODE" \
                CPU_BIND="$CPU_BIND" \
                SKIP_VERIFICATION="$SKIP_VERIFICATION" \
                VERBOSE_NVBW="$VERBOSE_NVBW" \
                PCM_METRICS="$PCM_METRICS" \
                PCM_SCOPE="$PCM_SCOPE" \
                PCM_AGGREGATE="$PCM_AGGREGATE" \
                SAMPLE_INTERVAL_MS="$SAMPLE_INTERVAL_MS" \
                PCM_WAIT_FOR_SIGNAL="$PCM_WAIT_FOR_SIGNAL" \
                PCM_SIGNAL_END="$PCM_SIGNAL_END" \
                PCM_SIGNAL_READY_DELAY_MS="$PCM_SIGNAL_READY_DELAY_MS" \
                COLLECT_POWER="$COLLECT_POWER" \
                COLLECT_PCIE="$COLLECT_PCIE" \
                COLLECT_XGMI="$COLLECT_XGMI" \
                HTML_REPORT="$HTML_REPORT" \
                AMDPROF_WAIT_TIMEOUT_SEC="$AMDPROF_WAIT_TIMEOUT_SEC" \
                "$SCRIPT_DIR/collect_amdprof_mem_bw_t33.sh" 2>&1 | tee "$outdir/driver.log"
        else
            env \
                TESTCASE="$testcase" \
                LOOP_COUNT="$loop_count" \
                BUFFER_SIZE="$buf_size" \
                BUFFER_SIZE_KIB="$buf_size_kib" \
                EXTRA_NVBW_ARGS="$extra_args" \
                OUTDIR="$outdir" \
                CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
                NUMA_NODE="$NUMA_NODE" \
                CPU_BIND="$CPU_BIND" \
                SKIP_VERIFICATION="$SKIP_VERIFICATION" \
                VERBOSE_NVBW="$VERBOSE_NVBW" \
                PCM_METRICS="$PCM_METRICS" \
                PCM_SCOPE="$PCM_SCOPE" \
                PCM_AGGREGATE="$PCM_AGGREGATE" \
                SAMPLE_INTERVAL_MS="$SAMPLE_INTERVAL_MS" \
                PCM_WAIT_FOR_SIGNAL="$PCM_WAIT_FOR_SIGNAL" \
                PCM_SIGNAL_END="$PCM_SIGNAL_END" \
                PCM_SIGNAL_READY_DELAY_MS="$PCM_SIGNAL_READY_DELAY_MS" \
                COLLECT_POWER="$COLLECT_POWER" \
                COLLECT_PCIE="$COLLECT_PCIE" \
                COLLECT_XGMI="$COLLECT_XGMI" \
                HTML_REPORT="$HTML_REPORT" \
                AMDPROF_WAIT_TIMEOUT_SEC="$AMDPROF_WAIT_TIMEOUT_SEC" \
                "$SCRIPT_DIR/collect_amdprof_mem_bw_t33.sh" 2>&1 | tee "$outdir/driver.log"
        fi
        rc=${PIPESTATUS[0]}
        set -e

        guard_tmp="/tmp/kilo/.guard.$$.tmp"
        amd_guard_evaluate "$outdir" "$loop_count" "$rc" "$case_name" > "$guard_tmp"

        guard_status=""
        guard_reason=""
        guard_direction=""
        guard_next_loop_count=""
        exec 4< "$guard_tmp"
        while IFS= read -r -u 4 guard_line; do
            case "$guard_line" in
                status=*) guard_status="${guard_line#status=}" ;;
                reason=*) guard_reason="${guard_line#reason=}" ;;
                direction=*) guard_direction="${guard_line#direction=}" ;;
                next_loop_count=*) guard_next_loop_count="${guard_line#next_loop_count=}" ;;
            esac
        done
        exec 4<&-
        rm -f "$guard_tmp"

        if [[ -z "$guard_status" && -z "$guard_reason" ]]; then
            echo "[FAIL] ${case_name} guard evaluation crashed (rc=${rc}), check guard output" | tee -a "$outdir/case.info"
            return 1
        fi

        if [[ "$guard_status" == "ok" && "$rc" -eq 0 ]]; then
            echo "[ OK ] ${case_name} loop_count=${loop_count}" | tee -a "$outdir/case.info"
            json_set_case_loop_count "$case_name" "$loop_count" 2>/dev/null || true
            return 0
        fi

        case_guard_warn "${case_name} attempt=${attempt} outdir=${outdir} rc=${rc} guard_status=${guard_status:-unknown} reason=${guard_reason:-unknown}"

        if [[ -n "$guard_next_loop_count" ]]; then
            loop_count="$guard_next_loop_count"
        elif [[ "$guard_direction" == "shrink" ]]; then
            loop_count=$(( loop_count / shrink_factor ))
            if (( loop_count < min_loop_count )); then
                loop_count="$min_loop_count"
            fi
        else
            loop_count=$(( loop_count * grow_factor ))
            if (( loop_count > max_loop_count )); then
                loop_count="$max_loop_count"
            fi
        fi

        if [[ "$loop_count" == "$previous_loop_count" ]]; then
            echo "[FAIL] ${case_name} loop_count stuck at ${loop_count}, cannot optimize further" | tee -a "$outdir/case.info"
            return 1
        fi

        for seen in "${loop_count_seen[@]}"; do
            if [[ "$loop_count" == "$seen" ]]; then
                echo "[FAIL] ${case_name} loop_count oscillating (${loop_count} already tried), cannot converge" | tee -a "$outdir/case.info"
                return 1
            fi
        done
        loop_count_seen+=("$loop_count")
        if ((${#loop_count_seen[@]} > 4)); then
            loop_count_seen=("${loop_count_seen[@]: -4}")
        fi

        attempt=$(( attempt + 1 ))
    done
}

run_label="${RUN_LABEL:-default}"
mkdir -p "$SCRIPT_DIR/out"

case_list_tmp="/tmp/kilo/.case_list.$$.tmp"
json_emit_cases > "$case_list_tmp"

total_cases=$(wc -l < "$case_list_tmp")
current_case=0

exec 3< "$case_list_tmp"
while IFS=$'\t' read -r -u 3 case_name testcase buffer_unit buffer_value tune_arg tune_flag tune_value loop_count; do
    [[ -z "$case_name" ]] && continue
    current_case=$(( current_case + 1 ))
    echo ""
    echo "========================================================================"
    echo "PROGRESS: case ${current_case}/${total_cases}"
    echo "========================================================================"
    outdir="$SCRIPT_DIR/out/${run_label}/${case_name}"
    if ! run_case "$case_name" "$testcase" "$buffer_unit" "$buffer_value" "$tune_arg" "$tune_flag" "$tune_value" "$loop_count" "$outdir"; then
        failed=1
        continue
    fi
done
exec 3<&-

rm -f "$case_list_tmp"

echo ""
echo "========================================================================"
echo "AMD Sweep complete. failed=${failed} total=${total_cases}"
echo "========================================================================"

exit "$failed"

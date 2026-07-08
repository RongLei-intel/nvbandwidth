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

eval "$(json_emit_collector_defaults)"

max_seconds="$(json_query global.maxSeconds)"
min_mem_samples="$(json_query global.minPcmMemorySamples)"
min_pcie_samples="$(json_query global.minPcmPcieSamples)"
grow_factor="$(json_query global.growFactor)"
shrink_factor="$(json_query global.shrinkFactor)"
max_attempts_num="$(json_query global.maxAttempts)"
min_run_seconds="$(json_query global.minRunTimeSeconds)"
min_loop_count="$(json_query global.minLoopCount)"
max_loop_count="$(json_query global.maxLoopCount)"

export SWEEP_CASE_MAX_SECONDS="$max_seconds"
export SWEEP_CASE_MIN_PCM_MEMORY_SAMPLES="$min_mem_samples"
export SWEEP_CASE_MIN_PCM_PCIE_SAMPLES="$min_pcie_samples"
export SWEEP_CASE_GROW_FACTOR="$grow_factor"
export SWEEP_CASE_SHRINK_FACTOR="$shrink_factor"
export SWEEP_CASE_MAX_ATTEMPTS="$max_attempts_num"
export SWEEP_CASE_MIN_LOOP_COUNT="$min_loop_count"
export SWEEP_CASE_MAX_LOOP_COUNT="$max_loop_count"
export SWEEP_CASE_MIN_RUN_TIME_SECONDS="$min_run_seconds"

failed=0
json_expand_cases

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

        # Build BUFFER_SIZE and BUFFER_SIZE_KIB based on unit
        if [[ "$buffer_unit" == "KiB" ]]; then
            buf_size=""
            buf_size_kib="$buffer_value"
        else
            buf_size="$buffer_value"
            buf_size_kib=""
        fi

        extra_args="${tune_flag} ${tune_value}"
        env \
            NVBANDWIDTH_TIMEOUT_SECONDS="$max_seconds" \
            TESTCASE="$testcase" \
            LOOP_COUNT="$loop_count" \
            BUFFER_SIZE="$buf_size" \
            BUFFER_SIZE_KIB="$buf_size_kib" \
            EXTRA_NVBW_ARGS="$extra_args" \
            OUTDIR="$outdir" \
            NVBANDWIDTH_BIN="$NVBANDWIDTH_BIN" \
            CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
            NUMA_NODE="$NUMA_NODE" \
            CPU_BIND="$CPU_BIND" \
            TEST_SAMPLES="$TEST_SAMPLES" \
            HOST_READ_PARALLELISM="$HOST_READ_PARALLELISM" \
            LATENCY_STRIDE_LEN="$LATENCY_STRIDE_LEN" \
            SKIP_VERIFICATION="$SKIP_VERIFICATION" \
            VERBOSE_NVBW="$VERBOSE_NVBW" \
            SAMPLE_INTERVAL="$SAMPLE_INTERVAL" \
            NVIDIA_QUERY_INTERVAL="$NVIDIA_QUERY_INTERVAL" \
            NVIDIA_DMON_INTERVAL="$NVIDIA_DMON_INTERVAL" \
            PCM_TOOLS="$PCM_TOOLS" \
            INCLUDE_NVIDIA_QUERY="$INCLUDE_NVIDIA_QUERY" \
            INCLUDE_NVIDIA_DMON="$INCLUDE_NVIDIA_DMON" \
            INCLUDE_NVIDIA_PMON="$INCLUDE_NVIDIA_PMON" \
            INCLUDE_NVIDIA_APPS="$INCLUDE_NVIDIA_APPS" \
            "$SCRIPT_DIR/collect_pcm_nvsmi_nvbw.sh" 2>&1 | tee "$outdir/driver.log"
        rc=${PIPESTATUS[0]}

        guard_tmp="/tmp/kilo/.guard.$$.tmp"
        case_guard_evaluate "$outdir" "$loop_count" "$rc" "$case_name" > "$guard_tmp"

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
echo "Sweep complete. failed=${failed} total=${total_cases}"
echo "========================================================================"

exit "$failed"

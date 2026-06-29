#!/usr/bin/env bash
set -uo pipefail

# Sweep latency pointer-chase stride lengths for testcase 32 and save all results.
# Default command:
#   CUDA_VISIBLE_DEVICES=0 numactl --membind=0 --physcpubind=1 ./nvbandwidth -t 32 --latencyStrideLen <stride>

DEFAULT_STRIDES=(1 2 4 8 16 32 64 100 128 150 200 250 256)

if [[ -n "${STRIDES:-}" ]]; then
    # Override example: STRIDES="1 16 64" bash sweep_latency_stride.sh
    # shellcheck disable=SC2206
    STRIDE_LIST=(${STRIDES})
else
    STRIDE_LIST=("${DEFAULT_STRIDES[@]}")
fi

CUDA_VISIBLE_DEVICES_VALUE="${CUDA_VISIBLE_DEVICES:-0}"
NUMA_NODE="${NUMA_NODE:-0}"
CPU_BIND="${CPU_BIND:-1}"
TESTCASE="${TESTCASE:-32}"
NVBANDWIDTH_BIN="${NVBANDWIDTH_BIN:-./nvbandwidth}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
OUTDIR="${OUTDIR:-latency_stride_sweep_t${TESTCASE}_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$OUTDIR"

RESULTS_CSV="$OUTDIR/results.csv"
SUMMARY_TXT="$OUTDIR/summary.txt"
COMBINED_LOG="$OUTDIR/combined.log"

parse_latency_ns() {
    local output_file="$1"
    awk '
        /memory latency SM CPU\(row\) <-> GPU\(column\) \(ns\)/ {
            in_latency_table = 1
            next
        }
        in_latency_table && $1 ~ /^[0-9]+$/ && NF >= 2 {
            print $2
            exit
        }
    ' "$output_file"
}

print_command() {
    printf '%q ' "$@"
    printf '\n'
}

{
    echo "outdir=$OUTDIR"
    echo "date=$(date --iso-8601=seconds)"
    echo "testcase=$TESTCASE"
    echo "strides=${STRIDE_LIST[*]}"
    echo "cuda_visible_devices=$CUDA_VISIBLE_DEVICES_VALUE"
    echo "numa_node=$NUMA_NODE"
    echo "cpu_bind=$CPU_BIND"
    echo "nvbandwidth_bin=$NVBANDWIDTH_BIN"
    echo "extra_args=$EXTRA_ARGS"
} > "$OUTDIR/run.info"

echo "stride,latency_ns,exit_code,stdout_file,stderr_file" > "$RESULTS_CSV"
: > "$COMBINED_LOG"

overall_rc=0

for stride in "${STRIDE_LIST[@]}"; do
    stdout_file="$OUTDIR/stride_${stride}.out"
    stderr_file="$OUTDIR/stride_${stride}.err"

    cmd=(
        env "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES_VALUE"
        numactl "--membind=$NUMA_NODE" "--physcpubind=$CPU_BIND"
        "$NVBANDWIDTH_BIN" -t "$TESTCASE" --latencyStrideLen "$stride"
    )

    if [[ -n "$EXTRA_ARGS" ]]; then
        # shellcheck disable=SC2206
        extra_args_array=($EXTRA_ARGS)
        cmd+=("${extra_args_array[@]}")
    fi

    {
        echo
        echo "===== stride=$stride ====="
        echo -n "command="
        print_command "${cmd[@]}"
    } | tee -a "$COMBINED_LOG"

    "${cmd[@]}" > "$stdout_file" 2> "$stderr_file"
    rc=$?

    if (( rc != 0 )); then
        overall_rc=$rc
    fi

    latency_ns="$(parse_latency_ns "$stdout_file" || true)"
    if [[ -z "$latency_ns" ]]; then
        latency_ns="NA"
    fi

    cat "$stdout_file" >> "$COMBINED_LOG"
    if [[ -s "$stderr_file" ]]; then
        {
            echo "----- stderr stride=$stride -----"
            cat "$stderr_file"
        } >> "$COMBINED_LOG"
    fi

    echo "$stride,$latency_ns,$rc,$stdout_file,$stderr_file" >> "$RESULTS_CSV"
    printf 'stride=%s latency_ns=%s exit_code=%s\n' "$stride" "$latency_ns" "$rc" | tee -a "$COMBINED_LOG"
done

{
    printf '%-10s %-15s %-10s\n' "stride" "latency_ns" "exit_code"
    tail -n +2 "$RESULTS_CSV" | awk -F, '{printf "%-10s %-15s %-10s\n", $1, $2, $3}'
} > "$SUMMARY_TXT"

echo
cat "$SUMMARY_TXT"
echo
echo "Saved full logs to: $OUTDIR"
echo "CSV: $RESULTS_CSV"
echo "Combined log: $COMBINED_LOG"

exit "$overall_rc"
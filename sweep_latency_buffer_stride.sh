#!/usr/bin/env bash
set -uo pipefail

# Sweep testcase 32 latency pointer-chase buffer sizes and stride lengths.
# Default command for each point:
#   CUDA_VISIBLE_DEVICES=0 numactl --membind=0 --physcpubind=1 \
#     ./nvbandwidth -t 32 --latencyBufferSize <MiB> --latencyStrideLen <stride>
#
# Optional overrides:
#   BUFFERS="2 4" STRIDES="16 25600" EXTRA_ARGS="-L 1" ./sweep_latency_buffer_stride.sh

DEFAULT_BUFFERS=(2 4 8 16 32 64 128 256 512 1024)
DEFAULT_STRIDES=(1 2 4 8 16 32 64 128 256 512 25600)

if [[ -n "${BUFFERS:-}" ]]; then
    # shellcheck disable=SC2206
    BUFFER_LIST=(${BUFFERS})
else
    BUFFER_LIST=("${DEFAULT_BUFFERS[@]}")
fi

if [[ -n "${STRIDES:-}" ]]; then
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
OUTDIR="${OUTDIR:-latency_buffer_stride_sweep_t${TESTCASE}_$(date +%Y%m%d_%H%M%S)}"

if [[ ! -x "$NVBANDWIDTH_BIN" ]]; then
    echo "error: $NVBANDWIDTH_BIN not found or not executable" >&2
    exit 1
fi

if ! command -v numactl >/dev/null 2>&1; then
    echo "error: numactl not found in PATH" >&2
    exit 127
fi

mkdir -p "$OUTDIR"

RESULTS_CSV="$OUTDIR/results.csv"
SUMMARY_TXT="$OUTDIR/summary.txt"
COMBINED_LOG="$OUTDIR/combined.log"

parse_latency_ns() {
    local output_file="$1"
    awk '
        /^SUM[[:space:]]+host_device_latency_sm[[:space:]]+/ {
            print $3
            exit
        }
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

csv_escape() {
    local value="$1"
    value="${value//\"/\"\"}"
    printf '"%s"' "$value"
}

print_command() {
    printf '%q ' "$@"
    printf '\n'
}

{
    echo "outdir=$OUTDIR"
    echo "date=$(date --iso-8601=seconds)"
    echo "testcase=$TESTCASE"
    echo "buffers_mib=${BUFFER_LIST[*]}"
    echo "strides=${STRIDE_LIST[*]}"
    echo "cuda_visible_devices=$CUDA_VISIBLE_DEVICES_VALUE"
    echo "numa_node=$NUMA_NODE"
    echo "cpu_bind=$CPU_BIND"
    echo "nvbandwidth_bin=$NVBANDWIDTH_BIN"
    echo "extra_args=$EXTRA_ARGS"
} > "$OUTDIR/run.info"

echo "buffer_mib,stride,latency_ns,exit_code,start_time,end_time,stdout_file,stderr_file,command" > "$RESULTS_CSV"
: > "$COMBINED_LOG"

total_runs=$(( ${#BUFFER_LIST[@]} * ${#STRIDE_LIST[@]} ))
run_idx=0
overall_rc=0

echo "Starting latency buffer/stride sweep: $total_runs runs"
echo "Output directory: $OUTDIR"

for buffer_mib in "${BUFFER_LIST[@]}"; do
    for stride in "${STRIDE_LIST[@]}"; do
        run_idx=$((run_idx + 1))
        stdout_file="$OUTDIR/buffer_${buffer_mib}MiB_stride_${stride}.out"
        stderr_file="$OUTDIR/buffer_${buffer_mib}MiB_stride_${stride}.err"

        cmd=(
            env "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES_VALUE"
            numactl "--membind=$NUMA_NODE" "--physcpubind=$CPU_BIND"
            "$NVBANDWIDTH_BIN" -t "$TESTCASE"
            --latencyBufferSize "$buffer_mib"
            --latencyStrideLen "$stride"
            --flushHostCache
        )

        if [[ -n "$EXTRA_ARGS" ]]; then
            # shellcheck disable=SC2206
            extra_args_array=($EXTRA_ARGS)
            cmd+=("${extra_args_array[@]}")
        fi

        command_text="$(print_command "${cmd[@]}")"
        start_time="$(date --iso-8601=seconds)"

        {
            echo
            echo "===== [$run_idx/$total_runs] buffer=${buffer_mib}MiB stride=$stride ====="
            echo "start_time=$start_time"
            echo "command=$command_text"
        } | tee -a "$COMBINED_LOG"

        "${cmd[@]}" > "$stdout_file" 2> "$stderr_file"
        rc=$?
        end_time="$(date --iso-8601=seconds)"

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
                echo "----- stderr buffer=${buffer_mib}MiB stride=$stride -----"
                cat "$stderr_file"
            } >> "$COMBINED_LOG"
        fi

        {
            printf '%s,%s,%s,%s,%s,%s,' "$buffer_mib" "$stride" "$latency_ns" "$rc" "$start_time" "$end_time"
            csv_escape "$stdout_file"
            printf ','
            csv_escape "$stderr_file"
            printf ','
            csv_escape "$command_text"
            printf '\n'
        } >> "$RESULTS_CSV"

        printf '[%d/%d] buffer=%sMiB stride=%s latency_ns=%s exit_code=%s\n' \
            "$run_idx" "$total_runs" "$buffer_mib" "$stride" "$latency_ns" "$rc" | tee -a "$COMBINED_LOG"
    done
done

{
    printf '%-12s %-10s %-15s %-10s\n' "buffer_mib" "stride" "latency_ns" "exit_code"
    tail -n +2 "$RESULTS_CSV" | awk -F, '{printf "%-12s %-10s %-15s %-10s\n", $1, $2, $3, $4}'
} > "$SUMMARY_TXT"

echo
cat "$SUMMARY_TXT"
echo
echo "Saved full logs to: $OUTDIR"
echo "CSV: $RESULTS_CSV"
echo "Combined log: $COMBINED_LOG"

exit "$overall_rc"
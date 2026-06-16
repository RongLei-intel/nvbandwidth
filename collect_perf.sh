#!/usr/bin/env bash
set -euo pipefail

# Collect instruction counts for nvbandwidth testcase 32.
# Defaults mirror /home/ronglei/kernel_launch/collect_perf.sh, but skip
# nvbandwidth verification so the benchmark spends less time outside the test.

PERF_SECONDS="${PERF_SECONDS:-120}"
WARMUP_SECONDS="${WARMUP_SECONDS:-20}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
NUMA_NODE="${NUMA_NODE:-0}"
CPU_BIND="${CPU_BIND:-1}"
TESTCASE="${TESTCASE:-32}"
LOOP_COUNT="${LOOP_COUNT:-300}"
PERF_EVENTS="${PERF_EVENTS:-instructions}"
OUTDIR="${OUTDIR:-perf_nvbw_t${TESTCASE}_loop${LOOP_COUNT}_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$OUTDIR"

cleanup() {
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}
trap cleanup INT TERM

env CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
    numactl --membind="$NUMA_NODE" --physcpubind="$CPU_BIND" \
    ./nvbandwidth -t"$TESTCASE" --loopCount "$LOOP_COUNT" --skipVerification \
    > "$OUTDIR/nvbandwidth.out" 2> "$OUTDIR/nvbandwidth.err" &
pid=$!

echo "$pid" > "$OUTDIR/pid.txt"
cat > "$OUTDIR/run.info" <<EOF
outdir=$OUTDIR
pid=$pid
command=./nvbandwidth -t$TESTCASE --loopCount $LOOP_COUNT
cuda_visible_devices=$CUDA_VISIBLE_DEVICES
numa_node=$NUMA_NODE
cpu_bind=$CPU_BIND
warmup_seconds=$WARMUP_SECONDS
perf_seconds=$PERF_SECONDS
perf_events=$PERF_EVENTS
EOF

echo "Started nvbandwidth pid=$pid, output directory: $OUTDIR"
echo "Warmup ${WARMUP_SECONDS}s, then collecting perf for ${PERF_SECONDS}s"

if (( WARMUP_SECONDS > 0 )); then
    sleep "$WARMUP_SECONDS"
fi

perf stat -p "$pid" \
    -e "$PERF_EVENTS" \
    -- sleep "$PERF_SECONDS" \
    > "$OUTDIR/perf.out" 2> "$OUTDIR/perf.stat"
perf_rc=$?

wait "$pid"
nvbandwidth_rc=$?

cat >> "$OUTDIR/run.info" <<EOF
perf_rc=$perf_rc
nvbandwidth_rc=$nvbandwidth_rc
EOF

echo "Done. Results written to $OUTDIR"
exit "$nvbandwidth_rc"

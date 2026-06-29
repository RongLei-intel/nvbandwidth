#!/usr/bin/env bash
set -euo pipefail

# Collect AMD uProf PCM topdown and IPC metrics for nvbandwidth testcase 32.
# The default metric set includes pipeline_util for L1/L2 topdown plus ipc for
# cycles/instructions/IPC-related counters.

PERF_SECONDS="${PERF_SECONDS:-120}"
WARMUP_SECONDS="${WARMUP_SECONDS:-20}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
NUMA_NODE="${NUMA_NODE:-0}"
CPU_BIND="${CPU_BIND:-1}"
TESTCASE="${TESTCASE:-33}"
LOOP_COUNT="${LOOP_COUNT:-300}"
PCM_METRICS="${PCM_METRICS:-pipeline_util,ipc}"
PCM_SCOPE="${PCM_SCOPE:-core=$CPU_BIND}"
PCM_AGGREGATE="${PCM_AGGREGATE:-system,core}"
SAMPLE_INTERVAL_MS="${SAMPLE_INTERVAL_MS:-1000}"
SKIP_VERIFICATION="${SKIP_VERIFICATION:-1}"
AMDPROF_PCM="${AMDPROF_PCM:-AMDuProfPcm}"
OUTDIR="${OUTDIR:-amdprof_nvbw_t${TESTCASE}_loop${LOOP_COUNT}_$(date +%Y%m%d_%H%M%S)}"

if ! command -v "$AMDPROF_PCM" >/dev/null 2>&1; then
    echo "error: $AMDPROF_PCM not found in PATH" >&2
    exit 127
fi

if [[ ! -x ./nvbandwidth ]]; then
    echo "error: ./nvbandwidth not found or not executable" >&2
    exit 1
fi

mkdir -p "$OUTDIR"

start_delay_ms=$((WARMUP_SECONDS * 1000))

start_delay_args=()
if (( start_delay_ms > 0 )); then
    start_delay_args=(--start-delay "$start_delay_ms")
fi

duration_args=()
if [[ -n "$PERF_SECONDS" ]]; then
    duration_args=(-d "$PERF_SECONDS")
fi

nvbandwidth_args=(-t"$TESTCASE" --loopCount "$LOOP_COUNT")
if [[ "$SKIP_VERIFICATION" != "0" ]]; then
    nvbandwidth_args+=(--skipVerification)
fi

pcm_scope_args=()
if [[ "$PCM_SCOPE" == "all" ]]; then
    pcm_scope_args=(-a)
elif [[ -n "$PCM_SCOPE" ]]; then
    pcm_scope_args=(-c "$PCM_SCOPE")
fi

pcm_aggregate_args=()
if [[ -n "$PCM_AGGREGATE" ]]; then
    pcm_aggregate_args=(-A "$PCM_AGGREGATE")
fi

pcm_cmd=(
    "$AMDPROF_PCM" profile
    -m "$PCM_METRICS"
    "${pcm_scope_args[@]}"
    "${pcm_aggregate_args[@]}"
    "${duration_args[@]}"
    "${start_delay_args[@]}"
    -I "$SAMPLE_INTERVAL_MS"
    -O "$OUTDIR"
    --
    env CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES"
    numactl --membind="$NUMA_NODE" --physcpubind="$CPU_BIND"
    ./nvbandwidth "${nvbandwidth_args[@]}"
)

cat > "$OUTDIR/run.info" <<RUNINFO
outdir=$OUTDIR
amdprof_pcm=$AMDPROF_PCM
amdprof_command=${pcm_cmd[*]}
nvbandwidth_command=./nvbandwidth ${nvbandwidth_args[*]}
cuda_visible_devices=$CUDA_VISIBLE_DEVICES
numa_node=$NUMA_NODE
cpu_bind=$CPU_BIND
warmup_seconds=$WARMUP_SECONDS
perf_seconds=$PERF_SECONDS
sample_interval_ms=$SAMPLE_INTERVAL_MS
skip_verification=$SKIP_VERIFICATION
pcm_metrics=$PCM_METRICS
pcm_scope=$PCM_SCOPE
pcm_aggregate=$PCM_AGGREGATE
RUNINFO

echo "Collecting AMD uProf PCM metrics, output directory: $OUTDIR"
if [[ -n "$PERF_SECONDS" ]]; then
    echo "Warmup ${WARMUP_SECONDS}s, then collecting for ${PERF_SECONDS}s"
else
    echo "Warmup ${WARMUP_SECONDS}s, then collecting until nvbandwidth exits"
fi
echo "Metrics: $PCM_METRICS"

set +e
"${pcm_cmd[@]}" > "$OUTDIR/amdprof_pcm.out" 2> "$OUTDIR/amdprof_pcm.err"
amdprof_rc=$?
set -e

cat >> "$OUTDIR/run.info" <<RUNINFO
amdprof_rc=$amdprof_rc
RUNINFO

echo "Done. Results written to $OUTDIR"
exit "$amdprof_rc"

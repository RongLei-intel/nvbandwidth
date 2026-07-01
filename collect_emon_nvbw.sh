#!/usr/bin/env bash
set -Eeuo pipefail

# Collect Intel SEP EMON EDP data while running nvbandwidth.
#
# Default mode starts EMON EDP collection in the background with `-f emon.dat`,
# runs nvbandwidth once, then sends SIGINT to EMON. This follows Intel's EDP
# quickstart guidance to stop collection with Ctrl-C and avoids app-mode
# re-running the workload for many event groups.
#
# Default workload is similar to:
#   CUDA_VISIBLE_DEVICES=0 numactl --membind=0 --physcpubind=1 ./nvbandwidth -t 33 --loopCount 300 --skipVerification
#
# Common overrides:
#   SEP_VARS=/opt/intel/sep/sep_vars.sh      Intel SEP environment script to source
#   EMON_BIN=emon                            EMON command after sourcing sep_vars.sh
#   NVBANDWIDTH_BIN=./nvbandwidth            nvbandwidth binary
#   TESTCASE=33                              nvbandwidth testcase to run
#   CUDA_VISIBLE_DEVICES=0                   GPUs visible to nvbandwidth
#   NUMA_NODE=0                              host memory NUMA binding; empty disables membind
#   CPU_BIND=1                               CPU/core binding; empty disables physcpubind
#   LOOP_COUNT=300                           nvbandwidth --loopCount; set empty to omit
#   HOST_READ_PARALLELISM=                   optional --hostReadParallelism for testcase 33
#   BUFFER_SIZE=                             optional --bufferSize in MiB
#   TEST_SAMPLES=                            optional --testSamples
#   LATENCY_STRIDE_LEN=                      optional --latencyStrideLen
#   EXTRA_NVBW_ARGS="..."                    extra nvbandwidth args, simple shell-like words
#   SKIP_VERIFICATION=1                      add --skipVerification when non-zero
#   VERBOSE_NVBW=0                           add --verbose when non-zero
#
# EMON overrides:
#   EMON_CONTROL_MODE=external               external => emon background + workload once + SIGINT; app => EMON executes wrapper
#   EMON_INTERVAL_SECONDS=0.1                EMON -t value in seconds; 0.1 = 100 ms
#   EMON_LOOPS=                              optional EMON -l value; do not use 0 with -collect-edp on this host
#   EMON_START_DELAY_SECONDS=                optional EMON -s delay before monitoring starts
#   EMON_WARMUP_SECONDS=2                    seconds to wait after starting background EMON before workload
#   EMON_EDP_FILE=                           optional EDP event file for -collect-edp edp_file=<file>
#   EMON_DRIVERLESS=0                        set 1 to add --driverless for Linux perf collection
#   EMON_EXTRA_ARGS="..."                    extra EMON args before the workload command
#   OUTDIR=                                  output directory; default timestamped
#
# Main output files:
#   emon.dat                 raw EMON EDP collection stdout, equivalent to `emon -collect-edp > emon.dat`
#   emon.err                 EMON stderr
#   run.info                 run metadata and exact commands
#   command.txt              shell-quoted EMON command
#   workload.sh              wrapper executed by EMON; avoids EMON parsing nvbandwidth options
#   nvbandwidth.out         workload stdout in external mode
#   nvbandwidth.err         workload stderr in external mode
#   nvbandwidth_from_emon.out convenience copy of nvbandwidth output lines found inside emon.dat, mostly useful in app mode

NVBW_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$NVBW_SCRIPT_DIR"

SEP_VARS="${SEP_VARS:-/opt/intel/sep/sep_vars.sh}"
EMON_BIN="${EMON_BIN:-emon}"
NVBANDWIDTH_BIN="${NVBANDWIDTH_BIN:-./nvbandwidth}"
TESTCASE="${TESTCASE:-33}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
NUMA_NODE="${NUMA_NODE:-0}"
CPU_BIND="${CPU_BIND:-1}"
LOOP_COUNT="${LOOP_COUNT:-50}"
BUFFER_SIZE="${BUFFER_SIZE:-}"
TEST_SAMPLES="${TEST_SAMPLES:-}"
HOST_READ_PARALLELISM="${HOST_READ_PARALLELISM:-}"
LATENCY_STRIDE_LEN="${LATENCY_STRIDE_LEN:-}"
EXTRA_NVBW_ARGS="${EXTRA_NVBW_ARGS:-}"
SKIP_VERIFICATION="${SKIP_VERIFICATION:-1}"
VERBOSE_NVBW="${VERBOSE_NVBW:-0}"

EMON_CONTROL_MODE="${EMON_CONTROL_MODE:-external}"
EMON_INTERVAL_SECONDS="${EMON_INTERVAL_SECONDS:-0.1}"
EMON_LOOPS="${EMON_LOOPS:-}"
EMON_START_DELAY_SECONDS="${EMON_START_DELAY_SECONDS:-}"
EMON_WARMUP_SECONDS="${EMON_WARMUP_SECONDS:-2}"
EMON_EDP_FILE="${EMON_EDP_FILE:-}"
EMON_DRIVERLESS="${EMON_DRIVERLESS:-0}"
EMON_EXTRA_ARGS="${EMON_EXTRA_ARGS:-}"
OUTDIR="${OUTDIR:-emon_nvbw_t${TESTCASE}_$(date +%Y%m%d_%H%M%S)}"

emon_pid=""
nvbw_pid=""
interrupted=0

log() {
    printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$OUTDIR/collector.log"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

quote_cmd() {
    local out=""
    local arg
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        out+="${out:+ }$arg"
    done
    printf '%s' "$out"
}

build_nvbw_command() {
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
        # Simple word splitting for convenience. For complex quoting, put args in EXTRA_NVBW_ARGS without spaces inside values.
        # shellcheck disable=SC2206
        local extra_args=( $EXTRA_NVBW_ARGS )
        nvbandwidth_args+=("${extra_args[@]}")
    fi

    nvbandwidth_cmd=(env "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES")
    if [[ -n "$NUMA_NODE" || -n "$CPU_BIND" ]]; then
        nvbandwidth_cmd+=(numactl)
        if [[ -n "$NUMA_NODE" ]]; then
            nvbandwidth_cmd+=(--membind="$NUMA_NODE")
        fi
        if [[ -n "$CPU_BIND" ]]; then
            nvbandwidth_cmd+=(--physcpubind="$CPU_BIND")
        fi
    fi
    nvbandwidth_cmd+=("$NVBANDWIDTH_BIN" "${nvbandwidth_args[@]}")
}

build_emon_command() {
    emon_cmd=("$EMON_BIN")

    if [[ -n "$EMON_LOOPS" ]]; then
        emon_cmd+=(-l "$EMON_LOOPS")
    fi
    if [[ -n "$EMON_INTERVAL_SECONDS" ]]; then
        emon_cmd+=(-t "$EMON_INTERVAL_SECONDS")
    elif [[ "$EMON_CONTROL_MODE" == "app" ]]; then
        emon_cmd+=(-t 0)
    fi
    if [[ -n "$EMON_START_DELAY_SECONDS" ]]; then
        emon_cmd+=(-s "$EMON_START_DELAY_SECONDS")
    fi

    if [[ -n "$EMON_EDP_FILE" ]]; then
        emon_cmd+=(-collect-edp "edp_file=$EMON_EDP_FILE")
    else
        emon_cmd+=(-collect-edp)
    fi

    if [[ "$EMON_CONTROL_MODE" == "external" ]]; then
        emon_cmd+=(-f "$OUTDIR/emon.dat")
    fi

    if [[ "$EMON_DRIVERLESS" != "0" ]]; then
        emon_cmd+=(--driverless)
    fi

    if [[ -n "$EMON_EXTRA_ARGS" ]]; then
        # shellcheck disable=SC2206
        local extra_args=( $EMON_EXTRA_ARGS )
        emon_cmd+=("${extra_args[@]}")
    fi

    if [[ "$EMON_CONTROL_MODE" == "app" ]]; then
        # Application command line: give EMON a no-argument wrapper so it does not
        # mistake nvbandwidth options such as `-t 33` for EMON options. Note that
        # -collect-edp app mode may run this wrapper once per EDP event group.
        emon_cmd+=("$workload_wrapper")
    elif [[ "$EMON_CONTROL_MODE" != "external" ]]; then
        echo "ERROR: unsupported EMON_CONTROL_MODE=$EMON_CONTROL_MODE; use external or app" >&2
        exit 1
    fi
}

write_workload_wrapper() {
    workload_wrapper="$OUTDIR/workload.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -Eeuo pipefail'
        printf 'cd %q\n' "$NVBW_SCRIPT_DIR"
        printf 'exec %s\n' "$(quote_cmd "${nvbandwidth_cmd[@]}")"
    } >"$workload_wrapper"
    chmod +x "$workload_wrapper"
}

stop_emon() {
    local reason="$1"

    if [[ -n "$emon_pid" ]] && kill -0 "$emon_pid" 2>/dev/null; then
        log "stopping EMON pid=$emon_pid: $reason"
        # `emon -collect-edp` on this host does not register as a controllable
        # sampling session for `emon -stop`; Intel's EDP quickstart says to stop
        # collection with Ctrl-C, so send SIGINT first.
        kill -INT "$emon_pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$emon_pid" 2>/dev/null; then
            kill -TERM "$emon_pid" 2>/dev/null || true
        fi
        sleep 1
        if kill -0 "$emon_pid" 2>/dev/null; then
            kill -KILL "$emon_pid" 2>/dev/null || true
        fi
    fi
}

stop_workload() {
    local reason="$1"

    if [[ -n "$nvbw_pid" ]] && kill -0 "$nvbw_pid" 2>/dev/null; then
        log "stopping nvbandwidth pid=$nvbw_pid: $reason"
        kill -TERM "$nvbw_pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$nvbw_pid" 2>/dev/null; then
            kill -KILL "$nvbw_pid" 2>/dev/null || true
        fi
    fi
}

on_interrupt() {
    interrupted=1
    set +e
    log "interrupt received"
    stop_workload "interrupt"
    stop_emon "interrupt"
    exit 130
}

collect_static_info() {
    {
        echo "# date"
        date --iso-8601=ns
        echo
        echo "# uname"
        uname -a
        echo
        echo "# lscpu"
        lscpu
        echo
        echo "# numactl --hardware"
        numactl --hardware 2>&1 || true
        echo
        echo "# emon -v"
        "$EMON_BIN" -v 2>&1 || true
    } >"$OUTDIR/system.txt"
}

if [[ ! -r "$SEP_VARS" ]]; then
    echo "ERROR: SEP vars script not readable: $SEP_VARS" >&2
    exit 1
fi

mkdir -p "$OUTDIR"

# sep_vars.sh may inspect optional positional parameters such as $1. Temporarily
# disable nounset so `set -u` in this wrapper does not break Intel's script.
set +e
set +u
# shellcheck disable=SC1090
source "$SEP_VARS" >"$OUTDIR/sep_vars.out" 2>"$OUTDIR/sep_vars.err"
sep_vars_rc=$?
set -u
set -e
if [[ "$sep_vars_rc" -ne 0 ]]; then
    echo "ERROR: failed to source $SEP_VARS, rc=$sep_vars_rc" >&2
    echo "See: $OUTDIR/sep_vars.out and $OUTDIR/sep_vars.err" >&2
    exit "$sep_vars_rc"
fi

if ! have_cmd "$EMON_BIN"; then
    echo "ERROR: $EMON_BIN not found after sourcing $SEP_VARS" >&2
    exit 127
fi

if [[ ! -x "$NVBANDWIDTH_BIN" ]]; then
    echo "ERROR: $NVBANDWIDTH_BIN not found or not executable in $NVBW_SCRIPT_DIR" >&2
    exit 1
fi

if [[ -n "$NUMA_NODE$CPU_BIND" ]] && ! have_cmd numactl; then
    echo "ERROR: numactl not found; set NUMA_NODE= CPU_BIND= to disable binding" >&2
    exit 127
fi

build_nvbw_command
write_workload_wrapper
build_emon_command

collect_static_info

quote_cmd "${emon_cmd[@]}" >"$OUTDIR/command.txt"
printf '\n' >>"$OUTDIR/command.txt"

cat >"$OUTDIR/run.info" <<EOF
outdir=$OUTDIR
script=$0
start_time=$(date --iso-8601=ns)
sep_vars=$SEP_VARS
emon_bin=$(command -v "$EMON_BIN" || printf '%s' "$EMON_BIN")
nvbandwidth_bin=$NVBANDWIDTH_BIN
testcase=$TESTCASE
cuda_visible_devices=$CUDA_VISIBLE_DEVICES
numa_node=$NUMA_NODE
cpu_bind=$CPU_BIND
loop_count=$LOOP_COUNT
buffer_size=$BUFFER_SIZE
test_samples=$TEST_SAMPLES
host_read_parallelism=$HOST_READ_PARALLELISM
latency_stride_len=$LATENCY_STRIDE_LEN
extra_nvbw_args=$EXTRA_NVBW_ARGS
skip_verification=$SKIP_VERIFICATION
verbose_nvbw=$VERBOSE_NVBW
emon_interval_seconds=$EMON_INTERVAL_SECONDS
emon_loops=$EMON_LOOPS
emon_start_delay_seconds=$EMON_START_DELAY_SECONDS
emon_warmup_seconds=$EMON_WARMUP_SECONDS
emon_edp_file=$EMON_EDP_FILE
emon_driverless=$EMON_DRIVERLESS
emon_extra_args=$EMON_EXTRA_ARGS
emon_control_mode=$EMON_CONTROL_MODE
nvbandwidth_command=$(quote_cmd "${nvbandwidth_cmd[@]}")
workload_wrapper=$workload_wrapper
emon_command=$(quote_cmd "${emon_cmd[@]}")
EOF

log "output directory: $OUTDIR"
log "EMON command: $(quote_cmd "${emon_cmd[@]}")"
log "control mode: $EMON_CONTROL_MODE"

run_start_epoch="$(date +%s)"
trap on_interrupt INT TERM
set +e
nvbw_rc=0
if [[ "$EMON_CONTROL_MODE" == "external" ]]; then
    log "start EMON EDP collection in background"
    "${emon_cmd[@]}" >"$OUTDIR/emon.out" 2>"$OUTDIR/emon.err" &
    emon_pid=$!
    echo "$emon_pid" >"$OUTDIR/emon.pid"

    if [[ -n "$EMON_WARMUP_SECONDS" && "$EMON_WARMUP_SECONDS" != "0" ]]; then
        sleep "$EMON_WARMUP_SECONDS"
    fi

    if ! kill -0 "$emon_pid" 2>/dev/null; then
        wait "$emon_pid"
        emon_rc=$?
        emon_pid=""
        log "ERROR: EMON exited before workload rc=$emon_rc"
    else
        log "start nvbandwidth"
        "${nvbandwidth_cmd[@]}" >"$OUTDIR/nvbandwidth.out" 2>"$OUTDIR/nvbandwidth.err" &
        nvbw_pid=$!
        echo "$nvbw_pid" >"$OUTDIR/nvbandwidth.pid"
        wait "$nvbw_pid"
        nvbw_rc=$?
        nvbw_pid=""
        log "nvbandwidth exited rc=$nvbw_rc; stopping EMON with SIGINT"
        stop_emon "workload exited"
        wait "$emon_pid"
        emon_rc=$?
        emon_pid=""
    fi
else
    log "start EMON app-mode wrapped nvbandwidth"
    "${emon_cmd[@]}" >"$OUTDIR/emon.dat" 2>"$OUTDIR/emon.err" &
    emon_pid=$!
    echo "$emon_pid" >"$OUTDIR/emon.pid"
    wait "$emon_pid"
    emon_rc=$?
    emon_pid=""
    nvbw_rc=$emon_rc
fi
set -e
trap - INT TERM
run_end_epoch="$(date +%s)"
run_seconds=$(( run_end_epoch - run_start_epoch ))

{
    echo "end_time=$(date --iso-8601=ns)"
    echo "emon_rc=$emon_rc"
    echo "nvbandwidth_rc=$nvbw_rc"
    echo "interrupted=$interrupted"
    echo "run_seconds=$run_seconds"
    if (( run_seconds < 2 )); then
        echo "warning=workload finished very quickly; increase LOOP_COUNT or set EMON_INTERVAL_SECONDS/EMON_LOOPS explicitly if more samples are needed"
    fi
} >>"$OUTDIR/run.info"

# In app mode, nvbandwidth stdout is embedded in emon.dat because EMON owns the
# application command. Keep a small convenience extraction for quick inspection.
grep -E '^(SUM|AVG)|bandwidth|latency|Running|Test|Device|ERROR|WARN' "$OUTDIR/emon.dat" >"$OUTDIR/nvbandwidth_from_emon.out" 2>/dev/null || true

{
    echo "# EMON nvbandwidth collection summary"
    echo
    echo "- Output directory: $OUTDIR"
    echo "- Raw EMON data: $OUTDIR/emon.dat"
    echo "- EMON stderr: $OUTDIR/emon.err"
    echo "- EMON command: $(quote_cmd "${emon_cmd[@]}")"
    echo "- Run seconds: $run_seconds"
    echo "- EMON exit code: $emon_rc"
    echo "- nvbandwidth exit code: $nvbw_rc"
    echo
    echo "## nvbandwidth output"
    echo
    if [[ -s "$OUTDIR/nvbandwidth.out" ]]; then
        grep -E '^(SUM|AVG)|bandwidth|latency|Running|Test|Device|ERROR|WARN' "$OUTDIR/nvbandwidth.out" | tail -n 80 || true
    elif [[ -s "$OUTDIR/nvbandwidth_from_emon.out" ]]; then
        tail -n 80 "$OUTDIR/nvbandwidth_from_emon.out"
    else
        echo "No matching nvbandwidth summary lines found; inspect nvbandwidth.out or emon.dat directly."
    fi
} >"$OUTDIR/summary.txt"

log "done; raw data: $OUTDIR/emon.dat"
log "summary: $OUTDIR/summary.txt"
if [[ "$nvbw_rc" -ne 0 ]]; then
    exit "$nvbw_rc"
fi
exit "$emon_rc"
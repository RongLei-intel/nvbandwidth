#!/usr/bin/env bash
set -Eeuo pipefail

# Collect Intel PCM + NVIDIA SMI metrics while running nvbandwidth.
#
# Default benchmark command is similar to:
#   CUDA_VISIBLE_DEVICES=0 numactl --membind=0 --physcpubind=1 ./nvbandwidth -t 33 --loopCount 300 --skipVerification
#
# Common overrides:
#   TESTCASE=33                         nvbandwidth testcase to run
#   CUDA_VISIBLE_DEVICES=0              GPUs visible to nvbandwidth
#   NUMA_NODE=0                         host memory NUMA binding; empty disables membind
#   CPU_BIND=1                          CPU/core binding; empty disables physcpubind
#   LOOP_COUNT=300                      nvbandwidth --loopCount; set empty to omit
#   HOST_READ_PARALLELISM=1             optional --hostReadParallelism for testcase 33
#   BUFFER_SIZE=                        optional --bufferSize in MiB
#   TEST_SAMPLES=                       optional --testSamples
#   LATENCY_STRIDE_LEN=                 optional --latencyStrideLen
#   EXTRA_NVBW_ARGS="..."               extra nvbandwidth args, simple shell-like words
#   SKIP_VERIFICATION=1                 add --skipVerification when non-zero
#   VERBOSE_NVBW=0                      add --verbose when non-zero
#
# Collector overrides:
#   SAMPLE_INTERVAL=1                   PCM sample interval in seconds
#   NVIDIA_QUERY_INTERVAL=1             nvidia-smi query loop interval in seconds
#   NVIDIA_DMON_INTERVAL=1              nvidia-smi dmon/pmon interval in seconds
#   PCM_TOOLS="pcm-memory pcm-pcie pcm-iio pcm-power pcm-numa pcm-core pcm"
#                                       space/comma separated PCM collectors; set empty to disable PCM
#   INCLUDE_NVIDIA_QUERY=1              collect high-value nvidia-smi --query-gpu CSV
#   INCLUDE_NVIDIA_DMON=1               collect nvidia-smi dmon
#   INCLUDE_NVIDIA_PMON=1               collect nvidia-smi pmon
#   INCLUDE_NVIDIA_APPS=1               collect nvidia-smi --query-compute-apps loop
#   OUTDIR=                             output directory; default timestamped
#   SUMMARIZE_ONLY_DIR=                 regenerate summary.txt for an existing output directory and exit
#
# Notes:
# - Multiple PCM tools can run together on this machine in basic testing, but if a
#   collector fails, inspect its *.err file and reduce PCM_TOOLS.
# - If nvbandwidth finishes before one sample interval, increase LOOP_COUNT or use
#   EXTRA_NVBW_ARGS to make the run longer.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NVBANDWIDTH_BIN="${NVBANDWIDTH_BIN:-./nvbandwidth}"
TESTCASE="${TESTCASE:-32}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
NUMA_NODE="${NUMA_NODE:-0}"
CPU_BIND="${CPU_BIND:-1}"
LOOP_COUNT="${LOOP_COUNT:-300}"
BUFFER_SIZE="${BUFFER_SIZE:-}"
TEST_SAMPLES="${TEST_SAMPLES:-}"
HOST_READ_PARALLELISM="${HOST_READ_PARALLELISM:-}"
LATENCY_STRIDE_LEN="${LATENCY_STRIDE_LEN:-}"
EXTRA_NVBW_ARGS="${EXTRA_NVBW_ARGS:-}"
SKIP_VERIFICATION="${SKIP_VERIFICATION:-1}"
VERBOSE_NVBW="${VERBOSE_NVBW:-0}"

SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
NVIDIA_QUERY_INTERVAL="${NVIDIA_QUERY_INTERVAL:-1}"
NVIDIA_DMON_INTERVAL="${NVIDIA_DMON_INTERVAL:-1}"
PCM_TOOLS="${PCM_TOOLS:-pcm-memory pcm-pcie pcm-iio pcm-power pcm-numa pcm-core pcm}"
INCLUDE_NVIDIA_QUERY="${INCLUDE_NVIDIA_QUERY:-1}"
INCLUDE_NVIDIA_DMON="${INCLUDE_NVIDIA_DMON:-1}"
INCLUDE_NVIDIA_PMON="${INCLUDE_NVIDIA_PMON:-1}"
INCLUDE_NVIDIA_APPS="${INCLUDE_NVIDIA_APPS:-1}"
SUMMARIZE_ONLY_DIR="${SUMMARIZE_ONLY_DIR:-}"

if [[ -n "$SUMMARIZE_ONLY_DIR" ]]; then
    OUTDIR="$SUMMARIZE_ONLY_DIR"
else
    OUTDIR="${OUTDIR:-pcm_nvsmi_nvbw_t${TESTCASE}_$(date +%Y%m%d_%H%M%S)}"
fi
mkdir -p "$OUTDIR"
export OUTDIR

collector_names=()
collector_pids=()
nvbw_pid=""
collectors_stopped=0

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

start_collector() {
    local name="$1"
    shift
    if ! have_cmd "$1"; then
        log "skip $name: command not found: $1"
        return 0
    fi

    log "start $name: $(quote_cmd "$@")"
    printf '%s\t%s\n' "$name" "$(quote_cmd "$@")" >> "$OUTDIR/collectors.tsv"
    "$@" >"$OUTDIR/${name}.out" 2>"$OUTDIR/${name}.err" &
    local pid=$!
    collector_names+=("$name")
    collector_pids+=("$pid")
    printf '%s\t%s\n' "$name" "$pid" >> "$OUTDIR/collector_pids.tsv"
}

stop_collectors() {
    if [[ "$collectors_stopped" == "1" ]]; then
        return 0
    fi
    collectors_stopped=1

    local i pid name
    for i in "${!collector_pids[@]}"; do
        pid="${collector_pids[$i]}"
        name="${collector_names[$i]}"
        if kill -0 "$pid" 2>/dev/null; then
            log "stop $name pid=$pid with SIGINT"
            kill -INT "$pid" 2>/dev/null || true
        fi
    done

    sleep 1

    for i in "${!collector_pids[@]}"; do
        pid="${collector_pids[$i]}"
        name="${collector_names[$i]}"
        if kill -0 "$pid" 2>/dev/null; then
            log "stop $name pid=$pid with SIGTERM"
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    sleep 1

    for i in "${!collector_pids[@]}"; do
        pid="${collector_pids[$i]}"
        name="${collector_names[$i]}"
        if kill -0 "$pid" 2>/dev/null; then
            log "stop $name pid=$pid with SIGKILL"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done

    for i in "${!collector_pids[@]}"; do
        pid="${collector_pids[$i]}"
        name="${collector_names[$i]}"
        set +e
        wait "$pid"
        local rc=$?
        set -e
        printf '%s\t%s\t%s\n' "$name" "$pid" "$rc" >> "$OUTDIR/collector_exit_codes.tsv"
    done
}

cleanup() {
    local rc=$?
    set +e
    if [[ -n "$nvbw_pid" ]] && kill -0 "$nvbw_pid" 2>/dev/null; then
        log "cleanup: stopping nvbandwidth pid=$nvbw_pid"
        kill -TERM "$nvbw_pid" 2>/dev/null || true
        wait "$nvbw_pid" 2>/dev/null || true
    fi
    stop_collectors || true
    exit "$rc"
}
trap cleanup INT TERM

nvidia_query_loop() {
    local out="$1"
    local interval="$2"
    local fields="$3"

    nvidia-smi --query-gpu="$fields" --format=csv,nounits >"$out" 2>>"$OUTDIR/nvidia-query.err" || return $?
    while true; do
        nvidia-smi --query-gpu="$fields" --format=csv,noheader,nounits >>"$out" 2>>"$OUTDIR/nvidia-query.err" || true
        sleep "$interval"
    done
}

nvidia_apps_loop() {
    local out="$1"
    local interval="$2"
    local fields='timestamp,gpu_uuid,pid,process_name,used_memory'

    printf 'collector_timestamp,%s\n' "$fields" >"$out"
    while true; do
        local now
        now="$(date '+%F %T.%N %z')"
        nvidia-smi --query-compute-apps="$fields" --format=csv,noheader,nounits 2>>"$OUTDIR/nvidia-apps.err" \
            | awk -v ts="$now" 'NF { print ts "," $0 }' >>"$out" || true
        sleep "$interval"
    done
}

select_nvidia_fields() {
    local preferred fallback
    preferred='timestamp,index,name,pci.bus_id,pstate,pcie.link.gen.current,pcie.link.gen.gpucurrent,pcie.link.gen.max,pcie.link.gen.gpumax,pcie.link.gen.hostmax,pcie.link.width.current,pcie.link.width.max,power.draw,power.draw.average,power.draw.instant,power.limit,enforced.power.limit,temperature.gpu,utilization.gpu,utilization.memory,memory.total,memory.used,memory.free,clocks.current.graphics,clocks.current.sm,clocks.current.memory,clocks.current.video,clocks.max.graphics,clocks.max.sm,clocks.max.memory,encoder.stats.sessionCount,encoder.stats.averageFps,encoder.stats.averageLatency,retired_pages.single_bit_ecc.count,retired_pages.double_bit.count,retired_pages.pending,remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure'
    fallback='timestamp,index,name,pci.bus_id,pstate,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,power.draw,power.limit,temperature.gpu,utilization.gpu,utilization.memory,memory.total,memory.used,memory.free,clocks.current.graphics,clocks.current.sm,clocks.current.memory,clocks.current.video'

    if nvidia-smi --query-gpu="$preferred" --format=csv,noheader,nounits >/dev/null 2>"$OUTDIR/nvidia-query-field-test.err"; then
        printf '%s' "$preferred"
    else
        log "preferred NVIDIA query field list failed; using fallback fields"
        printf '%s' "$fallback"
    fi
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
        echo "# perf_event_paranoid"
        cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || true
    } >"$OUTDIR/system.txt"

    if have_cmd nvidia-smi; then
        nvidia-smi >"$OUTDIR/nvidia-smi.txt" 2>"$OUTDIR/nvidia-smi.err" || true
        nvidia-smi -q >"$OUTDIR/nvidia-smi-q.txt" 2>"$OUTDIR/nvidia-smi-q.err" || true
        nvidia-smi -q -x >"$OUTDIR/nvidia-smi-q.xml" 2>"$OUTDIR/nvidia-smi-q-xml.err" || true
        nvidia-smi topo -m >"$OUTDIR/nvidia-smi-topo.txt" 2>"$OUTDIR/nvidia-smi-topo.err" || true
        nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,memory.total,power.limit --format=csv >"$OUTDIR/gpu-static.csv" 2>"$OUTDIR/gpu-static.err" || true
    fi

    if have_cmd lspci; then
        lspci -tv >"$OUTDIR/lspci-tree.txt" 2>"$OUTDIR/lspci-tree.err" || true
        lspci -nn >"$OUTDIR/lspci-nn.txt" 2>"$OUTDIR/lspci-nn.err" || true
    fi

    if have_cmd pcm-sensor; then
        timeout 5 pcm-sensor >"$OUTDIR/pcm-sensor-snapshot.txt" 2>"$OUTDIR/pcm-sensor-snapshot.err" || true
    fi
}

start_pcm_collectors() {
    local normalized tool
    normalized="${PCM_TOOLS//,/ }"
    for tool in $normalized; do
        case "$tool" in
            pcm-memory)
                start_collector pcm-memory pcm-memory "$SAMPLE_INTERVAL" -silent "-csv=$OUTDIR/pcm-memory.csv"
                ;;
            pcm-pcie)
                start_collector pcm-pcie pcm-pcie "$SAMPLE_INTERVAL" -silent -B "-csv=$OUTDIR/pcm-pcie.csv"
                ;;
            pcm-iio)
                start_collector pcm-iio pcm-iio "$SAMPLE_INTERVAL" -silent "-csv=$OUTDIR/pcm-iio.csv" -human-readable -root-port
                ;;
            pcm-power)
                start_collector pcm-power pcm-power "$SAMPLE_INTERVAL" -silent "-csv=$OUTDIR/pcm-power.csv"
                ;;
            pcm-numa)
                start_collector pcm-numa pcm-numa "$SAMPLE_INTERVAL" -silent "-csv=$OUTDIR/pcm-numa.csv"
                ;;
            pcm-core)
                start_collector pcm-core pcm-core "$SAMPLE_INTERVAL" -silent "-csv=$OUTDIR/pcm-core.csv"
                ;;
            pcm)
                start_collector pcm pcm "$SAMPLE_INTERVAL" -silent "-csv=$OUTDIR/pcm.csv"
                ;;
            "")
                ;;
            *)
                log "unknown PCM tool '$tool' in PCM_TOOLS; skipping"
                ;;
        esac
    done
}

start_nvidia_collectors() {
    if ! have_cmd nvidia-smi; then
        log "skip NVIDIA collectors: nvidia-smi not found"
        return 0
    fi

    if [[ "$INCLUDE_NVIDIA_QUERY" != "0" ]]; then
        local fields
        fields="$(select_nvidia_fields)"
        printf '%s\n' "$fields" >"$OUTDIR/nvidia-query.fields"
        start_collector nvidia-query bash -c "$(declare -f nvidia_query_loop); nvidia_query_loop \"\$1\" \"\$2\" \"\$3\"" _ "$OUTDIR/nvidia-query-gpu.csv" "$NVIDIA_QUERY_INTERVAL" "$fields"
    fi

    if [[ "$INCLUDE_NVIDIA_DMON" != "0" ]]; then
        start_collector nvidia-dmon nvidia-smi dmon -s pucvmet -d "$NVIDIA_DMON_INTERVAL" -o TD
    fi

    if [[ "$INCLUDE_NVIDIA_PMON" != "0" ]]; then
        start_collector nvidia-pmon nvidia-smi pmon -s um -d "$NVIDIA_DMON_INTERVAL" -o TD
    fi

    if [[ "$INCLUDE_NVIDIA_APPS" != "0" ]]; then
        start_collector nvidia-apps bash -c "$(declare -f nvidia_apps_loop); nvidia_apps_loop \"\$1\" \"\$2\"" _ "$OUTDIR/nvidia-compute-apps.csv" "$NVIDIA_QUERY_INTERVAL"
    fi
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

summarize_outputs() {
    if have_cmd python3; then
        python3 - "$OUTDIR" "$SAMPLE_INTERVAL" "$(quote_cmd "${nvbandwidth_cmd[@]}")" >"$OUTDIR/summary.txt" <<'PY' || {
import csv
import os
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

outdir = Path(sys.argv[1])
sample_interval = sys.argv[2]
nvbw_command = sys.argv[3]


def read_text(name):
    path = outdir / name
    if not path.exists():
        return ""
    return path.read_text(errors="replace")


def parse_float(value):
    if value is None:
        return None
    text = str(value).strip().replace(",", "")
    if not text or text in {"-", "N/A", "[N/A]"}:
        return None
    mult = 1.0
    if text[-1:] in {"K", "M", "G", "T"}:
        mult = {"K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12}[text[-1]]
        text = text[:-1].strip()
    try:
        return float(text) * mult
    except ValueError:
        return None


def stats(values):
    vals = [float(v) for v in values if v is not None]
    if not vals:
        return None
    return {
        "count": len(vals),
        "avg": statistics.fmean(vals),
        "max": max(vals),
        "min": min(vals),
        "last": vals[-1],
    }


def fmt(value, digits=3):
    if value is None:
        return "NA"
    return f"{value:.{digits}f}"


def stat_line(label, stat, unit="", scale=1.0, digits=3):
    if not stat:
        return f"| {label} | NA | NA | NA | NA | 0 |"
    suffix = f" {unit}" if unit else ""
    return (
        f"| {label} | {fmt(stat['avg'] / scale, digits)}{suffix} | "
        f"{fmt(stat['max'] / scale, digits)}{suffix} | "
        f"{fmt(stat['last'] / scale, digits)}{suffix} | "
        f"{fmt(stat['min'] / scale, digits)}{suffix} | {stat['count']} |"
    )


def get_run_info():
    info = {}
    for line in read_text("run.info").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            info[key.strip()] = value.strip()
    return info


def summarize_nvbandwidth():
    text = read_text("nvbandwidth.out")
    sums = []
    for line in text.splitlines():
        m = re.match(r"^SUM\s+(\S+)\s+([-+0-9.eE]+)", line.strip())
        if m:
            sums.append((m.group(1), parse_float(m.group(2))))
    desc = []
    for line in text.splitlines():
        if "bandwidth" in line.lower() or "latency" in line.lower():
            desc.append(line.strip())
    return sums, desc[-3:]


def load_pcm_memory():
    path = outdir / "pcm-memory.csv"
    if not path.exists() or path.stat().st_size == 0:
        return None
    rows = list(csv.reader(path.open(newline="")))
    if len(rows) < 3:
        return None
    groups = [c.strip() for c in rows[0]]
    names = [c.strip() for c in rows[1]]
    metrics = defaultdict(list)
    active_rows = 0
    total_memory_values = []
    for row in rows[2:]:
        if len(row) < 3 or not row[0].strip():
            continue
        row_vals = {}
        for i, raw in enumerate(row):
            if i >= len(names):
                continue
            group = groups[i] if i < len(groups) else ""
            name = names[i]
            if not name or name in {"Date", "Time"}:
                continue
            value = parse_float(raw)
            if value is None:
                continue
            key = f"{group}.{name}" if group else name
            metrics[key].append(value)
            row_vals[key] = value
        sys_mem = row_vals.get("System.Memory")
        if sys_mem is not None:
            total_memory_values.append(sys_mem)
            if sys_mem > 0:
                active_rows += 1
    return metrics, len(total_memory_values), active_rows


def load_pcm_pcie():
    path = outdir / "pcm-pcie.csv"
    if not path.exists() or path.stat().st_size == 0:
        return None
    samples = []
    current = []
    header = None
    for row in csv.reader(path.open(newline="")):
        if not row:
            continue
        first = row[0].strip()
        if first == "Skt":
            if current:
                samples.append(current)
                current = []
            header = [c.strip() for c in row]
            continue
        if header and first not in {"*", ""}:
            current.append(dict(zip(header, row)))
    if current:
        samples.append(current)
    totals = defaultdict(list)
    per_socket = defaultdict(lambda: defaultdict(list))
    for sample in samples:
        sample_totals = defaultdict(float)
        for row in sample:
            skt = str(row.get("Skt", "")).strip()
            for key in ["PCIe Rd (B)", "PCIe Wr (B)", "PCIRdCur", "ItoM", "ItoMCacheNear", "UCRdF", "WiL", "WCiL", "WCiLF"]:
                val = parse_float(row.get(key))
                if val is None:
                    continue
                sample_totals[key] += val
                per_socket[skt][key].append(val)
        for key, val in sample_totals.items():
            totals[key].append(val)
        if "PCIe Rd (B)" in sample_totals or "PCIe Wr (B)" in sample_totals:
            totals["PCIe Total (B)"].append(sample_totals.get("PCIe Rd (B)", 0.0) + sample_totals.get("PCIe Wr (B)", 0.0))
    return totals, per_socket, len(samples)


def load_nvidia_dmon():
    path = outdir / "nvidia-dmon.out"
    if not path.exists() or path.stat().st_size == 0:
        return None
    cols = ["date", "time", "gpu", "pwr", "gtemp", "mtemp", "sm", "mem", "enc", "dec", "jpg", "ofa", "mclk", "pclk", "pviol", "tviol", "fb", "bar1", "ccpm", "sbecc", "dbecc", "pci", "rxpci", "txpci"]
    per_gpu = defaultdict(lambda: defaultdict(list))
    per_ts = defaultdict(lambda: {"rxpci": 0.0, "txpci": 0.0, "pwr": 0.0, "sm": []})
    rows = 0
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < len(cols):
            continue
        rec = dict(zip(cols, parts[:len(cols)]))
        gpu = rec["gpu"]
        ts = f"{rec['date']} {rec['time']}"
        rows += 1
        for key in ["pwr", "gtemp", "sm", "mem", "mclk", "pclk", "fb", "bar1", "rxpci", "txpci"]:
            val = parse_float(rec.get(key))
            if val is None:
                continue
            per_gpu[gpu][key].append(val)
            if key in {"rxpci", "txpci", "pwr"}:
                per_ts[ts][key] += val
            if key == "sm":
                per_ts[ts]["sm"].append(val)
    agg = defaultdict(list)
    for rec in per_ts.values():
        agg["rxpci"].append(rec["rxpci"])
        agg["txpci"].append(rec["txpci"])
        agg["pcie_total"].append(rec["rxpci"] + rec["txpci"])
        agg["pwr"].append(rec["pwr"])
        if rec["sm"]:
            agg["sm_avg_across_gpus"].append(statistics.fmean(rec["sm"]))
    return per_gpu, agg, rows


def load_nvidia_query():
    path = outdir / "nvidia-query-gpu.csv"
    if not path.exists() or path.stat().st_size == 0:
        return None
    per_gpu = defaultdict(lambda: defaultdict(list))
    last = {}
    rows = 0
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows += 1
            row = {k.strip(): (v.strip() if isinstance(v, str) else v) for k, v in row.items() if k is not None}
            gpu = row.get("index") or row.get(" index") or row.get("gpu")
            if gpu is None:
                continue
            last[gpu] = row
            for key, value in row.items():
                clean_key = re.sub(r"\s*\[.*\]$", "", key.strip())
                val = parse_float(value)
                if val is not None:
                    per_gpu[gpu][clean_key].append(val)
    return per_gpu, last, rows


def parse_iio_value(value):
    return parse_float(value)


def load_pcm_iio_top(limit=8):
    path = outdir / "pcm-iio.csv"
    if not path.exists() or path.stat().st_size == 0:
        return []
    totals = defaultdict(lambda: defaultdict(float))
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            socket = (row.get("Socket") or "").strip()
            root = (row.get("Root Port") or "").strip()
            name = (row.get("Name") or "").strip()
            if not name:
                continue
            label = f"{socket} {root} {name}".strip()
            for key in ["IB write", "IB read", "OB read", "OB write"]:
                val = parse_iio_value(row.get(key))
                if val is not None:
                    totals[label][key] += val
    ranked = []
    for label, vals in totals.items():
        total = vals.get("IB write", 0) + vals.get("IB read", 0) + vals.get("OB read", 0) + vals.get("OB write", 0)
        if total > 0:
            ranked.append((total, label, vals))
    ranked.sort(reverse=True, key=lambda x: x[0])
    return ranked[:limit]


run_info = get_run_info()
display_command = nvbw_command or run_info.get("nvbandwidth_command", "")
nvbw_sums, nvbw_desc = summarize_nvbandwidth()
mem = load_pcm_memory()
pcie = load_pcm_pcie()
dmon = load_nvidia_dmon()
nquery = load_nvidia_query()
iio_top = load_pcm_iio_top()

print("# nvbandwidth PCM/NVIDIA Summary")
print()
print("## Run")
print()
print(f"- Output directory: `{outdir}`")
print(f"- Command: `{display_command}`")
for key in ["start_time", "end_time", "run_seconds", "nvbandwidth_rc", "testcase", "cuda_visible_devices", "numa_node", "cpu_bind", "loop_count", "host_read_parallelism", "sample_interval"]:
    if key in run_info:
        print(f"- {key}: `{run_info[key]}`")
print()

print("## nvbandwidth")
print()
if nvbw_desc:
    for line in nvbw_desc:
        print(f"- {line}")
if nvbw_sums:
    print()
    print("| testcase | SUM | unit |")
    print("|---|---:|---|")
    for name, value in nvbw_sums:
        print(f"| {name} | {fmt(value, 3)} | GB/s or testcase native unit |")
else:
    print("- No SUM line found in nvbandwidth.out")
print()

print("## PCM memory bandwidth")
print()
if mem:
    metrics, row_count, active_rows = mem
    print(f"- Samples: `{row_count}` total, `{active_rows}` active non-zero system-memory samples")
    print("- Values from `pcm-memory.csv`; MB/s converted to GB/s with decimal 1000.")
    print()
    print("| metric | avg | max | last | min | samples |")
    print("|---|---:|---:|---:|---:|---:|")
    for key in ["System.Read", "System.Write", "System.Memory", "SKT0.Mem Read (MB/s)", "SKT0.Mem Write (MB/s)", "SKT0.Memory (MB/s)", "SKT1.Mem Read (MB/s)", "SKT1.Mem Write (MB/s)", "SKT1.Memory (MB/s)"]:
        if key in metrics:
            print(stat_line(key, stats(metrics[key]), "GB/s", scale=1000.0, digits=3))
    channel_stats = []
    for key, vals in metrics.items():
        if re.search(r"SKT\d+\.Ch\d+(Read|Write)$", key):
            st = stats(vals)
            if st:
                channel_stats.append((st["max"], key, st))
    if channel_stats:
        print()
        print("Top memory channels by max bandwidth:")
        print()
        print("| channel | avg | max | last | min | samples |")
        print("|---|---:|---:|---:|---:|---:|")
        for _, key, st in sorted(channel_stats, reverse=True)[:12]:
            print(stat_line(key, st, "GB/s", scale=1000.0, digits=3))
else:
    print("- `pcm-memory.csv` not found or empty")
print()

print("## PCM PCIe bandwidth")
print()
if pcie:
    totals, per_socket, sample_count = pcie
    print(f"- Samples: `{sample_count}`")
    print("- Values from `pcm-pcie -B`; reported as estimated B/s by PCM and converted to GB/s.")
    print()
    print("| metric | avg | max | last | min | samples |")
    print("|---|---:|---:|---:|---:|---:|")
    for key in ["PCIe Rd (B)", "PCIe Wr (B)", "PCIe Total (B)"]:
        if key in totals:
            print(stat_line(f"System {key}", stats(totals[key]), "GB/s", scale=1e9, digits=3))
    for skt in sorted(per_socket, key=lambda x: int(x) if str(x).isdigit() else str(x)):
        for key in ["PCIe Rd (B)", "PCIe Wr (B)"]:
            if key in per_socket[skt]:
                print(stat_line(f"Socket{skt} {key}", stats(per_socket[skt][key]), "GB/s", scale=1e9, digits=3))
else:
    print("- `pcm-pcie.csv` not found or empty")
print()

print("## NVIDIA dmon GPU telemetry")
print()
if dmon:
    per_gpu, agg, rows = dmon
    print(f"- Rows: `{rows}`")
    print("- `rxpci`/`txpci` are from `nvidia-smi dmon`, unit MB/s; converted to GB/s below.")
    print()
    print("| metric | avg | max | last | min | samples |")
    print("|---|---:|---:|---:|---:|---:|")
    print(stat_line("All GPUs rxpci", stats(agg.get("rxpci", [])), "GB/s", scale=1000.0, digits=3))
    print(stat_line("All GPUs txpci", stats(agg.get("txpci", [])), "GB/s", scale=1000.0, digits=3))
    print(stat_line("All GPUs rxpci+txpci", stats(agg.get("pcie_total", [])), "GB/s", scale=1000.0, digits=3))
    print(stat_line("All GPUs board power", stats(agg.get("pwr", [])), "W", scale=1.0, digits=1))
    print(stat_line("Average SM utilization across GPUs", stats(agg.get("sm_avg_across_gpus", [])), "%", scale=1.0, digits=1))
    print()
    print("Per-GPU peak PCIe and utilization:")
    print()
    print("| GPU | max rxpci | max txpci | max rx+tx | max SM | max power | max temp | max mem clock | max graphics clock |")
    print("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for gpu in sorted(per_gpu, key=lambda x: int(x) if str(x).isdigit() else str(x)):
        data = per_gpu[gpu]
        rx = stats(data.get("rxpci", []))
        tx = stats(data.get("txpci", []))
        total = [a + b for a, b in zip(data.get("rxpci", []), data.get("txpci", []))]
        sm = stats(data.get("sm", []))
        pwr = stats(data.get("pwr", []))
        temp = stats(data.get("gtemp", []))
        mclk = stats(data.get("mclk", []))
        pclk = stats(data.get("pclk", []))
        print(f"| {gpu} | {fmt((rx or {}).get('max', 0)/1000.0, 3)} GB/s | {fmt((tx or {}).get('max', 0)/1000.0, 3)} GB/s | {fmt((stats(total) or {}).get('max', 0)/1000.0, 3)} GB/s | {fmt((sm or {}).get('max'), 1)}% | {fmt((pwr or {}).get('max'), 1)} W | {fmt((temp or {}).get('max'), 1)} C | {fmt((mclk or {}).get('max'), 0)} MHz | {fmt((pclk or {}).get('max'), 0)} MHz |")
else:
    print("- `nvidia-dmon.out` not found or empty")
print()

print("## NVIDIA query GPU state")
print()
if nquery:
    per_gpu_q, last_rows, rows = nquery
    print(f"- Rows: `{rows}`")
    print("- Includes PCIe link state, pstate, power, utilization, clocks, and memory from `nvidia-smi --query-gpu`.")
    print()
    print("| GPU | bus | max pcie gen | last pcie gen | width | max util.gpu | max power | max mem used | max sm clock | last pstate |")
    print("|---:|---|---:|---:|---:|---:|---:|---:|---:|---|")
    for gpu in sorted(last_rows, key=lambda x: int(x) if str(x).isdigit() else str(x)):
        row = last_rows[gpu]
        data = per_gpu_q[gpu]
        bus = row.get("pci.bus_id", "NA")
        last_gen = row.get("pcie.link.gen.current", row.get("pcie.link.gen.gpucurrent", "NA"))
        width = row.get("pcie.link.width.current", "NA")
        pstate = row.get("pstate", "NA")
        max_gen = stats(data.get("pcie.link.gen.current", []) or data.get("pcie.link.gen.gpucurrent", []))
        util = stats(data.get("utilization.gpu", []))
        pwr = stats(data.get("power.draw", []))
        mem = stats(data.get("memory.used", []))
        smclk = stats(data.get("clocks.current.sm", []))
        print(f"| {gpu} | {bus} | {fmt((max_gen or {}).get('max'), 0)} | {last_gen} | x{width} | {fmt((util or {}).get('max'), 1)}% | {fmt((pwr or {}).get('max'), 1)} W | {fmt((mem or {}).get('max'), 0)} MiB | {fmt((smclk or {}).get('max'), 0)} MHz | {pstate} |")
else:
    print("- `nvidia-query-gpu.csv` not found or empty")
print()

print("## PCM IIO top activity")
print()
if iio_top:
    print("- Top root-port/IIO rows by accumulated IB/OB activity. Units are PCM human-readable transfer counts, normalized to base counts.")
    print()
    print("| rank | socket/root/name | IB write | IB read | OB read | OB write | total |")
    print("|---:|---|---:|---:|---:|---:|---:|")
    for idx, (total, label, vals) in enumerate(iio_top, 1):
        print(f"| {idx} | {label} | {fmt(vals.get('IB write', 0), 0)} | {fmt(vals.get('IB read', 0), 0)} | {fmt(vals.get('OB read', 0), 0)} | {fmt(vals.get('OB write', 0), 0)} | {fmt(total, 0)} |")
else:
    print("- `pcm-iio.csv` not found/empty or no non-zero IIO rows")
print()

print("## Collector status")
print()
exit_text = read_text("collector_exit_codes.tsv")
if exit_text.strip():
    print("| collector | pid | exit code | note |")
    print("|---|---:|---:|---|")
    for line in exit_text.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            name, pid, code = parts[:3]
            note = "OK" if code == "0" else "stopped by script" if code in {"130", "143", "137"} else "check .err"
            print(f"| {name} | {pid} | {code} | {note} |")
else:
    print("- No collector_exit_codes.tsv found")
print()

print("## Files to inspect if needed")
print()
important = [
    "nvbandwidth.out", "pcm-memory.csv", "pcm-pcie.csv", "pcm-iio.csv", "pcm-power.csv", "pcm-numa.csv", "pcm-core.csv", "pcm.csv",
    "nvidia-query-gpu.csv", "nvidia-dmon.out", "nvidia-pmon.out", "nvidia-compute-apps.csv", "run.info",
]
print("| file | size |")
print("|---|---:|")
for name in important:
    path = outdir / name
    if path.exists():
        print(f"| {name} | {path.stat().st_size} bytes |")
PY
            echo "summary generation failed; falling back to basic summary" >"$OUTDIR/summary.txt"
        }
    else
        {
            echo "# Output directory"
            echo "$OUTDIR"
            echo
            echo "# nvbandwidth command"
            quote_cmd "${nvbandwidth_cmd[@]}"
            echo
            echo
            echo "# nvbandwidth result summary"
            grep -E '^(SUM|AVG)|bandwidth|latency|ERROR|WARN' "$OUTDIR/nvbandwidth.out" 2>/dev/null | tail -n 80 || true
            echo
            echo "# PCM CSV files"
            find "$OUTDIR" -maxdepth 1 -type f -name 'pcm*.csv' -printf '%f\t%s bytes\n' | sort || true
            echo
            echo "# NVIDIA files"
            find "$OUTDIR" -maxdepth 1 -type f \( -name 'nvidia*.csv' -o -name 'nvidia*.out' -o -name 'gpu-static.csv' \) -printf '%f\t%s bytes\n' | sort || true
            echo
            echo "# Collector exit codes"
            cat "$OUTDIR/collector_exit_codes.tsv" 2>/dev/null || true
        } >"$OUTDIR/summary.txt"
    fi
}

if [[ ! -x "$NVBANDWIDTH_BIN" ]]; then
    if [[ -n "$SUMMARIZE_ONLY_DIR" ]]; then
        summarize_outputs
        echo "Regenerated summary: $OUTDIR/summary.txt"
        exit 0
    fi
    echo "ERROR: $NVBANDWIDTH_BIN not found or not executable in $SCRIPT_DIR" >&2
    exit 1
fi

if [[ -n "$SUMMARIZE_ONLY_DIR" ]]; then
    summarize_outputs
    echo "Regenerated summary: $OUTDIR/summary.txt"
    exit 0
fi

: >"$OUTDIR/collectors.tsv"
: >"$OUTDIR/collector_pids.tsv"

collect_static_info
build_nvbw_command

cat >"$OUTDIR/run.info" <<EOF
outdir=$OUTDIR
script=$0
start_time=$(date --iso-8601=ns)
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
sample_interval=$SAMPLE_INTERVAL
nvidia_query_interval=$NVIDIA_QUERY_INTERVAL
nvidia_dmon_interval=$NVIDIA_DMON_INTERVAL
pcm_tools=$PCM_TOOLS
include_nvidia_query=$INCLUDE_NVIDIA_QUERY
include_nvidia_dmon=$INCLUDE_NVIDIA_DMON
include_nvidia_pmon=$INCLUDE_NVIDIA_PMON
include_nvidia_apps=$INCLUDE_NVIDIA_APPS
nvbandwidth_command=$(quote_cmd "${nvbandwidth_cmd[@]}")
EOF

log "output directory: $OUTDIR"
log "nvbandwidth command: $(quote_cmd "${nvbandwidth_cmd[@]}")"

start_pcm_collectors
start_nvidia_collectors

log "start nvbandwidth"
run_start_epoch="$(date +%s)"
"${nvbandwidth_cmd[@]}" >"$OUTDIR/nvbandwidth.out" 2>"$OUTDIR/nvbandwidth.err" &
nvbw_pid=$!
printf '%s\n' "$nvbw_pid" >"$OUTDIR/nvbandwidth.pid"

set +e
wait "$nvbw_pid"
nvbw_rc=$?
set -e
nvbw_pid=""
run_end_epoch="$(date +%s)"
run_seconds=$(( run_end_epoch - run_start_epoch ))

log "nvbandwidth exited rc=$nvbw_rc after ${run_seconds}s"
stop_collectors

{
    echo "end_time=$(date --iso-8601=ns)"
    echo "nvbandwidth_rc=$nvbw_rc"
    echo "run_seconds=$run_seconds"
    if (( run_seconds < 2 )); then
        echo "warning=nvbandwidth finished very quickly; increase LOOP_COUNT or SAMPLE_INTERVAL may produce too few samples"
    fi
} >>"$OUTDIR/run.info"

# Capture post-run GPU state as a final snapshot.
if have_cmd nvidia-smi; then
    nvidia-smi >"$OUTDIR/nvidia-smi-after.txt" 2>"$OUTDIR/nvidia-smi-after.err" || true
    nvidia-smi --query-gpu=index,name,pci.bus_id,pstate,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,power.draw,temperature.gpu,utilization.gpu,utilization.memory,memory.used --format=csv >"$OUTDIR/gpu-after.csv" 2>"$OUTDIR/gpu-after.err" || true
fi

summarize_outputs
log "done; summary: $OUTDIR/summary.txt"
exit "$nvbw_rc"

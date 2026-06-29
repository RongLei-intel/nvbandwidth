#!/usr/bin/env bash
set -euo pipefail

# Collect and parse host-memory read bandwidth for nvbandwidth testcase 33.
# Default command:
#   CUDA_VISIBLE_DEVICES=0 numactl --membind=0 --physcpubind=1 ./nvbandwidth -t 33
#
# Tunables:
#   NUMA_NODE=0              NUMA node whose UMC counters are reported as target socket
#   INTERVAL_MS=100          perf stat interval in ms
#   BYTES_PER_CAS=128        bandwidth conversion factor for amd_umc/umc_cas_cmd.rd/
#   CUDA_VISIBLE_DEVICES=0   GPU selection
#   PHYS_CPU=1               CPU binding
#   OUTDIR=<dir>             output directory
#   EXTRA_NVBW_ARGS="..."    extra nvbandwidth arguments, e.g. "-L 1000 -i 5"

NUMA_NODE="${NUMA_NODE:-0}"
INTERVAL_MS="${INTERVAL_MS:-100}"
BYTES_PER_CAS="${BYTES_PER_CAS:-128}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
PHYS_CPU="${PHYS_CPU:-1}"
OUTDIR="${OUTDIR:-perf_nvbw_t33_memread_$(date +%Y%m%d_%H%M%S)}"
EXTRA_NVBW_ARGS="${EXTRA_NVBW_ARGS:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -x ./nvbandwidth ]]; then
  echo "ERROR: ./nvbandwidth not found or not executable in $SCRIPT_DIR" >&2
  exit 1
fi

if ! command -v perf >/dev/null 2>&1; then
  echo "ERROR: perf not found" >&2
  exit 1
fi

if ! command -v numactl >/dev/null 2>&1; then
  echo "ERROR: numactl not found" >&2
  exit 1
fi

if [[ ! -d /sys/bus/event_source/devices/amd_umc_0 ]]; then
  echo "ERROR: AMD UMC perf PMU devices were not found under /sys/bus/event_source/devices" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

# Build UMC instance lists. On this platform cpumask is 0 for socket0 UMCs and 64 for socket1 UMCs.
# We still derive the target list from NUMA node cpulist so the script is less hard-coded.
mapfile -t UMC_INFO < <(python3 - "$NUMA_NODE" <<'PY'
from pathlib import Path
import re, sys

numa_node = int(sys.argv[1])
node_cpulist_path = Path(f"/sys/devices/system/node/node{numa_node}/cpulist")
if not node_cpulist_path.exists():
    raise SystemExit(f"ERROR: {node_cpulist_path} not found")

def expand_cpulist(text):
    cpus = set()
    for part in text.strip().split(','):
        if not part:
            continue
        if '-' in part:
            a, b = map(int, part.split('-', 1))
            cpus.update(range(a, b + 1))
        else:
            cpus.add(int(part))
    return cpus

node_cpus = expand_cpulist(node_cpulist_path.read_text())
entries = []
for d in sorted(Path('/sys/bus/event_source/devices').glob('amd_umc_*'), key=lambda p: int(p.name.rsplit('_', 1)[1])):
    idx = int(d.name.rsplit('_', 1)[1])
    cpumask = (d / 'cpumask').read_text().strip()
    m = re.search(r'\d+', cpumask)
    if not m:
        continue
    cpu = int(m.group(0))
    target = 1 if cpu in node_cpus else 0
    print(f"{idx},{cpu},{target}")
PY
)

TARGET_UMCS=()
ALL_UMCS=()
{
  echo "# idx,cpu,is_target_numa_node_${NUMA_NODE}"
  for row in "${UMC_INFO[@]}"; do
    IFS=, read -r idx cpu target <<< "$row"
    ALL_UMCS+=("$idx")
    [[ "$target" == "1" ]] && TARGET_UMCS+=("$idx")
    echo "$row"
  done
} > "$OUTDIR/umc_map.csv"

if [[ "${#TARGET_UMCS[@]}" -eq 0 ]]; then
  echo "ERROR: no amd_umc_* instances mapped to NUMA node $NUMA_NODE" >&2
  exit 1
fi

# Raw encoding verified from perf list --details:
#   amd_umc/umc_cas_cmd.rd/ => amd_umc/event=0xa,rdwrmask=0x1/
EVENT_ARGS=()
for idx in "${ALL_UMCS[@]}"; do
  EVENT_ARGS+=( -e "amd_umc_${idx}/event=0xa,rdwrmask=0x1/" )
done

CMD=(env "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}" numactl "--membind=${NUMA_NODE}" "--physcpubind=${PHYS_CPU}" ./nvbandwidth -t 33)
if [[ -n "$EXTRA_NVBW_ARGS" ]]; then
  # shellcheck disable=SC2206
  EXTRA_ARGS=( $EXTRA_NVBW_ARGS )
  CMD+=("${EXTRA_ARGS[@]}")
fi

{
  printf 'perf stat -a -x, -I %q' "$INTERVAL_MS"
  printf ' %q' "${EVENT_ARGS[@]}"
  printf ' --'
  printf ' %q' "${CMD[@]}"
  echo
} > "$OUTDIR/command.txt"

cat > "$OUTDIR/run.info" <<EOF
NUMA_NODE=$NUMA_NODE
PHYS_CPU=$PHYS_CPU
CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES
INTERVAL_MS=$INTERVAL_MS
BYTES_PER_CAS=$BYTES_PER_CAS
TARGET_UMCS=${TARGET_UMCS[*]}
ALL_UMCS=${ALL_UMCS[*]}
OUTDIR=$OUTDIR
EOF

echo "Running perf collection..."
echo "  output dir : $OUTDIR"
echo "  target UMCs: ${TARGET_UMCS[*]}"
echo "  all UMCs   : ${ALL_UMCS[*]}"
echo

perf stat -a -x, -I "$INTERVAL_MS" "${EVENT_ARGS[@]}" -- "${CMD[@]}" \
  > "$OUTDIR/nvbandwidth.out" \
  2> "$OUTDIR/perf_interval.csv"

echo "Parsing results..."
python3 - "$OUTDIR" "$NUMA_NODE" "$BYTES_PER_CAS" <<'PY' | tee "$OUTDIR/summary.txt"
from pathlib import Path
import re, sys

outdir = Path(sys.argv[1])
numa_node = int(sys.argv[2])
bytes_per_cas = int(sys.argv[3])

umc_map = {}
for line in (outdir / 'umc_map.csv').read_text().splitlines():
    if not line or line.startswith('#'):
        continue
    idx, cpu, target = line.split(',')
    umc_map[int(idx)] = bool(int(target))

target_indices = sorted(i for i, is_target in umc_map.items() if is_target)
all_indices = sorted(umc_map)

# perf stat -x, with raw event descriptors contains commas inside the event name, so parse by regex.
pat = re.compile(r'^(?P<ts>\d+(?:\.\d+)?),(?P<count>\d+),,amd_umc_(?P<idx>\d+)/.*?/')
intervals = {}
for line in (outdir / 'perf_interval.csv').read_text(errors='replace').splitlines():
    m = pat.match(line)
    if not m:
        continue
    ts = round(float(m.group('ts')), 9)
    count = int(m.group('count'))
    idx = int(m.group('idx'))
    bucket = intervals.setdefault(ts, {'target': 0, 'other': 0, 'per_umc': {}})
    bucket['per_umc'][idx] = bucket['per_umc'].get(idx, 0) + count
    if umc_map.get(idx, False):
        bucket['target'] += count
    else:
        bucket['other'] += count

rows = []
last_ts = 0.0
for ts in sorted(intervals):
    dt = ts - last_ts if last_ts else ts
    last_ts = ts
    if dt <= 0:
        continue
    target_cas = intervals[ts]['target']
    other_cas = intervals[ts]['other']
    total_cas = target_cas + other_cas
    target_gbps = target_cas * bytes_per_cas / 1e9 / dt
    total_gbps = total_cas * bytes_per_cas / 1e9 / dt
    rows.append((ts, dt, target_cas, other_cas, total_cas, target_gbps, total_gbps))

nvbw_text = (outdir / 'nvbandwidth.out').read_text(errors='replace')
reported = None
for line in nvbw_text.splitlines():
    m = re.match(r'^SUM\s+host_device_bandwidth_sm\s+([0-9.]+)', line.strip())
    if m:
        reported = float(m.group(1))

print('=== nvbandwidth output ===')
if reported is not None:
    print(f'nvbandwidth_SUM_host_device_bandwidth_sm_GBps={reported:.3f}')
else:
    print('nvbandwidth_SUM_host_device_bandwidth_sm_GBps=NOT_FOUND')

print('\n=== perf UMC read bandwidth ===')
print(f'numa_node={numa_node}')
print(f'target_umcs={" ".join(map(str, target_indices))}')
print(f'all_umcs={" ".join(map(str, all_indices))}')
print(f'bytes_per_read_cas={bytes_per_cas}')

if not rows:
    print('ERROR: no perf interval rows parsed')
    raise SystemExit(1)

elapsed = rows[-1][0]
target_total_cas = sum(r[2] for r in rows)
other_total_cas = sum(r[3] for r in rows)
total_cas = target_total_cas + other_total_cas
print(f'elapsed_s={elapsed:.9f}')
print(f'target_total_read_cas={target_total_cas}')
print(f'other_total_read_cas={other_total_cas}')
print(f'all_total_read_cas={total_cas}')
print(f'target_whole_process_avg_GBps={target_total_cas * bytes_per_cas / 1e9 / elapsed:.3f}')
print(f'all_whole_process_avg_GBps={total_cas * bytes_per_cas / 1e9 / elapsed:.3f}')

# Active window heuristic: keep intervals above 5 GB/s, i.e. excludes CUDA init / allocation / teardown.
active = [r for r in rows if r[5] > 5.0]
if active:
    active_time = sum(r[1] for r in active)
    active_avg = sum(r[5] * r[1] for r in active) / active_time
    peak = max(active, key=lambda r: r[5])
    print(f'active_window_threshold_GBps=5.000')
    print(f'active_window_time_s={active_time:.9f}')
    print(f'active_avg_target_GBps={active_avg:.3f}')
    print(f'peak_target_GBps={peak[5]:.3f}')
    print(f'peak_at_s={peak[0]:.3f}')
else:
    print('active_avg_target_GBps=NOT_FOUND')
    print('peak_target_GBps=NOT_FOUND')

print('\n=== per-interval target bandwidth ===')
print('ts_s,dt_s,target_read_cas,other_read_cas,target_GBps,total_GBps')
for ts, dt, target_cas, other_cas, total_cas, target_gbps, total_gbps in rows:
    print(f'{ts:.3f},{dt:.3f},{target_cas},{other_cas},{target_gbps:.3f},{total_gbps:.3f}')
PY

echo
echo "Done. Files written under: $OUTDIR"
echo "  nvbandwidth output : $OUTDIR/nvbandwidth.out"
echo "  perf raw CSV       : $OUTDIR/perf_interval.csv"
echo "  parsed summary     : $OUTDIR/summary.txt"

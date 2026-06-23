#!/usr/bin/env bash
set -euo pipefail

# Sweep AMD uProf PCM for nvbandwidth testcase 33 over buffer sizes.
#
# Default command per buffer:
#   OUTDIR=<sweep_root>/buffer_<N>MiB BUFFER_SIZE=<N> ./collect_amdprof_mem_bw_t33.sh
#
# Useful examples:
#   ./sweep_amdprof_t33_buffersize.sh
#   LOOP_COUNT=5000 ./sweep_amdprof_t33_buffersize.sh
#   SAMPLE_INTERVAL_MS=10 LOOP_COUNT=100 ./sweep_amdprof_t33_buffersize.sh
#   SAMPLE_INTERVAL_MS=1 START_DELAY_MS=0 PROFILE_SECONDS=1 LOOP_COUNT=100 ./sweep_amdprof_t33_buffersize.sh
#   PCM_WAIT_FOR_SIGNAL=1 SAMPLE_INTERVAL_MS=1 LOOP_COUNT=100 ./sweep_amdprof_t33_buffersize.sh
#   USE_SCALED_LOOP_COUNT=1 ./sweep_amdprof_t33_buffersize.sh
#   BUFFER_SIZES="2 4 8 16" USE_SCALED_LOOP_COUNT=1 TEST_SAMPLES=3 ./sweep_amdprof_t33_buffersize.sh
#
# Tunables passed through to collect_amdprof_mem_bw_t33.sh:
#   CUDA_VISIBLE_DEVICES, NUMA_NODE, CPU_BIND, TESTCASE, TEST_SAMPLES,
#   HOST_READ_PARALLELISM, LATENCY_STRIDE_LEN, PCM_METRICS, SAMPLE_INTERVAL_MS,
#   START_DELAY_MS, PROFILE_SECONDS, EXTRA_NVBW_ARGS, etc.
#
# Sweep-specific tunables:
#   BUFFER_SIZES="2 4 8 16 32 64 128 256 512"
#   OUTROOT=<dir>                 sweep root dir; default timestamped
#   RETRIES=2                     attempts per buffer
#   SAMPLE_INTERVAL_MS=20         AMDuProfPcm -I interval; lower means higher sampling frequency
#   START_DELAY_MS=0              AMDuProfPcm --start-delay milliseconds
#   PROFILE_SECONDS=              AMDuProfPcm -d duration seconds; empty stops when app exits
#   PCM_WAIT_FOR_SIGNAL=1         make AMDuProfPcm wait for nvbandwidth SIGUSR1 start marker; set 0 for full-process profiling
#   PCM_SIGNAL_END=1              with PCM_WAIT_FOR_SIGNAL=1, nvbandwidth sends SIGINT end marker
#   LOOP_COUNT=<N>                fixed loopCount for all buffers; empty means collect script default
#   USE_SCALED_LOOP_COUNT=0       set 1 to scale loopCount inversely with buffer size
#   BASE_LOOP_COUNT=5000          loopCount at BASE_BUFFER_MIB when USE_SCALED_LOOP_COUNT=1
#   BASE_BUFFER_MIB=2             base buffer for scaled loopCount
#   MIN_LOOP_COUNT=16             lower bound for scaled loopCount
#   VERBOSE_NVBW=0                passed through
#   SKIP_VERIFICATION=0           passed through

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUFFER_SIZES="${BUFFER_SIZES:-1 2 4 8 16 32 64 128}"
OUTROOT="${OUTROOT:-amdprof_nvbw_t33_sweep_$(date +%Y%m%d_%H%M%S)}"
RETRIES="${RETRIES:-2}"
SAMPLE_INTERVAL_MS="${SAMPLE_INTERVAL_MS:-1}"
START_DELAY_MS="${START_DELAY_MS:-0}"
PROFILE_SECONDS="${PROFILE_SECONDS:-}"
PCM_WAIT_FOR_SIGNAL="${PCM_WAIT_FOR_SIGNAL:-1}"
PCM_SIGNAL_END="${PCM_SIGNAL_END:-1}"
LOOP_COUNT_FIXED="${LOOP_COUNT:-1000}"
USE_SCALED_LOOP_COUNT="${USE_SCALED_LOOP_COUNT:-0}"
BASE_LOOP_COUNT="${BASE_LOOP_COUNT:-5000}"
BASE_BUFFER_MIB="${BASE_BUFFER_MIB:-2}"
MIN_LOOP_COUNT="${MIN_LOOP_COUNT:-16}"

mkdir -p "$OUTROOT"

scaled_loop_count() {
  local buffer_mib="$1"
  local loop_count
  loop_count=$(( BASE_LOOP_COUNT * BASE_BUFFER_MIB / buffer_mib ))
  if (( loop_count < MIN_LOOP_COUNT )); then
    loop_count="$MIN_LOOP_COUNT"
  fi
  printf '%s\n' "$loop_count"
}

summary_file_for_buffer() {
  local buffer_mib="$1"
  find "$OUTROOT" -maxdepth 1 -type d \( -name "buffer_${buffer_mib}MiB" -o -name "buffer_${buffer_mib}MiB_retry*" \) \
    | while read -r d; do
        if [[ -f "$d/summary.txt" ]]; then
          printf '%s\n' "$d"
        fi
      done \
    | sort -V \
    | tail -n 1
}

{
  echo "sweep_root=$OUTROOT"
  echo "buffer_sizes_MiB=$BUFFER_SIZES"
  echo "retries=$RETRIES"
  echo "sample_interval_ms=$SAMPLE_INTERVAL_MS"
  echo "start_delay_ms=$START_DELAY_MS"
  echo "profile_seconds=$PROFILE_SECONDS"
  echo "pcm_wait_for_signal=$PCM_WAIT_FOR_SIGNAL"
  echo "pcm_signal_end=$PCM_SIGNAL_END"
  echo "loop_count_fixed=$LOOP_COUNT_FIXED"
  echo "use_scaled_loop_count=$USE_SCALED_LOOP_COUNT"
  echo "base_loop_count=$BASE_LOOP_COUNT"
  echo "base_buffer_mib=$BASE_BUFFER_MIB"
  echo "min_loop_count=$MIN_LOOP_COUNT"
  echo "start_time=$(date --iso-8601=seconds)"
} | tee "$OUTROOT/sweep.info"

failed=0

for b in $BUFFER_SIZES; do
  ok=0

  loop_env=()
  pcm_timing_env=("SAMPLE_INTERVAL_MS=$SAMPLE_INTERVAL_MS" "START_DELAY_MS=$START_DELAY_MS" "PROFILE_SECONDS=$PROFILE_SECONDS" "PCM_WAIT_FOR_SIGNAL=$PCM_WAIT_FOR_SIGNAL" "PCM_SIGNAL_END=$PCM_SIGNAL_END")
  if [[ -n "$LOOP_COUNT_FIXED" ]]; then
    loop_env=("LOOP_COUNT=$LOOP_COUNT_FIXED")
  elif [[ "$USE_SCALED_LOOP_COUNT" != "0" ]]; then
    loop_env=("LOOP_COUNT=$(scaled_loop_count "$b")")
  fi

  for attempt in $(seq 1 "$RETRIES"); do
    suffix=""
    if (( attempt > 1 )); then
      suffix="_retry${attempt}"
    fi
    outdir="$OUTROOT/buffer_${b}MiB${suffix}"

    echo
    echo "===== BUFFER_SIZE=${b} MiB attempt=${attempt}/${RETRIES} -> ${outdir} ====="
    if ((${#loop_env[@]})); then
      echo "  ${loop_env[*]}"
    fi
    echo "  ${pcm_timing_env[*]}"

    set +e
    env OUTDIR="$outdir" BUFFER_SIZE="$b" "${pcm_timing_env[@]}" "${loop_env[@]}" ./collect_amdprof_mem_bw_t33.sh 2>&1 | tee "$outdir.driver.log"
    rc=${PIPESTATUS[0]}
    set -e

    if [[ "$rc" -eq 0 ]]; then
      echo "BUFFER_SIZE=${b} status=ok attempt=${attempt} outdir=${outdir} ${pcm_timing_env[*]} ${loop_env[*]-}" | tee -a "$OUTROOT/sweep.info"
      ok=1
      break
    fi

    echo "BUFFER_SIZE=${b} status=failed attempt=${attempt} rc=${rc} outdir=${outdir} ${pcm_timing_env[*]} ${loop_env[*]-}" | tee -a "$OUTROOT/sweep.info"
  done

  if [[ "$ok" -ne 1 ]]; then
    failed=1
  fi
done

{
  echo "end_time=$(date --iso-8601=seconds)"
  echo "failed=$failed"
} | tee -a "$OUTROOT/sweep.info"

# Generate four-column summary requested most often:
#   buffer, nvbandwidth SUM, System Mem Rd median/p95, System PCIe Rd median/p95
summary_csv="$OUTROOT/four_column_summary.csv"
summary_md="$OUTROOT/four_column_summary.md"

python3 - "$OUTROOT" $BUFFER_SIZES <<'PY'
from pathlib import Path
import csv
import sys

root = Path(sys.argv[1])
buffers = [int(x) for x in sys.argv[2:]]
keys = {
    'nvbandwidth_SUM_host_device_bandwidth_sm_GBps': 'nvbandwidth_SUM_GBps',
    'system_total_mem_read_bw_GBps_median': 'system_mem_rd_median_GBps',
    'system_total_mem_read_bw_GBps_p95': 'system_mem_rd_p95_GBps',
    'system_total_pcie_read_bw_GBps_median': 'system_pcie_rd_median_GBps',
    'system_total_pcie_read_bw_GBps_p95': 'system_pcie_rd_p95_GBps',
}

def dirs_for_buffer(b):
    return sorted(
        [p for p in root.iterdir()
         if p.is_dir()
         and (p.name == f'buffer_{b}MiB' or p.name.startswith(f'buffer_{b}MiB_retry'))
         and (p / 'summary.txt').is_file()],
        key=lambda p: p.name,
    )

rows = []
for b in buffers:
    dirs = dirs_for_buffer(b)
    row = {'buffer_MiB': b, 'result_dir': ''}
    if not dirs:
        row.update({v: '' for v in keys.values()})
        rows.append(row)
        continue

    d = dirs[-1]
    row['result_dir'] = str(d)
    for line in (d / 'summary.txt').read_text(errors='replace').splitlines():
        if '=' not in line:
            continue
        k, v = line.split('=', 1)
        if k in keys:
            row[keys[k]] = v
    for out_key in keys.values():
        row.setdefault(out_key, '')
    rows.append(row)

csv_path = root / 'four_column_summary.csv'
with csv_path.open('w', newline='') as f:
    fieldnames = [
        'buffer_MiB',
        'nvbandwidth_SUM_GBps',
        'system_mem_rd_median_GBps',
        'system_mem_rd_p95_GBps',
        'system_pcie_rd_median_GBps',
        'system_pcie_rd_p95_GBps',
        'result_dir',
    ]
    w = csv.DictWriter(f, fieldnames=fieldnames)
    w.writeheader()
    w.writerows(rows)

md_lines = [
    '# nvbandwidth testcase 33 sweep summary',
    '',
    '- Units: GB/s.',
    '',
    '| Buffer MiB | nvbandwidth SUM | System Mem Rd median | System Mem Rd p95 | System PCIe Rd median | System PCIe Rd p95 |',
    '| ---: | ---: | ---: | ---: | ---: | ---: |',
]
for r in rows:
    md_lines.append(
        f"| {r['buffer_MiB']} | {r['nvbandwidth_SUM_GBps']} | "
        f"{r['system_mem_rd_median_GBps']} | {r['system_mem_rd_p95_GBps']} | "
        f"{r['system_pcie_rd_median_GBps']} | {r['system_pcie_rd_p95_GBps']} |"
    )
md_path = root / 'four_column_summary.md'
md_path.write_text('\n'.join(md_lines) + '\n')

print(md_path)
print(csv_path)
print('\n'.join(md_lines[4:]))
PY

echo
echo "Done. Sweep root: $OUTROOT"
echo "Summary markdown: $summary_md"
echo "Summary CSV     : $summary_csv"

exit "$failed"

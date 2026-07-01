#!/usr/bin/env bash
set -Eeuo pipefail

# Rerun low-sample nvbandwidth/Intel PCM points.
# Generated from combined_results_20260701_021706/latest_full_sweep_repeat_aggregate.csv
# Goal: at least 15 PCM samples per repeat by targeting about 20 seconds/run.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
OUTBASE="${OUTBASE:-rerun_low_sample_min15/$TS}"
mkdir -p "$OUTBASE"
LOG="$OUTBASE/rerun_low_sample_min15.log"
echo "Low-sample rerun outputs: $OUTBASE" | tee "$LOG"
echo "Manifest: low_sample_rerun_manifest_min15.csv" | tee -a "$LOG"

run_sweep_point() {
  local testcase="$1"
  local run_label="$2"
  local tuning_name="$3"
  local tuning_value="$4"
  local buffer_mib="$5"
  local loop_count="$6"
  local outroot
  outroot="$OUTBASE/intel_pcm_nvbw_t${testcase}_${run_label}_sweep_low_sample_min15_${tuning_name}_${tuning_value}_buffer_${buffer_mib}MiB_$(date +%Y%m%d_%H%M%S)"
  echo "=== t${testcase} ${run_label} ${tuning_name}=${tuning_value} buffer=${buffer_mib}MiB LOOP_COUNT=${loop_count} -> ${outroot} ===" | tee -a "$LOG"
  if [[ "$testcase" == "16" ]]; then
    env RUN_LABEL="$run_label" OUTROOT="$outroot" TESTCASE=16 BUFFER_SIZES="$buffer_mib" SM_COPY_BYTES_LIST="$tuning_value" LOOP_COUNT="$loop_count" RETRIES="${RETRIES:-3}" SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}" NVIDIA_QUERY_INTERVAL="${NVIDIA_QUERY_INTERVAL:-1}" NVIDIA_DMON_INTERVAL="${NVIDIA_DMON_INTERVAL:-1}" bash ./sweep_intel_pcm_t16.sh 2>&1 | tee -a "$LOG"
  elif [[ "$testcase" == "33" ]]; then
    env RUN_LABEL="$run_label" OUTROOT="$outroot" TESTCASE=33 BUFFER_SIZES="$buffer_mib" PTR_CHASE_LOAD_BYTES_LIST="$tuning_value" LOOP_COUNT="$loop_count" RETRIES="${RETRIES:-3}" SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}" NVIDIA_QUERY_INTERVAL="${NVIDIA_QUERY_INTERVAL:-1}" NVIDIA_DMON_INTERVAL="${NVIDIA_DMON_INTERVAL:-1}" bash ./sweep_intel_pcm_t33.sh 2>&1 | tee -a "$LOG"
  else
    echo "Unsupported testcase: $testcase" | tee -a "$LOG"
    return 1
  fi
}

apply_state() {
  local ro_state="$1"
  local msr_value="$2"
  if [[ "$ro_state" == "on" ]]; then
    bash enable_RO.sh
  else
    bash disable_RO.sh
  fi
  wrmsr 0xc8b "$msr_value"
}

echo "### Applying state ro_on_c000: RO=on, MSR=0xc000" | tee -a "$LOG"
apply_state "on" "0xc000"
run_sweep_point 16 ro_on_c000 sm_copy_bytes 32 1 3276800
run_sweep_point 16 ro_on_c000 sm_copy_bytes 32 2 1404928
run_sweep_point 16 ro_on_c000 sm_copy_bytes 32 4 983040
run_sweep_point 16 ro_on_c000 sm_copy_bytes 32 8 351232
run_sweep_point 16 ro_on_c000 sm_copy_bytes 32 16 176128
run_sweep_point 16 ro_on_c000 sm_copy_bytes 32 32 102400
run_sweep_point 33 ro_on_c000 ptr_chase_load_bytes 32 1 63488
run_sweep_point 33 ro_on_c000 ptr_chase_load_bytes 32 2 59392
run_sweep_point 33 ro_on_c000 ptr_chase_load_bytes 32 4 23552
run_sweep_point 33 ro_on_c000 ptr_chase_load_bytes 32 8 10240
run_sweep_point 33 ro_on_c000 ptr_chase_load_bytes 32 16 5120
run_sweep_point 33 ro_on_c000 ptr_chase_load_bytes 32 32 3072
run_sweep_point 33 ro_on_c000 ptr_chase_load_bytes 32 64 2048
run_sweep_point 33 ro_on_c000 ptr_chase_load_bytes 32 128 519
run_sweep_point 33 ro_on_c000 ptr_chase_load_bytes 32 256 247
run_sweep_point 33 ro_on_c000 ptr_chase_load_bytes 32 512 107

echo "### Applying state ro_off_c000: RO=off, MSR=0xc000" | tee -a "$LOG"
apply_state "off" "0xc000"
run_sweep_point 16 ro_off_c000 sm_copy_bytes 32 1 2808832
run_sweep_point 16 ro_off_c000 sm_copy_bytes 32 2 1228800
run_sweep_point 16 ro_off_c000 sm_copy_bytes 32 4 819200
run_sweep_point 16 ro_off_c000 sm_copy_bytes 32 8 409600
run_sweep_point 16 ro_off_c000 sm_copy_bytes 32 16 204800
run_sweep_point 16 ro_off_c000 sm_copy_bytes 32 32 88064
run_sweep_point 33 ro_off_c000 ptr_chase_load_bytes 32 1 66560
run_sweep_point 33 ro_off_c000 ptr_chase_load_bytes 32 2 59392
run_sweep_point 33 ro_off_c000 ptr_chase_load_bytes 32 4 20480
run_sweep_point 33 ro_off_c000 ptr_chase_load_bytes 32 8 11264
run_sweep_point 33 ro_off_c000 ptr_chase_load_bytes 32 16 5120
run_sweep_point 33 ro_off_c000 ptr_chase_load_bytes 32 32 3072
run_sweep_point 33 ro_off_c000 ptr_chase_load_bytes 32 64 2048
run_sweep_point 33 ro_off_c000 ptr_chase_load_bytes 32 128 534
run_sweep_point 33 ro_off_c000 ptr_chase_load_bytes 32 256 247
run_sweep_point 33 ro_off_c000 ptr_chase_load_bytes 32 512 107

echo "### Applying state ro_on_ff00: RO=on, MSR=0xff00" | tee -a "$LOG"
apply_state "on" "0xff00"
run_sweep_point 16 ro_on_ff00 sm_copy_bytes 32 1 2457600
run_sweep_point 16 ro_on_ff00 sm_copy_bytes 32 2 1404928
run_sweep_point 16 ro_on_ff00 sm_copy_bytes 32 4 702464
run_sweep_point 16 ro_on_ff00 sm_copy_bytes 32 8 409600
run_sweep_point 16 ro_on_ff00 sm_copy_bytes 32 16 176128
run_sweep_point 16 ro_on_ff00 sm_copy_bytes 32 32 88064
run_sweep_point 33 ro_on_ff00 ptr_chase_load_bytes 32 1 65536
run_sweep_point 33 ro_on_ff00 ptr_chase_load_bytes 32 2 65536
run_sweep_point 33 ro_on_ff00 ptr_chase_load_bytes 32 4 20480
run_sweep_point 33 ro_on_ff00 ptr_chase_load_bytes 32 8 10240
run_sweep_point 33 ro_on_ff00 ptr_chase_load_bytes 32 16 5120
run_sweep_point 33 ro_on_ff00 ptr_chase_load_bytes 32 32 3072
run_sweep_point 33 ro_on_ff00 ptr_chase_load_bytes 32 64 2048
run_sweep_point 33 ro_on_ff00 ptr_chase_load_bytes 32 128 519
run_sweep_point 33 ro_on_ff00 ptr_chase_load_bytes 32 256 247
run_sweep_point 33 ro_on_ff00 ptr_chase_load_bytes 32 512 112

echo "### Applying state ro_off_ff00: RO=off, MSR=0xff00" | tee -a "$LOG"
apply_state "off" "0xff00"
run_sweep_point 16 ro_off_ff00 sm_copy_bytes 32 1 2185216
run_sweep_point 16 ro_off_ff00 sm_copy_bytes 32 2 1404928
run_sweep_point 16 ro_off_ff00 sm_copy_bytes 32 4 819200
run_sweep_point 16 ro_off_ff00 sm_copy_bytes 32 8 409600
run_sweep_point 16 ro_off_ff00 sm_copy_bytes 32 16 204800
run_sweep_point 16 ro_off_ff00 sm_copy_bytes 32 32 102400
run_sweep_point 33 ro_off_ff00 ptr_chase_load_bytes 32 1 66560
run_sweep_point 33 ro_off_ff00 ptr_chase_load_bytes 32 2 59392
run_sweep_point 33 ro_off_ff00 ptr_chase_load_bytes 32 4 20480
run_sweep_point 33 ro_off_ff00 ptr_chase_load_bytes 32 8 10240
run_sweep_point 33 ro_off_ff00 ptr_chase_load_bytes 32 16 5120
run_sweep_point 33 ro_off_ff00 ptr_chase_load_bytes 32 32 3072
run_sweep_point 33 ro_off_ff00 ptr_chase_load_bytes 32 64 2048
run_sweep_point 33 ro_off_ff00 ptr_chase_load_bytes 32 128 519
run_sweep_point 33 ro_off_ff00 ptr_chase_load_bytes 32 256 260
run_sweep_point 33 ro_off_ff00 ptr_chase_load_bytes 32 512 110

echo "Reruns finished: $OUTBASE" | tee -a "$LOG"
echo "To merge these reruns into the existing integrated result, run:" | tee -a "$LOG"
echo "  python3 merge_low_sample_reruns.py --base combined_results_20260701_021706 --rerun-root $OUTBASE" | tee -a "$LOG"

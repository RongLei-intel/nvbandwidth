#!/usr/bin/env bash
set -euo pipefail

# Auto-generated rerun script from combined_intel_pcm_summary1/2 analysis
# It reruns only selected abnormal points and saves outputs under rerun_results/<timestamp>/
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
OUTBASE="rerun_results/$TS"
mkdir -p "$OUTBASE"
echo "Rerun outputs will be saved under: $OUTBASE"

echo "=== testcase=16 run_label=ro_off sm_copy_bytes=32 buffers=[1 2 4 8 16 32] ==="
(
  export RUN_LABEL="ro_off_rerun"
  export BUFFER_SIZES="1 2 4 8 16 32"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="5"
  export PCM_TOOLS="amd-uprof-pcm"
  export TESTCASE=16
  export SM_COPY_BYTES_LIST="32"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t16_ro_off_rerun_sm_copy_bytes_32_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t16.sh
)

echo "=== testcase=16 run_label=ro_off_c000 sm_copy_bytes=32 buffers=[1 2 4 8 16 32] ==="
(
  export RUN_LABEL="ro_off_c000_rerun"
  export BUFFER_SIZES="1 2 4 8 16 32"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="1"
  export NVIDIA_QUERY_INTERVAL="1"
  export NVIDIA_DMON_INTERVAL="1"
  export PCM_TOOLS="pcm-memory pcm-pcie"
  export TESTCASE=16
  export SM_COPY_BYTES_LIST="32"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t16_ro_off_c000_rerun_sm_copy_bytes_32_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t16.sh
)

echo "=== testcase=16 run_label=ro_off_ff00 sm_copy_bytes=32 buffers=[1 2 4 8 16 32] ==="
(
  export RUN_LABEL="ro_off_ff00_rerun"
  export BUFFER_SIZES="1 2 4 8 16 32"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="1"
  export NVIDIA_QUERY_INTERVAL="1"
  export NVIDIA_DMON_INTERVAL="1"
  export PCM_TOOLS="pcm-memory pcm-pcie"
  export TESTCASE=16
  export SM_COPY_BYTES_LIST="32"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t16_ro_off_ff00_rerun_sm_copy_bytes_32_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t16.sh
)

echo "=== testcase=16 run_label=ro_off_ff00 sm_copy_bytes=4 buffers=[2048] ==="
(
  export RUN_LABEL="ro_off_ff00_rerun"
  export BUFFER_SIZES="2048"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="1"
  export NVIDIA_QUERY_INTERVAL="1"
  export NVIDIA_DMON_INTERVAL="1"
  export PCM_TOOLS="pcm-memory pcm-pcie"
  export TESTCASE=16
  export SM_COPY_BYTES_LIST="4"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t16_ro_off_ff00_rerun_sm_copy_bytes_4_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t16.sh
)

echo "=== testcase=16 run_label=ro_on sm_copy_bytes=32 buffers=[1 2 4 8 16 32] ==="
(
  export RUN_LABEL="ro_on_rerun"
  export BUFFER_SIZES="1 2 4 8 16 32"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="5"
  export PCM_TOOLS="amd-uprof-pcm"
  export TESTCASE=16
  export SM_COPY_BYTES_LIST="32"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t16_ro_on_rerun_sm_copy_bytes_32_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t16.sh
)

echo "=== testcase=16 run_label=ro_on_c000 sm_copy_bytes=32 buffers=[1 2 4 8 16 32] ==="
(
  export RUN_LABEL="ro_on_c000_rerun"
  export BUFFER_SIZES="1 2 4 8 16 32"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="1"
  export NVIDIA_QUERY_INTERVAL="1"
  export NVIDIA_DMON_INTERVAL="1"
  export PCM_TOOLS="pcm-memory pcm-pcie"
  export TESTCASE=16
  export SM_COPY_BYTES_LIST="32"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t16_ro_on_c000_rerun_sm_copy_bytes_32_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t16.sh
)

echo "=== testcase=16 run_label=ro_on_ff00 sm_copy_bytes=32 buffers=[1 2 4 8 16 32] ==="
(
  export RUN_LABEL="ro_on_ff00_rerun"
  export BUFFER_SIZES="1 2 4 8 16 32"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="1"
  export NVIDIA_QUERY_INTERVAL="1"
  export NVIDIA_DMON_INTERVAL="1"
  export PCM_TOOLS="pcm-memory pcm-pcie"
  export TESTCASE=16
  export SM_COPY_BYTES_LIST="32"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t16_ro_on_ff00_rerun_sm_copy_bytes_32_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t16.sh
)

echo "=== testcase=33 run_label=ro_off ptr_chase_load_bytes=16 buffers=[1024 2048] ==="
(
  export RUN_LABEL="ro_off_rerun"
  export BUFFER_SIZES="1024 2048"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="5"
  export PCM_TOOLS="amd-uprof-pcm"
  export TESTCASE=33
  export PTR_CHASE_LOAD_BYTES_LIST="16"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t33_ro_off_rerun_ptr_chase_load_bytes_16_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t33.sh
)

echo "=== testcase=33 run_label=ro_off ptr_chase_load_bytes=32 buffers=[1024 2048] ==="
(
  export RUN_LABEL="ro_off_rerun"
  export BUFFER_SIZES="1024 2048"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="5"
  export PCM_TOOLS="amd-uprof-pcm"
  export TESTCASE=33
  export PTR_CHASE_LOAD_BYTES_LIST="32"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t33_ro_off_rerun_ptr_chase_load_bytes_32_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t33.sh
)

echo "=== testcase=33 run_label=ro_off ptr_chase_load_bytes=8 buffers=[1024 2048] ==="
(
  export RUN_LABEL="ro_off_rerun"
  export BUFFER_SIZES="1024 2048"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="5"
  export PCM_TOOLS="amd-uprof-pcm"
  export TESTCASE=33
  export PTR_CHASE_LOAD_BYTES_LIST="8"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t33_ro_off_rerun_ptr_chase_load_bytes_8_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t33.sh
)

echo "=== testcase=33 run_label=ro_on ptr_chase_load_bytes=16 buffers=[1024 2048] ==="
(
  export RUN_LABEL="ro_on_rerun"
  export BUFFER_SIZES="1024 2048"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="5"
  export PCM_TOOLS="amd-uprof-pcm"
  export TESTCASE=33
  export PTR_CHASE_LOAD_BYTES_LIST="16"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t33_ro_on_rerun_ptr_chase_load_bytes_16_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t33.sh
)

echo "=== testcase=33 run_label=ro_on ptr_chase_load_bytes=32 buffers=[1024 2048] ==="
(
  export RUN_LABEL="ro_on_rerun"
  export BUFFER_SIZES="1024 2048"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="5"
  export PCM_TOOLS="amd-uprof-pcm"
  export TESTCASE=33
  export PTR_CHASE_LOAD_BYTES_LIST="32"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t33_ro_on_rerun_ptr_chase_load_bytes_32_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t33.sh
)

echo "=== testcase=33 run_label=ro_on ptr_chase_load_bytes=8 buffers=[1024 2048] ==="
(
  export RUN_LABEL="ro_on_rerun"
  export BUFFER_SIZES="1024 2048"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="5"
  export PCM_TOOLS="amd-uprof-pcm"
  export TESTCASE=33
  export PTR_CHASE_LOAD_BYTES_LIST="8"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t33_ro_on_rerun_ptr_chase_load_bytes_8_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t33.sh
)

echo "=== testcase=33 run_label=ro_on_c000 ptr_chase_load_bytes=16 buffers=[1024] ==="
(
  export RUN_LABEL="ro_on_c000_rerun"
  export BUFFER_SIZES="1024"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="1"
  export NVIDIA_QUERY_INTERVAL="1"
  export NVIDIA_DMON_INTERVAL="1"
  export PCM_TOOLS="pcm-memory pcm-pcie"
  export TESTCASE=33
  export PTR_CHASE_LOAD_BYTES_LIST="16"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t33_ro_on_c000_rerun_ptr_chase_load_bytes_16_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t33.sh
)

echo "=== testcase=33 run_label=ro_on_c000 ptr_chase_load_bytes=32 buffers=[1 1024] ==="
(
  export RUN_LABEL="ro_on_c000_rerun"
  export BUFFER_SIZES="1 1024"
  export RETRIES=2
  export CUDA_VISIBLE_DEVICES="0"
  export NUMA_NODE="0"
  export CPU_BIND="1"
  export SAMPLE_INTERVAL="1"
  export NVIDIA_QUERY_INTERVAL="1"
  export NVIDIA_DMON_INTERVAL="1"
  export PCM_TOOLS="pcm-memory pcm-pcie"
  export TESTCASE=33
  export PTR_CHASE_LOAD_BYTES_LIST="32"
  export OUTROOT="$OUTBASE/intel_pcm_nvbw_t33_ro_on_c000_rerun_ptr_chase_load_bytes_32_$(date +%Y%m%d_%H%M%S)"
  bash ./sweep_intel_pcm_t33.sh
)

echo "All rerun commands finished. Outputs in: $OUTBASE"

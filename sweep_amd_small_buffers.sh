#!/usr/bin/env bash
set -euo pipefail

# Small-buffer AMD sweep driver using true KiB-sized nvbandwidth buffers.
#
# Default range: 512 KiB, 256 KiB, 128 KiB, 64 KiB, 32 KiB.
#
# Testcase selection:
#   TESTCASE=16 -> SM copy width sweep via --smCopyBytes
#   TESTCASE=33 -> pointer-chase load-width sweep via --ptrChaseLoadBytes
#
# Examples:
#   bash sweep_amd_small_buffers.sh
#   TESTCASE=33 bash sweep_amd_small_buffers.sh
#   BUFFER_SIZES_KIB="1024 512 256" bash sweep_amd_small_buffers.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUFFER_SIZES_KIB="${BUFFER_SIZES_KIB:-512 256 128 64 32}"
RETRIES="${RETRIES:-2}"
TESTCASE="${TESTCASE:-16}"
COLLECT_SCRIPT="${COLLECT_SCRIPT:-./collect_amdprof_mem_bw_t33.sh}"
TARGET_TRANSFER_MIB="${TARGET_TRANSFER_MIB:-256}"
MIN_LOOP_COUNT="${MIN_LOOP_COUNT:-4}"
MAX_LOOP_COUNT="${MAX_LOOP_COUNT:-262144}"
LOOP_COUNT_VALUE="${LOOP_COUNT-}"
AUTO_LOOP_COUNT="${AUTO_LOOP_COUNT:-1}"
RUN_LABEL="${RUN_LABEL:-}"
SAMPLE_INTERVAL_MS="${SAMPLE_INTERVAL_MS:-5}"
PCM_WAIT_FOR_SIGNAL="${PCM_WAIT_FOR_SIGNAL:-1}"

case "$TESTCASE" in
    16)
        TUNE_LIST="${SM_COPY_BYTES_LIST:-${SM_COPY_BYTES:-4 8 16 32}}"
        TUNE_ARG_NAME="smCopyBytes"
        OUTROOT_PREFIX="amd_small_kib_t16"
        ;;
    33)
        TUNE_LIST="${PTR_CHASE_LOAD_BYTES_LIST:-${SM_COPY_BYTES_LIST:-${PTR_CHASE_LOAD_BYTES:-8 16 32}}}"
        TUNE_ARG_NAME="ptrChaseLoadBytes"
        OUTROOT_PREFIX="amd_small_kib_t33"
        ;;
    *)
        echo "ERROR: TESTCASE must be 16 or 33; got '$TESTCASE'" >&2
        exit 1
        ;;
esac

if [[ -n "$RUN_LABEL" ]]; then
    OUTROOT_DEFAULT="${OUTROOT_PREFIX}_${RUN_LABEL}_sweep_$(date +%Y%m%d_%H%M%S)"
else
    OUTROOT_DEFAULT="${OUTROOT_PREFIX}_sweep_$(date +%Y%m%d_%H%M%S)"
fi
OUTROOT="${OUTROOT:-$OUTROOT_DEFAULT}"
SWEEP_INFO_FILE="$OUTROOT/sweep${RUN_LABEL:+_${RUN_LABEL}}.info"
DRIVER_LOG_BASENAME="driver${RUN_LABEL:+_${RUN_LABEL}}.log"

if [[ -z "${BUFFER_SIZES_KIB//[[:space:]]/}" ]]; then
    echo "ERROR: BUFFER_SIZES_KIB is empty; provide values such as BUFFER_SIZES_KIB=\"512 256 128 64 32\"" >&2
    exit 1
fi

if [[ -z "${TUNE_LIST//[[:space:]]/}" ]]; then
    echo "ERROR: tuning list is empty; provide values like SM_COPY_BYTES_LIST=\"4 8 16 32\" or PTR_CHASE_LOAD_BYTES_LIST=\"8 16 32\"" >&2
    exit 1
fi

for kib in $BUFFER_SIZES_KIB; do
    if [[ "$kib" =~ ^[0-9]+$ ]] && [[ "$kib" -gt 0 ]]; then
        :
    else
        echo "ERROR: BUFFER_SIZES_KIB contains invalid value '$kib'" >&2
        exit 1
    fi
done

for tune in $TUNE_LIST; do
    if [[ "$TESTCASE" == "16" ]]; then
        if [[ "$tune" != "4" && "$tune" != "8" && "$tune" != "16" && "$tune" != "32" ]]; then
            echo "ERROR: SM_COPY_BYTES_LIST contains unsupported value '$tune'; supported: 4, 8, 16, 32" >&2
            exit 1
        fi
    else
        if [[ "$tune" != "8" && "$tune" != "16" && "$tune" != "32" ]]; then
            echo "ERROR: PTR_CHASE_LOAD_BYTES_LIST contains unsupported value '$tune'; supported: 8, 16, 32" >&2
            exit 1
        fi
    fi
done

mkdir -p "$OUTROOT"

buffer_loop_count() {
    local buffer_kib="$1"
    local target_transfer_kib=$(( TARGET_TRANSFER_MIB * 1024 ))
    local loop_count
    loop_count=$(( (target_transfer_kib + buffer_kib - 1) / buffer_kib ))
    if (( loop_count < MIN_LOOP_COUNT )); then
        loop_count="$MIN_LOOP_COUNT"
    fi
    if (( loop_count > MAX_LOOP_COUNT )); then
        loop_count="$MAX_LOOP_COUNT"
    fi
    printf '%s\n' "$loop_count"
}

{
    echo "sweep_root=$OUTROOT"
    echo "buffer_sizes_kib=$BUFFER_SIZES_KIB"
    echo "retries=$RETRIES"
    echo "collect_script=$COLLECT_SCRIPT"
    echo "testcase=$TESTCASE"
    echo "tuning_list=$TUNE_LIST"
    echo "tuning_arg_name=$TUNE_ARG_NAME"
    echo "target_transfer_mib=$TARGET_TRANSFER_MIB"
    echo "min_loop_count=$MIN_LOOP_COUNT"
    echo "max_loop_count=$MAX_LOOP_COUNT"
    echo "loop_count_fixed=$LOOP_COUNT_VALUE"
    echo "auto_loop_count=$AUTO_LOOP_COUNT"
    echo "sample_interval_ms=$SAMPLE_INTERVAL_MS"
    echo "pcm_wait_for_signal=$PCM_WAIT_FOR_SIGNAL"
    echo "start_time=$(date --iso-8601=seconds)"
} | tee "$SWEEP_INFO_FILE"

failed=0

for tune in $TUNE_LIST; do
    for buffer_kib in $BUFFER_SIZES_KIB; do
        loop_count="$LOOP_COUNT_VALUE"
        if [[ -z "$loop_count" && "$AUTO_LOOP_COUNT" != "0" ]]; then
            loop_count="$(buffer_loop_count "$buffer_kib")"
        fi

        for attempt in $(seq 1 "$RETRIES"); do
            suffix=""
            if (( attempt > 1 )); then
                suffix="_retry${attempt}"
            fi

            case "$TESTCASE" in
                16)
                    outdir="$OUTROOT/buffer_${buffer_kib}KiB_smcopy_${tune}B${suffix}"
                    extra_args="--smCopyBytes $tune"
                    ;;
                33)
                    outdir="$OUTROOT/buffer_${buffer_kib}KiB_ptrload_${tune}B${suffix}"
                    extra_args="--ptrChaseLoadBytes $tune"
                    ;;
            esac

            mkdir -p "$outdir"
            echo
            echo "===== ${TUNE_ARG_NAME}=${tune} BUFFER_SIZE=${buffer_kib} KiB attempt=${attempt}/${RETRIES} -> ${outdir} ====="
            echo "  LOOP_COUNT=${loop_count:-<collector default>}"
            echo "  EXTRA_NVBW_ARGS=${extra_args}"

            set +e
            env \
                OUTDIR="$outdir" \
                BUFFER_SIZE="" \
                BUFFER_SIZE_KIB="$buffer_kib" \
                LOOP_COUNT="$loop_count" \
                TESTCASE="$TESTCASE" \
                SAMPLE_INTERVAL_MS="$SAMPLE_INTERVAL_MS" \
                PCM_WAIT_FOR_SIGNAL="$PCM_WAIT_FOR_SIGNAL" \
                EXTRA_NVBW_ARGS="$extra_args" \
                "$COLLECT_SCRIPT" 2>&1 | tee "$outdir/$DRIVER_LOG_BASENAME"
            rc=${PIPESTATUS[0]}
            set -e

            if [[ "$rc" -eq 0 ]]; then
                echo "${TUNE_ARG_NAME}=${tune} BUFFER_SIZE_KIB=${buffer_kib} status=ok attempt=${attempt} outdir=${outdir} LOOP_COUNT=${loop_count:-}" | tee -a "$SWEEP_INFO_FILE"
                break
            fi

            echo "${TUNE_ARG_NAME}=${tune} BUFFER_SIZE_KIB=${buffer_kib} status=failed attempt=${attempt} rc=${rc} outdir=${outdir} LOOP_COUNT=${loop_count:-}" | tee -a "$SWEEP_INFO_FILE"
            if (( attempt == RETRIES )); then
                failed=1
            fi
        done
    done
done

echo
echo "Done. Sweep root: $OUTROOT"
exit "$failed"

#!/usr/bin/env bash
set -euo pipefail

# Small-buffer AMD sweep wrapper.
#
# nvbandwidth bufferSize is measured in MiB, so this wrapper targets the
# "small buffer" range for this repository with 32/64/128/256/512 MiB by
# default. Override BUFFER_SIZES if you need a different range.
#
# This wrapper dispatches to the existing testcase-specific AMD sweep:
#   TESTCASE=16 -> ./sweep_amdprof_t16.sh
#   TESTCASE=33 -> ./sweep_amdprof_t33.sh
#
# Common examples:
#   bash sweep_amd_small_buffers.sh
#   TESTCASE=33 bash sweep_amd_small_buffers.sh
#   BUFFER_SIZES="16 32 64 128" bash sweep_amd_small_buffers.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUFFER_SIZES="${BUFFER_SIZES:-32 64 128 256 512}"
TESTCASE="${TESTCASE:-16}"
TARGET_TRANSFER_MIB="${TARGET_TRANSFER_MIB:-262144}"
LARGE_BUFFER_MIB_THRESHOLD="${LARGE_BUFFER_MIB_THRESHOLD:-1024}"
LARGE_TARGET_TRANSFER_MIB="${LARGE_TARGET_TRANSFER_MIB:-8192}"
LARGE_MIN_LOOP_COUNT="${LARGE_MIN_LOOP_COUNT:-4}"

case "$TESTCASE" in
    16)
        sweep_script="./sweep_amdprof_t16.sh"
        ;;
    33)
        sweep_script="./sweep_amdprof_t33.sh"
        ;;
    *)
        echo "ERROR: TESTCASE must be 16 or 33 for this wrapper; got '$TESTCASE'" >&2
        exit 1
        ;;
esac

export BUFFER_SIZES
export TESTCASE
export TARGET_TRANSFER_MIB
export LARGE_BUFFER_MIB_THRESHOLD
export LARGE_TARGET_TRANSFER_MIB
export LARGE_MIN_LOOP_COUNT

exec "$sweep_script" "$@"

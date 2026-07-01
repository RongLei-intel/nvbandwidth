#!/usr/bin/env bash
set -euo pipefail

# Small-buffer Intel sweep wrapper.
#
# nvbandwidth bufferSize is measured in MiB, so this wrapper targets the
# "small buffer" range for this repository with 32/64/128/256/512 MiB by
# default. Override BUFFER_SIZES if you need a different range.
#
# This wrapper dispatches to the existing testcase-specific Intel sweep:
#   TESTCASE=16 -> ./sweep_intel_pcm_t16.sh
#   TESTCASE=33 -> ./sweep_intel_pcm_t33.sh
#
# Common examples:
#   bash sweep_intel_small_buffers.sh
#   TESTCASE=33 bash sweep_intel_small_buffers.sh
#   BUFFER_SIZES="16 32 64 128" bash sweep_intel_small_buffers.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUFFER_SIZES="${BUFFER_SIZES:-32 64 128 256 512}"
TESTCASE="${TESTCASE:-16}"
SMALL_BUFFER_MAX_MIB="${SMALL_BUFFER_MAX_MIB:-512}"
SMALL_BUFFER_TARGET_TRANSFER_MIB="${SMALL_BUFFER_TARGET_TRANSFER_MIB:-262144}"
TARGET_TRANSFER_MIB="${TARGET_TRANSFER_MIB:-262144}"

case "$TESTCASE" in
    16)
        sweep_script="./sweep_intel_pcm_t16.sh"
        ;;
    33)
        sweep_script="./sweep_intel_pcm_t33.sh"
        ;;
    *)
        echo "ERROR: TESTCASE must be 16 or 33 for this wrapper; got '$TESTCASE'" >&2
        exit 1
        ;;
esac

export BUFFER_SIZES
export TESTCASE
export SMALL_BUFFER_MAX_MIB
export SMALL_BUFFER_TARGET_TRANSFER_MIB
export TARGET_TRANSFER_MIB

exec "$sweep_script" "$@"

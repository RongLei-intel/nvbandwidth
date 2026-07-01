#!/usr/bin/env bash
set -euo pipefail

# Convenience wrapper for the AMD true-KiB small-buffer sweep using testcase 33.
#
# This preserves the generic sweep driver while giving t33 its own easy-to-run entry.
#
# Examples:
#   bash sweep_amd_small_buffers_t33.sh
#   BUFFER_SIZES_KIB="512 256 128 64 32" bash sweep_amd_small_buffers_t33.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

exec env TESTCASE=33 bash ./sweep_amd_small_buffers.sh "$@"

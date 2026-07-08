#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

failed=0

run_step() {
	local desc="$1"
	shift
	echo
	echo "===== $desc ====="
	"$@"
	local rc=$?
	if [[ $rc -ne 0 ]]; then
		echo "[FAIL] $desc (rc=$rc)" >&2
		failed=1
	else
		echo "[ OK ] $desc"
	fi
}

run_step "enable RO" bash enable_RO.sh
run_step "amd sweep ro_on" env RUN_LABEL=ro_on ONLY_TESTCASE="${ONLY_TESTCASE:-}" bash ./sweep_amd_all.sh

run_step "disable RO" bash disable_RO.sh
run_step "amd sweep ro_off" env RUN_LABEL=ro_off ONLY_TESTCASE="${ONLY_TESTCASE:-}" bash ./sweep_amd_all.sh

echo
if [[ $failed -ne 0 ]]; then
	echo "AMD sweep config finished with failures" >&2
else
	echo "AMD sweep config finished successfully"
fi

exit "$failed"

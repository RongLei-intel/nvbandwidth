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
run_step "set msr c000" wrmsr 0xc8b 0xc000
run_step "intel sweep ro_on_c000" env RUN_LABEL=ro_on_c000 ONLY_TESTCASE="${ONLY_TESTCASE:-}" bash ./sweep_intel_all.sh

run_step "set msr ff00" wrmsr 0xc8b 0xff00
run_step "intel sweep ro_on_ff00" env RUN_LABEL=ro_on_ff00 ONLY_TESTCASE="${ONLY_TESTCASE:-}" bash ./sweep_intel_all.sh

run_step "disable RO" bash disable_RO.sh
run_step "set msr c000 again" wrmsr 0xc8b 0xc000
run_step "intel sweep ro_off_c000" env RUN_LABEL=ro_off_c000 ONLY_TESTCASE="${ONLY_TESTCASE:-}" bash ./sweep_intel_all.sh

run_step "set msr ff00 again" wrmsr 0xc8b 0xff00
run_step "intel sweep ro_off_ff00" env RUN_LABEL=ro_off_ff00 ONLY_TESTCASE="${ONLY_TESTCASE:-}" bash ./sweep_intel_all.sh

echo
if [[ $failed -ne 0 ]]; then
	echo "Intel sweep config finished with failures" >&2
else
	echo "Intel sweep config finished successfully"
fi

exit "$failed"

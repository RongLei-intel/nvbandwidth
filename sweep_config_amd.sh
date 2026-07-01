#!/usr/bin/env bash
set -u

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

run_step "enable RO" bash -lc 'bash enable_RO.sh'

run_step "sweep t16 ro_on" bash -lc 'RUN_LABEL=ro_on bash sweep_amdprof_t16.sh'
run_step "sweep t33 ro_on" bash -lc 'RUN_LABEL=ro_on bash sweep_amdprof_t33.sh'

run_step "disable RO" bash -lc 'bash disable_RO.sh'

run_step "sweep t16 ro_off" bash -lc 'RUN_LABEL=ro_off bash sweep_amdprof_t16.sh'
run_step "sweep t33 ro_off" bash -lc 'RUN_LABEL=ro_off bash sweep_amdprof_t33.sh'

echo
if [[ $failed -ne 0 ]]; then
	echo "AMD sweep config finished with failures" >&2
else
	echo "AMD sweep config finished successfully"
fi

exit "$failed"

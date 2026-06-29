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

run_step "enable RO + wrmsr 0xc8b 0xc000" bash -lc 'bash enable_RO.sh && wrmsr 0xc8b 0xc000'

run_step "sweep t16 ro_on_c000" bash -lc 'RUN_LABEL=ro_on_c000 bash sweep_amdprof_t16.sh'
run_step "sweep t33 ro_on_c000" bash -lc 'RUN_LABEL=ro_on_c000 bash sweep_amdprof_t33.sh'

run_step "disable RO + wrmsr 0xc8b 0xc000" bash -lc 'bash disable_RO.sh && wrmsr 0xc8b 0xc000'

run_step "sweep t16 ro_off_c000" bash -lc 'RUN_LABEL=ro_off_c000 bash sweep_amdprof_t16.sh'
run_step "sweep t33 ro_off_c000" bash -lc 'RUN_LABEL=ro_off_c000 bash sweep_amdprof_t33.sh'

run_step "enable RO + wrmsr 0xc8b 0xff00" bash -lc 'bash enable_RO.sh && wrmsr 0xc8b 0xff00'

run_step "sweep t16 ro_on_ff00" bash -lc 'RUN_LABEL=ro_on_ff00 bash sweep_amdprof_t16.sh'
run_step "sweep t33 ro_on_ff00" bash -lc 'RUN_LABEL=ro_on_ff00 bash sweep_amdprof_t33.sh'

run_step "disable RO + wrmsr 0xc8b 0xff00" bash -lc 'bash disable_RO.sh && wrmsr 0xc8b 0xff00'

run_step "sweep t16 ro_off_ff00" bash -lc 'RUN_LABEL=ro_off_ff00 bash sweep_amdprof_t16.sh'
run_step "sweep t33 ro_off_ff00" bash -lc 'RUN_LABEL=ro_off_ff00 bash sweep_amdprof_t33.sh'

echo
if [[ $failed -ne 0 ]]; then
	echo "AMD sweep config finished with failures" >&2
else
	echo "AMD sweep config finished successfully"
fi

exit "$failed"

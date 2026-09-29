#!/usr/bin/env bash
# Regression tests for scripts/device-safe-probe.sh.
#
# The point of these tests is the ownership contract: a probe run that never
# activated a node must not write to it on ANY exit path, and a run that did
# activate a node must always clear it.
#
# No device is involved. The probe is pointed at a mock /proc + /sys tree, and
# "zero writes" is asserted against a fingerprint of the entire mock kernel
# surface, not just against the two nodes under test.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

PROBE="$REPO_ROOT/scripts/device-safe-probe.sh"

TERM_DIR_() { echo "$DDRC_VOT_ROOT/GAUGE_TERM_VOLTAGE"; }
SHUT_DIR_() { echo "$DDRC_VOT_ROOT/GAUGE_SHUTDOWN_VOLTAGE"; }

# ---------------------------------------------------------------- test 1
# check mode with an external owner active must perform ZERO writes.

t_start "check mode: external owner active -> zero writes"
mock_setup
printf '1' >"$(TERM_DIR_)/force_active"
printf '3100' >"$(TERM_DIR_)/force_val"
printf '1' >"$(SHUT_DIR_)/force_active"
printf '3000' >"$(SHUT_DIR_)/force_val"
take_snapshot

sh "$PROBE" check >"$MOCK/out.txt" 2>&1
rc=$?

assert_eq "check exits non-zero when an external owner is active" "1" "$rc"
assert_zero_writes "check with external owner: nothing anywhere was written"
assert_file_eq "external TERM force_active still 1" "1" "$(TERM_DIR_)/force_active"
assert_file_eq "external SHUTDOWN force_active still 1" "1" "$(SHUT_DIR_)/force_active"
assert_file_eq "external TERM force_val preserved" "3100" "$(TERM_DIR_)/force_val"
assert_file_eq "external SHUTDOWN force_val preserved" "3000" "$(SHUT_DIR_)/force_val"
mock_teardown

# ---------------------------------------------------------------- test 2
# check mode on a clean device must also be zero-write, and must not arm a
# watchdog.

t_start "check mode: clean device -> zero writes"
mock_setup
take_snapshot

sh "$PROBE" check >"$MOCK/out.txt" 2>&1
rc=$?

assert_eq "check exits zero on a healthy device" "0" "$rc"
assert_zero_writes "check on a healthy device wrote nothing"
if [ -f "$DDRC_WORKDIR/watchdog.stamp" ]; then
	not_ok "check mode armed a watchdog" "watchdog.stamp exists"
else
	ok "check mode armed no watchdog"
fi
mock_teardown

# ---------------------------------------------------------------- test 3
# Every preflight failure must be zero-write.
#
# The mutation snippet is evaluated AFTER mock_setup, inside the same shell, so
# it really does alter the mock this run is pointed at. (An earlier revision of
# this file expanded the paths too early and silently tested a stale directory,
# which made the assertions pass for the wrong reason.)

run_preflight_fail() {
	label="$1"
	prep="$2"
	mock_setup
	# shellcheck disable=SC2086
	eval "$prep"
	take_snapshot
	sh "$PROBE" balanced >"$MOCK/out.txt" 2>&1
	rc=$?
	assert_eq "$label: probe fails closed" "1" "$rc"
	assert_zero_writes "$label: zero writes anywhere"
	if grep -q "preflight" "$MOCK/out.txt"; then
		ok "$label: failure reported as a preflight violation"
	else
		not_ok "$label: failure reported as a preflight violation" "$(head -3 "$MOCK/out.txt")"
	fi
	mock_teardown
}

t_start "preflight failures -> zero writes"
run_preflight_fail "wrong model" 'MOCK_MODEL=NOTPKU110; export MOCK_MODEL'
run_preflight_fail "wrong battery type" 'printf silicon_2 >"$DDRC_BAT_ROOT/battery_type"'
run_preflight_fail "charger connected" 'printf Charging >"$DDRC_PWR_ROOT/status"'
run_preflight_fail "soc too low" 'printf 20 >"$DDRC_PWR_ROOT/capacity"'
run_preflight_fail "vbat too low" 'printf 3600 >"$DDRC_BAT_ROOT/gauge_vbat"'
run_preflight_fail "temp too high" 'printf 500 >"$DDRC_PWR_ROOT/temp"'
run_preflight_fail "temp too low" 'printf 50 >"$DDRC_PWR_ROOT/temp"'
run_preflight_fail "external owner on TERM" 'printf 1 >"$DDRC_VOT_ROOT/GAUGE_TERM_VOLTAGE/force_active"'
run_preflight_fail "external owner on SHUTDOWN" 'printf 1 >"$DDRC_VOT_ROOT/GAUGE_SHUTDOWN_VOLTAGE/force_active"'

# ---------------------------------------------------------------- test 4
# DT gate: a profile whose pair is absent from the live tree is refused
# without writing.

t_start "pair absent from live DT -> refused, zero writes"
mock_setup
dt_make_normal_rows high 3200 3250 3300 3350 # balanced/full pairs deliberately absent
take_snapshot
sh "$PROBE" balanced >"$MOCK/out.txt" 2>&1
rc=$?
assert_eq "balanced refused when pair absent" "1" "$rc"
assert_zero_writes "pair absent: zero writes anywhere"
grep -q "absent from the live device tree" "$MOCK/out.txt" &&
	ok "rejection reason names the device tree" ||
	not_ok "rejection reason names the device tree"
mock_teardown

# ---------------------------------------------------------------- test 5
# Happy path: a valid balanced run applies, then restores, and never resets
# force_val. The kernel emulator stands in for the driver regenerating status.

t_start "valid balanced run applies and restores"
mock_setup
dt_make_standard
arm_expected_status 3150 3100
sh "$PROBE" balanced >"$MOCK/out.txt" 2>&1
rc=$?
assert_eq "balanced run passes" "0" "$rc"
assert_file_eq "TERM force_active restored to 0" "0" "$(TERM_DIR_)/force_active"
assert_file_eq "SHUTDOWN force_active restored to 0" "0" "$(SHUT_DIR_)/force_active"
assert_file_eq "TERM force_val kept (never reset)" "3150" "$(TERM_DIR_)/force_val"
assert_file_eq "SHUTDOWN force_val kept (never reset)" "3100" "$(SHUT_DIR_)/force_val"
grep -q "RESULT=PASS mode=balanced" "$MOCK/out.txt" &&
	ok "run reported PASS" ||
	not_ok "run reported PASS" "$(tail -3 "$MOCK/out.txt")"
grep -q "effective=DEBUG_FORCE_CLIENT v=3150" "$MOCK/out.txt" &&
	ok "readback confirmed the forced TERM value" ||
	not_ok "readback confirmed the forced TERM value" "$(grep READBACK "$MOCK/out.txt")"
mock_teardown

# ---------------------------------------------------------------- test 5b
# Same happy path for the full profile.

t_start "valid full run applies and restores"
mock_setup
dt_make_standard
arm_expected_status 3040 3000
sh "$PROBE" full >"$MOCK/out.txt" 2>&1
rc=$?
assert_eq "full run passes" "0" "$rc"
assert_file_eq "TERM force_active restored to 0" "0" "$(TERM_DIR_)/force_active"
assert_file_eq "SHUTDOWN force_active restored to 0" "0" "$(SHUT_DIR_)/force_active"
assert_file_eq "TERM force_val kept" "3040" "$(TERM_DIR_)/force_val"
assert_file_eq "SHUTDOWN force_val kept" "3000" "$(SHUT_DIR_)/force_val"
grep -q "RESULT=PASS mode=full" "$MOCK/out.txt" &&
	ok "run reported PASS" ||
	not_ok "run reported PASS" "$(tail -3 "$MOCK/out.txt")"
mock_teardown

# ---------------------------------------------------------------- test 5c
# A run whose pair is absent must be refused even when the kernel would accept
# the force; the DT gate runs before any write.

t_start "DT gate is evaluated before any write"
mock_setup
dt_make_normal_rows high 3200 3250 3300 3350
arm_expected_status 3040 3000
take_snapshot
sh "$PROBE" full >"$MOCK/out.txt" 2>&1
rc=$?
assert_eq "full refused" "1" "$rc"
assert_zero_writes "refused full run performed zero writes"
assert_file_eq "force_val untouched by the refused run" "0" "$(TERM_DIR_)/force_val"
mock_teardown

# ---------------------------------------------------------------- test 6
# Ownership contract, exercised through the library entry point. This is the
# regression for the original bug: cleanup() used to clear BOTH nodes
# unconditionally, which could wipe an external owner's force.

t_start "cleanup clears only the node the probe owns"
mock_setup
# An external owner holds SHUTDOWN; the probe owns TERM.
printf '1' >"$(SHUT_DIR_)/force_active"
printf '3200' >"$(SHUT_DIR_)/force_val"
printf '1' >"$(TERM_DIR_)/force_active"
printf '3150' >"$(TERM_DIR_)/force_val"
shut_before="$(snapshot_node "$(SHUT_DIR_)")"

DDRC_PROBE_LIB=1 bash -c '
	. "$1"
	OWN_TERM=1
	OWN_SHUT=0
	restore
' _ "$PROBE" >"$MOCK/out.txt" 2>&1

assert_file_eq "probe-owned TERM was cleared" "0" "$(TERM_DIR_)/force_active"
assert_no_write "externally-owned SHUTDOWN was NOT touched" "$(SHUT_DIR_)" "$shut_before"
assert_file_eq "external SHUTDOWN force_val intact" "3200" "$(SHUT_DIR_)/force_val"
mock_teardown

# ---------------------------------------------------------------- test 7
# Both nodes owned -> both cleared, and force_val is never reset.

t_start "cleanup clears both nodes when both are owned"
mock_setup
printf '3150' >"$(TERM_DIR_)/force_val"
printf '3100' >"$(SHUT_DIR_)/force_val"
printf '1' >"$(TERM_DIR_)/force_active"
printf '1' >"$(SHUT_DIR_)/force_active"

DDRC_PROBE_LIB=1 bash -c '
	. "$1"
	OWN_TERM=1
	OWN_SHUT=1
	restore
' _ "$PROBE" >"$MOCK/out.txt" 2>&1

assert_file_eq "TERM cleared" "0" "$(TERM_DIR_)/force_active"
assert_file_eq "SHUTDOWN cleared" "0" "$(SHUT_DIR_)/force_active"
assert_file_eq "force_val is never reset (TERM)" "3150" "$(TERM_DIR_)/force_val"
assert_file_eq "force_val is never reset (SHUTDOWN)" "3100" "$(SHUT_DIR_)/force_val"
mock_teardown

# ---------------------------------------------------------------- test 8
# Nothing owned -> nothing written, even with both nodes showing '1'.

t_start "cleanup with no ownership writes nothing"
mock_setup
printf '1' >"$(TERM_DIR_)/force_active"
printf '1' >"$(SHUT_DIR_)/force_active"
take_snapshot

DDRC_PROBE_LIB=1 bash -c '
	. "$1"
	restore
' _ "$PROBE" >"$MOCK/out.txt" 2>&1

assert_zero_writes "no-ownership restore wrote nothing anywhere"
mock_teardown

# ---------------------------------------------------------------- test 9
# Ownership bookkeeping is file-based and ownership-aware.

t_start "watchdog ownership bookkeeping"
mock_setup
DDRC_PROBE_LIB=1 bash -c '
	. "$1"
	owner_add TERM
	owner_has TERM && echo "owner_has TERM: yes"
	owner_has SHUT || echo "owner_has SHUT: no"
	owner_clear TERM
	owner_has TERM || echo "after clear: no TERM"
' _ "$PROBE" >"$MOCK/owners.txt" 2>&1

grep -q "owner_has TERM: yes" "$MOCK/owners.txt" && ok "owner_add records TERM" || not_ok "owner_add records TERM"
grep -q "owner_has SHUT: no" "$MOCK/owners.txt" && ok "SHUT is not recorded" || not_ok "SHUT is not recorded"
grep -q "after clear: no TERM" "$MOCK/owners.txt" && ok "owner_clear removes TERM" || not_ok "owner_clear removes TERM"
mock_teardown

# ---------------------------------------------------------------- test 10
# Ownership is claimed the moment force_active is written, not after readback,
# so a readback failure still unwinds. Verified by making the readback
# disagree with the requested value.

t_start "ownership is claimed before readback completes"
mock_setup
DDRC_PROBE_LIB=1 bash -c '
	. "$1"
	# Requested 3150 but the mock still reports the stock effective value, so the
	# readback must fail -- yet ownership has already been claimed.
	apply_force "$TERM_VAL" "$TERM_ACT" 3150 TERM
	echo "own_after_apply=$OWN_TERM"
	check_force "$TERM" 3150 && echo "readback=ok" || echo "readback=failed"
	restore
	echo "after_restore_act=$(force_active_of "$TERM")"
' _ "$PROBE" >"$MOCK/out.txt" 2>&1

grep -q "own_after_apply=1" "$MOCK/out.txt" &&
	ok "ownership claimed on successful force_active write" ||
	not_ok "ownership claimed on successful force_active write" "$(cat "$MOCK/out.txt")"
grep -q "readback=failed" "$MOCK/out.txt" &&
	ok "readback correctly detected the mismatch" ||
	not_ok "readback correctly detected the mismatch"
grep -q "after_restore_act=0" "$MOCK/out.txt" &&
	ok "node unwound despite the failed readback" ||
	not_ok "node unwound despite the failed readback" "$(cat "$MOCK/out.txt")"
mock_teardown

suite_summary

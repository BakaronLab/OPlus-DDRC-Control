#!/usr/bin/env bash
# Regression tests for module/common.sh.
#
# These cover the module's own safety gates: the live device tree gate for both
# non-stock profiles, fail-closed behaviour, and the rule that a force this
# module cannot prove it owns is never cleared.
#
# No device is involved; a mock /proc + /sys + device tree is used.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

COMMON="$REPO_ROOT/module/common.sh"

TERM_DIR_() { echo "$DDRC_VOT_ROOT/GAUGE_TERM_VOLTAGE"; }
SHUT_DIR_() { echo "$DDRC_VOT_ROOT/GAUGE_SHUTDOWN_VOLTAGE"; }

# run_common <shell-snippet>: sources common.sh with MODDIR set to the mock and
# runs the snippet. Prints the snippet's own output.
run_common() {
	MODDIR="$MOCK/module" DDRC_VOT_ROOT="$DDRC_VOT_ROOT" DDRC_BAT_ROOT="$DDRC_BAT_ROOT" \
		DDRC_DT_STRAT="$DDRC_DT_STRAT" \
		bash -c '
			MODDIR=$MODDIR
			. "$1"
			shift
			'"$1"'
		' _ "$COMMON" "$1"
}

mock_module_dir() {
	mkdir -p "$MOCK/module"
	printf 'MODE=balanced\n' >"$MOCK/module/config.conf"
}

# ---------------------------------------------------------------- test 1
# dt_has_pair: exact normal-table matching, cold-only pairs must not count.

t_start "dt_has_pair exact matching"
mock_setup
dt_make_standard
out="$(run_common '
	printf "3000/3040 -> "; dt_has_pair 3000 3040 && echo yes || echo no
	printf "3100/3150 -> "; dt_has_pair 3100 3150 && echo yes || echo no
	printf "3200/3250 -> "; dt_has_pair 3200 3250 && echo yes || echo no
	printf "2750/3059 -> "; dt_has_pair 2750 3059 && echo yes || echo no
	printf "9999/9999 -> "; dt_has_pair 9999 9999 && echo yes || echo no
	printf "3000/3100 -> "; dt_has_pair 3000 3100 && echo yes || echo no
')"
assert_eq "3000/3040 found" "3000/3040 -> yes" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "3100/3150 found" "3100/3150 -> yes" "$(printf '%s\n' "$out" | sed -n 2p)"
assert_eq "3200/3250 found" "3200/3250 -> yes" "$(printf '%s\n' "$out" | sed -n 3p)"
assert_eq "cold-only 2750/3059 rejected" "2750/3059 -> no" "$(printf '%s\n' "$out" | sed -n 4p)"
assert_eq "absent pair rejected" "9999/9999 -> no" "$(printf '%s\n' "$out" | sed -n 5p)"
assert_eq "mismatched pairing rejected" "3000/3100 -> no" "$(printf '%s\n' "$out" | sed -n 6p)"
mock_teardown

# ---------------------------------------------------------------- test 2
# profile_dt_ok gates both non-stock profiles and always allows stock.

t_start "profile_dt_ok gates balanced and full"
mock_setup
dt_make_standard
out="$(run_common '
	for m in stock balanced full bogus; do
		printf "%s -> " "$m"; profile_dt_ok "$m" && echo ok || echo rejected
	done
')"
assert_eq "stock always allowed" "stock -> ok" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "balanced allowed when present" "balanced -> ok" "$(printf '%s\n' "$out" | sed -n 2p)"
assert_eq "full allowed when present" "full -> ok" "$(printf '%s\n' "$out" | sed -n 3p)"
assert_eq "unknown profile rejected" "bogus -> rejected" "$(printf '%s\n' "$out" | sed -n 4p)"
mock_teardown

# ---------------------------------------------------------------- test 3
# set_mode balanced with the pair absent -> refused, mode stock, no force left.

t_start "balanced pair absent -> refused and stays stock"
mock_setup
mock_module_dir
dt_make_normal_rows high 3200 3250 3300 3350 # no 3100/3150, no 3000/3040
out="$(run_common '
	set_mode balanced
	echo "rc=$?"
	echo "mode=$(state_read mode)"
	echo "term_act=$(force_active_of "$TERM_NODE") shut_act=$(force_active_of "$SHUT_NODE")"
')"
assert_eq "set_mode refused" "rc=1" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "state mode is stock" "mode=stock" "$(printf '%s\n' "$out" | sed -n 2p)"
assert_eq "no force left active" "term_act=0 shut_act=0" "$(printf '%s\n' "$out" | sed -n 3p)"
mock_teardown

# ---------------------------------------------------------------- test 4
# set_mode full with the pair absent -> refused, mode stock. Critically it must
# NOT fall back to balanced.

t_start "full pair absent -> refused, never downgraded to balanced"
mock_setup
mock_module_dir
dt_make_normal_rows high 3100 3150 3200 3250 # balanced present, full absent
out="$(run_common '
	set_mode full
	echo "rc=$?"
	echo "mode=$(state_read mode)"
	echo "term_act=$(force_active_of "$TERM_NODE") shut_act=$(force_active_of "$SHUT_NODE")"
')"
assert_eq "set_mode refused" "rc=1" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "state mode is stock, not balanced" "mode=stock" "$(printf '%s\n' "$out" | sed -n 2p)"
assert_eq "no force applied" "term_act=0 shut_act=0" "$(printf '%s\n' "$out" | sed -n 3p)"
mock_teardown

# ---------------------------------------------------------------- test 5
# set_mode balanced with everything satisfied -> applies the pair.

t_start "balanced pair present -> applied"
mock_setup
mock_module_dir
dt_make_standard
arm_expected_status 3150 3100
out="$(run_common '
	set_mode balanced
	echo "rc=$?"
	echo "mode=$(state_read mode)"
	echo "term=$(force_val_of "$TERM_NODE") shut=$(force_val_of "$SHUT_NODE")"
	echo "act=$(force_active_of "$TERM_NODE")/$(force_active_of "$SHUT_NODE")"
')"
assert_eq "set_mode succeeded" "rc=0" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "state mode balanced" "mode=balanced" "$(printf '%s\n' "$out" | sed -n 2p)"
assert_eq "balanced values written" "term=3150 shut=3100" "$(printf '%s\n' "$out" | sed -n 3p)"
assert_eq "force active on both" "act=1/1" "$(printf '%s\n' "$out" | sed -n 4p)"
mock_teardown

# ---------------------------------------------------------------- test 6
# Invalid MODE in config resolves to stock.

t_start "invalid config MODE resolves to stock"
mock_setup
mock_module_dir
printf 'MODE=nonsense\n' >"$MOCK/module/config.conf"
out="$(run_common 'echo "mode=$(config_mode)"')"
assert_eq "invalid mode -> stock" "mode=stock" "$out"
printf 'MODE=\n' >"$MOCK/module/config.conf"
out="$(run_common 'echo "mode=$(config_mode)"')"
assert_eq "empty mode -> stock" "mode=stock" "$out"
printf 'MODE=FULL\n' >"$MOCK/module/config.conf"
out="$(run_common 'echo "mode=$(config_mode)"')"
assert_eq "case-sensitive: FULL -> stock" "mode=stock" "$out"
mock_teardown

# ---------------------------------------------------------------- test 7
# external_owner_present and restore_owned: a force this module cannot prove it
# owns must be reported and never cleared.

t_start "external owner is detected and never cleared"
mock_setup
mock_module_dir
dt_make_standard
# Someone else owns SHUTDOWN with a value this module never writes.
printf '1' >"$(SHUT_DIR_)/force_active"
printf '2900' >"$(SHUT_DIR_)/force_val"
shut_before="$(snapshot_node "$(SHUT_DIR_)")"
out="$(run_common '
	external_owner_present && echo "external=yes" || echo "external=no"
	restore_owned
	echo "shut_act=$(force_active_of "$SHUT_NODE")"
')"
assert_eq "external owner detected" "external=yes" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "external force left active" "shut_act=1" "$(printf '%s\n' "$out" | sed -n 2p)"
assert_no_write "external node was not written" "$(SHUT_DIR_)" "$shut_before"
mock_teardown

# ---------------------------------------------------------------- test 8
# A force that matches this module's own recorded value IS cleared.

t_start "module-owned force is cleared on restore"
mock_setup
mock_module_dir
dt_make_standard
arm_expected_status 3150 3100
out="$(run_common '
	apply_profile balanced
	echo "applied_act=$(force_active_of "$SHUT_NODE")"
	restore_owned
	echo "after_act=$(force_active_of "$SHUT_NODE")"
	echo "after_owned=$(state_read owned)"
')"
assert_eq "force applied" "applied_act=1" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "force cleared" "after_act=0" "$(printf '%s\n' "$out" | sed -n 2p)"
assert_eq "ownership flag cleared" "after_owned=0" "$(printf '%s\n' "$out" | sed -n 3p)"
mock_teardown

# ---------------------------------------------------------------- test 9
# headroom: refuse to arm a shutdown threshold too close to the live voltage.

t_start "voltage headroom gate"
mock_setup
mock_module_dir
dt_make_standard
printf '3150' >"$DDRC_BAT_ROOT/gauge_vbat"
out="$(run_common 'headroom_ok 3100 && echo "ok" || echo "refused"')"
assert_eq "3100 vs 3150 mV is refused" "refused" "$out"
printf '4055' >"$DDRC_BAT_ROOT/gauge_vbat"
out="$(run_common 'headroom_ok 3100 && echo "ok" || echo "refused"')"
assert_eq "3100 vs 4055 mV is allowed" "ok" "$out"
mock_teardown

# ---------------------------------------------------------------- test 10
# Device identity gate.

t_start "device identity gate"
mock_setup
mock_module_dir
printf 'silicon_1' >"$DDRC_BAT_ROOT/battery_type"
out="$(run_common 'device_identity_ok && echo ok || echo rejected')"
assert_eq "silicon_1 accepted" "ok" "$out"
printf 'li_ion' >"$DDRC_BAT_ROOT/battery_type"
out="$(run_common 'device_identity_ok && echo ok || echo rejected')"
assert_eq "other battery_type rejected" "rejected" "$out"
mock_teardown

suite_summary

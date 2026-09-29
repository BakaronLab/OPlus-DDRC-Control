#!/usr/bin/env bash
# Shared helpers for the OPlus DDRC Control regression suite.
#
# The suite never touches a real device. Every test builds a throwaway mock of
# the kernel surface under a temp directory and points the scripts at it through
# the DDRC_*_ROOT environment variables.
#
# Sourced by tests/test-*.sh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

PASS_COUNT=0
FAIL_COUNT=0

# ------------------------------------------------------------------ reporting

t_start() {
	printf '\n-- %s\n' "$1"
}

ok() {
	PASS_COUNT=$((PASS_COUNT + 1))
	printf '   PASS  %s\n' "$1"
}

not_ok() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	printf '   FAIL  %s\n' "$1"
	[ $# -gt 1 ] && printf '         %s\n' "$2"
}

assert_eq() {
	# assert_eq <label> <expected> <actual>
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		not_ok "$1" "expected [$2] got [$3]"
	fi
}

assert_file_eq() {
	# assert_file_eq <label> <expected-content> <file>
	if [ ! -f "$3" ]; then
		not_ok "$1" "file $3 does not exist"
		return
	fi
	actual="$(tr -d ' \n\r' <"$3")"
	if [ "$2" = "$actual" ]; then
		ok "$1"
	else
		not_ok "$1" "expected [$2] got [$actual]"
	fi
}

suite_summary() {
	printf '\n== %s: %d passed, %d failed ==\n' "$(basename "$0")" "$PASS_COUNT" "$FAIL_COUNT"
	[ "$FAIL_COUNT" -eq 0 ] || return 1
	return 0
}

# ----------------------------------------------------------------- mock root

# mock_setup: creates $MOCK with a fake kernel surface and stub commands.
mock_setup() {
	MOCK="$(mktemp -d)"
	export MOCK

	export DDRC_VOT_ROOT="$MOCK/proc/oplus-votable"
	export DDRC_BAT_ROOT="$MOCK/sys/class/oplus_chg/battery"
	export DDRC_PWR_ROOT="$MOCK/sys/class/power_supply/battery"
	export DDRC_DT_STRAT="$MOCK/sys/firmware/devicetree/base/soc/oplus,mms_gauge/ddrc_strategy"
	export DDRC_WORKDIR="$MOCK/work"

	mkdir -p "$DDRC_VOT_ROOT/GAUGE_TERM_VOLTAGE" "$DDRC_VOT_ROOT/GAUGE_SHUTDOWN_VOLTAGE"
	mkdir -p "$DDRC_BAT_ROOT" "$DDRC_PWR_ROOT" "$DDRC_WORKDIR" "$DDRC_DT_STRAT"

	# Force-active / force-val start at the healthy STOCK shape.
	for n in GAUGE_TERM_VOLTAGE GAUGE_SHUTDOWN_VOLTAGE; do
		printf '0' >"$DDRC_VOT_ROOT/$n/force_active"
		printf '0' >"$DDRC_VOT_ROOT/$n/force_val"
	done

	# Battery surface good enough for the probe preflight.
	printf 'silicon_1' >"$DDRC_BAT_ROOT/battery_type"
	printf '4055' >"$DDRC_BAT_ROOT/gauge_vbat"
	printf '3250' >"$DDRC_BAT_ROOT/vbat_uv"
	printf '72' >"$DDRC_PWR_ROOT/capacity"
	printf '325' >"$DDRC_PWR_ROOT/temp"
	printf 'Discharging' >"$DDRC_PWR_ROOT/status"

	set_stock_status

	# Stub commands the scripts call that either do not exist on the build host
	# or must not actually run during a test.
	#
	# MOCK_MODEL is reset here on purpose: a test that overrides it must not
	# leak that value into every later test in the same file.
	MOCK_MODEL=PKU110
	export MOCK_MODEL
	STUB_BIN="$MOCK/bin"
	mkdir -p "$STUB_BIN"
	cat >"$STUB_BIN/getprop" <<'EOF'
#!/bin/sh
case "$1" in
ro.product.model) echo "${MOCK_MODEL:-PKU110}" ;;
*) echo "" ;;
esac
EOF
	# setsid does not exist in a minimal container; the probe calls it as
	# `setsid sh -c "..."`, so the stub just replaces the process image with the
	# command it was given. (Dropping the first argument here would turn
	# `setsid sh -c SCRIPT` into `exec -c SCRIPT`, which is not the same thing.)
	cat >"$STUB_BIN/setsid" <<'EOF'
#!/bin/sh
exec "$@"
EOF

	# The hold timings are shortened so the suite stays fast, but the watchdog
	# delay must stay LONG relative to the run, because the watchdog is supposed
	# to fire only if the probe dies without disarming it. Stubbing `sleep` to
	# return instantly would make the watchdog clear the node while the probe is
	# still mid-test -- and then the test would be asserting against a state the
	# product code never produced.
	export DDRC_HOLD_SEC=0
	export DDRC_NOOP_HOLD_SEC=0
	export DDRC_WD_SEC=120

	chmod +x "$STUB_BIN"/*
	export PATH="$STUB_BIN:$PATH"
}

mock_teardown() {
	[ -n "${MOCK:-}" ] && rm -rf "$MOCK"
}

# set_stock_status: rewrite the status files as a stock, unforced device.
set_stock_status() {
	set_stock_status_for GAUGE_TERM_VOLTAGE
	set_stock_status_for GAUGE_SHUTDOWN_VOLTAGE
}

# set_stock_status_for <node>: the OEM voter view for one node.
set_stock_status_for() {
	case "$1" in
	GAUGE_TERM_VOLTAGE)
		cat >"$DDRC_VOT_ROOT/GAUGE_TERM_VOLTAGE/status" <<'EOF'
GAUGE_TERM_VOLTAGE: READY_VOTER:			en=0 v=0
GAUGE_TERM_VOLTAGE: DEEP_COUNT_VOTER:			en=1 v=3250
GAUGE_TERM_VOLTAGE: effective=DEEP_COUNT_VOTER type=Max v=3250
EOF
		;;
	GAUGE_SHUTDOWN_VOLTAGE)
		cat >"$DDRC_VOT_ROOT/GAUGE_SHUTDOWN_VOLTAGE/status" <<'EOF'
GAUGE_SHUTDOWN_VOLTAGE: READY_VOTER:			en=0 v=0
GAUGE_SHUTDOWN_VOLTAGE: SPEC_VOTER:			en=1 v=2750
GAUGE_SHUTDOWN_VOLTAGE: DEEP_COUNT_VOTER:			en=1 v=3200
GAUGE_SHUTDOWN_VOLTAGE: SUPER_ENDURANCE_MODE_VOTER:			en=1 v=3250
GAUGE_SHUTDOWN_VOLTAGE: effective=SUPER_ENDURANCE_MODE_VOTER type=Max v=3250
EOF
		;;
	esac
}

# set_forced_status <term> <shut>: status files as if the force is applied.
set_forced_status() {
	cat >"$DDRC_VOT_ROOT/GAUGE_TERM_VOLTAGE/status" <<EOF
GAUGE_TERM_VOLTAGE: READY_VOTER:			en=0 v=0
GAUGE_TERM_VOLTAGE: DEEP_COUNT_VOTER:			en=1 v=3250
GAUGE_TERM_VOLTAGE: effective=DEBUG_FORCE_CLIENT type=Max v=$1
EOF
	cat >"$DDRC_VOT_ROOT/GAUGE_SHUTDOWN_VOLTAGE/status" <<EOF
GAUGE_SHUTDOWN_VOLTAGE: READY_VOTER:			en=0 v=0
GAUGE_SHUTDOWN_VOLTAGE: SPEC_VOTER:			en=1 v=2750
GAUGE_SHUTDOWN_VOLTAGE: DEEP_COUNT_VOTER:			en=1 v=3200
GAUGE_SHUTDOWN_VOLTAGE: SUPER_ENDURANCE_MODE_VOTER:			en=1 v=3250
GAUGE_SHUTDOWN_VOLTAGE: effective=DEBUG_FORCE_CLIENT type=Max v=$2
EOF
}

# ------------------------------------------------------- kernel emulation

# In the mock, `status` is the KERNEL's output surface: the real driver
# regenerates it whenever force_active/force_val change. A plain file cannot do
# that, and polling cannot win the race against a synchronous readback, so the
# fixture below pre-arms `status` to describe the state a successful force
# would produce (DEBUG_FORCE_CLIENT at the requested value) while force_active
# is still 0.
#
# This keeps the readback deterministic. It does NOT weaken the tests: every
# test that uses it also asserts on the actual bytes of force_val, so a probe
# that wrote the wrong value would still be caught.
#
# `status` is therefore excluded from tree_hash() -- in the mock it is input
# from the kernel's point of view, never something the probe may write.

arm_expected_status() {
	# arm_expected_status <term_mv> <shut_mv>
	set_forced_status "$1" "$2"
}

# ------------------------------------------------------------------ DT mock

# oct_escape <0-255> : the three-digit octal escape for one byte, as text.
oct_escape() {
	printf '\\%03o' "$1"
}

# be32 <decimal>... : emit big-endian u32 cells for the given values.
#
# This deliberately avoids awk's `printf "%c"`. Under a UTF-8 locale that
# writes the *character* U+00xx encoded as UTF-8 (two bytes for anything above
# 0x7f), which silently corrupts the fixture. Shell `printf '%b'` with octal
# escapes produces raw bytes regardless of locale or which awk is installed,
# and mawk -- the default on many runners -- handles "%c" differently again.
be32() {
	for v in "$@"; do
		n=$((v % 4294967296))
		[ "$n" -lt 0 ] && n=$((n + 4294967296))
		printf '%b' "$(oct_escape $(((n / 16777216) % 256)))$(oct_escape $(((n / 65536) % 256)))$(oct_escape $(((n / 256) % 256)))$(oct_escape $((n % 256)))"
	done
}

# dt_make <ratio_name> <temp_name> <v1 v2 v3 ...>: writes a strategy table.
dt_make() {
	ratio="$1"
	temp="$2"
	shift 2
	dir="$DDRC_DT_STRAT/strategy_ratio_range_$ratio"
	mkdir -p "$dir"
	name="strategy_ratio_range_$ratio"
	printf '%s\0' "$name" >"$dir/name"
	be32 "$@" >"$dir/strategy_temp_$temp"
}

# dt_make_normal_rows <ratio> <shutdown term> ... : convenience wrapper that
# emits 4-column rows (index, shutdown, term, i) in the real device tree layout.
dt_make_normal_rows() {
	ratio="$1"
	shift
	args=""
	i=0
	while [ $# -ge 2 ]; do
		args="$args $i $1 $2 $i"
		shift 2
		i=$((i + 1))
	done
	# shellcheck disable=SC2086
	dt_make "$ratio" normal $args
}

# dt_make_standard: the subset of the real PKU110 normal tables that matters.
dt_make_standard() {
	dt_make_normal_rows high 3000 3040 3100 3150 3200 3250 3300 3350
	dt_make_normal_rows mid 3000 3040 3100 3150 3200 3250 3300 3350
	dt_make_normal_rows low 3000 3040 3100 3150 3200 3250 3300 3350
	# a cold-only pair that must never authorise an override
	dt_make high cold 0 2750 3059 0
}

# -------------------------------------------------------------- write probes

# tree_hash <dir> : a fingerprint of the authority surface under <dir> (path,
# size, mtime, content). Used to prove a code path performed zero writes.
#
# `status` files are skipped: in the mock they are the kernel's OUTPUT surface
# (regenerated by the emulator when force_active changes), not something the
# probe is allowed to write. The authority files force_val / force_active and
# the whole battery surface are always included.
tree_hash() {
	[ -d "$1" ] || {
		echo "missing:$1"
		return
	}
	find "$1" -type f ! -name 'status' 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
		printf '%s|' "$f"
		stat -c '%s|%y' "$f" 2>/dev/null
		cksum <"$f" 2>/dev/null
	done
}

# assert_zero_writes <label> : compares the whole mock votable tree (and the
# battery surface) against the snapshot taken before the run.
assert_zero_writes() {
	after="$(tree_hash "$DDRC_VOT_ROOT")$(tree_hash "$DDRC_BAT_ROOT")"
	if [ "$SNAPSHOT" = "$after" ]; then
		ok "$1"
	else
		not_ok "$1" "something under the mock kernel surface was modified"
		diff <(printf '%s\n' "$SNAPSHOT") <(printf '%s\n' "$after") | head -10
	fi
}

# take_snapshot : records the mock kernel surface for assert_zero_writes.
take_snapshot() {
	SNAPSHOT="$(tree_hash "$DDRC_VOT_ROOT")$(tree_hash "$DDRC_BAT_ROOT")"
}

# mtime_of <file> : nanosecond-resolution timestamp used to detect any write.
mtime_of() {
	stat -c '%y' "$1" 2>/dev/null || stat -f '%m.%N' "$1" 2>/dev/null
}

# snapshot_node <dir> : records mtime+content of force_val/force_active.
snapshot_node() {
	stat -c '%y %s' "$1/force_active" 2>/dev/null
	stat -c '%y %s' "$1/force_val" 2>/dev/null
	cat "$1/force_active" 2>/dev/null
	cat "$1/force_val" 2>/dev/null
}

# assert_no_write <label> <node-dir> <before-snapshot>
assert_no_write() {
	after="$(snapshot_node "$2")"
	if [ "$3" = "$after" ]; then
		ok "$1"
	else
		not_ok "$1" "node was modified"
	fi
}

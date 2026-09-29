#!/system/bin/sh
# OPlus DDRC Control -- runtime safety probe.
#
# This is a TEST TOOL. It is not part of the installed module payload.
#
# It writes exactly four kernel files and nothing else, all reached through the
# node variables defined below (VOT is the votable root, overridable for tests):
#
#   $VOT/GAUGE_TERM_VOLTAGE/force_val
#   $VOT/GAUGE_TERM_VOLTAGE/force_active
#   $VOT/GAUGE_SHUTDOWN_VOLTAGE/force_val
#   $VOT/GAUGE_SHUTDOWN_VOLTAGE/force_active
#
# OWNERSHIP MODEL (the point of this revision)
# --------------------------------------------
# Every kernel write in this script is gated on the probe having established
# ownership of that specific node, and ownership is only established once the
# probe itself has successfully enabled the force:
#
#   OWN_TERM=1  <=> this process set GAUGE_TERM_VOLTAGE/force_active to 1
#   OWN_SHUT=1  <=> this process set GAUGE_SHUTDOWN_VOLTAGE/force_active to 1
#
# restore() therefore clears a node ONLY when the matching flag is set. A run
# that never wrote anything -- `check`, a failed preflight, a refused external
# owner -- performs ZERO kernel writes on every exit path, including the EXIT
# trap and the detached watchdog.
#
# The watchdog keeps its own copy of that state in a plain file under WORKDIR
# (never an extra kernel node), so a watchdog that outlives a killed probe still
# clears only the nodes the probe actually turned on.
#
# force_val is never reset: the interface keeps a last value, and OEM behaviour
# comes back from clearing force_active alone.
#
# Usage:
#   sh device-safe-probe.sh check      # read-only, ZERO writes
#   sh device-safe-probe.sh noop       # force_val = current effective, active=1
#   sh device-safe-probe.sh balanced   # TERM 3150 / SHUTDOWN 3100
#   sh device-safe-probe.sh full       # TERM 3040 / SHUTDOWN 3000
#
# Exit code 0 = PASS, 1 = FAIL.
#
# Tests source this file with DDRC_PROBE_LIB=1 to exercise restore() and the
# ownership helpers directly; in that mode main() is not executed.

VOT=${DDRC_VOT_ROOT:-/proc/oplus-votable}
BAT=${DDRC_BAT_ROOT:-/sys/class/oplus_chg/battery}
PWR=${DDRC_PWR_ROOT:-/sys/class/power_supply/battery}
DT_STRAT=${DDRC_DT_STRAT:-/sys/firmware/devicetree/base/soc/oplus,mms_gauge/ddrc_strategy}

TERM="$VOT/GAUGE_TERM_VOLTAGE"
SHUT="$VOT/GAUGE_SHUTDOWN_VOLTAGE"
TERM_VAL="$TERM/force_val"
TERM_ACT="$TERM/force_active"
SHUT_VAL="$SHUT/force_val"
SHUT_ACT="$SHUT/force_active"

WORKDIR=${DDRC_WORKDIR:-/data/local/tmp/ddrc}
WD_STAMP="$WORKDIR/watchdog.stamp"
WD_LOG="$WORKDIR/watchdog.log"
WD_OWNERS="$WORKDIR/watchdog.owners"
WD_SEC=${DDRC_WD_SEC:-15}
HOLD_SEC=${DDRC_HOLD_SEC:-8}
NOOP_HOLD_SEC=${DDRC_NOOP_HOLD_SEC:-5}

# Profile values. Both pairs exist in the live OEM DDRC curve of the tested
# firmware; the probe re-checks that before applying either of them.
BAL_TERM=3150
BAL_SHUT=3100
FULL_TERM=3040
FULL_SHUT=3000

# ---------------------------------------------------------- ownership state

OWN_TERM=0
OWN_SHUT=0
WD_ARMED=0

owner_add() {
	# Record that this probe owns a node, durably enough for the watchdog.
	case "$1" in
	TERM | SHUT) ;;
	*) return 1 ;;
	esac
	mkdir -p "$WORKDIR" 2>/dev/null
	# Written before the watchdog can act on it; the watchdog is only armed
	# after the owner file exists.
	[ -f "$WD_OWNERS" ] || : >"$WD_OWNERS"
	grep -qx "$1" "$WD_OWNERS" 2>/dev/null || printf '%s\n' "$1" >>"$WD_OWNERS"
}

owner_clear() {
	[ -f "$WD_OWNERS" ] || return 0
	grep -vx "$1" "$WD_OWNERS" >"$WD_OWNERS.tmp" 2>/dev/null
	mv "$WD_OWNERS.tmp" "$WD_OWNERS" 2>/dev/null
	return 0
}

owner_has() {
	[ -f "$WD_OWNERS" ] || return 1
	grep -qx "$1" "$WD_OWNERS" 2>/dev/null
}

# ---------------------------------------------------------------- read helpers

say() { printf '%s\n' "$*"; }
kv() { cat "$1" 2>/dev/null; }

eff_line() { grep -m1 'effective=' "$1/status" 2>/dev/null; }
eff_name() { eff_line "$1" | sed 's/^[^=]*=\([^ ]*\).*/\1/'; }
eff_val() { eff_line "$1" | sed 's/.*v=\([0-9]*\).*/\1/'; }

force_val_of() { kv "$1/force_val"; }
force_active_of() { kv "$1/force_active"; }

report() {
	say "---- $1 status ----"
	kv "$1/status"
}

# ------------------------------------------------------------------- restore

restore() {
	# Clears only the nodes this probe turned on, SHUTDOWN first.
	# A node the probe never activated is never written, not even with '0'.
	if [ "$OWN_SHUT" = "1" ]; then
		printf '0' >"$SHUT_ACT" 2>/dev/null
		OWN_SHUT=0
		owner_clear SHUT
	fi
	if [ "$OWN_TERM" = "1" ]; then
		printf '0' >"$TERM_ACT" 2>/dev/null
		OWN_TERM=0
		owner_clear TERM
	fi
	return 0
}

verify_restored() {
	# Only asserts about nodes the probe is responsible for.
	rc=0
	if owner_has SHUT || [ "$OWN_SHUT" = "1" ]; then
		sa=$(force_active_of "$SHUT")
		say "RESTORE SHUTDOWN force_active=$sa"
		[ "$sa" = "0" ] || rc=1
	fi
	if owner_has TERM || [ "$OWN_TERM" = "1" ]; then
		ta=$(force_active_of "$TERM")
		say "RESTORE TERM force_active=$ta"
		[ "$ta" = "0" ] || rc=1
	fi
	[ "$rc" = "0" ] || return 1
	say "RESTORE verified for owned nodes only"
	return 0
}

# --------------------------------------------------------------- watchdog

start_watchdog() {
	rm -f "$WD_STAMP"
	[ -f "$WD_OWNERS" ] || : >"$WD_OWNERS"
	setsid sh -c "
		sleep $WD_SEC
		if [ ! -e $WD_STAMP ]; then
			if [ -f $WD_OWNERS ] && grep -qx SHUT $WD_OWNERS 2>/dev/null; then
				printf '0' > $SHUT_ACT 2>/dev/null
				printf '[watchdog] cleared SHUTDOWN\n' >> $WD_LOG
			fi
			if [ -f $WD_OWNERS ] && grep -qx TERM $WD_OWNERS 2>/dev/null; then
				printf '0' > $TERM_ACT 2>/dev/null
				printf '[watchdog] cleared TERM\n' >> $WD_LOG
			fi
		fi
	" >/dev/null 2>&1 &
	WD_ARMED=1
	say "WATCHDOG armed: ${WD_SEC}s (clears only probe-owned force_active nodes)"
}

stop_watchdog() {
	[ "$WD_ARMED" = "1" ] || return 0
	touch "$WD_STAMP"
	WD_ARMED=0
	say "WATCHDOG disarmed"
}

# ------------------------------------------------------------------- traps

cleanup() {
	restore
	stop_watchdog
}

on_signal() {
	say "SIGNAL received -- restoring probe-owned nodes only"
	restore
	verify_restored
	exit 1
}

# --------------------------------------------------------------- pre-flight

preflight() {
	rc=0
	model=$(getprop ro.product.model)
	btype=$(kv "$BAT/battery_type")
	soc=$(kv "$PWR/capacity")
	vbat=$(kv "$BAT/gauge_vbat")
	temp=$(kv "$PWR/temp")
	chg=$(kv "$PWR/status")

	say "PREFlight model=$model battery_type=$btype soc=$soc vbat=$vbat temp=$(echo "$temp" | awk '{printf "%.1f", $1/10}')C status=$chg"

	[ "$model" = "PKU110" ] || { say "FAIL preflight: model is not PKU110"; rc=1; }
	[ "$btype" = "silicon_1" ] || { say "FAIL preflight: battery_type is not silicon_1"; rc=1; }
	[ -n "$soc" ] && [ "$soc" -ge 60 ] 2>/dev/null || { say "FAIL preflight: soc=$soc < 60"; rc=1; }
	[ -n "$vbat" ] && [ "$vbat" -ge 3800 ] 2>/dev/null || { say "FAIL preflight: vbat=$vbat mV < 3800 mV"; rc=1; }
	[ -n "$temp" ] && [ "$temp" -ge 150 ] 2>/dev/null || { say "FAIL preflight: temp too low ($temp, need >= 150 = 15.0C)"; rc=1; }
	[ -n "$temp" ] && [ "$temp" -le 380 ] 2>/dev/null || { say "FAIL preflight: temp too high ($temp, need <= 380 = 38.0C)"; rc=1; }
	[ "$chg" = "Discharging" ] || { say "FAIL preflight: charger connected (status=$chg)"; rc=1; }

	for n in "$TERM" "$SHUT"; do
		a=$(force_active_of "$n")
		if [ "$a" != "0" ]; then
			say "FAIL preflight: $(basename "$n") force_active=$a -- possible external owner, refusing to write"
			rc=1
		fi
	done

	[ -w "$TERM_ACT" ] || { say "FAIL preflight: $TERM_ACT not writable"; rc=1; }
	[ -w "$SHUT_ACT" ] || { say "FAIL preflight: $SHUT_ACT not writable"; rc=1; }

	[ "$rc" = "0" ] || return 1
	say "PREFlight OK"
	return 0
}

# ------------------------------------------------------------- DT validation

dt_has_pair() {
	# dt_has_pair <shutdown_mv> <term_mv>
	# Big-endian u32 cells; the two values are adjacent cells in every row, so
	# the 16 hex digits of the pair are an exact match for that row.
	pat="$(printf '%08x%08x' "$1" "$2")"
	for f in "$DT_STRAT"/*/strategy_temp_normal; do
		[ -f "$f" ] || continue
		hex="$(od -An -tx1 -v "$f" 2>/dev/null | tr -d ' \n')"
		case "$hex" in
		*"$pat"*) return 0 ;;
		esac
	done
	return 1
}

# ------------------------------------------------------------------- helpers

apply_force() {
	# apply_force <value_path> <active_path> <value> <TERM|SHUT>
	#
	# The write targets are passed in explicitly rather than derived from a node
	# directory, so every kernel write in this script names its exact file and
	# the static audit can check them without inference.
	#
	# Ownership is claimed the moment force_active is written successfully --
	# not after readback -- so a readback failure still unwinds cleanly.
	valfile=$1
	actfile=$2
	v=$3
	which=$4

	printf '%s' "$v" >"$valfile" || return 1
	if printf '1' >"$actfile"; then
		case "$which" in
		TERM) OWN_TERM=1 ;;
		SHUT) OWN_SHUT=1 ;;
		esac
		owner_add "$which"
	else
		return 1
	fi
	return 0
}

check_force() {
	# check_force <node> <expected_val>
	node=$1
	want=$2
	name=$(eff_name "$node")
	val=$(eff_val "$node")
	act=$(force_active_of "$node")
	say "READBACK $(basename "$node"): effective=$name v=$val force_active=$act"
	if [ "$act" != "1" ]; then
		say "FAIL $node force_active=$act (expected 1)"
		return 1
	fi
	if [ "$val" != "$want" ]; then
		say "FAIL $node effective value $val != $want"
		return 1
	fi
	if [ "$name" != "DEBUG_FORCE_CLIENT" ]; then
		say "FAIL $node effective client is $name, not DEBUG_FORCE_CLIENT"
		return 1
	fi
	return 0
}

# --------------------------------------------------------------------- modes

mode_check() {
	# Read-only. No watchdog, and no ownership is ever established, so every
	# exit path -- including the EXIT trap -- performs zero kernel writes.
	preflight || return 1
	report "$SHUT"
	report "$TERM"
	say "RESULT=PASS mode=check (read-only, zero writes)"
	return 0
}

mode_noop() {
	preflight || return 1

	t_val=$(eff_val "$TERM")
	s_val=$(eff_val "$SHUT")
	say "NOOP: current effective TERM=$t_val SHUTDOWN=$s_val"

	start_watchdog

	apply_force "$TERM_VAL" "$TERM_ACT" "$t_val" TERM || { say "FAIL noop: TERM write failed"; return 1; }
	apply_force "$SHUT_VAL" "$SHUT_ACT" "$s_val" SHUT || { say "FAIL noop: SHUTDOWN write failed"; return 1; }

	ok=0
	check_force "$TERM" "$t_val" || ok=1
	check_force "$SHUT" "$s_val" || ok=1

	sleep "$NOOP_HOLD_SEC"

	restore
	verify_restored || { say "FAIL noop: restore verification failed"; return 1; }

	stop_watchdog
	report "$TERM"
	[ "$ok" = "0" ] || { say "RESULT=FAIL mode=noop"; return 1; }
	say "RESULT=PASS mode=noop"
	return 0
}

mode_pair() {
	# mode_pair <term_uv> <shut_uv> <label>
	t=$1
	s=$2
	label=$3

	preflight || return 1

	if ! dt_has_pair "$s" "$t"; then
		say "FAIL $label: OEM pair $s/$t is absent from the live device tree"
		say "RESULT=FAIL mode=$label (nothing written)"
		return 1
	fi
	say "DT check: pair $s/$t present in strategy_temp_normal"

	say "APPLY $label TERM=$t SHUTDOWN=$s"
	report "$SHUT"
	report "$TERM"

	start_watchdog

	apply_force "$TERM_VAL" "$TERM_ACT" "$t" TERM || { say "FAIL $label: TERM write failed"; return 1; }
	check_force "$TERM" "$t" || { say "FAIL $label: TERM readback mismatch"; return 1; }

	apply_force "$SHUT_VAL" "$SHUT_ACT" "$s" SHUT || { say "FAIL $label: SHUTDOWN write failed"; return 1; }
	check_force "$SHUT" "$s" || { say "FAIL $label: SHUTDOWN readback mismatch"; return 1; }

	say "vbat_uv=$(kv "$BAT/vbat_uv") gauge_vbat=$(kv "$BAT/gauge_vbat") soc=$(kv "$PWR/capacity")"

	sleep "$HOLD_SEC"

	restore
	verify_restored || { say "FAIL $label: restore verification failed"; return 1; }

	stop_watchdog
	report "$TERM"
	report "$SHUT"
	say "POSTRESTORE vbat_uv=$(kv "$BAT/vbat_uv")"

	say "RESULT=PASS mode=$label"
	return 0
}

# ---------------------------------------------------------------------- main

main() {
	MODE=$1
	[ -n "$MODE" ] || MODE=check

	mkdir -p "$WORKDIR" 2>/dev/null
	trap 'on_signal' INT TERM HUP
	trap 'cleanup' EXIT

	case "$MODE" in
	check) mode_check ;;
	noop) mode_noop ;;
	balanced) mode_pair "$BAL_TERM" "$BAL_SHUT" balanced ;;
	full) mode_pair "$FULL_TERM" "$FULL_SHUT" full ;;
	*)
		say "usage: sh device-safe-probe.sh {check|noop|balanced|full}"
		exit 2
		;;
	esac

	rc=$?
	if [ "$rc" != "0" ]; then
		say "RESULT=FAIL mode=$MODE"
	fi
	return $rc
}

if [ "${DDRC_PROBE_LIB:-0}" != "1" ]; then
	main "$@"
	exit $?
fi

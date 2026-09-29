#!/system/bin/sh
# OPlus DDRC Control -- runtime safety probe.
#
# This is the ONLY script in this project that writes to kernel nodes. It writes
# exactly four files, and nothing else:
#
#   /proc/oplus-votable/GAUGE_TERM_VOLTAGE/force_val
#   /proc/oplus-votable/GAUGE_TERM_VOLTAGE/force_active
#   /proc/oplus-votable/GAUGE_SHUTDOWN_VOLTAGE/force_val
#   /proc/oplus-votable/GAUGE_SHUTDOWN_VOLTAGE/force_active
#
# Restore always runs in this order, and is idempotent:
#   GAUGE_SHUTDOWN_VOLTAGE/force_active = 0
#   GAUGE_TERM_VOLTAGE/force_active = 0
#
# force_val is never reset to 0: the debug-force interface keeps a last value,
# so only force_active is cleared (clearing active is what restores the OEM
# voters; see scripts/../audit notes).
#
# Safety model:
#   * pre-flight checks run immediately before any write, and again implicitly
#     by refusing to continue when anything looks wrong (FAIL CLOSED)
#   * an EXIT/INT/TERM/HUP trap restores on every exit path
#   * an independent detached watchdog (setsid, so it survives a dead adb
#     session) restores after WD_SEC seconds unless the probe finished cleanly
#
# Usage:
#   sh device-safe-probe.sh check      # read-only, no writes at all
#   sh device-safe-probe.sh noop       # force_val = current effective, active=1
#   sh device-safe-probe.sh balanced   # TERM 3150 / SHUTDOWN 3100
#   sh device-safe-probe.sh full       # TERM 3040 / SHUTDOWN 3000
#
# Exit code 0 = PASS, 1 = FAIL (and the state has been restored either way).

VOT=/proc/oplus-votable
BAT=/sys/class/oplus_chg/battery

TERM="$VOT/GAUGE_TERM_VOLTAGE"
SHUT="$VOT/GAUGE_SHUTDOWN_VOLTAGE"
TERM_VAL="$TERM/force_val"
TERM_ACT="$TERM/force_active"
SHUT_VAL="$SHUT/force_val"
SHUT_ACT="$SHUT/force_active"

WORKDIR=${WORKDIR:-/data/local/tmp/ddrc}
WD_STAMP="$WORKDIR/watchdog.stamp"
WD_LOG="$WORKDIR/watchdog.log"
WD_SEC=${WD_SEC:-15}
HOLD_SEC=${HOLD_SEC:-8}

# Profile values. Both pairs were verified to exist in the live OEM DDRC curve
# of the tested firmware (see audit/live-dt-decoded.md).
BAL_TERM=3150
BAL_SHUT=3100
FULL_TERM=3040
FULL_SHUT=3000

MODE=$1
[ -n "$MODE" ] || MODE=check

say() { printf '%s\n' "$*"; }
kv() { cat "$1" 2>/dev/null; }

# ---------------------------------------------------------------- read helpers

eff_line() {
	grep -m1 'effective=' "$1/status" 2>/dev/null
}

eff_name() {
	eff_line "$1" | sed 's/^[^=]*=\([^ ]*\).*/\1/'
}

eff_val() {
	eff_line "$1" | sed 's/.*v=\([0-9]*\).*/\1/'
}

force_val_of() {
	kv "$1/force_val"
}

force_active_of() {
	kv "$1/force_active"
}

report() {
	say "---- $1 status ----"
	kv "$1/status"
}

# ------------------------------------------------------------------- restore

restore() {
	# Order is deliberate: shutdown first, then termination.
	printf '0' > "$SHUT_ACT" 2>/dev/null
	printf '0' > "$TERM_ACT" 2>/dev/null
}

verify_restored() {
	ta=$(force_active_of "$TERM")
	sa=$(force_active_of "$SHUT")
	say "RESTORE TERM force_active=$ta SHUTDOWN force_active=$sa"
	[ "$ta" = "0" ] && [ "$sa" = "0" ]
}

# --------------------------------------------------------------- watchdog

start_watchdog() {
	rm -f "$WD_STAMP"
	setsid sh -c "
		sleep $WD_SEC
		if [ ! -e $WD_STAMP ]; then
			printf '0' > $SHUT_ACT 2>/dev/null
			printf '0' > $TERM_ACT 2>/dev/null
			printf '[watchdog] fired after ${WD_SEC}s, force_active cleared\n' >> $WD_LOG
		fi
	" >/dev/null 2>&1 &
	WD_PID=$!
	say "WATCHDOG armed: ${WD_SEC}s (only writes the two force_active nodes)"
}

stop_watchdog() {
	touch "$WD_STAMP"
	say "WATCHDOG disarmed"
}

# ------------------------------------------------------------------- traps

cleanup() {
	restore
	stop_watchdog
}

on_signal() {
	say "SIGNAL received -- restoring"
	restore
	verify_restored
	exit 1
}

# --------------------------------------------------------------- pre-flight

preflight() {
	rc=0
	model=$(getprop ro.product.model)
	btype=$(kv "$BAT/battery_type")
	soc=$(kv /sys/class/power_supply/battery/capacity)
	vbat=$(kv "$BAT/gauge_vbat")
	temp=$(kv /sys/class/power_supply/battery/temp)
	chg=$(kv /sys/class/power_supply/battery/status)

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

# ------------------------------------------------------------------- helpers

apply_force() {
	# apply_force <node> <value>
	node=$1
	v=$2
	printf '%s' "$v" > "$node/force_val" || return 1
	printf '1' > "$node/force_active" || return 1
	return 0
}

check_force() {
	# check_force <node> <expected_val> -- verifies the driver reports our force
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
	preflight || return 1
	report "$SHUT"
	report "$TERM"
	say "RESULT=PASS mode=check (read-only)"
	return 0
}

mode_noop() {
	preflight || return 1

	t_val=$(eff_val "$TERM")
	s_val=$(eff_val "$SHUT")
	say "NOOP: current effective TERM=$t_val SHUTDOWN=$s_val"

	start_watchdog

	apply_force "$TERM" "$t_val" || { say "FAIL noop: TERM write failed"; return 1; }
	apply_force "$SHUT" "$s_val" || { say "FAIL noop: SHUTDOWN write failed"; return 1; }

	ok=0
	check_force "$TERM" "$t_val" || ok=1
	check_force "$SHUT" "$s_val" || ok=1

	sleep 5

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

	say "APPLY $label TERM=$t SHUTDOWN=$s"
	report "$SHUT"
	report "$TERM"

	start_watchdog

	apply_force "$TERM" "$t" || { say "FAIL $label: TERM write failed"; return 1; }
	check_force "$TERM" "$t" || { say "FAIL $label: TERM readback mismatch"; return 1; }

	apply_force "$SHUT" "$s" || { say "FAIL $label: SHUTDOWN write failed"; return 1; }
	check_force "$SHUT" "$s" || { say "FAIL $label: SHUTDOWN readback mismatch"; return 1; }

	say "vbat_uv=$(kv "$BAT/vbat_uv") gauge_vbat=$(kv "$BAT/gauge_vbat") soc=$(kv /sys/class/power_supply/battery/capacity)"

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

mkdir -p "$WORKDIR" 2>/dev/null
trap 'on_signal' INT TERM HUP
trap 'cleanup' EXIT

case "$MODE" in
check)
	mode_check
	;;
noop)
	mode_noop
	;;
balanced)
	mode_pair "$BAL_TERM" "$BAL_SHUT" balanced
	;;
full)
	mode_pair "$FULL_TERM" "$FULL_SHUT" full
	;;
*)
	say "usage: sh device-safe-probe.sh {check|noop|balanced|full}"
	exit 2
	;;
esac

rc=$?
if [ "$rc" != "0" ]; then
	say "RESULT=FAIL mode=$MODE"
fi
exit $rc

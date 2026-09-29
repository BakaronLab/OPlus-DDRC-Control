#!/system/bin/sh
# OPlus DDRC Control -- shared runtime logic.
#
# Sourced by service.sh / action.sh / uninstall.sh.
# NEVER sourced by customize.sh: installation must not touch live battery policy.
#
# This file is the only place in the module that writes to kernel nodes, and it
# writes exactly four paths:
#
#   /proc/oplus-votable/GAUGE_TERM_VOLTAGE/force_val
#   /proc/oplus-votable/GAUGE_TERM_VOLTAGE/force_active
#   /proc/oplus-votable/GAUGE_SHUTDOWN_VOLTAGE/force_val
#   /proc/oplus-votable/GAUGE_SHUTDOWN_VOLTAGE/force_active
#
# No other sysfs, procfs, devicetree or partition path is ever written.
# force_val is never reset to 0: the interface keeps a last value, and the OEM
# voters are restored by clearing force_active alone.

VOT=${DDRC_VOT_ROOT:-/proc/oplus-votable}
TERM_NODE="$VOT/GAUGE_TERM_VOLTAGE"
SHUT_NODE="$VOT/GAUGE_SHUTDOWN_VOLTAGE"
TERM_VAL="$TERM_NODE/force_val"
TERM_ACT="$TERM_NODE/force_active"
SHUT_VAL="$SHUT_NODE/force_val"
SHUT_ACT="$SHUT_NODE/force_active"

BAT=${DDRC_BAT_ROOT:-/sys/class/oplus_chg/battery}
DT_STRAT=${DDRC_DT_STRAT:-/sys/firmware/devicetree/base/soc/oplus,mms_gauge/ddrc_strategy}

STATE_DIR="$MODDIR/state"
LOG_FILE="$STATE_DIR/module.log"
LOG_MAX=65536

# Voltage pairs. Both were verified to exist in the live OEM DDRC curve of the
# tested PKU110 firmware before this module was published; see audit/.
BALANCED_TERM=3150
BALANCED_SHUT=3100
FULL_TERM=3040
FULL_SHUT=3000

# Minimum headroom between the forced shutdown threshold and the live battery
# voltage. Applying a shutdown voltage above the current cell voltage would ask
# the gauge to act immediately, so it is refused.
VBAT_HEADROOM_MV=200

log() {
	mkdir -p "$STATE_DIR" 2>/dev/null
	if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null)" -gt "$LOG_MAX" ] 2>/dev/null; then
		mv "$LOG_FILE" "$LOG_FILE.old" 2>/dev/null
	fi
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# ---------------------------------------------------------------- primitives

force_active_of() { cat "$1/force_active" 2>/dev/null | tr -d ' \n'; }
force_val_of() { cat "$1/force_val" 2>/dev/null | tr -d ' \n'; }

eff_name() { grep -m1 'effective=' "$1/status" 2>/dev/null | sed 's/^[^=]*=\([^ ]*\).*/\1/'; }
eff_val() { grep -m1 'effective=' "$1/status" 2>/dev/null | sed 's/.*v=\([0-9]*\).*/\1/'; }

state_read() { cat "$STATE_DIR/$1" 2>/dev/null | tr -d ' \n'; }
state_write() {
	mkdir -p "$STATE_DIR" 2>/dev/null
	printf '%s\n' "$2" > "$STATE_DIR/$1" 2>/dev/null
}

profile_term() {
	case "$1" in
	balanced) echo "$BALANCED_TERM" ;;
	full) echo "$FULL_TERM" ;;
	*) echo "" ;;
	esac
}

profile_shut() {
	case "$1" in
	balanced) echo "$BALANCED_SHUT" ;;
	full) echo "$FULL_SHUT" ;;
	*) echo "" ;;
	esac
}

# ------------------------------------------------------------------ identity

device_identity_ok() {
	[ "$(getprop ro.product.model)" = "PKU110" ] || return 1
	[ "$(cat "$BAT/battery_type" 2>/dev/null | tr -d ' \n')" = "silicon_1" ] || return 1
	return 0
}

votable_nodes_present() {
	[ -r "$TERM_ACT" ] && [ -w "$TERM_ACT" ] && [ -w "$SHUT_ACT" ] && return 0
	return 1
}

wait_for_votables() {
	# wait_for_votables <seconds>
	i=0
	while [ "$i" -lt "$1" ]; do
		votable_nodes_present && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

# ---------------------------------------------------------------- ownership
#
# The module only ever clears a force it can prove it set itself:
#   state/owned == 1, force_active == 1 and force_val == the recorded value.
# Anything else (force_active=1 with a different value, or without our state
# file) is treated as an external owner and left completely untouched.

owns_node() {
	# owns_node <node> <recorded_value>
	# The recorded value is checked first: an empty value must never be able to
	# match an empty readback and be mistaken for ownership.
	[ -n "$2" ] || return 1
	[ "$(state_read owned)" = "1" ] || return 1
	[ "$(force_active_of "$1")" = "1" ] || return 1
	[ "$(force_val_of "$1")" = "$2" ] || return 1
	return 0
}

external_owner_present() {
	# true when some force is active that this module cannot prove it owns
	if [ "$(force_active_of "$TERM_NODE")" = "1" ] && ! owns_node "$TERM_NODE" "$(state_read term)"; then
		return 0
	fi
	if [ "$(force_active_of "$SHUT_NODE")" = "1" ] && ! owns_node "$SHUT_NODE" "$(state_read shut)"; then
		return 0
	fi
	return 1
}

# ------------------------------------------------------------------ restore

restore_owned() {
	# Clears force_active only on nodes this module can prove it owns.
	# Order is deliberate: shutdown first, then termination.
	cleared=0
	if owns_node "$SHUT_NODE" "$(state_read shut)"; then
		printf '0' > "$SHUT_ACT" 2>/dev/null && cleared=1
	fi
	if owns_node "$TERM_NODE" "$(state_read term)"; then
		printf '0' > "$TERM_ACT" 2>/dev/null && cleared=1
	fi
	if [ "$cleared" = "1" ]; then
		state_write owned 0
		log "restore: module-owned force_active cleared (SHUTDOWN then TERM)"
	else
		log "restore: nothing owned by this module, no write performed"
	fi
	return 0
}

# ------------------------------------------------------------------ safety

vbat_mv() { cat "$BAT/gauge_vbat" 2>/dev/null | tr -d ' \n'; }

headroom_ok() {
	# headroom_ok <target_shutdown_mv>
	v=$(vbat_mv)
	[ -n "$v" ] || return 1
	[ "$v" -ge $(($1 + VBAT_HEADROOM_MV)) ] 2>/dev/null || return 1
	return 0
}

dt_has_pair() {
	# dt_has_pair <shutdown_mv> <term_mv>
	# Scans the live device tree DDRC strategy tables for the exact
	# (shutdown, term) pair. Device tree cells are big-endian u32 and the two
	# values are adjacent u32 cells in every row, so the 16 hex digits of the
	# two 4-byte cells are an exact match for that row.
	#
	# Only strategy_temp_normal is scanned. The cold/cool tables legitimately
	# allow lower values (e.g. 2750/3059) as an OEM low-temperature policy; a
	# pair that only appears there must not authorise an override at normal
	# temperature.
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

profile_dt_ok() {
	# profile_dt_ok <stock|balanced|full>
	# Single gate used by both set_mode() and service.sh. STOCK never needs DT
	# evidence because it applies no override.
	case "$1" in
	stock) return 0 ;;
	balanced) dt_has_pair "$BALANCED_SHUT" "$BALANCED_TERM" ;;
	full) dt_has_pair "$FULL_SHUT" "$FULL_TERM" ;;
	*) return 1 ;;
	esac
}

# -------------------------------------------------------------------- apply

apply_profile() {
	# apply_profile <balanced|full>
	mode="$1"
	term="$(profile_term "$mode")"
	shut="$(profile_shut "$mode")"
	[ -n "$term" ] && [ -n "$shut" ] || return 1

	# Record intent before writing anything, so a crash mid-apply is still
	# recognisable as module-owned state.
	state_write mode "$mode"
	state_write term "$term"
	state_write shut "$shut"
	state_write owned 1

	printf '%s' "$term" > "$TERM_VAL" || return 1
	printf '1' > "$TERM_ACT" || return 1
	if [ "$(eff_val "$TERM_NODE")" != "$term" ] || [ "$(force_active_of "$TERM_NODE")" != "1" ]; then
		return 1
	fi

	printf '%s' "$shut" > "$SHUT_VAL" || return 1
	printf '1' > "$SHUT_ACT" || return 1
	if [ "$(eff_val "$SHUT_NODE")" != "$shut" ] || [ "$(force_active_of "$SHUT_NODE")" != "1" ]; then
		return 1
	fi

	log "applied mode=$mode term=$term shutdown=$shut"
	return 0
}

apply_with_rollback() {
	# apply_with_rollback <balanced|full> -- one retry, then fail closed
	mode="$1"
	if apply_profile "$mode"; then
		return 0
	fi
	log "apply mode=$mode failed, retrying once"
	restore_owned
	sleep 1
	if apply_profile "$mode"; then
		return 0
	fi
	log "apply mode=$mode failed twice, rolling back to stock"
	restore_owned
	state_write mode stock
	return 1
}

set_mode() {
	# set_mode <stock|balanced|full> -- full runtime transition, used by action.sh
	#
	# Fail-closed contract: any failed precondition leaves the device with no
	# force applied and mode recorded as stock. A profile that cannot be
	# validated is never downgraded to a different non-stock profile.
	target="$1"
	case "$target" in
	stock)
		restore_owned
		state_write mode stock
		log "mode set to stock"
		return 0
		;;
	balanced | full)
		restore_owned
		if ! device_identity_ok; then
			log "refusing $target: device identity check failed"
			state_write mode stock
			return 1
		fi
		if ! votable_nodes_present; then
			log "refusing $target: votable nodes not present"
			state_write mode stock
			return 1
		fi
		if ! profile_dt_ok "$target"; then
			log "refusing $target: OEM pair $(profile_shut "$target")/$(profile_term "$target") absent from live device tree"
			state_write mode stock
			return 1
		fi
		if ! headroom_ok "$(profile_shut "$target")"; then
			log "refusing $target: battery voltage $(vbat_mv) mV too close to $(profile_shut "$target") mV"
			state_write mode stock
			return 1
		fi
		apply_with_rollback "$target" || {
			state_write mode stock
			return 1
		}
		state_write mode "$target"
		return 0
		;;
	*)
		log "invalid mode '$target', forcing stock"
		restore_owned
		state_write mode stock
		return 1
		;;
	esac
}

config_mode() {
	# Reads MODE= from config.conf. Anything invalid resolves to stock.
	cfg="$MODDIR/config.conf"
	[ -f "$cfg" ] || {
		echo stock
		return
	}
	m="$(grep -m1 '^MODE=' "$cfg" 2>/dev/null | cut -d= -f2 | tr -d ' \r\n')"
	case "$m" in
	stock | balanced | full) echo "$m" ;;
	*) echo stock ;;
	esac
}

config_set_mode() {
	# Persists a new mode into the module's own config.conf.
	cfg="$MODDIR/config.conf"
	[ -f "$cfg" ] || return 1
	if grep -q '^MODE=' "$cfg" 2>/dev/null; then
		sed -i "s/^MODE=.*/MODE=$1/" "$cfg" 2>/dev/null || return 1
	else
		printf 'MODE=%s\n' "$1" >> "$cfg" 2>/dev/null || return 1
	fi
	return 0
}

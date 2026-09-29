#!/system/bin/sh
# OPlus DDRC Control -- late_start service stage.
#
# Runs once per boot and exits; it never stays resident and installs no daemon.
# It waits up to 120 s for the oplus-votable nodes to appear, then applies the
# configured profile. Every failure path rolls back to stock.

MODDIR=${0%/*}
. "$MODDIR/common.sh"

MODE_FROM_CONFIG="$(config_mode)"
log "service: start (config mode=$MODE_FROM_CONFIG)"

if ! wait_for_votables 120; then
	log "service: votable nodes did not appear within 120s, exiting without any write"
	state_write mode "$MODE_FROM_CONFIG"
	exit 0
fi

if ! device_identity_ok; then
	log "service: identity check failed (model=$(getprop ro.product.model) battery_type=$(cat "$BAT/battery_type" 2>/dev/null)), exiting without any write"
	exit 0
fi

if external_owner_present; then
	log "service: an active force this module does not own was found, refusing to touch any node"
	exit 0
fi

MODE="$MODE_FROM_CONFIG"
state_write mode "$MODE"

case "$MODE" in
stock)
	log "service: stock requested, OEM DDRC left untouched"
	;;
balanced | full)
	# Any profile that cannot be validated against this exact device and this
	# exact live device tree stays stock. There is deliberately no fallback
	# from full to balanced: a profile that failed its own gate is not evidence
	# that a different non-stock profile is safe to apply.
	if ! profile_dt_ok "$MODE"; then
		log "service: $MODE rejected, OEM pair $(profile_shut "$MODE")/$(profile_term "$MODE") absent from live device tree; staying stock"
		state_write mode stock
		exit 0
	fi
	if ! headroom_ok "$(profile_shut "$MODE")"; then
		log "service: battery $(vbat_mv) mV has less than ${VBAT_HEADROOM_MV} mV headroom above $(profile_shut "$MODE") mV; staying stock"
		state_write mode stock
		exit 0
	fi
	if apply_with_rollback "$MODE"; then
		log "service: applied mode=$MODE term=$(eff_val "$TERM_NODE") shutdown=$(eff_val "$SHUT_NODE")"
	else
		log "service: apply of $MODE failed; rolled back to stock"
		state_write mode stock
	fi
	;;
*)
	log "service: unreachable mode branch"
	;;
esac

exit 0

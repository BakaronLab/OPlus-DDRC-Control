#!/system/bin/sh
# OPlus DDRC Control -- KernelSU / ReSukiSU Action button handler.
#
# Cycles: stock -> balanced -> full -> stock -> ...
# Each transition first restores whatever this module owns, then applies the
# new state. FULL additionally requires the device identity check and proof
# that the (3000, 3040) pair still exists in the live device tree.
# Any failure ends in stock.

MODDIR=${0%/*}
. "$MODDIR/common.sh"

print_state() {
	echo "GAUGE_TERM_VOLTAGE:     $(eff_name "$TERM_NODE" 2>/dev/null) = $(eff_val "$TERM_NODE") mV  force_active=$(force_active_of "$TERM_NODE")"
	echo "GAUGE_SHUTDOWN_VOLTAGE: $(eff_name "$SHUT_NODE" 2>/dev/null) = $(eff_val "$SHUT_NODE") mV  force_active=$(force_active_of "$SHUT_NODE")"
	echo "vbat=$(vbat_mv) mV"
}

cur="$(state_read mode)"
[ -n "$cur" ] || cur="$(config_mode)"
[ -n "$cur" ] || cur=stock

case "$cur" in
stock) next=balanced ;;
balanced) next=full ;;
full) next=stock ;;
*) next=balanced ;;
esac

echo "Current mode: $cur"
echo "New mode: $next"
echo

if external_owner_present; then
	echo "Result: EXTERNAL OWNER"
	echo "An active force that this module does not own was found."
	echo "Nothing was written. Current state:"
	print_state
	log "action: refused, external owner present"
	exit 1
fi

if [ "$next" = "full" ] || [ "$next" = "balanced" ]; then
	if ! profile_dt_ok "$next"; then
		echo "Result: REJECTED"
		echo "Reason: OEM pair $(profile_shut "$next")/$(profile_term "$next") absent from live DT"
		echo "Fallback: STOCK"
		set_mode stock
		config_set_mode stock
		print_state
		log "action: $next rejected, OEM pair absent from live DT, fell back to stock"
		exit 1
	fi
fi

if set_mode "$next"; then
	config_set_mode "$next"
	echo "Result: OK"
	if [ "$next" = "stock" ]; then
		echo "TERM:     no override (OEM DDRC)"
		echo "SHUTDOWN: no override (OEM DDRC)"
	else
		echo "TERM:     $(profile_term "$next") mV"
		echo "SHUTDOWN: $(profile_shut "$next") mV"
	fi
else
	set_mode stock
	config_set_mode stock
	echo "Result: FAILED (mode '$next' rejected, reverted to stock)"
fi
echo
print_state

if [ "$next" = "full" ]; then
	echo
	echo "NOTE: FULL_OEM is experimental. It reapplies a low-voltage window taken"
	echo "from this firmware's OEM DDRC curve; it has not been validated for the"
	echo "long-term behaviour of an aged cell. See the module README."
fi

exit 0

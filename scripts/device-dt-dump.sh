#!/system/bin/sh
# OPlus DDRC Control -- read-only live device tree dump.
#
# Dumps every property of the OPlus gauge / DDRC device tree node as hex so it
# can be decoded offline (device tree u32 cells are big-endian). Performs ZERO
# writes.
#
# Run as root on the device:
#   su -c 'sh device-dt-dump.sh'

DT=/sys/firmware/devicetree/base
NODE="$DT/soc/oplus,mms_gauge"

dump() {
	[ -e "$1" ] || { echo "@@missing $1"; return; }
	echo "@@file $1"
	printf '@@bytes %s\n' "$(wc -c < "$1" 2>/dev/null)"
	od -An -tx1 -v "$1" 2>/dev/null | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

if [ ! -d "$NODE" ]; then
	echo "@@error gauge node not found at $NODE"
	echo "@@hint: /proc/device-tree may be a symlink; this script uses the real path"
	exit 1
fi

# The DDRC curve data lives in sub-nodes (deep_spec,ddbc_curve,
# ddrc_strategy/strategy_ratio_range_*), so the walk must be recursive.
find "$NODE" -type f 2>/dev/null | sort | while read -r f; do
	dump "$f"
done

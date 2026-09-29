#!/system/bin/sh
# OPlus DDRC Control -- installer customization.
#
# This script is SOURCED by the KernelSU / ReSukiSU installer after the module
# files have been extracted to $MODPATH. It runs in the installer's BusyBox ash.
#
# It is allowed to: check the device, choose a profile, write config.conf and
# fix file permissions. It must NOT touch the votable nodes -- installing the
# ZIP never changes live battery policy; that only happens at boot (service.sh)
# or when the Action button is pressed.

ui_print "- OPlus DDRC Control"

# ------------------------------------------------------------- environment

[ -n "$MODPATH" ] || abort "MODPATH is not set (not running under a KernelSU installer?)"
[ -n "$API" ] || API=0
ui_print "- installer: KSU=${KSU:-?} KSU_VER=${KSU_VER:-?} API=$API ARCH=${ARCH:-?}"

if [ "$API" -lt 30 ] 2>/dev/null; then
	ui_print "! Android API $API is older than the tested platform (API 36)"
	ui_print "! continuing is not supported by the author -- aborting"
	abort "unsupported Android API level"
fi

# ------------------------------------------------------------ device check

MODEL="$(getprop ro.product.model)"
BTYPE="$(cat /sys/class/oplus_chg/battery/battery_type 2>/dev/null | tr -d ' \r\n')"
ui_print "- device: model=$MODEL battery_type=${BTYPE:-unknown}"

if [ "$MODEL" != "PKU110" ]; then
	ui_print "! this module was only tested on PKU110 (OPPO/OnePlus OPlus platform)"
	ui_print "! refusing to install on model '$MODEL'"
	abort "unsupported device"
fi

if [ "$BTYPE" != "silicon_1" ]; then
	ui_print "! expected battery_type silicon_1, found '${BTYPE:-none}'"
	abort "unsupported battery type"
fi

# ------------------------------------------------------- profile selection
#
# KernelSU does not provide volume-key state to customize.sh (unlike Magisk),
# so this is implemented with getevent. Access to /dev/input from the installer
# context is not guaranteed, and a missing key is not an error: every unknown
# outcome falls back to BALANCED. FULL_OEM is never selected automatically.

KEY_TIMEOUT=8

run_getevent() {
	if command -v timeout >/dev/null 2>&1; then
		timeout "$KEY_TIMEOUT" getevent -lq 2>/dev/null
	else
		getevent -lq 2>/dev/null &
		ge=$!
		sleep "$KEY_TIMEOUT"
		kill "$ge" 2>/dev/null
		wait "$ge" 2>/dev/null
	fi
}

detect_key_selection() {
	if ! command -v getevent >/dev/null 2>&1; then
		echo unavailable
		return
	fi
	if [ ! -r /dev/input/event0 ]; then
		echo unavailable
		return
	fi
	out="$(run_getevent)"
	case "$out" in
	*KEY_VOLUMEUP*) echo up ;;
	*KEY_VOLUMEDOWN*) echo down ;;
	*) echo none ;;
	esac
}

MODE=balanced
ui_print "- select a profile within ${KEY_TIMEOUT}s:"
ui_print "    Volume DOWN -> STOCK    (OEM DDRC, no override)"
ui_print "    Volume UP   -> FULL_OEM (experimental, 3000/3040)"
ui_print "    no key      -> BALANCED (default, 3100/3150)"

SELECTION="$(detect_key_selection)"
case "$SELECTION" in
up)
	MODE=full
	ui_print "- Volume key detected: FULL_OEM selected"
	;;
down)
	MODE=stock
	ui_print "- Volume key detected: STOCK selected"
	;;
none)
	ui_print "- no volume key pressed within ${KEY_TIMEOUT}s: BALANCED"
	;;
*)
	ui_print "- Install-time key selection unavailable. Defaulting to BALANCED."
	;;
esac

# --------------------------------------------------------------- config

{
	echo "# OPlus DDRC Control configuration"
	echo "#"
	echo "# MODE=stock     no override, OEM DDRC is left alone"
	echo "# MODE=balanced  GAUGE_TERM_VOLTAGE=3150 / GAUGE_SHUTDOWN_VOLTAGE=3100 (default)"
	echo "# MODE=full      GAUGE_TERM_VOLTAGE=3040 / GAUGE_SHUTDOWN_VOLTAGE=3000 (experimental)"
	echo "#"
	echo "# Read once per boot by service.sh; the Action button rewrites this file."
	echo "# Any other value is treated as stock."
	echo "MODE=$MODE"
} > "$MODPATH/config.conf" || abort "cannot write config.conf"

ui_print "- config.conf written with MODE=$MODE"

# ------------------------------------------------------------ permissions

for f in service.sh action.sh uninstall.sh common.sh; do
	[ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done

ui_print "- install complete (runtime override is applied on the next boot)"

#!/system/bin/sh
# OPlus DDRC Control -- read-only device audit.
#
# This script performs ZERO writes. It only reads sysfs / procfs / devicetree
# and prints a key=value report on stdout. It is safe to run at any time,
# including on a fully stock device.
#
# Run as root on the device:
#   su -c 'sh device-readonly-audit.sh'

BAT=/sys/class/oplus_chg/battery
COM=/sys/class/oplus_chg/common
VOT=/proc/oplus-votable

kv() {
	# kv <path> <label>
	if [ -r "$1" ]; then
		printf '%s=%s\n' "$2" "$(cat "$1" 2>/dev/null)"
	else
		printf '%s=<unavailable>\n' "$2"
	fi
}

echo "== device =="
printf 'model=%s\n' "$(getprop ro.product.model)"
printf 'device=%s\n' "$(getprop ro.product.device)"
printf 'vendor_name=%s\n' "$(getprop ro.product.vendor.name)"
printf 'android_release=%s\n' "$(getprop ro.build.version.release)"
printf 'build_incremental=%s\n' "$(getprop ro.build.version.incremental)"
printf 'oplusrom=%s\n' "$(getprop ro.build.version.oplusrom)"
printf 'display_id=%s\n' "$(getprop ro.build.display.id)"
printf 'kernel_release=%s\n' "$(uname -r)"
printf 'effective_uid=%s\n' "$(id -u)"
printf 'selinux_context=%s\n' "$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0')"

echo
echo "== battery (read-only) =="
for f in battery_type battery_cc battery_fcc battery_ui_cc battery_soh \
	battery_ui_soh battery_rm vbat_uv gauge_vbat chip_soc design_capacity \
	battery_chem_id battery_first_usage_date battery_manu_date \
	battery_seal_flag battery_used_flag dual_cells_batt_health; do
	kv "$BAT/$f" "battery.$f"
done
kv /sys/class/power_supply/battery/capacity power_supply.capacity
kv /sys/class/power_supply/battery/voltage_now power_supply.voltage_now
kv /sys/class/power_supply/battery/temp power_supply.temp
kv /sys/class/power_supply/battery/status power_supply.status
kv /sys/class/power_supply/battery/current_now power_supply.current_now

echo
echo "== deep discharge counters (read-only, never written by this project) =="
kv "$COM/deep_dischg_counts" common.deep_dischg_counts
kv "$COM/deep_dischg_count_cali" common.deep_dischg_count_cali
kv "$COM/deep_dischg_ratio_thr" common.deep_dischg_ratio_thr
kv "$COM/super_endurance_mode_status" common.super_endurance_mode_status
kv "$COM/super_endurance_mode_count" common.super_endurance_mode_count

echo
echo "== votable status (read-only) =="
for v in GAUGE_TERM_VOLTAGE GAUGE_SHUTDOWN_VOLTAGE TARGET_TERM_VOLTAGE TARGET_SHUTDOWN_VOLTAGE; do
	kv "$VOT/$v/status" "votable.$v.status"
done

echo
echo "== votable debug-force interface (read-only, no writes in this script) =="
for v in GAUGE_TERM_VOLTAGE GAUGE_SHUTDOWN_VOLTAGE; do
	kv "$VOT/$v/force_val" "votable.$v.force_val"
	kv "$VOT/$v/force_active" "votable.$v.force_active"
done

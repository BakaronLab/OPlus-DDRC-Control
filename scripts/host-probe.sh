#!/usr/bin/env bash
# Host-side (PC) driver for the on-device OPlus DDRC safety probe.
#
#   scripts/host-probe.sh check
#   scripts/host-probe.sh noop
#   scripts/host-probe.sh balanced
#   scripts/host-probe.sh full
#
# It refuses to run unless exactly one adb device is attached and reachable,
# then pushes the read-only / probe scripts to /data/local/tmp/ddrc and runs
# them as root.
#
# Two layers of restore protection are armed before the first kernel write:
#   1. the on-device detached watchdog inside device-safe-probe.sh (setsid),
#   2. a host-side watchdog opened over a second adb connection, which clears
#      the same two force_active nodes unless the device-side disarm stamp
#      exists.
#
# Raw probe output is written to audit/raw/ (gitignored) and never committed.

set -euo pipefail

# This driver runs from Git Bash on Windows: stop MSYS from rewriting the
# on-device absolute paths (/proc/..., /data/...) into Windows paths.
export MSYS_NO_PATHCONV=1

mode="${1:-check}"
case "$mode" in
	check|noop|balanced|full) ;;
	*)
		echo "usage: host-probe.sh {check|noop|balanced|full}" >&2
		exit 2
		;;
esac

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
raw_dir="$repo_root/audit/raw"
mkdir -p "$raw_dir"

workdir=/data/local/tmp/ddrc
shut_act=/proc/oplus-votable/GAUGE_SHUTDOWN_VOLTAGE/force_active
term_act=/proc/oplus-votable/GAUGE_TERM_VOLTAGE/force_active

device_count=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
if [ "$device_count" != "1" ]; then
	echo "FAIL: expected exactly 1 adb device in state 'device', found $device_count" >&2
	adb devices >&2
	exit 1
fi

echo "== pushing scripts =="
adb shell "su -c 'mkdir -p $workdir && chmod 777 $workdir'" >/dev/null
for f in device-safe-probe.sh device-readonly-audit.sh device-dt-dump.sh; do
	adb push "$(cygpath -w "$repo_root/scripts/$f")" "$workdir/$f" >/dev/null
done
adb shell "su -c 'rm -f $workdir/device-safe-probe $workdir/device-readonly-audit $workdir/device-dt-dump'" >/dev/null 2>&1 || true

stamp="$workdir/watchdog.stamp"
adb shell "su -c 'rm -f $stamp'" >/dev/null

host_watchdog() {
	# Second, independent restore layer. Only ever clears force_active.
	adb shell "su -c 'sleep 45; if [ ! -e $stamp ]; then printf 0 > $shut_act; printf 0 > $term_act; echo \"[host-watchdog] fired\" ; fi'" \
		>>"$raw_dir/host-watchdog.log" 2>&1
}

echo "== arming host-side watchdog (45s) =="
host_watchdog &
host_wd_pid=$!

out="$raw_dir/probe-$mode-$(date +%Y%m%d-%H%M%S).txt"
echo "== running probe: $mode =="
set +e
MSYS_NO_PATHCONV=1 adb shell "su -c 'sh $workdir/device-safe-probe.sh $mode'" 2>&1 | tee "$out"
rc=${PIPESTATUS[0]}
set -e

echo "== disarming host-side watchdog =="
kill "$host_wd_pid" 2>/dev/null || true
adb shell "su -c 'touch $stamp'" >/dev/null

echo
echo "---- final state (independent read) ----"
adb shell "su -c 'echo TERM_force_active=\$(cat $term_act); echo SHUT_force_active=\$(cat $shut_act)'"

echo "raw log: ${out#$repo_root/}"
exit "$rc"

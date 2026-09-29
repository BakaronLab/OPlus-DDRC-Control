#!/system/bin/sh
# OPlus DDRC Control -- module uninstall handler.
#
# KernelSU / ReSukiSU marks a module for removal and removes the directory on
# the next boot; uninstall.sh is executed in that removal pass. So this can run
# long after the user pressed "uninstall", and the runtime force it clears may
# already be gone (kernel state does not survive a reboot).
#
# It clears only force_active entries this module can prove it owns, in the
# order SHUTDOWN then TERM. It never writes force_val, never touches
# deep_dischg_counts and never touches a partition.

MODDIR=${0%/*}
. "$MODDIR/common.sh"

log "uninstall: handler invoked"
restore_owned
state_write mode stock

exit 0

#!/usr/bin/env bash
# Runs the whole regression suite. No device is involved.
#
#   sh tests/run-all.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0
for t in "$HERE"/test-*.sh; do
	[ -f "$t" ] || continue
	bash "$t" || rc=1
done

echo
if [ "$rc" -eq 0 ]; then
	echo "tests: PASS"
else
	echo "tests: FAIL"
fi
exit "$rc"

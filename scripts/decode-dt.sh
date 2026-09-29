#!/usr/bin/env bash
# PC-side decoder for the output of scripts/device-dt-dump.sh.
#
# Device tree cells are big-endian u32. This script prints, for every dumped
# property, the decoded u32 array and (when the whole payload is printable
# ASCII) the string form.
#
# Usage: scripts/decode-dt.sh audit/raw/dt-dump.txt

set -eu

in="${1:?usage: decode-dt.sh <dt-dump-file>}"

awk '
function hexval(c) {
	return index("0123456789abcdef", tolower(c)) - 1
}
function decode(   i, v, s, printable, out, cnt) {
	printf "## %s\n", path
	if (nbytes == 0) {
		printf "  <empty>\n\n"
		return
	}
	printable = 1
	for (i = 1; i <= nbytes; i++) {
		v = hexval(substr(raw[i], 1, 1)) * 16 + hexval(substr(raw[i], 2, 1))
		byte[i - 1] = v
		if (v != 0 && (v < 32 || v > 126)) printable = 0
	}
	printf "  bytes=%d\n", nbytes
	if (nbytes % 4 == 0) {
		cnt = 0
		out = ""
		for (i = 0; i + 3 < nbytes; i += 4) {
			v = byte[i] * 16777216 + byte[i+1] * 65536 + byte[i+2] * 256 + byte[i+3]
			out = out sprintf("%d ", v)
			cnt++
		}
		printf "  u32[%d]=%s\n", cnt, out
	}
	if (printable) {
		s = ""
		for (i = 0; i < nbytes; i++) if (byte[i] != 0) s = s sprintf("%c", byte[i])
		printf "  ascii=\"%s\"\n", s
	}
	printf "\n"
}
/^@@file / {
	if (path != "") decode()
	path = $2
	nbytes = 0
	next
}
/^@@bytes / { next }
/^@@/ { next }
{
	for (i = 1; i <= NF; i++) raw[++nbytes] = $i
}
END { if (path != "") decode() }
' "$in"

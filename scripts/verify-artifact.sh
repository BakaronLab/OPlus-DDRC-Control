#!/usr/bin/env bash
# Verify a built module ZIP against everything the project promises about it.
#
# Usage: verify-artifact.sh <path-to.zip> [--expect-dist-hash]
#
# The checks are chosen so that they mean the same thing on every host. Archive
# *bytes* are not compared, because the deflate output depends on the zlib the
# local zip(1) links against; requiring byte equality would make CI red for a
# reason that has nothing to do with the module. What is checked instead is
# everything a user actually depends on:
#
#   1. the file is a real ZIP, not a tar that was renamed
#   2. the entry set is exactly the module payload, at the ZIP root
#   3. nothing forbidden ships (no images, no kernel objects, no system/ tree)
#   4. every entry's recorded permission is the canonical 755/*.sh, 644/other
#   5. every entry's *content* is byte-identical to module/ in the working tree
#
# Check 5 is what keeps dist/ honest: it proves the committed artifact still
# describes the sources sitting next to it.

set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 1

zip_path="${1:-}"
expect_hash=0
for arg in "$@"; do
	[ "$arg" = "--expect-dist-hash" ] && expect_hash=1
done

if [ -z "$zip_path" ] || [ ! -f "$zip_path" ]; then
	echo "FAIL: no such archive: ${zip_path:-<not given>}" >&2
	exit 1
fi

fail=0
ok() { printf '  ok: %s\n' "$*"; }
bad() {
	printf '  FAIL: %s\n' "$*" >&2
	fail=1
}

echo "== verifying $zip_path =="

# --------------------------------------------------------------- 1. real ZIP
magic="$(od -An -tx1 -N4 "$zip_path" 2>/dev/null | tr -d ' \n')"
if [ "$magic" = "504b0304" ]; then
	ok "file is a ZIP archive"
else
	# Nothing below can be trusted if this is not a ZIP.
	bad "not a ZIP archive (magic bytes: ${magic:-unreadable})"
	echo "verify-artifact: FAIL"
	exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
	echo "FAIL: unzip is required to verify the artifact" >&2
	exit 1
fi

# ------------------------------------------------------- 2. expected contents
expected="action.sh common.sh config.conf customize.sh module.prop service.sh skip_mount uninstall.sh"
actual="$(unzip -Z1 "$zip_path" 2>/dev/null | sed 's|/$||' | sort)"

if [ "$actual" = "$(printf '%s\n' $expected | sort)" ]; then
	ok "entry set is exactly the module payload"
else
	bad "entry set does not match the module payload"
	printf '      expected: %s\n' "$(printf '%s ' $expected)"
	printf '      actual:   %s\n' "$(printf '%s ' $actual)"
fi

if printf '%s\n' "$actual" | grep -qE '^(OPlus-DDRC-Control|module)/'; then
	bad "archive has a wrapper directory; the installer needs a flat root"
else
	ok "entries sit at the ZIP root with no wrapper directory"
fi

# ------------------------------------------------------------ 3. nothing bad
forbidden="$(printf '%s\n' "$actual" |
	grep -E '\.(img|dtbo|bin|ko|so)$|^system/|^vendor/|^product/|^odm/|^system_ext/|^my_product/|^persist/|^metadata/' || true)"
if [ -n "$forbidden" ]; then
	bad "forbidden entry in archive: $(printf '%s ' $forbidden)"
else
	ok "no image, kernel object or partition tree ships"
fi

# ------------------------------------------------------------ 4. permissions
# A mode-less build host (Windows drive, some container mounts) makes chmod a
# no-op, and zip then records 0777 for everything. Catch that here rather than
# in the installer.
bad_modes=""
while read -r mode entry; do
	[ -n "${entry:-}" ] || continue
	case "$entry" in
	*.sh) want="-rwxr-xr-x" ;;
	*) want="-rw-r--r--" ;;
	esac
	[ "$mode" = "$want" ] || bad_modes="$bad_modes $entry=$mode"
done <<EOF
$(unzip -Z -l "$zip_path" 2>/dev/null | awk '$1 ~ /^-/ {print $1, $NF}')
EOF

if [ -n "$bad_modes" ]; then
	bad "entry permissions are not the canonical 755/644:$bad_modes"
else
	ok "permissions are 755 for scripts and 644 for everything else"
fi

# --------------------------------------------------------- 5. content matches
tmp="$(mktemp -d 2>/dev/null)" || tmp=""
if [ -z "$tmp" ]; then
	bad "could not create a temporary directory to compare contents"
else
	# Resolve to an absolute path before cd-ing away from the repo root.
	abs_zip="$(cd "$(dirname "$zip_path")" && pwd)/$(basename "$zip_path")"
	if ! (cd "$tmp" && unzip -qq "$abs_zip"); then
		bad "archive could not be extracted"
	else
		diff_out="$(diff -r "$tmp" module 2>&1 || true)"
		if [ -z "$diff_out" ]; then
			ok "contents are byte-identical to module/"
		else
			bad "contents differ from module/"
			printf '%s\n' "$diff_out" | sed 's/^/      /'
		fi
	fi
	rm -rf "$tmp"
fi

# ------------------------------------------------------- 6. published hash
if [ "$expect_hash" = "1" ]; then
	if [ ! -f dist/SHA256SUMS ]; then
		bad "dist/SHA256SUMS is missing"
	elif (cd dist && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
		ok "dist/SHA256SUMS matches the artifact"
	else
		bad "dist/SHA256SUMS does not describe this artifact"
	fi
fi

echo
if [ "$fail" = "0" ]; then
	echo "verify-artifact: PASS"
else
	echo "verify-artifact: FAIL"
fi
exit "$fail"

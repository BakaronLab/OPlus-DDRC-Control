#!/usr/bin/env bash
# Builds dist/OPlus-DDRC-Control-<version>.zip from module/ and writes
# dist/SHA256SUMS.
#
# The module payload must sit at the ZIP root (module.prop, customize.sh, ...),
# with no extra directory level, because that is what the KernelSU / ReSukiSU
# installer expects.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -n 's/^version=//p' "$repo_root/module/module.prop")"
[ -n "$version" ] || {
	echo "FAIL: cannot read version from module/module.prop" >&2
	exit 1
}

name="OPlus-DDRC-Control-$version"
dist="$repo_root/dist"
stage="$dist/stage/$name"
zip_path="$dist/$name.zip"

rm -rf "$dist/stage"
mkdir -p "$stage"

cp "$repo_root/module/"* "$stage/"

# Byte-level CR check (grep with a raw CR pattern is unreliable under MSYS).
while IFS= read -r f; do
	if od -An -tx1 -v "$f" 2>/dev/null | tr ' ' '\n' | grep -qx '0d'; then
		echo "FAIL: CRLF line endings found in staged file: $f" >&2
		exit 1
	fi
done < <(find "$stage" -type f | sort)

find "$stage" -name '*.sh' -exec chmod 755 {} +
chmod 644 "$stage/module.prop" "$stage/config.conf" "$stage/skip_mount"

rm -f "$zip_path"

# bsdtar (shipped with Windows) can write ZIP archives; Git Bash has no zip(1).
# Entries must be stored by bare name: a leading "./" makes the KernelSU /
# ReSukiSU installer fail with "specified file not found in archive".
tar_bin=/c/Windows/System32/tar.exe
[ -x "$tar_bin" ] || tar_bin="$(command -v tar)"

(cd "$stage" && "$tar_bin" -a -c -f "$(cygpath -w "$zip_path")" $(ls -1))

echo "built: dist/$name.zip"
echo "contents:"
(cd "$stage" && ls -1)

sha256sum "$zip_path" | awk -v n="$name.zip" '{print $1 "  " n}' >"$dist/SHA256SUMS"
cat "$dist/SHA256SUMS"

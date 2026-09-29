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
zip_path="$dist/$name.zip"

# ZIP records Unix permissions per entry, and zip(1) copies them from the
# staging filesystem. On a filesystem that cannot represent them -- Windows
# drives under MSYS/Git Bash, many container mounts -- every file reads as 0777,
# so the chmod calls below are a silent no-op and the module would ship
# world-writable. Probe the staging parent and move staging elsewhere when it
# cannot hold modes.
mode_capable() {
	[ -d "$1" ] || return 1
	probe="$1/.ddrc-mode-probe"
	: >"$probe" 2>/dev/null || return 1
	chmod 640 "$probe" 2>/dev/null
	perms="$(ls -l "$probe" 2>/dev/null | cut -c1-10)"
	rm -f "$probe"
	[ "$perms" = "-rw-r-----" ]
}

stage_root="$dist/stage"
stage_tmp=""
if ! mode_capable "$dist"; then
	if stage_tmp="$(mktemp -d 2>/dev/null)" && mode_capable "$stage_tmp"; then
		stage_root="$stage_tmp"
		echo "note: $dist cannot store Unix modes; staging in $stage_tmp"
	else
		[ -n "$stage_tmp" ] && rm -rf "$stage_tmp"
		stage_tmp=""
		echo "WARN: no mode-capable filesystem available; every archive entry" >&2
		echo "      will carry 0777. Do not publish an artifact built here." >&2
	fi
fi

stage="$stage_root/$name"

rm -rf "$dist/stage"
mkdir -p "$stage"

# A deprecated build must not linger in dist/: users could flash the older,
# unsafe revision. Only the artifact matching module.prop version is kept.
for old in "$dist"/OPlus-DDRC-Control-*.zip; do
	[ -e "$old" ] || continue
	[ "$old" = "$zip_path" ] && continue
	echo "removing superseded artifact: $(basename "$old")"
	rm -f "$old"
done

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

# Pin every entry's timestamp. ZIP records an MS-DOS mtime, so without this the
# archive bytes -- and therefore the published SHA256 -- would change on every
# build even when no file content changed.
find "$stage" -exec touch -t 202601010000 {} +

rm -f "$zip_path"

# Produce a real ZIP archive. The KernelSU / ReSukiSU installer reads ZIP
# central-directory metadata, so a uStar tar with a .zip name is not good
# enough -- and GNU tar produces exactly that even when passed -a, because -a
# keys off the file suffix only for the bsdtar shipped with Windows.
#
# Entries must be stored by bare name: a leading "./" makes the installer fail
# with "specified file not found in archive".
make_zip() {
	if command -v zip >/dev/null 2>&1; then
		# Info-ZIP (Linux, and macOS in most setups). -X drops extra file
		# attributes, -q keeps the log quiet.
		# shellcheck disable=SC2046
		(cd "$stage" && zip -q -X -r "$archive_path" $(ls -1))
		return $?
	fi

	# No zip(1): fall back to the bsdtar shipped with Windows. It writes a real
	# ZIP, but a different one -- the writer identity is part of the bytes, so
	# the resulting hash will not match the artifact CI rebuilds.
	echo "NOTE: zip(1) not found; using tar. The archive will work but its" >&2
	echo "      bytes will differ from the artifact committed by CI." >&2

	local_tar=/c/Windows/System32/tar.exe
	[ -x "$local_tar" ] || local_tar="$(command -v tar)"
	# shellcheck disable=SC2046
	(cd "$stage" && "$local_tar" -a -c -f "$archive_path" $(ls -1))
}

# cygpath only exists under MSYS/Cygwin. On a POSIX host the path is already
# usable, and a MSYS-style /c/... path would be rejected by a native tool.
if command -v cygpath >/dev/null 2>&1; then
	archive_path="$(cygpath -w "$zip_path")"
else
	archive_path="$zip_path"
fi

make_zip || {
	echo "FAIL: could not create the archive" >&2
	exit 1
}

echo "built: dist/$name.zip"
echo "contents:"
(cd "$stage" && ls -1)
echo

# Verify the artifact before publishing it. This is what makes the build
# portable: it fails loudly on a host whose tar silently produced a uStar
# archive under a .zip name, or whose filesystem could not store Unix modes so
# the chmod above changed nothing.
if ! bash "$repo_root/scripts/verify-artifact.sh" "dist/$name.zip"; then
	echo "FAIL: the archive did not pass verification; not publishing it" >&2
	[ -n "$stage_tmp" ] && rm -rf "$stage_tmp"
	rm -f "$zip_path"
	exit 1
fi

# Record the hash of the bare file name, as it is published. The entry is
# checked from inside dist/ because that is where the file actually sits.
(
	cd "$dist"
	sha256sum "$name.zip" | awk -v n="$name.zip" '{print $1 "  " n}' >SHA256SUMS
	echo
	cat SHA256SUMS
)

[ -n "$stage_tmp" ] && rm -rf "$stage_tmp"
exit 0

#!/usr/bin/env bash
# Pre-push privacy / secret scan.
#
# Scans staged content (git diff --cached) and every tracked file for personal
# information and credentials. Intended to be run before `git push` on this
# public repository.
#
# Usage: bash scripts/privacy-scan.sh

set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 1

fail=0
hit() {
	printf 'FAIL: %s\n' "$1"
	[ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/      /'
	fail=1
}

# Chinese output is fine here; the repo's docs are Chinese.
echo "== 1. scanning staged diff for secrets =="

PATTERNS=(
	'ghp_[A-Za-z0-9]{20,}'
	'github_pat_[A-Za-z0-9_]{20,}'
	'gho_[A-Za-z0-9]{20,}'
	'ghs_[A-Za-z0-9]{20,}'
	'sk-[A-Za-z0-9]{20,}'
	'xox[baprs]-[A-Za-z0-9-]{10,}'
	'AKIA[0-9A-Z]{16}'
	'-----BEGIN [A-Z ]*PRIVATE KEY-----'
	'Bearer [A-Za-z0-9._-]{20,}'
	'Authorization:[[:space:]]*[A-Za-z0-9._-]{10,}'
	'api[_-]?key[[:space:]]*[=:][[:space:]]*[A-Za-z0-9._-]{16,}'
	'access[_-]?token[[:space:]]*[=:][[:space:]]*[A-Za-z0-9._-]{16,}'
	'password[[:space:]]*[=:][[:space:]]*[^[:space:]]{6,}'
)

staged="$(git diff --cached -U0)"
for p in "${PATTERNS[@]}"; do
	m="$(printf '%s\n' "$staged" | grep -inE "^\+.*$p" || true)"
	[ -n "$m" ] && hit "staged content matches secret pattern /$p/" "$m"
done
[ "$fail" = "0" ] && echo "  ok: no secret pattern in staged content"

echo
echo "== 2. scanning tracked files for personal data =="

tracked="$(git ls-files)"
scan_files() {
	for f in $tracked; do
		[ -f "$f" ] || continue
		case "$f" in
		dist/*.zip) continue ;;
		# The scanner necessarily contains the very patterns it searches for.
		scripts/privacy-scan.sh) continue ;;
		esac
		printf '%s\n' "$f"
	done
}
files="$(scan_files)"

# Absolute home paths of the build machine. These are generic SHAPES: the
# scanner must never embed a real account name, hostname or private path.
#
# A shape appearing in the repository is not by itself a leak -- documentation
# has to name the pattern it is describing. So a match only counts as a
# violation when it contains a concrete account name (at least three word
# characters after `Users/` or `home/`) and the line does not look like a
# regex/pattern description (character classes or an ellipsis).
for p in '[A-Za-z]:[\\/]Users[\\/][A-Za-z0-9_.-]{3,}' '/home/[a-z][a-z0-9_-]{2,}' '/c/Users/[A-Za-z0-9_.-]{3,}' '/d/Users/[A-Za-z0-9_.-]{3,}'; do
	m="$(printf '%s\n' "$files" | xargs -r grep -inE "$p" 2>/dev/null |
		grep -vE '\[A-Za-z|\[a-z|\[0-9|\.\.\.' || true)"
	[ -n "$m" ] && hit "concrete home / user path matches /$p/" "$m"
done

# Build-account name, taken from the environment at run time. The value is
# never printed and never written to a file -- only the fact that it was found
# in a tracked file is reported.
CURRENT_USER="${USERNAME:-${USER:-}}"
if [ -n "$CURRENT_USER" ] && [ "${#CURRENT_USER}" -ge 3 ]; then
	m="$(printf '%s\n' "$files" | xargs -r grep -inF "$CURRENT_USER" 2>/dev/null || true)"
	[ -n "$m" ] && hit "build account name detected in tracked file" "$(printf '%s\n' "$m" | sed "s/$CURRENT_USER/[REDACTED]/g")"
fi

# email addresses other than the approved noreply form
m="$(printf '%s\n' "$files" | xargs -r grep -inE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 2>/dev/null |
	grep -v 'users\.noreply\.github\.com' | grep -v '@users.noreply' |
	grep -vE '^\S+:[0-9]+:\s*[^@]*@(example|test)\.' || true)"
[ -n "$m" ] && hit "email address(es) other than the approved GitHub noreply address" "$m"

# device serials / IMEI-like numeric runs of 15 digits
m="$(printf '%s\n' "$files" | xargs -r grep -inE '\b[0-9]{15}\b' 2>/dev/null || true)"
[ -n "$m" ] && hit "15-digit numeric string (possible IMEI/serial)" "$m"

# MAC addresses
m="$(printf '%s\n' "$files" | xargs -r grep -inE '\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b' 2>/dev/null || true)"
[ -n "$m" ] && hit "MAC address" "$m"

# LAN addresses of the test network
m="$(printf '%s\n' "$files" | xargs -r grep -inE '\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}' 2>/dev/null || true)"
[ -n "$m" ] && hit "LAN IP address" "$m"
m="$(printf '%s\n' "$files" | xargs -r grep -inE '\b(10|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}' 2>/dev/null || true)"
[ -n "$m" ] && hit "private-range IP address" "$m"

# hostnames of the build machine
m="$(printf '%s\n' "$files" | xargs -r grep -inE '\blocalhost\b|\bDESKTOP-[A-Z0-9]{7}\b|\bLAPTOP-[A-Z0-9]{7}\b' 2>/dev/null || true)"
[ -n "$m" ] && hit "hostname token" "$m"

[ "$fail" = "0" ] && echo "  ok: no personal data pattern in tracked files"

echo
echo "== 3. checking that the approved noreply address is the only email in scripts/docs =="
m="$(printf '%s\n' "$files" | xargs -r grep -inE 'noreply' 2>/dev/null || true)"
if [ -n "$m" ]; then
	echo "  noreply occurrences (expected: only in git history/docs if any):"
	printf '%s\n' "$m" | sed 's/^/      /'
fi
[ -z "$m" ] && echo "  ok: no noreply address embedded in tracked files"

echo
echo "== 4. confirming audit/raw is not tracked =="
if git ls-files --error-unmatch audit/raw >/dev/null 2>&1; then
	hit "audit/raw is tracked"
else
	echo "  ok: audit/raw is not tracked"
fi
n="$(git ls-files | grep -c '^audit/raw/' || true)"
[ "$n" != "0" ] && hit "$n files under audit/raw are tracked"
echo "  tracked files under audit/raw: $n"

echo
if [ "$fail" = "0" ]; then
	echo "privacy-scan: PASS"
else
	echo "privacy-scan: FAIL"
fi
exit "$fail"

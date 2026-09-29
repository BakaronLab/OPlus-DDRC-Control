#!/usr/bin/env bash
# Static safety audit for OPlus DDRC Control.
#
# It fails if any executable script contains a destructive primitive, if the
# module payload contains anything other than the documented text files, or if
# the four-node write contract is broken.
#
# Documentation (README.md, audit/*.md) is allowed to *name* these primitives
# while explaining what this project does not do, so only executable scripts
# and the module payload are audited. Comment lines inside scripts are stripped
# before matching, so a header comment may also mention them safely.

set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 1

fail=0
note() { printf '%s\n' "$*"; }
bad() {
	printf 'FAIL: %s\n' "$*"
	fail=1
}

# ---------------------------------------------------------------------------
# 1. executable scripts must not contain destructive primitives
# ---------------------------------------------------------------------------

FORBIDDEN=(
	'fastboot[[:space:]]+flash'
	'fastboot[[:space:]]+erase'
	'fastboot[[:space:]]+boot'
	'fastbootd'
	'dd[[:space:]]+if='
	'dd[[:space:]]+of='
	'/dev/block/'
	'avbctl'
	'bootctl'
	'mkfs'
	'mount[[:space:]]+-o[[:space:]]*rw'
	'remount'
	'setenforce[[:space:]]+0'
	'resetprop'
	'deep_dischg_counts[[:space:]]*>'
	'deep_dischg_count_cali[[:space:]]*>'
	'payload[[:space:]]+inject'
	'firehose'
	'edl'
)

note "== 1. scanning executable scripts for destructive primitives =="
mapfile -t scripts < <(find module scripts -maxdepth 1 -name '*.sh' -type f | sort)
# audit.sh necessarily contains the patterns themselves.
filtered=()
for s in "${scripts[@]}"; do
	[ "$s" = "scripts/audit.sh" ] && continue
	filtered+=("$s")
done

for s in "${filtered[@]}"; do
	code="$(grep -v '^[[:space:]]*#' "$s")"
	for p in "${FORBIDDEN[@]}"; do
		hit="$(printf '%s\n' "$code" | grep -nE "$p" || true)"
		if [ -n "$hit" ]; then
			bad "$s matches forbidden pattern /$p/:"
			printf '%s\n' "$hit" | sed 's/^/      /'
		fi
	done
done
[ "$fail" = "0" ] && note "  ok: no destructive primitive in any script"

# ---------------------------------------------------------------------------
# 2. the module may only write the four documented kernel nodes
# ---------------------------------------------------------------------------

note "== 2. checking the kernel write contract =="
for n in TERM_VAL TERM_ACT SHUT_VAL SHUT_ACT; do
	grep -q "^$n=" module/common.sh || bad "common.sh does not define $n"
done
for n in TERM_VAL TERM_ACT SHUT_VAL SHUT_ACT; do
	grep -qE ">[[:space:]]*\"\\\$$n\"" module/common.sh || bad "no kernel write found through \$$n"
done
note "  ok: the four kernel nodes exist and are written through their variables"

# every other redirect target in the module must be module-owned state or config
allowed_target='^(\$TERM_VAL|\$TERM_ACT|\$SHUT_VAL|\$SHUT_ACT|\$LOG_FILE|\$STATE_DIR[^ ]*|\$cfg|\$MODPATH/config\.conf)$'
while IFS= read -r target; do
	[ -n "$target" ] || continue
	case "$target" in
	*STATE_DIR* | *LOG_FILE* | *cfg* | *MODPATH* | '$TERM_VAL' | '$TERM_ACT' | '$SHUT_VAL' | '$SHUT_ACT') ;;
	*)
		bad "unexpected redirect target in module scripts: $target"
		;;
	esac
done < <(grep -hoE '>[[:space:]]*"[^"]+"' module/*.sh | sed -E 's/^>[[:space:]]*//; s/^"//; s/"$//' | sort -u)

absolute_targets="$(grep -hoE '(^|[^0-9])>[[:space:]]*"?/[A-Za-z0-9_./-]+' module/*.sh |
	sed -E 's/^[^>]*>[[:space:]]*"?//' | sort -u | grep -v '^/dev/null$' || true)"
if [ -n "$absolute_targets" ]; then
	bad "a redirect targets an absolute path: $absolute_targets"
else
	note "  ok: no redirect targets an absolute path (only /dev/null for stderr)"
fi

# ---------------------------------------------------------------------------
# 3. module payload contents
# ---------------------------------------------------------------------------

note "== 3. checking module payload =="
REQUIRED=(module.prop customize.sh service.sh uninstall.sh action.sh common.sh config.conf skip_mount)
for f in "${REQUIRED[@]}"; do
	[ -f "module/$f" ] || bad "module/$f is missing"
done

forbidden_paths=(system vendor product odm system_ext my_product initrc post-fs-data.sh system.prop sepolicy.rule)
for p in "${forbidden_paths[@]}"; do
	[ -e "module/$p" ] && bad "module/$p must not exist (systemless payload only)"
done

note "  module payload files:"
(cd module && ls -1 | sed 's/^/    /')

bin_hits="$(find module -type f \( -name '*.img' -o -name '*.dtbo' -o -name '*.bin' -o -name '*.ko' \) || true)"
[ -n "$bin_hits" ] && bad "binary payload found: $bin_hits"

elf_hits=""
while IFS= read -r f; do
	[ -f "$f" ] || continue
	head -c 4 "$f" | grep -q $'\x7fELF' && elf_hits="$elf_hits $f"
done < <(find module -type f)
[ -n "$elf_hits" ] && bad "ELF binary found in module/:$elf_hits"
[ -z "$bin_hits$elf_hits" ] && note "  ok: text-only payload, no images, no kernel objects, no ELF"

# ---------------------------------------------------------------------------
# 4. line endings
# ---------------------------------------------------------------------------

note "== 4. checking line endings =="
# Byte-level check: CR is 0x0d. grep with a raw CR pattern behaves
# inconsistently under MSYS, so od is used instead.
crlf=""
while IFS= read -r f; do
	[ -f "$f" ] || continue
	if od -An -tx1 -v "$f" 2>/dev/null | tr ' ' '\n' | grep -qx '0d'; then
		crlf="$crlf $f"
	fi
done < <(find module -type f | sort)
if [ -n "$crlf" ]; then
	bad "CRLF line endings found in:$crlf"
else
	note "  ok: all module files use LF"
fi

# ---------------------------------------------------------------------------

echo
if [ "$fail" = "0" ]; then
	echo "audit: PASS"
else
	echo "audit: FAIL"
fi
exit "$fail"

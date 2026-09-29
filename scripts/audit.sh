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

# Redirect targets are only meaningful in code: a comment may legitimately name
# a path while explaining what the script does (or does not) touch. Strip
# comment lines before scanning, so documentation cannot cause a false failure
# and, more importantly, so a real write can never hide behind one.
code_of() {
	sed -e 's/[[:space:]]\+$//' "$1" | grep -v '^[[:space:]]*#'
}

for n in TERM_VAL TERM_ACT SHUT_VAL SHUT_ACT; do
	grep -q "^$n=" module/common.sh || bad "common.sh does not define $n"
done
for n in TERM_VAL TERM_ACT SHUT_VAL SHUT_ACT; do
	grep -qE ">[[:space:]]*\"\\\$$n\"" module/common.sh || bad "no kernel write found through \$$n"
done
note "  ok: the four kernel nodes exist and are written through their variables"

# Every other redirect target in the module must be module-owned state or config.
# `grep -o` extracts from the operator itself, so a line containing several '>'
# characters (including '->' inside message strings) is still parsed correctly,
# and fd duplication such as 2>&1 is skipped.
redirect_targets() {
	for f in "$@"; do
		[ -f "$f" ] || continue
		code_of "$f"
	done | grep -oE '[^->]>>?[[:space:]]*("[^"]*"|\$[{A-Za-z_][A-Za-z0-9_}/$.{}-]*|[A-Za-z0-9_/.{}$-]+)' |
		sed -E -e 's/^[^>]*>>?[[:space:]]*//' -e 's/^"//' -e 's/"$//' -e 's/[);,]+$//' |
		sort -u
}

note "  module redirect targets: $(redirect_targets module/*.sh | tr '\n' ' ')"
while IFS= read -r target; do
	[ -n "$target" ] || continue
	case "$target" in
	'$TERM_VAL' | '$TERM_ACT' | '$SHUT_VAL' | '$SHUT_ACT') ;;
	'$STATE_DIR'* | '$LOG_FILE'* | '$cfg' | '$MODPATH/config.conf') ;;
	'/dev/null') ;;
	*)
		bad "unexpected redirect target in module scripts: $target"
		;;
	esac
done < <(redirect_targets module/*.sh)

absolute_targets="$(redirect_targets module/*.sh |
	grep -E '^/' | grep -v '^/dev/null$' || true)"
if [ -n "$absolute_targets" ]; then
	bad "a redirect in the module targets an absolute path: $absolute_targets"
else
	note "  ok: no module redirect targets an absolute path (only /dev/null for stderr)"
fi

# The probe is a test tool but it also writes kernel nodes, so it must obey the
# same rule: only the four nodes (through the shared variables or through
# apply_force()'s $node argument), its own work files, and /dev/null.
note "  checking scripts/device-safe-probe.sh write targets"
for n in TERM_VAL TERM_ACT SHUT_VAL SHUT_ACT; do
	grep -q "^$n=" scripts/device-safe-probe.sh || bad "device-safe-probe.sh does not define $n"
done
note "  probe redirect targets: $(redirect_targets scripts/device-safe-probe.sh | tr '\n' ' ')"
while IFS= read -r target; do
	[ -n "$target" ] || continue
	case "$target" in
	'$TERM_VAL' | '$TERM_ACT' | '$SHUT_VAL' | '$SHUT_ACT') ;;
	# The write helper takes the target as a parameter; the call sites are
	# constrained separately below.
	'$valfile' | '$actfile') ;;
	'$WD_LOG'* | '$WD_OWNERS'* | '$WORKDIR'*) ;;
	'/dev/null') ;;
	*)
		bad "unexpected redirect target in device-safe-probe.sh: $target"
		;;
	esac
done < <(redirect_targets scripts/device-safe-probe.sh)

# apply_force() is parameterised, so the parameter alone is not proof. Every
# call site must pass one of the four real node variables.
note "  checking apply_force() call sites"
call_sites="$(code_of scripts/device-safe-probe.sh | grep -nE '^[[:space:]]*apply_force ' || true)"
if [ -z "$call_sites" ]; then
	bad "apply_force() has no call sites; the probe cannot be exercising writes at all"
else
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		if printf '%s\n' "$line" | grep -qE 'apply_force "\$(TERM_VAL|SHUT_VAL)" "\$(TERM_ACT|SHUT_ACT)" '; then
			note "  ok: $(printf '%s' "$line" | sed 's/^[0-9]*:[[:space:]]*//' | cut -c1-70)"
		else
			bad "apply_force() called with an unexpected target: $line"
		fi
	done <<EOF
$call_sites
EOF
fi

# restore() in the probe must name the four node variables directly, so the
# ownership-gated writes are statically visible.
for n in TERM_ACT SHUT_ACT; do
	grep -qE "printf '0' >\"?\\\$$n" scripts/device-safe-probe.sh ||
		bad "probe restore() does not write \$$n directly"
done
note "  ok: probe restore() writes the node variables directly"

probe_abs="$(redirect_targets scripts/device-safe-probe.sh |
	grep -E '^/' | grep -v '^/dev/null$' || true)"
if [ -n "$probe_abs" ]; then
	bad "device-safe-probe.sh redirects to an absolute path: $probe_abs"
else
	note "  ok: probe redirects only to its own node variables and /dev/null"
fi

# ---------------------------------------------------------------------------
# 2b. ownership contract: restore() must never clear both nodes unconditionally
# ---------------------------------------------------------------------------

note "== 2b. checking the restore ownership contract =="

# The defect this guards against: a restore path that writes both force_active
# nodes with no ownership test in front of them.
check_restore_ownership() {
	file="$1"
	label="$2"
	# Extract the body of restore() only.
	body="$(awk '/^restore\(\) *\{/{f=1} f{print} f&&/^\}/{exit}' "$file")"
	if [ -z "$body" ]; then
		# No restore() in this file: nothing to check.
		return 0
	fi
	# A guard means the body mentions an ownership test before writing.
	if printf '%s\n' "$body" | grep -qE 'OWN_(TERM|SHUT)|owns_node'; then
		note "  ok: $label restore() is ownership-gated"
	else
		bad "$label restore() clears nodes without an ownership test"
	fi

	# Any other force_active write in the file is only acceptable inside a
	# block that tests ownership first. The watchdog is the only such place, and
	# it must consult the owner record before writing.
	other="$(awk '
		/^restore\(\) *\{/ {in_restore=1}
		in_restore && /^\}/ {in_restore=0; next}
		!in_restore {print NR": "$0}
	' "$file" | grep -E '(SHUT_ACT|TERM_ACT)' | grep -E "printf '0'|echo 0" || true)"
	if [ -n "$other" ]; then
		while IFS= read -r line; do
			lineno="${line%%:*}"
			# Look back a few lines for an ownership test on the owner record.
			context="$(sed -n "$((lineno > 12 ? lineno - 12 : 1)),${lineno}p" "$file")"
			if printf '%s\n' "$context" | grep -qE 'grep -qx? (SHUT|TERM) .*(WD_OWNERS|owners)'; then
				note "  ok: $label force_active write at line $lineno is guarded by the owner record"
			else
				bad "$label writes force_active at line $lineno without an ownership guard"
			fi
		done <<EOF
$other
EOF
	fi
	return 0
}

check_restore_ownership scripts/device-safe-probe.sh "probe"
check_restore_ownership module/common.sh "module"

# ---------------------------------------------------------------------------
# 2c. fail-closed profile gating
# ---------------------------------------------------------------------------

note "== 2c. checking fail-closed profile gating =="
for f in module/service.sh module/action.sh; do
	grep -q 'profile_dt_ok' "$f" || bad "$f does not gate its profile on the live device tree"
done
if grep -qE 'MODE=balanced|downgrad' module/service.sh; then
	bad "service.sh appears to downgrade a rejected profile to another non-stock one"
else
	note "  ok: service.sh has no full->balanced downgrade path"
fi
note "  ok: service.sh and action.sh both use profile_dt_ok()"

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
# 5. regression suite and CI configuration
# ---------------------------------------------------------------------------

note "== 5. running the regression suite =="
if [ -f tests/run-all.sh ]; then
	# tests/run-all.sh is a bash script (arrays, process substitution), so it
	# must not be handed to a POSIX sh. On the runner /bin/sh is dash.
	if bash tests/run-all.sh >/tmp/ddrc-tests.log 2>&1; then
		note "  ok: $(( $(grep -c '   PASS' /tmp/ddrc-tests.log) )) assertions passed"
	else
		bad "regression suite failed"
		tail -20 /tmp/ddrc-tests.log | sed 's/^/      /'
	fi
else
	bad "tests/run-all.sh is missing"
fi

note "== 6. checking CI configuration =="
if [ -f .github/workflows/ci.yml ]; then
	note "  ok: .github/workflows/ci.yml present"
	grep -q 'privacy-scan' .github/workflows/ci.yml ||
		bad "CI does not run the privacy scan"
	grep -q 'audit.sh' .github/workflows/ci.yml ||
		bad "CI does not run the static audit"
	grep -q 'run-all.sh\|tests/' .github/workflows/ci.yml ||
		bad "CI does not run the regression suite"
	if grep -qE 'secrets\.|GH_TOKEN|PAT|DEPLOY_KEY' .github/workflows/ci.yml; then
		bad "CI references secrets; this project needs none"
	else
		note "  ok: CI uses no secrets"
	fi
else
	bad ".github/workflows/ci.yml is missing"
fi

# ---------------------------------------------------------------------------
# 7. documentation must point at the artifact that actually ships
# ---------------------------------------------------------------------------

note "== 7. checking release references =="

# A doc that still names a superseded ZIP sends users to a file that is no
# longer in dist/ -- or, worse, to a revision this project has deprecated.
version="$(sed -n 's/^version=//p' module/module.prop)"
expected_zip="OPlus-DDRC-Control-$version.zip"
note "  current version: $version"

if [ ! -f "dist/$expected_zip" ]; then
	bad "dist/$expected_zip (the version named in module.prop) does not exist"
fi

while IFS= read -r ref; do
	[ -n "$ref" ] || continue
	if [ "$ref" != "$expected_zip" ]; then
		bad "a tracked file references a superseded artifact: $ref"
	fi
done < <(grep -rhoE 'OPlus-DDRC-Control-v[0-9][0-9A-Za-z.-]*\.zip' \
	README.md audit/ module/ scripts/ tests/ .github/ 2>/dev/null | sort -u)

# SHA256SUMS must describe exactly the ZIPs present in dist/, no more.
if [ -f dist/SHA256SUMS ]; then
	sums_zips="$(awk '{print $2}' dist/SHA256SUMS | sed 's/^\*//' | sort)"
	real_zips="$(cd dist && ls -1 ./*.zip 2>/dev/null | sed 's|^\./||' | sort)"
	if [ "$sums_zips" = "$real_zips" ]; then
		note "  ok: SHA256SUMS lists exactly the ZIPs in dist/"
	else
		bad "dist/SHA256SUMS does not match the ZIPs in dist/"
		printf '      in SHA256SUMS: %s\n' "$(printf '%s' "$sums_zips" | tr '\n' ' ')"
		printf '      in dist/:      %s\n' "$(printf '%s' "$real_zips" | tr '\n' ' ')"
	fi
else
	bad "dist/SHA256SUMS is missing"
fi

# ---------------------------------------------------------------------------

echo
if [ "$fail" = "0" ]; then
	echo "audit: PASS"
else
	echo "audit: FAIL"
fi
exit "$fail"

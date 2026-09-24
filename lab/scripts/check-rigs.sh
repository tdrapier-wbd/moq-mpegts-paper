#!/usr/bin/env bash
# Fail if any rig hard-codes a flag that the #3793 CLI migration renamed, or starts a relay
# without the grant and the offload setting.
#
# Every one of these has cost a run. The auth grant is the expensive one because it fails
# *silently* — the relay binds, both sessions are accepted, the announcement registers and no byte
# is ever delivered — but the renamed flags are only cheaper, not cheap: a rig that dies on an
# unknown argument at 03:00 has still lost the night. This check is the thing that notices, and it
# is cheap enough to run before every session.
#
#   check-rigs.sh            # audit lab/scripts
#   check-rigs.sh --quiet    # exit status only
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
QUIET=${1:-}
fails=0
note() { [ "$QUIET" = --quiet ] || echo "$@"; }

# The library defines the migrated names, and `ec2-swap-build.sh` is the sed recipe that rewrites
# them, so both legitimately contain the old spellings.
EXEMPT='moq-cli-flags.sh|ec2-swap-build.sh|check-rigs.sh'

fail() {
	fails=$((fails + 1))
	note "FAIL $1"
	note "$2" | sed 's/^/     /'
}

# --- 1. no literal pre/post-migration flag outside the library -------------------------------
hits=$(rg -n -- '--client-connect|--client-tls-disable-verify|--latency-max|--server-bind|--tls-generate |--server-quic-(gso|congestion-control|idle-timeout|keep-alive)' \
	--glob '*.sh' 2>/dev/null | rg -v "^($EXEMPT):" | rg -v ':[0-9]+:\s*#')
[ -n "$hits" ] && fail "a rig hard-codes a migrated flag; take it from moq-cli-flags.sh" "$hits"

# --- 2. no literal --auth-public ---------------------------------------------------------------
# The value inverted at the migration, so a literal is wrong on one side of it whichever you pick,
# and wrong silently.
hits=$(rg -n -- '--auth-public' --glob '*.sh' 2>/dev/null | rg -v "^($EXEMPT):" | rg -v ':[0-9]+:\s*#')
[ -n "$hits" ] && fail "a rig writes --auth-public literally; use RELAY_AUTH or moq_relay_public" "$hits"

# --- 3. every relay launch carries a grant and the offload setting -----------------------------
for f in *.sh; do
	echo "$f" | rg -q "^($EXEMPT)$" && continue
	rg -q -- '\$\{?RELAY_BIND|moq_relay_public|moq_relay_authed' "$f" 2>/dev/null || continue
	rg -q -- 'RELAY_AUTH|moq_relay_public|moq_relay_authed|--auth-api|--auth-key-dir|--auth-url' "$f" ||
		fail "$f starts a relay with no grant and no explicit auth source" \
			"a relay with neither --auth-public nor an auth source accepts sessions and serves nothing"
	rg -q -- 'RELAY_GSO|moq_relay_public|moq_relay_authed' "$f" ||
		fail "$f starts a relay without RELAY_GSO" \
			"GSO on the egress mis-accounts captured datagrams; every overhead figure taken with it is wrong"
done

# --- 4. process matching must not key on a renamed flag ----------------------------------------
hits=$(rg -n -- '(pgrep|pkill|proc_of|rss_of|ps -o).*(--server-bind|--listen )' --glob '*.sh' 2>/dev/null |
	rg -v "^($EXEMPT):" | rg -v ':[0-9]+:\s*#')
[ -n "$hits" ] && fail "a cleanup pattern keys on a flag name that changed" \
	"$(printf '%s\n' "$hits" 'a pattern that no longer matches leaves the relay holding the port,')"

# --- 5. every continuity count must use a pattern that tsp actually emits ----------------------
# `tsp -P continuity` writes `* continuity: packet index: N, PID: 0xNN (n), missing K packets`.
# Three rigs counted `TS:` and one counted `discontinuity` alone; both return **zero on a stream
# with known missing packets**, so those cells could not fail. Found in T42 after the same class of
# bug nearly inverted its own result. Match the wording, or the grader reports universal success.
hits=$(rg -n -- 'continuity' --glob '*.sh' 2>/dev/null | rg -- 'grep' |
	rg -v "^($EXEMPT):" | rg -v ':[0-9]+:\s*#' |
	rg -v "missing .\* packets\|discontinuity" | rg -v "grep -c \"continuity:\"")
[ -n "$hits" ] && fail "a rig counts continuity errors with a pattern tsp does not emit" \
	"$(printf '%s\n' "$hits" "use: grep -cE 'missing .* packets|discontinuity'")"

# --- 6. shell hygiene ---------------------------------------------------------------------------
for f in *.sh; do
	bash -n "$f" 2>/dev/null || fail "$f does not parse" "$(bash -n "$f" 2>&1 | head -3)"
done
if command -v shellcheck >/dev/null; then
	sc=$(shellcheck -S error -- *.sh 2>&1)
	[ -n "$sc" ] && fail "shellcheck reports errors" "$(printf '%s' "$sc" | head -20)"
fi

# --- 7. python hygiene --------------------------------------------------------------------------
# Half this directory is Python and none of it was gated, which is how 31 ruff findings accumulated
# across 14 files without anyone seeing them.
for f in *.py; do
	python3 -m py_compile "$f" 2>/dev/null ||
		fail "$f does not compile" "$(python3 -m py_compile "$f" 2>&1 | tail -3)"
done
rm -rf __pycache__
if command -v ruff >/dev/null; then
	rf=$(ruff check --quiet -- *.py 2>&1)
	[ -n "$rf" ] && fail "ruff reports findings" "$(printf '%s' "$rf" | tail -20)"
fi

if [ "$fails" -eq 0 ]; then
	note "check-rigs: clean ($(ls -1 -- *.sh | wc -l | tr -d ' ') shell, $(ls -1 -- *.py | wc -l | tr -d ' ') python)"
	exit 0
fi
note ""
note "check-rigs: $fails problem(s)"
exit 1

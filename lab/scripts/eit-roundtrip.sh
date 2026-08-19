#!/usr/bin/env bash
# Round-trip an EIT-bearing TS through the media-aware lane and report which SI survives.
#
# Answers what the code review could only infer: which PIDs `import.rs` intercepts, and what
# reaches the far end. `catalog::SI_PIDS` has grown from NIT and SDT/BAT alone to include EIT
# (0x0012, upstream #2909) and TDT/TOT (0x0014, #2929), so the expected result depends on the
# build under test and this measures it rather than asserting it. On a build carrying both,
# every SI PID above should survive; on an older one, only 0x0010 and 0x0011.
#
# Input is the synthetic fixture from make-eit-fixture.sh, because no capture we hold
# carries EIT.
#
# Everything runs inside one invocation: background processes do not survive across
# separate shell invocations in this environment.
#
# Usage: eit-roundtrip.sh [fixture.ts] [capture_seconds]

set -euo pipefail

SRC="${1:-$HOME/CNNiEMEA2_eit_full.ts}"
WINDOW="${2:-45}"
BROADCAST="eit.hang"
OUT="$HOME/eit_roundtrip_out.ts"
RELAY_LOG="$HOME/eit_relay.log"
SUB_LOG="$HOME/eit_sub.log"
PUB_LOG="$HOME/eit_pub.log"

[[ -r "$SRC" ]] || { echo "fixture not readable: $SRC — run make-eit-fixture.sh first" >&2; exit 1; }

# TGT may be set to grade a build other than the working checkout's — a PR head in a
# throwaway worktree, say. Unset, it resolves the sandbox cargo target, which rotates
# per session.
TGT="${TGT:-$(cd ~/moq-dev && cargo metadata --format-version 1 --no-deps \
	| python3 -c "import json,sys;print(json.load(sys.stdin)['target_directory'])")/release}"
[[ -x "$TGT/moq" && -x "$TGT/moq-relay" ]] || { echo "binaries missing under $TGT" >&2; exit 1; }
describe_build() {
	# The worktree a TGT belongs to is not derivable from the target dir when
	# CARGO_TARGET_DIR was redirected, so name it explicitly with BUILD_DESC.
	if [[ -n "${BUILD_DESC:-}" ]]; then
		echo "$BUILD_DESC"
	else
		(cd ~/moq-dev && git log --oneline -1)
	fi
}

# Two incompatible flag surfaces are in the wild: the dial-side options were renamed
# from `--client-*` to `--connect-*` and per-direction QUIC tuning was merged into one
# `--quic-*` section. Builds carrying the rename still *parse* the old names behind a
# deprecation warning, but `--client-quic-gso=false` does not reach the transport there,
# so GSO stays on and the session stalls on macOS loopback with no error logged. Detect
# the surface rather than assuming one.
if "$TGT/moq" --connect https://localhost --help >/dev/null 2>&1; then
	FLAGS_NEW=1
	GSO=(--quic-gso=false)
else
	FLAGS_NEW=0
	GSO=(--client-quic-gso=false)
fi
CF=() # dial-side flags, filled by client_flags once the fingerprint is known
client_flags() { # <fingerprint>
	if [[ "$FLAGS_NEW" == 1 ]]; then
		CF=(--connect-tls-fingerprint "$1" --connect https://localhost:4443 --quic-gso=false)
	else
		CF=(--client-tls-fingerprint "$1" --client-connect https://localhost:4443 --client-quic-gso=false)
	fi
}

echo "==> binaries $TGT"
echo "==> build    $(describe_build)"
echo "==> flags    $([[ "$FLAGS_NEW" == 1 ]] && echo '--connect-* (current)' || echo '--client-* (legacy)')"

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT

# GSO off: it stalls on macOS loopback. https:// + pinned fingerprint: the http://
# bootstrap is broken in this build.
( cd ~/moq-dev && "$TGT/moq-relay" demo/relay/localhost.toml "${GSO[@]/#--client-/--server-}" ) \
	>"$RELAY_LOG" 2>&1 &
PIDS+=($!)

for _ in $(seq 1 40); do
	FP="$(curl -s http://localhost:4443/certificate.sha256 || true)"
	[[ -n "$FP" ]] && break
	sleep 0.25
done
[[ -n "${FP:-}" ]] || { echo "relay did not come up; see $RELAY_LOG" >&2; exit 1; }
echo "==> relay up, fingerprint ${FP:0:16}…"

# Subscriber first: catalog reservation gating publishes the catalog once tracks resolve.
client_flags "$FP"
"$TGT/moq" "${CF[@]}" --broadcast "$BROADCAST" export ts >"$OUT" 2>"$SUB_LOG" &
PIDS+=($!)
sleep 2

tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null \
	| "$TGT/moq" "${CF[@]}" --broadcast "$BROADCAST" import ts >"$PUB_LOG" 2>&1 &
PIDS+=($!)

echo "==> capturing ${WINDOW}s"
sleep "$WINDOW"
cleanup
trap - EXIT
sleep 1

echo
echo "==> captured $(wc -c <"$OUT") bytes"
echo
printf '%-10s %-8s %-9s %s\n' TABLE PID SOURCE EGRESS
for spec in "NIT:0x0010" "SDT:0x0011" "EIT:0x0012" "TDT/TOT:0x0014"; do
	name="${spec%%:*}"; pid="${spec##*:}"
	s=$(tsp -I file "$SRC" -P count --pid "$pid" --total -O drop 2>&1 | rg -o "counted [0-9,]+" | head -1)
	e=$(tsp -I file "$OUT" -P count --pid "$pid" --total -O drop 2>&1 | rg -o "counted [0-9,]+" | head -1)
	printf '%-10s %-8s %-9s %s\n' "$name" "$pid" "${s#counted }" "${e#counted }"
done

echo
echo "==> egress PID list"
tsp -I file "$OUT" -P analyze --normalized -O drop 2>/dev/null \
	| rg "^pid:" | sed -E 's/^pid:pid=([0-9]+):.*description=(.*)$/  PID \1  \2/'

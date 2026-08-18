#!/usr/bin/env bash
# Time-to-first-byte for a TS exporter joining a broadcast that carries standalone SI.
#
# Why this exists: carrying SI on its own snapshot tracks (moq-dev/moq#2909) takes the
# service layer off the catalog, so a media-only subscriber no longer pays for it at join.
# A TS exporter does still pay, and it pays differently: export holds *all* output — tables
# and media alike — until every SI entry the catalog names has reduced its first snapshot,
# so the service layer leads the stream rather than trailing it. That turns an SI payload
# into blocking join latency, and the payload scales with the EPG: an 8-day schedule is
# ~30 kB per service across four sub-tables, so an MPTS multiplies both the bytes and the
# number of tracks that must resolve before the first TS packet.
#
# This measures that: the publisher is already running and its SI already advertised, then
# an exporter joins cold and we time its first byte out. Run it against a fixture carrying
# the EPG and against one carrying none; the difference is what the service layer costs a
# joining receiver.
#
# Everything runs inside one invocation: background processes do not survive across
# separate shell invocations in this environment.
#
# Usage: si-join-cost.sh <fixture.ts> <label> [joins] [settle_s]
#   TGT=<dir with moq/moq-relay>   which build to grade (default: sandbox cargo target)
#   BUILD_DESC="..."               how to name that build in the output

set -euo pipefail

SRC="${1:?usage: si-join-cost.sh <fixture.ts> <label> [joins] [settle_s]}"
LABEL="${2:?label}"
JOINS="${3:-5}"
# The publisher must have committed every sub-table before the first join, or we time
# acquisition rather than join. EIT schedule commits on transmission-cycle wrap, and the
# ETSI TS 101 211 "later" cycle is 30 s, so allow two.
SETTLE="${4:-70}"

RUN="$HOME/si_join_$LABEL"
BROADCAST="sijoin.$LABEL.hang"

[[ -r "$SRC" ]] || {
	echo "fixture not readable: $SRC" >&2
	exit 1
}
mkdir -p "$RUN"

TGT="${TGT:-$(cd ~/moq-dev && cargo metadata --format-version 1 --no-deps \
	| python3 -c "import json,sys;print(json.load(sys.stdin)['target_directory'])")/release}"
[[ -x "$TGT/moq" && -x "$TGT/moq-relay" ]] || {
	echo "binaries missing under $TGT" >&2
	exit 1
}

# The dial-side flags were renamed from `--client-*` to `--connect-*` and per-direction
# QUIC tuning merged into one `--quic-*` section. Builds carrying the rename still parse
# the old names behind a deprecation warning, but `--client-quic-gso=false` does not reach
# the transport there, so GSO stays on and the session stalls on macOS loopback with no
# error logged. Detect the surface rather than assuming one.
if "$TGT/moq" --connect https://localhost --help >/dev/null 2>&1; then
	CF=(--connect https://localhost:4443 --quic-gso=false)
	FPFLAG=--connect-tls-fingerprint
	RGSO=(--quic-gso=false)
else
	CF=(--client-connect https://localhost:4443 --client-quic-gso=false)
	FPFLAG=--client-tls-fingerprint
	RGSO=(--server-quic-gso=false)
fi

echo "==> binaries $TGT"
echo "==> build    ${BUILD_DESC:-$(cd ~/moq-dev && git log --oneline -1)}"
echo "==> fixture  $SRC"
echo "==> joins    $JOINS after ${SETTLE}s settle"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
	wait 2>/dev/null || true
}
trap cleanup EXIT

(cd ~/moq-dev && "$TGT/moq-relay" demo/relay/localhost.toml "${RGSO[@]}") >"$RUN/relay.log" 2>&1 &
PIDS+=($!)

for _ in $(seq 1 40); do
	FP="$(curl -s http://localhost:4443/certificate.sha256 || true)"
	[[ -n "$FP" ]] && break
	sleep 0.25
done
[[ -n "${FP:-}" ]] || {
	echo "relay did not come up; see $RUN/relay.log" >&2
	exit 1
}

tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null \
	| "$TGT/moq" "$FPFLAG" "$FP" "${CF[@]}" --broadcast "$BROADCAST" import ts >"$RUN/pub.log" 2>&1 &
PIDS+=($!)

echo "==> settling ${SETTLE}s so every sub-table has committed"
sleep "$SETTLE"

# One cold join per iteration. The reader timestamps the first byte it sees and exits, so
# the number is export's own gate, not a decode or a write to disk.
for i in $(seq 1 "$JOINS"); do
	"$TGT/moq" "$FPFLAG" "$FP" "${CF[@]}" --broadcast "$BROADCAST" export ts 2>"$RUN/sub.$i.log" \
		| python3 -c '
import sys, time
t0 = time.monotonic()
chunk = sys.stdin.buffer.read(1)
if chunk:
    print(f"{(time.monotonic() - t0) * 1000:.0f}")
' >"$RUN/ttfb.$i.txt" 2>/dev/null || true
	printf '  join %d: %s ms\n' "$i" "$(cat "$RUN/ttfb.$i.txt" 2>/dev/null || echo "none")"
done

cleanup
trap - EXIT

echo
echo "==> $LABEL time-to-first-byte (ms)"
cat "$RUN"/ttfb.*.txt 2>/dev/null | python3 -c '
import statistics, sys
v = [float(x) for x in sys.stdin.read().split()]
if not v:
    print("  no samples")
else:
    v.sort()
    print(f"  n={len(v)} min={v[0]:.0f} median={statistics.median(v):.0f} max={v[-1]:.0f}")
'
echo "==> SI tracks the exporter subscribed to"
rg -o 'track=[^ ]*\.si' "$RUN/sub.1.log" 2>/dev/null | sort -u | sed 's/^/  /' || echo "  (none logged)"

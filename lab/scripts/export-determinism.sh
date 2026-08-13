#!/usr/bin/env bash
# Two `moq export ts` subscribers of one broadcast, the second joining late: do they render
# the same packets?
#
# This is the topology of moq-dev/moq#2779 with the RTP/groomer layer removed, so what it
# measures is the exporter alone. It differs from the upstream unit tests in using a real
# DVB contribution stream, which carries SDT and NIT — the standalone SI PIDs are the ones
# whose cadence has no keyframe to re-anchor on, so a source without them cannot show the
# divergence at all.
#
# Everything runs inside one invocation: background processes do not survive across
# separate shell invocations in this environment.
#
# Usage: export-determinism.sh <moq-binary> <relay-binary> <label> [source.ts] [join_s] [window_s]

set -euo pipefail

MOQ="${1:?usage: export-determinism.sh <moq> <moq-relay> <label> [src] [join_s] [window_s]}"
RELAY="${2:?}"
LABEL="${3:?}"
SRC="${4:-$HOME/CNNiEMEA2.ts}"
JOIN="${5:-20}"
WINDOW="${6:-45}"
BROADCAST="det-$LABEL.hang"
OUT_A="$HOME/det_${LABEL}_a.ts"
OUT_B="$HOME/det_${LABEL}_b.ts"

[[ -x "$MOQ" && -x "$RELAY" ]] || { echo "binaries not executable" >&2; exit 1; }
[[ -r "$SRC" ]] || { echo "source not readable: $SRC" >&2; exit 1; }

echo "==> $LABEL: $(basename "$MOQ"), join +${JOIN}s, window ${WINDOW}s, src $(basename "$SRC")"

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT

# GSO off: it stalls on macOS loopback. https:// + pinned fingerprint: the http://
# bootstrap is broken in these builds.
( cd ~/moq-dev && "$RELAY" demo/relay/localhost.toml --server-quic-gso=false ) \
	>"$HOME/det_${LABEL}_relay.log" 2>&1 &
PIDS+=($!)

for _ in $(seq 1 40); do
	FP="$(curl -s http://localhost:4443/certificate.sha256 || true)"
	[[ -n "$FP" ]] && break
	sleep 0.25
done
[[ -n "${FP:-}" ]] || { echo "relay did not come up" >&2; exit 1; }

sub() {
	"$MOQ" --client-tls-fingerprint "$FP" --client-connect https://localhost:4443 \
		--client-quic-gso=false --broadcast "$BROADCAST" export ts
}

# Subscriber A first, then the publisher: reservation gating publishes the catalog once
# tracks resolve.
sub >"$OUT_A" 2>"$HOME/det_${LABEL}_suba.log" &
PIDS+=($!)
sleep 2

tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null \
	| "$MOQ" --client-tls-fingerprint "$FP" --client-connect https://localhost:4443 \
		--client-quic-gso=false --broadcast "$BROADCAST" import ts \
		>"$HOME/det_${LABEL}_pub.log" 2>&1 &
PIDS+=($!)

echo "==> A running; B joins in ${JOIN}s"
sleep "$JOIN"
sub >"$OUT_B" 2>"$HOME/det_${LABEL}_subb.log" &
PIDS+=($!)

sleep "$WINDOW"
cleanup
trap - EXIT
sleep 1

echo "==> A $(wc -c <"$OUT_A") bytes, B $(wc -c <"$OUT_B") bytes"

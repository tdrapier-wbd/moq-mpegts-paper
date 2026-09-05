#!/usr/bin/env bash
# Attribute a degenerate source PCR to the publisher's input or to the exporter.
#
# T21's rate divergence traces to the pacer's input carrying a PCR that stops
# advancing and increments by a single 90 kHz tick per packet. That is either
# something the source already did or something the MoQ round trip did to it,
# and the two have entirely different owners. This captures both ends of the
# same run so the same media point can be read on each side.
#
# Usage: t21-pcr-attribution.sh <label> [seconds]
set -euo pipefail

LABEL=${1:?label}
SECS=${2:-800}

MOQ=${MOQ:-$HOME/bin-main-eab96019/moq}
RELAY=${RELAY:-$HOME/bin-main-eab96019/moq-relay}
PACER=${PACER:-$HOME/pacer-instr/mpegts-pacer}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
RATE=${RATE:-11000000}
PORT=${PORT:-4473}
DIR=${DIR:-$HOME/t21attr}

RUN=$DIR/$LABEL
mkdir -p "$RUN"
BCAST="t21attr.$LABEL"
KIDS=()

cleanup() {
	for p in ${KIDS+"${KIDS[@]}"}; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in ${KIDS+"${KIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
	pkill -9 -f "$BCAST" 2>/dev/null
	pkill -9 -f "[m]oq-relay --server-bind 127.0.0.1:$PORT" 2>/dev/null
	true
}
trap cleanup EXIT

"$RELAY" --server-bind "127.0.0.1:$PORT" --tls-generate localhost --auth-public "" \
	>"$RUN/relay.log" 2>&1 &
KIDS+=("$!")
sleep 2

# The publisher's input, captured before MoQ sees it. This is the control: if
# its PCR is clean at the media point where the exporter's is degenerate, the
# round trip is responsible.
tsp -I file "$CLIP" --infinite -P regulate --pcr-synchronous -O file - 2>"$RUN/tsp.log" |
	tee "$RUN/source.ts" |
	"$MOQ" --client-tls-disable-verify --client-connect "https://127.0.0.1:$PORT/anon" \
		--broadcast "$BCAST" import ts >"$RUN/pub.log" 2>&1 &
KIDS+=("$!")
sleep 5

timeout "$SECS" "$MOQ" --client-tls-disable-verify \
	--client-connect "https://127.0.0.1:$PORT/anon" \
	--broadcast "$BCAST" export ts --latency-max 500ms 2>"$RUN/export.log" |
	tee "$RUN/exported.ts" |
	"$PACER" - "$RATE" --latency-ms 1000 --max-latency-ms 2500 \
		--stall-ms 2000 --on-stall mute --stats-interval-ms 15000 \
		2>"$RUN/pacer.log" >/dev/null || true

echo "source=$(stat -c%s "$RUN/source.ts") exported=$(stat -c%s "$RUN/exported.ts")"

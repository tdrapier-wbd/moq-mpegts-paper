#!/usr/bin/env bash
# Capture the media-aware exporter's raw output to a file, for offline replay
# through the pacer's rate estimator.
#
# The estimator is a pure function of the input packet sequence: it reads PCR
# values and counts packets between them, and consults no clock. So a capture
# replays it exactly, which turns a defect that needs nine minutes of live lane
# into a deterministic offline case.
#
# Usage: t21-capture-export.sh <label> [seconds]
set -euo pipefail

LABEL=${1:?label}
SECS=${2:-960}

MOQ=${MOQ:-$HOME/bin-3006/moq}
RELAY=${RELAY:-$HOME/bin-3006/moq-relay}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
PORT=${PORT:-4471}
DIR=${DIR:-$HOME/t21cap}

RUN=$DIR/$LABEL
mkdir -p "$RUN"
BCAST="t21cap.$LABEL"
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

tsp -I file "$CLIP" --infinite -P regulate --pcr-synchronous -O file - 2>"$RUN/tsp.log" |
	"$MOQ" --client-tls-disable-verify --client-connect "https://127.0.0.1:$PORT/anon" \
		--broadcast "$BCAST" import ts >"$RUN/pub.log" 2>&1 &
KIDS+=("$!")
sleep 5

# No pacer in the path. The capture is the exporter's own output, which is what
# the estimator sees, and writing to a file cannot change the packet sequence.
timeout "$SECS" "$MOQ" --client-tls-disable-verify \
	--client-connect "https://127.0.0.1:$PORT/anon" \
	--broadcast "$BCAST" export ts --latency-max 500ms \
	>"$RUN/export.ts" 2>"$RUN/export.log" || true

echo "captured $(stat -c%s "$RUN/export.ts") bytes to $RUN/export.ts"

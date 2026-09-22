#!/usr/bin/env bash
# The T21 diagnostic lane: the full media-aware path with the instrumented
# pacer, run long enough to pass the ~9-minute departure.
#
# The point of this rig over the soak is the counter line: the rate estimator's
# two accumulators are reported separately, so one run says whether the
# numerator grew or the denominator collapsed instead of only that their ratio
# went wrong.
#
# Usage: t21-rate-diag.sh <label> [seconds]
set -euo pipefail

# Post-#3793 CLI flags (dual old/new binaries).
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:?label}
SECS=${2:-1200}

MOQ=${MOQ:-$HOME/bin-3006/moq}
moq_cli_detect "$MOQ" "${RELAY:-${RELAY_BIN:-}}"
RELAY=${RELAY:-$HOME/bin-3006/moq-relay}
PACER=${PACER:-$HOME/pacer/mpegts-pacer-instr}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
RATE=${RATE:-11000000}
CUSHION_MS=${CUSHION_MS:-1000}
CAP_MS=${CAP_MS:-2500}
PORT=${PORT:-4472}
DIR=${DIR:-$HOME/t21diag}

RUN=$DIR/$LABEL
mkdir -p "$RUN"
BCAST="t21diag.$LABEL"
KIDS=()

cleanup() {
	for p in ${KIDS+"${KIDS[@]}"}; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in ${KIDS+"${KIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
	pkill -9 -f "$BCAST" 2>/dev/null
	pkill -9 -f "[m]oq-relay.*127.0.0.1:$PORT" 2>/dev/null
	true
}
trap cleanup EXIT

"$RELAY" "${RELAY_BIND[@]}" "127.0.0.1:$PORT" "${RELAY_TLS[@]}" localhost \
	"${RELAY_AUTH[@]}" "${RELAY_GSO[@]}" \
	>"$RUN/relay.log" 2>&1 &
KIDS+=("$!")
sleep 2

tsp -I file "$CLIP" --infinite -P regulate --pcr-synchronous -O file - 2>"$RUN/tsp.log" |
	"$MOQ" "${MOQ_DIAL[@]}" "https://127.0.0.1:$PORT/anon" \
		--broadcast "$BCAST" import ts >"$RUN/pub.log" 2>&1 &
KIDS+=("$!")
sleep 5

# The pacer's output goes to a counter, not a file: a soak that fills the disk
# stops for the wrong reason, and nothing here grades the bytes.
#
# CAPTURE=1 tees the exporter's output — the pacer's actual input — on the way
# past. Replaying that file through the estimator settles whether the defect
# lives in the byte stream or in state the pacer only reaches when it is being
# read live, and the two have different fixes. `tee` costs a copy, which on a
# host this small is itself a perturbation, so it is off by default.
if [ "${CAPTURE:-0}" = "1" ]; then
	TEE=(tee "$RUN/input.ts")
else
	TEE=(cat)
fi

timeout "$SECS" "$MOQ" "${MOQ_DIAL[0]}" \
	"${MOQ_DIAL[1]}" "https://127.0.0.1:$PORT/anon" \
	--broadcast "$BCAST" export ts "${MOQ_LAT[@]}" 500ms 2>"$RUN/export.log" |
	"${TEE[@]}" |
	"$PACER" - "$RATE" --latency-ms "$CUSHION_MS" --max-latency-ms "$CAP_MS" \
		--stall-ms 2000 --on-stall mute --stats-interval-ms 15000 \
		2>"$RUN/pacer.log" >/dev/null || true

echo "done: $RUN/pacer.log"

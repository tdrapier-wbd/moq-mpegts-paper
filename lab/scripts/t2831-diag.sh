#!/usr/bin/env bash
#
# The four cells that decide how the T28/T31 segmented ladder is read.
#
# The ladder itself ([`t28-t31-segmented-ladder.sh`](t28-t31-segmented-ladder.sh)) produced four
# readings that could each have been the lane or the instrument, and the point of this script is
# that the two are separable by re-running one variable at a time:
#
#   1-2. The MoQ outage arms read 0.22 whether the outage was 5 s or 30 s, which is not an outage
#        result -- the relay logs `subscribe canceled (idle)` at the break and the arm is measuring
#        the time before it. Re-running pinned to CUBIC, with the idle timeout out of the way,
#        separates a controller that cannot recover from a lane that cannot. It was the controller
#        at 5 s (0.227 -> 0.961) and neither at 30 s.
#   3-4. Two segmented cells returned a receiver exit of 1 after refusing a segment that was not a
#        multiple of 188 bytes -- the per-fetch timeout cutting a transfer in half. Re-running at a
#        60 s budget says whether the cell was the timeout: reorder moved six-fold and was, the
#        0.5x capacity rung returned a byte-identical figure and was not.
#
# The general form is worth more than these four results: on an impaired cell, re-run with the one
# instrument parameter changed, and let the byte count say whether you measured the lane.
#
# Writes into the ladder's own tree so the summary script picks the cells up alongside it.
#
# Usage: t2831-diag.sh
# Env:   ROOT  ladder run directory (default ~/t2831seg)

set -u

ROOT="${ROOT:-$HOME/t2831seg}"
ARM_RIG="${ARM_RIG:-$HOME/t20-h3-arm.sh}"
export RECV=verbatim

[ -r "$ARM_RIG" ] || {
	echo "FAIL: missing $ARM_RIG" >&2
	exit 1
}

# run <label> <arm> <window> <env assignment>...
run() {
	local label=$1 arm=$2 window=$3
	shift 3
	echo "### $label / $arm"
	env "$@" OUTDIR="$ROOT/$label" timeout 500 bash "$ARM_RIG" "$label" "$arm" "$window" 2>&1 |
		grep -E "^bytes=|^cc_errors|^receiver=|^carriage"
}

run outage-5s-cubic moq 75 MOQ_CC=loss MOQ_QUIC_IDLE_TIMEOUT=120s OUTAGE_S=5 OUTAGE_AT=15
run outage-30s-cubic moq 75 MOQ_CC=loss MOQ_QUIC_IDLE_TIMEOUT=120s OUTAGE_S=30 OUTAGE_AT=15
run reorder-25-t60 h3 60 RECV_TIMEOUT=60 IMPAIR="delay 30ms reorder 25% 50%"
run step-0.5x-60s-t60 h3 90 RECV_TIMEOUT=60 IMPAIR="rate 20mbit" RATE_BASE=20mbit DIP_RATE=4.98mbit DIP_S=60 DIP_AT=20

echo "ALLDONE"

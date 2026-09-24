#!/usr/bin/env bash
# The MoQ arms of T28 and T31 re-run with the two knobs the published figures did not name --
# export padding and the relay's congestion controller -- and every cell graded on content.
#
# Padding is applied by the subscriber's exporter, after the shaped link, so it cannot change
# what the network delivers; it can only change what the PCR grader sees. One padded/unpadded
# twin on the capacity-and-outage ladder establishes that, and the matched ladder then runs
# unpadded under both controllers. The SRT arm is re-run once, matched on the unpadded BBRv3
# arm's measured latency, so that both lanes are ranked by the same content grader.
#
#   ladder-pad-delay     build default (padded), BBRv3     T31 rungs + T28 outages
#   ladder-unpad-delay   --mux-rate 0,           BBRv3     the same cells
#   ladder-unpad-loss    --mux-rate 0,           CUBIC     the same cells
#   matched-unpad-delay  --mux-rate 0,           BBRv3     outage / loss 5,10 / reorder 20, 3 budgets, 2 reps
#   matched-unpad-loss   --mux-rate 0,           CUBIC     the same
#   matched-srt          SRT at the BBRv3 arm's measured latency
#
# Usage: t2831-rerun-chain.sh <bindir> [outroot]     (runs its steps under sudo; ~2.3 h)
set -uo pipefail

BIN=${1:?bindir, e.g. ~/bin-<sha>}
ROOT=${2:-$HOME/t2831-rerun}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIP=${CLIP:-$HOME/clip120.ts}
mkdir -p "$ROOT"
LOG="$ROOT/chain.log"

step() {
	echo "=== $(date -u +%FT%TZ) start $1 ===" >>"$LOG"
	shift
	"$@" >>"$LOG" 2>&1
	echo "=== $(date -u +%FT%TZ) end rc=$? ===" >>"$LOG"
}

ladder() {
	local label=$1 mux=$2 cc=$3
	step "$label" sudo env MOQ="$BIN/moq" RELAY="$BIN/moq-relay" CLIP="$CLIP" \
		NETNS="$HOME/t8b-netns.sh" GRADER="$HOME/t28-media-lost.py" CONTENT="$HOME/t28-content-lost.py" \
		OUT="$ROOT/$label" MOQ_CC="$cc" ${mux:+MOQ_MUX_RATE=$mux} KEEP_TS=1 \
		bash "$HERE/t28-t31-moq-ladder.sh"
}

matched() {
	local label=$1 lanes=$2 mux=$3 cc=$4 match=${5:-}
	step "$label" sudo env BIN="$BIN" CLIP="$CLIP" VPID=111 NETNS="$HOME/t8b-netns.sh" \
		GRADER="$HOME/t28-media-lost.py" CONTENT="$HOME/t28-content-lost.py" \
		LATENCY="$HOME/t18-latency.py" OUT="$ROOT" LANES="$lanes" BUDGETS="0.5 2 6" REPS=2 \
		IMPAIRS="none outage loss5 loss10 reorder20" MOQ_CC="$cc" ${mux:+MOQ_MUX_RATE=$mux} \
		${match:+MATCH_FILE=$match} bash "$HERE/t28-t31-srt-ladder.sh" "$label"
}

ladder ladder-pad-delay "" delay
ladder ladder-unpad-delay 0 delay
ladder ladder-unpad-loss 0 loss
matched matched-unpad-delay moq 0 delay
matched matched-unpad-loss moq 0 loss

# SRT's `--latency` from the BBRv3 arm's measured unimpaired median at each budget.
awk -F, '$1=="moq" && $5=="none" && $13+0>0 {print $2, $13}' \
	"$ROOT/matched-unpad-delay/summary.csv" >"$ROOT/match.txt"
matched matched-srt srt "" delay "$ROOT/match.txt"

echo "=== $(date -u +%FT%TZ) chain done ===" >>"$LOG"

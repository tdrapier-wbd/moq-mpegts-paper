#!/usr/bin/env bash
# T8, segmented-HTTP arm — is the segmented lane's loss collapse the lane or the controller?
#
#   t8-cc-2x2.sh [seconds] [out-dir]
#
# T8 established, on the media-aware lane, that the loss collapse everyone attributes
# to MoQ is a CUBIC default: pinned to BBR the same lane holds rate through loss that
# flattens it under CUBIC. T5 then ran a head-to-head loss ladder and concluded the
# two lanes have disjoint weaknesses — the media-aware lane holds 0.96 of source rate
# at 10 % loss where segmented HTTP falls to 0.45 at 3 %.
#
# That conclusion has a hole in it, and it is the hole T8 itself dug. T5 pinned the
# media-aware arm to BBR *because* T8 showed the controller decides the result, and
# left the segmented arm on the system default, which is CUBIC. So T5's loss column
# compares QUIC/BBR against TCP/CUBIC: two variables moved at once, and the one T8
# proved decisive is the one that was not controlled.
#
# This runs the missing cells. Same host, same shaper, same fixture, same window as
# T5, with the full 2x2 of lane against controller:
#
#                 CUBIC / loss-based        BBR / delay-based
#   media-aware   moq   CC=loss             moq   CC=delay      (T5's arm)
#   segmented     hls   TCP_CC=cubic        hls   TCP_CC=bbr    (new)
#
# Read down a column to compare lanes at a fixed controller, which is the comparison
# T5 meant to publish. Read across a row to see what the controller is worth on that
# lane. If segmented HTTP under BBR holds rate where it collapsed under CUBIC, T5's
# loss finding is a controller result wearing a lane's label; if it still collapses,
# the finding is the lane's and is now established against the objection.
#
# Only the loss ladder is run. Reordering is where the *media-aware* lane fails and
# T5 established that at a pinned controller already; loss is the contested half.
set -uo pipefail

SECS=${1:-40}
OUT=${2:-$HOME/t8cc/sweep}
ARM=$(dirname "$(readlink -f "$0")")/t5-impair-arm.sh
[ -x "$ARM" ] || ARM=$HOME/t5-impair-arm.sh

mkdir -p "$OUT"
LOG=$OUT/results.txt
: >"$LOG"

# The base cell carries the same 15 ms as T5 so the ladder's first rung is that
# experiment's baseline and the two sets of numbers sit on the same scale.
CONDS=(
	"base|delay 15ms"
	"loss1|delay 15ms loss 1%"
	"loss3|delay 15ms loss 3%"
	"loss5|delay 15ms loss 5%"
	"loss10|delay 15ms loss 10%"
)

run_cell() {
	local tag=$1 arm=$2 name=$3 spec=$4
	shift 4
	local dir=$OUT/$tag-$name line
	printf '>>> %s / %s (%s)\n' "$tag" "$name" "$spec"
	line=$(env "$@" "$ARM" "$arm" "$spec" "$SECS" "$dir" 2>>"$OUT/errors.log" |
		grep '^RESULT' || true)
	[ -z "$line" ] && line="RESULT arm=$tag spec=\"$spec\" status=no_result"
	printf '%s cell=%s\n' "$line" "$name" | tee -a "$LOG"
	rm -f "$dir/capture.ts" "$dir"/seg*.ts "$dir/pcr.csv"
	sleep 3
}

for cell in "${CONDS[@]}"; do
	name=${cell%%|*}
	spec=${cell#*|}
	run_cell hls-cubic hls "$name" "$spec" TCP_CC=cubic
	run_cell hls-bbr hls "$name" "$spec" TCP_CC=bbr
	run_cell moq-cubic moq "$name" "$spec" CC=loss
	run_cell moq-bbr moq "$name" "$spec" CC=delay
done

echo
echo "=== 2x2, loss ladder ==="
cat "$LOG"

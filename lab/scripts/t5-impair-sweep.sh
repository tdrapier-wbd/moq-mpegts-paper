#!/usr/bin/env bash
# T5 impairment sweep — both data planes, one host, one shaper, one fixture.
#
#   t5-impair-sweep.sh [seconds] [out-dir]
#
# Runs the same netem ladder against the segmented-HTTP lane and the media-aware MoQ
# lane. The point of running both here is that T5's original arms are not comparable
# to each other: the media-aware numbers came off the real EC2->home path on an older
# build, and the opaque numbers off a ~0 RTT loopback with both QUIC hops shaped at
# once. Same host, same shaper, same clip and same window makes the two columns mean
# something side by side.
#
# Captures are deleted as they are graded; only the RESULT lines and the logs are
# kept, because 20 cells of 40 s at ~10 Mb/s is more than this box has spare.
set -uo pipefail

SECS=${1:-40}
OUT=${2:-$HOME/t5/sweep}
ARM=$(dirname "$(readlink -f "$0")")/t5-impair-arm.sh
[ -x "$ARM" ] || ARM=$HOME/t5-impair-arm.sh

mkdir -p "$OUT"
LOG=$OUT/results.txt
: >"$LOG"

# Ladder mirrors the conditions T5 already reports, plus a 10 % cell to find the
# cliff and a `slot` cell for jitter *without* reordering — `netem delay X Y` reorders
# at these swings, which is the trap that made the original jitter row read as a
# collapse (method-notes).
#
# `slot` needs its `packets`/`bytes` allowances set explicitly. Bare `slot MIN MAX`
# releases **one packet per slot**, which at these intervals is a ~200 kb/s rate cap
# rather than a jitter model: the first pass of this sweep read 0.77 Mb/s on the
# segmented lane and recorded a collapse that was entirely the instrument.
CONDS=(
	"base|delay 15ms"
	"delay+100|delay 115ms"
	"delay+200|delay 215ms"
	"loss0.1|delay 15ms loss 0.1%"
	"loss1|delay 15ms loss 1%"
	"loss3|delay 15ms loss 3%"
	"loss5|delay 15ms loss 5%"
	"loss10|delay 15ms loss 10%"
	"jitter-inorder|slot 30ms 90ms packets 64 bytes 131072"
	"reorder25|delay 15ms reorder 25% 50%"
)

for arm in hls moq; do
	for cell in "${CONDS[@]}"; do
		name=${cell%%|*}
		spec=${cell#*|}
		dir=$OUT/$arm-$name
		printf '>>> %s / %s (%s)\n' "$arm" "$name" "$spec"
		line=$("$ARM" "$arm" "$spec" "$SECS" "$dir" 2>>"$OUT/errors.log" | grep '^RESULT' || true)
		[ -z "$line" ] && line="RESULT arm=$arm spec=\"$spec\" status=no_result"
		printf '%s cell=%s\n' "$line" "$name" | tee -a "$LOG"
		rm -f "$dir/capture.ts" "$dir"/seg*.ts "$dir/pcr.csv"
		sleep 3
	done
done

echo
echo "=== sweep complete: $LOG ==="
cat "$LOG"

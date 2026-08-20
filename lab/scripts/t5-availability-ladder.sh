#!/usr/bin/env bash
# T5, segmented lane — find the loss depth at which segments expire rather than arrive late.
#
#   t5-availability-ladder.sh [seconds] [out-dir]
#
# T5's headline for this lane is that it "loses time, never bytes": across the whole
# original ladder it recorded 0 continuity errors and 0 HTTP non-200s, even in the cell
# delivering a sixth of source rate. That is a real result but it is bounded by the rig —
# the ladder stopped at 10 % commanded loss and the client never fell far enough behind
# for a segment to leave the origin's window. T5 observation 9 says so, and says the
# boundary is not established.
#
# This establishes it. Two things had to change from the original sweep:
#
#   * **Depth.** The ladder runs to 40 % loss, because at 8 % nothing aged out.
#   * **Duration.** The failure is cumulative, not instantaneous. A client delivering a
#     fraction f of source rate falls behind at (1-f) x realtime, so with 9 segments of
#     availability (--live 6 plus --live-extra-segments 3, 18 s at 2 s segments) it needs
#     18/(1-f) seconds before the first 404 is even possible. The 40 s cells of the
#     original sweep are too short to reach that for anything but a near-total collapse,
#     which is its own explanation for the 0.
#
# CUBIC throughout. T8 established that BBR holds full rate on this lane through 10 %
# loss, so a BBR arm would be measuring the controller's refusal to back off rather than
# the availability window; the window is only reachable via a controller that starves.
# That makes this a bound on the lane's *content* resilience under its worst controller,
# which is the claim T5 actually makes.
set -uo pipefail

SECS=${1:-120}
OUT=${2:-$HOME/t5/avail}
ARM=${ARM:-$HOME/t5-impair-arm.sh}
SEGSECS=${SEGSECS:-2}
[ -x "$ARM" ] || { echo "no arm script at $ARM" >&2; exit 1; }

mkdir -p "$OUT"
LOG=$OUT/results.txt
: >"$LOG"

CONDS=(
	"loss10|delay 15ms loss 10%"
	"loss15|delay 15ms loss 15%"
	"loss20|delay 15ms loss 20%"
	"loss30|delay 15ms loss 30%"
	"loss40|delay 15ms loss 40%"
)

for cell in "${CONDS[@]}"; do
	name=${cell%%|*}
	spec=${cell#*|}
	dir=$OUT/$name
	printf '>>> hls / %s (%s), %ss\n' "$name" "$spec" "$SECS"
	line=$(TCP_CC=cubic "$ARM" hls "$spec" "$SECS" "$dir" 2>>"$OUT/errors.log" |
		grep '^RESULT' || true)
	[ -z "$line" ] && line="RESULT arm=hls spec=\"$spec\" status=no_result"

	# The RESULT line counts non-200s but not how far behind the client was when they
	# started, and lag is what the window is a bound on. Recover it from the playlist:
	# the last sequence the client fetched against the last the origin published.
	lastget=$(grep -oE 'GET /seg-[0-9]+\.ts' "$dir/origin.log" 2>/dev/null |
		grep -oE '[0-9]+' | tail -1)
	lastpub=$(grep -oE 'seg-[0-9]+\.ts' "$dir/index.m3u8" 2>/dev/null |
		grep -oE '[0-9]+' | tail -1)
	# Seconds of programme between the newest segment the origin had published and the
	# newest the client had taken. Compare it against the retention window
	# (--live plus --live-extra-segments, times the segment duration): once the lag
	# exceeds that, the next sequential fetch is a 404 by construction.
	lag=""
	if [ -n "${lastget:-}" ] && [ -n "${lastpub:-}" ]; then
		lag=$(((10#$lastpub - 10#$lastget) * SEGSECS))
	fi

	# The single most useful derived number on this ladder: how long one segment fetch
	# actually took, in units of segment periods. Above 1 the client can never catch up,
	# and the retention window only sets how many periods of grace it gets first.
	fetch_ratio=$(awk -v g="$(grep -c 'GET /seg-' "$dir/origin.log" 2>/dev/null || echo 0)" \
		-v s="$SECS" -v d="$SEGSECS" \
		'BEGIN { if (g > 0) printf "%.1f", (s / g) / d; else print "NA" }')

	printf '%s cell=%s lag_s=%s fetch_periods=%s\n' \
		"$line" "$name" "${lag:-NA}" "$fetch_ratio" | tee -a "$LOG"

	rm -f "$dir/capture.ts" "$dir"/seg*.ts "$dir/pcr.csv"
	sleep 5
done

echo
echo "=== ladder complete: $LOG ==="
cat "$LOG"

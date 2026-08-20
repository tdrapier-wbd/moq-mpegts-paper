#!/usr/bin/env bash
# T13 wire cadence on the *segmented* lane — the same groomer legs as
# [`t13-cadence.sh`](t13-cadence.sh), fed by `tsp -I hls` instead of `moq export ts`.
#
# The file-domain matrix says the two lanes hand a groomer different problems: a MoQ
# egress carries no stuffing and declares no rate, so a stage has to add both, and nothing
# off the shelf adds stuffing while carrying a broadcast mux; a segmented egress arrives
# with the source's stuffing and the source's declared rate, so `tsp -P pcradjust` alone
# clears every file-domain criterion with the mux intact.
#
# That only settles half the job. The other half is the wire, and this lane's arrival
# shape is the worst case for it: whole segments land at once, so a pass-through stage is
# alternately flooded and starved on the segment period. Whether TSDuck's `regulate` can
# absorb that is the question this answers, and it cannot be inferred from the MoQ legs —
# there the arrivals are object-sized, here they are seconds long.
#
# Legs, all at the same nominal rate, one at a time so CPU contention is not read as jitter:
#
#   tsduck        pcradjust + regulate + -O ip, the pass-through chain
#   pacer-deep    mpegts-pacer at an 8 s cushion, the depth T12/T16 need on this lane
#   pacer-shallow the same at 1 s, to show the cushion is what is doing the work
#
# Usage: t13-cadence-segmented.sh <pacer-bin> <src.ts> [window_s] [nominal_bps]

set -uo pipefail

PACER="${1:?usage: t13-cadence-segmented.sh <pacer-bin> <src.ts> [window_s] [nominal_bps]}"
SRC="${2:?}"
WINDOW="${3:-25}"
NOMINAL="${4:-9945951}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT="$HOME/t13_cadence_seg"
PORT="${PORT:-8094}"
SEGDUR="${SEGDUR:-2}"

[[ -x "$PACER" ]] || { echo "not executable: $PACER" >&2; exit 1; }
[[ -r "$SRC" ]] || { echo "no such source: $SRC" >&2; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT/origin"

ORIGIN_PIDS=()
cleanup() {
	for p in "${ORIGIN_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
	sleep 1
	for p in "${ORIGIN_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null || true; done
	pkill -f "[h]ttp.server $PORT" 2>/dev/null || true
}
trap cleanup EXIT

# One origin for the whole run. Every leg subscribes to the same live playlist, so the
# legs differ only in the groomer, which is the point of the comparison.
start_origin() {
	tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
		-O hls "$OUT/origin/seg.ts" --playlist "$OUT/origin/index.m3u8" \
		--duration "$SEGDUR" --live 6 --live-extra-segments 3 \
		--intra-close --align-first-segment >"$OUT/pkg.log" 2>&1 &
	ORIGIN_PIDS+=("$!")

	(cd "$OUT/origin" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
		>"$OUT/origin.log" 2>&1 &
	ORIGIN_PIDS+=("$!")

	local n=0
	for _ in $(seq 1 90); do
		n=$(grep -c '\.ts$' "$OUT/origin/index.m3u8" 2>/dev/null || echo 0)
		[[ "$n" -ge 3 ]] && return 0
		sleep 1
	done
	echo "packager produced nothing; see $OUT/pkg.log" >&2
	return 1
}

run_leg() { # run_leg <name> <port> <rtp|udp> <groomer...>
	local name=$1 port=$2 kind=$3
	shift 3
	echo "=== $name (port $port)"

	python3 "$HERE/t13-cadence.py" capture "$port" "$OUT/$name" "$WINDOW" \
		"$([[ $kind == rtp ]] && echo rtp)" >"$OUT/$name.cap.log" 2>&1 &
	local capture=$!
	sleep 1

	tsp -I hls "http://127.0.0.1:$PORT/index.m3u8" --live 2>"$OUT/$name.sub.log" |
		"$@" >"$OUT/$name.groom.log" 2>&1 &
	local chain=$!

	wait $capture
	kill "$chain" 2>/dev/null
	pkill -f "[t]sp -I hls http://127.0.0.1:$PORT" 2>/dev/null
	sleep 3
	cat "$OUT/$name.cap.log"
}

start_origin || exit 1

# The rate the pass-through chain paces at must come from a capture of its own input,
# not from the nominal and not from another stage's output (T13 Corrections). On this
# lane the egress carries stuffing, so this should land on the nominal rather than below
# it — unlike the MoQ lane, where the two differ by the stuffing that was dropped.
echo "==> measuring the segmented egress rate this chain will receive"
tsp -I hls "http://127.0.0.1:$PORT/index.m3u8" --live -P until --seconds 12 \
	-O file "$OUT/content.ts" >"$OUT/content.log" 2>&1
CONTENT=$(tsp -I file "$OUT/content.ts" -P analyze --normalized -O drop 2>/dev/null |
	grep '^ts:' | tr ':' '\n' | grep '^bitrate=' | head -1 | cut -d= -f2)
[[ -n "${CONTENT:-}" && "$CONTENT" -gt 0 ]] || { echo "could not measure egress rate" >&2; exit 1; }
echo "    segmented egress declares $CONTENT b/s (nominal $NOMINAL)"
sleep 3

run_leg tsduck 5012 udp \
	tsp --bitrate "$CONTENT" -I file - \
	-P pcradjust --bitrate "$CONTENT" \
	-P regulate --bitrate "$CONTENT" \
	-O ip 127.0.0.1:5012 --enforce-burst --packet-burst 7

run_leg pacer-deep 5013 rtp \
	"$PACER" 127.0.0.1:5013 "$NOMINAL" --rtp \
	--latency-ms 8000 --max-latency-ms 12000 --stall-ms 1000 --on-stall mute

run_leg pacer-shallow 5014 rtp \
	"$PACER" 127.0.0.1:5014 "$NOMINAL" --rtp \
	--latency-ms 1000 --max-latency-ms 2000 --stall-ms 1000 --on-stall mute

cleanup
trap - EXIT

echo
python3 "$HERE/t13-cadence.py" report "$OUT"/tsduck.csv "$OUT"/pacer-deep.csv "$OUT"/pacer-shallow.csv
echo
echo "PCR conformance of each stream as received:"
for f in "$OUT"/tsduck.ts "$OUT"/pacer-deep.ts "$OUT"/pacer-shallow.ts; do
	[[ -s "$f" ]] || continue
	n481=$(tsp -I file "$f" -P pcrverify --absolute --jitter-max 13 -O drop 2>&1 |
		grep -c 'PCR jitter')
	rep=$(tsp -I file "$f" -P pcrverify --absolute --jitter-max 13 -O drop 2>&1 |
		grep -c 'interval')
	printf "  %-16s %s\n" "$(basename "$f")" "jitter>481ns=$n481 interval-msgs=$rep"
done

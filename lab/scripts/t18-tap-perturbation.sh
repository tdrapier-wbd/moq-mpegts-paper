#!/usr/bin/env bash
# P1-m, step 1 — does the latency tap perturb the stream it measures?
#
# Every SRT cell in P1-m's first pass graded 4.196–5.391 s of media lost, on *unimpaired* controls
# as well as on impaired ones. A clean control that loses five seconds is not reporting a transport;
# it is reporting the instrument. The suspicion is `t18-latency.py tap --pipe`, which sits inline
# in the media path: it reads a block, parses every 188-octet packet in it for PES headers, writes
# the block on and flushes. At ~950 blocks a second that is Python between a real-time sender and a
# real-time receiver, and whatever it costs is paid as backpressure.
#
# **Why the defect was invisible on the lane that mattered.** The MoQ lane's exporter demultiplexes
# and remultiplexes: it mints its own continuity counters and regenerates PCR onto a synthetic grid.
# Damage done *upstream* of it is therefore laundered — the capture downstream is internally
# consistent whatever the tap did to the bytes going in, and `t28-media-lost.py` grades PCR against
# byte position, so it sees nothing. The SRT lane carries the mux verbatim, so the same damage
# survives to the grader. A single instrument produced ~0 on one lane and 5 s on the other, and the
# difference was read as a property of the transports.
#
# THE THREE ARMS. One clean SRT lane, no impairment, no shaping beyond the standing netns, run three
# ways that differ only in how the stream is observed:
#
#   none    `tsp -I srt … -O file out.ts`                      — the reference. Nothing observes it,
#           so there is no latency figure; this arm exists solely to establish what the lane loses
#           when no instrument is present, which no previous run measured.
#   inline  `tsp -I srt … -O file - | tap --pipe --save out.ts` — the current rig, reproduced
#           deliberately. If this does not show the 4–5 s, the hypothesis is wrong and the real
#           cause is still at large.
#   mirror  `tsp -I srt … -P fork --nowait 'tap --pipe' -O file out.ts` — the replacement. `fork`
#           hands a *copy* of each packet to the tap's stdin while the main chain continues to the
#           file, so the tap can be arbitrarily slow without the media path ever waiting on it.
#           `--nowait` keeps tsp from blocking on the child at teardown.
#
# The graded capture in every arm is `out.ts`, and in `mirror` it comes straight from tsp and has
# never passed through Python. That is the whole point of the change.
#
# PASS CRITERIA, fixed before the run:
#   1. `none` loses < 0.1 s of media. If it does not, the artefact is not the tap and this
#      experiment has found something else — stop and attribute that first.
#   2. `inline` reproduces the 4–5 s. Without this the rig is not reproducing the defect.
#   3. `mirror` is within 0.1 s of `none`, AND its `eg.csv` carries a comparable number of pictures
#      to `inline`'s. A tap that perturbs nothing because it observed nothing is not a fix, so the
#      picture count is a pass criterion and not a diagnostic.
#
#   sudo t18-tap-perturbation.sh <label>
#
# Env: BIN, CLIP, VPID, NETNS, GRADER, LATENCY, OUT, SECS.
set -uo pipefail

LABEL=${1:?label}
CLIP=${CLIP:-/home/ubuntu/clip120.ts}
VPID=${VPID:-111}
NETNS=${NETNS:-/home/ubuntu/t8b-netns.sh}
GRADER=${GRADER:-/home/ubuntu/t28-media-lost.py}
LATENCY=${LATENCY:-/home/ubuntu/t18-latency.py}
OUT=${OUT:-/home/ubuntu/p1m-tap}/$LABEL
SECS=${SECS:-60}
SRT_PORT=${SRT_PORT:-9200}
SRT_LATENCY_MS=${SRT_LATENCY_MS:-2000}
CAP_MBIT=${CAP_MBIT:-20}
DELAY_MS=${DELAY_MS:-50}

PUBIP=${PUBIP:-10.99.0.1}
pub() { ip netns exec t8b-pub "$@"; }
sub() { ip netns exec t8b-sub "$@"; }

rm -rf "$OUT"; mkdir -p "$OUT"

cleanup_procs() {
	pkill -9 -f "[t]sp -I srt" 2>/dev/null
	pkill -9 -f "[t]sp -I file - -O srt" 2>/dev/null
	pkill -9 -f "[t]sp -I file $CLIP" 2>/dev/null
	pkill -9 -f "python3 .*t18-latency\.py tap" 2>/dev/null
	sleep 1
}
trap 'cleanup_procs; bash "$NETNS" down >/dev/null 2>&1' EXIT

echo "=== $(date -u) t18-tap-perturbation $LABEL ==="
tsp --version 2>&1 | head -1
echo "clip=$CLIP secs=$SECS srt_latency=${SRT_LATENCY_MS}ms cap=${CAP_MBIT}Mb delay=${DELAY_MS}ms"

RATE_MBIT=$CAP_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" up || exit 1
RATE_MBIT=$CAP_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" cake || exit 1

# $1 arm name
run_arm() {
	local arm=$1
	local d="$OUT/$arm"
	mkdir -p "$d"
	cleanup_procs
	local tap_secs=$((SECS + 5))

	echo
	echo "== arm: $arm (${SECS}s) =="

	# The source side is varied independently of the egress side, because the first pass showed
	# they are not the same question: an inline tap on the *egress* perturbs nothing measurable,
	# while P1-m tapped both. The source tap sits between `regulate` and the SRT sender, which is
	# the one place in the chain where a slow reader starves a real-time transmitter.
	case "$arm" in
	src-inline)
		pub bash -c "tsp -I file '$CLIP' --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null \
		  | python3 '$LATENCY' tap $VPID '$d/src.csv' --pipe --seconds $tap_secs \
		  | tsp -I file - -O srt --listener '0.0.0.0:$SRT_PORT' \
			--transtype live --latency $SRT_LATENCY_MS" >"$d/pub.log" 2>&1 &
		;;
	src-mirror)
		pub bash -c "tsp -I file '$CLIP' --infinite -P regulate --pcr-synchronous \
			-P fork --nowait --ignore-abort \
			  \"python3 '$LATENCY' tap $VPID '$d/src.csv' --pipe --seconds $tap_secs > /dev/null\" \
			-O srt --listener '0.0.0.0:$SRT_PORT' \
			--transtype live --latency $SRT_LATENCY_MS" >"$d/pub.log" 2>&1 &
		;;
	*)
		pub bash -c "tsp -I file '$CLIP' --infinite -P regulate --pcr-synchronous -O srt \
			--listener '0.0.0.0:$SRT_PORT' --transtype live --latency $SRT_LATENCY_MS" \
			>"$d/pub.log" 2>&1 &
		;;
	esac

	# Wait for the listener rather than guessing: `regulate` has to fill before tsp starts its
	# output plugin, and TSDuck's SRT caller makes exactly one attempt.
	local bound=0
	for _ in $(seq 1 40); do
		if pub ss -lun 2>/dev/null | grep -q ":$SRT_PORT"; then bound=1; break; fi
		sleep 1
	done
	[ "$bound" = 1 ] || { echo "   VOID: SRT listener never bound"; return 1; }

	case "$arm" in
	none | src-inline | src-mirror)
		sub bash -c "timeout $((SECS + 3)) tsp -I srt --caller '$PUBIP:$SRT_PORT' \
			--transtype live --latency $SRT_LATENCY_MS -O file '$d/out.ts'" \
			>"$d/sub.log" 2>&1
		;;
	inline)
		sub bash -c "timeout $((SECS + 3)) tsp -I srt --caller '$PUBIP:$SRT_PORT' \
			--transtype live --latency $SRT_LATENCY_MS -O file - \
		  | python3 '$LATENCY' tap $VPID '$d/eg.csv' --pipe --seconds $tap_secs \
			--save '$d/out.ts' > /dev/null" \
			>"$d/sub.log" 2>&1
		;;
	mirror)
		# `fork` duplicates packets to the child's stdin; the main chain continues to -O file.
		# The child writes its CSV and discards the stream, so nothing downstream of it exists
		# to block on. `--ignore-abort` means a tap that dies cannot take the capture with it.
		sub bash -c "timeout $((SECS + 3)) tsp -I srt --caller '$PUBIP:$SRT_PORT' \
			--transtype live --latency $SRT_LATENCY_MS \
			-P fork --nowait --ignore-abort \
			  \"python3 '$LATENCY' tap $VPID '$d/eg.csv' --pipe --seconds $tap_secs > /dev/null\" \
			-O file '$d/out.ts'" \
			>"$d/sub.log" 2>&1
		;;
	esac

	cleanup_procs
	local n=0
	n=$(stat -c%s "$d/out.ts" 2>/dev/null || echo 0)
	printf '   capture: %s B (%s packets)\n' "$n" "$((n / 188))"
	if [ "$n" -lt 2000000 ]; then
		echo "   VOID: under the 2 MB floor — this arm grades nothing"
		return 1
	fi
	python3 "$GRADER" --input "$d/out.ts" --domain file --pid "$VPID" \
		--json "$d/lost.json" >"$d/lost.txt" 2>&1
	grep -iE 'media lost|duplicat|nominal|continuity' "$d/lost.txt" | sed 's/^/   /'
	for c in "$d/eg.csv" "$d/src.csv"; do
		[ -f "$c" ] && printf '   %s tap saw %s pictures\n' "$(basename "$c" .csv)" "$(($(wc -l <"$c") - 1))"
	done
	[ -f "$d/eg.csv" ] || [ -f "$d/src.csv" ] || echo "   tap: none (reference arm)"
}

for arm in ${ARMS:-none inline mirror src-inline src-mirror}; do
	run_arm "$arm"
done

echo
echo "=== summary ==="
printf '  %-8s %14s %12s %10s\n' arm media_lost_s duplicated_s pictures
for arm in ${ARMS:-none inline mirror src-inline src-mirror}; do
	f="$OUT/$arm/lost.json"
	lost=$(python3 -c "import json,sys;print(f\"{json.load(open(sys.argv[1])).get('media_lost_s',0):.3f}\")" "$f" 2>/dev/null || echo "-")
	dup=$(python3 -c "import json,sys;print(f\"{json.load(open(sys.argv[1])).get('media_duplicated_s',0):.3f}\")" "$f" 2>/dev/null || echo "-")
	csv="$OUT/$arm/eg.csv"; [ -f "$csv" ] || csv="$OUT/$arm/src.csv"
	pics=$(($(wc -l <"$csv" 2>/dev/null || echo 1) - 1))
	[ "$pics" -le 0 ] && pics="-"
	printf '  %-8s %14s %12s %10s\n' "$arm" "$lost" "$dup" "$pics"
done
echo
echo "pass: none < 0.1 s; inline reproduces 4-5 s; mirror within 0.1 s of none at comparable pictures"
echo "=== $(date -u) done: $OUT ==="

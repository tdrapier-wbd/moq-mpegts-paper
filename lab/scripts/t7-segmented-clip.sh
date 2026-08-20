#!/usr/bin/env bash
# T7, segmented-HTTP arm — TR 101 290 P1 on one clip, ungroomed and groomed.
#
#   t7-segmented-clip.sh <src.ts> <out-dir> [capture-seconds] [segment-seconds]
#
# T7 graded the media-aware lane's groomed egress against P1 across four clips of
# deliberately different shape — a synthetic exact-CBR reference, a 27.5 Mbps 4:2:2
# broadcast mux, and two real contribution captures. Only one of those clips has
# ever been through the segmented lane, so what is untested is not whether the
# chain grooms (T16 settled that) but whether it grooms *whatever it is given*.
# Bitrate, GOP structure and native PCR cadence all differ across these four, and
# the segment boundary is chosen by picture type, so they are not interchangeable
# inputs.
#
#   tsp -O hls -> HTTP origin -> tsp -I hls -> [mpegts-pacer] -> capture -> P1
#
# Two arms per clip, off one publisher:
#
#   A  ungroomed   the segmented egress as delivered, the baseline P1 is measured against
#   B  groomed     `mpegts-pacer` sizing its own buffer from the arrival pattern,
#                  which is the configuration T16 found sufficient
#
# Both arms are live: the groomer is pacing a stream, not re-writing a file. That
# distinction is the whole of T7's correction — reading a file the stage places
# PCRs wherever the arithmetic wants them, and delivering live it can only place
# one when it has a packet ready at the deadline. So every figure here is the
# delivered one, and there is no file-domain column to be misread as conformance.
#
# Prints one `RESULT ` line per arm.
set -uo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
SECS=${3:-45}
SEGSECS=${4:-2}

PORT=${PORT:-18120}
UDP=${UDP:-19120}
PACER=${PACER_REPO:-$HOME/mpegts-pacer}
HEADROOM=${HEADROOM:-1.15}
STARTUP=${STARTUP:-25}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLIP=$(basename "$SRC" .ts)

rm -rf "$OUT"
mkdir -p "$OUT/hls"

# T6 learned this the expensive way and the lesson is not specific to T6: a rig
# with a fixed port and no identity check will quietly grade whatever is already
# serving that port. Here that would be the previous clip's stream, which is the
# one failure this sweep is least able to notice, because a wrong-clip capture is
# still a perfectly conformant capture. So refuse to start on a busy port, and
# then prove the origin answering is this cell's.
CELL_ID="t7-$CLIP-$$-$(date +%s)"
port_free_or_die() {
	for _ in $(seq 1 30); do
		lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || return 0
		sleep 1
	done
	echo "RESULT clip=$CLIP arm=- status=PORT_BUSY port=$PORT"
	exit 1
}
port_free_or_die

PIDS=()
ORIGIN_PID=""
cleanup() {
	for p in ${PIDS+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done
	[ -n "$ORIGIN_PID" ] && kill "$ORIGIN_PID" 2>/dev/null
	wait 2>/dev/null || true
}
trap cleanup EXIT

# The groomer, built from whichever name this checkout carries.
(cd "$PACER" && { cargo build --release --bin mpegts-pacer ||
	cargo build --release --example ts_egress; }) >"$OUT/build.log" 2>&1 || {
	echo "RESULT clip=$CLIP arm=- status=BUILD_FAILED"
	exit 1
}
TARGET=$(cd "$PACER" && cargo metadata --format-version 1 --no-deps |
	sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')
EGRESS=""
for c in "$TARGET/release/mpegts-pacer" "$TARGET/release/examples/ts_egress"; do
	[ -x "$c" ] && { EGRESS=$c; break; }
done
[ -n "$EGRESS" ] || { echo "RESULT clip=$CLIP arm=- status=NO_PACER"; exit 1; }

CONTENT=$(python3 "$SCRIPTS/t13-grade.py" rate "$SRC")
RATE=$(python3 -c "print(int($CONTENT * $HEADROOM))")

# --- P1 grading, identical for both arms ---------------------------------------
# Every column T7's per-clip table carries, computed from the delivered bytes.
grade() {
	local arm=$1 cap=$2
	local bytes ccerr pcrv pcr analyze bitrate pcrbitrate
	bytes=$(stat -f%z "$cap" 2>/dev/null || echo 0)
	if [ "$bytes" -lt 100000 ]; then
		echo "RESULT clip=$CLIP arm=$arm status=NO_CAPTURE bytes=$bytes"
		return
	fi

	ccerr=$(tsp -I file "$cap" -P continuity -O drop 2>&1 | grep -c 'discontinuity' || true)
	: "${ccerr:=0}"

	# PCR accuracy at the P2 limit: ±500 ns is 13 PCR units at 27 MHz. Take the
	# count off pcrverify's own summary line rather than by counting its per-PCR
	# reports, which it stops emitting past its message limit.
	local pcrok
	pcrv=$(tsp -I file "$cap" -P pcrverify --absolute --jitter-max 13 -O drop 2>&1 |
		sed -n 's/.*, \([0-9][0-9]*\) with jitter >.*/\1/p' | tail -1)
	pcrok=$(tsp -I file "$cap" -P pcrverify --absolute --jitter-max 13 -O drop 2>&1 |
		sed -n 's/.*pcrverify: \([0-9,]*\) PCR OK.*/\1/p' | tail -1 | tr -d ,)
	: "${pcrv:=0}" "${pcrok:=0}"

	tsp -I file "$cap" -P pcrextract --pcr --csv -o "$OUT/$arm-pcr.csv" -O drop >/dev/null 2>&1
	pcr="pcr_max_ms=0 pcr_over40=0 pcr_pct40=0 pcr_n=0"
	[ -s "$OUT/$arm-pcr.csv" ] && pcr=$(awk -F, 'NR>1 && $6!=""{c=$6+0;
		if(p!=""){d=(c-p)/27000; if(d>0){n++; if(d>mx)mx=d; if(d>40)o++}}
		p=c}
		END{if(n)printf "pcr_max_ms=%.2f pcr_over40=%d pcr_pct40=%.4f pcr_n=%d",mx,o,o/n*100,n;
		    else printf "pcr_max_ms=0 pcr_over40=0 pcr_pct40=0 pcr_n=0"}' "$OUT/$arm-pcr.csv")

	analyze=$(tsp -I file "$cap" -P analyze -O drop 2>&1)
	echo "$analyze" >"$OUT/$arm-analyze.txt"
	# "exact CBR" in T7's table is these two agreeing: the rate the stream declares
	# and the rate its own PCR timeline implies.
	bitrate=$(echo "$analyze" | sed -n 's/.*User-specified: *\.*\ *\([0-9,]*\) b\/s.*/\1/p' | head -1 | tr -d ,)
	pcrbitrate=$(echo "$analyze" | sed -n "s/.*Estimated based on PCR's: *\.*\ *\([0-9,]*\) b\/s.*/\1/p" | head -1 | tr -d ,)
	: "${bitrate:=0}" "${pcrbitrate:=0}"

	echo "RESULT clip=$CLIP arm=$arm bytes=$bytes $pcr" \
		"pcr_ok=$pcrok pcrverify_viol=$pcrv cc_disc=$ccerr" \
		"bitrate=$bitrate pcrbitrate=$pcrbitrate status=ok"
}

# --- publisher and origin -------------------------------------------------------
tsp --realtime \
	-I file "$SRC" --infinite \
	-P regulate --pcr-synchronous \
	-O hls "$OUT/hls/seg.ts" \
	--playlist "$OUT/hls/index.m3u8" \
	--duration "$SEGSECS" \
	--live 6 --live-extra-segments 3 \
	--intra-close --align-first-segment \
	>"$OUT/publish.log" 2>&1 &
PIDS+=($!)

echo "$CELL_ID" >"$OUT/hls/cell-id"
(cd "$OUT/hls" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
	>"$OUT/origin.log" 2>&1 &
ORIGIN_PID=$!

for _ in $(seq 1 150); do
	[ -f "$OUT/hls/index.m3u8" ] &&
		[ "$(grep -c '\.ts$' "$OUT/hls/index.m3u8" 2>/dev/null || echo 0)" -ge 3 ] && break
	sleep 1
done
[ -f "$OUT/hls/index.m3u8" ] || { echo "RESULT clip=$CLIP arm=- status=NO_PLAYLIST"; exit 1; }

SERVED=$(curl -fsS --max-time 5 "http://127.0.0.1:$PORT/cell-id" 2>/dev/null || echo none)
[ "$SERVED" = "$CELL_ID" ] || {
	echo "RESULT clip=$CLIP arm=- status=FOREIGN_ORIGIN served=$SERVED"
	exit 1
}

URL="http://127.0.0.1:$PORT/index.m3u8"

# --- arm A: ungroomed -----------------------------------------------------------
tsp --realtime -I hls "$URL" --live \
	-P until --seconds "$SECS" \
	-O file "$OUT/a-ungroomed.ts" >"$OUT/receive-a.log" 2>&1
grade a-ungroomed "$OUT/a-ungroomed.ts"

# --- arm B: groomed, adaptive ----------------------------------------------------
# Captured off a loopback UDP socket rather than a pipe, because that is where a
# groomed egress actually goes and it is the measurement point T13 used on the
# media-aware lane.
python3 "$SCRIPTS/t13-cadence.py" capture "$UDP" "$OUT/b-groomed" "$SECS" \
	>"$OUT/capture-b.log" 2>&1 &
CAP=$!
sleep 1
tsp --realtime -I hls "$URL" --live \
	-P until --seconds "$((SECS + STARTUP))" \
	-O file - 2>"$OUT/receive-b.log" |
	"$EGRESS" "127.0.0.1:$UDP" "$RATE" >"$OUT/pacer-b.log" 2>&1
wait "$CAP" 2>/dev/null || true
grade b-groomed "$OUT/b-groomed.ts"

# --- arm C: groomed, cushion raised past the adaptive ceiling ---------------------
# Only run when asked. The adaptive sizer clamps at an 8 s ceiling, which is a
# constant while the thing it has to absorb — a segment period's worth of bytes —
# is not. This arm lifts the ceiling to test whether a clip that fails arm B fails
# because the lane cannot be groomed or because the ceiling was set for a lower rate.
if [ -n "${DEEP_MS:-}" ]; then
	python3 "$SCRIPTS/t13-cadence.py" capture "$UDP" "$OUT/c-groomed-deep" "$SECS" \
		>"$OUT/capture-c.log" 2>&1 &
	CAP=$!
	sleep 1
	tsp --realtime -I hls "$URL" --live \
		-P until --seconds "$((SECS + STARTUP + DEEP_MS / 1000))" \
		-O file - 2>"$OUT/receive-c.log" |
		"$EGRESS" "127.0.0.1:$UDP" "$RATE" \
			--latency-ms "$DEEP_MS" --max-latency-ms "$((DEEP_MS * 2))" --stall-ms 9000 \
			>"$OUT/pacer-c.log" 2>&1
	wait "$CAP" 2>/dev/null || true
	grade c-groomed-deep "$OUT/c-groomed-deep.ts"
fi

echo "INFO clip=$CLIP content_bps=$CONTENT target_bps=$RATE segsecs=$SEGSECS window=$SECS"

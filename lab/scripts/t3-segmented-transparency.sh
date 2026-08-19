#!/usr/bin/env bash
# T3 segmented-HTTP arm — transport transparency of TS-in-HLS, one clip, one invocation.
#
#   t3-segmented-transparency.sh <src.ts> <out-dir> [media_seconds] [segment_seconds]
#
# tsp -O hls (TS segments + live playlist) -> static HTTP origin -> tsp -I hls
# -> the reassembled TS, captured ungroomed.
#
# The measurement point is the *ungroomed* egress, matching T3's opaque arm, which
# ran the subscriber with --no-pacing. T16 measures the groomed version of this same
# chain; this arm is deliberately the raw reassembly output, because T3 asks whether
# the mux survived, not whether it can be re-paced.
#
# Bounded by PACKET COUNT, not wall clock. `tsp -I hls --live` drains the live
# window faster than real time before settling (T9's loopback span artefact, which
# T14 measurement 5 and T16 both hit), so a wall-clock window carries an unknown
# amount of media and no count in it can be compared with anything. A packet bound
# makes the egress window and the source reference cover the same quantity of mux.
#
# Background processes do not survive between tool invocations in this environment,
# so publisher, origin and receiver are all started and torn down here.
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
SECS=${3:-60}
SEGSECS=${4:-2}
PORT=${PORT:-18085}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command -v tsp >/dev/null || {
	echo "tsp not found" >&2
	exit 1
}
[ -f "$SRC" ] || {
	echo "no such source: $SRC" >&2
	exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT/hls"

# --- how many packets is $SECS of this clip? -----------------------------------
# From the clip's own PCR timeline, so the bound is media rather than wall time.
SRCBPS=$(tsp -I file "$SRC" -P until --packets 200000 -P analyze --normalized -O drop 2>/dev/null |
	sed -n 's/^ts:.*:pcrbitrate=\([0-9]*\):.*/\1/p' | head -1)
[ -n "$SRCBPS" ] || {
	echo "could not derive source PCR bitrate" >&2
	exit 1
}
NPKT=$((SRCBPS * SECS / 8 / 188))
echo "source ${SRCBPS} b/s (PCR-derived); ${SECS}s = ${NPKT} packets"

PIDS=()
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

# --- publisher: live-rate TS in, TS segments + sliding live playlist out -------
# --intra-close starts every segment on an I-frame; the plugin writes a PAT and PMT
# at the head of each segment natively (the spec's Media Initialization Section),
# which is the addition this experiment is scored against.
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
PUB_START=$(date +%s)

# --- origin: static file server over the segment directory --------------------
(cd "$OUT/hls" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
	>"$OUT/origin.log" 2>&1 &
PIDS+=($!)

# The receiver needs the live window filled before it starts, or `tsp -I hls` exits
# on an empty playlist.
echo "waiting for the publisher to fill the live window..."
for _ in $(seq 1 180); do
	if [ -f "$OUT/hls/index.m3u8" ] &&
		[ "$(grep -c '^seg.*\.ts$' "$OUT/hls/index.m3u8" || true)" -ge 3 ]; then
		break
	fi
	sleep 1
done
[ -f "$OUT/hls/index.m3u8" ] || {
	echo "no playlist produced; see $OUT/publish.log" >&2
	exit 1
}
cp "$OUT/hls/index.m3u8" "$OUT/playlist-sample.m3u8"
SEG_BEFORE=$(find "$OUT/hls" -name 'seg*.ts' | wc -l | tr -d ' ')

# --- source reference cut, same packet count, ALIGNED TO THE EGRESS MEDIA ------
# An equal-packet cut taken from position 0 is only a valid content reference if the
# mux is homogeneous, and one of these clips is not: `testloop_clean` carries 18.4 %
# stuffing over its first 60 s against 13.1-13.8 % later on, so a head cut reads as
# the lane having stripped stuffing when nothing was stripped.
#
# The publisher starts at file position 0 and paces off the source PCR, so its
# position when the receiver joins is its elapsed run time; the receiver then joins
# roughly a live window behind that. Offsetting the reference by the difference puts
# both windows on the same region of the clip. The residual is one segment either
# way, which is why homogeneity across the reference is reported rather than assumed.
ELAPSED=$(($(date +%s) - PUB_START))
WINDOW_S=$(awk -v d="$SEGSECS" 'BEGIN {printf "%d", d * 3}')
REF_SKIP_S=$((ELAPSED - WINDOW_S))
[ "$REF_SKIP_S" -lt 0 ] && REF_SKIP_S=0
REF_SKIP=$((SRCBPS * REF_SKIP_S / 8 / 188))
echo "publisher ran ${ELAPSED}s before the join; reference offset ${REF_SKIP_S}s (${REF_SKIP} packets)"
tsp -I file "$SRC" \
	-P skip --packets "$REF_SKIP" \
	-P until --packets "$NPKT" \
	-O file "$OUT/source-ref.ts" >/dev/null 2>&1

# --- receiver: playlist -> TS, ungroomed, captured -----------------------------
echo "capturing ${NPKT} packets from the live edge..."
set +e
tsp --realtime \
	-I hls "http://127.0.0.1:$PORT/index.m3u8" --live \
	-P until --packets "$NPKT" \
	-O file "$OUT/egress.ts" >"$OUT/receive.log" 2>&1
set -e

SEG_AFTER=$(find "$OUT/hls" -name 'seg*.ts' | wc -l | tr -d ' ')
# `--intra-close` overshoots the target to land on an I-frame, so the achieved
# duration is what any per-segment figure has to be divided by. Taken from the
# publisher's own EXTINF values across every playlist it wrote.
cat "$OUT/playlist-sample.m3u8" "$OUT/hls/index.m3u8" >"$OUT/extinf-sample.txt" 2>/dev/null || true
MEANINF=$(awk -F: '/^#EXTINF/ {gsub(/,.*/, "", $2); s += $2; n++}
	END {if (n) printf "%.3f", s / n}' "$OUT/extinf-sample.txt" 2>/dev/null || true)
{
	echo "segments_on_disk_before=$SEG_BEFORE"
	echo "segments_on_disk_after=$SEG_AFTER"
	echo "segment_target_s=$SEGSECS"
	echo "segment_mean_extinf_s=${MEANINF:-}"
	echo "packets_requested=$NPKT"
	echo "source_pcrbitrate=$SRCBPS"
	echo "reference_skip_packets=$REF_SKIP"
	echo "reference_skip_seconds=$REF_SKIP_S"
} >"$OUT/run.env"

[ -s "$OUT/egress.ts" ] || {
	echo "no egress captured; see $OUT/receive.log" >&2
	exit 1
}

echo
python3 "$SCRIPTS/t3-transparency.py" "$OUT/source-ref.ts" "$OUT/egress.ts" \
	--label "$(basename "$SRC" .ts)" --run-env "$OUT/run.env" | tee "$OUT/report.txt"

echo
echo "artefacts in $OUT: egress.ts source-ref.ts report.txt run.env playlist-sample.m3u8"

#!/usr/bin/env bash
# T13, file domain: put a MoQ egress through every candidate CBR/PCR grooming
# chain and leave the outputs side by side for [`t13-grade.py`](t13-grade.py).
#
# The input must be a real `moq ... export ts` capture. A source clip with PID
# 0x1FFF stripped looks equivalent and is not: it carries the source's own byte
# schedule, and a groomer fed that drops content it would keep on a live egress
# (see the T13 Corrections).
#
# The variants are the off-the-shelf suggestions plus the pacer as a control:
#
#   pacer-nominal   the pacer at the source's mux rate
#   pacer-auto      the pacer choosing its own rate
#   pcradjust       TSDuck re-stamping PCR against the *content* rate, no stuffing
#   pcradjust-mux   the same, but asking `mux` to pad up to the nominal rate first,
#                   which is the interesting negative result: tsp cannot inflate a
#                   stream, so nothing is inserted and the stream then claims a
#                   rate it does not carry
#   regulate        TSDuck pacing alone, the most commonly suggested answer
#   ffmpeg          `-muxrate`, which re-muxes
#   ffmpeg-pinned   `-muxrate` with every PID pinned back to its original value
#   gst-pinned      `tsdemux ! mpegtsmux bitrate=`, PIDs pinned at both ends
#   gst-scte35      the same, asking tsdemux to forward SCTE-35 as section events
#                   so mpegtsmux can re-insert them on a single splice PID
#
# The GStreamer branches are derived from the input by `t13-grade.py gstbranches`
# rather than written out, because both ends can only be pinned per stream. Note
# the queues: with default sizes the remux deadlocks and produces nothing.
#
# Usage: t13-groom-matrix.sh <pacer-examples-dir> <label> <egress.ts> <nominal_bps> [content_bps]

set -euo pipefail

PACER_DIR="${1:?usage: t13-groom-matrix.sh <pacer-dir> <label> <egress.ts> <nominal_bps> [content_bps]}"
LABEL="${2:?}"
IN="${3:?}"
NOMINAL="${4:?}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTENT="${5:-$(python3 "$HERE/t13-grade.py" rate "$IN")}"

OUT="$HOME/t13_$LABEL"
CBR_FILE="$PACER_DIR/cbr_file"

[[ -x "$CBR_FILE" ]] || {
	echo "not executable: $CBR_FILE" >&2
	exit 1
}

rm -rf "$OUT" && mkdir -p "$OUT"
NULLS="$OUT/nulls.ts"
tsp -I null 10000 -O file "$NULLS" >/dev/null 2>&1

echo "T13 $LABEL: nominal ${NOMINAL} b/s, content ${CONTENT} b/s, in $IN"

# Sorts first, so t13-grade.py takes it as the structural baseline.
cp "$IN" "$OUT/00-egress.ts"

"$CBR_FILE" "$IN" "$OUT/01-pacer-nominal.ts" "$NOMINAL" regenerate
"$CBR_FILE" "$IN" "$OUT/02-pacer-auto.ts" auto regenerate

tsp --bitrate "$CONTENT" -I file "$IN" \
	-P pcradjust --bitrate "$CONTENT" \
	-O file "$OUT/03-tsduck-pcradjust.ts"

tsp --bitrate "$CONTENT" -I file "$IN" \
	-P mux "$NULLS" --bitrate $((NOMINAL - CONTENT)) \
	-P pcradjust --bitrate "$NOMINAL" \
	-O file "$OUT/04-tsduck-pcradjust-mux.ts"

tsp --bitrate "$CONTENT" -I file "$IN" \
	-P regulate --bitrate "$CONTENT" \
	-O file "$OUT/05-tsduck-regulate.ts"

ffmpeg -nostdin -loglevel error -y -i "$IN" -map 0 -copy_unknown -c copy \
	-muxrate "$NOMINAL" -f mpegts "$OUT/06-ffmpeg-muxrate.ts"

# Pin every PID back. -streamid indexes ffmpeg's stream order, so read the
# original assignment off the input rather than assuming it. ffprobe reports the
# PID in hex, which bash arithmetic converts; `mapfile` is unavailable in the
# bash 3.2 that ships with macOS.
PMT_PID=$(tsp -I file "$IN" -P analyze --normalized -O drop 2>/dev/null |
	tr ':' '\n' | sed -n 's/^pmtpid=\([0-9]*\)$/\1/p' | head -1)
PIN=()
while IFS=, read -r index id; do
	[[ -n "$index" ]] || continue
	PIN+=(-streamid "$index:$((id))")
done < <(ffprobe -v error -show_entries stream=index,id -of csv=p=0 "$IN")

ffmpeg -nostdin -loglevel error -y -i "$IN" -map 0 -copy_unknown -c copy \
	-muxrate "$NOMINAL" -mpegts_pmt_start_pid "${PMT_PID:-4096}" "${PIN[@]}" \
	-f mpegts "$OUT/07-ffmpeg-pinned.ts"

GST_BRANCHES=()
while IFS= read -r token; do GST_BRANCHES+=("$token"); done < <(
	python3 "$HERE/t13-grade.py" gstbranches "$IN" 2>"$OUT/gst-unbranched.txt"
)

gst-launch-1.0 -q filesrc location="$IN" ! tsdemux name=d \
	mpegtsmux name=m bitrate="$NOMINAL" \
	! filesink location="$OUT/08-gst-pinned.ts" \
	"${GST_BRANCHES[@]}"

# tsdemux hands SCTE-35 to the muxer as section events, and mpegtsmux has room for
# one splice PID, so a mux with several of them can only keep the first.
SCTE_PID=$(tsp -I file "$IN" -P analyze --normalized -O drop 2>/dev/null |
	sed -n 's/^pid:pid=\([0-9]*\):.*SCTE 35.*/\1/p' | head -1)
if [[ -n "$SCTE_PID" ]]; then
	gst-launch-1.0 -q filesrc location="$IN" ! tsdemux name=d send-scte35-events=true \
		mpegtsmux name=m bitrate="$NOMINAL" scte-35-pid="$SCTE_PID" \
		! filesink location="$OUT/09-gst-scte35.ts" \
		"${GST_BRANCHES[@]}"
fi

rm -f "$NULLS"
echo
echo "streams GStreamer could not branch:"
sed 's/^/  /' "$OUT/gst-unbranched.txt"
echo
echo "outputs in $OUT; grade with:"
echo "  python3 $HERE/t13-grade.py grade $OUT"

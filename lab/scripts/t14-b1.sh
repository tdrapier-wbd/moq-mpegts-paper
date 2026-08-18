#!/usr/bin/env bash
# T14 arm B1 — classic HLS carrying MPEG-TS, symmetric TSDuck, one invocation.
#
#   t14-b1.sh <src.ts> <out-dir> <capture-seconds> [segment-seconds]
#
# tsp -O hls (segments + live playlist) -> static HTTP origin -> tsp -I hls
# -> cadence instrument -> reassembled TS.
#
# The chain is deliberately the same shape as leg A (MoQ): a live-rate publisher,
# a network hop, a reassembly stage, and the *same* cadence instrument on the
# ungroomed egress. Grooming is not applied here — measurement 2 is about what the
# reassembly stage hands the groomer, so the pacer is downstream of this script.
#
# Background processes do not survive between tool invocations in this
# environment, so publisher, origin and receiver are all started and torn down
# here.
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
SECS=${3:?capture seconds}
SEGSECS=${4:-2}
PORT=${PORT:-18080}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command -v tsp >/dev/null || {
	echo "tsp not found" >&2
	exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT/hls"

PIDS=()
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

# --- publisher: live-rate TS in, TS segments + sliding live playlist out --------
# --intra-close starts every segment on an I-frame; the plugin writes a PAT and PMT
# at the head of each segment natively (the spec's Media Initialization Section).
# --live-extra-segments is the Availability Duration knob: segments stay fetchable
# after leaving the playlist.
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

# --- origin: static file server over the segment directory ---------------------
# HTTP/1.1. A caching HTTP/3 hop is what measurements 3 and 5 need; measurement 2
# (burst granularity) and 4 (mux survival) do not depend on it, and this keeps the
# arm runnable with nothing installed.
(cd "$OUT/hls" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
	>"$OUT/origin.log" 2>&1 &
PIDS+=($!)

# Wait for a playlist with enough segments that --live has a live edge to join.
echo "waiting for the publisher to fill the live window..."
for _ in $(seq 1 120); do
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

# --- receiver: playlist -> TS, timestamped on the way out ----------------------
echo "capturing ${SECS}s from the live edge..."
set +e
tsp --realtime \
	-I hls "http://127.0.0.1:$PORT/index.m3u8" --live \
	-O file - 2>"$OUT/receive.log" |
	python3 "$SCRIPTS/t13-cadence.py" pipe "$OUT/b1-egress" "$SECS"
set -e

echo
echo "=== playlist as published ==="
cat "$OUT/playlist-sample.m3u8"
echo
echo "=== cadence of the ungroomed egress ==="
python3 "$SCRIPTS/t13-cadence.py" report "$OUT/b1-egress.csv"
echo
echo "artefacts in $OUT: b1-egress.ts b1-egress.csv publish.log receive.log"

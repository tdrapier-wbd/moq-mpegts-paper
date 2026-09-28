#!/usr/bin/env bash
# T10 arm D — one TS file through the segmented lane, captured to file, in one invocation.
#
#   t10-hls.sh <src.ts> <out-dir>
#
# tsp -O hls (TS segments + live playlist) -> static HTTP origin -> tsp -I hls -> file: the T3/T14
# rig with its flags unchanged, so any difference from those single-programme results is the
# multiplex's doing. The receiver starts once three segments exist and WITHOUT --live, so it begins
# at the first listed segment and the capture covers the whole source rather than the live edge.
#
# Env: PORT (6490), SEGSECS (2), TAIL_S (seconds to let the receiver drain after the publisher
# ends; default 20).
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
PORT=${PORT:-6490}
SEGSECS=${SEGSECS:-2}
TAIL_S=${TAIL_S:-20}

[ -f "$SRC" ] || {
	echo "no such source: $SRC" >&2
	exit 1
}
rm -rf "$OUT"
mkdir -p "$OUT/hls"
{
	tsp --version 2>&1 | head -1
	echo "source: $SRC $(md5sum "$SRC" | cut -d' ' -f1)"
} >"$OUT/build.txt"

PIDS=()
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

tsp --realtime \
	-I file "$SRC" \
	-P regulate --pcr-synchronous \
	-O hls "$OUT/hls/seg.ts" \
	--playlist "$OUT/hls/index.m3u8" \
	--duration "$SEGSECS" \
	--live 6 --live-extra-segments 3 \
	--intra-close --align-first-segment \
	>"$OUT/publish.log" 2>&1 &
PUB=$!
PIDS+=("$PUB")

(cd "$OUT/hls" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) >"$OUT/origin.log" 2>&1 &
PIDS+=($!)

for _ in $(seq 1 120); do
	if [ -f "$OUT/hls/index.m3u8" ] &&
		[ "$(grep -c '^seg.*\.ts$' "$OUT/hls/index.m3u8" || true)" -ge 3 ]; then
		break
	fi
	kill -0 "$PUB" 2>/dev/null || break
	sleep 1
done
[ -f "$OUT/hls/index.m3u8" ] || {
	echo "no playlist produced; see $OUT/publish.log" >&2
	tail -5 "$OUT/publish.log" >&2
	exit 1
}
cp "$OUT/hls/index.m3u8" "$OUT/playlist-early.m3u8"
cp "$OUT/hls/seg-000000.ts" "$OUT/first-segment.ts" 2>/dev/null || true

tsp -I hls "http://127.0.0.1:$PORT/index.m3u8" -O file "$OUT/egress.ts" 2>"$OUT/receive.log" &
RECV=$!
PIDS+=("$RECV")

wait "$PUB" || echo "publisher exit $?" >>"$OUT/publish.log"
cp "$OUT/hls/index.m3u8" "$OUT/playlist-final.m3u8" 2>/dev/null || true
for _ in $(seq 1 "$TAIL_S"); do
	kill -0 "$RECV" 2>/dev/null || break
	sleep 1
done
cleanup
trap - EXIT

{
	# The live window deletes old segments, so count them from the final playlist's media sequence.
	echo "segments_published=$(awk -F: '/^#EXT-X-MEDIA-SEQUENCE/ { s = $2 } /^seg.*\.ts$/ { n++ } END { print s + n }' \
		"$OUT/playlist-final.m3u8" 2>/dev/null || echo unknown)"
	echo "egress_bytes=$(stat -c%s "$OUT/egress.ts" 2>/dev/null || echo 0)"
} | tee "$OUT/run.env"
[ -s "$OUT/egress.ts" ] || {
	echo "VOID: no egress captured; see $OUT/receive.log" >&2
	exit 1
}

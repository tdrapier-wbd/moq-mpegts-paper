#!/usr/bin/env bash
# T65: two packagers (tsp -O hls, our epoch segmenter) read one paced source; four HLS receivers and
# Apple's validator read each, concurrently, for RUN_S seconds; segments are snapshotted as served.
#
#   lab/scripts/t65-hls-profile.sh <source.ts> <out-dir> [RUN_S]
#
# Grading is separate (lab/test-65-ird-hls-profile.md): t65-seg-structure.py on snap/{t,e},
# ts-si-survival.py and ts-pid-complete.py on each rx/*.ts, the validator's log in rx/V-*.log.
set -euo pipefail

SRC=$1
OUT=$2
RUN_S=${3:-120}
PORT=${PORT:-18650}
HERE=$(cd "$(dirname "$0")" && pwd)
TIMEOUT=${TIMEOUT:-/opt/homebrew/bin/timeout}

mkdir -p "$OUT"/www/t "$OUT"/www/e "$OUT"/snap/t "$OUT"/snap/e "$OUT"/rx "$OUT"/log
PIDS=()
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
	done
	[ -f "$OUT/nginx.pid" ] && nginx -c "$OUT/nginx.conf" -s quit 2>/dev/null || true
	wait 2>/dev/null || true
}
trap cleanup EXIT

cat >"$OUT/nginx.conf" <<EOF
worker_processes 1;
pid $OUT/nginx.pid;
error_log $OUT/log/nginx.error.log;
events { worker_connections 256; }
http {
	types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
	access_log $OUT/log/nginx.access.log;
	server {
		listen 127.0.0.1:$PORT;
		root $OUT/www;
		location ~ \.m3u8\$ { add_header Cache-Control no-cache; }
	}
}
EOF
nginx -c "$OUT/nginx.conf"

tsp --realtime -I file "$SRC" -P regulate --pcr-synchronous \
	-O hls "$OUT/www/t/seg.ts" --playlist "$OUT/www/t/index.m3u8" --duration 2 \
	--live 6 --live-extra-segments 3 --intra-close --align-first-segment \
	>"$OUT/log/pkg-t.log" 2>&1 &
PIDS+=($!)
tsp --realtime --max-flushed-packets 7 -I file "$SRC" -P regulate --pcr-synchronous -O file - 2>"$OUT/log/pkg-e-tsp.log" |
	python3 "$HERE/t65-epochseg-stdin.py" "$OUT/www/e" --pdt 2>"$OUT/log/pkg-e.log" &
PIDS+=($!)

listed() { [ -f "$1" ] && [ "$(grep -c '\.ts$' "$1" || true)" -ge 6 ]; }
for _ in $(seq 1 60); do
	listed "$OUT/www/t/index.m3u8" && listed "$OUT/www/e/index.m3u8" && break
	sleep 1
done
if ! { listed "$OUT/www/t/index.m3u8" && listed "$OUT/www/e/index.m3u8"; }; then
	echo "a packager did not fill its window; see $OUT/log/pkg-*.log" >&2
	exit 1
fi
cp "$OUT/www/t/index.m3u8" "$OUT/playlist-t.m3u8"
cp "$OUT/www/e/index.m3u8" "$OUT/playlist-e.m3u8"
echo "both windows full; receivers start for ${RUN_S}s"

RX=()
for a in t e; do
	URL="http://127.0.0.1:$PORT/$a/index.m3u8"
	"$TIMEOUT" -s INT "$RUN_S" tsp --realtime -I hls "$URL" --live -O file "$OUT/rx/tsp-$a.ts" \
		>"$OUT/log/rx-tsp-$a.log" 2>&1 &
	RX+=($!)
	"$TIMEOUT" -s INT "$RUN_S" ffmpeg -nostdin -hide_banner -loglevel warning -i "$URL" \
		-map 0 -c copy -copyts -f mpegts -y "$OUT/rx/ff-$a.ts" >"$OUT/log/rx-ff-$a.log" 2>&1 &
	RX+=($!)
	# hlsdemux holds a live playlist open through SIGINT's end-of-stream, so it is killed after 10 s.
	"$TIMEOUT" -s INT -k 10 "$RUN_S" gst-launch-1.0 -e souphttpsrc location="$URL" ! hlsdemux ! \
		filesink location="$OUT/rx/gst-$a.ts" >"$OUT/log/rx-gst-$a.log" 2>&1 &
	RX+=($!)
	python3 "$HERE/b8-hls-recv.py" "$URL" "$OUT/rx/b8-$a.ts" --seconds "$RUN_S" \
		--log "$OUT/log/rx-b8-$a.jsonl" >"$OUT/log/rx-b8-$a.log" 2>&1 &
	RX+=($!)
	mediastreamvalidator -t 90 -O "$OUT/rx/V-$a.json" "$URL" >"$OUT/rx/V-$a.log" 2>&1 &
	RX+=($!)
done

END=$(($(date +%s) + RUN_S + 5))
while [ "$(date +%s)" -lt "$END" ]; do
	for a in t e; do
		for f in $(grep '\.ts$' "$OUT/www/$a/index.m3u8" 2>/dev/null || true); do
			[ ! -e "$OUT/snap/$a/$f" ] && cp -p "$OUT/www/$a/$f" "$OUT/snap/$a/" 2>/dev/null || true
		done
	done
	sleep 4
done
for pid in "${RX[@]}"; do
	wait "$pid" || true
done
wc -c "$OUT"/rx/*.ts

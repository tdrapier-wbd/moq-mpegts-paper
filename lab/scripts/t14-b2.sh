#!/usr/bin/env bash
# T14 arm B2 — Low-Latency HLS carrying MPEG-TS partial segments.
#
#   t14-b2.sh <src.ts> <out-dir> <window-seconds> [client] [part-ms]
#     client: tsp (default) | ffmpeg
#     ORIGIN=nginx (default) | apple
#
# tsp -O ip -> mediastreamsegmenter (Apple HLS Tools) -> origin -> client
# -> cadence instrument.
#
# Two origins, because they test different things. `nginx` serves the segmenter's
# output as static files: the parts are individually addressable but the playlist
# carries no delivery directives, so a client must poll. `apple` builds and runs
# Apple's own `ll-hls-origin-example.go`, which synthesises a fully conformant
# low-latency playlist from the segmenter's `prog_index.m3u8` — adding
# `EXT-X-SERVER-CONTROL` with `CAN-BLOCK-RELOAD=YES` and `PART-HOLD-BACK`, and
# rewriting part URIs to its own `lowLatencySeg.ts?segment=` endpoint — and blocks
# the request until the requested part exists. Note the endpoint names are fixed by
# that origin: it reads `prog_index.m3u8` and publishes `lowLatencyHLS.m3u8`.
#
# Only the `apple` origin can settle whether a client declines parts because it
# cannot do low-latency at all, or merely because the origin never advertised that
# it could.
#
# Apple's tools are the only ones that produce `EXT-X-PART` with MPEG-TS parts;
# TSDuck, FFmpeg and Shaka all decline in different ways (see the experiment
# file). So the publish side is fixed, and the open question this rig answers is
# the *receive* side: does any freely available client actually fetch the parts?
#
# That question is settled at the HTTP layer rather than by inference. nginx logs
# every request, so `filePartN.M.ts` against `fileSequenceN.ts` in the access log
# says directly whether the client is running low-latency or has silently fallen
# back to classic segment fetching — which both candidates can do while appearing
# to work.
#
# Not used here: Apple's `ll-hls-origin-example.go`, which implements blocking
# playlist reload, delta updates and preload hints. It needs a Go toolchain that
# is not installed. Its absence costs *latency* (the client must poll rather than
# hold a request open) but not burst granularity, which is what this arm is for:
# the parts exist as separately fetchable resources either way.
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
WINDOW=${3:?window seconds}
CLIENT=${4:-tsp}
PARTMS=${5:-300}
PORT=${PORT:-18085}
UDP=${UDP:-9100}
SEGSECS=${SEGSECS:-2}
ORIGIN=${ORIGIN:-nginx}
APPLE_ORIGIN_SRC=${APPLE_ORIGIN_SRC:-/usr/local/share/hlstools/ll-hls-origin-example.go}
APPLE_ORIGIN_BIN=${APPLE_ORIGIN_BIN:-$HOME/llhls-origin/llhls-origin}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for tool in mediastreamsegmenter tsp; do
	command -v "$tool" >/dev/null || {
		echo "$tool not found" >&2
		exit 1
	}
done

case "$ORIGIN" in
nginx)
	command -v nginx >/dev/null || {
		echo "nginx not found" >&2
		exit 1
	}
	# Static origin: the segmenter's own index, fetched directly.
	INDEX=index.m3u8
	PLAYLIST=index.m3u8
	;;
apple)
	# Endpoint names are fixed by ll-hls-origin-example.go, not chosen here.
	INDEX=prog_index.m3u8
	PLAYLIST=lowLatencyHLS.m3u8
	if [ ! -x "$APPLE_ORIGIN_BIN" ]; then
		command -v go >/dev/null || {
			echo "go not found, needed to build $APPLE_ORIGIN_SRC" >&2
			exit 1
		}
		echo "building Apple LL-HLS origin..."
		mkdir -p "$(dirname "$APPLE_ORIGIN_BIN")"
		(cd "$(dirname "$APPLE_ORIGIN_BIN")" &&
			cp "$APPLE_ORIGIN_SRC" . &&
			{ [ -f go.mod ] || go mod init llhlsorigin >/dev/null; } &&
			go mod tidy >/dev/null 2>&1 &&
			go build -o "$APPLE_ORIGIN_BIN" .) || {
			echo "failed to build Apple origin" >&2
			exit 1
		}
	fi
	;;
*)
	echo "unknown ORIGIN $ORIGIN (want nginx or apple)" >&2
	exit 1
	;;
esac

rm -rf "$OUT"
mkdir -p "$OUT/hls" "$OUT/nginx/logs" "$OUT/nginx/conf"

PIDS=()
cleanup() {
	[ -f "$OUT/nginx/logs/nginx.pid" ] && nginx -p "$OUT/nginx" -c conf/nginx.conf -s quit 2>/dev/null || true
	for pid in ${PIDS+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
	pkill -f "mediastreamsegmenter.*$OUT" 2>/dev/null || true
	wait 2>/dev/null || true
}
trap cleanup EXIT

if [ "$ORIGIN" = apple ]; then
	"$APPLE_ORIGIN_BIN" -http "127.0.0.1:$PORT" -dir "$OUT/hls" >"$OUT/origin.log" 2>&1 &
	PIDS+=($!)
else

cat >"$OUT/nginx/conf/nginx.conf" <<CONF
worker_processes 1;
daemon on;
pid logs/nginx.pid;
error_log logs/error.log warn;
events { worker_connections 256; }
http {
    log_format bytes '\$msec \$request_method \$uri \$status \$bytes_sent \$body_bytes_sent \$request_length';
    access_log logs/access.log bytes;
    default_type video/mp2t;
    sendfile on;
    server {
        listen 127.0.0.1:$PORT;
        root $OUT/hls;
        location / { add_header Cache-Control "max-age=1"; }
    }
}
CONF
nginx -p "$OUT/nginx" -c conf/nginx.conf
fi

# --- publisher: Apple segmenter fed a paced TS over UDP ------------------------
mediastreamsegmenter \
	-w "$PARTMS" -t "$SEGSECS" --format=transport \
	-f "$OUT/hls" -i "$INDEX" -s 10 -D \
	"127.0.0.1:$UDP" >"$OUT/segmenter.log" 2>&1 &
PIDS+=($!)
sleep 2

tsp --realtime -I file "$SRC" --infinite \
	-P regulate --pcr-synchronous \
	-O ip "127.0.0.1:$UDP" >"$OUT/tsp-pub.log" 2>&1 &
PIDS+=($!)

# Wait for parts *and* for complete segments. A classic client needs the latter:
# at the live edge before the first segment closes the playlist holds only
# `EXT-X-PART` entries and a preload hint, and `tsp -I hls` rejects that outright
# with "empty HLS media playlist" rather than waiting. Starting the client then
# would measure the rig's timing, not the client's capability.
echo "waiting for partial segments and a filled live window..."
for _ in $(seq 1 90); do
	if [ -f "$OUT/hls/$INDEX" ] &&
		grep -q 'EXT-X-PART:' "$OUT/hls/$INDEX" &&
		[ "$(grep -c '^fileSequence.*\.ts$' "$OUT/hls/$INDEX" || true)" -ge 3 ]; then
		break
	fi
	sleep 1
done
grep -q 'EXT-X-PART:' "$OUT/hls/$INDEX" 2>/dev/null || {
	echo "no EXT-X-PART in playlist; see $OUT/segmenter.log" >&2
	exit 1
}

if [ "$ORIGIN" = apple ]; then
	LOG="$OUT/origin.log"
else
	LOG="$OUT/nginx/logs/access.log"
fi
MARK=$(wc -l <"$LOG" 2>/dev/null || echo 0)
URL="http://127.0.0.1:$PORT/$PLAYLIST"

echo "=== delivery directives the origin advertises ==="
curl -s "$URL" | grep -E '^#EXT-X-(SERVER-CONTROL|PART-INF)' || echo "  (none)"

echo "measuring ${WINDOW}s with client=$CLIENT..."
set +e
case "$CLIENT" in
tsp)
	tsp --realtime -I hls "$URL" --live -O file - 2>"$OUT/client.log" |
		python3 "$SCRIPTS/t13-cadence.py" pipe "$OUT/b2-egress" "$WINDOW"
	;;
ffmpeg)
	ffmpeg -nostdin -loglevel warning -i "$URL" -c copy -f mpegts - 2>"$OUT/client.log" |
		python3 "$SCRIPTS/t13-cadence.py" pipe "$OUT/b2-egress" "$WINDOW"
	;;
*)
	echo "unknown client $CLIENT" >&2
	exit 1
	;;
esac
set -e

# --- did the client actually run low-latency? ----------------------------------
# --- did the client actually run low-latency? ----------------------------------
# Matched on the whole log line rather than a fixed field, because the two origins
# name the same resource differently: nginx serves `filePart4.1.ts` directly, while
# Apple's rewrites it to `lowLatencySeg.ts?segment=filePart4.1.ts`.
echo
echo "=== what the client fetched ($ORIGIN origin log) ==="
tail -n "+$((MARK + 1))" "$LOG" |
	awk '{
		if ($0 ~ /filePart/)          parts++
		else if ($0 ~ /fileSequence/) segs++
		else if ($0 ~ /m3u8/)         pls++
		if ($0 ~ /_HLS_msn/)          blocking++
	}
	END {
		printf "  partial segments fetched : %d\n", parts
		printf "  full segments fetched    : %d\n", segs
		printf "  playlist fetches         : %d\n", pls
		printf "  blocking reloads (_HLS_msn) : %d\n", blocking
		if (parts > 0) print "  -> client IS running low-latency (fetching parts)"
		else           print "  -> client FELL BACK to classic segment fetching"
	}'

echo
python3 "$SCRIPTS/t13-cadence.py" report "$OUT/b2-egress.csv"

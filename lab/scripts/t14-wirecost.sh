#!/usr/bin/env bash
# T14 — segmented-HTTP carriage cost, measured at the HTTP layer.
#
#   t14-wirecost.sh <src.ts> <out-dir> <window-seconds> [segment-seconds]
#
# tsp -O hls -> nginx -> tsp -I hls, with nginx's access log as the instrument:
# $bytes_sent is every byte nginx put on the socket for a request, headers
# included, and $request_length is every byte it received. Summing those over a
# window gives exact HTTP-layer carriage, split by playlist against segment, with
# no privileges and nothing interposed in the path.
#
# Why the HTTP layer and not the wire. Per-packet framing cannot be measured
# honestly here: loopback's MTU is 16384, so datagram and segment counts bear no
# relation to a real path, and tcpdump needs root this environment does not have.
# T9 measured that framing on a real path instead (t9-overhead-wan.sh), and its
# arithmetic is per-packet and MTU-parameterised, so the honest division of labour
# is to measure the part T9 cannot (HTTP requests, response headers and playlist
# polling) and add framing from T9's table at a stated MTU.
#
# Everything starts and stops inside this invocation; background processes do not
# survive between tool calls here.
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
WINDOW=${3:?window seconds}
SEGSECS=${4:-2}
PORT=${PORT:-18081}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command -v nginx >/dev/null || {
	echo "nginx not found" >&2
	exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT/hls" "$OUT/nginx/logs"

PIDS=()
cleanup() {
	[ -f "$OUT/nginx/logs/nginx.pid" ] && nginx -p "$OUT/nginx" -c conf/nginx.conf -s quit 2>/dev/null || true
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

# --- nginx: static origin over the segment directory ---------------------------
# Access-log format is the measurement. HTTP/1.1 without TLS, deliberately: it is
# the header-cost upper bound, since HTTP/2 and HTTP/3 compress headers with
# HPACK/QPACK, and TLS records add a per-record cost accounted separately.
mkdir -p "$OUT/nginx/conf"
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

nginx -p "$OUT/nginx" -c conf/nginx.conf -t 2>&1 | sed 's/^/nginx: /'
nginx -p "$OUT/nginx" -c conf/nginx.conf

# --- publisher ------------------------------------------------------------------
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

echo "waiting for the live window to fill..."
for _ in $(seq 1 120); do
	if [ -f "$OUT/hls/index.m3u8" ] &&
		[ "$(grep -c '^seg.*\.ts$' "$OUT/hls/index.m3u8" || true)" -ge 3 ]; then
		break
	fi
	sleep 1
done
[ -f "$OUT/hls/index.m3u8" ] || {
	echo "no playlist; see $OUT/publish.log" >&2
	exit 1
}

# Mark the log so only requests inside the window are counted.
MARK=$(wc -l <"$OUT/nginx/logs/access.log" 2>/dev/null || echo 0)

# --- receiver: fetch through nginx, and record the delivered TS -----------------
echo "measuring ${WINDOW}s..."
set +e
tsp --realtime \
	-I hls "http://127.0.0.1:$PORT/index.m3u8" --live \
	-O file - 2>"$OUT/receive.log" |
	python3 "$SCRIPTS/t13-cadence.py" pipe "$OUT/wire-egress" "$WINDOW"
set -e

python3 "$SCRIPTS/t14-wirecost.py" \
	--access-log "$OUT/nginx/logs/access.log" \
	--skip-lines "$MARK" \
	--delivered-csv "$OUT/wire-egress.csv" \
	--source-bps "${SOURCE_BPS:-9945951}"

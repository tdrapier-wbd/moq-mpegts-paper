#!/usr/bin/env bash
# T70's origin: the clip, packaged by epoch and served by its own nginx, on a host that also runs
# standing units, which it leaves alone.
#
#   tsp regulate (video PTS tapped by a mirrored fork) -> UDP multicast on lo (its own group)
#     -> t61-epochseg.py --duration D --pdt -> nginx on :18690, under a path only the receiver knows
#
# Start it in its own session, so that stopping it is one signal to its process group and never a
# name pattern (the host's standing publisher is a `tsp` too):
#   cd <run>; nohup setsid bash t70-wan-origin.sh <run> <epoch-s> <path> [secs] > origin.log 2>&1 < /dev/null &
#   kill -TERM -- -"$(cat <run>/origin.pid)"
# Env: CLIP (~/contrib-10m.ts), SCRIPTS (this directory), PORT (18690), GROUP (239.255.0.70:5070)
set -uo pipefail

RUN=${1:?run dir}
EPOCH=${2:?epoch seconds: 1 or 2}
SECRET=${3:?path segment}
SECS=${4:-400}
SCRIPTS=${SCRIPTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
CLIP=${CLIP:-$HOME/contrib-10m.ts}
PORT=${PORT:-18690}
GROUP=${GROUP:-239.255.0.70:5070}
VPID=111
case "$EPOCH" in 1) TARGET=2 ;; 2) TARGET=4 ;; *) echo "epoch 1 or 2" >&2; exit 2 ;; esac

mkdir -p "$RUN"
RUN=$(cd "$RUN" && pwd)
echo $$ >"$RUN/origin.pid"
trap 'trap - EXIT TERM; kill -TERM -- -$$ 2>/dev/null' EXIT TERM
ev() { echo "$EPOCHREALTIME $*" >>"$RUN/origin-events.log"; }
ev "start epoch=$EPOCH target=$TARGET port=$PORT group=$GROUP"

tsp --realtime -I file "$CLIP" -P regulate --pcr-synchronous \
	-P fork --nowait --ignore-abort "python3 $SCRIPTS/t18-latency.py tap $VPID $RUN/src.csv --pipe --seconds $SECS > /dev/null" \
	-O ip "$GROUP" --local-address 127.0.0.1 --enforce-burst >"$RUN/source.log" 2>&1 &

www=$RUN/www/$SECRET
mkdir -p "$www" "$RUN/ngx/tmp"
nice -n 10 python3 "$SCRIPTS/t61-epochseg.py" "$www" --group "$GROUP" --duration "$EPOCH" --window 6 \
	--extra 3 --target "$TARGET" --pdt 2>"$RUN/seg.log" &

cat >"$RUN/ngx/nginx.conf" <<EOF
daemon off;
master_process off;
worker_processes 1;
pid ngx.pid;
error_log error.log info;
events { worker_connections 64; }
http {
	types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
	log_format t70 '\$msec \$status \$body_bytes_sent \$request_time';
	access_log access.log t70;
	client_body_temp_path tmp/body;
	proxy_temp_path tmp/proxy;
	fastcgi_temp_path tmp/fastcgi;
	uwsgi_temp_path tmp/uwsgi;
	scgi_temp_path tmp/scgi;
	sendfile on;
	keepalive_timeout 300s;
	keepalive_requests 100000;
	server {
		listen 0.0.0.0:$PORT;
		root $RUN/www;
		location ~ \.m3u8\$ { add_header Cache-Control "max-age=1" always; }
		location ~ \.ts\$ { add_header Cache-Control "max-age=60" always; }
	}
}
EOF
nginx -p "$RUN/ngx" -c "$RUN/ngx/nginx.conf" -e "$RUN/ngx/error.log" >"$RUN/ngx/stdout.log" 2>&1 &
ev "up"
sleep "$SECS"
ev "timeout"

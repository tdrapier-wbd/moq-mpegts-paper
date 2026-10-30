#!/usr/bin/env bash
# T69's origin, on a packager host (lab/test-69-segmented-access-and-scrambling.md, part C).
#
#   t69-aes-origin.sh start | stop | status
#
# `tsp` paces the clip into `-O hls` (clear segments in $P69/clear, never served); t69-aes-seg.py
# encrypts each into $P69/www/e and writes its keys to $P69/www/k; nginx on $PORT serves only www,
# and only to requests carrying the origin secret ($P69/origin-secret) that CloudFront adds. All
# three run detached and niced, and are stopped by their pid files, never by a pattern.
# Env: P69 (~/p69), PORT (18310), CLIP (~/contrib-10m.ts).

set -uo pipefail
P69=${P69:-$HOME/p69}
PORT=${PORT:-18310}
CLIP=${CLIP:-$HOME/contrib-10m.ts}
NGX=$P69/ngx

conf() {
	local secret
	secret=$(cat "$P69/origin-secret")
	umask 077
	cat >"$NGX/nginx.conf" <<EOF
worker_processes 2;
pid ngx.pid;
error_log error.log warn;
events { worker_connections 1024; }
http {
	types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; application/octet-stream key; }
	log_format p69 '\$msec \$status \$request_uri \$body_bytes_sent \$request_time';
	access_log access.log p69;
	client_body_temp_path tmp; proxy_temp_path tmp; fastcgi_temp_path tmp; uwsgi_temp_path tmp; scgi_temp_path tmp;
	sendfile on;
	keepalive_timeout 60;
	server {
		listen $PORT;
		root $P69/www;
		if (\$http_x_p69_origin != "$secret") { return 403; }
		location ~ \.m3u8\$ { add_header Cache-Control "max-age=1"; }
		location ~ \.(ts|key)\$ { add_header Cache-Control "max-age=60"; }
	}
}
EOF
}

start() {
	[ -s "$P69/origin-secret" ] || {
		echo "no $P69/origin-secret" >&2
		return 1
	}
	rm -rf "$P69/clear" "$P69/www"
	mkdir -p "$P69/clear" "$P69/www/e" "$P69/www/k" "$NGX/tmp"
	conf
	nice -n 10 nginx -p "$NGX" -c "$NGX/nginx.conf" -e "$NGX/error.log"
	local n
	n=$(date +%s)
	cd "$P69" || return 1
	setsid nohup nice -n 10 tsp --realtime -I file "$CLIP" --infinite -P regulate --pcr-synchronous \
		-O hls "$P69/clear/seg-$n.ts" --playlist "$P69/clear/index.m3u8" \
		--duration 2 --live 6 --live-extra-segments 3 --intra-close --start-media-sequence "$n" \
		>>"$P69/pack.log" 2>&1 </dev/null &
	echo $! >"$P69/pack.pid"
	setsid nohup nice -n 10 python3 "$P69/scripts/t69-aes-seg.py" "$P69/clear" "$P69/www" \
		--hashes "$P69/hashes.tsv" >>"$P69/aes.log" 2>&1 </dev/null &
	echo $! >"$P69/aes.pid"
	echo "$EPOCHREALTIME start n=$n" >>"$P69/events.log"
	sleep 1
	ss -ltn | grep -q ":$PORT " && echo "origin up on $PORT, first sequence $n" || echo "nginx failed" >&2
}

stop() {
	for f in aes pack; do
		[ -f "$P69/$f.pid" ] && kill "$(cat "$P69/$f.pid")" 2>/dev/null
		rm -f "$P69/$f.pid"
	done
	[ -f "$NGX/ngx.pid" ] && kill "$(cat "$NGX/ngx.pid")" 2>/dev/null
	sleep 1
	echo "$EPOCHREALTIME stop" >>"$P69/events.log"
	ss -ltn | grep -q ":$PORT " && echo "origin still listening" >&2 || echo "origin down"
}

status() {
	for f in pack aes; do
		if [ -f "$P69/$f.pid" ] && kill -0 "$(cat "$P69/$f.pid")" 2>/dev/null; then echo "$f up"; else echo "$f down"; fi
	done
	[ -f "$NGX/ngx.pid" ] && kill -0 "$(cat "$NGX/ngx.pid")" 2>/dev/null && echo "nginx up" || echo "nginx down"
	echo "segments hashed: $(wc -l <"$P69/hashes.tsv" 2>/dev/null || echo 0); keys: $(ls "$P69/www/k" 2>/dev/null | wc -l)"
	tail -n 3 "$P69/www/e/index.m3u8" 2>/dev/null
}

case "${1:-}" in
start) start ;;
stop) stop ;;
status) status ;;
*)
	sed -n '2,10p' "$0"
	exit 1
	;;
esac

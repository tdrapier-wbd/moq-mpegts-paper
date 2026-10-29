#!/usr/bin/env bash
# T59 pathway control, run on a packager host (lab/test-59-segmented-1plus1-cloudfront.md).
#
# One pathway is one packager reading this host's copy of the live feed, writing its own
# namespace, and one nginx origin serving it to CloudFront. Both run detached, so they outlive
# the ssh session that starts them, and the packager runs across cells as a 24/7 one would.
#
#   t59-pathway.sh origin-start | origin-stop | origin-reload
#   t59-pathway.sh pack-start [inject] | pack-kill | pack-freeze | pack-thaw
#   t59-pathway.sh status | down
#
# Env: P59 (default ~/p59), NS (namespace, "a" or "b"), PORT (18310), GROUP (239.255.0.1:5000).
# The origin secret is read from $P59/origin-secret; requests without it get 403.

set -uo pipefail
P59=${P59:-$HOME/p59}
NS=${NS:?set NS to the pathway namespace, a or b}
PORT=${PORT:-18310}
GROUP=${GROUP:-239.255.0.1:5000}
WWW=$P59/www
NGX=$P59/ngx
mkdir -p "$WWW/$NS" "$NGX"

origin_conf() {
	local secret
	secret=$(cat "$P59/origin-secret")
	cat >"$NGX/nginx.conf" <<EOF
worker_processes 2;
pid ngx.pid;
error_log error.log warn;
events { worker_connections 1024; }
http {
	types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
	log_format p59 '\$msec \$status \$request_uri \$body_bytes_sent \$request_time \$remote_addr';
	access_log access.log p59;
	client_body_temp_path tmp; proxy_temp_path tmp; fastcgi_temp_path tmp; uwsgi_temp_path tmp; scgi_temp_path tmp;
	sendfile on;
	keepalive_timeout 60;
	server {
		listen $PORT;
		root $WWW;
		if (\$http_x_p59_origin != "$secret") { return 403; }
		# T60's follow-up: /y/ and /z/ alias T61's /g/ with a playlist the edge must revalidate.
		location ~ ^/[yz]/.*\.m3u8\$ { add_header Cache-Control "max-age=0"; }
		location ~ \.m3u8\$ { add_header Cache-Control "max-age=1"; }
		location ~ \.ts\$ { add_header Cache-Control "max-age=60"; }
	}
}
EOF
	mkdir -p "$NGX/tmp"
}

origin_start() {
	origin_conf
	# Niced, as the packager is: the hosts carry T57's timing taps and the standing feed.
	nice -n 10 nginx -p "$NGX" -c "$NGX/nginx.conf" -e "$NGX/error.log"
	sleep 0.5
	ss -ltn | grep -q ":$PORT " && echo "origin up on $PORT" || { echo "origin failed" >&2; return 1; }
}

origin_stop() {
	[ -f "$NGX/ngx.pid" ] && kill "$(cat "$NGX/ngx.pid")" 2>/dev/null
	sleep 0.5
	ss -ltn | grep -q ":$PORT " && echo "origin still listening" >&2 || echo "origin down"
}

pack_start() {
	local n extra=(--slice-only)
	# The first name and media sequence come from the wall clock, so a restarted packager never
	# reuses a name a cache may still hold: seeded in seconds, a counter of 2 s segments falls
	# further behind the seed of any later restart the longer it runs.
	n=$(date +%s)
	[ "${1:-}" = inject ] && extra=(--align-first-segment)
	setsid nohup nice -n 10 tsp -I ip "$GROUP" --local-address 127.0.0.1 --buffer-size 16777216 \
		-O hls "$WWW/$NS/seg-$n.ts" --playlist "$WWW/$NS/index.m3u8" \
		--duration 2 --live 6 --live-extra-segments 3 --intra-close "${extra[@]}" \
		--start-media-sequence "$n" >>"$P59/pack.log" 2>&1 </dev/null &
	echo $! >"$P59/pack.pid"
	echo "$EPOCHREALTIME pack-start $NS n=$n ${extra[*]}" >>"$P59/events.log"
	echo "packager $! first=seg-$n.ts ${extra[*]}"
}

pack_signal() {
	local pid
	pid=$(cat "$P59/pack.pid" 2>/dev/null) || { echo "no packager" >&2; return 1; }
	kill "-$1" "$pid" && echo "$EPOCHREALTIME pack-$2 $NS" >>"$P59/events.log"
}

case "${1:-}" in
origin-start) origin_start ;;
origin-stop) origin_stop ;;
origin-reload) origin_conf && nginx -p "$NGX" -c "$NGX/nginx.conf" -s reload && echo "origin reloaded" ;;
pack-start) pack_start "${2:-}" ;;
pack-kill) pack_signal KILL kill ;;
pack-freeze) pack_signal STOP freeze ;;
pack-thaw) pack_signal CONT thaw ;;
status)
	pgrep -a -f "[t]sp -I ip $GROUP --local-address 127.0.0.1 --buffer-size 16777216 -O hls" | cut -c1-160
	ss -ltn | grep ":$PORT " || echo "no origin"
	ls "$WWW/$NS" | tail -3
	;;
down)
	pack_signal KILL kill 2>/dev/null
	origin_stop
	;;
*)
	echo "usage: NS=a|b t59-pathway.sh origin-start|origin-stop|pack-start [inject]|pack-kill|pack-freeze|pack-thaw|status|down" >&2
	exit 2
	;;
esac

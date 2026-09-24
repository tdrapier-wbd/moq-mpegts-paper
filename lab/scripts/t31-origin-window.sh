#!/usr/bin/env bash
# Whether the segmented lane's HTTP/3 origin can fill the netns rig's path at all.
#
# At 100 ms RTT and no bottleneck, the verbatim receiver fetched 3 MB segments in 4.5-5.3 s each --
# about 5 Mb/s, some 64 KB per round trip -- and fell behind a ~10 Mb/s stream. That is a window,
# not the path. This fetches one segment-sized object through a namespace-local nginx at each
# `http3_stream_buffer_size` given, and over HTTP/1.1 on TCP for comparison, and prints the rate.
#
# Usage: sudo t31-origin-window.sh [buffer ...]      (default: 64k 1m 16m; ~2 min)
# Env:   NETNS, CURL_H3, CERT_DIR, RATE_MBIT (20, the ladder's cake rate), DELAY_MS (50 per
#        direction), BYTES (3000000), REPS (3)
set -u

NETNS="${NETNS:-/home/ubuntu/t8b-netns.sh}"
CURL_H3="${CURL_H3:-/home/ubuntu/h3/bin/curl}"
CERT_DIR="${CERT_DIR:-/etc/nginx/h3}"
RATE_MBIT="${RATE_MBIT:-20}"
DELAY_MS="${DELAY_MS:-50}"
BYTES="${BYTES:-3000000}"
REPS="${REPS:-3}"
IP_PUB=10.99.0.1
BUFS=("$@")
[ ${#BUFS[@]} -eq 0 ] && BUFS=(64k 1m 16m)

[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo)" >&2
	exit 1
}
W=$(mktemp -d)
mkdir -p "$W/root" "$W/logs"
head -c "$BYTES" /dev/urandom >"$W/root/seg.ts"
trap '[ -s "$W/nginx.pid" ] && kill "$(cat "$W/nginx.pid")" 2>/dev/null; bash "$NETNS" down >/dev/null 2>&1; rm -rf "$W"' EXIT
trap 'exit 130' INT TERM

chmod 755 "$W" "$W/root"
chmod 644 "$W/root/seg.ts"
RATE_MBIT=$RATE_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" up >/dev/null || exit 1
RATE_MBIT=$RATE_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" cake | tail -1 || exit 1

fetch() { # label, curl args...
	local label="$1" r
	shift
	for r in $(seq "$REPS"); do
		ip netns exec t8b-sub "$@" --insecure -s -o /dev/null \
			-w "$label rep=$r http=%{http_version} bytes=%{size_download} ttfb_s=%{time_starttransfer} total_s=%{time_total} mbit=%{speed_download}\n" |
			awk '{for(i=1;i<=NF;i++) if($i ~ /^mbit=/){split($i,a,"="); $i=sprintf("mbit=%.2f", a[2]*8/1e6)}} 1'
	done
}

for buf in "${BUFS[@]}"; do
	cat >"$W/nginx.conf" <<-EOF
		worker_processes 1;
		pid $W/nginx.pid;
		error_log $W/logs/error.log warn;
		events { worker_connections 64; }
		http {
		    access_log off;
		    http3_stream_buffer_size $buf;
		    server {
		        listen $IP_PUB:8444 quic reuseport;
		        listen $IP_PUB:8445 ssl;
		        http3 on;
		        ssl_protocols TLSv1.3;
		        ssl_certificate $CERT_DIR/cert.pem;
		        ssl_certificate_key $CERT_DIR/key.pem;
		        root $W/root;
		    }
		}
	EOF
	ip netns exec t8b-pub nginx -p "$W" -c "$W/nginx.conf" || exit 1
	sleep 1
	fetch "h3 buf=$buf" "$CURL_H3" --http3-only "https://$IP_PUB:8444/seg.ts"
	[ "$buf" = "${BUFS[0]}" ] && fetch "h1-tcp" "$CURL_H3" --http1.1 "https://$IP_PUB:8445/seg.ts"
	kill "$(cat "$W/nginx.pid")"
	sleep 1
done

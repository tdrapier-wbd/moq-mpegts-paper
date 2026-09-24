#!/usr/bin/env bash
# T31's step-capacity ladder and T28's outages on the SEGMENTED lane, inside the T8b namespace rig.
#
# The segmented ladder ran on loopback with a `netem` token bucket because the only HTTP origin the
# campaign had was the host's nginx, which does not exist inside the namespaces; so it could be
# ranked against the MoQ lane only in the rig without an AQM. This puts an HTTP/3 origin inside
# the publisher namespace -- a second nginx, its own config, 10.99.0.1:8444 QUIC only -- and the
# byte-faithful receiver inside the subscriber namespace, and reuses `t28-t31-moq-ladder.sh`'s rig
# exactly: `t8b-netns.sh` veth, `cake` at 20 Mb/s, 100 ms base RTT, the same rungs as multiples of
# STREAM_MBIT, the same SETTLE / impairment / RECOVER timeline, re-shaped with `tc qdisc change`.
#
# The packager runs on the host filesystem, which the namespaces share; only the origin->receiver
# path crosses the bottleneck, as it does for the MoQ lane's relay->subscriber path.
#
# Graded as the MoQ ladder is -- content (video and audio PTS) from 8 s in, the PCR timeline in the
# wire domain beside it -- and the summary keeps the MoQ ladder's `cell`/`window_s` layout so
# `t2831-conservation.py` reads it unchanged. On this lane "short at close" is lag: the receiver
# fetches in order and never discards, so content not delivered by window close is late, and it is
# lost only where the receiver skipped (a 404, or a truncated segment under RECV_TRUNCATED=hole).
#
# Usage: sudo t31-seg-netns.sh [cell ...]
#   cells: control step-1.2x-60s step-0.9x-60s step-0.8x-5s step-0.8x-perm step-0.5x-60s
#          outage-5s outage-30s loss5 loss10, and step-<m>x-60s for any multiple m
# Env:   OUT, HLS_DIR (default /srv/hls-ns), RECV_TIMEOUT (15), RECV_TRUNCATED (abort), SEGDUR (2), H3_BUF (16m),
#        LIBCURL (~/h3/lib/libcurl.so.4; empty spawns curl per request),
#        STREAM_MBIT (9.95), CLIP, NETNS, GRADER, CONTENT, VERBATIM, CURL_H3, KEEP_TS=1
set -u

NETNS="${NETNS:-/home/ubuntu/t8b-netns.sh}"
CLIP="${CLIP:-/home/ubuntu/clip120.ts}"
GRADER="${GRADER:-/home/ubuntu/t28-media-lost.py}"
CONTENT="${CONTENT:-/home/ubuntu/t28-content-lost.py}"
VERBATIM="${VERBATIM:-/home/ubuntu/hls-verbatim-recv.py}"
CURL_H3="${CURL_H3:-/home/ubuntu/h3/bin/curl}"
CERT_DIR="${CERT_DIR:-/etc/nginx/h3}"
OUT="${OUT:-/home/ubuntu/t31-seg-netns}"
HLS_DIR="${HLS_DIR:-/srv/hls-ns}"
RECV_TIMEOUT="${RECV_TIMEOUT:-15}"
RECV_TRUNCATED="${RECV_TRUNCATED:-abort}"
SEGDUR="${SEGDUR:-2}"
# nginx's 64k default caps one HTTP/3 stream at ~64 KB per round trip -- ~4.8 Mb/s at this rig's
# 100 ms RTT, below the stream -- so the origin, not the path, would set every cell
# (t31-origin-window.sh).
H3_BUF="${H3_BUF:-16m}"
# One connection for the run, as a player keeps. Spawning curl per request restarts slow start
# twice a cycle, which at this RTT behind 20 Mb/s costs more than a segment's period; empty = spawn.
LIBCURL="${LIBCURL-/home/ubuntu/h3/lib/libcurl.so.4}"

PROV_MBIT=20
STREAM_MBIT="${STREAM_MBIT:-9.95}"
rate_for() { awk -v s="$STREAM_MBIT" -v m="$1" 'BEGIN{printf "%.2f", s*m}'; }
DELAY_MS=50
SETTLE=20
RECOVER=35
IP_PUB=10.99.0.1
H3_PORT=8444

[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo)" >&2
	exit 1
}
for f in "$NETNS" "$CLIP" "$GRADER" "$CONTENT" "$VERBATIM" "$CURL_H3" "$CERT_DIR/cert.pem" "$CERT_DIR/key.pem"; do
	[ -r "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done
command -v tsp >/dev/null && command -v nginx >/dev/null || {
	echo "FAIL: tsp and nginx are both required" >&2
	exit 1
}

CELLS=("$@")
[ ${#CELLS[@]} -eq 0 ] && CELLS=(control step-1.2x-60s step-0.9x-60s step-0.8x-5s step-0.8x-perm step-0.5x-60s outage-5s outage-30s loss5 loss10)

mkdir -p "$OUT" "$HLS_DIR"
NGX="$OUT/nginx"
mkdir -p "$NGX/logs"
SUMMARY="$OUT/summary.csv"
echo "cell,experiment,impairment,window_s,capture_bytes,media_lost_s,media_dup_s,holes,largest_hole_s,continuity_errors,video_lost_s,video_largest_s,audio_lost_s,recv_rc,recv_holes,batch_timeouts" >"$SUMMARY"
{
	echo "lane: segmented, HLS over HTTP/3, nginx $(nginx -v 2>&1 | sed 's/.*nginx\///') in t8b-pub, http3_stream_buffer_size $H3_BUF"
	echo "receiver: $(basename "$VERBATIM") via $("$CURL_H3" --version | head -1 | cut -d' ' -f1-2), ${LIBCURL:+one connection (libcurl), }timeout ${RECV_TIMEOUT}s, truncated=$RECV_TRUNCATED"
	echo "packager: tsp -O hls --live 6 --live-extra-segments 3 --duration $SEGDUR"
} | tee "$OUT/build.txt"

# The origin is its own nginx with its own prefix, so the host's h3lab vhosts are untouched and
# nothing here listens outside the namespace.
cat >"$NGX/nginx.conf" <<-EOF
	worker_processes 1;
	pid $NGX/nginx.pid;
	error_log $NGX/logs/error.log warn;
	events { worker_connections 256; }
	http {
	    types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
	    log_format seg '\$time_iso8601 proto=\$server_protocol http3=\$http3 \$status \$body_bytes_sent \$request_uri';
	    access_log $NGX/logs/access.log seg;
	    sendfile on;
	    http3_stream_buffer_size $H3_BUF;
	    server {
	        listen $IP_PUB:$H3_PORT quic reuseport;
	        http3 on;
	        ssl_protocols TLSv1.3;
	        ssl_certificate $CERT_DIR/cert.pem;
	        ssl_certificate_key $CERT_DIR/key.pem;
	        root $HLS_DIR;
	        location ~ \.m3u8\$ { add_header Cache-Control no-cache; }
	    }
	}
EOF

set_rate() { ip netns exec t8b-pub tc qdisc change dev veth-pub parent 1:1 handle 10: cake bandwidth "${1}mbit" >/dev/null 2>&1; }
set_loss() { ip netns exec t8b-pub tc qdisc change dev veth-pub root handle 1: netem delay "${DELAY_MS}ms" loss "${1}%" limit 100000 >/dev/null 2>&1; }
clear_loss() { ip netns exec t8b-pub tc qdisc change dev veth-pub root handle 1: netem delay "${DELAY_MS}ms" limit 100000 >/dev/null 2>&1; }

cleanup_procs() {
	[ -n "${RECV_PID:-}" ] && kill "$RECV_PID" 2>/dev/null
	[ -n "${PKG_PID:-}" ] && kill "$PKG_PID" 2>/dev/null
	pkill -f "tsp .*-O hls .*$HLS_DIR" 2>/dev/null
	RECV_PID="" PKG_PID=""
	sleep 1
}
stop_origin() { [ -s "$NGX/nginx.pid" ] && kill "$(cat "$NGX/nginx.pid")" 2>/dev/null; }
trap 'cleanup_procs; stop_origin; bash "$NETNS" down >/dev/null 2>&1' EXIT
trap 'exit 130' INT TERM

echo "== bringing the rig up =="
RATE_MBIT=$PROV_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" up || exit 1
RATE_MBIT=$PROV_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" cake || exit 1
ip netns exec t8b-pub nginx -t -p "$NGX" -c "$NGX/nginx.conf" 2>&1 | tail -1
ip netns exec t8b-pub nginx -p "$NGX" -c "$NGX/nginx.conf" || {
	echo "FAIL: origin did not start" >&2
	exit 1
}
sleep 1

run_cell() {
	local cell="$1" exp impair window mult
	case "$cell" in
	control) exp=both impair="none" window=$((SETTLE + 10 + RECOVER)) ;;
	step-0.8x-5s) exp=T31 impair="rate -> 0.8x stream for 5s" window=$((SETTLE + 5 + RECOVER)) ;;
	step-1.2x-60s) exp=T31 impair="rate -> 1.2x stream for 60s" window=$((SETTLE + 60 + RECOVER)) ;;
	step-0.9x-60s) exp=T31 impair="rate -> 0.9x stream for 60s" window=$((SETTLE + 60 + RECOVER)) ;;
	step-0.5x-60s) exp=T31 impair="rate -> 0.5x stream for 60s" window=$((SETTLE + 60 + RECOVER)) ;;
	step-0.8x-perm) exp=T31 impair="rate -> 0.8x stream permanent" window=$((SETTLE + 45 + 10)) ;;
	outage-5s) exp=T28 impair="100% loss for 5s" window=$((SETTLE + 5 + RECOVER)) ;;
	outage-30s) exp=T28 impair="100% loss for 30s" window=$((SETTLE + 30 + RECOVER)) ;;
	loss5) exp=T28 impair="5% random loss, whole window" window=$((SETTLE + 10 + RECOVER)) ;;
	loss10) exp=T28 impair="10% random loss, whole window" window=$((SETTLE + 10 + RECOVER)) ;;
	step-*x-60s)
		exp=T31 mult=${cell#step-}
		mult=${mult%x-60s}
		impair="rate -> ${mult}x stream for 60s" window=$((SETTLE + 60 + RECOVER))
		;;
	*)
		echo "unknown cell $cell"
		return 1
		;;
	esac

	local cap="$OUT/$cell.ts" log="$OUT/$cell"
	echo
	echo "== $cell ($exp) — $impair, ${window}s window =="
	set_rate $PROV_MBIT
	clear_loss
	rm -rf "${HLS_DIR:?}"/*
	: >"$NGX/logs/access.log"

	tsp --realtime -I file "$CLIP" --infinite -P regulate --pcr-synchronous \
		-O hls --live 6 --live-extra-segments 3 --duration "$SEGDUR" --intra-close \
		--align-first-segment --playlist "$HLS_DIR/index.m3u8" "$HLS_DIR/seg.ts" >"$log.pkg.log" 2>&1 &
	PKG_PID=$!
	local n
	for _ in $(seq 1 90); do
		n=$(find "$HLS_DIR" -name 'seg*.ts' | wc -l)
		[ "$n" -ge 4 ] && break
		sleep 1
	done

	# The loss cells impair the whole window, as T28's sustained-loss cells do.
	case "$cell" in
	loss5) set_loss 5 ;;
	loss10) set_loss 10 ;;
	esac

	ip netns exec t8b-sub python3 "$VERBATIM" "https://$IP_PUB:$H3_PORT/index.m3u8" -o "$cap" \
		--http-version 3 --curl "$CURL_H3" ${LIBCURL:+--libcurl "$LIBCURL"} --insecure --seconds "$window" \
		--timeout "$RECV_TIMEOUT" --truncated "$RECV_TRUNCATED" \
		--trace "$log.trace.csv" --origin-dir "$HLS_DIR" --summary "$log.recv.json" >"$log.recv.log" 2>&1 &
	RECV_PID=$!

	sleep "$SETTLE"
	case "$cell" in
	control | loss5 | loss10) sleep 10 ;;
	step-0.8x-5s) set_rate "$(rate_for 0.8)"; sleep 5; set_rate $PROV_MBIT ;;
	step-1.2x-60s) set_rate "$(rate_for 1.2)"; sleep 60; set_rate $PROV_MBIT ;;
	step-0.9x-60s) set_rate "$(rate_for 0.9)"; sleep 60; set_rate $PROV_MBIT ;;
	step-0.5x-60s) set_rate "$(rate_for 0.5)"; sleep 60; set_rate $PROV_MBIT ;;
	step-0.8x-perm) set_rate "$(rate_for 0.8)"; sleep 45 ;;
	outage-5s) set_loss 100; sleep 5; clear_loss ;;
	outage-30s) set_loss 100; sleep 30; clear_loss ;;
	step-*x-60s) set_rate "$(rate_for "$mult")"; sleep 60; set_rate $PROV_MBIT ;;
	esac
	case "$cell" in
	step-0.8x-perm) sleep 10 ;;
	*) sleep "$RECOVER" ;;
	esac

	local rc
	wait "$RECV_PID"
	rc=$?
	RECV_PID=""
	ip netns exec t8b-pub tc -s qdisc show dev veth-pub >"$log.qdisc.txt" 2>&1
	cp "$NGX/logs/access.log" "$log.origin.log"
	cleanup_procs

	local bytes
	bytes=$(stat -c%s "$cap" 2>/dev/null || echo 0)
	if [ "$bytes" -lt 200000 ]; then
		echo "   CELL VOID: only ${bytes}B captured (receiver rc=$rc)"
		echo "$cell,$exp,\"$impair\",$window,$bytes,VOID,VOID,VOID,VOID,VOID,VOID,VOID,VOID,$rc,VOID,VOID" >>"$SUMMARY"
		return 0
	fi
	python3 "$GRADER" --input "$cap" --domain wire --label "$cell" --json "$log.grade.json" 2>&1 | tail -1
	python3 "$CONTENT" --input "$cap" --from-s 8 --label "$cell" --json "$log.content.json" 2>&1 | tail -1
	python3 - "$log.grade.json" "$log.content.json" "$log.recv.json" "$cell" "$exp" "$impair" "$window" \
		"$bytes" "$rc" "$SUMMARY" <<-'PY'
		import json, sys
		def load(p):
		    try:
		        return json.load(open(p))
		    except (OSError, ValueError):
		        return {}
		g, c, r = load(sys.argv[1]), load(sys.argv[2]), load(sys.argv[3])
		row = [sys.argv[4], sys.argv[5], f'"{sys.argv[6]}"', sys.argv[7], sys.argv[8],
		       g.get("media_lost_s", "NA"), g.get("media_duplicated_s", "NA"), g.get("hole_count", "NA"),
		       g.get("largest_hole_s", "NA"), g.get("continuity_errors", "NA"),
		       c.get("content_lost_s", "NA"), c.get("largest_hole_s", "NA"), c.get("audio_lost_s", "NA"),
		       sys.argv[9], len(r.get("holes", [])) if r else "NA", r.get("batch_timeouts", "NA")]
		open(sys.argv[10], "a").write(",".join(str(x) for x in row) + "\n")
	PY
	[ "${KEEP_TS:-0}" = 1 ] || rm -f "$cap"
}

for c in "${CELLS[@]}"; do run_cell "$c"; done

echo
echo "== summary =="
column -s, -t "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
python3 "$(dirname "$CONTENT")/t2831-conservation.py" "$OUT" --csv "$OUT/conservation.csv" 2>/dev/null

#!/usr/bin/env bash
# T68 part A: one cell of the current segmented chain in T28's netns/cake rig.
#
#   tsp regulate on the host (video PTS tapped by a mirrored fork, T28's source tap)
#     -> UDP multicast on lo -> t61-epochseg.py (host) -> nginx in t8b-pub on 10.99.0.1:18683
#     == veth-pub: netem delay (the shape is applied here) -> cake 20 Mb/s ==>
#     b8-hls-recv.py in t8b-sub -> tee recv.ts -> mpegts-pacer --stream-clock -> t18-latency.py tap -> out.ts
#
# The namespaces, the bottleneck and the publisher namespace's TCP settings are the caller's
# (t68-netns-drive.py). The cell's clock starts at the groomer's first output, after its alignment
# watch: SETTLE s clean, then the shape, then the rest of the window, as T28's cells (a 5 s outage in
# a 60 s window; loss or reorder held 40 s in a 95 s one). At the window's end the receiver and the
# groomer stop together, so every cell of an arm is conserved against its control's window.
#
# Usage: t68-netns-cell.sh <out-dir> none|outage|loss<P>|reorder<P>       (as root)
# Env:   CLIP, PACER, SCRIPTS (the caller's ~/t68/scripts), RATE (11438000), LAT_MS (the cushion),
#        HOLD_MS (2500), ALIGN_MS (30000), CAP_MS (14000), STALL_MS (1000), POLL_MS (250),
#        RECV_TIMEOUT (3), GIVE_UP_MS (4000), SETTLE (20), OUTAGE (5), HELD (40), WINDOW (60 for none
#        and outage, 95 for loss and reorder), PATH_DELAY_MS (50, as the netns pair was brought up),
#        REORDER_DELAY_MS (50, T28's), KEEP_TS (unset: captures deleted once graded)
# Output: events.log, source/segmenter/origin/receiver/groomer logs, src.csv, eg.csv, grade.json.
set -uo pipefail

OUT=${1:?usage: t68-netns-cell.sh <out-dir> <shape>}
SHAPE=${2:?shape: none|outage|loss<P>|reorder<P>}
UHOME=$(getent passwd "${SUDO_USER:-ubuntu}" | cut -d: -f6)
CLIP=${CLIP:-$UHOME/contrib-10m.ts}
PACER=${PACER:-$UHOME/pacer-97f3a38/mpegts-pacer}
SCRIPTS=${SCRIPTS:-$UHOME/t68/scripts}
RATE=${RATE:-11438000}
LAT_MS=${LAT_MS:?set LAT_MS, the cushion}
HOLD_MS=${HOLD_MS:-2500}
ALIGN_MS=${ALIGN_MS:-30000}
CAP_MS=${CAP_MS:-14000}
STALL_MS=${STALL_MS:-1000}
POLL_MS=${POLL_MS:-250}
RECV_TIMEOUT=${RECV_TIMEOUT:-3}
GIVE_UP_MS=${GIVE_UP_MS:-4000}
SETTLE=${SETTLE:-20}
OUTAGE=${OUTAGE:-5}
HELD=${HELD:-40}
case "$SHAPE" in
none | outage) WINDOW=${WINDOW:-60} ;;
loss* | reorder*) WINDOW=${WINDOW:-95} ;;
*) echo "unknown shape $SHAPE" >&2; exit 2 ;;
esac
PATH_DELAY_MS=${PATH_DELAY_MS:-50}
REORDER_DELAY_MS=${REORDER_DELAY_MS:-50}
GROUP=239.255.0.68:5068
PUBIP=10.99.0.1
PORT=18683
VPID=111
TAP_S=$((90 + ALIGN_MS / 1000 + LAT_MS / 1000 + WINDOW))

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 2; }
[ -e "$OUT" ] && { echo "$OUT exists; refusing to overwrite a cell" >&2; exit 2; }
for f in "$CLIP" "$PACER" "$SCRIPTS/t61-epochseg.py" "$SCRIPTS/b8-hls-recv.py" "$SCRIPTS/t18-latency.py" \
	"$SCRIPTS/t28-content-lost.py" "$SCRIPTS/t68-netns-grade.py"; do
	[ -r "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
ip netns list | grep -q '^t8b-pub' || { echo "netns pair not up" >&2; exit 2; }
if ip netns exec t8b-pub ss -lnt "sport = :$PORT" | grep -q ":$PORT"; then
	echo "port $PORT in use in t8b-pub" >&2
	exit 2
fi
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
ev() { echo "$EPOCHREALTIME $*" >>"$OUT/events.log"; }
pub() { ip netns exec t8b-pub "$@"; }
sub() { ip netns exec t8b-sub "$@"; }
netem() { pub tc qdisc change dev veth-pub root handle 1: netem "$@" limit 100000; }
cc=$(pub sysctl -n net.ipv4.tcp_congestion_control)
ssai=$(pub sysctl -n net.ipv4.tcp_slow_start_after_idle)
ev "start shape=$SHAPE lat_ms=$LAT_MS hold_ms=$HOLD_MS align_ms=$ALIGN_MS cap_ms=$CAP_MS stall_ms=$STALL_MS poll_ms=$POLL_MS recv_timeout=$RECV_TIMEOUT give_up_ms=$GIVE_UP_MS window=$WINDOW settle=$SETTLE path_delay_ms=$PATH_DELAY_MS cc=$cc slow_start_after_idle=$ssai rate=$RATE"

PIDS=()
stop_chain() {
	pkill -TERM -f "[b]8-hls-recv.py http://$PUBIP:$PORT/"
	pkill -TERM -f "[m]pegts-pacer stdout $RATE"
}
cleanup() {
	stop_chain
	netem delay "${PATH_DELAY_MS}ms" 2>/dev/null
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	pkill -KILL -f "[t]18-latency.py tap $VPID $OUT/"
	pkill -KILL -f "[n]ginx -p $OUT/ngx"
}
trap cleanup EXIT
netem delay "${PATH_DELAY_MS}ms"

tsp --realtime -I file "$CLIP" -P regulate --pcr-synchronous \
	-P fork --nowait --ignore-abort "python3 $SCRIPTS/t18-latency.py tap $VPID $OUT/src.csv --pipe --seconds $TAP_S > /dev/null" \
	-O ip "$GROUP" --local-address 127.0.0.1 --enforce-burst >"$OUT/source.log" 2>&1 &
PIDS+=($!)

www=$OUT/www
pfx=$OUT/ngx
mkdir -p "$www" "$pfx/tmp"
nice -n 10 python3 "$SCRIPTS/t61-epochseg.py" "$www" --group "$GROUP" --duration 2 --window 6 \
	--extra 3 --target 4 --pdt 2>"$OUT/seg.log" &
PIDS+=($!)
cat >"$pfx/nginx.conf" <<EOF
daemon off;
master_process off;
worker_processes 1;
pid ngx.pid;
error_log error.log info;
events { worker_connections 1024; }
http {
	types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
	log_format t68 '\$msec \$status \$request_uri \$body_bytes_sent \$request_time';
	access_log access.log t68;
	client_body_temp_path tmp/body;
	proxy_temp_path tmp/proxy;
	fastcgi_temp_path tmp/fastcgi;
	uwsgi_temp_path tmp/uwsgi;
	scgi_temp_path tmp/scgi;
	sendfile on;
	keepalive_timeout 300s;
	keepalive_requests 100000;
	server {
		listen $PUBIP:$PORT;
		root $www;
		location = /index.m3u8 { add_header Cache-Control "max-age=1" always; }
		location ~ \.ts\$ { add_header Cache-Control "max-age=60" always; }
	}
}
EOF
ip netns exec t8b-pub nginx -p "$pfx" -c "$pfx/nginx.conf" -e "$pfx/error.log" >"$pfx/stdout.log" 2>&1 &
PIDS+=($!)

ok=0
for _ in $(seq 1 120); do
	code=$(sub curl -s -o /dev/null -m 2 -w '%{http_code}' "http://$PUBIP:$PORT/index.m3u8")
	[ "$code" = 200 ] && { ok=1; break; }
	sleep 0.5
done
[ "$ok" = 1 ] || { echo "playlist not served; see $OUT/seg.log" >&2; exit 1; }
ev "playlist-ready"

ip netns exec t8b-sub bash -c "python3 $SCRIPTS/b8-hls-recv.py http://$PUBIP:$PORT/index.m3u8 - --seconds 0 --poll $POLL_MS \
		--release-ms $HOLD_MS --timeout $RECV_TIMEOUT --give-up-ms $GIVE_UP_MS --log $OUT/recv.jsonl 2>$OUT/recv.err \
	| tee $OUT/recv.ts \
	| $PACER stdout $RATE --stream-clock --latency-ms $LAT_MS --max-latency-ms $CAP_MS --stall-ms $STALL_MS \
		--on-stall mute --align-ms $ALIGN_MS --stats-interval-ms 1000 2>$OUT/pacer.log \
	| python3 $SCRIPTS/t18-latency.py tap $VPID $OUT/eg.csv --pipe --seconds $TAP_S --save $OUT/out.ts > /dev/null" \
	2>"$OUT/egress.err" &
PIDS+=($!)
ev "recv-start"

first=0
for _ in $(seq 1 $(((ALIGN_MS + LAT_MS) / 50 + 1200))); do
	[ -s "$OUT/out.ts" ] && { first=1; break; }
	sleep 0.05
done
[ "$first" = 1 ] || { echo "the groomer never emitted; see $OUT/pacer.log" >&2; exit 1; }
t0=$EPOCHREALTIME
ev "first-output"
at() { sleep "$(python3 -c "print(max(0.0, $t0 + $1 - $EPOCHREALTIME))")"; }

case "$SHAPE" in
outage)
	at "$SETTLE"
	netem delay "${PATH_DELAY_MS}ms" loss 100%
	ev "impair-start loss=100"
	at "$((SETTLE + OUTAGE))"
	netem delay "${PATH_DELAY_MS}ms"
	ev "impair-end"
	;;
loss*)
	at "$SETTLE"
	netem delay "${PATH_DELAY_MS}ms" loss "${SHAPE#loss}%"
	ev "impair-start loss=${SHAPE#loss}"
	at "$((SETTLE + HELD))"
	netem delay "${PATH_DELAY_MS}ms"
	ev "impair-end"
	;;
reorder*)
	at "$SETTLE"
	netem delay "${REORDER_DELAY_MS}ms" reorder "${SHAPE#reorder}%" 50%
	ev "impair-start reorder=${SHAPE#reorder}"
	at "$((SETTLE + HELD))"
	netem delay "${PATH_DELAY_MS}ms"
	ev "impair-end"
	;;
esac
at "$WINDOW"
stop_chain
ev "stop"
for _ in $(seq 1 100); do
	pgrep -f "[t]18-latency.py tap $VPID $OUT/eg.csv" >/dev/null || break
	sleep 0.1
done
pub tc -s qdisc show dev veth-pub >"$OUT/qdisc.txt" 2>&1
trap - EXIT
cleanup
ev "end"

python3 "$SCRIPTS/t68-netns-grade.py" "$OUT" | tee "$OUT/grade.line"
[ -n "${KEEP_TS:-}" ] || rm -f "$OUT/out.ts" "$OUT/recv.ts"
rm -rf "$www"

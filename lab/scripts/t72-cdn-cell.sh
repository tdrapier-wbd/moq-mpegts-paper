#!/usr/bin/env bash
# T72: one cell of the current segmented chain through a CDN edge under T28's path faults
# (lab/test-72-segmented-cdn-edge-impairment.md).
#
#   tsp regulate on the host (video PTS tapped by a mirrored fork, T28's source tap)
#     -> UDP multicast on lo -> t61-epochseg.py -> nginx on the host, under a path new to each cell:
#        :18310 for the edge (the origin header required), 10.72.{1,2}.1:18311 for the direct arm
#     -> MODE=cf: https://$CF_DOMAIN/a/<cell path>/ through the edge; MODE=direct: the origin itself
#     == impaired leg, ns t72i (the shape on v72i's netem), and control leg, ns t72c, each
#        b8-hls-recv.py -> tee recv.ts -> mpegts-pacer --stream-clock -> t18-latency.py tap -> out.ts
#
# The paths are the caller's (t72-net.sh, through t72-cdn-drive.py). The cell's clock starts at the
# impaired leg's first output: SETTLE s clean, then the shape, then the rest of the window, as T68's
# cells. The control leg runs beside it in ctl/ and is graded the same way; the edge caches each
# cell's segments under that cell's own path, so no cell reads another's.
#
# Usage: t72-cdn-cell.sh <out-dir> none|outage|loss<P>|reorder<P>     (as root)
# Env:   MODE (cf | direct), CF_DOMAIN (cf), KEY_FILE (~/t72/viewer-key), GATE (~/t72/gate.conf: the
#        origin header check, an nginx `if` written by the caller), and T68's CLIP, PACER, SCRIPTS
#        (~/t72/scripts), RATE, LAT_MS, HOLD_MS, ALIGN_MS, CAP_MS, STALL_MS, POLL_MS, RECV_TIMEOUT,
#        GIVE_UP_MS, SETTLE, OUTAGE, HELD, WINDOW, PATH_DELAY_MS, REORDER_DELAY_MS, KEEP_TS
# Output: T68's files for the impaired leg, the same in ctl/ for the control leg, edge.txt (the
#        edge's response headers), qdisc-before.txt and qdisc.txt (the impaired netem's counters).
set -uo pipefail

OUT=${1:?usage: t72-cdn-cell.sh <out-dir> <shape>}
SHAPE=${2:?shape: none|outage|loss<P>|reorder<P>}
UHOME=$(getent passwd "${SUDO_USER:-ubuntu}" | cut -d: -f6)
MODE=${MODE:?set MODE, cf or direct}
CF_DOMAIN=${CF_DOMAIN:-}
KEY_FILE=${KEY_FILE:-$UHOME/t72/viewer-key}
GATE=${GATE:-$UHOME/t72/gate.conf}
CLIP=${CLIP:-$UHOME/contrib-10m.ts}
PACER=${PACER:-$UHOME/pacer-97f3a38/mpegts-pacer}
SCRIPTS=${SCRIPTS:-$UHOME/t72/scripts}
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
GROUP=239.255.0.72:5072
PORT_EDGE=18310
PORT_DIRECT=18311
VPID=111
TAP_S=$((90 + ALIGN_MS / 1000 + LAT_MS / 1000 + WINDOW))

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 2; }
[ -e "$OUT" ] && { echo "$OUT exists; refusing to overwrite a cell" >&2; exit 2; }
for f in "$CLIP" "$PACER" "$GATE" "$SCRIPTS/t61-epochseg.py" "$SCRIPTS/b8-hls-recv.py" \
	"$SCRIPTS/t18-latency.py" "$SCRIPTS/t28-content-lost.py" "$SCRIPTS/t68-netns-grade.py"; do
	[ -r "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
case "$MODE" in
cf) [ -n "$CF_DOMAIN" ] && [ -r "$KEY_FILE" ] || { echo "cf needs CF_DOMAIN and KEY_FILE" >&2; exit 2; } ;;
direct) ;;
*) echo "MODE is cf or direct" >&2; exit 2 ;;
esac
ip netns list | grep -q '^t72i' && ip netns list | grep -q '^t72c' || { echo "paths not up" >&2; exit 2; }
for p in $PORT_EDGE $PORT_DIRECT; do
	if ss -lnt "sport = :$p" | grep -q ":$p"; then
		echo "port $p in use" >&2
		exit 2
	fi
done
mkdir -p "$OUT/ctl"
OUT=$(cd "$OUT" && pwd)
CID="$(basename "$OUT")-$(date +%s)"
ev() { echo "$EPOCHREALTIME $*" >>"$OUT/events.log"; }
netem() { tc qdisc change dev v72i root handle 1: netem "$@" limit 100000; }
if [ "$MODE" = cf ]; then
	cc=edge
	KEY=$(cat "$KEY_FILE")
	URL_I="https://$CF_DOMAIN/a/$CID/index.m3u8"
	URL_C=$URL_I
	HDR=(--header "X-P59-Key: $KEY")
	HDR_S="--header 'X-P59-Key: $KEY'"
else
	cc=$(sysctl -n net.ipv4.tcp_congestion_control)
	URL_I="http://10.72.1.1:$PORT_DIRECT/a/$CID/index.m3u8"
	URL_C="http://10.72.2.1:$PORT_DIRECT/a/$CID/index.m3u8"
	HDR=()
	HDR_S=""
fi
ssai=$(sysctl -n net.ipv4.tcp_slow_start_after_idle)
ev "start shape=$SHAPE lat_ms=$LAT_MS hold_ms=$HOLD_MS align_ms=$ALIGN_MS cap_ms=$CAP_MS stall_ms=$STALL_MS poll_ms=$POLL_MS recv_timeout=$RECV_TIMEOUT give_up_ms=$GIVE_UP_MS window=$WINDOW settle=$SETTLE path_delay_ms=$PATH_DELAY_MS cc=$cc slow_start_after_idle=$ssai rate=$RATE mode=$MODE"

PIDS=()
LEGS=()
leg_pids() { pgrep -g "$1" -f "$2" 2>/dev/null; }
stop_chain() {
	local g
	for g in "${LEGS[@]:-}"; do
		[ -n "$g" ] || continue
		kill -TERM $(leg_pids "$g" '[b]8-hls-recv.py') $(leg_pids "$g" '[m]pegts-pacer') 2>/dev/null
	done
}
cleanup() {
	local g p
	stop_chain
	netem delay "${PATH_DELAY_MS}ms" 2>/dev/null
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	sleep 1
	for g in "${LEGS[@]:-}"; do [ -n "$g" ] && kill -KILL -- "-$g" 2>/dev/null; done
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	pkill -KILL -f "[t]18-latency.py tap $VPID $OUT/"
	pkill -KILL -f "[n]ginx -p $OUT/ngx"
}
trap cleanup EXIT
netem delay "${PATH_DELAY_MS}ms"
tc -s qdisc show dev v72i >"$OUT/qdisc-before.txt" 2>&1

tsp --realtime -I file "$CLIP" -P regulate --pcr-synchronous \
	-P fork --nowait --ignore-abort "python3 $SCRIPTS/t18-latency.py tap $VPID $OUT/src.csv --pipe --seconds $TAP_S > /dev/null" \
	-O ip "$GROUP" --local-address 127.0.0.1 --enforce-burst >"$OUT/source.log" 2>&1 &
PIDS+=($!)

www=$OUT/www
pfx=$OUT/ngx
mkdir -p "$www" "$pfx/tmp" "$OUT/root/a"
ln -s "$www" "$OUT/root/a/$CID"
nice -n 10 python3 "$SCRIPTS/t61-epochseg.py" "$www" --group "$GROUP" --duration 2 --window 6 \
	--extra 3 --target 4 --pdt 2>"$OUT/seg.log" &
PIDS+=($!)
locs='location ~ /index\.m3u8$ { add_header Cache-Control "max-age=0" always; }
		location ~ \.ts$ { add_header Cache-Control "max-age=60" always; }'
cat >"$pfx/nginx.conf" <<EOF
daemon off;
master_process off;
worker_processes 1;
pid ngx.pid;
error_log error.log info;
events { worker_connections 1024; }
http {
	types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
	log_format t72 '\$msec \$server_port \$status \$request_uri \$body_bytes_sent \$request_time';
	access_log access.log t72;
	client_body_temp_path tmp/body;
	proxy_temp_path tmp/proxy;
	fastcgi_temp_path tmp/fastcgi;
	uwsgi_temp_path tmp/uwsgi;
	scgi_temp_path tmp/scgi;
	sendfile on;
	keepalive_timeout 300s;
	keepalive_requests 100000;
	server {
		listen $PORT_EDGE;
		include $GATE;
		root $OUT/root;
		$locs
	}
	server {
		listen 10.72.1.1:$PORT_DIRECT;
		listen 10.72.2.1:$PORT_DIRECT;
		root $OUT/root;
		$locs
	}
}
EOF
nginx -p "$pfx" -c "$pfx/nginx.conf" -e "$pfx/error.log" >"$pfx/stdout.log" 2>&1 &
PIDS+=($!)

ok=0
for _ in $(seq 1 120); do
	code=$(ip netns exec t72i curl -s -o /dev/null -m 3 -w '%{http_code}' "${HDR[@]/#--header/-H}" "$URL_I")
	[ "$code" = 200 ] && { ok=1; break; }
	sleep 0.5
done
[ "$ok" = 1 ] || { echo "playlist not served (last $code); see $OUT/seg.log" >&2; exit 1; }
ip netns exec t72i curl -s -D - -o /dev/null -m 3 "${HDR[@]/#--header/-H}" "$URL_I" |
	grep -i -E '^(x-amz-cf-pop|x-cache|via|age|cache-control):' >"$OUT/edge.txt"
ev "playlist-ready"

chain() { # ns url dir
	echo "python3 $SCRIPTS/b8-hls-recv.py $2 - --seconds 0 --poll $POLL_MS $HDR_S \
		--release-ms $HOLD_MS --timeout $RECV_TIMEOUT --give-up-ms $GIVE_UP_MS --log $3/recv.jsonl 2>$3/recv.err \
	| tee $3/recv.ts \
	| $PACER stdout $RATE --stream-clock --latency-ms $LAT_MS --max-latency-ms $CAP_MS --stall-ms $STALL_MS \
		--on-stall mute --align-ms $ALIGN_MS --stats-interval-ms 1000 2>$3/pacer.log \
	| python3 $SCRIPTS/t18-latency.py tap $VPID $3/eg.csv --pipe --seconds $TAP_S --save $3/out.ts > /dev/null"
}
setsid ip netns exec t72i bash -c "$(chain t72i "$URL_I" "$OUT")" 2>"$OUT/egress.err" &
LEGS+=($!)
setsid ip netns exec t72c bash -c "$(chain t72c "$URL_C" "$OUT/ctl")" 2>"$OUT/ctl/egress.err" &
LEGS+=($!)
ev "recv-start"

first=0
for _ in $(seq 1 $(((ALIGN_MS + LAT_MS) / 50 + 1200))); do
	[ -s "$OUT/out.ts" ] && { first=1; break; }
	sleep 0.05
done
[ "$first" = 1 ] || { echo "the groomer never emitted; see $OUT/pacer.log" >&2; exit 1; }
t0=$EPOCHREALTIME
ev "first-output"
for _ in $(seq 1 400); do
	[ -s "$OUT/ctl/out.ts" ] && { ev "ctl-first-output"; break; }
	sleep 0.05
done
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
	pgrep -f "[t]18-latency.py tap $VPID $OUT/(ctl/)?eg.csv" >/dev/null || break
	sleep 0.1
done
tc -s qdisc show dev v72i >"$OUT/qdisc.txt" 2>&1
trap - EXIT
cleanup
ev "end"

# The control leg's events: the impaired leg's, its own first output in place of that leg's.
awk '$2 == "first-output" {next} $2 == "ctl-first-output" {$2 = "first-output"} {print}' \
	"$OUT/events.log" >"$OUT/ctl/events.log"
ln -s ../src.csv "$OUT/ctl/src.csv"
python3 "$SCRIPTS/t68-netns-grade.py" "$OUT/ctl" >"$OUT/ctl/grade.line"
python3 "$SCRIPTS/t68-netns-grade.py" "$OUT" | tee "$OUT/grade.line"
[ -n "${KEEP_TS:-}" ] || rm -f "$OUT/out.ts" "$OUT/recv.ts" "$OUT/ctl/out.ts" "$OUT/ctl/recv.ts"
rm -rf "$www"

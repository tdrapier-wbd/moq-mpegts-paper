#!/usr/bin/env bash
# T68 parts B and C: two independent chains of the current segmented design on one host, loopback.
#
#   tsp regulate -> UDP multicast on lo
#     -> t61-epochseg.py A -> nginx A -> b8-hls-recv.py A -> mpegts-pacer --stream-clock A -> RTP :5681
#     -> t61-epochseg.py B -> nginx B -> b8-hls-recv.py B -> mpegts-pacer --stream-clock B -> RTP :5682
#
# Nothing is shared past the source: each chain has its own packager, origin, receiver and groomer,
# as two pathways would. Both legs are recorded from their sockets (T12's format: a little-endian
# u16 length, then the datagram) and graded with t12-rtpcmp.py at equal RTP timestamps.
#
# Part C freezes chain A's playlist: nginx serves frozen.m3u8 in place of index.m3u8 while it
# exists, so the origin answers 200 with a stale listing while segments keep landing, as T30's
# frozen-playlist cell did.
#
# Usage: t68-seg-pair.sh <out-dir>
# Env:   CLIP (~/contrib-10m.ts), PACER (~/pacer-97f3a38/mpegts-pacer), SCRIPTS (~/t68/scripts),
#        RATE (11438000), LAT_MS (the cushion, 1000), CAP_MS (14000), STALL_MS (1000),
#        HOLD_MS (unset: no hold; set: b8 --release-ms), ALIGN_MS (unset; set: the groomer's --align-ms),
#        POLL_MS (250), LEGS (2; 1 runs chain A only),
#        WINDOW (120 s of legs), FREEZE_AT (unset; s after the legs start), FREEZE_S (10),
#        FREEZE_PHASE (unset: freeze at FREEZE_AT; set: at this many s after chain A's next listing)
# Output: a.rtp b.rtp, per-chain logs, events.log, and one RESULT line on stdout.
set -uo pipefail

OUT=${1:?usage: t68-seg-pair.sh <out-dir>}
CLIP=${CLIP:-$HOME/contrib-10m.ts}
PACER=${PACER:-$HOME/pacer-97f3a38/mpegts-pacer}
SCRIPTS=${SCRIPTS:-$HOME/t68/scripts}
RATE=${RATE:-11438000}
LAT_MS=${LAT_MS:-1000}
CAP_MS=${CAP_MS:-14000}
STALL_MS=${STALL_MS:-1000}
HOLD_MS=${HOLD_MS:-}
ALIGN_MS=${ALIGN_MS:-}
POLL_MS=${POLL_MS:-250}
LEGS=${LEGS:-2}
WINDOW=${WINDOW:-120}
FREEZE_AT=${FREEZE_AT:-}
FREEZE_S=${FREEZE_S:-10}
FREEZE_PHASE=${FREEZE_PHASE:-}
GROUP=239.255.0.68:5068
SSRC=538968071

[ -e "$OUT" ] && { echo "$OUT exists; refusing to overwrite a run" >&2; exit 2; }
for f in "$CLIP" "$PACER" "$SCRIPTS/t61-epochseg.py" "$SCRIPTS/b8-hls-recv.py"; do
	[ -r "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
for p in 18681 18682 5681 5682; do
	if ss -lntu "sport = :$p" | grep -q ":$p"; then
		echo "port $p is in use; clear it before running" >&2
		exit 2
	fi
done
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
ev() { echo "$EPOCHREALTIME $*" >>"$OUT/events.log"; }
ev "start lat_ms=$LAT_MS cap_ms=$CAP_MS hold_ms=${HOLD_MS:-none} align_ms=${ALIGN_MS:-none} stall_ms=$STALL_MS poll_ms=$POLL_MS legs=$LEGS window=$WINDOW freeze_at=${FREEZE_AT:-none} freeze_s=$FREEZE_S rate=$RATE"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
}
trap cleanup EXIT

python3 - "$OUT/a.rtp" "$OUT/b.rtp" <<'PY' &
import selectors, signal, socket, struct, sys

signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
sel = selectors.DefaultSelector()
files = {}
for port, path in ((5681, sys.argv[1]), (5682, sys.argv[2])):
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 << 20)
	s.bind(("127.0.0.1", port))
	files[s] = open(path, "wb")
	sel.register(s, selectors.EVENT_READ)
try:
	while True:
		for key, _ in sel.select():
			d = key.fileobj.recv(65535)
			files[key.fileobj].write(struct.pack("<H", len(d)) + d)
finally:
	for f in files.values():
		f.close()
PY
REC=$!
PIDS+=("$REC")
sleep 0.5

tsp --realtime -I file "$CLIP" -P regulate --pcr-synchronous \
	-O ip "$GROUP" --local-address 127.0.0.1 --enforce-burst >"$OUT/source.log" 2>&1 &
PIDS+=($!)

chains=(a)
[ "$LEGS" = 2 ] && chains=(a b)
port_of() { [ "$1" = a ] && echo 18681 || echo 18682; }
rtp_of() { [ "$1" = a ] && echo 5681 || echo 5682; }

for c in "${chains[@]}"; do
	www=$OUT/www-$c
	pfx=$OUT/ngx-$c
	mkdir -p "$www" "$pfx/tmp"
	nice -n 10 python3 "$SCRIPTS/t61-epochseg.py" "$www" --group "$GROUP" --duration 2 --window 6 \
		--extra 3 --target 4 --pdt 2>"$OUT/seg-$c.log" &
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
	server {
		listen 127.0.0.1:$(port_of "$c");
		root $www;
		location = /index.m3u8 {
			add_header Cache-Control "max-age=1" always;
			try_files /frozen.m3u8 /index.m3u8 =404;
		}
		location ~ \.ts\$ { add_header Cache-Control "max-age=60" always; }
	}
}
EOF
	nginx -p "$pfx" -c "$pfx/nginx.conf" -e "$pfx/error.log" >"$pfx/stdout.log" 2>&1 &
	PIDS+=($!)
done

for _ in $(seq 1 120); do
	ok=1
	for c in "${chains[@]}"; do
		code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(port_of "$c")/index.m3u8")
		[ "$code" = 200 ] || ok=0
	done
	[ "$ok" = 1 ] && break
	sleep 0.5
done
[ "$ok" = 1 ] || { echo "playlists not served; see $OUT/seg-*.log" >&2; exit 1; }
ev "playlists-ready"

recv_pat() { echo "[b]8-hls-recv.py http://127.0.0.1:$(port_of "$1")/"; }
stop_receivers() { for c in "${chains[@]}"; do pkill -TERM -f "$(recv_pat "$c")"; done; }
trap 'stop_receivers; cleanup' EXIT

declare -A PACEPID
for c in "${chains[@]}"; do
	fetch=(python3 "$SCRIPTS/b8-hls-recv.py" "http://127.0.0.1:$(port_of "$c")/index.m3u8" -
		--seconds 0 --poll "$POLL_MS" --log "$OUT/recv-$c.jsonl")
	[ -n "$HOLD_MS" ] && fetch+=(--release-ms "$HOLD_MS")
	pace=("$PACER" "127.0.0.1:$(rtp_of "$c")" "$RATE" --rtp --ssrc "$SSRC" --stream-clock --sequence-seed 0
		--latency-ms "$LAT_MS" --max-latency-ms "$CAP_MS" --stall-ms "$STALL_MS" --on-stall mute
		--stats-interval-ms 1000)
	[ -n "$ALIGN_MS" ] && pace+=(--align-ms "$ALIGN_MS")
	"${fetch[@]}" 2>"$OUT/recv-$c.err" | "${pace[@]}" 2>"$OUT/pacer-$c.log" &
	PACEPID[$c]=$!
	PIDS+=("${PACEPID[$c]}")
done
ev "legs-start"

t0=$EPOCHREALTIME
if [ -n "$FREEZE_AT" ]; then
	sleep "$FREEZE_AT"
	if [ -n "$FREEZE_PHASE" ]; then
		n0=$(grep -c ' playlist ' "$OUT/seg-a.log")
		while [ "$(grep -c ' playlist ' "$OUT/seg-a.log")" = "$n0" ]; do sleep 0.01; done
		sleep "$FREEZE_PHASE"
	fi
	cp "$OUT/www-a/index.m3u8" "$OUT/www-a/.frozen.tmp" && mv "$OUT/www-a/.frozen.tmp" "$OUT/www-a/frozen.m3u8"
	ev "freeze-a"
	sleep "$FREEZE_S"
	rm -f "$OUT/www-a/frozen.m3u8"
	ev "thaw-a"
fi
left=$(python3 -c "import sys; print(max(0.0, $WINDOW - ($EPOCHREALTIME - $t0)))")
sleep "$left"

ev "legs-stop"
stop_receivers
for c in "${chains[@]}"; do
	for _ in $(seq 1 $(((LAT_MS + 6000) / 250))); do
		kill -0 "${PACEPID[$c]}" 2>/dev/null || break
		sleep 0.25
	done
done
sleep 0.5
kill "$REC" 2>/dev/null
wait "$REC" 2>/dev/null
ev "end"

summary() {
	local f=$OUT/pacer-$1.log hw
	hw=$(grep -o 'buffer_high_water=[0-9]*' "$f" | cut -d= -f2 | sort -n | tail -1)
	echo "$(grep -o 'done\..*' "$f" | grep -oE '(dropped|late_drops|underruns|withheld|cut_runs|stalls|muted)=[0-9]+' | tr '\n' ' ')high_water=${hw:-?}"
}
line="RESULT $(basename "$OUT") lat_ms=$LAT_MS hold_ms=${HOLD_MS:-none} align_ms=${ALIGN_MS:-none} cap_ms=$CAP_MS"
for c in "${chains[@]}"; do line="$line | $c: $(summary "$c")"; done
echo "$line" | tee -a "$OUT/events.log"

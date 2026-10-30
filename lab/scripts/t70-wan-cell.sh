#!/usr/bin/env bash
# T70: one cell of the current segmented chain over the internet path, receiver here.
#
#   origin (t70-wan-origin.sh): tsp regulate -> t61-epochseg.py --duration D -> nginx :18690
#     == the open internet ==>
#   b8-hls-recv.py -> tee recv.ts -> mpegts-pacer --stream-clock -> t18-latency.py tap -> out.ts
#
# The clock reference (`t18-latency.py clock-server` on the origin) is the caller's fixture: probed
# here before and after the cell, never started. The cell's clock starts at the groomer's first
# output; at WINDOW s the receiver and the groomer stop together, then the origin's process group.
#
# Usage: t70-wan-cell.sh <out-dir> <epoch-s> design|default <cushion-ms>
# Env:   ORIGIN_IP and PACER (required), HOST (moq-secondary), SECRET_FILE (~/.t70-path, the URL's
#        path segment), REMOTE (/home/ubuntu/t70), PORT (18690), CLOCKPORT (9010), WINDOW (120),
#        RATE (11438000), HOLD_MS (1500), ALIGN_MS (30000), CAP_MS (14000), STALL_MS (1000),
#        POLL_MS (250), KEEP_TS (unset: captures deleted once graded)
# Output: events.log, clock-before.txt, clock-after.txt, receiver and groomer logs, origin/, eg.csv,
#         grade.json.
set -uo pipefail

OUT=${1:?usage: t70-wan-cell.sh <out-dir> <epoch-s> design|default <cushion-ms>}
EPOCH=${2:?epoch: 1 or 2}
VARIANT=${3:?variant: design or default}
LAT_MS=${4:?cushion ms}
ORIGIN_IP=${ORIGIN_IP:?set ORIGIN_IP}
PACER=${PACER:?set PACER}
HOST=${HOST:-moq-secondary}
SECRET=$(cat "${SECRET_FILE:-$HOME/.t70-path}")
REMOTE=${REMOTE:-/home/ubuntu/t70}
PORT=${PORT:-18690}
CLOCKPORT=${CLOCKPORT:-9010}
WINDOW=${WINDOW:-120}
RATE=${RATE:-11438000}
HOLD_MS=${HOLD_MS:-1500}
ALIGN_MS=${ALIGN_MS:-30000}
CAP_MS=${CAP_MS:-14000}
STALL_MS=${STALL_MS:-1000}
POLL_MS=${POLL_MS:-250}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TIMEOUT=/opt/homebrew/bin/timeout
VPID=111
case "$VARIANT" in
design) RECV_HOLD=(--release-ms "$HOLD_MS"); ALIGN=(--align-ms "$ALIGN_MS") ;;
default) RECV_HOLD=(); ALIGN=(); HOLD_MS=0; ALIGN_MS=0 ;;
*) echo "variant: design or default" >&2; exit 2 ;;
esac
TAP_S=$((60 + ALIGN_MS / 1000 + LAT_MS / 1000 + WINDOW))
ORIGIN_S=$((TAP_S + 60))

[ -e "$OUT" ] && { echo "$OUT exists; refusing to overwrite a cell" >&2; exit 2; }
if pgrep -f "[t]18-latency.py tap $VPID" >/dev/null; then
	echo "a t18 tap is already running here" >&2
	exit 2
fi
mkdir -p "$OUT/origin"
OUT=$(cd "$OUT" && pwd)
NAME=$(basename "$OUT")
RUN=$REMOTE/runs/$NAME
ev() { echo "$EPOCHREALTIME $*" >>"$OUT/events.log"; }
rsh() { $TIMEOUT 60 ssh -n -o BatchMode=yes "$HOST" "$@"; }
probe() { $TIMEOUT 30 python3 "$SCRIPTS/t18-latency.py" clock-client "$ORIGIN_IP" "$CLOCKPORT" --samples 30 >"$1" 2>&1; }

ev "start epoch=$EPOCH variant=$VARIANT lat_ms=$LAT_MS hold_ms=$HOLD_MS align_ms=$ALIGN_MS cap_ms=$CAP_MS stall_ms=$STALL_MS poll_ms=$POLL_MS window=$WINDOW rate=$RATE"
probe "$OUT/clock-before.txt" || { echo "no clock reference on $ORIGIN_IP:$CLOCKPORT" >&2; exit 1; }
ev "clock-before"

stop_chain() {
	pkill -TERM -f "[b]8-hls-recv.py http://$ORIGIN_IP:$PORT/"
	pkill -TERM -f "[m]pegts-pacer stdout $RATE"
}
stop_origin() {
	rsh "[ -s $RUN/origin.pid ] && kill -TERM -- -\$(cat $RUN/origin.pid) 2>/dev/null; true"
}
cleanup() {
	stop_chain
	stop_origin
	sleep 1
	pkill -KILL -f "[t]18-latency.py tap $VPID $OUT/"
}
trap cleanup EXIT

if ! rsh "ss -lnt 'sport = :$PORT' | grep -q ':$PORT' && exit 3; mkdir -p $RUN; cd $RUN || exit 4; \
	nohup setsid bash $REMOTE/scripts/t70-wan-origin.sh $RUN $EPOCH $SECRET $ORIGIN_S >origin.log 2>&1 </dev/null &"; then
	echo "origin not started (port $PORT busy, or ssh failed)" >&2
	exit 1
fi
ev "origin-start"
URL=http://$ORIGIN_IP:$PORT/$SECRET/index.m3u8
ok=0
for _ in $(seq 1 120); do
	[ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$URL")" = 200 ] && { ok=1; break; }
	sleep 0.5
done
[ "$ok" = 1 ] || { echo "playlist not served" >&2; exit 1; }
ev "playlist-ready"

bash -c "python3 $SCRIPTS/b8-hls-recv.py $URL - --seconds 0 --poll $POLL_MS ${RECV_HOLD[*]} \
		--log $OUT/recv.jsonl 2>$OUT/recv.err \
	| tee $OUT/recv.ts \
	| $PACER stdout $RATE --stream-clock --latency-ms $LAT_MS --max-latency-ms $CAP_MS --stall-ms $STALL_MS \
		--on-stall mute ${ALIGN[*]} --stats-interval-ms 1000 2>$OUT/pacer.log \
	| python3 $SCRIPTS/t18-latency.py tap $VPID $OUT/eg.csv --pipe --seconds $TAP_S --save $OUT/out.ts > /dev/null" \
	2>"$OUT/egress.err" &
ev "recv-start"

first=0
for _ in $(seq 1 $(((ALIGN_MS + LAT_MS) / 50 + 1200))); do
	[ -s "$OUT/out.ts" ] && { first=1; break; }
	sleep 0.05
done
[ "$first" = 1 ] || { echo "the groomer never emitted; see $OUT/pacer.log" >&2; exit 1; }
t0=$EPOCHREALTIME
ev "first-output"
sleep "$(python3 -c "print(max(0.0, $t0 + $WINDOW - $EPOCHREALTIME))")"
stop_chain
ev "stop"
for _ in $(seq 1 100); do
	pgrep -f "[t]18-latency.py tap $VPID $OUT/eg.csv" >/dev/null || break
	sleep 0.1
done
stop_origin
ev "origin-stop"
probe "$OUT/clock-after.txt"
ev "clock-after"
trap - EXIT
cleanup

rsh "cd $RUN && tar -cf - src.csv seg.log source.log origin-events.log ngx/access.log ngx/error.log 2>/dev/null; \
	rm -rf $RUN/www" | tar -C "$OUT/origin" -xf -
python3 "$SCRIPTS/t70-wan-grade.py" "$OUT" | tee "$OUT/grade.line"
[ -n "${KEEP_TS:-}" ] || rm -f "$OUT/out.ts" "$OUT/recv.ts"

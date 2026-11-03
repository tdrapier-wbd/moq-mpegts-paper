#!/usr/bin/env bash
# P1-ak, the telemetry half: what each source a NOC could watch says about T22's, T24's and T32's
# faults on the segmented lane, on the laptop against a local origin.
#
#   p1ak-telemetry.sh <arm> <out-dir>        arm = control | video | audio | stall | origin
#
# Source: the clip through ts-partial-stall.py (control passes it unchanged) and `tsp -P regulate`,
# into t61-epochseg.py --pdt, the deployed segmenter, served by a local HTTP origin. Receiver:
# b8-hls-recv.py with CMCD v2 in request mode and event mode to p1ak-collector.py; its output goes
# to TSDuck's `influx --tr-101-290`, posting to the same collector, and to ts-liveness.py, T27's
# per-PID detector. The fault, AT seconds into the source:
#   video, audio  ts-partial-stall.py suppresses those PES for DUR s, the PCR kept (T24)
#   stall         SIGSTOP on the segmenter for STALL s (T22's segmented arm)
#   origin        the origin stopped for STALL s (T32's second row)
# events.log has the wall time of each step; p1ak-grade.py reads the rest.
#
# Env: CLIP (~/contrib-10m.ts), SECS (170), AT (50), DUR (60), STALL (30), JOIN (10, the receiver's
#      start after the source's), PCR_TIMEOUT (6, ts-liveness.py's), ORIGIN_PORT (18501), COL_PORT (18502)
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ARM=${1:?arm: control, video, audio, stall or origin}
OUT=${2:?out dir}
CLIP=${CLIP:-$HOME/contrib-10m.ts}
SECS=${SECS:-170}
AT=${AT:-50}
DUR=${DUR:-60}
STALL=${STALL:-30}
JOIN=${JOIN:-10}
# Three segment durations: the receiver hands on whole segments, up to 3.1 s apart.
PCR_TIMEOUT=${PCR_TIMEOUT:-6}
ORIGIN_PORT=${ORIGIN_PORT:-18501}
COL_PORT=${COL_PORT:-18502}

# Passes the source through and records the wall time of its first byte: the fault's clock.
TAP='import sys, time
first = True
while (b := sys.stdin.buffer.read1(65536)):
	if first:
		open(sys.argv[1], "w").write(f"{time.time():.3f}\n")
		first = False
	sys.stdout.buffer.write(b)
	sys.stdout.buffer.flush()'
# Adds the arrival wall time to each of ts-liveness.py's JSON lines.
STAMP='import json, sys, time
for line in sys.stdin:
	print(json.dumps(dict(json.loads(line), wall=round(time.time(), 3))), flush=True)'

now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
ev() { echo "$(now) $*" >>"$OUT/events.log"; }
until_t() { python3 -c 'import sys, time; time.sleep(max(0.0, float(sys.argv[1]) - time.time()))' "$1"; }

case $ARM in
control | video | audio | stall | origin) ;;
*)
	echo "arm: control, video, audio, stall or origin" >&2
	exit 2
	;;
esac
for p in "$ORIGIN_PORT" "$COL_PORT"; do
	if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
		echo "port $p is taken" >&2
		exit 1
	fi
done

rm -rf "$OUT"
mkdir -p "$OUT/www"
PIDS=()
SEG_PID=""
ORIGIN_PID=""
cleanup() {
	[ -n "$SEG_PID" ] && kill -CONT "$SEG_PID" 2>/dev/null
	for p in "${PIDS[@]}" $ORIGIN_PID; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in "${PIDS[@]}" $ORIGIN_PID; do kill -9 "$p" 2>/dev/null; done
	true
}
trap cleanup EXIT

origin() {
	python3 -m http.server --bind 127.0.0.1 --directory "$OUT/www" "$ORIGIN_PORT" >>"$OUT/origin.log" 2>&1 &
	ORIGIN_PID=$!
}

{
	echo "arm=$ARM secs=$SECS at=$AT dur=$DUR stall=$STALL join=$JOIN"
	echo "clip=$(basename "$CLIP") size=$(stat -f %z "$CLIP" 2>/dev/null || stat -c %s "$CLIP")"
	echo "tsp=$(tsp --version 2>&1 | head -1)"
	echo "started=$(date -u +%FT%TZ)"
} >"$OUT/meta.txt"

python3 "$HERE/p1ak-collector.py" "$COL_PORT" "$OUT/collector.jsonl" &
PIDS+=($!)
origin
mkfifo "$OUT/src.fifo"
python3 "$HERE/t61-epochseg.py" "$OUT/www" --file "$OUT/src.fifo" --pdt >"$OUT/seg.log" 2>&1 &
SEG_PID=$!
PIDS+=("$SEG_PID")

mode=control
case $ARM in video | audio) mode=$ARM ;; esac
python3 "$HERE/ts-partial-stall.py" --mode "$mode" --at "$AT" --for "$DUR" "$CLIP" 2>"$OUT/stim.log" |
	tsp -I file - -P regulate --pcr-synchronous -O file - 2>"$OUT/regulate.log" |
	python3 -c "$TAP" "$OUT/source-t0.txt" >"$OUT/src.fifo" &
PIDS+=($!)

for _ in $(seq 1 100); do
	[ -s "$OUT/source-t0.txt" ] && break
	sleep 0.1
done
T0=$(cat "$OUT/source-t0.txt" 2>/dev/null) || {
	echo "no source" >&2
	exit 1
}
ev "source-start"

until_t "$(echo "$T0 + $JOIN" | bc)"
python3 "$HERE/b8-hls-recv.py" "http://127.0.0.1:$ORIGIN_PORT/index.m3u8" - --seconds $((SECS - JOIN)) \
	--cmcd headers --cmcd-collector "http://127.0.0.1:$COL_PORT/cmcd" --cmcd-interval 5 \
	--log "$OUT/b8.jsonl" 2>"$OUT/b8.err" |
	tee >(python3 -u "$HERE/ts-liveness.py" - --jsonl --quiet --pcr-timeout "$PCR_TIMEOUT" \
		2>"$OUT/liveness.err" | python3 -u -c "$STAMP" >"$OUT/liveness.jsonl") |
	tsp -r --buffer-size-mb 1 --max-input-packets 70 -I file - -P influx --tr-101-290 \
		--host-url "http://127.0.0.1:$COL_PORT" --org lab --bucket p1ak --token none --interval 1 \
		-O drop 2>"$OUT/tsp.log" &
PIDS+=($!)
ev "receiver-start"

until_t "$(echo "$T0 + $AT" | bc)"
case $ARM in
stall)
	kill -STOP "$SEG_PID"
	ev "fault-start"
	sleep "$STALL"
	kill -CONT "$SEG_PID"
	ev "fault-end"
	;;
origin)
	kill "$ORIGIN_PID"
	ev "fault-start"
	sleep "$STALL"
	origin
	ev "fault-end"
	;;
video | audio)
	ev "fault-start"
	until_t "$(echo "$T0 + $AT + $DUR" | bc)"
	ev "fault-end"
	;;
esac

until_t "$(echo "$T0 + $SECS" | bc)"
ev "end"
cleanup
trap - EXIT
echo "finished=$(date -u +%FT%TZ)" >>"$OUT/meta.txt"
touch "$OUT/done"

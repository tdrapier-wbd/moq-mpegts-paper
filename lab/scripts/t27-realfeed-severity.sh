#!/usr/bin/env bash
# Does the #3375 fence arm on a *real* encoder feed, or only on a manufactured content join?
#
#   t27-realfeed-severity.sh <label> <relay-ip> <broadcast> <duration-s>
#
# The reproducer that found the regression replays a clip on a continuous timeline, so its join is a
# hard cut at a repeat point — ordinary in broadcast, but manufactured. That leaves the severity
# question open: a live feed never repeats, and if it never produces a per-track backwards step then
# the fence never arms and the defect is a lab artefact. If it does, the defect ends a real service.
#
# So: subscribe to a live SRT-fed broadcast twice over, once on each side of the #3375 merge, with a
# per-PID liveness detector on each. Same broadcast, same relay, same wall time — the build is the
# only difference. Emitted rate comes from /proc/<pid>/io wchar, so an exporter that is still
# receiving but no longer muxing reads as a low number rather than as a dead process.
set -uo pipefail

LABEL=${1:?label}
RELAY_IP=${2:?relay ip}
BCAST=${3:?broadcast}
DURATION=${4:-3300}

PORT=${PORT:-443}
OLD=${OLD:?set OLD to the pre-#3375 binary}
NEW=${NEW:?set NEW to the post-#3375 binary}
LIVENESS=${LIVENESS:-$HOME/f5/ts-liveness.py}
LATMAX=${LATMAX:-3s}
SAMPLE=${SAMPLE:-10}
OUT=${OUT:-$HOME/t27}/$LABEL

rm -rf "$OUT"
mkdir -p "$OUT"

CONN=(--client-tls-disable-verify --client-connect "https://$RELAY_IP:$PORT/anon"
	"--client-quic-gso=${GSO:-true}")

PIDS=()
cleanup() {
	for p in "${PIDS[@]+${PIDS[@]}}"; do kill -9 "$p" 2>/dev/null || true; done
	pkill -f "[t]s-liveness.py --warmup 10 --learn 40" 2>/dev/null || true
}
trap cleanup EXIT

{
	echo "label=$LABEL relay=$RELAY_IP:$PORT broadcast=$BCAST duration=${DURATION}s latmax=$LATMAX"
	echo "old=$OLD  new=$NEW"
	echo "started=$(date -u +%FT%T%z)"
} >"$OUT/meta.txt"

# A real feed's cadence is not a clip's: learn for longer before arming, so a satellite feed's
# ordinary jitter does not become a threshold the run then alarms on.
start() { # start <tag> <binary>
	"$2" "${CONN[@]}" --broadcast "$BCAST" export ts --latency-max "$LATMAX" 2>"$OUT/sub.$1.log" |
		python3 "$LIVENESS" --warmup 10 --learn 40 --jsonl - >"$OUT/live.$1.jsonl" 2>"$OUT/live.$1.err" &
	# The rate to watch is the exporter's, not the detector's, so record the pipeline's head.
	PIDS+=("$(pgrep -nf "export ts --latency-max $LATMAX")")
}

start old "$OLD"
sleep 2
start new "$NEW"
sleep 3

for p in "${PIDS[@]}"; do
	kill -0 "$p" 2>/dev/null || {
		echo "t27-real: a subscriber failed to start" >&2
		exit 1
	}
done
echo "t27-real: both subscribers up on $BCAST"

wchar() { awk -F': *' '/^wchar/{print $2}' "/proc/$1/io" 2>/dev/null || echo 0; }

CSV="$OUT/rates.csv"
echo "t_s,mbps_old,mbps_new,alive" >"$CSV"
PREV=()
for p in "${PIDS[@]}"; do PREV+=("$(wchar "$p")"); done
T0=$(date +%s)
TP=$T0

while :; do
	sleep "$SAMPLE"
	NOW=$(date +%s)
	EL=$((NOW - T0))
	WIN=$((NOW - TP))
	[ "$WIN" -lt 1 ] && WIN=1
	LINE="$EL"
	ALIVE=0
	for n in 0 1; do
		p=${PIDS[$n]}
		kill -0 "$p" 2>/dev/null && ALIVE=$((ALIVE + 1))
		c=$(wchar "$p")
		LINE="$LINE,$(awk -v a="${PREV[$n]}" -v b="$c" -v w="$WIN" 'BEGIN{printf "%.2f", (b-a)*8/w/1e6}')"
		PREV[$n]=$c
	done
	echo "$LINE,$ALIVE" >>"$CSV"
	TP=$NOW
	[ $((EL % 300)) -lt "$SAMPLE" ] && echo "  t=${EL}s  $(tail -1 "$CSV")"
	[ "$EL" -ge "$DURATION" ] && break
done

echo "finished=$(date -u +%FT%T%z)" >>"$OUT/meta.txt"
echo "t27-real done: $CSV"

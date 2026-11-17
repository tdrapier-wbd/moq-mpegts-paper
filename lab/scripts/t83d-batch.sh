#!/usr/bin/env bash
# T83 Part D's switch cells from the laptop: each run starts t83d-switch.sh's two halves on one T0,
# the receiving half on RCV_HOST and the source half on SRC_HOST, waits them out, copies the source
# half's events and its PSI/SI capture to the receiving host, merges the two event logs in time
# order, and grades the run there into t83b-batch.sh's summary (GRADE_ONLY).
#
#   SRC_HOST=moq-primary RCV_HOST=moq-far SRC_IP=<source public IP> RCV_IP=<receiver public IP> \
#     LATS="<ms>" t83d-batch.sh <label>
#
# Env: CELLS ("none outage-a outage-b kill-a kill-b cut"), REPS (3), LEGB (moq | seg), SRT_INIT (7),
#      SRC_BIN, SRC_CLIP, RCV_BIN, RCV_CLIP, PACER (the receiving host's), RDIR (the scripts' and
#      runs' directory on both hosts, ~/t83d), LEAD (s from launch to T0, 30), and t83d-switch.sh's.
set -uo pipefail

LABEL=${1:?label}
SRC_HOST=${SRC_HOST:-moq-primary}
RCV_HOST=${RCV_HOST:-moq-far}
SRC_IP=${SRC_IP:?set SRC_IP}
RCV_IP=${RCV_IP:?set RCV_IP}
LATS=${LATS:?set LATS}
CELLS=${CELLS:-"none outage-a outage-b kill-a kill-b cut"}
REPS=${REPS:-3}
LEGB=${LEGB:-moq}
SRT_INIT=${SRT_INIT:-7}
SECS=${SECS:-75}
LEAD=${LEAD:-30}
RDIR=${RDIR:-/home/ubuntu/t83d}
SRC_BIN=${SRC_BIN:-/home/ubuntu/bin-cd560bde}
SRC_CLIP=${SRC_CLIP:-/home/ubuntu/contrib-10m.ts}
RCV_BIN=${RCV_BIN:-/home/ubuntu/bin-cd560bde}
RCV_CLIP=${RCV_CLIP:-/home/ubuntu/contrib-10m.ts}
PACER=${PACER:-/home/ubuntu/pacer-97f3a38/mpegts-pacer}
T=/opt/homebrew/bin/timeout
X="$T 120 ssh"

run() { # $1 run name, $2 srt_ms, $3 cell (none | outage-a ... | cut), $4 rep
	local n=$1 lat=$2 c=${3%-*} s=a t0 env
	case $3 in *-b) s=b ;; esac
	t0=$(($(date +%s) + LEAD))
	env="T0=$t0 CELL=$c SERVE=$s LEGB=$LEGB SRT_LAT=$lat SRT_INIT=$SRT_INIT SECS=$SECS OUT=$RDIR/runs"
	$X "$RCV_HOST" "mkdir -p $RDIR/runs && cd $RDIR && (sudo $env ROLE=rcv PEER=$SRC_IP BIN=$RCV_BIN PACER=$PACER \
		setsid nohup bash scripts/t83d-switch.sh $n >runs/$n.rcv.log 2>&1 </dev/null &)" </dev/null
	$X "$SRC_HOST" "mkdir -p $RDIR/runs && cd $RDIR && ($env ROLE=src PEER=$RCV_IP BIN=$SRC_BIN SRC=$SRC_CLIP \
		setsid nohup bash scripts/t83d-switch.sh $n >runs/$n.src.log 2>&1 </dev/null &)" </dev/null
	sleep $((t0 + SECS + 20 - $(date +%s)))
	$X "$SRC_HOST" "tar -C $RDIR/runs/$n -czf - events.txt live1-si.ts live1-si.idx tap.json build.txt \
		srt-send.log importb.log relayb.log pkg.log 2>/dev/null" </dev/null |
		$X "$RCV_HOST" "mkdir -p $RDIR/runs/$n/src && tar -C $RDIR/runs/$n/src -xzf -"
	$X "$RCV_HOST" "cd $RDIR/runs/$n && sudo mv events.txt events-rcv.txt && sort -k2 -n events-rcv.txt src/events.txt |
		sudo tee events.txt >/dev/null && sudo cp src/live1-si.ts src/live1-si.idx . &&
		sudo TABLES_PREFIX=live1-si GRADE_ONLY='$RDIR/runs/$n $n t83d$([ "$LEGB" = seg ] && echo -seg) srt $lat $c $s $4' \
		BIN=$RCV_BIN PACER=$PACER SRC=$RCV_CLIP OUT=$RDIR LEGB=$LEGB bash $RDIR/scripts/t83b-batch.sh $LABEL;
		echo tap: \$(cat src/tap.json 2>/dev/null | head -c 200)" </dev/null
}

echo "=== $(date -u) t83d-batch $LABEL: $SRC_HOST -> $RCV_HOST, LATS=$LATS CELLS=$CELLS REPS=$REPS LEGB=$LEGB ==="
for lat in $LATS; do
	for cell in $CELLS; do
		for ((rep = 1; rep <= REPS; rep++)); do
			run "s$lat-$cell-$rep" "$lat" "$cell" "$rep"
		done
	done
done
echo "=== $(date -u) t83d-batch $LABEL done: $RCV_HOST:$RDIR/$LABEL.summary.csv ==="

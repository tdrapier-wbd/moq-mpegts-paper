#!/usr/bin/env bash
# What does a leg joining a broadcast already in progress actually receive?
#
# Publishes for JOIN_AFTER seconds, then brings up a single stream-clocked leg
# and lets it run. The publisher is stopped first so the exporter reaches the end
# of the broadcast and the pacer prints its counters — which is the point of the
# run: `resyncs` says whether the leg found itself behind the live edge, and
# `dropped` says whether it was quietly deleting programme to stay inside its
# buffer bound.
set -uo pipefail
cd ~/t12 && source env.sh

PORT=${PORT:-7643}
RTP_PORT=${RTP_PORT:-5300}
JOIN_AFTER=${JOIN_AFTER:-20}
RUN_FOR=${RUN_FOR:-25}
MAXLAT=${MAXLAT:-10000}
LAT=${LAT:-1500}
BCAST=t12.joindiag$$.hang
R=$HOME/t12/joindiag
rm -rf "$R"; mkdir -p "$R"

# The pacer's egress example was renamed moq_egress -> ts_egress when it learned to groom
# a segmented-HTTP arrival pattern as well as a MoQ one (T16). Accept either, so this rig
# runs against the build it was written for and against current heads.
EGRESS="$PACER/ts_egress"
[[ -x "$EGRESS" ]] || EGRESS="$PACER/moq_egress"

cleanup() {
	for pid in ${LEG:-} ${PUB:-} ${RELAY:-}; do
		pkill -KILL -P "$pid" 2>/dev/null
		kill -KILL "$pid" 2>/dev/null
	done
}
trap cleanup EXIT

setsid "$MOQ_RELAY" --server-bind "127.0.0.1:$PORT" --tls-generate localhost --auth-public "" \
	--server-quic-idle-timeout 30s --server-quic-keep-alive 5s >"$R/relay.log" 2>&1 </dev/null &
RELAY=$!
sleep 2

setsid bash -c "tsp -I file \"$SRC\" --infinite -P regulate --pcr-synchronous -O file - \
	| \"$MOQ\" --client-tls-disable-verify --client-connect https://localhost:$PORT/anon \
		--broadcast $BCAST import ts" >"$R/pub.log" 2>&1 </dev/null &
PUB=$!

echo "publishing ${JOIN_AFTER}s before the leg joins (max-latency ${MAXLAT} ms)"
sleep "$JOIN_AFTER"

setsid bash -c "\"$MOQ\" --client-tls-disable-verify --client-connect https://localhost:$PORT/anon \
	--broadcast $BCAST export ts --latency-max ${LATENCY_MAX:-500ms} \
	| \"$EGRESS\" 127.0.0.1:$RTP_PORT $RATE --rtp --ssrc 538968071 \
		--latency-ms $LAT --max-latency-ms $MAXLAT --stall-ms 1000 --on-stall mute \
		--stream-clock --sequence-seed 0" >"$R/leg.log" 2>&1 </dev/null &
LEG=$!
sleep "$RUN_FOR"

# The pacer reports on EOF, and a muted leg will hold its carrier indefinitely
# otherwise, so close the pipe from the exporter's end rather than killing the
# group and losing the counters the run is for.
pkill -KILL -P "$PUB" 2>/dev/null
kill -KILL "$PUB" 2>/dev/null
sleep 3
pkill -TERM -f "broadcast $BCAST export" 2>/dev/null
sleep 8

grep -v "moq_native\|moq_net" "$R/leg.log"

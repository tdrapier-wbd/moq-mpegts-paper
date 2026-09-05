#!/usr/bin/env bash
#
# T22 — silent media-plane failure: the feed stops, the transport does not.
#
#   t22-silent-stall.sh <label> <arm> [stall_s] [window_s]
#
#   arms:  input      the source feeding the publisher freezes (SIGSTOP on tsp)
#          publisher  the publisher process freezes (SIGSTOP on `moq import ts`)
#          relay      the relay freezes (SIGSTOP on `moq-relay`)
#          control    nothing is injected, to establish the false-positive floor
#
# NOTHING IS KILLED. That is the whole design. Every failure drill in the campaign so far has
# removed a process, and a removed process is the easy case: the socket closes, the peer
# notices, something reconnects. The failure an operator is least protected against is the one
# where every component is still running and still connected and the programme has stopped —
# an alarm set on process liveness or session state reports green while the feed is off air.
# `SIGSTOP` produces exactly that: the process exists, its sockets stay open, its connection
# state is untouched, and it does no work.
#
# WHAT IS BEING TIMED is the interval from the last advancing media to the first moment each
# candidate detector could have fired, per detector, plus what the transport said throughout.
# `t22-wire-observer.py` records the carrier and the clock separately at 100 ms, because the
# premise of the failure is that those two disagree: a groomer holds its bitrate over a dead
# source, so bytes keep arriving at the nominal rate while no PCR advances.
#
# THE GROOMER'S STALL POLICY IS A VARIABLE, not a setting, so each arm runs twice. Under
# `mute` the groomer stops emitting and the failure becomes visible downstream; under
# `continue` it holds a byte-perfect CBR carrier with no programme in it and the failure
# stays silent. Which one is right is a deployment question; what it costs is measurable, and
# that is the point of running both.
#
# Resumption is by `SIGCONT` after `stall_s`, so the recovery half is scored on the same run:
# how long until useful media returns, and how much programme was lost.
set -uo pipefail

LABEL=${1:?label}
ARM=${2:?arm: input|publisher|relay|control}
STALL=${3:-30}
WINDOW=${4:-120}
POLICY=${POLICY:-mute}
RATE=${RATE:-11000000}
CUSHION_MS=${CUSHION_MS:-1000}
CAP_MS=${CAP_MS:-2500}
PORT=${PORT:-4461}

MOQ=${MOQ:-$HOME/bin-3006/moq}
RELAY=${RELAY:-$HOME/bin-3006/moq-relay}
PACER=${PACER:-$HOME/pacer/mpegts-pacer}
OBSERVER=${OBSERVER:-$HOME/t22/t22-wire-observer.py}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
DIR=${DIR:-$HOME/t22}

RUN=$DIR/$LABEL
mkdir -p "$RUN"
BCAST="t22.$LABEL"
KIDS=()

for f in "$MOQ" "$RELAY" "$PACER" "$OBSERVER" "$CLIP"; do
	[ -e "$f" ] || {
		echo "missing: $f" >&2
		exit 1
	}
done

if pgrep -f "[m]oq-relay --server-bind 127.0.0.1:$PORT" >/dev/null 2>&1; then
	echo "a relay is already bound to 127.0.0.1:$PORT — kill it before starting" >&2
	exit 1
fi

# A stopped process cannot be killed, and a SIGSTOPped process left behind holds the port and
# wedges the next run. Continue everything by signature before tearing it down.
cleanup() {
	pkill -CONT -f "$BCAST" 2>/dev/null
	pkill -CONT -f "[m]oq-relay --server-bind 127.0.0.1:$PORT" 2>/dev/null
	pkill -CONT -f "[t]sp -I file $CLIP" 2>/dev/null
	sleep 0.3
	for p in ${KIDS+"${KIDS[@]}"}; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in ${KIDS+"${KIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
	pkill -9 -f "$BCAST" 2>/dev/null
	pkill -9 -f "[m]oq-relay --server-bind 127.0.0.1:$PORT" 2>/dev/null
	true
}
trap cleanup EXIT

stamp() { date +%s.%3N; }
event() { echo "$(stamp) $*" >>"$RUN/events.log"; }

: >"$RUN/events.log"

"$RELAY" --server-bind "127.0.0.1:$PORT" --tls-generate localhost --auth-public "" \
	>"$RUN/relay.log" 2>&1 &
RELAY_PID=$!
KIDS+=("$RELAY_PID")
sleep 2
event "relay up pid=$RELAY_PID"

# The source and the publisher are separate processes on purpose: freezing the source with the
# publisher still running is the "input stalled, session healthy" case, and it is not the same
# failure as freezing the publisher.
tsp -I file "$CLIP" --infinite -P regulate --pcr-synchronous -O file - 2>"$RUN/tsp.log" |
	"$MOQ" --client-tls-disable-verify --client-connect "https://127.0.0.1:$PORT/anon" \
		--broadcast "$BCAST" import ts >"$RUN/pub.log" 2>&1 &
KIDS+=("$!")
sleep 1
TSP_PID=$(pgrep -f "[t]sp -I file $CLIP" | head -1)
PUB_PID=$(pgrep -f "$BCAST import" | head -1)
event "publisher up tsp=$TSP_PID pub=$PUB_PID"
sleep 4

"$MOQ" --client-tls-disable-verify --client-connect "https://127.0.0.1:$PORT/anon" \
	--broadcast "$BCAST" export ts --latency-max 500ms 2>"$RUN/export.log" |
	"$PACER" - "$RATE" --latency-ms "$CUSHION_MS" --max-latency-ms "$CAP_MS" \
		--stall-ms 1000 --on-stall "$POLICY" --stats-interval-ms 5000 2>"$RUN/pacer.log" |
	python3 "$OBSERVER" --tick 0.1 >"$RUN/wire.csv" 2>"$RUN/observer.log" &
KIDS+=("$!")
EXP_PID=$(pgrep -f "$BCAST export" | head -1)
event "egress up export=$EXP_PID policy=$POLICY"

# Settle before injecting, so the cushion is at its set point rather than still priming and
# the detection latency is not measured against a transient.
SETTLE=${SETTLE:-25}
sleep "$SETTLE"
event "settled"

case "$ARM" in
input) VICTIM_PID=$TSP_PID VICTIM=tsp ;;
publisher) VICTIM_PID=$PUB_PID VICTIM=publisher ;;
relay) VICTIM_PID=$RELAY_PID VICTIM=relay ;;
control) VICTIM_PID="" VICTIM=none ;;
*)
	echo "unknown arm $ARM" >&2
	exit 1
	;;
esac

if [ -n "$VICTIM_PID" ]; then
	kill -STOP "$VICTIM_PID"
	event "STOP $VICTIM pid=$VICTIM_PID"
	# What the transport says while the media is gone is the control reading of the whole
	# experiment, so it is sampled during the stall rather than inferred afterwards.
	for _ in $(seq 1 "$STALL"); do
		ESTAB=$(ss -uan 2>/dev/null | grep -c ":$PORT" || true)
		event "transport udp_sockets=$ESTAB victim_state=$(awk '{print $3}' "/proc/$VICTIM_PID/stat" 2>/dev/null || echo gone)"
		sleep 1
	done
	kill -CONT "$VICTIM_PID"
	event "CONT $VICTIM pid=$VICTIM_PID"
else
	sleep "$STALL"
	event "control: no injection"
fi

sleep "$WINDOW"
event "window closed"

{
	echo "label=$LABEL arm=$ARM policy=$POLICY stall_s=$STALL window_s=$WINDOW settle_s=$SETTLE"
	echo "rate=$RATE cushion=${CUSHION_MS}ms cap=${CAP_MS}ms port=$PORT"
	echo "moq=$($MOQ --version 2>&1 | head -1) relay=$($RELAY --version 2>&1 | head -1)"
	echo "pacer=$($PACER --version 2>&1 | head -1)"
	echo "clip=$CLIP md5=$(md5sum "$CLIP" | cut -d' ' -f1)"
} >"$RUN/meta.txt"

echo "done: $RUN"

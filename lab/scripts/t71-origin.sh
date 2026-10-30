#!/usr/bin/env bash
# T71's origin: an open relay, the clock reference and one lane's source, on a host that also runs
# standing units, which it leaves alone.
#
#   t71-origin.sh relay-up <dir> | relay-down <dir> | clock-up <dir> | clock-down <dir>
#   t71-origin.sh start <cell-dir> <srt|opaque|aware> <seconds> <broadcast> | stop <cell-dir>
#
# The source is the clip from its start, paced by `tsp -P regulate` and tapped by a mirrored fork in
# the same process as the transmitter: an inline tap between pacing and an SRT sender cost that lane
# seconds and thousands of continuity errors (T28). On the MoQ lanes the transmitter is the pipe into
# `moq import ts`.
#
# Every stage starts in its own session, with all three streams redirected so the ssh that started it
# returns, and stops by the process group recorded in <dir>/<role>.pgid, never by a name pattern: the
# host's standing relay and publisher are `moq-relay`, `moq` and `tsp` too. One `timeout`, outermost,
# bounds each stage; an inner one would move its children out of the recorded group.
#
# Env: BIN (~/bin-66af7231), CLIP (~/contrib-10m.ts), RELAY_PORT (4711), SRT_PORT (9711),
# CLOCK_PORT (9710), CC (delay), BUFMS (1000), VPID (111), CLOCK_LIFETIME (14400 s)
set -euo pipefail

ACTION=${1:?action}
DIR=${2:?dir}
BIN=${BIN:-$HOME/bin-66af7231}
CLIP=${CLIP:-$HOME/contrib-10m.ts}
SCRIPTS=${SCRIPTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
RELAY_PORT=${RELAY_PORT:-4711}
SRT_PORT=${SRT_PORT:-9711}
CLOCK_PORT=${CLOCK_PORT:-9710}
CC=${CC:-delay}
BUFMS=${BUFMS:-1000}
VPID=${VPID:-111}

mkdir -p "$DIR"
DIR=$(cd "$DIR" && pwd)

launch() {
	local role=$1
	shift
	setsid "$@" >"$DIR/$role.log" 2>&1 </dev/null &
	echo $! >"$DIR/$role.pgid"
	sleep 2
	local g
	g=$(cat "$DIR/$role.pgid")
	if ! kill -0 "$g" 2>/dev/null; then
		echo "$role exited at once; its log:" >&2
		cat "$DIR/$role.log" >&2
		rm -f "$DIR/$role.pgid"
		exit 1
	fi
	[ "$(ps -o sid= -p "$g" | tr -d ' ')" = "$g" ] || {
		echo "$role is not its own session leader; stop it by hand (pid $g)" >&2
		exit 1
	}
	echo "$role up, pgid $g"
}

halt() {
	local f="$DIR/$1.pgid"
	[ -s "$f" ] || {
		echo "no $1.pgid in $DIR; nothing to stop"
		return 0
	}
	local g
	g=$(cat "$f")
	kill -TERM -- "-$g" 2>/dev/null || true
	sleep 1
	kill -KILL -- "-$g" 2>/dev/null || true
	rm -f "$f"
	echo "$1 stopped (pgid $g)"
}

case "$ACTION" in
relay-up)
	echo "relay: $(head -n 1 "$BIN.sha" 2>/dev/null || echo 'no sidecar'), controller $CC" >"$DIR/relay-build.txt"
	launch relay timeout "${CLOCK_LIFETIME:-14400}" "$BIN/moq-relay" --listen "0.0.0.0:$RELAY_PORT" \
		--listen-tls-generate localhost --auth-public "**" --quic-congestion-control "$CC"
	;;
relay-down) halt relay ;;
clock-up)
	launch clock python3 "$SCRIPTS/t18-latency.py" clock-server "$CLOCK_PORT" \
		--seconds "${CLOCK_LIFETIME:-14400}"
	;;
clock-down) halt clock ;;
start)
	LANE=${3:?lane: srt, opaque or aware}
	SECS=${4:?seconds}
	BCAST=${5:?broadcast}
	RUN=$((SECS + 40))
	rm -f "$DIR/source.csv"
	tap="python3 $SCRIPTS/t18-latency.py tap $VPID $DIR/source.csv --pipe --seconds $RUN > /dev/null"
	pace=(tsp --realtime -I file "$CLIP" -P regulate --pcr-synchronous --wait-min 5
		-P fork --nowait --ignore-abort "$tap")
	case "$LANE" in
	srt)
		launch source timeout "$RUN" "${pace[@]}" -O srt --listener "0.0.0.0:$SRT_PORT" --latency "$BUFMS"
		;;
	opaque | aware)
		imp=(import ts)
		[ "$LANE" = opaque ] && imp=(import ts --passthrough)
		left=("${pace[@]}" -O file -)
		# shellcheck disable=SC2016
		launch source timeout "$RUN" bash -c 'n=$1; shift; "${@:1:n}" | "${@:n+1}"' _ "${#left[@]}" \
			"${left[@]}" "$BIN/moq" --connect-tls-insecure --connect "https://127.0.0.1:$RELAY_PORT/anon" \
			--connect-websocket-enabled=false --broadcast "$BCAST" "${imp[@]}"
		;;
	*)
		echo "unknown lane: $LANE" >&2
		exit 2
		;;
	esac
	;;
stop) halt source ;;
*)
	echo "unknown action: $ACTION" >&2
	exit 2
	;;
esac

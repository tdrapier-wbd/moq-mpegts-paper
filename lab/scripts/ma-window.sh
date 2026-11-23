#!/bin/bash
# Feed 2 (`ma`) on a candidate build, beside or in place of the lane's own chain, on the secondary.
#
#   ma-window.sh up <port>     candidate: own relay on 127.0.0.1:4495, `import ts --program 1` from
#                              the group, `export ts --delay 2s`, the lane's groomer, to 127.0.0.1:<port>
#   ma-window.sh base <port>   the lane's own chain (standing relay, MOQ_MA) to 127.0.0.1:<port>
#   ma-window.sh serve <port>  as `up`, in the foreground, each stage restarted 2 s after it exits
#                              (each exit logged to serve.log): for the `ma-window` unit
#   ma-window.sh down          stop whatever `up` or `base` started
#
# The window itself: `sudo systemctl stop srt-lane-ma; ma-window.sh up 5191`; back:
# `ma-window.sh down; sudo systemctl start srt-lane-ma`. srt-send-ma reads 127.0.0.1:5191 throughout.
# Env: BIN (candidate bindir), PORT (4495, its relay), RUN (~/ma-window), VERSION (forced on the
# candidate's relay and clients; empty for the default), BCAST, GROUP, RATE, DELAY, FOLLOW (10s:
# the candidate's export follows a republish as a program switch, `--follow FOLLOW --stitch`;
# empty: it exits), PUBLIC (**, the relay's anonymous grant; current main takes ''), MA_LAT_MS,
# PACER, MOQ_MA, SRC, MA_JWT_FILE.
set -u
BIN=${BIN:-$HOME/bin-9757807f}
VERSION=${VERSION-moq-lite-07-wip}
GROUP=${GROUP:-239.255.0.1:5000}
RATE=${RATE:-26000000}
DELAY=${DELAY:-2s}
FOLLOW=${FOLLOW-10s}
PUBLIC=${PUBLIC-**}
FOLLOWS=${FOLLOW:+--follow $FOLLOW --stitch}
MA_LAT_MS=${MA_LAT_MS:-1000}
PACER=${PACER:-$HOME/pacer-97f3a38/mpegts-pacer}
MOQ_MA=${MOQ_MA:-$HOME/bin-3c0daa21/moq}
SRC=${SRC-}
BCAST=${BCAST-}
MA_JWT_FILE=${MA_JWT_FILE:-$HOME/.moq-live/probe.jwt}
RUN=${RUN:-$HOME/ma-window}
PORT=${PORT:-4495}
mkdir -p "$RUN"
export PACER RATE MA_LAT_MS

groom() {
	"$PACER" "127.0.0.1:$1" "$RATE" --stream-clock --sequence-seed 0 --stall-ms 1000 \
		--on-stall mute --stats-interval-ms 10000 --latency-ms "$MA_LAT_MS" --max-latency-ms 8000
}

export -f groom

up() {
	local to=$1 ver=() C
	[ -n "$VERSION" ] && ver=(--listen-version "$VERSION")
	setsid "$BIN/moq-relay" --listen "127.0.0.1:$PORT" --listen-tls-generate localhost \
		--auth-public "$PUBLIC" --quic-gso=false "${ver[@]}" > "$RUN/relay.log" 2>&1 &
	echo $! > "$RUN/relay.pid"
	sleep 2
	C="--connect-tls-insecure --connect https://127.0.0.1:$PORT/anon --quic-gso=false"
	[ -n "$VERSION" ] && C="$C --connect-version $VERSION"
	setsid bash -c "tsp -I ip $GROUP --local-address 127.0.0.1 -O file - 2>>'$RUN/tsp.log' \
		| '$BIN/moq' $C --broadcast window.hang import ts --program 1" > "$RUN/import.log" 2>&1 &
	echo $! > "$RUN/import.pid"
	sleep 3
	setsid bash -c "'$BIN/moq' $C --broadcast window.hang export ts --delay $DELAY $FOLLOWS 2>'$RUN/export.log' \
		| groom $to" > "$RUN/pacer.log" 2>&1 &
	echo $! > "$RUN/export.pid"
}

# loop <name> <cmd...>: run cmd, and again 2 s after each exit, logging each exit to serve.log
loop() {
	local name=$1 rc
	shift
	while :; do
		"$@"
		rc=$?
		echo "$(date -u +%FT%TZ) $name exited $rc" >>"$RUN/serve.log"
		sleep 2
	done
}

# serve <port>: `up` in the foreground for a unit, each stage restarted whenever it exits
serve() {
	local to=$1 ver=() C
	[ -n "$VERSION" ] && ver=(--listen-version "$VERSION")
	C="--connect-tls-insecure --connect https://127.0.0.1:$PORT/anon --quic-gso=false"
	[ -n "$VERSION" ] && C="$C --connect-version $VERSION"
	loop relay bash -c "'$BIN/moq-relay' --listen 127.0.0.1:$PORT --listen-tls-generate localhost \
		--auth-public '$PUBLIC' --quic-gso=false ${ver[*]} >>'$RUN/relay.log' 2>&1" &
	sleep 2
	loop import bash -c "tsp -I ip $GROUP --local-address 127.0.0.1 -O file - 2>>'$RUN/tsp.log' \
		| '$BIN/moq' $C --broadcast window.hang import ts --program 1 >>'$RUN/import.log' 2>&1" &
	sleep 3
	loop export bash -c "'$BIN/moq' $C --broadcast window.hang export ts --delay $DELAY $FOLLOWS 2>>'$RUN/export.log' \
		| groom $to >>'$RUN/pacer.log' 2>&1" &
	wait
}

base() {
	local to=$1
	: "${SRC:?set SRC to the standing relay host}" "${BCAST:?set BCAST to the lane broadcast}"
	setsid bash -c "MOQ_CONNECT='https://$SRC:443/anon?jwt=$(cat "$MA_JWT_FILE")' '$MOQ_MA' --connect-tls-insecure \
		--broadcast '$BCAST' export ts --delay $DELAY 2>'$RUN/base-export.log' \
		| groom $to" > "$RUN/base-pacer.log" 2>&1 &
	echo $! > "$RUN/base.pid"
}

down() {
	local f pid
	for f in export import base relay; do
		[ -f "$RUN/$f.pid" ] || continue
		pid=$(cat "$RUN/$f.pid")
		kill -TERM -- "-$pid" 2>/dev/null
		rm -f "$RUN/$f.pid"
	done
}

case ${1:-} in
up) up "$2" ;;
serve) serve "$2" ;;
base) base "$2" ;;
down) down ;;
*)
	echo "usage: $0 up <port> | serve <port> | base <port> | down" >&2
	exit 2
	;;
esac

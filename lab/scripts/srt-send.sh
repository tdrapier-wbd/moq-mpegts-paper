#!/usr/bin/env bash
# SRT sends of the live feed for an IRD or a TS analyser: as this host received it, or as it arrives
# here over one of the three lanes from the other host. Every process is a transient systemd unit, so
# a send starts and stops without touching the standing units, the HLS edges or a soak's origin.
#
#   srt-send.sh start LANE listener PORT [LATENCY_MS]       the receiver calls this host (a /32 UDP rule)
#   srt-send.sh start LANE caller HOST:PORT [LATENCY_MS]    this host calls the receiver's listener
#   srt-send.sh stop LANE|all
#   srt-send.sh status
#   srt-send.sh origin start|stop                           on the source host, for the pt lane
#
# LANE, with SRC the source host's private address:
#   rx   the contribution as this host received it (stage 1's loopback group), untouched;
#   ma   media-aware MoQ: `export ts` from SRC's standing relay (broadcast BCAST, the subscribe
#        token in MA_JWT_FILE), groomed by `mpegts-pacer --stream-clock` at RATE;
#   pt   passthrough MoQ: `export ts --passthrough` from the lane relay `origin start` runs on SRC:
#        the source's bytes, released on its PCR, not groomed;
#   seg  segmented HTTP: b8-hls-recv.py (beside this script) on SRC's HLS edge (the tokened playlist
#        URL in SEG_URL_FILE), held to each segment's program date-time, groomed as ma.
#
# A lane other than rx is a producer unit (srt-lane-LANE) sending UDP to 127.0.0.1:519N and a sender
# unit (srt-send-LANE) reading it, so a receiver's disconnect restarts only the sender. Lanes run in
# parallel, one SRT port each. Tokens are read from their files inside the unit and reach no command
# line; the SRT passphrase does, because tsp takes it only as an argument.
#
# Env: SRC, BCAST, MA_JWT_FILE (~/.moq-live/probe.jwt), SEG_URL_FILE (~/.srt-send/seg.url),
#   PASSPHRASE_FILE (AES-256), GROUP (239.255.0.1:5000), RATE (26000000), DELAY (2s, both exports),
#   MA_LAT_MS (1000), SEG_LAT_MS (8000), SEG_RELEASE_MS (1500), LANE_PORT (4490), MOQ_MA
#   (~/bin-3c0daa21/moq, the standing relay's build), MOQ_PT (~/bin-66af7231), PACER
#   (~/pacer-97f3a38/mpegts-pacer).

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GROUP=${GROUP:-239.255.0.1:5000}
RATE=${RATE:-26000000}
DELAY=${DELAY:-2s}
MA_LAT_MS=${MA_LAT_MS:-1000}
SEG_LAT_MS=${SEG_LAT_MS:-8000}
SEG_RELEASE_MS=${SEG_RELEASE_MS:-1500}
LANE_PORT=${LANE_PORT:-4490}
MA_JWT_FILE=${MA_JWT_FILE:-$HOME/.moq-live/probe.jwt}
SEG_URL_FILE=${SEG_URL_FILE:-$HOME/.srt-send/seg.url}
MOQ_MA=${MOQ_MA:-$HOME/bin-3c0daa21/moq}
MOQ_PT=${MOQ_PT:-$HOME/bin-66af7231}
PACER=${PACER:-$HOME/pacer-97f3a38/mpegts-pacer}
LOGDIR=$HOME/.srt-send
PT_BCAST=lane.pt.hang
LANES="rx ma pt seg"
UNITS="srt-send-rx srt-lane-ma srt-send-ma srt-lane-pt srt-send-pt srt-lane-seg srt-send-seg
	srt-lane-relay srt-lane-pt-pub"

# The playlist URL carries the token, so the receiver's arguments are set inside the interpreter.
B8_URL_FROM_FILE='import runpy, sys
url_file, b8 = sys.argv[1:3]
sys.argv = [b8, open(url_file).read().strip(), "-"] + sys.argv[3:]
runpy.run_path(b8, run_name="__main__")'

die() {
	echo "$*" >&2
	exit 2
}

redact() {
	sed -E 's/eyJ[A-Za-z0-9._-]+/<T>/g; s/jwt=[^ "&]+/jwt=<T>/g; s#/t/[^ "]+#/t/<T>#g; s/passphrase [^ ]+/passphrase <P>/g'
}

udp_port() {
	case $1 in
	ma) echo 5191 ;;
	pt) echo 5192 ;;
	seg) echo 5193 ;;
	esac
}

unit() {
	local name=$1
	shift
	# tsp's SRT listener ignores SIGTERM while it waits for a caller.
	sudo systemd-run --quiet --unit="$name" --uid="$(id -u)" --property=Nice=5 \
		--property=Restart=always --property=RestartSec=2 --property=TimeoutStopSec=5 "$@"
}

# Non-secret settings only: unit properties are readable by every local user.
config_env() {
	local v
	for v in HOME SRC BCAST MA_JWT_FILE SEG_URL_FILE GROUP RATE DELAY MA_LAT_MS SEG_LAT_MS \
		SEG_RELEASE_MS LANE_PORT MOQ_MA MOQ_PT PACER ADDR; do
		printf -- '--setenv=%s=%s\n' "$v" "${!v:-}"
	done
}

# Runs inside srt-lane-LANE.
produce() {
	local lane=$1 to
	to=127.0.0.1:$(udp_port "$lane")
	local groom=("$PACER" "$to" "$RATE" --stream-clock --sequence-seed 0 --stall-ms 1000
		--on-stall mute --stats-interval-ms 10000)
	case $lane in
	ma)
		MOQ_CONNECT="https://$SRC:443/anon?jwt=$(cat "$MA_JWT_FILE")" "$MOQ_MA" --connect-tls-insecure \
			--broadcast "$BCAST" export ts --delay "$DELAY" |
			"${groom[@]}" --latency-ms "$MA_LAT_MS" --max-latency-ms 8000
		;;
	pt)
		"$MOQ_PT/moq" --connect-tls-insecure --connect "https://$SRC:$LANE_PORT/anon" \
			--broadcast "$PT_BCAST" export ts --passthrough --delay "$DELAY" |
			tsp --realtime --buffer-size-mb 1 --max-input-packets 7 -I file - -O ip "$to"
		;;
	seg)
		python3 -c "$B8_URL_FROM_FILE" "$SEG_URL_FILE" "$HERE/b8-hls-recv.py" --seconds 0 \
			--release-ms "$SEG_RELEASE_MS" --log "$LOGDIR/seg-b8.jsonl" |
			"${groom[@]}" --latency-ms "$SEG_LAT_MS" --max-latency-ms 14000
		;;
	esac
}

# Runs inside srt-lane-pt-pub, on the source host: the opaque lane's publisher beside the live one.
publish() {
	tsp -I ip "$GROUP" --local-address 127.0.0.1 --buffer-size 16777216 -O file - |
		"$MOQ_PT/moq" --connect-tls-insecure --connect "https://$ADDR:$LANE_PORT/anon" \
			--broadcast "$PT_BCAST" import ts --passthrough
}

sender() {
	local lane=$1 mode=$2 addr=$3 latency=${4:-1000} in srt crypt=""
	case $mode in
	listener) srt="--listener 0.0.0.0:$addr" ;;
	caller) srt="--caller $addr" ;;
	*) die "mode: listener or caller" ;;
	esac
	if [ "$lane" = rx ]; then
		in=$GROUP
	else
		in=$(udp_port "$lane")
	fi
	if [ -n "${PASSPHRASE_FILE:-}" ]; then
		[ -r "$PASSPHRASE_FILE" ] || die "cannot read $PASSPHRASE_FILE"
		crypt="--passphrase \"\$(cat '$PASSPHRASE_FILE')\" --pbkeylen 32"
	fi
	unit "srt-send-$lane" /bin/bash -c "exec tsp --buffer-size-mb 1 -I ip $in --local-address 127.0.0.1 \
		-O srt $srt --transtype live --latency $latency $crypt"
}

start() {
	local lane=$1 envs
	shift
	case " $LANES " in *" $lane "*) ;; *) die "LANE: one of $LANES" ;; esac
	if [ "$lane" != rx ]; then
		[ -n "${SRC:-}" ] || die "SRC: the source host's private address"
		case $lane in
		ma) [ -n "${BCAST:-}" ] && [ -r "$MA_JWT_FILE" ] || die "ma needs BCAST and MA_JWT_FILE" ;;
		seg) [ -r "$SEG_URL_FILE" ] || die "seg needs SEG_URL_FILE" ;;
		esac
		mkdir -p "$LOGDIR"
		chmod 700 "$LOGDIR"
		mapfile -t envs < <(config_env)
		unit "srt-lane-$lane" "${envs[@]}" /bin/bash "$HERE/srt-send.sh" _lane "$lane"
	fi
	sender "$lane" "$@"
	sleep 3
	status
}

stop() {
	sudo systemctl stop "$@" 2>/dev/null || true
	sudo systemctl reset-failed "$@" 2>/dev/null || true
}

status() {
	local u
	for u in $UNITS; do
		[ "$(systemctl show "$u" -p LoadState --value)" = loaded ] || continue
		printf '%-16s %s\n' "$u" "$(systemctl show "$u" -p ActiveState -p NRestarts -p ExecMainStartTimestamp |
			tr '\n' ' ')"
		journalctl -u "$u" -n 2 --no-pager -o cat 2>/dev/null | cut -c1-200 | redact | sed 's/^/    /'
	done
}

origin() {
	local envs
	ADDR=${ADDR:-$(ip -4 -o addr show ens5 | awk '{print $4}' | cut -d/ -f1)}
	case ${1:-} in
	start)
		unit srt-lane-relay "$MOQ_PT/moq-relay" --listen "$ADDR:$LANE_PORT" --listen-tls-generate "$ADDR" \
			--auth-public "**" --quic-gso=false --log-level warn
		sleep 2
		mapfile -t envs < <(config_env)
		unit srt-lane-pt-pub "${envs[@]}" /bin/bash "$HERE/srt-send.sh" _publish
		sleep 3
		status
		;;
	stop) stop srt-lane-pt-pub srt-lane-relay ;;
	*) die "origin start|stop" ;;
	esac
}

case "${1:-}" in
start) start "${2:?LANE}" "${3:?mode}" "${4:?PORT or HOST:PORT}" "${5:-}" ;;
stop)
	lanes=${2:?LANE or all}
	[ "$lanes" = all ] && lanes=$LANES
	units=()
	for l in $lanes; do units+=("srt-send-$l" "srt-lane-$l"); done
	stop "${units[@]}"
	;;
status) status ;;
origin) origin "${2:-}" ;;
_lane) produce "${2:?}" ;;
_publish) publish ;;
*) die "usage: srt-send.sh start LANE listener PORT|caller HOST:PORT [LATENCY_MS] | stop LANE|all | status | origin start|stop" ;;
esac

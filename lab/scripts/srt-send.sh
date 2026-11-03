#!/usr/bin/env bash
# An SRT send of the live feed as received, for an IRD or a TS analyser, from the primary or the
# secondary. It joins the contribution's loopback group (stage 1's output) read-only and serves it
# from a transient systemd unit, so it starts and stops without touching the standing units, the HLS
# edges or a soak's origin.
#
#   srt-send.sh start listener PORT [LATENCY_MS]       the receiver calls this host (a /32 UDP rule)
#   srt-send.sh start caller HOST:PORT [LATENCY_MS]    this host calls the receiver's listener
#   srt-send.sh stop | status
#
# Env: PASSPHRASE_FILE (AES-256 with the passphrase in that file), GROUP (239.255.0.1:5000).
# LATENCY_MS defaults to 1000. The unit restarts after a receiver disconnects.

set -euo pipefail
UNIT=srt-send
GROUP=${GROUP:-239.255.0.1:5000}

start() {
	local mode=$1 addr=$2 latency=${3:-1000} srt crypt=""
	case $mode in
	listener) srt="--listener 0.0.0.0:$addr" ;;
	caller) srt="--caller $addr" ;;
	*)
		echo "mode: listener or caller" >&2
		exit 2
		;;
	esac
	if [ -n "${PASSPHRASE_FILE:-}" ]; then
		[ -r "$PASSPHRASE_FILE" ] || {
			echo "cannot read $PASSPHRASE_FILE" >&2
			exit 2
		}
		crypt="--passphrase \"\$(cat '$PASSPHRASE_FILE')\" --pbkeylen 32"
	fi
	sudo systemd-run --unit="$UNIT" --uid="$(id -u)" --property=Nice=5 --property=Restart=always \
		--property=RestartSec=2 /bin/bash -c "exec tsp --buffer-size-mb 1 \
		-I ip $GROUP --local-address 127.0.0.1 -O srt $srt --transtype live --latency $latency $crypt"
	sleep 2
	status
}

status() {
	systemctl show "$UNIT" -p ActiveState -p SubState -p NRestarts -p ExecMainStartTimestamp
	journalctl -u "$UNIT" -n 5 --no-pager -o cat 2>/dev/null | sed -E 's/passphrase [^ ]+/passphrase <P>/g'
}

case "${1:-}" in
start) start "${2:?mode}" "${3:?PORT or HOST:PORT}" "${4:-}" ;;
stop) sudo systemctl stop "$UNIT" ;;
status) status ;;
*)
	echo "usage: srt-send.sh start listener PORT [LATENCY_MS] | start caller HOST:PORT [LATENCY_MS] | stop | status" >&2
	exit 2
	;;
esac

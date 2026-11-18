#!/usr/bin/env bash
# T67 — a passthrough lane in shadow on the live feed, through the encoder's own switches.
#
# usage: t67p-shadow.sh <bin dir with moq and moq-relay> <out dir> [hours]
#
# Its own relay on loopback, a passthrough import of the feed's loopback multicast group (§7a), and a
# passthrough export, each restarted if it exits and each exit logged (supervisor-*.txt). A tap on
# each side (t67p-tap.py) records counters, not media: in.csv before the import, out.csv after the
# export. rss.txt samples the processes' resident memory every 10 minutes. Touches no standing unit:
# it only joins the group.
#
# env: PORT (4823, UDP), MCAST (239.255.0.1:5000), LAT (1s), MOQ_CONNECT_VERSION and
#      MOQ_LISTEN_VERSION (moq-lite-07-wip).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=${1:?bin dir with moq and moq-relay}
OUT=${2:?out dir}
HOURS=${3:-72}
PORT=${PORT:-4823}
MCAST=${MCAST:-239.255.0.1:5000}
LAT=${LAT:-1s}
export MOQ_CONNECT_VERSION=${MOQ_CONNECT_VERSION:-moq-lite-07-wip}
export MOQ_LISTEN_VERSION=${MOQ_LISTEN_VERSION:-moq-lite-07-wip}
BCAST="t67.shadow.$$.hang"

# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"

mkdir -p "$OUT"
now() { date +%s.%N | cut -c1-14; }
{
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	echo "hours=$HOURS mcast=$MCAST lat=$LAT version=$MOQ_CONNECT_VERSION host=$(hostname)"
	echo "started=$(now)"
} >"$OUT/meta.txt"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	pkill -f -- "--broadcast $BCAST" 2>/dev/null
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	echo "ended=$(now)" >>"$OUT/meta.txt"
}
trap cleanup EXIT

moq_relay_public "127.0.0.1:$PORT" 127.0.0.1 --log-level info
"$BIN/moq-relay" "${RELAY_ARGV[@]}" >"$OUT/relay.log" 2>&1 &
PIDS+=($!)
sleep 2
C=("${MOQ_DIAL[@]}" "https://127.0.0.1:$PORT" --broadcast "$BCAST")

supervise() { # $1 side; the rest, the command run through bash
	local side=$1 k=0
	shift
	while :; do
		echo "start $k $(now)" >>"$OUT/supervisor-$side.txt"
		bash -c "$*"
		echo "exit $k $? $(now)" >>"$OUT/supervisor-$side.txt"
		k=$((k + 1))
		sleep 1
	done
}
printf -v DIAL '%q ' "${C[@]}"
supervise import "tsp -I ip $MCAST --local-address 127.0.0.1 -O file - 2>>$OUT/tsp.log |
	python3 $HERE/t67p-tap.py $OUT/in.csv --tee |
	$BIN/moq $DIAL import ts --passthrough 2>>$OUT/import.log" &
PIDS+=($!)
sleep 3
supervise export "$BIN/moq $DIAL export ts ${MOQ_LAT[*]} $LAT --passthrough 2>>$OUT/export.log |
	python3 $HERE/t67p-tap.py $OUT/out.csv" &
PIDS+=($!)

end=$(($(date +%s) + HOURS * 3600))
while [ "$(date +%s)" -lt "$end" ]; do
	line="$(now) relay $(ps -o rss= -p "${PIDS[0]}")"
	for side in import export; do
		p=$(pgrep -f -- "^$BIN/moq .*$BCAST $side ts" | head -1)
		line+=" $side ${p:+$(ps -o rss= -p "$p")}"
	done
	echo "$line" >>"$OUT/rss.txt"
	sleep 600
done

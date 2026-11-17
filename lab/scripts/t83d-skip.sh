#!/usr/bin/env bash
# T83 Part D's skip test: the live feed through a relay that writes qlog, subscribed across the path
# by two media-aware exports, one at the `ma` lane's 2 s delay and one at SRT's matched latency,
# while the receiving host blacks out the relay's flow inbound in bursts of set lengths.
#
#   ROLE=src (publishing host): the relay, as the standing relay's flags, on BIND:PORT with
#     --quic-qlog OUT/qlog, and an importer of the live feed's multicast as the standing publisher's.
#   ROLE=rcv (receiving host, root): the two exports, each tapped with arrival times (d2, d6), after
#     a control with no burst, BURSTS lengths REPS times, GAP s apart, each an iptables INPUT drop
#     of the relay's UDP from PEER; events.txt holds each burst's on and off.
#
#   T0=<epoch s> ROLE=src|rcv PEER=<other host> BIN=<moq dir> t83d-skip.sh <label>
#
# Env: PORT (4810), FEED (239.255.0.1:5000), DELAYS ("2s 5822ms"), BURSTS ("0.25 0.5 1 1.5 2 3 4"),
#      REPS (3), CONTROL (60 s), GAP (25 s), OUT (/tmp/t83d-skip), BIND (first of `hostname -I`).
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LABEL=${1:?label}
ROLE=${ROLE:?src or rcv}
T0=${T0:?epoch seconds}
PEER=${PEER:?the other host}
BIN=${BIN:?moq dir}
PORT=${PORT:-4810}
FEED=${FEED:-239.255.0.1:5000}
read -ra DELAYS <<<"${DELAYS:-2s 5822ms}"
read -ra BURSTS <<<"${BURSTS:-0.25 0.5 1 1.5 2 3 4}"
REPS=${REPS:-3}
CONTROL=${CONTROL:-60}
GAP=${GAP:-25}
OUT=${OUT:-/tmp/t83d-skip}/$LABEL
BC=t83d.skip.$LABEL
FIRST=$((T0 + 10 + CONTROL))
SECS=$((FIRST + ${#BURSTS[@]} * REPS * GAP + 10 - T0))
PIDS=()

now() { date +%s.%N; }
stamp() { echo "$1 $(now)" >>"$OUT/events.txt"; }
until_t() { python3 -c "import time; time.sleep(max(0.0, $1 - time.time()))"; }
drop() { iptables "$1" INPUT -s "$PEER" -p udp --sport "$PORT" -j DROP; }
cleanup() {
	[ "$ROLE" = rcv ] && while drop -D 2>/dev/null; do :; done
	for p in ${PIDS+"${PIDS[@]}"}; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
	sleep 1
	for p in ${PIDS+"${PIDS[@]}"}; do kill -KILL -- "-$p" 2>/dev/null; done
	wait 2>/dev/null
}
trap cleanup EXIT

rm -rf "$OUT"
mkdir -p "$OUT"
{
	echo "=== $(date -u +%FT%TZ) t83d-skip $LABEL ($ROLE, peer $PEER), T0 $T0, ${SECS}s"
	"$BIN/moq" --version 2>&1 | head -1
	[ "$ROLE" = src ] && "$BIN/moq-relay" --version 2>&1 | head -1
	sha256sum "$BIN"/moq* | cut -c1-16
	[ "$ROLE" = rcv ] && echo "delays ${DELAYS[*]}; bursts ${BURSTS[*]} s x $REPS, every ${GAP}s after ${CONTROL}s control"
} >"$OUT/build.txt" 2>&1

if [ "$ROLE" = src ]; then
	BIND=${BIND:-$(hostname -I | awk '{print $1}')}
	mkdir -p "$OUT/qlog"
	until_t "$T0"
	setsid "$BIN/moq-relay" --listen "$BIND:$PORT" --listen-tls-generate "$BIND" --auth-public "**" \
		--quic-gso=false --quic-qlog "$OUT/qlog" --log-level info >"$OUT/relay.log" 2>&1 &
	PIDS+=("$!")
	stamp relay_start
	sleep 2
	setsid bash -c "tsp --realtime -I ip '$FEED' --local-address 127.0.0.1 -O file - 2>>'$OUT/tsp.log' |
		'$BIN/moq' --connect-tls-insecure --connect 'https://$BIND:$PORT/anon' --broadcast '$BC' \
		import ts --program 1 >>'$OUT/import.log' 2>&1" &
	PIDS+=("$!")
	stamp import_start
	until_t "$((T0 + SECS))"
	stamp src_end
	exit 0
fi

[ "$(id -u)" -eq 0 ] || {
	echo "rcv runs as root (iptables)" >&2
	exit 1
}
until_t "$((T0 + 6))"
for d in "${DELAYS[@]}"; do
	n=d${d%%[a-z]*}
	setsid bash -c "MOQ_CONNECT='https://$PEER:$PORT/anon' '$BIN/moq' --connect-tls-insecure --broadcast '$BC' \
		export ts --delay '$d' 2>>'$OUT/$n.log' | python3 '$H/t56-stamp.py' '$OUT/$n'" &
	PIDS+=("$!")
	stamp "export_start_$n"
	sleep 1
done
k=0
for ((r = 1; r <= REPS; r++)); do
	for b in "${BURSTS[@]}"; do
		until_t "$((FIRST + k * GAP))"
		drop -I
		stamp "burst_on $b $r"
		until_t "$(python3 -c "print($FIRST + $k * $GAP + $b)")"
		drop -D
		stamp "burst_off $b $r"
		k=$((k + 1))
	done
done
until_t "$((T0 + SECS))"
stamp rcv_end

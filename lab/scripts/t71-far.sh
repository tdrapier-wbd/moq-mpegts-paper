#!/usr/bin/env bash
# T71's receiver: the impairment on the lanes' flows, one lane's receive stage, and the clock reads.
#
#   sudo -E t71-far.sh impair <loss-%>     the qdiscs, at <loss-%> each way (0 for a clean cell)
#   sudo -E t71-far.sh counters <file>     netem's counters, appended to <file>
#   sudo -E t71-far.sh clear
#   t71-far.sh recv <cell-dir> <srt|opaque|aware> <seconds> <broadcast>
#   t71-far.sh clock <cell-dir> <before|after>
#
# **Only the lanes' flows are impaired.** netem acts on UDP to and from the origin's relay and SRT
# ports, never on the clock probe or the session carrying this host's shell. Ingress datagrams are
# redirected into an ifb whose root is the netem; egress passes a prio qdisc whose fourth band holds
# the netem, with everything else in the second. Each direction loses at the commanded rate,
# independently. GRO is off, so each datagram on the wire meets the netem once (a coalesced one
# would be dropped whole), and the subscriber runs without GSO for the same reason.
#
# Env: ORIGIN_IP (required), BIN (~/bin-66af7231), RELAY_PORT (4711), SRT_PORT (9711),
# CLOCK_PORT (9710), BUFMS (1000), DELAY (1s), VPID (111), DEV (ens5), IFB (ifb71)
set -euo pipefail

ACTION=${1:?action}
ORIGIN_IP=${ORIGIN_IP:?set ORIGIN_IP to the origin address}
BIN=${BIN:-$HOME/bin-66af7231}
SCRIPTS=${SCRIPTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
RELAY_PORT=${RELAY_PORT:-4711}
SRT_PORT=${SRT_PORT:-9711}
CLOCK_PORT=${CLOCK_PORT:-9710}
BUFMS=${BUFMS:-1000}
DELAY=${DELAY:-1s}
VPID=${VPID:-111}
DEV=${DEV:-ens5}
IFB=${IFB:-ifb71}

clear_qdiscs() {
	tc qdisc del dev "$DEV" root 2>/dev/null || true
	tc qdisc del dev "$DEV" ingress 2>/dev/null || true
	ip link del "$IFB" 2>/dev/null || true
}

impair() {
	local loss=$1
	clear_qdiscs
	ethtool -K "$DEV" gro off
	modprobe ifb numifbs=0
	ip link add "$IFB" type ifb
	ip link set "$IFB" up
	tc qdisc add dev "$IFB" root handle 1: netem loss "$loss%"
	tc qdisc add dev "$DEV" handle ffff: ingress
	tc qdisc add dev "$DEV" root handle 1: prio bands 4 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
	tc qdisc add dev "$DEV" parent 1:4 handle 40: netem loss "$loss%"
	local p
	for p in "$RELAY_PORT" "$SRT_PORT"; do
		tc filter add dev "$DEV" parent ffff: protocol ip prio 1 u32 \
			match ip src "$ORIGIN_IP/32" match ip protocol 17 0xff match ip sport "$p" 0xffff \
			action mirred egress redirect dev "$IFB"
		tc filter add dev "$DEV" parent 1: protocol ip prio 1 u32 \
			match ip dst "$ORIGIN_IP/32" match ip protocol 17 0xff match ip dport "$p" 0xffff flowid 1:4
	done
	echo "impairment: loss $loss% each way on UDP $RELAY_PORT and $SRT_PORT with $ORIGIN_IP; GRO off"
}

# "Sent <bytes> bytes <pkts> pkt (dropped <n>, ...": what netem passed, and what it dropped.
counters() {
	local out=$1 i e
	i=$(tc -s qdisc show dev "$IFB" 2>/dev/null | awk '/Sent/{gsub(",", ""); print $4, $7; exit}')
	e=$(tc -s qdisc show dev "$DEV" 2>/dev/null | awk '/netem 40:/{n=1} n && /Sent/{gsub(",", ""); print $4, $7; exit}')
	{
		echo "at=$EPOCHREALTIME"
		echo "in_sent=${i%% *} in_dropped=${i##* }"
		echo "out_sent=${e%% *} out_dropped=${e##* }"
		echo "gro=$(ethtool -k "$DEV" | awk '/generic-receive-offload/{print $2}')"
	} >>"$out"
}

recv() {
	local cell=$1 lane=$2 secs=$3 bcast=$4
	mkdir -p "$cell"
	local rx moq
	moq=("$BIN/moq" --connect-tls-insecure --connect "https://$ORIGIN_IP:$RELAY_PORT/anon"
		--connect-websocket-enabled=false --quic-gso=false --broadcast "$bcast" export ts)
	case "$lane" in
	srt) rx=(tsp --realtime -I srt --caller "$ORIGIN_IP:$SRT_PORT" --latency "$BUFMS" -O file -) ;;
	opaque) rx=("${moq[@]}" --passthrough --delay "$DELAY") ;;
	aware) rx=("${moq[@]}" --delay "$DELAY") ;;
	*)
		echo "unknown lane: $lane" >&2
		exit 2
		;;
	esac
	echo "$EPOCHREALTIME recv-start $lane" >"$cell/recv-events.log"
	set +e
	{
		timeout "$((secs + 5))" "${rx[@]}" 2>"$cell/receive.log"
		echo "$EPOCHREALTIME recv-exit $?" >>"$cell/recv-events.log"
	} | python3 "$SCRIPTS/t18-latency.py" tap "$VPID" "$cell/egress.csv" --pipe --seconds "$secs" \
		--save "$cell/egress.ts" >/dev/null
	set -e
	echo "$EPOCHREALTIME tap-exit" >>"$cell/recv-events.log"
	echo "egress $(stat -c %s "$cell/egress.ts" 2>/dev/null || echo 0) bytes"
}

clock() {
	local cell=$1 when=$2
	mkdir -p "$cell"
	{
		echo "== $when $EPOCHREALTIME"
		python3 "$SCRIPTS/t18-latency.py" clock-client "$ORIGIN_IP" "$CLOCK_PORT" --samples 30 2>&1
		chronyc -n tracking
	} >>"$cell/clock-far.txt"
}

case "$ACTION" in
impair) impair "${2:?loss %}" ;;
counters) counters "${2:?file}" ;;
clear) clear_qdiscs ;;
recv) recv "${2:?cell}" "${3:?lane}" "${4:?seconds}" "${5:?broadcast}" ;;
clock) clock "${2:?cell}" "${3:?before|after}" ;;
*)
	echo "unknown action: $ACTION" >&2
	exit 2
	;;
esac

#!/usr/bin/env bash
# T71's receiver: the impairment on the lanes' flows, one lane's receive stage, and the clock reads.
#
#   sudo ORIGIN_IP=<addr> t71-far.sh impair <loss>       the qdiscs, each way: <loss> is a percentage
#                                                        (0 for a clean cell) or ge:<p>,<r>, a Gilbert
#                                                        model (bursts of mean 100/<r> datagrams);
#                                                        in:<spec> or out:<spec> for one direction
#   sudo ORIGIN_IP=<addr> t71-far.sh counters <file>     netem's counters, appended to <file>
#   sudo ORIGIN_IP=<addr> t71-far.sh clear
#   t71-far.sh recv <cell-dir> <srt|opaque|aware|seg> <seconds> <broadcast>
#   t71-far.sh clock <cell-dir> <before|after>
#
# **Only the lanes' flows are impaired.** netem acts on UDP to and from the origin's relay and SRT
# ports and TCP to and from its segmented origin, never on the clock probe or the session carrying
# this host's shell. Ingress datagrams are
# redirected into an ifb whose root is the netem; egress passes a prio qdisc whose fourth band holds
# the netem, with everything else in the second. Each direction loses at the commanded rate,
# independently. GRO is off, so each datagram on the wire meets the netem once (a coalesced one
# would be dropped whole), and the subscriber runs without GSO for the same reason.
#
# Env: ORIGIN_IP (required), BIN (~/bin-66af7231), RELAY_PORT (4711), SRT_PORT (9711),
# CLOCK_PORT (9710), BUFMS (1000), DELAY (1s), VPID (111), DEV (ens5), IFB (ifb71); the segmented
# lane: SEG_PORT (18731), PACER (~/pacer-97f3a38/mpegts-pacer), RATE (11438000), its cushion BUFMS
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
SEG_PORT=${SEG_PORT:-18731}
PACER=${PACER:-$HOME/pacer-97f3a38/mpegts-pacer}
RATE=${RATE:-11438000}

clear_qdiscs() {
	tc qdisc del dev "$DEV" root 2>/dev/null || true
	tc qdisc del dev "$DEV" ingress 2>/dev/null || true
	ip link del "$IFB" 2>/dev/null || true
}

impair() {
	local loss=$1 inward outward
	case "$loss" in
	in:*) inward=${loss#in:} outward=0 ;;
	out:*) inward=0 outward=${loss#out:} ;;
	*) inward=$loss outward=$loss ;;
	esac
	clear_qdiscs
	ethtool -K "$DEV" gro off
	modprobe ifb numifbs=0
	ip link add "$IFB" type ifb
	ip link set "$IFB" up
	# shellcheck disable=SC2046
	tc qdisc add dev "$IFB" root handle 1: netem $(model "$inward")
	tc qdisc add dev "$DEV" handle ffff: ingress
	tc qdisc add dev "$DEV" root handle 1: prio bands 4 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
	# shellcheck disable=SC2046
	tc qdisc add dev "$DEV" parent 1:4 handle 40: netem $(model "$outward")
	local proto port
	for proto in "17 $RELAY_PORT" "17 $SRT_PORT" "6 $SEG_PORT"; do
		port=${proto#* }
		proto=${proto% *}
		tc filter add dev "$DEV" parent ffff: protocol ip prio 1 u32 \
			match ip src "$ORIGIN_IP/32" match ip protocol "$proto" 0xff match ip sport "$port" 0xffff \
			action mirred egress redirect dev "$IFB"
		tc filter add dev "$DEV" parent 1: protocol ip prio 1 u32 \
			match ip dst "$ORIGIN_IP/32" match ip protocol "$proto" 0xff match ip dport "$port" 0xffff flowid 1:4
	done
	echo "impairment: inward $(model "$inward"), outward $(model "$outward"), on UDP $RELAY_PORT, $SRT_PORT and TCP $SEG_PORT with $ORIGIN_IP; GRO off"
}

# A loss spec as netem arguments: a percentage, or ge:<p>,<r>, Gilbert's two-state model.
model() {
	case "$1" in
	ge:*,*)
		local p=${1#ge:}
		echo "loss gemodel ${p%,*}% ${p#*,}% 100% 0%"
		;;
	*) echo "loss $1%" ;;
	esac
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
	local rx moq tap_s=$secs
	moq=("$BIN/moq" --connect-tls-insecure --connect "https://$ORIGIN_IP:$RELAY_PORT/anon"
		--connect-websocket-enabled=false --quic-gso=false --broadcast "$bcast" export ts)
	case "$lane" in
	srt) rx=(tsp --realtime -I srt --caller "$ORIGIN_IP:$SRT_PORT" --latency "$BUFMS" -O file -) ;;
	opaque) rx=("${moq[@]}" --passthrough --delay "$DELAY") ;;
	aware) rx=("${moq[@]}" --delay "$DELAY") ;;
	seg)
		# The playlist exists once the segmenter has closed its first epochs; the groomer's
		# output starts a cushion and a fetch later, so the tap runs that much longer.
		local url="http://$ORIGIN_IP:$SEG_PORT/hls/index.m3u8" i
		for i in $(seq 1 120); do
			[ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$url")" = 200 ] && break
			sleep 0.5
		done
		tap_s=$((secs + 8))
		# shellcheck disable=SC2016
		rx=(bash -c 'python3 "$1" "$2" - --seconds 0 --poll 250 --log "$3/recv.jsonl" 2>"$3/recv.err" |
			"$4" stdout "$5" --stream-clock --latency-ms "$6" --max-latency-ms 14000 --stall-ms 1000 \
				--on-stall mute --stats-interval-ms 1000 2>"$3/pacer.log"' _
			"$SCRIPTS/b8-hls-recv.py" "$url" "$cell" "$PACER" "$RATE" "$BUFMS")
		;;
	*)
		echo "unknown lane: $lane" >&2
		exit 2
		;;
	esac
	echo "$EPOCHREALTIME recv-start $lane" >"$cell/recv-events.log"
	set +e
	{
		timeout "$((tap_s + 5))" "${rx[@]}" 2>"$cell/receive.log"
		echo "$EPOCHREALTIME recv-exit $?" >>"$cell/recv-events.log"
	} | python3 "$SCRIPTS/t18-latency.py" tap "$VPID" "$cell/egress.csv" --pipe --seconds "$tap_s" \
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

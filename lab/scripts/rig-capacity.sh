#!/usr/bin/env bash
# The `netns`/`cake` rig's own capacity, measured with no media stack: TCP bulk transfers with the
# sender's `ss -tin` sampled, and paced UDP at QUIC-sized datagrams across the configured rate.
# Every T31 rung is a multiple of the stream's rate set on `cake`, so a rig that passes less than it
# is configured for moves every boundary by the difference.
#
# It runs a renamed copy of `t8b-netns.sh` (namespaces `t8x-*`, 10.98.0.0/24), so it is independent
# of the rig a ladder may be using at the time.
#
#   netem  the rig as every ladder runs it: `cake` as the child of the data path's `netem` delay
#   split  `cake` as the data path's root and the whole 100 ms RTT on the acknowledgement path
#   zero   `cake` still the child of a data-path `netem`, which the ladders need to impair the
#          path, but at 0 ms, with the whole RTT on the acknowledgement path
#
# Usage: sudo rig-capacity.sh <outdir> [topology...]     (RATE_MBIT, default 20)
set -uo pipefail
OUT=${1:?usage: rig-capacity.sh <outdir> [netem] [split]}
shift
TOPOS=${*:-netem split}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RATE=${RATE_MBIT:-20}
RIG=$(mktemp /tmp/t8x-netns.XXXXXX)
mkdir -p "$OUT"
sed -e 's/t8b-pub/t8x-pub/g; s/t8b-sub/t8x-sub/g; s/veth-pub/vx-pub/g; s/veth-sub/vx-sub/g' \
	-e 's/10\.99\.0\./10.98.0./g' "$HERE/t8b-netns.sh" >"$RIG"
PY=(python3 "$HERE/rig-capacity.py")
DST=10.98.0.2
pub() { ip netns exec t8x-pub "$@"; }
sub() { ip netns exec t8x-sub "$@"; }
rig() { RATE_MBIT=$RATE DELAY_MS=50 bash "$RIG" "$@"; }

tcp() { # <label> <bytes> [congestion-control]
	local label=$1 rp sp
	sub "${PY[@]}" tcp-recv 5201 >"$OUT/$label.json" &
	rp=$!
	sleep 0.5
	(while kill -0 "$rp" 2>/dev/null; do
		pub ss -tinH dst "$DST"
		sleep 0.25
	done) >"$OUT/$label.ss" 2>&1 &
	sp=$!
	pub "${PY[@]}" tcp-send "$DST" 5201 "$2" ${3:+"$3"}
	wait "$rp"
	kill "$sp" 2>/dev/null
	wait "$sp" 2>/dev/null
	echo "  $label $(cat "$OUT/$label.json") $(grep -o 'retrans:[0-9/]*' "$OUT/$label.ss" | tail -1)"
}

udp() { # <label> <mbit> <seconds> <datagram-bytes>
	local label=$1 rp
	sub "${PY[@]}" udp-recv 5202 "$3" >"$OUT/$label.json" &
	rp=$!
	sleep 0.5
	pub "${PY[@]}" udp-send "$DST" 5202 "$2" "$3" "$4"
	wait "$rp"
	echo "  $label $(cat "$OUT/$label.json")"
}

HAS_BBR=$(sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr && echo 1)
for topo in $TOPOS; do
	rig down >/dev/null 2>&1
	rig up >/dev/null
	case "$topo" in
	netem) rig cake >/dev/null ;;
	split)
		pub tc qdisc replace dev vx-pub root cake bandwidth "${RATE}mbit"
		sub tc qdisc replace dev vx-sub root netem delay 100ms limit 100000
		;;
	zero)
		pub tc qdisc replace dev vx-pub root handle 1: netem delay 0ms limit 100000
		pub tc qdisc add dev vx-pub parent 1:1 handle 10: cake bandwidth "${RATE}mbit"
		sub tc qdisc replace dev vx-sub root netem delay 100ms limit 100000
		;;
	*)
		echo "unknown topology $topo" >&2
		continue
		;;
	esac
	echo "== $topo, $RATE Mb/s: $(pub ping -c 3 -q "$DST" | tail -1)"
	for i in 1 2 3; do tcp "$topo-tcp3m-$i" 3000000; done
	tcp "$topo-tcp30m" 30000000
	[[ -n "$HAS_BBR" ]] && tcp "$topo-tcp30m-bbr" 30000000 bbr
	for m in 10 15 18 19 20 21; do udp "$topo-udp-${m}m" "$m" 10 1200; done
	pub tc -s qdisc show dev vx-pub >"$OUT/$topo-qdisc.txt"
done
rig down >/dev/null 2>&1
rm -f "$RIG"

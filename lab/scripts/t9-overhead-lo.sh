#!/usr/bin/env bash
# T9 carriage overhead, loopback leg — corrected accounting.
#
# Same topology as the original loopback rig (relay, publisher and subscriber all on
# one host, private port) but every quantity is reduced to a rate over a duration the
# measuring side establishes for itself. The original compared a byte total captured
# over WINDOW+3 s against a payload total sampled over WINDOW s, which inflated the
# wire side by the ratio of the two windows.
#
# Run the relay with GSO off, or the capture reports kernel-coalesced segments rather
# than datagrams and the size distribution is meaningless.
#
# usage: t9-overhead-lo.sh [window-seconds] [source.ts]
set -uo pipefail
BIN=${BIN:-/home/ubuntu/bin-0.14.9}
PORT=${PORT:-8043}
SRC=${SRC:-${2:-/home/ubuntu/CNNiEMEA2.ts}}
WINDOW=${WINDOW:-${1:-40}}
BCAST=t9lo.$$.hang
RELAY=""; PUB=""; SUB=""

cleanup() {
	for p in $SUB $PUB $RELAY; do
		[ -n "$p" ] && { pkill -9 -P "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; }
	done
	pkill -9 -f "$BCAST" 2>/dev/null
	sudo pkill -9 -f 'tcpdump.*t9_lo' 2>/dev/null
	sleep 1
}
trap cleanup EXIT INT TERM

io() { awk -F': *' -v k="^$2" '$1 ~ k {print $2}' "/proc/$1/io" 2>/dev/null || echo 0; }

$BIN/moq-relay --server-bind "0.0.0.0:$PORT" --tls-generate 127.0.0.1 --auth-public "" \
	--server-quic-gso=false >/tmp/t9lo_relay.log 2>&1 &
RELAY=$!
sleep 3

setsid bash -c "tsp -I file '$SRC' --infinite -P regulate --pcr-synchronous -O file - \
  | $BIN/moq --client-tls-disable-verify --client-connect https://127.0.0.1:$PORT/anon \
      --client-quic-gso=false --broadcast $BCAST import ts" >/tmp/t9lo_pub.log 2>&1 &
PUB=$!
sleep 8

$BIN/moq --client-tls-disable-verify --client-connect "https://127.0.0.1:$PORT/anon" \
	--client-quic-gso=false --broadcast "$BCAST" export ts >/dev/null 2>/tmp/t9lo_sub.log &
SUB=$!
sleep 12

# The importer's read side is the source rate actually being fed, which is a better
# denominator than a remembered clip bitrate.
IMP=$(pgrep -f "moq .*--broadcast $BCAST import ts" | head -1)
SPORT=$(sudo ss -uanp 2>/dev/null | awk -v k="pid=$SUB," '$0 ~ k {split($4,a,":"); print a[length(a)]; exit}')
[ -z "$SPORT" ] && { echo "could not resolve subscriber udp port"; exit 1; }
echo "subscriber pid=$SUB port=$SPORT importer pid=${IMP:-none}"

sudo timeout $((WINDOW + 2)) tcpdump -i lo -nn -s 128 -w /tmp/t9_lo.pcap \
	"udp and port $SPORT" >/dev/null 2>&1 &
CAPPID=$!
sleep 2
w0=$(io "$SUB" wchar); r0=$(io "${IMP:-1}" rchar); t0=$(date +%s.%N)
sleep $((WINDOW - 4))
w1=$(io "$SUB" wchar); r1=$(io "${IMP:-1}" rchar); t1=$(date +%s.%N)
wait $CAPPID 2>/dev/null
sync

sudo tcpdump -r /tmp/t9_lo.pcap -nn -q -tt 2>/dev/null |
	awk -v sport="$SPORT" -v tsb=$((w1 - w0)) -v srcb=$((r1 - r0)) -v pt0="$t0" -v pt1="$t1" '
	/UDP, length/ {
		n = split($0, a, " "); len = a[n] + 0
		t = $1 + 0; if (!c0 || t < c0) c0 = t; if (t > c1) c1 = t
		split($5, d, "."); dp = d[5]; sub(":", "", dp)
		if (dp == sport) { dn++; db += len; dh[len]++; if (len > dmax) dmax = len }
		else             { un++; ub += len }
	}
	END {
		cspan = c1 - c0; pspan = pt1 - pt0
		printf "CAP_SPAN_S %.3f\nPAYLOAD_SPAN_S %.3f\n", cspan, pspan
		printf "DOWN_DATAGRAMS %d\nDOWN_QUIC_BYTES %d\nDOWN_DGRAM_MEAN %.1f\nDOWN_DGRAM_MAX %d\n",
			dn, db, (dn ? db / dn : 0), dmax
		printf "DOWN_QUIC_MBPS %.4f\nDOWN_WIRE_MBPS %.4f\n",
			db * 8 / cspan / 1e6, (db + 28 * dn) * 8 / cspan / 1e6
		printf "TS_DELIVERED_MBPS %.4f\nSOURCE_FED_MBPS %.4f\n",
			tsb * 8 / pspan / 1e6, srcb * 8 / pspan / 1e6
		# The original rig`s error, quantified: the same byte totals divided by the
		# window each side was nominally given rather than the one it actually covered.
		printf "MISMATCH_IF_SPANS_ASSUMED_EQUAL %.4f\n", cspan / pspan
		for (l in dh) printf "H %d %d %.2f\n", l, dh[l], dh[l] / dn * 100
	}' | tee /tmp/t9_lo.summary | grep -v '^H '
echo "DOWN_SIZE_HISTOGRAM (size, count, share)"
grep '^H ' /tmp/t9_lo.summary | sort -k2,2n | awk '{printf "  %6d B : %8d  (%5.2f%%)\n", $2, $3, $4}' | tail -20

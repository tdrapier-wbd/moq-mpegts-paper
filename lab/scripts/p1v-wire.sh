#!/usr/bin/env bash
# P1-v — wire bytes per source byte on the live feed: T14 measurement 5 on the live profile, with
# T9's instrument (IP headers captured on the sender's interface, each side over its own span).
#
#   p1v-wire.sh cap <out.pcap> <seconds> <peer-ip> <port>        # sender: both directions of one port
#   p1v-wire.sh srt-src <seconds> [port]                          # sender: the multicast group, SRT listener
#   p1v-wire.sh moq-sub <bin-dir> <out-dir> <seconds> <origin> <broadcast>   # subscriber: export ts
#   p1v-wire.sh srt-sub <out-dir> <seconds> <origin> [port]       # subscriber: SRT caller
#   p1v-wire.sh sum <pcap> <port> [source-bps]                    # IP bytes per peer port, each way
#
# The standing relay runs with GSO off; a GSO sender is still seen per datagram here, because ENA
# segments in software before the capture tap. `sum` prints the largest IP length as the check.
#
# env: GROUP (239.255.0.1:5000), IFACE (ens5), SRT_LATENCY (2000), MAX_AGE (2s)
set -uo pipefail

ROLE=${1:?cap, srt-src, moq-sub, srt-sub or sum}
shift
GROUP=${GROUP:-239.255.0.1:5000}
IFACE=${IFACE:-ens5}
SRT_LATENCY=${SRT_LATENCY:-2000}
MAX_AGE=${MAX_AGE:-2s}

# Bytes read from stdin and the span between the first and the last read.
count() {
	python3 -c '
import sys, time
total, t0, t1 = 0, None, None
while True:
	b = sys.stdin.buffer.read1(1 << 16)
	if not b:
		break
	t1 = time.monotonic()
	t0 = t0 or t1
	total += len(b)
span = (t1 - t0) if t0 else 0
print(f"delivered_bytes={total} span_s={span:.3f} rate_bps={8 * total / span if span else 0:.0f}")
'
}

case $ROLE in
cap)
	OUT=${1:?out.pcap} SECS=${2:?seconds} PEER=${3:?peer ip} PORT=${4:?port}
	sudo timeout "$SECS" tcpdump -i "$IFACE" -nn -s 64 -w "$OUT" "udp and host $PEER and port $PORT"
	;;
srt-src)
	SECS=${1:?seconds} PORT=${2:-4443}
	timeout "$SECS" tsp -I ip "$GROUP" --local-address 127.0.0.1 --buffer-size 16777216 \
		-O srt --listener ":$PORT" --transtype live --latency "$SRT_LATENCY"
	;;
moq-sub)
	BIN=${1:?bin dir} OUT=${2:?out dir} SECS=${3:?seconds} ORIGIN=${4:?origin} BCAST=${5:?broadcast}
	mkdir -p "$OUT"
	timeout -s INT "$SECS" "$BIN/moq" --connect-tls-insecure --connect "https://$ORIGIN:443/anon" \
		--broadcast "$BCAST" export ts --max-age "$MAX_AGE" 2>"$OUT/sub.log" | count >"$OUT/delivered.txt"
	cat "$OUT/delivered.txt"
	;;
srt-sub)
	OUT=${1:?out dir} SECS=${2:?seconds} ORIGIN=${3:?origin} PORT=${4:-4443}
	mkdir -p "$OUT"
	timeout "$SECS" tsp -I srt --caller "$ORIGIN:$PORT" --transtype live --latency "$SRT_LATENCY" \
		-O file 2>"$OUT/sub.log" | count >"$OUT/delivered.txt"
	cat "$OUT/delivered.txt"
	;;
sum)
	PCAP=${1:?pcap} PORT=${2:?port} SRC_BPS=${3:-25000000}
	tcpdump -r "$PCAP" -nn -tt -v 2>/dev/null | gawk -v port="$PORT" -v src="$SRC_BPS" '
		/ IP \(/ { t = $1; match($0, /length [0-9]+\)/); len = substr($0, RSTART + 7, RLENGTH - 8) + 0; next }
		/ > / {
			split($1, a, "."); sp = a[5]; split($3, b, "."); dp = b[5]; sub(/:$/, "", dp)
			if (sp == port) { k = "fwd " dp } else if (dp == port) { k = "ret " sp } else next
			bytes[k] += len; pk[k]++; if (!(k in t0)) t0[k] = t; t1[k] = t; if (len > mx[k]) mx[k] = len
			s = int(t); sec[k, s] += len; if (!(k in s0)) s0[k] = s; s1[k] = s
		}
		END {
			# The steady rate: whole seconds from the first to the last at half the median or more, less
			# the edge seconds, so a join ramp or the packets after a client goes do not set the span.
			for (k in bytes) {
				n = 0
				for (s = s0[k]; s <= s1[k]; s++) v[++n] = sec[k, s] + 0
				asort(v, w); med = w[int((n + 1) / 2)]; lo = 0; hi = 0
				for (s = s0[k]; s <= s1[k]; s++) if (sec[k, s] >= med / 2) { if (!lo) lo = s; hi = s }
				sb = 0; for (s = lo + 1; s <= hi - 1; s++) sb += sec[k, s]
				ns = hi - lo - 1; r = ns > 0 ? 8 * sb / ns : 0
				printf "%s packets=%d ip_bytes=%d span_s=%.3f steady_s=%d steady_bps=%.0f max_ip_len=%d vs_source=%.4f\n",
					k, pk[k], bytes[k], t1[k] - t0[k], ns, r, mx[k], r / src
				delete v; delete w
			}
		}' | sort
	;;
*)
	echo "unknown role $ROLE" >&2
	exit 2
	;;
esac

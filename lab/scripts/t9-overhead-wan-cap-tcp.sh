#!/usr/bin/env bash
# T9 carriage overhead, WAN leg — capture side for a TCP lane (runs on the origin host).
#
# The companion UDP script reads "UDP, length N" and adds a fixed 28 B of IP+UDP
# header per datagram, which is exact because neither header ever varies. TCP's does:
# the timestamp option adds 12 bytes to most segments and not to all of them, so
# reconstructing the wire size from the payload size would build the answer out of an
# assumption about the very thing being priced.
#
# So take the wire size from the wire. `tcpdump -e` prints the Ethernet frame length
# from the pcap record's *original* length field, which is recorded before the snaplen
# truncates the payload — subtract the 14 B Ethernet header and what remains is the IP
# datagram the path actually carried, options and all.
#
# usage: t9-overhead-wan-cap-tcp.sh <subscriber-ip> <origin-port> <window-s> <label> [iface]
set -uo pipefail
SUB_IP=${1:?subscriber ip}
PORT=${2:?origin port}
WINDOW=${3:-40}
LABEL=${4:-seg}
IFACE=${5:-ens5}
CAP=/tmp/t9_oh_${LABEL}.pcap
SUMMARY=/tmp/t9_oh_${LABEL}.summary

# The bracket keeps the pattern from matching this pkill's own command line, which
# otherwise kills itself before it reaches tcpdump.
if [ -z "${SKIP_CAPTURE:-}" ]; then
	sudo pkill -9 -f '[t]cpdump.*t9_oh_' 2>/dev/null
	sudo timeout $((WINDOW + 2)) tcpdump -i "$IFACE" -nn -s 96 -e -w "$CAP" \
		"tcp and host $SUB_IP and port $PORT" >/dev/null 2>&1
	sync
fi

# Rates over the pcap's own first-to-last span, for the same reason as the UDP script:
# tcpdump's start-up and teardown make the nominal window the wrong denominator.
sudo tcpdump -r "$CAP" -nn -q -tt -e 2>/dev/null |
	awk -v port="$PORT" -v label="$LABEL" -v win="$WINDOW" '
	/, IPv4, length / {
		# "<ts> <srcmac> > <dstmac>, IPv4, length 1514: 10.0.0.1.8080 > 10.0.0.2.51000: tcp 1448"
		fl = 0
		for (i = 1; i < NF; i++)
			if ($i == "length") { fl = $(i + 1) + 0; break }
		if (!fl) next
		ip = fl - 14                       # Ethernet header off; IP datagram remains
		t = $1 + 0; if (!t0 || t < t0) t0 = t; if (t > t1) t1 = t

		# Payload length, so pure-ACK segments can be told from carrying ones.
		pl = ($(NF - 1) == "tcp") ? $NF + 0 : 0

		# Direction on the source port: the origin serving is "down". Take the *last*
		# ">" — the first one separates the two MAC addresses, not the two endpoints.
		src = ""
		for (i = 1; i <= NF; i++) if ($i == ">") src = $(i - 1)
		n = split(src, s, "."); sp = s[n] + 0

		if (sp == port) {
			dn++; db += ip; dp += pl; dh[ip]++; if (ip > dmax) dmax = ip
			if (pl == 0) dack++
		} else {
			un++; ub += ip; up += pl
			if (pl == 0) uack++
		}
	}
	END {
		span = t1 - t0
		printf "LEG %s\nWINDOW_NOMINAL_S %s\nCAP_SPAN_S %.3f\n", label, win, span
		printf "DOWN_SEGMENTS %d\nDOWN_PAYLOAD_BYTES %d\nDOWN_WIRE_BYTES %d\n", dn, dp, db
		printf "DOWN_SEG_MEAN %.1f\nDOWN_SEG_MAX %d\nDOWN_PURE_ACKS %d\n",
			(dn ? db / dn : 0), dmax, dack
		printf "UP_SEGMENTS %d\nUP_PAYLOAD_BYTES %d\nUP_WIRE_BYTES %d\nUP_PURE_ACKS %d\n",
			un, up, ub, uack
		if (span > 0) {
			printf "DOWN_PAYLOAD_MBPS %.4f\nDOWN_WIRE_MBPS %.4f\nUP_WIRE_MBPS %.4f\n",
				dp * 8 / span / 1e6, db * 8 / span / 1e6, ub * 8 / span / 1e6
		}
		# The span-free figure, and on this lane the one to quote. A segment fetcher is
		# idle between bursts, so first-to-last-packet understates how long the flow ran
		# and inflates every rate divided by it — here by about 4 %. Bytes on the wire per
		# byte carried has no denominator to get wrong, and multiplying it by the source
		# rate gives the IP capacity the service needs.
		if (dp > 0) printf "DOWN_WIRE_PER_PAYLOAD %.5f\n", db / dp
		if (db > 0) printf "UP_SHARE_OF_DOWN %.5f\n", ub / db
		for (l in dh) printf "H %d %d %.2f\n", l, dh[l], dh[l] / dn * 100
	}' >"$SUMMARY"

grep -v '^H ' "$SUMMARY"
echo "DOWN_SIZE_HISTOGRAM (IP bytes, count, share)"
grep '^H ' "$SUMMARY" | sort -k2,2n | awk '{printf "  %6d B : %8d  (%5.2f%%)\n", $2, $3, $4}'
echo "CAP $CAP"

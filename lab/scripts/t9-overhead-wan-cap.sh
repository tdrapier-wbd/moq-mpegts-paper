#!/usr/bin/env bash
# T9 carriage overhead, WAN leg — capture side (runs on the origin/relay host).
#
# Captures the relay's egress QUIC flow to a *remote* subscriber on the physical
# interface and reports the UDP datagram-size distribution plus byte totals.
#
# Why this exists separately from the loopback rig (`~/t9/overhead_ec2.sh`): on
# loopback the kernel coalesces datagrams via GSO, so a capture shows multi-kB
# segments and the datagram-size distribution — the one output that prices
# per-packet overhead honestly — is unreadable. Run the relay with
# `--server-quic-gso=false` so one sendmsg is one datagram, and capture on a real
# egress path so the MTU is the path's rather than the loopback device's.
#
# Snaplen 128 keeps the pcap small; "UDP, length N" is read from the IP/UDP
# header, so truncating the payload does not affect any figure reported here.
#
# usage: t9-overhead-wan-cap.sh <subscriber-ip> <relay-port> <window-s> <label> [iface]
set -uo pipefail
SUB_IP=${1:?subscriber ip}; PORT=${2:?relay port}
WINDOW=${3:-40}; LABEL=${4:-wan}; IFACE=${5:-ens5}
CAP=/tmp/t9_oh_${LABEL}.pcap
SUMMARY=/tmp/t9_oh_${LABEL}.summary

sudo pkill -9 -f 'tcpdump.*t9_oh_' 2>/dev/null
sudo timeout $((WINDOW + 2)) tcpdump -i "$IFACE" -nn -s 128 -w "$CAP" \
	"udp and host $SUB_IP and port $PORT" >/dev/null 2>&1
sync

# `-q -tt` fixes the line shape as "<epoch> IP src.sport > dst.dport: UDP, length N".
# Direction is decided on the source port, so the relay's own egress is "down".
# Rates are computed over the pcap's own first-to-last span, not over the nominal
# window: tcpdump start-up and teardown make the two differ by around a second, and
# a rate divided by the wrong duration is what makes a wire measurement unreadable.
sudo tcpdump -r "$CAP" -nn -q -tt 2>/dev/null |
	awk -v port="$PORT" -v label="$LABEL" -v win="$WINDOW" '
	/UDP, length/ {
		n = split($0, a, " "); len = a[n] + 0
		t = $1 + 0; if (!t0 || t < t0) t0 = t; if (t > t1) t1 = t
		split($3, s, "."); sp = s[5]
		if (sp == port) { dn++; db += len; dh[len]++; if (len > dmax) dmax = len }
		else            { un++; ub += len }
	}
	END {
		span = t1 - t0
		printf "LEG %s\nWINDOW_NOMINAL_S %s\nCAP_SPAN_S %.3f\n", label, win, span
		printf "DOWN_DATAGRAMS %d\nDOWN_QUIC_BYTES %d\nDOWN_DGRAM_MEAN %.1f\nDOWN_DGRAM_MAX %d\n",
			dn, db, (dn ? db / dn : 0), dmax
		printf "UP_DATAGRAMS %d\nUP_QUIC_BYTES %d\n", un, ub
		# IP+UDP headers counted per real datagram rather than assumed from volume.
		printf "DOWN_WIRE_BYTES %d\nUP_WIRE_BYTES %d\n", db + 28 * dn, ub + 28 * un
		if (span > 0) {
			printf "DOWN_QUIC_MBPS %.4f\nDOWN_WIRE_MBPS %.4f\nUP_WIRE_MBPS %.4f\n",
				db * 8 / span / 1e6, (db + 28 * dn) * 8 / span / 1e6,
				(ub + 28 * un) * 8 / span / 1e6
		}
		for (l in dh) printf "H %d %d %.2f\n", l, dh[l], dh[l] / dn * 100
	}' >"$SUMMARY"

grep -v '^H ' "$SUMMARY"
echo "DOWN_SIZE_HISTOGRAM (size, count, share)"
grep '^H ' "$SUMMARY" | sort -k2,2n | awk '{printf "  %6d B : %8d  (%5.2f%%)\n", $2, $3, $4}'
echo "CAP $CAP"

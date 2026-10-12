#!/usr/bin/env bash
# Bytes and packets one UDP source port sends to one destination, sampled to CSV.
#
#   udp-port-acct.sh <sport> <dest-ip> <out.csv> [interval-s]
#
# A relay host's NIC counters cannot isolate one flow when other traffic shares the interface. On the
# subscriber host of a two-tier fan-out the origin sends one copy (~10 Mb/s) to the edge, while the
# host's subscribers send acknowledgements to the same edge at a comparable rate, so tx_bytes
# measures the acks. An iptables rule with no target counts and passes; it is removed on exit.
# A GSO sender is counted per send batch: packets are batches, and bytes miss each datagram's own
# IP and UDP headers after segmentation.
set -euo pipefail

SPORT=${1:?source port}
DEST=${2:?destination ip}
OUT=${3:?output csv}
EVERY=${4:-5}

TAG="udp-port-acct-$SPORT-$DEST"
RULE=(OUTPUT -p udp --sport "$SPORT" -d "$DEST" -m comment --comment "$TAG")
sudo iptables -I "${RULE[@]}"
trap 'sudo iptables -D "${RULE[@]}" 2>/dev/null || true' EXIT
trap 'exit 0' INT TERM

echo "epoch,packets,bytes" >"$OUT"
while :; do
	sudo iptables -L OUTPUT -vnx | awk -v c="/* $TAG */" -v t="$(date +%s)" \
		'index($0, c) {print t "," $1 "," $2; exit}' >>"$OUT"
	sleep "$EVERY"
done

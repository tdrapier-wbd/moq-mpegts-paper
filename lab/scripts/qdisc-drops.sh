#!/usr/bin/env bash
# Every qdisc's drop counter on one device, once a second, for t28-qlog-shape.py's --tc:
# `<unix ns> <kind>:<dropped> ...`, one field per qdisc (netem's random loss counts as its drops).
# A sample taken before the namespace exists has the timestamp alone.
#
#   sudo qdisc-drops.sh <netns> <dev> <seconds> >tc.log     # e.g. t8b-pub veth-pub 300
set -uo pipefail

NS=${1:?netns}
DEV=${2:?device}
SECS=${3:?seconds}
end=$(($(date +%s) + SECS))
while [ "$(date +%s)" -lt "$end" ]; do
	printf '%s ' "$(date +%s%N)"
	ip netns exec "$NS" tc -s qdisc show dev "$DEV" 2>/dev/null |
		awk '/^qdisc/ { k = $2 } /Sent/ { for (i = 1; i <= NF; i++) if ($i == "(dropped") { d = $(i + 1); sub(",", "", d); printf "%s:%s ", k, d } }'
	echo
	sleep 1
done

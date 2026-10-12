#!/usr/bin/env bash
# Sample the t8b-netns rig's qdisc counters once a second until killed (T28, P1-q).
#
# usage: sudo bash t28-qdisc-sample.sh <out.log> [interval_s]
#
# Each sample is a line "@ <unix time>" followed by `tc -s qdisc show` for the publisher-side
# interface (data direction: netem delay, then the shaper and its leaf) and the subscriber side
# (acks). Drops during a cell are the difference between the samples bracketing it.
set -u
OUT=${1:?usage: t28-qdisc-sample.sh <out.log> [interval_s]}
STEP=${2:-1}
NS_PUB=${NS_PUB:-t8b-pub}
NS_SUB=${NS_SUB:-t8b-sub}
VETH_PUB=${VETH_PUB:-veth-pub}
VETH_SUB=${VETH_SUB:-veth-sub}
while :; do
	{
		echo "@ $(date +%s.%N)"
		echo "# pub $VETH_PUB"
		ip netns exec "$NS_PUB" tc -s qdisc show dev "$VETH_PUB" 2>&1
		echo "# sub $VETH_SUB"
		ip netns exec "$NS_SUB" tc -s qdisc show dev "$VETH_SUB" 2>&1
	} >>"$OUT"
	sleep "$STEP"
done

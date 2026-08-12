#!/usr/bin/env bash
# Impairment lane for the T9 WAN overhead legs, driven from the subscriber host.
#
# Shapes only the two measured flows (QUIC sport 443, SRT sport 9010) towards this
# host, so the SSH control channel stays clean. The destination is resolved from the
# origin's view of this connection at the moment the lane is built: a lane pinned to a
# remembered address silently shapes nothing, and the run then reads as "impairment
# made no difference" rather than as a rig failure.
#
# `verify` reports the shaper's own sent/dropped counters. Always run it: it is the
# only evidence that the impairment reached the flow under measurement.
#
# usage: t9-netem-lane.sh set "<netem spec>" | verify | clear
set -uo pipefail
ORIGIN=${ORIGIN:?set ORIGIN to user@host of the origin box}
PEM=${PEM:?set PEM to the ssh key}
IFACE=${IFACE:-ens5}
SSH=(ssh -i "$PEM" -o ConnectTimeout=15 "$ORIGIN")

case ${1:?set|verify|clear} in
set)
	SPEC=${2:?netem spec, e.g. "loss 1%"}
	DST=$("${SSH[@]}" 'echo $SSH_CLIENT' | awk '{print $1}')
	[ -z "$DST" ] && { echo "could not resolve this host as seen by the origin"; exit 1; }
	echo "shaping towards $DST: $SPEC"
	"${SSH[@]}" 'bash -s' <<-EOF
		set -e
		sudo tc qdisc del dev $IFACE root 2>/dev/null || true
		sudo tc qdisc add dev $IFACE root handle 1: prio bands 4 \
			priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
		sudo tc qdisc add dev $IFACE parent 1:4 handle 40: netem $SPEC
		for sp in 443 9010; do
			sudo tc filter add dev $IFACE parent 1:0 protocol ip prio 1 u32 \
				match ip protocol 17 0xff match ip sport \$sp 0xffff \
				match ip dst $DST/32 flowid 1:4
		done
		sudo bash -c "nohup sh -c 'sleep 3600; tc qdisc del dev $IFACE root' >/dev/null 2>&1 &"
		tc qdisc show dev $IFACE | sed -n '1,3p'
	EOF
	;;
verify)
	"${SSH[@]}" "tc -s qdisc show dev $IFACE | grep -A3 'handle 40|netem' || tc -s qdisc show dev $IFACE"
	;;
clear)
	"${SSH[@]}" "sudo tc qdisc del dev $IFACE root 2>/dev/null; tc qdisc show dev $IFACE | head -1"
	;;
esac

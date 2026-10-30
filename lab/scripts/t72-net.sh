#!/usr/bin/env bash
# T72's receiver paths, as root on the receiver host (lab/test-72-segmented-cdn-edge-impairment.md).
#
#   ns t72i (10.72.1.2) == v72in | v72i == host (10.72.1.1)   impaired: host -> ns netem PATH_DELAY_MS
#                                                              (the shape) -> cake RATE_MBIT;
#                                                              ns -> host netem ACK_DELAY_MS
#   ns t72c (10.72.2.2) == v72cn | v72c == host (10.72.2.1)   control: unimpaired
#
# Both namespaces leave by NAT on IF, with DOMAIN pinned to EDGE in their hosts files. The host's
# receive offload on IF is turned off while the paths are up, so a forwarded segment reaches the
# netem as one packet, and restored by `down`.
#
#   t72-net.sh up DOMAIN EDGE | down | show
# Env: IF (ens5), RATE_MBIT (20), PATH_DELAY_MS (50), ACK_DELAY_MS (50)

set -uo pipefail
IF=${IF:-ens5}
RATE_MBIT=${RATE_MBIT:-20}
PATH_DELAY_MS=${PATH_DELAY_MS:-50}
ACK_DELAY_MS=${ACK_DELAY_MS:-50}

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 2; }

idx() { case $1 in i) echo 1 ;; c) echo 2 ;; esac; }

up() {
	local domain=$1 edge=$2 l i ns
	down >/dev/null 2>&1
	set -e
	cat /proc/sys/net/ipv4/ip_forward >/run/t72-ip_forward.orig
	ethtool -k "$IF" | awk '/^generic-receive-offload:/ {print $2}' >/run/t72-gro.orig
	ethtool -K "$IF" gro off
	sysctl -qw net.ipv4.ip_forward=1
	iptables -t nat -C POSTROUTING -s 10.72.0.0/16 -o "$IF" -j MASQUERADE 2>/dev/null ||
		iptables -t nat -A POSTROUTING -s 10.72.0.0/16 -o "$IF" -j MASQUERADE
	for l in i c; do
		i=$(idx $l)
		ns=t72$l
		ip netns add $ns
		ip link add v72$l type veth peer name v72${l}n
		ip link set v72${l}n netns $ns
		ip addr add 10.72.$i.1/30 dev v72$l
		ip link set v72$l up
		ip -n $ns addr add 10.72.$i.2/30 dev v72${l}n
		ip -n $ns link set v72${l}n up
		ip -n $ns link set lo up
		ip -n $ns route add default via 10.72.$i.1
		ethtool -K v72$l tso off gso off gro off >/dev/null
		ip netns exec $ns ethtool -K v72${l}n tso off gso off gro off >/dev/null
		mkdir -p /etc/netns/$ns
		grep -h '^nameserver' /run/systemd/resolve/resolv.conf >/etc/netns/$ns/resolv.conf
		{ cat /etc/hosts; echo "$edge $domain"; } >/etc/netns/$ns/hosts
	done
	tc qdisc add dev v72i root handle 1: netem delay "${PATH_DELAY_MS}ms" limit 100000
	tc qdisc add dev v72i parent 1:1 handle 10: cake bandwidth "${RATE_MBIT}mbit"
	ip netns exec t72i tc qdisc add dev v72in root netem delay "${ACK_DELAY_MS}ms" limit 100000
	set +e
	echo "paths up: impaired ${PATH_DELAY_MS}+${ACK_DELAY_MS} ms, ${RATE_MBIT} Mb/s; control unimpaired; $domain -> $edge; $IF gro off"
}

down() {
	local l
	for l in i c; do
		ip netns del t72$l 2>/dev/null
		ip link del v72$l 2>/dev/null
		rm -rf /etc/netns/t72$l
	done
	iptables -t nat -D POSTROUTING -s 10.72.0.0/16 -o "$IF" -j MASQUERADE 2>/dev/null
	[ -f /run/t72-ip_forward.orig ] && sysctl -qw net.ipv4.ip_forward="$(cat /run/t72-ip_forward.orig)"
	[ -s /run/t72-gro.orig ] && ethtool -K "$IF" gro "$(cat /run/t72-gro.orig)"
	rm -f /run/t72-ip_forward.orig /run/t72-gro.orig
	echo "paths down: ip_forward=$(cat /proc/sys/net/ipv4/ip_forward), $IF $(ethtool -k "$IF" | grep '^generic-receive-offload:')"
}

case "${1:-}" in
up) up "${2:?domain}" "${3:?edge address}" ;;
down) down ;;
show)
	tc -s qdisc show dev v72i
	ip netns exec t72i tc -s qdisc show dev v72in
	;;
*)
	echo "usage: t72-net.sh up DOMAIN EDGE | down | show" >&2
	exit 2
	;;
esac

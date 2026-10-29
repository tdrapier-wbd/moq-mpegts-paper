#!/usr/bin/env bash
# T59 receiver side, run as root on the receiver host (lab/test-59-segmented-1plus1-cloudfront.md).
#
# Two legs, a and b. Each leg's fetcher (b8-hls-recv.py) runs in its own network namespace,
# NATed out of the host, so netem on that namespace's veth impairs one leg's path alone; its
# groomer (mpegts-pacer --stream-clock) runs on the host and sends RTP to 127.0.0.1:5100 (a) or
# :5200 (b), where one recorder writes both legs into one raw-IPv4 pcap on one clock
# (t55-grade.py's input).
#
#   t59-legs.sh net-up | net-down
#   t59-legs.sh rec-start DIR | rec-stop DIR
#   t59-legs.sh leg-start a|b DIR URL SECONDS | leg-kill a|b DIR
#   t59-legs.sh netem a|b 'loss 2% delay 20ms' | netem a|b off
#
# Env: PACER (~ubuntu/pacer-5626c88/mpegts-pacer), B8 (~ubuntu/p59/b8-hls-recv.py),
# KEY_FILE (~ubuntu/p59/viewer-key), RATE (26000000), LAT_MS (8000), CAP_MS (14000), IF (ens5),
# ALIGN_MS (unset: the groomer starts on its first content; set: --align-ms, T60), RELEASE_MS
# (set: the fetcher holds each dated segment to its time plus this, T63).

set -uo pipefail
U=/home/ubuntu
PACER=${PACER:-$U/pacer-5626c88/mpegts-pacer}
B8=${B8:-$U/p59/b8-hls-recv.py}
KEY_FILE=${KEY_FILE:-$U/p59/viewer-key}
RATE=${RATE:-26000000}
LAT_MS=${LAT_MS:-8000}
CAP_MS=${CAP_MS:-14000}
IF=${IF:-ens5}

idx() { case $1 in a) echo 1 ;; b) echo 2 ;; *) echo "leg must be a or b" >&2; exit 2 ;; esac; }
port() { echo $((5000 + 100 * $(idx "$1"))); }

net_up() {
	cat /proc/sys/net/ipv4/ip_forward >/run/p59-ip_forward.orig
	sysctl -qw net.ipv4.ip_forward=1
	iptables -t nat -C POSTROUTING -s 10.59.0.0/16 -o "$IF" -j MASQUERADE 2>/dev/null ||
		iptables -t nat -A POSTROUTING -s 10.59.0.0/16 -o "$IF" -j MASQUERADE
	for l in a b; do
		local i ns=p59$l
		i=$(idx $l)
		ip netns add $ns
		ip link add v59$l type veth peer name v59${l}n
		ip link set v59${l}n netns $ns
		ip addr add 10.59.$i.1/30 dev v59$l
		ip link set v59$l up
		ip -n $ns addr add 10.59.$i.2/30 dev v59${l}n
		ip -n $ns link set v59${l}n up
		ip -n $ns link set lo up
		ip -n $ns route add default via 10.59.$i.1
		mkdir -p /etc/netns/$ns
		grep -h '^nameserver' /run/systemd/resolve/resolv.conf >/etc/netns/$ns/resolv.conf
	done
	echo "namespaces up"
}

net_down() {
	for l in a b; do
		ip netns del p59$l 2>/dev/null
		ip link del v59$l 2>/dev/null
		rm -rf /etc/netns/p59$l
	done
	iptables -t nat -D POSTROUTING -s 10.59.0.0/16 -o "$IF" -j MASQUERADE 2>/dev/null
	[ -f /run/p59-ip_forward.orig ] && sysctl -qw net.ipv4.ip_forward="$(cat /run/p59-ip_forward.orig)"
	echo "namespaces down, ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"
}

rec_start() {
	local dir=$1
	mkdir -p "$dir"
	chown ubuntu: "$dir" # the workstation drops events.txt here and grades as the login user
	setsid python3 - "$dir/legs.pcap" 5100 5200 >"$dir/rec.log" 2>&1 <<'PY' &
import selectors, signal, socket, struct, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
out, ports = sys.argv[1], [int(p) for p in sys.argv[2:]]
f = open(out, "wb", buffering=1 << 20)
f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 101))
sel = selectors.DefaultSelector()
for port in ports:
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 << 20)
	s.bind(("127.0.0.1", port))
	sel.register(s, selectors.EVENT_READ, port)
lo = socket.inet_aton("127.0.0.1")
try:
	while True:
		for key, _ in sel.select():
			data = key.fileobj.recv(65535)
			t = time.time()
			udp = struct.pack("!HHHH", 40000, key.data, 8 + len(data), 0)
			ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 28 + len(data), 0, 0, 64, 17, 0, lo, lo)
			frame = ip + udp + data
			f.write(struct.pack("<IIII", int(t), int((t % 1) * 1e6), len(frame), len(frame)) + frame)
finally:
	f.flush()
	f.close()
PY
	echo $! >"$dir/rec.pid"
	sleep 1
	echo "recorder $(cat "$dir/rec.pid")"
}

rec_stop() {
	kill -TERM "$(cat "$1/rec.pid")" 2>/dev/null
	sleep 1
	ls -la "$1/legs.pcap"
}

leg_start() {
	local l=$1 dir=$2 url=$3 secs=$4 key
	key=$(cat "$KEY_FILE")
	mkdir -p "$dir"
	# A new session, so the whole leg (fetcher, pipe, groomer) is one process group to kill.
	setsid bash -c "ip netns exec p59$l python3 '$B8' '$url' - --seconds '$secs' \
		--header 'X-P59-Key: $key' ${RELEASE_MS:+--release-ms $RELEASE_MS} \
		--log '$dir/b8-$l.jsonl' 2>'$dir/b8-$l.err' |
		'$PACER' 127.0.0.1:$(port "$l") $RATE --rtp --ssrc 538968071 --stream-clock \
		--sequence-seed 0 --latency-ms $LAT_MS --max-latency-ms $CAP_MS --stall-ms 1000 \
		--on-stall mute --stats-interval-ms 10000 ${ALIGN_MS:+--align-ms $ALIGN_MS} \
		2>>'$dir/pacer-$l.log'" </dev/null >/dev/null 2>&1 &
	echo $! >"$dir/leg-$l.pid"
	echo "$EPOCHREALTIME leg-start-$l" >>"$dir/events.log"
	echo "leg $l pgid $(cat "$dir/leg-$l.pid")"
}

leg_kill() {
	local l=$1 dir=$2
	kill -KILL -- "-$(cat "$dir/leg-$l.pid")" 2>/dev/null
	echo "$EPOCHREALTIME leg-kill-$l" >>"$dir/events.log"
	echo "leg $l killed"
}

netem() {
	local l=$1 spec=$2
	idx "$l" >/dev/null
	if [ "$spec" = off ]; then
		tc qdisc del dev v59$l root 2>/dev/null
	else
		# shellcheck disable=SC2086 # the spec is a list of netem arguments
		tc qdisc replace dev v59$l root netem $spec
	fi
	tc qdisc show dev v59$l | head -1
}

case "${1:-}" in
net-up) net_up ;;
net-down) net_down ;;
rec-start) rec_start "$2" ;;
rec-stop) rec_stop "$2" ;;
leg-start) leg_start "$2" "$3" "$4" "$5" ;;
leg-kill) leg_kill "$2" "$3" ;;
netem) netem "$2" "$3" ;;
*)
	echo "usage: t59-legs.sh net-up|net-down|rec-start DIR|rec-stop DIR|leg-start a|b DIR URL SECONDS|leg-kill a|b DIR|netem a|b SPEC|off" >&2
	exit 2
	;;
esac

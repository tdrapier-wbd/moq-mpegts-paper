#!/usr/bin/env bash
# T12 arm D on the opaque lane, one leg joining late (P1-o).
#
# The demultiplexed export merges only co-started legs. The opaque lane's export writes the
# source's own packets, and a leg joining 8 s late is byte-identical to the first (T48), so two
# such legs, each through its own stream-clocked groomer, should merge at the byte whenever both
# are up, and a leg back from a blackout should rejoin the numbering. Everything runs on one host,
# on loopback, clear of the standing units: a relay on its own port, the clip piped into
# `import ts --passthrough` and teed as the reference, two legs to ports 5100 and 5200, one
# tcpdump of both.
#
# Cells (CELL=): control; blackout (A dark for DARK_S s at 40 s, then B at 100 s); kill (A's export
# SIGKILLed at 40 s). A blackout longer than the session's idle timeout (about 13 s) ends the
# leg's export instead of pausing it. A blackout drops the leg's QUIC flow both ways with iptables rules keyed on
# its own ephemeral UDP ports, so no other loopback traffic is touched, and a detached watchdog
# removes the rules if the rig dies first.
#
#   sudo CELL=control BIN=<moq dir> PACER=<pacer dir> t12-opaque-late.sh <label>
#
# Env: CLIP, RATE (the clip's, bits/s), SECS (150), LATE (8), DARK_S (15), DELAY (2s), PORT (4480),
#      SSRC, SEQ_SEED, OUT. The grading commands are printed at the end.
set -uo pipefail

# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:?label}
CELL=${CELL:-control}
BIN=${BIN:?set BIN to the moq binary dir}
PACER=${PACER:?set PACER to the pacer dir}
CLIP=${CLIP:-/home/ubuntu/contrib-10m.ts}
RATE=${RATE:-9945951}
SECS=${SECS:-150}
LATE=${LATE:-8}
DARK_S=${DARK_S:-15}
DELAY=${DELAY:-2s}
PORT=${PORT:-4480}
SSRC=${SSRC:-538968071}
SEQ_SEED=${SEQ_SEED:-4242}
OUT=${OUT:-/home/ubuntu/p1o-opaque}/$LABEL-$CELL
BC="p1o.opaque.$CELL.$$"
EGRESS=$PACER/mpegts-pacer

[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo): iptables and tcpdump" >&2
	exit 1
}
for f in "$CLIP" "$BIN/moq" "$BIN/moq-relay" "$EGRESS"; do
	[ -r "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done
case "$CELL" in
control | blackout | kill) ;;
*)
	echo "CELL must be control, blackout or kill" >&2
	exit 1
	;;
esac
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"

rm -rf "$OUT"
mkdir -p "$OUT"
URL="https://127.0.0.1:$PORT/anon"

set -m
PIDS=()
DARK=()
light() {
	iptables -D OUTPUT -o lo -p udp --sport "$1" -j DROP 2>/dev/null
	iptables -D OUTPUT -o lo -p udp --dport "$1" -j DROP 2>/dev/null
}
cleanup() {
	for p in ${DARK+"${DARK[@]}"}; do light "$p"; done
	pkill -INT -f "[t]cpdump -i lo -n -s 0 -Z root -B 65536 -w $OUT/" 2>/dev/null
	for p in ${PIDS+"${PIDS[@]}"}; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
	sleep 1
	for p in ${PIDS+"${PIDS[@]}"}; do kill -KILL -- "-$p" 2>/dev/null; done
	wait 2>/dev/null
}
trap cleanup EXIT

stamp() { echo "$1 $(date +%s%N)" >>"$OUT/events.txt"; }

# Every UDP port the leg's export holds, so a blackout takes its whole QUIC path. A QUIC client's
# socket is unconnected, which ss lists only with -a.
ports_of() { ss -H -uanp 2>/dev/null | awk -v p="pid=$1," 'index($0, p) { n = split($4, a, ":"); print a[n] }' | sort -u; }

dark() { # $1 leg name, $2 export pid, $3 seconds
	local ports
	ports=$(ports_of "$2")
	[ -n "$ports" ] || {
		echo "   no UDP port found for leg $1 (pid $2)" >&2
		return 1
	}
	for p in $ports; do
		iptables -I OUTPUT -o lo -p udp --sport "$p" -j DROP
		iptables -I OUTPUT -o lo -p udp --dport "$p" -j DROP
		DARK+=("$p")
		setsid bash -c "sleep $(($3 + 20)); iptables -D OUTPUT -o lo -p udp --sport $p -j DROP; iptables -D OUTPUT -o lo -p udp --dport $p -j DROP" \
			>/dev/null 2>&1 </dev/null &
	done
	stamp "${1}_dark"
	echo "   leg $1 dark (ports $(echo "$ports" | tr '\n' ' '))"
	sleep "$3"
	for p in $ports; do light "$p"; done
	stamp "${1}_light"
	echo "   leg $1 back"
}

echo "=== $(date -u) t12-opaque-late $LABEL cell $CELL ==="
{
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	cat "$BIN.sha" 2>/dev/null || echo "sha: no sidecar for $BIN"
	echo "pacer: $EGRESS $(cat "$PACER.sha" 2>/dev/null || true)"
	echo "clip $CLIP at $RATE b/s; legs: export ts --passthrough ${MOQ_LAT[*]} $DELAY; B $LATE s late; ${SECS}s"
} | tee "$OUT/build.txt"

# Sinks first: a datagram to a closed loopback port earns an ICMP error the pacer would see.
for port in 5100 5200; do
	python3 -c 'import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 << 20)
s.bind(("127.0.0.1", int(sys.argv[1])))
while True:
    s.recv(65535)' "$port" &
	PIDS+=("$!")
done
tcpdump -i lo -n -s 0 -Z root -B 65536 -w "$OUT/legs.pcap" "udp and (dst port 5100 or dst port 5200)" \
	2>"$OUT/tcpdump.log" &
PIDS+=("$!")

"$BIN/moq-relay" "${RELAY_BIND[@]}" "127.0.0.1:$PORT" "${RELAY_TLS[@]}" localhost \
	"${RELAY_AUTH[@]}" "${RELAY_GSO[@]}" --log-level warn >"$OUT/relay.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 30); do
	ss -lun 2>/dev/null | grep -q ":$PORT " && break
	sleep 0.5
done

# The reference is what the importer read, so a defect upstream of the lane cannot pass as one in it.
(tsp --realtime -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>"$OUT/tsp.log" |
	tee "$OUT/ref.ts" |
	"$BIN/moq" "${MOQ_DIAL[@]}" "$URL" --broadcast "$BC" import ts --passthrough) >"$OUT/import.log" 2>&1 &
PIDS+=("$!")
sleep 12

# Not called through $(...): the leg's process group has to land in PIDS for teardown.
LEGPID=""
leg() { # $1 name, $2 port; sets LEGPID to the leg's export pid
	bash -c "'$BIN/moq' ${MOQ_DIAL[*]} '$URL' --broadcast '$BC' export ts --passthrough ${MOQ_LAT[*]} $DELAY \
		2>'$OUT/$1.export.log' \
	| '$EGRESS' 127.0.0.1:$2 $RATE --rtp --ssrc $SSRC --latency-ms 1500 --max-latency-ms 8000 \
		--stall-ms 1000 --on-stall mute --stream-clock --sequence-seed $SEQ_SEED" \
		>"$OUT/$1.pacer.log" 2>&1 </dev/null &
	PIDS+=("$!")
	sleep 1
	LEGPID=$(pgrep -n -x moq)
	grep -q "$BC" "/proc/$LEGPID/cmdline" 2>/dev/null || LEGPID=""
	stamp "${1}_start"
}

leg a 5100
APID=$LEGPID
echo "   leg a up (export pid ${APID:-unknown})"
sleep $((LATE - 1))
leg b 5200
BPID=$LEGPID
echo "   leg b up (export pid ${BPID:-unknown})"
T=$((LATE + 1))

case "$CELL" in
blackout)
	sleep $((40 - T))
	dark a "$APID" "$DARK_S"
	sleep $((100 - 40 - DARK_S))
	dark b "$BPID" "$DARK_S"
	sleep $((SECS - 100 - DARK_S))
	;;
kill)
	sleep $((40 - T))
	kill -KILL "$APID" 2>/dev/null
	stamp a_kill
	echo "   leg a export killed"
	sleep $((SECS - 40))
	;;
*)
	sleep $((SECS - T))
	;;
esac

cleanup
trap - EXIT
chown -R "${SUDO_USER:-root}": "$OUT" 2>/dev/null
grep -i "dropped by kernel" "$OUT/tcpdump.log" | sed 's/^/   tcpdump: /'
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cat <<EOF
=== $(date -u) done: $OUT ===
grade (as the user):
  cd $OUT
  python3 $H/t12-merge-oracle.py --pcap legs.pcap --leg-a-port 5100 --leg-b-port 5200 --k-ms 50 --out-prefix merged --json oracle.json
  python3 $H/ts-passthrough-identity.py ref.ts merged.seqmerge.ts --groomed --json identity.json
  python3 $H/t12-resume.py --pcap legs.pcap
  tsp -I file merged.seqmerge.ts -P continuity -O drop
EOF

#!/usr/bin/env bash
# T55: ST 2022-7 legs from two passthrough exports, each through TSDuck's RTP output
# (lab/test-55-tsp-rtp-legs.md).
#
# `tsp -O ip --rtp` numbers datagrams by its own count from --start-sequence-number and stamps
# them from the stream's PCR, so two legs carry the same datagrams under the same numbers only if
# they cut the same packets from the same first packet. Each cell tests one way a leg can stop
# doing that. The relay, the importer and both legs run on this host. Both legs are
# recorded from their sockets into one classic pcap, so no capture privilege is needed. With
# RELAY_URL the importer and both legs still run here, through that relay.
#
# Cells (CELL=):
#   costart  both legs started before the importer, so both begin at its first packet
#   late     leg B started LATE s after leg A
#   kill     both co-started; leg A's export killed at KILL_AT s, the leg restarted DARK_S s later
#            with the same configuration
#   stall    both co-started; leg A's export stopped (SIGSTOP) at KILL_AT s for DARK_S s
#   blackout both co-started; leg A's QUIC path dropped at KILL_AT s for DARK_S s (Linux, root)
#
# START=apart starts leg B LATE s after leg A in every cell, as `late` does. LEG=pacer puts each
# export through T12's stream-clocked groomer (`mpegts-pacer --rtp --stream-clock` at RATE, shared
# SSRC and SEQ_SEED) in place of tsp, so a datagram's number is its slot on the source's timeline.
#
#   CELL=costart BIN=<moq dir> CLIP=<ts> t55-tsp-rtp-legs.sh <label>
#
# Env: SECS (120), LATE (8), KILL_AT (40), DARK_S (10), DELAY (2s), PORT (4590), SEQ (1000),
#      SSRC (538968071), BURST (7), TSP_LEG_OPTS (extra tsp options on each leg, e.g.
#      "--initial-input-packets 7": by default tsp sends its first half-buffer, about 7 s of a
#      10 Mb/s stream, as one burst), START (together), LEG (tsp), PACER (the pacer's dir, for
#      LEG=pacer), RATE (the clip's, bits/s: 9945951), SEQ_SEED (4242), RELAY_URL (default: a
#      local relay on PORT), BC, OUT (/tmp/t55). Grading commands are printed at the end.
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=moq-cli-flags.sh
. "$H/moq-cli-flags.sh"

LABEL=${1:?label}
CELL=${CELL:-costart}
BIN=${BIN:?set BIN to the moq binary dir}
SECS=${SECS:-120}
LATE=${LATE:-8}
KILL_AT=${KILL_AT:-40}
DARK_S=${DARK_S:-10}
DELAY=${DELAY:-2s}
PORT=${PORT:-4590}
SEQ=${SEQ:-1000}
SSRC=${SSRC:-538968071}
BURST=${BURST:-7}
TSP_LEG_OPTS=${TSP_LEG_OPTS:-}
START=${START:-together}
LEG=${LEG:-tsp}
RATE=${RATE:-9945951}
SEQ_SEED=${SEQ_SEED:-4242}
OUT=${OUT:-/tmp/t55}/$LABEL-$CELL
REMOTE=${RELAY_URL:+1}
URL=${RELAY_URL:-https://127.0.0.1:$PORT/anon}
BC=${BC:-t55.$CELL.$$}

case "$CELL" in
costart | late | kill | stall) ;;
blackout)
	[ "$(uname)" = Linux ] && [ "$(id -u)" -eq 0 ] || {
		echo "blackout needs Linux and root (iptables)" >&2
		exit 1
	}
	;;
*)
	echo "CELL must be costart, late, kill, stall or blackout" >&2
	exit 1
	;;
esac
[ -r "${CLIP:-}" ] || {
	echo "set CLIP to a readable TS file" >&2
	exit 1
}
for f in "$BIN/moq" "$BIN/moq-relay"; do [ -x "$f" ] || {
	echo "missing $f" >&2
	exit 1
}; done
command -v tsp >/dev/null || {
	echo "tsp not found" >&2
	exit 1
}
case "$START:$LEG" in
together:tsp | apart:tsp) ;;
together:pacer | apart:pacer)
	[ -x "${PACER:-}/mpegts-pacer" ] || {
		echo "LEG=pacer needs PACER, the dir holding mpegts-pacer" >&2
		exit 1
	}
	;;
*)
	echo "START must be together or apart, LEG tsp or pacer" >&2
	exit 1
	;;
esac
[ "$CELL" = late ] && START=apart
if [ "$LEG" = pacer ]; then
	STAGE="'$PACER/mpegts-pacer' 127.0.0.1:%s $RATE --rtp --ssrc $SSRC --latency-ms 1500 --max-latency-ms 8000 --stall-ms 1000 --on-stall mute --stream-clock --sequence-seed $SEQ_SEED"
else
	STAGE="tsp --realtime $TSP_LEG_OPTS -O ip 127.0.0.1:%s --rtp --enforce-burst --packet-burst $BURST --start-sequence-number $SEQ --ssrc-identifier $SSRC"
fi
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"

rm -rf "$OUT"
mkdir -p "$OUT"
set -m
PIDS=()
DARK=()
now_ns() { python3 -c 'import time; print(time.time_ns())'; }
stamp() { echo "$1 $(now_ns)" >>"$OUT/events.txt"; }
light() {
	iptables -D OUTPUT -o lo -p udp --sport "$1" -j DROP 2>/dev/null
	iptables -D OUTPUT -o lo -p udp --dport "$1" -j DROP 2>/dev/null
}
cleanup() {
	for p in ${DARK+"${DARK[@]}"}; do light "$p"; done
	for p in ${PIDS+"${PIDS[@]}"}; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
	sleep 1
	for p in ${PIDS+"${PIDS[@]}"}; do kill -KILL -- "-$p" 2>/dev/null; done
	wait 2>/dev/null
}
trap cleanup EXIT

echo "=== $(date -u) t55-tsp-rtp-legs $LABEL cell $CELL ==="
{
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	cat "$BIN.sha" 2>/dev/null || echo "sha: no sidecar for $BIN"
	tsp --version 2>&1 | head -1
	[ "$LEG" = pacer ] && echo "pacer: $PACER/mpegts-pacer $(cat "$PACER.sha" 2>/dev/null || true)"
	echo "relay: ${REMOTE:+remote }$URL; broadcast $BC; ${SECS}s; delay $DELAY; start $START"
	# shellcheck disable=SC2059 # STAGE is the leg's format, %s its port
	echo "legs: export ts --passthrough | $(printf "$STAGE" PORT)"
} | tee "$OUT/build.txt"

# The recorder: both legs' datagrams into one pcap (raw IPv4, synthesized headers carrying each
# leg's destination port), started first so no datagram is missed.
python3 - "$OUT/legs.pcap" 5100 5200 <<'PY' &
import selectors, socket, struct, sys, time
out, ports = sys.argv[1], [int(p) for p in sys.argv[2:]]
f = open(out, "wb")
f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 101))
sel = selectors.DefaultSelector()
for port in ports:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 << 20)
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
except (KeyboardInterrupt, SystemExit):
    pass
finally:
    f.flush()
    f.close()
PY
PIDS+=("$!")
sleep 1

if [ -z "$REMOTE" ]; then
	"$BIN/moq-relay" "${RELAY_BIND[@]}" "127.0.0.1:$PORT" "${RELAY_TLS[@]}" localhost \
		"${RELAY_AUTH[@]}" "${RELAY_GSO[@]}" --log-level warn >"$OUT/relay.log" 2>&1 &
	PIDS+=("$!")
	sleep 2
fi

# The reference is what the importer read.
importer() {
	(tsp --realtime -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>"$OUT/tsp-src.log" |
		tee "$OUT/ref.ts" |
		"$BIN/moq" "${MOQ_DIAL[@]}" "$URL" --broadcast "$BC" import ts --passthrough) >"$OUT/import.log" 2>&1 &
	PIDS+=("$!")
	stamp import_start
}

# A leg is its export piped into the RTP stage; LEGPID is the export's pid. Not called through
# $(...): the leg's process group has to land in PIDS for teardown.
LEGPID=""
LEGPG=""
leg() { # $1 name, $2 port
	# shellcheck disable=SC2059 # STAGE is the leg's format, %s its port
	bash -c "'$BIN/moq' ${MOQ_DIAL[*]} '$URL' --broadcast '$BC' export ts --passthrough ${MOQ_LAT[*]} $DELAY \
		2>>'$OUT/$1.export.log' & echo \$! > '$OUT/$1.export.pid'; wait" |
		bash -c "exec $(printf "$STAGE" "$2")" >>"$OUT/$1.$LEG.log" 2>&1 &
	LEGPG=$!
	PIDS+=("$LEGPG")
	sleep 0.5
	LEGPID=$(cat "$OUT/$1.export.pid" 2>/dev/null)
	stamp "${1}_start"
}

dark() { # $1 leg, $2 export pid, $3 seconds: drop the leg's QUIC flow both ways on loopback
	local ports
	ports=$(ss -H -uanp 2>/dev/null | awk -v p="pid=$2," 'index($0, p) { n = split($4, a, ":"); print a[n] }' | sort -u)
	[ -n "$ports" ] || {
		echo "   no UDP port for leg $1 (pid $2)" >&2
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
	sleep "$3"
	for p in $ports; do light "$p"; done
	stamp "${1}_light"
}

T=0
if [ "$START" = apart ]; then
	importer
	sleep 6
	leg a 5100
	A=$LEGPID
	APG=$LEGPG
	sleep "$LATE"
	leg b 5200
	T=$((LATE + 1))
else
	leg a 5100
	A=$LEGPID
	APG=$LEGPG
	leg b 5200
	sleep 1
	importer
	T=2
fi
echo "   legs up (A export ${A:-?})"

case "$CELL" in
kill)
	sleep $((KILL_AT - T))
	kill -KILL "$A" 2>/dev/null
	stamp a_kill
	echo "   leg A's export killed"
	sleep "$DARK_S"
	kill -0 "$APG" 2>/dev/null && {
		echo "   leg A's RTP stage still up ${DARK_S}s after its input ended; stopped" | tee -a "$OUT/events.note"
		kill -TERM "$APG"
	}
	wait "$APG" 2>/dev/null
	leg a 5100
	echo "   leg A restarted"
	sleep $((SECS - KILL_AT - DARK_S))
	;;
stall)
	sleep $((KILL_AT - T))
	kill -STOP "$A"
	stamp a_stop
	sleep "$DARK_S"
	kill -CONT "$A"
	stamp a_cont
	echo "   leg A's export stopped for ${DARK_S}s"
	sleep $((SECS - KILL_AT - DARK_S))
	;;
blackout)
	sleep $((KILL_AT - T))
	dark a "$A" "$DARK_S"
	echo "   leg A dark for ${DARK_S}s"
	sleep $((SECS - KILL_AT - DARK_S))
	;;
*)
	sleep $((SECS - T))
	;;
esac

cleanup
trap - EXIT
[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER": "$OUT" 2>/dev/null
cat <<EOF
=== $(date -u) done: $OUT ===
grade:
  cd $OUT
  python3 $H/t55-grade.py legs.pcap ref.ts --events events.txt --json grade.json
EOF
[ "$LEG" = tsp ] || echo "  python3 $H/ts-passthrough-identity.py ref.ts merged.ts --groomed --json identity.json"

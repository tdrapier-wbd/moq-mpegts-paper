#!/usr/bin/env bash
# T83 Part A: an SRT leg beside an opaque MoQ leg of one source, merged (P1-as).
#
# One host, on loopback, clear of the standing units. The clip is paced once onto a loopback
# multicast group of its own; a tap on the group writes the reference, and each leg reads the group:
#
#   leg a (SRT)     tsp -I ip -O srt --caller  ->  tsp -I srt --listener --multiple  -> groomer -> :5100
#   leg b (opaque)  tsp -I ip | moq import ts --passthrough -> relay -> export ts --passthrough
#                                                                                     -> groomer -> :5200
#
#   LEGB=seg: leg b is segmented. Two packagers read the group, behind a loopback HTTP origin:
#   `tsp -O hls` (1 s segments) and the deployed seg lane's t61-epochseg.py (2 s slices, --pdt).
#   Three b8-hls-recv.py receivers feed their own groomers: tsp's segments with the added PAT/PMT
#   pair dropped (--strip-tables) -> :5200, t61's held to their program date-time (--release-ms
#   1500, as srt-send.sh's seg lane) -> :5300, tsp's as they are -> :5400.
#
# Each groomer is stream-clocked, with the same SSRC and sequence seed, as t12-opaque-late.sh's legs.
# The SRT sender, the SRT receiver and the importer run under loops that restart them 1 s after they
# exit, as a process manager would; the export does not, as in T12. One tcpdump of both legs.
#
# Cells (CELL=): control; dark-a, dark-b (the leg's UDP dropped both ways for DARK_S from 40 s);
# kill-a (the SRT receiver and its loop SIGKILLed at 40 s: the leg ends); kill-b (the export SIGKILLed
# at 40 s); late-a, late-b (that leg starts LATE s after the other); sender (the SRT sender SIGKILLed at
# 40 s, its loop restarting it); relay (the relay SIGKILLed at 40 s and started again 1 s later).
# With LEGB=seg, dark-b drops the origin's TCP port, kill-b kills the three receivers, late-b starts
# them late, and relay kills both packagers, whose loops restart them under new segment names.
# CLOCK=arrival grooms both legs on arrival instead of the stream clock: the negative control.
#
#   sudo CELL=control BIN=<moq dir> PACER=<pacer dir> t83-mixed-merge.sh <label>
#
# Env: CLIP, RATE (the clip's, bits/s), SECS (120), LATE (8), DARK_S (15), DELAY (2s), SRT_LAT (ms,
#      1000), PORT (4483), GROUP (239.255.0.83:5083), SRTPORT (9383), CLOCK (stream | arrival), SSRC,
#      SEQ_SEED, LEGB (opaque | seg), HTTPPORT (18383), SEG_LAT_MS (3000: the groomer's cushion behind
#      t61's slices, T70's floor for 2 s slices held to their program date-time; 1500 behind the
#      others), OUT. The grading commands are printed at the end.
set -uo pipefail

# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:?label}
CELL=${CELL:-control}
BIN=${BIN:?set BIN to the moq binary dir}
PACER=${PACER:?set PACER to the pacer dir}
CLIP=${CLIP:-/home/ubuntu/contrib-10m.ts}
RATE=${RATE:-9945951}
SECS=${SECS:-120}
LATE=${LATE:-8}
DARK_S=${DARK_S:-15}
DELAY=${DELAY:-2s}
SRT_LAT=${SRT_LAT:-1000}
PORT=${PORT:-4483}
GROUP=${GROUP:-239.255.0.83:5083}
SRTPORT=${SRTPORT:-9383}
CLOCK=${CLOCK:-stream}
SSRC=${SSRC:-538968071}
SEQ_SEED=${SEQ_SEED:-4242}
LEGB=${LEGB:-opaque}
HTTPPORT=${HTTPPORT:-18383}
SEG_LAT_MS=${SEG_LAT_MS:-3000}
OUT=${OUT:-/home/ubuntu/t83a}/$LABEL-$CELL
BC="t83a.$CELL.$$"
EGRESS=$PACER/mpegts-pacer
case "$CLOCK" in
stream) CLK=--stream-clock ;;
arrival) CLK="" ;;
*)
	echo "CLOCK must be stream or arrival" >&2
	exit 1
	;;
esac
case "$CELL" in
control | dark-a | dark-b | kill-a | kill-b | late-a | late-b | sender | relay) ;;
*)
	echo "CELL must be control, dark-a, dark-b, kill-a, kill-b, late-a, late-b, sender or relay" >&2
	exit 1
	;;
esac
case "$LEGB" in opaque | seg) ;; *)
	echo "LEGB must be opaque or seg" >&2
	exit 1
	;;
esac
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SEGB=(drop:5200 epoch:5300 packaged:5400)
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
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"

rm -rf "$OUT"
mkdir -p "$OUT"
URL="https://127.0.0.1:$PORT/anon"
GIN="-I ip $GROUP --local-address 127.0.0.1 --buffer-size 16777216"

set -m
PIDS=()
DARK=()
light() { # $1 port, $2 protocol (udp)
	iptables -D OUTPUT -o lo -p "${2:-udp}" --sport "$1" -j DROP 2>/dev/null
	iptables -D OUTPUT -o lo -p "${2:-udp}" --dport "$1" -j DROP 2>/dev/null
}
cleanup() {
	for p in ${DARK+"${DARK[@]}"}; do light "${p%/*}" "${p#*/}"; done
	pkill -INT -f "[t]cpdump -i lo -n -s 0 -Z root -B 65536 -w $OUT/" 2>/dev/null
	for p in ${PIDS+"${PIDS[@]}"}; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
	sleep 1
	for p in ${PIDS+"${PIDS[@]}"}; do kill -KILL -- "-$p" 2>/dev/null; done
	wait 2>/dev/null
}
trap cleanup EXIT

stamp() { echo "$1 $(date +%s%N)" >>"$OUT/events.txt"; }

# Every UDP port a process holds; a QUIC client's socket is unconnected, which ss lists only with -a.
ports_of() { ss -H -uanp 2>/dev/null | awk -v p="pid=$1," 'index($0, p) { n = split($4, a, ":"); print a[n] }' | sort -u; }

dark() { # $1 leg name, $2 ports, $3 seconds, $4 protocol (udp)
	local p pr=${4:-udp}
	for p in $2; do
		iptables -I OUTPUT -o lo -p "$pr" --sport "$p" -j DROP
		iptables -I OUTPUT -o lo -p "$pr" --dport "$p" -j DROP
		DARK+=("$p/$pr")
		setsid bash -c "sleep $(($3 + 20)); iptables -D OUTPUT -o lo -p $pr --sport $p -j DROP; iptables -D OUTPUT -o lo -p $pr --dport $p -j DROP" \
			>/dev/null 2>&1 </dev/null &
	done
	stamp "${1}_dark"
	echo "   leg $1 dark ($pr ports $(echo "$2" | tr '\n' ' '))"
	sleep "$3"
	for p in $2; do light "$p" "$pr"; done
	stamp "${1}_light"
	echo "   leg $1 back"
}

start_relay() {
	"$BIN/moq-relay" "${RELAY_BIND[@]}" "127.0.0.1:$PORT" "${RELAY_TLS[@]}" localhost \
		"${RELAY_AUTH[@]}" "${RELAY_GSO[@]}" --log-level warn >>"$OUT/relay.log" 2>&1 &
	RELAYPID=$!
	PIDS+=("$RELAYPID")
	for _ in $(seq 1 30); do
		ss -lun 2>/dev/null | grep -q ":$PORT " && break
		sleep 0.5
	done
}

groomer() { # $1 port, $2 cushion (ms, 1500)
	echo "'$EGRESS' 127.0.0.1:$1 $RATE --rtp --ssrc $SSRC --latency-ms ${2:-1500} --max-latency-ms 8000 --stall-ms 1000 --on-stall mute $CLK --sequence-seed $SEQ_SEED"
}

echo "=== $(date -u) t83-mixed-merge $LABEL cell $CELL ==="
{
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	cat "$BIN.sha" 2>/dev/null || echo "sha: no sidecar for $BIN"
	echo "pacer: $EGRESS $(cat "$PACER.sha" 2>/dev/null || true) clock $CLOCK"
	tsp --version 2>&1 | head -1
	if [ "$LEGB" = seg ]; then
		echo "b8-hls-recv.py sha256 $(sha256sum "$H/b8-hls-recv.py" | cut -c1-12); t61-epochseg.py sha256 $(sha256sum "$H/t61-epochseg.py" | cut -c1-12)"
		B="segmented: tsp -O hls --duration 1 and t61-epochseg.py --duration 2 --pdt (groomer cushion $SEG_LAT_MS ms), origin :$HTTPPORT; ${SEGB[*]}"
	else
		B="export ts --passthrough ${MOQ_LAT[*]} $DELAY"
	fi
	echo "clip $CLIP at $RATE b/s; leg a SRT --latency $SRT_LAT; leg b $B; ${SECS}s"
} | tee "$OUT/build.txt"

SINKS="5100 5200"
[ "$LEGB" = seg ] && SINKS="5100 5200 5300 5400"
# Sinks first: a datagram to a closed loopback port earns an ICMP error the pacer would see.
for port in $SINKS; do
	python3 -c 'import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 << 20)
s.bind(("127.0.0.1", int(sys.argv[1])))
while True:
    s.recv(65535)' "$port" &
	PIDS+=("$!")
done
tcpdump -i lo -n -s 0 -Z root -B 65536 -w "$OUT/legs.pcap" "udp and (dst port ${SINKS// / or dst port })" \
	2>"$OUT/tcpdump.log" &
PIDS+=("$!")
[ "$LEGB" = opaque ] && start_relay

# The reference is what both legs read from the group, so a defect upstream of a leg cannot pass as one in it.
# shellcheck disable=SC2086
tsp $GIN -O file "$OUT/ref.ts" 2>"$OUT/ref.log" &
PIDS+=("$!")
sleep 1
tsp --realtime -I file "$CLIP" -P regulate --pcr-synchronous -O ip "$GROUP" --local-address 127.0.0.1 \
	--enforce-burst 2>"$OUT/source.log" &
PIDS+=("$!")
if [ "$LEGB" = opaque ]; then
	bash -c "while :; do tsp $GIN -O file - 2>>'$OUT/import.tsp.log' | '$BIN/moq' ${MOQ_DIAL[*]} '$URL' --broadcast '$BC' import ts --passthrough; echo \"restart \$(date +%s%N)\"; sleep 1; done" \
		>"$OUT/import.log" 2>&1 </dev/null &
	PIDS+=("$!")
else
	mkdir -p "$OUT/hls/std" "$OUT/hls/epoch"
	python3 -c 'import functools, http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_):
        pass
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), functools.partial(H, directory=sys.argv[2])).serve_forever()' \
		"$HTTPPORT" "$OUT/hls" 2>>"$OUT/origin.log" &
	PIDS+=("$!")
	# Each tsp restart writes under a new prefix: the receivers know a segment by its name. t61 names
	# its segments by content time, the same across restarts.
	bash -c "echo \$\$ >'$OUT/pkg-std.pid'; k=0; while :; do tsp $GIN -O hls --duration 1 --live 10 --playlist '$OUT/hls/std/index.m3u8' '$OUT/hls/std/r'\$k'-seg-.ts' 2>>'$OUT/pkg-std.log'; echo \"pkg-restart \$(date +%s%N)\" >>'$OUT/pkg-std.log'; k=\$((k + 1)); sleep 1; done" \
		>/dev/null 2>&1 </dev/null &
	PIDS+=("$!")
	bash -c "echo \$\$ >'$OUT/pkg-epoch.pid'; while :; do python3 '$H/t61-epochseg.py' '$OUT/hls/epoch' --group $GROUP --duration 2 --pdt 2>>'$OUT/pkg-epoch.log'; echo \"pkg-restart \$(date +%s%N)\" >>'$OUT/pkg-epoch.log'; sleep 1; done" \
		>/dev/null 2>&1 </dev/null &
	PIDS+=("$!")
fi
sleep 10

leg_a() {
	bash -c "echo \$\$ >'$OUT/a-send.pid'; while :; do tsp $GIN -O srt --caller 127.0.0.1:$SRTPORT --latency $SRT_LAT 2>>'$OUT/a.send.log'; echo \"send-restart \$(date +%s%N)\" >>'$OUT/a.send.log'; sleep 1; done" \
		>/dev/null 2>&1 </dev/null &
	PIDS+=("$!")
	bash -c "bash -c \"echo \\\$\\\$ >'$OUT/a-recv.pid'; while :; do tsp -I srt --listener 127.0.0.1:$SRTPORT --latency $SRT_LAT --multiple -O file - 2>>'$OUT/a.recv.log'; echo recv-restart >>'$OUT/a.recv.log'; sleep 1; done\" \
		| $(groomer 5100)" >"$OUT/a.pacer.log" 2>&1 </dev/null &
	PIDS+=("$!")
	stamp a_start
	echo "   leg a up (SRT, --latency $SRT_LAT)"
}

LEGPID=""
leg_b() {
	if [ "$LEGB" = seg ]; then
		local e v port dir strip lat
		for e in "${SEGB[@]}"; do
			v=${e%:*} port=${e#*:} dir=std strip="" lat=1500
			[ "$v" = epoch ] && dir=epoch strip="--release-ms 1500" lat=$SEG_LAT_MS
			[ "$v" = drop ] && strip=--strip-tables
			bash -c "bash -c \"echo \\\$\\\$ >'$OUT/b-$v.pid'; exec python3 '$H/b8-hls-recv.py' 'http://127.0.0.1:$HTTPPORT/$dir/index.m3u8' - --seconds 0 --edge 1 --poll 100 $strip --log '$OUT/b-$v.recv.jsonl'\" \
				| $(groomer "$port" "$lat")" >"$OUT/b-$v.pacer.log" 2>&1 </dev/null &
			PIDS+=("$!")
		done
		stamp b_start
		echo "   leg b up (segmented: ${SEGB[*]})"
		return
	fi
	bash -c "'$BIN/moq' ${MOQ_DIAL[*]} '$URL' --broadcast '$BC' export ts --passthrough ${MOQ_LAT[*]} $DELAY \
		2>'$OUT/b.export.log' | $(groomer 5200)" >"$OUT/b.pacer.log" 2>&1 </dev/null &
	PIDS+=("$!")
	sleep 1
	LEGPID=$(pgrep -n -x moq)
	grep -q "$BC" "/proc/$LEGPID/cmdline" 2>/dev/null && grep -q "export" "/proc/$LEGPID/cmdline" || LEGPID=""
	stamp b_start
	echo "   leg b up (opaque, export pid ${LEGPID:-unknown})"
}

case "$CELL" in
late-a)
	leg_b
	sleep $((LATE - 1))
	leg_a
	;;
late-b)
	leg_a
	sleep $((LATE - 1))
	leg_b
	;;
*)
	leg_a
	leg_b
	;;
esac
BPID=$LEGPID
T=$((LATE + 1))
case "$CELL" in late-a | late-b) ;; *) T=2 ;; esac

kids() { pgrep -P "$1" 2>/dev/null; }
case "$CELL" in
dark-a)
	sleep $((40 - T))
	dark a "$SRTPORT" "$DARK_S"
	sleep $((SECS - 40 - DARK_S))
	;;
dark-b)
	sleep $((40 - T))
	if [ "$LEGB" = seg ]; then
		dark b "$HTTPPORT" "$DARK_S" tcp
	elif [ -n "$BPID" ] && P=$(ports_of "$BPID") && [ -n "$P" ]; then
		dark b "$P" "$DARK_S"
	else
		echo "   no UDP port found for leg b (pid ${BPID:-unknown})" >&2
		stamp b_dark_failed
		sleep "$DARK_S"
	fi
	sleep $((SECS - 40 - DARK_S))
	;;
kill-a)
	sleep $((40 - T))
	L=$(cat "$OUT/a-recv.pid" 2>/dev/null)
	K=$(kids "$L")
	# shellcheck disable=SC2086
	kill -KILL "$L" $K 2>/dev/null
	stamp a_kill
	echo "   leg a receiver killed (loop $L, tsp $K)"
	sleep $((SECS - 40))
	;;
kill-b)
	sleep $((40 - T))
	if [ "$LEGB" = seg ]; then
		# shellcheck disable=SC2046
		kill -KILL $(cat "$OUT"/b-*.pid 2>/dev/null) 2>/dev/null
	else
		kill -KILL "$BPID" 2>/dev/null
	fi
	stamp b_kill
	echo "   leg b killed (the export, or the receivers)"
	sleep $((SECS - 40))
	;;
sender)
	sleep $((40 - T))
	K=$(kids "$(cat "$OUT/a-send.pid" 2>/dev/null)")
	# shellcheck disable=SC2086
	kill -KILL $K 2>/dev/null
	stamp a_sender_kill
	echo "   leg a sender killed (tsp $K); its loop restarts it"
	sleep $((SECS - 40))
	;;
relay)
	sleep $((40 - T))
	if [ "$LEGB" = seg ]; then
		K=""
		for v in std epoch; do K="$K $(kids "$(cat "$OUT/pkg-$v.pid" 2>/dev/null)")"; done
		# shellcheck disable=SC2086
		kill -KILL $K 2>/dev/null
		stamp pkg_kill
		echo "   packagers killed (tsp$K); their loops restart them"
		sleep $((SECS - 40))
	else
		kill -KILL "$RELAYPID" 2>/dev/null
		stamp relay_kill
		sleep 1
		start_relay
		stamp relay_start
		echo "   relay restarted"
		sleep $((SECS - 41))
	fi
	;;
*)
	sleep $((SECS - T))
	;;
esac

cleanup
trap - EXIT
chown -R "${SUDO_USER:-root}": "$OUT" 2>/dev/null
grep -i "dropped by kernel" "$OUT/tcpdump.log" | sed 's/^/   tcpdump: /'
echo "=== $(date -u) done: $OUT ==="
echo "grade (as the user; with LEGB=seg, once per leg-b port: 5200 dropped, 5300 t61's, 5400 as packaged):"
cat <<EOF
  cd $OUT
  python3 $H/t12-merge-oracle.py --pcap legs.pcap --leg-a-port 5100 --leg-b-port 5200 --k-ms 50 --out-prefix merged --json oracle.json
  python3 $H/ts-passthrough-identity.py ref.ts merged.seqmerge.ts --groomed --json identity.json
  tsp -I file merged.seqmerge.ts -P continuity -O drop
EOF

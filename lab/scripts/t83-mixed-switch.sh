#!/usr/bin/env bash
# T83 Part B: an SRT leg and a media-aware MoQ leg of one source into T80's switch (P1-at).
#
# One host, on loopback. The clip is paced to a UDP port and tapped with arrival times (live1);
# both legs read the tap as it grows:
#
#   leg a (SRT)    tsp -O srt --caller  ->  tsp -I srt --listener --multiple                -> FIFO a
#   leg b (MoQ)    moq import ts -> relay -> moq export ts --stitch --follow, supervised    -> FIFO b
#
#   LEGB=seg: leg b is the seg lane, t61-epochseg.py's 2 s slices behind a loopback HTTP origin, read
#   by b8-hls-recv.py held to each one's program date-time, paced by a stream-clocked mpegts-pacer
#   to stdout                                                                                  -> FIFO b
#
# t80-vswitch.py reads both FIFOs in T80's lookback mode (202 ms of video silence, 2,000 ms held),
# and one groomer (mpegts-pacer --rtp) sends its output to a recorder. LEGA=moq makes leg a a second
# media-aware leg with its own importer and relay: the same-plane control. Recorded with arrival
# times (t56-stamp.py): each leg as the switch reads it (la, lb), the switch's output (sw) and the
# recorder's (sub1). The SRT ends and the export run under loops that restart them 1 s after they
# exit. Events, and the switch's decisions, go to events.txt; an importer's start is `imp<leg>_start`,
# which t56-grade.py does not grade (a fault's return is `arrive_<leg>`, graded with --arrive).
#
# Cells (CELL=): none; outage (the serving leg's UDP dropped both ways from KILL_AT for BACK s);
# kill (the serving leg's source side SIGKILLed at KILL_AT and restarted BACK s later: the SRT
# sender, or the importer); cut (commanded cuts, a -> b at KILL_AT and b -> a BACK s later). With
# LEGB=seg, leg b's outage drops the origin's TCP port and its kill is the packager's.
# SERVE=a|b picks the leg the switch serves first, so a fault strikes the leg it names.
#
#   CELL=outage SERVE=a BIN=<moq dir> PACER=<mpegts-pacer> SRC=<ts> t83-mixed-switch.sh <label>
#
# The SRT sender reads a pipe, so tsp withholds its initial load (half its 16 MB buffer, about 7 s
# of this clip) and sends it as one burst; the groomer primes on it and sheds the excess at its 5 %
# servo limit for the rest of the run. SRT_INIT=<packets> sets that load (empty: TSDuck's default).
#
# Env: LEGA (srt | moq), SRT_LAT (ms, 1000), SRT_INIT (), IDLE (6), KILL_AT (30), BACK (15), SECS (75),
#      DELAY (2s), FOLLOW (10s), RATE (11000000), PORT (4810; leg a's relay, if MoQ, on PORT+1),
#      SRTPORT (9483), UDP (5810; the groomer on UDP+1), LEGB (moq | seg), HTTPPORT (18483), SEG_MS
#      (3000, the segmented leg's pacer cushion: T70's floor for 2 s slices held to their time),
#      OUT (/tmp/t83b).
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=moq-cli-flags.sh
. "$H/moq-cli-flags.sh"

LABEL=${1:?label}
CELL=${CELL:-none}
SERVE=${SERVE:-a}
LEGA=${LEGA:-srt}
SRT_LAT=${SRT_LAT:-1000}
SRT_INIT=${SRT_INIT:-}
BIN=${BIN:?set BIN to the moq binary dir}
PACER=${PACER:?set PACER to the mpegts-pacer binary}
SRC=${SRC:?set SRC to the source clip}
IDLE=${IDLE:-6}
KILL_AT=${KILL_AT:-30}
BACK=${BACK:-15}
SECS=${SECS:-75}
DELAY=${DELAY:-2s}
FOLLOW=${FOLLOW:-10s}
RATE=${RATE:-11000000}
PORT=${PORT:-4810}
SRTPORT=${SRTPORT:-9483}
UDP=${UDP:-5810}
LEGB=${LEGB:-moq}
HTTPPORT=${HTTPPORT:-18483}
SEG_MS=${SEG_MS:-3000}
OUT=${OUT:-/tmp/t83b}/$LABEL
BC=t83b.$CELL.$$

case $CELL in none | outage | kill | cut) ;; *)
	echo "CELL must be none, outage, kill or cut" >&2
	exit 1
	;;
esac
case $SERVE in a | b) ;; *)
	echo "SERVE must be a or b" >&2
	exit 1
	;;
esac
case $LEGA in srt | moq) ;; *)
	echo "LEGA must be srt or moq" >&2
	exit 1
	;;
esac
case $LEGB in moq | seg) ;; *)
	echo "LEGB must be moq or seg" >&2
	exit 1
	;;
esac
[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo): iptables" >&2
	exit 1
}
for f in "$BIN/moq" "$BIN/moq-relay" "$PACER" "$SRC"; do [ -e "$f" ] || {
	echo "missing $f" >&2
	exit 1
}; done
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"
KEEP=$(python3 -c "print(f'{$IDLE / 3:g}s')")
QUIC=(--quic-idle-timeout "${IDLE}s" --quic-keep-alive "$KEEP")
EXP=(export ts --stitch --follow "$FOLLOW" --delay "$DELAY")
GSW=(--silence-ms 202 --lookback-ms 2000)
GROOM=(--rtp --latency-ms 1000 --max-latency-ms 8000 --stall-ms 1000 --on-stall mute --stats-interval-ms 1000)

rm -rf "$OUT"
mkdir -p "$OUT"
set -m
PIDS=()
DARK=()
now() { python3 -c 'import time; print(f"{time.time():.6f}")'; }
stamp() { echo "$1 $(now)" >>"$OUT/events.txt"; }
light() { # <port> [protocol, udp]
	iptables -D OUTPUT -o lo -p "${2:-udp}" --sport "$1" -j DROP 2>/dev/null
	iptables -D OUTPUT -o lo -p "${2:-udp}" --dport "$1" -j DROP 2>/dev/null
}
cleanup() {
	for p in ${DARK+"${DARK[@]}"}; do light "${p%/*}" "${p#*/}"; done
	for p in ${PIDS+"${PIDS[@]}"}; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
	sleep 1
	for p in ${PIDS+"${PIDS[@]}"}; do kill -KILL -- "-$p" 2>/dev/null; done
	pkill -f "[t]ail -c 0 -f $OUT/" 2>/dev/null
	wait 2>/dev/null
}
trap cleanup EXIT

{
	echo "=== $(date -u +%FT%TZ) t83-mixed-switch $LABEL: cell $CELL, serving $SERVE first, leg a $LEGA"
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	head -2 "$BIN.sha" 2>/dev/null || echo "sha: no sidecar for $BIN"
	echo "pacer $("$PACER" --version 2>&1 | head -1); sha256 $(sha256sum "$PACER" | cut -c1-12)"
	echo "t80-vswitch.py sha256 $(sha256sum "$H/t80-vswitch.py" | cut -c1-12)"
	tsp --version 2>&1 | head -1
	echo "src $SRC; leg a $LEGA$([ "$LEGA" = srt ] && echo " --latency $SRT_LAT, sender initial load ${SRT_INIT:-default}"); idle ${IDLE}s; export: ${EXP[*]}"
	[ "$LEGB" = seg ] && echo "leg b segmented: t61-epochseg.py --duration 2 --pdt (sha256 $(sha256sum "$H/t61-epochseg.py" | cut -c1-12)), origin :$HTTPPORT; b8-hls-recv.py --release-ms 1500 (sha256 $(sha256sum "$H/b8-hls-recv.py" | cut -c1-12)); pacer --stream-clock --latency-ms $SEG_MS"
	echo "switch ${GSW[*]}; groomer $RATE ${GROOM[*]}; fault at ${KILL_AT}s, back ${BACK}s later; ${SECS}s"
} | tee "$OUT/build.txt"

declare -A IMPPID RPORT=([a]=$((PORT + 1)) [b]=$PORT)
relay() { # <a|b>
	moq_relay_public "127.0.0.1:${RPORT[$1]}" localhost "${QUIC[@]}" --log-level info
	"$BIN/moq-relay" "${RELAY_ARGV[@]}" >>"$OUT/relay$1.log" 2>&1 &
	PIDS+=("$!")
}
[ "$LEGB" = moq ] && relay b
[ "$LEGA" = moq ] && relay a

tsp --max-flushed-packets 7 -I ip "$UDP" -O file - 2>>"$OUT/tsp-live.log" | python3 "$H/t56-stamp.py" "$OUT/live1" &
PIDS+=("$!")
tsp -I ip "$((UDP + 1))" -O file - 2>>"$OUT/tsp-rec.log" | python3 "$H/t56-stamp.py" "$OUT/sub1" &
PIDS+=("$!")
sleep 1
tsp -I file "$SRC" -P regulate --pcr-synchronous -O ip "127.0.0.1:$UDP" 2>>"$OUT/tsp-src.log" &
PIDS+=("$!")
sleep 0.5

importer() { # <a|b>
	tail -c 0 -f "$OUT/live1.ts" |
		"$BIN/moq" "${MOQ_DIAL[@]}" "https://127.0.0.1:${RPORT[$1]}/anon" "${QUIC[@]}" \
			--broadcast "$BC.$1" import ts >>"$OUT/import$1.log" 2>&1 &
	IMPPID[$1]=$!
	PIDS+=("$!")
	stamp "imp$1_start"
}
srt_sender() {
	bash -c "echo \$\$ >'$OUT/a-send.pid'; while :; do tail -c 0 -f '$OUT/live1.ts' | tsp ${SRT_INIT:+--initial-input-packets $SRT_INIT} -I file - -O srt --caller 127.0.0.1:$SRTPORT --latency $SRT_LAT 2>>'$OUT/srt-send.log'; echo \"srt_send_exit \$(date +%s.%N)\" >>'$OUT/events.txt'; sleep 1; done" \
		>/dev/null 2>&1 </dev/null &
	PIDS+=("$!")
	stamp srt_send_start
}
# The segmented leg's packager, the seg lane's: t61-epochseg.py's segmenter on the tap, 2 s slices
# with a program date-time, named by content time.
packager() {
	mkdir -p "$OUT/hls"
	bash -c "tail -c 0 -f '$OUT/live1.ts' | python3 '$H/t65-epochseg-stdin.py' '$OUT/hls' --duration 2 --pdt 2>>'$OUT/pkg.log'" \
		>/dev/null 2>&1 </dev/null &
	PKGPID=$!
	PIDS+=("$!")
	stamp pkg_start
}
origin() {
	mkdir -p "$OUT/hls"
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
}

rm -f "$OUT/a.fifo" "$OUT/b.fifo"
mkfifo "$OUT/a.fifo" "$OUT/b.fifo"
exec 7<>"$OUT/a.fifo" 8<>"$OUT/b.fifo"
if [ "$SERVE" = a ]; then IN=("$OUT/a.fifo" "$OUT/b.fifo"); else IN=("$OUT/b.fifo" "$OUT/a.fifo"); fi
python3 "$H/t80-vswitch.py" "${IN[@]}" --events "$OUT/events.txt" "${GSW[@]}" 2>>"$OUT/vswitch.log" |
	tee >(python3 "$H/t56-stamp.py" "$OUT/sw") |
	"$PACER" "127.0.0.1:$((UDP + 1))" "$RATE" "${GROOM[@]}" --ssrc 1083 2>>"$OUT/pacer.log" &
PIDS+=("$!")
sleep 0.5
SWPID=$(pgrep -n -f "t80-vswitch.py $OUT/")

# A leg's output: a loop that restarts its last stage, recorded as the switch reads it.
leg_out() { # <a|b> <command...>
	local l=$1
	shift
	(
		while :; do
			"$@"
			echo "${l}_exit_$? $(now)" >>"$OUT/events.txt"
			sleep 1
		done | tee >(python3 "$H/t56-stamp.py" "$OUT/l$l") >"$OUT/$l.fifo"
	) &
	PIDS+=("$!")
	stamp "leg${l}_start"
}

if [ "$LEGB" = seg ]; then
	origin
	packager
else
	importer b
fi
if [ "$LEGA" = moq ]; then
	importer a
	leg_out a "$BIN/moq" "${MOQ_DIAL[@]}" "https://127.0.0.1:${RPORT[a]}/anon" "${QUIC[@]}" --broadcast "$BC.a" "${EXP[@]}"
else
	leg_out a tsp -I srt --listener "127.0.0.1:$SRTPORT" --latency "$SRT_LAT" --multiple -O file -
	srt_sender
fi
sleep 2
if [ "$LEGB" = seg ]; then
	# shellcheck disable=SC2016
	leg_out b bash -c 'python3 "$1" "$2" - --seconds 0 --edge 1 --poll 100 --release-ms 1500 --log "$3/b-recv.jsonl" 2>>"$3/b-recv.err" |
		"$4" stdout "$5" --stream-clock --latency-ms "$6" --max-latency-ms 14000 --stall-ms 1000 --on-stall mute \
			--stats-interval-ms 1000 2>>"$3/b-pacer.log"' _ \
		"$H/b8-hls-recv.py" "http://127.0.0.1:$HTTPPORT/index.m3u8" "$OUT" "$PACER" "$RATE" "$SEG_MS"
else
	leg_out b "$BIN/moq" "${MOQ_DIAL[@]}" "https://127.0.0.1:${RPORT[b]}/anon" "${QUIC[@]}" --broadcast "$BC.b" "${EXP[@]}"
fi
sleep 4

# The serving leg's port: the SRT port, its relay's (the importer's and the export's flows both), or
# the segmented leg's origin (TCP).
fault_port() {
	if [ "$SERVE" = a ] && [ "$LEGA" = srt ]; then
		echo "$SRTPORT"
	elif [ "$SERVE" = b ] && [ "$LEGB" = seg ]; then
		echo "$HTTPPORT"
	else
		echo "${RPORT[$SERVE]}"
	fi
}
fault_proto() { if [ "$SERVE" = b ] && [ "$LEGB" = seg ]; then echo tcp; else echo udp; fi; }
for ((t = 8; t <= SECS; t++)); do
	sleep 1
	if [ "$t" -eq "$KILL_AT" ]; then
		case $CELL in
		outage)
			p=$(fault_port) pr=$(fault_proto)
			iptables -I OUTPUT -o lo -p "$pr" --sport "$p" -j DROP
			iptables -I OUTPUT -o lo -p "$pr" --dport "$p" -j DROP
			DARK+=("$p/$pr")
			stamp "outage_$SERVE"
			;;
		kill)
			if [ "$SERVE" = a ] && [ "$LEGA" = srt ]; then
				L=$(cat "$OUT/a-send.pid")
				# shellcheck disable=SC2046
				kill -KILL "$L" $(pgrep -P "$L") $(pgrep -f "[t]sp -I file - -O srt --caller 127.0.0.1:$SRTPORT") 2>/dev/null
			elif [ "$SERVE" = b ] && [ "$LEGB" = seg ]; then
				kill -KILL -- "-$PKGPID" 2>/dev/null
			else
				kill -KILL "${IMPPID[$SERVE]}" 2>/dev/null
			fi
			stamp "kill_$SERVE"
			;;
		cut) kill -USR1 "$SWPID" ;;
		none) ;;
		esac
	fi
	if [ "$t" -eq $((KILL_AT + BACK)) ]; then
		case $CELL in
		outage)
			light "$(fault_port)" "$(fault_proto)"
			stamp "light_$SERVE"
			;;
		kill)
			if [ "$SERVE" = a ] && [ "$LEGA" = srt ]; then
				srt_sender
			elif [ "$SERVE" = b ] && [ "$LEGB" = seg ]; then
				packager
			else
				importer "$SERVE"
			fi
			stamp "arrive_$SERVE"
			;;
		cut) kill -USR1 "$SWPID" ;;
		none) ;;
		esac
	fi
done
stamp end
cleanup
trap - EXIT
chown -R "${SUDO_USER:-root}": "$OUT" 2>/dev/null
echo "events:"
cat "$OUT/events.txt"
cat <<EOF
grade (as the user):
  python3 $H/t56-grade.py $OUT --ref $SRC --caps sub1 --arrive
  python3 $H/t83-leg-lag.py $OUT/la $OUT/lb
  python3 $H/t83-tables.py $OUT/sw --source $OUT/live1 --vswitch-log $OUT/vswitch.log
EOF

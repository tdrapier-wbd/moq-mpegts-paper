#!/usr/bin/env bash
# T83 Part B: an SRT leg and a media-aware MoQ leg of one source into T80's switch (P1-at).
#
# One host, on loopback. The clip is paced to a UDP port and tapped with arrival times (live1);
# both legs read the tap as it grows:
#
#   leg a (SRT)    tsp -O srt --caller  ->  tsp -I srt --listener --multiple                -> FIFO a
#   leg b (MoQ)    moq import ts -> relay -> moq export ts --stitch --follow, supervised    -> FIFO b
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
# sender, or the importer); cut (commanded cuts, a -> b at KILL_AT and b -> a BACK s later).
# SERVE=a|b picks the leg the switch serves first, so a fault strikes the leg it names.
#
#   CELL=outage SERVE=a BIN=<moq dir> PACER=<mpegts-pacer> SRC=<ts> t83-mixed-switch.sh <label>
#
# Env: LEGA (srt | moq), SRT_LAT (ms, 1000), IDLE (6), KILL_AT (30), BACK (15), SECS (75),
#      DELAY (2s), FOLLOW (10s), RATE (11000000), PORT (4810; leg a's relay, if MoQ, on PORT+1),
#      SRTPORT (9483), UDP (5810; the groomer on UDP+1), OUT (/tmp/t83b).
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=moq-cli-flags.sh
. "$H/moq-cli-flags.sh"

LABEL=${1:?label}
CELL=${CELL:-none}
SERVE=${SERVE:-a}
LEGA=${LEGA:-srt}
SRT_LAT=${SRT_LAT:-1000}
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
light() {
	iptables -D OUTPUT -o lo -p udp --sport "$1" -j DROP 2>/dev/null
	iptables -D OUTPUT -o lo -p udp --dport "$1" -j DROP 2>/dev/null
}
cleanup() {
	for p in ${DARK+"${DARK[@]}"}; do light "$p"; done
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
	echo "src $SRC; leg a $LEGA$([ "$LEGA" = srt ] && echo " --latency $SRT_LAT"); idle ${IDLE}s; export: ${EXP[*]}"
	echo "switch ${GSW[*]}; groomer $RATE ${GROOM[*]}; fault at ${KILL_AT}s, back ${BACK}s later; ${SECS}s"
} | tee "$OUT/build.txt"

declare -A IMPPID RPORT=([a]=$((PORT + 1)) [b]=$PORT)
relay() { # <a|b>
	moq_relay_public "127.0.0.1:${RPORT[$1]}" localhost "${QUIC[@]}" --log-level info
	"$BIN/moq-relay" "${RELAY_ARGV[@]}" >>"$OUT/relay$1.log" 2>&1 &
	PIDS+=("$!")
}
relay b
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
	bash -c "echo \$\$ >'$OUT/a-send.pid'; while :; do tail -c 0 -f '$OUT/live1.ts' | tsp -I file - -O srt --caller 127.0.0.1:$SRTPORT --latency $SRT_LAT 2>>'$OUT/srt-send.log'; echo \"srt_send_exit \$(date +%s.%N)\" >>'$OUT/events.txt'; sleep 1; done" \
		>/dev/null 2>&1 </dev/null &
	PIDS+=("$!")
	stamp srt_send_start
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

importer b
if [ "$LEGA" = moq ]; then
	importer a
	leg_out a "$BIN/moq" "${MOQ_DIAL[@]}" "https://127.0.0.1:${RPORT[a]}/anon" "${QUIC[@]}" --broadcast "$BC.a" "${EXP[@]}"
else
	leg_out a tsp -I srt --listener "127.0.0.1:$SRTPORT" --latency "$SRT_LAT" --multiple -O file -
	srt_sender
fi
sleep 2
leg_out b "$BIN/moq" "${MOQ_DIAL[@]}" "https://127.0.0.1:${RPORT[b]}/anon" "${QUIC[@]}" --broadcast "$BC.b" "${EXP[@]}"
sleep 4

# The serving leg's UDP: the SRT port, or its relay's (the importer's and the export's flows both).
fault_port() { if [ "$SERVE" = a ] && [ "$LEGA" = srt ]; then echo "$SRTPORT"; else echo "${RPORT[$SERVE]}"; fi; }
for ((t = 8; t <= SECS; t++)); do
	sleep 1
	if [ "$t" -eq "$KILL_AT" ]; then
		case $CELL in
		outage)
			p=$(fault_port)
			iptables -I OUTPUT -o lo -p udp --sport "$p" -j DROP
			iptables -I OUTPUT -o lo -p udp --dport "$p" -j DROP
			DARK+=("$p")
			stamp "outage_$SERVE"
			;;
		kill)
			if [ "$SERVE" = a ] && [ "$LEGA" = srt ]; then
				L=$(cat "$OUT/a-send.pid")
				# shellcheck disable=SC2046
				kill -KILL "$L" $(pgrep -P "$L") $(pgrep -f "[t]sp -I file - -O srt --caller 127.0.0.1:$SRTPORT") 2>/dev/null
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
			light "$(fault_port)"
			stamp "light_$SERVE"
			;;
		kill)
			if [ "$SERVE" = a ] && [ "$LEGA" = srt ]; then srt_sender; else importer "$SERVE"; fi
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

#!/usr/bin/env bash
# T81: two edge gateways on the media-aware lane behind an IRD-model input switch
# (lab/test-81-gateway-failover.md).
#
# T58's two legs on loopback, each an importer, a relay and a broadcast of its own. Each of two
# gateways exports both legs (`export ts --stitch`, under a supervisor), switches them with
# t80-vswitch.py in T80's lookback mode, and grooms the result with mpegts-pacer to RTP on its own
# UDP port. An IRD model reads both groomers' RTP and writes one: tsswitch cutting on absence
# (IRD=tsswitch), or t80-vswitch.py in rap mode through `tsp -I ip` (IRD=rap). Importer A starts at
# 0 s, gateway 1's exports at 2 s (A) and 7 s (B), gateway 2's at 3 s and 8 s, importer B at 8 s,
# the IRD model at IRD_AT s on gateway 1. At KILL_AT the rig fails one thing and restores it BACK s
# later. Recorded with arrival times (t56-stamp.py): the IRD model's output (sub1) and each
# gateway's switch output before its groomer (gw1, gw2; gw1r after gateway 1's restart). Events go
# to events.txt as `<name> <unix seconds>`; each gateway's own switch decisions to gw<N>.events.
#
# Cells (CELL=): gw (gateway 1 killed whole, restarted), leg (importer A SIGKILLed, restarted),
# none (no fault).
#
#   CELL=gw IRD=tsswitch BIN=<moq dir> PACER=<mpegts-pacer> SRC=<ts> t81-gateway-failover.sh <label>
#
# Env: RT (500: tsswitch receive timeout, ms), IDLE (6), KILL_AT (30), BACK (15), SECS (75),
#      IRD_AT (14), DELAY (2s), FOLLOW (10s), RATE (11000000: the groomers' bit/s), PORT (4710; leg
#      B's relay on PORT+1), UDP (5710: the live source; the groomers on UDP+1, UDP+2), OUT (/tmp/t81).
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=moq-cli-flags.sh
. "$H/moq-cli-flags.sh"

LABEL=${1:?label}
CELL=${CELL:-gw}
IRD=${IRD:-tsswitch}
RT=${RT:-500}
BIN=${BIN:?set BIN to the moq binary dir}
PACER=${PACER:?set PACER to the mpegts-pacer binary}
SRC=${SRC:?set SRC to the source clip}
IDLE=${IDLE:-6}
KILL_AT=${KILL_AT:-30}
BACK=${BACK:-15}
SECS=${SECS:-75}
IRD_AT=${IRD_AT:-14}
DELAY=${DELAY:-2s}
FOLLOW=${FOLLOW:-10s}
RATE=${RATE:-11000000}
PORT=${PORT:-4710}
UDP=${UDP:-5710}
OUT=${OUT:-/tmp/t81}/$LABEL
BC=t81.$CELL.$$

case $CELL in
gw | leg | none) ;;
*)
	echo "CELL must be gw, leg or none" >&2
	exit 1
	;;
esac
case $IRD in
tsswitch | rap) ;;
*)
	echo "IRD must be tsswitch or rap" >&2
	exit 1
	;;
esac
for c in tsswitch tsp; do command -v "$c" >/dev/null || {
	echo "$c (TSDuck) not found" >&2
	exit 1
}; done
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
PLOG=info,moq_net::lite::publisher=debug,moq_net::ietf::publisher=debug

rm -rf "$OUT"
mkdir -p "$OUT"
set -m
PIDS=()
now() { python3 -c 'import time; print(f"{time.time():.6f}")'; }
stamp() { echo "$1 $(now)" >>"$OUT/events.txt"; }
cleanup() {
	for p in ${PIDS+"${PIDS[@]}"}; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
	sleep 1
	for p in ${PIDS+"${PIDS[@]}"}; do kill -KILL -- "-$p" 2>/dev/null; done
	pkill -f "[t]ail -c 0 -f $OUT/" 2>/dev/null
	wait 2>/dev/null
}
trap cleanup EXIT

{
	echo "=== $(date -u +%FT%TZ) t81-gateway-failover $LABEL: cell $CELL, IRD $IRD"
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	head -2 "$BIN.sha" 2>/dev/null || echo "sha: no sidecar for $BIN"
	echo "pacer $("$PACER" --version 2>&1 | head -1); sha256 $(shasum -a 256 "$PACER" | cut -c1-12)"
	echo "t80-vswitch.py sha256 $(shasum -a 256 "$H/t80-vswitch.py" | cut -c1-12)"
	tsswitch --version 2>&1 | head -1
	echo "src $SRC; idle ${IDLE}s keep-alive $KEEP; export: ${EXP[*]}"
	echo "gateway switch ${GSW[*]}; groomer $RATE ${GROOM[*]}"
	echo "IRD $IRD from ${IRD_AT}s$([ "$IRD" = tsswitch ] && echo ", --fast-switch --receive-timeout $RT")"
	echo "fault at ${KILL_AT}s, back ${BACK}s later; ${SECS}s"
} | tee "$OUT/build.txt"

declare -A RELAYPID IMPPID GWPID LEGPORT=([A]=$PORT [B]=$((PORT + 1)))
relay() { # <A|B>
	moq_relay_public "127.0.0.1:${LEGPORT[$1]}" localhost "${QUIC[@]}" --log-level info
	"$BIN/moq-relay" "${RELAY_ARGV[@]}" >>"$OUT/relay$1.log" 2>&1 &
	RELAYPID[$1]=$!
	PIDS+=("$!")
}
relay A
relay B
sleep 2

: >"$OUT/live1.ts"
tsp --max-flushed-packets 7 -I ip "$UDP" -O file "$OUT/live1.ts" 2>>"$OUT/tsp-live.log" &
PIDS+=("$!")
tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O ip "127.0.0.1:$UDP" 2>>"$OUT/tsp-src.log" &
PIDS+=("$!")
sleep 0.5

importer() { # <A|B>
	tail -c 0 -f "$OUT/live1.ts" |
		RUST_LOG=$PLOG "$BIN/moq" "${MOQ_DIAL[@]}" "https://127.0.0.1:${LEGPORT[$1]}/anon" "${QUIC[@]}" \
			--broadcast "$BC.$1" import ts >>"$OUT/import$1.log" 2>&1 &
	IMPPID[$1]=$!
	PIDS+=("$!")
	stamp "import$1_start"
}

# One gateway, in one process group so that a kill takes all of it: an export of each leg under a
# supervisor, into a FIFO each, read by the gateway's switch, groomed to RTP on UDP+<N>.
gw_export() { # <N> <A|B> <delay before the first start, s>
	sleep "$3"
	local first=g$1export$2_start
	while :; do
		echo "$first $(now)" >>"$OUT/events.txt"
		first=g$1rearm$2
		"$BIN/moq" "${MOQ_DIAL[@]}" "https://127.0.0.1:${LEGPORT[$2]}/anon" "${QUIC[@]}" \
			--broadcast "$BC.$2" "${EXP[@]}" 2>>"$OUT/g$1export$2.log"
		echo "g$1export$2_exit_$? $(now)" >>"$OUT/events.txt"
		sleep 1
	done >"$OUT/g$1.$2.fifo"
}
gateway() { # <N> <capture> <delay of its leg-A export, s> <of its leg-B export, s>
	local n=$1
	rm -f "$OUT/g$n.A.fifo" "$OUT/g$n.B.fifo"
	mkfifo "$OUT/g$n.A.fifo" "$OUT/g$n.B.fifo"
	(
		set +m
		exec 7<>"$OUT/g$n.A.fifo" 8<>"$OUT/g$n.B.fifo"
		gw_export "$n" A "$3" &
		gw_export "$n" B "$4" &
		python3 "$H/t80-vswitch.py" "$OUT/g$n.A.fifo" "$OUT/g$n.B.fifo" --events "$OUT/gw$n.events" "${GSW[@]}" \
			2>>"$OUT/vswitch$n.log" |
			tee >(python3 "$H/t56-stamp.py" "$OUT/$2") |
			"$PACER" "127.0.0.1:$((UDP + n))" "$RATE" "${GROOM[@]}" --ssrc $((1000 + n)) 2>>"$OUT/pacer$n.log"
	) &
	GWPID[$n]=$!
	PIDS+=("$!")
}

# The IRD model: two RTP inputs, gateway 1 first.
ird() {
	stamp ird_start
	if [ "$IRD" = tsswitch ]; then
		tsswitch --fast-switch --receive-timeout "$RT" --event-command "sh $H/t58-event.sh $OUT/events.txt" \
			-I ip "$((UDP + 1))" -I ip "$((UDP + 2))" -O file 2>>"$OUT/ird.log" |
			python3 "$H/t56-stamp.py" "$OUT/sub1" &
		PIDS+=("$!")
	else
		mkfifo "$OUT/ird0.fifo" "$OUT/ird1.fifo"
		exec 5<>"$OUT/ird0.fifo" 6<>"$OUT/ird1.fifo"
		for i in 0 1; do
			tsp -I ip "$((UDP + 1 + i))" -O file "$OUT/ird$i.fifo" 2>>"$OUT/ird-rx$i.log" &
			PIDS+=("$!")
		done
		python3 "$H/t80-vswitch.py" "$OUT/ird0.fifo" "$OUT/ird1.fifo" --events "$OUT/events.txt" \
			--silence-ms 200 --lookback-ms 0 2>>"$OUT/ird.log" | python3 "$H/t56-stamp.py" "$OUT/sub1" &
		PIDS+=("$!")
	fi
}

importer A
gateway 1 gw1 2 7
gateway 2 gw2 3 8
for ((t = 1; t <= SECS; t++)); do
	sleep 1
	[ "$t" -eq 8 ] && importer B
	[ "$t" -eq "$IRD_AT" ] && ird
	if [ "$t" -eq "$KILL_AT" ]; then
		case $CELL in
		gw) kill -KILL -- "-${GWPID[1]}" && stamp killgw1 ;;
		leg) kill -KILL "${IMPPID[A]}" && stamp killimportA ;;
		none) ;;
		esac
	fi
	if [ "$t" -eq $((KILL_AT + BACK)) ]; then
		case $CELL in
		gw) gateway 1 gw1r 0 0 && stamp arrivegw1 ;;
		leg) importer A ;;
		esac
	fi
done
stamp end
echo "events:"
cat "$OUT/events.txt"
echo "grade: python3 $H/t56-grade.py $OUT --ref $SRC --caps sub1,gw2 --arrive"

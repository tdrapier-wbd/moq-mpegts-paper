#!/usr/bin/env bash
# T58: 1+1 on the media-aware lane, selected at the receiver (lab/test-58-receiver-select.md).
#
# Two legs on loopback, each an importer, a relay and a broadcast of its own, and an export under a
# supervisor that restarts it when it exits. TSDuck's tsswitch reads both exports (--fast-switch,
# input 0 leg A, input 1 leg B) and writes the switched output. Every leg starts apart: importer A
# at 0 s, export A at 2 s, export B at 7 s, importer B at 8 s. The switched output (sub1) and each
# leg's export (sub2 for A, sub3 for B) are recorded with arrival times (t56-stamp.py). Events, and
# each tsswitch switch (t58-event.sh), go to events.txt as `<name> <unix seconds>`. At KILL_AT the
# rig fails one component of the leg tsswitch serves and restarts it BACK s later; an export
# restarts at once under its supervisor. Graded events: the fault, the standby's first start, and
# each restart (`import*` after the first event, and `arrive*`).
#
# Cells (CELL=): kill | term (the importer), relay (SIGKILL the leg's relay), egress (SIGKILL its
# export), outage (drop the importer's QUIC flow both ways on loopback for OUTAGE_S s, and any
# socket it opens meanwhile; nothing restarted; Linux, root, as T56's outage cell).
# MODE=nonrevertive (--receive-timeout RT) | revertive (and --primary-input 0).
# SRC2 set: importer B reads SRC2, a separate encode of the programme, started with SRC.
#
#   CELL=kill MODE=nonrevertive RT=500 BIN=<moq dir> SRC=<ts> t58-receiver-select.sh <label>
#
# Env: RT (500: tsswitch receive timeout, ms), IDLE (6: QUIC idle timeout in s, keep-alive a third),
#      KILL_AT (30), BACK (15), SECS (75), DELAY (2s), FOLLOW (10s), SRC2, PORT (4610; leg B's relay
#      on PORT+1), UDP (5610), OUT (/tmp/t58), RETRY (the importers' --connect-backoff-timeout;
#      unset, the CLI's 10 s, which a relay down BACK=15 s outlasts; 0s retries forever),
#      OUTAGE_S (IDLE; may be fractional).
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=moq-cli-flags.sh
. "$H/moq-cli-flags.sh"

LABEL=${1:?label}
CELL=${CELL:-kill}
MODE=${MODE:-nonrevertive}
RT=${RT:-500}
BIN=${BIN:?set BIN to the moq binary dir}
SRC=${SRC:?set SRC to the source clip}
SRC2=${SRC2:-}
IDLE=${IDLE:-6}
KILL_AT=${KILL_AT:-30}
BACK=${BACK:-15}
SECS=${SECS:-75}
DELAY=${DELAY:-2s}
FOLLOW=${FOLLOW:-10s}
PORT=${PORT:-4610}
UDP=${UDP:-5610}
OUT=${OUT:-/tmp/t58}/$LABEL
RETRY=${RETRY:-}
OUTAGE_S=${OUTAGE_S:-$IDLE}
IMP=()
[ -n "$RETRY" ] && IMP=(--connect-backoff-timeout "$RETRY")
BC=t58.$CELL.$$

case $CELL in
kill | term | relay | egress) ;;
outage)
	[ "$(uname)" = Linux ] && [ "$(id -u)" -eq 0 ] || {
		echo "outage needs Linux and root (iptables)" >&2
		exit 1
	}
	;;
*)
	echo "CELL must be kill, term, relay, egress or outage" >&2
	exit 1
	;;
esac
SWITCH=(--fast-switch --receive-timeout "$RT")
case $MODE in
nonrevertive) ;;
revertive) SWITCH+=(--primary-input 0) ;;
*)
	echo "MODE must be nonrevertive or revertive" >&2
	exit 1
	;;
esac
for f in "$BIN/moq" "$BIN/moq-relay" "$SRC" ${SRC2:+"$SRC2"}; do [ -e "$f" ] || {
	echo "missing $f" >&2
	exit 1
}; done
command -v tsswitch >/dev/null || {
	echo "tsswitch (TSDuck) not found" >&2
	exit 1
}
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"
KEEP=$(python3 -c "print(f'{$IDLE / 3:g}s')")
QUIC=(--quic-idle-timeout "${IDLE}s" --quic-keep-alive "$KEEP")
EXP=(export ts --stitch --follow "$FOLLOW" --delay "$DELAY")
PLOG=info,moq_net::lite::publisher=debug,moq_net::ietf::publisher=debug

rm -rf "$OUT"
mkdir -p "$OUT"
set -m
PIDS=()
now() { python3 -c 'import time; print(f"{time.time():.6f}")'; }
stamp() { echo "$1 $(now)" >>"$OUT/events.txt"; }
dark() { # <port>: drop it both ways on loopback, once
	grep -qx "$1" "$OUT/dark.ports" 2>/dev/null && return 0
	iptables -I OUTPUT -o lo -p udp --sport "$1" -j DROP
	iptables -I OUTPUT -o lo -p udp --dport "$1" -j DROP
	echo "$1" >>"$OUT/dark.ports"
}
light() {
	iptables -D OUTPUT -o lo -p udp --sport "$1" -j DROP 2>/dev/null
	iptables -D OUTPUT -o lo -p udp --dport "$1" -j DROP 2>/dev/null
}
ports_of() { # <pid>: its UDP ports
	ss -H -uanp 2>/dev/null | awk -v p="pid=$1," 'index($0, p) { n = split($4, a, ":"); print a[n] }' | sort -u
}
cleanup() {
	[ -f "$OUT/dark.ports" ] && while read -r p; do light "$p"; done <"$OUT/dark.ports"
	for p in ${PIDS+"${PIDS[@]}"}; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
	sleep 1
	for p in ${PIDS+"${PIDS[@]}"}; do kill -KILL -- "-$p" 2>/dev/null; done
	pkill -f "[t]ail -c 0 -f $OUT/" 2>/dev/null
	wait 2>/dev/null
}
trap cleanup EXIT

{
	echo "=== $(date -u +%FT%TZ) t58-receiver-select $LABEL: cell $CELL, mode $MODE, receive timeout ${RT} ms"
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	head -2 "$BIN.sha" 2>/dev/null || echo "sha: no sidecar for $BIN"
	tsswitch --version 2>&1 | head -1
	echo "src $SRC${SRC2:+; importer B reads $SRC2}; idle ${IDLE}s keep-alive $KEEP"
	echo "fault at ${KILL_AT}s, back ${BACK}s later; ${SECS}s; export: ${EXP[*]}; tsswitch ${SWITCH[*]}"
	echo "importer retry: ${RETRY:-CLI default}"
	[ "$CELL" = outage ] && echo "outage ${OUTAGE_S}s"
} | tee "$OUT/build.txt"

declare -A RELAYPID IMPPID LEGPORT=([A]=$PORT [B]=$((PORT + 1)))
relay() { # <A|B>
	moq_relay_public "127.0.0.1:${LEGPORT[$1]}" localhost "${QUIC[@]}" --log-level info
	"$BIN/moq-relay" "${RELAY_ARGV[@]}" >>"$OUT/relay$1.log" 2>&1 &
	RELAYPID[$1]=$!
	PIDS+=("$!")
}
relay A
relay B
sleep 2

# The live sources, as T56 plays them: each importer follows its file from its own start.
live() { # <clip> <udp port> <file>
	: >"$OUT/$3"
	tsp --max-flushed-packets 7 -I ip "$2" -O file "$OUT/$3" 2>>"$OUT/tsp-live.log" &
	PIDS+=("$!")
	tsp -I file "$1" --infinite -P regulate --pcr-synchronous -O ip "127.0.0.1:$2" 2>>"$OUT/tsp-src.log" &
	PIDS+=("$!")
}
live "$SRC" "$UDP" live1.ts
B_FILE=live1.ts
[ -n "$SRC2" ] && live "$SRC2" $((UDP + 1)) live2.ts && B_FILE=live2.ts
sleep 0.5

importer() { # <A|B> <live file>
	tail -c 0 -f "$OUT/$2" |
		RUST_LOG=$PLOG "$BIN/moq" "${MOQ_DIAL[@]}" "https://127.0.0.1:${LEGPORT[$1]}/anon" "${QUIC[@]}" \
			${IMP+"${IMP[@]}"} --broadcast "$BC.$1" import ts >>"$OUT/import$1.log" 2>&1 &
	IMPPID[$1]=$!
	PIDS+=("$!")
	stamp "import$1_start"
}

# Each leg's export writes to its FIFO, which tsswitch reads; the rig holds both open read-write so
# neither side blocks on the other's start.
mkfifo "$OUT/legA.fifo" "$OUT/legB.fifo"
exec 7<>"$OUT/legA.fifo" 8<>"$OUT/legB.fifo"
tsswitch "${SWITCH[@]}" --event-command "sh $H/t58-event.sh $OUT/events.txt" \
	-I file "$OUT/legA.fifo" -I file "$OUT/legB.fifo" -O file 2>>"$OUT/tsswitch.log" |
	python3 "$H/t56-stamp.py" "$OUT/sub1" &
PIDS+=("$!")

export_leg() { # <A|B> <capture>
	(
		first=export$1_start
		[ "$1" = B ] && first=arriveexportB
		while :; do
			echo "${first} $(now)" >>"$OUT/events.txt"
			first=arriveexport$1
			"$BIN/moq" "${MOQ_DIAL[@]}" "https://127.0.0.1:${LEGPORT[$1]}/anon" "${QUIC[@]}" \
				--broadcast "$BC.$1" "${EXP[@]}" 2>>"$OUT/export$1.log"
			echo "export$1_exit_$? $(now)" >>"$OUT/events.txt"
			sleep 1
		done | tee >(python3 "$H/t56-stamp.py" "$OUT/$2") >"$OUT/leg$1.fifo"
	) &
	PIDS+=("$!")
}

# The leg tsswitch serves: the input its last switch went to, or input 0 before any.
serving() {
	local last
	last=$(grep '^switch_' "$OUT/events.txt" | tail -n 1 | cut -d' ' -f1)
	[ "${last##*_}" = 1 ] && echo B || echo A
}

importer A live1.ts
sleep 2
export_leg A sub2
for ((t = 3; t <= SECS; t++)); do
	sleep 1
	[ "$t" -eq 7 ] && export_leg B sub3
	[ "$t" -eq 8 ] && importer B "$B_FILE"
	if [ "$t" -eq "$KILL_AT" ]; then
		V=$(serving)
		echo "victim leg $V" | tee -a "$OUT/build.txt"
		case $CELL in
		kill) kill -KILL "${IMPPID[$V]}" && stamp "killimport$V" ;;
		term) kill -TERM "${IMPPID[$V]}" && stamp "termimport$V" ;;
		relay) kill -KILL "${RELAYPID[$V]}" && stamp "killrelay$V" ;;
		egress) pkill -KILL -f -- "--broadcast $BC.$V export" && stamp "killexport$V" ;;
		outage)
			VP=${IMPPID[$V]}
			for p in $(ports_of "$VP"); do dark "$p"; done
			stamp "outage$V"
			(
				end=$((${EPOCHREALTIME/./} + $(python3 -c "print(round($OUTAGE_S * 1e6))")))
				while left=$((end - ${EPOCHREALTIME/./})) && [ "$left" -gt 0 ]; do
					for p in $(ports_of "$VP"); do dark "$p"; done
					if [ "$left" -gt 100000 ]; then sleep 0.1; else sleep "0.$(printf %06d "$left")"; fi
				done
				while read -r p; do light "$p"; done <"$OUT/dark.ports"
				stamp "light$V"
			) &
			PIDS+=("$!")
			;;
		esac
	fi
	if [ "$t" -eq $((KILL_AT + BACK)) ]; then
		F=live1.ts
		[ "$V" = B ] && F=$B_FILE
		case $CELL in
		kill | term) importer "$V" "$F" ;;
		relay) relay "$V" && stamp "arriverelay$V" ;;
		esac
	fi
done
stamp end
echo "events:"
cat "$OUT/events.txt"
echo "grade: python3 $H/t56-grade.py $OUT --ref $SRC --caps sub1,sub2,sub3 --arrive"

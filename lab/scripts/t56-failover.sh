#!/usr/bin/env bash
# T56: media-aware failover as a decoder sees it (lab/test-56-media-aware-failover.md).
#
# One relay on loopback, two importers of one broadcast and two exports, every leg started at its
# own time: importer A at 0 s and importer B STAGGER s later; export 1 at 2 s and export 2
# SUB_STAGGER s after it. Each export runs under a supervisor that restarts it when it exits, as a
# standing egress would, and its output is recorded with arrival times (t56-stamp.py) so the
# grader can place every picture and every gap on the clock. Events go to events.txt as
# `<name> <unix seconds>`; the importer serving at a fault is the one that logged more
# `serving group` lines over the 2 s before it.
#
# Cells (CELL=):
#   select   no fault: the grader splices the exports into each other, a receiver's input select;
#            importer B and a broadcast of its own for export 2 only with SRC2
#   kill     SIGKILL the serving importer at KILL_AT s; start it again BACK s later
#   term     SIGTERM it instead
#   outage   drop the serving importer's QUIC flow for OUTAGE_S s (Linux, root)
# SRC2 set: importer B reads SRC2, a separate encode of the programme, started with SRC.
#
#   CELL=kill BIN=<moq dir> SRC=<ts> t56-failover.sh <label>
#
# Env: IDLE (6: QUIC idle timeout in s, keep-alive a third of it, on every client and the relay),
#      STAGGER (8), SUB_STAGGER (5), KILL_AT (30), BACK (15), OUTAGE_S (IDLE; may be fractional), SECS (75),
#      DELAY (2s), FOLLOW (10s), LANE (demux | passthrough), VER (--connect-version for every
#      client; default negotiated), SRC2, PORT (4600), UDP (5600), OUT (/tmp/t56).
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=moq-cli-flags.sh
. "$H/moq-cli-flags.sh"

LABEL=${1:?label}
CELL=${CELL:-kill}
BIN=${BIN:?set BIN to the moq binary dir}
SRC=${SRC:?set SRC to the source clip}
SRC2=${SRC2:-}
IDLE=${IDLE:-6}
STAGGER=${STAGGER:-8}
SUB_STAGGER=${SUB_STAGGER:-5}
KILL_AT=${KILL_AT:-30}
BACK=${BACK:-15}
OUTAGE_S=${OUTAGE_S:-$IDLE}
SECS=${SECS:-75}
DELAY=${DELAY:-2s}
FOLLOW=${FOLLOW:-10s}
LANE=${LANE:-demux}
VER=${VER:-}
PORT=${PORT:-4600}
UDP=${UDP:-5600}
OUT=${OUT:-/tmp/t56}/$LABEL
BC=t56.$CELL.$$
URL=https://127.0.0.1:$PORT/anon

case $CELL in
select | kill | term) ;;
outage)
	[ "$(uname)" = Linux ] && [ "$(id -u)" -eq 0 ] || {
		echo "outage needs Linux and root (iptables)" >&2
		exit 1
	}
	;;
*)
	echo "CELL must be select, kill, term or outage" >&2
	exit 1
	;;
esac
case $LANE in
demux) IMP=(import ts) EXP=(export ts --stitch --follow "$FOLLOW" --delay "$DELAY") ;;
passthrough) IMP=(import ts --passthrough) EXP=(export ts --passthrough --delay "$DELAY") ;;
*)
	echo "LANE must be demux or passthrough" >&2
	exit 1
	;;
esac
for f in "$BIN/moq" "$BIN/moq-relay" "$SRC" ${SRC2:+"$SRC2"}; do [ -e "$f" ] || {
	echo "missing $f" >&2
	exit 1
}; done
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"
KEEP=$(python3 -c "print(f'{$IDLE / 3:g}s')")
QUIC=(--quic-idle-timeout "${IDLE}s" --quic-keep-alive "$KEEP")
VERS=()
[ -n "$VER" ] && VERS=(--connect-version "$VER")
PLOG=info,moq_net::lite::publisher=debug,moq_net::ietf::publisher=debug

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
	echo "=== $(date -u +%FT%TZ) t56-failover $LABEL: cell $CELL, lane $LANE"
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	head -2 "$BIN.sha" 2>/dev/null || echo "sha: no sidecar for $BIN"
	echo "src $SRC${SRC2:+; importer B reads $SRC2}; idle ${IDLE}s keep-alive $KEEP; version ${VER:-negotiated}"
	echo "stagger ${STAGGER}s, exports ${SUB_STAGGER}s apart; kill at ${KILL_AT}s, back ${BACK}s later; outage ${OUTAGE_S}s; ${SECS}s"
	echo "import: ${IMP[*]}; export: ${EXP[*]}"
} | tee "$OUT/build.txt"

moq_relay_public "127.0.0.1:$PORT" localhost "${QUIC[@]}" --log-level info
"$BIN/moq-relay" "${RELAY_ARGV[@]}" >"$OUT/relay.log" 2>&1 &
PIDS+=("$!")
sleep 2

# The live sources: each played in real time to loopback UDP and written to a file by its own
# receiver; an importer follows its file from its own start, so both importers of one source read
# the same bytes, and two sources started together carry the programme in step.
live() { # <clip> <udp port> <file>
	: >"$OUT/$3"
	tsp --max-flushed-packets 7 -I ip "$2" -O file "$OUT/$3" 2>>"$OUT/tsp-live.log" &
	PIDS+=("$!")
	tsp -I file "$1" --infinite -P regulate --pcr-synchronous -O ip "127.0.0.1:$2" 2>>"$OUT/tsp-src.log" &
	PIDS+=("$!")
}
live "$SRC" "$UDP" live1.ts
[ -n "$SRC2" ] && live "$SRC2" $((UDP + 1)) live2.ts
sleep 0.5

declare -A IMPPID
importer() { # <A|B> <live file> <broadcast>
	tail -c 0 -f "$OUT/$2" |
		RUST_LOG=$PLOG "$BIN/moq" "${MOQ_DIAL[@]}" "$URL" "${VERS[@]+"${VERS[@]}"}" "${QUIC[@]}" \
			--broadcast "$3" "${IMP[@]}" >>"$OUT/import$1.log" 2>&1 &
	IMPPID[$1]=$!
	PIDS+=("$!")
	stamp "import$1_start"
}
served() {
	local n
	n=$(grep -c 'serving group' "$OUT/import$1.log" 2>/dev/null)
	echo "${n:-0}"
}

export_leg() { # <1|2> <broadcast>
	(
		while :; do
			echo "export$1_start $(now)" >>"$OUT/events.txt"
			"$BIN/moq" "${MOQ_DIAL[@]}" "$URL" "${VERS[@]+"${VERS[@]}"}" "${QUIC[@]}" --broadcast "$2" \
				"${EXP[@]}" 2>>"$OUT/export$1.log"
			echo "export$1_exit_$? $(now)" >>"$OUT/events.txt"
			sleep 1
		done | python3 "$H/t56-stamp.py" "$OUT/sub$1"
	) &
	PIDS+=("$!")
}

B_FILE=live1.ts B_BC=$BC
[ -n "$SRC2" ] && B_FILE=live2.ts
[ "$CELL" = select ] && [ -n "$SRC2" ] && B_BC=$BC.b
importer A live1.ts "$BC"
sleep 2
export_leg 1 "$BC"
for ((t = 3; t <= SECS; t++)); do
	sleep 1
	[ "$t" -eq $((2 + SUB_STAGGER)) ] && export_leg 2 "$B_BC"
	[ "$t" -eq "$STAGGER" ] && { [ "$CELL" != select ] || [ -n "$SRC2" ]; } && importer B "$B_FILE" "$B_BC"
	[ "$CELL" = select ] && continue
	if [ "$t" -eq $((KILL_AT - 2)) ]; then SA=$(served A) SB=$(served B); fi
	if [ "$t" -eq "$KILL_AT" ]; then
		DA=$(($(served A) - SA)) DB=$(($(served B) - SB))
		V=A
		[ "$DB" -gt "$DA" ] && V=B
		echo "victim=import$V; groups served over the 2 s before: A $DA, B $DB" | tee -a "$OUT/build.txt"
		VP=${IMPPID[$V]}
		case $CELL in
		kill) kill -KILL "$VP" && stamp "kill$V" ;;
		term) kill -TERM "$VP" && stamp "term$V" ;;
		outage)
			ports=$(ss -H -uanp 2>/dev/null | awk -v p="pid=$VP," 'index($0, p) { n = split($4, a, ":"); print a[n] }' | sort -u)
			for p in $ports; do
				iptables -I OUTPUT -o lo -p udp --sport "$p" -j DROP
				iptables -I OUTPUT -o lo -p udp --dport "$p" -j DROP
				DARK+=("$p")
			done
			stamp "outage$V"
			(
				sleep "$OUTAGE_S"
				for p in $ports; do light "$p"; done
				stamp "light$V"
			) &
			PIDS+=("$!")
			;;
		esac
	fi
	if [ "$CELL" != outage ] && [ "$t" -eq $((KILL_AT + BACK)) ]; then
		if [ "$V" = B ]; then importer B "$B_FILE" "$B_BC"; else importer A live1.ts "$BC"; fi
		stamp "back$V"
	fi
done
stamp end
echo "events:"
cat "$OUT/events.txt"
echo "grade: python3 $H/t56-grade.py $OUT --ref $SRC"

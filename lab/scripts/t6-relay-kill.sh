#!/usr/bin/env bash
# T6's restart drills on whichever CLI surface the build has: one relay, one `moq import ts`
# publisher, two `moq export ts` subscribers on loopback. Every process is tracked by PID, never by
# name, so a standing relay on the same host is untouched.
#
#   MODE=relay      SIGKILL the relay at KILL s and restart it on the same port at RESTART s.
#   MODE=publisher  A live source on loopback UDP feeds the publisher. SIGKILL the publisher at KILL s
#                   and start a fresh one on the same live stream at RESTART s (default 1 s later),
#                   so its media clock continues from the first one's.
#   MODE=standby    Two publishers of one broadcast run from the start, fed the same live stream; at
#                   KILL s the active one gets SIG and nothing restarts, so the subscribers can
#                   continue only through the relay reselecting the standby. `moq` handles only
#                   SIGINT, so TERM is a hard kill like KILL; INT exits through its own shutdown, and
#                   EOF ends the importer's input, so it finishes the broadcast as a clean source end.
#   HOP             One hop id for both publishers (`--hop`, or `--origin` on builds that predate
#                   it), which declares them interchangeable. Unset, each mints its own.
#   LATE_SUBS=1     Start the subscribers only once both publishers are producing. With a shared
#                   hop the newest announcement wins, so a standby that arrives after the
#                   subscribers takes over at once, before it has tracks; this isolates the kill.
#   KILL_WHICH      `oldest` (default) or `newest` publisher is the one SIG goes to. Their logs are
#                   pub.log and pub2.log, and the one with media subscriptions was serving.
#   SUPERVISE=1     Restart each exporter whenever it exits, appending to the same capture: what a
#                   standing egress under a process supervisor would deliver.
#
# The report at END s says whether each exporter is alive, how much it wrote after the restart, and
# when its output first grew again. The client idle timeout is 6 s with a 2 s keep-alive, so the
# subscribers see the session drop inside the relay's 12 s outage rather than after QUIC's 30 s default.
#
# Usage: t6-relay-kill.sh <bin-dir> [outdir]      (SRC the source clip, PORT the loopback port)
set -uo pipefail
BIN=${1:?bin dir with moq and moq-relay}
OUT=${2:-$HOME/t6-relay-kill}
SRC=${SRC:-$HOME/CNNiEMEA2.ts}
PORT=${PORT:-4443}
UDP=${UDP:-$((PORT + 1000))}
MODE=${MODE:-relay}
SUPERVISE=${SUPERVISE:-0}
LATE_SUBS=${LATE_SUBS:-0}
KILL_WHICH=${KILL_WHICH:-oldest}
HOP=${HOP:-${ORIGIN:-}}
SIG=${SIG:-KILL}
KILL=${KILL:-12}
case $MODE in
publisher | standby) RESTART=${RESTART:-$((KILL + 1))} ;;
*) RESTART=${RESTART:-24} ;;
esac
END=${END:-70}
MOQ="$BIN/moq"
RELAY="$BIN/moq-relay"
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"
moq_cli_detect "$MOQ" "$RELAY"
if [ "$MOQ_CLI_NEW" -eq 1 ]; then
	IDLE=(--quic-keep-alive 2s --quic-idle-timeout 6s)
else
	IDLE=(--client-quic-keep-alive 2s --client-quic-idle-timeout 6s)
fi
ORIG=()
if [ -n "$HOP" ]; then
	if "$MOQ" --help 2>&1 | grep -q -- '--hop <'; then ORIG=(--hop "$HOP")
	elif "$MOQ" --help 2>&1 | grep -q -- '--origin <'; then ORIG=(--origin "$HOP")
	else echo "this build has neither --hop nor --origin"; exit 1; fi
fi
moq_relay_public "127.0.0.1:$PORT" localhost --log-level info
BC=rec.hang
URL="https://localhost:$PORT"
mkdir -p "$OUT"
rm -f "$OUT"/*.ts "$OUT"/*.log "$OUT"/*.restarts "$OUT/sizes.csv"
size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
start_relay() {
	"$RELAY" "${RELAY_ARGV[@]}" >>"$OUT/relay.log" 2>&1 &
	RLY=$!
}
start_pub() { # [udp-port] [log]
	if [ "$MODE" = publisher ] || [ "$MODE" = standby ]; then
		(
			tsp -I ip "${1:-$UDP}" -O file - 2>>"$OUT/tsp-in.log" |
				"$MOQ" "${MOQ_DIAL[@]}" "$URL" "${IDLE[@]}" --broadcast "$BC" "${ORIG[@]+"${ORIG[@]}"}" import ts >>"$OUT/${2:-pub.log}" 2>&1
		) &
	else
		(
			tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - 2>"$OUT/tsp.log" |
				"$MOQ" "${MOQ_DIAL[@]}" "$URL" "${IDLE[@]}" --broadcast "$BC" import ts >"$OUT/pub.log" 2>&1
		) &
	fi
	PUB=$!
}
sub() { # <i>
	if [ "$SUPERVISE" = 1 ]; then
		while :; do
			"$MOQ" "${MOQ_DIAL[@]}" "$URL" "${IDLE[@]}" --broadcast "$BC" export ts >>"$OUT/sub$1.ts" 2>>"$OUT/sub$1.log"
			rc=$?
			echo "$(date +%s) exit $rc" >>"$OUT/sub$1.restarts"
			sleep 1
		done
	else
		"$MOQ" "${MOQ_DIAL[@]}" "$URL" "${IDLE[@]}" --broadcast "$BC" export ts >"$OUT/sub$1.ts" 2>"$OUT/sub$1.log"
	fi
}
moq_record_build "$MOQ" "$RELAY" | tee "$OUT/build.txt"
echo "mode=$MODE supervise=$SUPERVISE late_subs=$LATE_SUBS kill_which=$KILL_WHICH hop=${HOP:-fresh} sig=$SIG kill=$KILL restart=$RESTART" | tee -a "$OUT/build.txt"
start_relay
sleep 3
kill -0 "$RLY" 2>/dev/null || { echo "RELAY DID NOT START: $(tail -3 "$OUT/relay.log")"; exit 1; }
SUBS=()
start_subs() {
	for i in 1 2; do
		sub "$i" &
		SUBS+=($!)
	done
	sleep 1
}
[ "$LATE_SUBS" = 1 ] || start_subs
SOURCE=""
if [ "$MODE" = publisher ]; then
	tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O ip "127.0.0.1:$UDP" 2>"$OUT/tsp.log" &
	SOURCE=$!
elif [ "$MODE" = standby ]; then
	# One live stream to both publishers: `fork` pipes a copy to the standby's port.
	tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous \
		-P fork "tsp -I file - -O ip 127.0.0.1:$((UDP + 1))" -O ip "127.0.0.1:$UDP" 2>"$OUT/tsp.log" &
	SOURCE=$!
fi
start_pub
if [ "$MODE" = standby ]; then
	sleep 2
	ACTIVE=$PUB
	start_pub $((UDP + 1)) pub2.log
	STANDBY=$PUB
	PUB=$ACTIVE
	# The victim: the first publisher, or the second, which serves when the hop is shared.
	[ "$KILL_WHICH" = newest ] && PUB=$STANDBY STANDBY=$ACTIVE
fi
if [ "$LATE_SUBS" = 1 ]; then
	sleep 4
	start_subs
fi
echo "t,sub1,sub2,event" >"$OUT/sizes.csv"
for t in $(seq 0 "$END"); do
	ev=""
	if [ "$t" -eq "$KILL" ]; then
		case $MODE in
		publisher) pkill -KILL -P "$PUB" 2>/dev/null; ev=KILL_publisher ;;
		# The active publisher's moq process only, so a TERM exercises its own clean exit.
		standby)
			if [ "$SIG" = EOF ]; then pkill -TERM -P "$PUB" -f "tsp -I ip" 2>/dev/null
			else pkill -"$SIG" -P "$PUB" -f "import ts" 2>/dev/null; fi
			ev=${SIG}_active ;;
		*) kill -KILL "$RLY" 2>/dev/null; ev=KILL_relay ;;
		esac
	elif [ "$t" -eq "$RESTART" ]; then
		case $MODE in
		publisher) start_pub; ev=RESTART_publisher ;;
		standby) ev=none ;;
		*) start_relay; ev=RESTART_relay ;;
		esac
	fi
	echo "$t,$(size "$OUT/sub1.ts"),$(size "$OUT/sub2.ts"),$ev" >>"$OUT/sizes.csv"
	[ "$t" -eq "$RESTART" ] && AT_RESTART=("$(size "$OUT/sub1.ts")" "$(size "$OUT/sub2.ts")")
	sleep 1
done
for i in 1 2; do
	pid=${SUBS[$((i - 1))]}; now=$(size "$OUT/sub$i.ts"); after=$((now - ${AT_RESTART[$((i - 1))]}))
	if [ "$SUPERVISE" = 1 ]; then state=supervised
	elif kill -0 "$pid" 2>/dev/null; then state=alive; else state=exited; fi
	# The first second after the kill in which the capture grew again.
	resumed=$(awk -F, -v c=$((i + 1)) -v k="$KILL" 'NR > 1 && $1 > k && $c > prev && stalled { print $1; exit }
		NR > 1 { if ($1 > k && $c == prev) stalled = 1; prev = $c }' "$OUT/sizes.csv")
	# The longest run of seconds after the kill in which the capture did not grow.
	stall=$(awk -F, -v c=$((i + 1)) -v k="$KILL" 'NR > 1 { if ($1 > k) { run = ($c == prev) ? run + 1 : 0; if (run > max) max = run }; prev = $c }
		END { print max + 0 }' "$OUT/sizes.csv")
	restarts=0
	[ -f "$OUT/sub$i.restarts" ] && restarts=$(wc -l <"$OUT/sub$i.restarts")
	echo "sub$i: $state at t=$END; ${after} B written after the restart; resumed at t=${resumed:-never}; longest stall after the kill ${stall} s; $((restarts)) exporter restarts; $(grep -m1 '^Error:' "$OUT/sub$i.log" || echo 'no error')"
done | tee "$OUT/verdict.txt"
# Stop each subscriber's shell before killing its exporter, or a supervisor restarts it.
kill -STOP "${SUBS[@]}" 2>/dev/null
for pid in "${SUBS[@]}" "$PUB" ${STANDBY:+"$STANDBY"}; do pkill -P "$pid" 2>/dev/null; done
kill -KILL "${SUBS[@]}" 2>/dev/null
kill "$PUB" ${STANDBY:+"$STANDBY"} "$RLY" ${SOURCE:+"$SOURCE"} 2>/dev/null
[ -n "$SOURCE" ] && pkill -f "[t]sp -I file - -O ip 127.0.0.1:$((UDP + 1))" 2>/dev/null
wait 2>/dev/null

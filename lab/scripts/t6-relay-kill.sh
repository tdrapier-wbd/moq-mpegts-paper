#!/usr/bin/env bash
# T6's relay-restart drill on whichever CLI surface the build has: one relay, one `moq import ts`
# publisher, two `moq export ts` subscribers on loopback. SIGKILL the relay at KILL s, restart it on
# the same port at RESTART s, and report at END s whether each exporter is alive and wrote anything
# after the restart. Every process is tracked by PID, never by name, so a standing relay on the same
# host is untouched.
#
# The client idle timeout is 6 s with a 2 s keep-alive, so the subscribers see the session drop inside
# the 12 s outage rather than after QUIC's 30 s default.
#
# Usage: t6-relay-kill.sh <bin-dir> [outdir]      (SRC the source clip, PORT the loopback port)
set -uo pipefail
BIN=${1:?bin dir with moq and moq-relay}
OUT=${2:-$HOME/t6-relay-kill}
SRC=${SRC:-$HOME/CNNiEMEA2.ts}
PORT=${PORT:-4443}
KILL=${KILL:-12}
RESTART=${RESTART:-24}
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
moq_relay_public "127.0.0.1:$PORT" localhost --log-level info
BC=rec.hang
URL="https://localhost:$PORT"

mkdir -p "$OUT"
rm -f "$OUT"/*.ts "$OUT"/*.log "$OUT/sizes.csv"
size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
start_relay() {
	"$RELAY" "${RELAY_ARGV[@]}" >>"$OUT/relay.log" 2>&1 &
	RLY=$!
}

moq_record_build "$MOQ" "$RELAY" | tee "$OUT/build.txt"
start_relay
sleep 3
kill -0 "$RLY" 2>/dev/null || {
	echo "RELAY DID NOT START: $(tail -3 "$OUT/relay.log")"
	exit 1
}
SUBS=()
for i in 1 2; do
	"$MOQ" "${MOQ_DIAL[@]}" "$URL" "${IDLE[@]}" --broadcast "$BC" export ts \
		>"$OUT/sub$i.ts" 2>"$OUT/sub$i.log" &
	SUBS+=($!)
done
sleep 1
(
	tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - 2>"$OUT/tsp.log" |
		"$MOQ" "${MOQ_DIAL[@]}" "$URL" "${IDLE[@]}" --broadcast "$BC" import ts >"$OUT/pub.log" 2>&1
) &
PUB=$!

echo "t,sub1,sub2,event" >"$OUT/sizes.csv"
for t in $(seq 0 "$END"); do
	ev=""
	if [ "$t" -eq "$KILL" ]; then
		kill -KILL "$RLY" 2>/dev/null
		ev=KILL_relay
	elif [ "$t" -eq "$RESTART" ]; then
		start_relay
		ev=RESTART_relay
	fi
	echo "$t,$(size "$OUT/sub1.ts"),$(size "$OUT/sub2.ts"),$ev" >>"$OUT/sizes.csv"
	[ "$t" -eq "$RESTART" ] && AT_RESTART=("$(size "$OUT/sub1.ts")" "$(size "$OUT/sub2.ts")")
	sleep 1
done

for i in 1 2; do
	pid=${SUBS[$((i - 1))]}
	now=$(size "$OUT/sub$i.ts")
	after=$((now - ${AT_RESTART[$((i - 1))]}))
	if kill -0 "$pid" 2>/dev/null; then state=alive; else state=exited; fi
	echo "sub$i: $state at t=$END; ${after} B written after the restart; $(grep -m1 '^Error:' "$OUT/sub$i.log" || echo 'no error')"
done | tee "$OUT/verdict.txt"

pkill -P "$PUB" 2>/dev/null
kill "${SUBS[@]}" "$PUB" "$RLY" 2>/dev/null
wait 2>/dev/null

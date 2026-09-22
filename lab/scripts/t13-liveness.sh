#!/usr/bin/env bash
# T13 P1-n, third property — does the egress distinguish a source that is *late* from one that is
# *gone*?
#
# A groomer holds the wire at a constant rate by stuffing null packets, which is exactly right
# while the source is late and exactly wrong once it has died: left alone, the output is a
# byte-perfect carrier — valid transport, correct rate, PCR present and accurate — with no
# programme in it. Every signal a monitor or a 1+1 receiver normally keys on reads healthy, and an
# input-failover policy performs zero switches because there is never any silence to detect.
# `mpegts-pacer` treats this as a first-class case (`StallPolicy`, `stalls`, `content_gap_max_ms`).
#
# The question here is what `moq export ts` does, now that #3831 has given it a null-packet
# generator and a rate to hold. Two outcomes, and they have opposite consequences:
#
#   a) output stops when content stops — carrier liveness and content liveness are the same thing,
#      downstream can detect the failure, and there is nothing for a groomer to add.
#   b) output continues as stuffing — the exporter mints a healthy-looking dead carrier, and
#      nothing in the CLI can tell a deployment that it has.
#
#   t13-liveness.sh [label]
#
# Env: BIN (moq binary dir), CLIP, PORT, OUT, RUN_S (seconds of live source before the kill).
set -uo pipefail

# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:-run}
BIN=${BIN:?set BIN to the moq binary dir}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
PORT=${PORT:-4479}
RUN_S=${RUN_S:-30}
OUT=${OUT:-$HOME/t13-liveness}/$LABEL

rm -rf "$OUT"; mkdir -p "$OUT"
BCAST="t13live-$$.hang"
cleanup() {
	pkill -f "[m]oq .*$BCAST" 2>/dev/null || true
	pkill -f "[m]oq-relay.*127.0.0.1:$PORT" 2>/dev/null || true
	pkill -f "[t]sp --realtime -I file $CLIP" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== $(date -u) t13-liveness $LABEL ==="
"$BIN/moq" --version
[ -f "$BIN.sha" ] && echo "build: $(cat "$BIN.sha")"

moq_cli_detect "$BIN/moq" "$BIN/moq-relay"
moq_relay_public "127.0.0.1:$PORT" localhost
"$BIN/moq-relay" "${RELAY_ARGV[@]}" >"$OUT/relay.log" 2>&1 &
sleep 2

setsid bash -c "$BIN/moq ${MOQ_DIAL[*]} https://127.0.0.1:$PORT/anon --quic-gso=false \
	--broadcast $BCAST export ts > $OUT/out.ts" 2>"$OUT/export.log" &
sleep 2

setsid bash -c "tsp --realtime -I file $CLIP -P regulate --pcr-synchronous --wait-min 5 -O file - \
	| $BIN/moq ${MOQ_DIAL[*]} https://127.0.0.1:$PORT/anon --quic-gso=false \
	--broadcast $BCAST import ts" >"$OUT/import.log" 2>&1 &

sleep "$RUN_S"
size() { stat -c%s "$OUT/out.ts" 2>/dev/null || echo 0; }
live=$(size)
echo "source live, T+${RUN_S}s: $live B"
[ "$live" -lt 1000000 ] && { echo "VOID: nothing was delivered before the kill; this grades nothing"; exit 1; }

echo "--- killing the publisher ---"
pkill -f "[t]sp --realtime -I file $CLIP" 2>/dev/null || true
pkill -f "[m]oq .*$BCAST import" 2>/dev/null || true
prev=$live
for t in 5 10 20 40; do
	sleep 5
	[ "$t" -gt 10 ] && sleep 5
	[ "$t" -gt 20 ] && sleep 10
	now=$(size)
	printf '  kill+%-3ss  %12s B   +%s since the kill   (+%s in this interval)\n' \
		"$t" "$now" "$((now - live))" "$((now - prev))"
	prev=$now
done

echo "--- exporter state ---"
alive=0
if pgrep -f "[m]oq .*$BCAST export" >/dev/null; then
	echo "  the exporter is STILL RUNNING"
	alive=1
else
	echo "  the exporter has exited"
fi
tail -5 "$OUT/export.log"

# Phase 2. A standing egress outlives an upstream blip or it is not a standing egress: in a
# primary-distribution chain the publisher is restarted for a version bump, a failover or an
# encoder reboot, and a subscriber that has to be restarted alongside it cannot be the thing
# holding the service up. Restart the source and see whether the same exporter picks it up.
echo
echo "--- phase 2: the publisher returns ---"
before=$(size)
setsid bash -c "tsp --realtime -I file $CLIP -P regulate --pcr-synchronous --wait-min 5 -O file - \
	| $BIN/moq ${MOQ_DIAL[*]} https://127.0.0.1:$PORT/anon --quic-gso=false \
	--broadcast $BCAST import ts" >"$OUT/import2.log" 2>&1 &
sleep 25
after=$(size)
echo "  recovered after the restart: $((after - before)) B"
if [ "$alive" = 1 ] && [ "$((after - before))" -gt 1000000 ]; then
	echo "  the original exporter survived the blip and is carrying the restarted source"
elif [ "$alive" = 1 ]; then
	echo "  the exporter is alive but recovered nothing from the restarted source"
else
	echo "  the exporter had already exited, so the restarted source reaches nothing:"
	echo "  a standing egress cannot outlive a publisher restart without supervision"
fi
echo "=== $(date -u) done: $OUT ==="

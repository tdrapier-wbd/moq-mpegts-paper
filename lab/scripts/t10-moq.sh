#!/usr/bin/env bash
# T10 arms A/B — one TS file through `moq import ts` -> moq-relay -> `moq export ts`, captured to
# file, in one invocation.
#
#   t10-moq.sh <src.ts> <out-dir> [label]
#
# Relay on loopback, subscriber started before the publisher (reservation gating publishes the
# catalog once the tracks resolve), publisher fed at source rate by `tsp -P regulate`, one pass of
# the file with no loop, so the capture holds the whole source and no loop discontinuity.
#
# Env: BIN (default ~/bin-ffa5b81b), MOQ, RELAY, PORT (4490), TAIL_S (seconds to let the exporter
# drain after the publisher ends; default 15).
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
LABEL=${3:-$(basename "$OUT")}
BIN=${BIN:-$HOME/bin-ffa5b81b}
MOQ=${MOQ:-$BIN/moq}
RELAY=${RELAY:-$BIN/moq-relay}
PORT=${PORT:-4490}
TAIL_S=${TAIL_S:-15}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=moq-cli-flags.sh
. "$SCRIPTS/moq-cli-flags.sh"
moq_cli_detect "$MOQ" "$RELAY"
moq_relay_public "127.0.0.1:$PORT" localhost --log-level info

[ -f "$SRC" ] || {
	echo "no such source: $SRC" >&2
	exit 1
}
rm -rf "$OUT"
mkdir -p "$OUT"
{
	moq_record_build "$MOQ" "$RELAY" || true
	if [ -f "$BIN.sha" ]; then echo "sha: $(cat "$BIN.sha")"; fi
	echo "source: $SRC $(md5sum "$SRC" | cut -d' ' -f1)"
} >"$OUT/build.txt"

PIDS=()
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

"$RELAY" "${RELAY_ARGV[@]}" >"$OUT/relay.log" 2>&1 &
PIDS+=($!)
sleep 2

URL="https://localhost:$PORT"
BCAST="t10.$LABEL.hang"
"$MOQ" "${MOQ_DIAL[@]}" "$URL" "${MOQ_GSO[@]}" --broadcast "$BCAST" export ts \
	>"$OUT/egress.ts" 2>"$OUT/sub.log" &
SUB=$!
PIDS+=("$SUB")
sleep 1

T0=$(date +%s.%N)
(
	set +e
	tsp -I file "$SRC" -P regulate --pcr-synchronous -O file - 2>"$OUT/tsp.log" |
		"$MOQ" "${MOQ_DIAL[@]}" "$URL" "${MOQ_GSO[@]}" --broadcast "$BCAST" import ts >"$OUT/pub.log" 2>&1
	echo "pub_exit=${PIPESTATUS[1]}" >"$OUT/pub.status"
) &
PUB=$!
PIDS+=("$PUB")

TTFB=none
for _ in $(seq 1 600); do
	if [ -s "$OUT/egress.ts" ]; then
		TTFB=$(awk -v a="$(date +%s.%N)" -v b="$T0" 'BEGIN { printf "%.2f", a - b }')
		break
	fi
	kill -0 "$PUB" 2>/dev/null || break
	sleep 0.05
done

wait "$PUB" || true
for _ in $(seq 1 "$TAIL_S"); do
	kill -0 "$SUB" 2>/dev/null || break
	sleep 1
done
SUB_ALIVE=$(kill -0 "$SUB" 2>/dev/null && echo yes || echo no)
cleanup
trap - EXIT

{
	echo "label=$LABEL"
	echo "broadcast=$BCAST"
	echo "ttfb_s=$TTFB"
	cat "$OUT/pub.status" 2>/dev/null || echo "pub_exit=unknown"
	echo "subscriber_alive_at_teardown=$SUB_ALIVE"
	echo "egress_bytes=$(stat -c%s "$OUT/egress.ts")"
} | tee "$OUT/run.env"

moq_require_bytes "$OUT/egress.ts" 1000000 "subscriber ($LABEL)"

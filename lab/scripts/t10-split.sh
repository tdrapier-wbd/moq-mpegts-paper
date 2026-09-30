#!/usr/bin/env bash
# T10 per-programme split — one multiplex through `moq import ts --program all` -> moq-relay ->
# one `moq export ts` per programme, each captured to file, in one invocation.
#
#   t10-split.sh <src.ts> <out-dir> [label]
#
# The same rig as t10-moq.sh, for builds that refuse a multi-programme input without a programme
# selection. `--program all` publishes programme n of `t10.<label>.hang` as `t10.<label>/n.hang`,
# so one subscriber per programme is started before the publisher. Grade each capture with
# `t10-grade.py <src.ts> <out-dir>/egress-<n>.ts` and read programme n's row; the others are
# expected ABSENT.
#
# Env: BIN (default ~/bin-ffa5b81b), MOQ, RELAY, PORT (4490), TAIL_S (default 15), PROGRAMS
# (space-separated programme numbers to subscribe; default "1 2 3").
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
LABEL=${3:-$(basename "$OUT")}
BIN=${BIN:-$HOME/bin-ffa5b81b}
MOQ=${MOQ:-$BIN/moq}
RELAY=${RELAY:-$BIN/moq-relay}
PORT=${PORT:-4490}
TAIL_S=${TAIL_S:-15}
PROGRAMS=${PROGRAMS:-1 2 3}
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
	echo "programs: $PROGRAMS"
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
declare -A SUB
for n in $PROGRAMS; do
	"$MOQ" "${MOQ_DIAL[@]}" "$URL" "${MOQ_GSO[@]}" --broadcast "t10.$LABEL/$n.hang" export ts \
		>"$OUT/egress-$n.ts" 2>"$OUT/sub-$n.log" &
	SUB[$n]=$!
	PIDS+=($!)
done
sleep 1

(
	set +e
	tsp -I file "$SRC" -P regulate --pcr-synchronous -O file - 2>"$OUT/tsp.log" |
		"$MOQ" "${MOQ_DIAL[@]}" "$URL" "${MOQ_GSO[@]}" --broadcast "t10.$LABEL.hang" import ts --program all \
			>"$OUT/pub.log" 2>&1
	echo "pub_exit=${PIPESTATUS[1]}" >"$OUT/pub.status"
) &
PUB=$!
PIDS+=("$PUB")

wait "$PUB" || true
sleep "$TAIL_S"
{
	echo "label=$LABEL"
	cat "$OUT/pub.status" 2>/dev/null || echo "pub_exit=unknown"
	for n in $PROGRAMS; do
		alive=$(kill -0 "${SUB[$n]}" 2>/dev/null && echo yes || echo no)
		echo "program=$n subscriber_alive_at_teardown=$alive egress_bytes=$(stat -c%s "$OUT/egress-$n.ts")"
	done
} | tee "$OUT/run.env"
cleanup
trap - EXIT

for n in $PROGRAMS; do
	moq_require_bytes "$OUT/egress-$n.ts" 100000 "subscriber (programme $n)"
done

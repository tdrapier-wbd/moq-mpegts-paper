#!/usr/bin/env bash
# T8b — one high-loss point with noq's BBRv3: does the relay survive, and what does it deliver?
#
# T8 records noq's BBRv3 aborting the process under high loss (noq #768). The capacity ladders
# (T31) create a bottleneck, not random loss, so they cannot reproduce it. This puts uniform
# random loss on the media direction of the T8b namespace pair, with no rate limit, and runs a
# real clip through relay -> export for a fixed window.
#
#   sudo t8b-loss-point.sh <label> <bin-dir> [seconds]
#
# env: LOSS_PCT (10), DELAY_MS (25, each way), CC (delay = BBRv3 on noq), CLIP, OUT (~/t8b-loss),
#      SUB_BIN (the subscriber's build; defaults to <bin-dir>, set it to cross builds),
#      LAT (2s, the export's --max-age or --delay value), KEEP_EGRESS (0; 1 keeps egress.ts for
#      grading), and any MOQ_TS_* variables, which reach the export unchanged
#
# Oracle: the relay and both clients stay alive for the window (an abort is a result), plus the
# subscriber's delivered rate and TSDuck continuity on what it wrote. The egress file is deleted
# after grading.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LABEL=${1:?label}
BIN=${2:?bin dir with moq and moq-relay}
SUB_BIN=${SUB_BIN:-$BIN}
SECS=${3:-120}
LOSS_PCT=${LOSS_PCT:-10}
DELAY_MS=${DELAY_MS:-25}
CC=${CC:-delay}
LAT=${LAT:-2s}
KEEP_EGRESS=${KEEP_EGRESS:-0}
CLIP=${CLIP:-/home/ubuntu/CNNiEMEA2.ts}
OUT=${OUT:-/home/ubuntu/t8b-loss}/$LABEL
PORT=4443

# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$SUB_BIN/moq" "$SUB_BIN/moq-relay"
SUB_DIAL=("${MOQ_DIAL[@]}")
SUB_LAT=("${MOQ_LAT[@]}")
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"
MOQ_CC=$CC moq_relay_public "10.99.0.1:$PORT" 10.99.0.1 --log-level info

rm -rf "$OUT"
mkdir -p "$OUT"
{
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	[ "$SUB_BIN" = "$BIN" ] || echo "subscriber: $("$SUB_BIN/moq" --version 2>&1 | head -1) from $SUB_BIN"
	echo "label=$LABEL loss=${LOSS_PCT}% delay=${DELAY_MS}ms each way cc=$CC secs=$SECS lat=$LAT"
	env | grep '^MOQ_TS_' | sort
	echo "started=$(date -Is)"
} | tee "$OUT/meta.txt"

bash "$HERE/t8b-netns.sh" up >/dev/null
ip netns exec t8b-pub tc qdisc replace dev veth-pub root netem delay "${DELAY_MS}ms" loss "${LOSS_PCT}%"
ip netns exec t8b-sub tc qdisc replace dev veth-sub root netem delay "${DELAY_MS}ms"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	pkill -9 -f "[t]8b[.]loss[.]${LABEL}[.]hang" 2>/dev/null
	bash "$HERE/t8b-netns.sh" down >/dev/null 2>&1
	true
}
trap cleanup EXIT

ip netns exec t8b-pub "$BIN/moq-relay" "${RELAY_ARGV[@]}" >"$OUT/relay.log" 2>&1 &
RELAY_P=$!
PIDS+=("$RELAY_P")
sleep 2

BCAST="t8b.loss.$LABEL.hang"
DIAL=$(printf '%q ' "${MOQ_DIAL[@]}")
ip netns exec t8b-pub bash -c "tsp --realtime -I file '$CLIP' -P regulate --pcr-synchronous -O file - 2>/dev/null \
	| '$BIN/moq' $DIAL https://10.99.0.1:$PORT --broadcast '$BCAST' import ts" >"$OUT/import.log" 2>&1 &
PIDS+=($!)
sleep 4

ip netns exec t8b-sub "$SUB_BIN/moq" "${SUB_DIAL[@]}" "https://10.99.0.1:$PORT" --broadcast "$BCAST" \
	export ts "${SUB_LAT[@]}" "$LAT" >"$OUT/egress.ts" 2>"$OUT/export.log" &
SUB_P=$!
PIDS+=("$SUB_P")

echo "t_s,relay_alive,sub_alive,egress_bytes" >"$OUT/samples.csv"
T=0
while [ "$T" -lt "$SECS" ]; do
	sleep 5
	T=$((T + 5))
	ra=0
	sa=0
	kill -0 "$RELAY_P" 2>/dev/null && ra=1
	kill -0 "$SUB_P" 2>/dev/null && sa=1
	echo "$T,$ra,$sa,$(stat -c%s "$OUT/egress.ts" 2>/dev/null || echo 0)" >>"$OUT/samples.csv"
done

python3 - "$OUT" "$SECS" <<'PY' | tee -a "$OUT/meta.txt"
import csv, sys
out, secs = sys.argv[1], int(sys.argv[2])
rows = list(csv.DictReader(open(f"{out}/samples.csv")))
relay_dead = [r["t_s"] for r in rows if r["relay_alive"] == "0"]
sub_dead = [r["t_s"] for r in rows if r["sub_alive"] == "0"]
b = [int(r["egress_bytes"]) for r in rows]
half = len(b) // 2
tail = (b[-1] - b[half]) * 8 / ((len(b) - 1 - half) * 5) / 1e6 if len(b) > half + 1 else 0
print(f"relay_died_at={relay_dead[0] if relay_dead else 'never'} "
      f"subscriber_died_at={sub_dead[0] if sub_dead else 'never'} "
      f"egress={b[-1]} B  mean={b[-1] * 8 / secs / 1e6:.2f} Mb/s  second_half={tail:.2f} Mb/s")
PY
{
	echo "panics: $(grep -l -E 'panicked|overflow' "$OUT"/*.log 2>/dev/null | xargs -r -n1 basename | paste -sd, -)"
	tsp -I file "$OUT/egress.ts" -P continuity -P count --total -O drop 2>&1 | tail -3
	echo "finished=$(date -Is)"
} | tee -a "$OUT/meta.txt"
[ "$KEEP_EGRESS" = 1 ] || rm -f "$OUT/egress.ts"

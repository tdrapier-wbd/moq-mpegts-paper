#!/usr/bin/env bash
# T11b rejoin arm: one publisher session, two subscribers in turn. With a gap longer than the
# relay's idle timeout for the first subscriber's dead session, the relay cancels its upstream
# subscription and re-subscribes for the second, which separates a cancel/re-subscribe race from a
# publisher that never releases a cancelled subscription.
# usage: PUB=<msfts-publisher> CLIP=<ts> t11b-rejoin.sh <bin-dir> <out-dir> <draft> <subscriber-version> [first-sub-s] [gap-s] [packets-per-object]
set -u
BIN=$1 OUT=$2 DRAFT=$3 SVER=$4 FIRST=${5:-4} GAP=${6:-15} PPO=${7:-66}
HERE=$(cd "$(dirname "$0")" && pwd)
: "${PUB:?set PUB to the msfts-publisher binary}"
: "${CLIP:?set CLIP to the source TS}"
mkdir -p "$OUT"
rm -f "$OUT"/*.ts "$OUT"/*.csv "$OUT"/*.log "$OUT"/*.exit

"$BIN/moq-relay" "$HERE/t11b-relay.toml" --quic-gso=false > "$OUT/relay.log" 2>&1 &
RELAY=$!
for _ in $(seq 50); do
	FP=$(curl -s http://127.0.0.1:4481/certificate.sha256) && [ -n "$FP" ] && break
	sleep 0.2
done

sub() {
	"$BIN/rawsub" --connect https://localhost:4481 --connect-tls-fingerprint "$FP" --connect-version "$SVER" \
		--broadcast t11b --track ts --log "$OUT/objects-$1.csv" --idle 5 > "$OUT/rx-$1.ts" 2> "$OUT/sub-$1.log"
	echo $? > "$OUT/sub-$1.exit"
}

sub a &
A=$!
sleep 1
"$PUB" --input "$CLIP" --endpoint "moqt://127.0.0.1:4481/" --namespace t11b --track ts \
	--packets-per-object "$PPO" --draft "$DRAFT" --insecure > "$OUT/pub.log" 2>&1 &
P=$!
sleep "$FIRST"
kill "$A" 2> /dev/null
pkill -f "rawsub .*objects-a.csv" 2> /dev/null
sleep "$GAP"
sub b &
wait "$P"
echo $? > "$OUT/pub.exit"
for _ in $(seq 30); do
	[ -s "$OUT/sub-b.exit" ] && break
	sleep 1
done
pkill -f "rawsub .*objects-b.csv" 2> /dev/null
kill $RELAY 2> /dev/null
wait 2> /dev/null
for s in a b; do
	echo "sub-$s exit=$(cat "$OUT/sub-$s.exit" 2> /dev/null) objects=$(($(wc -l < "$OUT/objects-$s.csv") - 1)) $(tail -1 "$OUT/sub-$s.log")"
done
echo "pub=$(cat "$OUT/pub.exit") $(grep '^Published' "$OUT/pub.log")"

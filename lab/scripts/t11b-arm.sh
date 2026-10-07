#!/usr/bin/env bash
# T11b arm: OpenMOQ's MSFTS example publisher -> moq-relay -> a raw subscriber holding one SUBSCRIBE.
# usage: PUB=<msfts-publisher> t11b-arm.sh <bin-dir> <out-dir> <draft> <moqt|https> [subscriber-version] [packets-per-object]
#   <bin-dir> holds moq-relay and rawsub (t11b-rawsub.rs built as a moq-tokio example).
#   PUB is moqxr's examples/msfts-publisher binary; CLIP is the single-programme source.
#   An empty subscriber version lets the subscriber negotiate moq-lite.
# Grade with: t11b-grade.py "$CLIP" <out-dir>/rx.ts --rewritten 0,<pmt-pid> --dropped 16,17,20
set -u
BIN=$1 OUT=$2 DRAFT=$3 SCHEME=$4 SVER=${5:-} PPO=${6:-66}
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

VARGS=()
[ -n "$SVER" ] && VARGS=(--connect-version "$SVER")
("$BIN/rawsub" --connect https://localhost:4481 --connect-tls-fingerprint "$FP" "${VARGS[@]}" \
	--broadcast t11b --track ts --log "$OUT/objects.csv" --idle 5 > "$OUT/rx.ts" 2> "$OUT/sub.log"
	echo $? > "$OUT/sub.exit") &
sleep 1
"$PUB" --input "$CLIP" --endpoint "$SCHEME://127.0.0.1:4481/" --namespace t11b --track ts \
	--packets-per-object "$PPO" --draft "$DRAFT" --insecure > "$OUT/pub.log" 2>&1
echo $? > "$OUT/pub.exit"
for _ in $(seq 30); do
	[ -s "$OUT/sub.exit" ] && break
	sleep 1
done
pkill -f "rawsub --connect https://localhost:4481" 2> /dev/null
kill $RELAY 2> /dev/null
wait 2> /dev/null
echo "pub=$(cat "$OUT/pub.exit") sub=$(cat "$OUT/sub.exit" 2> /dev/null) $(grep '^Published' "$OUT/pub.log") / $(tail -1 "$OUT/sub.log")"

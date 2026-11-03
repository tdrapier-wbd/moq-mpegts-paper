#!/usr/bin/env bash
# T11: which client loses imquic's final objects. One publish of the synthetic fixture through
# imquic's public relay (draft 22, raw QUIC), three clients on it:
#   M  moq export ts --passthrough, up before the publisher (capture m.ts, map with t11-loss-map.py)
#   I  imquic-moq-sub SUBSCRIBE from 2 s in (i.log: every object, its group, ID, size, eos)
#   F  imquic-moq-sub FETCH of groups 0-19, ascending, from 26 s in (f.log)
# The publisher's input is held open 30 s past the fixture's end, so F runs while it is connected.
#
#   BIN=<moq dir> SUB=<imquic-moq-sub> FIXTURE=<fixture.ts> t11-imquic-fetch.sh <out dir> [replicates]
set -uo pipefail

BIN=${BIN:?set BIN to the moq build dir}
SUB=${SUB:?set SUB to imquic-moq-sub}
FIXTURE=${FIXTURE:?set FIXTURE to the synthetic fixture}
OUT=${1:?out dir}
N=${2:-3}
HOST=${HOST:-lminiero.it}
PORT=${PORT:-9000}
IP=$(dig +short "$HOST" A | tail -n 1)
[ -n "$IP" ] || {
	echo "cannot resolve $HOST" >&2
	exit 2
}
mkdir -p "$OUT"
"$BIN/moq" --version >"$OUT/build.txt" 2>&1
"$SUB" --help 2>&1 | sed -n 1,3p >>"$OUT/build.txt"
C=(--connect "moqt://$HOST:$PORT" --connect-version moq-transport-22)
S=(-r "$IP" -R "$PORT" -S "$HOST" -q -M 22 -N 0.m2ts -d 4)
export RUST_LOG=${RUST_LOG:-info}

for r in $(seq 1 "$N"); do
	d="$OUT/r$r"
	mkdir -p "$d"
	leaf="t11f-$$-$r"
	echo "$(date -u +%FT%TZ) r$r start" >>"$OUT/events.log"
	timeout 50 "$BIN/moq" "${C[@]}" --broadcast "moq-test/$leaf" export ts --passthrough \
		>"$d/m.ts" 2>"$d/m.log" &
	sleep 1
	( (tsp -I file "$FIXTURE" -P regulate --pcr-synchronous -O file - 2>/dev/null; sleep 30) |
		timeout 70 "$BIN/moq" "${C[@]}" --broadcast "moq-test/$leaf" import ts --passthrough \
			>"$d/pub.log" 2>&1) &
	sleep 2
	timeout 45 "$SUB" "${S[@]}" -n moq-test -n "$leaf" >"$d/i.log" 2>&1 &
	sleep 24
	timeout 20 "$SUB" "${S[@]}" -n moq-test -n "$leaf" -f ascending -g 0 -G 19 >"$d/f.log" 2>&1
	wait
	echo "$(date -u +%FT%TZ) r$r end" >>"$OUT/events.log"
	sleep 5
done

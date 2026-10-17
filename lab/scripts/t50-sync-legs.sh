#!/usr/bin/env bash
# Test 50: `moq export ts --sync` legs of one broadcast, on one host, everything on loopback.
#
#   t50-sync-legs.sh <bin-dir> <clip> <out-dir> <arm>
#
# Arms (lab/test-50-deterministic-ts-legs.md):
#   A  leg a, then the publisher; leg b joins JOIN s later; both run WINDOW s together
#   B  legs a, b and r start together; a is stopped for STOP s at +STOP_A, b at +STOP_B
#   C  arm A without --sync (the grader's one-byte flip of arm A's leg b is the other half)
#
# Env: RATE (12000000), DELAY (1s), JOIN (20), WINDOW (60), SECS (arm B's length, 60),
#      STOP (3), STOP_A (20), STOP_B (35), PORT (4443), RELAY_TOML (the tree's localhost.toml).
# The clip is read once, never looped: run no arm longer than the clip.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=${1:?bin dir with moq and moq-relay}
CLIP=${2:?clip}
OUT=${3:?out dir}
ARM=${4:?arm A, B or C}
RATE=${RATE:-12000000}
DELAY=${DELAY:-1s}
JOIN=${JOIN:-20}
WINDOW=${WINDOW:-60}
SECS=${SECS:-60}
STOP=${STOP:-3}
STOP_A=${STOP_A:-20}
STOP_B=${STOP_B:-35}
PORT=${PORT:-4443}
RELAY_TOML=${RELAY_TOML:?set RELAY_TOML to the tree under test's demo/relay/localhost.toml}
MOQ=$BIN/moq
RELAY=$BIN/moq-relay
BCAST=t50.sync.hang
SYNC=(--sync)
[ "$ARM" = C ] && SYNC=()

. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$MOQ" "$RELAY"

rm -rf "$OUT"
mkdir -p "$OUT"
{
	moq_record_build "$MOQ" "$RELAY"
	echo "arm=$ARM clip=$CLIP rate=$RATE delay=$DELAY join=$JOIN window=$WINDOW secs=$SECS stop=$STOP@$STOP_A,$STOP_B sync=${SYNC[*]:-off}"
	echo "started=$(date -u +%FT%TZ)"
} | tee "$OUT/meta.txt"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
	pkill -f "[t]sp --realtime -I file $CLIP" 2>/dev/null
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	true
}
trap cleanup EXIT

cp "$RELAY_TOML" "$OUT/relay.toml"
(cd "$OUT" && exec "$RELAY" relay.toml "${RELAY_GSO[@]}") >"$OUT/relay.log" 2>&1 &
RELAY_PID=$!
PIDS+=("$RELAY_PID")
for _ in $(seq 1 40); do
	FP="$(curl -s "http://localhost:$PORT/certificate.sha256" 2>/dev/null || true)"
	[ -n "$FP" ] && break
	sleep 0.25
done
[ -n "${FP:-}" ] && kill -0 "$RELAY_PID" 2>/dev/null || {
	echo "relay did not come up, or another holds :$PORT; see $OUT/relay.log" >&2
	exit 1
}
C=("${MOQ_FP[@]}" "$FP" "${MOQ_DIAL[1]}" "https://localhost:$PORT" "${MOQ_GSO[@]}")

# leg <name>: an export writing <name>.ts; its PID lands in LEG_PID.
leg() {
	"$MOQ" "${C[@]}" --broadcast "$BCAST" export ts "${SYNC[@]}" --mux-rate "$RATE" --delay "$DELAY" \
		>"$OUT/$1.ts" 2>"$OUT/$1.log" &
	LEG_PID=$!
	PIDS+=("$LEG_PID")
	echo "leg $1 started $(date -u +%T.%N)" >>"$OUT/meta.txt"
}

publish() {
	(tsp --realtime -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>/dev/null |
		"$MOQ" "${C[@]}" --broadcast "$BCAST" import ts) >"$OUT/import.log" 2>&1 &
	PIDS+=($!)
}

# pause <pid> <name>: stop the process for STOP s, as a leg whose path fails.
pause() {
	kill -STOP "$1"
	echo "leg $2 stopped $(date -u +%T.%N)" >>"$OUT/meta.txt"
	sleep "$STOP"
	kill -CONT "$1"
	echo "leg $2 resumed $(date -u +%T.%N)" >>"$OUT/meta.txt"
}

case "$ARM" in
A | C)
	leg a
	sleep 1
	publish
	sleep "$JOIN"
	leg b
	sleep "$WINDOW"
	;;
B)
	leg a
	A=$LEG_PID
	leg b
	B=$LEG_PID
	leg r
	sleep 1
	publish
	sleep "$STOP_A"
	pause "$A" a
	sleep $((STOP_B - STOP_A - STOP))
	pause "$B" b
	sleep $((SECS - STOP_B - STOP))
	;;
*)
	echo "unknown arm $ARM" >&2
	exit 2
	;;
esac
cleanup
trap - EXIT
echo "finished=$(date -u +%FT%TZ)" | tee -a "$OUT/meta.txt"

for f in "$OUT"/*.ts; do
	moq_require_bytes "$f" 10000000 "$(basename "$f")" || exit 1
done

# Grade: identity (and arm B's merge against leg r), then continuity and PCR per leg.
{
	legs=("$OUT/a.ts" "$OUT/b.ts")
	[ "$ARM" = B ] && legs+=("$OUT/r.ts")
	echo "--- identity"
	python3 "$HERE/ts-sync-identity.py" --rate "$RATE" "${legs[@]}" --merge-out "$OUT/merge.ts" \
		--json "$OUT/identity.json" >/dev/null
	echo "identity exit $? (0: no conflict, every slot at the rate, arm B's merge equals leg r)"
	cat "$OUT/identity.json"
	if [ "$ARM" = A ]; then
		python3 "$HERE/ts-sync-identity.py" --flip "$OUT/b.ts" "$OUT/b-flip.ts"
		echo "--- control: leg b with one byte flipped, against itself"
		python3 "$HERE/ts-sync-identity.py" --rate "$RATE" "$OUT/b.ts" "$OUT/b-flip.ts" --json "$OUT/flip.json" >/dev/null
		python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["pairs"][0]; print("conflicts", p["conflicts"], p["conflict_examples"][:2])' "$OUT/flip.json"
	fi
	for f in "${legs[@]}" "$OUT/merge.ts"; do
		[ "$ARM" = B ] || [ "$f" != "$OUT/merge.ts" ] || continue
		echo "--- $(basename "$f")"
		echo "continuity: $(tsp -I file "$f" -P continuity -O drop 2>&1 | grep -c .) lines"
		tsp -I file "$f" -P continuity -O drop 2>&1 | head -5
		tsp -I file "$f" -P pcrextract --pcr --csv -o "$f.pcr.csv" -O drop 2>/dev/null
		awk -F, 'NR>1{c=$7;if(p!=""){d=(c-p)/27000;n++;s+=d;if(d>m)m=d;if(d>40)o++}p=c}
			END{printf "pcr interval mean=%.2f max=%.2f >40ms=%d of %d\n",s/n,m,o,n}' "$f.pcr.csv"
		echo "pcrverify: $(tsp -I file "$f" -P pcrverify --absolute --jitter-max 13 --bitrate "$RATE" -O drop 2>&1 | tail -1)"
	done
	echo "--- exporters"
	for l in a b r; do
		[ -f "$OUT/$l.log" ] || continue
		echo "$l: $(sed 's/\x1b\[[0-9;]*m//g' "$OUT/$l.log" | grep -E 'release clock|WARN|ERROR' | tail -3)"
	done
} 2>&1 | tee "$OUT/grade.txt"

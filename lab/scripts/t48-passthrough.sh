#!/usr/bin/env bash
# T48 — `moq export ts --passthrough` on a real capture, loopback on one host.
#
#   t48-passthrough.sh <bin-dir> <clip.ts> <out-dir> [seconds]
#
# Starts a relay, publishes the clip with `import ts --passthrough` paced on its own PCR
# (`tsp regulate --pcr-synchronous`), and runs two `export ts --passthrough --delay $DELAY`
# subscribers: leg A from the start, its stdout teed into upstream's live PCR grader
# (`pcr-timing.py --live`, which grades when each PCR was released against the PCR's own value),
# and leg B joining LATE s later. Then grades each leg against the clip
# (`ts-passthrough-identity.py`), B against A over their overlap, and upstream's T-STD check
# (`compliance.py`) on A and on the source span A covers.
#
# env: DELAY (1s), LATE (8), PORT (4443), RELAY_TOML (the build tree's demo/relay/localhost.toml),
#      TSC (upstream's test/ts directory, for compliance.py and pcr-timing.py)
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=${1:?bin dir with moq and moq-relay}
CLIP=${2:?clip}
OUT=${3:?out dir}
SECS=${4:-120}
DELAY=${DELAY:-1s}
LATE=${LATE:-8}
PORT=${PORT:-4443}
TSC=${TSC:-$HOME/moq-wt/ts-passthrough-export/test/ts}
RELAY_TOML=${RELAY_TOML:-$HOME/moq-wt/ts-passthrough-export/demo/relay/localhost.toml}
MOQ=$BIN/moq
RELAY=$BIN/moq-relay
BCAST=t48.passthrough.hang
DELAY_MS=$(python3 -c "import re,sys; v,u=re.fullmatch(r'([\d.]+)(ms|s)', sys.argv[1]).groups(); print(int(float(v)*(1 if u=='ms' else 1000)))" "$DELAY")

# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$MOQ" "$RELAY"

rm -rf "$OUT"
mkdir -p "$OUT"
{
	moq_record_build "$MOQ" "$RELAY"
	echo "clip=$CLIP secs=$SECS delay=$DELAY late=$LATE"
	echo "started=$(date -u +%FT%TZ)"
} | tee "$OUT/meta.txt"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
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

# Leg A first: reservation gating publishes the catalog once tracks resolve. The grader's window
# ends the leg (tee then takes SIGPIPE), so it is set to end before the run does.
WINDOW=$((SECS - 10))
("$MOQ" "${C[@]}" --broadcast "$BCAST" export ts --passthrough --delay "$DELAY" 2>"$OUT/a.log" |
	tee "$OUT/a.ts" |
	python3 "$TSC/pcr-timing.py" --live --seconds "$WINDOW" --drift-ms "$DELAY_MS" \
		--report-json "$OUT/a-pcr.json" >"$OUT/a-pcr.txt" 2>&1) &
PIDS+=($!)
sleep 1
(tsp --realtime -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>/dev/null |
	"$MOQ" "${C[@]}" --broadcast "$BCAST" import ts --passthrough) >"$OUT/import.log" 2>&1 &
PIDS+=($!)
sleep "$LATE"
"$MOQ" "${C[@]}" --broadcast "$BCAST" export ts --passthrough --delay "$DELAY" \
	>"$OUT/b.ts" 2>"$OUT/b.log" &
PIDS+=($!)
sleep $((SECS - LATE))
cleanup
trap - EXIT
echo "finished=$(date -u +%FT%TZ)" | tee -a "$OUT/meta.txt"

ID="$HERE/ts-passthrough-identity.py"
{
	echo "--- release timing, leg A (pcr-timing.py --live, exit 0 = every hard check passes)"
	tail -n 12 "$OUT/a-pcr.txt"
	for leg in a b; do
		echo "--- identity, leg $leg against the clip"
		span=()
		[ "$leg" = a ] && span=(--span-out "$OUT/a-span.ts")
		python3 "$ID" "$CLIP" "$OUT/$leg.ts" --json "$OUT/$leg-id.json" "${span[@]}"
		echo "exporter: $(sed 's/\x1b\[[0-9;]*m//g' "$OUT/$leg.log" | grep 'passthrough release clock' | tail -1)"
	done
	echo "--- leg B against leg A over their overlap"
	python3 - "$OUT" <<'PY'
import json, sys
out = sys.argv[1]
a, b = (json.load(open(f"{out}/{x}-id.json")) for x in "ab")
if a["gaps"] or b["gaps"] or a["foreign"] or b["foreign"]:
    print("a leg has gaps or foreign packets; the overlap is compared byte for byte anyway")
lo, hi = max(a["first_source_packet"], b["first_source_packet"]), min(a["end_source_packet"], b["end_source_packet"])
A, B = open(f"{out}/a.ts", "rb").read(), open(f"{out}/b.ts", "rb").read()
ra = A[(lo - a["first_source_packet"]) * 188 : (hi - a["first_source_packet"]) * 188]
rb = B[(lo - b["first_source_packet"]) * 188 : (hi - b["first_source_packet"]) * 188]
same = ra == rb and len(ra) == (hi - lo) * 188
print(f"overlap source packets {lo}..{hi} ({(hi - lo) * 188 / 1e6:.1f} MB): {'identical' if same else 'DIFFERENT'}")
PY
	for f in a a-span; do
		echo "--- compliance.py on $f.ts"
		python3 "$TSC/compliance.py" --ts "$OUT/$f.ts" --report-json "$OUT/$f-tsc.json" 2>&1 | grep -E 'tstd|PASS|FAIL|WARN' | head -20
	done
} 2>&1 | tee "$OUT/grade.txt"

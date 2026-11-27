#!/usr/bin/env bash
# Does a paused input cost the passthrough lane the bytes held at the pause? moq2ts#58: a 2.5 s
# input pause held the packets read since the last object boundary for 2.5 s. `moq import ts
# --passthrough` holds each object until the next PCR packet, and `export ts --passthrough` drops
# packets later than its `--delay`. One relay on loopback; the export subscribed first; the clip fed
# paced to one import in two parts, split at packet SPLIT (no PCR boundary), with PAUSE s between.
# A run is `kept` when the HELD packets before the split reach the output byte-identical and whole,
# `void` when packets 10,000-10,400 are missing (the export never joined).
#
# Usage: xc-input-pause.sh OUT    env: MOQ (bin dir), CLIP, PACKETS (133000), SPLIT (50000),
#                                      PAUSE (2.5), DELAY (2s), HELD (400), RUNS (3)

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
MOQ=${MOQ:-$HOME/bin-ed3a2697-thin} CLIP=${CLIP:-$HOME/contrib-10m.ts}
PACKETS=${PACKETS:-133000} SPLIT=${SPLIT:-50000} PAUSE=${PAUSE:-2.5} DELAY=${DELAY:-2s}
HELD=${HELD:-400} RUNS=${RUNS:-3}
M=$MOQ/moq R=$MOQ/moq-relay
# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$M" "$R"
mkdir -p "$OUT" && cd "$OUT" || exit 1
P=$((20000 + RANDOM % 20000))
CONNECT=${MOQ_DIAL[${#MOQ_DIAL[@]} - 1]}
DIAL=("${MOQ_DIAL[@]:0:${#MOQ_DIAL[@]}-1}" "$CONNECT" "https://localhost:$P/anon")

head -c $((188 * PACKETS)) "$CLIP" >clip.ts
head -c $((188 * SPLIT)) clip.ts >part1.ts
tail -c +$((188 * SPLIT + 1)) clip.ts >part2.ts
moq_relay_public "[::]:$P" localhost --log-level info
"$R" "${RELAY_ARGV[@]}" >relay.log 2>&1 &
RP=$!
trap 'kill "$RP" 2>/dev/null; wait 2>/dev/null' EXIT
sleep 1
echo "build=$(head -1 "$MOQ.sha" 2>/dev/null || echo unknown) packets=$PACKETS split=$SPLIT pause=$PAUSE delay=$DELAY held=$HELD" | tee meta.txt

for n in $(seq 1 "$RUNS"); do
	b=xc-pause-$n
	timeout 120 "$M" "${DIAL[@]}" --broadcast "$b" export ts --passthrough --delay "$DELAY" >"run-$n.ts" 2>"run-$n.export.log" &
	ep=$!
	sleep 1
	{
		tsp -I file part1.ts -P regulate --pcr-synchronous -O file - 2>/dev/null
		sleep "$PAUSE"
		tsp -I file part2.ts -P regulate --pcr-synchronous -O file - 2>/dev/null
	} | RUST_LOG=info timeout 120 "$M" "${DIAL[@]}" --broadcast "$b" import ts --passthrough 2>"run-$n.import.log"
	wait "$ep"
	python3 - "$n" "$SPLIT" "$HELD" <<'EOF' | tee -a results.tsv
import sys
n, split, held = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
clip, out = open("clip.ts", "rb").read(), open(f"run-{n}.ts", "rb").read()
def has(a, b):
    return out.find(clip[188 * a:188 * b]) >= 0
early = has(10000, 10400)
before = has(split - held, split)
after = has(split, split + held)
verdict = "void" if not early else ("kept" if before else "lost")
print(f"run-{n}\tout={len(out)}\tearly={early}\tbefore_pause={before}\tafter_pause={after}\t{verdict}")
EOF
	grep -h -E "release clock|skipped|dropped=[1-9]" "run-$n.export.log" | tail -3 | cut -c1-220 >"run-$n.notes"
done

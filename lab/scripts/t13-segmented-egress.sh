#!/usr/bin/env bash
# T13, segmented lane — capture a segmented egress and grade the same candidate chains.
#
#   ./t13-segmented-egress.sh <outdir> <src.ts> [secs]
#
# T13's whole question is what a grooming stage has to do, and it has only ever been
# asked of a MoQ egress. That egress carries no stuffing and declares no mux rate, so
# the stage has to *add* both — and T13's conclusion is that no off-the-shelf tool adds
# stuffing while carrying a broadcast mux unchanged.
#
# A segmented egress is a different stream. The packager slices the transport stream it
# was given, nulls and all, so what a client hands downstream already has the source's
# stuffing and the source's declared rate. If that holds, the grooming *requirement* on
# this lane is a strictly smaller one — pacing, and nothing else — and T13's unsolved half
# does not arise. That is a claim about the lane rather than about a tool, so it is worth
# a capture rather than an assertion.
#
# This produces the capture and the census that decides it, then runs the same candidate
# chains over it so the two lanes can be read from the same table.
set -uo pipefail

OUT=${1:?usage: t13-segmented-egress.sh <outdir> <src.ts> [secs]}
SRC=${2:?}
SECS=${3:-60}
PORT=${PORT:-8093}
SEGDUR=${SEGDUR:-2}

[ -r "$SRC" ] || { echo "no such source: $SRC" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT/origin"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

if lsof -nP -i ":$PORT" >/dev/null 2>&1; then
	echo "port $PORT already in use" >&2
	exit 1
fi

tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
	-O hls "$OUT/origin/seg.ts" --playlist "$OUT/origin/index.m3u8" \
	--duration "$SEGDUR" --live 6 --live-extra-segments 3 \
	--intra-close --align-first-segment >"$OUT/pkg.log" 2>&1 &
PIDS+=("$!")

(cd "$OUT/origin" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
	>"$OUT/origin.log" 2>&1 &
PIDS+=("$!")

for _ in $(seq 1 90); do
	n=$(grep -c '\.ts$' "$OUT/origin/index.m3u8" 2>/dev/null || echo 0)
	[ "$n" -ge 3 ] && break
	sleep 1
done
[ "${n:-0}" -ge 3 ] || { echo "packager produced nothing; see $OUT/pkg.log" >&2; exit 1; }

echo "==> capturing ${SECS}s of segmented egress"
tsp -I hls "http://127.0.0.1:$PORT/index.m3u8" --live -P until --seconds "$SECS" \
	-O file "$OUT/00-ungroomed-segmented.ts" >"$OUT/client.log" 2>&1

cleanup
trap - EXIT

EG="$OUT/00-ungroomed-segmented.ts"
[ -s "$EG" ] || { echo "no egress captured; see $OUT/client.log" >&2; exit 1; }

# The census that decides the framing. A MoQ egress reads 0 % here; if this one reads the
# source's own stuffing ratio then the two lanes hand a groomer different problems.
echo
echo "=== what the segmented lane hands a groomer ==="
census() { # label file
	tsp -I file "$2" -P analyze --normalized -O drop 2>/dev/null |
		awk -v label="$1" -F: '
		/^ts:/ { for (i = 1; i <= NF; i++) {
			if ($i ~ /^packets=/)  { split($i, a, "="); tot = a[2] }
			if ($i ~ /^bitrate=/)  { split($i, a, "="); br  = a[2] }
		} }
		/^pid:/ { pid = ""; pkts = 0
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^pid=/)     { split($i, a, "="); pid  = a[2] }
				if ($i ~ /^packets=/) { split($i, a, "="); pkts = a[2] }
			}
			if (pid == 8191) nulls = pkts
		}
		END { printf "%-22s packets=%s  nulls=%s (%.2f %%)  declared=%s b/s\n",
			label, tot, nulls + 0, tot ? nulls * 100 / tot : 0, br }'
}
census "source clip" "$SRC"
census "segmented egress" "$EG"

echo
echo "==> candidate chains over the segmented egress"
RATE=$(tsp -I file "$EG" -P analyze --normalized -O drop 2>/dev/null |
	grep '^ts:' | tr ':' '\n' | grep '^bitrate=' | head -1 | cut -d= -f2)
: "${RATE:=9945951}"
echo "    declared rate $RATE b/s"

tsp -I file "$EG" -P regulate --bitrate "$RATE" -O file "$OUT/10-tsp-regulate.ts" \
	>"$OUT/10.log" 2>&1
tsp -I file "$EG" -P pcradjust --bitrate "$RATE" -O file "$OUT/20-tsp-pcradjust.ts" \
	>"$OUT/20.log" 2>&1
ffmpeg -nostdin -y -loglevel error -i "$EG" -c copy -muxrate "$RATE" \
	-f mpegts "$OUT/30-ffmpeg-muxrate.ts" >"$OUT/30.log" 2>&1

echo
echo "==> grade with: t13-grade.py grade $OUT $SRC"
ls -1 "$OUT"/*.ts

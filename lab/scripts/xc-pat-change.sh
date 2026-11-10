#!/usr/bin/env bash
# Does a PAT that gains a programme mid-stream end `moq import ts`, and does a supervised restart
# bring the broadcast back? moq2ts#33, asked of moq-dev (lab/cross-check.md). Loopback only.
#
# Fixture (built unless FIXTURE names one): the clip's first 20 s as one programme, then 40 s with
# a second merged in (PAT version 1): 228 kb/s of the clip's own audio as service 2 on PIDs
# 0x1100/0x1101, merged into the clip's nulls by `tsp -P merge` at the clip's rate.
# Cases, one run each: plain (no --program) and program1 (--program 1, the control). The fixture is
# sent paced to a UDP port; a supervisor restarts `tsp -I ip | moq import ts` whenever it exits; a
# subscriber, relaunched whenever it exits, logs the wall time of each video PES it receives.
# Prints per case: imports started and how each ended, video PES received before the change, in the
# 10 s after it and after that, and the longest gap in video from the change on.
#
# Usage: xc-pat-change.sh OUT        env: MOQ (bin dir), CLIP, RATE (the clip's b/s), FIXTURE

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
MOQ=${MOQ:-$HOME/bin-cd560bde-thin} CLIP=${CLIP:-$HOME/contrib-10m.ts} RATE=${RATE:-9945951}
M=$MOQ/moq R=$MOQ/moq-relay
# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$M" "$R"
mkdir -p "$OUT" && cd "$OUT" || exit 1
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

FX=${FIXTURE:-$OUT/spts2mpts.ts}
if [ ! -s "$FX" ]; then
	N=$((RATE * 20 / 8 / 188))
	head -c $((188 * N)) "$CLIP" >part1.ts
	tail -c +$((188 * N + 1)) "$CLIP" | head -c $((188 * N * 2)) >part2.ts
	ffmpeg -nostdin -loglevel quiet -y -ss 20 -t 45 -i "$CLIP" -map 0:a:0 -c copy -f mpegts \
		-mpegts_service_id 2 -mpegts_pmt_start_pid 0x1100 -mpegts_start_pid 0x1101 prog2.ts || exit 1
	tsp --bitrate "$RATE" -I file part2.ts -P regulate \
		-P merge "tsp --bitrate 228107 -I file $OUT/prog2.ts" -O file part2m.ts || exit 1
	cat part1.ts part2m.ts >"$FX" && rm -f part1.ts part2.ts part2m.ts prog2.ts
fi
CHANGE_S=$(python3 - "$FX" "$RATE" <<'EOF'
import sys
d = open(sys.argv[1], "rb").read()
for i in range(len(d) // 188):
    b = i * 188
    if ((d[b + 1] & 0x1F) << 8 | d[b + 2]) or not d[b + 1] & 0x40:
        continue
    o = b + 4 + (1 + d[b + 4] if d[b + 3] & 0x20 else 0)
    o += 1 + d[o]
    if ((d[o + 1] & 0x0F) << 8 | d[o + 2]) > 13:
        print(f"{b * 8 / int(sys.argv[2]):.3f}")
        break
EOF
)
[ -n "$CHANGE_S" ] || {
	echo "fixture has no second programme" >&2
	exit 1
}
echo "build=$(head -1 "$MOQ.sha" 2>/dev/null || echo unknown) change_s=$CHANGE_S" | tee meta.txt

P=$((20000 + RANDOM % 20000))
UP=$((P + 1))
CONNECT=${MOQ_DIAL[${#MOQ_DIAL[@]} - 1]}
INSECURE=("${MOQ_DIAL[@]:0:${#MOQ_DIAL[@]}-1}")
URL="https://localhost:$P/anon"
moq_relay_public "[::]:$P" localhost --log-level info
"$R" "${RELAY_ARGV[@]}" >relay.log 2>&1 &
RP=$!
trap 'kill "$RP" 2>/dev/null; pkill -f -- "--broadcast xc-pat-" 2>/dev/null; wait 2>/dev/null' EXIT
sleep 1

VIDEO_PES='import sys, time
f, out = sys.stdin.buffer, open(sys.argv[1], "a")
while len(p := f.read(188)) == 188:
    o = 4 + (1 + p[4] if p[3] & 0x20 else 0)
    if p[1] & 0x40 and o < 184 and p[o:o + 3] == b"\0\0\1" and 0xE0 <= p[o + 3] <= 0xEF:
        out.write("%.3f\n" % time.time())
        out.flush()'

run() { # <case> [import flags ...]
	local name=$1 bc="xc-pat-$1" t0 t1 sub sup rc
	shift
	rm -f "$name.stop" "$name.video" "$name.imports"
	(
		while [ ! -e "$name.stop" ]; do
			RUST_LOG=info "$M" "${INSECURE[@]}" "$CONNECT" "$URL" --broadcast "$bc" export ts 2>>"$name.export.log" |
				python3 -c "$VIDEO_PES" "$name.video"
			sleep 0.2
		done
	) &
	sub=$!
	(
		while [ ! -e "$name.stop" ]; do
			echo "$(now) start" >>"$name.imports"
			tsp -I ip --receive-timeout 3000 --local-address 127.0.0.1 "$UP" -O file 2>/dev/null |
				RUST_LOG=info "$M" "${INSECURE[@]}" "$CONNECT" "$URL" --broadcast "$bc" import ts "$@" \
					>/dev/null 2>>"$name.import.log"
			rc=${PIPESTATUS[1]}
			echo "$(now) exit $rc" >>"$name.imports"
			sleep 0.5
		done
	) &
	sup=$!
	sleep 2
	t0=$(now)
	tsp -I file "$FX" -P regulate --bitrate "$RATE" -O ip "127.0.0.1:$UP" 2>/dev/null
	sleep 5
	t1=$(now)
	touch "$name.stop"
	pkill -f -- "--broadcast $bc" 2>/dev/null
	wait "$sub" "$sup" 2>/dev/null
	python3 - "$name" "$t0" "$CHANGE_S" "$t1" <<'EOF' | tee -a results.tsv
import sys
name, t0, ch, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
change = t0 + ch
try:
    v = [float(x) for x in open(f"{name}.video")]
except FileNotFoundError:
    v = []
ends = [x.split()[2] for x in open(f"{name}.imports") if " exit " in x]
pts = [change] + [t for t in v if t >= change] + [t1]
gap = max(b - a for a, b in zip(pts, pts[1:]))
print(
    f"{name}\timports={len(ends)}\texits={','.join(ends)}\tvideo_before={sum(t < change for t in v)}"
    f"\tvideo_0_10s={sum(change <= t < change + 10 for t in v)}\tvideo_after_10s={sum(t >= change + 10 for t in v)}"
    f"\tlongest_gap_s={gap:.2f}"
)
EOF
}

run plain
run program1 --program 1

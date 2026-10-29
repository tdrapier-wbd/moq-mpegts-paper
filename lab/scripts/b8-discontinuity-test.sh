#!/usr/bin/env bash
# b8-hls-recv.py's EXT-X-DISCONTINUITY handling, offline: two FFmpeg sources on different timelines,
# three tsp -O hls segments of each, one live playlist joining them.
#
#   lab/scripts/b8-discontinuity-test.sh [WORKDIR]
#
# Passes if, without the tag, the receiver's output is the six segments byte for byte, and, with it,
# differs from them only in discontinuity_indicator bits on the first segment after the boundary,
# the PCR PID's first PCR among them. Exits 1 otherwise.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
W=${1:-$(mktemp -d)}
PORT=${PORT:-18652}
mkdir -p "$W"
cd "$W"

for s in a b; do
	off=$([ $s = a ] && echo 0 || echo 5000)
	ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=25 \
		-f lavfi -i sine=frequency=1000:sample_rate=48000 -t 8 -c:v libx264 -preset veryfast -g 50 \
		-c:a mp2 -output_ts_offset "$off" -f mpegts -y "src-$s.ts"
	rm -rf "$s" && mkdir "$s"
	tsp -I file "src-$s.ts" -O hls "$s/seg.ts" --playlist "$s/index.m3u8" --duration 2 --intra-close 2>/dev/null
done

playlist() {
	{
		printf '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n'
		for i in 0 1 2; do printf '#EXTINF:2.0,\na/seg-%06d.ts\n' "$i"; done
		[ "$1" = tag ] && printf '#EXT-X-DISCONTINUITY\n'
		for i in 0 1 2; do printf '#EXTINF:2.0,\nb/seg-%06d.ts\n' "$i"; done
	} >"$1.m3u8"
}
playlist tag
playlist plain
cat a/seg-00000{0,1,2}.ts b/seg-00000{0,1,2}.ts >expected.ts

python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 1
for p in plain tag; do
	python3 "$HERE/b8-hls-recv.py" "http://127.0.0.1:$PORT/$p.m3u8" "out-$p.ts" --edge 6 --seconds 3 \
		--log "log-$p.jsonl"
done

python3 - "$(wc -c <a/seg-000000.ts)" "$(cat a/seg-00000{0,1,2}.ts | wc -c)" "$(wc -c <b/seg-000000.ts)" <<'PY'
import json, sys
a0, boundary, b0 = (int(x) for x in sys.argv[1:])
exp = open("expected.ts", "rb").read()
plain, tag = open("out-plain.ts", "rb").read(), open("out-tag.ts", "rb").read()
ok = True
if plain != exp:
	print("FAIL: without the tag the output is not the segments byte for byte"); ok = False
if len(tag) != len(exp):
	print(f"FAIL: with the tag the output is {len(tag)} bytes, not {len(exp)}"); sys.exit(1)
diffs = [i for i in range(len(exp)) if tag[i] != exp[i]]
bad = [i for i in diffs if not (boundary <= i < boundary + b0 and i % 188 == 5 and tag[i] ^ exp[i] == 0x80)]
if not diffs:
	print("FAIL: with the tag nothing was marked"); ok = False
if bad:
	print(f"FAIL: {len(bad)} changed bytes are not discontinuity_indicator bits after the boundary"); ok = False
pcr_pids = set()
for i in diffs:
	p = tag[i - 5:i - 5 + 188]
	if p[3] & 0x20 and p[4] >= 7 and p[5] & 0x10:
		pcr_pids.add((p[1] & 0x1F) << 8 | p[2])
ev = [json.loads(line) for line in open("log-tag.jsonl") if '"discontinuity"' in line]
print(f"marked {len(diffs)} packets after the boundary; PCR PIDs marked {sorted(pcr_pids)}; log {ev}")
if not pcr_pids:
	print("FAIL: no PCR was marked"); ok = False
if len(ev) != 1:
	print("FAIL: the log does not record one discontinuity"); ok = False
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY

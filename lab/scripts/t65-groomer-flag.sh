#!/usr/bin/env bash
# The stream-clocked groomer downstream of b8-hls-recv.py's discontinuity marking, offline, on loopback.
#
#   PACER=BIN lab/scripts/t65-groomer-flag.sh step|splice|restart [WORKDIR]
#
#   step     two FFmpeg sources, 20 s and 10 s, the second starting 3 s after the first ends: a flagged
#            forward step under the 5 s a jump must clear to be inferred
#   splice   two 8 s sources 5,000 s apart: an unflagged splice the groomer infers
#   restart  one 30 s source whose playlist drops segments 6-8 (an origin down for 6 s) and marks
#            the return with EXT-X-DISCONTINUITY, on a clock that carried on
#
# tsp -O hls cuts 2 s segments; b8-hls-recv.py joins them into one stream, flagging the first segment
# after the tag; the stream is handed to the groomer one segment per burst at the segment's own time,
# as b8 delivers it live (step, restart), or at a constant byte rate (splice). The groomer runs
# stream-clocked at seg-recv-leg.sh's cushion and cap; its RTP is captured and graded: PCR steps
# against the wire's byte clock and whether each is flagged, video PTS minus the clock at every PES
# start, the longest stuffing run, and the groomer's own counters.
set -euo pipefail

CASE=${1:?step|splice|restart}
PACER=${PACER:?the mpegts-pacer binary}
HERE=$(cd "$(dirname "$0")" && pwd)
W=${2:-$(mktemp -d)}
HTTP=${HTTP_PORT:-18670} RTP=${RTP_PORT:-18671} RATE=6000000
mkdir -p "$W"
cd "$W"

encode() { # name seconds offset
	ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=25 \
		-f lavfi -i sine=frequency=1000:sample_rate=48000 -t "$2" -c:v libx264 -preset veryfast -g 50 \
		-c:a mp2 -output_ts_offset "$3" -f mpegts -y "src-$1.ts"
	rm -rf "$1" && mkdir "$1"
	tsp -I file "src-$1.ts" -O hls "$1/seg.ts" --playlist "$1/index.m3u8" --duration 2 --intra-close 2>/dev/null
}
entries() { # dir first last
	for i in $(seq "$2" "$3"); do printf '#EXTINF:2.0,\n%s/seg-%06d.ts\n' "$1" "$i"; done
}
{
	printf '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n'
	case $CASE in
	step) encode a 20 0 && encode b 10 23 && entries a 0 9 && echo '#EXT-X-DISCONTINUITY' && entries b 0 3 ;;
	splice) encode a 8 0 && encode b 8 5000 && entries a 0 2 && echo '#EXT-X-DISCONTINUITY' && entries b 0 2 ;;
	restart) encode a 30 0 && entries a 0 5 && echo '#EXT-X-DISCONTINUITY' && entries a 9 13 ;;
	*) echo "unknown case $CASE" >&2 && exit 2 ;;
	esac
} >tag.m3u8

python3 -m http.server "$HTTP" --bind 127.0.0.1 >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1
python3 "$HERE/b8-hls-recv.py" "http://127.0.0.1:$HTTP/tag.m3u8" in.ts --edge "$(grep -c EXTINF tag.m3u8)" \
	--seconds 3 --log fetch.jsonl
kill $SRV

# tsp's ip input takes a bare port for unicast; an address is for joining a multicast group.
tsp -I ip --local-address 127.0.0.1 "$RTP" -O file cap.ts 2>cap.log &
CAP=$!
sleep 1
python3 - "$CASE" <<'PY' |
import json, re, sys, time
segs = [(e["name"], e["bytes"]) for e in map(json.loads, open("fetch.jsonl"))
	if e.get("ev") == "seg" and e.get("status") == 200]
data = open("in.ts", "rb").read()
out, t0, off = sys.stdout.buffer, time.monotonic(), 0
if sys.argv[1] == "splice":
	rate = len(data) / (2 * len(segs))
	for i in range(0, len(data), 18800):
		time.sleep(max(0, t0 + i / rate - time.monotonic()))
		out.write(data[i:i + 18800]); out.flush()
	sys.exit()
for k, (name, n) in enumerate(segs):
	index = int(re.search(r"(\d+)\.ts", name).group(1)) if sys.argv[1] == "restart" else k
	time.sleep(max(0, t0 + 2 * (index + 1) - time.monotonic()))
	out.write(data[off:off + n]); out.flush(); off += n
PY
	"$PACER" "127.0.0.1:$RTP" "$RATE" --rtp --ssrc 538968071 --stream-clock --sequence-seed 0 \
		--latency-ms 8000 --max-latency-ms 14000 --stall-ms 1000 --on-stall mute --stats-interval-ms 60000 \
		2>pacer.log || true
sleep 1
kill $CAP 2>/dev/null || true
wait $CAP 2>/dev/null || true

python3 - "$RATE" <<'PY'
import sys
rate = int(sys.argv[1])
TICKS = 188 * 8 * 27_000_000 / rate


def packets(path):
	d = open(path, "rb").read()
	return [d[i:i + 188] for i in range(0, len(d) - 187, 188)]


def pid(p):
	return ((p[1] & 0x1F) << 8) | p[2]


def pcr(p):
	if p[3] & 0x20 and p[4] >= 7 and p[5] & 0x10:
		b = p[6:12]
		return ((b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)) * 300 + (((b[4] & 1) << 8) | b[5])
	return None


src = [p for p in packets("in.ts") if pid(p) == 0x100 and pcr(p) is not None]
for p0, p1 in zip(src, src[1:]):
	if abs(pcr(p1) - pcr(p0)) > 13_500_000:
		print(f"input: PCR step {(pcr(p1) - pcr(p0)) / 27e6:+.3f} s, flagged {bool(p1[5] & 0x80)}")
cap = packets("cap.ts")
content = sum(pid(p) == 0x100 for p in cap)
run = best = 0
for p in cap:
	run = run + 1 if pid(p) == 0x1FFF else 0
	best = max(best, run)
pcrs = [(i, pcr(p), bool(p[5] & 0x80)) for i, p in enumerate(cap) if pid(p) == 0x100 and pcr(p) is not None]
steps = [(round((v1 - v0 - (i1 - i0) * TICKS) / 27e6, 3), f) for (i0, v0, _), (i1, v1, f) in zip(pcrs, pcrs[1:])
	if abs(v1 - v0 - (i1 - i0) * TICKS) > 27_000]
offsets, last = [], None
for i, p in enumerate(cap):
	if pid(p) != 0x100:
		continue
	if pcr(p) is not None:
		last = (i, pcr(p))
	pes = p[4 + (p[4] + 1 if p[3] & 0x20 else 0):]
	if p[1] & 0x40 and last and pes[:3] == b"\x00\x00\x01" and pes[7] & 0x80:
		t = pes[9:14]
		pts = ((t[0] >> 1) & 7) << 30 | t[1] << 22 | (t[2] >> 1) << 15 | t[3] << 7 | t[4] >> 1
		offsets.append((pts - (last[1] + (i - last[0]) * TICKS) / 300) / 90000)
print(f"wire: {len(cap)} packets ({len(cap) * 188 * 8 / rate:.2f} s), longest stuffing run {best}")
print(f"wire: PCR steps against the byte clock (s, flagged): {steps}")
print(f"wire: video PTS minus clock {min(offsets):.3f} to {max(offsets):.3f} s over {len(offsets)} PES starts")
PY
rg -o 'content=\S+|late_drops=\S+|withheld=\S+|cut_runs=\S+|resyncs=\S+' pacer.log | tr '\n' ' '
echo

#!/usr/bin/env bash
# Validate the content-domain grader, and demonstrate the padding blindness it exists to avoid.
#
# Three kinds of capture, each with an answer known before either grader sees it:
#
#   control      an unimpaired slice                                -> expect ~0 s lost
#                (run on the source clip and on an unimpaired `moq export ts` capture)
#   hole-N       N packets excised                                  -> expect the excised media
#   padhole-N    N packets excised and replaced by padding: nulls,  -> expect the same media
#                plus PCR-only packets on the PCR PID stepping at
#                the clip's own cadence across the gap
#
# The padded hole models what a constant-rate exporter writes across a media gap: the bytes are
# back *and* the clock keeps ticking, but no access unit is present. It is the case both of the
# PCR grader's domains are exposed to -- `file` because the bytes add up, `wire` because the PCR
# values step at cadence -- and it is built that way so the demonstration is not a straw man.
#
# Truth is read from the clip, not from either grader's arithmetic: every video access unit whose
# PES starts inside the cut is gone, and each is charged its own duration on the full clip's
# sorted presentation timeline. That is the media time the cut removed, field by field.
#
# The content grader must recover truth on all three kinds, to within the 100 ms tolerance T28
# grades at. The PCR grader (`t28-media-lost.py`, `wire` domain) is run beside it on the same
# files: on hole-N it should agree, and on padhole-N it is expected to read about zero. That second
# result is the defect being demonstrated, not a failure of this test, and is reported as such.
#
# Usage: t28-content-selftest.sh [clip] [outdir]
set -euo pipefail

CLIP="${1:-$HOME/CNNiEMEA2.ts}"
OUT="${2:-/tmp/t28-content-selftest}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTENT="$HERE/t28-content-lost.py"
PCRG="$HERE/t28-media-lost.py"
TOLERANCE_MS=100
HEAD_PKTS=40000
TAIL_PKTS=40000
# Slices start past the first ~3 s. An exporter capture opens with a real hole -- the subscriber
# joins on the tail of one group and jumps to the next -- which is content, but not the content a
# test of a cut should be charged with.
SKIP_PKTS="${SKIP_PKTS:-20000}"

for f in "$CLIP" "$CONTENT" "$PCRG"; do
	[ -r "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done
mkdir -p "$OUT"
rm -f "$OUT"/*.ts "$OUT"/*.json 2>/dev/null || true
fail=0

field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
within() { python3 -c 'import sys;sys.exit(0 if abs(float(sys.argv[1])-float(sys.argv[2]))<=float(sys.argv[3])/1000 else 1)' "$1" "$2" "$TOLERANCE_MS"; }

# build <clip> <head> <cut> <tail> <out-hole> <out-padhole>; prints the truth in seconds.
build() {
	python3 - "$@" <<-'PY'
		import sys, statistics
		clip, skip, head, cut, tail, out_hole, out_pad = sys.argv[1], *map(int, sys.argv[2:6]), sys.argv[6], sys.argv[7]
		with open(clip, "rb") as f:
		    f.seek(skip * 188)
		    data = f.read((head + cut + tail) * 188)
		pk = [data[i:i + 188] for i in range(0, len(data) - 187, 188)]

		def payload(p):
		    afc = (p[3] >> 4) & 3
		    return p[4 + (1 + p[4] if afc & 2 else 0):] if afc & 1 else b""

		def pes_ts(p):
		    if not p[1] & 0x40:
		        return None
		    q = payload(p)
		    if len(q) < 14 or q[:3] != b"\x00\x00\x01" or not 0xE0 <= q[3] <= 0xEF or q[7] >> 6 not in (2, 3):
		        return None
		    b = q[9:14]
		    return (((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | (b[4] >> 1)) / 90000

		def pcr(p):
		    if not (p[3] >> 4) & 2 or p[4] < 7 or not p[5] & 0x10:
		        return None
		    b = p[6:12]
		    base = b[0] << 25 | b[1] << 17 | b[2] << 9 | b[3] << 1 | b[4] >> 7
		    return base * 300 + ((b[4] & 1) << 8 | b[5])

		au = [(i, pes_ts(p)) for i, p in enumerate(pk) if pes_ts(p) is not None]
		order = sorted(t for _, t in au)
		duration = {a: b - a for a, b in zip(order, order[1:])}
		print(f"{sum(duration.get(t, 0.0) for i, t in au if head <= i < head + cut):.6f}")

		pcrs = [(i, ((p[1] & 0x1F) << 8) | p[2], pcr(p)) for i, p in enumerate(pk) if pcr(p) is not None]
		pid = max({x[1] for x in pcrs}, key=lambda q: sum(1 for x in pcrs if x[1] == q))
		mine = [(i, v) for i, q, v in pcrs if q == pid]
		cadence = round(statistics.median([b - a for (_, a), (_, b) in zip(mine, mine[1:]) if b > a]))
		before = [v for i, v in mine if i < head][-1]
		after = next(v for i, v in mine if i >= head + cut)

		null = b"\x47\x1f\xff\x10" + b"\xff" * 184
		def pcr_only(value):
		    base, ext = divmod(value, 300)
		    af = bytes([183, 0x10, base >> 25 & 0xFF, base >> 17 & 0xFF, base >> 9 & 0xFF, base >> 1 & 0xFF,
		                (base & 1) << 7 | 0x7E | ext >> 8, ext & 0xFF])
		    # Adaptation field only, no payload: the continuity counter does not advance.
		    return bytes([0x47, pid >> 8 & 0x1F, pid & 0xFF, 0x20]) + af + b"\xff" * (184 - len(af))

		ticks = []
		v = before + cadence
		while v < after:
		    ticks.append(v)
		    v += cadence
		filler = [null] * cut
		for k, value in enumerate(ticks):
		    filler[min(cut - 1, round((k + 1) * cut / (len(ticks) + 1)))] = pcr_only(value)

		kept_head, kept_tail = pk[:head], pk[head + cut:]
		open(out_hole, "wb").write(b"".join(kept_head + kept_tail))
		open(out_pad, "wb").write(b"".join(kept_head + filler + kept_tail))
	PY
}

echo "== control: expect ~0 s lost =="
dd if="$CLIP" of="$OUT/control.ts" bs=188 skip="$SKIP_PKTS" count=$((HEAD_PKTS + TAIL_PKTS)) status=none
python3 "$CONTENT" --input "$OUT/control.ts" --label control --json "$OUT/control.content.json"
c=$(field "$OUT/control.content.json" content_lost_s)
d=$(field "$OUT/control.content.json" content_dup_s)
if within "$c" 0 && within "$d" 0; then
	echo "  PASS control: content ${c}s lost, ${d}s duplicated"
else
	echo "  FAIL control: content ${c}s lost, ${d}s duplicated on an unimpaired slice"
	fail=1
fi

blind=0
for CUT in 2000 10000 50000; do
	T=$(build "$CLIP" "$SKIP_PKTS" "$HEAD_PKTS" "$CUT" "$TAIL_PKTS" "$OUT/hole-$CUT.ts" "$OUT/padhole-$CUT.ts")
	for KIND in hole padhole; do
		NAME="$KIND-$CUT"
		python3 "$CONTENT" --input "$OUT/$NAME.ts" --label "$NAME" --json "$OUT/$NAME.content.json" >/dev/null
		python3 "$PCRG" --input "$OUT/$NAME.ts" --domain wire --tolerance-ms "$TOLERANCE_MS" \
			--label "$NAME" --json "$OUT/$NAME.pcr.json" >/dev/null
		c=$(field "$OUT/$NAME.content.json" content_lost_s)
		p=$(field "$OUT/$NAME.pcr.json" media_lost_s)
		if within "$c" "$T"; then
			verdict="PASS"
		else
			verdict="FAIL"
			fail=1
		fi
		note=""
		if [ "$KIND" = padhole ]; then
			if within "$p" 0; then
				note="  [PCR grader blind to it]"
				blind=$((blind + 1))
			else
				note="  [PCR grader sees ${p}s]"
			fi
		fi
		printf '  %s %-14s truth %.3f s | content %.3f s | pcr(wire) %.3f s%s\n' "$verdict" "$NAME" "$T" "$c" "$p" "$note"
	done
done

echo "PCR grader blind to $blind of 3 padded holes"
if [ "$fail" -eq 0 ]; then
	echo "content grader: VALID on control, holes and padded holes (tolerance ${TOLERANCE_MS} ms)"
else
	echo "content grader: NOT VALID -- do not quote figures from it"
	exit 1
fi

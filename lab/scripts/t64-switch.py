#!/usr/bin/env python3
"""A synthetic unflagged encoder switch: the whole multiplex steps onto another clock at one packet.

Two encodes of one synthetic programme (H.264, MP2 and AC-3 under PAT, PMT, SDT and NIT), muxed
alike at a constant rate on clocks STEP seconds apart, with their GOPs out of phase, are cut into
one stream at one packet. There every PID changes source and breaks its continuity counter once;
the video and the MP2 are cut mid-PES on both sides; the second encode's video joins mid-GOP; the
tables are byte-identical either side; and no packet sets discontinuity_indicator. It is the switch
a contribution made between two encoders whose clocks were not locked (T34), without the capture.

usage: t64-switch.py <out.ts> [back|forward]
env:   STEP (16844.5 s), CUT (30 s into the first encode), SECS (60, each encode's length),
       BASE (33155.5 s, the lower clock, so a step back stays above zero; the upper is BASE + STEP),
       KEY (0.08 s, the second encode's first keyframe after the switch, in decode order)
"""

import bisect
import os
import subprocess
import sys
import tempfile

TS = 188
WRAP = 1 << 33
STEP = float(os.environ.get("STEP", "16844.5"))
CUT = float(os.environ.get("CUT", "30"))
SECS = float(os.environ.get("SECS", "60"))
BASE = float(os.environ.get("BASE", "33155.5"))
KEY = float(os.environ.get("KEY", "0.08"))
# The second encode starts this far into the programme, and cuts its GOPs at another length (frames
# at 25 Hz).
SKEW = 0.28
GOP_A, GOP_B = 24, 30


def encode(path, offset, skew, gop, muxdelay):
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    for graph in ("testsrc2=size=1280x720:rate=25", "sine=frequency=1000:sample_rate=48000",
                  "sine=frequency=440:sample_rate=48000"):
        cmd += ["-ss", str(skew), "-t", str(SECS), "-f", "lavfi", "-i", graph]
    cmd += [
        "-map", "0:v", "-map", "1:a", "-map", "2:a",
        "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-pix_fmt", "yuv420p",
        "-g", str(gop), "-keyint_min", str(gop), "-sc_threshold", "0", "-bf", "2",
        "-b:v", "4M", "-maxrate", "4M", "-bufsize", "4M", "-x264-params", "nal-hrd=cbr",
        "-c:a:0", "mp2", "-b:a:0", "192k", "-c:a:1", "ac3", "-b:a:1", "192k",
        "-f", "mpegts", "-muxrate", "6000000", "-pcr_period", "20", "-mpegts_flags", "+nit",
        "-mpegts_service_id", "1", "-mpegts_pmt_start_pid", "0x100", "-mpegts_start_pid", "0x101",
        "-metadata", "service_provider=synthetic", "-metadata", "service_name=switch",
        "-muxdelay", str(muxdelay), "-output_ts_offset", str(offset), path,
    ]
    subprocess.run(cmd, check=True)
    data = open(path, "rb").read()
    return [bytearray(data[i:i + TS]) for i in range(0, len(data) - TS + 1, TS)]


def pid(p):
    return (p[1] & 0x1F) << 8 | p[2]


def pusi(p):
    return bool(p[1] & 0x40)


def payload_at(p):
    afc = (p[3] >> 4) & 3
    if not afc & 1:
        return None
    off = 5 + p[4] if afc & 2 else 4
    return off if off < TS else None


def flags(p):
    """The adaptation field's flag byte, or 0."""
    return p[5] if (p[3] & 0x20) and p[4] else 0


def pcr(p):
    if not flags(p) & 0x10 or p[4] < 7:
        return None
    return p[6] << 25 | p[7] << 17 | p[8] << 9 | p[9] << 1 | p[10] >> 7


def stamp(p):
    """The decode time of a PES start in this packet (its DTS, else its PTS), when its header is
    whole."""
    off = payload_at(p)
    if off is None or not pusi(p) or p[off:off + 3] != b"\0\0\1" or not p[off + 7] & 0x80:
        return None
    b = p[off + 14:off + 19] if p[off + 7] & 0x40 else p[off + 9:off + 14]
    return ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1


def streams(pkts):
    """The PMT's PCR PID and elementary PIDs, from the first PMT."""
    for p in pkts:
        if pid(p) == 0x100 and pusi(p):
            s = p[payload_at(p) + 1 + p[payload_at(p)]:]
            pcr_pid = (s[8] & 0x1F) << 8 | s[9]
            i = 12 + ((s[10] & 0x0F) << 8 | s[11])
            end = 3 + ((s[1] & 0x0F) << 8 | s[2]) - 4
            es = []
            while i < end:
                es.append(((s[i + 1] & 0x1F) << 8 | s[i + 2], s[i]))
                i += 5 + ((s[i + 3] & 0x0F) << 8 | s[i + 4])
            return pcr_pid, es
    sys.exit("no PMT")


def interleave(pkts, es):
    """Spread each PES over the packets until its PID's next PES, as a broadcast multiplexer does
    (FFmpeg writes each PES whole), and re-stamp each PCR for its new place at the constant rate."""
    slot = [float(k) for k in range(len(pkts))]
    for q in es:
        runs = []
        for k, p in enumerate(pkts):
            if pid(p) == q:
                if pusi(p) or not runs:
                    runs.append([])
                runs[-1].append(k)
        for run, nxt in zip(runs, runs[1:]):
            for n, k in enumerate(run):
                slot[k] = run[0] + n * (nxt[0] - run[0]) / len(run)
    out = [pkts[k] for k in sorted(range(len(pkts)), key=slot.__getitem__)]
    stamped = [(k, pcr27(p)) for k, p in enumerate(pkts) if pcr27(p) is not None]
    (k0, c0), (k1, c1) = stamped[0], stamped[-1]
    per = (c1 - c0) // (k1 - k0)
    first = next(k for k, p in enumerate(out) if pcr27(p) is not None)
    for k, p in enumerate(out):
        if pcr27(p) is not None:
            c = c0 + (k - first) * per
            base, ext = (c // 300) % WRAP, c % 300
            p[6:12] = bytes([base >> 25 & 0xFF, base >> 17 & 0xFF, base >> 9 & 0xFF, base >> 1 & 0xFF,
                             (base & 1) << 7 | 0x7E | ext >> 8, ext & 0xFF])
    return out


def pcr27(p):
    """The full PCR, in 27 MHz ticks."""
    if pcr(p) is None:
        return None
    return pcr(p) * 300 + ((p[10] & 1) << 8 | p[11])


def first_from(pkts, i, want):
    for k in range(i, len(pkts)):
        if pid(pkts[k]) == want and payload_at(pkts[k]) is not None:
            return k
    return None


def seconds_in(pkts, offset, video):
    """Index of the first packet whose PCR, less the encode's clock offset, is past CUT."""
    for k, p in enumerate(pkts):
        if pid(p) == video and pcr(p) is not None and pcr(p) / 90000 - offset >= CUT:
            return k
    sys.exit("encode shorter than CUT")


def step(a, b):
    """b - a in seconds, the shorter way round the 33-bit clock."""
    return ((b - a + WRAP // 2) % WRAP - WRAP // 2) / 90000


def main():
    out = sys.argv[1]
    back = (sys.argv[2] if len(sys.argv) > 2 else "back") == "back"
    off_a, off_b = (BASE + STEP, BASE) if back else (BASE, BASE + STEP)
    with tempfile.TemporaryDirectory() as tmp:
        a = encode(os.path.join(tmp, "a.ts"), off_a, 0, GOP_A, 0.7)
        b = encode(os.path.join(tmp, "b.ts"), off_b, SKEW, GOP_B, 0.9)
    video, es = streams(a)
    if streams(b) != (video, es):
        sys.exit("the two encodes' PMTs differ")
    audio = next(p for p, t in es if t in (0x03, 0x04))
    a, b = (interleave(x, [q for q, _ in es]) for x in (a, b))

    # The first encode stops before i, mid-PES on the video and the MP2.
    i = seconds_in(a, off_a, video)
    while any(pusi(a[first_from(a, i, s)]) for s in (video, audio)):
        i += 1
    # The second takes over at j, mid-PES on both, its first whole video PES not a keyframe and
    # its first keyframe KEY later in decode order.
    starts = [k for k, p in enumerate(b) if pid(p) == video and pusi(p)]
    keys = [k for k in starts if flags(b[k]) & 0x40]
    j = seconds_in(b, off_b - SKEW - GOP_B / 25 / 2, video)
    while True:
        nv, na = first_from(b, j, video), first_from(b, j, audio)
        if not pusi(b[nv]) and not pusi(b[na]):
            k = starts[bisect.bisect_left(starts, nv)]
            key = keys[bisect.bisect_left(keys, nv)]
            if k != key and abs((stamp(b[key]) - stamp(b[k])) / 90000 - KEY) < 0.02:
                break
        j += 1

    # Every PID breaks its continuity counter once, as at the real switch.
    last = {}
    for p in a[:i]:
        if payload_at(p) is not None:
            last[pid(p)] = p[3] & 0x0F
    seen = set()
    for p in b[j:]:
        q = pid(p)
        if q == 0x1FFF or q not in last or payload_at(p) is None or q in seen:
            continue
        seen.add(q)
        cc = p[3] & 0x0F
        if cc in (last[q], (last[q] + 1) & 0x0F):
            bump = (last[q] + 9 - cc) & 0x0F
            for r in b[j:]:
                if pid(r) == q:
                    r[3] = (r[3] & 0xF0) | ((r[3] + bump) & 0x0F)
    spliced = a[:i] + b[j:]
    if any(flags(p) & 0x80 for p in spliced):
        sys.exit("a packet sets discontinuity_indicator")
    with open(out, "wb") as f:
        f.write(b"".join(spliced))

    def last_of(pkts, want, fn):
        return next(fn(p) for p in reversed(pkts) if pid(p) == want and fn(p) is not None)

    def first_of(pkts, want, fn):
        return next(fn(p) for p in pkts if pid(p) == want and fn(p) is not None)

    print(f"{out}: {len(spliced)} packets, the switch at packet {i} ({'back' if back else 'forward'})")
    s = step(last_of(a[:i], video, pcr), first_of(b[j:], video, pcr))
    print(f"  PCR (PID {video}) steps {s:+.3f} s")
    for q, t in es:
        s = step(last_of(a[:i], q, stamp), first_of(b[j:], q, stamp))
        print(f"  PES PID {q} (type 0x{t:02x}) steps {s:+.3f} s")
    for q in (0x0000, 0x0010, 0x0011, 0x0100):
        pa = next(p for p in reversed(a[:i]) if pid(p) == q and pusi(p))
        pb = next(p for p in b[j:] if pid(p) == q and pusi(p))
        print(f"  PID 0x{q:04x} table {'identical' if pa[4:] == pb[4:] else 'DIFFERS'} either side")


if __name__ == "__main__":
    main()

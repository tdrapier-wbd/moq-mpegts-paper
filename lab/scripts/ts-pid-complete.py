#!/usr/bin/env python3
"""Does an export carry every unit of every elementary stream, between where it joins and where it stops?

`ts-tstd.py` and `pcrverify` grade only what is present, so a programme passes both with its audio
missing ([T47](../test-47-fixed-delay-export.md)). This reads the source's PMT and asks, of each
elementary-stream PID it lists, what the output lacks inside the span the output covers.

- **PES PIDs** (video, audio, teletext) are keyed by DTS, or PTS where there is none, which the
  export carries through to within the microsecond timestamps' rounding (`--tolerance`, in 90 kHz
  ticks). Either side may pack several audio frames to a PES, and differently, so an MP2 or AC-3
  PID is counted as frames on both, at the duration their headers give, the output's first. A PES
  flagged `data_alignment_indicator` that opens with a frame carries the frames that start in it,
  walked by their lengths, so a lost PES or packet loses its frames. Any other PES carries its PTS
  and the frames after it up to the next PES. Another PID whose source PES are spaced at least
  twice the output's is counted as frames at the output's spacing. A unit is missing if the
  source has it between the output's first and last decode time on that PID and the output does
  not. *Start* is how far the PID's first unit trails
  the video's first, in decode time: what a join costs that track beyond the video's group. Units
  lost in the last `--tail` before the video's last are counted apart, as *tail*: a rig that stops
  its source before the capture ends loses a few there, which is teardown and not carriage.
- **Section PIDs** (SCTE-35) carry no timestamp, and their heartbeats repeat byte for byte, so they
  are counted: the source's sections inside the output's PCR span against the output's. The
  output's PCR runs on the source's timeline (PTS are carried through and the decode buffer ties
  PCR to them), but a section can sit up to a schedule lead either side of the span's edge, so a
  deficit of up to `--edge` sections is not resolved.
- **Duplicate packets** (a payload packet repeating its predecessor's continuity counter and
  payload, which ISO/IEC 13818-1 2.4.3.3 permits once) are discarded from both files, as a
  receiver discards them, so a source's duplicate is not a unit the output owes.

A source whose video PES carry several access units is not handled: the frame expansion meant for
audio misreads it.

Usage: ts-pid-complete.py <source.ts> <output.ts> [--max-start MS] [--edge N] [--tolerance TICKS]

Exits 1 if a PID the source lists is absent from the output, a PES unit is missing, a PID starts more
than `--max-start` after the video (default 1,200 ms, one GOP of the T47 clip), or a section PID is
short by more than `--edge` (default 2).
"""

import argparse
import bisect
import importlib.util
import os
import sys
from collections import Counter

TS = 188
WRAP = 1 << 33

_spec = importlib.util.spec_from_file_location(
    "ts_audio_pes", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ts-audio-pes.py")
)
tap = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tap)


def packets(path):
    with open(path, "rb") as f:
        while True:
            chunk = f.read(TS * 65536)
            if not chunk:
                return
            for off in range(0, len(chunk) - TS + 1, TS):
                p = chunk[off : off + TS]
                if p[0] == 0x47:
                    yield p


def payload(p):
    afc = (p[3] >> 4) & 3
    if not afc & 1:
        return b""
    i = 4 + (1 + p[4] if afc & 2 else 0)
    return p[i:] if i < TS else b""


def pcr(p):
    if (p[3] >> 4) & 2 and p[4] >= 7 and p[5] & 0x10:
        b = p[6:12]
        return (b[0] << 25 | b[1] << 17 | b[2] << 9 | b[3] << 1 | b[4] >> 7) % WRAP
    return None


def section(data):
    """The section starting at the pointer field, as far as this packet holds it."""
    if not data:
        return b""
    s = data[1 + data[0] :]
    if len(s) < 3:
        return b""
    return s[: 3 + (((s[1] & 0x0F) << 8) | s[2])]


class Unwrap:
    """A 33-bit clock made monotone across its rollover, relative to its first value."""

    def __init__(self):
        self.last = None
        self.add = 0

    def __call__(self, v):
        if self.last is not None and v + self.add < self.last - WRAP // 2:
            self.add += WRAP
        self.last = v + self.add
        return self.last


def codec(stream_type, info):
    """The audio frame parser's codec for a PMT entry, if it is MP2 or AC-3 (ATSC, or DVB's
    AC-3 descriptor)."""
    tags, i = set(), 0
    while i + 2 <= len(info):
        tags.add(info[i])
        i += 2 + info[i + 1]
    if stream_type in (0x03, 0x04):
        return "mp2"
    if stream_type == 0x81 or (stream_type == 0x06 and 0x6A in tags):
        return "ac3"
    return None


def frame_count(codec, es):
    """How many sync frames start in `es`, walked by their lengths from its first byte, or None if
    no frame opens it."""
    parse = tap.taf.mp2_frame_len if codec == "mp2" else tap.taf.ac3_frame_len
    pos = n = 0
    while length := parse(es[pos : pos + 8]):
        n += 1
        pos += length
    return n or None


def scan(path, es=None):
    """(es {pid: stream_type}, pcr pid, {pid: [pts]}, {pid: [(stc, section)]}, (first stc, last stc),
    {pid: [frames]}, {pid: frame ticks}).

    `es` is the PID set to read; None takes it from the file's own first PMT. The PCR PID and the
    audio codecs are the file's own either way. Beside each PES's timestamp, the frames an MP2 or
    AC-3 PES carries if it opens with one, else None."""
    pmt_pid = pcr_pid = None
    found, codecs, ticks = {}, {}, {}
    units, sections = {}, {}
    # The elementary stream so far of each audio PID's PES that opens with a frame.
    open_es, counts = {}, {}

    def close(pid):
        es = open_es.pop(pid, None)
        if es is not None and (n := frame_count(codecs[pid], es)):
            counts[pid][-1] = n
            ticks.setdefault(pid, tap.frame_ticks(codecs[pid], es, {"es_offset": 0}))

    stc = None
    span = [None, None]
    clocks = {}
    last = {}
    for p in packets(path):
        pid = ((p[1] & 0x1F) << 8) | p[2]
        pusi = p[1] & 0x40
        if pid == 0 and pusi and pmt_pid is None:
            s = section(payload(p))
            for k in range(8, len(s) - 4, 4):
                if (s[k] << 8 | s[k + 1]) != 0:
                    pmt_pid = ((s[k + 2] & 0x1F) << 8) | s[k + 3]
                    break
            continue
        if pid == pmt_pid and pusi and not found:
            s = section(payload(p))
            pcr_pid = ((s[8] & 0x1F) << 8) | s[9]
            k = 12 + (((s[10] & 0x0F) << 8) | s[11])
            while k + 5 <= len(s) - 4:
                es_pid = ((s[k + 1] & 0x1F) << 8) | s[k + 2]
                info = ((s[k + 3] & 0x0F) << 8) | s[k + 4]
                found[es_pid] = s[k]
                if kind := codec(s[k], s[k + 5 : k + 5 + info]):
                    codecs[es_pid] = kind
                k += 5 + info
            continue
        if pid == pcr_pid:
            v = pcr(p)
            if v is not None:
                stc = clocks.setdefault("pcr", Unwrap())(v)
                span[0] = stc if span[0] is None else span[0]
                span[1] = stc
        if (p[3] >> 4) & 1:
            key = (p[3] & 0x0F, payload(p))
            if last.get(pid) == key:
                continue
            last[pid] = key
        want = es if es is not None else found
        if pid not in want:
            continue
        if not pusi:
            if pid in open_es:
                open_es[pid] += payload(p)
            continue
        data = payload(p)
        if data[:3] == b"\x00\x00\x01":
            close(pid)
            if len(data) >= 14 and data[7] & 0x80:
                # DTS where there is one, so the span is in decode order: with B-frames the last
                # picture sent is not the last presented, and a capture cut there is no loss.
                b = data[14:19] if data[7] & 0x40 and len(data) >= 19 else data[9:14]
                ts = ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1
                units.setdefault(pid, []).append(clocks.setdefault(pid, Unwrap())(ts))
                counts.setdefault(pid, []).append(None)
                # data_alignment_indicator: the payload opens with a frame.
                if pid in codecs and data[6] & 0x04:
                    open_es[pid] = bytearray(data[9 + data[8] :])
        elif stc is not None:
            sections.setdefault(pid, []).append((stc, section(data)))
    for pid in list(open_es):
        close(pid)
    return found, pcr_pid, units, sections, span, counts, ticks


def frames(pes, spacing):
    """Each PES's PTS, and the frames after it at `spacing` that fall before the next PES."""
    out = []
    for t, nxt in zip(pes, pes[1:] + [None]):
        out.append(t)
        k = 1
        while nxt is not None and spacing and t + k * spacing < nxt - spacing // 2:
            out.append(t + k * spacing)
            k += 1
    return out


def counted(pes, counts, tick):
    """The frames of PES with PTS `pes`, `tick` apart: as many as each was counted to carry, or
    else up to the next PES."""
    pairs = sorted(zip(pes, counts), key=lambda pair: pair[0])
    out = []
    for (t, n), (nxt, _) in zip(pairs, pairs[1:] + [(None, None)]):
        if n is None:
            n = 1
            while nxt is not None and t + n * tick < nxt - tick // 2:
                n += 1
        out.extend(t + k * tick for k in range(n))
    return out


def mode_gap(sorted_ts):
    gaps = Counter(b - a for a, b in zip(sorted_ts, sorted_ts[1:]) if b > a)
    return gaps.most_common(1)[0][0] if gaps else 0


def least_gap(sorted_ts):
    return min((b - a for a, b in zip(sorted_ts, sorted_ts[1:]) if b > a), default=0)


def near(sorted_ts, t, tol):
    i = bisect.bisect_left(sorted_ts, t - tol)
    return i < len(sorted_ts) and sorted_ts[i] <= t + tol


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("output")
    ap.add_argument("--max-start", type=float, default=1200.0, help="ms after the video's first unit")
    ap.add_argument("--edge", type=int, default=2, help="section deficit not resolved at the span's edges")
    ap.add_argument("--tolerance", type=int, default=2, help="PTS match, in 90 kHz ticks")
    ap.add_argument("--tail", type=float, default=1000.0, help="ms before the video's last unit counted apart")
    a = ap.parse_args()

    es, video, src_units, src_sections, _, src_counts, src_ticks = scan(a.source)
    if not es:
        sys.exit("no PMT in the source")
    _, _, out_units, out_sections, out_span, out_counts, out_ticks = scan(a.output, es=set(es))
    fail = []
    first_video = min(out_units[video]) if out_units.get(video) else None
    last_video = max(out_units[video]) if out_units.get(video) else None
    tail = last_video - a.tail * 90 if last_video is not None else float("inf")
    head = ("PID", 5), ("type", 4), ("delivered", 9), ("expected", 8), ("missing", 7), ("tail", 4), ("foreign", 7)
    print("  ".join(f"{name:>{width}}" for name, width in head) + "  start ms")
    for pid in sorted(es):
        kind = f"{es[pid]:#04x}"
        if pid in src_units or pid in out_units:
            got = out_units.get(pid, [])
            if not got:
                print(f"{pid:>5}  {kind:>4}  {'absent':>9}")
                fail.append(f"PID {pid} absent")
                continue
            have = sorted(got)
            source = sorted(set(src_units.get(pid, [])))
            spacing = mode_gap(have)
            if tick := out_ticks.get(pid) or src_ticks.get(pid):
                have = sorted(counted(got, out_counts.get(pid, []), tick))
                source = sorted(set(counted(src_units.get(pid, []), src_counts.get(pid, []), tick)))
            # Expand only a source that packs several frames per PES, judged on the least gap: a
            # video PID mixing frame and field pictures has gaps of both sizes on both sides, in
            # proportions that vary along the clip.
            elif spacing and least_gap(source) >= 2 * spacing:
                source = frames(source, spacing)
            lo, hi = have[0] - a.tolerance, have[-1] + a.tolerance
            want = [t for t in source if lo <= t <= hi]
            lost = [t for t in want if not near(have, t, a.tolerance)]
            missing = [t for t in lost if t < tail]
            foreign = sum(1 for t in have if not near(source, t, a.tolerance))
            start = (have[0] - first_video) / 90.0 if first_video is not None else float("nan")
            print(
                f"{pid:>5}  {kind:>4}  {len(have):>9,}  {len(want):>8,}  {len(missing):>7,}  "
                f"{len(lost) - len(missing):>4,}  {foreign:>7,}  {start:+9.1f}"
            )
            if missing:
                fail.append(f"PID {pid}: {len(missing)} units missing, first at PTS {missing[0] % WRAP}")
            if start > a.max_start:
                fail.append(f"PID {pid} starts {start:.0f} ms after the video")
        else:
            got = out_sections.get(pid, [])
            if not got:
                print(f"{pid:>5}  {kind:>4}  {'absent':>9}")
                fail.append(f"PID {pid} absent")
                continue
            lo, hi = out_span
            want = [s for t, s in src_sections.get(pid, []) if lo <= t <= hi]
            short = len(want) - len(got)
            foreign = sum((Counter(s for _, s in got) - Counter(s for _, s in src_sections.get(pid, []))).values())
            row = f"{pid:>5}  {kind:>4}  {len(got):>9,}  {len(want):>8,}  {max(short, 0):>7,}"
            print(f"{row}  {'':>4}  {foreign:>7,}  (sections)")
            if short > a.edge:
                fail.append(f"PID {pid}: {short} sections short over the output's span")
    print("PASS" if not fail else "FAIL: " + "; ".join(fail))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())

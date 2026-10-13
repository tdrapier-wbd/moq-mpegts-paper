#!/usr/bin/env python3
"""Loop a clip into a long transport stream whose every join passes the T-STD.

`ts-continuous-source.py` shifts the whole clip by its PCR span. That keeps PCR, PTS and DTS
monotone, but each join splices the partial PES at the end of one pass onto the partial PES at
the start of the next, and steps every track's frame grid by whatever fraction of a frame the
span leaves over. On `CNNiEMEA2.ts` the MP2 and AC-3 buffers underflow there, and a 35 min
export run stopped at the first join ([T47](../test-47-fixed-delay-export.md) § Corrections).

This cuts each pass from one keyframe to another whose decode time is a whole number of every
track's PES periods later, so each track's timestamps continue exactly across the join:

- **Whole PES only.** A PES track keeps the PES whose timestamp lies in its window, which starts
  at the first PES to begin at or after the opening keyframe and lasts the pass. Video's window
  ends at the closing keyframe, in decode order. A PES split by the cut is dropped.
- **Sections are kept as they come.** Every section PID of the clip must start a section in each
  packet; the survey refuses one that does not, and reports a stray packet that continues none.
- **Bytes stay where they were.** A kept packet goes to its own slot, offset by the pass. A PES
  that ends after the pass's last slot spills into the next pass's first slots, behind which that
  track's next packets wait; packets that collide take the next free slot, in order. The survey
  reports each track's spill, and `ts-tstd.py` on a cut across a join is the judge.
- **PCR follows the output byte clock**, at the clip's own rate. A dropped packet that carried a
  PCR leaves an adaptation-only PCR packet in its slot. PTS and DTS advance by the pass length,
  which the byte clock matches to within half a packet per pass, without accumulating.
- **Continuity counters are renumbered per PID**, keeping any duplicate packet the clip carries.

What it does not reproduce is `ts-continuous-source.py`'s list: the join is a hard cut at a
keyframe, TDT/TOT and SCTE-35 payloads repeat each pass, and the bitrate profile repeats.

Usage:
  ts-seamless-loop.py <clip.ts> --passes N [-o out.ts] [--verify] [--min-pass S]
"""

import argparse
import math
import mmap
import sys
from collections import defaultdict, deque
from heapq import heappop, heappush, merge

TS = 188
NULL_PID = 0x1FFF
PTS_MOD = 1 << 33
PCR_MOD = PTS_MOD * 300


def stamp(b, off):
    return (
        ((b[off] & 0x0E) << 29)
        | (b[off + 1] << 22)
        | ((b[off + 2] & 0xFE) << 14)
        | (b[off + 3] << 7)
        | ((b[off + 4] & 0xFE) >> 1)
    )


def put_stamp(b, off, value, prefix):
    v = value % PTS_MOD
    b[off] = (prefix << 4) | ((v >> 29) & 0x0E) | 0x01
    b[off + 1] = (v >> 22) & 0xFF
    b[off + 2] = ((v >> 14) & 0xFE) | 0x01
    b[off + 3] = (v >> 7) & 0xFF
    b[off + 4] = ((v << 1) & 0xFE) | 0x01


def payload_offset(p):
    afc = (p[3] >> 4) & 3
    if not afc & 1:
        return None
    off = 4 if afc == 1 else 5 + p[4]
    return off if off < TS else None


def pcr_of(p):
    if not (p[3] >> 4) & 2 or p[4] < 7 or not p[5] & 0x10:
        return None
    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
    return base * 300 + (((p[10] & 1) << 8) | p[11])


def put_pcr(p, ticks):
    base, ext = divmod(ticks % PCR_MOD, 300)
    p[6] = (base >> 25) & 0xFF
    p[7] = (base >> 17) & 0xFF
    p[8] = (base >> 9) & 0xFF
    p[9] = (base >> 1) & 0xFF
    p[10] = ((base & 1) << 7) | 0x7E | ((ext >> 8) & 1)
    p[11] = ext & 0xFF


def pes_stamps(p, off):
    """(timestamp, [(offset, prefix)…]) of a PES header at `off`: DTS if present, else PTS."""
    if p[off : off + 3] != b"\x00\x00\x01" or off + 14 > TS:
        return None, ()
    flags = (p[off + 7] >> 6) & 3
    base = off + 9
    if flags == 2:
        return stamp(p, base), ((base, 2),)
    if flags == 3:
        return stamp(p, base + 5), ((base, 3), (base + 5, 1))
    return None, ()


def survey(m):
    """Per-PID PES lists, section PIDs, keyframes and the clip's byte clock."""
    n = len(m) // TS
    pes = defaultdict(list)  # pid -> [start, end, ts, key]
    kind = {}
    pcrs = []
    for i in range(n):
        p = m[i * TS : i * TS + TS]
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if pid == NULL_PID:
            continue
        v = pcr_of(p)
        if v is not None:
            pcrs.append((i, v))
        off = payload_offset(p)
        if off is None:
            continue
        if not p[1] & 0x40:
            if pes.get(pid):
                pes[pid][-1][1] = i
            elif kind.get(pid) == "sec":
                print(f"PID {pid}: packet {i} continues no section; copied as it is", file=sys.stderr)
            continue
        if p[off : off + 3] == b"\x00\x00\x01":
            kind[pid] = "pes"
            ts, _ = pes_stamps(p, off)
            key = bool((p[3] >> 4) & 2 and p[4] and p[5] & 0x40)
            pes[pid].append([i, i, ts, key])
        else:
            if kind.get(pid) == "pes":
                raise SystemExit(f"PID {pid} mixes PES and sections")
            kind[pid] = "sec"
            if p[off] != 0:
                raise SystemExit(f"PID {pid}: a section does not start its packet")
    (i0, c0), (i1, c1) = pcrs[0], pcrs[-1]
    tpkt = (c1 - c0) / (i1 - i0)  # 27 MHz ticks per packet
    return n, pes, kind, pcrs, tpkt


def period(stamps):
    d = sorted(b - a for a, b in zip(stamps, stamps[1:]))
    return d[len(d) // 2]


def plan(n, pes, kind, tpkt, vpid, min_pass):
    audio = [pid for pid in pes if pid != vpid and kind.get(pid) == "pes"]
    per = {}
    for pid in audio:
        ts = [e[2] for e in pes[pid]]
        p = period(ts)
        off = [(t - ts[0]) % p for t in ts]
        if any(off):
            raise SystemExit(f"PID {pid}: timestamps leave its {p}-tick grid")
        per[pid] = p
    grid = math.lcm(*per.values()) if per else 1
    keys = [e for e in pes[vpid] if e[3]]
    best = None
    for a in keys[: len(keys) // 4]:
        for b in reversed(keys):
            d = b[2] - a[2]
            if d < min_pass * 90000:
                break
            if d % grid:
                continue
            spill = spills(pes, a, d, per, vpid, tpkt)
            if spill is None:
                continue
            score = (max(spill.values()), -d)
            if best is None or score < best[0]:
                best = (score, a, b, d, spill)
    if best is None:
        raise SystemExit("no keyframe pair fits the grid")
    _, a, b, d, spill = best
    return {"grid": grid, "period": per, "k1": a, "k2": b, "d": d, "spill": spill}


def spills(pes, k1, d, per, vpid, tpkt):
    """Slots each track's first packet in the next pass waits behind its last in this one, or
    None if a window runs off the clip."""
    width = round(d * 300 / tpkt)
    out = {}
    win = window(pes, k1, d, per, vpid)
    for pid, (lo, hi) in win.items():
        inside = [e for e in pes[pid] if lo <= e[2] < hi]
        if not inside or pes[pid][-1][2] < hi:
            return None
        first = min(e[0] for e in inside)
        out[pid] = max(0, max(e[1] for e in inside) - first - width + 1)
    return out


def window(pes, k1, d, per, vpid):
    s = k1[0]
    win = {vpid: (k1[2], k1[2] + d)}
    for pid in per:
        first = next(e for e in pes[pid] if e[0] >= s)
        win[pid] = (first[2], first[2] + d)
    return win


def emit(m, out, n_passes, pes, kind, pcrs, tpkt, vpid, cfg):
    s = cfg["k1"][0]
    d = cfg["d"]
    win = window(pes, cfg["k1"], d, cfg["period"], vpid)
    stop = max(e[1] for pid, (lo, hi) in win.items() for e in pes[pid] if lo <= e[2] < hi) + 1
    # Byte-clock origin: the opening keyframe's own PCR time, interpolated.
    (ia, ca), (ib, cb) = next((pcrs[j], pcrs[j + 1]) for j in range(len(pcrs) - 1) if pcrs[j + 1][0] > s)
    t0 = ca + (s - ia) * (cb - ca) / (ib - ia)
    per_pass = d * 300 / tpkt
    # The last packet each PES track takes in a pass, relative to the pass's first slot: the
    # next pass's packets on that PID wait behind it, so two PES never interleave on one PID.
    last_rel = {pid: max(e[1] for e in pes[pid] if lo <= e[2] < hi) - s for pid, (lo, hi) in win.items()}

    def packets(k):
        base = round(k * per_pass)
        width = round((k + 1) * per_pass) - base
        prior = round((k - 1) * per_pass) if k else None
        inside = {}  # pid -> current PES is in window
        held = []  # a packet held behind its PID's spill is yielded once nothing can precede it
        for i in range(s, stop):
            p = m[i * TS : i * TS + TS]
            pid = ((p[1] & 0x1F) << 8) | p[2]
            rel = i - s
            while held and held[0][0] <= base + rel:
                yield heappop(held)
            if pid == NULL_PID:
                continue
            off = payload_offset(p)
            if kind.get(pid) == "pes":
                if off is not None and p[1] & 0x40:
                    ts, _ = pes_stamps(p, off)
                    lo, hi = win.get(pid, (0, -1))
                    inside[pid] = ts is not None and lo <= ts < hi
                if inside.get(pid):
                    desired = base + rel
                    if prior is not None and pid in last_rel:
                        desired = max(desired, prior + last_rel[pid] + 1)
                    heappush(held, (desired, k, i, pid, "keep"))
                elif rel < width and pcr_of(p) is not None:
                    heappush(held, (base + rel, k, i, pid, "pcr"))
            elif rel < width:
                heappush(held, (base + rel, k, i, pid, "keep"))
        while held:
            yield heappop(held)

    cc = {}
    prev = {}
    pending = deque()
    slot = 0
    held = 0
    late = defaultdict(int)
    null = bytes([0x47, 0x1F, 0xFF, 0x10]) + b"\xff" * 184

    def write(item):
        desired, k, i, pid, what = item
        late[pid] = max(late[pid], slot - desired)
        if what == "pcr":
            p = bytearray([0x47, pid >> 8 & 0x1F, pid & 0xFF, 0x20 | cc.get(pid, 0), 183, 0x10])
            p += b"\x00" * 6 + b"\xff" * 176
        else:
            p = bytearray(m[i * TS : i * TS + TS])
            if k:
                off = payload_offset(p)
                if off is not None and p[1] & 0x40:
                    for o, prefix in pes_stamps(p, off)[1]:
                        put_stamp(p, o, stamp(p, o) + k * d, prefix)
            if (p[3] >> 4) & 1:
                # Only the clip's own: two passes' identical heartbeats can share a counter.
                body = bytes(m[i * TS + 4 : i * TS + TS])
                dup = prev.get(pid) == (k, p[3] & 0x0F, body)
                prev[pid] = (k, p[3] & 0x0F, body)
                if pid not in cc:
                    cc[pid] = p[3] & 0x0F
                elif not dup:
                    cc[pid] = (cc[pid] + 1) & 0x0F
            p[3] = (p[3] & 0xF0) | cc.get(pid, p[3] & 0x0F)
        if pcr_of(p) is not None:
            put_pcr(p, round(t0 + slot * tpkt))
        out.write(p)

    stream = merge(*(packets(k) for k in range(n_passes)))
    nxt = next(stream, None)
    while nxt is not None or pending:
        while nxt is not None and nxt[0] <= slot:
            pending.append(nxt)
            nxt = next(stream, None)
        if pending:
            write(pending.popleft())
            held = max(held, len(pending))
        else:
            out.write(null)
        slot += 1
    return slot, held, dict(late)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clip")
    ap.add_argument("--passes", type=int, default=4)
    ap.add_argument("-o", "--out")
    ap.add_argument("--verify", action="store_true", help="survey and plan, write nothing")
    ap.add_argument("--min-pass", type=float, default=540.0, help="shortest pass, seconds")
    ap.add_argument("--vpid", type=int, default=0, help="video PID (default: the PCR PID)")
    a = ap.parse_args()

    with open(a.clip, "rb") as f:
        m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    n, pes, kind, pcrs, tpkt = survey(m)
    vpid = a.vpid or ((m[pcrs[0][0] * TS + 1] & 0x1F) << 8 | m[pcrs[0][0] * TS + 2])
    cfg = plan(n, pes, kind, tpkt, vpid, a.min_pass)
    rate = TS * 8 * 27e6 / tpkt
    k1, k2 = cfg["k1"], cfg["k2"]
    print(
        f"clip {n} packets at {rate:,.0f} b/s; video PID {vpid}; PES periods "
        f"{ {pid: p for pid, p in cfg['period'].items()} } ticks, grid {cfg['grid']} ({cfg['grid'] / 90:.0f} ms)\n"
        f"pass: keyframe at packet {k1[0]} to keyframe at packet {k2[0]}, "
        f"{cfg['d'] / 90000:.3f} s; next pass's first packet waits per PID (slots) {cfg['spill']}",
        file=sys.stderr,
    )
    if a.verify:
        return 0
    out = open(a.out, "wb") if a.out else sys.stdout.buffer
    slots, held, late = emit(m, out, a.passes, pes, kind, pcrs, tpkt, vpid, cfg)
    out.flush()
    print(
        f"wrote {slots} packets ({slots * TS * 8 / rate:.1f} s); most packets queued {held}; "
        f"latest placement per PID (slots) {late}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

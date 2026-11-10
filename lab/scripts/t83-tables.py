#!/usr/bin/env python3
"""What changes in the tables across each switch cut, and whether any SCTE-35 section is lost (T83).

    t83-tables.py <output prefix> --source <prefix> --vswitch-log <log> [--horizon 35] [--window 6]
                  [--latency 10] [--json]

<output prefix> and <source prefix> are t56-stamp.py captures: the switch's output and the source
as the legs read it. The cuts are the `cut <a>-><b> written` lines of t80-vswitch.py's log. For each
cut, each table's last value before it is compared with its first after it, within HORIZON s and
skipping 0.2 s each side: PAT and PMT by version and content (programmes, PCR PID, the PIDs and
stream types carried), every other section by PID, table_id, table_id_extension and version, so
SDT, NIT, EIT and TDT/TOT appear as they change, arrive or vanish. Every distinct SCTE-35 section
(stream_type 0x86 in a PMT) the source carried from LATENCY s after the output's first packet to
LATENCY s before its last must appear in the output; the ones that do not are listed with the
source time, and those within WINDOW + LATENCY of a cut are charged to it. A repeated section (a
heartbeat) is checked by its cadence instead: per SCTE-35 PID, the longest gap between sections
within 3 s of the cut, a miss if over 1.5 times the PID's median. A sparse table that is `not seen`
on a side with less than its repetition interval of capture is not a loss.
"""
import argparse
import bisect
import hashlib
import json
import re

PKT = 188


def load(prefix):
    rows = [tuple(map(float, r.split(","))) for r in open(prefix + ".idx") if r.strip()]
    offs, ts = [int(r[0]) for r in rows], [r[1] for r in rows]
    data = open(prefix + ".ts", "rb").read()
    return data, lambda off: ts[max(0, bisect.bisect_right(offs, off) - 1)]


def sections(prefix):
    """Every complete PSI/SI section, as (time, pid, section bytes), and the SCTE-35 PIDs seen."""
    data, clock = load(prefix)
    buf, out, pmt_pids, scte = {}, [], set(), set()
    for i in range(0, len(data) - PKT + 1, PKT):
        p = data[i:i + PKT]
        if p[0] != 0x47:
            continue
        pid = (p[1] & 0x1F) << 8 | p[2]
        if pid not in (0, 0x10, 0x11, 0x12, 0x14) and pid not in pmt_pids and pid not in scte:
            continue
        afc = (p[3] >> 4) & 3
        off = 4 + (1 + p[4] if afc & 2 else 0)
        if not afc & 1 or off >= PKT:
            continue
        pl, t = p[off:], clock(i)
        if p[1] & 0x40:
            ptr = pl[0]
            if pid in buf:
                buf[pid] += pl[1:1 + ptr]
            done, buf[pid] = buf.get(pid, b""), bytearray(pl[1 + ptr:])
            chunks = [done]
        else:
            if pid not in buf:
                continue
            buf[pid] += pl
            chunks = []
        for chunk in chunks + [None]:
            b = buf[pid] if chunk is None else chunk
            while len(b) >= 3 and b[0] != 0xFF:
                n = 3 + ((b[1] & 0x0F) << 8 | b[2])
                if len(b) < n:
                    break
                s = bytes(b[:n])
                out.append((t, pid, s))
                b = b[n:]
                if pid == 0 and s[0] == 0x00:
                    pmt_pids |= {(s[j + 2] & 0x1F) << 8 | s[j + 3] for j in range(8, n - 4, 4) if s[j] << 8 | s[j + 1]}
                elif s[0] == 0x02 and pid in pmt_pids:
                    j, end = 12 + ((s[10] & 0x0F) << 8 | s[11]), n - 4
                    while j + 5 <= end:
                        if s[j] == 0x86:
                            scte.add((s[j + 1] & 0x1F) << 8 | s[j + 2])
                        j += 5 + ((s[j + 3] & 0x0F) << 8 | s[j + 4])
            if chunk is None:
                buf[pid] = bytearray(b)
    return out, scte


def describe(pid, s):
    """A table's key and a readable value: PAT and PMT by content, the rest by version."""
    tid = s[0]
    if not s[1] & 0x80 or len(s) < 8:
        return (pid, tid), "present"
    ext, ver = s[3] << 8 | s[4], (s[5] >> 1) & 0x1F
    if tid == 0x00:
        progs = sorted((s[j] << 8 | s[j + 1], (s[j + 2] & 0x1F) << 8 | s[j + 3]) for j in range(8, len(s) - 4, 4))
        return (pid, tid, ext), f"v{ver} programmes {progs}"
    if tid == 0x02:
        pcr = (s[8] & 0x1F) << 8 | s[9]
        j, end, es = 12 + ((s[10] & 0x0F) << 8 | s[11]), len(s) - 4, []
        while j + 5 <= end:
            es.append(((s[j + 1] & 0x1F) << 8 | s[j + 2], s[j]))
            j += 5 + ((s[j + 3] & 0x0F) << 8 | s[j + 4])
        return (pid, tid, ext), f"v{ver} PCR {pcr} streams {sorted(es)}"
    return (pid, tid, ext), f"v{ver}"


def tables(secs, cut, horizon):
    """Each table's last value before the cut and first after it, within horizon s of it."""
    before, after = {}, {}
    for t, pid, s in secs:
        if s[0] == 0xFC or not cut - horizon <= t <= cut + horizon or abs(t - cut) < 0.2:
            continue
        k, v = describe(pid, s)
        if t < cut:
            before[k] = v
        else:
            after.setdefault(k, v)
    return before, after


def name(k):
    tid = k[1]
    label = {0x00: "PAT", 0x02: "PMT", 0x40: "NIT", 0x41: "NIT other", 0x42: "SDT", 0x46: "SDT other",
             0x4A: "BAT", 0x4E: "EIT p/f", 0x4F: "EIT p/f other", 0x70: "TDT", 0x73: "TOT"}.get(tid)
    if label is None and 0x50 <= tid <= 0x6F:
        label = "EIT schedule"
    label = label or f"table 0x{tid:02X}"
    return f"{label} (PID {k[0]}{', ext ' + str(k[2]) if len(k) > 2 else ''})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("output")
    ap.add_argument("--source", required=True)
    ap.add_argument("--vswitch-log", required=True)
    ap.add_argument("--window", type=float, default=6.0)
    ap.add_argument("--horizon", type=float, default=35.0)
    ap.add_argument("--latency", type=float, default=10.0)
    ap.add_argument("--json", action="store_true")
    o = ap.parse_args()
    cuts = [(float(m.group(1)), m.group(2)) for m in
            (re.match(r"([0-9.]+) cut (\d->\d) written", r) for r in open(o.vswitch_log)) if m]
    out, _ = sections(o.output)
    src, scte = sections(o.source)
    res = {"cuts": [], "scte35_pids": sorted(scte)}
    for t, how in cuts:
        before, after = tables(out, t, o.horizon)
        diff = []
        for k in sorted(before.keys() | after.keys(), key=lambda k: (k[0], k[1], k[2] if len(k) > 2 else -1)):
            b, a = before.get(k), after.get(k)
            if b != a:
                diff.append(f"{name(k)}: {b or 'not seen'} -> {a or 'not seen'}")
        res["cuts"].append({"t": round(t, 3), "cut": how, "changes": diff})
    first, last = (out[0][0], out[-1][0]) if out else (0, 0)
    have = {hashlib.sha1(s).hexdigest() for _, pid, s in out if s[0] == 0xFC}
    want = {}
    for t, pid, s in src:
        if s[0] == 0xFC and first + o.latency <= t <= last - o.latency:
            want.setdefault(hashlib.sha1(s).hexdigest(), t)
    lost = sorted(t for h, t in want.items() if h not in have)
    res["scte35"] = {"source_sections": len(want), "lost": len(lost), "lost_at": [round(t - first, 1) for t in lost]}
    at = {}
    for t, pid, s in out:
        if s[0] == 0xFC:
            at.setdefault(pid, []).append(t)
    for c in res["cuts"]:
        c["scte35_lost_near"] = sum(1 for t in lost if abs(t - c["t"]) <= o.window + o.latency)
        c["scte35_gaps"] = {}
        for pid, ts in sorted(at.items()):
            med = sorted(b - a for a, b in zip(ts, ts[1:]))[len(ts) // 2 - 1] if len(ts) > 2 else None
            near = [b - a for a, b in zip(ts, ts[1:]) if c["t"] - 3 <= b and a <= c["t"] + 3]
            if med and near:
                c["scte35_gaps"][pid] = {"longest_ms": round(1000 * max(near)), "median_ms": round(1000 * med),
                                         "missed": max(near) > 1.5 * med}
    if o.json:
        print(json.dumps(res, indent=1))
        return
    print(f"SCTE-35 PIDs {res['scte35_pids']}: {len(want)} distinct sections in the source over the output's span, "
          f"{len(lost)} missing from the output{' at ' + str(res['scte35']['lost_at']) if lost else ''}")
    for c in res["cuts"]:
        gaps = "; ".join(f"PID {p} {g['longest_ms']} ms (median {g['median_ms']}){' MISSED' if g['missed'] else ''}"
                         for p, g in c["scte35_gaps"].items())
        print(f"cut {c['cut']} at {c['t'] - first:.1f} s: {len(c['changes'])} table change(s), "
              f"{c['scte35_lost_near']} distinct SCTE-35 section(s) lost near it; longest SCTE-35 gap {gaps or '-'}")
        for d in c["changes"]:
            print("   " + d)


if __name__ == "__main__":
    main()

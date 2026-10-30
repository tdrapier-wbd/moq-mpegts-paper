#!/usr/bin/env python3
"""T69's grader.

    t69-grade.py strip IN OUT              IN less PIDs 0 and 0x64 (the PAT and PMT a packager injects)
    t69-grade.py span REF CAPTURE OUT [W]  REF's (or W's) packets over CAPTURE's span, matched less PSI and nulls
    t69-grade.py pmt CAPTURE               PMT sections on 0x64: how many carry BISS-CA's CA_descriptor
    t69-grade.py segs KEEP_DIR             criterion 7: segment count, EXTINF, the first packet on 111
    t69-grade.py recv LOG HASHES           criterion 2: decrypted segments against the origin's record
    t69-grade.py revoked LOG WRITE_END     criterion 4: what a viewer handed on after the write ended
    t69-grade.py trials TRIALS_JSON        criterion 3: per PoP, the time to the first refusal
"""
import glob
import json
import os
import statistics
import sys

PKT = 188


def packets(path):
    buf = open(path, "rb").read()
    return [buf[i : i + PKT] for i in range(0, len(buf) - PKT + 1, PKT)]


def pid(p):
    return (p[1] & 0x1F) << 8 | p[2]


def strip(src, dst):
    ps = packets(src)
    keep = [p for p in ps if pid(p) not in (0, 0x64)]
    open(dst, "wb").write(b"".join(keep))
    print(f"strip: {len(ps) - len(keep)} of {len(ps)} packets on PIDs 0 and 0x64 removed from {os.path.basename(src)}")


def pmt(path):
    n = with_ca = 0
    for p in packets(path):
        if pid(p) != 0x64 or not p[1] & 0x40:
            continue
        off = 4 + (1 + p[4] if p[3] & 0x20 else 0)
        sec = p[off + 1 + p[off] :]
        if sec[0] != 0x02:
            continue
        n += 1
        pil = (sec[10] & 0x0F) << 8 | sec[11]
        d, i = sec[12 : 12 + pil], 0
        while i + 2 <= len(d):
            tag, ln = d[i], d[i + 1]
            if tag == 0x09 and ln >= 4 and (d[i + 2] << 8 | d[i + 3]) == 0x2610 and ((d[i + 4] & 0x1F) << 8 | d[i + 5]) == 0x200:
                with_ca += 1
                break
            i += 2 + ln
    print(f"pmt: {n} PMT sections, {with_ca} with CA_descriptor 0x2610/ECM 0x200")
    print("pmt PASS" if n and n == with_ca else "pmt FAIL")


def span(ref, cap, out, write=None):
    def groom(ps):
        g, index = [], []
        for i, p in enumerate(ps):
            if pid(p) in (0, 0x64, 0x1FFF):
                continue
            if p[3] & 0x20 and p[4] >= 7 and p[5] & 0x10:
                p = p[:6] + bytes(6) + p[12:]
            g.append(p)
            index.append(i)
        return g, index

    r = packets(ref)
    g_ref, index = groom(r)
    g_cap, _ = groom(packets(cap))
    hay, n = b"".join(g_ref), 8

    def locate(needle):
        off = hay.find(needle)
        while off >= 0 and off % PKT:
            off = hay.find(needle, off + 1)
        return None if off < 0 else off // PKT

    first, last = locate(b"".join(g_cap[:n])), locate(b"".join(g_cap[-n:]))
    if first is None or last is None:
        print("span: the capture's first or last packets are not in the reference")
        return
    lo, hi = index[first], index[last + n - 1]
    src = packets(write) if write else r
    open(out, "wb").write(b"".join(src[lo : hi + 1]))
    print(f"span: reference packets {lo}..{hi} ({(hi - lo + 1) * PKT * 8 / 9.95e6:.1f} s at the stimulus rate) written to {out}")


def segs(keep):
    extinf = {}
    for pl in sorted(glob.glob(os.path.join(keep, "pl-*.m3u8"))):
        dur = None
        for line in open(pl):
            line = line.strip()
            if line.startswith("#EXTINF:"):
                dur = float(line.split(":", 1)[1].rstrip(","))
            elif line and not line.startswith("#") and dur is not None:
                extinf[os.path.basename(line)] = dur
                dur = None
    names = sorted(f for f in os.listdir(keep) if f.endswith(".ts"))
    rai = pusi = 0
    first_pids = {}
    for f in names:
        ps = packets(os.path.join(keep, f))
        if ps:
            first_pids[pid(ps[0])] = first_pids.get(pid(ps[0]), 0) + 1
        v = next((p for p in ps if pid(p) == 111), None)
        if v is None:
            continue
        pusi += bool(v[1] & 0x40)
        rai += bool(v[3] & 0x20 and v[4] > 0 and v[5] & 0x40)
    d = [extinf[n] for n in names if n in extinf]
    print(f"segs: {len(names)} segments, {len(d)} with an EXTINF; EXTINF min {min(d, default=0):.3f} median "
          f"{statistics.median(d) if d else 0:.3f} max {max(d, default=0):.3f} s")
    print(f"segs: first packet on 111 starts a PES in {pusi}, has random_access_indicator in {rai}; "
          f"first packet's PID: {', '.join(f'{k:#x} x{v}' for k, v in sorted(first_pids.items()))}")


def recv(log, hashes):
    ref = {}
    for line in open(hashes):
        f = line.rstrip("\n").split("\t")
        ref[int(f[0])] = {"name": f[1], "period": int(f[2]), "clear": f[3], "enc": f[4]}
    rows = [json.loads(l) for l in open(log)]
    seg = [r for r in rows if r["kind"] == "seg" and r["status"] == 200]
    match = sum(ref.get(r["seq"], {}).get("clear") == r["sha"] for r in seg)
    missing = [r["seq"] for r in seg if r["seq"] not in ref]
    same = sum(ref[r["seq"]]["clear"] == ref[r["seq"]]["enc"] for r in seg if r["seq"] in ref)
    periods = sorted({ref[r["seq"]]["period"] for r in seg if r["seq"] in ref})
    seqs = [r["seq"] for r in seg]
    holes = sum(b - a - 1 for a, b in zip(seqs, seqs[1:]) if b > a + 1)
    secs = sum(r["extinf"] for r in seg)
    other = {}
    for r in rows:
        if r["status"] != 200:
            other[(r["kind"], r["status"], r["deny"])] = other.get((r["kind"], r["status"], r["deny"]), 0) + 1
    pops = sorted({r["pop"] for r in rows if r["pop"]})
    print(f"recv: {len(seg)} segments ({secs:.1f} s), {match} decrypt to the clear record, {len(missing)} unrecorded, "
          f"{same} ciphertexts equal their clear bytes; sequence holes {holes}; key periods {len(periods)} "
          f"({len(periods) - 1} changes); keys fetched {sum(r['kind'] == 'key' for r in rows)}; PoPs {pops}")
    if other:
        print("recv: refused or failed requests " + ", ".join(f"{k}: {v}" for k, v in sorted(other.items(), key=str)))
    ok = seg and match == len(seg) and not same and len(periods) >= 3
    print("recv PASS" if ok else "recv FAIL")


def revoked(log, write_end):
    t = float(write_end)
    rows = [json.loads(l) for l in open(log)]
    after = [r for r in rows if r["t"] >= t]
    seg = [r for r in after if r["kind"] == "seg" and r["status"] == 200]
    first = next((r for r in after if r["status"] != 200), None)
    last_ok = max((r["t"] for r in after if r["status"] == 200), default=None)
    print(f"revoked: after the write, {len(seg)} segments handed on ({sum(r['extinf'] for r in seg):.2f} s of programme); "
          f"last admitted request {'%.2f s' % (last_ok - t) if last_ok else 'none'} after; first refusal "
          f"{'%.2f s after, on the %s (%s %s)' % (first['t'] - t, first['kind'], first['status'], first['deny']) if first else 'none'}")


def trials(path):
    tr = json.load(open(path))
    by = {}
    for t in tr:
        for p in t["probes"]:
            by.setdefault(p["probe"], []).append(p)
    w = [t["write_ms"] for t in tr]
    print(f"trials: {len(tr)}, write {min(w):.0f}-{max(w):.0f} ms (median {statistics.median(w):.0f}); "
          f"put failures {sum(t['put_rc'] != 0 for t in tr)}")
    for name, ps in by.items():
        f = [p["first_refusal_ms"] for p in ps if p["first_refusal_ms"] is not None]
        pre = sum(p["pre_n"] - p["pre_admitted"] for p in ps)
        print(f"  {name} ({', '.join(sorted({p['pop'] or '-' for p in ps}))}): first refusal after the write ends "
              f"median {statistics.median(f) if f else 'NA'} ms, min {min(f, default='NA')}, max {max(f, default='NA')} "
              f"over {len(f)}/{len(ps)}; reasons {sorted({p['first_deny'] for p in ps}, key=str)}; admitted after the "
              f"first refusal {sum(p['admitted_after_first_refusal'] for p in ps)} requests in "
              f"{sum(p['admitted_after_first_refusal'] > 0 for p in ps)} trials; refused before the write {pre}")


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    {"strip": strip, "span": span, "pmt": pmt, "segs": segs, "recv": recv, "revoked": revoked,
     "trials": trials}[cmd](*args)


if __name__ == "__main__":
    main()

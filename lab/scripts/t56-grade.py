#!/usr/bin/env python3
"""Grade a T56 run: what each export's decoder shows across each event.

    t56-grade.py <run dir> --ref <clip> [--select 8] [--json]

Each capture (sub<N>.ts with its arrival index sub<N>.idx, from t56-stamp.py) is decoded by FFmpeg
following PMT versions, and afresh wherever the PAT moves the programme to another PMT PID (as a
receiver re-acquires; FFmpeg does not follow the move), into two grey thumbnails per picture: 16x9 finds the
picture's frame in the reference decode, 64x36 judges it. A picture is *good* when its 64x36
distance to that frame is within three times the median of the pictures around it, so concealed or
corrupt pictures are not; each is placed at its last packet's arrival.

Per export and event: the *stall*, the longest gap between video packet arrivals; the *decoder
hole*, the longest gap between good pictures, beside the same before the event; the *outage*, from
the event's first gap over 0.5 s between good pictures to the first second of them with no such gap,
which a blip of pictures inside a hole does not split; the *programme lost* (positive) or *repeated*
(negative), the step in source frame less output picture across the outage; the latency step; the
switches the output marks (a PMT version change, the PIDs it leaves unflagged), from
t6-switch-grade.py; the export's restarts; and audio's longest gap.

The select cell has no fault: the grader splices export 1 into export 2 and back every --select
seconds, at packet boundaries by arrival, as a receiver's input select would, and grades each
splice of that capture as an event. Void conditions print first; the grade is also written to the
run's grade.json.
"""
import argparse
import bisect
import json
import operator
import os
import statistics
import subprocess
import sys

PKT = 188
FPS = 25
VIDEO = {0x01, 0x02, 0x1B, 0x24, 0x27}
AUDIO = {0x03, 0x04, 0x0F, 0x11, 0x81, 0x87}
HERE = os.path.dirname(os.path.abspath(__file__))
SMALL, LARGE = (16, 9), (64, 36)


def thumbs(path, extra_in=(), secs=None):
    """Decode a clip's first video stream into (small, large) grey thumbnails, one pair per picture."""
    sw, sh = SMALL
    lw, lh = LARGE
    fc = f"[0:v:0]split[a][b];[a]scale={sw}:{sh},format=gray[s];[b]scale={lw}:{lh},format=gray[l]"
    base = os.path.join("/tmp", f"t56g-{os.getpid()}")
    cmd = ["ffmpeg", "-nostdin", "-v", "error", *extra_in, "-i", path]
    if secs:
        cmd[cmd.index("-i"):cmd.index("-i")] = ["-t", str(secs)]
    cmd += ["-filter_complex", fc, "-fps_mode", "passthrough", "-map", "[s]", "-f", "rawvideo",
            base + ".s", "-fps_mode", "passthrough", "-map", "[l]", "-f", "rawvideo", base + ".l", "-y"]
    subprocess.run(cmd, stderr=subprocess.DEVNULL, check=False)
    out = []
    with open(base + ".s", "rb") as s, open(base + ".l", "rb") as large:
        a, b = s.read(), large.read()
    os.remove(base + ".s")
    os.remove(base + ".l")
    ns, nl = sw * sh, lw * lh
    for i in range(min(len(a) // ns, len(b) // nl)):
        out.append((a[i * ns:(i + 1) * ns], b[i * nl:(i + 1) * nl]))
    return out


def frames(path):
    """The capture's decoded pictures, in output order: (pkt_pos, key_frame, pict_type)."""
    r = subprocess.run(["ffprobe", "-v", "quiet", "-merge_pmt_versions", "1", "-select_streams", "v:0",
                        "-show_frames", "-show_entries", "frame=pkt_pos,key_frame,pict_type",
                        "-of", "compact=p=0", path], capture_output=True, text=True, check=False)
    out = []
    for line in r.stdout.splitlines():
        kv = dict(f.split("=", 1) for f in line.split("|") if "=" in f)
        pos = kv.get("pkt_pos", "N/A")
        out.append((int(pos) if pos.isdigit() else -1, kv.get("key_frame") == "1", kv.get("pict_type", "?")))
    return out


def pat_moves(data):
    """Byte offsets where the PAT moves the programme to another PMT PID, which FFmpeg does not
    follow and a receiver re-acquires at."""
    cuts, pmt = [], None
    for i in range(len(data) // PKT):
        p = data[i * PKT:(i + 1) * PKT]
        if p[0] != 0x47 or (p[1] & 0x1F) << 8 | p[2] or not p[1] & 0x40:
            continue
        off = 5 + p[4] if (p[3] >> 4) & 2 else 4
        s = off + 1 + p[off]
        if s + 12 >= PKT or p[s] != 0x00:
            continue
        for j in range(s + 8, min(s + 3 + ((p[s + 1] & 0x0F) << 8 | p[s + 2]) - 4, PKT - 3), 4):
            if p[j] << 8 | p[j + 1]:
                new = (p[j + 2] & 0x1F) << 8 | p[j + 3]
                if pmt is not None and new != pmt:
                    cuts.append(i * PKT)
                pmt = new
                break
    return cuts


def decode(path, data):
    """Pictures and thumbnails, decoded afresh from each PAT move on, pkt_pos in the whole file."""
    meta, pics = [], []
    bounds = [0, *pat_moves(data), len(data)]
    for a, b in zip(bounds, bounds[1:]):
        seg = path
        if len(bounds) > 2:
            seg = os.path.join("/tmp", f"t56g-{os.getpid()}-seg.ts")
            with open(seg, "wb") as f:
                f.write(data[a:b])
        m = frames(seg)
        t = thumbs(seg, extra_in=("-merge_pmt_versions", "1"))
        if len(m) != len(t):
            print(f"  {os.path.basename(path)} bytes {a}-{b}: ffprobe {len(m)} pictures, ffmpeg {len(t)}",
                  file=sys.stderr)
        n = min(len(m), len(t))
        meta += [(pos + a if pos >= 0 else -1, key, pt) for pos, key, pt in m[:n]]
        pics += t[:n]
        if seg != path:
            os.remove(seg)
    return meta, pics, len(bounds) - 2


def sad(a, b):
    return sum(map(abs, map(operator.sub, a, b))) / len(a)


def scan(data):
    """Video PES start -> last packet offset, and video and audio packet offsets."""
    pmt_pid, vpids, apids = None, set(), set()
    pes_last, open_pes, vpk, apk = {}, {}, [], []
    for i in range(len(data) // PKT):
        o = i * PKT
        p = data[o:o + PKT]
        if p[0] != 0x47:
            continue
        pid = (p[1] & 0x1F) << 8 | p[2]
        pusi = p[1] & 0x40
        afc = (p[3] >> 4) & 3
        off = 5 + p[4] if afc & 2 else 4
        if not afc & 1 or off >= PKT:
            continue
        if pid == 0 and pusi:
            s = off + 1 + p[off]
            if s + 12 < PKT and p[s] == 0x00:
                for j in range(s + 8, min(s + 3 + ((p[s + 1] & 0x0F) << 8 | p[s + 2]) - 4, PKT - 3), 4):
                    if p[j] << 8 | p[j + 1]:
                        pmt_pid = (p[j + 2] & 0x1F) << 8 | p[j + 3]
                        break
        elif pid == pmt_pid and pusi:
            s = off + 1 + p[off]
            if s + 12 < PKT and p[s] == 0x02:
                end = min(s + 3 + ((p[s + 1] & 0x0F) << 8 | p[s + 2]) - 4, PKT)
                j = s + 12 + ((p[s + 10] & 0x0F) << 8 | p[s + 11])
                vpids, apids = set(), set()
                while j + 5 <= end:
                    st, epid = p[j], (p[j + 1] & 0x1F) << 8 | p[j + 2]
                    (vpids if st in VIDEO else apids if st in AUDIO else set()).add(epid)
                    j += 5 + ((p[j + 3] & 0x0F) << 8 | p[j + 4])
        elif pid in vpids:
            vpk.append(o)
            if pusi:
                open_pes[pid] = o
                pes_last[o] = o
            elif pid in open_pes:
                pes_last[open_pes[pid]] = o
        elif pid in apids and pusi:
            apk.append(o)
    return pes_last, vpk, apk


class Clock:
    """Byte offset -> arrival time, from a t56-stamp.py index."""

    def __init__(self, idx):
        rows = [tuple(map(float, r.split(","))) for r in open(idx) if r.strip()]
        self.off = [int(r[0]) for r in rows]
        self.t = [r[1] for r in rows]

    def at(self, offset):
        return self.t[max(0, bisect.bisect_right(self.off, offset) - 1)]


def splice(run, cuts):
    """Write select.ts/.idx: export 1 until cuts[0], export 2 until cuts[1], and so on."""
    caps = []
    for n in (1, 2):
        data = open(os.path.join(run, f"sub{n}.ts"), "rb").read()
        caps.append((data, Clock(os.path.join(run, f"sub{n}.idx"))))
    bounds = [float("-inf"), *cuts, float("inf")]
    ptr = [0, 0]
    with open(os.path.join(run, "select.ts"), "wb") as ts, open(os.path.join(run, "select.idx"), "w") as idx:
        out, last = 0, None
        for k in range(len(bounds) - 1):
            data, clock = caps[k % 2]
            lo, hi = bounds[k], bounds[k + 1]
            i = ptr[k % 2]
            while i < len(data) // PKT and clock.at(i * PKT) < lo:
                i += 1
            while i < len(data) // PKT and (t := clock.at(i * PKT)) < hi:
                if t != last:
                    idx.write(f"{out},{t:.6f}\n")
                    last = t
                ts.write(data[i * PKT:(i + 1) * PKT])
                out += PKT
                i += 1
            ptr[k % 2] = i


def grade(run, name, ref, events, until, t0):
    path = os.path.join(run, name + ".ts")
    data = open(path, "rb").read()
    clock = Clock(os.path.join(run, name + ".idx"))
    pes_last, vpk, apk = scan(data)
    meta, pics, moves = decode(path, data)
    n = len(meta)
    # Match each picture to its reference frame, near the running offset; a poor match searches all.
    idx, d16, d64, run_d = [], [], [], []
    for k in range(n):
        s, large = pics[k]
        if run_d:
            c = k + int(statistics.median(run_d[-25:]))
            cand = range(max(0, c - 400), min(len(ref), c + 400))
        else:
            cand = range(len(ref))
        best = min(cand, key=lambda j: sad(s, ref[j][0])) if cand else 0
        dist = sad(s, ref[best][0])
        if run_d and dist > 12:
            alt = min(range(len(ref)), key=lambda j: sad(s, ref[j][0]))
            if sad(s, ref[alt][0]) < dist:
                best, dist = alt, sad(s, ref[alt][0])
        idx.append(best)
        d16.append(dist)
        d64.append(sad(large, ref[best][1]))
        run_d.append(best - k)
    arr = [clock.at(pes_last.get(meta[k][0], meta[k][0])) if meta[k][0] >= 0 else None for k in range(n)]
    good = []
    for k in range(n):
        w = d64[max(0, k - 312):k + 313]
        good.append(arr[k] is not None and d64[k] <= max(3 * statistics.median(w), 1.5))
    vt = [clock.at(o) for o in vpk]
    at = [clock.at(o) for o in apk]
    sw = json.loads(subprocess.run([sys.executable, os.path.join(HERE, "t6-switch-grade.py"), path],
                                   capture_output=True, text=True, check=False).stdout or "{}")
    switches = [(clock.at(s["packet"] * PKT), s) for s in sw.get("switches", [])]

    def longest(ts, lo, hi):
        """The longest gap starting in [lo, hi], as (length, start, end)."""
        ts = sorted(t for t in ts if t is not None)
        g = [(b - a, a, b) for a, b in zip(ts, ts[1:]) if lo <= a <= hi]
        return max(g) if g else (None, None, None)

    def r3(x):
        return round(x, 3) if x is not None else None

    rows = []
    times = [t for _, t in events] + [until]
    goods = [arr[k] for k in range(n) if good[k]]
    first = min((a for a in arr if a), default=events[0][1])
    settled = first
    for e, (ev, te) in enumerate(events):
        hi = min(te + 20, times[e + 1])
        if ev.startswith("select"):
            hi = min(hi, times[e + 1] - 0.5)
        hole, _, back = longest(goods, te - 0.5, hi)
        back = back or te
        # Output can resume in a blip, a few pictures, and stop again before it resumes for good:
        # it has resumed at the first second of good pictures with no gap over 0.5 s.
        sg = sorted(g for g in goods if back <= g < times[e + 1])
        resume, i = back, 0
        while i < len(sg):
            j = i
            while j + 1 < len(sg) and sg[j + 1] - sg[j] <= 0.5 and sg[j] - sg[i] < 1.0:
                j += 1
            if sg[j] - sg[i] >= 1.0:
                resume = sg[i]
                break
            i = j + 1
        sgo = sorted(goods)
        gap0 = next((x for x, y in zip(sgo, sgo[1:]) if te - 0.5 <= x <= hi and y - x > 0.5), None)
        before = [k for k in range(n) if good[k] and max(settled, te - 10) <= arr[k] < te - 0.5]
        stop = min([b2 for b2, a2 in zip(goods[1:], goods) if a2 > resume and b2 - a2 > 0.5] + [resume + 5.5])
        after = [k for k in range(n) if good[k] and resume + 0.2 <= arr[k] < stop]
        row = {"export": name, "event": ev, "t": round(te - t0, 1),
               "stall_s": r3(longest(vt, te - 0.5, hi)[0]), "hole_s": r3(hole),
               "outage_s": r3(resume - gap0) if gap0 is not None else None,
               "hole_before_s": r3(longest(goods, max(settled, te - 20), te - 1.5)[0]),
               "audio_gap_s": r3(longest(at, te - 0.5, hi)[0])}
        settled = resume + 0.5
        if before and after:
            db = statistics.median(idx[k] - k for k in before)
            da = statistics.median(idx[k] - k for k in after)
            row["lost_s"] = round((da - db) / FPS, 2)
            lb = statistics.median(arr[k] - idx[k] / FPS for k in before)
            la = statistics.median(arr[k] - idx[k] / FPS for k in after)
            row["latency_step_s"] = round(la - lb, 2)
        marks = [s for t, s in switches if te - 1 <= t < max(hi, back + 1)]
        row["switches"] = [f"{s['pmt_version']}{' unflagged ' + str(s['unflagged']) if s['unflagged'] else ''}"
                           for s in marks]
        row["bad_pictures"] = sum(1 for k in range(n) if arr[k] and te - 0.5 <= arr[k] < back + 5.5 and not good[k])
        rows.append(row)
    summary = {"export": name, "pictures": n, "pat_moves": moves,
               "cc_errors_outside_switches": sw.get("cc_errors_outside"),
               "pts_gaps_outside": len(sw.get("pts_gaps_outside", [])),
               "median_match": round(statistics.median(d16), 2) if d16 else None}
    return rows, summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--ref", required=True)
    ap.add_argument("--select", type=float, default=8.0)
    ap.add_argument("--caps", default="sub1,sub2", help="the recordings to grade (T58: sub1,sub2,sub3)")
    ap.add_argument("--arrive", action="store_true", help="also grade `arrive*` events (T58's restarts)")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    caps = a.caps.split(",")
    ev = [(r.split()[0], float(r.split()[1])) for r in open(os.path.join(a.run, "events.txt")) if r.strip()]
    t0 = ev[0][1]
    end = next(t for n, t in ev if n == "end")
    build = open(os.path.join(a.run, "build.txt")).read()
    void = []
    exits = [(n, t) for n, t in ev if "_exit_" in n]
    for name in caps:
        cap = os.path.join(a.run, f"{name}.idx")
        rows = [r for r in open(cap) if r.strip()] if os.path.exists(cap) else []
        if not rows or float(rows[-1].split(",")[1]) < end - 3:
            void.append(f"{name} does not cover the run")
    live = os.path.join(a.run, "live1.ts")
    if os.path.exists(live):
        lv = json.loads(subprocess.run([sys.executable, os.path.join(HERE, "t6-switch-grade.py"), live],
                                       capture_output=True, text=True, check=False).stdout or "{}")
        if lv.get("cc_errors_outside") or lv.get("switches"):
            void.append(f"source tap: {lv.get('cc_errors_outside')} continuity errors")
    secs = end - t0 + 30
    ref = thumbs(a.ref, secs=secs)
    print(f"reference: {len(ref)} pictures over {secs:.0f} s", file=sys.stderr)
    faults = [(n, t) for n, t in ev if n[:4] in ("kill", "term", "outa", "ligh")
              or (n.startswith("import") and t > t0) or (a.arrive and n.startswith("arrive"))]
    out = {"run": a.run, "build": build.splitlines()[1:3], "void": void, "restarts": exits, "rows": [], "summary": []}
    if "cell select" in build:
        e2 = next(t for n, t in ev if n == "export2_start")
        cuts = [e2 + 10 + a.select * j for j in range(int((end - e2 - 14) // a.select))]
        splice(a.run, cuts)
        names = [("select", [(("select2" if j % 2 == 0 else "select1"), c) for j, c in enumerate(cuts)])]
        starts = {n: next(t for m, t in ev if m == f"export{n}_start") for n in (1, 2)}
        names += [(f"sub{n}", [(f"export{n}_start", starts[n])]) for n in (1, 2)]
    else:
        names = [(name, faults) for name in caps]
    for name, evs in names:
        if not evs:
            continue
        rows, summ = grade(a.run, name, ref, evs, end, t0)
        out["rows"] += rows
        out["summary"].append(summ)
    with open(os.path.join(a.run, "grade.json"), "w") as f:
        json.dump(out, f, indent=1)
    if a.json:
        print(json.dumps(out, indent=1))
        return
    print(f"run {a.run}")
    for line in out["build"]:
        print(" ", line)
    print("VOID: " + "; ".join(void) if void else "void checks: pass")
    for n, t in exits:
        print(f"  restart: {n} at {t - t0:.1f} s")
    cols = ["export", "event", "t", "stall_s", "hole_s", "outage_s", "hole_before_s", "lost_s", "latency_step_s",
            "audio_gap_s", "bad_pictures", "switches"]
    print("\t".join(cols))
    for r in out["rows"]:
        print("\t".join(str(r.get(c, "-")) for c in cols))
    for s in out["summary"]:
        print("  " + ", ".join(f"{k} {v}" for k, v in s.items()))


if __name__ == "__main__":
    main()

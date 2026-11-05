#!/usr/bin/env python3
"""Grade T39 Part B: what the publisher side learns from a subscriber's feedback, and when.

  stim <control.ts> <faulted.ts> --pids P[,P] --for S
      The fault's extent: the first and last packet whose PID differs from the control's, each
      of them on a suppressed PID in the control. Prints `<onset byte> <end byte> packets=<n>
      span_s=<s>` and exits 1 unless the fault is there and spans at least 80 % of S on the
      control's own PCR.
  run <out dir> [--json grade.json]
      Every `<arm>-<n>/` trial t39b-echo-return.sh wrote, against the rules and criteria fixed in
      the test file (Part B), which are the constants below.

A row is STOPPED at the first snapshot whose `units` equal those of a snapshot received at least
STOP_S earlier, and resumes at the first snapshot whose `units` grew. The feedback is ABSENT
ABSENT_S after a snapshot with no successor in that time. An arm is classified by its first
alarm after onset and the alarms within CLASS_S of it.
"""

import argparse
import bisect
import json
import os
import sys

VIDEO = {111}
AUDIO = {121, 123}
GRADED = VIDEO | AUDIO
STOP_S = 2.0
ABSENT_S = 3.0
CLASS_S = 2.0
LATENCY_S = 6.0
RECOVER_S = 10.0
CADENCE_S = 1.5
SETTLE_S = 10.0
EXPECT = {"audio": "audio", "video": "video", "stall": "all", "relay": "absent"}
EXPECT_LOCAL = {"audio": "audio", "video": "video", "stall": "all", "relay": "all"}


# ---- stim -----------------------------------------------------------------------------------


def pcr_of(p):
    if not p[3] & 0x20 or p[4] == 0 or not p[5] & 0x10:
        return None
    b = p[6:11]
    return ((b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)) / 90000.0


def stim(args):
    pids = {int(x) for x in args.pids.split(",")}
    size = os.path.getsize(args.control)
    if size != os.path.getsize(args.faulted) or size % 188:
        print("the stimulus and the control differ in length, or are not whole packets")
        return 1
    first = last = None
    n = bad = idx = 0
    pcr0 = pcr1 = None
    with open(args.control, "rb") as a, open(args.faulted, "rb") as b:
        while True:
            ca, cb = a.read(188 * 8192), b.read(188 * 8192)
            if not ca:
                break
            for off in range(0, len(ca), 188):
                pa = ((ca[off + 1] & 0x1F) << 8) | ca[off + 2]
                pb = ((cb[off + 1] & 0x1F) << 8) | cb[off + 2]
                if pa != pb:
                    first = idx if first is None else first
                    last = idx
                    n += 1
                    bad += pa not in pids
                pcr = pcr_of(ca[off:off + 188])
                if pcr is not None:
                    pcr0 = (idx, pcr) if pcr0 is None else pcr0
                    pcr1 = (idx, pcr)
                idx += 1
    if first is None or pcr0 is None or pcr1[1] <= pcr0[1]:
        print("no fault: the stimulus is the control")
        return 1
    rate = (pcr1[0] - pcr0[0]) / (pcr1[1] - pcr0[1])
    span = (last - first) / rate
    print(f"{first * 188} {(last + 1) * 188} packets={n} span_s={span:.2f} off_pid={bad}")
    return 0 if bad == 0 and span >= 0.8 * args.dur else 1


# ---- run ------------------------------------------------------------------------------------


def tsv(path):
    if not os.path.exists(path):
        return []
    rows = []
    for line in open(path, errors="replace"):
        parts = line.rstrip("\n").split("\t", 2)
        if len(parts) >= 2:
            try:
                rows.append((float(parts[0]), parts[1], parts[2] if len(parts) > 2 else ""))
            except ValueError:
                pass
    return rows


def snapshots(path, key):
    """(rx time, {pid: (class, units, quiet)}, whole value) from stamped JSON lines."""
    out = []
    for t, body, rest in tsv(path):
        line = body if not rest else body + "\t" + rest
        try:
            value = json.loads(line)
        except ValueError:
            continue
        snap = value.get(key, value) if key else value
        rows = {}
        for pid, row in ((snap.get("mpegts") or {}).get("streams") or {}).items():
            rows[int(pid)] = (row.get("class", "data"), row.get("units", 0), row.get("quiet"))
        out.append((t, rows, value))
    return out


def row_alarms(snaps, only=None):
    """[(t, pid, 'stop'|'resume')] under the STOPPED rule: the audio and video rows, as the report
    classes them, or the PIDs in `only` whatever their class."""
    times = [s[0] for s in snaps]
    stopped, last, out = {}, {}, []
    for i, (t, rows, _) in enumerate(snaps):
        j = bisect.bisect_right(times, t - STOP_S) - 1
        for pid, (cls, units, _) in rows.items():
            if (pid not in only) if only else cls not in ("audio", "video"):
                continue
            if stopped.get(pid):
                if units > last.get(pid, units):
                    out.append((t, pid, "resume"))
                    stopped[pid] = False
            elif j >= 0 and pid in snaps[j][1] and snaps[j][1][pid][1] == units:
                out.append((t, pid, "stop"))
                stopped[pid] = True
            last[pid] = units
    return out


def absent_alarms(snaps, until):
    out = []
    for (t0, _, _), (t1, _, _) in zip(snaps, snaps[1:]):
        if t1 - t0 > ABSENT_S and t0 + ABSENT_S < until:
            out.append((t0 + ABSENT_S, None, "absent", t1))
    if snaps and snaps[-1][0] + ABSENT_S < until:
        out.append((snaps[-1][0] + ABSENT_S, None, "absent", None))
    return out


def classify(alarms, video=VIDEO, audio=AUDIO):
    """The first alarm and those within CLASS_S of it: (class, t, pids)."""
    if not alarms:
        return "none", None, set()
    t1 = alarms[0][0]
    near = [a for a in alarms if a[0] <= t1 + CLASS_S]
    if alarms[0][2] == "absent":
        return "absent", t1, set()
    pids = {a[1] for a in near if a[1] is not None}
    if any(a[1] is None for a in near) or (video | audio) <= pids:
        return "all", t1, pids
    if audio <= pids and not pids & video:
        return "audio", t1, pids
    if video <= pids and not pids & audio:
        return "video", t1, pids
    return "partial", t1, pids


def classes_at(snaps, t):
    """The report's own video and audio PIDs in the last snapshot before `t`."""
    before = [s for s in snaps if s[0] <= t] or snaps[:1]
    rows = before[-1][1] if before else {}
    return ({p for p, r in rows.items() if r[0] == "video"},
            {p for p, r in rows.items() if r[0] == "audio"})


def local_alarms(path):
    out = []
    for t, body, _ in tsv(path):
        try:
            e = json.loads(body)
        except ValueError:
            continue
        if e.get("event") != "alarm":
            continue
        pid = e.get("pid")
        if pid is None or pid in GRADED:
            out.append((t, pid, e.get("reason", "")))
    return out


def cadence(snaps, lo, hi):
    """Mean interval and full-row share of the snapshots in [lo, hi], or None if under 5 s."""
    sel = [s for s in snaps if lo <= s[0] <= hi]
    if hi - lo < 5 or len(sel) < 2:
        return None
    mean = (sel[-1][0] - sel[0][0]) / (len(sel) - 1)
    full = sum(GRADED <= set(s[1]) for s in sel) / len(sel)
    return round(mean, 3), round(full, 3)


def health(snaps, lo, hi):
    """TR 101 290 counters that moved in [lo, hi] (tier 1)."""
    keys = ("pcrRepetitionError", "pcrDiscontinuityIndicatorError", "ptsError",
            "continuityCountError", "patError", "pmtError", "tsSyncLoss", "crcError")

    def at(t):
        before = [s for s in snaps if s[0] <= t]
        snap = before[-1][2] if before else {}
        return (snap.get("mpegts") or {})

    a, b = at(lo), at(hi)
    return {k: b.get(k, 0) - a.get(k, 0) for k in keys if b.get(k, 0) != a.get(k, 0)}


def grade_trial(d):
    arm = open(os.path.join(d, "arm")).read().strip()
    marks = {name: t for t, name, _ in tsv(os.path.join(d, "marks.tsv"))}
    events = {name: t for t, name, _ in tsv(os.path.join(d, "events.tsv"))}
    onset = marks.get("onset", events.get("onset"))
    end = marks.get("end", events.get("end"))
    eof = marks.get("eof")
    echo = snapshots(os.path.join(d, "echo.tsv"), "feedback")
    rep = snapshots(os.path.join(d, "report.tsv"), None)
    r = {"trial": os.path.basename(d), "arm": arm, "snapshots": len(echo)}
    if not echo or eof is None:
        r["error"] = "no feedback" if not echo else "the source never ended"
        return r
    r["broadcasts"] = sorted({s[2].get("broadcast", "?") for s in echo})
    start = echo[0][0] + SETTLE_S
    alarms = sorted(
        [(t, p, k) for t, p, k in row_alarms(echo) if k == "stop"]
        + [a[:3] for a in absent_alarms(echo, eof)]
    )
    spans = [(start, onset if onset else eof)]
    if end:
        spans.append((end + RECOVER_S, eof))
    r["cadence"] = [cadence(echo, lo, hi) for lo, hi in spans]
    ok1 = all(c is None or (c[0] <= CADENCE_S and c[1] == 1.0) for c in r["cadence"])
    ok1 = ok1 and any(c is not None for c in r["cadence"])
    last = echo[-1][2]["feedback"]
    r["release_last"] = last.get("release", {})
    if arm == "control":
        false = [a for a in alarms if start <= a[0] <= eof]
        r["false_alarms"] = [(round(a[0] - start, 2), a[1], a[2]) for a in false]
        r["c1"] = ok1 and not false
        return r
    after = [a for a in alarms if a[0] >= onset]
    video, audio = classes_at(echo, onset)
    r["report_classes"] = {"video": sorted(video), "audio": sorted(audio)}
    cls, t1, pids = classify(after, video, audio)
    r["class"], r["pids"] = cls, sorted(pids)
    # Rows the report classes as data but whose units have a cadence: when each stopped.
    verbatim = [(t, p) for t, p, k in row_alarms(echo, {123, 131}) if k == "stop" and t >= onset]
    r["data_rows_stopped_s"] = {p: round(min(t for t, q in verbatim if q == p) - onset, 2)
                                for p in sorted({p for _, p in verbatim})}
    r["latency_s"] = round(t1 - onset, 2) if t1 else None
    loc = [a for a in local_alarms(os.path.join(d, "live.tsv")) if a[0] >= onset]
    lcls, lt1, lpids = classify([(t, p, "stop") for t, p, _ in loc])
    r["local_class"], r["local_pids"] = lcls, sorted(lpids)
    r["local_latency_s"] = round(lt1 - onset, 2) if lt1 else None
    # Recovery: each stopped row resumes, or the feedback returns, after the fault ends.
    if cls == "absent":
        nxt = [s[0] for s in echo if s[0] > end]
        r["recover_s"] = round(nxt[0] - end, 2) if nxt else None
    else:
        res = [(t, p) for t, p, k in row_alarms(echo) if k == "resume" and t > onset]
        back = [min((t for t, p in res if p == q), default=None) for q in pids]
        r["recover_s"] = (round(max(back) - end, 2)
                          if back and None not in back and end else None)
    tv, ta = classes_at(rep, onset)
    tcls, tt1, tpids = classify(sorted([(t, p, k) for t, p, k in row_alarms(rep)
                                        if k == "stop" and t >= onset]), tv, ta)
    r["tier1"] = {"class": tcls, "pids": sorted(tpids),
                  "latency_s": round(tt1 - onset, 2) if tt1 else None,
                  "tr101290": health(rep, onset, (end or onset) + 5), "snapshots": len(rep)}
    r["c1"] = ok1
    r["c2"] = cls == EXPECT[arm] and lcls == EXPECT_LOCAL[arm]
    r["c3"] = r["latency_s"] is not None and r["latency_s"] <= LATENCY_S and cls == EXPECT[arm]
    r["c4"] = r["recover_s"] is not None and r["recover_s"] <= RECOVER_S
    return r


def run(args):
    trials = sorted(
        os.path.join(args.out, x) for x in os.listdir(args.out)
        if os.path.exists(os.path.join(args.out, x, "arm"))
    )
    results = [grade_trial(d) for d in trials]
    for r in results:
        print(json.dumps(r, separators=(",", ":")))
    print()
    for c, name in [("c1", "return path carries it"), ("c2", "faults told apart"),
                    ("c3", f"alarm within {LATENCY_S:.0f} s"), ("c4", "recovers")]:
        graded = [r for r in results if c in r]
        bad = [r["trial"] for r in graded if not r[c]]
        verdict = "PASS" if graded and not bad else "FAIL"
        print(f"{c} {name}: {verdict} ({len(graded) - len(bad)}/{len(graded)})"
              + (f"  failing: {', '.join(bad)}" if bad else ""))
    errors = [r["trial"] for r in results if "error" in r]
    if errors:
        print(f"not graded: {', '.join(errors)}")
    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=1)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stim")
    s.add_argument("control")
    s.add_argument("faulted")
    s.add_argument("--pids", required=True)
    s.add_argument("--for", dest="dur", type=float, required=True)
    g = sub.add_parser("run")
    g.add_argument("out")
    g.add_argument("--json")
    args = ap.parse_args()
    return stim(args) if args.cmd == "stim" else run(args)


if __name__ == "__main__":
    sys.exit(main())

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
  live <out dir> [--json grade.json]
      The live hour t39b-live.sh wrote: Part B's criteria 5 and 6 from LIVE_SKIP_S after the
      first snapshot, with the frozen-row positive control, and T21's catalog-rate criteria
      from the monitored export's windows.

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
LIVE_SKIP_S = 90.0
DAMAGE_S = 10.0
SOURCE_BPS = 25_000_000
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


# ---- live -----------------------------------------------------------------------------------

TR101290 = ("pcrRepetitionError", "pcrDiscontinuityIndicatorError", "ptsError",
            "continuityCountError", "patError", "pmtError", "tsSyncLoss", "crcError")


def damage_times(rep):
    """When the importer's own TR 101 290 counters moved: the contribution's damage, as tier 1
    saw it."""
    out, last = [], None
    for t, _, value in rep:
        m = value.get("mpegts") or {}
        now = tuple(m.get(k, 0) for k in TR101290)
        if last is not None and now != last:
            out.append(t)
        last = now
    return out


def exits(path, lo, hi):
    """Export ends in (lo, hi): (t, reason)."""
    return [(round(t, 1), rest.split("\t", 1)[-1]) for t, kind, rest in tsv(path)
            if kind == "end" and lo < t < hi]


def freeze(snaps, pid, t0, dur):
    """A copy of `snaps` with `pid`'s units held at their t0 value for `dur` seconds."""
    held, out = None, []
    for t, rows, value in snaps:
        rows = dict(rows)
        if pid in rows and t0 <= t <= t0 + dur:
            held = rows[pid][1] if held is None else held
            rows[pid] = (rows[pid][0], held, rows[pid][2])
        out.append((t, rows, value))
    return out


def monitor(path):
    out = []
    for t, body, rest in tsv(path):
        kv = dict(x.split("=", 1) for x in (body + " " + rest).split() if "=" in x)
        if "rate_bps" in kv:
            out.append((t, {k: float(v) for k, v in kv.items() if v.replace(".", "", 1).lstrip("-").isdigit()}))
    return out


def live(args):
    d = args.out
    ev = {name: t for t, name, _ in tsv(os.path.join(d, "events.tsv"))}
    marks = {name: (t, rest) for t, name, rest in tsv(os.path.join(d, "marks.tsv"))}
    echo = snapshots(os.path.join(d, "echo.tsv"), "feedback")
    rep = snapshots(os.path.join(d, "report.tsv"), None)
    if not echo or "first" not in marks:
        print(json.dumps({"error": "no feedback" if not echo else "the source never started"}))
        return 1
    first = marks["first"][0]
    until = ev.get("stop") or ev.get("source_ended") or echo[-1][0]
    start = echo[0][0] + LIVE_SKIP_S
    r = {"build_dir": d, "graded_s": round(until - start, 1), "snapshots": len(echo),
         "source_ended_early": "source_ended" in ev}

    # Criterion 5: the path holds.
    sel = [s for s in echo if start <= s[0] <= until]
    gaps = [b[0] - a[0] for a, b in zip(sel, sel[1:])]
    r["cadence_mean_s"] = round((sel[-1][0] - sel[0][0]) / (len(sel) - 1), 3) if len(sel) > 1 else None
    r["gap_max_s"] = round(max(gaps), 3) if gaps else None
    r["gaps_over_cadence"] = sum(g > CADENCE_S for g in gaps)
    r["full_rows"] = round(sum(GRADED <= set(s[1]) for s in sel) / max(len(sel), 1), 4)
    r["sub_exits"] = exits(os.path.join(d, "sub-exits.tsv"), first + 20, until)
    trailing = until - sel[-1][0] if sel else None
    r["c5"] = (r["cadence_mean_s"] is not None and r["cadence_mean_s"] <= CADENCE_S
               and r["gap_max_s"] <= ABSENT_S and trailing is not None and trailing <= ABSENT_S
               and not r["sub_exits"])

    # Criterion 6: no false alarm, damage counted by the importer excused and listed.
    damage = damage_times(rep)
    alarms = sorted([(t, p, k) for t, p, k in row_alarms(echo) if k == "stop" and start <= t <= until]
                    + [a[:3] for a in absent_alarms(sel, until)])
    def near(t):
        return any(abs(t - x) <= DAMAGE_S for x in damage)

    r["damage_moments"] = len([x for x in damage if start <= x <= until])
    r["alarms_excused"] = [(round(t - start, 1), p, k) for t, p, k in alarms if near(t)]
    r["alarms"] = [(round(t - start, 1), p, k) for t, p, k in alarms if not near(t)]
    r["comparator_alarms"] = [(round(t - start, 1), p, why)
                              for t, p, why in local_alarms(os.path.join(d, "live.tsv"))
                              if start <= t <= until]
    r["c6"] = not r["alarms"]
    t0 = start + min(600.0, (until - start) / 2)
    pos = [(t, p, k) for t, p, k in row_alarms(freeze(echo, 121, t0, 10.0)) if k == "stop" and start <= t <= until]
    base = [(t, p, k) for t, p, k in row_alarms(echo) if k == "stop" and start <= t <= until]
    r["control_positive"] = [round(t - t0, 2) for t, p, _ in pos if p == 121 and (t, p, "stop") not in base]
    r["control_ok"] = len(r["control_positive"]) == 1

    # Reported: the release clock per 10 minutes, and each row's class.
    bins = {}
    for t, _, value in sel:
        rel = (value.get("feedback") or {}).get("release") or {}
        b = int((t - start) // 600)
        bins.setdefault(b, []).append((rel.get("drift"), rel.get("outOfTolerance")))
    r["release_per_10min"] = []
    for b in sorted(bins):
        drifts = [x for x, _ in bins[b] if isinstance(x, (int, float))]
        oot = [y for _, y in bins[b] if isinstance(y, (int, float))]
        r["release_per_10min"].append({"from_min": b * 10,
                                       "drift": [round(min(drifts), 1), round(max(drifts), 1)] if drifts else None,
                                       "outOfTolerance_added": (oot[-1] - oot[0]) if len(oot) > 1 else None})
    r["classes"] = {p: row[0] for p, row in sorted(echo[-1][1].items())}

    # T21: the catalog's rate after the import's fix.
    mon = monitor(os.path.join(d, "mux-monitor.tsv"))
    def dev(bps):
        return round((bps - SOURCE_BPS) / SOURCE_BPS * 100, 4)

    r["mux_windows"] = len(mon)
    sizes = sorted(kv.get("packets", 0) for _, kv in mon)
    full = [(t, kv) for t, kv in mon if sizes and kv.get("packets", 0) >= 0.9 * sizes[len(sizes) // 2]]
    r["mux_first_windows_pct"] = [dev(kv["rate_bps"]) for _, kv in full[:2]]
    thin_end = marks.get("thin_end", (None, ""))[0]
    r["thin_end_s"] = round(thin_end - first, 1) if thin_end else None
    after = [(t, kv) for t, kv in mon if thin_end and t >= thin_end + 40 and t <= until]
    r["mux_after_pct"] = [min((dev(kv["rate_bps"]) for _, kv in after), default=None),
                          max((dev(kv["rate_bps"]) for _, kv in after), default=None)]
    rise = [t for t, kv in mon if thin_end and t >= thin_end and abs(dev(kv["rate_bps"])) <= 0.01]
    r["mux_raised_after_s"] = round(rise[0] - thin_end, 1) if rise else None
    r["mux_cc_windows"] = sum(kv.get("cc", 0) > 0 for t, kv in mon if t >= start)
    r["mux_gt40_windows"] = sum(kv.get("gt40", 0) > 0 for t, kv in mon if t >= start)
    r["mux_exits"] = exits(os.path.join(d, "mux-exits.tsv"), first + 20, until)
    r["m1"] = len(r["mux_first_windows_pct"]) == 2 and all(-0.25 <= x <= -0.15 for x in r["mux_first_windows_pct"])
    r["m2"] = bool(after) and all(abs(dev(kv["rate_bps"])) <= 0.01 for _, kv in after)
    r["m3"] = not r["mux_exits"] and not r["sub_exits"]

    print(json.dumps(r, indent=1))
    print()
    for c, name in [("c5", "holds for the hour"), ("c6", "no false alarm"),
                    ("control_ok", "frozen-row positive control"),
                    ("m1", "T21 stimulus: first windows low"), ("m2", "T21 fix: rate raised and held"),
                    ("m3", "T21 consequence: no export ended")]:
        print(f"{c} {name}: {'PASS' if r[c] else 'FAIL'}")
    if args.json:
        with open(args.json, "w") as f:
            json.dump(r, f, indent=1)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stim")
    s.add_argument("control")
    s.add_argument("faulted")
    s.add_argument("--pids", required=True)
    s.add_argument("--for", dest="dur", type=float, required=True)
    for name in ("run", "live"):
        g = sub.add_parser(name)
        g.add_argument("out")
        g.add_argument("--json")
    args = ap.parse_args()
    return {"stim": stim, "run": run, "live": live}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())

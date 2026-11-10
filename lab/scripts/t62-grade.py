#!/usr/bin/env python3
"""Grade T62 (lab/test-62-origin-group-soak.md) from the logs of its three hosts.

  t62-grade.py DIR [--duration 2]

DIR holds tertiary/ (the soak's run directory: events.log, merge.jsonl, pcr.log, pacer-a.log,
pacer-b.log, b8-a.jsonl, b8-b.jsonl, resources.txt), and primary/ and secondary/ (each origin's
seg.log, guard.log, events.log, its soak resources file *-resources.txt, and access.log: the
primary's requests not answered 200 or 304, all of the secondary's). Prints one section per
criterion, each event with its hour into the soak, and attributes an event to a reset both
segmenters made, or damage both cut at the same K, within ATTRIB_S before it. T76 adds C7 (PTS
against PCR, from the monitor's --pts fields) and C8 (the --peer rule's answers); a peer's
digest reads (seg-K.sha1) are counted apart from the edges' group requests.
"""

import argparse
import glob
import json
import os
import re
import statistics

WRAP = 1 << 33
ATTRIB_S = 180
PAIR_S = 2.0
C4_MB_PER_H = 1.60
C3_MS = 450
C7_BAND_MS = (0.0, 2000.0)
C8_WAIT_S = 3.0
C8_SLACK_S = 0.5
SLOW_MS = 900
CLK_TCK = 100
ORIGINS = ("primary", "secondary")


def slope(xs, ys):
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx if sxx else 0.0


def read_events(path):
    ev = {}
    for line in open(path):
        p = line.split()
        if len(p) >= 2:
            ev.setdefault(p[1], float(p[0]))
    return ev


def read_seg(path):
    """Resets, segments, digests by K, and the --peer rule's events (t, event, k, rest)."""
    resets, segs, digest, rule = [], [], {}, []
    for line in open(path):
        p = line.split()
        if len(p) < 2:
            continue
        if p[1] == "reset":
            resets.append((float(p[0]), " ".join(p[2:])))
        elif p[1] == "seg":
            f = dict(x.split("=", 1) for x in p[2:] if "=" in x)
            k = int(f["k"])
            segs.append((float(p[0]), k))
            digest[k] = (float(p[0]), f.get("bytes"), f.get("sha1"))
        elif p[1] in ("damaged", "shared", "unshared", "unverified") and len(p) > 2 and p[2].startswith("k="):
            rule.append((float(p[0]), p[1], int(p[2][2:]), " ".join(p[3:])))
    return resets, segs, digest, rule


def receiver_episodes(path):
    """Playlist-failure episodes (start, end, fetches, statuses), and media-sequence skips."""
    episodes, skips, ep = [], [], None
    for line in open(path):
        try:
            x = json.loads(line)
        except ValueError:
            continue
        e = x.get("ev")
        if e == "pl-fail":
            if ep is None:
                ep = [x["t"], x["t"], 0, set()]
            ep[1], ep[2] = x["t"], ep[2] + 1
            ep[3].add(x.get("status"))
        elif e == "pl-recovered" and ep is not None:
            ep[1] = x["t"]
            episodes.append(ep)
            ep = None
        elif e == "msn-skip":
            skips.append(x)
    if ep is not None:
        episodes.append(ep)
    return episodes, skips


def pacer_samples(path):
    """Samples, and events dated by the sample that follows them (samples are 10 s apart)."""
    out, events, pending = [], [], []
    for line in open(path):
        if " sample " in line:
            m = dict(re.findall(r"(\w+)=([-\w.]+)", line))
            out.append((float(m["t"]), m))
            events += [(float(m["t"]), e) for e in pending]
            pending = []
        elif "STALLED" in line or "source Live" in line:
            pending.append(line.strip().removeprefix("mpegts-pacer: "))
    return out, events


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--duration", type=float, default=2.0, help="the segmenters' epoch D, s")
    ap.add_argument("--c7-hourly", metavar="TSV", help="write C7's per-PID hourly minimum and maximum here")
    a = ap.parse_args()
    d = a.dir
    span = round(a.duration * 90000)

    ev = read_events(os.path.join(d, "tertiary", "events.log"))
    t0 = ev["soak-start"]
    leg0 = {"a": ev["leg-start-a"], "b": ev["leg-start-b"]}

    def h(t):
        return (t - t0) / 3600

    merge = [json.loads(x) for x in open(os.path.join(d, "tertiary", "merge.jsonl"))]
    while merge and not merge[-1]["merged"]:
        merge.pop()
    t_end = merge[-1]["t"]
    print(f"run: soak {h(t_end):.2f} h ({len(merge)} merge minutes); 72 h needed")

    seg = {o: read_seg(os.path.join(d, o, "seg.log")) for o in ORIGINS}
    run = {o: [(t, w) for t, w in seg[o][0] if t0 - 60 <= t <= t_end] for o in ORIGINS}
    common, single = [], []
    for t, w in run["primary"]:
        if any(abs(t - u) <= PAIR_S and w == v for u, v in run["secondary"]):
            common.append((t, w))
        else:
            single.append(("primary", t, w))
    for t, w in run["secondary"]:
        if not any(abs(t - u) <= PAIR_S and w == v for u, v in run["primary"]):
            single.append(("secondary", t, w))

    dmg = {o: {k: t for t, e, k, _ in seg[o][3] if e == "damaged" and t0 - 60 <= t <= t_end} for o in ORIGINS}
    both_dmg = sorted(
        (min(dmg["primary"][k], dmg["secondary"][k]), k)
        for k in set(dmg["primary"]) & set(dmg["secondary"])
        if abs(dmg["primary"][k] - dmg["secondary"][k]) <= PAIR_S
    )

    def cause(t):
        hits = [w for u, w in common if u <= t + PAIR_S and t - u <= ATTRIB_S]
        if hits:
            return "both segmenters reset (" + ", ".join(sorted(set(hits))) + ")"
        ks = [k for u, k in both_dmg if u <= t + PAIR_S and t - u <= ATTRIB_S]
        if ks:
            return "damage both segmenters cut (k " + ", ".join(map(str, ks)) + ")"
        if t - min(leg0.values()) <= 120:
            return "the legs' start"
        return "UNATTRIBUTED"

    print("\nsegmenter resets in the run, on both at once:")
    for t, w in common:
        print(f"  {h(t):7.3f} h  {w}")
    print(f"on one pathway only: {len(single)}")
    for o, t, w in single:
        print(f"  {h(t):7.3f} h  {o}: {w}")

    print("\nC1, the merged wire: minutes with a PCR interval over 40 ms or a continuity error")
    bad = []
    for line in open(os.path.join(d, "tertiary", "pcr.log")):
        if not line.startswith("t="):
            continue
        m = dict(re.findall(r"(\w+)=([\d.]+)", line))
        gt40, cc = int(m["gt40"]), int(m["cc"])
        if gt40 or cc:
            t = t0 + float(m["t"])
            bad.append(t)
            print(f"  {h(t):7.3f} h  gt40={gt40} max_ms={m['max_ms']} cc={cc}  {cause(t)}")
    print(f"  {len(bad)} minutes")
    cum, at = 0, []
    for x in merge:
        cum += x["merged"] * 7
        at.append((cum, x["t"]))
    clusters = []
    for line in open(os.path.join(d, "tertiary", "cc.log")):
        m = re.search(r"packet index: ([\d,]+), PID: \S+ \((\d+)\), missing (\d+)", line)
        if not m:
            continue
        idx = int(m[1].replace(",", ""))
        if not clusters or idx - clusters[-1][1] > 1_000_000:
            clusters.append([idx, idx, 0, set()])
        c = clusters[-1]
        c[1], c[2] = idx, c[2] + 1
        c[3].add(int(m[2]))
    print(
        f"  tsp's continuity check on the merged wire: {sum(c[2] for c in clusters)} reports in {len(clusters)} bursts"
    )
    for first, _, n, pids in clusters:
        t = next((u for k, u in at if k >= first), t_end)
        print(f"    by {h(t):7.3f} h  {n} reports on {len(pids)} PIDs  {cause(t)}")

    print("\nC2, the merge")
    tot = {k: sum(x[k] for x in merge) for k in ("lost", "mismatched", "late", "a_missing", "b_missing")}
    print("  totals: " + ", ".join(f"{k} {v:,}" for k, v in tot.items()))
    for x in merge:
        if x["lost"] or x["mismatched"] or x["late"]:
            print(
                f"  {h(x['t']):7.3f} h  lost={x['lost']:,} mismatched={x['mismatched']} late={x['late']}"
                f"  {cause(x['t'])}"
            )
    rx = {leg: receiver_episodes(os.path.join(d, "tertiary", f"b8-{leg}.jsonl")) for leg in ("a", "b")}

    def own_cause(t, leg):
        c = cause(t)
        if c != "UNATTRIBUTED":
            return c
        for s0, s1, n, _ in rx[leg][0]:
            if s0 - 60 <= t <= s1 + 120:
                return f"leg {leg}'s playlist failures from {h(s0):.3f} h ({n} fetches)"
        return c

    print("  each leg's own losses (the other leg's copy merged), consecutive minutes as one span:")
    spans = []
    for x in merge:
        if x["a_missing"] or x["b_missing"]:
            if spans and x["t"] - spans[-1][1] <= 120:
                sp = spans[-1]
            else:
                sp = [x["t"], x["t"], 0, 0, 0, 0]
                spans.append(sp)
            sp[1], sp[2] = x["t"], sp[2] + 1
            sp[3] += x["a_missing"]
            sp[4] += x["b_missing"]
            sp[5] += x["lost"]
    for s0, s1, n, am, bm, lost in spans:
        leg = "a" if am >= bm else "b"
        print(
            f"  {h(s0):7.3f}-{h(s1):.3f} h  {n} min  a_missing={am:,} b_missing={bm:,}"
            f"{f'  (merge also lost {lost:,})' if lost else ''}  {own_cause(s0, leg)}"
        )

    print(f"\nC3, the skew (within {C3_MS} ms)")
    skewed = [x for x in merge if x["skew_ms"][1] is not None]
    lo = min(x["skew_ms"][0] for x in skewed)
    hi = max(x["skew_ms"][2] for x in skewed)
    hours = {}
    for x in skewed:
        hours.setdefault(int(h(x["t"])), []).append(x["skew_ms"][1])
    med = [(k, statistics.median(v)) for k, v in sorted(hours.items())]
    print(
        f"  range {lo} to {hi} ms; hourly medians {min(m for _, m in med)} to {max(m for _, m in med)} ms;"
        f" drift {slope([k for k, _ in med], [m for _, m in med]):+.4f} ms/h"
        f"  {'pass' if max(abs(lo), abs(hi)) <= C3_MS else 'FAIL'}"
    )

    print(f"\nC4, resources: RSS slope by least squares over the run (bar {C4_MB_PER_H} MB/h)")
    files = {"tertiary": os.path.join(d, "tertiary", "resources.txt")}
    for o in ORIGINS:
        files[o] = glob.glob(os.path.join(d, o, "*-resources.txt"))[0]
    worst = 0.0
    for host, path in files.items():
        series, ticks = {}, {}
        for line in open(path):
            p = line.split()
            if len(p) != 5 or not t0 <= float(p[0]) <= t_end:
                continue
            series.setdefault((p[1], p[2]), []).append((h(float(p[0])), int(p[3]) / 1024))
            ticks.setdefault((p[1], p[2]), []).append((float(p[0]), int(p[4])))
        by_role = {}
        for (role, pid), pts in series.items():
            if role == "disk" or len(pts) < 60:
                continue
            s = slope([x for x, _ in pts], [y for _, y in pts])
            r = by_role.setdefault(role, [0, -1e9, None, 0.0])
            r[0] += 1
            (ta, ca), (tb, cb) = ticks[(role, pid)][0], ticks[(role, pid)][-1]
            r[3] += (cb - ca) / CLK_TCK / (tb - ta) * 100
            if s > r[1]:
                r[1], r[2] = s, (pts[0][1], pts[-1][1], pts[-1][0] - pts[0][0])
            worst = max(worst, s)
        for role, (n, s, (first, last, dur), cpu) in sorted(by_role.items()):
            print(
                f"  {host:9} {role:6} {n:2} pid(s), steepest {s:+.4f} MB/h"
                f" ({first:.1f} -> {last:.1f} MB over {dur:.1f} h); CPU {cpu:.1f} % of a core"
            )
        disk = [
            (h(float(p[0])), int(p[3]) / 1048576)
            for p in (line.split() for line in open(path))
            if len(p) == 5 and p[1] == "disk" and t0 <= float(p[0]) <= t_end
        ]
        if disk:
            print(f"  {host:9} disk free {disk[0][1]:.2f} -> {disk[-1][1]:.2f} GB")
    print(f"  {'pass' if worst < C4_MB_PER_H else 'FAIL'}: steepest {worst:+.4f} MB/h")

    print("\nC5, events: receivers")
    for leg in ("a", "b"):
        for line in open(os.path.join(d, "tertiary", f"b8-{leg}.jsonl")):
            try:
                x = json.loads(line)
            except ValueError:
                continue
            if x.get("ev") == "seg" and x.get("status") != 200:
                print(
                    f"  leg {leg} {h(x['t']):7.3f} h  segment {x.get('name')} status {x.get('status')}  {cause(x['t'])}"
                )
        episodes, skips = rx[leg]
        fails = sum(n for _, _, n, _ in episodes)
        print(f"  leg {leg}: {fails} playlist failures in {len(episodes)} episodes, {len(skips)} media-sequence skips")
        for s0, s1, n, st in episodes:
            print(f"    {h(s0):7.3f} h  {s1 - s0:5.1f} s, {n} fetches, status {sorted(st, key=str)}  {cause(s0)}")
        for x in skips:
            rest = {k: v for k, v in x.items() if k not in ("t", "ev")}
            print(f"    {h(x['t']):7.3f} h  skip {rest}  {cause(x['t'])}")

    print("\nC5, events: groomers")
    for leg in ("a", "b"):
        samples, events = pacer_samples(os.path.join(d, "tertiary", f"pacer-{leg}.log"))
        keys = ("dropped", "late_drops", "stalls", "muted", "underruns", "resyncs", "pcr_inserted", "pcr_rebases")
        prev = None
        for t, m in samples:
            cur = {k: int(m.get(k, 0)) for k in keys}
            if prev is not None and cur != prev:
                delta = {k: cur[k] - prev[k] for k in keys if cur[k] != prev[k]}
                at = leg0[leg] + t
                print(
                    f"  leg {leg} {h(at):7.3f} h  "
                    + " ".join(f"{k}+{v:,}" for k, v in delta.items())
                    + f"  {cause(at)}"
                )
            prev = cur
        print(f"  leg {leg} at the end: " + " ".join(f"{k}={prev[k]:,}" for k in keys))
        for t, e in events:
            if "STALLED" in e:
                print(f"  leg {leg} {h(leg0[leg] + t):7.3f} h  {e}  {cause(leg0[leg] + t)}")

    p = os.path.join(d, "secondary", "access.log")
    at_b = []
    if os.path.exists(p):
        at_b = [
            float(x[0]) for x in (line.split() for line in open(p)) if len(x) > 2 and x[2].startswith(("/g/", "/h/"))
        ]
    slow, fetches = [], 0
    for leg in ("a", "b"):
        for line in open(os.path.join(d, "tertiary", f"b8-{leg}.jsonl")):
            try:
                x = json.loads(line)
            except ValueError:
                continue
            if x.get("ev") in ("pl", "seg") and t0 <= x["t"] <= t_end:
                fetches += 1
                if (x.get("ttfb_ms") or 0) >= SLOW_MS:
                    slow.append((x["t"], leg, x["ev"], x["ttfb_ms"]))
    print(f"\nC5, events: of {fetches:,} fetches, {len(slow)} had a first byte after {SLOW_MS} ms")
    for t, leg, e, ms in slow:
        c = cause(t)
        if c == "UNATTRIBUTED":
            c = "failed over to the secondary" if any(abs(u - t) <= 3 for u in at_b) else "no failover"
        print(f"    {h(t):7.3f} h  leg {leg} {e} {ms:.0f} ms  {c}")

    def failover(t):
        c = cause(t)
        if c != "UNATTRIBUTED":
            return c
        hits = [f"leg {leg} {e} {ms:.0f} ms" for u, leg, e, ms in slow if abs(u - t) <= 3]
        return "the edge timed out on the primary (" + ", ".join(hits) + ")" if hits else c

    print("\nC5, events: origins (guard withdrawals and actions in the run; failovers from access.log)")
    for o in ORIGINS:
        for name in ("guard.log", "events.log"):
            p = os.path.join(d, o, name)
            hits = [line.split() for line in open(p)] if os.path.exists(p) else []
            hits = [x for x in hits if x and t0 <= float(x[0]) <= t_end]
            print(f"  {o} {name}: {len(hits)} in the run")
            for x in hits:
                print(f"    {h(float(x[0])):7.3f} h  {' '.join(x[1:])}  {cause(float(x[0]))}")
        p = os.path.join(d, o, "access.log")
        if not os.path.exists(p):
            print(f"  {o} access.log: not fetched")
            continue
        group, refused, peer_reads, ep = [], 0, 0, None
        for line in open(p):
            x = line.split()
            if len(x) < 3 or not t0 <= float(x[0]) <= t_end:
                continue
            t, status, path = float(x[0]), x[1], x[2]
            if not path.startswith(("/g/", "/h/")):
                refused += status in ("400", "403")
                continue
            if path.endswith(".sha1"):
                peer_reads += 1
                continue
            if o == "primary" and status in ("200", "304"):
                continue
            if ep is None or t - ep[1] > 30:
                ep = [t, t, {}]
                group.append(ep)
            ep[1] = t
            ep[2][status] = ep[2].get(status, 0) + 1
        what = "group requests" if o == "secondary" else "group errors"
        print(
            f"  {o}: {len(group)} episodes of {what}; {refused} requests outside the group refused;"
            f" {peer_reads} digest reads by its peer"
        )
        for s0, s1, st in group:
            print(f"    {h(s0):7.3f} h  {s1 - s0:5.1f} s  {st}  {failover(s0)}")

    print("\nC6, the PTS wraps (where K * D crosses a multiple of 2^33)")
    for o in ORIGINS:
        segs = [(t, k) for t, k in seg[o][1] if t0 - 60 <= t <= t_end]
        breaks = [(segs[i - 1], segs[i]) for i in range(1, len(segs)) if segs[i][1] != segs[i - 1][1] + 1]
        print(f"  {o}: {len(segs):,} segments, {len(breaks)} numbering breaks")
        for (ta, ka), (tb, kb) in breaks:
            print(f"    {h(tb):7.3f} h  k {ka} -> {kb}  {cause(tb)}")
        for i in range(1, len(segs)):
            ka, (tb, kb) = segs[i - 1][1], segs[i]
            if ka * span // WRAP != kb * span // WRAP:
                near = [w for u, w in run[o] if abs(u - tb) <= 300]
                c1 = sum(1 for u in bad if abs(u - tb) <= 360)
                order = "consecutive" if kb == ka + 1 else "NOT consecutive"
                print(
                    f"    wrap at {h(tb):7.3f} h: k {ka} -> {kb} {order}; resets within 5 min: {near or 'none'};"
                    f" C1 minutes within 5 min: {c1}"
                )

    print(f"\nC7, the clock: every PES's PTS {C7_BAND_MS[0]:.0f}-{C7_BAND_MS[1]:.0f} ms ahead of the PCR before it")
    c7_bad, c7_un, hourly, minutes = 0, 0, {}, 0
    for line in open(os.path.join(d, "tertiary", "pcr.log")):
        if not line.startswith("t=") or "lead_min_ms=" not in line:
            continue
        minutes += 1
        m = dict(re.findall(r"(\w+)=(-?[\d.]+)", line))
        t = t0 + float(m["t"])
        lo, hi, out = float(m["lead_min_ms"]), float(m["lead_max_ms"]), int(m["lead_out"])
        if out or lo < C7_BAND_MS[0] or hi > C7_BAND_MS[1]:
            c7_bad += 1
            c = cause(t)
            c7_un += c == "UNATTRIBUTED"
            print(f"  {h(t):7.3f} h  lead {lo:.1f} to {hi:.1f} ms, {out} PES outside  {c}")
        leads = re.search(r"leads=(\S+)", line)
        for item in leads[1].split(",") if leads else []:
            pid, span_ms = item.split(":")
            a_ms, b_ms = (float(v) for v in span_ms.split("/"))
            r = hourly.setdefault(pid, {}).setdefault(int(h(t)), [a_ms, b_ms])
            r[0], r[1] = min(r[0], a_ms), max(r[1], b_ms)
    for pid, hrs in sorted(hourly.items(), key=lambda kv: int(kv[0])):
        lows, highs = [v[0] for v in hrs.values()], [v[1] for v in hrs.values()]
        print(
            f"  PID {pid}: over {len(hrs)} hours, hourly minimum {min(lows):.0f} to {max(lows):.0f} ms,"
            f" hourly maximum {min(highs):.0f} to {max(highs):.0f} ms"
        )
    if a.c7_hourly:
        with open(a.c7_hourly, "w") as f:
            f.write("pid\thour\tmin_ms\tmax_ms\n")
            for pid, hrs in sorted(hourly.items(), key=lambda kv: int(kv[0])):
                for hr, (lo, hi) in sorted(hrs.items()):
                    f.write(f"{pid}\t{hr}\t{lo:.0f}\t{hi:.0f}\n")
    print(
        f"  {c7_bad} of {minutes:,} minutes outside the band, {c7_un} unattributed"
        f"  {'pass' if minutes and not c7_un else 'FAIL' if minutes else 'no --pts fields'}"
    )

    print(f"\nC8, the rule: each damaged segment answered within the {C8_WAIT_S:.0f} s wait")
    c8_fail = 0
    for o in ORIGINS:
        peer = ORIGINS[1 - ORIGINS.index(o)]
        held, answers = {}, []
        for t, e, k, rest in seg[o][3]:
            if not t0 - 60 <= t <= t_end:
                continue
            if e == "damaged":
                held[k] = (t, rest)
            elif k in held:
                td, why = held.pop(k)
                answers.append((td, t, e, k, why, rest))
        print(f"  {o}: {len(answers) + len(held)} damaged segments, {len(answers)} answered")
        for td, t, e, k, why, rest in answers:
            notes = []
            if t - td > C8_WAIT_S + C8_SLACK_S:
                notes.append(f"LATE {t - td:.1f} s")
            near = lambda rs: [w for u, w in rs if td - PAIR_S <= u <= t + 10]  # noqa: E731
            if e == "shared":
                mine, theirs = seg[o][2].get(k), seg[peer][2].get(k)
                if not theirs or not mine or mine[1:] != theirs[1:]:
                    notes.append("NOT the same object on both")
                if near(run[o]) or near(run[peer]):
                    notes.append(f"a reset beside it: {near(run[o]) + near(run[peer])}")
            elif e == "unshared":
                if near(run[peer]):
                    notes.append(f"the peer reset too: {near(run[peer])}")
                lost = sum(x["lost"] for x in merge if td <= x["t"] <= td + ATTRIB_S)
                if lost:
                    notes.append(f"the merge lost {lost:,}")
            c8_fail += bool(notes)
            print(f"    {h(td):7.3f} h  k {k} ({why}) {e} after {t - td:.3f} s {rest}  {'; '.join(notes) or 'ok'}")
        for k, (td, why) in sorted(held.items(), key=lambda kv: kv[1][0]):
            c8_fail += 1
            print(f"    {h(td):7.3f} h  k {k} ({why}) UNANSWERED  {cause(td)}")
    print(f"  {'pass' if not c8_fail else 'FAIL'}: {c8_fail} answers not as the rule requires")

    print("\nAlso: are the origins' segments the same objects? (same k: bytes and SHA-1)")
    da, db = ({k: v for k, v in seg[o][2].items() if t0 - 60 <= v[0] <= t_end} for o in ORIGINS)
    both = sorted(set(da) & set(db))
    differ = [k for k in both if da[k][1:] != db[k][1:]]
    only = len(set(da) ^ set(db))
    print(f"  {len(both):,} cut by both, {only} by one only; {len(differ)} differ")
    for k in differ[:20]:
        print(f"    k {k} at {h(da[k][0]):7.3f} h: {da[k][1:]} vs {db[k][1:]}  {cause(da[k][0])}")


if __name__ == "__main__":
    main()

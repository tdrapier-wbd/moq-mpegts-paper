#!/usr/bin/env python3
"""Grade a T82 matrix: the criteria of lab/test-82-slow-unresponsive-subscribers.md, cell by cell.

Usage: t82-grade.py <root> [--csv summary.csv] [--controls <root>]

<root> holds one directory per cell, as `t82-slow-consumer.sh` writes them. Criterion zero voids a
cell; criteria 1-4 are graded. The cost per session (criterion 2) is graded across cells, because
it needs the same build's healthy32 null. --controls adds another root's control cells to the
victims' reference, for a root that has none. A subscriber with no reader log (a light abuser) is
not graded as one. Times are seconds after the cell's t0. RSS is reported in
MB (10^6 bytes), the unit the criteria's 5.24 MB is written in.
"""

import bisect
import csv
import datetime as dt
import re
import statistics
import sys
from pathlib import Path

T_EV, T_END, RATE = 45.0, 170.0, 9_950_000
PIDS = (111, 121, 123)
MB = 1e6


def meta(cell):
    m = {}
    for line in (cell / "meta.txt").read_text().splitlines():
        for tok in line.split():
            if "=" in tok and not tok.startswith("--"):
                k, v = tok.split("=", 1)
                m.setdefault(k, v)
    m["t0"] = float(m["t0"])
    m["abusers"] = int(m["abusers"])
    m["dur"] = float(m["dur"].rstrip("s"))
    m["idle_s"] = float(m["idle"].rstrip("s"))
    m["noq"] = "-noq-" in cell.name
    return m


class Sub:
    """One reader's log: rows of (t, bytes, n111, dts111, n121, dts121, n123, dts123)."""

    def __init__(self, path, t0):
        self.t, self.rows = [], []
        with open(path) as f:
            for r in csv.DictReader(f):
                self.t.append(float(r["t"]) - t0)
                row = {"bytes": int(r["bytes"])}
                for p in PIDS:
                    row[f"n{p}"] = int(r[f"n{p}"])
                    row[f"dts{p}"] = float(r[f"dts{p}"]) if r[f"dts{p}"] else None
                self.rows.append(row)

    def at(self, t):
        i = bisect.bisect_right(self.t, t) - 1
        return self.rows[i] if i >= 0 else None

    def gain(self, key, a, b):
        ra, rb = self.at(a), self.at(b)
        if rb is None:
            return 0
        return rb[key] - (ra[key] if ra else 0)

    def last_t(self):
        return self.t[-1] if self.t else 0.0


def lag(sub, ref, t):
    """How far `sub`'s last video decode timestamp trails `ref`'s at wall time t (s), or None."""
    rs, rr = sub.at(t), ref.at(t)
    if not rs or not rr or rs["dts111"] is None or rr["dts111"] is None:
        return None
    return rr["dts111"] - rs["dts111"]


def grid(a, b, step=0.1):
    n = int(round((b - a) / step))
    return [a + i * step for i in range(n + 1)]


def ps_rows(cell, t0_unused=None):
    """pid -> list of (t, rss MB, stat)."""
    out = {}
    path = cell / "ps.tsv"
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        ms, pid, rss, stat = line.split("\t")
        out.setdefault(int(pid), []).append((int(ms) / 1000, int(rss) * 1024 / MB, stat))
    return out


def metrics(cell):
    """series name (with labels) -> list of (t, value)."""
    out = {}
    path = cell / "metrics.tsv"
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        ms, rest = line.split("\t", 1)
        name, _, val = rest.rpartition(" ")
        out.setdefault(name, []).append((int(ms) / 1000, float(val)))
    return out


def value_at(series, t):
    v = None
    for ts, x in series:
        if ts > t:
            break
        v = x
    return v


ISO = re.compile(r"^(\S+Z)\s+(\w+)\s+(.*)$")
CLOCK = re.compile(r"TS (?:export|passthrough) release clock dropped=(\d+)(?: trimmed=(\d+))?(?: gaps=(\d+))?")


def export_log(path, t0):
    """(clock rows [(t, dropped, gaps)], notable [(t, level, message)])"""
    clock, notable = [], []
    if not path.exists():
        return clock, notable
    for line in path.read_text(errors="replace").splitlines():
        m = ISO.match(line)
        if not m:
            continue
        t = dt.datetime.fromisoformat(m.group(1).replace("Z", "+00:00")).timestamp() - t0
        c = CLOCK.search(m.group(3))
        if c:
            clock.append((t, int(c.group(1)), int(c.group(3) or 0)))
        elif m.group(2) in ("WARN", "ERROR"):
            notable.append((t, m.group(2), m.group(3)))
    return clock, notable


def relay_sessions(path, t0):
    """([accept times], [(close time, cause)]) from the relay's log."""
    opened, closed = [], []
    for line in path.read_text(errors="replace").splitlines():
        m = ISO.match(line)
        if not m:
            continue
        t = dt.datetime.fromisoformat(m.group(1).replace("Z", "+00:00")).timestamp() - t0
        if "session accepted" in m.group(3):
            opened.append(t)
        elif "connection closed" in m.group(3):
            cause = m.group(3).split("err=", 1)[-1].strip()
            closed.append((t, cause))
    return opened, closed


def template(msg):
    return re.sub(r"\d+(\.\d+)?", "#", re.sub(r"conn\{[^}]*\}: ", "", msg))[:150]


def med_rss(rows, a, b):
    xs = [r for t, r, _ in rows if a <= t < b]
    return statistics.median(xs) if xs else None


def rss_excess(rows, a, b):
    base = [r for t, r, _ in rows if 35 <= t < 45]
    peak = [r for t, r, _ in rows if a <= t <= b]
    if not base or not peak:
        return None, None
    med = statistics.median(base)
    return max(peak) - med, med


def grade_cell(cell, controls):
    m = meta(cell)
    t0, n, ev, dur = m["t0"], m["abusers"], m["event"], m["dur"]
    t_end = float(m.get("t_end", T_END))
    pids = dict(line.split("\t") for line in (cell / "pids.tsv").read_text().splitlines())
    pids = {k: int(v) for k, v in pids.items()}
    subs = {k: Sub(cell / f"{k}.csv", t0) for k in pids if k not in ("relay", "pub") and (cell / f"{k}.csv").exists()}
    v1, v2 = subs["v1"], subs["v2"]
    abusers = [k for k in subs if k.startswith("a")]
    ps = ps_rows(cell)
    met = metrics(cell)
    events = {}
    if (cell / "events.tsv").exists():
        for line in (cell / "events.tsv").read_text().splitlines():
            ms, what, _ = line.split("\t")
            events[what] = int(ms) / 1000
    exits = {}
    if (cell / "exits.tsv").exists():
        for line in (cell / "exits.tsv").read_text().splitlines():
            k, state, code = line.split("\t")
            exits[k] = (state, code)
    cc = {}
    if (cell / "cc.tsv").exists():
        for line in (cell / "cc.tsv").read_text().splitlines():
            cap, size, errs = line.split("\t")
            cc[cap] = (int(size), int(errs))
    r = {"cell": cell.name, **{k: m[k] for k in ("arm", "lane", "abusers", "event", "idle", "send_window")}}
    r["build"] = "noq-3c0daa21" if m["noq"] else "main-bad28cef"
    void = []

    # --- criterion zero ------------------------------------------------------------------------
    pre_v1 = v1.gain("bytes", 20, 45)
    for a in abusers:
        g = subs[a].gain("bytes", 20, 45)
        if pre_v1 == 0 or abs(g - pre_v1) / pre_v1 > 0.05:
            void.append(f"{a} pre-event bytes {g} vs v1 {pre_v1}")
    if ev == "freeze":
        ts, tc = events.get("STOP"), events.get("CONT")
        if ts is None or tc is None:
            void.append("no STOP/CONT event")
        else:
            for a in abusers:
                rows = [s for t, _, s in ps.get(pids[a], []) if ts + 1 <= t <= tc - 1]
                if not rows or not all("T" in s for s in rows):
                    void.append(f"{a} not stopped throughout ({len(rows)} samples)")
    if ev == "slow":
        a = subs[abusers[0]]
        bps = a.gain("bytes", 50, 100) * 8 / 50
        want = float(m["frac"]) * RATE
        r["slow_bps"] = round(bps)
        if abs(bps - want) / want > 0.10:
            void.append(f"slow reader {bps:.0f} b/s vs {want:.0f}")
    if ev == "stop":
        a = subs[abusers[0]]
        g = a.gain("bytes", 46, 105)
        l46, l104 = lag(a, v1, 46), lag(a, v1, 104.5)
        rise = None if l46 is None or l104 is None else l104 - l46
        r["stop_lag_rise_s"] = None if rise is None else round(rise, 2)
        if g > 65536:
            void.append(f"stop reader gained {g} B")
        if rise is None or rise < 50:
            void.append(f"stop lag rise {rise} < 50 s (lag instrument)")
    r["void"] = "; ".join(void)

    # --- criterion 1: isolation ----------------------------------------------------------------
    c1 = []
    key = (m["lane"], m["noq"])
    ctl = controls.get(key, {})
    for name, v, other in (("v1", v1, v2), ("v2", v2, v1)):
        for p in PIDS:
            mine, theirs = v.gain(f"n{p}", 45, T_END), other.gain(f"n{p}", 45, T_END)
            if theirs == 0 or abs(mine - theirs) / theirs > 0.005:
                c1.append(f"{name} pid {p} {mine} vs other victim {theirs}")
            ref = ctl.get(p)
            if ref and abs(mine - ref) / ref > 0.005:
                c1.append(f"{name} pid {p} {mine} vs control mean {ref:.0f}")
        r[f"{name}_n111"] = v.gain("n111", 45, T_END)
    worst = 0.0
    for t in grid(20, t_end - 0.1):
        x = lag(v2, v1, t)
        if x is None:
            c1.append(f"v2 no PTS at {t:.1f}")
            break
        worst = max(worst, abs(x))
    r["victim_lag_max_s"] = round(worst, 3)
    if worst > 0.5:
        c1.append(f"victim lag {worst:.3f} s")
    for cap in ("v1.ts", "v2.ts"):
        if cap not in cc:
            c1.append(f"{cap} no continuity result")
        elif cc[cap][1]:
            c1.append(f"{cap} {cc[cap][1]} continuity errors")
    for name in ("v1", "v2"):
        clock, _ = export_log(cell / "logs" / f"{name}.log", t0)
        before = [(d, g) for t, d, g in clock if t <= 20]
        after = [(d, g) for t, d, g in clock if t > 20]
        if before and after:
            d0, g0 = before[-1]
            if max(d for d, _ in after) > d0 or max(g for _, g in after) > g0:
                c1.append(f"{name} export dropped/gaps rose after 20 s")
        elif not after:
            c1.append(f"{name} no export clock lines after 20 s")
        if exits.get(name, ("?",))[0] != "running":
            c1.append(f"{name} did not run to the end: {exits.get(name)}")
    r["c1"] = "PASS" if not c1 else "FAIL: " + "; ".join(c1)

    # --- relay cost, idle close and stale counters ---------------------------------------------
    relay_rows = ps.get(pids["relay"], [])
    ts = events.get("STOP", T_EV)
    base = med_rss(relay_rows, ts - 6, ts)
    r["relay_base_mb"] = None if base is None else round(base, 1)
    if base is not None and n >= 32:
        m49, m2429 = med_rss(relay_rows, ts + 4, ts + 9), med_rss(relay_rows, ts + 24, ts + 29)
        r["L_mb"] = round(m49 - base, 1)
        r["G_mb"] = round(m2429 - m49, 1)
        r["L_per_session_mb"] = round((m49 - base) / n, 2)
        r["G_per_session_mb"] = round((m2429 - m49) / n, 2)
        if ev == "none" and (abs(r["L_mb"]) > 40 or abs(r["G_mb"]) > 40):
            void.append(f"null L {r['L_mb']} or G {r['G_mb']} outside 40 MB")
            r["void"] = "; ".join(void)
    if ev == "freeze" and base is not None:
        after = med_rss(relay_rows, ts + dur + 20, ts + dur + 30)
        r["relay_after_mb"] = None if after is None else round(after - base, 1)
    # The same windows on the relay's physical footprint, which swap and compression leave intact.
    if (cell / "fp.tsv").exists() and n >= 32:
        with open(cell / "fp.tsv") as f:
            fp = [(float(x["t"]), float(x["footprint_mb"]), None) for x in csv.DictReader(f, delimiter="\t")]
        b, m49, m2429 = (med_rss(fp, *w) for w in ((ts - 6, ts), (ts + 4, ts + 9), (ts + 24, ts + 29)))
        if None not in (b, m49, m2429):
            r["fp_base_mb"] = round(b, 1)
            r["fp_L_per_session_mb"] = round((m49 - b) / n, 2)
            r["fp_G_per_session_mb"] = round((m2429 - m49) / n, 2)
    # Without a stats node the relay leaves its per-tier session series empty, so the idle close is
    # read from its log: one "session accepted" and one "connection closed" line per connection.
    if ev == "freeze" and "STOP" in events and n and dur > m["idle_s"]:
        ts, idle = events["STOP"], m["idle_s"]
        opened, closed = relay_sessions(cell / "logs" / "relay.log", t0)
        inside = [t for t, _ in closed if ts + idle - 1 <= t <= ts + idle + 5]
        r["idle_closes"] = len(inside)
        r["idle_close_s"] = round(max(inside) - ts, 2) if inside else None
        causes = {}
        for t, cause in closed:
            if ts + idle - 1 <= t <= ts + idle + 5:
                causes[cause] = causes.get(cause, 0) + 1
        r["idle_close_causes"] = causes
        t_chk = ts + idle + 5
        live = sum(t <= t_chk for t in opened) - sum(t <= t_chk for t, _ in closed)
        r["sessions_at_check"] = live
        r["c2_close"] = "PASS" if len(inside) >= n and live == 3 else "FAIL"
    stale = 'moq_relay_stale_groups_total{tier="",role="publisher"}'
    if stale in met:
        s = met[stale]
        r["stale_groups"] = (value_at(s, T_END) or 0) - (value_at(s, 20) or 0)

    # --- criteria 3 and 4: the abusers ---------------------------------------------------------
    fates = []
    for a in abusers:
        sa = subs[a]
        rows = ps.get(pids[a], [])
        gone = None
        if rows and exits.get(a, ("running",))[0] == "exited":
            gone = rows[-1][0] + 0.5
        fate = {}
        if ev == "slow":
            lags = [(t, lag(sa, v1, t)) for t in grid(55, T_EV + dur)]
            vals = [x for _, x in lags if x is not None]
            fate["slow_lag_max_s"] = round(max(vals), 2) if vals else None
            if len(vals) > 2:
                xs = [t for t, x in lags if x is not None]
                fate["slow_lag_slope"] = round(statistics.linear_regression(xs, vals).slope, 3)
            share = sa.gain("n111", 55, T_EV + dur) / max(1, v1.gain("n111", 55, T_EV + dur))
            fate["slow_video_share"] = round(share, 3)
            ex, _ = rss_excess(rows, 45, T_EV + dur)
            fate["slow_export_rss_mb"] = None if ex is None else round(ex, 1)
            ok = vals and max(vals) <= 4 and share >= 0.25 and ex is not None and ex <= 32
            fate["c3"] = "PASS" if ok else "FAIL"
        if ev in ("slow", "stop", "freeze"):
            te = T_EV + dur if ev in ("slow", "stop") else events.get("CONT", T_EV + dur)
            dl = 15.0 if (ev == "freeze" and (dur >= 30 or n > 1)) else 10.0
            fate["te"] = round(te, 1)
            if gone is not None and gone <= te + dl:
                fate["fate"] = "exit"
                fate["exit_at_s"] = round(gone, 1)
            else:
                end = min(t_end - 0.1, sa.last_t())
                live_from = None
                for t in grid(te, end):
                    x = lag(sa, v1, t)
                    if x is not None and abs(x) <= 0.5:
                        if live_from is None:
                            live_from = t
                    else:
                        live_from = None
                # A hang: alive, reading, no new video PTS for more than 10 s after te.
                hang, last_pts, last_change = False, None, te
                for t in grid(te, end):
                    row = sa.at(t)
                    p = row["dts111"] if row else None
                    if p != last_pts:
                        last_pts, last_change = p, t
                    elif t - last_change > 10:
                        hang = True
                        break
                if hang:
                    fate["fate"] = "hang"
                elif live_from is not None and live_from <= te + dl:
                    fate["fate"] = "live"
                    fate["live_after_s"] = round(live_from - te, 1)
                else:
                    fate["fate"] = "stale"
                    x = lag(sa, v1, min(te + dl, end))
                    fate["lag_at_deadline_s"] = None if x is None else round(x, 2)
            fate["c4"] = "PASS" if fate["fate"] in ("exit", "live") else "FAIL"
            # Reported, not graded: the peak 1 s of output after te, as a multiple of the line rate.
            peak = max(
                (sa.gain("bytes", t, t + 1) for t in grid(te, min(te + 5, sa.last_t() - 1))),
                default=0,
            )
            fate["burst_x"] = round(peak * 8 / RATE, 1)
        _, notable = export_log(cell / "logs" / f"{a}.log", t0)
        seen = {}
        for t, lvl, msg in notable:
            if t >= T_EV - 1:
                seen.setdefault(template(msg), (round(t, 1), lvl, msg[:200]))
        fate["log"] = list(seen.values())[:6]
        fates.append((a, fate))
    r["fates"] = fates
    return r


def control_means(cells):
    acc = {}
    for cell in cells:
        m = meta(cell)
        if m["arm"] not in ("control", "pt-control"):
            continue
        for name in ("v1", "v2"):
            s = Sub(cell / f"{name}.csv", m["t0"])
            for p in PIDS:
                acc.setdefault((m["lane"], m["noq"]), {}).setdefault(p, []).append(s.gain(f"n{p}", 45, T_END))
    return {k: {p: statistics.mean(v) for p, v in d.items()} for k, d in acc.items()}


def main():
    root = Path(sys.argv[1])
    out_csv = sys.argv[sys.argv.index("--csv") + 1] if "--csv" in sys.argv else None
    cells = sorted(
        (c for c in root.iterdir() if (c / "meta.txt").exists() and (c / "pids.tsv").exists()),
        key=lambda c: int(c.name.split("-")[0]),
    )
    extra = []
    if "--controls" in sys.argv:
        croot = Path(sys.argv[sys.argv.index("--controls") + 1])
        extra = [c for c in croot.iterdir() if (c / "meta.txt").exists() and (c / "pids.tsv").exists()]
    controls = control_means(cells + extra)
    results = [grade_cell(c, controls) for c in cells]
    for r in results:
        print(f"== {r['cell']}  [{r['build']}, {r['lane']}, N={r['abusers']}, {r['event']}, idle {r['idle']}]")
        if r["void"]:
            print(f"   VOID: {r['void']}")
        print(f"   C1 {r['c1']}  victim lag max {r['victim_lag_max_s']} s  v1 video PES {r['v1_n111']}")
        extra = {
            k: r[k]
            for k in (
                "relay_base_mb",
                "L_mb",
                "G_mb",
                "relay_after_mb",
                "fp_base_mb",
                "fp_L_per_session_mb",
                "fp_G_per_session_mb",
                "idle_closes",
                "idle_close_s",
                "idle_close_causes",
                "sessions_at_check",
                "c2_close",
                "stale_groups",
                "slow_bps",
                "stop_lag_rise_s",
            )
            if k in r
        }
        print(f"   {extra}")
        tally = {}
        for a, f in r["fates"]:
            if r["abusers"] > 2:
                tally[f.get("fate")] = tally.get(f.get("fate"), 0) + 1
                continue
            log = f.pop("log")
            print(f"   {a}: {f}")
            for t, lvl, msg in log:
                print(f"      {t:7.1f} {lvl} {msg}")
        if tally:
            live = [f["live_after_s"] for _, f in r["fates"] if "live_after_s" in f]
            exits = [f["exit_at_s"] for _, f in r["fates"] if "exit_at_s" in f]
            print(f"   abuser fates {tally}")
            if live:
                print(f"   live after {min(live)}-{max(live)} s past the SIGCONT")
            if exits:
                print(f"   exits at {min(exits)}-{max(exits)} s")
            first = r["fates"][0][1]
            for t, lvl, msg in first.get("log", []):
                print(f"      a1 {t:7.1f} {lvl} {msg}")

    # --- criterion 2: cost per session, across cells -------------------------------------------
    print("== cost per frozen session (criterion 2)")
    for build in sorted({r["build"] for r in results}):
        cost = [r for r in results if r["build"] == build and r["abusers"] >= 32 and "L_mb" in r]
        if not cost:
            continue
        nulls = [r for r in cost if r["event"] == "none"]
        for r in cost:
            print(
                f"   {build} {r['cell']}: L {r['L_mb']} MB ({r['L_per_session_mb']}/session), "
                f"G {r['G_mb']} MB ({r['G_per_session_mb']}/session), after {r.get('relay_after_mb')}"
            )
        if not nulls or any(r["void"] for r in nulls):
            print(f"   {build} H2 VOID: no valid healthy32 null")
            continue
        r1 = [r for r in cost if r["arm"] == "r1" and not r["void"]]
        r2 = [r for r in cost if r["arm"] == "r2" and not r["void"]]
        r3 = [r for r in cost if r["arm"] == "r3" and not r["void"]]
        if r1 and r2:
            level_ok = all(r["L_per_session_mb"] <= 6.5 for r in r1 + r2)
            growth_ok = all(r["G_per_session_mb"] <= 2.5 for r in r2)
            if level_ok and growth_ok:
                verdict = "PASS: the send-window model"
            elif any(r["G_per_session_mb"] >= 12 for r in r2):
                verdict = "FAIL: T25's retention model (cost grows while stuck)"
            else:
                verdict = "FAIL: neither model"
            print(f"   {build} H2 {verdict}")
        if r3 and r2:
            d = statistics.mean(r["L_per_session_mb"] for r in r3) - statistics.mean(r["L_per_session_mb"] for r in r2)
            binds = "the send window" if d > 2.5 else "not the send window"
            print(f"   {build} r3 - r2 level per session {d:.2f} MB: {binds} binds")

    if out_csv:
        keys = [
            "cell",
            "build",
            "arm",
            "lane",
            "abusers",
            "event",
            "idle",
            "send_window",
            "void",
            "c1",
            "victim_lag_max_s",
            "v1_n111",
            "v2_n111",
            "relay_base_mb",
            "L_mb",
            "G_mb",
            "L_per_session_mb",
            "G_per_session_mb",
            "relay_after_mb",
            "fp_base_mb",
            "fp_L_per_session_mb",
            "fp_G_per_session_mb",
            "idle_closes",
            "idle_close_s",
            "idle_close_causes",
            "sessions_at_check",
            "c2_close",
            "stale_groups",
            "slow_bps",
            "stop_lag_rise_s",
            "abuser_fates",
        ]
        with open(out_csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
            w.writeheader()
            for r in results:
                fates = []
                for a, fa in r["fates"]:
                    fa = {k: v for k, v in fa.items() if k != "log"}
                    fates.append(f"{a}:" + ",".join(f"{k}={v}" for k, v in fa.items() if k != "log"))
                w.writerow({**r, "abuser_fates": " | ".join(fates)})


if __name__ == "__main__":
    main()

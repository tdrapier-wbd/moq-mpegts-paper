#!/usr/bin/env python3
"""Grade T82's follow-up cells, Parts B-D of lab/test-82-slow-unresponsive-subscribers.md.

Usage: t82-followup.py <root> [--controls <root>] [--csv out.csv]

Each cell is graded by the matrix grader first (criterion zero and the victims' criterion 1, against
the control cells of --controls), then by its part: a receiver chain (-tsp, -pacer), a reset drain
(r2x32l, r2x64, r2x64f, and Part G's r2) or a storm. Part E's slow-np cells take the matrix grader's
criterion 3.
"""

import csv
import importlib.util
import statistics
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("g", Path(__file__).with_name("t82-grade.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def events(cell):
    out = []
    if (cell / "events.tsv").exists():
        for line in (cell / "events.tsv").read_text().splitlines():
            ms, what, arg = line.split("\t")
            out.append((int(ms) / 1000, what, arg))
    return out


def part_b(cell, m):
    t0, t_end, te = m["t0"], float(m["t_end"]), g.T_EV + m["dur"]
    v1, k1r, a1r = (g.Sub(cell / f"{k}.csv", t0) for k in ("v1", "k1r", "a1r"))
    lk = [(t, g.lag(k1r, v1, t)) for t in g.grid(20, t_end - 0.5)]
    base = statistics.median(x for t, x in lk if t < 45 and x is not None)
    off = [t for t, x in lk if x is None or abs(x - base) > 0.5]
    runs, run = [], []
    for t in off:
        if run and t - run[-1] > 0.15:
            runs.append(run)
            run = []
        run.append(t)
    if run:
        runs.append(run)
    longest = max((r[-1] - r[0] + 0.1 for r in runs), default=0.0)
    valve = g.Sub(cell / "a1.csv", t0).gain("bytes", 46, 105)
    r = {"B_s": round(base, 3), "k1_off_rows_pct": round(100 * len(off) / len(lk), 2)}
    r["k1_longest_off_s"] = round(longest, 1)
    r["valve_gain_46_105"] = valve
    r["valid"] = len(off) <= 0.01 * len(lk) and longest <= 1.0 and valve <= 65536
    la = {t: g.lag(a1r, v1, t) for t in g.grid(te, t_end - 0.5)}
    behind = [x - base for t, x in la.items() if te + 10 <= t <= te + 40 and x is not None]
    r["HB"] = bool(behind) and min(behind) >= 50 and len(behind) == len(g.grid(te + 10, te + 40))
    back = None
    for t in sorted(la):
        x = la[t]
        if x is not None and x <= base + 0.5:
            back = back if back is not None else t
        else:
            back = None
    r["back_after_s"] = None if back is None else round(back - te, 1)
    r["remedy"] = back is not None and back <= te + 10
    for d in (10, 40, 100):
        x = g.lag(a1r, v1, te + d)
        r[f"La_te+{d}"] = None if x is None else round(x, 2)
    for a, b in ((te, te + 10), (te + 10, te + 60), (te + 60, t_end - 1)):
        r[f"rx_mbps_{a - te:.0f}_{b - te:.0f}"] = round(a1r.gain("bytes", a, b) * 8 / (b - a) / 1e6, 2)
    r["rx_video_share"] = round(a1r.gain("n111", te, t_end - 1) / max(1, v1.gain("n111", te, t_end - 1)), 3)
    r["rx_last_s"] = round(a1r.last_t(), 1)
    return r


def exit_times(cell, m):
    """abuser -> its export's exit time (s after t0), or None if it ran to the cell's end."""
    pids = {k: int(v) for k, v in (ln.split("\t") for ln in (cell / "pids.tsv").read_text().splitlines())}
    ps = g.ps_rows(cell)
    states = dict(ln.split("\t", 1) for ln in (cell / "exits.tsv").read_text().splitlines())
    out = {}
    for k, pid in pids.items():
        if not k.startswith("a"):
            continue
        rows = ps.get(pid, [])
        out[k] = rows[-1][0] + 0.5 if rows and states.get(k, "").startswith("exited") else None
        # The log's last timestamped line, as a check on the process table.
        clock, notable = g.export_log(cell / "logs" / f"{k}.log", m["t0"])
        last = max([t for t, *_ in clock] + [t for t, *_ in notable], default=None)
        if out[k] is not None and last is not None and abs(out[k] - last) > 1.5:
            print(f"   note {k}: ps exit {out[k]:.1f} vs last log line {last:.1f}")
    return out


def part_c(cell, m):
    cont = next(t for t, what, _ in events(cell) if what == "CONT")
    ex = exit_times(cell, m)
    ends = sorted((t - cont) if t is not None else None for t in ex.values() if True)
    done = [x for x in ends if x is not None]
    late = [x for x in ends if x is None or x > 15]
    r = {"n": len(ends), "late": len(late), "never": ends.count(None)}
    r["drain_s"] = round(max(done), 1) if ends and None not in ends else f">={float(m['t_end']) - cont:.0f}"
    r["ends_s"] = [round(x, 1) for x in done]
    if done:
        r["p50_s"] = round(statistics.median(done), 1)
    return r


def part_d(cell, m):
    t0 = m["t0"]
    with open(cell / "fp.tsv") as f:
        # A zero is the sampler's read after the relay exited.
        rows = csv.DictReader(f, delimiter="\t")
        fp = [(float(x["t"]), float(x["footprint_mb"])) for x in rows if float(x["footprint_mb"]) > 0]
    f0 = statistics.median(v for t, v in fp if 39 <= t < 45)
    opened, closed = g.relay_sessions(cell / "logs" / "relay.log", t0)
    closes = [t for t, _ in closed]

    def held(t):
        return sum(x <= t for x in opened) - sum(x <= t for x in closes)

    win = [(t, v) for t, v in fp if 50 <= t <= 110]
    p = max(v for _, v in win) - f0
    h = max(held(t) for t, _ in win) - 3
    idle = m["idle_s"]
    rec_t = 105 + idle + 30
    rec = [v for t, v in fp if rec_t - 2.5 <= t <= rec_t + 2.5]
    causes = {}
    for t, c in closed:
        if t > 45:
            causes[c[:60]] = causes.get(c[:60], 0) + 1
    gens = sum(1 for _, what, _ in events(cell) if what == "STORM")
    t_end = float(m["t_end"])
    drained = next((t for t, _ in fp if t > 105 and held(t) <= 3), None)
    after = [v for t, v in fp if drained is not None and drained + 5 <= t <= t_end - 2]
    return {
        "F0_mb": round(f0, 1),
        "P_mb": round(p, 1),
        "H_sessions": h,
        "P_per_H_mb": round(p / h, 2) if h else None,
        "HD": bool(h) and p / h <= 1.0,
        "T25": bool(h) and p / h >= 5.0,
        f"F_at_{rec_t:.0f}_minus_F0_mb": round(statistics.median(rec) - f0, 1) if rec else None,
        "recovered": bool(rec) and statistics.median(rec) - f0 <= 40,
        "accepted_after_45": sum(t > 45 for t in opened),
        "closed_after_45": causes,
        "storm_ticks": gens,
        "held_back_to_3_at_s": None if drained is None else round(drained, 1),
        "F_after_drain_minus_F0_mb": round(statistics.median(after) - f0, 1) if after else None,
    }


def main():
    root = Path(sys.argv[1])
    croot = Path(sys.argv[sys.argv.index("--controls") + 1]) if "--controls" in sys.argv else None
    cells = sorted(
        (c for c in root.iterdir() if (c / "meta.txt").exists() and (c / "pids.tsv").exists()),
        key=lambda c: int(c.name.split("-")[0]),
    )
    extra = []
    if croot:
        extra = [c for c in croot.iterdir() if (c / "meta.txt").exists() and (c / "pids.tsv").exists()]
    controls = g.control_means(cells + extra)
    rows = []
    for cell in cells:
        m = g.meta(cell)
        m.setdefault("t_end", g.T_END)
        r = g.grade_cell(cell, controls)
        print(f"== {cell.name}  [{r['build']}, N={m['abusers']}, {m['event']}, idle {m['idle']}]")
        if r["void"]:
            print(f"   VOID: {r['void']}")
        print(f"   C1 {r['c1']}  victim lag max {r['victim_lag_max_s']} s")
        if m.get("rx", "none") != "none":
            part = part_b(cell, m)
        elif m["event"] == "storm":
            part = part_d(cell, m)
        elif m["arm"].startswith("r2"):
            part = part_c(cell, m)
        elif m["event"] == "slow":
            keep = ("slow_lag_max_s", "slow_lag_slope", "slow_video_share", "slow_export_rss_mb", "c3", "fate")
            part = {k: v for k, v in r["fates"][0][1].items() if k in keep + ("live_after_s", "burst_x")}
        else:
            print("   (not a follow-up cell)")
            continue
        for k, v in part.items():
            print(f"   {k}: {v}")
        rows.append({"cell": cell.name, "build": r["build"], "void": r["void"], "c1": r["c1"], **part})
    if "--csv" in sys.argv:
        keys = list(dict.fromkeys(k for row in rows for k in row))
        with open(sys.argv[sys.argv.index("--csv") + 1], "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            w.writerows(rows)


if __name__ == "__main__":
    main()

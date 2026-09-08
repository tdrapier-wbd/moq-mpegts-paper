#!/usr/bin/env python3
"""Grade an F5 cross-host fan-out ramp: join the two hosts' samples and name what bound it.

The two sides are measured on their own hosts by their own scripts, so the join is by wall clock.
The subscriber side writes an epoch for each phase boundary; the relay side samples once a second.
For each N we take the relay's counters across exactly the window the subscriber side used to
compute delivery, so the two columns of a row describe the same 45 seconds.

The point of the join is attribution. A fan-out ramp always ends somewhere, and the useful output is
not the last N but which resource ran out first, so every row carries the relay's own CPU, the box it
sits on, the interface's throughput, and the counters AWS increments when it decides to police that
interface. If delivery collapses while all four allowance counters are flat and the relay is not at
its core limit, then neither the network nor the relay's CPU is the explanation and the search has to
continue -- which is a more useful result than a maximum.

Shapes are fitted rather than asserted. The claim this experiment exists to test is "near-zero
marginal cost per subscriber", and the way to be wrong about that is to fit a line to a curve, so a
linear and a quadratic fit are compared over the pre-collapse points and both are reported.
"""

import argparse
import csv
import statistics as st

HZ = 100  # kernel USER_HZ, as read by /proc on these hosts


def load_phases(path):
    """Measure windows, keyed by N, as (start, end) epochs."""
    starts = {}
    for line in open(path):
        f = line.split()
        if len(f) >= 3 and f[2] == "measure_start":
            starts[int(f[1].split("=")[1])] = int(f[0])
    return starts


def load_relay(path):
    rows = []
    for r in csv.DictReader(open(path)):
        try:
            rows.append({k: int(v) if v not in ("", None) else 0 for k, v in r.items()})
        except ValueError:
            continue
    return rows


def window(rows, t0, t1):
    """First and last relay sample inside [t0, t1]."""
    inside = [r for r in rows if t0 <= r["epoch"] <= t1]
    return (inside[0], inside[-1]) if len(inside) >= 2 else (None, None)


def fit_linear(xs, ys):
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return 0.0, my, 0.0
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    a = my - b * mx
    ss_tot = sum((y - my) ** 2 for y in ys)
    ss_res = sum((y - (a + b * x)) ** 2 for x, y in zip(xs, ys))
    r2 = 1 - ss_res / ss_tot if ss_tot else 1.0
    return b, a, r2


def fit_quadratic(xs, ys):
    """Least squares y = a + bx + cx^2 by normal equations; returns (c, r2)."""
    n = len(xs)
    if n < 4:
        return None, None
    S = [[0.0] * 4 for _ in range(3)]
    for i in range(3):
        for j in range(3):
            S[i][j] = sum(x ** (i + j) for x in xs)
        S[i][3] = sum(y * x**i for x, y in zip(xs, ys))
    for i in range(3):
        p = max(range(i, 3), key=lambda r: abs(S[r][i]))
        S[i], S[p] = S[p], S[i]
        if abs(S[i][i]) < 1e-12:
            return None, None
        for r in range(3):
            if r != i:
                f = S[r][i] / S[i][i]
                for c in range(i, 4):
                    S[r][c] -= f * S[i][c]
    coef = [S[i][3] / S[i][i] for i in range(3)]
    my = sum(ys) / n
    ss_tot = sum((y - my) ** 2 for y in ys)
    ss_res = sum((y - (coef[0] + coef[1] * x + coef[2] * x * x)) ** 2 for x, y in zip(xs, ys))
    r2 = 1 - ss_res / ss_tot if ss_tot else 1.0
    return coef[2], r2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--relay", required=True)
    ap.add_argument("--subs", required=True)
    ap.add_argument("--phases", required=True)
    ap.add_argument("--cores", type=int, default=2, help="cores on the relay host")
    a = ap.parse_args()

    phases = load_phases(a.phases)
    relay = load_relay(a.relay)
    subs = list(csv.DictReader(open(a.subs)))

    print(
        f"{'N':>4} {'alive':>5} {'per-sub':>9} {'%N=1':>6} {'agg Mb/s':>9} "
        f"{'relay CPU':>9} {'relay/box':>9} {'relay RSS':>9} {'thr':>4} {'fd':>4} "
        f"{'tx Mb/s':>8} {'kpps':>6} {'alw':>4} {'subs cores':>10} {'sub box':>7}"
    )
    print("-" * 126)

    table = []
    for s in subs:
        N = int(s["n_target"])
        t0 = phases.get(N)
        if t0 is None:
            continue
        r0, r1 = window(relay, t0, t0 + int(s["window_s"]))
        if r0 is None:
            continue
        dt = r1["epoch"] - r0["epoch"]
        if dt <= 0:
            continue
        rcpu = (r1["relay_cpu_ticks"] - r0["relay_cpu_ticks"]) / HZ / dt * 100
        bt = r1["box_total"] - r0["box_total"]
        bi = r1["box_idle"] - r0["box_idle"]
        rbox = (bt - bi) / bt * 100 if bt else 0.0
        tx = (r1["tx_bytes"] - r0["tx_bytes"]) * 8 / dt / 1e6
        pps = (r1["tx_packets"] - r0["tx_packets"]) / dt / 1e3
        alw = sum((r1[k] - r0[k]) for k in ("bw_out_exc", "bw_in_exc", "pps_exc", "conntrack_exc"))
        row = dict(
            n=N,
            alive=int(s["n_alive"]),
            per=float(s["per_sub_bps"]) / 1e6,
            frac=float(s["per_sub_frac"]) * 100,
            agg=float(s["agg_bps"]) / 1e6,
            rcpu=rcpu,
            rbox=rbox,
            rss=r1["relay_rss_kb"] / 1024,
            thr=r1["relay_thr"],
            fd=r1["relay_fd"],
            tx=tx,
            pps=pps,
            alw=alw,
            subcores=float(s["sub_cpu_pct_core"]) / 100,
            subbox=float(s["box_busy_pct"]),
        )
        table.append(row)
        print(
            f"{row['n']:>4} {row['alive']:>5} {row['per']:>8.2f}M {row['frac']:>5.1f}% "
            f"{row['agg']:>9.0f} {rcpu:>8.1f}% {rbox:>8.1f}% {row['rss']:>8.1f}M "
            f"{row['thr']:>4} {row['fd']:>4} {tx:>8.0f} {pps:>6.1f} {alw:>4} "
            f"{row['subcores']:>10.2f} {row['subbox']:>6.1f}%"
        )

    # Pre-collapse points only: a fit that spans the cliff describes neither side of it.
    good = [r for r in table if r["frac"] >= 95.0]
    print()
    if len(good) >= 3:
        xs = [r["n"] for r in good]
        print(f"Scaling model over the {len(good)} points that held delivery (N={xs[0]}..{xs[-1]}):")
        for label, key, unit in (
            ("relay CPU", "rcpu", "% of a core"),
            ("relay RSS", "rss", "MB"),
            ("egress", "tx", "Mb/s"),
        ):
            ys = [r[key] for r in good]
            b, a0, r2 = fit_linear(xs, ys)
            c, qr2 = fit_quadratic(xs, ys)
            extra = ""
            if c is not None:
                extra = f"   quadratic r2={qr2:.4f} (x^2 coef {c:+.3e})"
            print(f"  {label:10s} = {a0:8.2f} + {b:8.4f} per subscriber {unit:12s} linear r2={r2:.4f}{extra}")
        rc = fit_linear(xs, [r["rcpu"] for r in good])[0]
        if rc > 0:
            print(
                f"\n  At {rc:.4f} % of a core per subscriber, one core serves ~{100 / rc:.0f} "
                f"and this {a.cores}-core host ~{100 * a.cores / rc:.0f} before CPU alone binds."
            )
        pers = [r["per"] for r in good]
        print(
            f"  Per-subscriber delivery across those points: "
            f"{min(pers):.2f}-{max(pers):.2f} Mb/s (spread {(max(pers) - min(pers)) / st.mean(pers) * 100:.2f} %)"
        )

    bad = [r for r in table if r["frac"] < 95.0]
    if bad:
        b = bad[0]
        last = good[-1] if good else None
        print(f"\nCollapse at N={b['n']}:")
        if last:
            print(
                f"  aggregate {last['agg']:.0f} -> {b['agg']:.0f} Mb/s, "
                f"per-subscriber {last['per']:.2f} -> {b['per']:.2f} Mb/s"
            )
        print(f"  relay CPU {b['rcpu']:.1f} % of a core ({b['rbox']:.1f} % of the relay box)")
        print(f"  relay egress {b['tx']:.0f} Mb/s at {b['pps']:.1f} kpps")
        print(f"  subscriber host {b['subbox']:.1f} % busy, subscribers using {b['subcores']:.2f} cores")
        print(f"  EC2 allowance counters incremented during the window: {b['alw']}")
        print(f"  subscribers still alive: {b['alive']} of {b['n']}")
        verdict = []
        if b["alw"] > 0:
            verdict.append("the interface was policed by EC2 — a NIC limit, not a relay limit")
        if b["rcpu"] > 90 * a.cores:
            verdict.append(f"the relay itself was at its core limit ({b['rcpu']:.0f} % of {a.cores})")
        elif b["rbox"] > 90:
            verdict.append("the relay's host was out of CPU, though the relay itself was not")
        if b["subbox"] > 85:
            verdict.append("the subscriber host was saturated — the harness, not the relay")
        # Subscribers that vanish while their own host still has CPU to spare are
        # the signature of the harness running out of *memory* rather than of the
        # relay refusing service: the export client's footprint is fixed per
        # process, so that ceiling is the subscriber box's RAM divided by it.
        if b["alive"] < b["n"] and b["subbox"] <= 85:
            verdict.append(
                f"{b['n'] - b['alive']} subscriber(s) disappeared with their host at only "
                f"{b['subbox']:.0f} % busy — check it for the OOM killer before reading this as a relay limit"
            )
        if not verdict:
            verdict.append(
                "none of NIC policing, relay CPU or harness saturation explains it — the binding resource is elsewhere"
            )
        print("  reading: " + "; ".join(verdict))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""A transport stream's system clock against the host clock that timed its arrivals.

    ts-pcr-rate.py <egress-pcr.csv> [--source <source-pcr.csv>] [--window 600] [--step 60]
                   [--settle 10] [--limit-ppm 30] [--limit-hz-s 0.075] [--settled-ppm 0.5]

Reads the `t_ns,pcr` logs `t18-latency.py tap --pcr` writes, one line per PCR as it arrived,
and fits the PCR (27 MHz) against the arrival time:

- **PCR_FO**: the whole-run fit, after `--settle` seconds, in ppm against the host's clock,
  graded against 13818-1 2.4.2.1's 30 ppm (810 Hz).
- **PCR_DR**: the change in that rate between consecutive `--window` windows, in Hz/s of
  27 MHz, graded against 2.4.2.1's 0.075 Hz/s. Windows stepped by `--step` are reported beside
  it, ungraded, for where in the run the largest change falls.
- **The instrument's floor**: each window's residual about its own fit, and from it the
  standard error of the slope and of a difference of two windows, in Hz/s. A change below
  about three times that floor is not resolved.

With `--source`, the source's rate in each window (timed on its own host) is reported beside
the output's, with their difference; the run has settled if the last window's difference is
within `--settled-ppm`. The two host clocks are both disciplined, so the difference carries
their disagreement, which `t18-latency.py clock-client` can bound.

A PCR that steps by more than 100 ms from where the arrivals put it is a discontinuity: it is
counted, and the fit continues across it as if the step had not happened.
"""

from __future__ import annotations

import sys

WRAP = (1 << 33) * 300
HZ = 27e6


def load(path: str) -> tuple[list[float], list[float], int]:
	"""Arrival seconds and PCR seconds, unwrapped and spliced across discontinuities."""
	ts: list[float] = []
	ys: list[float] = []
	steps = 0
	prev_t = prev_raw = None
	offset = 0.0
	with open(path) as f:
		next(f)
		for line in f:
			a, b = line.split(",")
			t = int(a) / 1e9
			raw = int(b)
			if prev_raw is not None:
				d = raw - prev_raw
				if d < -WRAP // 2:
					d += WRAP
				elif d > WRAP // 2:
					d -= WRAP
				dt = t - prev_t
				if abs(d / HZ - dt) > 0.1:
					steps += 1
					d = round(dt * HZ)
				ys.append(ys[-1] + d / HZ)
			else:
				ys.append(offset)
			ts.append(t)
			prev_t, prev_raw = t, raw
	return ts, ys, steps


def fit(ts: list[float], ys: list[float], lo: int, hi: int) -> tuple[float, float, int]:
	"""Least-squares slope of PCR on arrival over [lo, hi), as ppm, the residual RMS in
	seconds, and the point count."""
	n = hi - lo
	if n < 3:
		return float("nan"), float("nan"), n
	t0, y0 = ts[lo], ys[lo]
	sx = sy = sxx = sxy = 0.0
	for i in range(lo, hi):
		x, y = ts[i] - t0, ys[i] - y0
		sx += x
		sy += y
		sxx += x * x
		sxy += x * y
	den = n * sxx - sx * sx
	slope = (n * sxy - sx * sy) / den
	icpt = (sy - slope * sx) / n
	ss = 0.0
	for i in range(lo, hi):
		r = (ys[i] - y0) - (icpt + slope * (ts[i] - t0))
		ss += r * r
	return (slope - 1.0) * 1e6, (ss / n) ** 0.5, n


def windows(ts: list[float], start: float, width: float, step: float) -> list[tuple[float, int, int]]:
	"""(start time, first index, end index) for each whole window from `start`."""
	out = []
	lo = 0
	w0 = start
	while w0 + width <= ts[-1]:
		while lo < len(ts) and ts[lo] < w0:
			lo += 1
		hi = lo
		while hi < len(ts) and ts[hi] < w0 + width:
			hi += 1
		out.append((w0, lo, hi))
		w0 += step
	return out


def main() -> None:
	args = sys.argv[1:]
	if not args or args[0].startswith("-"):
		sys.exit(__doc__)

	def opt(flag, default, cast=float):
		return cast(args[args.index(flag) + 1]) if flag in args else default

	width = opt("--window", 600.0)
	step = opt("--step", 60.0)
	settle = opt("--settle", 10.0)
	lim_ppm = opt("--limit-ppm", 30.0)
	lim_dr = opt("--limit-hz-s", 0.075)
	settled = opt("--settled-ppm", 0.5)
	src_path = opt("--source", "", str)

	ts, ys, steps = load(args[0])
	start = ts[0] + settle
	lo = next(i for i, t in enumerate(ts) if t >= start)
	whole, rms, n = fit(ts, ys, lo, len(ts))
	span = ts[-1] - start
	print(f"egress: {len(ts):,} PCRs over {ts[-1] - ts[0]:.0f} s, {steps} discontinuities")
	print(
		f"PCR_FO: {whole:+.3f} ppm on the whole-run fit over {span:.0f} s "
		f"({'PASS' if abs(whole) <= lim_ppm else 'FAIL'}, limit {lim_ppm:g} ppm); residual RMS {rms * 1e3:.3f} ms"
	)

	src = None
	if src_path:
		sts, sys_, ssteps = load(src_path)
		slo = next(i for i, t in enumerate(sts) if t >= sts[0] + settle)
		swhole, srms, _ = fit(sts, sys_, slo, len(sts))
		print(f"source: {len(sts):,} PCRs, {ssteps} discontinuities, {swhole:+.3f} ppm whole-run, residual RMS {srms * 1e3:.3f} ms")
		src = (sts, sys_)

	rows = []
	for w0, a, b in windows(ts, start, width, width):
		ppm, r, k = fit(ts, ys, a, b)
		se = r * (12.0 / k) ** 0.5 / width * 1e6 if k > 2 else float("nan")
		sppm = float("nan")
		if src:
			sts, sys_ = src
			# The same media span on the source's clock is earlier by the latency; the source
			# rate barely moves within a window, so the matching wall-clock window serves.
			sw = [x for x in windows(sts, w0, width, width)[:1]]
			if sw:
				sppm = fit(sts, sys_, sw[0][1], sw[0][2])[0]
		rows.append((w0 - start, ppm, r, se, k, sppm))

	print(f"\n{len(rows)} windows of {width:g} s from +{settle:g} s:")
	print("   start s    egress ppm   resid ms   slope SE ppm   source ppm   egress-source ppm")
	for t0, ppm, r, se, k, sppm in rows:
		diff = ppm - sppm if src else float("nan")
		print(f"   {t0:7.0f}    {ppm:+10.3f}   {r * 1e3:8.3f}   {se:12.4f}   {sppm:+10.3f}   {diff:+10.3f}")

	if len(rows) >= 2:
		drs = [abs(rows[i + 1][1] - rows[i][1]) * HZ / 1e6 / width for i in range(len(rows) - 1)]
		worst = max(drs)
		floor = max(r[3] for r in rows) * 2**0.5 * HZ / 1e6 / width
		verdict = "PASS" if worst <= lim_dr else "FAIL"
		print(
			f"\nPCR_DR: worst change between consecutive {width:g} s windows {worst:.4f} Hz/s "
			f"({verdict}, limit {lim_dr:g}); the instrument's floor on a difference {floor:.5f} Hz/s (1 SE)"
		)
		print("   per pair:", " ".join(f"{d:.4f}" for d in drs))
		slid = windows(ts, start, width, step)
		k = int(round(width / step))
		if len(slid) > k:
			rates = [fit(ts, ys, a, b)[0] for _, a, b in slid]
			best = max(range(len(rates) - k), key=lambda i: abs(rates[i + k] - rates[i]))
			print(
				f"   windows stepped {step:g} s: largest change {abs(rates[best + k] - rates[best]) * HZ / 1e6 / width:.4f} Hz/s, "
				f"between windows starting +{slid[best][0] - start:.0f} s and +{slid[best + k][0] - start:.0f} s"
			)
	if src and rows:
		last = rows[-1][1] - rows[-1][5]
		print(
			f"settled: last window egress-source {last:+.3f} ppm "
			f"({'yes' if abs(last) <= settled else 'no'}, within {settled:g} ppm)"
		)


if __name__ == "__main__":
	main()

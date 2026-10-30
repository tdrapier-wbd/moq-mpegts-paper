#!/usr/bin/env python3
"""Grade one t70-wan-cell.sh cell: grade.json in the cell, and one JSON line on stdout.

  - the clock: the probes' mean offset corrects the latency, their drift and uncertainty bound it
    (criterion 1);
  - delivery latency by t18-latency.py report over the origin's source tap and the egress tap, with
    that offset and an 8 s settle;
  - clean (criterion 2): the groomer's counters from its first output to the stop, from its 1 s
    samples, and the receiver's give-ups, both as t68-netns-grade.py reads them;
  - P1/P2 on the saved egress: TSDuck continuity, pcrverify --absolute --jitter-max 13 (481 ns) and
    PCR intervals over 40 ms from pcrextract, as T18;
  - the buffer model: ts-tstd.py --skip 8, pass when it exits 0, as T44.

Usage: t70-wan-grade.py <cell-dir> [--scripts DIR]
"""

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys


def load(scripts, name):
	spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(scripts, name))
	mod = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(mod)
	return mod


def probe(path):
	try:
		text = open(path).read()
	except OSError:
		return None
	m = dict(re.findall(r"^(offset_s|uncertainty_s) (-?[\d.]+)$", text, re.M))
	return {k: float(v) for k, v in m.items()} if "offset_s" in m else None


def clock(cell):
	a, b = probe(os.path.join(cell, "clock-before.txt")), probe(os.path.join(cell, "clock-after.txt"))
	if not a:
		return dict(error="no probe before the cell")
	b = b or a
	drift = abs(b["offset_s"] - a["offset_s"]) * 1e3
	unc = max(a["uncertainty_s"], b["uncertainty_s"]) * 1e3
	return dict(offset_s=round((a["offset_s"] + b["offset_s"]) / 2, 6), drift_ms=round(drift, 2),
				uncertainty_ms=round(unc, 2), after_probed=b is not a, ok=drift <= 10 and unc <= 10)


def latency(cell, scripts, offset_s):
	kv = os.path.join(cell, "lat.kv")
	r = subprocess.run([sys.executable, os.path.join(scripts, "t18-latency.py"), "report",
						os.path.join(cell, "origin", "src.csv"), os.path.join(cell, "eg.csv"),
						"--clock-offset", f"{offset_s:.6f}", "--settle", "8", "--kv", kv],
					   capture_output=True, text=True)
	open(os.path.join(cell, "lat.txt"), "w").write(r.stdout + r.stderr)
	try:
		d = dict(line.strip().split("=", 1) for line in open(kv) if "=" in line)
	except OSError:
		return dict(error="no latency")
	out = {k: float(d[k]) for k in ("lat_min", "lat_median", "lat_p95", "lat_max", "trend_head",
									  "trend_tail") if k in d}
	out["matched"], out["seen"], out["shift"] = int(d["matched"]), int(d["seen"]), int(d["shift"])
	return out


def wire(cell):
	ts = os.path.join(cell, "out.ts")
	if not os.path.exists(ts) or os.path.getsize(ts) < 200_000:
		return dict(error="out.ts missing or empty")
	pcr_csv = os.path.join(cell, "pcr.csv")
	r = subprocess.run(["tsp", "-I", "file", ts, "-P", "continuity", "-P", "pcrverify", "--absolute",
						"--jitter-max", "13", "-P", "pcrextract", "--pcr", "--csv", "-o", pcr_csv, "-O", "drop"],
					   capture_output=True, text=True)
	log = r.stdout + r.stderr
	open(os.path.join(cell, "wire.txt"), "w").write(log)
	cc = len(re.findall(r"missing .* packets|discontinuity", log))
	m = re.search(r"([\d,]+) PCR OK, ([\d,]+) with jitter", log)
	jit = int(m.group(2).replace(",", "")) if m else None
	pcrs = []
	for line in open(pcr_csv):
		f = line.split(",")
		if len(f) > 5 and f[3] == "PCR":
			pcrs.append(int(f[5]))
	gaps = [(b - a) / 27000 for a, b in zip(pcrs, pcrs[1:])]
	over = sum(1 for g in gaps if g > 40)
	return dict(cc_errors=cc, pcr_jitter_over=jit, pcr_intervals=len(gaps), pcr_over_40ms=over,
				pcr_max_ms=round(max(gaps), 1) if gaps else None,
				p1p2_ok=cc == 0 and jit == 0 and over == 0)


def tstd(cell, scripts):
	ts = os.path.join(cell, "out.ts")
	if not os.path.exists(ts):
		return dict(error="out.ts missing")
	r = subprocess.run([sys.executable, os.path.join(scripts, "ts-tstd.py"), ts, "--skip", "8",
						"--json", os.path.join(cell, "tstd.json")], capture_output=True, text=True)
	open(os.path.join(cell, "tstd.txt"), "w").write(r.stdout + r.stderr)
	bad = [line.strip() for line in r.stdout.splitlines()
		   if re.search(r"(overflow pkts|underflows|overflows) +[1-9]", line)]
	return dict(exit=r.returncode, ok=r.returncode == 0, failing=bad[:6])


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("cell")
	ap.add_argument("--scripts", default=os.path.dirname(os.path.abspath(__file__)))
	a = ap.parse_args()
	t68 = load(a.scripts, "t68-netns-grade.py")
	ev, p = t68.events(a.cell)
	out = dict(cell=os.path.basename(a.cell.rstrip("/")), epoch_s=int(p["epoch"]), variant=p["variant"],
			   lat_ms=int(p["lat_ms"]), hold_ms=int(p["hold_ms"]), align_ms=int(p["align_ms"]),
			   window_s=round(ev["stop"] - ev["first-output"], 3),
			   first_output_after_recv_s=round(ev["first-output"] - ev["recv-start"], 3))
	out["clock"] = clock(a.cell)
	out["latency"] = latency(a.cell, a.scripts, out["clock"].get("offset_s", 0.0))
	out["receiver"] = t68.receiver(a.cell, None)
	out["groomer"] = t68.groomer(a.cell, ev["first-output"], ev["stop"], ev["recv-start"])
	win = out["groomer"].get("window", {})
	out["clean"] = bool(win) and all(v == 0 for v in win.values()) and out["receiver"]["lost"] == 0
	out["wire"] = wire(a.cell)
	out["tstd"] = tstd(a.cell, a.scripts)
	json.dump(out, open(os.path.join(a.cell, "grade.json"), "w"), indent=1)
	print(json.dumps(out))


if __name__ == "__main__":
	main()

#!/usr/bin/env python3
"""Grade one t71-cell.sh cell on the receiver: grade.json in the cell, one JSON line on stdout.

  - the path (criterion 1): the probe's lowest-delay round trip, and netem's counters as applied
    loss each way;
  - the clock (criterion 2): both hosts' chrony before and after; the bound is the larger of the two
    reads of |offset| + root distance (root delay / 2 + root dispersion) summed over the hosts; the
    probe's offset must agree with zero within its uncertainty;
  - delivery latency by t18-latency.py report over the origin's source tap and the egress tap,
    uncorrected (both clocks on UTC), 30 s settle;
  - P1/P2 on the saved egress: TSDuck continuity, pcrverify --absolute --jitter-max 13 (481 ns) and
    PCR intervals over 40 ms from pcrextract, as T18 and T70;
  - delivered programme: t28-content-lost.py from 8 s (video and the busiest audio), and on the
    byte-faithful lanes ts-passthrough-identity.py against the clip;
  - with --tstd, the buffer model: ts-tstd.py --skip 8, pass when it exits 0.

Usage: t71-grade.py <cell-dir> --lane srt|opaque|aware [--clip PATH] [--tstd] [--scripts DIR]
"""

import argparse
import json
import os
import re
import subprocess
import sys

TIME_SYNC = "169.254.169.123"


def blocks(path):
	"""The '== <label> ...' blocks of a clock file, by label."""
	try:
		text = open(path).read()
	except OSError:
		return {}
	out = {}
	for part in re.split(r"^== ", text, flags=re.M)[1:]:
		label = part.split(None, 1)[0]
		out[label] = part
	return out


def chrony(text):
	m = re.search(r"System time\s*:\s*([\d.]+) seconds (slow|fast)", text)
	d = re.search(r"Root delay\s*:\s*([\d.]+)", text)
	s = re.search(r"Root dispersion\s*:\s*([\d.]+)", text)
	ref = re.search(r"Reference ID\s*:\s*\S+ \(([^)]*)\)", text)
	leap = re.search(r"Leap status\s*:\s*(\S+)", text)
	if not (m and d and s):
		return None
	off = float(m.group(1))
	dist = float(d.group(1)) / 2 + float(s.group(1))
	return dict(offset_ms=round(off * 1e3, 4), root_distance_ms=round(dist * 1e3, 4),
				synced=bool(ref and ref.group(1) == TIME_SYNC and leap and leap.group(1) == "Normal"))


def probe(text):
	o = re.search(r"^offset_s (-?[\d.]+)$", text, re.M)
	u = re.search(r"^uncertainty_s (-?[\d.]+)$", text, re.M)
	r = re.search(r"^rtt_ms (-?[\d.]+)$", text, re.M)
	if not (o and u):
		return None
	return dict(offset_ms=round(float(o.group(1)) * 1e3, 2), uncertainty_ms=round(float(u.group(1)) * 1e3, 2),
				rtt_ms=float(r.group(1)) if r else None)


def clock(cell):
	far, org = blocks(os.path.join(cell, "clock-far.txt")), blocks(os.path.join(cell, "clock-origin.txt"))
	out, bounds, synced, agree, rtts = {}, [], True, True, []
	for when in ("before", "after"):
		f, o = chrony(far.get(when, "")), chrony(org.get(when, ""))
		p = probe(far.get(when, ""))
		out[when] = dict(far=f, origin=o, probe=p)
		if not (f and o):
			synced = False
			continue
		synced &= f["synced"] and o["synced"]
		bounds.append(f["offset_ms"] + f["root_distance_ms"] + o["offset_ms"] + o["root_distance_ms"])
		if p:
			agree &= abs(p["offset_ms"]) <= p["uncertainty_ms"]
			if p["rtt_ms"] is not None:
				rtts.append(p["rtt_ms"])
		else:
			agree = False
	bound = round(max(bounds), 3) if bounds else None
	out.update(bound_ms=bound, synced=synced, probe_agrees=agree, rtt_ms=min(rtts) if rtts else None,
			   ok=bool(bound is not None and synced and agree and bound <= 5))
	return out


def impairment(cell):
	try:
		kv = dict(re.findall(r"(\w+)=(\S+)", open(os.path.join(cell, "impair.txt")).read()))
	except OSError:
		return dict(error="no counters")
	out = dict(commanded_pct=float(kv.get("loss", "nan")), gro=kv.get("gro"))
	for d in ("in", "out"):
		try:
			s, x = int(kv[f"{d}_sent"]), int(kv[f"{d}_dropped"])
		except (KeyError, ValueError):
			out[d] = None
			continue
		out[d] = dict(sent=s, dropped=x, applied_pct=round(100 * x / (s + x), 3) if s + x else None)
	return out


def latency(cell, scripts):
	kv = os.path.join(cell, "lat.kv")
	r = subprocess.run([sys.executable, os.path.join(scripts, "t18-latency.py"), "report",
						os.path.join(cell, "source.csv"), os.path.join(cell, "egress.csv"),
						"--clock-offset", "0", "--settle", "30", "--kv", kv], capture_output=True, text=True)
	open(os.path.join(cell, "lat.txt"), "w").write(r.stdout + r.stderr)
	try:
		d = dict(line.strip().split("=", 1) for line in open(kv) if "=" in line)
	except OSError:
		return dict(error="no latency")
	out = {k: float(d[k]) for k in ("lat_min", "lat_median", "lat_p95", "lat_max", "trend_head",
									  "trend_tail", "window") if k in d}
	out["matched"], out["seen"], out["shift"] = int(d["matched"]), int(d["seen"]), int(d["shift"])
	return out


def wire(cell):
	ts = os.path.join(cell, "egress.ts")
	if not os.path.exists(ts) or os.path.getsize(ts) < 200_000:
		return dict(error="egress.ts missing or empty")
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
				pcr_max_ms=round(max(gaps), 1) if gaps else None, p1_ok=cc == 0 and over == 0)


def content(cell, scripts):
	js = os.path.join(cell, "content.json")
	r = subprocess.run([sys.executable, os.path.join(scripts, "t28-content-lost.py"), "--input",
						os.path.join(cell, "egress.ts"), "--from-s", "8", "--json", js], capture_output=True, text=True)
	open(os.path.join(cell, "content.txt"), "w").write(r.stdout + r.stderr)
	try:
		c = json.load(open(js))
	except (OSError, ValueError):
		return dict(error="no content grade")
	keep = ("content_lost_s", "holes", "largest_hole_s", "content_dup_s", "discontinuities", "audio_pid",
			"audio_lost_s", "audio_holes", "audio_largest_hole_s", "null_pct")
	out = {k: c[k] for k in keep if k in c}
	out["whole"] = c.get("content_lost_s", 1) == 0 and c.get("audio_lost_s", 0) == 0
	return out


def identity(cell, scripts, clip):
	js = os.path.join(cell, "identity.json")
	r = subprocess.run([sys.executable, os.path.join(scripts, "ts-passthrough-identity.py"), clip,
						os.path.join(cell, "egress.ts"), "--json", js], capture_output=True, text=True)
	open(os.path.join(cell, "identity.txt"), "w").write(r.stdout + r.stderr)
	try:
		d = json.load(open(js))
	except (OSError, ValueError):
		return dict(error="no identity grade")
	return {k: d[k] for k in ("matched", "foreign", "gaps", "gap_packets", "capture_packets")}


def tstd(cell, scripts):
	r = subprocess.run([sys.executable, os.path.join(scripts, "ts-tstd.py"), os.path.join(cell, "egress.ts"),
						"--skip", "8", "--json", os.path.join(cell, "tstd.json")], capture_output=True, text=True)
	open(os.path.join(cell, "tstd.txt"), "w").write(r.stdout + r.stderr)
	bad = [line.strip() for line in r.stdout.splitlines()
		   if re.search(r"(overflow pkts|underflows|overflows) +[1-9]", line)]
	return dict(exit=r.returncode, ok=r.returncode == 0, failing=bad[:6])


def receiver(cell):
	ev = {}
	try:
		for line in open(os.path.join(cell, "recv-events.log")):
			f = line.split()
			if len(f) >= 2:
				ev[f[1]] = (float(f[0]), f[2] if len(f) > 2 else None)
	except OSError:
		return dict(error="no events")
	t0 = ev.get("recv-start", (None,))[0]
	out = {}
	if t0 is not None and "recv-exit" in ev:
		out["ran_s"] = round(ev["recv-exit"][0] - t0, 2)
		out["exit"] = ev["recv-exit"][1]
	if t0 is not None and "tap-exit" in ev:
		out["tap_s"] = round(ev["tap-exit"][0] - t0, 2)
	return out


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("cell")
	ap.add_argument("--lane", required=True, choices=("srt", "opaque", "aware"))
	ap.add_argument("--clip", default=os.path.expanduser("~/contrib-10m.ts"))
	ap.add_argument("--tstd", action="store_true")
	ap.add_argument("--scripts", default=os.path.dirname(os.path.abspath(__file__)))
	a = ap.parse_args()
	out = dict(cell=os.path.basename(a.cell.rstrip("/")), lane=a.lane)
	out["impairment"] = impairment(a.cell)
	out["clock"] = clock(a.cell)
	out["receiver"] = receiver(a.cell)
	out["latency"] = latency(a.cell, a.scripts)
	out["wire"] = wire(a.cell)
	out["content"] = content(a.cell, a.scripts)
	if a.lane in ("srt", "opaque"):
		out["identity"] = identity(a.cell, a.scripts, a.clip)
	if a.tstd:
		out["tstd"] = tstd(a.cell, a.scripts)
	json.dump(out, open(os.path.join(a.cell, "grade.json"), "w"), indent=1)
	print(json.dumps(out))


if __name__ == "__main__":
	main()

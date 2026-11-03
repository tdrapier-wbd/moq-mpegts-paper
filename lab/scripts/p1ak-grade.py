#!/usr/bin/env python3
"""T79's grader: per arm and source, the first explicit and the first derived signal of the fault.

  p1ak-grade.py RUN_DIR...        (p1ak-telemetry.sh's output directories)

Sources, as lab/test-79 defines them: the receiver's log (b8.jsonl), CMCD v2 event mode and
TSDuck's TR 101 290 counters (both in collector.jsonl), and per-PID liveness (liveness.jsonl).
An explicit signal is a record that says something is wrong; a derived one is an absence longer
than three segment durations that a monitor would have to time itself. A control is graded for
false positives from 25 s after the receiver joins; a fault from its onset to its end plus 10 s.
"""
import json
import re
import sys

SEG_S = 2.0
DERIVED_S = 3 * SEG_S
WARM_S = 25.0
LATE_S = 10.0
B8_EXPLICIT = {"pl-fail", "seg-retry", "seg-lost", "msn-skip", "msn-regress", "discontinuity"}
CMCD_KV = re.compile(r'([a-z]+)(?:=("(?:[^"\\]|\\.)*"|\([^)]*\)|[^,]*))?(?:,|$)')
COUNTER = re.compile(r"counter,name=([a-z0-9_]+),severity=(\d)\S* value=(\d+)")


def cmcd(line):
	rec = {}
	for k, v in CMCD_KV.findall(line):
		rec[k] = v.strip('"') if v else True
	return rec


def gaps(times, start, label):
	"""(time a monitor would fire, description) for each absence longer than DERIVED_S."""
	out = []
	for a, b in zip(times, times[1:]):
		if b - a > DERIVED_S and a + DERIVED_S >= start:
			out.append((a + DERIVED_S, f"no {label} for {b - a:.1f} s"))
	return out


def load(d):
	ev = {}
	for line in open(f"{d}/events.log"):
		t, name = line.split(None, 1)
		ev[name.strip()] = float(t)
	meta = dict(kv.split("=", 1) for kv in open(f"{d}/meta.txt").readline().split())
	arm = meta["arm"]
	# The onset is the source's clock, not the step's log line, which follows the kill.
	if arm != "control":
		ev["fault-start"] = float(open(f"{d}/source-t0.txt").read()) + float(meta["at"])
		ev["fault-end"] = ev["fault-start"] + float(meta["stall" if arm in ("stall", "origin") else "dur"])
	signals = {s: {"explicit": [], "derived": []} for s in ("receiver", "cmcd", "tr101290", "liveness")}

	segs = []
	for line in open(f"{d}/b8.jsonl"):
		r = json.loads(line)
		if r["ev"] in B8_EXPLICIT:
			signals["receiver"]["explicit"].append((r["t"], r["ev"]))
		elif r["ev"] == "seg":
			segs.append(r["t"])
	signals["receiver"]["derived"] = gaps(segs, 0, "new segment")

	av, reports, prev = [], [], {}
	for line in open(f"{d}/collector.jsonl"):
		post = json.loads(line)
		if post["path"] == "/cmcd":
			for rec in map(cmcd, post["lines"]):
				t = int(rec.get("ts", 0)) / 1000.0
				e = rec.get("e")
				if e == "e":
					signals["cmcd"]["explicit"].append((t, f"e ec={rec.get('ec')}"))
				elif e == "ps" and rec.get("sta") in ("r", "f"):
					signals["cmcd"]["explicit"].append((t, f"ps sta={rec['sta']}"))
				elif e == "rr" and rec.get("rc") != "200":
					signals["cmcd"]["explicit"].append((t, f"rr rc={rec.get('rc')} ot={rec.get('ot')}"))
				if e == "rr" and rec.get("ot") == "av" and rec.get("rc") == "200":
					av.append(t)
		elif post["path"] == "/api/v2/write":
			reports.append(post["t"])
			for name, sev, value in (m.groups() for m in map(COUNTER.match, post["lines"]) if m):
				value = int(value)
				if int(sev) <= 3 and name in prev and value > prev[name]:
					signals["tr101290"]["explicit"].append((post["t"], f"{name} +{value - prev[name]}"))
				prev[name] = value
	signals["cmcd"]["derived"] = gaps(sorted(av), 0, "segment response")
	signals["tr101290"]["derived"] = gaps(reports, 0, "report")

	for line in open(f"{d}/liveness.jsonl"):
		r = json.loads(line)
		if r.get("event") == "alarm":
			what = r.get("reason") or f"pid {r.get('pid')}"
			signals["liveness"]["explicit"].append((r["wall"], f"alarm {what}"))
	return arm, ev, signals


def first(items, lo, hi):
	hits = sorted((t, s) for t, s in items if lo <= t <= hi)
	return hits[0] if hits else None


def main():
	for d in sys.argv[1:]:
		arm, ev, signals = load(d)
		print(f"== {d.rstrip('/').rsplit('/', 1)[-1]} (arm {arm})")
		if arm == "control":
			lo, hi = ev["receiver-start"] + WARM_S, ev["end"]
			for src, kinds in signals.items():
				fp = [(round(t - ev["receiver-start"], 1), s)
					  for k in ("explicit", "derived") for t, s in kinds[k] if lo <= t <= hi]
				print(f"  {src:9} false positives: {len(fp)} {fp[:4]}")
			continue
		onset, end = ev["fault-start"], ev["fault-end"]
		print(f"  fault {end - onset:.1f} s")
		for src, kinds in signals.items():
			cells = []
			for k in ("explicit", "derived"):
				hit = first(kinds[k], onset, end + LATE_S)
				cells.append(f"{k} {hit[0] - onset:+.2f} s {hit[1]}" if hit else f"{k} none")
			kinds_seen = sorted({s.split(" +")[0] for t, s in kinds["explicit"] if onset <= t <= end + LATE_S})
			print(f"  {src:9} {' | '.join(cells)}" + (f"  [all: {', '.join(kinds_seen)}]" if kinds_seen else ""))


if __name__ == "__main__":
	main()

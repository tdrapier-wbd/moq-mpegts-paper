#!/usr/bin/env python3
"""T74: bursts of loss defined in time, on T71's two netem qdiscs.

  t74-time-burst.py --seed N [--mean-ms 20] [--percent 1] [--dirs in,out] --log FILE
  t74-time-burst.py --summary FILE

Each direction alternates gaps and bursts of 100 % loss, both exponential: bursts of mean --mean-ms,
gaps of mean mean-ms * (100 / percent - 1), so --percent of time is lost. A direction's schedule is
drawn from its own generator seeded by (seed, direction) and anchored at start, so every cell run on
one seed meets the same loss timeline from its impairment onward. One `tc -batch -` process switches
the inward netem (the ifb's root) and the outward one (handle 40: under the prio root) between loss
0 % and loss 100 %; each switch is logged as JSON with its scheduled and written realtime. SIGTERM
sets both directions back to 0 % and exits. --summary reads a log: switches, lateness, the share of
the window lost each way and the mean burst.
"""
import argparse
import json
import random
import signal
import subprocess
import sys
import time

QDISC = {
	"in": "qdisc change dev {ifb} root handle 1: netem loss {pct}%",
	"out": "qdisc change dev {dev} parent 1:4 handle 40: netem loss {pct}%",
}


def schedule(seed, direction, mean_ms, percent, horizon_s):
	"""(offset_s, lossy) switch points from 0 to horizon_s, starting in a gap."""
	rng = random.Random(f"{seed}-{direction}")
	gap_ms = mean_ms * (100.0 / percent - 1.0)
	t, out = 0.0, []
	while t < horizon_s:
		t += rng.expovariate(1.0 / gap_ms) / 1000.0
		out.append((t, True))
		t += rng.expovariate(1.0 / mean_ms) / 1000.0
		out.append((t, False))
	return out


def run(a):
	dirs = [d for d in a.dirs.split(",") if d]
	tc = subprocess.Popen(["tc", "-force", "-batch", "-"], stdin=subprocess.PIPE, text=True, bufsize=1)
	log = open(a.log, "w", buffering=1)

	def put(direction, pct):
		tc.stdin.write(QDISC[direction].format(dev=a.dev, ifb=a.ifb, pct=pct) + "\n")
		tc.stdin.flush()

	def stop(*_):
		for d in dirs:
			put(d, 0)
		log.write(json.dumps({"end": time.time()}) + "\n")
		tc.stdin.close()
		tc.wait(timeout=5)
		sys.exit(0)

	signal.signal(signal.SIGTERM, stop)
	signal.signal(signal.SIGINT, stop)
	events = sorted((t, d, lossy) for d in dirs
					for t, lossy in schedule(a.seed, d, a.mean_ms, a.percent, a.seconds))
	m0, r0 = time.monotonic(), time.time()
	head = {"start": r0, "seed": a.seed, "mean_ms": a.mean_ms, "percent": a.percent, "dirs": dirs}
	log.write(json.dumps(head) + "\n")
	for t, d, lossy in events:
		deadline = m0 + t
		while True:
			left = deadline - time.monotonic()
			if left <= 0:
				break
			time.sleep(left - 0.001 if left > 0.002 else 0)
		put(d, 100 if lossy else 0)
		wrote = r0 + time.monotonic() - m0
		log.write(json.dumps({"d": d, "s": int(lossy), "t": round(r0 + t, 6), "w": round(wrote, 6)}) + "\n")
	stop()


def summary(path):
	start = end = None
	rows = []
	for line in open(path):
		e = json.loads(line)
		if "start" in e:
			start = e["start"]
		elif "end" in e:
			end = e["end"]
		else:
			rows.append(e)
	end = end or (rows[-1]["w"] if rows else start)
	out = {"window_s": round(end - start, 3), "switches": len(rows)}
	late = [abs(r["w"] - r["t"]) * 1000 for r in rows]
	out["late_ms_max"] = round(max(late), 3) if late else 0
	out["late_over_2ms"] = sum(1 for x in late if x > 2)
	for d in ("in", "out"):
		ev = [r for r in rows if r["d"] == d]
		if not ev:
			continue
		lost, bursts, on = 0.0, [], None
		for r in ev:
			if r["s"] and on is None:
				on = r["w"]
			elif not r["s"] and on is not None:
				bursts.append(r["w"] - on)
				on = None
		if on is not None:
			bursts.append(end - on)
		lost = sum(bursts)
		out[d] = {"lost_pct": round(100 * lost / (end - start), 3), "bursts": len(bursts),
				  "mean_burst_ms": round(1000 * lost / len(bursts), 2) if bursts else 0}
	print(json.dumps(out))


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("--seed", type=int)
	ap.add_argument("--mean-ms", type=float, default=20.0)
	ap.add_argument("--percent", type=float, default=1.0)
	ap.add_argument("--dirs", default="in,out")
	ap.add_argument("--seconds", type=float, default=900.0, help="horizon of the schedule")
	ap.add_argument("--dev", default="ens5")
	ap.add_argument("--ifb", default="ifb71")
	ap.add_argument("--log")
	ap.add_argument("--summary", metavar="LOG")
	a = ap.parse_args()
	if a.summary:
		summary(a.summary)
	elif a.seed is None or not a.log:
		ap.error("--seed and --log are required to run")
	else:
		run(a)


if __name__ == "__main__":
	main()

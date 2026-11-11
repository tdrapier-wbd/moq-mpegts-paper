#!/usr/bin/env python3
"""Grade one leg of a t84-moq-cell.sh cell: grade.json in the leg's directory, and one JSON line.

  - content at the export's output (out.ts) by t28-content-lost.py from 8 s, and delivery latency
    by t18-latency.py report over the source and egress taps (one host, clock offset 0, 8 s settle):
    t68-netns-grade.py's instruments, imported from it; conservation against the arm's control is
    t84-moq-drive.py's;
  - the window and the shape from events.log, with their UTC edges, over which the relay's own
    counters are read;
  - the subscriber: whether it was gone before the stop, its log's warnings by message, and its
    namespace's UDP receive errors.

Usage: t84-moq-grade.py <leg-dir> [--scripts DIR]
"""

import argparse
import importlib.util
import json
import os
import re
import time
from collections import Counter

ANSI = re.compile(r"\x1b\[[0-9;]*m")
MESSAGE = re.compile(r"\b(WARN|ERROR)\b\s+(?:[\w:]+:\s+)?(.*?)(?:\s+\w+=|$)")


def t68(scripts):
	spec = importlib.util.spec_from_file_location("t68grade", os.path.join(scripts, "t68-netns-grade.py"))
	m = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(m)
	return m


def utc(t):
	return time.strftime("%H:%M:%S", time.gmtime(t))


def subscriber(leg):
	try:
		lines = open(os.path.join(leg, "sub.log"), errors="replace").read().splitlines()
	except OSError:
		return dict(error="no sub.log")
	levels, kinds, last_error = Counter(), Counter(), None
	for line in lines:
		s = ANSI.sub("", line)
		m = MESSAGE.search(s)
		if m:
			levels[m.group(1)] += 1
			kinds[f"{m.group(1)} {m.group(2)[:80]}"] += 1
		if s.startswith("Error") or (m and m.group(1) == "ERROR"):
			last_error = s[-200:]
	return dict(warn=levels["WARN"], error=levels["ERROR"], last_error=last_error,
				messages=dict(kinds.most_common(6)))


def udp_errors(leg):
	"""The leg's namespace's UDP receive errors over the cell: a socket's drops, not the path's."""
	snap = []
	for name in ("udp-before.txt", "udp.txt"):
		try:
			head, vals = [line.split()[1:] for line in open(os.path.join(leg, name))][:2]
		except (OSError, ValueError):
			return None
		snap.append(dict(zip(head, map(int, vals))))
	return {k: snap[1][k] - snap[0][k] for k in ("InErrors", "RcvbufErrors") if k in snap[0]}


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("leg")
	ap.add_argument("--scripts", default=os.path.dirname(os.path.abspath(__file__)))
	a = ap.parse_args()
	m = t68(a.scripts)
	ev, p = m.events(a.leg)
	t0, t_stop, t_shape = ev["first-output"], ev["stop"], ev.get("impair-start")
	out = dict(cell=os.path.basename(a.leg.rstrip("/")), shape=p["shape"], relay=p["relay"], lane=p["lane"],
			delay_ms=int(p["delay_ms"]), ver=p["ver"], path_delay_ms=int(p["path_delay_ms"]),
			qlog=p.get("qlog") == "1", window_s=round(t_stop - t0, 3),
			first_output_after_legs_s=round(t0 - ev["legs-start"], 3),
			day=time.strftime("%Y-%m-%d", time.gmtime(t0)), window_utc=[utc(t0), utc(t_stop)])
	if t_shape is not None:
		out["shape_at_s"] = round(t_shape - t0, 3)
		out["shape_for_s"] = round(ev["impair-end"] - t_shape, 3)
		out["shape_utc"] = [utc(t_shape), utc(ev["impair-end"])]
	out["ended_early"] = os.path.exists(os.path.join(a.leg, "ended-early"))
	out["latency"] = m.latency(a.leg, a.scripts)
	out["content"] = m.content(a.leg, "out", a.scripts)
	out["subscriber"] = subscriber(a.leg)
	out["udp_errors"] = udp_errors(a.leg)
	json.dump(out, open(os.path.join(a.leg, "grade.json"), "w"), indent=1)
	print(json.dumps(out))


if __name__ == "__main__":
	main()

#!/usr/bin/env python3
"""Grade t11-imquic-fetch.sh: per group, whether each client holds the group's final object.

  t11-imquic-grade.py FIXTURE RUN_DIR [RUN_DIR ...]

M is read from m.ts with t11-loss-map.py's alignment; I and F from imquic-moq-sub's object log
(i.log, f.log). A group's final object is the importer's last object of it in the fixture.
"""
import importlib.util
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("lossmap", os.path.join(here, "t11-loss-map.py"))
lm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lm)

OBJ = re.compile(r"Incoming object: .*?group=(\d+), subgroup=\d+.*?, id=(\d+),.*?payload=(\d+) bytes"
				 r".*?status=(\w+), eos=(\d)")
STITCH = re.compile(r"no fill to stitch a mid-group stream onto sequence=(\d+)")


def objects(path):
	got = {}
	if not os.path.exists(path):
		return got
	for line in open(path, errors="replace"):
		m = OBJ.search(line)
		if m:
			g, o, size, status, eos = m.groups()
			got[(int(g), int(o))] = (int(size), status, int(eos))
	return got


def split_groups(path):
	"""Groups delivered on more than one stream: an object ends a stream and another object follows.

	An empty object is only the stream's end, and does not count as one that follows."""
	seq = {}
	if os.path.exists(path):
		for line in open(path, errors="replace"):
			m = OBJ.search(line)
			if m:
				g, o, size, _, eos = m.groups()
				seq.setdefault(int(g), []).append((int(o), int(size), int(eos)))
	return sorted(g for g, objs in seq.items()
				  if any(e == 1 and (n[0], n[1]) != (0, 0) for (_, _, e), n in zip(objs, objs[1:])))


def main():
	fx = lm.packets(sys.argv[1])
	pcr_pid, video = lm.layout(fx)
	where, objs = lm.assign(fx, pcr_pid, video)
	full = sorted(g for g in objs if g + 1 in objs)  # groups the fixture closes
	for run in sys.argv[2:]:
		m = lm.map_capture(fx, where, objs, os.path.join(run, "m.ts"))
		m_lost = {x["group"] for x in m["missing"] if x["last_object"]}
		join = m.get("join", (None,))[0]
		i, f = objects(os.path.join(run, "i.log")), objects(os.path.join(run, "f.log"))
		i_groups = {g for g, _ in i}
		print(f"== {os.path.basename(run)}: M join group {join}, M lacks the final object of "
			  f"{sorted(m_lost)}; I from group {min(i_groups) if i_groups else None}; "
			  f"F {len({g for g, _ in f})} groups")
		print("  group  M     I     I-eos  F     final-size")
		for g in full:
			last = (g, objs[g] - 1)
			mi = "lost" if g in m_lost else ("-" if join is None or g < join else "ok")
			ii = ("ok" if last in i else "lost") if i_groups and g >= min(i_groups) else "-"
			ie = str(i[last][2]) if last in i else "-"
			ff = "ok" if last in f else "lost"
			size = (i.get(last) or f.get(last) or ("?",))[0]
			print(f"  {g:5d}  {mi:5s} {ii:5s} {ie:6s} {ff:5s} {size}")
		lost_m = [g for g in full if g in m_lost]
		print(f"  M lost {len(lost_m)}; of those I holds {sum(1 for g in lost_m if (g, objs[g] - 1) in i)}, "
			  f"F holds {sum(1 for g in lost_m if (g, objs[g] - 1) in f)}; "
			  f"M-lost groups whose final object reached I with eos=1: "
			  f"{sum(1 for g in lost_m if i.get((g, objs[g] - 1), (0, 0, 0))[2] == 1)}; "
			  f"groups with eos=1 at I that M kept: "
			  f"{[g for g in full if g not in m_lost and i.get((g, objs[g] - 1), (0, 0, 0))[2] == 1]}")
		mlog = os.path.join(run, "m.log")
		warned = (sorted(int(s) for s in STITCH.findall(open(mlog, errors="replace").read()))
				  if os.path.exists(mlog) else [])
		print(f"  groups I received on two streams: {split_groups(os.path.join(run, 'i.log'))}; "
			  f"M's stitch warnings: {warned}")
		unended = [g for g in full if i_groups and g >= min(i_groups) and not any(
			e == 1 for (gg, _), (_, _, e) in i.items() if gg == g)]
		print(f"  groups from I's join whose stream I never saw end: {unended}; "
			  f"F lacks the final object of: {[g for g in full if (g, objs[g] - 1) not in f]}")


if __name__ == "__main__":
	main()

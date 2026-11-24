#!/usr/bin/env python3
"""How long t79-epochseg.py withholds its playlist across a step in the source's clock.

Feeds a clip with one unflagged clock step (the interop runner's `make-fixture.sh --step`, with
its manifest beside it) through the segmenter on a simulated clock, each datagram arriving when
the clip's mux rate delivers it, and reports, per --step-window, when the playlist is withdrawn and
published again after the step, and from what content. Run twice: the step read as the PTS going
back, and, with the clock set so that it crosses the 33-bit wrap's midpoint, as the PCR and PTS
running ahead (as the source's backward changeover read live).

  t79-step-test.py CLIP [--windows 0,1,2] [--rate BITS_PER_S]   exit 0 when every case holds
"""
import argparse
import importlib.util
import json
import os
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("epochseg", os.path.join(HERE, "t79-epochseg.py"))
seg_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seg_mod)

WRAP = 1 << 33


def first_pts(data):
	for i in range(0, len(data), 188):
		p = data[i:i + 188]
		if p[1] & 0x40 and (p[3] >> 4) & 1:
			off = 4 + (1 + p[4] if (p[3] >> 4) & 2 else 0)
			if off + 14 <= 188 and (pts := seg_mod.pes_pts(p, off)) is not None:
				return pts
	raise SystemExit("no PTS in the clip")


def run(data, rate, start, step_window, step_at):
	clock = {"now": start}
	seg_mod.time = types.SimpleNamespace(time=lambda: clock["now"])
	events = []
	real_print = print

	def capture(*args, file=None, flush=False):
		if file is sys.stderr:
			t, what, *rest = " ".join(str(a) for a in args).split(" ", 2)
			events.append((float(t) - start, what, rest[0] if rest else ""))
		else:
			real_print(*args)

	seg_mod.print = capture
	with tempfile.TemporaryDirectory() as out:
		s = seg_mod.Segmenter(out, 2.0, 6, 3, 4, pdt=True, step_window=step_window)
		per = 188 * 8 / rate
		for i in range(0, len(data), 1316):
			clock["now"] = start + (i // 188) * per
			s.datagram(data[i:i + 1316], clock["now"])
	resets = [e for e in events if e[1] == "reset" and e[0] >= step_at - 0.5]
	after = [e for e in events if e[1] == "playlist" and resets and e[0] > resets[0][0]]
	segs = [e for e in events if e[1] == "seg" and resets and e[0] > resets[0][0]]
	return resets, after, segs


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("clip")
	ap.add_argument("--windows", default="0,1,2")
	ap.add_argument("--rate", type=float, default=2_000_000)
	args = ap.parse_args()
	data = open(args.clip, "rb").read()
	manifest = json.load(open(os.path.splitext(args.clip)[0] + ".json"))
	step_at = manifest["step_packet"] * 188 * 8 / args.rate
	p0 = first_pts(data)
	pre = (p0 + round(step_at * 90000)) % WRAP
	# "back": the wall clock reads the clip's own start. "ahead": the pre-step PTS lies 1000 s
	# inside the far side of the wrap's midpoint, so the backward step unwraps as a jump forward.
	starts = {"back": p0 / 90000 + 1e9 // (WRAP / 90000) * (WRAP / 90000),
			"ahead": (pre + WRAP // 2 - 1000 * 90000) / 90000 - step_at + 1e9 // (WRAP / 90000) * (WRAP / 90000)}
	fail = 0
	print(f"step at {step_at:.2f} s of {len(data) * 8 / args.rate:.1f} s")
	for name, start in starts.items():
		for w in (int(x) for x in args.windows.split(",")):
			resets, after, segs = run(data, args.rate, start, w, step_at)
			why = "; ".join(r[2] for r in resets)
			if not after:
				print(f"{name:5} --step-window {w}: reset ({why}); no playlist by the clip's end")
				fail |= w != 0
				continue
			back = after[0][0] - step_at
			first = segs[0][2].split()[1] if segs else "?"
			print(f"{name:5} --step-window {w}: reset ({why}); playlist again {back:.2f} s after the step, "
				f"from {first}, {len(segs)} segments to the end")
			if w:
				fail |= back > 2 * w + 2.5
	return fail


if __name__ == "__main__":
	sys.exit(main())

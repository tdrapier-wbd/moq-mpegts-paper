#!/usr/bin/env python3
"""T30 timeline oracle: flag programme time travel that continuity and PCR checks cannot see.

A receiver that switches between two copies of a feed whose timelines disagree emits a
transport stream with clean continuity counters and, once groomed, a clean PCR, yet the
programme jumps back and forth. This grader walks the video PES timestamps in arrival order
and reports every step outside +-THRESHOLD seconds:

  backward steps  time travel (the receiver shows content it already showed): the silent error
  forward steps   content skipped; a hole the content-lost grader also scores

Picture reordering moves PTS back by a few frames at most, far inside the threshold. A clip
loop wraps the timeline back by the clip's length; pass --loop-s to exclude steps within
--loop-tol-s of it.

Usage:
    t30-timeline.py --input groomed.ts [--threshold-s 2] [--loop-s 578.88] [--json out.json]
"""

import argparse
import importlib.util
import json
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
	"t28_content_lost", Path(__file__).with_name("t28-content-lost.py")
)
_cl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cl)


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--input", required=True, type=Path)
	ap.add_argument("--pid", type=lambda s: int(s, 0))
	ap.add_argument("--threshold-s", type=float, default=2.0)
	ap.add_argument("--loop-s", type=float, default=0.0)
	ap.add_argument("--loop-tol-s", type=float, default=1.0)
	ap.add_argument("--json", type=Path)
	args = ap.parse_args()

	scanned = _cl.scan(_cl.read_ts(args.input), args.pid)
	t = _cl.unwrap(scanned["stamps"])
	back, fwd = [], []
	for i in range(1, len(t)):
		step = t[i] - t[i - 1]
		if args.loop_s and abs(abs(step) - args.loop_s) <= args.loop_tol_s:
			continue
		if step < -args.threshold_s:
			back.append((round(t[i - 1] - t[0], 3), round(step, 3)))
		elif step > args.threshold_s:
			fwd.append((round(t[i - 1] - t[0], 3), round(step, 3)))

	out = {
		"input": str(args.input),
		"pid": scanned["pid"],
		"pictures": len(t),
		"span_s": round(t[-1] - t[0], 3) if t else 0.0,
		"threshold_s": args.threshold_s,
		"back_steps": len(back),
		"back_max_s": round(max((-s for _, s in back), default=0.0), 3),
		"fwd_steps": len(fwd),
		"fwd_max_s": round(max((s for _, s in fwd), default=0.0), 3),
		"silent_time_travel": bool(back),
		"events": [{"at_media_s": a, "step_s": s} for a, s in sorted(back + fwd)],
	}
	if args.json:
		args.json.write_text(json.dumps(out, indent=2) + "\n")
	print(
		f"TIMELINE pid={out['pid']} pictures={out['pictures']} span_s={out['span_s']} "
		f"back_steps={out['back_steps']} back_max_s={out['back_max_s']} "
		f"fwd_steps={out['fwd_steps']} fwd_max_s={out['fwd_max_s']} "
		f"silent_time_travel={'yes' if back else 'no'}"
	)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())

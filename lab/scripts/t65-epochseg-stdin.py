#!/usr/bin/env python3
"""Run `t61-epochseg.py`'s segmenter on a transport stream piped in, for one host without multicast.

    tsp --realtime --max-flushed-packets 7 -I file SRC -P regulate --pcr-synchronous -O file - |
        t65-epochseg-stdin.py DIR [--pdt] [--duration 2] [--window 6] [--extra 3] [--target 4]

The `Segmenter` class is imported unchanged; only its input differs from the origins'. Arrival
times are the pipe's, so the writer must flush in small batches: the segmenter resets on a 0.5 s
gap, and `tsp` without `--max-flushed-packets` writes in bursts longer than that.
"""

import argparse
import importlib.util
import os
import sys
import time

_spec = importlib.util.spec_from_file_location(
	"epochseg", os.path.join(os.path.dirname(os.path.abspath(__file__)), "t61-epochseg.py"))
es = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(es)


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("dir")
	ap.add_argument("--duration", type=float, default=2.0)
	ap.add_argument("--window", type=int, default=6)
	ap.add_argument("--extra", type=int, default=3)
	ap.add_argument("--target", type=int, default=4)
	ap.add_argument("--pdt", action="store_true")
	ap.add_argument("--pdt-settle", type=float, default=2.0)
	args = ap.parse_args()
	os.makedirs(args.dir, exist_ok=True)
	seg = es.Segmenter(args.dir, args.duration, args.window, args.extra, args.target, args.pdt, args.pdt_settle)
	inp, held = sys.stdin.buffer, b""
	while data := inp.read1(65536):
		data = held + data
		cut = len(data) - len(data) % 188
		held = data[cut:]
		if cut:
			seg.datagram(data[:cut], time.time())


if __name__ == "__main__":
	main()

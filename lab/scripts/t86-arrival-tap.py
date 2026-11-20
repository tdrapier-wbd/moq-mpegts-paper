#!/usr/bin/env python3
"""T86: stand in for `ts-pcr-timing.py --live` in `t11d-arm.sh`, recording arrivals instead.

    PCRT=lab/scripts/t86-arrival-tap.py bash lab/scripts/t11d-arm.sh <out> <arm>

Release timing graded against the stream's own PCR is meaningless across a PCR discontinuity, which
is what P2-s puts in. This takes the rig's arguments, ignores all but `--report-json <path>`, and
runs `t67p-tap.py` on stdin at one-second intervals, writing its CSV to `<path>` with `.csv` in
place of `.json`: packets, continuity errors, the longest gap between two reads, PCR steps.
"""

import os
import sys

out = "arrivals.json"
args = sys.argv[1:]
if "--report-json" in args:
    out = args[args.index("--report-json") + 1]
tap = os.path.join(os.path.dirname(os.path.abspath(__file__)), "t67p-tap.py")
os.execvp(sys.executable, [sys.executable, tap, os.path.splitext(out)[0] + ".csv", "--interval", "1"])

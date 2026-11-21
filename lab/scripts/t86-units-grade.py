#!/usr/bin/env python3
"""T86 P2-w: each output's units against its source's, on T83 Part C's unit parser.

    t86-units-grade.py <source.ts> <out.ts>... [--rate 25000000]

Units (t83c-shadow.py units) are taken in the source's order. Each output is graded from its
first source unit other than a SCTE-35 section (its join) to the source's end, each PID from its own
first unit delivered: present (key and digest), altered (key, other
digest), missing, and extra (in the output, not the source). A clock step is where a video unit's
PTS falls more than 1,000 s below the highest before it; missing video units are placed against it
in seconds, at the source's video unit rate, and every unit missing or altered is counted near the
step (within --near s of it, placed at the video unit before it) or away. One row per output.
"""

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STEP_TICKS = 1000 * 90000


def units(path):
    with open(path, "rb") as f:
        out = subprocess.run(
            [sys.executable, os.path.join(HERE, "t83c-shadow.py"), "units"],
            stdin=f, capture_output=True, text=True, check=True,
        ).stdout
    rows = []
    for line in out.splitlines():
        p = line.split()
        if p and p[0] == "u":
            rows.append((int(p[1]), p[2], p[4], p[5], len(p) > 6))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("outputs", nargs="+")
    ap.add_argument("--rate", type=float, default=25e6)
    ap.add_argument("--near", type=float, default=5.0)
    ap.add_argument("--json")
    a = ap.parse_args()

    src = units(a.source)
    duration = os.path.getsize(a.source) * 8 / a.rate
    video = [i for i, u in enumerate(src) if u[3] == "video"]
    vrate = len(video) / duration
    vindex = {i: n for n, i in enumerate(video)}
    pos, n = [], 0
    for i in range(len(src)):
        n = vindex.get(i, n)
        pos.append(n)
    step, top = None, None
    for i in video:
        pts = int(src[i][1])
        if top is not None and pts < top - STEP_TICKS:
            step = vindex[i]
            break
        top = pts if top is None else max(top, pts)
    print(f"source {len(src)} units, {len(video)} video at {vrate:.2f}/s over {duration:.1f} s; "
          f"step at {'%.2f s' % (step / vrate) if step is not None else 'none'}")
    print("output | join s | present | altered | missing (video) | extra | longest video run s (at s from step)"
          " | lost near / away")

    detail = {}
    for path in a.outputs:
        out = units(path)
        got = {}
        for u in out:
            got.setdefault((u[0], u[1]), set()).add(u[2])
        skeys = {(u[0], u[1]) for u in src}
        # a section is keyed by its CRC, which a repeated section shares, so it places no join
        first = next((i for i, u in enumerate(src) if (u[0], u[1]) in got and u[3] != "scte35"), None)
        if first is None:
            print(f"{path} | no source unit")
            continue
        # each PID from its own first unit delivered: a PES begun before the first byte cannot be
        pid_join = {}
        for i in range(first, len(src)):
            u = src[i]
            if u[0] not in pid_join and (u[0], u[1]) in got:
                pid_join[u[0]] = i
        present = altered = near = away = 0
        missing, mvideo = [], []
        for i in range(first, len(src)):
            u = src[i]
            if i < pid_join.get(u[0], len(src)):
                continue
            d = got.get((u[0], u[1]))
            if d is not None and u[2] in d:
                present += 1
                continue
            if d is None:
                missing.append(i)
                if u[3] == "video":
                    mvideo.append(vindex[i])
            else:
                altered += 1
            if step is not None and abs(pos[i] - step) / vrate <= a.near:
                near += 1
            else:
                away += 1
        extra = sum(1 for u in out if (u[0], u[1]) not in skeys)
        run, best, start, bstart = 0, 0, None, None
        prev = None
        for n in mvideo:
            run = run + 1 if prev is not None and n == prev + 1 else 1
            start = n if run == 1 else start
            if run > best:
                best, bstart = run, start
            prev = n
        join_v = next((vindex[i] for i in range(first, len(src)) if i in vindex), 0)
        at = ""
        if best and step is not None:
            at = f" ({(bstart - step) / vrate:+.2f})"
        print(f"{path} | {join_v / vrate:.2f} | {present} | {altered} | {len(missing)} ({len(mvideo)}) | "
              f"{extra} | {best / vrate:.2f}{at} | {near} / {away}")
        detail[path] = {
            "join_s": join_v / vrate, "present": present, "altered": altered,
            "missing": len(missing), "missing_video": len(mvideo), "extra": extra,
            "lost_near_step": near, "lost_away": away,
            "longest_video_run_s": best / vrate,
            "run_from_step_s": (bstart - step) / vrate if best and step is not None else None,
        }
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"step_s": step / vrate if step is not None else None, "outputs": detail}, f, indent=1)


if __name__ == "__main__":
    main()

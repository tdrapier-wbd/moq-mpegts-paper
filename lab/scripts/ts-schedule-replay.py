#!/usr/bin/env python3
"""Replay the fixed-delay TS export's slot schedule on one clip's video, offline.

    ts-schedule-replay.py <source.ts> --rate BPS --window S[,S...]
                          [--reserve TICKS] [--period TICKS] [--eb BYTES]
                          [--check <egress.ts>]

The fixed-delay export (quest/m1/tstd/, the constant-rate schedule) lays its
multiplex on 25 ms slots. Each access unit has to be out by the slot of its
decode time and may leave at most `window` slots (the export's --delay) before
it. Units leave in decode order. This replays that rule on the video PID's
access units, read from the source with ffprobe, and reports for each window
whether the stream fits and, if not, how much of its decode timeline is out
when it stops, which is comparable with how far an export capture got. Two send
policies are replayed:

    alap    as late as the rate allows, what the export does: each slot carries
            the fewest packets that keep every queued unit on time, with
            rate // (188 * 8 * 40) - 1 packets of room assumed in each later
            slot. A unit is queued once it is within the window of the slot
            being laid. Overrun is the export's own condition (needed >= the
            slot's allowance, the clock packet included).
    edf     as early as the window and the decoder buffer allow: units in
            decode order, each slot filled up to its allowance while the
            elementary-stream buffer (--eb bytes, the T-STD's EB) has room.
            A unit is late if any of it is unsent at its decode slot.

Each policy is replayed on two decode timelines: the source's own DTS, and the
DTS the export authors from PTS alone (a port of its DecodeClock: the PTS in
display order, reserve // period pictures late). --reserve is the catalog
`jitter` in 90 kHz ticks, which the export logs as "raising the video DTS
reserve"; --period is the picture period the SPS declares, in ticks.
--check compares the authored PTS - DTS with an export capture of the same
clip, frame by frame after its first 30, as a check on the port.

Video only: audio, tables and the PCR packet's own budget beyond one packet a
slot are not modelled, so a pass here is necessary for the full multiplex, not
sufficient. EB occupancy is counted in 184-byte packet payloads, which
overstates it slightly.
"""

import argparse
import bisect
import subprocess
import sys

SLOT = 0.025
PACKET = 188 * 8 * 40
WRAP = 1 << 33


def read_units(path):
    """(pts, dts, size, key) per video PES, in file order, ticks unwrapped."""
    out = subprocess.run(
        ["ffprobe", "-v", "quiet", "-select_streams", "v:0", "-show_entries",
         "packet=pts,dts,size,flags", "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True).stdout
    units, last, offset = [], None, 0
    for line in out.splitlines():
        f = line.split(",")
        if len(f) < 4 or not f[0] or not f[1]:
            continue
        pts, dts = int(f[0]), int(f[1])
        if last is not None and dts + offset < last - WRAP // 2:
            offset += WRAP
        pts, dts = pts + offset, dts + offset
        last = dts
        units.append((pts, dts, int(f[2]), "K" in f[3]))
    return units


def packets(size, has_dts):
    return -(-(size + (19 if has_dts else 14)) // 184)


def author(pts_list, reserve, declared):
    """The export's DecodeClock::author over decode-order PTS."""
    window, last, previous, period, out = [], None, None, None, []
    for pts in pts_list:
        if previous is not None and pts != previous:
            step = abs(pts - previous)
            period = step if period is None else min(period, step)
        previous = pts
        per = declared or period
        if per:
            depth = reserve // per
            bisect.insort_left(window, pts)
            held = len(window)
            if held > depth:
                earliest = window[held - depth - 1]
                del window[:held - depth]
            else:
                earliest = max(window[0] - (depth + 1 - held) * per, 0)
            dts = max(earliest - reserve % per, 0)
        else:
            dts = max(pts - reserve, 0)
        if last is not None and dts <= last:
            dts = last + 1
        last = dts
        out.append(dts)
    return out


def due_slots(seq, wslots):
    t0 = seq[0][0]
    due = [int((d - t0) / 90000 / SLOT) + wslots for d, _ in seq]
    for j in range(1, len(due)):
        k = j - 1
        while k >= 0 and due[k] > due[j]:
            due[k] = due[j]
            k -= 1
    return due


def allowance(rate):
    credit = 0
    while True:
        credit += rate
        allowed = max(credit // PACKET, 1)
        credit -= min(credit // PACKET, allowed) * PACKET
        yield allowed


def alap(seq, rate, wslots):
    due, rem = due_slots(seq, wslots), [p for _, p in seq]
    room_per = rate // PACKET - 1
    head, grant = 0, allowance(rate)
    for index in range(due[-1] + 1):
        allowed = next(grant)
        queued = needed = 0
        j = head
        while j < len(due) and due[j] <= index + wslots:
            queued += rem[j]
            needed = max(needed, queued - max(due[j] - index, 0) * room_per)
            j += 1
        if needed >= allowed:
            return f"stops with {(index - wslots) * SLOT:.2f} s of DTS out (needs {needed} > {allowed})"
        left = needed
        while head < len(due) and left > 0:
            take = min(rem[head], left)
            rem[head] -= take
            left -= take
            if rem[head]:
                break
            head += 1
    return "fits"


def edf(seq, rate, wslots, eb):
    due, rem = due_slots(seq, wslots), [p for _, p in seq]
    head = decoded = occupancy = peak = 0
    grant = allowance(rate)
    for index in range(due[-1] + 1):
        allowed = next(grant)
        while decoded < len(due) and due[decoded] < index:
            if rem[decoded]:
                return f"late at {(index - wslots) * SLOT:.2f} s of DTS"
            occupancy -= seq[decoded][1] * 184
            decoded += 1
        left = allowed - 1
        while head < len(due) and left > 0 and due[head] - wslots <= index:
            take = min(rem[head], left, (eb - occupancy) // 184)
            if take <= 0:
                break
            rem[head] -= take
            left -= take
            occupancy += take * 184
            if rem[head]:
                break
            head += 1
        peak = max(peak, occupancy)
    return f"fits (EB peak {peak / eb:.0%})"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("--rate", type=int, required=True, help="multiplex rate, b/s")
    ap.add_argument("--window", required=True, help="comma-separated --delay values, seconds")
    ap.add_argument("--reserve", type=int, default=36000, help="catalog jitter, 90 kHz ticks")
    ap.add_argument("--period", type=int, default=0, help="SPS picture period, ticks (0: smallest PTS step)")
    ap.add_argument("--eb", type=int, help="EB size in bytes for the edf policy")
    ap.add_argument("--check", help="an export capture of this clip, to check the DTS port")
    args = ap.parse_args()

    units = read_units(args.source)
    start = next((i for i, u in enumerate(units) if u[3]), 0)
    units = units[start:]
    pts = [u[0] for u in units]
    authored = author(pts, args.reserve, args.period or None)
    timelines = {
        "source DTS": [(u[1], packets(u[2], u[0] != u[1])) for u in units],
        "authored DTS": [(d, packets(u[2], u[0] != d)) for u, d in zip(units, authored)],
    }

    if args.check:
        ours = {p % WRAP: p - d for p, d in zip(pts, authored)}
        hits = total = 0
        for p, d, _, _ in read_units(args.check)[30:]:
            for k in (p, p + 1, p - 1):
                if k % WRAP in ours:
                    total += 1
                    hits += ours[k % WRAP] == p - d
                    break
        print(f"DTS port: PTS - DTS reproduced on {hits} of {total} captured frames")

    print(f"{len(units)} video units from the first keyframe, rate {args.rate} b/s")
    for w in (float(x) for x in args.window.split(",")):
        wslots = round(w / SLOT)
        for name, seq in timelines.items():
            row = f"window {w:5.2f} s  {name:12s}  alap: {alap(seq, args.rate, wslots)}"
            if args.eb:
                row += f"  |  edf: {edf(seq, args.rate, wslots, args.eb)}"
            print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())

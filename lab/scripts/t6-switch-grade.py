#!/usr/bin/env python3
"""Grade an exporter's capture across source switches (T6, P1-p).

usage: t6-switch-grade.py <capture.ts> [sizes.csv column]   (column: 2 for sub1, 3 for sub2)

A switch is a PMT version change, which is how `export ts --stitch` marks one. For each it reports
the rig second it was written in (from sizes.csv, the first second whose size covers it), the
PMT version either side, the PIDs carrying the discontinuity indicator from 0.5 s of output before
it to 2 s after against the PIDs present in the second after it, and the video decode-time gap
across it: `lost_s` is the source time absent (the step less one frame), `repeat_s` the source time
written twice when it steps back. Outside switches it counts continuity errors (a counter step on a
packet without the indicator), video gaps over two frames, which is where a seamless resume would
lose programme without marking it, and any other discontinuity indicators, by PID and second.
"""
import json
import statistics
import sys

PKT = 188
VIDEO_TYPES = {0x01, 0x02, 0x1B, 0x24, 0x27}
WRAP = 1 << 33


def pts_of(p, off):
    """The decode timestamp: the DTS where the PES carries one, else the PTS."""
    if p[off:off + 3] != b'\x00\x00\x01' or len(p) < off + 19 or not p[off + 7] & 0x80:
        return None
    b = p[off + 14:off + 19] if p[off + 7] & 0x40 else p[off + 9:off + 14]
    return ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1


def step(a, b):
    d = (b - a) % WRAP
    return d - WRAP if d > WRAP // 2 else d


def main():
    path = sys.argv[1]
    sizes = []
    if len(sys.argv) > 3:
        col = int(sys.argv[3]) - 1
        with open(sys.argv[2]) as f:
            next(f)
            sizes = [(int(r.split(',')[0]), int(r.split(',')[col])) for r in f if r.strip()]
    data = open(path, 'rb').read()
    n = len(data) // PKT
    pmt_pid, video_pid, pmt_ver = None, None, None
    cc, flagged_at, pmt_changes, cc_errors, vpts = {}, [], [], [], []
    seen_after = {}
    for i in range(n):
        p = data[i * PKT:(i + 1) * PKT]
        if p[0] != 0x47:
            continue
        pid = (p[1] & 0x1F) << 8 | p[2]
        pusi = p[1] & 0x40
        afc = (p[3] >> 4) & 3
        off, disc = 4, False
        if afc & 2:
            alen = p[4]
            disc = alen > 0 and bool(p[5] & 0x80)
            off = 5 + alen
        if disc:
            flagged_at.append((i, pid))
        if afc & 1 and pid != 0x1FFF:
            c = p[3] & 0x0F
            if pid in cc and not disc and c != (cc[pid] + 1) % 16 and c != cc[pid]:
                cc_errors.append((i, pid))
            cc[pid] = c
        seen_after.setdefault(pid, []).append(i)
        if not (afc & 1) or off >= PKT:
            continue
        if pid == 0 and pusi:
            s = off + 1 + p[off]
            if p[s] == 0x00:
                slen = (p[s + 1] & 0x0F) << 8 | p[s + 2]
                for j in range(s + 8, min(s + 3 + slen - 4, PKT - 3), 4):
                    if p[j] << 8 | p[j + 1]:
                        pmt_pid = (p[j + 2] & 0x1F) << 8 | p[j + 3]
                        break
        elif pid == pmt_pid and pusi:
            s = off + 1 + p[off]
            if p[s] == 0x02:
                ver = (p[s + 5] >> 1) & 0x1F
                if pmt_ver is not None and ver != pmt_ver:
                    pmt_changes.append((i, pmt_ver, ver))
                pmt_ver = ver
                slen = (p[s + 1] & 0x0F) << 8 | p[s + 2]
                info = (p[s + 10] & 0x0F) << 8 | p[s + 11]
                j, end = s + 12 + info, min(s + 3 + slen - 4, PKT)
                while j + 5 <= end:
                    st, epid = p[j], (p[j + 1] & 0x1F) << 8 | p[j + 2]
                    if st in VIDEO_TYPES:
                        video_pid = epid
                    j += 5 + ((p[j + 3] & 0x0F) << 8 | p[j + 4])
        elif pid == video_pid and pusi:
            t = pts_of(p, off)
            if t is not None:
                vpts.append((i, t))

    deltas = [step(a[1], b[1]) for a, b in zip(vpts, vpts[1:]) if 0 < step(a[1], b[1]) < 9000]
    frame = statistics.median(deltas) if deltas else 3600
    # Packets per second of output, so 0.5 s of output can group a switch's packets.
    rate = n / max(1, (step(vpts[0][1], vpts[-1][1]) / 90000)) if len(vpts) > 1 else 5000
    windows = [(i - rate / 2, i + 2 * rate, i, a, b) for i, a, b in pmt_changes]

    def second(i):
        for t, sz in sizes:
            if sz >= (i + 1) * PKT:
                return t
        return None

    switches = []
    for lo, hi, at, a, b in windows:
        flagged = sorted({pid for i, pid in flagged_at if lo <= i <= hi})
        present = sorted({pid for pid, idx in seen_after.items() if pid != 0x1FFF
                          and any(at < i <= at + rate for i in idx)})
        before = [t for i, t in vpts if i < at]
        after = [t for i, t in vpts if i >= at]
        sw = {'packet': at, 'second': second(at), 'pmt_version': f'{a}->{b}',
              'flagged': flagged, 'present_after': present,
              'unflagged': [p for p in present if p not in flagged]}
        if before and after:
            d = step(before[-1], after[0])
            sw['lost_s'] = round(max(0, d - frame) / 90000, 3)
            sw['repeat_s'] = round(max(0, -d + frame) / 90000, 3) if d <= 0 else 0.0
        switches.append(sw)
    def inside(i):
        return any(lo <= i <= hi for lo, hi, *_ in windows)

    other = sorted({(pid, second(i)) for i, pid in flagged_at if not inside(i)}, key=str)
    gaps = []
    for (ia, a), (ib, b) in zip(vpts, vpts[1:]):
        d = step(a, b)
        if (d > 2 * frame or d <= 0) and not inside(ib):
            gaps.append({'packet': ib, 'second': second(ib), 'step_s': round(d / 90000, 3)})
    errs = [e for e in cc_errors if not inside(e[0])]
    out = {'capture': path, 'packets': n, 'video_pid': video_pid, 'frame_s': round(frame / 90000, 4),
           'switches': switches, 'cc_errors_outside': len(errs),
           'cc_error_pids': sorted({p for _, p in errs}), 'pts_gaps_outside': gaps,
           'other_flags': [f'{pid}@{s}' for pid, s in other]}
    print(json.dumps(out))


if __name__ == '__main__':
    main()

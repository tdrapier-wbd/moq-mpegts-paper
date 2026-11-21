#!/usr/bin/env python3
"""How fast each PCR PID's timestamps drift against its PCR.

    ts-dts-lead.py <file.ts>

For each PID that carries both the PCR and PES (the video, in every kit fixture), the lead of each
PES's DTS (else PTS) over the last PCR is averaged over the file's first and last tenth; their
difference over the time between them is the drift, in ppm. A programme whose media do not fit its
mux rate falls steadily behind its own clock, which neither continuity nor pcrverify sees, and a
receiver that follows the clock reads it as drift. Prints the worst |ppm| on the last line.
"""

import sys

TS = 188
WRAP = 1 << 33


def ts33(b):
    return ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1


def main():
    data = open(sys.argv[1], "rb").read()
    total = len(data) // TS
    pcr, leads = {}, {}
    for n in range(total):
        p = data[n * TS:(n + 1) * TS]
        pid = (p[1] & 0x1F) << 8 | p[2]
        off = 4
        if p[3] & 0x20:
            if p[4] >= 7 and p[5] & 0x10:
                pcr[pid] = p[6] << 25 | p[7] << 17 | p[8] << 9 | p[9] << 1 | p[10] >> 7
            off = 5 + p[4]
        if pid not in pcr or not p[1] & 0x40 or p[off:off + 3] != b"\0\0\1" or off + 19 > TS:
            continue
        flags = p[off + 7]
        if not flags & 0x80:
            continue
        stamp = ts33(p[off + 14:off + 19]) if flags & 0x40 else ts33(p[off + 9:off + 14])
        lead = (stamp - pcr[pid] + WRAP // 2) % WRAP - WRAP // 2
        leads.setdefault(pid, []).append((n, lead / 90000))
    rate = packet_rate(data)
    worst = 0.0
    for pid, v in sorted(leads.items()):
        k = max(1, len(v) // 10)
        head, tail = v[:k], v[-k:]
        mean = lambda xs, i: sum(x[i] for x in xs) / len(xs)
        secs = (mean(tail, 0) - mean(head, 0)) / rate
        ppm = (mean(tail, 1) - mean(head, 1)) / secs * 1e6 if secs else 0.0
        worst = max(worst, abs(ppm))
        print(f"pid {pid}: lead {mean(head, 1):+.2f} s -> {mean(tail, 1):+.2f} s, {ppm:+.0f} ppm")
    print(f"worst {worst:.0f} ppm")


def packet_rate(data):
    """Packets per second of PCR time, over the first PCR PID's first 10 s."""
    first = want = None
    for n in range(len(data) // TS):
        p = data[n * TS:(n + 1) * TS]
        if not (p[3] & 0x20 and p[4] >= 7 and p[5] & 0x10):
            continue
        pid = (p[1] & 0x1F) << 8 | p[2]
        want = pid if want is None else want
        if pid != want:
            continue
        c = p[6] << 25 | p[7] << 17 | p[8] << 9 | p[9] << 1 | p[10] >> 7
        if first is None:
            first = (n, c)
        elif (c - first[1]) % WRAP >= 10 * 90000:
            break
        last = (n, (c - first[1]) % WRAP)
    return (last[0] - first[0]) / (last[1] / 90000)


if __name__ == "__main__":
    main()

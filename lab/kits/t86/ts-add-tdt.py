#!/usr/bin/env python3
"""Give a transport stream a TDT (PID 0x14), as a broadcast multiplex carries one.

    ts-add-tdt.py <in.ts> <out.ts> [--epoch 2026-06-19T07:54:42] [--every 1.0]

ffmpeg writes no TDT, and `make-real-mpts.sh`'s `eitinject` follows the TDT in programme 1 to
schedule EIT present/following. Once every --every seconds of PCR time a null packet becomes a TDT
whose UTC is --epoch plus the PCR time elapsed since the first PCR, so the stream's length and
every other packet are unchanged. The default epoch is the one `make-mpts-epg.py` anchors its
events to.
"""

import argparse
import datetime

TS = 188
NULL = 0x1FFF
MJD0 = datetime.date(1858, 11, 17).toordinal()


def bcd(n):
    return (n // 10) << 4 | n % 10


def tdt(when, cc):
    mjd = when.date().toordinal() - MJD0
    section = bytes([0x70, 0x70, 0x05, mjd >> 8, mjd & 0xFF,
                     bcd(when.hour), bcd(when.minute), bcd(when.second)])
    head = bytes([0x47, 0x40, 0x14, 0x10 | cc, 0x00])
    return head + section + b"\xff" * (TS - len(head) - len(section))


def pcr(p):
    if not p[3] & 0x20 or p[4] < 7 or not p[5] & 0x10:
        return None
    base = p[6] << 25 | p[7] << 17 | p[8] << 9 | p[9] << 1 | p[10] >> 7
    return base * 300 + ((p[10] & 1) << 8 | p[11])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--epoch", default="2026-06-19T07:54:42")
    ap.add_argument("--every", type=float, default=1.0)
    a = ap.parse_args()
    epoch = datetime.datetime.fromisoformat(a.epoch)
    data = bytearray(open(a.src, "rb").read())
    if len(data) % TS or data[0] != 0x47:
        raise SystemExit(f"{a.src}: not whole 188-byte packets")
    first = last = due = None
    cc = written = 0
    for off in range(0, len(data), TS):
        p = data[off:off + TS]
        pid = (p[1] & 0x1F) << 8 | p[2]
        if pid == 0x14:
            raise SystemExit(f"{a.src} already carries PID 0x14")
        c = pcr(p)
        if c is not None:
            first = c if first is None else first
            last = c
            due = first if due is None else due
        if pid == NULL and last is not None and last >= due:
            elapsed = (last - first) / 27e6
            data[off:off + TS] = tdt(epoch + datetime.timedelta(seconds=int(elapsed)), cc)
            cc = (cc + 1) & 0xF
            written += 1
            due += int(a.every * 27e6)
    if not written:
        raise SystemExit(f"{a.src}: no null packet after a PCR to carry a TDT")
    open(a.dst, "wb").write(data)
    print(f"{a.dst}: {written} TDT from {epoch.isoformat()}")


if __name__ == "__main__":
    main()

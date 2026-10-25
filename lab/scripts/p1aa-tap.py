#!/usr/bin/env python3
"""Stamp a TS stream's pictures and PCRs on arrival, recording no media (P1-aa).

    p1aa-tap.py udp <group> <port> <out.csv> [--secs N]
    p1aa-tap.py stdin <out.csv> [--secs N]

The video PID is the first video stream of the first PMT. For each of its PES starts the tap writes
`P,<pts>,<arrival_ns>`, and for every 25th PCR on it `C,<pcr_27MHz>,<arrival_ns>`; a line
`R,<packets>,<arrival_ns>` every 10 s counts the packets read. In udp mode, after joining <group>
on the loopback interface where the hand-off publishes, the arrival is the kernel's receive stamp
(SO_TIMESTAMPNS); in stdin mode it is the application's, when the read returns. It writes nothing
else, about 3 MB an hour, so a live feed can be tapped unattended.
"""
import argparse
import os
import signal
import socket
import struct
import sys
import time

PKT = 188
VIDEO = {0x01, 0x02, 0x1B, 0x24, 0x27}
SO_TIMESTAMPNS = getattr(socket, "SO_TIMESTAMPNS", 35)


class Tap:
    def __init__(self, out):
        self.f = open(out, "w", buffering=1 << 16)
        self.pmt = self.vpid = None
        self.pcrs = self.packets = 0
        self.flushed = self.counted = time.monotonic()

    def feed(self, data, ns):
        for o in range(0, len(data) - PKT + 1, PKT):
            p = data[o:o + PKT]
            if p[0] != 0x47:
                continue
            self.packets += 1
            pid = (p[1] & 0x1F) << 8 | p[2]
            pusi = p[1] & 0x40
            afc = (p[3] >> 4) & 3
            off = 4
            if afc & 2:
                alen = p[4]
                if pid == self.vpid and alen >= 7 and p[5] & 0x10:
                    self.pcrs += 1
                    if self.pcrs % 25 == 1:
                        b = p[6:12]
                        base = b[0] << 25 | b[1] << 17 | b[2] << 9 | b[3] << 1 | b[4] >> 7
                        self.f.write(f"C,{base * 300 + ((b[4] & 1) << 8 | b[5])},{ns}\n")
                off = 5 + alen
            if not afc & 1 or off >= PKT - 3 or not pusi:
                continue
            if pid == 0 and self.pmt is None:
                s = off + 1 + p[off]
                if s + 12 < PKT and p[s] == 0x00:
                    end = min(s + 3 + ((p[s + 1] & 0x0F) << 8 | p[s + 2]) - 4, PKT - 3)
                    for j in range(s + 8, end, 4):
                        if p[j] << 8 | p[j + 1]:
                            self.pmt = (p[j + 2] & 0x1F) << 8 | p[j + 3]
                            break
            elif pid == self.pmt and self.vpid is None:
                s = off + 1 + p[off]
                if s + 12 < PKT and p[s] == 0x02:
                    end = min(s + 3 + ((p[s + 1] & 0x0F) << 8 | p[s + 2]) - 4, PKT)
                    j = s + 12 + ((p[s + 10] & 0x0F) << 8 | p[s + 11])
                    while j + 5 <= end:
                        if p[j] in VIDEO:
                            self.vpid = (p[j + 1] & 0x1F) << 8 | p[j + 2]
                            break
                        j += 5 + ((p[j + 3] & 0x0F) << 8 | p[j + 4])
            elif pid == self.vpid and p[off:off + 3] == b"\x00\x00\x01" and off + 14 <= PKT and p[off + 7] & 0x80:
                b = p[off + 9:off + 14]
                pts = ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1
                self.f.write(f"P,{pts},{ns}\n")
        now = time.monotonic()
        if now - self.counted >= 10:
            self.f.write(f"R,{self.packets},{ns}\n")
            self.counted = now
        if now - self.flushed >= 1:
            self.f.flush()
            self.flushed = now

    def close(self):
        self.f.flush()
        self.f.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["udp", "stdin"])
    ap.add_argument("args", nargs="+")
    ap.add_argument("--secs", type=float, default=0)
    a = ap.parse_args()
    out = a.args[-1]
    tap = Tap(out)
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))
    end = time.time() + a.secs if a.secs else float("inf")
    if a.mode == "udp":
        group, port = a.args[0], int(a.args[1])
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
        s.setsockopt(socket.SOL_SOCKET, SO_TIMESTAMPNS, 1)
        s.bind((group, port))
        s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                     socket.inet_aton(group) + socket.inet_aton("127.0.0.1"))
        s.settimeout(1.0)
        while not stop and time.time() < end:
            try:
                data, anc, _, _ = s.recvmsg(65536, socket.CMSG_SPACE(16))
            except socket.timeout:
                continue
            except InterruptedError:
                continue
            ns = time.time_ns()
            for level, kind, val in anc:
                if level == socket.SOL_SOCKET and kind == SO_TIMESTAMPNS and len(val) >= 16:
                    sec, nsec = struct.unpack("qq", val[:16])
                    ns = sec * 1_000_000_000 + nsec
            tap.feed(data, ns)
    else:
        fd = sys.stdin.fileno()
        rest = b""
        while not stop and time.time() < end:
            try:
                chunk = os.read(fd, 1 << 16)
            except InterruptedError:
                continue
            if not chunk:
                break
            ns = time.time_ns()
            data = rest + chunk
            cut = len(data) - len(data) % PKT
            tap.feed(data[:cut], ns)
            rest = data[cut:]
    tap.close()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Forward a TS byte stream to UDP as it arrives, without re-clocking it.

    ts-rtp-forward.py <host:port> <rate_bps> [--rtp] [--ssrc N] [--json PATH]
                      [--latency-ms N] [--max-latency-ms N] [--stall-ms N] [--on-stall X]

The groomer slot of t18-arm.sh, for an exporter that paces its own output. The
fixed-delay TS export (quest/m1/tstd/delay) slices its multiplex on the PCR grid
and writes each slice at its slot boundary, so the time a byte leaves it is part
of what is under test. A groomer in that slot would replace the schedule being
graded with its own. This sends every whole packet the moment it is read, at most
seven to a datagram, and never holds a short remainder back for the next read:
holding it would delay a PCR packet by up to a slot and charge the exporter for
the forwarder's batching. Nothing is rewritten, dropped or inserted.

The rate is accepted and unused. --latency-ms, --max-latency-ms, --stall-ms and
--on-stall are accepted so that the rig can pass the pacer's command line, and
ignored. The RTP timestamp is the 90 kHz wall clock at send. Statistics go to
stderr at exit and as JSON with --json.
"""

import argparse
import json
import os
import signal
import socket
import struct
import sys
import time

TS = 188
BURST = 7


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dest", help="host:port")
    ap.add_argument("rate", type=int, help="accepted for the pacer's command line; unused")
    ap.add_argument("--rtp", action="store_true")
    ap.add_argument("--ssrc", type=int, default=0x4D4F5100)
    ap.add_argument("--json", metavar="PATH")
    for flag in ("--latency-ms", "--max-latency-ms", "--stall-ms", "--on-stall"):
        ap.add_argument(flag, help=argparse.SUPPRESS)
    a = ap.parse_args()

    host, port = a.dest.rsplit(":", 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
    addr = (host, int(port))

    fd = sys.stdin.buffer.fileno()
    pending = b""
    seq = 0
    stats = {"bytes": 0, "packets": 0, "datagrams": 0, "short_datagrams": 0, "reads": 0,
             "max_read_packets": 0, "unsynced": 0}

    # The rig ends a run with SIGTERM, so the statistics have to survive it.
    def stop(_sig, _frame):
        raise EOFError

    signal.signal(signal.SIGTERM, stop)
    while True:
        try:
            chunk = os.read(fd, 1 << 16)
        except EOFError:
            break
        if not chunk:
            break
        stats["reads"] += 1
        pending += chunk
        whole = len(pending) - len(pending) % TS
        if whole == 0:
            continue
        body, pending = pending[:whole], pending[whole:]
        stats["max_read_packets"] = max(stats["max_read_packets"], whole // TS)
        for off in range(0, whole, TS * BURST):
            payload = body[off:off + TS * BURST]
            n = len(payload) // TS
            stats["unsynced"] += sum(1 for i in range(n) if payload[i * TS] != 0x47)
            if a.rtp:
                ts90 = int(time.monotonic() * 90000) & 0xFFFFFFFF
                payload = struct.pack("!BBHII", 0x80, 33, seq, ts90, a.ssrc) + payload
                seq = (seq + 1) & 0xFFFF
            sock.sendto(payload, addr)
            stats["datagrams"] += 1
            stats["short_datagrams"] += n < BURST
            stats["packets"] += n
            stats["bytes"] += n * TS

    stats["trailing_bytes"] = len(pending)
    print(json.dumps(stats), file=sys.stderr)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(stats, f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())

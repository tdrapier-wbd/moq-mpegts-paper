#!/usr/bin/env python3
"""What a shaped rig actually passes, measured with no media stack in the way.

A rig configured at R Mb/s is only calibrated at R if a flow can reach R through it. This measures
two things a lane cannot separate from its own behaviour:

  tcp   a bulk transfer, sender to receiver, timed from the first byte received to the last
  udp   a paced datagram stream at a fixed rate and size, counted at the receiver by sequence
        number, so the rate the rig delivers and what it drops are read directly

Usage:
  rig-capacity.py tcp-recv <port>
  rig-capacity.py tcp-send <host> <port> <bytes> [congestion-control]
  rig-capacity.py udp-recv <port> <seconds>
  rig-capacity.py udp-send <host> <port> <mbit> <seconds> <datagram-bytes>

Each receiver prints one JSON line.
"""

import json
import socket
import struct
import sys
import time


def tcp_recv(port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(1)
    conn, _ = srv.accept()
    total, first, last = 0, None, None
    while True:
        buf = conn.recv(1 << 20)
        if not buf:
            break
        now = time.monotonic()
        first = first or now
        last = now
        total += len(buf)
    span = (last - first) if first and last and last > first else float("nan")
    print(
        json.dumps(
            {
                "mode": "tcp",
                "bytes": total,
                "seconds": round(span, 3),
                "mbit": round(total * 8 / span / 1e6, 2) if span == span else None,
            }
        )
    )


def tcp_send(host, port, nbytes, cc=None):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if cc:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, cc.encode())
    sock.connect((host, port))
    chunk = b"\0" * (1 << 16)
    sent = 0
    while sent < nbytes:
        n = min(len(chunk), nbytes - sent)
        sock.sendall(chunk[:n])
        sent += n
    sock.shutdown(socket.SHUT_WR)
    sock.recv(1)
    sock.close()


def udp_recv(port, seconds):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 24)
    sock.bind(("0.0.0.0", port))
    sock.settimeout(seconds + 5)
    count, total, first, last, highest, reordered = 0, 0, None, None, -1, 0
    try:
        while True:
            buf = sock.recv(65536)
            now = time.monotonic()
            first = first or now
            last = now
            seq, sent_total = struct.unpack("!QQ", buf[:16])
            if seq == 0xFFFFFFFFFFFFFFFF:
                break
            count += 1
            total += len(buf)
            if seq < highest:
                reordered += 1
            highest = max(highest, seq)
            sock.settimeout(3)
    except socket.timeout:
        sent_total = highest + 1
    span = (last - first) if first and last and last > first else float("nan")
    lost = sent_total - count
    print(
        json.dumps(
            {
                "mode": "udp",
                "sent": sent_total,
                "received": count,
                "lost_pct": round(100 * lost / sent_total, 3) if sent_total else None,
                "reordered": reordered,
                "seconds": round(span, 3),
                "mbit": round(total * 8 / span / 1e6, 2) if span == span else None,
            }
        )
    )


def udp_send(host, port, mbit, seconds, size):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    interval = size * 8 / (mbit * 1e6)
    pad = b"\0" * (size - 16)
    start = time.monotonic()
    seq = 0
    while True:
        due = start + seq * interval
        if due - start >= seconds:
            break
        wait = due - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        sock.sendto(struct.pack("!QQ", seq, 0) + pad, (host, port))
        seq += 1
    for _ in range(5):
        sock.sendto(struct.pack("!QQ", 0xFFFFFFFFFFFFFFFF, seq) + pad, (host, port))
        time.sleep(0.05)


def main():
    mode, args = sys.argv[1], sys.argv[2:]
    if mode == "tcp-recv":
        tcp_recv(int(args[0]))
    elif mode == "tcp-send":
        tcp_send(args[0], int(args[1]), int(args[2]), args[3] if len(args) > 3 else None)
    elif mode == "udp-recv":
        udp_recv(int(args[0]), float(args[1]))
    elif mode == "udp-send":
        udp_send(args[0], int(args[1]), float(args[2]), float(args[3]), int(args[4]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()

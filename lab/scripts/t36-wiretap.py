#!/usr/bin/env python3
"""Userspace datagram wiretap for T36 — a capture substitute that needs no privileges.

`tcpdump` on macOS requires root to open `/dev/bpf`, which is not available in
this environment. This forwards UDP between a client and the relay, so it sees
exactly the bytes that cross the wire, and records:

  * datagram and byte counts in each direction, with a monotonic timestamp on
    the first and last datagram, so an arm can be scored on whether any BULK
    transfer occurred rather than only on whether a handshake happened;
  * whether any 188-byte-strided 0x47 sync structure is visible in the payload,
    which is the wire-confidentiality check.

The second of those is the point worth stating plainly: QUIC encrypts its
payload, so a capture of this traffic yields ciphertext. A capture therefore
CANNOT count "payload bytes delivered" — only the receiving endpoint can, after
it has decrypted. The wiretap is corroboration for the byte-volume question and
the instrument for the confidentiality question; the payload measurement comes
from the subscriber's own output.

    t36-wiretap.py --listen 9444 --forward 9443 --log wiretap.jsonl [--mark ID]
"""

import argparse
import json
import socket
import sys
import threading
import time

SYNC = 0x47
TS_PKT = 188


def ts_structure(buf):
    """Count positions where a 0x47 appears at a 188-byte stride at least 3 times.

    A cleartext TS payload shows this immediately; ciphertext effectively never
    does. Deliberately cheap and deliberately generous: a false positive is
    worth investigating, a false negative is what would matter.
    """
    hits = 0
    n = len(buf)
    for start in range(min(TS_PKT, n)):
        if buf[start] != SYNC:
            continue
        run = 1
        pos = start + TS_PKT
        while pos < n and buf[pos] == SYNC:
            run += 1
            pos += TS_PKT
        if run >= 3:
            hits += 1
    return hits


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.d = {
            "c2s_datagrams": 0, "c2s_bytes": 0,
            "s2c_datagrams": 0, "s2c_bytes": 0,
            "first_mono": None, "last_mono": None,
            "ts_structure_hits": 0, "largest_s2c": 0,
        }

    def add(self, direction, n, buf):
        with self.lock:
            now = time.monotonic()
            if self.d["first_mono"] is None:
                self.d["first_mono"] = now
            self.d["last_mono"] = now
            self.d[f"{direction}_datagrams"] += 1
            self.d[f"{direction}_bytes"] += n
            if direction == "s2c":
                self.d["largest_s2c"] = max(self.d["largest_s2c"], n)
            self.d["ts_structure_hits"] += ts_structure(buf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, required=True)
    ap.add_argument("--forward", type=int, required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--mark", default="")
    ap.add_argument("--seconds", type=float, default=0,
                    help="run for this long then write the record and exit")
    args = ap.parse_args()

    stats = Stats()
    front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    front.bind(("127.0.0.1", args.listen))
    upstream = ("127.0.0.1", args.forward)

    # One back socket per client address, so several clients can share the tap.
    backs = {}
    lock = threading.Lock()

    def pump(back, client):
        while True:
            try:
                data, _ = back.recvfrom(65535)
            except OSError:
                return
            stats.add("s2c", len(data), data)
            try:
                front.sendto(data, client)
            except OSError:
                return

    print(f"wiretap {args.listen} -> {args.forward} mark={args.mark}", flush=True)

    # Self-terminate rather than depend on a signal: a process blocked in
    # recvfrom does not reliably die on SIGINT here, and a tap that outlives its
    # arm silently merges two arms' byte counts.
    deadline = time.monotonic() + args.seconds if args.seconds else None
    if deadline:
        front.settimeout(0.25)

    try:
        while True:
            if deadline and time.monotonic() >= deadline:
                break
            try:
                data, client = front.recvfrom(65535)
            except socket.timeout:
                continue
            stats.add("c2s", len(data), data)
            with lock:
                back = backs.get(client)
                if back is None:
                    back = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    back.connect(upstream)
                    backs[client] = back
                    threading.Thread(target=pump, args=(back, client), daemon=True).start()
            try:
                back.send(data)
            except OSError:
                pass
    except KeyboardInterrupt:
        pass
    finally:
        rec = dict(stats.d)
        rec["mark"] = args.mark
        if rec["first_mono"] is not None:
            rec["duration_s"] = round(rec["last_mono"] - rec["first_mono"], 4)
        del rec["first_mono"], rec["last_mono"]
        with open(args.log, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")
        print(json.dumps(rec), flush=True)


if __name__ == "__main__":
    main()

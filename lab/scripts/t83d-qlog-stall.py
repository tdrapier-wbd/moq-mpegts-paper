#!/usr/bin/env python3
"""t83d-skip.sh's relay qlog, per burst and per export connection: the stall and the stream resets.

    t83d-qlog-stall.py <qlog dir> <events.txt> [--json]

The stall runs from the burst's start to the first acknowledgement the relay received for a packet
it sent after the burst ended. Resets are the RESET_STREAM frames the relay sent in the burst's
window (its start to the next burst's), by application code: WebTransport maps code n onto
0x52e4a40fa8db + n + n // 0x1e, and moq-lite's `Old` is 0x34. Times are the epoch in each file's
name plus the event's offset; the importer's connection (a local peer) is skipped.
"""

import argparse
import glob
import json
import os
import re
import sys
from collections import Counter

WT = 0x52E4A40FA8DB


def app_code(h3):
    n = h3 - WT
    return n - n // 0x1F if n >= 0 else None


def bursts(path):
    on, off = [], []
    for line in open(path):
        f = line.split()
        if f[0] == "burst_on":
            on.append((f[1], int(f[2]), float(f[-1])))
        elif f[0] == "burst_off":
            off.append(float(f[-1]))
        elif f[0] == "rcv_end":
            end = float(f[-1])
    return [(d, r, t, off[i], on[i + 1][2] if i + 1 < len(on) else end) for i, (d, r, t) in enumerate(on)]


def connection(path, bs):
    t0 = int(re.search(r"moq-server-(\d+)-", os.path.basename(path)).group(1)) / 1000
    sent, peer = {}, None
    stall = [None] * len(bs)
    resets = [Counter() for _ in bs]
    with open(path, errors="replace") as f:
        for rec in f:
            if '"packet_' not in rec and "connection_started" not in rec:
                continue
            try:
                e = json.loads(rec.strip("\x1e\n"))
            except ValueError:
                continue
            name, d = e.get("name", ""), e.get("data", {})
            t = t0 + e["time"] / 1000
            if name == "quic:connection_started":
                peer = d.get("remote", {}).get("ip_v4")
                continue
            if name == "quic:packet_sent":
                sent[d["header"].get("packet_number")] = t
                for fr in d.get("frames", []):
                    if fr.get("frame_type") == "reset_stream":
                        for i, b in enumerate(bs):
                            if b[2] <= t < b[4]:
                                resets[i][app_code(fr.get("error_code", 0))] += 1
            elif name == "quic:packet_received":
                for fr in d.get("frames", []):
                    if fr.get("frame_type") != "ack" or not fr.get("acked_ranges"):
                        continue
                    top = max(r[-1] for r in fr["acked_ranges"])
                    ts = sent.get(top)
                    for i, b in enumerate(bs):
                        if stall[i] is None and ts is not None and ts >= b[3] and t >= b[3]:
                            stall[i] = round(t - b[2], 3)
    return peer, t0, stall, resets


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("qlog")
    ap.add_argument("events")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    bs = bursts(a.events)
    out = []
    for p in sorted(glob.glob(f"{a.qlog}/*.qlog")):
        peer, t0, stall, resets = connection(p, bs)
        if peer is None or peer.startswith(("10.", "127.")):
            continue
        out.append(
            {
                "file": os.path.basename(p),
                "peer_start": t0,
                "stall_s": stall,
                "resets": [{str(k): v for k, v in c.items()} for c in resets],
            }
        )
    if a.json:
        json.dump({"bursts": bs, "connections": out}, sys.stdout, indent=1)
        return
    for c in out:
        print(f"connection started {c['peer_start']:.3f} ({c['file'][:40]})")
        for b, s, r in zip(bs, c["stall_s"], c["resets"]):
            print(f"  burst {b[0]} rep {b[1]}: stall {s} s, resets {r}")


if __name__ == "__main__":
    main()

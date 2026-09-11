#!/usr/bin/env python3
"""Record when an affiliate's media egress actually stopped — T37/T38.

Reads a subscriber's TS on stdin, writes it through to a file, and records the
wall-clock time of every write. What it reports is the time of the LAST byte the
affiliate received, which is the measurement T37 requires: the zero of each
revocation arm is the control-plane decision, taken at the authorization
endpoint, and the stop is the last TS packet the affiliate actually got — not a
"session closed" line in a relay log, which is the relay's account of its own
behaviour rather than an observation of the egress.

Writes a JSON record on exit:

    {"first_write": ..., "last_write": ..., "bytes": ..., "writes": ...}

all times being `time.time()`, so they share a clock domain with the stub's
request log.
"""
import argparse
import json
import os
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="where to write the TS")
    ap.add_argument("--record", required=True, help="where to write the JSON record")
    ap.add_argument("--mark", default="")
    args = ap.parse_args()

    first = last = None
    total = writes = 0
    profile = []          # (wall, cumulative bytes) per chunk
    src = sys.stdin.buffer

    with open(args.out, "wb") as dst:
        while True:
            chunk = src.read(65536)
            if not chunk:
                break
            now = time.time()
            if first is None:
                first = now
            last = now
            total += len(chunk)
            writes += 1
            profile.append((round(now, 4), total))
            dst.write(chunk)

    rec = {"mark": args.mark, "first_write": first, "last_write": last,
           "bytes": total, "writes": writes, "profile": profile}
    with open(args.record, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec) + "\n")
    print(json.dumps(rec), flush=True)


if __name__ == "__main__":
    main()

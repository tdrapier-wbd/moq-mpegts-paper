#!/usr/bin/env python3
"""Record a byte stream from stdin with its arrival times (T56).

    t56-stamp.py <out-prefix>

Writes <out-prefix>.ts, the bytes as read, and <out-prefix>.idx, one `offset,unix_seconds` line per
read: the offset of the read's first byte and when it returned. A grader places any packet on the
clock by the last index line at or before its offset. Reads return as soon as bytes are there, so
the stamp is when the writer released them, within the pipe's scheduling.
"""
import os
import sys
import time

out = sys.argv[1]
fd = sys.stdin.fileno()
with open(out + ".ts", "wb") as ts, open(out + ".idx", "w") as idx:
    offset = 0
    while True:
        data = os.read(fd, 1 << 16)
        t = time.time()
        if not data:
            break
        ts.write(data)
        idx.write(f"{offset},{t:.6f}\n")
        offset += len(data)
        ts.flush()
        idx.flush()

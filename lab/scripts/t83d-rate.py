"""Count the bytes on stdin, printing `<epoch second> <bytes>` once a second, empty seconds included."""

import sys
import time

n, sec = 0, int(time.time())
src = sys.stdin.buffer.raw
while True:
    chunk = src.read(1 << 16)
    now = int(time.time())
    while now > sec:
        print(sec, n, flush=True)
        n, sec = 0, sec + 1
    if not chunk:
        break
    n += len(chunk)
print(sec, n, flush=True)

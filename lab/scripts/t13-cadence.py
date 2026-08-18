#!/usr/bin/env python3
"""T13 wire cadence: what a groomer actually puts on the socket.

    t13-cadence.py capture <port> <out-prefix> <seconds> [rtp]
    t13-cadence.py pipe <out-prefix> <seconds>
    t13-cadence.py report <capture.csv> [...]

`capture` timestamps every datagram arriving on a loopback port, writing
`<prefix>.csv` (arrival time in ns since the first datagram, payload length) and
`<prefix>.ts` (the stream as received, RTP header stripped when `rtp` is given)
so one capture answers both the cadence and the PCR question. Reading the socket
directly needs no privileges, which is why this rather than a pcap.

`pipe` does the same for a stream arriving on stdin, which is what T14
measurement 2 needs: the cadence of an *ungroomed* egress — `tsp -I hls` or
`moq export ts` — before any pacer touches it. Each `read()` returns whatever the
writer has buffered, so a burst appears as consecutive full-size reads at ~zero
gap and an idle period as one long gap, the same shape a datagram capture sees.
Two limits worth stating when quoting the numbers: the read size caps resolution,
so bursts are resolved at or above `CHUNK`, and the pipe buffer itself smooths
anything finer. Both legs must be measured with the same `CHUNK` to compare.

`report` summarises the gap distribution and the delivered rate in 10 ms and 1 s
windows. The 1 s series is the one that exposes a groomer which emits a
constant-rate *stream* as fast as its input arrives rather than pacing it: the
average comes out right while the wire is nothing an IRD would accept.
"""

from __future__ import annotations

import csv
import os
import socket
import statistics as stats
import sys
import time

WINDOW_10MS = 10_000_000
WINDOW_1S = 1_000_000_000
CHUNK = 65536


def write_records(prefix: str, records: list[tuple[int, int]], unit: str) -> None:
    with open(prefix + ".csv", "w") as fh:
        fh.write("t_ns,bytes\n")
        for arrival, length in records:
            fh.write(f"{arrival},{length}\n")

    span = records[-1][0] / 1e9 if records else 0.0
    total = sum(length for _, length in records)
    rate = f", {total * 8 / span / 1e6:.3f} Mb/s" if span else ""
    print(f"captured {len(records):,} {unit}, {total:,} bytes, {span:.2f} s{rate}")


def capture(port: int, prefix: str, seconds: float, rtp: bool) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    sock.bind(("127.0.0.1", port))
    sock.settimeout(2.0)

    records: list[tuple[int, int]] = []
    first: int | None = None
    with open(prefix + ".ts", "wb") as stream:
        while True:
            try:
                datagram = sock.recv(65535)
            except socket.timeout:
                if first is not None:
                    break
                continue
            now = time.perf_counter_ns()
            if first is None:
                first = now
            elif (now - first) / 1e9 > seconds:
                break
            records.append((now - first, len(datagram)))
            stream.write(datagram[12:] if rtp else datagram)

    write_records(prefix, records, "datagrams")


def pipe(prefix: str, seconds: float) -> None:
    """Timestamp reads from stdin, writing the same csv/ts pair as `capture`."""
    fd = sys.stdin.fileno()
    records: list[tuple[int, int]] = []
    first: int | None = None
    with open(prefix + ".ts", "wb") as stream:
        while True:
            block = os.read(fd, CHUNK)
            if not block:
                break
            now = time.perf_counter_ns()
            if first is None:
                first = now
            elif (now - first) / 1e9 > seconds:
                break
            records.append((now - first, len(block)))
            stream.write(block)

    write_records(prefix, records, "reads")


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(p / 100 * len(ordered)))]


def windowed(records: list[tuple[int, int]], width_ns: int) -> list[float]:
    buckets: dict[int, int] = {}
    for arrival, length in records:
        buckets[arrival // width_ns] = buckets.get(arrival // width_ns, 0) + length
    if not buckets:
        return []
    return [
        buckets.get(index, 0) * 8 / (width_ns / 1e9)
        for index in range(min(buckets), max(buckets))
    ]


def report(paths: list[str]) -> None:
    for path in paths:
        with open(path) as fh:
            records = [
                (int(row["t_ns"]), int(row["bytes"])) for row in csv.DictReader(fh)
            ]
        if len(records) < 2:
            print(f"=== {path}: nothing captured")
            continue
        gaps = [(later[0] - earlier[0]) / 1000 for earlier, later in zip(records, records[1:])]
        fine = windowed(records, WINDOW_10MS)
        coarse = windowed(records, WINDOW_1S)
        name = path.split("/")[-1].removesuffix(".csv")
        print(f"=== {name}: {len(records):,} records over {records[-1][0] / 1e9:.2f} s")
        print(f"    gap us   mean {stats.mean(gaps):8.1f}  p50 {percentile(gaps, 50):8.1f}"
              f"  p95 {percentile(gaps, 95):8.1f}  p99 {percentile(gaps, 99):8.1f}"
              f"  max {max(gaps):9.1f}")
        print(f"    10 ms    mean {stats.mean(fine) / 1e6:7.3f}  min {min(fine) / 1e6:7.3f}"
              f"  max {max(fine) / 1e6:7.3f}  p95 {percentile(fine, 95) / 1e6:7.3f} Mb/s"
              f"  peak/mean {max(fine) / stats.mean(fine):.2f}"
              f"  CoV {stats.pstdev(fine) / stats.mean(fine):.3f}")
        print("    1 s      " + " ".join(f"{value / 1e6:.2f}" for value in coarse))


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    if sys.argv[1] == "capture":
        capture(int(sys.argv[2]), sys.argv[3], float(sys.argv[4]),
                len(sys.argv) > 5 and sys.argv[5] == "rtp")
    elif sys.argv[1] == "pipe":
        pipe(sys.argv[2], float(sys.argv[3]))
    elif sys.argv[1] == "report":
        report(sys.argv[2:])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()

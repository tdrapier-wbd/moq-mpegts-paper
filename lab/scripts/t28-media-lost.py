#!/usr/bin/env python3
"""T28's shared grader: seconds of programme lost or duplicated in a captured TS.

The headline metric for the failure-injection matrix is *programme* time, not session
recovery time, and the two are different numbers. This grader derives it from the PCR
timeline of a file capture, so it scores the same way on either lane and needs nothing
from the transport's own logs.

The method. In a file capture, bytes that never arrived do not leave a gap in the file --
they leave a gap in the *clock*. Successive PCR samples carry both a packet index and a
27 MHz timestamp, so for every adjacent pair we know how many bytes were delivered and
how much programme time elapsed. At the nominal rate those agree. Where programme time
ran ahead of the bytes, the excess is media that was never delivered; where it ran
backwards, the stream repeated itself.

    media lost (s) = sum over adjacent PCR pairs of
                     max(0, dt_observed - bytes_between / nominal_rate)

The nominal rate is the *median* of the per-interval rates rather than the mean or the
overall file average, because the holes are exactly what we are measuring and must not
be allowed to move the reference they are measured against. One 30 s blackout in a 60 s
capture halves the file average; it does not move the median.

Reports duplication separately rather than netting it off: a stream that loses five
seconds and repeats five seconds has not broken even.

Usage:
    t28-media-lost.py --input capture.ts [--pid 111] [--tolerance-ms 100] [--json out.json]
    t28-media-lost.py --csv pcr.csv     [--pid 111]          # re-grade without re-running tsp

Pass criterion 1 of T28 requires that this report ~0 on an unimpaired capture *and* the
injected duration to within 100 ms on a capture with a known hole. `t28-grader-selftest.sh`
does both; do not quote a zero from this script that has not been paired with that run.
"""

import argparse
import csv
import json
import re
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

PCR_HZ = 27_000_000
# PCR is a 33-bit 90 kHz base plus a 9-bit 27 MHz extension, so the full-value modulus is
# 2**33 * 300 and the clock wraps every ~26.5 hours.
PCR_MODULUS = (1 << 33) * 300
TS_PACKET_BITS = 188 * 8


def extract_pcr_csv(ts_path: Path, out_csv: Path) -> None:
	subprocess.run(
		[
			"tsp",
			"-I", "file", str(ts_path),
			"-P", "pcrextract", "--output-file", str(out_csv),
			"-O", "drop",
		],
		check=True,
		capture_output=True,
	)


def read_pcr_samples(csv_path: Path, pid: int | None) -> tuple[int, list[tuple[int, int]]]:
	"""Return (pid, [(packet_index_in_ts, pcr_27mhz), ...]) for one PID.

	Column 5 is `Value`. Reading column 6 (`Value offset in PID`) instead is a mistake this
	campaign has already made once; it yields absurd 64-bit deltas rather than an obvious
	error, so the header is asserted rather than trusted.
	"""
	by_pid: dict[int, list[tuple[int, int]]] = {}
	with csv_path.open(newline="") as fh:
		reader = csv.reader(fh)
		header = next(reader, None)
		if not header or header[5] != "Value" or header[1] != "Packet index in TS":
			raise SystemExit(f"unexpected pcrextract header: {header}")
		for row in reader:
			if len(row) < 6 or row[3] != "PCR":
				continue
			by_pid.setdefault(int(row[0]), []).append((int(row[1]), int(row[5])))

	if not by_pid:
		raise SystemExit("no PCR samples found; is this a transport stream with a PCR PID?")

	if pid is None:
		# The PCR-bearing PID with the most samples is the programme clock.
		pid = max(by_pid, key=lambda p: len(by_pid[p]))
	elif pid not in by_pid:
		raise SystemExit(f"PID {pid} carries no PCR; PIDs with PCR: {sorted(by_pid)}")

	return pid, by_pid[pid]


def unwrap(samples: list[tuple[int, int]]) -> list[tuple[int, float]]:
	"""Undo PCR wraparound, returning seconds. A backward step of more than half the
	modulus is a wrap; anything smaller is a real regression and must survive to be
	counted as duplication."""
	out: list[tuple[int, float]] = []
	epochs = 0
	prev_raw = None
	for idx, raw in samples:
		if prev_raw is not None and raw - prev_raw < -(PCR_MODULUS // 2):
			epochs += 1
		prev_raw = raw
		out.append((idx, (raw + epochs * PCR_MODULUS) / PCR_HZ))
	return out


def grade(samples: list[tuple[int, float]], tolerance_s: float) -> dict:
	if len(samples) < 3:
		raise SystemExit(f"only {len(samples)} PCR samples; too few to establish a rate")

	intervals = []
	for (i0, t0), (i1, t1) in zip(samples, samples[1:]):
		intervals.append((i1 - i0, t1 - t0, t0, t1))

	# Median of the per-interval rates: immune to the holes being measured.
	rates = [(di * TS_PACKET_BITS) / dt for di, dt, _, _ in intervals if dt > 0 and di > 0]
	if not rates:
		raise SystemExit("no usable PCR intervals; the clock never advanced")
	nominal_bps = statistics.median(rates)

	holes, repeats = [], []
	for di, dt, t0, t1 in intervals:
		expected = (di * TS_PACKET_BITS) / nominal_bps
		excess = dt - expected
		if excess > tolerance_s:
			holes.append({"at_s": round(t0, 6), "lost_s": round(excess, 6)})
		elif -excess > tolerance_s:
			repeats.append({"at_s": round(t0, 6), "duplicated_s": round(-excess, 6)})

	span = samples[-1][1] - samples[0][1]
	return {
		"pcr_samples": len(samples),
		"nominal_bitrate_bps": round(nominal_bps),
		"timeline_span_s": round(span, 6),
		"media_lost_s": round(sum(h["lost_s"] for h in holes), 6),
		"media_duplicated_s": round(sum(r["duplicated_s"] for r in repeats), 6),
		"hole_count": len(holes),
		"largest_hole_s": round(max((h["lost_s"] for h in holes), default=0.0), 6),
		"holes": holes,
		"repeats": repeats,
	}


CONTINUITY_RE = re.compile(r"missing ([\d,]+) packet")


def continuity_errors(ts_path: Path) -> int:
	"""Count continuity errors by the plugin's *data* -- the packet counts it reports --
	not by grepping for the word "discontinuity", which appears in headings and in
	signalled-discontinuity notices that are conformant."""
	proc = subprocess.run(
		["tsp", "-I", "file", str(ts_path), "-P", "continuity", "-O", "drop"],
		capture_output=True,
		text=True,
	)
	return sum(int(m.group(1).replace(",", "")) for m in CONTINUITY_RE.finditer(proc.stderr + proc.stdout))


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	src = ap.add_mutually_exclusive_group(required=True)
	src.add_argument("--input", type=Path, help="captured transport stream to grade")
	src.add_argument("--csv", type=Path, help="a pcrextract CSV already produced")
	ap.add_argument("--pid", type=int, default=None, help="PCR PID (default: the one with most samples)")
	ap.add_argument(
		"--tolerance-ms",
		type=float,
		default=100.0,
		help="ignore timeline excursions below this; default 100 ms, T28 pass criterion 1's margin",
	)
	ap.add_argument("--json", type=Path, help="write the full result here")
	ap.add_argument("--label", default="", help="cell label carried through to the JSON")
	args = ap.parse_args()

	with tempfile.TemporaryDirectory() as tmp:
		if args.input:
			csv_path = Path(tmp) / "pcr.csv"
			extract_pcr_csv(args.input, csv_path)
		else:
			csv_path = args.csv

		pid, raw = read_pcr_samples(csv_path, args.pid)
		result = grade(unwrap(raw), args.tolerance_ms / 1000.0)

	result["pcr_pid"] = pid
	result["tolerance_ms"] = args.tolerance_ms
	result["label"] = args.label
	result["source"] = str(args.input or args.csv)
	if args.input:
		result["continuity_errors"] = continuity_errors(args.input)

	print(
		f"{result['label'] or result['source']}: "
		f"media_lost={result['media_lost_s']:.3f}s "
		f"duplicated={result['media_duplicated_s']:.3f}s "
		f"holes={result['hole_count']} "
		f"largest={result['largest_hole_s']:.3f}s "
		f"span={result['timeline_span_s']:.3f}s "
		f"continuity_errors={result.get('continuity_errors', 'n/a')}"
	)

	if args.json:
		args.json.write_text(json.dumps(result, indent=2) + "\n")

	return 0


if __name__ == "__main__":
	sys.exit(main())

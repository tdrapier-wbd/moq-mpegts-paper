#!/usr/bin/env python3
"""Move every Nth PCR of a transport stream by a known number of 27 MHz ticks: a positive control.

    <ts on stdin> | pcr-perturb.py --every 250 --ticks 20 [--pid N] [--log FILE] | <grader>
    <ts on stdin> | pcr-perturb.py --null-every 2000 [--null-pid N] [--log FILE] | <grader>

A PCR-accuracy grader that has only ever read "clean" has not been shown to work (method notes §1).
This damages a stream's clock by a known amount at known PCRs and leaves every byte else as it
was, so a grader in the same pipeline must report the moved PCRs and nothing more. 20 ticks is
741 ns, past TR 101 290's ±500 ns; the PCR is rewritten in place (base and extension), so the
packet count between PCRs, and with it the stream's rate, is unchanged.

--null-every is the continuity grader's control: every Nth packet of one PID is replaced by a null
packet, so that PID loses one continuity count each time and every PCR stays where it was.

The PCR PID is the first to carry a PCR unless --pid names one; the nulled PID is the first other
PID to start a PES (an elementary stream, not a table) unless --null-pid names one. --log writes one line per moved PCR
(its index on the PID and the packet index) and per nulled packet, for matching against the
grader's report.
"""

import argparse
import sys

TS = 188
WRAP = (1 << 33) * 300
NULL = bytes([0x47, 0x1F, 0xFF, 0x10]) + b"\xff" * (TS - 4)


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	ap.add_argument("--every", type=int, help="move every Nth PCR on the PID")
	ap.add_argument("--ticks", type=int, help="27 MHz ticks added to each moved PCR")
	ap.add_argument("--pid", type=int)
	ap.add_argument("--null-every", type=int, help="replace every Nth packet of the PID by a null")
	ap.add_argument("--null-pid", type=int)
	ap.add_argument("--log")
	args = ap.parse_args()
	if args.every is None and args.null_every is None:
		ap.error("give --every and --ticks, or --null-every")
	if args.every is not None and (args.every < 2 or args.ticks is None):
		ap.error("--every must be at least 2, with --ticks")
	if args.null_every is not None and args.null_every < 2:
		ap.error("--null-every must be at least 2")
	log = open(args.log, "w") if args.log else None
	src, dst = sys.stdin.buffer, sys.stdout.buffer
	pid, npid, n, m, nulled, k = args.pid, args.null_pid, 0, 0, 0, 0
	buf = b""
	while True:
		chunk = src.read(TS * 1024)
		if not chunk:
			break
		buf += chunk
		cut = len(buf) - len(buf) % TS
		out = bytearray(buf[:cut])
		buf = buf[cut:]
		for off in range(0, cut, TS):
			k += 1
			p = out[off : off + TS]
			if p[0] != 0x47:
				continue
			this = ((p[1] & 0x1F) << 8) | p[2]
			pcr = p[3] & 0x20 and p[4] >= 7 and p[5] & 0x10
			if pcr and pid is None:
				pid = this
			if args.null_every is not None and p[3] & 0x10 and 0x20 <= this < 0x1FFF and this != pid:
				start = 5 + p[4] if p[3] & 0x20 else 4
				if npid is None and pid is not None and p[1] & 0x40 and p[start : start + 3] == b"\x00\x00\x01":
					npid = this
				if this == npid:
					m += 1
					if m % args.null_every == 0:
						out[off : off + TS] = NULL
						nulled += 1
						if log:
							print(f"null pid={this} packet={k}", file=log, flush=True)
						continue
			if not pcr or this != pid:
				continue
			n += 1
			if args.every is None or n % args.every:
				continue
			b = p[6:12]
			base = (b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)
			ext = ((b[4] & 1) << 8) | b[5]
			v = (base * 300 + ext + args.ticks) % WRAP
			base, ext = divmod(v, 300)
			out[off + 6 : off + 12] = bytes(
				(
					(base >> 25) & 0xFF,
					(base >> 17) & 0xFF,
					(base >> 9) & 0xFF,
					(base >> 1) & 0xFF,
					((base & 1) << 7) | (b[4] & 0x7E) | (ext >> 8),
					ext & 0xFF,
				)
			)
			if log:
				print(f"pcr={n} packet={k} ticks={args.ticks}", file=log, flush=True)
		dst.write(out)
	dst.write(buf)
	dst.flush()
	moved = n // args.every if args.every else 0
	print(
		f"pcr-perturb: pid={pid} pcrs={n} moved={moved} ticks={args.ticks} null_pid={npid} nulled={nulled}",
		file=sys.stderr,
	)
	return 0


if __name__ == "__main__":
	sys.exit(main())

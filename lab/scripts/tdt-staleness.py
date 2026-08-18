#!/usr/bin/env python3
"""How late is the clock a transport delivers?

Reads a transport stream and, for every TDT/TOT section on PID 0x0014, reports the
difference between the UTC the section *asserts* and the wall clock when it
arrived. On a live path fed by `tsp -P timeref --start system` the source's clock
is true at the moment of transmission, so that difference is the transport's
contribution and nothing else.

The number matters because TDT is not state, it is a sample of an advancing
quantity. A transport that forwards sections at a constant delay is late by that
delay and no more. One that caches a section and re-emits it on its own schedule
asserts a time it knows to be wrong, repeatedly, and the error grows with the gap
between source sections rather than staying bounded by the path.

Usage: tdt-staleness.py [file.ts]     (default: stdin)
"""

import datetime
import sys

TDT_PID = 0x0014
PACKET = 188


def mjd_to_date(mjd: int) -> datetime.date:
	"""EN 300 468 Annex C. Valid 1900-03-01 to 2100-02-28, which covers TDT's field."""
	yp = int((mjd - 15078.2) / 365.25)
	mp = int((mjd - 14956.1 - int(yp * 365.25)) / 30.6001)
	day = mjd - 14956 - int(yp * 365.25) - int(mp * 30.6001)
	k = 1 if mp in (14, 15) else 0
	return datetime.date(yp + k + 1900, mp - 1 - k * 12, day)


def bcd(byte: int) -> int:
	return (byte >> 4) * 10 + (byte & 0x0F)


def utc_time(field: bytes) -> datetime.datetime | None:
	"""The 40-bit UTC_time field shared by TDT and TOT: 16-bit MJD, then BCD hhmmss."""
	mjd = (field[0] << 8) | field[1]
	try:
		date = mjd_to_date(mjd)
		return datetime.datetime.combine(
			date,
			datetime.time(bcd(field[2]), bcd(field[3]), bcd(field[4])),
			tzinfo=datetime.timezone.utc,
		)
	except ValueError:
		return None


def main() -> None:
	src = open(sys.argv[1], "rb") if len(sys.argv) > 1 else sys.stdin.buffer
	now = datetime.datetime.now(datetime.timezone.utc)
	first = now

	deltas: list[float] = []
	seen: dict[int, int] = {}
	buf = b""
	print(f"{'arrival (s)':>11}  {'table':>5}  {'asserted UTC':<20}  {'late by (ms)':>12}")

	while chunk := src.read(PACKET * 64):
		buf += chunk
		# Resync on the sync byte rather than assuming the stream starts aligned:
		# a socket capture can open mid-packet.
		while (start := buf.find(b"\x47")) >= 0 and len(buf) - start >= PACKET:
			pkt, buf = buf[start : start + PACKET], buf[start + PACKET :]
			pid = ((pkt[1] & 0x1F) << 8) | pkt[2]
			if pid != TDT_PID or not (pkt[1] & 0x40):
				continue
			off = 4
			if pkt[3] & 0x20:  # adaptation field
				off += 1 + pkt[4]
			off += 1 + pkt[off]  # pointer_field, then the section it points at
			if off + 8 > PACKET:
				continue
			table_id = pkt[off]
			if table_id not in (0x70, 0x73):  # TDT, TOT
				continue
			asserted = utc_time(pkt[off + 3 : off + 8])
			if asserted is None:
				continue
			now = datetime.datetime.now(datetime.timezone.utc)
			late = (now - asserted).total_seconds() * 1000
			deltas.append(late)
			seen[table_id] = seen.get(table_id, 0) + 1
			print(
				f"{(now - first).total_seconds():11.2f}  "
				f"0x{table_id:02X}   {asserted:%Y-%m-%d %H:%M:%S}  {late:12.0f}"
			)

	if not deltas:
		print("\nno TDT/TOT section on PID 0x0014: the clock did not survive")
		sys.exit(1)

	tally = " ".join(f"0x{t:02X}x{n}" for t, n in sorted(seen.items()))
	span = max(deltas) - min(deltas)
	print(
		f"\n{len(deltas)} section(s) [{tally}]  "
		f"late by min {min(deltas):.0f} / median {sorted(deltas)[len(deltas) // 2]:.0f} / "
		f"max {max(deltas):.0f} ms, spread {span:.0f} ms"
	)


if __name__ == "__main__":
	main()

#!/usr/bin/env python3
"""Write the TS payload of a recorded RTP leg (T12's format: a little-endian u16 length, then the
datagram) as a transport stream, in arrival order, for the content graders.

Usage: t68-rtp2ts.py <leg.rtp> <out.ts>
"""

import struct
import sys

RTP_HEADER = 12


def main():
	src, dst = sys.argv[1], sys.argv[2]
	with open(src, "rb") as f:
		blob = f.read()
	i = n_dg = 0
	with open(dst, "wb") as out:
		while i + 2 <= len(blob):
			(n,) = struct.unpack_from("<H", blob, i)
			i += 2
			dg = blob[i : i + n]
			i += n
			if len(dg) < n or (len(dg) - RTP_HEADER) % 188:
				continue
			out.write(dg[RTP_HEADER:])
			n_dg += 1
	print(f"{n_dg} datagrams")


if __name__ == "__main__":
	main()

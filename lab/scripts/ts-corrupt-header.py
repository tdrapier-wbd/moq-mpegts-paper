#!/usr/bin/env python3
"""Flip exactly one bit in one frame header of one elementary stream of an MPEG-TS.

Written to check moq-dev/moq#2751 (fix for #2729): before the fix a single damaged MP2 or
AC-3 header aborted `moq import ts` and every other track with it, while video recovered
from the same treatment. Building the arms from a real capture rather than a synthetic PES
puts the corruption in genuine payload with real PSI, PCR and interleave around it.

Targets are found by walking TS packets of one PID, skipping the PES header, and matching
the codec's sync pattern, so the damaged byte is a real frame boundary rather than a chance
hit. Verify the result with `cmp -l clean.ts damaged.ts | wc -l` - it must be 1.

usage: ts-corrupt-header.py <src.ts> <dst.ts> <pid> {mp2|ac3|video} <skip>

  <skip>  how many matching headers to pass over before damaging one, so the damage can be
          placed mid-file rather than at the first frame.

Caveat worth knowing: a sync pattern can occur by chance inside compressed payload, so a
low <skip> on a dense stream may land on a false positive and prove nothing. If an arm
fails to reproduce, confirm the damage was fatal on a known-bad build before believing it.
"""
import sys

PKT = 188


def pes_payload_offset(pkt):
	"""Byte offset of the PES payload within a TS packet, or None."""
	if pkt[0] != 0x47:
		return None
	afc = (pkt[3] >> 4) & 0x3
	off = 4
	if afc in (2, 3):
		off += 1 + pkt[4]
	if afc == 2 or off >= PKT:
		return None
	if not (pkt[1] & 0x40):        # not a PES start: payload is frame continuation
		return off
	if pkt[off:off + 3] != b"\x00\x00\x01":
		return None
	return off + 9 + pkt[off + 8]  # 6-byte PES header + flags + PES_header_data_length


def is_mp2_header(b):
	# 11-bit sync, MPEG-1 (0b11), layer II (0b10), non-free non-reserved bitrate
	return (len(b) >= 4 and b[0] == 0xFF and (b[1] & 0xE0) == 0xE0
	        and (b[1] & 0x18) == 0x18 and (b[1] & 0x06) == 0x04
	        and (b[2] >> 4) not in (0x0, 0xF) and ((b[2] >> 2) & 0x3) != 0x3)


def is_ac3_header(b):
	return len(b) >= 6 and b[0] == 0x0B and b[1] == 0x77 and (b[4] >> 6) != 0x3


def is_video_startcode(b):
	# H.264 Annex-B 4-byte start code followed by a non-zero NAL header
	return len(b) >= 5 and b[0:4] == b"\x00\x00\x00\x01" and b[4] != 0


MATCH = {"mp2": is_mp2_header, "ac3": is_ac3_header, "video": is_video_startcode}


def main():
	src, dst, pid, kind, skip = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
	data = bytearray(open(src, "rb").read())
	match = MATCH[kind]
	seen = 0

	for base in range(0, len(data) - PKT + 1, PKT):
		pkt = data[base:base + PKT]
		if pkt[0] != 0x47 or ((pkt[1] & 0x1F) << 8 | pkt[2]) != pid:
			continue
		off = pes_payload_offset(pkt)
		if off is None:
			continue
		for i in range(off, PKT - 6):
			if not match(pkt[i:i + 8]):
				continue
			seen += 1
			if seen <= skip:
				continue
			abs_off = base + i
			# Break the sync pattern with a single bit, at its last byte for video so the
			# start code itself still delimits the unit the way a real bit error would.
			target = abs_off + 3 if kind == "video" else abs_off
			before = data[target]
			data[target] = before ^ 0x01
			open(dst, "wb").write(data)
			print(f"{kind} PID {pid}: header #{seen} at byte {abs_off} (packet {base // PKT}), "
			      f"flipped offset {target}: 0x{before:02X} -> 0x{data[target]:02X}")
			return 0

	print(f"no {kind} header found on PID {pid} after skipping {skip}", file=sys.stderr)
	return 1


sys.exit(main())

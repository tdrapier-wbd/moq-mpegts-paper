#!/usr/bin/env python3
"""Audit an egress TS capture for audio frames that exist nowhere in the source.

Built for moq-dev/moq#2802 — "moq import ts publishes one frame of mixed bytes
before resyncing at a splice". A frame assembled across a splice is made of bytes
from both sides of it, so its hash appears in the capture and in neither the
source's frame set nor anywhere else in the source's elementary stream. That makes
"alien frame" a decidable property rather than a judgement about audio quality.

For each PID it reports:

  * whether the source's audio PES packets end on frame boundaries, which decides
    whether a carried tail can arise at a PES boundary at all;
  * how many leading continuation packets (no PUSI) the source begins with, which
    is where a looped file's foreign bytes enter the *same* PES as the pre-wrap
    tail rather than the next one;
  * alien frames per capture, whether each begins with the source's trailing
    partial frame, and for AC-3 whether its mandatory crc1 rejects it.

usage: ts-splice-audit.py <source.ts> <capture.ts>[,<capture.ts>...] [pid:codec ...]
       defaults to 121:mp2 123:ac3
"""

import importlib.util
import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("taf", os.path.join(_here, "ts-audio-frames.py"))
taf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(taf)


def crc16_ansi(data):
	crc = 0
	for b in data:
		crc ^= b << 8
		for _ in range(8):
			crc = ((crc << 1) ^ 0x8005) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
	return crc


def ac3_crc1_ok(frame):
	"""A/52 crc1 protects the first 5/8 of the frame and is stored at bytes 2..4.

	It is prepended rather than appended, so a CRC taken across the stored value
	and the region it covers comes to zero on a good frame.
	"""
	n = len(frame)
	n58 = ((n >> 1) + (n >> 3)) & ~1
	return crc16_ansi(frame[2:n58]) == 0


def es_of(path, pid):
	out = bytearray()
	for _, payload in taf.pes_payloads(path, pid):
		out.extend(payload)
	return bytes(out)


def pes_ends(path, pid):
	ends, total = [], 0
	for _, payload in taf.pes_payloads(path, pid):
		total += len(payload)
		ends.append(total)
	return ends


def leading_continuations(path, pid):
	"""Payload bytes on `pid` that precede the file's first PUSI for that PID."""
	raw = open(path, "rb").read()
	got, count = bytearray(), 0
	for off in range(0, len(raw) - 188 + 1, 188):
		p = raw[off:off + 188]
		if p[0] != 0x47 or ((p[1] << 8 | p[2]) & 0x1FFF) != pid:
			continue
		afc = (p[3] >> 4) & 0x03
		i = 4
		if afc in (2, 3):
			i += 1 + p[4]
		if afc == 2 or i >= 188:
			continue
		if p[1] & 0x40:
			break
		got.extend(p[i:])
		count += 1
	return count, bytes(got)


def main():
	if len(sys.argv) < 3:
		raise SystemExit(__doc__)
	source, captures = sys.argv[1], sys.argv[2].split(",")
	specs = sys.argv[3:] or ["121:mp2", "123:ac3"]

	for spec in specs:
		pid_s, codec = spec.split(":")
		pid = int(pid_s, 0)
		parser = {"mp2": taf.mp2_frame_len, "ac3": taf.ac3_frame_len}[codec]

		src = es_of(source, pid)
		sf, lead, tail, _ = taf.walk(src, parser)
		srcset = {f["sha1"] for f in sf}
		flen = sorted({f["len"] for f in sf})

		print(f"\n===== PID {pid} ({pid:#x}) {codec} =====")
		print(f"source            : {len(sf)} frames, length(s) {flen}, "
		      f"trailing partial {len(tail)} B")
		ends = pes_ends(source, pid)
		misaligned = [e for e in ends[:-1] if flen and e % flen[0] != 0]
		print(f"PES alignment     : {len(misaligned)}/{len(ends)-1} interior PES ends "
		      f"fall mid-frame"
		      f"{'  -> a carried tail can only come from the file end' if not misaligned else ''}")
		ncont, contbytes = leading_continuations(source, pid)
		print(f"leading continuation packets (no PUSI): {ncont} ({len(contbytes)} B) "
		      f"-> foreign bytes enter the SAME PES as the pre-wrap tail")
		if codec == "mp2" and sf:
			prot = sum(1 for f in sf if not (src[f["es_offset"] + 1] & 0x01))
			print(f"CRC protection    : {prot}/{len(sf)} frames carry a CRC "
			      f"(MP2 protection_bit == 0)")
		elif codec == "ac3" and sf:
			ok = sum(1 for f in sf
			         if ac3_crc1_ok(src[f["es_offset"]:f["es_offset"] + f["len"]]))
			print(f"CRC protection    : crc1 mandatory; validates on {ok}/{len(sf)} "
			      f"source frames")

		for cap in captures:
			es = es_of(cap, pid)
			ef, _, _, gaps = taf.walk(es, parser)
			alien = [f for f in ef if f["sha1"] not in srcset]
			label = os.path.basename(cap)
			print(f"  {label:24s} {len(ef):5d} frames  {len(gaps)} resync gaps  "
			      f"ALIEN {len(alien)}")
			for a in alien:
				blob = es[a["es_offset"]:a["es_offset"] + a["len"]]
				bits = [f"begins with the source's trailing partial: "
				        f"{blob[:len(tail)] == tail}"]
				if codec == "ac3":
					bits.append(f"crc1 rejects it: {not ac3_crc1_ok(blob)}")
				print(f"      idx {a['index']:5d} len {a['len']}  {a['sha1'][:12]}  "
				      + ";  ".join(bits))


if __name__ == "__main__":
	main()

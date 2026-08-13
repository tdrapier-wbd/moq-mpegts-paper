#!/usr/bin/env python3
"""Walk the audio elementary stream of one TS PID frame by frame.

Reassembles PES payloads for a PID, then parses the elementary stream as a
sequence of MP2 (MPEG-1 Layer II) or AC-3 sync frames, reporting each frame's
offset, length and content hash.

Two things it is built to answer:

  * does the stream end mid-frame?  A partial frame at the end of a clip is the
    carried tail that a loop wrap splices onto unrelated bytes.
  * is every frame in a capture also present in the source?  A frame assembled
    across a splice is made of bytes from both sides, so its hash appears in the
    capture and nowhere in the source.

usage: ts-audio-frames.py <file.ts> <pid> {mp2|ac3} [--json <out>] [--quiet]
"""

import hashlib
import json
import sys

TS_PACKET = 188
SYNC_BYTE = 0x47

# MPEG-1 Layer II, kbps by bitrate_index.
MP2_BITRATE = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0]
MP2_RATE = [44100, 48000, 32000, 0]
# AC-3 nominal kbps by frmsizecod >> 1 (A/52 Table 5.18).
AC3_BITRATE = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
               384, 448, 512, 576, 640]


def pes_payloads(path, pid):
	"""Yield (pts, payload) per PES packet on `pid`, in transport order."""
	data = open(path, "rb").read()
	if len(data) < TS_PACKET or data[0] != SYNC_BYTE:
		raise SystemExit(f"{path}: not a 188-byte TS (first byte {data[0]:#x})")

	cur, cur_pts = None, None
	for off in range(0, len(data) - TS_PACKET + 1, TS_PACKET):
		pkt = data[off:off + TS_PACKET]
		if pkt[0] != SYNC_BYTE:
			continue
		if ((pkt[1] << 8 | pkt[2]) & 0x1FFF) != pid:
			continue
		pusi = pkt[1] & 0x40
		afc = (pkt[3] >> 4) & 0x03
		i = 4
		if afc in (2, 3):
			i += 1 + pkt[4]
		if afc == 2 or i >= TS_PACKET:
			continue
		body = pkt[i:]

		if pusi:
			if cur is not None:
				yield cur_pts, bytes(cur)
			# PES header: 6-byte prefix, flags, then header_data_length.
			if len(body) < 9 or body[0:3] != b"\x00\x00\x01":
				cur, cur_pts = None, None
				continue
			hdr_len = body[8]
			cur_pts = None
			if body[7] & 0x80 and hdr_len >= 5:
				p = body[9:14]
				cur_pts = (((p[0] >> 1) & 0x07) << 30 | p[1] << 22 |
				           (p[2] >> 1) << 15 | p[3] << 7 | p[4] >> 1)
			cur = bytearray(body[9 + hdr_len:])
		elif cur is not None:
			cur.extend(body)

	if cur is not None:
		yield cur_pts, bytes(cur)


def mp2_frame_len(b):
	if len(b) < 4 or b[0] != 0xFF or (b[1] & 0xE0) != 0xE0:
		return None
	if ((b[1] >> 1) & 0x03) != 2:      # Layer II
		return None
	version = (b[1] >> 3) & 0x03
	rate = MP2_RATE[(b[2] >> 2) & 0x03]
	kbps = MP2_BITRATE[(b[2] >> 4) & 0x0F]
	if not rate or not kbps:
		return None
	if version == 2:                   # MPEG-2 halves the sample rate
		rate //= 2
	pad = (b[2] >> 1) & 0x01
	return 144 * kbps * 1000 // rate + pad


def ac3_frame_len(b):
	if len(b) < 7 or b[0] != 0x0B or b[1] != 0x77:
		return None
	fscod = b[4] >> 6
	frmsizecod = b[4] & 0x3F
	if frmsizecod > 37:
		return None
	kbps = AC3_BITRATE[frmsizecod >> 1]
	if fscod == 0:
		return 4 * kbps
	if fscod == 1:
		return 2 * (320 * kbps // 147 + (frmsizecod & 1))
	if fscod == 2:
		return 6 * kbps
	return None


def walk(es, frame_len):
	"""Parse `es` as back-to-back sync frames. Returns (frames, lead, tail)."""
	# The clip may start mid-frame; find the first offset that parses and whose
	# declared length lands on another parsable header.
	start = None
	for i in range(0, min(len(es), 1 << 16)):
		n = frame_len(es[i:])
		if n and (i + n >= len(es) or frame_len(es[i + n:])):
			start = i
			break
	if start is None:
		return [], len(es), b""

	frames, off, gaps = [], start, []
	while off < len(es):
		n = frame_len(es[off:])
		if n and off + n <= len(es):
			frames.append({
				"index": len(frames),
				"es_offset": off,
				"len": n,
				"sha1": hashlib.sha1(es[off:off + n]).hexdigest(),
			})
			off += n
			continue
		if n:                      # declared length runs past the buffer end
			break
		# Lost sync: scan for the next header that a second header confirms, so a
		# capture with one damaged frame still yields the frames after it.
		nxt = None
		for i in range(off + 1, len(es)):
			k = frame_len(es[i:])
			if k and (i + k >= len(es) or frame_len(es[i + k:])):
				nxt = i
				break
		if nxt is None:
			break
		gaps.append({"es_offset": off, "skipped": nxt - off})
		off = nxt
	return frames, start, es[off:], gaps


def main():
	args = [a for a in sys.argv[1:] if not a.startswith("--")]
	flags = {a for a in sys.argv[1:] if a.startswith("--")}
	if len(args) < 3:
		raise SystemExit(__doc__)
	path, pid, codec = args[0], int(args[1], 0), args[2]
	parser = {"mp2": mp2_frame_len, "ac3": ac3_frame_len}.get(codec)
	if parser is None:
		raise SystemExit("codec must be mp2 or ac3")

	es, ptses = bytearray(), []
	for pts, payload in pes_payloads(path, pid):
		if pts is not None:
			ptses.append((len(es), pts))
		es.extend(payload)
	frames, lead, tail, gaps = walk(bytes(es), parser)

	print(f"{path}  pid={pid} ({pid:#x})  codec={codec}")
	print(f"  ES bytes        : {len(es)}")
	print(f"  lead-in skipped : {lead} (bytes before the first whole frame)")
	print(f"  frames          : {len(frames)}")
	print(f"  resync gaps     : {len(gaps)}"
	      + (f"  (skipped {sum(g['skipped'] for g in gaps)} B)" if gaps else ""))
	if frames:
		lens = {f['len'] for f in frames}
		print(f"  frame length(s) : {sorted(lens)}")
		print(f"  first PTS       : {ptses[0][1] if ptses else None}")
		if codec == "mp2":
			prot = sum(1 for f in frames if not (es[f["es_offset"] + 1] & 0x01))
			print(f"  CRC-protected   : {prot}/{len(frames)} frames "
			      f"(MP2 protection_bit == 0 means a CRC follows the header)")
	print(f"  TRAILING PARTIAL: {len(tail)} bytes"
	      f"{'  <-- ends mid-frame, a wrap here splices' if tail else '  (ends clean on a frame boundary)'}")

	out = next((a.split("=", 1)[1] for a in flags if a.startswith("--json=")), None)
	if out:
		json.dump({"path": path, "pid": pid, "codec": codec,
		           "es_bytes": len(es), "lead": lead, "tail": len(tail),
		           "tail_hex": tail[:32].hex(), "frames": frames, "gaps": gaps},
		          open(out, "w"), indent=1)
		print(f"  wrote {out}")


if __name__ == "__main__":
	main()

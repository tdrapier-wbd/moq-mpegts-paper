#!/usr/bin/env python3
"""Per-segment structure of TS-in-HLS segments, against RFC 8216 §3.2.

    t65-seg-structure.py <dir> [<dir> ...]

For every `*.ts` in each directory: the programmes its PAT lists, whether it holds a PAT and a PMT,
whether its first two packets are the PAT and PMT (the RFC's SHOULD), and whether its first video
packet starts a PES with `random_access_indicator` set (opens at a random access point). Prints one
line per segment and a summary per directory; exits 1 if any segment lacks a PAT or PMT, lists more
than one programme, or does not open at a random access point.
"""

import os
import re
import sys

TS = 188
VIDEO_TYPES = (0x01, 0x02, 0x1B, 0x24)


def payload(p):
	afc = p[3] >> 4 & 3
	if not afc & 1:
		return None
	off = 4 + (1 + p[4] if afc & 2 else 0)
	return p[off:] if off < TS else None


def segment(path):
	with open(path, "rb") as f:
		data = f.read()
	pids, programs, pmt, video = [], None, None, None
	has_pmt = False
	for i in range(0, len(data) - TS + 1, TS):
		p = data[i:i + TS]
		pid = (p[1] & 0x1F) << 8 | p[2]
		if len(pids) < 2:
			pids.append(pid)
		pay = payload(p)
		if pay is None or not p[1] & 0x40:
			continue
		s = pay[1 + pay[0]:]
		if pid == 0 and programs is None and s[0] == 0x00:
			end = 3 + ((s[1] & 0xF) << 8 | s[2]) - 4
			progs = [(s[j] << 8 | s[j + 1], (s[j + 2] & 0x1F) << 8 | s[j + 3]) for j in range(8, end, 4)]
			programs = [n for n, _ in progs if n]
			pmt = next((pp for n, pp in progs if n), None)
		elif pid == pmt and s[0] == 0x02:
			has_pmt = True
			if video is None:
				end = 3 + ((s[1] & 0xF) << 8 | s[2]) - 4
				j = 12 + ((s[10] & 0xF) << 8 | s[11])
				while j + 5 <= end:
					if s[j] in VIDEO_TYPES:
						video = (s[j + 1] & 0x1F) << 8 | s[j + 2]
						break
					j += 5 + ((s[j + 3] & 0xF) << 8 | s[j + 4])
	first_video, rap = None, False
	if video is not None:
		for i in range(0, len(data) - TS + 1, TS):
			p = data[i:i + TS]
			if ((p[1] & 0x1F) << 8 | p[2]) == video:
				first_video = i // TS
				rap = bool(p[1] & 0x40 and p[3] & 0x20 and p[4] and p[5] & 0x40)
				break
	return {
		"programs": len(programs or []),
		"pat": programs is not None,
		"pmt": has_pmt,
		"head_pat_pmt": len(pids) == 2 and pids[0] == 0 and pids[1] == pmt,
		"rap": bool(rap),
		"first_video_packet": first_video,
		"packets": len(data) // TS,
	}


def main():
	bad = False
	for d in sys.argv[1:]:
		names = sorted((f for f in os.listdir(d) if f.endswith(".ts")),
				key=lambda f: [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", f)])
		n = head = rap = one = both = 0
		for f in names:
			r = segment(os.path.join(d, f))
			n += 1
			head += r["head_pat_pmt"]
			rap += r["rap"]
			one += r["programs"] == 1
			both += r["pat"] and r["pmt"]
			print(f"{d}/{f}: programs={r['programs']} pat={int(r['pat'])} pmt={int(r['pmt'])} "
					f"head_pat_pmt={int(r['head_pat_pmt'])} rap={int(r['rap'])} "
					f"first_video_packet={r['first_video_packet']} packets={r['packets']}")
		print(f"{d}: {n} segments; one programme {one}; PAT and PMT {both}; "
				f"opens at a RAP {rap}; PAT, PMT first {head}")
		bad |= n == 0 or one < n or both < n or rap < n
	sys.exit(1 if bad else 0)


if __name__ == "__main__":
	main()

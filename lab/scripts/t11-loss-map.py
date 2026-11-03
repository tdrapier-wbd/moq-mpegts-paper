#!/usr/bin/env python3
"""Map each packet a relay capture lacks to the group and object `moq import ts --passthrough`
published it in.

  t11-loss-map.py FIXTURE RECEIVED [RECEIVED ...] [--json OUT]

Groups and objects are recomputed from the fixture with the importer's rule: a group starts at a
packet with random_access_indicator on the video PID, an object at each PCR packet on the PCR PID
and at each group start; bytes before the first group are not published. Each capture is aligned
to the fixture on non-null packets; a fixture packet inside the aligned span with no counterpart is
missing. Missing packets before the first aligned packet are the join, after the last the end.
"""
import argparse
import difflib
import json
import sys


def packets(path):
	data = open(path, "rb").read()
	return [data[i:i + 188] for i in range(0, len(data) - 187, 188) if data[i] == 0x47]


def pid(p):
	return (p[1] & 0x1F) << 8 | p[2]


def layout(pkts):
	"""(PCR PID, video PID) from the first PMT."""
	pmt_pid = None
	for p in pkts:
		if pid(p) == 0 and p[1] & 0x40:
			s = p[5 + p[4]:]
			n = ((s[1] & 0x0F) << 8 | s[2]) - 9
			for i in range(8, 8 + n, 4):
				if (s[i] << 8 | s[i + 1]) != 0:
					pmt_pid = (s[i + 2] & 0x1F) << 8 | s[i + 3]
					break
		elif pmt_pid is not None and pid(p) == pmt_pid and p[1] & 0x40:
			s = p[5 + p[4]:]
			end = 3 + ((s[1] & 0x0F) << 8 | s[2]) - 4
			pcr_pid = (s[8] & 0x1F) << 8 | s[9]
			i = 12 + ((s[10] & 0x0F) << 8 | s[11])
			video = None
			while i < end:
				st, epid, elen = s[i], (s[i + 1] & 0x1F) << 8 | s[i + 2], (s[i + 3] & 0x0F) << 8 | s[i + 4]
				if st in (0x01, 0x02, 0x1B, 0x24) and video is None:
					video = epid
				i += 5 + elen
			return pcr_pid, video
	sys.exit("no PMT in the fixture")


def has_af(p):
	return p[3] & 0x20 and p[4] > 0


def assign(pkts, pcr_pid, video):
	"""[(group, object) or None] per packet, and the object count of each group."""
	out, g, o, objs = [], -1, -1, {}
	for p in pkts:
		q = pid(p)
		rap = q == video and has_af(p) and p[5] & 0x40
		is_pcr = q == pcr_pid and has_af(p) and p[5] & 0x10
		if rap:
			g, o = g + 1, 0
		elif is_pcr and g >= 0:
			o += 1
		if g >= 0:
			objs[g] = o + 1
		out.append((g, o) if g >= 0 else None)
	return out, objs


def describe(p):
	if pid(p) == 0x1FFF:
		return "null"
	kind = "AF-only" if p[3] & 0x30 == 0x20 else ("PUSI" if p[1] & 0x40 else "payload")
	pcr = "+PCR" if has_af(p) and p[5] & 0x10 else ""
	return f"PID {pid(p)} {kind}{pcr}"


def map_capture(fx, where, objs, path):
	rx = packets(path)
	fi = [i for i, p in enumerate(fx) if pid(p) != 0x1FFF and where[i] is not None]
	a = [fx[i] for i in fi]
	b = [p for p in rx if pid(p) != 0x1FFF]
	sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
	blocks = [m for m in sm.get_matching_blocks() if m.size]
	res = dict(file=path, received=len(rx), received_non_null=len(b), missing=[], extra=0)
	if not blocks:
		res["aligned"] = 0
		return res
	first, last = blocks[0].a, blocks[-1].a + blocks[-1].size - 1
	res["join"] = where[fi[first]]
	res["end"] = where[fi[last]]
	res["aligned"] = sum(m.size for m in blocks)
	for tag, a0, a1, b0, b1 in sm.get_opcodes():
		if tag in ("delete", "replace"):
			for k in range(a0, a1):
				if first <= k <= last:
					g, o = where[fi[k]]
					in_obj = [j for j in fi if where[j] == (g, o)]
					res["missing"].append(dict(group=g, object=o, of=objs[g], last_object=o == objs[g] - 1,
											   index=in_obj.index(fi[k]), obj_packets=len(in_obj),
											   what=describe(fx[fi[k]])))
		if tag in ("insert", "replace"):
			res["extra"] += b1 - b0
	return res


def summary(res):
	lines = [f"{res['file']}: {res['received_non_null']} non-null packets, join {res.get('join')}, "
			 f"end {res.get('end')}, {len(res['missing'])} missing inside, {res['extra']} not in the fixture"]
	by_obj = {}
	for m in res["missing"]:
		by_obj.setdefault((m["group"], m["object"]), []).append(m)
	for (g, o), ms in sorted(by_obj.items()):
		whole = len(ms) == ms[0]["obj_packets"]
		tail = "last object" if ms[0]["last_object"] else f"object {o} of {ms[0]['of']}"
		kinds = ", ".join(sorted({m["what"] for m in ms}))
		lost = "whole object" if whole else f"{len(ms)} of {ms[0]['obj_packets']} packets"
		lines.append(f"  group {g} {tail}: {lost} ({kinds})")
	return "\n".join(lines)


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("fixture")
	ap.add_argument("received", nargs="+")
	ap.add_argument("--json", default=None)
	args = ap.parse_args()
	fx = packets(args.fixture)
	pcr_pid, video = layout(fx)
	where, objs = assign(fx, pcr_pid, video)
	print(f"fixture: {len(fx)} packets, PCR PID {pcr_pid}, video PID {video}, {len(objs)} groups, "
		  f"{min(objs.values())}-{max(objs.values())} objects each")
	out = [map_capture(fx, where, objs, r) for r in args.received]
	for r in out:
		print(summary(r))
	if args.json:
		json.dump(out, open(args.json, "w"), indent=1)


if __name__ == "__main__":
	main()

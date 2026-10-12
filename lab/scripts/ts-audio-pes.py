#!/usr/bin/env python3
"""Grade one audio PID's PES framing, timestamps and frames, optionally against a source.

Per PES on the PID: whether data_alignment_indicator is set, whether the
payload starts on a frame boundary, and its PTS. Frames are walked with
ts-audio-frames.py's parser. Each PES's PTS belongs to the first frame that
starts in its payload, and two consecutive stamped frames must be exactly the
frames between them apart (MP2 1152 samples, AC-3 1536, at the stream's rate).

With --source, the file's frames are matched to the source's by content hash:
in order, none missing or repeated between the first and last frame, except
within --tail-s of the end (a stopping source loses its last frames).

usage: ts-audio-pes.py <file.ts> <pid> {mp2|ac3} [--source <src.ts>] [--tail-s 1.0] [--json <out>]
"""

import argparse
import importlib.util
import json
import os

TS_PACKET = 188
SAMPLES = {"mp2": 1152, "ac3": 1536}
MP2_RATE = [44100, 48000, 32000, 0]
AC3_RATE = [48000, 44100, 32000, 0]
PTS_WRAP = 1 << 33

_spec = importlib.util.spec_from_file_location(
	"ts_audio_frames", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ts-audio-frames.py"))
taf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(taf)


def pes_list(path, pid):
	"""Return (es, [{es_offset, aligned, pts}]) for every PES started on `pid`."""
	data = open(path, "rb").read()
	es, pes, started = bytearray(), [], False
	for off in range(0, len(data) - TS_PACKET + 1, TS_PACKET):
		pkt = data[off:off + TS_PACKET]
		if pkt[0] != 0x47 or ((pkt[1] << 8 | pkt[2]) & 0x1FFF) != pid:
			continue
		afc = (pkt[3] >> 4) & 0x03
		i = 4
		if afc in (2, 3):
			i += 1 + pkt[4]
		if afc == 2 or i >= TS_PACKET:
			continue
		body = pkt[i:]
		if pkt[1] & 0x40:
			if len(body) < 9 or body[0:3] != b"\x00\x00\x01":
				started = False
				continue
			hdr_len = body[8]
			pts = None
			if body[7] & 0x80 and hdr_len >= 5:
				p = body[9:14]
				pts = (((p[0] >> 1) & 0x07) << 30 | p[1] << 22 |
				       (p[2] >> 1) << 15 | p[3] << 7 | p[4] >> 1)
			pes.append({"es_offset": len(es), "aligned": bool(body[6] & 0x04), "pts": pts})
			es.extend(body[9 + hdr_len:])
			started = True
		elif started:
			es.extend(body)
	return bytes(es), pes


def frame_ticks(codec, es, frame):
	b = es[frame["es_offset"]:frame["es_offset"] + 5]
	rate = MP2_RATE[(b[2] >> 2) & 0x03] if codec == "mp2" else AC3_RATE[b[4] >> 6]
	if not rate or SAMPLES[codec] * 90000 % rate:
		raise SystemExit(f"unsupported sample rate {rate}")
	return SAMPLES[codec] * 90000 // rate


def grade_pes(codec, es, pes, frames):
	starts = [f["es_offset"] for f in frames]
	index_at = {o: k for k, o in enumerate(starts)}
	out = {"pes": len(pes), "flagged": 0, "flagged_unaligned": 0, "unflagged_aligned": 0,
	       "pts_without_frame": 0, "steps": 0, "off_steps": 0, "dup_pts": 0, "max_dev": 0,
	       "first_unaligned": None, "first_off_step": None}
	stamped, k = [], 0
	for n, p in enumerate(pes):
		at_frame = p["es_offset"] in index_at
		if p["aligned"]:
			out["flagged"] += 1
			if not at_frame:
				out["flagged_unaligned"] += 1
				if out["first_unaligned"] is None:
					out["first_unaligned"] = {"pes": n, "es_offset": p["es_offset"], "pts": p["pts"]}
		elif at_frame:
			out["unflagged_aligned"] += 1
		if p["pts"] is None:
			continue
		end = pes[n + 1]["es_offset"] if n + 1 < len(pes) else len(es)
		while k < len(starts) and starts[k] < p["es_offset"]:
			k += 1
		if k < len(starts) and starts[k] < end:
			stamped.append((k, p["pts"], n))
		else:
			out["pts_without_frame"] += 1
	if not frames:
		return out
	tick = frame_ticks(codec, es, frames[0])
	out["frame_ticks"] = tick
	for (fa, pa, _), (fb, pb, nb) in zip(stamped, stamped[1:]):
		delta = (pb - pa) % PTS_WRAP
		dev = delta - (fb - fa) * tick
		out["steps"] += 1
		if delta == 0:
			out["dup_pts"] += 1
		if dev:
			out["off_steps"] += 1
			out["max_dev"] = max(out["max_dev"], abs(dev))
			if out["first_off_step"] is None:
				out["first_off_step"] = {"pes": nb, "pts": pb, "dev_ticks": dev, "frames_between": fb - fa}
	return out


def match_source(frames, src_frames, tail_n, run=8, look=400):
	"""Walk the file's frames against the source's in order by hash."""
	h, s = [f["sha1"] for f in frames], [f["sha1"] for f in src_frames]
	res = {"frames": len(h), "matched": 0, "missing": 0, "repeated_or_foreign": 0,
	       "missing_in_tail": 0, "first_fault": None, "anchored": False}

	def runs_equal(i, j):
		return h[i:i + run] == s[j:j + run] and len(h[i:i + run]) == min(run, len(h) - i)

	j = next((j for j in range(len(s)) if runs_equal(0, j)), None)
	if j is None:
		return res
	res["anchored"], res["source_start"] = True, j
	i = 0
	while i < len(h) and j < len(s):
		if h[i] == s[j]:
			res["matched"] += 1
			i += 1
			j += 1
			continue
		in_tail = i >= len(h) - tail_n
		skip = next((d for d in range(1, look) if j + d < len(s) and runs_equal(i, j + d)), None)
		if skip is not None:
			res["missing_in_tail" if in_tail else "missing"] += skip
			if not in_tail and res["first_fault"] is None:
				res["first_fault"] = {"frame": i, "kind": "missing", "count": skip}
			j += skip
			continue
		res["repeated_or_foreign"] += 1
		if res["first_fault"] is None:
			res["first_fault"] = {"frame": i, "kind": "repeated_or_foreign"}
		i += 1
	return res


def main():
	ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
	ap.add_argument("file")
	ap.add_argument("pid", type=lambda v: int(v, 0))
	ap.add_argument("codec", choices=["mp2", "ac3"])
	ap.add_argument("--source")
	ap.add_argument("--tail-s", type=float, default=1.0)
	ap.add_argument("--json")
	a = ap.parse_args()
	frame_len = taf.mp2_frame_len if a.codec == "mp2" else taf.ac3_frame_len

	es, pes = pes_list(a.file, a.pid)
	frames, lead, _tail, gaps = taf.walk(es, frame_len)
	report = {"file": a.file, "pid": a.pid, "codec": a.codec, "lead_bytes": lead,
	          "sync_gaps": len(gaps), **grade_pes(a.codec, es, pes, frames)}
	print(f"{a.file} pid {a.pid:#x} {a.codec}: {len(pes)} PES, {len(frames)} frames, "
	      f"{len(gaps)} sync gaps; flagged aligned {report['flagged']} "
	      f"(of which not on a frame start {report['flagged_unaligned']}), "
	      f"unflagged on a frame start {report['unflagged_aligned']}")
	print(f"  PTS: {report['steps']} steps, {report['off_steps']} off the frame count "
	      f"(max {report['max_dev']} ticks), {report['dup_pts']} duplicates, "
	      f"{report['pts_without_frame']} PTS with no frame start")
	if report["first_unaligned"]:
		print(f"  first flagged-unaligned PES: {report['first_unaligned']}")
	if report["first_off_step"]:
		print(f"  first off step: {report['first_off_step']}")

	if a.source:
		s_es, _ = pes_list(a.source, a.pid)
		s_frames, *_ = taf.walk(s_es, frame_len)
		tick = report.get("frame_ticks") or 2160
		tail_n = int(a.tail_s * 90000 / tick + 0.999)
		m = match_source(frames, s_frames, tail_n)
		report["source_match"] = m
		print(f"  vs source: anchored {m['anchored']}, matched {m['matched']} of {m['frames']}, "
		      f"missing {m['missing']} (+{m['missing_in_tail']} in the last {a.tail_s:g} s), "
		      f"repeated or foreign {m['repeated_or_foreign']}; first fault {m['first_fault']}")

	if a.json:
		with open(a.json, "w") as f:
			json.dump(report, f, indent=1)


if __name__ == "__main__":
	main()

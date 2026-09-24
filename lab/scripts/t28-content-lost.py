#!/usr/bin/env python3
"""Programme lost or duplicated in a TS capture, measured on the content's own clock.

`t28-media-lost.py` derives loss from the PCR timeline, and on `moq export ts` output the PCR
timeline does not carry the loss. MoQ delivers each elementary stream as its own track, and
under congestion the video track's groups are evicted while audio carries on; the exporter
keeps writing PCR -- adaptation-only packets on the video PID, at its 25 ms cadence -- straight
across the missing pictures. On one unpadded chronic-congestion capture the PCR grader scored
0.775 s lost where the video timeline has 36.4 s of holes, the picture count implies about 35 s
and the subscriber logged 22 group evictions. Padding (`export ts` pads to the catalog's
`mpegts.muxRate` from moq-dev #3831 onward) adds a second blindness on top, for the `file`
domain: the nulls make the bytes between two PCRs add up to the nominal rate.

This grader measures what neither the clock nor the padding can manufacture: the presentation
timestamps of the access units themselves, video by default, with the busiest audio track
graded beside it because the two do not fail together. Sorted, they sit one picture period apart in media time. Where
the sorted sequence jumps by more than a period, the pictures in between were never
delivered; where a value appears twice, a picture was repeated. Nulls, PCR-only packets and
re-synthesised tables carry no access units and so cannot close a hole or open one.

    content lost (s) = sum over adjacent sorted PTS values of  max(0, dt - nominal step)
                       counted where the excess exceeds the tolerance

**PTS, not DTS, and sorted rather than in arrival order.** `moq export ts` does not carry the
source's DTS: it authors one, as a saw on reordered content with each B-picture nudged a single
90 kHz tick past the previous DTS (T18; moq-dev #2967). Several consecutive access units
therefore carry DTS values 11 us apart, and a DTS-based grader reads them as one picture
followed by a 300 ms hole -- it scored 62.8 s lost on an unpadded 90 s capture that the PCR
grader and the picture count both call nearly clean. PTS is the one content clock the exporter
passes through. Sorting within a segment removes B-picture reordering, which in arrival order
is a backward step of up to the reorder depth.

The nominal step is the longest step that is *regular* -- one taking at least 5 % of all
steps -- rather than the median. Broadcast H.264 mixes field and frame pictures, so on the
campaign's fixture access units step 20 ms and 40 ms (872 and 321 of 1,193 steps); a median
nominal of 20 ms would score every ordinary 40 ms step as 20 ms lost and overstate each real
hole by up to a frame. Like the PCR grader's median, it is chosen so the holes being measured
cannot move their own reference.

In arrival order, a backward step larger than --discontinuity-s is a timeline discontinuity
(a looped source, a re-anchor), not reordering; the capture is split there into segments, each
sorted and graded on its own, and the joins are counted rather than scored.

Reordering also makes a capture's edges ragged in presentation order, and splits one real hole
into a main gap flanked by small ones; gaps within the measured reorder window of a segment's
ends are ignored unless longer than it, and gaps closer together than it are one hole. Each gap
is charged the duration of the picture before it, estimated from the step into that picture,
so a field followed by a hole is not charged a frame.

Resolution is one field (20 ms on the fixture), well inside T28's 100 ms tolerance; a hole
reads up to one field short, never long. Every `moq export ts` capture opens with a real
join hole -- the tail of one group, then the next -- so ladder cells grade with `--from-s`.

**Holes are measured between pictures that arrived, so a capture whose picture stops early
reads clean.** At a 0.5 s budget under 5 % loss the subscriber evicted every video group for the
last 26 s of a 60 s window and this grader scored 2.76 s lost. `content_present_s` and
`timeline_advance_s` are reported so a caller can conserve against a clean cell of the same
window; `t2831-conservation.py` does that for the ladders, and its figure, not `content_lost_s`,
is the programme lost.

Usage:
    t28-content-lost.py --input capture.ts [--pid 111] [--tolerance-ms 100] [--from-s 8]
                        [--json out.json]

Validate with `t28-content-selftest.sh` before quoting a figure from it; that script also
demonstrates the padding blindness this grader exists to avoid.
"""

import argparse
import json
import statistics
import sys
from collections import Counter
from pathlib import Path

TS = 188
NULL_PID = 0x1FFF
PTS_HZ = 90_000
PTS_MODULUS = 1 << 33


def read_ts(path: Path) -> bytes:
	data = path.read_bytes()
	# Captures here are written packet-aligned; find the first offset where three successive
	# sync bytes line up rather than assume it, so a truncated head does not shift every packet.
	for off in range(min(TS, len(data))):
		if all(off + k * TS < len(data) and data[off + k * TS] == 0x47 for k in range(3)):
			return data[off:]
	raise SystemExit(f"{path}: no transport-stream sync found")


def pes_kind(stream_id: int) -> str | None:
	if 0xE0 <= stream_id <= 0xEF:
		return "video"
	if 0xC0 <= stream_id <= 0xDF or stream_id == 0xBD:
		return "audio"
	return None


def pes_timestamp(payload: bytes) -> tuple[str, int] | None:
	"""(kind, PTS) of an audio or video PES packet; None if it carries none."""
	if len(payload) < 14 or payload[0:3] != b"\x00\x00\x01":
		return None
	kind = pes_kind(payload[3])
	if kind is None:
		return None
	flags = payload[7] >> 6
	if flags not in (2, 3):
		return None

	b = payload[9:14]
	return kind, ((b[0] >> 1) & 0x07) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | (b[4] >> 1)


def scan(data: bytes, want_pid: int | None) -> dict:
	counts: dict[int, int] = {}
	stamps: dict[int, list[int]] = {}
	kinds: dict[int, str] = {}
	for off in range(0, len(data) - TS + 1, TS):
		pkt = data[off : off + TS]
		if pkt[0] != 0x47:
			continue
		pid = ((pkt[1] & 0x1F) << 8) | pkt[2]
		counts[pid] = counts.get(pid, 0) + 1
		if not pkt[1] & 0x40:
			continue
		afc = (pkt[3] >> 4) & 0x03
		if not afc & 0x01:
			continue
		start = 4 + (1 + pkt[4] if afc & 0x02 else 0)
		if start >= TS:
			continue
		found = pes_timestamp(pkt[start:])
		if found is not None:
			kinds[pid] = found[0]
			stamps.setdefault(pid, []).append(found[1])

	def busiest(kind: str) -> int | None:
		pids = [p for p in stamps if kinds[p] == kind]
		return max(pids, key=lambda p: len(stamps[p])) if pids else None

	pid = want_pid if want_pid is not None else busiest("video")
	if pid is None or pid not in stamps:
		raise SystemExit(f"PID {pid} carries no PES timestamps; candidates: {sorted(stamps)}")
	audio = busiest("audio")
	return {
		"pid": pid,
		"stamps": stamps[pid],
		"audio_pid": audio,
		"audio_stamps": stamps.get(audio, []),
		"counts": counts,
	}


def unwrap(raw: list[int]) -> list[float]:
	out, base, prev = [], 0, None
	for v in raw:
		if prev is not None and v - prev < -(PTS_MODULUS // 2):
			base += PTS_MODULUS
		prev = v
		out.append((v + base) / PTS_HZ)
	return out


def nominal_regular(steps: list[float]) -> list[float]:
	"""The steps, to the millisecond, that at least 5 % of all steps take."""
	ms = Counter(round(s * 1000) for s in steps)
	regular = [k / 1000.0 for k, n in ms.items() if n >= 0.05 * len(steps)]
	return regular or [statistics.median(steps)]


def nominal_step(steps: list[float]) -> float:
	"""The longest regular step: what one ordinary picture advances the timeline by."""
	return max(nominal_regular(steps))


def segments(t: list[float], discontinuity_s: float) -> list[list[float]]:
	"""Split arrival-order PTS where it falls further behind its running maximum than any
	reordering could put it; each piece is one continuous timeline."""
	out: list[list[float]] = [[t[0]]]
	peak = t[0]
	for cur in t[1:]:
		if cur < peak - discontinuity_s:
			out.append([cur])
			peak = cur
			continue
		out[-1].append(cur)
		peak = max(peak, cur)
	return out


def reorder_depth(seg: list[float]) -> float:
	"""How far behind its running maximum arrival-order PTS ever falls: the B-picture depth."""
	peak, depth = seg[0], 0.0
	for cur in seg[1:]:
		depth = max(depth, peak - cur)
		peak = max(peak, cur)
	return depth


def grade(t: list[float], tolerance_s: float, discontinuity_s: float, from_s: float = 0.0) -> dict:
	raw = segments(t, discontinuity_s)
	if from_s > 0:
		# A subscriber joins on the tail of one group and jumps to the next, which is a real hole
		# and is in every capture, impaired or not. Grading from past it charges the impairment
		# with the impairment's cost only; the join itself is the control's business.
		start = min(raw[0]) + from_s
		raw[0] = [x for x in raw[0] if x >= start]
		raw = [s for s in raw if s]
	segs = [sorted(s) for s in raw]
	uniq = [sorted(set(s)) for s in segs]
	steps = [b - a for u in uniq for a, b in zip(u, u[1:])]
	if not steps:
		raise SystemExit("fewer than two distinct access units")
	nominal = nominal_step(steps)
	# Reordering makes a capture's edges ragged in presentation order: one that stops mid-GOP has
	# its last P-picture and not the B-pictures before it. The same raggedness splits one real
	# hole into a main gap flanked by small ones. So a gap inside the reorder window of a segment's
	# ends is ignored if it is no longer than that window -- raggedness cannot open a longer one --
	# and gaps closer together than the window are one hole.
	window = max((reorder_depth(s) for s in raw), default=0.0) + nominal
	lost = lost_all = 0.0
	holes: list[float] = []
	shortest = min(nominal_regular(steps))
	for u in uniq:
		# A gap from a to b is missing everything after a's own duration. That duration is not
		# in the capture, but the step into a is the best estimate of it -- a field follows a
		# field -- clamped to the stream's regular steps so a hole cannot vouch for itself.
		gaps = []
		for k in range(len(u) - 1):
			a, b = u[k], u[k + 1]
			own = min(nominal, max(shortest, u[k] - u[k - 1])) if k else nominal
			# Only a step longer than every regular step is a gap; an ordinary 40 ms step after a
			# 20 ms field is the stream's cadence, and admitting it would chain across the capture.
			if b - a > nominal + 0.001:
				gaps.append((a, b, b - a - own))
		gaps = [
			g for g in gaps
			if g[1] - g[0] > window or (g[0] >= u[0] + window and g[1] <= u[-1] - window)
		]
		clusters: list[list[tuple[float, float, float]]] = []
		for g in gaps:
			if clusters and g[0] - clusters[-1][-1][1] <= window:
				clusters[-1].append(g)
			else:
				clusters.append([g])
		for c in clusters:
			excess = sum(g[2] for g in c)
			lost_all += excess
			if excess > tolerance_s:
				lost += excess
				holes.append(excess)
	advance = sum(steps)
	frames = len(t)
	repeats = sum(len(s) - len(u) for s, u in zip(segs, uniq))
	discontinuities = len(segs) - 1
	# A repeated access unit is charged its average duration, which is what one AU of this
	# stream carries once fields and frames are averaged together.
	per_au = advance / max(1, len(steps))
	return {
		"access_units": frames,
		"nominal_step_s": round(nominal, 6),
		"reorder_window_s": round(window, 3),
		"timeline_advance_s": round(advance, 3),
		"content_present_s": round(advance - lost_all, 3),
		"content_lost_s": round(lost, 3),
		"content_lost_all_s": round(lost_all, 3),
		"holes": len(holes),
		"largest_hole_s": round(max(holes), 3) if holes else 0.0,
		"repeated_access_units": repeats,
		"content_dup_s": round(repeats * per_au, 3),
		"discontinuities": discontinuities,
	}


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	ap.add_argument("--input", type=Path, required=True)
	ap.add_argument("--pid", type=int, default=None, help="PES PID to grade (default: the busiest video PID)")
	ap.add_argument("--tolerance-ms", type=float, default=100.0)
	ap.add_argument("--discontinuity-s", type=float, default=1.0)
	ap.add_argument("--from-s", type=float, default=0.0, help="grade from this far into the timeline")
	ap.add_argument("--label", default=None)
	ap.add_argument("--json", type=Path, default=None)
	args = ap.parse_args()

	data = read_ts(args.input)
	s = scan(data, args.pid)
	result = grade(unwrap(s["stamps"]), args.tolerance_ms / 1000.0, args.discontinuity_s, args.from_s)
	total = sum(s["counts"].values())
	nulls = s["counts"].get(NULL_PID, 0)
	# The busiest audio track is graded beside the picture because MoQ carries each elementary
	# stream as its own track, and under congestion they do not fail together: video groups are
	# evicted while audio, and the clock, carry on.
	if len(set(s["audio_stamps"])) >= 3:
		a = grade(unwrap(s["audio_stamps"]), args.tolerance_ms / 1000.0, args.discontinuity_s, args.from_s)
		result.update(
			{
				"audio_pid": s["audio_pid"],
				"audio_lost_s": a["content_lost_s"],
				"audio_holes": a["holes"],
				"audio_largest_hole_s": a["largest_hole_s"],
				"audio_advance_s": a["timeline_advance_s"],
				"audio_present_s": a["content_present_s"],
			}
		)
	result.update(
		{
			"label": args.label or args.input.name,
			"video_pid": s["pid"],
			"video_packets": s["counts"].get(s["pid"], 0),
			"null_packets": nulls,
			"total_packets": total,
			"null_pct": round(100.0 * nulls / total, 2) if total else 0.0,
			"domain": "content",
		}
	)
	if args.json:
		args.json.write_text(json.dumps(result, indent=2) + "\n")
	print(
		f"{result['label']}: content lost {result['content_lost_s']:.3f} s in {result['holes']} hole(s)"
		f" (largest {result['largest_hole_s']:.3f} s), dup {result['content_dup_s']:.3f} s,"
		f" {result['discontinuities']} discontinuities, nulls {result['null_pct']:.1f} %"
		+ (f"; audio PID {result['audio_pid']} lost {result['audio_lost_s']:.3f} s" if "audio_pid" in result else "")
	)
	return 0


if __name__ == "__main__":
	sys.exit(main())

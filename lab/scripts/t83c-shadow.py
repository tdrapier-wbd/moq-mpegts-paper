#!/usr/bin/env python3
"""T83 Part C's shadow grader: what each leg of the live feed lacks against the reference leg.

  t83c-shadow.py units < TS                       one line per complete unit, for the matcher
  t83c-shadow.py drop --log FILE [--every N] [--blackout-every S] [--blackout S] < TS > TS
  t83c-shadow.py match --out DIR --ref rx --leg NAME=CMD|NAME=@FIFO ... [--influx PORT] [--hold 60]
                       [--warmup 120] [--hours 72] [--pts-slack 2] [--log-units LEG,...] [--once]
  t83c-shadow.py controls DIR --copy rxcopy --cut rxcut --drop-log FILE [--all]

A unit is, on a PID the PMT lists: one audio frame (MPEG audio, AC-3, E-AC-3 or ADTS AAC), cut from
the PID's elementary stream wherever its PES begin and end; one PES on any other PID; or one SCTE-35
section. A frame or PES is keyed by PID and PTS, a section by its CRC. The digest is the BLAKE2b of
the frame, or of the elementary-stream bytes after the PES header (to the PES length, when it has
one), so a leg that re-multiplexes (other packet and PES boundaries, stuffing, header fields) matches
where the media is the same; an H.264 or HEVC PES's leaves out its delimiters, parameter sets and
filler, which a leg that keeps them out of band re-emits in its own order. A frame takes the PTS
of the PES it starts in if it is the first to start there, else its predecessor's plus the
predecessor's duration; after a resynchronisation, the PES's PTS plus one duration per frame length
from the PES's first frame. An audio PID with no frame
in its first 64 KiB is cut by PES. A packet repeating its predecessor's continuity counter and
payload is a duplicate and is skipped. Each PID's kind comes from its stream type, or from its
descriptors when the type is private (0x06): video, audio, scte35 or other. Nothing is stored but
the units' keys and digests, for --hold seconds.

units prints "u PID KEY LEN DIGEST KIND [d]" (d: a continuity error inside it), "m PID TYPE KIND"
when the PMT lists a PID, and "s PACKETS SYNCLOSS DUPS" every 10 s.

drop removes whole PES at known places, for the negative control: every --every-th PES of each video
and audio PID, and every packet for --blackout seconds each --blackout-every seconds of wall time,
with the rest of each PES that starts inside it. It cuts units from what it reads as units does, and
logs "T FATE PID KEY KIND" for each video or audio unit it touched: removed (a PES, or a frame whose
header it removed), damaged (one that lost other bytes) or swallowed (a frame whose header falls
inside the bytes a damaged frame before it spans on the cut stream).

match runs each leg's command (its stdout units' lines, restarted 2 s after it exits) or reads a
FIFO (held open for writing too, so a writer's restart is no EOF), and holds each unit --hold s from
its first sighting on any leg. A video, audio or other unit joins one up to --pts-slack 90 kHz ticks
from its PTS (from the reference's, once the reference has it). Then, for every leg against the
reference: matched (same digest), altered (same key, other digest), missing (the reference has it,
the leg not) or extra (the leg has it, the reference not). Units first seen in the first --warmup s
or the last --hold s are not graded. TSDuck's
`-P influx --tr-101-290 --bucket LEG --host-url http://127.0.0.1:PORT` posts reach --influx, and
the rise of each priority 1 to 3 counter is taken per leg and per hour. Writes DIR/hours.csv (a row per
leg per hour), DIR/events.jsonl (each run of missing, altered or extra units, every such unit of the
--log-units legs, leg starts and exits, counter rises) and DIR/status.json every minute. --once:
the legs are files; nothing restarts, and everything is graded when every leg has ended.

controls grades criterion 9: the copy has no unit unmatched; the cut lacks every unit the dropper
removed or swallowed inside the graded window and lacks or alters every one it damaged there, and
names no unit the dropper did not touch.
"""
import argparse
import collections
import hashlib
import http.server
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import threading
import time
import urllib.parse

VIDEO_TYPES = {0x01, 0x02, 0x10, 0x1B, 0x20, 0x24, 0x42, 0xD1, 0xEA}
AUDIO_TYPES = {0x03, 0x04, 0x0F, 0x11, 0x1C, 0x81, 0x87}
NO_PES_IDS = {0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xF2, 0xF8, 0xFF}
PTS_WRAP = 1 << 33
# NAL unit types a video digest leaves out, by stream type: delimiters, parameter sets, filler
NAL_SKIP = {0x1B: (False, {7, 8, 9, 12}), 0x24: (True, {32, 33, 34, 35, 38})}

MPA_KBPS = {  # (MPEG-1, layer) -> kb/s by bitrate index
	(True, 1): (0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448),
	(True, 2): (0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384),
	(True, 3): (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320),
	(False, 1): (0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256),
	(False, 2): (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160),
}
MPA_KBPS[(False, 3)] = MPA_KBPS[(False, 2)]
MPA_RATES = {3: (44100, 48000, 32000), 2: (22050, 24000, 16000), 0: (11025, 12000, 8000)}
AC3_WORDS = (  # 16-bit words per frame by frmsizecod, at 48, 44.1 and 32 kHz
	(64, 69, 96), (64, 70, 96), (80, 87, 120), (80, 88, 120), (96, 104, 144), (96, 105, 144),
	(112, 121, 168), (112, 122, 168), (128, 139, 192), (128, 140, 192), (160, 174, 240),
	(160, 175, 240), (192, 208, 288), (192, 209, 288), (224, 243, 336), (224, 244, 336),
	(256, 278, 384), (256, 279, 384), (320, 348, 480), (320, 349, 480), (384, 417, 576),
	(384, 418, 576), (448, 487, 672), (448, 488, 672), (512, 557, 768), (512, 558, 768),
	(640, 696, 960), (640, 697, 960), (768, 835, 1152), (768, 836, 1152), (896, 975, 1344),
	(896, 976, 1344), (1024, 1114, 1536), (1024, 1115, 1536), (1152, 1253, 1728),
	(1152, 1254, 1728), (1280, 1393, 1920), (1280, 1394, 1920))
AC3_RATES = (48000, 44100, 32000)
ADTS_RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)


def pes_head(h):
	"""(PTS or None, header length, ES length or None) of a PES whose start code opens h, or None."""
	if len(h) < 9 or h[:3] != b"\x00\x00\x01" or h[3] in NO_PES_IDS:
		return None
	pts = None
	if h[7] & 0x80 and len(h) >= 14:
		pts = ((h[9] >> 1) & 7) << 30 | h[10] << 22 | (h[11] >> 1) << 15 | h[12] << 7 | h[13] >> 1
	hl = 9 + h[8]
	plen = h[4] << 8 | h[5]
	return pts, hl, (plen + 6 - hl if plen else None)


def nal_digest(es, hevc, skip):
	"""BLAKE2b of an Annex B elementary stream's NAL units, less those of the skipped types."""
	h = hashlib.blake2b(digest_size=8)
	i = es.find(b"\x00\x00\x01")
	if i < 0:
		h.update(es)
	while 0 <= i < len(es) - 3:
		j = es.find(b"\x00\x00\x01", i + 3)
		t = (es[i + 3] >> 1) & 0x3F if hevc else es[i + 3] & 0x1F
		if t not in skip:
			h.update(bytes(es[i + 3:len(es) if j < 0 else j]).rstrip(b"\x00"))
		i = j
	return h.hexdigest()


def frame_head(b, i):
	"""(codec, length, duration in 90 kHz ticks) of the audio frame header at b[i]; None if there is
	none, False if b ends first."""
	if len(b) - i < 7:
		return False
	b1, b2 = b[i + 1], b[i + 2]
	if b[i] == 0x0B and b1 == 0x77:
		bsid, fscod = b[i + 5] >> 3, b[i + 4] >> 6
		if bsid <= 10:
			code = b[i + 4] & 0x3F
			if fscod == 3 or code >= len(AC3_WORDS):
				return None
			return "ac3", 2 * AC3_WORDS[code][fscod], 1536 * 90000 / AC3_RATES[fscod]
		if bsid > 16:
			return None
		if fscod == 3:
			fs2 = (b[i + 4] >> 4) & 3
			if fs2 == 3:
				return None
			rate, blocks = (24000, 22050, 16000)[fs2], 6
		else:
			rate, blocks = AC3_RATES[fscod], (1, 2, 3, 6)[(b[i + 4] >> 4) & 3]
		return "eac3", 2 * (((b2 & 7) << 8 | b[i + 3]) + 1), 256 * blocks * 90000 / rate
	if b[i] != 0xFF or b1 & 0xE0 != 0xE0:
		return None
	layer = (b1 >> 1) & 3
	if layer == 0:
		if b1 & 0xF0 != 0xF0 or (b2 >> 2) & 0xF >= len(ADTS_RATES):
			return None
		n = (b[i + 3] & 3) << 11 | b[i + 4] << 3 | b[i + 5] >> 5
		return ("adts", n, 1024 * ((b[i + 6] & 3) + 1) * 90000 / ADTS_RATES[(b2 >> 2) & 0xF]) if n >= 7 else None
	ver, layer = (b1 >> 3) & 3, 4 - layer
	bri, fsi = b2 >> 4, (b2 >> 2) & 3
	if ver == 1 or bri in (0, 15) or fsi == 3:
		return None
	mpeg1 = ver == 3
	bps, rate, pad = MPA_KBPS[(mpeg1, layer)][bri] * 1000, MPA_RATES[ver][fsi], (b2 >> 1) & 1
	if layer == 1:
		return "mpa", (12 * bps // rate + pad) * 4, 384 * 90000 / rate
	long = layer == 2 or mpeg1
	return "mpa", (144 if long else 72) * bps // rate + pad, (1152 if long else 576) * 90000 / rate


class Framer:
	"""One audio PID's frames, cut from its elementary stream. The dropper also passes the stream
	ranges it removed, and each frame's fate on the cut stream comes back with it."""

	def __init__(self):
		self.buf = bytearray()
		self.base = 0  # stream offset of buf[0]
		self.pos = 0  # stream offset of the next frame
		self.marks = collections.deque()  # [stream offset of a PES, its PTS, offset of its first frame]
		self.codec = None
		self.prev = None  # (PTS, duration, length) of the last frame
		self.resync = True
		self.pes = False
		self.dmg = collections.deque()  # stream ranges with a continuity error
		self.cut = collections.deque()  # stream ranges the dropper removed
		self.cut_before = 0
		self.overrun = -1  # cut-stream offset the last damaged frame spans to

	def add(self, es, pts, damaged, cuts=(), fate=None):
		if self.pes:
			if pts is None:
				return []
			return [(pts, hashlib.blake2b(es, digest_size=8).hexdigest(), len(es), damaged, fate)]
		start = self.base + len(self.buf)
		if pts is not None:
			self.marks.append([start, pts, None])
		self.buf += es
		if damaged:
			self.dmg.append((start, start + len(es)))
		for s, e in cuts:
			s, e = start + s, start + e
			if self.cut and self.cut[-1][1] == s:
				self.cut[-1] = (self.cut[-1][0], e)
			else:
				self.cut.append((s, e))
		out = self.frames()
		if self.codec is None and start + len(es) > 65536:
			self.pes, self.buf = True, bytearray()
		return out

	def sync(self, b, i):
		if self.codec in ("mpa", "adts"):
			return b.find(b"\xff", i)
		if self.codec:
			return b.find(b"\x0b\x77", i)
		found = [j for j in (b.find(b"\xff", i), b.find(b"\x0b\x77", i)) if j >= 0]
		return min(found) if found else -1

	def frames(self):
		out, b = [], self.buf
		while True:
			i = self.pos - self.base
			h = frame_head(b, i)
			if h is False:
				break
			ok = h is not None and h[0] == (self.codec or h[0])
			if ok and len(b) < i + h[1]:
				break
			if ok and (self.resync or self.prev is None or abs(h[1] - self.prev[2]) > 1):
				nxt = frame_head(b, i + h[1])
				if nxt is False:
					break
				ok = nxt is not None and nxt[0] == h[0]
			if not ok:
				j = self.sync(b, i + 1)
				self.pos = self.base + (j if j >= 0 else max(i + 1, len(b) - 1))
				self.resync = True
				if j < 0:
					break
				continue
			codec, n, dur = h
			self.codec = codec
			o = self.pos
			pts = self.stamp(o, n, dur)
			fate = self.fate(o, n)
			if pts is not None:
				out.append((int(round(pts)) % PTS_WRAP, hashlib.blake2b(b[i:i + n], digest_size=8).hexdigest(), n,
							self.damaged(o, n), fate))
			self.pos = o + n
		if self.pos > self.base:
			del b[:self.pos - self.base]
			self.base = self.pos
		return out

	def stamp(self, o, n, dur):
		marks = self.marks
		while len(marks) > 1 and marks[1][0] <= o:
			marks.popleft()
		m = marks[0] if marks and marks[0][0] <= o else None
		if m is not None and m[2] is None:
			k = (o - m[0]) // n if self.resync else 0
			m[2] = o - k * n
			pts = m[1] + k * dur
		elif m is not None and self.resync:
			pts = m[1] + round((o - m[2]) / n) * dur
		elif self.prev is not None:
			pts = self.prev[0] + self.prev[1]
		else:
			pts = None
		self.resync = False
		self.prev = None if pts is None else (pts, dur, n)
		return pts

	def damaged(self, o, n):
		while self.dmg and self.dmg[0][1] <= o:
			self.dmg.popleft()
		return any(s < o + n and e > o for s, e in self.dmg)

	def fate(self, o, n):
		cut = self.cut
		while cut and cut[0][1] <= o:
			s, e = cut.popleft()
			self.cut_before += e - s
		c = o - self.cut_before - sum(min(e, o) - s for s, e in cut if s < o)
		hl = 4 if self.codec == "mpa" else 7
		if any(s < o + hl and e > o for s, e in cut):
			return "removed"
		if any(s < o + n and e > o for s, e in cut):
			self.overrun = c + n
			return "damaged"
		return "swallowed" if c < self.overrun else None


class Demux:
	"""PAT and PMT to the PIDs that carry units, and each unit's bytes. Calls on_unit(pid, key,
	digest, length, kind, damaged, fate) when a unit completes, and on_pid(pid, type, kind) when the
	PMT lists a PID or changes its type. fate is set only for units that packet(p, dropped=True)
	touched."""

	def __init__(self, on_unit, on_pid=None):
		self.on_unit, self.on_pid = on_unit, on_pid or (lambda *a: None)
		self.pmt_pids = set()
		self.kind = {}
		self.stype = {}
		self.cur = {}  # pid -> [pts, bytes or hasher, length, damaged, remaining, cuts, packets, dropped]
		self.framers = {}
		self.cc = {}
		self.sect = {}
		self.packets = self.dups = 0

	def section(self, pid, data, pusi):
		out = []
		if pusi:
			ptr = data[0]
			if pid in self.sect:
				self.sect[pid] += data[1:1 + ptr]
				out += self.complete(pid)
			self.sect[pid] = bytearray(data[1 + ptr:])
		elif pid in self.sect:
			self.sect[pid] += data
		out += self.complete(pid)
		return out

	def complete(self, pid):
		out = []
		b = self.sect[pid]
		while len(b) >= 3 and b[0] != 0xFF:
			n = 3 + ((b[1] & 0x0F) << 8 | b[2])
			if len(b) < n:
				break
			out.append(bytes(b[:n]))
			b = b[n:]
		self.sect[pid] = b if len(b) and b[0] != 0xFF else bytearray()
		if not self.sect[pid]:
			del self.sect[pid]
		return out

	def pmt(self, s):
		if s[0] != 0x02 or len(s) < 16:
			return
		pil = (s[10] & 0x0F) << 8 | s[11]
		i, end = 12 + pil, len(s) - 4
		while i + 5 <= end:
			st, pid, eil = s[i], (s[i + 1] & 0x1F) << 8 | s[i + 2], (s[i + 3] & 0x0F) << 8 | s[i + 4]
			desc = s[i + 5:i + 5 + eil]
			i += 5 + eil
			if st in VIDEO_TYPES:
				kind = "video"
			elif st in AUDIO_TYPES:
				kind = "audio"
			elif st == 0x86:
				kind = "scte35"
			elif st == 0x06:
				tags, j = set(), 0
				while j + 2 <= len(desc):
					tags.add(desc[j])
					j += 2 + desc[j + 1]
				kind = "audio" if tags & {0x6A, 0x7A, 0x7C, 0x7F} else "other"
			else:
				kind = "other"
			if self.kind.get(pid) != kind or self.stype.get(pid) != st:
				self.kind[pid], self.stype[pid] = kind, st
				self.on_pid(pid, st, kind)

	def finish(self, pid):
		u = self.cur.pop(pid, None)
		if not u:
			return
		kind = self.kind.get(pid, "other")
		fate = None if not u[7] else "removed" if u[7] == u[6] else "damaged"
		if kind == "audio" and isinstance(u[1], bytearray):
			fr = self.framers.setdefault(pid, Framer())
			for key, digest, length, damaged, f in fr.add(u[1], u[0], u[3], u[5], fate):
				self.on_unit(pid, key, digest, length, kind, damaged, f)
		elif isinstance(u[1], bytearray):
			if u[0] is not None:
				skip = NAL_SKIP.get(self.stype.get(pid), (False, ()))
				self.on_unit(pid, u[0], nal_digest(u[1], *skip), u[2], kind, u[3], fate)
		elif u[0] is not None:
			self.on_unit(pid, u[0], u[1].hexdigest(), u[2], kind, u[3], fate)

	def flush(self):
		for pid in list(self.cur):
			self.finish(pid)

	def packet(self, p, dropped=False):
		self.packets += 1
		pid = (p[1] & 0x1F) << 8 | p[2]
		afc = (p[3] >> 4) & 3
		if pid == 0x1FFF or not afc & 1:
			return
		pusi = p[1] & 0x40
		cc = p[3] & 0x0F
		off = 4 + (1 + p[4] if afc & 2 else 0)
		data = p[off:]
		last = self.cc.get(pid)
		self.cc[pid] = (cc, data)
		if last is not None:
			if cc == last[0] and data == last[1]:
				self.dups += 1
				return
			if cc != (last[0] + 1) & 0x0F and pid in self.cur and not (afc & 2 and p[4] and p[5] & 0x80):
				self.cur[pid][3] = True
		if off >= 188:
			return
		if pid == 0:
			for s in self.section(0, data, pusi):
				if s[0] == 0x00:
					n = len(s) - 4
					self.pmt_pids = {(s[i + 2] & 0x1F) << 8 | s[i + 3] for i in range(8, n - 3, 4)
									 if (s[i] << 8 | s[i + 1]) != 0}
			return
		if pid in self.pmt_pids:
			for s in self.section(pid, data, pusi):
				self.pmt(s)
			return
		kind = self.kind.get(pid)
		if kind is None:
			return
		if kind == "scte35":
			for s in self.section(pid, data, pusi):
				if s[0] == 0xFC and len(s) >= 4:
					self.on_unit(pid, int.from_bytes(s[-4:], "big"), s[-4:].hex(), len(s), kind, False, None)
			return
		if pusi:
			self.finish(pid)
			h = pes_head(data)
			if h is None:
				return
			pts, hl, rem = h
			es = data[hl:]
			if rem is not None:
				es = es[:max(rem, 0)]
				rem -= len(es)
			whole = kind == "audio" or (kind == "video" and self.stype.get(pid) in NAL_SKIP)
			acc = bytearray(es) if whole else hashlib.blake2b(es, digest_size=8)
			self.cur[pid] = [pts, acc, len(es), False, rem, [(0, len(es))] if dropped else [], 1, int(dropped)]
			return
		u = self.cur.get(pid)
		if u is None:
			return
		if u[4] is not None:
			data = data[:max(u[4], 0)]
			u[4] -= len(data)
		u[6] += 1
		if dropped:
			u[7] += 1
			if u[5] and u[5][-1][1] == u[2]:
				u[5][-1] = (u[5][-1][0], u[2] + len(data))
			else:
				u[5].append((u[2], u[2] + len(data)))
		if isinstance(u[1], bytearray):
			u[1] += data
		else:
			u[1].update(data)
		u[2] += len(data)


def packets(f):
	"""188-byte packets from f; None for each resynchronisation on the sync byte."""
	buf = b""
	while True:
		chunk = f.read(188 * 512)
		if not chunk:
			return
		buf += chunk
		i, n = 0, len(buf)
		while i + 188 <= n:
			if buf[i] == 0x47:
				yield buf[i:i + 188]
				i += 188
				continue
			j = buf.find(b"\x47", i + 1)
			i = n if j == -1 else j
			yield None
		buf = buf[i:]


def cmd_units(a):
	w = sys.stdout.write

	def unit(pid, key, digest, length, kind, damaged, fate):
		w(f"u {pid} {key} {length} {digest} {kind}{' d' if damaged else ''}\n")

	dm = Demux(unit, lambda pid, st, kind: w(f"m {pid} {st} {kind}\n"))
	lost = 0
	next_s = time.monotonic() + 10
	for p in packets(sys.stdin.buffer):
		if p is None:
			lost += 1
			continue
		dm.packet(p)
		if dm.packets & 511 == 0:
			sys.stdout.flush()
			if time.monotonic() >= next_s:
				next_s += 10
				w(f"s {dm.packets} {lost} {dm.dups}\n")
	dm.flush()
	w(f"s {dm.packets} {lost} {dm.dups}\n")
	sys.stdout.flush()


def cmd_drop(a):
	log = open(a.log, "a", buffering=1)
	out = sys.stdout.buffer

	def unit(pid, key, digest, length, kind, damaged, fate):
		if fate and kind in ("video", "audio"):
			log.write(f"{time.time():.3f} {fate} {pid} {key} {kind}\n")

	dm = Demux(unit)
	count = collections.Counter()
	removing = {}
	t0 = time.time()
	was_dark = False
	batch = []
	for p in packets(sys.stdin.buffer):
		if p is None:
			continue
		now = time.time()
		dark = a.blackout_every > 0 and (now - t0) % a.blackout_every >= a.blackout_every - a.blackout
		if dark != was_dark:
			log.write(f"{now:.3f} blackout {'start' if dark else 'end'} - -\n")
			was_dark = dark
		pid = (p[1] & 0x1F) << 8 | p[2]
		drop = dark
		if dm.kind.get(pid) in ("video", "audio") and (p[3] >> 4) & 1:
			if p[1] & 0x40:
				count[pid] += 1
				removing[pid] = dark or (a.every > 0 and count[pid] % a.every == 0)
			drop = drop or removing.get(pid, False)
		dm.packet(p, drop)
		if drop:
			continue
		batch.append(p)
		if len(batch) >= 64:
			out.write(b"".join(batch))
			out.flush()
			batch = []
	dm.flush()
	out.write(b"".join(batch))
	out.flush()


COUNTER = re.compile(r"^counter,name=([a-z0-9_]+),severity=([1-4]),scope=ts\S* value=(\d+)", re.M)


class Influx:
	"""TSDuck's TR 101 290 posts, one bucket per leg: each counter's rise since the last post."""

	def __init__(self, port, on_rise):
		self.last = {}
		owner = self

		class H(http.server.BaseHTTPRequestHandler):
			def log_message(self, *_):
				pass

			def do_POST(self):  # noqa: N802 - the stdlib's name
				body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
				q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
				owner.ingest(q.get("bucket", ["?"])[0], body, on_rise)
				self.send_response(204)
				self.end_headers()

		self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
		threading.Thread(target=self.srv.serve_forever, daemon=True).start()

	def ingest(self, leg, body, on_rise):
		for name, sev, value in COUNTER.findall(body):
			if sev == "4":
				continue
			v = int(value)
			was = self.last.get((leg, name))
			self.last[(leg, name)] = v
			fresh = was is None or v < was
			rise = v if fresh else v - was
			if rise:
				on_rise(leg, name, int(sev), rise, fresh)


class Leg:
	def __init__(self, name, spec, sel):
		self.name, self.spec, self.sel = name, spec, sel
		self.proc = self.f = None
		self.buf = b""
		self.ended = False
		self.restart_at = 0.0
		self.starts = 0

	def open(self):
		if self.spec.startswith("@"):
			self.f = os.fdopen(os.open(self.spec[1:], os.O_RDWR | os.O_NONBLOCK), "rb", buffering=0)
		else:
			self.proc = subprocess.Popen(["bash", "-c", self.spec], stdout=subprocess.PIPE, bufsize=0,
										 start_new_session=True)
			self.f = self.proc.stdout
			os.set_blocking(self.f.fileno(), False)
		self.sel.register(self.f, selectors.EVENT_READ, self)
		self.starts += 1

	def close(self):
		try:
			self.sel.unregister(self.f)
		except (KeyError, ValueError):
			pass
		self.f.close()
		rc = None
		if self.proc:
			for sig, wait in ((None, 1), (signal.SIGTERM, 10), (signal.SIGKILL, None)):
				if sig:
					try:
						os.killpg(self.proc.pid, sig)
					except OSError:
						pass
				try:
					rc = self.proc.wait(timeout=wait)
					break
				except subprocess.TimeoutExpired:
					continue
			try:
				os.killpg(self.proc.pid, signal.SIGTERM)
			except OSError:
				pass
		self.f = self.proc = None
		return rc


class Matcher:
	def __init__(self, a):
		self.a = a
		self.ref = a.ref
		self.out = a.out
		os.makedirs(self.out, exist_ok=True)
		self.events = open(os.path.join(self.out, "events.jsonl"), "a", buffering=1)
		self.sel = selectors.DefaultSelector()
		self.legs = {}
		for spec in a.leg:
			name, cmd = spec.split("=", 1)
			self.legs[name] = Leg(name, cmd, self.sel)
		self.names = list(self.legs)
		self.log_units = set(filter(None, (a.log_units or "").split(",")))
		self.near = [0] + [s for d in range(1, a.pts_slack + 1) for s in (-d, d)]
		self.pending = {}  # (pid, key) -> [entry], entry = [t_first, {leg: (digest, t, damaged, key)}]
		self.order = collections.deque()
		self.kinds = {}
		self.t0 = time.time()
		self.graded_from = self.t0 + a.warmup
		self.graded_until = None
		self.runs = {}
		self.totals = collections.defaultdict(collections.Counter)
		self.lock = threading.Lock()
		self.hour = 0
		self.new_hour()
		self.stop = False
		if a.influx:
			Influx(a.influx, self.on_rise)

	def ev(self, **kv):
		kv["t"] = round(kv.get("t", time.time()), 3)
		self.events.write(json.dumps(kv) + "\n")

	def new_hour(self):
		self.acc = {n: collections.Counter() for n in self.names}
		self.lags = {n: [] for n in self.names}
		self.tr = {n: collections.Counter() for n in self.names}

	def on_rise(self, leg, name, sev, rise, fresh):
		with self.lock:
			if leg in self.tr:
				self.tr[leg][f"p{sev}.{name}"] += rise
				self.totals[leg][f"p{sev}.{name}"] += rise
			self.ev(ev="tr101290", leg=leg, name=name, sev=sev, rise=rise, fresh=fresh)

	def line(self, leg, s, now):
		f = s.split()
		if not f:
			return
		if f[0] == "u" and len(f) >= 6:
			pid, key, digest, kind = int(f[1]), int(f[2]), f[4], f[5]
			self.kinds[pid] = kind
			mine = (digest, now, len(f) > 6, key)
			slack = 0 if kind == "scte35" else self.a.pts_slack
			for d in ((0,) if kind == "scte35" else self.near):
				for e in self.pending.get((pid, (key + d) % PTS_WRAP), ()):
					ref = e[1].get(self.ref)
					if ref and min((key - ref[3]) % PTS_WRAP, (ref[3] - key) % PTS_WRAP) > slack:
						continue
					if leg not in e[1]:
						e[1][leg] = mine
						return
			e = [now, {leg: mine}]
			self.pending.setdefault((pid, key), []).append(e)
			self.order.append(((pid, key), e))
		elif f[0] == "m" and len(f) >= 4:
			self.ev(ev="pid", leg=leg, pid=int(f[1]), type=int(f[2]), kind=f[3])
		elif f[0] == "s" and len(f) >= 4 and (int(f[2]) or int(f[3])):
			self.ev(ev="stats", leg=leg, packets=int(f[1]), sync_lost=int(f[2]), dups=int(f[3]))

	def run(self, leg, what, t, pid, kind):
		r = self.runs.get((leg, what))
		if r and t - r["last"] <= 1.0:
			r["last"], r["n"] = t, r["n"] + 1
			r["kinds"][kind] = r["kinds"].get(kind, 0) + 1
			r["pids"].add(pid)
			return
		self.close_run(leg, what)
		self.runs[(leg, what)] = dict(first=t, last=t, n=1, kinds={kind: 1}, pids={pid})

	def close_run(self, leg, what):
		r = self.runs.pop((leg, what), None)
		if r:
			self.ev(ev=what, leg=leg, first=round(r["first"], 3), last=round(r["last"], 3), n=r["n"],
					kinds=r["kinds"], pids=sorted(r["pids"]))

	def grade(self, e, key):
		t = e[0]
		if t < self.graded_from:
			return
		while int((t - self.graded_from) // 3600) > self.hour:
			self.flush_hour()
			self.hour += 1
			self.new_hour()
		self.graded_until = t
		pid = key[0]
		kind = self.kinds.get(pid, "other")
		seen = e[1]
		ref = seen.get(self.ref)
		if ref:
			self.acc[self.ref][f"{kind}.units"] += 1
			self.totals[self.ref][f"{kind}.units"] += 1
		for leg in self.names:
			if leg == self.ref:
				continue
			mine = seen.get(leg)
			if ref and mine:
				what = "matched" if mine[0] == ref[0] else "altered"
				if what == "matched":
					self.lags[leg].append(mine[1] - ref[1])
			elif ref:
				what = "missing"
			elif mine:
				what = "extra"
			else:
				continue
			self.acc[leg][f"{kind}.{what}"] += 1
			self.totals[leg][f"{kind}.{what}"] += 1
			if what == "matched":
				for w in ("missing", "altered", "extra"):
					r = self.runs.get((leg, w))
					if r and t - r["last"] > 1.0:
						self.close_run(leg, w)
				continue
			self.run(leg, what, t, pid, kind)
			if leg in self.log_units:
				self.ev(ev="unit", leg=leg, what=what, pid=pid, key=(ref or mine)[3], kind=kind, t=t)

	def flush_hour(self):
		path = os.path.join(self.out, "hours.csv")
		new = not os.path.exists(path)
		with open(path, "a") as f:
			if new:
				f.write("hour,leg,units_video,units_audio,units_scte35,units_other,matched,missing,altered,extra,"
						"missing_video,missing_audio,lag_p50,lag_max,tr_p1,tr_p2,tr_counters,starts\n")
			ref = self.acc[self.ref] if self.ref in self.acc else collections.Counter()
			for leg in self.names:
				c = self.acc[leg]
				lag = sorted(self.lags[leg])
				p50 = f"{lag[len(lag) // 2]:.3f}" if lag else ""
				mx = f"{lag[-1]:.3f}" if lag else ""

				def s(w):
					return sum(v for k, v in c.items() if k.endswith("." + w))

				tr = self.tr[leg]
				p1 = sum(v for k, v in tr.items() if k.startswith("p1."))
				p2 = sum(v for k, v in tr.items() if k.startswith("p2."))
				trs = ";".join(f"{k}={v}" for k, v in sorted(tr.items()))
				f.write(f"{self.hour},{leg},{ref['video.units']},{ref['audio.units']},{ref['scte35.units']},"
						f"{ref['other.units']},{s('matched')},{s('missing')},{s('altered')},{s('extra')},"
						f"{c['video.missing']},{c['audio.missing']},{p50},{mx},{p1},{p2},{trs},"
						f"{self.legs[leg].starts}\n")

	def expire(self, now, everything=False):
		limit = now - self.a.hold
		while self.order and (everything or self.order[0][1][0] < limit):
			key, e = self.order.popleft()
			lst = self.pending.get(key)
			if lst:
				lst.remove(e)
				if not lst:
					del self.pending[key]
			if everything and not self.a.once and e[0] >= limit:
				continue
			self.grade(e, key)

	def status(self):
		st = dict(t=round(time.time(), 3), started=round(self.t0, 3), graded_from=round(self.graded_from, 3),
				  graded_until=self.graded_until and round(self.graded_until, 3), hour=self.hour,
				  pending=len(self.order),
				  legs={n: dict(starts=self.legs[n].starts, alive=self.legs[n].f is not None) for n in self.names},
				  totals={n: dict(self.totals[n]) for n in self.names})
		tmp = os.path.join(self.out, ".status.json")
		with open(tmp, "w") as f:
			json.dump(st, f, indent=1, sort_keys=True)
		os.replace(tmp, os.path.join(self.out, "status.json"))

	def read(self, leg):
		try:
			chunk = leg.f.read(65536)
		except BlockingIOError:
			return
		now = time.time()
		if chunk is None:
			return
		if not chunk:
			rc = leg.close()
			self.ev(ev="leg-exit", leg=leg.name, rc=rc)
			if self.a.once:
				leg.ended = True
			else:
				leg.restart_at = now + 2
			return
		lines = (leg.buf + chunk).split(b"\n")
		leg.buf = lines.pop()
		with self.lock:
			for s in lines:
				try:
					self.line(leg.name, s.decode("ascii", "replace"), now)
				except (ValueError, IndexError):
					self.ev(ev="bad-line", leg=leg.name)

	def main(self):
		signal.signal(signal.SIGTERM, lambda *_: setattr(self, "stop", True))
		signal.signal(signal.SIGINT, lambda *_: setattr(self, "stop", True))
		for leg in self.legs.values():
			leg.open()
			self.ev(ev="leg-start", leg=leg.name)
		end = self.t0 + self.a.hours * 3600 if self.a.hours else None
		next_tick = next_status = time.time() + 1
		while not self.stop and not (end and time.time() >= end):
			for key, _ in self.sel.select(timeout=0.2):
				self.read(key.data)
			now = time.time()
			for leg in self.legs.values():
				if leg.f is None and not leg.ended and leg.restart_at and now >= leg.restart_at:
					leg.restart_at = 0
					leg.open()
					self.ev(ev="leg-start", leg=leg.name)
			if self.a.once and all(leg.ended for leg in self.legs.values()):
				break
			if now >= next_tick:
				next_tick = now + 1
				if not self.a.once:
					with self.lock:
						self.expire(now)
			if now >= next_status:
				next_status = now + 60
				with self.lock:
					self.status()
		with self.lock:
			self.expire(time.time(), everything=True)
			for leg, what in list(self.runs):
				self.close_run(leg, what)
			self.flush_hour()
			self.status()
			self.ev(ev="end")
		for leg in self.legs.values():
			if leg.f is not None:
				leg.close()


def cmd_controls(a):
	"""Criterion 9, unit by unit."""
	fate = {}
	for s in open(a.drop_log):
		f = s.split()
		if len(f) == 5 and f[1] in ("removed", "damaged", "swallowed") and f[4] in ("video", "audio"):
			fate[(int(f[2]), int(f[3]))] = (f[1], float(f[0]))
	st = json.load(open(os.path.join(a.dir, "status.json")))
	lo, hi = (float("-inf"), float("inf")) if a.all else (st["graded_from"] + 1, (st["graded_until"] or 0) - 1)
	found = collections.defaultdict(set)
	for s in open(os.path.join(a.dir, "events.jsonl")):
		e = json.loads(s)
		if e.get("ev") == "unit" and e["kind"] in ("video", "audio"):
			found[(e["leg"], e["what"])].add((e["pid"], e["key"]))
	copy = {k: v for k, v in st["totals"].get(a.copy, {}).items()
			if not k.endswith(".matched") and not k.startswith("p")}
	miss, alt, ext = found[(a.cut, "missing")], found[(a.cut, "altered")], found[(a.cut, "extra")]
	named = miss | alt | ext
	untouched = {k for k in named if k not in fate} | ext
	wrong = {k for k in alt if fate.get(k, ("",))[0] in ("removed", "swallowed")}
	inside = {k: w for k, (w, t) in fate.items() if lo <= t <= hi}
	unnamed = {k for k, w in inside.items() if k not in (named if w == "damaged" else miss)}
	by = collections.Counter(inside.values())
	print(f"positive control ({a.copy}): unmatched {copy or 'none'}")
	print(f"negative control ({a.cut}): missing {len(miss)}, altered {len(alt)}, extra {len(ext)}; inside the "
		  f"window the dropper removed {by['removed']}, swallowed {by['swallowed']}, damaged {by['damaged']}")
	print(f"  named but untouched {len(untouched)}, removed but altered {len(wrong)}, touched but not named "
		  f"{len(unnamed)}")
	for name, s in (("untouched", untouched), ("wrong", wrong), ("unnamed", unnamed)):
		for k in sorted(s)[:5]:
			print(f"  {name} pid={k[0]} key={k[1]} {fate.get(k, ('-',))[0]}")
	ok = not copy and not (untouched or wrong or unnamed) and by["removed"]
	print("criterion 9:", "holds" if ok else "FAILS")
	return 0 if ok else 1


def main():
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	sub = ap.add_subparsers(dest="cmd", required=True)
	sub.add_parser("units")
	d = sub.add_parser("drop")
	d.add_argument("--log", required=True)
	d.add_argument("--every", type=int, default=997)
	d.add_argument("--blackout-every", type=float, default=0)
	d.add_argument("--blackout", type=float, default=2.0)
	m = sub.add_parser("match")
	m.add_argument("--out", required=True)
	m.add_argument("--ref", default="rx")
	m.add_argument("--leg", action="append", required=True, help="NAME=CMD or NAME=@FIFO")
	m.add_argument("--influx", type=int, default=0)
	m.add_argument("--hold", type=float, default=60)
	m.add_argument("--warmup", type=float, default=120)
	m.add_argument("--hours", type=float, default=0)
	m.add_argument("--pts-slack", type=int, default=2)
	m.add_argument("--log-units", default="")
	m.add_argument("--once", action="store_true")
	c = sub.add_parser("controls")
	c.add_argument("dir")
	c.add_argument("--copy", default="rxcopy")
	c.add_argument("--cut", default="rxcut")
	c.add_argument("--drop-log", required=True)
	c.add_argument("--all", action="store_true", help="every unit the dropper logged (a --once run)")
	a = ap.parse_args()
	if a.cmd == "units":
		cmd_units(a)
	elif a.cmd == "drop":
		cmd_drop(a)
	elif a.cmd == "match":
		Matcher(a).main()
	else:
		sys.exit(cmd_controls(a))


if __name__ == "__main__":
	main()

#!/usr/bin/env python3
"""An epoch-locked HLS segmenter, so that origins are interchangeable (lab/test-61-*.md).

Each segment starts at the first random-access point (the adaptation field's flag, on the video
PID) at or after a multiple of D of content time, and is named and numbered by that multiple:
seg-K.ts, media sequence K, K = PTS // D, the 33-bit PTS unwrapped against the wall clock (which
two hosts agree on to far better than the 13 h that would make them differ). Nothing in a segment,
its name, its duration or the playlist depends on when the packager joined or on the host, so two
packagers reading the same feed publish the same objects, and a CDN can fetch any of them from
either origin. A segment is an exact slice of the input (no PSI is inserted), so consecutive
segments concatenate to the input stream.

A packager publishes only while it is provably such a copy: a continuity-counter error, a stall in
the input or the PTS going back withdraws the playlist at once and holds it until a full window
of intact segments has been cut again. A pathway that has just joined, or lost input, therefore
answers 404 for its playlist rather than a window its peer does not share.

With --pdt, each segment carries EXT-X-PROGRAM-DATE-TIME: the wall-clock time of its first PCR,
as the PCR plus an offset fixed from the soonest arrival over the first --pdt-settle seconds after
a reset. It follows the content exactly and differs between origins only by their offsets, so a
receiver can release every segment at the same wall-clock time whichever origin or edge served it
(T63). It is multiplex time, not presentation time: the two differ by the encoder's PTS lead.

  t61-epochseg.py DIR [--group 239.255.0.1:5000] [--duration 2] [--window 6] [--extra 3]
                  [--target 4] [--pdt] [--pdt-settle 2] [--file TS]

One line per event on stderr: "<unix time> seg k=K dur=S bytes=N sha1=H", "playlist", "reset why",
"pdt offset=S".
"""
import argparse
import datetime
import hashlib
import os
import re
import socket
import sys
import time

WRAP = 1 << 33
HALF = 1 << 32
STALL_S = 0.5


def pes_pts(p, off):
	if p[off:off + 3] != b"\x00\x00\x01" or not p[off + 7] & 0x80:
		return None
	b = p[off + 9:off + 14]
	return ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1


def pcr_of(p):
	"""The packet's PCR base (90 kHz), or None."""
	if p[3] & 0x20 and p[4] >= 7 and p[5] & 0x10:
		return p[6] << 25 | p[7] << 17 | p[8] << 9 | p[9] << 1 | p[10] >> 7
	return None


class Segmenter:
	def __init__(self, out, duration, window, extra, target, pdt=False, pdt_settle=2.0):
		self.out = out
		self.span = round(duration * 90000)
		self.window = window
		self.extra = extra
		self.target = target
		self.pdt = pdt
		self.pdt_settle = pdt_settle
		self.playlist = os.path.join(out, "index.m3u8")
		self.pmt = None
		self.video = None
		self.pcr_pid = None
		self.cc = {}
		self.last_rx = None
		self.reset("start")

	def event(self, what, detail=""):
		print(f"{time.time():.3f} {what} {detail}".rstrip(), file=sys.stderr, flush=True)

	def reset(self, why):
		self.edge_k = None
		self.cur = None
		self.done = []
		self.cc.clear()
		self.offset = None  # wall clock less PCR time, s: the soonest arrival while settling
		self.settle_until = None
		self.settled = False
		try:
			os.remove(self.playlist)
		except FileNotFoundError:
			pass
		self.event("reset", why)

	def datagram(self, data, now):
		if self.last_rx is not None and now - self.last_rx > STALL_S:
			self.reset(f"input stalled {now - self.last_rx:.3f}s")
		self.last_rx = now
		for i in range(0, len(data) - 187, 188):
			self.packet(data[i:i + 188], now)

	def packet(self, p, now):
		if p[0] != 0x47:
			self.reset("sync")
			return
		pid = (p[1] & 0x1F) << 8 | p[2]
		afc = p[3] >> 4 & 3
		if afc & 1 and pid != 0x1FFF:
			cc = p[3] & 0xF
			last = self.cc.get(pid)
			if last is not None and cc != (last + 1) & 0xF and cc != last:
				self.reset(f"cc pid={pid}")
			self.cc[pid] = cc
		pusi = p[1] & 0x40
		if pusi and (pid == 0 or pid == self.pmt):
			self.psi(pid, p, afc)
		elif pusi and pid == self.video and afc & 2 and p[4] and p[5] & 0x40:
			pts = pes_pts(p, 5 + p[4])
			if pts is not None:
				ref = int(now * 90000)
				self.rap(ref + ((pts - ref + HALF) % WRAP) - HALF, now)
		if self.pdt and pid == self.pcr_pid and (base := pcr_of(p)) is not None:
			self.pcr(base, now)
		if self.cur is not None:
			self.cur[2] += p

	def pcr(self, base, now):
		ref = int(now * 90000)
		t = (ref + ((base - ref + HALF) % WRAP) - HALF) / 90000
		if self.settle_until is None:
			self.settle_until = now + self.pdt_settle
		if now <= self.settle_until:
			self.offset = now - t if self.offset is None else min(self.offset, now - t)
		elif not self.settled:
			self.settled = True
			self.event("pdt", f"offset={self.offset:.6f}")
		if self.cur is not None and self.cur[3] is None:
			self.cur[3] = t

	def psi(self, pid, p, afc):
		off = 4 + (1 + p[4] if afc & 2 else 0)
		s = p[off + 1 + p[off]:]
		if pid == 0:
			self.pmt = (s[10] & 0x1F) << 8 | s[11]
		elif self.video is None:
			self.pcr_pid = (s[8] & 0x1F) << 8 | s[9]
			end = 3 + ((s[1] & 0xF) << 8 | s[2]) - 4
			j = 12 + ((s[10] & 0xF) << 8 | s[11])
			while j + 5 <= end:
				if s[j] in (0x02, 0x1B, 0x24):
					self.video = (s[j + 1] & 0x1F) << 8 | s[j + 2]
					return
				j += 5 + ((s[j + 3] & 0xF) << 8 | s[j + 4])

	def rap(self, v, now):
		k = v // self.span
		prev, self.edge_k = self.edge_k, k
		if prev is None or k == prev:
			return
		if k < prev:
			self.reset(f"pts went back {prev}->{k}")
			self.edge_k = k
			return
		if self.cur is not None:
			self.close(v)
		if k > prev + 1:
			self.event("gap", f"k={prev}->{k}")
		self.cur = [k, v, bytearray(), None]

	def close(self, v):
		k, v0, buf, pcr0 = self.cur
		name = f"seg-{k}.ts"
		tmp = os.path.join(self.out, f".{name}.tmp")
		with open(tmp, "wb") as f:
			f.write(buf)
		os.replace(tmp, os.path.join(self.out, name))
		dur = (v - v0) / 90000
		self.done.append((k, dur, name, pcr0))
		del self.done[:-self.window]
		self.event("seg", f"k={k} dur={dur:.3f} bytes={len(buf)} sha1={hashlib.sha1(buf).hexdigest()[:16]}")
		if len(self.done) == self.window:
			self.publish()
		self.prune(self.done[0][0] - self.extra)

	def publish(self):
		lines = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{self.target}",
				f"#EXT-X-MEDIA-SEQUENCE:{self.done[0][0]}"]
		for _, dur, name, pcr0 in self.done:
			if self.pdt and pcr0 is not None and self.settled:
				at = datetime.datetime.fromtimestamp(pcr0 + self.offset, datetime.timezone.utc)
				lines.append("#EXT-X-PROGRAM-DATE-TIME:" + at.isoformat(timespec="milliseconds")[:-6] + "Z")
			lines += [f"#EXTINF:{dur:.3f},", name]
		tmp = self.playlist + ".tmp"
		with open(tmp, "w") as f:
			f.write("\n".join(lines) + "\n")
		os.replace(tmp, self.playlist)
		self.event("playlist", f"msn={self.done[0][0]}")

	def prune(self, below):
		for f in os.listdir(self.out):
			m = re.fullmatch(r"seg-(\d+)\.ts", f)
			if m and int(m.group(1)) < below:
				os.remove(os.path.join(self.out, f))


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("dir")
	ap.add_argument("--group", default="239.255.0.1:5000")
	ap.add_argument("--duration", type=float, default=2.0, help="epoch D, seconds")
	ap.add_argument("--window", type=int, default=6, help="segments listed")
	ap.add_argument("--extra", type=int, default=3, help="segments kept after leaving the list")
	ap.add_argument("--target", type=int, default=4, help="EXT-X-TARGETDURATION, the same on every origin")
	ap.add_argument("--pdt", action="store_true", help="EXT-X-PROGRAM-DATE-TIME on every segment")
	ap.add_argument("--pdt-settle", type=float, default=2.0, help="seconds to settle the PCR offset")
	ap.add_argument("--file", help="read a TS file instead of the group (tests)")
	args = ap.parse_args()
	os.makedirs(args.dir, exist_ok=True)
	seg = Segmenter(args.dir, args.duration, args.window, args.extra, args.target, args.pdt, args.pdt_settle)
	if args.file:
		with open(args.file, "rb") as f:
			while data := f.read(1316):
				seg.datagram(data, time.time())
		return
	group, port = args.group.rsplit(":", 1)
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
	s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 << 20)
	s.bind((group, int(port)))
	s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
				socket.inet_aton(group) + socket.inet_aton("127.0.0.1"))
	while True:
		seg.datagram(s.recv(65536), time.time())


if __name__ == "__main__":
	main()

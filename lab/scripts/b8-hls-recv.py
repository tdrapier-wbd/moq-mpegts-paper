#!/usr/bin/env python3
"""B-8, first increment: an HLS media-playlist receiver for the segmented lane's TS hand-off.

Grown from t6-hls-pull.py, which T30 keeps using unchanged. What it adds is what a 24/7 receiver
behind a CDN needs and the T30 receiver lacked:

  - one persistent connection, and any request headers (a CDN's viewer secret, CMCD later);
  - a segment that fails is retried until --give-up-ms, rather than skipped at once, because a
    CDN's transient 5xx or a 404 from a replica not yet holding the object is the common case;
    later segments wait behind it, so the output stays in order;
  - a media sequence going backwards with new names is flagged, the one signal T30 found for a
    namespace two packagers share, and one that skips segments never listed to it (T59's
    origin outage, behind an edge serving the last playlist) is flagged too;
  - every request is logged as one JSON line (status, bytes, time to first byte, total, the CDN's
    X-Cache, Age and PoP, and for a segment how long OUT took to accept it), which is the
    telemetry the lane's monitoring is built from.

It writes the transport stream to OUT ("-" for stdout, to pipe into a groomer). It joins at the
live edge, and on recovery it re-anchors there rather than replaying history: a hole, not a lag.
CMCD and CAT renewal are later increments (lab/test-30 § Tooling).

With --release-ms, a segment the playlist dates (EXT-X-PROGRAM-DATE-TIME, its first PCR's wall-clock
time, as t61-epochseg.py --pdt writes it) is held until its last PCR's time plus the hold, so every
receiver of the stream hands it on at the same instant, whatever path delivered it and however long
that took (T63). The last PCR, not the last packet, because a stream-clocked groomer can place
packets only up to the newest PCR it has seen. One that arrives later is passed on at once and
logged as late. The host clock must be synchronised.

Usage:
  b8-hls-recv.py URL OUT [--seconds N] [--poll MS] [--edge N] [--timeout S] [--give-up-ms MS]
                 [--release-ms MS] [--header 'Name: value']... [--log FILE.jsonl]
"""
import argparse
import datetime
import http.client
import json
import sys
import time
import urllib.parse

PCR_WRAP = (1 << 33) * 300


class Client:
	"""One keep-alive connection, reopened on any failure."""

	def __init__(self, base, headers, timeout):
		u = urllib.parse.urlsplit(base)
		self.https = u.scheme == "https"
		self.host = u.netloc
		self.headers = dict(headers, **{"User-Agent": "b8-hls-recv/1"})
		self.timeout = timeout
		self.conn = None

	def get(self, url):
		path = urllib.parse.urlsplit(url)
		path = path.path + ("?" + path.query if path.query else "")
		if self.conn is None:
			cls = http.client.HTTPSConnection if self.https else http.client.HTTPConnection
			self.conn = cls(self.host, timeout=self.timeout)
		t0 = time.time()
		try:
			self.conn.request("GET", path, headers=self.headers)
			r = self.conn.getresponse()
			ttfb = time.time() - t0
			body = r.read()
		except Exception:
			self.conn.close()
			self.conn = None
			raise
		meta = dict(status=r.status, bytes=len(body), ttfb_ms=round(ttfb * 1000, 1),
					ms=round((time.time() - t0) * 1000, 1), cache=r.getheader("X-Cache"),
					age=r.getheader("Age"), pop=r.getheader("X-Amz-Cf-Pop"))
		return r.status, body, meta


def parse_media_playlist(text):
	"""Return (media_sequence, [segment_uri, ...], {uri: program date-time, unix s})."""
	seq, uris, dated, pdt = 0, [], {}, None
	for line in text.splitlines():
		line = line.strip()
		if line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
			try:
				seq = int(line.split(":", 1)[1])
			except ValueError:
				pass
		elif line.startswith("#EXT-X-PROGRAM-DATE-TIME:"):
			try:
				pdt = datetime.datetime.fromisoformat(line.split(":", 1)[1]).timestamp()
			except ValueError:
				pdt = None
		elif line and not line.startswith("#"):
			uris.append(line)
			if pdt is not None:
				dated[line] = pdt
			pdt = None
	return seq, uris, dated


def pcr_span(data):
	"""Seconds from a segment's first PCR to its last; None without two. PCRs are read from the
	first PID that carries one."""
	pid, first, last = None, None, None
	for i in range(len(data) // 188):
		p = data[i * 188:i * 188 + 188]
		if p[0] != 0x47 or not p[3] & 0x20 or p[4] < 7 or not p[5] & 0x10:
			continue
		this = (p[1] & 0x1F) << 8 | p[2]
		if pid is None:
			pid = this
		elif this != pid:
			continue
		last = (p[6] << 25 | p[7] << 17 | p[8] << 9 | p[9] << 1 | p[10] >> 7) * 300 + ((p[10] & 1) << 8 | p[11])
		if first is None:
			first = last
	if first is None or last == first:
		return None
	return ((last - first) % PCR_WRAP) / 27e6


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("url")
	ap.add_argument("out")
	ap.add_argument("--seconds", type=float, default=60.0)
	ap.add_argument("--poll", type=float, default=250.0, help="playlist poll interval, ms")
	ap.add_argument("--edge", type=int, default=1, help="join this many segments back from the live edge")
	ap.add_argument("--timeout", type=float, default=3.0)
	ap.add_argument("--give-up-ms", type=float, default=4000.0,
					help="how long a failing segment is retried before it is skipped")
	ap.add_argument("--release-ms", type=float, default=None,
					help="hold each dated segment until its last PCR's time plus this")
	ap.add_argument("--header", action="append", default=[])
	ap.add_argument("--log", default=None)
	args = ap.parse_args()

	headers = dict(h.split(":", 1) for h in args.header)
	headers = {k.strip(): v.strip() for k, v in headers.items()}
	logf = open(args.log, "a", buffering=1) if args.log else sys.stderr

	def log(ev, **kw):
		print(json.dumps(dict(t=round(time.time(), 3), ev=ev, **kw)), file=logf)

	out = sys.stdout.buffer if args.out == "-" else open(args.out, "wb", buffering=0)
	client = Client(args.url, headers, args.timeout)
	deadline = time.time() + args.seconds
	poll = args.poll / 1000.0

	# Segment identity is the URI; a restarted packager starts a new media sequence, and names
	# derived from the wall clock make the URI unique across restarts.
	seen = set()
	failing = {}  # uri -> first failure time
	joined = False
	last_msn, last_uris = None, set()
	n_seg = n_lost = n_fail = n_skip = 0
	down_since = None

	while time.time() < deadline:
		try:
			status, body, meta = client.get(args.url)
		except Exception as e:  # noqa: BLE001 - any failure is a retry, by design
			status, body, meta = None, b"", dict(error=str(e)[:120])
		if status != 200:
			n_fail += 1
			if down_since is None:
				down_since = time.time()
			log("pl-fail", **meta)
			time.sleep(poll)
			continue
		if down_since is not None:
			log("pl-recovered", after_s=round(time.time() - down_since, 3))
			down_since = None

		msn, uris, dated = parse_media_playlist(body.decode("utf-8", "replace"))
		if last_msn is not None and msn < last_msn and not set(uris) <= last_uris:
			log("msn-regress", was=last_msn, now=msn)
		# Segments listed and withdrawn between two of our reads: an edge that served a stale
		# playlist through an origin outage answers 200 throughout, so nothing else shows them.
		# A restarted packager jumps the sequence too, so this is a count of events, not of loss.
		if last_msn is not None and msn > last_msn + len(last_uris):
			n_skip += 1
			log("msn-skip", was=last_msn, now=msn, unseen=msn - last_msn - len(last_uris))
		if msn != last_msn:
			log("pl", msn=msn, n=len(uris), **meta)
		last_msn, last_uris = msn, set(uris)
		if not uris:
			time.sleep(poll)
			continue
		if not joined:
			for u in uris[:-args.edge] if args.edge else uris:
				seen.add(u)
			joined = True
			log("join", at=uris[-args.edge] if args.edge else None)

		for u in uris:
			if u in seen:
				continue
			try:
				status, data, meta = client.get(urllib.parse.urljoin(args.url, u))
			except Exception as e:  # noqa: BLE001
				status, data, meta = None, b"", dict(error=str(e)[:120])
			if status == 200:
				if args.release_ms is not None and u in dated and (span := pcr_span(data)) is not None:
					wait = dated[u] + span + args.release_ms / 1000.0 - time.time()
					if wait > 0:
						time.sleep(wait)
						meta["held_ms"] = round(wait * 1000, 1)
					else:
						meta["late_ms"] = round(-wait * 1000, 1)
				try:
					t_write = time.time()
					out.write(data)
					meta["write_ms"] = round((time.time() - t_write) * 1000, 1)
				except BrokenPipeError:
					log("downstream-closed")
					return
				seen.add(u)
				failing.pop(u, None)
				n_seg += 1
				log("seg", name=u, **meta)
				continue
			n_fail += 1
			first = failing.setdefault(u, time.time())
			if time.time() - first < args.give_up_ms / 1000.0:
				log("seg-retry", name=u, **meta)
				break  # keep order: nothing after it until it arrives or is given up
			log("seg-lost", name=u, **meta)
			seen.add(u)
			failing.pop(u, None)
			n_lost += 1

		# Names that left the playlist unfetched are lost too, and say so.
		for u in [u for u in failing if u not in uris]:
			log("seg-lost", name=u, reason="left playlist")
			seen.add(u)
			failing.pop(u)
			n_lost += 1
		time.sleep(poll)

	log("done", segments=n_seg, lost=n_lost, failures=n_fail, skips=n_skip)
	if out is not sys.stdout.buffer:
		out.close()


if __name__ == "__main__":
	main()

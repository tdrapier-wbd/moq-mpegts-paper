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
CAT renewal is a later increment (lab/test-30 § Tooling).

With --cmcd, every request carries CMCD v2 (CTA-5004-B) in request mode, in the four CMCD-*
headers or the CMCD query argument, which is the form a CDN's standard access log keeps: the
session (cid, sf=h, sid, st=l, v=2), the object (ot, d), and per request sn, su on the first
segment and on the one after a retry, mtp from the last segment, nor, ltc (a dated segment's
program date-time to its hand-off), bs after a lost segment or playlist outage, msd once. With
--cmcd-collector it also reports in event mode, a batched POST of application/cmcd records:
play-state changes (starting, playing, rebuffering, quit or fatal), a response record (rc, url,
ttfb, ttlb) for each segment and each failed playlist fetch, an error (ec) per anomaly, and an
interval report every --cmcd-interval seconds. A buffer the receiver does not hold (bl, tbl) is
not sent.

With --ts-counters PORT it also listens on loopback for TR 101 290 counters from the TSDuck that
reads its output (`tsp -P influx --tr-101-290 --host-url http://127.0.0.1:PORT`), passing each post
on unchanged to --ts-counters-forward if given. Once the first report is in, every request and
interval report carries each priority's running total as a custom key (PREFIX-p1, -p2, -p3, PREFIX
from --cmcd-ts-prefix), and a counter that rises between two reports is an error record naming it
(ec PREFIX-<counter>). Counters already raised in the first report are totals, not errors.

With --release-ms, a segment the playlist dates (EXT-X-PROGRAM-DATE-TIME, its first PCR's wall-clock
time, as t61-epochseg.py --pdt writes it) is held until its last PCR's time plus the hold, so every
receiver of the stream hands it on at the same instant, whatever path delivered it and however long
that took (T63). The last PCR, not the last packet, because a stream-clocked groomer can place
packets only up to the newest PCR it has seen. One that arrives later is passed on at once and
logged as late. The host clock must be synchronised.

A segment the playlist marks with EXT-X-DISCONTINUITY (a new source, a new timeline) is handed on
with the transport stream's own signal for it, which a groomer or an IRD reads and a playlist tag
does not reach: `discontinuity_indicator` is set on each PID's first PCR in the segment and on each
other PID's first packet if it carries an adaptation field. Nothing else in the segment is changed,
and nothing at all without the tag. A PID whose first packet has no adaptation field cannot be
marked without re-packetising, and the log names it.

With --strip-tables, a segment that opens with a PAT and a PMT that PAT lists loses those two
packets, the pair a packager adds, so the hand-off carries only the source's packets (T83). TSDuck's
packager also advances those two PIDs' continuity counters by one for each pair it adds, which this
does not undo; its --slice-only adds no pair.

Usage:
  b8-hls-recv.py URL OUT [--seconds N, 0 for no end] [--poll MS] [--edge N] [--timeout S]
                 [--give-up-ms MS] [--release-ms MS] [--strip-tables] [--header 'Name: value']...
                 [--log FILE.jsonl]
                 [--cmcd headers|query] [--cmcd-cid ID] [--cmcd-collector URL] [--cmcd-interval S]
                 [--ts-counters PORT] [--ts-counters-forward URL] [--cmcd-ts-prefix PREFIX]
"""
import argparse
import datetime
import http.client
import http.server
import json
import posixpath
import queue
import re
import sys
import threading
import time
import urllib.parse
import uuid

PCR_WRAP = (1 << 33) * 300
# One TR 101 290 counter of TSDuck's influx plugin, the transport stream's total (scope=ts).
COUNTER = re.compile(r"^counter,name=([a-z0-9_]+),severity=([1-3]),scope=ts\S* value=(\d+)", re.M)


class Tok(str):
	"""A CMCD token: written bare, where a string is quoted."""


def sf_item(v):
	"""One value as RFC 8941 writes it: an inner list from a list, a parameter from a tuple."""
	if isinstance(v, list):
		return "(" + " ".join(sf_item(x) for x in v) + ")"
	if isinstance(v, tuple):
		return f"{sf_item(v[0])};{v[1]}"
	if isinstance(v, Tok):
		return str(v)
	if isinstance(v, str):
		return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
	return str(int(v))


def cmcd_payload(keys):
	"""Key-value pairs in alphabetical order; a TRUE boolean is its key alone."""
	return ",".join(k if v is True else f"{k}={sf_item(v)}" for k, v in sorted(keys.items()))


class Cmcd:
	"""One receiver session's CMCD v2: request mode on every fetch, event mode to a collector."""

	SHARD = {"cid": "Session", "msd": "Session", "sf": "Session", "sid": "Session", "st": "Session",
			 "v": "Session", "d": "Object", "ot": "Object", "bs": "Status"}

	def __init__(self, mode, cid, collector, log):
		self.mode, self.collector, self.log = mode, collector, log
		self.session = dict(cid=cid, sf=Tok("h"), sid=str(uuid.uuid4()), st=Tok("l"), v=2)
		self.sn = {"request": 0, "event": 0}
		self.lock = threading.Lock()
		self.events = queue.Queue()
		self.poster = None
		if collector:
			self.poster = threading.Thread(target=self._post, daemon=True)
			self.poster.start()

	def request(self, url, ot, **keys):
		"""The URL and headers of one fetch carrying request-mode CMCD."""
		if not self.mode:
			return url, {}
		keys = dict(self.session, ot=Tok(ot), sn=self.sn["request"],
					**{k: v for k, v in keys.items() if v is not None and v is not False})
		self.sn["request"] += 1
		if self.mode == "query":
			sep = "&" if urllib.parse.urlsplit(url).query else "?"
			return url + sep + "CMCD=" + urllib.parse.quote(cmcd_payload(keys), safe=""), {}
		shards = {}
		for k, v in keys.items():
			shards.setdefault(self.SHARD.get(k, "Request"), {})[k] = v
		return url, {f"CMCD-{s}": cmcd_payload(kv) for s, kv in shards.items()}

	def event(self, e, ts=None, **keys):
		"""Queue one event-mode record; `ts` defaults to now."""
		if not self.collector:
			return
		with self.lock:  # the counters' listener reports from its own thread
			rec = dict(self.session, e=Tok(e), sn=self.sn["event"], ts=round((ts or time.time()) * 1000),
					   **{k: v for k, v in keys.items() if v is not None})
			self.sn["event"] += 1
			self.events.put(cmcd_payload(rec))

	def close(self):
		if self.poster:
			self.events.put(None)
			self.poster.join(timeout=5)

	def _post(self):
		"""Send queued records in batches of up to a second's worth, off the fetch loop."""
		u = urllib.parse.urlsplit(self.collector)
		cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
		done = False
		while not done:
			batch = [self.events.get()]
			until = time.time() + 1.0
			while len(batch) < 200 and batch[-1] is not None:
				try:
					batch.append(self.events.get(timeout=max(0.0, until - time.time())))
				except queue.Empty:
					break
			done = None in batch
			batch = [r for r in batch if r is not None]
			if not batch:
				continue
			try:
				conn = cls(u.netloc, timeout=5)
				conn.request("POST", u.path or "/", body="\n".join(batch).encode(),
							 headers={"Content-Type": "application/cmcd"})
				r = conn.getresponse()
				r.read()
				conn.close()
				if r.status >= 300:
					self.log("cmcd-post-fail", status=r.status, records=len(batch))
			except Exception as e:  # noqa: BLE001 - a lost report never stops the receiver
				self.log("cmcd-post-fail", error=str(e)[:120], records=len(batch))


class TsCounters:
	"""TR 101 290 counters posted by a downstream `tsp -P influx`, kept as running totals."""

	def __init__(self, port, forward, on_rise, log):
		self.totals, self.lock, self.on_rise, self.log = {}, threading.Lock(), on_rise, log
		fwd = urllib.parse.urlsplit(forward) if forward else None
		owner = self

		class Handler(http.server.BaseHTTPRequestHandler):
			def log_message(self, *_):
				pass

			def do_POST(self):  # noqa: N802 - the stdlib's name
				body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
				owner.ingest(body.decode("utf-8", "replace"))
				self.send_response(204)
				self.end_headers()
				if fwd:
					owner.forward(fwd, self.path, body, self.headers.get("Content-Type", "text/plain"))

		self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
		threading.Thread(target=self.srv.serve_forever, daemon=True).start()

	def ingest(self, body):
		rises = []
		with self.lock:
			for name, sev, value in COUNTER.findall(body):
				was = self.totals.get(name)
				self.totals[name] = (int(sev), int(value))
				if was is not None and int(value) > was[1]:
					rises.append((name, int(sev), int(value) - was[1], int(value)))
		for r in rises:
			self.on_rise(*r)

	def forward(self, u, path, body, ctype):
		cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
		try:
			conn = cls(u.netloc, timeout=5)
			conn.request("POST", u.path.rstrip("/") + path, body=body, headers={"Content-Type": ctype})
			conn.getresponse().read()
			conn.close()
		except Exception as e:  # noqa: BLE001 - a lost copy never stops the receiver
			self.log("ts-forward-fail", error=str(e)[:120])

	def keys(self, prefix):
		"""Each priority's total, once a report is in."""
		with self.lock:
			if not self.totals:
				return {}
			sums = {1: 0, 2: 0, 3: 0}
			for sev, value in self.totals.values():
				sums[sev] += value
		return {f"{prefix}-p{s}": n for s, n in sums.items()}

	def close(self):
		self.srv.shutdown()


class Client:
	"""One keep-alive connection, reopened on any failure."""

	def __init__(self, base, headers, timeout):
		u = urllib.parse.urlsplit(base)
		self.https = u.scheme == "https"
		self.host = u.netloc
		self.headers = dict(headers, **{"User-Agent": "b8-hls-recv/1"})
		self.timeout = timeout
		self.conn = None
		self.t0 = None  # the last request's start, for CMCD's response records

	def get(self, url, extra=None):
		path = urllib.parse.urlsplit(url)
		path = path.path + ("?" + path.query if path.query else "")
		if self.conn is None:
			cls = http.client.HTTPSConnection if self.https else http.client.HTTPConnection
			self.conn = cls(self.host, timeout=self.timeout)
		t0 = self.t0 = time.time()
		try:
			self.conn.request("GET", path, headers=dict(self.headers, **(extra or {})))
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
	"""Return (media_sequence, [segment_uri, ...], {uri: program date-time, unix s},
	{uri that EXT-X-DISCONTINUITY precedes}, {uri: EXTINF duration, s})."""
	seq, uris, dated, disc, dur, pdt, brk, extinf = 0, [], {}, set(), {}, None, False, None
	for line in text.splitlines():
		line = line.strip()
		if line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
			try:
				seq = int(line.split(":", 1)[1])
			except ValueError:
				pass
		elif line.startswith("#EXTINF:"):
			try:
				extinf = float(line[8:].split(",", 1)[0])
			except ValueError:
				extinf = None
		elif line.startswith("#EXT-X-PROGRAM-DATE-TIME:"):
			try:
				pdt = datetime.datetime.fromisoformat(line.split(":", 1)[1]).timestamp()
			except ValueError:
				pdt = None
		elif line == "#EXT-X-DISCONTINUITY":
			brk = True
		elif line and not line.startswith("#"):
			uris.append(line)
			if pdt is not None:
				dated[line] = pdt
			if brk:
				disc.add(line)
			if extinf is not None:
				dur[line] = extinf
			pdt, brk, extinf = None, False, None
	return seq, uris, dated, disc, dur


def relative(frm, to):
	"""`to` relative to `frm`'s directory, as CMCD's nor carries it."""
	a, b = urllib.parse.urlsplit(frm), urllib.parse.urlsplit(to)
	if a.netloc != b.netloc:
		return to
	return posixpath.relpath(b.path, posixpath.dirname(a.path)) + ("?" + b.query if b.query else "")


def mark_discontinuity(data):
	"""Set discontinuity_indicator on each PID's first PCR and on each other PID's first packet
	that has an adaptation field. Returns (data, marked PIDs, PIDs that could not be marked)."""
	data = bytearray(data)
	first, pcr_done = {}, set()
	for i in range(0, len(data) - 187, 188):
		p = data[i:i + 4]
		if p[0] != 0x47:
			continue
		pid = (p[1] & 0x1F) << 8 | p[2]
		if pid == 0x1FFF:
			continue
		has_af = p[3] & 0x20 and data[i + 4] > 0
		if has_af and data[i + 5] & 0x10 and pid not in pcr_done:
			data[i + 5] |= 0x80
			pcr_done.add(pid)
			first.setdefault(pid, True)
		elif pid not in first:
			if has_af:
				data[i + 5] |= 0x80
			first[pid] = bool(has_af)
	return bytes(data), sorted(p for p, ok in first.items() if ok), sorted(p for p, ok in first.items() if not ok)


def strip_added_tables(data):
	"""Drop a segment's first two packets when they are a PAT and a PMT that PAT lists: the pair a
	packager puts at the head of each segment (TSDuck's `-O hls` puts one on every segment after
	its first). Returns (data, whether a pair was dropped)."""
	if len(data) < 376 or data[0] != 0x47 or data[188] != 0x47:
		return data, False
	if (data[1] & 0x1F) << 8 | data[2] != 0 or not data[1] & 0x40:
		return data, False
	o = 4 + (1 + data[4] if data[3] & 0x20 else 0)
	s = o + 1 + data[o]
	length = (data[s + 1] & 0x0F) << 8 | data[s + 2]
	pmts = set()
	for e in range(s + 8, min(s + 3 + length - 4, 188), 4):
		if data[e] << 8 | data[e + 1]:
			pmts.add((data[e + 2] & 0x1F) << 8 | data[e + 3])
	if (data[189] & 0x1F) << 8 | data[190] not in pmts or not data[189] & 0x40:
		return data, False
	return data[376:], True


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
	ap.add_argument("--seconds", type=float, default=60.0, help="how long to run; 0 runs until stopped")
	ap.add_argument("--poll", type=float, default=250.0, help="playlist poll interval, ms")
	ap.add_argument("--edge", type=int, default=1, help="join this many segments back from the live edge")
	ap.add_argument("--timeout", type=float, default=3.0)
	ap.add_argument("--give-up-ms", type=float, default=4000.0,
					help="how long a failing segment is retried before it is skipped")
	ap.add_argument("--release-ms", type=float, default=None,
					help="hold each dated segment until its last PCR's time plus this")
	ap.add_argument("--header", action="append", default=[])
	ap.add_argument("--strip-tables", action="store_true",
					help="drop the PAT and PMT a packager adds at the head of each segment")
	ap.add_argument("--log", default=None)
	ap.add_argument("--cmcd", choices=["headers", "query"], default=None,
					help="send request-mode CMCD v2 on every fetch")
	ap.add_argument("--cmcd-cid", default=None, help="CMCD content ID; the playlist's path by default")
	ap.add_argument("--cmcd-collector", default=None, help="POST event-mode CMCD v2 to this URL")
	ap.add_argument("--cmcd-interval", type=float, default=30.0,
					help="seconds between event-mode interval reports; 0 sends none")
	ap.add_argument("--ts-counters", type=int, default=None,
					help="listen on this loopback port for tsp -P influx --tr-101-290's posts")
	ap.add_argument("--ts-counters-forward", default=None, help="pass each counter post on to this URL")
	ap.add_argument("--cmcd-ts-prefix", default="tr101290", help="the counters' custom-key prefix")
	args = ap.parse_args()

	headers = dict(h.split(":", 1) for h in args.header)
	headers = {k.strip(): v.strip() for k, v in headers.items()}
	logf = open(args.log, "a", buffering=1) if args.log else sys.stderr

	def log(ev, **kw):
		print(json.dumps(dict(t=round(time.time(), 3), ev=ev, **kw)), file=logf)

	out = sys.stdout.buffer if args.out == "-" else open(args.out, "wb", buffering=0)
	client = Client(args.url, headers, args.timeout)
	t_start = time.time()
	deadline = t_start + args.seconds if args.seconds > 0 else float("inf")
	poll = args.poll / 1000.0

	cmcd = Cmcd(args.cmcd, args.cmcd_cid or urllib.parse.urlsplit(args.url).path, args.cmcd_collector, log)
	state, once, mtp, ltc = "s", {}, None, None  # play state; keys for the next request only
	next_report = t_start + args.cmcd_interval if args.cmcd_interval > 0 else float("inf")
	cmcd.event("ps", ts=t_start, sta=Tok("s"))
	pre = args.cmcd_ts_prefix

	def counter_rose(name, sev, rise, total):
		log("ts-counter", name=name, severity=sev, rise=rise, total=total)
		cmcd.event("e", ec=[f"{pre}-{name}"])

	counters = TsCounters(args.ts_counters, args.ts_counters_forward, counter_rose, log) \
		if args.ts_counters else None

	def tsk():
		return counters.keys(pre) if counters else {}

	def play_state(sta, **kw):
		nonlocal state
		if sta != state:
			state = sta
			cmcd.event("ps", sta=Tok(sta), **kw)

	def starved(code):
		cmcd.event("e", ec=[code])
		if state == "p":
			play_state("r")
			once["bs"] = True

	def response(status, url, meta, ot):
		cmcd.event("rr", ts=client.t0, rc=status or 0, url=url, ot=Tok(ot),
				   ttfb=round(meta["ttfb_ms"]) if "ttfb_ms" in meta else None,
				   ttlb=round(meta["ms"]) if "ms" in meta else None)

	def quit_session():
		play_state("q")
		cmcd.close()
		if counters:
			counters.close()

	# Segment identity is the URI; a restarted packager starts a new media sequence, and names
	# derived from the wall clock make the URI unique across restarts.
	seen = set()
	failing = {}  # uri -> first failure time
	joined = False
	last_msn, last_uris = None, set()
	n_seg = n_lost = n_fail = n_skip = 0
	down_since = None

	while time.time() < deadline:
		if time.time() >= next_report:
			cmcd.event("t", sta=Tok(state), mtp=mtp, ltc=ltc, **tsk())
			next_report += args.cmcd_interval
		url, extra = cmcd.request(args.url, "m", **once, **tsk())
		once.clear()
		try:
			status, body, meta = client.get(url, extra)
		except Exception as e:  # noqa: BLE001 - any failure is a retry, by design
			status, body, meta = None, b"", dict(error=str(e)[:120])
		if status != 200:
			n_fail += 1
			response(status, args.url, meta, "m")
			if down_since is None:
				down_since = time.time()
				starved("pl-fail")
			log("pl-fail", **meta)
			time.sleep(poll)
			continue
		if down_since is not None:
			log("pl-recovered", after_s=round(time.time() - down_since, 3))
			down_since = None

		msn, uris, dated, disc, dur = parse_media_playlist(body.decode("utf-8", "replace"))
		if last_msn is not None and msn < last_msn and not set(uris) <= last_uris:
			log("msn-regress", was=last_msn, now=msn)
			cmcd.event("e", ec=["msn-regress"])
		# Segments listed and withdrawn between two of our reads: an edge that served a stale
		# playlist through an origin outage answers 200 throughout, so nothing else shows them.
		# A restarted packager jumps the sequence too, so this is a count of events, not of loss.
		if last_msn is not None and msn > last_msn + len(last_uris):
			n_skip += 1
			log("msn-skip", was=last_msn, now=msn, unseen=msn - last_msn - len(last_uris))
			cmcd.event("e", ec=["msn-skip"])
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

		for i, u in enumerate(uris):
			if u in seen:
				continue
			seg_url = urllib.parse.urljoin(args.url, u)
			nxt = [relative(seg_url, urllib.parse.urljoin(args.url, uris[i + 1]))] if i + 1 < len(uris) else None
			url, extra = cmcd.request(seg_url, "av", d=round(dur[u] * 1000) if u in dur else None, nor=nxt,
									  mtp=mtp, ltc=ltc, su=state != "p", **once, **tsk())
			once.clear()
			try:
				status, data, meta = client.get(url, extra)
			except Exception as e:  # noqa: BLE001
				status, data, meta = None, b"", dict(error=str(e)[:120])
			response(status, seg_url, meta, "av")
			if status == 200:
				if meta["ms"] > 0:
					mtp = max(100, round(len(data) * 8 / meta["ms"] / 100) * 100)
				if args.release_ms is not None and u in dated and (span := pcr_span(data)) is not None:
					wait = dated[u] + span + args.release_ms / 1000.0 - time.time()
					if wait > 0:
						time.sleep(wait)
						meta["held_ms"] = round(wait * 1000, 1)
					else:
						meta["late_ms"] = round(-wait * 1000, 1)
				if args.strip_tables:
					data, meta["stripped"] = strip_added_tables(data)
				if u in disc and n_seg:
					data, marked, unmarked = mark_discontinuity(data)
					log("discontinuity", name=u, marked=marked, unmarked=unmarked)
				try:
					t_write = time.time()
					out.write(data)
					meta["write_ms"] = round((time.time() - t_write) * 1000, 1)
				except BrokenPipeError:
					log("downstream-closed")
					quit_session()
					return
				if u in dated:
					ltc = max(0, round((t_write - dated[u]) * 1000))
				if state != "p":
					if not n_seg:
						once["msd"] = round((t_write - t_start) * 1000)
					play_state("p", msd=once.get("msd"))
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
			starved("seg-lost")
			seen.add(u)
			failing.pop(u, None)
			n_lost += 1

		# Names that left the playlist unfetched are lost too, and say so.
		for u in [u for u in failing if u not in uris]:
			log("seg-lost", name=u, reason="left playlist")
			starved("seg-lost")
			seen.add(u)
			failing.pop(u)
			n_lost += 1
		time.sleep(poll)

	log("done", segments=n_seg, lost=n_lost, failures=n_fail, skips=n_skip)
	quit_session()
	if out is not sys.stdout.buffer:
		out.close()


if __name__ == "__main__":
	main()

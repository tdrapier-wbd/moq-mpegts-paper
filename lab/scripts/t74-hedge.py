#!/usr/bin/env python3
"""b8-hls-recv.py with a hedged segment fetch on a second connection already open, for T74's last arm.

    t74-hedge.py --hedge-ms MS URL OUT [b8-hls-recv.py's options]

P1-ap's deadline shut a slow fetch and retried on a new connection, which on the 116 ms path costs
about a second of handshake and slow start, the slack a 2 s cushion leaves. This keeps two
keep-alive connections as warm as the receiver's one: segment fetches alternate between them, and
each playlist poll also goes out on the idle one and is discarded, so neither sits idle past a
retransmission timeout, after which Linux cuts a sender's window. When a segment fetch has not
completed after MS, the same request goes out on the other connection if it is idle, and the
first complete response is used. The slower fetch is left to finish or fail in the background,
its connection out of use until then; none is shut. Playlist fetches are not hedged.

Each segment's record gains `conn` (the connection that answered) and, when hedged, `hedged_at_ms`
and `won` (`first` or `hedge`); `hedge` is `none-idle` when no connection was free to take it.
Each background fetch logs its end to stderr as a JSON line. The receiver is loaded unchanged from
beside this file.
"""

import http.client
import importlib.util
import json
import os
import queue
import sys
import threading
import time
import urllib.parse


def note(ev, **kw):
	print(json.dumps(dict(t=round(time.time(), 3), ev=ev, **kw)), file=sys.stderr, flush=True)


class Leg:
	"""One keep-alive connection, reopened on any failure; `busy` while a fetch holds it."""

	def __init__(self, name, host, https, timeout):
		self.name, self.host, self.https, self.timeout = name, host, https, timeout
		self.conn = None
		self.busy = False

	def run(self, path, headers):
		if self.conn is None:
			cls = http.client.HTTPSConnection if self.https else http.client.HTTPConnection
			self.conn = cls(self.host, timeout=self.timeout)
		t0 = time.time()
		try:
			self.conn.request("GET", path, headers=headers)
			r = self.conn.getresponse()
			ttfb = time.time() - t0
			body = r.read()
		except Exception:
			self.conn.close()
			self.conn = None
			raise
		hdr = {k: r.getheader(h) for k, h in (("cache", "X-Cache"), ("age", "Age"), ("pop", "X-Amz-Cf-Pop"))}
		return r.status, body, ttfb, hdr


class HedgedClient:
	"""b8-hls-recv.py's Client, over two connections."""

	def __init__(self, base, headers, timeout, hedge_s):
		u = urllib.parse.urlsplit(base)
		self.headers = dict(headers, **{"User-Agent": "b8-hls-recv/1"})
		self.legs = [Leg(n, u.netloc, u.scheme == "https", timeout) for n in ("a", "b")]
		self.hedge_s = hedge_s
		self.turn = 0
		self.lock = threading.Lock()
		self.t0 = None

	def take(self, first):
		with self.lock:
			for leg in (self.legs[first], self.legs[1 - first]):
				if not leg.busy:
					leg.busy = True
					return leg
		return None

	def free(self, leg):
		with self.lock:
			leg.busy = False

	def get(self, url, extra=None):
		u = urllib.parse.urlsplit(url)
		path = u.path + ("?" + u.query if u.query else "")
		headers = dict(self.headers, **(extra or {}))
		t0 = self.t0 = time.time()
		if u.path.endswith(".m3u8"):
			leg = self.take(0)
			if leg is None:
				leg = Leg("x", self.legs[0].host, self.legs[0].https, self.legs[0].timeout)
				leg.busy = True
			warm = self.take(self.legs.index(leg) ^ 1) if leg in self.legs else None
			done = threading.Event()
			if warm is not None:

				def keep_warm():
					try:
						warm.run(path, headers)
					except Exception:  # noqa: BLE001 - the next fetch on it reopens it
						pass
					finally:
						self.free(warm)
						done.set()

				threading.Thread(target=keep_warm, daemon=True).start()
			try:
				status, body, ttfb, hdr = leg.run(path, headers)
			finally:
				self.free(leg)
			if warm is not None:
				done.wait(0.05)
			return status, body, self.meta(status, body, ttfb, t0, hdr, leg)
		first = self.take(self.turn)
		self.turn ^= 1
		if first is None:
			first = Leg("x", self.legs[0].host, self.legs[0].https, self.legs[0].timeout)
			first.busy = True
		results = queue.Queue()

		def work(leg, tag):
			t = time.time()
			try:
				results.put((tag, leg, leg.run(path, headers), None))
				ok = True
			except Exception as e:  # noqa: BLE001 - reported to the caller as any fetch failure
				results.put((tag, leg, None, e))
				ok = False
			finally:
				self.free(leg)
			if tag == state.get("loser"):
				note("hedge-loser-end", conn=leg.name, tag=tag, ok=ok, ms=round((time.time() - t) * 1000, 1), path=path)

		state = {}
		threading.Thread(target=work, args=(first, "first"), daemon=True).start()
		pending, extra_meta = 1, {}
		try:
			got = results.get(timeout=self.hedge_s)
		except queue.Empty:
			second = self.take(self.legs.index(first) ^ 1 if first in self.legs else 0)
			if second is None:
				extra_meta["hedge"] = "none-idle"
			else:
				extra_meta["hedged_at_ms"] = round((time.time() - t0) * 1000, 1)
				threading.Thread(target=work, args=(second, "hedge"), daemon=True).start()
				pending += 1
			got = results.get()
		tag, leg, res, err = got
		pending -= 1
		if err is not None and pending:
			tag, leg, res, err = results.get()
			pending -= 1
		if pending:
			state["loser"] = "hedge" if tag == "first" else "first"
		if err is not None:
			raise err
		status, body, ttfb, hdr = res
		meta = self.meta(status, body, ttfb, t0, hdr, leg)
		meta.update(extra_meta)
		if "hedged_at_ms" in extra_meta:
			meta["won"] = tag
		return status, body, meta

	@staticmethod
	def meta(status, body, ttfb, t0, hdr, leg):
		return dict(status=status, bytes=len(body), ttfb_ms=round(ttfb * 1000, 1),
					ms=round((time.time() - t0) * 1000, 1), conn=leg.name, **hdr)


def main():
	argv = sys.argv[1:]
	try:
		i = argv.index("--hedge-ms")
		hedge_s = float(argv[i + 1]) / 1000.0
		del argv[i:i + 2]
	except (ValueError, IndexError):
		sys.exit("usage: t74-hedge.py --hedge-ms MS URL OUT [b8-hls-recv.py's options]")
	path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "b8-hls-recv.py")
	spec = importlib.util.spec_from_file_location("b8_hls_recv", path)
	b8 = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(b8)
	b8.Client = lambda base, headers, timeout: HedgedClient(base, headers, timeout, hedge_s)
	note("t74-hedge", hedge_ms=round(hedge_s * 1000), conns=2)
	sys.argv = [path] + argv
	b8.main()


if __name__ == "__main__":
	main()

#!/usr/bin/env python3
"""A stock HLS fetcher under a supervisor, in b8-hls-recv.py's place, for P1-aq.

    P1AQ_FETCHER=tsp|gst p1aq-stock-recv.py URL - [--seconds S] [--header 'Name: value'] [--log FILE]
    sudo B8=<this file> P1AQ_FETCHER=tsp bash t59-legs.sh leg-start a DIR URL SECONDS

t59-legs.sh runs its fetcher as $B8 with b8-hls-recv.py's arguments; with B8 pointing here, the leg
runs TSDuck's `tsp -I hls --live` or GStreamer's `hlsdemux` instead, restarted a second after it
exits, with stdout held open so that the groomer sees one stream. `tsp` runs with --realtime: its
file output otherwise writes in batches of up to 10,000 packets, holding a segment's tail back.
GStreamer 1.28's demuxers, hlsdemux and hlsdemux2 alike, send a custom header on the first playlist
request only, so the gst fetcher reaches an origin that checks no header key.

The stock fetchers log no segments, so the log records what reaches stdout, in b8-hls-recv.py's
format so that t61-report.py reads it unchanged: a "seg" event when output stops for --gap-ms,
timed at its last byte (one per segment while the fetcher keeps up), and "fetcher-start" and
"fetcher-exit" events, the exit with its status and run time.
"""
import argparse
import json
import os
import select
import signal
import subprocess
import sys
import time


def fetcher(kind, url, headers):
	if kind == "tsp":
		cmd = ["tsp", "--realtime", "-I", "hls", url, "--live"]
		for h in headers:
			cmd += ["--headers", h]
		return cmd + ["-O", "file"]
	if kind == "gst":
		src = ["souphttpsrc", f"location={url}"]
		if headers:
			fields = ",".join(
				"{}=(string)\"{}\"".format(*[p.strip() for p in h.split(":", 1)]) for h in headers)
			src.append(f"extra-headers=headers,{fields}")
		return ["gst-launch-1.0", "-q", *src, "!", "hlsdemux", "!", "fdsink", "fd=1", "sync=false"]
	sys.exit(f"P1AQ_FETCHER must be tsp or gst, not {kind!r}")


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("url")
	ap.add_argument("out", help="'-' only")
	ap.add_argument("--seconds", type=float, default=0, help="how long to run; 0 runs until stopped")
	ap.add_argument("--header", action="append", default=[])
	ap.add_argument("--log")
	ap.add_argument("--gap-ms", type=float, default=500)
	ap.add_argument("--restart-ms", type=float, default=1000)
	ap.add_argument("--release-ms", help="not supported: b8-hls-recv.py's alone")
	a = ap.parse_args()
	if a.out != "-" or a.release_ms:
		sys.exit("p1aq-stock-recv.py writes to stdout only, and has no --release-ms")
	kind = os.environ.get("P1AQ_FETCHER", "")
	cmd = fetcher(kind, a.url, a.header)
	log = open(a.log, "a", buffering=1) if a.log else None

	def ev(e, **kw):
		if log:
			log.write(json.dumps({"t": round(time.time(), 3), "ev": e, **kw}) + "\n")

	stop = time.time() + a.seconds if a.seconds else None
	signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
	out = sys.stdout.buffer
	gap, n = a.gap_ms / 1000.0, 0
	ev("join", fetcher=kind, gap_ms=a.gap_ms)
	try:
		while stop is None or time.time() < stop:
			t0 = time.time()
			p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=sys.stderr, start_new_session=True)
			ev("fetcher-start", pid=p.pid)
			fd, burst, last = p.stdout.fileno(), 0, 0.0
			while True:
				r, _, _ = select.select([fd], [], [], 0.05)
				now = time.time()
				if r:
					b = os.read(fd, 1 << 16)
					if not b:
						break
					out.write(b)
					out.flush()
					burst, last = burst + len(b), now
				elif burst and now - last >= gap:
					n += 1
					ev("seg", t=round(last, 3), name=f"burst-{n}", bytes=burst)
					burst = 0
				if stop is not None and now >= stop:
					os.killpg(p.pid, signal.SIGTERM)
					break
			if burst:
				n += 1
				ev("seg", t=round(last, 3), name=f"burst-{n}", bytes=burst)
			# tsp can ignore SIGTERM while its HLS input blocks, and would hold the groomer's input open.
			try:
				rc = p.wait(timeout=3)
			except subprocess.TimeoutExpired:
				os.killpg(p.pid, signal.SIGKILL)
				rc = p.wait()
			ev("fetcher-exit", status=rc, ran_s=round(time.time() - t0, 3))
			if stop is not None and time.time() >= stop:
				break
			time.sleep(a.restart_ms / 1000.0)
	except BrokenPipeError:
		ev("downstream-closed")
	finally:
		try:
			os.killpg(p.pid, signal.SIGKILL)
		except (NameError, ProcessLookupError):
			pass


if __name__ == "__main__":
	main()

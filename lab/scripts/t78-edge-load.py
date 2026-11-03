#!/usr/bin/env python3
"""Many CDN edges on one segmented origin (lab/test-78-*.md): N simulated edges, each polling the
playlist as an edge revalidating a max-age=1 object would and fetching every newly listed segment
once, as an edge filling its cache would.

    t78-edge-load.py URL --edges N [--seconds 120] [--procs 8] [--poll 1.0] [--header NAME:FILE]
                     [--json OUT]

URL is the origin's playlist (http://host:port/g/index.m3u8). The edges are spread over --procs
processes, each running its edges as threads over keep-alive HTTP/1.1 connections; each edge
starts at a random phase within one poll and fetches only segments listed after its first poll.
A segment's body is read and discarded.

Prints, and with --json writes: fetches and errors by kind, and the playlist's and the segments'
time to first byte and total time (median, 99th percentile, maximum, ms), bytes and the rate they
imply.
"""
import argparse
import http.client
import json
import multiprocessing
import random
import re
import statistics
import threading
import time
import urllib.parse


def edge(url, headers, poll, until, out):
	u = urllib.parse.urlsplit(url)
	base = u.path.rsplit("/", 1)[0] + "/"
	conn = None
	seen = set()
	time.sleep(random.random() * poll)
	while time.monotonic() < until:
		t_poll = time.monotonic()
		try:
			if conn is None:
				conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=10)
			body, ttfb, total = get(conn, u.path, headers)
			out["playlist"].append((ttfb, total))
			names = re.findall(r"^(seg-\d+\.ts)$", body.decode(), re.M)
			new = [n for n in names if n not in seen]
			if seen:
				for n in new:
					data, ttfb, total = get(conn, base + n, headers)
					out["segment"].append((ttfb, total))
					out["bytes"] += len(data)
			seen.update(names)
		except (OSError, http.client.HTTPException, ValueError) as e:
			out["errors"][type(e).__name__] = out["errors"].get(type(e).__name__, 0) + 1
			if conn is not None:
				conn.close()
			conn = None
		time.sleep(max(0.0, poll - (time.monotonic() - t_poll)))


def get(conn, path, headers):
	t0 = time.monotonic()
	conn.request("GET", path, headers=headers)
	r = conn.getresponse()
	ttfb = time.monotonic() - t0
	data = r.read()
	total = time.monotonic() - t0
	if r.status != 200:
		raise ValueError(f"http {r.status}")
	return data, ttfb * 1000, total * 1000


def proc(url, headers, poll, edges, seconds, q):
	until = time.monotonic() + seconds
	out = {"playlist": [], "segment": [], "bytes": 0, "errors": {}}
	threads = [threading.Thread(target=edge, args=(url, headers, poll, until, out), daemon=True) for _ in range(edges)]
	for t in threads:
		t.start()
	for t in threads:
		t.join()
	q.put(out)


def pct(xs, p):
	if not xs:
		return None
	xs = sorted(xs)
	return round(xs[min(len(xs) - 1, int(p / 100 * len(xs)))], 1)


def summary(rows):
	ttfb = [r[0] for r in rows]
	total = [r[1] for r in rows]
	return {
		"n": len(rows),
		"ttfb_ms": {"p50": pct(ttfb, 50), "p99": pct(ttfb, 99), "max": round(max(ttfb), 1) if ttfb else None},
		"total_ms": {"p50": pct(total, 50), "p99": pct(total, 99), "max": round(max(total), 1) if total else None,
					"mean": round(statistics.mean(total), 1) if total else None},
	}


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("url")
	ap.add_argument("--edges", type=int, required=True)
	ap.add_argument("--seconds", type=float, default=120)
	ap.add_argument("--procs", type=int, default=8)
	ap.add_argument("--poll", type=float, default=1.0)
	ap.add_argument("--header", metavar="NAME:FILE")
	ap.add_argument("--json")
	args = ap.parse_args()
	headers = {}
	if args.header:
		name, path = args.header.split(":", 1)
		with open(path) as f:
			headers[name] = f.read().strip()
	procs = min(args.procs, args.edges)
	share = [args.edges // procs + (1 if i < args.edges % procs else 0) for i in range(procs)]
	q = multiprocessing.Queue()
	t0 = time.time()
	ps = [multiprocessing.Process(target=proc, args=(args.url, headers, args.poll, n, args.seconds, q)) for n in share]
	for p in ps:
		p.start()
	outs = [q.get() for _ in ps]
	for p in ps:
		p.join()
	playlist = [r for o in outs for r in o["playlist"]]
	segment = [r for o in outs for r in o["segment"]]
	errors = {}
	for o in outs:
		for k, v in o["errors"].items():
			errors[k] = errors.get(k, 0) + v
	nbytes = sum(o["bytes"] for o in outs)
	res = {
		"edges": args.edges, "seconds": args.seconds, "start": round(t0, 3),
		"playlist": summary(playlist), "segment": summary(segment),
		"errors": errors, "bytes": nbytes, "gbps": round(nbytes * 8 / args.seconds / 1e9, 3),
	}
	print(json.dumps(res))
	if args.json:
		with open(args.json, "w") as f:
			json.dump(res, f, indent=1)


if __name__ == "__main__":
	main()

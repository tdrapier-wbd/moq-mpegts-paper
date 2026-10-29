#!/usr/bin/env python3
"""T30 torn-read probe: fetch every segment the moment a playlist lists it, and again later.

Polls the playlist every --poll-ms. Each newly listed segment is fetched at once and then at
each offset in --refetch-ms; every response's status, length and SHA-256 are logged. A segment
is torn when any fetch's body differs from the one its last fetch returned, or when a body is
not a whole number of 188-byte packets.

Usage:
    t30-hammer.py URL --seconds 60 --log hammer.csv [--poll-ms 20] [--refetch-ms 100,500,1500]
"""

import argparse
import hashlib
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def fetch(url: str, timeout: float) -> tuple[int, bytes]:
	try:
		with urllib.request.urlopen(url, timeout=timeout) as r:
			return r.status, r.read()
	except urllib.error.HTTPError as e:
		return e.code, b""
	except Exception:
		return 0, b""


def main() -> int:
	ap = argparse.ArgumentParser()
	ap.add_argument("url")
	ap.add_argument("--seconds", type=float, required=True)
	ap.add_argument("--log", required=True)
	ap.add_argument("--poll-ms", type=float, default=20)
	ap.add_argument("--refetch-ms", default="100,500,1500")
	ap.add_argument("--timeout", type=float, default=5)
	args = ap.parse_args()
	offsets = [0.0] + [float(x) / 1000 for x in args.refetch_ms.split(",") if x]

	rows: list[tuple] = []
	lock = threading.Lock()
	seen: set[str] = set()
	threads: list[threading.Thread] = []

	def probe(uri: str, listed_at: float) -> None:
		for off in offsets:
			delay = listed_at + off - time.monotonic()
			if delay > 0:
				time.sleep(delay)
			status, body = fetch(urllib.parse.urljoin(args.url, uri), args.timeout)
			with lock:
				rows.append((uri, off, status, len(body), hashlib.sha256(body).hexdigest()[:16]))

	end = time.monotonic() + args.seconds
	while time.monotonic() < end:
		status, body = fetch(args.url, args.timeout)
		if status == 200:
			for line in body.decode(errors="replace").splitlines():
				line = line.strip()
				if line and not line.startswith("#") and line not in seen:
					seen.add(line)
					th = threading.Thread(target=probe, args=(line, time.monotonic()), daemon=True)
					th.start()
					threads.append(th)
		time.sleep(args.poll_ms / 1000)
	for th in threads:
		th.join(timeout=offsets[-1] + args.timeout + 1)

	by_uri: dict[str, list[tuple]] = {}
	with open(args.log, "w") as f:
		f.write("uri,offset_s,status,bytes,sha\n")
		for r in sorted(rows):
			f.write(",".join(str(x) for x in r) + "\n")
			by_uri.setdefault(r[0], []).append(r)
	torn = misaligned = non200 = 0
	for fetches in by_uri.values():
		fetches.sort(key=lambda r: r[1])
		last = fetches[-1]
		if any(r[2] == 200 and last[2] == 200 and r[4] != last[4] for r in fetches):
			torn += 1
		misaligned += sum(1 for r in fetches if r[2] == 200 and r[3] % 188)
		non200 += sum(1 for r in fetches if r[2] != 200)
	print(f"HAMMER segments={len(by_uri)} fetches={len(rows)} torn_segments={torn} "
		f"misaligned_bodies={misaligned} non200={non200}")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())

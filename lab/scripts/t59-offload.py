#!/usr/bin/env python3
"""T59 offload: what one origin served CloudFront over a window, per segment and per playlist.

Usage: t59-offload.py ACCESS_LOG FROM_EPOCH TO_EPOCH [B8_LOG.jsonl ...]

Reads t59-pathway.sh's nginx log format ("$msec $status $request_uri $body_bytes_sent
$request_time $remote_addr"). Segment requests are counted per name, for names first requested
inside the window, so a name half outside it is not under-counted. Each b8-hls-recv.py log
named adds what that receiver saw: segments fetched and CloudFront's X-Cache verdicts.
"""

import json
import sys
from collections import Counter

log, lo, hi = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
seg_first, seg_count, seg_bytes = {}, Counter(), 0
playlist, edges = Counter(), set()
with open(log) as f:
	for line in f:
		parts = line.split()
		if len(parts) < 6:
			continue
		t, status, uri, size = float(parts[0]), parts[1], parts[2], int(parts[3])
		if uri.endswith(".ts"):
			seg_first.setdefault(uri, t)
			if lo <= seg_first[uri] < hi:
				seg_count[uri] += 1
				seg_bytes += size
				edges.add(parts[5])
		elif uri.endswith(".m3u8") and lo <= t < hi:
			playlist[status] += 1
			edges.add(parts[5])

span = hi - lo
per = Counter(seg_count.values())
print(f"window {span:.0f} s: {len(seg_count)} segments, {sum(seg_count.values())} origin segment requests, "
	f"{seg_bytes / 1e6:.1f} MB; requests per segment {dict(sorted(per.items()))}")
print(f"playlist requests {sum(playlist.values())} ({sum(playlist.values()) / span:.2f}/s) by status {dict(playlist)}; "
	f"{len(edges)} distinct CloudFront addresses")

for path in sys.argv[4:]:
	segs, cache, pops = 0, Counter(), Counter()
	with open(path) as f:
		for line in f:
			e = json.loads(line)
			if e.get("ev") != "seg" or not lo <= e.get("t", 0) < hi:
				continue
			segs += 1
			cache[(e.get("cache") or "-").split(" ")[0]] += 1
			pops[e.get("pop") or "-"] += 1
	print(f"{path}: {segs} segments; X-Cache {dict(cache)}; pops {dict(pops)}")

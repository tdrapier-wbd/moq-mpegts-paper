#!/usr/bin/env python3
"""b8-hls-recv.py's CMCD v2, offline: a live origin of 1 s segments, one of which is never served
and one served on its second request, and a collector for event mode.

  lab/scripts/b8-cmcd-test.py [--recv PATH]

Passes if, with --cmcd headers, every request carries the session in CMCD-Session, ot and d in
CMCD-Object, sn counting the requests, keys in alphabetical order, su on the first segment and on
the one after the lost segment, bs on the request after the loss, mtp and nor on segments, and
msd once; with --cmcd query, the same keys in the CMCD query argument and no CMCD header; without
--cmcd, neither. The collector must receive application/cmcd records each carrying e, sid, sn, ts
and v=2, numbered in order, play states starting, playing, rebuffering, playing, quit, a response
record per segment fetch including the refused one, an error naming the lost segment and an
interval report. With --ts-counters, where the test posts two TSDuck reports (TR 101 290 counters
in InfluxDB line protocol, one counter already raised in the first, three rising in the second,
and a severity-4 and a per-PID line in each that must not count): no request before the first
report carries the counters' keys, every request after it carries each priority's total in
CMCD-Request (1, 0, 0, then 4, 1, 0), an error record names each risen counter and no other, an
interval report carries the totals, and both reports are forwarded unchanged. Exits 1 otherwise.
"""
import argparse
import http.client
import http.server
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
SEG_S, WINDOW, LOST, FLAKY = 1.0, 4, 3, 5
T0 = time.time()
REQUESTS, POSTS, FLAKY_SEEN = [], [], set()
NULLS = (b"\x47\x1f\xff\x10" + b"\xff" * 184) * 50
REPORT_AT = (1.5, 3.5)  # seconds after the receiver starts


def report(pat, pid, cc, pts):
	"""One TSDuck influx post: four TR 101 290 counters, an untracked total and a per-PID line."""
	lines = [f"counter,name=pat_error,severity=1,scope=ts,tsid=0 value={pat} 1",
			 f"counter,name=pid_error,severity=1,scope=ts,tsid=0 value={pid} 1",
			 f"counter,name=continuity_count_error,severity=1,scope=ts,tsid=0 value={cc} 1",
			 f"counter,name=pts_error,severity=2,scope=ts,tsid=0 value={pts} 1",
			 "counter,name=nit_error,severity=3,scope=ts,tsid=0 value=0 1",
			 f"counter,name=packet_count,severity=4,scope=ts,tsid=0 value={1000 + pid} 1",
			 f"counter,name=pid_error,severity=1,scope=pid,pid=256 value={9 * pid} 1"]
	return "\n".join(lines) + "\n"


REPORTS = (report(1, 0, 0, 0), report(1, 2, 1, 1))


def free_port():
	s = socket.socket()
	s.bind(("127.0.0.1", 0))
	port = s.getsockname()[1]
	s.close()
	return port


def post_reports(port, t_start, sent):
	"""Post REPORTS to the receiver's listener at REPORT_AT, as tsp -P influx would."""
	for at, body in zip(REPORT_AT, REPORTS):
		time.sleep(max(0.0, t_start + at - time.time()))
		for _ in range(20):
			try:
				conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
				conn.request("POST", "/api/v2/write?org=lab&bucket=t&precision=ms", body=body.encode(),
							 headers={"Content-Type": "text/plain; charset=utf-8"})
				status = conn.getresponse().status
				conn.close()
				if status == 204:
					sent.append(time.time())
				break
			except ConnectionRefusedError:  # not listening yet; a listener that fails a report is a failure
				time.sleep(0.05)
			except OSError:
				break


def split_top(s):
	"""Split a CMCD payload on the commas outside quotes and inner lists."""
	out, cur, quoted, depth, esc = [], "", False, 0, False
	for ch in s:
		if esc:
			cur, esc = cur + ch, False
			continue
		if ch == "\\" and quoted:
			cur, esc = cur + ch, True
			continue
		if ch == '"':
			quoted = not quoted
		elif not quoted and ch == "(":
			depth += 1
		elif not quoted and ch == ")":
			depth -= 1
		if ch == "," and not quoted and depth == 0:
			out.append(cur)
			cur = ""
		else:
			cur += ch
	if cur:
		out.append(cur)
	return out


def parse(payload):
	"""Return [(key, raw value or True)] in payload order."""
	pairs = []
	for item in split_top(payload):
		k, sep, v = item.partition("=")
		pairs.append((k, v if sep else True))
	return pairs


class Origin(http.server.BaseHTTPRequestHandler):
	def log_message(self, *a):
		pass

	def do_GET(self):
		u = urllib.parse.urlsplit(self.path)
		REQUESTS.append(dict(t=time.time(), path=u.path, query=urllib.parse.parse_qs(u.query),
							 headers={k: v for k, v in self.headers.items() if k.lower().startswith("cmcd-")}))
		latest = int((time.time() - T0) / SEG_S) - 1
		if u.path == "/live/index.m3u8":
			if latest < 0:
				return self.reply(404, b"")
			first = max(0, latest - WINDOW + 1)
			lines = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{int(SEG_S)}",
					 f"#EXT-X-MEDIA-SEQUENCE:{first}"]
			for n in range(first, latest + 1):
				pdt = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(T0 + n * SEG_S))
				lines += [f"#EXT-X-PROGRAM-DATE-TIME:{pdt}.000Z", f"#EXTINF:{SEG_S:.3f},", f"seg-{n}.ts"]
			return self.reply(200, ("\n".join(lines) + "\n").encode(), "application/vnd.apple.mpegurl")
		if u.path.startswith("/live/seg-"):
			n = int(u.path[len("/live/seg-"):-3])
			if n == LOST or n > latest:
				return self.reply(404, b"")
			if n == FLAKY and n not in FLAKY_SEEN:
				FLAKY_SEEN.add(n)
				return self.reply(503, b"")
			return self.reply(200, NULLS, "video/mp2t")
		self.reply(404, b"")

	def do_POST(self):
		body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
		POSTS.append(dict(path=self.path, ctype=self.headers.get("Content-Type"), body=body))
		self.reply(204, b"")

	def reply(self, status, body, ctype="text/plain"):
		self.send_response(status)
		self.send_header("Content-Type", ctype)
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)


def run(recv, port, workdir, mode):
	global T0
	REQUESTS.clear()
	POSTS.clear()
	FLAKY_SEEN.clear()
	T0 = time.time() - 3.5  # three segments listed at the join, so nor has a next to name
	cmd = [sys.executable, recv, f"http://127.0.0.1:{port}/live/index.m3u8", os.path.join(workdir, f"out-{mode}.ts"),
		   "--seconds", "7", "--edge", "3", "--poll", "100", "--give-up-ms", "500",
		   "--log", os.path.join(workdir, f"log-{mode}.jsonl")]
	if mode != "none":
		cmd += ["--cmcd", "headers" if mode == "counters" else mode,
				"--cmcd-collector", f"http://127.0.0.1:{port}/cmcd", "--cmcd-interval", "2"]
	sent, poster = [], None
	if mode == "counters":
		cport = free_port()
		cmd += ["--ts-counters", str(cport), "--ts-counters-forward", f"http://127.0.0.1:{port}/fwd"]
		poster = threading.Thread(target=post_reports, args=(cport, time.time(), sent), daemon=True)
		poster.start()
	rc = subprocess.run(cmd, stderr=subprocess.PIPE, text=True, timeout=30)
	if poster:
		poster.join(timeout=5)
	time.sleep(0.3)
	return rc, list(REQUESTS), list(POSTS), sent


def check_counters(reqs, posts, sent):
	"""--ts-counters: the totals on each request after a report, an error per risen counter."""
	fails = []
	if len(sent) != len(REPORTS):
		return [f"counters: {len(sent)} of {len(REPORTS)} reports reached the receiver"]
	want = ({}, {"tr101290-p1": "1", "tr101290-p2": "0", "tr101290-p3": "0"},
			{"tr101290-p1": "4", "tr101290-p2": "1", "tr101290-p3": "0"})
	settle = 0.3  # a request in flight as a report lands may carry either total
	for r in reqs:
		shard = dict(parse(r["headers"].get("CMCD-Request", "")))
		got = {k: v for k, v in shard.items() if k.startswith("tr101290-")}
		stage = sum(r["t"] >= s for s in sent)
		if any(abs(r["t"] - s) < settle for s in sent):
			continue
		if got != want[stage]:
			fails.append(f"counters: {r['path']} {stage} report(s) in carried {got}, not {want[stage]}")
			break
	recs = [dict(parse(line)) for p in posts if p["path"] == "/cmcd" for line in p["body"].split("\n")]
	ecs = sorted(r["ec"] for r in recs if r.get("e") == "e" and "tr101290" in r.get("ec", ""))
	if ecs != sorted(f'("tr101290-{n}")' for n in ("pid_error", "continuity_count_error", "pts_error")):
		fails.append(f"counters: error records {ecs}")
	if not any(r.get("e") == "t" and r.get("tr101290-p1") for r in recs):
		fails.append("counters: no interval report carried the totals")
	fwd = [p for p in posts if p["path"].startswith("/fwd/api/v2/write")]
	if [p["body"] for p in fwd] != list(REPORTS):
		fails.append(f"counters: {len(fwd)} reports forwarded, not both unchanged")
	return fails


def check(mode, rc, reqs, posts):
	fails = []
	if rc.returncode:
		return [f"{mode}: the receiver exited {rc.returncode}: {rc.stderr.strip()[-200:]}"]
	segs = [r for r in reqs if r["path"].startswith("/live/seg-")]
	if not segs or not any(r["path"] == f"/live/seg-{LOST}.ts" for r in segs):
		return [f"{mode}: the run never reached segment {LOST}"]
	if mode == "none":
		if any(r["headers"] or "CMCD" in r["query"] for r in reqs):
			fails.append("none: a request carried CMCD without --cmcd")
		if posts:
			fails.append("none: something was posted without a collector")
		return fails

	keys = []  # per request: {key: value}, and each shard's key order
	for r in reqs:
		if mode == "headers":
			if "CMCD" in r["query"]:
				fails.append("headers: a request carried the CMCD query argument")
			shards = {h.lower(): parse(v) for h, v in r["headers"].items()}
		else:
			if r["headers"]:
				fails.append("query: a request carried CMCD headers")
			shards = {"query": parse(r["query"].get("CMCD", [""])[0])}
		for name, pairs in shards.items():
			if [k for k, _ in pairs] != sorted(k for k, _ in pairs):
				fails.append(f"{mode}: keys out of order in {name}: {[k for k, _ in pairs]}")
		flat = {k: v for pairs in shards.values() for k, v in pairs}
		if mode == "headers":
			for k, shard in (("v", "cmcd-session"), ("sid", "cmcd-session"), ("ot", "cmcd-object"),
							 ("sn", "cmcd-request")):
				if k not in dict(shards.get(shard, [])):
					fails.append(f"headers: {k} missing from {shard} on {r['path']}")
			if "bs" in flat and "bs" not in dict(shards.get("cmcd-status", [])):
				fails.append("headers: bs outside CMCD-Status")
		keys.append((r["path"], flat))

	sids = {k.get("sid") for _, k in keys}
	if len(sids) != 1 or not all(k.get("v") == "2" and k.get("sf") == "h" and k.get("st") == "l"
								 and k.get("cid") == '"/live/index.m3u8"' for _, k in keys):
		fails.append(f"{mode}: the session keys are not on every request alike")
	sns = [int(k.get("sn", -1)) for _, k in keys]
	if sns != list(range(len(keys))):
		fails.append(f"{mode}: sn does not count the requests: {sns[:12]}")
	for path, k in keys:
		want = "m" if path.endswith(".m3u8") else "av"
		if k.get("ot") != want:
			fails.append(f"{mode}: ot={k.get('ot')} on {path}")
		if want == "av" and k.get("d") != "1000":
			fails.append(f"{mode}: d={k.get('d')} on {path}")
	seg_keys = [(p, k) for p, k in keys if p.startswith("/live/seg-")]
	if "su" not in seg_keys[0][1]:
		fails.append(f"{mode}: the first segment lacks su")
	after = [k for p, k in seg_keys if p == f"/live/seg-{LOST + 1}.ts"]
	if not after or "su" not in after[0]:
		fails.append(f"{mode}: the segment after the lost one lacks su")
	lost_i = max(i for i, (p, _) in enumerate(keys) if p == f"/live/seg-{LOST}.ts")
	if "bs" not in keys[lost_i + 1][1]:
		fails.append(f"{mode}: the request after the loss lacks bs")
	if sum("bs" in k for _, k in keys) != 1:
		fails.append(f"{mode}: bs sent {sum('bs' in k for _, k in keys)} times, not once")
	if sum("msd" in k for _, k in keys) != 1:
		fails.append(f"{mode}: msd sent {sum('msd' in k for _, k in keys)} times, not once")
	if all("su" in k for _, k in seg_keys):
		fails.append(f"{mode}: su is on every segment")
	if not any("mtp" in k and int(k["mtp"]) % 100 == 0 for _, k in seg_keys[1:]):
		fails.append(f"{mode}: no segment carried mtp in hundreds")
	if not any(str(k.get("nor", "")).startswith('("seg-') for _, k in seg_keys):
		fails.append(f"{mode}: no segment named the next in nor")

	if not posts:
		return fails + [f"{mode}: nothing reached the collector"]
	if any(p["ctype"] != "application/cmcd" or p["path"] != "/cmcd" for p in posts):
		fails.append(f"{mode}: a post was not application/cmcd to the collector")
	recs = [dict(parse(line)) for p in posts for line in p["body"].split("\n")]
	for r in recs:
		if not all(k in r for k in ("e", "sid", "sn", "ts")) or r.get("v") != "2":
			fails.append(f"{mode}: a record lacks e, sid, sn, ts or v=2: {r}")
			break
	if [int(r.get("sn", -1)) for r in recs] != list(range(len(recs))):
		fails.append(f"{mode}: event sn does not count the records")
	sta = [r.get("sta") for r in recs if r.get("e") == "ps"]
	if sta != ["s", "p", "r", "p", "q"]:
		fails.append(f"{mode}: play states {sta}, not s p r p q")
	rr = [r for r in recs if r.get("e") == "rr" and r.get("ot") == "av"]
	if len(rr) != len(segs):
		fails.append(f"{mode}: {len(rr)} response records for {len(segs)} segment fetches")
	if not any(r.get("rc") == "404" and r.get("url", "").endswith(f'seg-{LOST}.ts"') for r in rr):
		fails.append(f"{mode}: no response record for the refused segment")
	if not any(r.get("rc") == "200" and "ttfb" in r and "ttlb" in r for r in rr):
		fails.append(f"{mode}: no response record with rc, ttfb and ttlb")
	if not any(r.get("e") == "e" and r.get("ec") == '("seg-lost")' for r in recs):
		fails.append(f"{mode}: no error record naming the lost segment")
	if not any(r.get("e") == "t" for r in recs):
		fails.append(f"{mode}: no interval report")
	return fails


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("--recv", default=os.path.join(HERE, "b8-hls-recv.py"))
	args = ap.parse_args()
	srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
	threading.Thread(target=srv.serve_forever, daemon=True).start()
	port = srv.server_address[1]
	fails = []
	with tempfile.TemporaryDirectory() as w:
		for mode in ("headers", "query", "none", "counters"):
			rc, reqs, posts, sent = run(args.recv, port, w, mode)
			f = check("headers" if mode == "counters" else mode, rc, reqs,
					  [p for p in posts if p["path"] == "/cmcd"])
			if mode == "counters":
				f += check_counters(reqs, posts, sent)
			n_seg = sum(r["path"].startswith("/live/seg-") for r in reqs)
			print(f"{mode}: {len(reqs)} requests, {n_seg} segment fetches, {len(posts)} posts, "
				  f"{'ok' if not f else f'{len(f)} failures'}")
			fails += f
	srv.shutdown()
	for f in fails:
		print("FAIL:", f)
	print("PASS" if not fails else "FAIL")
	sys.exit(1 if fails else 0)


if __name__ == "__main__":
	main()

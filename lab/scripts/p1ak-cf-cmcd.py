#!/usr/bin/env python3
"""P1-ak, the CloudFront half: which of B-8's CMCD keys a CloudFront real-time log keeps.

  p1ak-cf-cmcd.py capture CAPTURE.json            b8-hls-recv.py's requests in b8-cmcd-test.py's
                                                  counters run, header form then query form
  p1ak-cf-cmcd.py replay CAPTURE.json DOMAIN SENT.json TAG
                                                  the controls, then every captured request in
                                                  order, each form under its own path, index in
                                                  it; then each again with its v=2 removed (v1)
  p1ak-cf-cmcd.py read STREAM FIELDS.txt LOG.jsonl
                                                  every record in the Kinesis stream, one shard,
                                                  as {field: value}
  p1ak-cf-cmcd.py grade CAPTURE.json SENT.json LOG.jsonl TAG

The distribution answers every request itself (a viewer-request function), so nothing reaches an
origin. FIELDS.txt names the real-time log config's fields, one per line; CloudFront writes them
in its own documented order, not the config's, and the grader checks the alignment against the
PoP each response named. The controls (lab/test-79): a request with no CMCD, and a CMCD v1
request in each form with keys CloudFront documents. TAG prefixes every path, so replays into
one stream stay apart.
"""
import base64
import http.client
import http.server
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
# CloudFront's dedicated CMCD fields, by the CTA-5004 key each carries.
FIELD = {"br": "cmcd-encoded-bitrate", "bl": "cmcd-buffer-length", "bs": "cmcd-buffer-starvation",
		 "cid": "cmcd-content-id", "d": "cmcd-object-duration", "dl": "cmcd-deadline",
		 "mtp": "cmcd-measured-throughput", "nor": "cmcd-next-object-request", "nrr": "cmcd-next-range-request",
		 "ot": "cmcd-object-type", "pr": "cmcd-playback-rate", "rtp": "cmcd-requested-maximum-throughput",
		 "sf": "cmcd-streaming-format", "sid": "cmcd-session-id", "st": "cmcd-stream-type",
		 "su": "cmcd-startup", "tb": "cmcd-top-bitrate", "v": "cmcd-version"}
# The real-time log's field order, as CloudFront documents and writes it (the fields used here).
ORDER = ["timestamp", "c-ip", "time-to-first-byte", "sc-status", "sc-bytes", "cs-method", "cs-protocol", "cs-host",
		 "cs-uri-stem", "cs-bytes", "x-edge-location", "x-edge-request-id", "x-host-header", "time-taken",
		 "cs-protocol-version", "c-ip-version", "cs-user-agent", "cs-referer", "cs-cookie", "cs-uri-query",
		 "x-edge-response-result-type", "x-forwarded-for", "ssl-protocol", "ssl-cipher", "x-edge-result-type",
		 "fle-encrypted-fields", "fle-status", "sc-content-type", "sc-content-len", "sc-range-start",
		 "sc-range-end", "c-port", "x-edge-detailed-result-type", "c-country", "cs-accept-encoding", "cs-accept",
		 "cache-behavior-path-pattern", "cs-headers", "cs-header-names", "cs-headers-count",
		 "primary-distribution-id", "primary-distribution-dns-name", "origin-fbl", "origin-lbl", "asn",
		 *FIELD.values()]
V1 = {"CMCD-Object": "br=3200,d=4004,ot=v", "CMCD-Request": "bl=21300",
	  "CMCD-Session": 'cid="faec5fc2-ac30-11ea-bb37-0242ac130002",sid="6e2fb550-c457-11e9-bb97-0800200c9a66",v=1'}
V1_WANT = {"br": "3200", "bl": "21300", "cid": "faec5fc2-ac30-11ea-bb37-0242ac130002", "d": "4004", "ot": "v",
		   "sid": "6e2fb550-c457-11e9-bb97-0800200c9a66", "v": "1"}


def load_test():
	spec = importlib.util.spec_from_file_location("b8test", os.path.join(HERE, "b8-cmcd-test.py"))
	t = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(t)
	return t


def capture(out):
	t = load_test()
	srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), t.Origin)
	threading.Thread(target=srv.serve_forever, daemon=True).start()
	port, got = srv.server_address[1], {}
	with tempfile.TemporaryDirectory() as w:
		for form in ("headers", "query"):
			t.REQUESTS.clear()
			t.POSTS.clear()
			t.FLAKY_SEEN.clear()
			t.T0 = time.time() - 3.5
			cport, sent = t.free_port(), []
			cmd = [sys.executable, os.path.join(HERE, "b8-hls-recv.py"), f"http://127.0.0.1:{port}/live/index.m3u8",
				   os.path.join(w, "out.ts"), "--seconds", "7", "--edge", "3", "--poll", "100", "--give-up-ms", "500",
				   "--cmcd", form, "--cmcd-collector", f"http://127.0.0.1:{port}/cmcd", "--cmcd-interval", "2",
				   "--ts-counters", str(cport)]
			poster = threading.Thread(target=t.post_reports, args=(cport, time.time(), sent), daemon=True)
			poster.start()
			subprocess.run(cmd, check=True, timeout=30)
			poster.join(timeout=5)
			got[form] = [dict(path=r["path"], headers=r["headers"], query=r["query"].get("CMCD", [None])[0])
						 for r in t.REQUESTS]
			print(f"{form}: {len(got[form])} requests, {len(sent)} counter reports")
	srv.shutdown()
	json.dump(got, open(out, "w"), indent=1)


def drop_v(payload):
	return ",".join(i for i in split_top(payload) if i != "v=2")


def arms(cap):
	"""(arm, form, [(headers, query)]): B-8's requests as sent, then with v=2 removed."""
	h = [(r["headers"], None) for r in cap["headers"]]
	q = [({}, r["query"]) for r in cap["query"]]
	h1 = [({n: drop_v(p) for n, p in hd.items() if drop_v(p)}, None) for hd, _ in h]
	q1 = [({}, drop_v(qs)) for _, qs in q]
	return [("headers", "headers", h), ("query", "query", q), ("headers-v1", "headers", h1), ("query-v1", "query", q1)]


def replay(cap, domain, out, tag):
	cap = json.load(open(cap))
	base = f"/p1ak/{tag}"
	reqs = [("ctl-none", f"{base}/ctl/none/x.ts", {}),
			("ctl-v1-headers", f"{base}/ctl/v1h/x.ts", V1),
			("ctl-v1-query", f"{base}/ctl/v1q/x.ts?CMCD=" + urllib.parse.quote(
				",".join(sorted(",".join(V1.values()).split(","))), safe=""), {})]
	paths = {"headers": [r["path"] for r in cap["headers"]], "query": [r["path"] for r in cap["query"]]}
	for arm, form, items in arms(cap):
		for i, (headers, query) in enumerate(items):
			p = f"{base}/{arm}/{i:03d}{paths[form][i]}"
			reqs.append((f"{arm}-{i}", p + ("?CMCD=" + urllib.parse.quote(query, safe="") if query else ""), headers))
	conn, sent = None, []
	for name, path, headers in reqs:
		for _ in range(3):
			try:
				if conn is None:
					conn = http.client.HTTPSConnection(domain, timeout=10)
				conn.request("GET", path, headers=dict(headers, **{"User-Agent": "p1ak-cf-cmcd/1"}))
				r = conn.getresponse()
				r.read()
				sent.append(dict(name=name, path=path, status=r.status, pop=r.getheader("X-Amz-Cf-Pop"),
								 t=round(time.time(), 3)))
				break
			except (OSError, http.client.HTTPException):
				conn = None
				time.sleep(0.5)
		time.sleep(0.05)
	json.dump(sent, open(out, "w"), indent=1)
	print(f"{len(sent)} of {len(reqs)} sent; statuses {sorted({s['status'] for s in sent})}; "
		  f"PoPs {sorted({s['pop'] for s in sent if s['pop']})}")


def aws(*args):
	return json.loads(subprocess.run(["aws", *args, "--output", "json"], check=True, capture_output=True,
									 text=True).stdout)


def read(stream, fields, out):
	names = sorted((f.strip() for f in open(fields) if f.strip()), key=ORDER.index)
	shard = aws("kinesis", "list-shards", "--stream-name", stream)["Shards"][0]["ShardId"]
	it = aws("kinesis", "get-shard-iterator", "--stream-name", stream, "--shard-id", shard,
			 "--shard-iterator-type", "TRIM_HORIZON")["ShardIterator"]
	n, idle = 0, 0
	with open(out, "w") as f:
		while it and idle < 3:
			r = aws("kinesis", "get-records", "--shard-iterator", it, "--limit", "1000")
			for rec in r["Records"]:
				for line in base64.b64decode(rec["Data"]).decode("utf-8", "replace").splitlines():
					f.write(json.dumps(dict(zip(names, line.split("\t")))) + "\n")
					n += 1
			idle = idle + 1 if not r["Records"] and r.get("MillisBehindLatest", 0) == 0 else 0
			it = r.get("NextShardIterator")
			time.sleep(0.3)
	print(f"{n} log lines")


def split_top(s):
	out, cur, quoted, depth = [], "", False, 0
	for ch in s:
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
	return out + [cur] if cur else out


def kv(payload):
	return {k: (v if sep else True) for k, sep, v in (item.partition("=") for item in split_top(payload or ""))}


def logged_headers(raw):
	"""cs-headers as {lowercased name: value}; CloudFront URL-encodes it, one header per line."""
	text = urllib.parse.unquote(raw or "")
	out = {}
	for line in text.replace("\r", "").split("\n"):
		name, sep, value = line.partition(":")
		if sep:
			out[name.strip().lower()] = value.strip()
	return out


def grade(cap, sent, logf, tag):
	cap, sent = json.load(open(cap)), json.load(open(sent))
	base = f"/p1ak/{tag}/"
	log = [json.loads(line) for line in open(logf)]
	by_stem = {}
	for rec in log:
		stem = rec.get("cs-uri-stem", "").split("?")[0]
		if stem.startswith(base):
			by_stem.setdefault(stem, []).append(rec)
	counts = {s["name"]: len(by_stem.get(s["path"].split("?")[0], [])) for s in sent}
	missing = [n for n, c in counts.items() if c != 1]
	print(f"complete: {len(sent) - len(missing)} of {len(sent)} requests logged once"
		  + (f"; not once: {missing[:8]}" if missing else ""))

	def rec_of(name):
		s = next(x for x in sent if x["name"] == name)
		recs = by_stem.get(s["path"].split("?")[0], [])
		return (recs[0] if recs else None), s

	aligned = all(r is None or (r.get("x-edge-location") == s["pop"] and r.get("sc-status") == str(s["status"]))
				  for r, s in (rec_of(x["name"]) for x in sent))
	print(f"fields aligned (PoP and status as each response named them): {aligned}")
	none, _ = rec_of("ctl-none")
	filled = sorted(f for f in FIELD.values() if none and none.get(f, "-") not in ("-", ""))
	print(f"control, no CMCD: {'not logged' if none is None else ('no field filled' if not filled else filled)}")
	valid = aligned and none is not None and not filled
	for form in ("headers", "query"):
		r, _ = rec_of(f"ctl-v1-{form}")
		got = {k: (r or {}).get(FIELD[k], "-") for k in V1_WANT}
		ok = r is not None and all(got[k] == v for k, v in V1_WANT.items())
		valid &= ok
		print(f"control, CMCD v1 in {form}: {'filled' if ok else 'NOT as sent'} {got}")
	print("VALID" if valid else "VOID")

	for arm, form, items in arms(cap):
		keys = {}
		for i, (headers, query) in enumerate(items):
			rec, _ = rec_of(f"{arm}-{i}")
			sentkv = ({k: v for p in headers.values() for k, v in kv(p).items()} if form == "headers" else kv(query))
			raw_ok = None
			if rec is not None:
				if form == "query":
					logged = urllib.parse.unquote(rec.get("cs-uri-query", ""))
					raw_ok = urllib.parse.parse_qs(logged, keep_blank_values=True).get("CMCD", [""])[0] == query
				else:
					h = logged_headers(rec.get("cs-headers"))
					raw_ok = all(h.get(n.lower()) == v for n, v in headers.items())
			for k, v in sentkv.items():
				e = keys.setdefault(k, dict(n=0, field=FIELD.get(k), filled=0, same=0, raw=0, sample=None))
				e["n"] += 1
				if rec is None:
					continue
				e["raw"] += bool(raw_ok)
				if e["field"]:
					lv = rec.get(e["field"], "-")
					if lv not in ("-", ""):
						e["filled"] += 1
						same = lv in ("1", "true") if v is True else lv == v.strip('"')
						e["same"] += same
						if e["sample"] is None or not same:
							e["sample"] = (v, lv)
		print(f"\n{arm}: key, requests carrying it, dedicated field, filled, as sent, raw intact, sample")
		for k in sorted(keys):
			e = keys[k]
			print(f"  {k:12} {e['n']:3}  {e['field'] or '-':34} {e['filled']:3} {e['same']:3} {e['raw']:3}  "
				  f"{e['sample']}")
	return 0 if valid and not missing else 1


def main():
	cmd, args = sys.argv[1], sys.argv[2:]
	if cmd == "capture":
		capture(*args)
	elif cmd == "replay":
		replay(*args)
	elif cmd == "read":
		read(*args)
	elif cmd == "grade":
		sys.exit(grade(*args))
	else:
		sys.exit(__doc__)


if __name__ == "__main__":
	main()

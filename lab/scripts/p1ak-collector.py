#!/usr/bin/env python3
"""P1-ak's collector: one HTTP endpoint that keeps every report it is sent, with its arrival time.

Two senders post to it: b8-hls-recv.py's CMCD v2 event mode (application/cmcd, one record per
line) and TSDuck's `influx` plugin (InfluxDB v2 line protocol on /api/v2/write). Each POST is one
JSON line in OUT: {"t": arrival, "path", "query", "type", "lines": [...]}. Anything else is
answered 204 and kept the same way, so a sender's probe never fails it.

  p1ak-collector.py PORT OUT
"""
import json
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
	port, out = int(sys.argv[1]), open(sys.argv[2], "a", buffering=1)

	class Handler(BaseHTTPRequestHandler):
		protocol_version = "HTTP/1.1"

		def keep(self, body=b""):
			u = urllib.parse.urlsplit(self.path)
			out.write(json.dumps(dict(t=round(time.time(), 3), path=u.path, query=u.query,
									  type=self.headers.get("Content-Type"),
									  lines=body.decode("utf-8", "replace").splitlines())) + "\n")
			self.send_response(204)
			self.send_header("Content-Length", "0")
			self.end_headers()

		def do_POST(self):  # noqa: N802 - the stdlib's name
			self.keep(self.rfile.read(int(self.headers.get("Content-Length") or 0)))

		def do_GET(self):  # noqa: N802
			self.keep()

		def log_message(self, *_):
			pass

	ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
	main()

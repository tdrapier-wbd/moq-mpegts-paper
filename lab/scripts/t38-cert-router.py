#!/usr/bin/env python3
"""T38 Part 5's per-certificate auth endpoint: route each relay auth request by its certificate.

usage: t38-cert-router.py <listen port> <table.json> <log.jsonl>

table.json is {"token": <port>, "certs": {"<sha256 hex>": <port>, ...}}, re-read on every request,
so editing it withdraws a certificate (drop its fingerprint) or narrows one (point it at another
backend). A request carrying a certificate goes to its fingerprint's backend, and is refused when
none is listed; one without goes to the token backend. Every backend is a `moq auth serve`, which
writes the grant. The log records each request's event, path, certificate name and fingerprint,
whether a credential rode along, the backend and the status; never the credential itself.
"""

import json
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, TABLE, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
REFUSED = b'{"reason":"refused"}'


class Router(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        request = json.loads(body)
        with open(TABLE) as f:
            table = json.load(f)
        tls = request.get("tls")
        port = table["certs"].get(tls["fingerprint"]) if tls else table["token"]
        if port is None:
            status, out = 403, REFUSED
        else:
            forward = urllib.request.Request(
                f"http://127.0.0.1:{port}/", data=body, headers={"Content-Type": "application/json"}
            )
            try:
                with urllib.request.urlopen(forward, timeout=5) as response:
                    status, out = response.status, response.read()
            except urllib.error.HTTPError as err:
                status, out = err.code, err.read()
        self.send_response(status)
        if out:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
        record = {
            "t": round(time.time(), 3),
            "event": request.get("event"),
            "path": request.get("path"),
            "tls_name": tls.get("name") if tls else None,
            "tls_fp": tls.get("fingerprint") if tls else None,
            "tls_issuer": tls.get("issuer") if tls else None,
            "credential": bool(request.get("token")) or "jwt=" in (request.get("query") or ""),
            "backend": port,
            "status": status,
        }
        with open(LOG, "a") as f:
            f.write(json.dumps(record) + "\n")

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Router).serve_forever()

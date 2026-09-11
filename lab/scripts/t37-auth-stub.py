#!/usr/bin/env python3
"""Authorization endpoint stub for T36/T37/T38 — the apparatus, not the finding.

Serves the unified `--auth-api` contract moq-relay expects:

    GET <base>?root=<path>&kid=<kid>&mtls=true&transport=<t>

and answers with a JSON object whose fields are all optional: `alias`, `public`,
`key`, `tier`. The relay's revalidation schedule is opted into by this endpoint
returning a `Cache-Control: max-age=N`, so the cadence under test is set here.

Every decision is driven by a state file that is re-read on every request, so a
grant can be withdrawn at a known instant without restarting anything. Every
request is appended to a JSONL log with both wall-clock and monotonic
timestamps, which is what gives the re-check cadence directly rather than by
inference.

The relay distinguishes a refusal from an outage by status code, and the two
drive different arms:

  * 404               -> AuthError::NotFound  -> refusal  -> immediate close
  * 200 without `key` -> KeyNotFound          -> refusal  -> immediate close
  * 503 / conn refused-> ApiUnavailable       -> unavailable -> staleness window

State file shape:

    {
      "mode": "up" | "refuse" | "unavailable",
      "cache_control": "max-age=5, stale-while-revalidate=30",
      "channels": ["cnn", "cnn-intl", "tnt"],
      "affiliates": {
        "<kid>": {"enabled": true, "channels": ["cnn"], "key": "<path to public jwk>"}
      },
      "public": {"<root>": {"subscribe": ["cnn"], "publish": []}},
      "alias": {"<root>": "<canonical root>"},
      "tier": null
    }

No credential material is stored in this file — only paths to the *public*
verifying keys, which is what §7.2 of the control-plane design requires a relay
to hold.
"""

import argparse
import base64
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

STATE = None
LOGPATH = None
T0 = None


def load_state():
    with open(STATE, encoding="utf-8") as fh:
        return json.load(fh)


def read_jwk(path):
    """`moq token generate` writes base64url-encoded JSON; the auth API contract
    wants the JWK as a JSON object. Accept either form."""
    raw = open(path, encoding="utf-8").read().strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pad = "=" * (-len(raw) % 4)
        return json.loads(base64.urlsafe_b64decode(raw + pad))


def log(record):
    record["wall"] = time.time()
    record["mono"] = time.monotonic() - T0
    with open(LOGPATH, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record) + "\n")
        fh.flush()


def channels_for(state, kid, root):
    """The subscribe prefixes this caller is licensed for, relative to `root`.

    The matrix is keyed on the affiliate's key id. A channel the affiliate does
    not license is simply absent from the grant, which is what makes a partial
    licensing matrix expressible.
    """
    aff = state.get("affiliates", {}).get(kid)
    if aff is None or not aff.get("enabled", False):
        return None
    return aff.get("channels", [])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # silence the default stderr spew
        pass

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        root = q.get("root", [""])[0]
        kid = q.get("kid", [None])[0]
        mtls = q.get("mtls", [None])[0]
        transport = q.get("transport", [None])[0]

        try:
            state = load_state()
        except Exception as exc:  # a broken state file must not look like a grant
            log({"root": root, "kid": kid, "decision": "state-error", "err": str(exc)})
            self.send_response(500)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        mode = state.get("mode", "up")

        # --- outage and blanket-refusal levers -----------------------------
        if mode == "unavailable":
            log({"root": root, "kid": kid, "mtls": mtls, "transport": transport,
                 "decision": "unavailable-503"})
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if mode == "refuse":
            log({"root": root, "kid": kid, "mtls": mtls, "transport": transport,
                 "decision": "refused-404"})
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        # --- normal resolution ---------------------------------------------
        body = {}

        alias = state.get("alias", {}).get(root)
        if alias:
            body["alias"] = alias

        tier = state.get("tier")
        if tier:
            body["tier"] = tier

        decision = "granted"
        granted = None

        if kid:
            licensed = channels_for(state, kid, root)
            if licensed is None:
                # Affiliate disabled or unknown: answer, but withhold the key.
                # That is KeyNotFound at the relay, which is a refusal.
                decision = "no-key"
            else:
                aff = state["affiliates"][kid]
                keypath = aff.get("key")
                try:
                    body["key"] = read_jwk(keypath)
                    granted = licensed
                except Exception as exc:
                    decision = "key-read-error"
                    log({"root": root, "kid": kid, "decision": decision, "err": str(exc)})
                    self.send_response(500)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
        else:
            pub = state.get("public", {}).get(root)
            if pub:
                body["public"] = pub
                granted = pub.get("subscribe", [])
            else:
                decision = "no-public-grant"

        payload = json.dumps(body).encode()
        cc = state.get("cache_control")

        log({"root": root, "kid": kid, "mtls": mtls, "transport": transport,
             "decision": decision, "granted": granted, "cache_control": cc})

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        if cc:
            self.send_header("Cache-Control", cc)
        self.end_headers()
        self.wfile.write(payload)


def main():
    global STATE, LOGPATH, T0
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9401)
    ap.add_argument("--state", required=True)
    ap.add_argument("--log", required=True)
    args = ap.parse_args()

    STATE = args.state
    LOGPATH = args.log
    T0 = time.monotonic()

    open(LOGPATH, "a").close()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    srv.daemon_threads = True
    print(f"auth stub on 127.0.0.1:{args.port} state={STATE} log={LOGPATH}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

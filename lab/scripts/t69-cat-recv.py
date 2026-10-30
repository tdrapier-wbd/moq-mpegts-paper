#!/usr/bin/env python3
"""T69: an HLS AES-128 receiver that presents a Common Access Token on every request.

    t69-cat-recv.py URL OUT --token-file F [--seconds N] [--poll-ms 500] [--edge 2] [--pin IP]
                    [--stop-after-denies N] [--log FILE.jsonl]

Fetches the playlist, each key it names (once) and each new segment on one HTTPS connection, the
token in CTA-Common-Access-Token, decrypts each segment (AES-128-CBC, the key's bytes, the media
sequence number as IV, through `openssl enc`) and appends it to OUT. --pin connects to that address
with the URL's host as SNI and Host, to reach a chosen CloudFront PoP. Each request is one JSON line
in the log: wall and monotonic time, kind, path, status, the gate's x-t69-deny, the PoP, X-Cache,
bytes, and for a segment its sequence, EXTINF and the decrypted SHA-256. The token is never logged.
"""
import argparse
import hashlib
import http.client
import json
import socket
import ssl
import subprocess
import sys
import time
import urllib.parse


class Conn:
    def __init__(self, host, pin, token):
        self.host, self.pin, self.token = host, pin, token
        self.c = None

    def _open(self):
        ctx = ssl.create_default_context()
        c = http.client.HTTPSConnection(self.host, 443, timeout=10, context=ctx)
        if self.pin:
            sock = socket.create_connection((self.pin, 443), timeout=10)
            c.sock = ctx.wrap_socket(sock, server_hostname=self.host)
        self.c = c

    def get(self, path):
        for attempt in (0, 1):
            if self.c is None:
                self._open()
            t0 = time.time()
            try:
                self.c.request("GET", path, headers={"CTA-Common-Access-Token": self.token})
                r = self.c.getresponse()
                body = r.read()
                h = {k.lower(): v for k, v in r.getheaders()}
                return r.status, h, body, t0, time.time()
            except (OSError, http.client.HTTPException):
                self.c.close()
                self.c = None
                if attempt:
                    return 0, {}, b"", t0, time.time()


def parse(text):
    seq, key, segs, dur = 0, None, [], None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
            seq = int(line.split(":", 1)[1])
        elif line.startswith("#EXT-X-KEY:"):
            key = line.split('URI="', 1)[1].split('"', 1)[0]
        elif line.startswith("#EXTINF:"):
            dur = float(line.split(":", 1)[1].rstrip(","))
        elif line and not line.startswith("#"):
            segs.append((seq + len(segs), dur, key, line))
    return segs


def decrypt(key, seq, data):
    p = subprocess.run(
        ["openssl", "enc", "-d", "-aes-128-cbc", "-K", key.hex(), "-iv", f"{seq:032x}"],
        input=data, capture_output=True, check=True,
    )
    return p.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("out")
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--seconds", type=float, default=150)
    ap.add_argument("--poll-ms", type=int, default=500)
    ap.add_argument("--edge", type=int, default=2)
    ap.add_argument("--pin")
    ap.add_argument("--stop-after-denies", type=int, default=0)
    ap.add_argument("--log")
    a = ap.parse_args()
    u = urllib.parse.urlsplit(a.url)
    conn = Conn(u.hostname, a.pin, open(a.token_file).read().strip())
    out = sys.stdout.buffer if a.out == "-" else open(a.out, "wb")
    log = open(a.log, "a", buffering=1) if a.log else sys.stderr
    keys, last, denies = {}, None, 0
    end = time.time() + a.seconds

    def note(kind, path, st, h, n, t0, t1, **kw):
        rec = {"t": round(t0, 3), "mono": time.monotonic(), "kind": kind, "path": path, "status": st,
               "deny": h.get("x-t69-deny"), "pop": h.get("x-amz-cf-pop"), "cache": h.get("x-cache"),
               "bytes": n, "ms": round((t1 - t0) * 1000, 1)}
        rec.update(kw)
        log.write(json.dumps(rec) + "\n")

    while time.time() < end:
        st, h, body, t0, t1 = conn.get(u.path)
        note("playlist", u.path, st, h, len(body), t0, t1)
        if st != 200:
            denies += 1
            if a.stop_after_denies and denies >= a.stop_after_denies:
                break
            time.sleep(a.poll_ms / 1000)
            continue
        segs = parse(body.decode())
        if last is None and segs:
            last = segs[-a.edge][0] - 1 if len(segs) >= a.edge else segs[0][0] - 1
        for seq, dur, kuri, path in segs:
            if seq <= last:
                continue
            if kuri not in keys:
                kst, kh, kb, k0, k1 = conn.get(kuri)
                note("key", kuri, kst, kh, len(kb), k0, k1)
                if kst != 200 or len(kb) != 16:
                    denies += 1
                    break
                keys[kuri] = kb
            sst, sh, sb, s0, s1 = conn.get(path)
            if sst != 200:
                note("seg", path, sst, sh, len(sb), s0, s1, seq=seq, extinf=dur)
                denies += 1
                break
            clear = decrypt(keys[kuri], seq, sb)
            out.write(clear)
            out.flush()
            note("seg", path, sst, sh, len(sb), s0, s1, seq=seq, extinf=dur,
                 sha=hashlib.sha256(clear).hexdigest(), clear_bytes=len(clear))
            last = seq
        if a.stop_after_denies and denies >= a.stop_after_denies:
            break
        time.sleep(a.poll_ms / 1000)


if __name__ == "__main__":
    main()

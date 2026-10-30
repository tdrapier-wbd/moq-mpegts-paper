#!/usr/bin/env python3
"""T69: encrypt a live HLS packager's segments for the CAT gate (HLS AES-128).

    t69-aes-seg.py CLEAR_DIR WWW_DIR --hashes FILE [--period 5] [--poll-ms 100]

Watches CLEAR_DIR/index.m3u8 (as `tsp -O hls` writes it). Each newly listed segment is encrypted
whole with AES-128-CBC and PKCS#7 padding, the IV its media sequence number (HLS's default when
EXT-X-KEY names no IV), under a key drawn at random for every PERIOD segments, and written to
WWW_DIR/e/; the key goes to WWW_DIR/k/<period>.key before any playlist names it. WWW_DIR/e/index.m3u8
mirrors the clear playlist with an EXT-X-KEY wherever the key changes. Every write is a rename.
For each segment, FILE gets: sequence, name, period, clear SHA-256, encrypted SHA-256, clear bytes,
and the wall time it was published, which is what a receiver's output is graded against.
"""
import argparse
import hashlib
import os
import sys
import time

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


def parse(text):
    seq, target, segs, dur = None, None, [], None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
            seq = int(line.split(":", 1)[1])
        elif line.startswith("#EXT-X-TARGETDURATION:"):
            target = line.split(":", 1)[1]
        elif line.startswith("#EXTINF:"):
            dur = line.split(":", 1)[1]
        elif line and not line.startswith("#") and dur is not None:
            segs.append((dur, line))
            dur = None
    if seq is None or target is None:
        return None
    return seq, target, segs


def put(path, data, mode=0o600):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    os.write(fd, data)
    os.close(fd)
    os.replace(tmp, path)


def encrypt(key, seq, data):
    p = padding.PKCS7(128).padder()
    e = Cipher(algorithms.AES(key), modes.CBC(seq.to_bytes(16, "big"))).encryptor()
    return e.update(p.update(data) + p.finalize()) + e.finalize()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clear")
    ap.add_argument("www")
    ap.add_argument("--hashes", required=True)
    ap.add_argument("--period", type=int, default=5)
    ap.add_argument("--poll-ms", type=int, default=100)
    a = ap.parse_args()
    edir, kdir = os.path.join(a.www, "e"), os.path.join(a.www, "k")
    os.makedirs(edir, exist_ok=True)
    os.makedirs(kdir, exist_ok=True)
    keys, done, last = {}, {}, None
    hashes = open(a.hashes, "a", buffering=1)
    while True:
        try:
            text = open(os.path.join(a.clear, "index.m3u8")).read()
        except OSError:
            time.sleep(a.poll_ms / 1000)
            continue
        parsed = parse(text)
        if parsed is None or parsed[0] == last and len(parsed[2]) == len(done.get("listed", [])):
            time.sleep(a.poll_ms / 1000)
            continue
        first, target, segs = parsed
        listed = []
        for i, (dur, name) in enumerate(segs):
            seq = first + i
            if seq not in done:
                try:
                    clear = open(os.path.join(a.clear, name), "rb").read()
                except OSError:
                    break
                period = seq // a.period
                if period not in keys:
                    keys[period] = os.urandom(16)
                    put(os.path.join(kdir, f"{period}.key"), keys[period])
                ct = encrypt(keys[period], seq, clear)
                put(os.path.join(edir, name), ct)
                done[seq] = (name, period)
                hashes.write(
                    f"{seq}\t{name}\t{period}\t{hashlib.sha256(clear).hexdigest()}\t"
                    f"{hashlib.sha256(ct).hexdigest()}\t{len(clear)}\t{time.time():.3f}\n"
                )
            listed.append((seq, dur, name))
        out = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{target}"]
        if listed:
            out.append(f"#EXT-X-MEDIA-SEQUENCE:{listed[0][0]}")
        cur = None
        for seq, dur, name in listed:
            period = done[seq][1]
            if period != cur:
                out.append(f'#EXT-X-KEY:METHOD=AES-128,URI="/k/{period}.key"')
                cur = period
            out += [f"#EXTINF:{dur}", f"/e/{name}"]
        put(os.path.join(edir, "index.m3u8"), ("\n".join(out) + "\n").encode(), 0o644)
        done["listed"] = listed
        last = first
        if listed:
            for seq in [s for s in done if isinstance(s, int) and s < listed[0][0] - 3]:
                try:
                    os.unlink(os.path.join(edir, done[seq][0]))
                except OSError:
                    pass
                del done[seq]
        time.sleep(a.poll_ms / 1000)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)

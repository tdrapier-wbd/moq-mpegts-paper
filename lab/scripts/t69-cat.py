#!/usr/bin/env python3
"""T69: mint CTA-5007 Common Access Tokens (a CWT under COSE_Mac0, HS256) for the CloudFront gate.

    t69-cat.py selftest
    t69-cat.py mint --key-file F [--kid ID] [--iss ISS] [--exp-in S | --exp T] [--nbf-in S]
                    [--cti HEX] [--catu-prefix PATH] [--flip-mac] [--out FILE]
    t69-cat.py info TOKEN_FILE

`mint` writes the base64url token to --out (or stdout for a pipe) and its cti to stderr; a token is a
credential, so callers keep it in a file and never print it. `selftest` rebuilds RFC 8392's example
MAC token (A.4, HMAC 256/64) byte for byte, which checks the CBOR encoder and the MAC structure.
The key file holds the HMAC key as hex.
"""
import argparse
import base64
import hashlib
import hmac
import os
import sys
import time

CWT_TAG, MAC0_TAG = 61, 17
ISS, EXP, NBF, IAT, CTI = 1, 4, 5, 6, 7
CATV, CATU = 310, 312
CATU_PATH, MATCH_PREFIX = 3, 1


def head(major, n):
    if n < 24:
        return bytes([major << 5 | n])
    for ai, size in ((24, 1), (25, 2), (26, 4), (27, 8)):
        if n < 1 << (8 * size):
            return bytes([major << 5 | ai]) + n.to_bytes(size, "big")
    raise ValueError(n)


class Tag:
    def __init__(self, tag, value):
        self.tag, self.value = tag, value


def enc(v):
    if isinstance(v, bool):
        return b"\xf5" if v else b"\xf4"
    if isinstance(v, int):
        return head(0, v) if v >= 0 else head(1, -1 - v)
    if isinstance(v, (bytes, bytearray)):
        return head(2, len(v)) + bytes(v)
    if isinstance(v, str):
        b = v.encode()
        return head(3, len(b)) + b
    if isinstance(v, list):
        return head(4, len(v)) + b"".join(enc(x) for x in v)
    if isinstance(v, dict):
        return head(5, len(v)) + b"".join(enc(k) + enc(x) for k, x in v.items())
    if isinstance(v, Tag):
        return head(6, v.tag) + enc(v.value)
    raise TypeError(type(v))


def mac0(claims, key, kid, alg=5, cwt_tag=True, flip=False):
    protected = enc({1: alg})
    payload = enc(claims)
    tag = hmac.new(key, enc(["MAC0", protected, b"", payload]), hashlib.sha256).digest()
    if alg == 4:
        tag = tag[:8]
    if flip:
        tag = bytes([tag[0] ^ 1]) + tag[1:]
    token = Tag(MAC0_TAG, [protected, {4: kid}, payload, tag])
    return enc(Tag(CWT_TAG, token) if cwt_tag else token)


def selftest():
    key = bytes.fromhex("403697de87af64611c1d32a05dab0fe1fcb715a86ab435f1ec99192d79569388")
    claims = {
        1: "coap://as.example.com",
        2: "erikw",
        3: "coap://light.example.com",
        4: 1444064944,
        5: 1443944944,
        6: 1443944944,
        7: bytes.fromhex("0b71"),
    }
    want = (
        "d83dd18443a10104a1044c53796d6d65747269633235365850a70175636f61703a2f2f61732e6578616d706c652e"
        "636f6d02656572696b77037818636f61703a2f2f6c696768742e6578616d706c652e636f6d041a5612aeb0051a56"
        "10d9f0061a5610d9f007420b7148093101ef6d789200"
    )
    got = mac0(claims, key, b"Symmetric256", alg=4).hex()
    print("selftest", "PASS" if got == want else "FAIL")
    return got == want


def mint(a):
    key = bytes.fromhex(open(a.key_file).read().strip())
    now = int(time.time())
    cti = bytes.fromhex(a.cti) if a.cti else os.urandom(8)
    claims = {ISS: a.iss, EXP: a.exp if a.exp else now + a.exp_in, IAT: now, CTI: cti, CATV: 1}
    if a.nbf_in is not None:
        claims[NBF] = now + a.nbf_in
    if a.catu_prefix:
        claims[CATU] = {CATU_PATH: {MATCH_PREFIX: a.catu_prefix}}
    tok = base64.urlsafe_b64encode(mac0(claims, key, a.kid.encode(), flip=a.flip_mac)).rstrip(b"=")
    if a.out:
        fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, tok + b"\n")
        os.close(fd)
    else:
        sys.stdout.write(tok.decode() + "\n")
    print(f"cti={cti.hex()} exp={claims[EXP]}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest")
    m = sub.add_parser("mint")
    m.add_argument("--key-file", required=True)
    m.add_argument("--kid", default="t69k1")
    m.add_argument("--iss", default="t69")
    m.add_argument("--exp-in", type=int, default=3600)
    m.add_argument("--exp", type=int)
    m.add_argument("--nbf-in", type=int)
    m.add_argument("--cti")
    m.add_argument("--catu-prefix", default="/")
    m.add_argument("--flip-mac", action="store_true")
    m.add_argument("--out")
    sub.add_parser("info").add_argument("token_file")
    a = ap.parse_args()
    if a.cmd == "selftest":
        sys.exit(0 if selftest() else 1)
    if a.cmd == "mint":
        mint(a)
    if a.cmd == "info":
        raw = open(a.token_file).read().strip()
        b = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
        print(f"{len(b)} bytes, sha256 prefix {hashlib.sha256(b).hexdigest()[:12]}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""T69: the CAT gate's control, revocation trials and expiry, probed at two CloudFront PoPs at once.

    t69-revoke.py control --domain D --pin IP --key-file K --out DIR
    t69-revoke.py trials  --domain D --pin IP --key-file K --kvs-arn ARN --out DIR [--trials 10]
    t69-revoke.py expiry  --domain D --pin IP --key-file K --out DIR [--in 30]
    t69-revoke.py revoke  --kvs-arn ARN --cti HEX

Two probes: one to the PoP the laptop resolves, one to --pin with the domain as SNI and Host; each
reads its PoP from x-amz-cf-pop. A probe GETs /e/index.m3u8 every --interval s on one connection.
A trial mints a token with a fresh cti, probes, waits a random 3-6 s, writes rev:<cti> to the
KeyValueStore (cloudfront-keyvaluestore put-key), and probes on until --consecutive refusals at
both PoPs or --max-s. Every time is the probes' monotonic clock; the write is stamped before it
starts and when it returns. Tokens are kept in memory and never written to the output.
"""
import argparse
import base64
import importlib.util
import json
import os
import random
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("t69cat", os.path.join(HERE, "t69-cat.py"))
cat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cat)
recv_spec = importlib.util.spec_from_file_location("t69recv", os.path.join(HERE, "t69-cat-recv.py"))
recv = importlib.util.module_from_spec(recv_spec)
recv_spec.loader.exec_module(recv)


def token(key, cti=None, exp=None, iss="t69", prefix="/", flip=False):
    now = int(time.time())
    claims = {cat.ISS: iss, cat.EXP: exp if exp else now + 3600, cat.IAT: now,
              cat.CTI: cti or os.urandom(8), cat.CATV: 1, cat.CATU: {cat.CATU_PATH: {cat.MATCH_PREFIX: prefix}}}
    raw = cat.mac0(claims, key, b"t69k1", flip=flip)
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode(), claims[cat.CTI]


class Probe(threading.Thread):
    def __init__(self, domain, pin, tok, interval, path="/e/index.m3u8"):
        super().__init__(daemon=True)
        self.conn = recv.Conn(domain, pin, tok)
        self.interval, self.path = interval, path
        self.rows, self.stop = [], threading.Event()

    def run(self):
        nxt = time.monotonic()
        while not self.stop.is_set():
            t = time.monotonic()
            st, h, body, w0, w1 = self.conn.get(self.path)
            self.rows.append({"mono": t, "rtt_ms": round((w1 - w0) * 1000, 1), "wall": w0, "status": st,
                              "deny": h.get("x-t69-deny"), "pop": h.get("x-amz-cf-pop"),
                              "date": h.get("date"), "cache": h.get("x-cache")})
            nxt += self.interval
            time.sleep(max(0, nxt - time.monotonic()))


def kvs_put(arn, key, value="1"):
    etag = subprocess.run(["aws", "cloudfront-keyvaluestore", "describe-key-value-store", "--kvs-arn", arn,
                           "--query", "ETag", "--output", "text"], capture_output=True, text=True, check=True).stdout.strip()
    return etag, ["aws", "cloudfront-keyvaluestore", "put-key", "--kvs-arn", arn, "--key", key,
                  "--value", value, "--if-match", etag, "--query", "ETag", "--output", "text"]


def control(a, key):
    tok, _ = token(key)
    st, h, body, *_ = recv.Conn(a.domain, None, tok).get("/e/index.m3u8")
    segs = recv.parse(body.decode()) if st == 200 else []
    if not segs:
        sys.exit(f"control: the valid token got {st} on the playlist; nothing to probe")
    paths = {"playlist": "/e/index.m3u8", "segment": segs[-1][3], "key": segs[-1][2]}
    cases = {
        "missing": None,
        "mac": token(key, flip=True)[0],
        "expired": token(key, exp=int(time.time()) - 60)[0],
        "uri": token(key, prefix="/x/")[0],
        "iss": token(key, iss="other")[0],
        "valid": token(key)[0],
    }
    rows, ok = [], True
    for pop, pin in (("resolved", None), ("pinned", a.pin)):
        for case, t in cases.items():
            for kind, path in paths.items():
                c = recv.Conn(a.domain, pin, t or "")
                if t is None:
                    c.token = None
                st, h, *_ = get_raw(c, path)
                admitted = st == 200
                want = case == "valid"
                ok &= admitted == want
                rows.append({"probe": pop, "pop": h.get("x-amz-cf-pop"), "case": case, "object": kind,
                             "status": st, "deny": h.get("x-t69-deny"), "as_designed": admitted == want})
    json.dump(rows, open(os.path.join(a.out, "control.json"), "w"), indent=1)
    for r in rows:
        print(f"{r['probe']:8} {r['pop'] or '-':10} {r['case']:8} {r['object']:8} {r['status']} {r['deny'] or ''}")
    print("control", "PASS" if ok else "FAIL")


def get_raw(c, path):
    if c.token is None:
        c._open()
        t0 = time.time()
        c.c.request("GET", path)
        r = c.c.getresponse()
        body = r.read()
        return r.status, {k.lower(): v for k, v in r.getheaders()}, body, t0, time.time()
    return c.get(path)


def trials(a, key):
    summary = []
    for i in range(1, a.trials + 1):
        tok, cti = token(key)
        probes = [Probe(a.domain, None, tok, a.interval), Probe(a.domain, a.pin, tok, a.interval)]
        for p in probes:
            p.start()
        etag, cmd = kvs_put(a.kvs_arn, "rev:" + cti.hex())
        time.sleep(random.uniform(3, 6))
        w0 = time.monotonic()
        res = subprocess.run(cmd, capture_output=True, text=True)
        w1 = time.monotonic()
        deadline = w1 + a.max_s
        while time.monotonic() < deadline:
            if all(len(p.rows) >= a.consecutive and all(r["status"] != 200 for r in p.rows[-a.consecutive:])
                   and p.rows[-1]["mono"] > w1 for p in probes):
                break
            time.sleep(0.2)
        for p in probes:
            p.stop.set()
        for p in probes:
            p.join()
        trial = {"trial": i, "cti": cti.hex(), "write_ms": round((w1 - w0) * 1000, 1), "put_rc": res.returncode,
                 "put_err": res.stderr.strip()[-200:], "probes": []}
        for name, p in zip(("resolved", "pinned"), probes):
            pre = [r for r in p.rows if r["mono"] < w0]
            post = [r for r in p.rows if r["mono"] >= w1]
            first = next((r for r in post if r["status"] != 200), None)
            after = [r for r in post if first and r["mono"] > first["mono"]]
            trial["probes"].append({
                "probe": name, "pop": next((r["pop"] for r in p.rows if r["pop"]), None),
                "pre_n": len(pre), "pre_admitted": sum(r["status"] == 200 for r in pre),
                "during_write": [r["status"] for r in p.rows if w0 <= r["mono"] < w1],
                "first_refusal_ms": round((first["mono"] - w1) * 1000) if first else None,
                "first_refusal_from_start_ms": round((first["mono"] - w0) * 1000) if first else None,
                "first_deny": first["deny"] if first else None,
                "admitted_after_first_refusal": sum(r["status"] == 200 for r in after),
                "last_admitted_ms": round((max((r["mono"] for r in post if r["status"] == 200), default=w1) - w1) * 1000),
                "requests": len(p.rows), "rtt_ms_median": sorted(r["rtt_ms"] for r in p.rows)[len(p.rows) // 2],
            })
            with open(os.path.join(a.out, f"trial-{i}-{name}.jsonl"), "w") as f:
                for r in p.rows:
                    f.write(json.dumps(dict(r, rel_w1_ms=round((r["mono"] - w1) * 1000))) + "\n")
        summary.append(trial)
        print(json.dumps({k: trial[k] for k in ("trial", "write_ms", "put_rc")} |
                         {p["probe"]: (p["pop"], p["first_refusal_ms"], p["first_deny"], p["admitted_after_first_refusal"])
                          for p in trial["probes"]}), flush=True)
        time.sleep(2)
    json.dump(summary, open(os.path.join(a.out, "trials.json"), "w"), indent=1)


def expiry(a, key):
    exp = int(time.time()) + a.expire_in
    tok, _ = token(key, exp=exp)
    probes = [Probe(a.domain, None, tok, a.interval), Probe(a.domain, a.pin, tok, a.interval)]
    for p in probes:
        p.start()
    while time.time() < exp + 10:
        time.sleep(0.5)
    for p in probes:
        p.stop.set()
    for p in probes:
        p.join()
    import email.utils
    out = {"exp": exp, "probes": []}
    for name, p in zip(("resolved", "pinned"), probes):
        rows = [dict(r, edge_s=int(email.utils.parsedate_to_datetime(r["date"]).timestamp()) if r["date"] else None)
                for r in p.rows]
        early = [r for r in rows if r["edge_s"] is not None and r["edge_s"] < exp and r["status"] != 200]
        late = [r for r in rows if r["edge_s"] is not None and r["edge_s"] >= exp and r["status"] == 200]
        out["probes"].append({"probe": name, "pop": next((r["pop"] for r in rows if r["pop"]), None),
                              "requests": len(rows), "refused_before_exp": len(early), "admitted_from_exp": len(late),
                              "last_admitted_wall_minus_exp": round(max((r["wall"] for r in rows if r["status"] == 200), default=0) - exp, 3),
                              "first_refused_wall_minus_exp": round(min((r["wall"] for r in rows if r["status"] != 200), default=0) - exp, 3),
                              "denies": sorted({r["deny"] for r in rows if r["deny"]})})
        with open(os.path.join(a.out, f"expiry-{name}.jsonl"), "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
    json.dump(out, open(os.path.join(a.out, "expiry.json"), "w"), indent=1)
    print(json.dumps(out))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["control", "trials", "expiry", "revoke"])
    ap.add_argument("--domain")
    ap.add_argument("--pin")
    ap.add_argument("--key-file")
    ap.add_argument("--kvs-arn")
    ap.add_argument("--cti")
    ap.add_argument("--out", default=".")
    ap.add_argument("--trials", type=int, default=10)
    ap.add_argument("--interval", type=float, default=0.1)
    ap.add_argument("--consecutive", type=int, default=20)
    ap.add_argument("--max-s", type=float, default=90)
    ap.add_argument("--in", dest="expire_in", type=int, default=30)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if a.cmd == "revoke":
        etag, cmd = kvs_put(a.kvs_arn, "rev:" + a.cti)
        w0 = time.time()
        subprocess.run(cmd, check=True, capture_output=True)
        print(json.dumps({"cti": a.cti, "write_start": round(w0, 3), "write_end": round(time.time(), 3)}))
        return
    key = bytes.fromhex(open(a.key_file).read().strip())
    {"control": control, "trials": trials, "expiry": expiry}[a.cmd](a, key)


if __name__ == "__main__":
    main()

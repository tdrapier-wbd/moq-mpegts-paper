#!/usr/bin/env python3
"""Write the authorization stub's state file. Called to set up an arm and to
flip a lever mid-session; the write is the instant of the control-plane decision.

    mkstate.py --cache-control "max-age=5" --enable affakey,affbkey,wbdkey,rivalkey
    mkstate.py --mode refuse
"""
import argparse, json, os, sys, time

W = "/tmp/t36"
STATE = f"{W}/authstate.json"
DECISIONS = f"{W}/decisions.jsonl"

KEYS = {
    "wbdkey":   f"{W}/keys/wbd.pub.jwk",
    "rivalkey": f"{W}/keys/rival.pub.jwk",
    "affakey":  f"{W}/keys/affa.pub.jwk",
    "affbkey":  f"{W}/keys/affb.pub.jwk",
    "affckey":  f"{W}/keys/affc.pub.jwk",
}
CHANNELS = {
    "wbdkey": ["cnn", "cnn-intl", "tnt", "nobody"],
    "rivalkey": ["cnn"],
    "affakey": ["cnn"],
    "affbkey": ["cnn", "tnt"],
    "affckey": ["tnt"],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="up", choices=["up", "refuse", "unavailable"])
    ap.add_argument("--cache-control", default=None)
    ap.add_argument("--enable", default="wbdkey,rivalkey,affakey,affbkey,affckey")
    ap.add_argument("--keymap", default=None,
                    help="kid=path,kid=path — override which key file a kid resolves to")
    ap.add_argument("--mark", default="", help="label this decision in decisions.jsonl")
    args = ap.parse_args()

    enabled = set(x for x in args.enable.split(",") if x)
    keys = dict(KEYS)
    if args.keymap:
        for pair in args.keymap.split(","):
            k, v = pair.split("=", 1)
            keys[k] = v

    state = {
        "mode": args.mode,
        "cache_control": args.cache_control,
        "affiliates": {
            kid: {"enabled": kid in enabled, "channels": CHANNELS.get(kid, []),
                  "key": keys[kid]}
            for kid in keys
        },
        "public": {},
        "alias": {},
        "tier": None,
    }

    tmp = STATE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=1)
    os.replace(tmp, STATE)          # atomic: the stub never reads a half-written file
    t = time.time()

    rec = {"wall": t, "mark": args.mark, "mode": args.mode,
           "cache_control": args.cache_control, "enabled": sorted(enabled),
           "keymap": args.keymap}
    with open(DECISIONS, "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    print(json.dumps(rec), flush=True)


if __name__ == "__main__":
    main()

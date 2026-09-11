#!/usr/bin/env python3
"""Write the authorization stub's state from the estate matrix — T38.

Unlike mkstate.py (which carries T37's small fixed cast inline), this reads
matrix.json, so the licensing matrix is declared in one place and an arm changes
it by naming the cell rather than by restating the estate.

    mkstate2.py --cache-control "max-age=5"
    mkstate2.py --disable affdkey --mark "withdraw affiliate D"
    mkstate2.py --relicense affdkey=tnt --mark "narrow D to tnt only"
    mkstate2.py --keymap affakey=/path/other.pub.jwk
"""
import argparse, json, os, time

W = "/tmp/t36"
STATE = f"{W}/authstate.json"
DECISIONS = f"{W}/decisions.jsonl"
MATRIX = f"{W}/matrix.json"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="up", choices=["up", "refuse", "unavailable"])
    ap.add_argument("--cache-control", default="max-age=5")
    ap.add_argument("--disable", default="", help="comma-separated kids to withdraw")
    ap.add_argument("--relicense", default="",
                    help="kid=ch1|ch2,... — replace a kid's licensed set")
    ap.add_argument("--keymap", default="", help="kid=path,... — swap the key a kid resolves to")
    ap.add_argument("--mark", default="")
    args = ap.parse_args()

    m = json.load(open(MATRIX))
    disabled = set(x for x in args.disable.split(",") if x)
    relic = {}
    for pair in (p for p in args.relicense.split(",") if p):
        k, v = pair.split("=", 1)
        relic[k] = [c for c in v.split("|") if c]
    keymap = dict(p.split("=", 1) for p in args.keymap.split(",") if p)

    affs = {}
    for kid, spec in m["affiliates"].items():
        affs[kid] = {
            "enabled": kid not in disabled,
            "channels": relic.get(kid, spec["licensed"]),
            "key": keymap.get(kid, spec["key"]),
        }

    state = {"mode": args.mode, "cache_control": args.cache_control,
             "affiliates": affs, "public": {}, "alias": {}, "tier": None}

    tmp = STATE + ".tmp"
    json.dump(state, open(tmp, "w"), indent=1)
    os.replace(tmp, STATE)
    rec = {"wall": time.time(), "mark": args.mark, "mode": args.mode,
           "cache_control": args.cache_control, "disabled": sorted(disabled),
           "relicense": relic, "keymap": keymap}
    open(DECISIONS, "a").write(json.dumps(rec) + "\n")
    print(json.dumps(rec), flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Check a rewrite of `docs/` against the claim register: nothing lost, nothing invented.

The source is `docs/` at one commit (paper-claims.py's register); the edition is any set of
markdown files. Three findings, each fatal unless the dropped list explains it:

- **lost**: a number, evidence ID or build in the source that the edition never states;
- **invented**: a number, evidence ID or build in the edition that the source never states;
- **unscoped**: a source unit's distinctive number (one at most two units carry) appears in the
  edition, but a qualifier that scoped it there (loopback, derived, one host, ...) is in none of
  the edition's units carrying that number. This is the rewrite's commonest damage: the figure
  kept, its limit lost.

The dropped list is TSV, one decision per line with its reason:
    <token or unit id>  <reason>        the token, or every token of the unit, is dropped on purpose
    <token>  = <token>                  the source token is carried re-expressed (3800 ms = 3.8 s)
    <number>|<qualifier>  <reason>      that qualifier no longer needs to sit beside that number

usage: paper-preserve.py [--rev REV] [--glob 'docs/*.md'] [--dropped dropped.tsv] <edition.md>...
"""

import argparse
import importlib.util
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("claims", os.path.join(HERE, "paper-claims.py"))
claims = importlib.util.module_from_spec(spec)
spec.loader.exec_module(claims)

KINDS = ("numbers", "ids", "builds")
TRIVIAL = {str(n) for n in range(0, 11)}


def read_dropped(path):
    drop, alias = {}, {}
    if not path:
        return drop, alias
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            key, _, why = line.partition("\t")
            if not why.strip():
                sys.exit(f"{path}:{n}: a dropped token needs its reason")
            if why.startswith("="):
                alias[claims.norm_number(key)] = claims.norm_number(why[1:].strip())
            else:
                drop[claims.norm_number(key) if not key.startswith("docs/") else key] = why.strip()
    return drop, alias


def edition_units(paths):
    for path in paths:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        for k, (_, _, line, body) in enumerate(claims.units(path, text), 1):
            yield f"{path}#{k}", line, claims.tokens(body)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rev", default="HEAD")
    ap.add_argument("--glob", default="docs/*.md")
    ap.add_argument("--dropped")
    ap.add_argument("edition", nargs="+")
    a = ap.parse_args()

    rev = claims.subprocess.run(["git", "rev-parse", "--short=9", a.rev], capture_output=True, text=True, check=True)
    rev = rev.stdout.strip()
    src = list(claims.register(rev, claims.git_files(rev, a.glob)))
    ed = list(edition_units(a.edition))
    drop, alias = read_dropped(a.dropped)
    dropped_units = {k for k in drop if k.startswith("docs/")}

    s_tok, e_tok = defaultdict(set), defaultdict(set)
    s_where = defaultdict(list)
    for u in src:
        for kind in KINDS:
            for t in u[kind]:
                s_tok[kind].add(t)
                s_where[t].append(u["id"])
    e_where = defaultdict(list)
    for uid, _, t in ed:
        for kind in KINDS:
            for x in t[kind]:
                e_tok[kind].add(x)
                e_where[x].append((uid, t))

    findings = 0
    for kind in KINDS:
        carried = e_tok[kind] | {t for t, b in alias.items() if b in e_tok[kind]}
        lost = sorted(
            t
            for t in s_tok[kind] - carried
            if t not in drop
            and not all(w in dropped_units for w in s_where[t])
            and not (kind == "numbers" and t in TRIVIAL)
        )
        explained = set(s_tok[kind]) | set(alias.values())
        invented = sorted(t for t in e_tok[kind] - explained if not (kind == "numbers" and t in TRIVIAL))
        for t in lost:
            print(f"lost {kind[:-1]}: {t!r}  (in {', '.join(s_where[t][:3])})")
        for t in invented:
            print(f"invented {kind[:-1]}: {t!r}  (at {', '.join(w for w, _ in e_where[t][:3])})")
        findings += len(lost) + len(invented)

    for u in src:
        if u["id"] in dropped_units or not u["qualifiers"]:
            continue
        for t in u["numbers"]:
            if t in TRIVIAL or len(s_where[t]) > 2:
                continue
            carried = alias.get(t, t)
            if carried not in e_where:
                continue
            near = set().union(*(set(x["qualifiers"]) for _, x in e_where[carried]))
            missing = sorted(q for q in set(u["qualifiers"]) - near if f"{t}|{q}" not in drop)
            if missing:
                print(
                    f"unscoped: {t!r} from {u['id']} (line {u['line']}) lost {missing}"
                    f"  (at {', '.join(w for w, _ in e_where[carried][:3])})"
                )
                findings += 1

    print(f"{len(src)} source units at {rev}, {len(ed)} edition units: {findings} finding(s)")
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The paper's claim register: every unit of `docs/` at one commit, with what it asserts on.

A unit is a heading, a paragraph, a list item or a table row. For each, the register records the
tokens a rewrite must not lose or invent: numbers with their units, evidence IDs (tests, plan
points, requirements, sections), builds and versions, and the qualifiers that scope a claim
(loopback, one host, derived, unmeasured, ...). It is read from git, not the working tree, so a
register names the exact text it was taken from.

usage: paper-claims.py [--rev REV] [--glob 'docs/*.md'] [--files a.md b.md] > claims.jsonl
       paper-claims.py --summary [...]
"""

import argparse
import fnmatch
import json
import re
import subprocess
import sys

UNIT = (
    r"(?:ms|µs|us|ns|s|min|h|days?|Gb/s|Mb/s|kb/s|kB|KiB|MB|MiB|GB|GiB|TB|%|ppm|×|x|vCPUs?|"
    r"cores?|subscribers|packets|runs?|pictures|groups|words)"
)
VALUE = r"\d[\d,]*(?:\.\d+)?"
NUMBER = re.compile(r"(?<![\w.#/§-])[+−-]?" + VALUE + r"(?:\s?[–-]\s?" + VALUE + r")?(?:\s?" + UNIT + r")?(?!\.?\w)")
IDS = re.compile(r"\b(?:T\d+[a-z]?|P[0-2]-[a-z]{1,2}|R[1-8]|B-\d+)\b|§\d+(?:\.\d+)*")
BUILD = re.compile(
    r"\b(?:moq(?:-relay|-lite)?|moqx|moqxr|draft)[ -]v?\d+(?:\.\d+)*(?:-wip)?\b"
    r"|\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{8,10}\b"
)
QUALIFIERS = [
    "loopback",
    "one host",
    "two hosts",
    "one run",
    "one region",
    "one feed",
    "one clip",
    "one build",
    "single",
    "software",
    "wire",
    "hardware",
    "P0",
    "P1",
    "P2",
    "derived",
    "extrapolated",
    "modelled",
    "hypothetical",
    "indicated",
    "measured",
    "unmeasured",
    "not measured",
    "not established",
    "untested",
    "not run",
    "by design",
    "unknown",
    "STRONGLY SUPPORTED",
    "SUPPORTED",
    "NOT SUPPORTED",
    "on the build measured",
    "consistent with",
    "not located",
]
QUAL = re.compile(r"\b(?:" + "|".join(re.escape(q) for q in sorted(QUALIFIERS, key=len, reverse=True)) + r")\b")
LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")


def git_show(rev, path):
    return subprocess.run(["git", "show", f"{rev}:{path}"], capture_output=True, text=True, check=True).stdout


def git_files(rev, pattern):
    out = subprocess.run(["git", "ls-tree", "-r", "--name-only", rev], capture_output=True, text=True, check=True)
    return sorted(p for p in out.stdout.split("\n") if fnmatch.fnmatch(p, pattern))


def norm_number(tok):
    """'3,800 ms' -> '3800 ms'; '124–139' -> '124-139'; minus signs unified."""
    t = tok.replace(",", "").replace("−", "-").replace("–", "-")
    return re.sub(r"\s+", " ", re.sub(r"\s?-\s?", "-", t)).strip()


def tokens(text):
    plain = LINK.sub(r"\1", text)
    plain = plain.replace("**", "").replace("`", "")
    return {
        "numbers": sorted({norm_number(m.group(0)) for m in NUMBER.finditer(plain)}),
        "ids": sorted(set(IDS.findall(plain))),
        "builds": sorted({m.group(0) for m in BUILD.finditer(plain)}),
        "qualifiers": sorted(set(QUAL.findall(plain))),
    }


def units(path, text):
    """Yield (kind, heading path, first line, text) for each unit of one markdown file."""
    heads, block, start, kind = [], [], 0, None

    def flush():
        if block:
            yield kind, " > ".join(heads), start, "\n".join(block)

    lines = text.split("\n")
    in_code = False
    for n, line in enumerate(lines, 1):
        if line.startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        h = re.match(r"^(#{1,6})\s+(.*)", line)
        row = line.startswith("|")
        item = re.match(r"^\s*(?:[-*]|\d+\.)\s+", line)
        if h or not line.strip() or row or item:
            yield from flush()
            block, kind = [], None
        if h:
            level = len(h.group(1))
            heads[:] = heads[: level - 1] + [h.group(2).strip()]
            yield "heading", " > ".join(heads[:-1]), n, h.group(2).strip()
        elif row:
            if not re.match(r"^\|[\s|:-]+\|$", line):
                yield "row", " > ".join(heads), n, line
        elif line.strip():
            if not block:
                start, kind = n, "item" if item else "para"
            block.append(line)
    yield from flush()


def register(rev, files):
    for path in files:
        k = 0
        for kind, where, line, text in units(path, git_show(rev, path)):
            k += 1
            t = tokens(text)
            yield {
                "id": f"{path}#{k}",
                "rev": rev,
                "file": path,
                "line": line,
                "kind": kind,
                "section": where,
                "bold": re.findall(r"\*\*(.+?)\*\*", text),
                **t,
                "text": text,
            }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rev", default="HEAD")
    ap.add_argument("--glob", default="docs/*.md")
    ap.add_argument("--files", nargs="*")
    ap.add_argument("--summary", action="store_true")
    a = ap.parse_args()
    rev = subprocess.run(["git", "rev-parse", "--short=9", a.rev], capture_output=True, text=True, check=True)
    rev = rev.stdout.strip()
    files = a.files or git_files(rev, a.glob)
    reg = list(register(rev, files))
    if a.summary:
        for f in files:
            us = [u for u in reg if u["file"] == f]
            n = sum(len(u["numbers"]) for u in us)
            q = sum(len(u["qualifiers"]) for u in us)
            print(f"{f}: {len(us)} units, {n} numbers, {q} qualifiers")
        print(f"rev {rev}: {len(reg)} units")
        return
    for u in reg:
        sys.stdout.write(json.dumps(u, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()

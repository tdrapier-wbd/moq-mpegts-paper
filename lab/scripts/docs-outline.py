#!/usr/bin/env python3
"""Outline tools for `docs/`: headings, inbound references, contents lists, anchors, renumbering.

    docs-outline.py outline docs/X.md...          each H2/H3: words, heading length, first sentence
    docs-outline.py refs X                        every § reference to docs/X.md, by file and line
    docs-outline.py toc docs/X.md... [--write]    the Contents list, rebuilt from the headings
    docs-outline.py check                         every relative link and anchor in tracked Markdown
    docs-outline.py renumber X map.tsv [--write] [--readme]

`outline` flags LONG (a heading over 40 characters) and NOCLAIM (a section that does not open on a
bold sentence). `renumber` rewrites the § references to docs/X.md, in X itself and in every file
citing it, from an `old<TAB>new` map; a section absent from the map takes its parent's new number.
It changes README.md only with --readme, because the README's wording needs the author's approval.
"""

import argparse
import os
import re
import subprocess
import sys

ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
DOCS = ["problem", "comparison", "architecture", "control-plane", "economics", "primer", "glossary", "getting-started"]
OTHER = {"evidence", "method-notes", "cost-model", "planned-experiments", "upstream-contributions", "readme"}
HEADING = re.compile(r"^(?:>\s*)?(#{1,6})\s+(.*?)\s*$")
NUM = r"\d+(?:\.\d+)*"
CHAIN = re.compile(rf"§\s?{NUM}(?:–§?{NUM})?(?:\s*(?:,|and|or|/)\s*§\s?{NUM}(?:–§?{NUM})?)*")
TAIL = re.compile(r"(?:\[(?P<text>[^\]]*)\](?:\((?P<url>[^)\s]*)\))?|`?(?P<word>[\w./-]+)`?)(?:'s|’s)?[\s(]*$")
LINK = re.compile(r"\]\(([^)\s]+)\)|^\[[^\]]+\]:\s*(\S+)", re.M)


def tracked(pattern):
    out = subprocess.run(["git", "ls-files", pattern], capture_output=True, text=True, cwd=ROOT).stdout
    return [os.path.join(ROOT, p) for p in out.split()]


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def prose_lines(text):
    """Yield (index, line) outside fenced code blocks."""
    fence = False
    for i, line in enumerate(text.split("\n")):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if not fence:
            yield i, line


def slug(text):
    t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    t = re.sub(r"[`*]", "", t)
    t = re.sub(r"(^|[\s(])_+|_+($|[\s).,:;])", r"\1\2", t)
    t = re.sub(r"[^\w\- ]", "", t.strip().lower())
    return t.replace(" ", "-")


def headings(text):
    seen, out = {}, []
    for i, line in prose_lines(text):
        m = HEADING.match(line)
        if m:
            base = slug(m.group(2))
            n = seen.get(base, 0)
            seen[base] = n + 1
            out.append((i, len(m.group(1)), m.group(2), base if n == 0 else f"{base}-{n}"))
    return out


def cited(before):
    """The document a § chain refers to, judged from the text just before it."""
    m = TAIL.search(before[-240:])
    if not m:
        return None
    s = (m.group("url") or m.group("text") or m.group("word") or "").lower().split("#")[0]
    s = os.path.basename(s).removesuffix(".md").replace(" ", "-")
    if s in DOCS:
        return s
    if s in OTHER or s.startswith("test-"):
        return "other"
    return None


def chains(doc):
    """Yield (path, line index, match) for every § chain that refers to docs/<doc>.md."""
    own = os.path.join(ROOT, "docs", f"{doc}.md")
    for path in tracked("*.md"):
        text = read(path)
        lines = text.split("\n")
        for i, line in prose_lines(text):
            for m in CHAIN.finditer(line):
                before = "\n".join(lines[max(0, i - 2) : i] + [line[: m.start()]])
                target = cited(before)
                if target == doc or (target is None and path == own):
                    yield path, i, m


def cmd_outline(args):
    for path in args.files:
        text = read(path)
        lines = text.split("\n")
        hs = headings(text)
        for k, (i, level, title, _) in enumerate(hs):
            if level not in (2, 3):
                continue
            end = hs[k + 1][0] if k + 1 < len(hs) else len(lines)
            body = [ln for ln in lines[i + 1 : end] if ln.strip()]
            first = body[0].strip() if body else ""
            flags = []
            if len(title) > 40:
                flags.append("LONG")
            if body and not first.startswith("**"):
                flags.append("NOCLAIM")
            words = len(" ".join(body).split())
            sentence = re.split(r"(?<=[.!?])\s", first, maxsplit=1)[0][:150]
            print(f"{'  ' * (level - 2)}{title}  [{words}w {len(title)}c{' ' + ' '.join(flags) if flags else ''}]")
            print(f"{'  ' * (level - 2)}    {sentence}")


def cmd_refs(args):
    by_file = {}
    for path, i, m in chains(args.doc):
        by_file.setdefault(os.path.relpath(path, ROOT), []).append(f"{i + 1}:{m.group(0)}")
    for path, refs in sorted(by_file.items(), key=lambda kv: -len(kv[1])):
        print(f"{path} ({len(refs)}): {'; '.join(refs)}")


def contents(text):
    items = []
    for _, level, title, anchor in headings(text):
        if level in (2, 3):
            label = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", title)
            items.append(f"{'  ' * (level - 2)}- [{label}](#{anchor})")
    return items


def cmd_toc(args):
    for path in args.files:
        text = read(path)
        lines = text.split("\n")
        if "**Contents**" not in lines:
            print(f"{path}: no **Contents** line", file=sys.stderr)
            continue
        start = lines.index("**Contents**") + 2
        end = start
        while end < len(lines) and lines[end].lstrip().startswith("- "):
            end += 1
        new = lines[:start] + contents(text) + lines[end:]
        if args.write:
            with open(path, "w", encoding="utf-8") as f:
                f.write("\n".join(new))
        else:
            print("\n".join(contents(text)))


def cmd_check(_args):
    anchors, bad = {}, 0
    for path in tracked("*.md"):
        text = read(path)
        for i, line in prose_lines(text):
            for m in LINK.finditer(line):
                target = m.group(1) or m.group(2)
                if re.match(r"[a-z]+:", target):
                    continue
                file, _, anchor = target.partition("#")
                dest = os.path.normpath(os.path.join(os.path.dirname(path), file)) if file else path
                where = f"{os.path.relpath(path, ROOT)}:{i + 1}"
                if not os.path.exists(dest):
                    print(f"{where}: missing file {target}")
                    bad += 1
                elif anchor and dest.endswith(".md"):
                    if dest not in anchors:
                        anchors[dest] = {a for *_, a in headings(read(dest))}
                    if anchor not in anchors[dest]:
                        print(f"{where}: missing anchor {target}")
                        bad += 1
    print(f"{bad} broken link(s)")
    return 1 if bad else 0


def cmd_renumber(args):
    table = {}
    for line in read(args.map).split("\n"):
        parts = line.split("#")[0].split()
        if len(parts) == 2:
            table[parts[0]] = parts[1]

    def new(num):
        parts = num.split(".")
        for k in range(len(parts), 0, -1):
            head = ".".join(parts[:k])
            if head in table:
                return ".".join([table[head]] + parts[k:])
        return num

    own = os.path.join(ROOT, "docs", f"{args.doc}.md")
    sections = {m.group(1) for _, _, t, _ in headings(read(own)) if (m := re.match(rf"({NUM})\.?\s", t))}
    edits = {}
    for path, i, m in chains(args.doc):
        old = m.group(0)
        stray = [n for n in re.findall(NUM, old) if n not in sections]
        if stray:
            print(f"{os.path.relpath(path, ROOT)}:{i + 1}: {old}  (skipped: no section {', '.join(stray)} here)")
            continue
        rewritten = re.sub(NUM, lambda n: new(n.group(0)), old)
        if rewritten != old:
            edits.setdefault(path, []).append((i, m.start(), m.end(), old, rewritten))
    for path, items in sorted(edits.items()):
        rel = os.path.relpath(path, ROOT)
        held = rel == "README.md" and not args.readme
        for i, _, _, old, rewritten in items:
            print(f"{rel}:{i + 1}: {old} -> {rewritten}{'  (held: README)' if held else ''}")
        if args.write and not held:
            lines = read(path).split("\n")
            for i, start, end, _, rewritten in sorted(items, key=lambda e: (e[0], -e[1])):
                lines[i] = lines[i][:start] + rewritten + lines[i][end:]
            with open(path, "w", encoding="utf-8") as f:
                f.write("\n".join(lines))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("outline")
    s.add_argument("files", nargs="+")
    s = sub.add_parser("refs")
    s.add_argument("doc", choices=DOCS)
    s = sub.add_parser("toc")
    s.add_argument("files", nargs="+")
    s.add_argument("--write", action="store_true")
    sub.add_parser("check")
    s = sub.add_parser("renumber")
    s.add_argument("doc", choices=DOCS)
    s.add_argument("map")
    s.add_argument("--write", action="store_true")
    s.add_argument("--readme", action="store_true")
    args = p.parse_args()
    handler = {"outline": cmd_outline, "refs": cmd_refs, "toc": cmd_toc, "check": cmd_check}
    return handler.get(args.cmd, cmd_renumber)(args) or 0


if __name__ == "__main__":
    sys.exit(main())

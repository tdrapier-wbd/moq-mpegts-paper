#!/usr/bin/env python3
"""Vale on the wording that changed: the alerts on lines of public Markdown added or edited since a revision.

    vale-changed.py                  # the working tree against HEAD, untracked files included
    vale-changed.py --staged         # the index against HEAD (the pre-commit hook)
    vale-changed.py --rev main~3     # the working tree against any revision
    vale-changed.py FILE...          # only these files
    vale-changed.py --all FILE...    # every line of these files

Public Markdown is README.md and *.md under docs/, lab/ and interop/, less *.local.md. Exit status 1
when any alert is reported, 2 when Vale is missing.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HUNK = re.compile(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@")


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def public(path):
    p = Path(path)
    if p.suffix != ".md" or p.name.endswith(".local.md"):
        return False
    return p.parts == ("README.md",) or (len(p.parts) > 1 and p.parts[0] in ("docs", "lab", "interop"))


def changed_files(rev, staged):
    names = git("diff", "--name-only", "--diff-filter=AMR", *(["--cached"] if staged else []), rev).split()
    if not staged:
        names += git("ls-files", "--others", "--exclude-standard").split()
    return sorted({n for n in names if public(n)})


def changed_lines(path, rev, staged):
    """The line numbers of `path` added or edited since `rev`, or None for a file new since it."""
    if subprocess.run(["git", "cat-file", "-e", f"{rev}:{path}"], cwd=ROOT, capture_output=True).returncode:
        return None
    lines = set()
    for line in git("diff", "-U0", *(["--cached"] if staged else []), rev, "--", path).splitlines():
        m = HUNK.match(line)
        if m:
            start, count = int(m[1]), int(m[2] or 1)
            lines.update(range(start, start + count))
    return lines


def lint(path, lines=None, text=None):
    """Vale's alerts on `path` (or on `text`, read as that file), kept to `lines` when given."""
    if text is None:
        cmd, stdin = ["vale", "--output=JSON", str(path)], None
    else:
        cmd, stdin = ["vale", "--output=JSON", "--ext=.md"], text
    out = subprocess.run(cmd, cwd=ROOT, input=stdin, capture_output=True, text=True).stdout
    try:
        alerts = [a for file_alerts in json.loads(out or "{}").values() for a in file_alerts]
    except ValueError:
        sys.exit(f"vale-changed: Vale gave no JSON for {path}: {out[:200]}")
    return [a for a in alerts if lines is None or a["Line"] in lines]


def report(path, alerts):
    return [f"{path}:{a['Line']}:{a['Span'][0]}  {a['Check']}  {a['Message']}" for a in alerts]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--rev", default="HEAD")
    ap.add_argument("--staged", action="store_true", help="lint the index rather than the working tree")
    ap.add_argument("--all", action="store_true", help="report every line, not only the changed ones")
    a = ap.parse_args()
    if not shutil.which("vale"):
        print("vale-changed: vale is not installed", file=sys.stderr)
        return 2
    files = [str(Path(f).resolve().relative_to(ROOT)) for f in a.files] or changed_files(a.rev, a.staged)
    out = []
    for f in files:
        lines = None if a.all else changed_lines(f, a.rev, a.staged)
        if lines == set():
            continue
        text = git("show", f":{f}") if a.staged else None
        out += report(f, lint(f, lines, text))
    print("\n".join(out) if out else f"vale-changed: no alerts on the changed lines of {len(files)} file(s)")
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main())

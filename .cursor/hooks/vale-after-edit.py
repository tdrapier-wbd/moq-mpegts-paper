#!/usr/bin/env python3
"""postToolUse hook: Vale on the wording an agent edit wrote to public Markdown, handed back to the agent.

Cursor reports a replacement as a `Write` of the whole file, so the hook lints the lines changed since
HEAD (lab/scripts/vale-changed.py) and reports only alerts it has not already reported this session.
Fails open: no output means nothing new to report.
"""

import importlib.util
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("vale_changed", ROOT / "lab/scripts/vale-changed.py")
vc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vc)


def main():
    event = json.load(sys.stdin)
    path = (event.get("tool_input") or {}).get("file_path")
    if not path:
        return
    path = Path(path).resolve()
    if not path.is_relative_to(ROOT) or not path.is_file():
        return
    rel = str(path.relative_to(ROOT))
    if not vc.public(rel) or not vc.shutil.which("vale"):
        return
    lines = vc.changed_lines(rel, "HEAD", False)
    if lines == set():
        return
    text = path.read_text().splitlines()
    seen_file = Path(tempfile.gettempdir()) / f"vale-hook-{event.get('conversation_id', 'none')}.json"
    seen = json.loads(seen_file.read_text()) if seen_file.exists() else {}
    known = set(seen.get(rel, []))
    new = []
    for a in vc.lint(rel, lines):
        key = f"{a['Check']}|{a['Match']}|{text[a['Line'] - 1].strip()}"
        if key not in known:
            known.add(key)
            new.append(a)
    seen[rel] = sorted(known)
    seen_file.write_text(json.dumps(seen))
    if new:
        context = "Vale on the wording this edit changed (fix each, or add a genuine term to PaperVocab):\n"
        print(json.dumps({"additional_context": context + "\n".join(vc.report(rel, new))}))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # a lint hook never blocks an edit
        print(f"vale-after-edit: {e}", file=sys.stderr)

#!/usr/bin/env python3
"""Wait for Codex's and CodeRabbit's reviews of a pull request's current head; return once both
have finished on it, never after a fixed wait.

    pr-await-bots.py <owner/repo> <pr> [--poll 30] [--max-min 45] [--no-codex]

Codex is done when its summary comment's `codex-review-state` names the head with status
`completed`. CodeRabbit is done when it has a review on the head, or its summary marks the head
assessed with no review in progress. A Codex status naming a failure, and CodeRabbit's "Reviews
paused" or "Review skipped", end that bot's wait as a failure. A push meanwhile restarts both on the
new head. Then it prints the head's review comments and review bodies, the input to the loop's
reply step. Exit 0 when both finished, 2 when a bot failed, paused or skipped, 1 on timeout, 3 when
the PR is a draft (CodeRabbit skips drafts; Codex waits for ready).
"""
import argparse
import json
import re
import subprocess
import sys
import time

CODEX = "chatgpt-codex-connector[bot]"
RABBIT = "coderabbitai[bot]"
STATE = re.compile(r"codex-review-state:v1 (\{.*?\})\s*-->", re.S)


def gh(*args):
    out = subprocess.run(["gh", *args], capture_output=True, text=True)
    if out.returncode:
        raise RuntimeError(out.stderr.strip())
    return out.stdout


def paged(path):
    return [x for page in json.loads(gh("api", "--paginate", "--slurp", path)) for x in page]


def codex_state(comments, head):
    for c in comments:
        if c["user"]["login"] != CODEX:
            continue
        m = STATE.search(c["body"] or "")
        if not m:
            continue
        try:
            review = json.loads(m.group(1)).get("code_review", {})
        except ValueError:
            continue
        if review.get("commit_sha") != head:
            return "waiting", f"last read {str(review.get('commit_sha'))[:9]}"
        status = str(review.get("status", ""))
        if status == "completed":
            return "done", "findings" if review.get("has_any_findings") else "no findings"
        if re.search(r"fail|error|cancel", status):
            return "failed", status
        return "waiting", status or "in progress"
    return "waiting", "no summary yet"


def rabbit_state(comments, reviews, head):
    if any(r["user"]["login"] == RABBIT and r["commit_id"] == head for r in reviews):
        return "done", "reviewed the head"
    for c in comments:
        if c["user"]["login"] != RABBIT:
            continue
        body = c["body"] or ""
        if "review in progress by coderabbit.ai" in body:
            return "waiting", "in progress"
        if re.search(r"Reviews? paused", body):
            return "failed", "reviews paused"
        if re.search(r"Review skipped", body) and head in body:
            return "failed", "review skipped"
        if f'change_assessment_commit:"{head}"' in body:
            return "done", "assessed the head, no review comments"
    return "waiting", "no review on the head"


def report(repo, n, head):
    comments = paged(f"repos/{repo}/pulls/{n}/comments?per_page=100")
    reviews = paged(f"repos/{repo}/pulls/{n}/reviews?per_page=100")
    print(f"\n# Review comments on {head[:9]}")
    for c in comments:
        if c.get("commit_id") == head and c["user"]["login"] in (CODEX, RABBIT) and not c.get("in_reply_to_id"):
            print(f"\n## {c['id']} {c['user']['login']} {c['path']}:{c.get('line')}\n{c['body']}")
    for r in reviews:
        if r["commit_id"] == head and r["user"]["login"] in (CODEX, RABBIT) and r["body"].strip():
            print(f"\n## review {r['id']} {r['user']['login']}\n{r['body']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("pr", type=int)
    ap.add_argument("--poll", type=int, default=30, help="seconds between polls")
    ap.add_argument("--max-min", type=int, default=45, help="give up after this many minutes")
    ap.add_argument("--no-codex", action="store_true", help="wait for CodeRabbit only")
    a = ap.parse_args()
    deadline = time.time() + a.max_min * 60
    head, last = None, None
    while True:
        pr = json.loads(gh("pr", "view", str(a.pr), "-R", a.repo, "--json", "headRefOid,isDraft,state"))
        if pr["state"] != "OPEN":
            print(f"PR is {pr['state'].lower()}")
            return 0
        if pr["isDraft"]:
            print("PR is a draft: CodeRabbit skips drafts and Codex waits for ready")
            return 3
        if pr["headRefOid"] != head:
            if head:
                print(f"new head {pr['headRefOid'][:9]} (was {head[:9]}): waiting again")
            head = pr["headRefOid"]
        comments = paged(f"repos/{a.repo}/issues/{a.pr}/comments?per_page=100")
        reviews = paged(f"repos/{a.repo}/pulls/{a.pr}/reviews?per_page=100")
        cx = ("done", "not awaited") if a.no_codex else codex_state(comments, head)
        cr = rabbit_state(comments, reviews, head)
        line = f"{time.strftime('%H:%M:%S')} {head[:9]} codex: {cx[0]} ({cx[1]}); coderabbit: {cr[0]} ({cr[1]})"
        if line[9:] != last:
            print(line, flush=True)
            last = line[9:]
        if cx[0] != "waiting" and cr[0] != "waiting":
            report(a.repo, a.pr, head)
            return 2 if "failed" in (cx[0], cr[0]) else 0
        if time.time() > deadline:
            print(f"timed out after {a.max_min} min")
            return 1
        time.sleep(a.poll)


if __name__ == "__main__":
    sys.exit(main())

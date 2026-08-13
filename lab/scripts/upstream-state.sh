#!/usr/bin/env bash
# What happened upstream while we were away?
#
# Reads every issue/PR number mentioned in the given files and reports each one's live
# state, so a status document can be checked against reality rather than trusted. Merged
# is distinguished from closed, and a merged PR's base branch is printed because
# `moq-dev/moq` keeps a `dev` branch for semver-breaking work: merged into `dev` does not
# mean present in a `main` build.
#
# Requires `gh` authenticated against the repository.
#
# Usage: upstream-state.sh [--repo owner/name] [--open-only] <file>...
#        upstream-state.sh STATUS.md lab/*.md

set -euo pipefail

REPO="moq-dev/moq"
OPEN_ONLY=""
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO="$2"
            shift 2
            ;;
        --open-only)
            OPEN_ONLY=1
            shift
            ;;
        -h | --help)
            sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            FILES+=("$1")
            shift
            ;;
    esac
done

[[ ${#FILES[@]} -gt 0 ]] || {
    echo "usage: $(basename "$0") [--repo owner/name] [--open-only] <file>..." >&2
    exit 2
}
command -v gh >/dev/null 2>&1 || {
    echo "error: gh is required" >&2
    exit 1
}

# Both link forms and the bare #NNNN. Four digits or more: #14 in prose is not an issue.
NUMBERS=$(grep -ohE '(issues|pull)/[0-9]+|#[0-9]{3,6}\b' "${FILES[@]}" |
    grep -oE '[0-9]{3,6}' | sort -un)

[[ -n "$NUMBERS" ]] || {
    echo "no issue or PR references found"
    exit 0
}

printf '%-7s %-8s %-12s %s\n' NUMBER STATE KIND TITLE
for n in $NUMBERS; do
    json=$(gh api "repos/$REPO/issues/$n" 2>/dev/null) || {
        printf '%-7s %-8s %-12s %s\n' "#$n" "-" "-" "(no such issue or PR)"
        continue
    }
    read -r state kind title <<<"$(python3 -c "
import json, sys
d = json.load(sys.stdin)
pr = d.get('pull_request')
state = d['state']
kind = 'issue'
if pr:
    kind = 'PR'
    if pr.get('merged_at'):
        state = 'merged'
print(state, kind, d['title'][:64].replace('\n', ' '))
" <<<"$json")"
    [[ -n "$OPEN_ONLY" && "$state" != "open" ]] && continue
    base=""
    if [[ "$kind" == "PR" ]]; then
        base=$(gh api "repos/$REPO/pulls/$n" --jq '.base.ref' 2>/dev/null || true)
        [[ -n "$base" ]] && kind="PR→$base"
    fi
    printf '%-7s %-8s %-12s %s\n' "#$n" "$state" "$kind" "$title"
done

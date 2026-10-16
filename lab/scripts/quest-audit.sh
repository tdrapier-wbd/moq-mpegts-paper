#!/usr/bin/env bash
# Is planned-experiments.md's quest table still true of upstream?
#
# Resolves every quest the section "Upstream quests worth building" names against `quest/` on
# upstream `main`, and reports per quest: its file (or the commit that deleted it), its size tag
# against the table's, open pull requests whose branch or body name it, and whether its file
# changed since the last audit. Then lists TS-related quests added since that audit, which the
# table neither ranks nor sets aside. It changes nothing: each flag is a row to re-read.
#
# Requires a clone of moq-dev/moq (`origin` = upstream) and `gh`. Fetches `origin main`; never
# touches the clone's working tree.
#
# Usage: quest-audit.sh [--repo-dir <clone>] [<last-audited-sha>]
#        quest-audit.sh 3abf0161c

set -euo pipefail

DIR="${HOME}/moq-dev"
SINCE=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo-dir)
		DIR="$2"
		shift 2
		;;
	-h | --help)
		sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		SINCE="$1"
		shift
		;;
	esac
done

PLAN="$(cd "$(dirname "$0")/.." && pwd)/planned-experiments.md"
git -C "$DIR" fetch -q origin main
MAIN=$(git -C "$DIR" rev-parse --short=9 origin/main)
TREE=$(git -C "$DIR" ls-tree -r --name-only origin/main quest/)
SECTION=$(awk '/^## Upstream quests worth building/{p=1; next} p && /^## /{exit} p' "$PLAN")
PRS=$(gh pr list --repo moq-dev/moq --state open --limit 300 \
	--json number,headRefName,body --jq '.[] | "\(.number)\t\(.headRefName)\t\(.body | gsub("\n"; " "))"')

# shellcheck disable=SC2016 # the backticks are the pattern, not a substitution
NAMES=$(grep -o '`[a-z0-9][a-z0-9/-]*`' <<<"$SECTION" | tr -d '`' | grep -E '[-/]' | sort -u)

echo "quest table against upstream main ${MAIN}${SINCE:+, changes since ${SINCE}}"
for name in $NAMES; do
	path=$(grep -E "^quest/([^/]+/)+${name}(\.md|/README\.md)$" <<<"$TREE" | head -1 || true)
	if [[ -z "$path" ]]; then
		gone=$(git -C "$DIR" log origin/main --format='%h %s' --diff-filter=D -1 -- "quest/*${name}.md" "quest/*${name}/README.md")
		printf '%-6s %s: %s\n' GONE "$name" "${gone:-never on main}"
		continue
	fi
	have=$(git -C "$DIR" show "origin/main:${path}" | head -1 | grep -o '^# \[[SML]\]' | tr -d '# ' || true)
	table=$(grep -o "\`${name}\` \[[SML]\]" <<<"$SECTION" | grep -o '\[[SML]\]' | head -1 || true)
	flags=""
	[[ -n "$table" && "$table" != "$have" ]] && flags+=" size ${table}->${have}"
	taken=$(awk -F'\t' -v n="$name" 'index($2, n) || index($3, n) {print "#" $1 " (" $2 ")"}' <<<"$PRS" | tr '\n' ' ')
	[[ -n "$taken" ]] && flags+=" named-by ${taken}"
	if [[ -n "$SINCE" ]] && [[ -n $(git -C "$DIR" log --format=%h -1 "${SINCE}..origin/main" -- "$path") ]]; then
		flags+=" changed"
	fi
	status=ok
	[[ -n "$flags" ]] && status=CHECK
	printf '%-6s %s %s%s\n' "$status" "$name" "$have" "$flags"
done

if [[ -n "$SINCE" ]]; then
	echo "TS-related quests added since ${SINCE}, not named in the section:"
	git -C "$DIR" diff --name-only --diff-filter=A "${SINCE}" origin/main -- quest/ |
		grep -iE 'ts|tstd|mpegts|m2ts|srt|scte|pcr|epoch' |
		while read -r f; do
			n=${f#quest/*/}
			n=${n%.md}
			n=${n%/README}
			grep -qF "\`${n}\`" <<<"$SECTION" || echo "  ${f}: $(git -C "$DIR" show "origin/main:${f}" | head -1)"
		done
fi
echo "record in STATUS.md: quests audited at main ${MAIN}"

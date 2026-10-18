#!/usr/bin/env bash
# Is STATUS.md's upstream tracker still true?
#
# Reads every table row under STATUS.md's "## Upstream": the GitHub links in its first cell are the
# tracked items, and the row's first ISO date is the last word already read. Reports, per item, its
# state and who spoke last: `ok` when nothing needs reading, `CHECK` with flags otherwise. It changes
# nothing: each flag is a row to re-read.
#
#   merged, closed   the item ended: the ledger records its final state; the row goes
#   reply <login>    someone other than us spoke after our last word and the row's date
#   bot <login>      an automated reviewer did
#   ci <checks>      failing checks on a pull request that the row does not already name
#   changes          a reviewer requested changes
#   draft            the pull request is a draft (reported, not flagged)
#
# Requires `gh`. Usage: upstream-audit.sh [--me <login>] [<status-file>]

set -euo pipefail

ME="t0ms"
STATUS="$(cd "$(dirname "$0")/../.." && pwd)/STATUS.md"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--me)
		ME="$2"
		shift 2
		;;
	-h | --help)
		sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		STATUS="$1"
		shift
		;;
	esac
done

ROWS=$(awk '/^## Upstream/ { p = 1; next } /^## / { p = 0 } p && /^\|/' "$STATUS")
grep -qE '^\|[^|]*https://github\.com/' <<<"$ROWS" || {
	echo "no tracked links under '## Upstream' in $STATUS" >&2
	exit 1
}

# shellcheck disable=SC2016
JQ='
def bot: test("\\[bot\\]$|^(github-actions|coderabbitai|copilot|chatgpt-codex-connector)"; "i");
(([.comments[]? | {who: .author.login, at: .createdAt}]
	+ [.reviews[]? | select(.state != "PENDING") | {who: .author.login, at: .submittedAt}])
	| sort_by(.at)) as $words
| ([($words | map(select(.who == $me)) | last | .at // ""), $read] | max) as $mine
| ($words | map(select(.at > $mine and .who != $me))) as $after
| ($words | last) as $last
| [
	(if .state == "MERGED" then "merged" elif .state == "CLOSED" then "closed" else empty end),
	($after | map(select(.who | bot | not)) | if length > 0 then "reply " + (map(.who) | unique | join(",")) else empty end),
	($after | map(select(.who | bot)) | if length > 0 then "bot " + (map(.who) | unique | join(",")) else empty end),
	([.statusCheckRollup[]? | select((.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED"; "i")) | (.name // .context)]
		| unique | map(select(. as $check | $row | contains($check) | not))
		| if length > 0 then "ci " + join(",") else empty end),
	(if .reviewDecision == "CHANGES_REQUESTED" then "changes" else empty end)
] as $flags
| (if .isDraft == true then ", draft" else "" end) as $draft
| "\(if ($flags | length) > 0 then "CHECK" else "ok   " end)  \($id)  \(.state | ascii_downcase)\($draft), "
	+ (if $last then "last word \($last.who) \($last.at[0:10])" else "no replies" end)
	+ (if ($flags | length) > 0 then ": " + ($flags | join("; ")) else "" end)
'

echo "upstream tracker in $(basename "$STATUS"), as $ME, $(date -u +%Y-%m-%dT%H:%MZ)"
while IFS= read -r row; do
	first=$(awk -F'|' '{ print $2 }' <<<"$row")
	seen=$(grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' <<<"$row" | head -1 || true)
	for url in $(grep -oE 'https://github\.com/[^/]+/[^/]+/(issues|pull)/[0-9]+' <<<"$first" || true); do
		repo=$(cut -d/ -f4,5 <<<"$url")
		num=${url##*/}
		if [[ "$url" == */pull/* ]]; then
			json=$(gh pr view "$num" -R "$repo" --json state,isDraft,comments,reviews,statusCheckRollup,reviewDecision)
		else
			json=$(gh issue view "$num" -R "$repo" --json state,comments)
		fi
		jq -r --arg me "$ME" --arg id "$repo#$num" --arg row "$row" \
			--arg read "${seen:+${seen}T23:59:59Z}" "$JQ" <<<"$json"
	done
done <<<"$ROWS"

#!/usr/bin/env bash
# What moved in moq2ts, and in moq-dev's TS code, that lab/cross-check.md does not yet answer?
#
# Lists every openmoq/moq2ts issue and pull request updated since DATE, and every commit on moq-dev
# `main` since SHA that touches the TS path (moq-mux's TS container and catalog, moq-srt, moq-msf).
# Each line is `ok` when cross-check.md cites the item and `new` when it does not. It changes
# nothing: each `new` line is an item to triage into the register, or to pass over (build,
# packaging, UI). Then set STATUS.md's cross-check line to the date and the `main` it printed.
#
# Requires a clone of moq-dev/moq (`origin` = upstream) and `gh`. Fetches `origin main`; never
# touches the clone's working tree.
#
# Usage: cross-audit.sh [--repo-dir <clone>] <since-date> <since-sha>
#        cross-audit.sh 2026-11-10 cd560bde5e

set -euo pipefail

DIR="${HOME}/moq-dev"
ARGS=()
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
		ARGS+=("$1")
		shift
		;;
	esac
done
[[ ${#ARGS[@]} -eq 2 ]] || {
	sed -n '13,14p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}
SINCE_DATE=${ARGS[0]} SINCE_SHA=${ARGS[1]}

REG="$(cd "$(dirname "$0")/.." && pwd)/cross-check.md"
git -C "$DIR" fetch -q origin main
MAIN=$(git -C "$DIR" rev-parse --short=10 origin/main)

cited() { # <repo path> <number>: ok when the register links the item
	if grep -qE "github\.com/$1/(issues|pull)/$2([^0-9]|$)" "$REG"; then echo ok; else echo new; fi
}

echo "cross-check against moq2ts updated since ${SINCE_DATE} and moq-dev ${SINCE_SHA}..${MAIN}"
for kind in issue pr; do
	gh "$kind" list --repo openmoq/moq2ts --state all --limit 200 --search "updated:>=${SINCE_DATE}" \
		--json number,state,author,title --jq '.[] | "\(.number)\t\(.state)\t\(.author.login)\t\(.title)"' |
		while IFS=$'\t' read -r n state who title; do
			printf '%-4s moq2ts#%s %s %s %s: %s\n' "$(cited openmoq/moq2ts "$n")" "$n" "$kind" "$state" "$who" "$title"
		done
done
git -C "$DIR" log --format='%h%x09%s' "${SINCE_SHA}..origin/main" -- \
	rs/moq-mux/src/container/ts rs/moq-mux/src/catalog rs/moq-srt rs/moq-msf |
	while IFS=$'\t' read -r h subject; do
		pr=$(grep -oE '\(#[0-9]+\)$' <<<"$subject" | tr -dc '0-9' || true)
		mark=new
		[[ -n "$pr" ]] && mark=$(cited moq-dev/moq "$pr")
		printf '%-4s moq-dev %s: %s\n' "$mark" "$h" "$subject"
	done

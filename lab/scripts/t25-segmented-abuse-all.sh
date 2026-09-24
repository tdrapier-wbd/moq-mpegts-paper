#!/usr/bin/env bash
# Run every T25 segmented-abuse arm in one pass, with a verified-clean host between arms.
#
# This exists as a file rather than as an ssh one-liner for one reason: the cleanup pattern has
# to match the rig's processes, and if the same literal appears in the command line of the shell
# issuing it, `pkill -f` matches that too and kills the session. Running from a file keeps the
# pattern out of the caller's argv. See method-notes.md.
#
# Usage: t25-segmented-abuse-all.sh [label] [window_s]
set -u

LABEL="${1:-p2b}"
WINDOW="${2:-60}"
RIG="${RIG:-$HOME/t25-segmented-abuse.sh}"
PAT='t25seg[.]'

sweep() {
	pkill -9 -f "$PAT" 2>/dev/null
	sleep 4
	if pgrep -f "$PAT" >/dev/null 2>&1; then
		echo "WARN: processes survived the sweep:" >&2
		pgrep -af "$PAT" >&2
	fi
}

sweep
rm -rf "$HOME/t25seg"

for arm in control churn slow flood; do
	echo "########## $arm ##########"
	bash "$RIG" "$LABEL" "$arm" "$WINDOW" 2>&1 |
		grep -E "^label=|^victim|^nginx_rss|FATAL|FAIL"
	sweep
done

echo
echo "########## summary ##########"
printf '%-9s %14s %14s %14s %6s %6s %10s\n' ARM victim1 victim2 victim3 CC HOLES 'nginx peak'
for arm in control churn slow flood; do
	r="$HOME/t25seg/$LABEL-$arm/result"
	[ -f "$r" ] || {
		printf '%-9s %s\n' "$arm" "(no result)"
		continue
	}
	# shellcheck disable=SC2046  # the fields are numeric and word-splitting is intended
	printf '%-9s %14s %14s %14s %6s %6s %10s\n' "$arm" \
		$(sed -n 's/^victim1 bytes=\([0-9]*\).*/\1/p' "$r") \
		$(sed -n 's/^victim2 bytes=\([0-9]*\).*/\1/p' "$r") \
		$(sed -n 's/^victim3 bytes=\([0-9]*\).*/\1/p' "$r") \
		"$(grep -c 'cc_errors=[1-9]' "$r")" \
		"$(grep -c 'holes=[1-9]' "$r")" \
		"$(sed -n 's/.*nginx_rss_peak_mb=\([0-9.]*\).*/\1/p' "$r")"
done

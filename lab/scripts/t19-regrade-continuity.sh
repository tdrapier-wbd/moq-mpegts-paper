#!/usr/bin/env bash
#
# T19 -- re-grade the cushion sweep's continuity column against the retained wires.
#
# The sweep's `cc_errors` column read 0 on every rung, including the three that shed more than
# 78 % of the programme. It was counting `tsp -P continuity` output lines matching `TS:`, a string
# that plugin never writes, so the column was a constant rather than a measurement (T42's method
# rule; the pattern is now gated in check-rigs.sh). The sweep keeps the graded wire of each arm
# precisely so a column can be re-examined without re-running it, which is what this does.
#
# Reports three numbers per rung rather than one, because on an arm that has shed most of its
# content they mean different things: the number of continuity *events*, the number of packets
# those events account for, and the per-PID spread. A single event missing 80,000 packets and
# 80,000 events missing one packet each are both "continuity errors" and grade very differently.
#
# Usage: t19-regrade-continuity.sh <sweep-dir> [prefix ...]     (default prefixes: old new)

set -u

DIR="${1:?usage: t19-regrade-continuity.sh <sweep-dir> [prefix ...]}"
shift || true
PREFIXES=("$@")
[ ${#PREFIXES[@]} -eq 0 ] && PREFIXES=(old new)

printf '%-6s %-8s %12s %10s %14s %8s %10s\n' \
	ARM CUSHION PACKETS EVENTS 'MISSING_PKTS' PIDS 'LOSS_PCT'

for prefix in "${PREFIXES[@]}"; do
	for f in "$DIR/$prefix"*.ts; do
		[ -e "$f" ] || continue
		base=$(basename "$f" .ts)
		cushion=${base#"$prefix"}

		# One pass of the plugin, three readings off it. `-O drop` so nothing is written.
		rpt=$(tsp -I file "$f" -P continuity -O drop 2>&1)
		events=$(printf '%s\n' "$rpt" | grep -cE 'missing .* packets|discontinuity' || true)
		missing=$(printf '%s\n' "$rpt" |
			sed -n 's/.*missing \([0-9,]*\) packets.*/\1/p' | tr -d ',' |
			awk '{s+=$1} END{print s+0}')
		pids=$(printf '%s\n' "$rpt" |
			sed -n 's/.*PID: \(0x[0-9A-Fa-f]*\).*/\1/p' | sort -u | wc -l | tr -d ' ')

		pkts=$(($(stat -f%z "$f" 2>/dev/null || stat -c%s "$f") / 188))
		# Expressed against the delivered packet count, so it reads as "of what arrived, this
		# much again was missing" -- the denominator the sweep's own conservation figure uses.
		pct=$(awk -v m="$missing" -v p="$pkts" 'BEGIN{printf "%.2f", p? m/(m+p)*100 : 0}')

		printf '%-6s %-8s %12s %10s %14s %8s %10s\n' \
			"$prefix" "$cushion" "$pkts" "$events" "$missing" "$pids" "$pct"
	done
done

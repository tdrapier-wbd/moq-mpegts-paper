#!/usr/bin/env bash
#
# T20 -- re-measure the impairment cells through the byte-faithful receiver.
#
# The published impairment cells were graded through `ffmpeg -c copy -f mpegts`, which re-muxes:
# T42 measured it reporting 0 continuity errors on an origin missing ten transport packets, and
# the clean-baseline re-run showed it also moves `delivered_ratio` by 11.6 % because it discards
# the null packets and the NIT/TDT/TOT that the wire carries. So neither the carriage columns nor
# the delivery columns of those cells survive the receiver change untested, and this re-runs them.
#
# One invocation per cell per arm, because `t20-h3-arm.sh` owns the loopback shaper and the
# origin for the length of a run and two concurrent arms would shape each other. That serialises
# the whole sweep; budget ~35 minutes for the default cell list.
#
# Usage: t20-impair-rerun.sh [cell ...]     (default: every cell below)
# Env:   ARMS      arms to run per cell     (default "h1 h3 moq")
#        ROOT      run directory            (default ~/t20v)
#        RECV      receiver                 (default verbatim -- the point of the exercise)

set -u

ROOT="${ROOT:-$HOME/t20v}"
ARMS="${ARMS:-h1 h3 moq}"
export RECV="${RECV:-verbatim}"
mkdir -p "$ROOT"

# Cell definitions: name | window | env assignments. The cells chosen are the four the experiment
# draws a conclusion from -- the reordering cell, the one loss rung that discriminates, the one
# outage length that discriminates, and the sustained capacity shortfall. The rungs that were flat
# under the old receiver (loss 1-10 %, the 500 ms and 5 s outages, the transient dips) are not
# re-run: they separated nothing, so a receiver change cannot alter what they decided.
cells() {
	cat <<-'EOF'
		reorder|60|IMPAIR=delay 30ms reorder 25% 50%
		loss20|60|IMPAIR=loss 20%
		outage30|75|OUTAGE_S=30;OUTAGE_AT=15
		cap8perm|90|IMPAIR=rate 20mbit;RATE_BASE=20mbit;DIP_RATE=8mbit;DIP_S=perm;DIP_AT=20
	EOF
}

want=("$@")
selected() {
	[ ${#want[@]} -eq 0 ] && return 0
	local c
	for c in "${want[@]}"; do [ "$c" = "$1" ] && return 0; done
	return 1
}

run_cell() {
	local name="$1" window="$2" envs="$3" arm
	for arm in $ARMS; do
		echo "########## $name / $arm ##########"
		(
			# Split on ';' so a cell can set several variables; each assignment is exported
			# into the child rather than prefixed on the command line, because the netem
			# specs contain spaces and a prefix would word-split them.
			local IFS=';'
			for kv in $envs; do export "${kv?}"; done
			OUTDIR="$ROOT/$name" timeout 400 bash "$HOME/t20-h3-arm.sh" "$name" "$arm" "$window"
		) 2>&1 | tail -12
		sleep 3
	done
}

while IFS='|' read -r name window envs; do
	[ -z "$name" ] && continue
	selected "$name" || continue
	run_cell "$name" "$window" "$envs"
done < <(cells)

echo
echo "########## summary ##########"
# Read the result blocks with sed rather than sourcing them: the values contain spaces and
# percent signs, and an eval over them mangles both. (It did, and produced a summary of `?`s
# over a set of perfectly good runs.)
rkey() { sed -n "s/^.*[[:space:]]\{0,\}$2=\([^ ]*\).*$/\1/p" "$1" | head -1; }
printf '%-10s %-4s %11s %8s %6s %12s %10s  %s\n' CELL ARM BYTES RATIO CC 'MEDIA_LOST' 'LARGEST' CARRIAGE
for f in "$ROOT"/*/*.result; do
	[ -e "$f" ] || continue
	d=$(dirname "$f")
	arm=$(basename "$f" .result)
	lost=- largest=-
	if [ -s "$d/${arm}_pcr.csv" ] && [ -n "${GRADER:-$HOME/t28-media-lost.py}" ]; then
		read -r lost largest < <(python3 "${GRADER:-$HOME/t28-media-lost.py}" \
			--csv "$d/${arm}_pcr.csv" --json "$d/$arm.grade.json" >/dev/null 2>&1 &&
			python3 -c "
import json,sys
g=json.load(open(sys.argv[1]))
print(f\"{g['media_lost_s']:.3f}\", f\"{g['largest_hole_s']:.3f}\")
" "$d/$arm.grade.json" || echo "- -")
	fi
	printf '%-10s %-4s %11s %8s %6s %12s %10s  %s\n' \
		"$(basename "$d")" "$arm" \
		"$(rkey "$f" bytes)" "$(rkey "$f" delivered_ratio)" "$(rkey "$f" cc_errors)" \
		"$lost" "$largest" "$(sed -n 's/^carriage_valid=//p' "$f" | head -1)"
done

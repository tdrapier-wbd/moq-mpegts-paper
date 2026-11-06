#!/bin/bash
# T21: does a 1 s export at the catalog's rate survive the import raising its published rate?
#
# Each trial is a fresh loopback relay, import and export of a recording. A thinned arm drops one
# packet in 500 of the source's first PACKETS, all from the arm's listed PIDs, so the import's
# meter publishes a rate about 0.2 % low and raises it once the thinning ends; a plain arm drops
# nothing. One export at the catalog's rate, `--delay 1s`, runs from before the source starts,
# under the PCR monitor in 10 s windows; the trial records whether it ended, when, and the error
# it named. The arms run in turn, TRIALS of each.
#
# ARMS is a space-separated list of NAME:CLIP:PACKETS:PIDS (PACKETS 0 for a plain arm). The
# default: the live feed's 300 s capture (25 Mb/s, no stuffing) thinned on its two data PIDs, the
# same capture plain, and the clip thinned on its null packets, which leave its export 4 % spare.
#
# Usage: MOQ=<bin dir> [TRIALS=8] [SECS=50] [ARMS=...] t21-revision-exit.sh <out dir>
set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=moq-cli-flags.sh
. "$R/moq-cli-flags.sh"
OUT=${1:?out dir}
MOQ=${MOQ:?bin dir}
TRIALS=${TRIALS:-8}
SECS=${SECS:-50}
ARMS=${ARMS:-"L:$HOME/live300.ts:500000:123,131 N:$HOME/live300.ts:0: C:$HOME/contrib-10m.ts:200000:8191"}
PORT=${PORT:-9871}
M=$MOQ/moq

moq_cli_detect "$M" "$MOQ/moq-relay"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
U="https://127.0.0.1:$PORT/anon"
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
reason() { # log: its last error line, colour codes stripped
	sed -E 's/\x1b\[[0-9;]*m//g' "$1" 2>/dev/null | grep -i 'error\|missed' | tail -1 | cut -c1-240
}
cleanup() {
	pkill -f "127\.0\.0\.1:$PORT/anon" 2>/dev/null
	pkill -f "moq-relay --listen 127\.0\.0\.1:$PORT" 2>/dev/null
	pkill -f "tsp --realtime -I file .* -P regulate --pcr-synchronous -O file -$" 2>/dev/null
}
trap cleanup EXIT

for arm in $ARMS; do
	IFS=: read -r _ clip _ _ <<<"$arm"
	[ -s "$clip" ] || {
		echo "no clip at $clip"
		exit 1
	}
done
[ -f "$MOQ.sha" ] && echo "build: $(head -1 "$MOQ.sha")"
printf 'trial\tarm\tthin_end\texport_end\treason\n' >"$OUT/trials.tsv"

trial() { # n spec
	local n=$1 name clip packets pids d relay thin=() t_thin=- t_end=- why=- t_int src
	IFS=: read -r name clip packets pids <<<"$2"
	d="$OUT/$n-$name"
	mkdir -p "$d"
	[ "$packets" -gt 0 ] && thin=(--thin "500:$packets:$pids")
	moq_relay_public 127.0.0.1:$PORT localhost --log-level warn
	"$MOQ/moq-relay" "${RELAY_ARGV[@]}" >"$d/relay.log" 2>&1 &
	relay=$!
	sleep 1.5
	kill -0 $relay 2>/dev/null || {
		echo "relay did not start"
		exit 1
	}
	{
		sh -c 'echo $$ >"$0"; exec "$@"' "$d/export.pid" "$M" "${MOQ_DIAL[@]}" "$U" "${MOQ_GSO[@]}" \
			--broadcast ch1 export ts "${MOQ_LAT[@]}" 1s 2>"$d/export.log"
		now >"$d/export.end"
	} | python3 "$R/t21-pcr-monitor.py" --window 10 >"$d/monitor.tsv" &
	sleep 1
	sh -c 'echo $$ >"$0"; exec tsp --realtime -I file "$1" -P regulate --pcr-synchronous -O file -' \
		"$d/tsp.pid" "$clip" 2>"$d/tsp.log" |
		python3 "$R/t39b-tap.py" bytes --log "$d/marks.tsv" ${thin[@]+"${thin[@]}"} |
		"$M" "${MOQ_DIAL[@]}" "$U" "${MOQ_GSO[@]}" --broadcast ch1 import ts >"$d/import.log" 2>&1 &
	src=$!
	sleep "$SECS"
	t_int=$(now)
	[ -s "$d/export.pid" ] && kill -INT "$(cat "$d/export.pid")" 2>/dev/null
	[ -s "$d/tsp.pid" ] && kill "$(cat "$d/tsp.pid")" 2>/dev/null
	kill $src 2>/dev/null
	sleep 2
	pkill -f "127\.0\.0\.1:$PORT/anon" 2>/dev/null
	kill $relay 2>/dev/null
	wait 2>/dev/null
	t_thin=$(awk -F'\t' '$2 == "thin_end" { print $1 }' "$d/marks.tsv" 2>/dev/null)
	[ -n "$t_thin" ] || t_thin=-
	if [ -s "$d/export.end" ] && awk -v e="$(cat "$d/export.end")" -v i="$t_int" 'BEGIN { exit !(e < i) }'; then
		t_end=$(cat "$d/export.end")
		why=$(reason "$d/export.log")
		[ -n "$why" ] || why="no error logged"
	fi
	printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$name" "$t_thin" "$t_end" "$why" >>"$OUT/trials.tsv"
	echo "trial $n $name: thin_end=$t_thin export_end=$t_end ${why:0:100}"
}

i=1
while [ $i -le "$TRIALS" ]; do
	for arm in $ARMS; do
		trial $i "$arm"
	done
	i=$((i + 1))
done
echo "done: $OUT/trials.tsv"

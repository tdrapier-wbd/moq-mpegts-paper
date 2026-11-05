#!/usr/bin/env bash
# T21's PCR accuracy over days (Evidence §5 row 10), criterion 1: the watch's own pipeline, binary
# and flags, graded on a local relay carrying the clip before the live run, in three arms: clean;
# through pcr-perturb.py moving every EVERY-th PCR by TICKS; and nulling every NULL_EVERY-th packet
# of one PID. pcrverify measures each PCR from the last one it reported, so a move is reported twice
# (+TICKS at the moved PCR, -TICKS at the next): `expected` is twice the moves, `other` counts
# failures of any other size. A nulled packet costs its PID one continuity count and moves no PCR:
# `cc` is TSDuck's `missing N packets` lines and `monitor_cc` the monitor's sum, each against `nulled`.
#
#   t21-pcr-controls.sh <bin-dir> <out-dir> [clip]
#
# Env: PORT (4443), RATE (12000000: the padded rate given to the export and the grader), SECS (100),
#      EVERY (250), TICKS (20), NULL_EVERY (100), ARMS (clean perturbed nulled).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
BIN=${1:?bin dir}
OUT=${2:?out dir}
CLIP=${3:-$HOME/clip120.ts}
PORT=${PORT:-4443}
RATE=${RATE:-12000000}
SECS=${SECS:-100}
EVERY=${EVERY:-250}
TICKS=${TICKS:-20}
NULL_EVERY=${NULL_EVERY:-100}
read -ra ARMS <<<"${ARMS:-clean perturbed nulled}"
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"
mkdir -p "$OUT"
for arm in "${ARMS[@]}"; do
	d=$OUT/$arm
	rm -rf "$d"
	mkdir -p "$d"
	"$BIN/moq-relay" "${RELAY_BIND[@]}" "127.0.0.1:$PORT" "${RELAY_TLS[@]}" 127.0.0.1 "${RELAY_AUTH[@]}" \
		"${RELAY_GSO[@]}" --log-level warn >"$d/relay.log" 2>&1 &
	relay=$!
	sleep 2
	tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>"$d/tsp.log" |
		"$BIN/moq" "${MOQ_DIAL[@]}" "https://127.0.0.1:$PORT/anon" --broadcast t21ctl import ts >"$d/pub.log" 2>&1 &
	sleep 2
	case $arm in
	clean) p= ;;
	perturbed) p="--every $EVERY --ticks $TICKS" ;;
	nulled) p="--null-every $NULL_EVERY" ;;
	esac
	PORT=$PORT SECS=$SECS GRADE_RATE=$RATE MONITOR=1 PERTURB=$p EXPORT_FLAGS="--delay 1s --mux-rate $RATE" \
		bash "$HERE/p0j-step-watch.sh" watch "$BIN" "$d" 1 127.0.0.1 t21ctl
	pkill -INT -f "[b]roadcast t21ctl import" 2>/dev/null
	kill "$relay" 2>/dev/null
	wait 2>/dev/null
	moved=0 nulled=0
	[ ! -f "$d/perturb.log" ] || moved=$(grep -c '^pcr=' "$d/perturb.log")
	[ ! -f "$d/perturb.log" ] || nulled=$(grep -c '^null ' "$d/perturb.log")
	fail=$(grep -c 'PCR jitter:' "$d/grade.log")
	other=$(grep 'PCR jitter:' "$d/grade.log" | grep -Evc "jitter: -?$TICKS =")
	mcc=$(grep -o ' cc=[0-9]*' "$d/monitor.log" | awk -F= '{s += $2} END {print s + 0}')
	echo "$arm: $(grep -o '[0-9,]* PCR OK.*' "$d/grade.log" | tail -n 1);" \
		"failures=$fail expected=$((2 * moved)) other=$other moved=$moved" \
		"cc=$(grep -Ec 'missing [0-9,]+ packets' "$d/grade.log") monitor_cc=$mcc nulled=$nulled"
done

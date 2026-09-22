#!/usr/bin/env bash
#
# T21 follow-up — per-process RSS for every role in the media-aware lane.
#
#   t21-role-memory.sh <label> [hours]
#
# The 24 h soak measured RSS with `pgrep -f` on a *signature*, which sums every process whose
# command line matches. The publisher's signature matches its wrapper shell as well as
# `moq import ts`, because the wrapper's argv contains the whole pipeline text. A shell does
# not grow, so the 24 h growth is not the wrapper's — but "not the wrapper's" is an argument,
# and a leak reported upstream needs a measurement. This samples each PID separately and
# labels it, so the growth is attributed to a binary rather than to a signature.
#
# It also re-reads the relay, whose 24 h growth fitted a logarithm (R2=0.989) far better than a
# line, because that reading is the one keeping the relay off the defect list and it deserves a
# second, independently sampled run.
#
# Same lane, same source mode and same groomer settings as the soak, so the two are comparable.
# Deliberately no impairment and no shaping: this is a resource measurement on a healthy lane.
set -uo pipefail

# Post-#3793 CLI flags (dual old/new binaries).
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:?label}
HOURS=${2:-4}
SAMPLE=${SAMPLE:-30}
RATE=${RATE:-11000000}
CUSHION_MS=${CUSHION_MS:-1000}
CAP_MS=${CAP_MS:-2500}
LATENCY_MAX=${LATENCY_MAX:-500ms}
PORT=${PORT:-4461}

MOQ=${MOQ:-$HOME/bin-merged/moq}
RELAY=${RELAY:-$HOME/bin-merged/moq-relay}
moq_cli_detect "$MOQ" "$RELAY"
PACER=${PACER:-$HOME/pacer-fixed/mpegts-pacer}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
CONTSRC=${CONTSRC:-$HOME/t21/ts-continuous-source.py}
DIR=${DIR:-$HOME/t21}
SOURCE_MODE=${SOURCE_MODE:-continuous}

SECS=${SECS:-$((HOURS * 3600))}
RUN=$DIR/$LABEL
mkdir -p "$RUN"
BCAST="t21.mem.$LABEL.hang"
CSV=$RUN/roles.csv
KIDS=()

case "$SOURCE_MODE" in
continuous) FEED="python3 $CONTSRC $CLIP | tsp -I file - -P regulate --pcr-synchronous -O file -" ;;
loop) FEED="tsp -I file $CLIP --infinite -P regulate --pcr-synchronous -O file -" ;;
*)
	echo "SOURCE_MODE must be continuous or loop" >&2
	exit 1
	;;
esac

CHECK=("$MOQ" "$RELAY" "$PACER" "$CLIP")
[ "$SOURCE_MODE" = continuous ] && CHECK+=("$CONTSRC")
for f in "${CHECK[@]}"; do
	[ -e "$f" ] || {
		echo "missing: $f" >&2
		exit 1
	}
done

RELAY_GREP="${RELAY_BIND[0]} 127.0.0.1:$PORT"
if pgrep -f "[m]oq-relay ${RELAY_BIND[0]} 127.0.0.1:$PORT" >/dev/null 2>&1 ||
	pgrep -f "[m]oq-relay.*127.0.0.1:$PORT" >/dev/null 2>&1; then
	echo "a relay is already bound to 127.0.0.1:$PORT — kill it before starting" >&2
	exit 1
fi

cleanup() {
	for p in ${KIDS+"${KIDS[@]}"}; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in ${KIDS+"${KIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
	pkill -9 -f "$BCAST" 2>/dev/null
	pkill -9 -f "[m]oq-relay ${RELAY_BIND[0]} 127.0.0.1:$PORT" 2>/dev/null
	pkill -9 -f "[m]oq-relay.*127.0.0.1:$PORT" 2>/dev/null
	true
}
trap cleanup EXIT

"$RELAY" "${RELAY_BIND[@]}" "127.0.0.1:$PORT" "${RELAY_TLS[@]}" localhost "${RELAY_AUTH[@]}" \
	"${RELAY_GSO[@]}" "$RELAY_CC_FLAG" "${MOQ_CC:-delay}" \
	>"$RUN/relay.log" 2>&1 &
RELAY_PID=$!
KIDS+=("$RELAY_PID")
sleep 2

# Started with `exec` at the end of each stage so the PID recorded is the binary's own and not
# a shell that will hand off to it. No respawn wrapper here, deliberately: a restart would
# reset the very series being measured, and a role that dies is the result.
bash -c "$FEED" 2>"$RUN/src.log" |
	"$MOQ" "${MOQ_DIAL[@]}" "https://127.0.0.1:$PORT/anon" \
		--broadcast "$BCAST" import ts >"$RUN/import.log" 2>&1 &
PUB_PID=$!
KIDS+=("$PUB_PID")
sleep 5

"$MOQ" "${MOQ_DIAL[@]}" "https://127.0.0.1:$PORT/anon" \
	--broadcast "$BCAST" export ts "${MOQ_LAT[@]}" "$LATENCY_MAX" 2>"$RUN/export.log" |
	"$PACER" - "$RATE" --latency-ms "$CUSHION_MS" --max-latency-ms "$CAP_MS" \
		--stall-ms 1000 --on-stall mute --stats-interval-ms $((SAMPLE * 1000)) 2>"$RUN/pacer.log" |
	tsp -I file - -P continuity -P count --total --interval 1000000 -O drop \
		>"$RUN/grade.log" 2>&1 &
SUB_PID=$!
KIDS+=("$SUB_PID")
sleep 5

# Resolve each role to a single PID by matching the binary AND its distinguishing argument,
# then never re-resolve: a PID that vanishes is recorded as gone rather than silently replaced
# by whatever else now matches the pattern.
pid_of() { pgrep -f "$1" 2>/dev/null | head -1; }
RELAY_P=$(pid_of "[m]oq-relay .*127.0.0.1:$PORT")
IMPORT_P=$(pid_of "[m]oq .*$BCAST import")
EXPORT_P=$(pid_of "[m]oq .*$BCAST export")
PACER_P=$(pid_of "[m]pegts-pacer - $RATE")
PY_P=$(pid_of "[p]ython3 .*ts-continuous-source")
TSP_P=$(pid_of "[t]sp -I file")
[ "$SOURCE_MODE" = loop ] && PY_P=${PY_P:-0}

{
	echo "label=$LABEL hours=$HOURS sample=${SAMPLE}s rate=$RATE port=$PORT source_mode=$SOURCE_MODE"
	echo "moq=$($MOQ --version 2>&1 | head -1) relay=$($RELAY --version 2>&1 | head -1)"
	echo "pacer=$($PACER --version 2>&1 | head -1)"
	echo "clip=$CLIP md5=$(md5sum "$CLIP" | cut -d' ' -f1)"
	echo "pids: relay=$RELAY_P import=$IMPORT_P export=$EXPORT_P pacer=$PACER_P python=$PY_P tsp=$TSP_P"
	echo "started=$(date -Is)"
} >"$RUN/meta.txt"
cat "$RUN/meta.txt"

REQUIRED=(RELAY_P IMPORT_P EXPORT_P PACER_P TSP_P)
[ "$SOURCE_MODE" = continuous ] && REQUIRED+=(PY_P)
for v in "${REQUIRED[@]}"; do
	[ -n "${!v}" ] && [ "${!v}" != 0 ] || {
		echo "could not resolve $v — see $RUN/*.log" >&2
		exit 1
	}
done

echo "epoch,elapsed_s,relay_rss,relay_thr,import_rss,import_thr,export_rss,export_thr,pacer_rss,pacer_thr,python_rss,tsp_rss,alive,pkts,cc" >"$CSV"

rss() { awk '/^VmRSS/{print $2; found=1} END{if(!found) print 0}' "/proc/$1/status" 2>/dev/null || echo 0; }
thr() { awk '/^Threads/{print $2; found=1} END{if(!found) print 0}' "/proc/$1/status" 2>/dev/null || echo 0; }

START=$(date +%s)
while :; do
	NOW=$(date +%s)
	EL=$((NOW - START))
	[ "$EL" -ge "$SECS" ] && break
	ALIVE=0
	for p in "$RELAY_P" "$IMPORT_P" "$EXPORT_P" "$PACER_P" "$TSP_P"; do
		kill -0 "$p" 2>/dev/null && ALIVE=$((ALIVE + 1))
	done
	[ "$PY_P" != 0 ] && kill -0 "$PY_P" 2>/dev/null && ALIVE=$((ALIVE + 1))
	PKTS=$(grep -oE 'total: [0-9,]+ packets' "$RUN/grade.log" 2>/dev/null | tail -1 |
		grep -oE '[0-9,]+' | tr -d ,)
	CCE=$(grep -cE 'missing .* packets|discontinuity' "$RUN/grade.log" 2>/dev/null || true)
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$NOW" "$EL" \
		"$(rss "$RELAY_P")" "$(thr "$RELAY_P")" \
		"$(rss "$IMPORT_P")" "$(thr "$IMPORT_P")" \
		"$(rss "$EXPORT_P")" "$(thr "$EXPORT_P")" \
		"$(rss "$PACER_P")" "$(thr "$PACER_P")" \
		"$([ "$PY_P" != 0 ] && rss "$PY_P" || echo 0)" "$(rss "$TSP_P")" \
		"$ALIVE" "${PKTS:-0}" "${CCE:-0}" >>"$CSV"
	sleep "$SAMPLE"
done

echo "finished=$(date -Is) elapsed_s=$EL" >>"$RUN/meta.txt"

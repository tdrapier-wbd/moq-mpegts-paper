#!/usr/bin/env bash
# T83 Part B's cells in one pass: the controls, then every cell at each SRT latency, each graded as it
# ends into summary.csv, one row per graded event: t56-grade.py on the recording (sub1), detection
# from the fault to the switch's decision in events.txt, t83-leg-lag.py on the legs as the switch
# reads them, and t83-tables.py across the run's cuts (the full diff stays in the run's tables.json).
#
#   sudo BIN=<moq dir> PACER=<mpegts-pacer> SRC=<ts> t83b-batch.sh <label>
#
# Env: LATS (SRT latencies, ms: "1000"), CELLS ("none outage-a outage-b kill-a kill-b cut"), REPS (3),
#      CONTROLS (1: first T80's lookback kill cell on T58's rig, and the commanded cut on two
#      media-aware legs, REPS each), LEGB and SRT_INIT (t83-mixed-switch.sh's), OUT
#      (/home/ubuntu/t83b) holds one directory per run and the summary.
set -uo pipefail

LABEL=${1:?label}
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=${BIN:?set BIN}
PACER=${PACER:?set PACER}
SRC=${SRC:?set SRC}
LATS=${LATS:-1000}
CELLS=${CELLS:-"none outage-a outage-b kill-a kill-b cut"}
REPS=${REPS:-3}
CONTROLS=${CONTROLS:-1}
LEGB=${LEGB:-moq}
SRT_INIT=${SRT_INIT:-}
OUT=${OUT:-/home/ubuntu/t83b}
U=${SUDO_USER:-ubuntu}
SUM=$OUT/$LABEL.summary.csv
[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo)" >&2
	exit 1
}
mkdir -p "$OUT/$LABEL"
chown "$U": "$OUT" "$OUT/$LABEL"
[ -s "$SUM" ] || echo "run,rig,lega,srt_ms,cell,serve,rep,event,t,detect_s,stall_s,hole_s,hole_before_s,outage_s,lost_s,latency_step_s,audio_gap_s,bad_pictures,restarts,void,lag_med_ms,lag_p5_ms,lag_p95_ms,cuts,table_changes,scte35_lost,scte35_lost_near,scte35_missed" >"$SUM"

grade() { # $1 run dir, $2 run name, $3 rig, $4 lega, $5 srt_ms, $6 cell, $7 serve, $8 rep
	local d=$1
	chown -R "$U": "$d"
	timeout 600 python3 "$H/t56-grade.py" "$d" --ref "$SRC" --caps sub1 --arrive >"$d/grade.txt" 2>&1
	if [ -e "$d/la.idx" ] && [ -e "$d/lb.idx" ]; then
		timeout 300 python3 "$H/t83-leg-lag.py" "$d/la" "$d/lb" --json >"$d/lag.json" 2>"$d/lag.err"
	fi
	if [ -e "$d/sw.idx" ]; then
		timeout 300 python3 "$H/t83-tables.py" "$d/sw" --source "$d/live1" --vswitch-log "$d/vswitch.log" \
			--json >"$d/tables.json" 2>"$d/tables.err"
	fi
	python3 - "$@" >>"$SUM" <<'PY'
import json, sys
d, run, rig, lega, srt, cell, serve, rep = sys.argv[1:]
def load(name):
    try:
        return json.load(open(f"{d}/{name}"))
    except (OSError, ValueError):
        return {}
g, lag, tb = load("grade.json"), load("lag.json"), load("tables.json")
ev = [(r.split()[0], float(r.split()[1])) for r in open(f"{d}/events.txt") if r.strip()]
t0 = ev[0][1]
def f(x):
    return "" if x is None else str(x)
cuts = tb.get("cuts", [])
common = [f(lag.get("median_ms")), f(lag.get("p5_ms")), f(lag.get("p95_ms")), str(len(cuts)),
          str(sum(len(c["changes"]) for c in cuts)) if tb else "",
          f(tb.get("scte35", {}).get("lost")), str(sum(c["scte35_lost_near"] for c in cuts)) if tb else "",
          str(sum(1 for c in cuts for p in c["scte35_gaps"].values() if p["missed"])) if tb else ""]
rows = [r for r in g.get("rows", []) if r.get("export") == "sub1"] or [{"event": "-"}]
for r in rows:
    det = None
    if r.get("event", "")[:4] in ("kill", "outa"):
        te = t0 + r["t"]
        sw = [t for n, t in ev if n.startswith("switch") and t >= te - 0.1]
        det = round(min(sw) - te, 2) if sw else None
    print(",".join([run, rig, lega, srt, cell, serve, rep, r.get("event", "-"), f(r.get("t")), f(det),
                    f(r.get("stall_s")), f(r.get("hole_s")), f(r.get("hole_before_s")), f(r.get("outage_s")),
                    f(r.get("lost_s")), f(r.get("latency_step_s")), f(r.get("audio_gap_s")),
                    f(r.get("bad_pictures")), str(len(g.get("restarts", []))),
                    "|".join(g.get("void", [])).replace(",", ";")] + common))
PY
	tail -n +2 "$SUM" | grep "^$2," | tail -3
}

mixed() { # $1 run name, $2 lega, $3 srt_ms, $4 cell (none | outage-a ... | cut), $5 rep
	local c=${4%-*} s=a
	case $4 in *-b) s=b ;; esac
	CELL=$c SERVE=$s LEGA=$2 LEGB=$LEGB SRT_LAT=$3 SRT_INIT=$SRT_INIT BIN=$BIN PACER=$PACER SRC=$SRC OUT=$OUT/$LABEL \
		bash "$H/t83-mixed-switch.sh" "$1" >"$OUT/$LABEL.$1.log" 2>&1
	grade "$OUT/$LABEL/$1" "$1" "t83$([ "$LEGB" = seg ] && echo -seg)" "$2" "$3" "$c" "$s" "$5"
}

echo "=== $(date -u) t83b-batch $LABEL: LATS=$LATS CELLS=$CELLS REPS=$REPS ==="
if [ "$CONTROLS" = 1 ]; then
	for rep in $(seq 1 "$REPS"); do
		n="t80-kill-$rep"
		SWITCHER=vswitch LOOKBACK=2000 SILENCE=202 CELL=kill MODE=nonrevertive BIN=$BIN SRC=$SRC OUT=$OUT/$LABEL \
			bash "$H/t58-receiver-select.sh" "$n" >"$OUT/$LABEL.$n.log" 2>&1
		grade "$OUT/$LABEL/$n" "$n" t58 moq - kill a "$rep"
		mixed "moq-cut-$rep" moq - cut "$rep"
	done
fi
for lat in $LATS; do
	for cell in $CELLS; do
		for rep in $(seq 1 "$REPS"); do
			mixed "s$lat-$cell-$rep" srt "$lat" "$cell" "$rep"
		done
	done
done
chown -R "$U": "$OUT"
echo "=== $(date -u) t83b-batch $LABEL done: $SUM ==="

#!/usr/bin/env bash
# T40 — drive the #3533 content-join stall through the SRT contribution chain.
#
# #3533's published reproducer is a local pipe: generator | tsp | moq import. That proves the
# defect but it does not prove the deployed path is exposed to it, because the deployed path is
# two stages joined by a loopback multicast group (INSTRUCTIONS §7, srt-ingest ->
# moq-live-publisher) and every stage between the encoder and the importer is a place the
# trigger could in principle be absorbed. This rig reproduces that chain shape exactly, on its
# own ports and its own broadcast, so the standing services are never touched.
#
# It is also the acceptance test for the eventual fix: when a build claims to close #3533, run
# this against it and the emitted rate must hold across every join.
#
#   t40-continuous-join-srt.sh <label> <moq-binary> <relay-url> <clip.ts> [seconds] [passes]
#
# env: SRT_PORT (9101), MCAST (239.255.0.9:5009), OUTDIR (~/t40), SAMPLE (5)
#
# The oracle is the subscriber's own emitted-byte counter (/proc/<pid>/io wchar), which is what
# #3533 reports, so a result here is directly comparable with the issue's table.
set -uo pipefail

LABEL="${1:?label}"
MOQ="${2:?path to moq}"
RELAY="${3:?relay url}"
CLIP="${4:?source clip}"
SECS="${5:-150}"
PASSES="${6:-40}"

SRT_PORT="${SRT_PORT:-9101}"
MCAST="${MCAST:-239.255.0.9:5009}"
OUTDIR="${OUTDIR:-$HOME/t40}"
SAMPLE="${SAMPLE:-5}"

RUN="$OUTDIR/$LABEL"
BCAST="t40.${LABEL}.hang"
GEN="$HOME/ts-continuous-source.py"

mkdir -p "$RUN"
[ -x "$MOQ" ] || {
	echo "no moq at $MOQ" >&2
	exit 2
}
[ -f "$CLIP" ] || {
	echo "no clip at $CLIP" >&2
	exit 2
}
[ -f "$GEN" ] || {
	echo "no generator at $GEN" >&2
	exit 2
}

echo "== t40/$LABEL ==" | tee "$RUN/meta.txt"
{
	echo "moq:      $("$MOQ" --version 2>&1 | head -1)"
	echo "binary:   $MOQ"
	echo "relay:    $RELAY"
	echo "clip:     $CLIP ($(stat -c%s "$CLIP" 2>/dev/null) bytes)"
	echo "broadcast:$BCAST  srt:$SRT_PORT  mcast:$MCAST"
	echo "window:   ${SECS}s  sample:${SAMPLE}s  passes:$PASSES"
	echo "host:     $(hostname)  $(nproc) vCPU"
	echo "started:  $(date -Is)"
} | tee -a "$RUN/meta.txt"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
}
trap cleanup EXIT

# --- stage 1: SRT listener -> loopback multicast (the srt-ingest shape) -------------------
tsp -I srt --listener "0.0.0.0:$SRT_PORT" --multiple --transtype live \
	--rcv-latency 2000 --udp-rcvbuf 16777216 \
	-O ip "$MCAST" --local-address 127.0.0.1 >"$RUN/stage1.log" 2>&1 &
PIDS+=($!)
sleep 2

# --- stage 2: multicast -> moq import (the moq-live-publisher shape) ----------------------
setsid bash -c "tsp -I ip $MCAST --local-address 127.0.0.1 -O file - \
	| '$MOQ' --client-tls-disable-verify --client-connect '$RELAY' \
	  --broadcast '$BCAST' import ts" >"$RUN/stage2.log" 2>&1 &
PIDS+=($!)
sleep 2

# --- the source: a continuous timeline whose content restarts -----------------------------
setsid bash -c "python3 '$GEN' '$CLIP' --passes $PASSES \
	| tsp -I file - -P regulate --pcr-synchronous --wait-min 5 \
	  -O srt --caller 127.0.0.1:$SRT_PORT --transtype live" >"$RUN/source.log" 2>&1 &
PIDS+=($!)
sleep 6

# --- the subscriber under test ------------------------------------------------------------
"$MOQ" --client-tls-disable-verify --client-connect "$RELAY" \
	--broadcast "$BCAST" export ts --latency-max 3s >/dev/null 2>"$RUN/export.log" &
SUB=$!
PIDS+=("$SUB")
sleep 3
if ! kill -0 "$SUB" 2>/dev/null; then
	echo "FAIL: subscriber exited immediately; see $RUN/export.log" | tee -a "$RUN/meta.txt"
	tail -5 "$RUN/export.log" | tee -a "$RUN/meta.txt"
	exit 3
fi

# --- oracle: emitted bytes per sample, exactly what #3533 reports --------------------------
echo "t_s,wchar,delta_bytes,mbps" >"$RUN/rate.csv"
PREV=0
T=0
while [ "$T" -lt "$SECS" ]; do
	sleep "$SAMPLE"
	T=$((T + SAMPLE))
	kill -0 "$SUB" 2>/dev/null || {
		echo "subscriber exited at t=${T}s" | tee -a "$RUN/meta.txt"
		break
	}
	W=$(awk '/^wchar:/{print $2}' "/proc/$SUB/io" 2>/dev/null)
	[ -n "${W:-}" ] || break
	D=$((W - PREV))
	PREV=$W
	# skip the first sample: it includes process start-up
	[ "$T" -gt "$SAMPLE" ] && printf "%d,%d,%d,%.2f\n" "$T" "$W" "$D" \
		"$(awk -v d="$D" -v s="$SAMPLE" 'BEGIN{printf "%.4f", d*8/s/1000000}')" >>"$RUN/rate.csv"
done

# --- grade ---------------------------------------------------------------------------------
python3 - "$RUN" <<'PY' | tee -a "$RUN/meta.txt"
import csv, sys, statistics as st
run = sys.argv[1]
rows = list(csv.DictReader(open(f"{run}/rate.csv")))
r = [(int(x["t_s"]), float(x["mbps"])) for x in rows if x["mbps"]]
if len(r) < 4:
    print("INCONCLUSIVE: too few samples"); sys.exit(0)
mb = [v for _, v in r]
peak = max(mb)
# the join is wherever the rate first falls below a third of the established peak
early = [v for t, v in r if t <= 20] or mb[:2]
base = st.median(early)
tail = [v for t, v in r if t >= r[len(r)//2][0]]
print(f"\nsamples={len(r)}  baseline(<=20s)={base:.2f} Mb/s  peak={peak:.2f}  "
      f"tail_median={st.median(tail):.2f}  tail_max={max(tail):.2f}  tail_min={min(tail):.2f}")
collapsed = [t for t, v in r if v < base * 0.33]
if collapsed and max(tail) < base * 0.33:
    print(f"RESULT: STALLED — first collapse at t={collapsed[0]}s, and the maximum sample "
          f"thereafter is {max(tail):.2f} Mb/s against a {base:.2f} Mb/s baseline. "
          f"Permanent, not slow recovery.")
elif collapsed:
    print(f"RESULT: DIPPED BUT RECOVERED — collapse at t={collapsed[0]}s, tail max "
          f"{max(tail):.2f} Mb/s. Not the #3533 signature.")
else:
    print(f"RESULT: HEALTHY — no sample below {base*0.33:.2f} Mb/s across {len(r)} samples.")
PY

echo "finished: $(date -Is)" | tee -a "$RUN/meta.txt"

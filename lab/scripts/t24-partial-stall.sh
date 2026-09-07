#!/usr/bin/env bash
#
# T24 — a partial media-plane stall through the media-aware lane.
#
#   t24-partial-stall.sh <arm>            arm = control | video | audio | es
#   ARMS="control video audio es" t24-partial-stall.sh all
#
# [T22](../test-22-silent-media-plane-failure.md) froze whole processes and concluded that PCR
# progression is the detector to build on. Its limits section records what it did not test: an
# encoder that half-works. Because PCR rides on the video PID in this clip — as in most — a dead
# video encoder behind a live mux emits healthy PCR over no pictures, and PCR progression reads
# green through the whole outage. `ts-partial-stall.py` builds that stimulus, and it is graded
# before use: in `video` mode it carries the same 24,574 PCRs, the same 24.951 ms worst interval
# and the same zero continuity errors as the control, with a 60.02 s hole in the video.
#
# Two questions, and the second is the one that could change the architecture rather than the
# monitoring advice:
#
#   1. Is the failure observable anywhere in the delivered stream?
#   2. Does the lane *contain* it or *amplify* it? A mux that waits for a track that will never
#      arrive would turn one dead elementary stream into a dead service, which would be far
#      worse than not detecting it.
#
# The output is captured and graded offline by `t24-grade.py`, per elementary stream and in
# media time. Live observation was the right instrument for T22, which was timing a detector;
# here the question is what the delivered stream contains, and a capture answers it exactly.
set -uo pipefail

ARM=${1:?arm: control|video|audio|es|all}

SECS=${SECS:-150}
AT=${AT:-30}
DUR=${DUR:-60}
RATE=${RATE:-11000000}
CUSHION_MS=${CUSHION_MS:-1000}
CAP_MS=${CAP_MS:-2500}
STALL_MS=${STALL_MS:-1000}
ON_STALL=${ON_STALL:-mute}
LATENCY_MAX=${LATENCY_MAX:-500ms}
PORT=${PORT:-4471}

MOQ=${MOQ:-$HOME/bin-merged/moq}
RELAY=${RELAY:-$HOME/bin-merged/moq-relay}
PACER=${PACER:-$HOME/pacer-fixed/mpegts-pacer}
CLIP=${CLIP:-$HOME/t24/clip180.ts}
STALLSRC=${STALLSRC:-$HOME/t24/ts-partial-stall.py}
DIR=${DIR:-$HOME/t24}

run_arm() {
	local arm=$1
	local run=$DIR/$arm
	local bcast="t24.$arm"
	local kids=()
	rm -rf "$run"
	mkdir -p "$run"

	pkill -9 -f "[m]oq-relay --server-bind 127.0.0.1:$PORT" 2>/dev/null
	sleep 1

	"$RELAY" --server-bind "127.0.0.1:$PORT" --tls-generate localhost --auth-public "" \
		>"$run/relay.log" 2>&1 &
	kids+=("$!")
	sleep 2

	# The stimulus is generated into the pipe rather than onto disk: it is deterministic from
	# the clip and the window, and four 200 MB copies of it would buy nothing.
	python3 "$STALLSRC" --mode "$arm" --at "$AT" --for "$DUR" "$CLIP" 2>"$run/stim.log" |
		tsp -I file - -P regulate --pcr-synchronous -O file - 2>"$run/tsp.log" |
		"$MOQ" --client-tls-disable-verify --client-connect "https://127.0.0.1:$PORT/anon" \
			--broadcast "$bcast" import ts >"$run/import.log" 2>&1 &
	kids+=("$!")
	sleep 4

	"$MOQ" --client-tls-disable-verify --client-connect "https://127.0.0.1:$PORT/anon" \
		--broadcast "$bcast" export ts --latency-max "$LATENCY_MAX" 2>"$run/export.log" |
		"$PACER" - "$RATE" --latency-ms "$CUSHION_MS" --max-latency-ms "$CAP_MS" \
			--stall-ms "$STALL_MS" --on-stall "$ON_STALL" --stats-interval-ms 1000 \
			2>"$run/pacer.log" |
		timeout "$SECS" dd of="$run/out.ts" bs=188 status=none 2>"$run/dd.log" &
	kids+=("$!")

	{
		echo "arm=$arm secs=$SECS window=${AT}s..$((AT + DUR))s rate=$RATE"
		echo "cushion=${CUSHION_MS}ms cap=${CAP_MS}ms stall=${STALL_MS}ms on-stall=$ON_STALL"
		echo "latency_max=$LATENCY_MAX broadcast=$bcast port=$PORT"
		echo "moq=$($MOQ --version 2>&1 | head -1) relay=$($RELAY --version 2>&1 | head -1)"
		echo "pacer=$($PACER --version 2>&1 | head -1)"
		echo "clip=$CLIP md5=$(md5sum "$CLIP" | cut -d' ' -f1)"
		echo "started=$(date -Is)"
	} >"$run/meta.txt"

	echo "[$arm] running ${SECS}s..."
	sleep $((SECS + 6))

	for p in "${kids[@]}"; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in "${kids[@]}"; do kill -9 "$p" 2>/dev/null; done
	pkill -9 -f "$bcast" 2>/dev/null
	pkill -9 -f "[m]oq-relay --server-bind 127.0.0.1:$PORT" 2>/dev/null
	sleep 1

	echo "finished=$(date -Is)" >>"$run/meta.txt"

	# The groomer's own counters are a candidate detector in their own right, so its last
	# sample and its summary are kept next to the capture rather than being read from the log
	# by hand later.
	grep -E "^mpegts-pacer: (sample|done|arrival)" "$run/pacer.log" | tail -3 \
		>"$run/pacer-final.txt" 2>/dev/null

	# Session-state detector, filtered the same way T22 filtered it: the connect lines every
	# run opens with are benign, and a detector credited with those would be credited with
	# noticing the failure before it happened.
	{
		echo "--- import ---"
		grep -viE "connecting|connected|subscribe started|announce|^$" "$run/import.log" | head -20
		echo "--- relay ---"
		grep -viE "connecting|connected|listening|accepted|session|^$" "$run/relay.log" | head -20
		echo "--- export ---"
		grep -viE "connecting|connected|subscribe started|announce|^$" "$run/export.log" | head -20
	} >"$run/session.txt" 2>/dev/null

	local n
	n=$(stat -c%s "$run/out.ts" 2>/dev/null || echo 0)
	echo "[$arm] captured $((n / 188)) packets ($((n / 1048576)) MB)"
}

if [ "$ARM" = all ]; then
	for a in ${ARMS:-control video audio es}; do run_arm "$a"; done
else
	run_arm "$ARM"
fi

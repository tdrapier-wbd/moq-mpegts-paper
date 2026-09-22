#!/usr/bin/env bash
# T13 arm — does `moq export ts` hand a groomer a constant-rate stream now?
#
# T13's census of the MoQ lane opens with three things the exporter did not do: it carried no
# stuffing, declared no mux rate, and delivered in object bursts, so a groomer had to put all
# three back. Upstream #3831 (`feat(moq-mux): record the TS mux rate and pad export to it`)
# addresses the first two: import measures the whole-multiplex rate off the PCR PID and records
# it in the catalog as `mpegts.muxRate`, and export settles a packet balance each PCR slot and
# emits null packets to make up the difference.
#
# This grades that claim in the file domain and states what it does not touch. Four arms, three
# of them on one build so the feature is isolated from everything else that moved:
#
#   cbr       a CBR source with its stuffing intact -> import should record the rate, export
#             should pad back to it. The arm the feature is for.
#   stripped  the same clip with PID 0x1FFF filtered out, so the source is no longer paced to a
#             constant rate. Import should record nothing and export should behave as before —
#             the negative control that separates "the feature fired" from "the build changed".
#   override  the stripped source with `--mux-rate` given explicitly, which is the path for a
#             broadcast whose catalog carries no rate.
#   old       the CBR source through a pre-#3831 build, for the before/after. Read it with the
#             backend caveat below rather than as a clean A/B.
#
# Backend. #3811 deleted the quinn backend, so OLD (quinn) and NEW (noq) differ in QUIC stack as
# well as in this feature. Everything here is loopback with no loss and every figure is taken
# from the captured bytes rather than from delivery, so the stack is not expected to reach the
# census — but the `old` arm crosses it and the three same-build arms are the evidence.
#
# Domain. This is a FILE-domain census: what the bytes say. Null padding changes the composition
# of the stream, not the instants at which it is written, so nothing here speaks to T13's
# criterion 4 on the wire. `t13-cadence.sh` is the rig for that and is deliberately not folded in.
#
#   t13-export-muxrate.sh <label> [seconds]
#
# Env: NEW, OLD (binary dirs), CLIP, PORT, PACKETS, OUT.
set -uo pipefail

# Post-#3793 CLI flags, detected per binary rather than assumed.
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:?label}
SECS=${2:-90}

NEW=${NEW:?set NEW to the post-#3831 binary dir}
OLD=${OLD:-}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
PORT=${PORT:-4460}
# 300,000 packets is the slice T13's file-domain census uses; keeping it makes the two
# comparable without rescaling the stuffing percentages.
PACKETS=${PACKETS:-300000}
OUT=${OUT:-$HOME/t13-muxrate}/$LABEL
# The clip's own declared rate, used for the `override` arm and as the yardstick everywhere else.
NOMINAL=${NOMINAL:-9945951}

rm -rf "$OUT"
mkdir -p "$OUT"
PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
	pkill -f "[m]oq-relay .*127.0.0.1:$PORT" 2>/dev/null || true
	pkill -f "[m]oq .*t13mr-" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== $(date -u) t13-export-muxrate $LABEL ==="
"$NEW/moq" --version
[ -n "$OLD" ] && "$OLD/moq" --version

# One relay for every arm, including `old`: the arms differ in the *client* build, so holding the
# relay fixed is what makes the before/after a comparison rather than two separate rigs.
#
# The grant comes from `RELAY_AUTH`, never a literal: `--auth-public` inverted at the CLI migration
# and the wrong value fails *silently* here — the publisher announces, the subscriber attaches, and
# nothing is ever delivered, with no error on any of the three and a zero-byte capture that grades
# as a broken feature. A literal also voids any arm whose binary sits on the other side of the
# migration, which is exactly what a pre-#3831 control is.
moq_cli_detect "$NEW/moq" "$NEW/moq-relay"
moq_relay_public "127.0.0.1:$PORT" localhost
"$NEW/moq-relay" "${RELAY_ARGV[@]}" >"$OUT/relay.log" 2>&1 &
PIDS+=($!)
sleep 2

# $1 arm, $2 moq binary dir, $3 feed (a shell pipeline writing TS to stdout), rest: export args
run_arm() {
	local arm=$1 bin=$2 feed=$3
	shift 3
	local bcast="t13mr-$arm.hang"
	local d="$OUT/$arm"
	mkdir -p "$d"

	# Both builds under test are post-#3793, so both take the `--connect`/`--max-age` names;
	# detect anyway rather than assume, since the `old` slot is meant to hold a bisect build.
	moq_cli_detect "$bin/moq" ""

	echo "--- arm $arm ($bin) ---"
	# Subscriber first: reservation gating publishes the catalog once tracks resolve, so a
	# subscriber that attaches afterwards can miss it and sit idle forever.
	setsid bash -c "RUST_LOG=moq_mux=debug,info '$bin/moq' \
		${MOQ_DIAL[*]} 'https://127.0.0.1:$PORT/anon' --quic-gso=false \
		--broadcast '$bcast' export ts ${MOQ_LAT[*]} 3s $* \
		> '$d/out.ts'" 2>"$d/export.log" &
	PIDS+=($!)
	sleep 2

	# Publisher. `regulate --pcr-synchronous` releases the file at its own PCR rate, so import
	# sees the source's real pacing rather than disk speed — which is what the rate measurement
	# on the PCR PID depends on.
	setsid bash -c "$feed | RUST_LOG=moq_mux=debug,info '$bin/moq' \
		${MOQ_DIAL[*]} 'https://127.0.0.1:$PORT/anon' --quic-gso=false \
		--broadcast '$bcast' import ts" >"$d/import.log" 2>&1 &
	PIDS+=($!)

	# #3831 publishes the rate only once it is stable across a window of PCR intervals (four
	# half-second samples), and the exporter picks it up at the next catalog. The capture has to
	# outlast that or it grades the unpadded prefix.
	sleep "$SECS"
	pkill -f "[m]oq .*$bcast" 2>/dev/null || true
	sleep 2

	# An empty capture is the failure this rig is most likely to produce and least likely to
	# notice — see the `--auth-public` note above — so report the size every time.
	echo "  captured: $(wc -c <"$d/out.ts") bytes"
	grep -ioE "mux.?rate[^,}]*" "$d/import.log" "$d/export.log" 2>/dev/null | sort -u | head -5 >"$d/muxrate.grep" || true
}

FEED_CBR="tsp --realtime -I file $CLIP -P regulate --pcr-synchronous --wait-min 5 -O file -"
# `filter --negate --pid 0x1FFF` drops the stuffing, which is what makes the source VBR: the
# media is unchanged but it is no longer paced to a constant rate.
FEED_VBR="tsp --realtime -I file $CLIP -P filter --negate --pid 0x1FFF -P regulate --pcr-synchronous --wait-min 5 -O file -"

run_arm cbr "$NEW" "$FEED_CBR"
run_arm stripped "$NEW" "$FEED_VBR"
run_arm override "$NEW" "$FEED_VBR" --mux-rate "$NOMINAL"
[ -n "$OLD" ] && run_arm old "$OLD" "$FEED_CBR"

echo
echo "=== census ==="
for d in "$OUT"/*/; do
	arm=$(basename "$d")
	[ -s "$d/out.ts" ] || {
		echo "$arm: no output"
		continue
	}
	# Slice to a fixed packet count so stuffing percentages compare across arms.
	head -c $((PACKETS * 188)) "$d/out.ts" >"$d/slice.ts"
	tsp -I file "$d/slice.ts" -P analyze -O drop >"$d/analyze.txt" 2>&1 || true
	tsp -I file "$d/slice.ts" -P pcrverify --absolute --jitter-max 13 -O drop >"$d/pcrverify.txt" 2>&1 || true
	tsp -I file "$d/slice.ts" -P continuity -O drop >"$d/continuity.txt" 2>&1 || true
	python3 "$HOME/t19-pcr-positions.py" "$d/slice.ts" "$NOMINAL" >"$d/pcrpos.txt" 2>&1 || true
	python3 "$HOME/ts-pcr-timing.py" "$d/slice.ts" >"$d/pcrtiming.txt" 2>&1 || true
	echo "--- $arm ---"
	grep -E "Stuffing|Estimated based on PCR|TS packets: " "$d/analyze.txt" | head -4
	grep -iE "back-to-back|PCR packets:" "$d/pcrpos.txt" | head -2
done

echo "=== $(date -u) done: $OUT ==="

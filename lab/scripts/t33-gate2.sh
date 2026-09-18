#!/usr/bin/env bash
# T33 — Gate 2, end to end, as ONE command.
#
# Why this exists. `t33-acceptance.sh` fixes the measurement set, the run order and the pass
# table, and its docstring says so — but it is not the entry point it reads like. It assumes a
# relay is already listening, that its fingerprint is at `/tmp/t33/fp.txt`, and that three
# fixtures already exist under `/tmp/t33/fixtures/`. None of those are created by anything in
# this repository: they were built by hand during the September rehearsal and lived in a `/tmp`
# that no longer exists. Re-running the rehearsal therefore aborted on its own precondition
# check, which is the second time T33's preparation has found an untested precondition and
# exactly what it is for.
#
# On hardware day the window is short, attended and expensive, and "stand the relay up first,
# and by the way build three fixtures" is not something to rediscover with an analyser on the
# bench. So everything the harness assumes is built here, deterministically, from a clip.
#
#   t33-gate2.sh <out-dir> [subject-seconds] [soak-seconds]
#
# env: MOQ, RELAY (moq-relay), PACER, CLIP, PORT (9543)
#
# It refuses to print a Gate 2 verdict — that needs the analyser and the IRDs. What it
# produces is the evidence that the rig is sound and the run is one command.
set -u

OUT="${1:?out dir}"
SUBJ_S="${2:-60}"
SOAK_S="${3:-300}"

W=/tmp/t33
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOQ="${MOQ:?set MOQ}"
RELAY="${RELAY:?set RELAY (moq-relay)}"
PACER="${PACER:?set PACER}"
CLIP="${CLIP:?set CLIP}"
PORT="${PORT:-9543}"

mkdir -p "$OUT" "$W/fixtures" "$W/out"
LOG="$OUT/gate2.log"
: >"$LOG"
say() { echo "$*" | tee -a "$LOG"; }

say "=== T33 Gate 2, one command — $(date -Is) ==="
say "moq:    $("$MOQ" --version 2>&1 | head -1)"
say "relay:  $("$RELAY" --version 2>&1 | head -1)"
say "clip:   $CLIP"

RELAY_PID=""
cleanup() {
	[ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null
	sleep 1
	[ -n "$RELAY_PID" ] && kill -9 "$RELAY_PID" 2>/dev/null
	return 0
}
trap cleanup EXIT

die() {
	say "ABORTED: $*"
	exit 2
}

# ---------------------------------------------------------------------------
# Step A -- fixtures. Built from the clip, so a fresh host needs nothing carried in.
# ---------------------------------------------------------------------------
say "--- fixtures ---"

# svc-normal: a conformant DVB-wrapped fixture; the clean half of the grader self-test.
if [ ! -f "$W/fixtures/svc-normal.ts" ]; then
	python3 "$REPO/scripts/t33-service-fixture.py" normal --seconds 20 \
		-o "$W/fixtures/svc-normal.ts" >>"$LOG" 2>&1 ||
		die "could not build svc-normal.ts"
fi
say "  svc-normal.ts      $(stat -c%s "$W/fixtures/svc-normal.ts") bytes"

# BROKEN-excised: the same stream with a run of packets cut out, so the continuity counter has
# something it must report. A grader that cannot fail is not evidence when it passes.
if [ ! -f "$W/fixtures/BROKEN-excised.ts" ]; then
	python3 - "$W/fixtures/svc-normal.ts" "$W/fixtures/BROKEN-excised.ts" <<'PY' >>"$LOG" 2>&1 || die "could not build BROKEN-excised.ts"
import sys
src, dst = sys.argv[1], sys.argv[2]
blob = open(src, 'rb').read()
pkts = [blob[i:i+188] for i in range(0, len(blob) - 187, 188)]
# excise 50 packets from the middle; enough to be unambiguous, small enough to stay parseable
cut = len(pkts) // 2
del pkts[cut:cut + 50]
open(dst, 'wb').write(b''.join(pkts))
print(f"excised 50 packets at {cut}")
PY
fi
say "  BROKEN-excised.ts  $(stat -c%s "$W/fixtures/BROKEN-excised.ts") bytes"

# base20: 20 s of real coded video. The boundary conditions are injected into this rather than
# into a synthetic fixture, because `moq export ts` refuses a stream of verbatim tracks --
# "TS export requires a video or audio track for the PCR" -- which is the precondition the
# first rehearsal discovered.
#
# Cut it by PACKET COUNT, not `-P until --seconds`. `until --seconds` counts wall-clock, and a
# file source is read as fast as the disk allows, so it passes the entire clip — which is how
# the first run of this script produced a 745 MB "20 second" fixture. The rule is in
# `method-notes.md`; this is the second time it has been paid for.
BASE_PKTS="${BASE_PKTS:-132000}" # ~20 s at the 9.95 Mbps campaign clip
if [ ! -f "$W/fixtures/base20.ts" ]; then
	tsp -I file "$CLIP" -P until --packets "$BASE_PKTS" -O file "$W/fixtures/base20.ts" >>"$LOG" 2>&1 ||
		die "could not build base20.ts from $CLIP"
fi
BASE_SZ=$(stat -c%s "$W/fixtures/base20.ts")
say "  base20.ts          $BASE_SZ bytes ($((BASE_SZ / 188)) packets)"
[ "$BASE_SZ" -gt 100000 ] || die "base20.ts is too small -- is $CLIP shorter than $BASE_PKTS packets?"
[ "$BASE_SZ" -lt 100000000 ] || die "base20.ts is $BASE_SZ bytes -- the packet cut did not take"

# ---------------------------------------------------------------------------
# Step B -- the relay, and its fingerprint. The harness reads fp.txt and never starts one.
# ---------------------------------------------------------------------------
say "--- relay on :$PORT ---"
GSO=""
"$RELAY" --help 2>&1 | grep -q 'server-quic-gso' && GSO="--server-quic-gso=false"
"$RELAY" --help 2>&1 | grep -q '^\s*--quic-gso' && GSO="--quic-gso=false"

# The fingerprint is served by the *web* listener, not the QUIC one. Started from a TOML
# config the two share a port and it is easy to assume the QUIC listener provides it; started
# from flags, a relay with only `--server-bind` comes up healthy, logs `listening kind="quic"`,
# and serves no `/certificate.sha256` at all. That is what the first run of this script hit:
# the relay was fine and the harness was right to abort.
WEB=""
"$RELAY" --help 2>&1 | grep -q 'web-http-listen' && WEB="--web-http-listen [::]:$PORT"

# shellcheck disable=SC2086
"$RELAY" --server-bind "[::]:$PORT" --tls-generate localhost --auth-public "" $GSO $WEB \
	>"$OUT/relay.log" 2>&1 &
RELAY_PID=$!

FP=""
for _ in $(seq 1 30); do
	sleep 1
	FP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/certificate.sha256" 2>/dev/null) || true
	[ -n "$FP" ] && break
	kill -0 "$RELAY_PID" 2>/dev/null || die "relay exited; see $OUT/relay.log$(
		printf '\n'
		tail -5 "$OUT/relay.log"
	)"
done
[ -n "$FP" ] || die "relay never served a fingerprint on :$PORT; see $OUT/relay.log"
printf '%s' "$FP" >"$W/fp.txt"
say "  fingerprint: ${FP:0:16}…  (pid $RELAY_PID)"

# ---------------------------------------------------------------------------
# Step C -- hand over to the acceptance harness, unchanged.
# ---------------------------------------------------------------------------
say "--- acceptance harness ---"
MOQ="$MOQ" PACER="$PACER" CLIP="$CLIP" \
	RELAY_URL="https://127.0.0.1:$PORT/t33" \
	bash "$REPO/scripts/t33-acceptance.sh" "$OUT" "$SUBJ_S" "$SOAK_S"
RC=$?

say "--- acceptance harness exited $RC ---"
[ -f "$OUT/results.csv" ] && {
	say "results:"
	sed 's/^/  /' "$OUT/results.csv" | tee -a "$LOG"
}
say "=== finished $(date -Is) ==="
exit $RC

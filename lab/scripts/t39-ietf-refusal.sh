#!/bin/bash
# Does a publishing client learn that its announce was refused? Measured, per wire version.
#
# `docs/upstream/publish-refusal-not-signalled.local.md` claimed, from reading the source, that
# moq-transport signals a refused publish (PUBLISH_NAMESPACE_ERROR / REQUEST_ERROR) where
# moq-lite silently drops the same Error::Unauthorized. That is a claim about the wire, and it
# was never run. This runs it.
#
# The relay speaks both wires and `--client-version` pins which one, so the same refusal can be
# put over each in turn with nothing else changed -- one relay, one token, one source clip.
#
# Two cells per version, and the control is what makes the subject readable:
#
#   in-scope    publish affa.telemetry   MUST ADMIT    proves the wire works at all for publish
#   out-of-scope publish tnt             MUST REFUSE   the subject: what is the client told?
#
# Without the in-scope control, an error on the IETF path could equally mean "the IETF path
# cannot publish TS at all", which would look like a refusal signal and be nothing of the kind.
#
# TWO INDEPENDENT ORACLES, because the whole point is that the client's own view is unreliable:
#   1. Admission truth: whether a separate, fully-privileged subscriber can read the bytes back.
#      Bytes at a subscriber, never a log line. (Same oracle as t39-token-dualscope.sh.)
#   2. What the client learned: its exit code, how long it stayed up, and whether anything in
#      its own output names the refusal. A client that is told exits promptly; one that is not
#      runs to the timeout believing it is publishing.
#
# Nothing below prints key or token material.
#
# Usage: t39-ietf-refusal.sh [versions...]   (default: moq-lite-05 moq-transport-14 moq-transport-19)

set -u
W=/tmp/t39ietf
M=~/bin-3529/moq
PORT=9711
HTTP=9712
HOLD=10 # seconds a publisher is given; a signalled refusal should exit well inside this
READBACK=16 # the reader must outlast the publisher, or a control fails for want of a window

VERSIONS=("$@")
[ ${#VERSIONS[@]} -eq 0 ] && VERSIONS=(moq-lite-05 moq-transport-14 moq-transport-19)

command -v tsp >/dev/null || {
	echo "FAIL: tsp not found"
	exit 1
}
[ -x "$M" ] || {
	echo "FAIL: $M not executable"
	exit 1
}

rm -rf $W && mkdir -p $W/keydir $W/tok $W/logs $W/out && cd $W || exit 1

# Video-only, and fed through `regulate --pcr-synchronous` at run time rather than read at disk
# speed. An unpaced clip is consumed in about a second, so the publisher exits before the
# question has been asked and every cell reads "refused" for want of a publisher.
CLIP=~/t12_vidonly.ts
[ -r "$CLIP" ] || {
	echo "FAIL: source clip not readable: $CLIP"
	exit 1
}

EXP=$(($(date +%s) + 7200))
$M token generate --algorithm HS256 --id affa --out-dir $W/keydir >/dev/null 2>&1
$M token generate --algorithm HS256 --id wbd --out-dir $W/keydir >/dev/null 2>&1
# The token under test: publish is scoped to affa.telemetry and nothing else.
$M token sign --key $W/keydir/affa.jwk --root wbd \
	--publish affa.telemetry --expires $EXP >$W/tok/pub.jwt
# The oracle: read anything under the root.
$M token sign --key $W/keydir/wbd.jwk --root wbd --subscribe "" --expires $EXP >$W/tok/oracle.jwt

$M-relay --server-bind 127.0.0.1:$PORT --tls-generate localhost --server-quic-gso=false \
	--web-http-listen 127.0.0.1:$HTTP --auth-key-dir $W/keydir --log-level debug \
	>$W/logs/relay.log 2>&1 &
RELAY=$!
trap 'kill $RELAY 2>/dev/null' EXIT
sleep 4
FP=$(curl -s --max-time 5 http://127.0.0.1:$HTTP/certificate.sha256)
[ -z "$FP" ] && {
	echo "FAIL: relay did not come up"
	tail -5 $W/logs/relay.log
	exit 1
}
echo "relay up on $PORT; token publish scope = [affa.telemetry], root wbd"
echo

# The root goes in the URL path and broadcast names are relative to it. Omitting `/wbd` makes
# the relay refuse everything, including the control, which looks exactly like a refusal signal.
url() { echo "https://127.0.0.1:$PORT/wbd?jwt=$1"; }
PJWT=$(cat $W/tok/pub.jwt)
OJWT=$(cat $W/tok/oracle.jwt)

printf '%-18s %-16s %-9s %-7s %-7s %-11s %s\n' VERSION CELL VERDICT PUB_RC HELD_S READBACK CLIENT_TOLD
fail=0

for V in "${VERSIONS[@]}"; do
	for CELL in in-scope out-of-scope; do
		# Scope matching is segment-aware and the separator is `/`, not `.`: a broadcast named
		# `affa.telemetry.probe` is a *sibling* of the granted `affa.telemetry`, not a child of
		# it, and is refused -- which fails the control and imitates the very signal being
		# looked for. The sub-path has to be `affa.telemetry/<leaf>`.
		# A distinct leaf per cell, because a reused name can attach to the previous cell's
		# retained announce and the readback then passes for the wrong reason.
		LEAF="p$(echo "$V" | tr -d '.-')"
		case $CELL in
		in-scope) BC="affa.telemetry/$LEAF" ;;
		out-of-scope) BC="tnt/$LEAF" ;;
		esac
		PLOG=$W/logs/pub-$V-$CELL.log
		OUT=$W/out/$V-$CELL.ts

		# Reader first, so the catalog resolves once the publisher announces.
		(timeout $READBACK $M --client-connect "$(url "$OJWT")" --client-tls-fingerprint "$FP" \
			--client-quic-gso=false --client-version "$V" --backoff-timeout 5s \
			--broadcast "$BC" export ts >"$OUT" 2>$W/logs/oracle-$V-$CELL.log) &
		ORACLE=$!
		sleep 1

		T0=$(python3 -c 'import time;print(time.time())')
		timeout $HOLD tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>/dev/null |
			timeout $HOLD $M --client-connect "$(url "$PJWT")" --client-tls-fingerprint "$FP" \
				--client-quic-gso=false --client-version "$V" --backoff-timeout 4s \
				--broadcast "$BC" import ts >"$PLOG" 2>&1
		PRC=$?
		HELD=$(python3 -c "import time;print(f'{time.time()-$T0:.1f}')")
		wait $ORACLE 2>/dev/null

		BYTES=$(stat -f%z "$OUT" 2>/dev/null || echo 0)
		# Admission truth: did a privileged reader get media?
		if [ "$BYTES" -gt 20000 ]; then VERDICT=ADMIT; else VERDICT=refused; fi

		# What did the publishing client itself learn? Look for a refusal named in its own
		# output, not merely for a non-zero exit -- `timeout` also returns non-zero.
		if rg -qi 'unauthor|forbidden|refus|denied|not allowed|error' "$PLOG" 2>/dev/null; then
			TOLD="yes: $(rg -oi 'unauthor[a-z]*|forbidden|refus[a-z]*|denied' "$PLOG" | head -1)"
		elif [ "$PRC" -eq 124 ]; then
			TOLD="no (ran to timeout)"
		elif [ "$PRC" -eq 0 ]; then
			TOLD="no (clean exit)"
		else
			TOLD="rc=$PRC, no message"
		fi

		NEG=$(rg -o 'moq-lite-[0-9]+|moq-transport-[0-9]+' "$PLOG" | head -1)
		[ "$NEG" = "$V" ] || {
			echo "  WARNING: $V cell $CELL negotiated '$NEG' -- cell is void"
			fail=1
		}

		printf '%-18s %-16s %-9s %-7s %-7s %-11s %s\n' \
			"$V" "$CELL" "$VERDICT" "$PRC" "$HELD" "${BYTES}B" "$TOLD"

		# Fixed before the run: in-scope must be admitted, out-of-scope must be refused.
		case $CELL in
		in-scope) [ "$VERDICT" = ADMIT ] || {
			echo "  FAIL: in-scope publish was refused on $V -- this wire cannot publish, cells void"
			fail=1
		} ;;
		out-of-scope) [ "$VERDICT" = refused ] || {
			echo "  FAIL: out-of-scope publish was ADMITTED on $V -- enforcement gap, not a signalling question"
			fail=1
		} ;;
		esac
	done
done

echo
echo "Relay-side record of the refusals (what the operator can see):"
rg -i 'declin|unauthor|outside|scope' $W/logs/relay.log 2>/dev/null | head -8 ||
	echo "  (nothing in the relay log names a declined announce)"

echo
[ "$fail" -eq 0 ] && echo "HARNESS OK: every control held and every subject was refused" ||
	echo "HARNESS FAILURE: see the FAIL lines above; do not read the CLIENT_TOLD column"
exit "$fail"

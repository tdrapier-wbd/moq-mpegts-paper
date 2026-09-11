#!/bin/bash
# Verify whether ONE moq token can carry a media `--subscribe` grant and an unrelated
# `--publish` grant for a telemetry path, and whether the relay routes both correctly.
#
# This is the load-bearing assumption under any cross-administrative-boundary observability
# design: if the subscriber's existing credential can also authorise a telemetry publish back
# to us, the client edge needs no second credential, no second connection and no inbound hole
# in the client's firewall. If it cannot, every such design needs a second credential and the
# argument changes. It is stated here as a hypothesis to falsify, not as a premise.
#
# THE ORACLE IS THE POINT. A first version of this script read each publish cell's verdict by
# grepping the publishing client's own log for an authorization error, and reported that the
# relay admits publishes it should refuse. That was wrong, and wrong in the alarming
# direction: the publishing client is told *nothing either way* -- its log ends at "connected"
# whether the announce was accepted or dropped. So a publish cell is scored here by whether an
# independent, fully-privileged subscriber can read back what was published. Bytes at a
# subscriber, never a log line.
#
# Cells, each with its verdict fixed before the run:
#
#   1  subscribe cnn                  MUST ADMIT   the media grant
#   2  publish   affa.telemetry       MUST ADMIT   the telemetry grant, same token
#   3  publish   tnt                  MUST REFUSE  a subscriber must not publish media
#   4  subscribe tnt                  MUST REFUSE  an unlicensed channel
#   5  publish   affb.telemetry       MUST REFUSE  another affiliate's telemetry path
#   6  publish   affa.telemetry/gw1   MUST ADMIT   the prefix must cover a per-gateway sub-path
#
# Cell 3 uses `tnt` rather than `cnn` deliberately: the estate's legitimate publisher is on
# `cnn`, so a subscriber there reads bytes whether or not the rogue publish was admitted, and
# the cell would pass for the wrong reason.
#
# Usage: t39-token-dualscope.sh

set -u
W=/tmp/t39
M=~/bin-3529/moq
PORT=9643
HTTP=9680
rm -rf $W
mkdir -p $W/keys $W/keydir $W/tok $W/logs $W/out
cd $W

EXP=$(($(date +%s) + 7200))

# --- estate -------------------------------------------------------------------
# Nothing below prints key or token material.
$M token generate --algorithm HS256 --id affa --out-dir $W/keydir >/dev/null 2>&1
$M token generate --algorithm HS256 --id wbd --out-dir $W/keydir >/dev/null 2>&1

# THE TOKEN UNDER TEST: one token, two unrelated grants.
$M token sign --key $W/keydir/affa.jwk --root wbd \
	--subscribe cnn --publish affa.telemetry --expires $EXP >$W/tok/dual.jwt
# The estate's own publisher, and a privileged reader used only as the oracle.
$M token sign --key $W/keydir/wbd.jwk --root wbd --publish "" --expires $EXP >$W/tok/pub.jwt
$M token sign --key $W/keydir/wbd.jwk --root wbd --subscribe "" --expires $EXP >$W/tok/oracle.jwt
echo "one token under test: root=wbd subscribe=[cnn] publish=[affa.telemetry]"

# --- relay --------------------------------------------------------------------
$M-relay --server-bind 127.0.0.1:$PORT --tls-generate localhost --server-quic-gso=false \
	--web-http-listen 127.0.0.1:$HTTP --auth-key-dir $W/keydir --log-level info \
	>$W/logs/relay.log 2>&1 &
RELAY=$!
trap 'kill $RELAY 2>/dev/null; pkill -f "127.0.0.1:$PORT" 2>/dev/null' EXIT
sleep 4
FP=$(curl -s --max-time 4 http://127.0.0.1:$HTTP/certificate.sha256)
[ -z "$FP" ] && {
	echo "relay did not come up"
	tail -5 $W/logs/relay.log
	exit 1
}
JWT=$(cat $W/tok/dual.jwt)
PJWT=$(cat $W/tok/pub.jwt)
OJWT=$(cat $W/tok/oracle.jwt)

url() { echo "https://127.0.0.1:$PORT/wbd?jwt=$1"; }

# --- the estate's legitimate media publisher, for the subscribe cells ----------
tsp -I file ~/t12_vidonly.ts --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null |
	$M --client-connect "$(url "$PJWT")" --client-tls-fingerprint "$FP" \
		--client-quic-gso=false --broadcast cnn import ts >$W/logs/pub.log 2>&1 &
PUB=$!
trap 'kill $RELAY $PUB 2>/dev/null' EXIT
sleep 5

RESULT=$W/out/cells.csv
echo "cell,op,path,expected,observed,bytes,verdict" >$RESULT

sub_cell() { # n path want note -- the token under test subscribes; bytes are the oracle
	local n="$1" path="$2" want="$3" note="$4"
	timeout 8 $M --client-connect "$(url "$JWT")" --client-tls-fingerprint "$FP" \
		--client-quic-gso=false --backoff-timeout 3s --broadcast "$path" export ts \
		>"$W/out/c$n.ts" 2>"$W/logs/c$n.log"
	local b got
	b=$(stat -f%z "$W/out/c$n.ts" 2>/dev/null || echo 0)
	[ "$b" -gt 10000 ] && got=ADMIT || got=REFUSE
	report "$n" subscribe "$path" "$want" "$got" "$b" "$note"
}

pub_cell() { # n path want note -- the token under test publishes; a PRIVILEGED SUBSCRIBER
	# on the same path is the oracle. The publishing client is told nothing either way, so
	# its own log cannot score this.
	local n="$1" path="$2" want="$3" note="$4"
	timeout 12 $M --client-connect "$(url "$OJWT")" --client-tls-fingerprint "$FP" \
		--client-quic-gso=false --backoff-timeout 8s --broadcast "$path" export ts \
		>"$W/out/c$n.ts" 2>"$W/logs/c$n-oracle.log" &
	local O=$!
	sleep 1
	timeout 9 tsp -I file ~/t12_vidonly.ts -P regulate --pcr-synchronous -O file - 2>/dev/null |
		timeout 9 $M --client-connect "$(url "$JWT")" --client-tls-fingerprint "$FP" \
			--client-quic-gso=false --backoff-timeout 3s --broadcast "$path" import ts \
			>"$W/logs/c$n.log" 2>&1
	wait $O 2>/dev/null
	local b got
	b=$(stat -f%z "$W/out/c$n.ts" 2>/dev/null || echo 0)
	[ "$b" -gt 10000 ] && got=ADMIT || got=REFUSE
	report "$n" publish "$path" "$want" "$got" "$b" "$note"
}

report() {
	local n="$1" op="$2" path="$3" want="$4" got="$5" b="$6" note="$7" v="ok"
	[ "$got" = "$want" ] || v="*** MISMATCH ***"
	printf "  %-2s %-9s %-22s want=%-6s got=%-6s %10s B  %-8s %s\n" \
		"$n" "$op" "$path" "$want" "$got" "$b" "$v" "$note"
	echo "$n,$op,$path,$want,$got,$b,$v" >>"$RESULT"
}

echo
echo "cell op        path                   expected  observed      bytes"
sub_cell 1 cnn ADMIT "the media grant"
pub_cell 2 affa.telemetry ADMIT "telemetry, same token"
pub_cell 3 tnt REFUSE "subscriber must not publish media"
sub_cell 4 tnt REFUSE "unlicensed channel"
pub_cell 5 affb.telemetry REFUSE "another affiliate's telemetry"
pub_cell 6 affa.telemetry/gw1 ADMIT "per-gateway sub-path"

# --- oracle control: the oracle itself must be able to read a path that IS published,
# or every REFUSE above is unfalsifiable.
echo
timeout 8 $M --client-connect "$(url "$OJWT")" --client-tls-fingerprint "$FP" \
	--client-quic-gso=false --broadcast cnn export ts >$W/out/oracle-control.ts 2>/dev/null
OB=$(stat -f%z $W/out/oracle-control.ts 2>/dev/null || echo 0)
if [ "$OB" -gt 10000 ]; then
	echo "oracle control: reads a live path, ${OB} B -- a REFUSE above means refused"
else
	echo "oracle control: FAILED (${OB} B) -- every REFUSE above is unfalsifiable, discard the run"
fi

kill $PUB $RELAY 2>/dev/null
wait 2>/dev/null

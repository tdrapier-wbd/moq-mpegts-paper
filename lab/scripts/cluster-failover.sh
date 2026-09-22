#!/usr/bin/env bash
#
# cluster_failover.sh — end-to-end 1+1 active/active source-failover drill for a
# two-relay moq-relay mesh. Offered to moq-dev/moq as the integration drill that
# PR #2473 (issue #2461) lists under "Not in this PR".
#
# Topology (relayB is ACTIVELY CARRYING the broadcast via relayA while also
# holding a local standby, which is the scenario #2473's analysis describes):
#
#     pubA ──▶ relayA(:4443) ◀──cluster──▶ relayB(:5443) ◀── pubB
#               ▲   ▲                          ▲
#             sub1 sub2                       sub3   (sub3 forces relayB to carry)
#
#   * pubA and pubB publish the SAME broadcast and SHARE an --origin id, which is
#     how #2473 declares two publishers interchangeable (same first hop → splice).
#   * sub1/sub2 subscribe on relayA (served by the local pubA).
#   * sub3 subscribes on relayB; with no local publisher yet, relayB fetches the
#     broadcast across the mesh from relayA — so relayB is "carrying pubA→relayA→relayB".
#   * pubB then joins relayB as the hot standby.
#
# Two graded checks:
#   CHECK 1 (failover, #2461): kill pubA; sub1 on relayA must resume, i.e. relayA
#     reselected onto the pubB standby advertised by relayB.
#   CHECK 2 (regression):      sub3 on relayB must SURVIVE pubB joining. This used
#     to abort with Error::Unroutable (code=30) because a standby wins dispatch
#     before a real publisher has lazily created every track.
#
# *** READ THIS BEFORE CHANGING THE TIMELINE ***
# `kill` on a publisher never sends CONNECTION_CLOSE, so the relay keeps serving the
# dead source until the QUIC **idle timeout** expires (DEFAULT_IDLE_TIMEOUT = 30s).
# The relay logs nothing between the kill and `connection closed err=timed out` 30s
# later, and only then can it reselect onto the standby. A grading window shorter
# than that budget CANNOT pass on any build — an earlier version of this drill killed
# at t=22 and graded at t=43, i.e. 21s into a 30s timeout, and reported a spurious
# "no failover". The window is therefore DERIVED from the detection budget:
#   IDLE_BUDGET  seconds the relay needs to notice a hard-killed publisher (default 30).
#   SIDLE        optional --server-quic-idle-timeout on the relays (e.g. 6s) for a fast
#                run; it also shrinks IDLE_BUDGET. Must stay ABOVE the keep-alive
#                interval or even healthy sessions flap.
#
# Requirements: moq + moq-relay on PATH or via $MOQ/$RELAY; tsp (TSDuck) for pacing;
# a looping TS source in $SRC. On macOS loopback the --*-quic-gso=false flags are
# required (already passed below); they are harmless elsewhere.
set -uo pipefail

MOQ="${MOQ:-moq}"; RELAY="${RELAY:-moq-relay}"
SRC="${SRC:-$HOME/CNNiEMEA2.ts}"           # any looping MPEG-TS clip
BCAST="${BCAST:-red.hang}"
OID="${OID-424242}"                        # shared publisher origin id (OID="" ⇒ independent ids)

SIDLE="${SIDLE:-}"
IDLE_BUDGET="${IDLE_BUDGET:-${SIDLE%s}}"; IDLE_BUDGET="${IDLE_BUDGET:-30}"
PRE=10; KILLA=22
KILLB=$((KILLA + IDLE_BUDGET + 20))        # >=20s of observation AFTER detection
END=$((KILLB + 8))
SIDLE_ARG=""; [ -n "$SIDLE" ] && SIDLE_ARG="--server-quic-idle-timeout $SIDLE"

WORK="$(mktemp -d)"; cd "$WORK"
echo "workdir=$WORK  moq=$($MOQ --version 2>/dev/null)  origin=${OID:-random-per-pub}"
echo "timeline: pubB_join=$PRE KILL_pubA=$KILLA KILL_pubB=$KILLB end=$END (idle budget=${IDLE_BUDGET}s${SIDLE:+, --server-quic-idle-timeout $SIDLE})"
echo "tip: RUST_LOG=moq_net=debug shows 'no advertisable route for this peer' then 'announce … hops=2' at the standby join"

cat >relayA.toml <<EOF
[server]
listen = "[::]:4443"
tls.generate = ["localhost"]
[web.http]
listen = "[::]:4443"
[auth]
public = ""
[cluster]
id = 11111
connect = ["https://localhost:5443/"]
EOF
cat >relayB.toml <<EOF
[server]
listen = "[::]:5443"
tls.generate = ["localhost"]
[web.http]
listen = "[::]:5443"
[auth]
public = ""
[cluster]
id = 22222
connect = ["https://localhost:4443/"]
EOF

cleanup() { pkill -P $$ 2>/dev/null; pkill -f "moq-relay .*relay[AB].toml" 2>/dev/null; }
trap cleanup EXIT

"$RELAY" relayA.toml --server-quic-gso=false --client-quic-gso=false --client-tls-disable-verify $SIDLE_ARG >relayA.log 2>&1 &
"$RELAY" relayB.toml --server-quic-gso=false --client-quic-gso=false --client-tls-disable-verify $SIDLE_ARG >relayB.log 2>&1 &
sleep 4
FPA=$(curl -s http://localhost:4443/certificate.sha256)
FPB=$(curl -s http://localhost:5443/certificate.sha256)
[ -z "$FPA" ] || [ -z "$FPB" ] && { echo "FAIL: relay(s) did not come up"; exit 1; }

OARG=""; [ -n "$OID" ] && OARG="--origin $OID"
sub() { "$MOQ" --client-tls-fingerprint "$3" --client-connect "https://localhost:$2" --client-quic-gso=false \
    --broadcast "$BCAST" export ts >"$1.ts" 2>"$1.log" & echo $!; }
pub() { ( tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - 2>"$1_tsp.log" \
    | "$MOQ" --client-tls-fingerprint "$2" --client-connect "https://localhost:$3" --client-quic-gso=false $OARG \
        --broadcast "$BCAST" import ts ) >"$1.log" 2>&1 & echo $!; }

S1=$(sub sub1 4443 "$FPA")
S2=$(sub sub2 4443 "$FPA")
S3=$(sub sub3 5443 "$FPB")     # subscriber on relay B ⇒ relay B actively carries via relay A
sleep 1
PUBA=$(pub pubA "$FPA" 4443)
echo "sub1=$S1 sub2=$S2 sub3(relayB)=$S3 pubA=$PUBA"

sz() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }
( echo "t,sub1,sub3,event" >sizes.csv
  for t in $(seq 0 $END); do
    ev=""; [ "$t" -eq "$PRE" ] && ev=pubB_join; [ "$t" -eq "$KILLA" ] && ev=KILL_pubA; [ "$t" -eq "$KILLB" ] && ev=KILL_pubB
    printf "%s,%s,%s,%s\n" "$t" "$(sz sub1.ts)" "$(sz sub3.ts)" "$ev" >>sizes.csv
    sleep 1; done ) &

sleep "$PRE";  PUBB=$(pub pubB "$FPB" 5443); echo ">> t=$PRE pubB joined relayB (hot standby)"
sleep $((KILLA-PRE)); echo ">> t=$KILLA KILL pubA (active source)"; pkill -P "$PUBA" 2>/dev/null; kill "$PUBA" 2>/dev/null
sleep $((KILLB-KILLA)); echo ">> t=$KILLB KILL pubB"; pkill -P "$PUBB" 2>/dev/null; kill "$PUBB" 2>/dev/null
sleep $((END-KILLB)); echo ">> teardown"; cleanup; wait 2>/dev/null

echo "=== sizes.csv ==="; cat sizes.csv
RC=0

# --- CHECK 1: did sub1 on relay A fail over onto the standby? ---
B=$(awk -F, -v k=$KILLA '$1==k{print $2}' sizes.csv)
A=$(awk -F, -v k=$((KILLB-1)) '$1==k{print $2}' sizes.csv)
R=$(awk -F, -v k=$KILLA -v b="$B" -v e=$KILLB '$1>k && $1<e && $2>b {print $1; exit}' sizes.csv)
echo "=== CHECK 1 (failover): sub1 at KILL_pubA(t=$KILLA)=$B -> before KILL_pubB(t=$((KILLB-1)))=$A ==="
if [ -n "$B" ] && [ -n "$A" ] && [ "$A" -gt "$B" ]; then
  echo ">>> PASS: sub1 resumed at t=$R ($((R-KILLA))s after the kill, +$((A-B)) bytes) — relayA failed over to the pubB standby"
else
  echo ">>> FAIL: sub1 frozen for the whole $((KILLB-KILLA))s window after pubA died — no source failover"; RC=1
fi

# --- CHECK 2: did sub3 on relay B survive the standby joining? ---
J=$(awk -F, -v k=$PRE '$1==k{print $3}' sizes.csv)
JA=$(awk -F, -v k=$((PRE+8)) '$1==k{print $3}' sizes.csv)
echo "=== CHECK 2 (standby join): sub3 at pubB_join(t=$PRE)=$J -> t=$((PRE+8))=$JA ==="
if [ -n "$J" ] && [ -n "$JA" ] && [ "$JA" -gt "$J" ]; then
  echo ">>> PASS: sub3 survived pubB's join (+$((JA-J)) bytes)"
else
  echo ">>> FAIL: sub3 torn down when the shared-origin standby joined the carrying relay"; RC=1
fi

grep -iE "unroutable|json: dropped" sub1.log sub3.log 2>/dev/null | tail -4
exit $RC

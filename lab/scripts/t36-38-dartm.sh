#!/bin/bash
# Run one T37 disable arm.
#   dartm.sh <id> <settle_s> <observe_s> <lever...>
# Starts the affiliate under test and a collateral affiliate (affb, separately
# licensed for the same channel), lets both settle, then applies the lever.
# The lever's write to the state file is the zero of the measurement.
#
# --backoff-timeout 100ms: the client's DEFAULT 10 s reconnect-retry window
# otherwise dominates every figure, because a revoked client keeps re-dialling
# and only exits when it gives up. That is the client's behaviour, not the
# relay's revocation latency, and conflating them would have reported a 25 ms
# revocation as a 10 s one.
W=/tmp/t36
cd $W
FP=$(cat $W/fp.txt)
LB=/Users/tdrapier/moq-mpegts-paper/lab/scripts/t37-lastbyte.py
ID="$1"; SETTLE="$2"; OBSERVE="$3"; shift 3
TOKA="${TOKA:-affa.jwt}"
CHAN="${CHAN:-cnn}"
TOTAL=$((SETTLE + OBSERVE))
BOFF="${BOFF:-100ms}"

sub() {  # sub <role> <tokenfile> <channel>
  timeout $TOTAL ~/bin-3529/moq --backoff-timeout "$BOFF" \
      --client-connect "https://127.0.0.1:9443/wbd?jwt=$(cat $W/tok/$2)" \
      --client-tls-fingerprint "$FP" export --broadcast "$3" ts 2> $W/logs/$ID-$1.log \
    | python3 $LB --out $W/out/$ID-$1.ts --record $W/lastbyte.jsonl --mark "$ID-$1" > /dev/null &
}

sub A "$TOKA" "$CHAN"
sub C affb.jwt cnn
sleep "$SETTLE"
# randomised sub-cadence phase, so the decision does not land at a fixed point
# in the poll cycle (see sweep-d2.sh)
[ -n "${OFFSET:-}" ] && sleep "$OFFSET"
# ---- the control-plane decision -----------------------------------------
python3 $W/mkstate.py --mark "$ID" "$@" > /dev/null
# --------------------------------------------------------------------------
wait

python3 $W/report.py "$ID"

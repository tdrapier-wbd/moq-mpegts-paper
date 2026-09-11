#!/bin/bash
# T38 Parts 2 and 3 — the headline.
#
# An affiliate licenses two channels and loses one of them. The question is what
# that costs on the channel it KEEPS, under two credential topologies:
#
#   BROAD  (affiliate D): one key covers both channels. Under the authorization
#          endpoint the revocable unit is the key, so withdrawing either channel
#          means withdrawing the key — which takes both down — and then
#          re-provisioning the survivor under a new, narrower credential.
#   NARROW (affiliate E): one key per channel. Withdrawing one withdraws exactly
#          one.
#
# This is the de-provisioning-granularity term the control-plane document's
# scope-granularity trade-off does not consider.
W=/tmp/t36
cd $W
FP=$(cat $W/fp.txt)
LB=/Users/tdrapier/moq-mpegts-paper/lab/scripts/t37-lastbyte.py
SETTLE="${SETTLE:-10}"
OBS="${OBS:-25}"
TOTAL=$((SETTLE+OBS))

sub() {  # sub <mark> <tokenfile> <channel> <seconds>
  timeout $4 ~/bin-3529/moq --backoff-timeout 100ms \
      --client-connect "https://127.0.0.1:9443/wbd?jwt=$(cat $W/tok/$2.jwt)" \
      --client-tls-fingerprint "$FP" export --broadcast "$3" ts 2> $W/logs/$1.log \
    | python3 $LB --out $W/out/$1.ts --record $W/lastbyte.jsonl --mark "$1" > /dev/null &
}

echo "################ BROAD topology — affiliate D, one key for both channels ################"
python3 $W/mkstate2.py --cache-control "max-age=2" --mark "reset broad" >/dev/null; sleep 1
sub BROAD-cnn affd cnn $TOTAL
sub BROAD-tnt affd tnt $TOTAL
sleep $SETTLE
python3 $W/mkstate2.py --cache-control "max-age=2" --disable affdkey \
        --mark "BROAD withdraw cnn (must withdraw the key, which covers both)" >/dev/null
sleep 3
# re-provision the surviving channel under a narrower credential (kid affdtntkey,
# already in the matrix, granting tnt only)
python3 $W/mkstate2.py --cache-control "max-age=2" --disable affdkey \
        --mark "BROAD reprovision tnt" >/dev/null
sub BROAD-tnt2 affd-tnt tnt $((OBS-5))
wait

echo
echo "################ NARROW topology — affiliate E, one key per channel ################"
python3 $W/mkstate2.py --cache-control "max-age=2" --mark "reset narrow" >/dev/null; sleep 1
sub NARROW-cnn affe-cnn cnn $TOTAL
sub NARROW-tnt affe-tnt tnt $TOTAL
sleep $SETTLE
python3 $W/mkstate2.py --cache-control "max-age=2" --disable affecnnkey \
        --mark "NARROW withdraw cnn (one key, one channel)" >/dev/null
wait

echo
echo "=== what happened to the channel each affiliate KEPT ==="
python3 $W/t38report.py

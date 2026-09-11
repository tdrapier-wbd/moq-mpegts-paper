#!/bin/bash
# T37 arms other than the D2 cadence sweep: E1, E2, D1a/b, D3a/b, D5, D6.
# C1 (the uninvolved affiliate) rides along in every arm via dartm.sh.
W=/tmp/t36
cd $W
M=~/bin-3529/moq
FP=$(cat $W/fp.txt)
LB=/Users/tdrapier/moq-mpegts-paper/lab/scripts/t37-lastbyte.py

reset() { python3 $W/mkstate.py --cache-control "max-age=5" --mark "reset $1" >/dev/null; sleep 1; }

echo "############ ENABLE ARMS ############"

# ---- E1: grant, then connect. Zero is the grant appearing at the endpoint ----
echo "== E1: grant-and-connect =="
python3 $W/mkstate.py --cache-control "max-age=5" --enable "wbdkey,rivalkey,affbkey,affckey" --mark "E1 pre" >/dev/null
sleep 2
for r in 1 2 3 4 5; do
  python3 $W/mkstate.py --cache-control "max-age=5" --mark "E1-r$r" >/dev/null   # the grant
  T0=$(python3 -c "
import json;print([json.loads(l) for l in open('$W/decisions.jsonl') if json.loads(l).get('mark')=='E1-r$r'][-1]['wall'])")
  timeout 10 $M --backoff-timeout 100ms \
    --client-connect "https://127.0.0.1:9443/wbd?jwt=$(cat $W/tok/affa.jwt)" \
    --client-tls-fingerprint "$FP" export --broadcast cnn ts 2>$W/logs/E1-r$r.log \
    | python3 $LB --out $W/out/E1-r$r.ts --record $W/lastbyte.jsonl --mark "E1-r$r" >/dev/null
  python3 -c "
import json
lb={json.loads(l)['mark']:json.loads(l) for l in open('$W/lastbyte.jsonl')}
r=lb.get('E1-r$r')
print(f\"  E1-r$r grant-to-first-byte: {r['first_write']-$T0:6.3f} s   ({r['bytes']:,} B delivered)\" if r and r.get('first_write') else '  E1-r$r NO MEDIA')"
  python3 $W/mkstate.py --cache-control "max-age=5" --enable "wbdkey,rivalkey,affbkey,affckey" --mark "E1 reset r$r" >/dev/null
  sleep 1
done

reset E2
echo
echo "== E2: add a second channel to a live affiliate =="
# affiliate B already holds cnn+tnt. Start cnn, then bring up tnt on a second
# session, and grade whether cnn was disturbed.
timeout 24 $M --backoff-timeout 100ms \
  --client-connect "https://127.0.0.1:9443/wbd?jwt=$(cat $W/tok/affb.jwt)" \
  --client-tls-fingerprint "$FP" export --broadcast cnn ts 2>$W/logs/E2-cnn.log \
  | python3 $LB --out $W/out/E2-cnn.ts --record $W/lastbyte.jsonl --mark "E2-cnn" >/dev/null &
sleep 8
python3 $W/mkstate.py --cache-control "max-age=5" --mark "E2-add" >/dev/null
timeout 12 $M --backoff-timeout 100ms \
  --client-connect "https://127.0.0.1:9443/wbd?jwt=$(cat $W/tok/affb.jwt)" \
  --client-tls-fingerprint "$FP" export --broadcast tnt ts 2>$W/logs/E2-tnt.log \
  | python3 $LB --out $W/out/E2-tnt.ts --record $W/lastbyte.jsonl --mark "E2-tnt" >/dev/null
wait
echo "  cnn continuity across the addition:"
python3 $W/grade.py $W/out/E2-cnn.ts $W/out/E2-tnt.ts

echo
echo "############ DISABLE ARMS ############"

# ---- D1: does an established session outlive its own token? (H1) ----
echo "== D1: stop refreshing — does expiry bound a live session? =="
for variant in withrecheck norecheck; do
  reset "D1-$variant"
  EXP=$(($(date +%s)+15))
  $M token sign --key $W/keys/affa.jwk --root wbd --subscribe cnn --expires $EXP > $W/tok/affa-short.jwt
  if [ "$variant" = "withrecheck" ]; then
    python3 $W/mkstate.py --cache-control "max-age=5" --mark "D1-$variant" >/dev/null
  else
    python3 $W/mkstate.py --mark "D1-$variant" >/dev/null          # no Cache-Control at all
  fi
  sleep 1
  timeout 50 $M --backoff-timeout 100ms \
    --client-connect "https://127.0.0.1:9443/wbd?jwt=$(cat $W/tok/affa-short.jwt)" \
    --client-tls-fingerprint "$FP" export --broadcast cnn ts 2>$W/logs/D1-$variant.log \
    | python3 $LB --out $W/out/D1-$variant.ts --record $W/lastbyte.jsonl --mark "D1-$variant" >/dev/null
  python3 -c "
import json
lb={json.loads(l)['mark']:json.loads(l) for l in open('$W/lastbyte.jsonl')}
r=lb.get('D1-$variant')
if r and r.get('last_write'):
    d=r['last_write']-$EXP
    verdict='STOPPED AT EXPIRY' if d < 6 else 'OUTLIVED ITS TOKEN'
    print(f'  D1-$variant: token exp at t=0; last byte {d:+7.3f} s   -> {verdict}   ({r[\"bytes\"]:,} B)')
else: print('  D1-$variant: NO MEDIA')"
done

# ---- D3: withdraw the key, and replace a key under the same kid ----
echo
echo "== D3a: withdraw the verifying key =="
reset D3a
./dartm.sh D3a 6 14 --cache-control "max-age=5" --enable "wbdkey,rivalkey,affbkey,affckey"

echo "== D3b: REPLACE the key under the same kid (a 'does a key exist' check would miss this) =="
reset D3b
./dartm.sh D3b 6 14 --cache-control "max-age=5" --keymap "affakey=$W/keys/affc.pub.jwk"

# ---- D5: unreachable endpoint (H4) ----
echo
echo "== D5: authorization endpoint unreachable, nothing revoked =="
for sw in "" "stale-while-revalidate=30"; do
  lbl=$([ -z "$sw" ] && echo "D5-nostale" || echo "D5-stale30")
  reset $lbl
  cc="max-age=5"; [ -n "$sw" ] && cc="max-age=5, $sw"
  python3 $W/mkstate.py --cache-control "$cc" --mark "$lbl pre" >/dev/null; sleep 1
  CC="$cc" ./dartm.sh $lbl 6 45 --mode unavailable --cache-control "$cc"
done

# ---- D6: no schedule offered (H3) ----
echo
echo "== D6: endpoint returns no Cache-Control, then the grant is withdrawn =="
reset D6
python3 $W/mkstate.py --mark "D6 pre (no cache-control)" >/dev/null; sleep 1
./dartm.sh D6 6 40 --enable "wbdkey,rivalkey,affbkey,affckey"

reset final
echo
echo "all non-sweep T37 arms complete"

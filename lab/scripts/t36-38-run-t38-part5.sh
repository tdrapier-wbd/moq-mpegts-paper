#!/bin/bash
# T38 Part 5 — keys and certificates.
W=/tmp/t36
cd $W
M=~/bin-3529/moq
FP=$(cat $W/fp.txt)
LB=/Users/tdrapier/moq-mpegts-paper/lab/scripts/t37-lastbyte.py

echo "################ 5a — key rotation with overlapping validity ################"
# Mint the successor key and a token under it.
$M token generate --algorithm ES256 --id affakey2 --root wbd --subscribe "" \
   --out $W/keys/affa2.jwk --public $W/keys/affa2.pub.jwk >/dev/null
$M token sign --key $W/keys/affa2.jwk --root wbd --subscribe cnn \
   --expires $(($(date +%s)+7200)) > $W/tok/affa2.jwt
python3 - <<'PY'
import json
m=json.load(open('/tmp/t36/matrix.json'))
m['affiliates']['affakey2']={'licensed':['cnn'],'key':'/tmp/t36/keys/affa2.pub.jwk',
                             'role':'affiliate A — successor key'}
json.dump(m,open('/tmp/t36/matrix.json','w'),indent=1)
PY
echo "  successor key affakey2 minted and added to the matrix (overlap begins)"

python3 $W/mkstate2.py --cache-control "max-age=2" --mark "rotation: overlap" >/dev/null
sleep 1

# old credential streaming; new credential brought up alongside (make-before-break)
timeout 26 $M --backoff-timeout 100ms \
  --client-connect "https://127.0.0.1:9443/wbd?jwt=$(cat $W/tok/affa.jwt)" \
  --client-tls-fingerprint "$FP" export --broadcast cnn ts 2>$W/logs/ROT-old.log \
  | python3 $LB --out $W/out/ROT-old.ts --record $W/lastbyte.jsonl --mark "ROT-old" >/dev/null &
sleep 6
timeout 20 $M --backoff-timeout 100ms \
  --client-connect "https://127.0.0.1:9443/wbd?jwt=$(cat $W/tok/affa2.jwt)" \
  --client-tls-fingerprint "$FP" export --broadcast cnn ts 2>$W/logs/ROT-new.log \
  | python3 $LB --out $W/out/ROT-new.ts --record $W/lastbyte.jsonl --mark "ROT-new" >/dev/null &
sleep 8
# retire the predecessor
python3 $W/mkstate2.py --cache-control "max-age=2" --disable affakey \
        --mark "rotation: retire predecessor" >/dev/null
wait

python3 - <<'PY'
import json
W="/tmp/t36"
lb={json.loads(l)["mark"]:json.loads(l) for l in open(f"{W}/lastbyte.jsonl")}
dec=[d for d in (json.loads(l) for l in open(f"{W}/decisions.jsonl"))
     if d.get("mark")=="rotation: retire predecessor"]
t0=dec[-1]["wall"]
for mk,lbl in (("ROT-old","predecessor key"),("ROT-new","successor key")):
    r=lb.get(mk)
    if not r or not r.get("last_write"): print(f"  {lbl:18s}: NO MEDIA"); continue
    print(f"  {lbl:18s}: last byte {r['last_write']-t0:+7.3f} s after retirement, {r['bytes']:>10,} B")
PY

echo
echo "################ 5b — per-affiliate mTLS client certificates ################"
echo "  (relay restarted with --server-tls-root; see run log)"

echo
echo "################ 5c — key handling: does the relay hold signing material? ################"
python3 - <<'PY'
import base64, glob, json
def dec(p):
    raw=open(p).read().strip()
    try: return json.loads(raw)
    except json.JSONDecodeError:
        return json.loads(base64.urlsafe_b64decode(raw+'='*(-len(raw)%4)))
m=json.load(open('/tmp/t36/matrix.json'))
bad=[]
print("  every key the authorization endpoint can serve:")
for kid,spec in sorted(m['affiliates'].items()):
    j=dec(spec['key'])
    priv='d' in j
    if priv: bad.append(kid)
    print(f"    {kid:12s} alg={j.get('alg'):6s} key_ops={j.get('key_ops')} private_scalar={priv}")
print()
print(f"  keys carrying signing material: {bad if bad else 'none'}")
PY
echo "  relay command line (what key material it was given):"
ps -o command= -p "$(pgrep -f 'moq-relay --server-bind 127.0.0.1:9443' | head -1)" | tr ' ' '\n' | rg -A1 'auth|tls' | sed 's/^/    /'

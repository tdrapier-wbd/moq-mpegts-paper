#!/bin/bash
# Lay out the T36 estate: two broadcasters, channels that share a stem, and
# per-affiliate credentials. Idempotent.
set -euo pipefail
W=/tmp/t36
M=~/bin-3529/moq
mkdir -p $W/tok $W/keys $W/keydir $W/logs $W/out $W/cap
cd $W
EXP=$(($(date +%s) + 7200))
PAST=$(($(date +%s) - 60))

# ---- publisher tokens (tenant key, publish role) -------------------------
for ch in cnn cnn-intl tnt nobody; do
  $M token sign --key keys/wbd.jwk --root wbd --publish "$ch" --expires $EXP > tok/pub-$ch.jwt
done
$M token sign --key keys/rival.jwk --root rival --publish cnn --expires $EXP > tok/pub-rival-cnn.jwt

# ---- affiliate subscribe tokens ------------------------------------------
# The licensing matrix, fixed here before any arm runs:
#   affa : wbd/cnn
#   affb : wbd/cnn, wbd/tnt
#   affc : wbd/tnt
#   wbd/cnn-intl : licensed by nobody (the shared-stem trap)
#   wbd/nobody   : licensed by nobody (the control channel)
$M token sign --key keys/affa.jwk --root wbd --subscribe cnn                     --expires $EXP > tok/affa.jwt
$M token sign --key keys/affb.jwk --root wbd --subscribe cnn --subscribe tnt     --expires $EXP > tok/affb.jwt
$M token sign --key keys/affc.jwk --root wbd --subscribe tnt                     --expires $EXP > tok/affc.jwt

# ---- arm-specific credentials -------------------------------------------
# A4: expired
$M token sign --key keys/affa.jwk --root wbd --subscribe cnn --expires $PAST > tok/affa-expired.jwt
# A7: subscribe-only token, used to attempt a publish
cp tok/affa.jwt tok/affa-subonly.jwt
# A8: publish-only token, used to attempt a subscribe
$M token sign --key keys/wbd.jwk --root wbd --publish cnn --expires $EXP > tok/pubonly.jwt
# A10: parent-path grant (root wbd, subscribe "" = everything beneath wbd)
$M token sign --key keys/wbd.jwk --root wbd --subscribe "" --expires $EXP > tok/wbd-parent.jwt
# A3: a token minted by the OTHER tenant's key, for its own root
$M token sign --key keys/rival.jwk --root rival --subscribe cnn --expires $EXP > tok/rival-sub.jwt

# A6: malformed variants, derived from a valid token
V=$(cat tok/affa.jwt)
printf '%s' "${V:0:${#V}-12}"        > tok/mal-truncated.jwt      # truncated
printf '%s' "$V" | sed 's/.$/X/'     > tok/mal-badsig.jwt         # last sig char altered
python3 - "$V" > tok/mal-altered.jwt <<'PY'
import base64, json, sys
# Re-encode the payload with a widened grant, keeping the original signature.
tok = sys.argv[1]
h, p, s = tok.split('.')
def d(x): return base64.urlsafe_b64decode(x + '=' * (-len(x) % 4))
def e(b): return base64.urlsafe_b64encode(b).decode().rstrip('=')
claims = json.loads(d(p))
claims['get'] = ['']            # claim everything under the root
sys.stdout.write(f"{h}.{e(json.dumps(claims).encode())}.{s}")
PY

echo "estate laid out:"
echo "  broadcasters : wbd, rival"
echo "  wbd channels : cnn, cnn-intl (shared stem), tnt, nobody (licensed by nobody)"
echo "  affiliates   : affa={cnn}  affb={cnn,tnt}  affc={tnt}"
echo "  tokens       : $(ls tok | wc -l | tr -d ' ') files"

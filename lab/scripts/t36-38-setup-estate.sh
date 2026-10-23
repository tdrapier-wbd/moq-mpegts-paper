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
for ch in ch1 ch1-intl ch2 nobody; do
  $M token sign --key keys/bcast.jwk --root bcast --publish "$ch" --expires $EXP > tok/pub-$ch.jwt
done
$M token sign --key keys/rival.jwk --root rival --publish ch1 --expires $EXP > tok/pub-rival-ch1.jwt

# ---- affiliate subscribe tokens ------------------------------------------
# The licensing matrix, fixed here before any arm runs:
#   affa : bcast/ch1
#   affb : bcast/ch1, bcast/ch2
#   affc : bcast/ch2
#   bcast/ch1-intl : licensed by nobody (the shared-stem trap)
#   bcast/nobody   : licensed by nobody (the control channel)
$M token sign --key keys/affa.jwk --root bcast --subscribe ch1                     --expires $EXP > tok/affa.jwt
$M token sign --key keys/affb.jwk --root bcast --subscribe ch1 --subscribe ch2     --expires $EXP > tok/affb.jwt
$M token sign --key keys/affc.jwk --root bcast --subscribe ch2                     --expires $EXP > tok/affc.jwt

# ---- arm-specific credentials -------------------------------------------
# A4: expired
$M token sign --key keys/affa.jwk --root bcast --subscribe ch1 --expires $PAST > tok/affa-expired.jwt
# A7: subscribe-only token, used to attempt a publish
cp tok/affa.jwt tok/affa-subonly.jwt
# A8: publish-only token, used to attempt a subscribe
$M token sign --key keys/bcast.jwk --root bcast --publish ch1 --expires $EXP > tok/pubonly.jwt
# A10: parent-path grant (root bcast, subscribe "" = everything beneath bcast)
$M token sign --key keys/bcast.jwk --root bcast --subscribe "" --expires $EXP > tok/bcast-parent.jwt
# A3: a token minted by the OTHER tenant's key, for its own root
$M token sign --key keys/rival.jwk --root rival --subscribe ch1 --expires $EXP > tok/rival-sub.jwt

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
echo "  broadcasters : bcast, rival"
echo "  bcast channels : ch1, ch1-intl (shared stem), ch2, nobody (licensed by nobody)"
echo "  affiliates   : affa={ch1}  affb={ch1,ch2}  affc={ch2}"
echo "  tokens       : $(ls tok | wc -l | tr -d ' ') files"

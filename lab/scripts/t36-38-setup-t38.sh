#!/bin/bash
# Sign the estate's affiliate tokens from matrix.json. Each token grants exactly
# the channels its kid licenses, so the token and the endpoint agree at the
# start of every arm and any divergence later is the arm's doing.
set -euo pipefail
W=/tmp/t36
M=~/bin-3529/moq
cd $W
EXP=$(($(date +%s) + 14400))

python3 - "$EXP" <<'PY'
import json, os, subprocess, sys
W = "/tmp/t36"
exp = sys.argv[1]
m = json.load(open(f"{W}/matrix.json"))
priv = {  # kid -> private key file
    "affakey": "affa", "affbkey": "affb", "affckey": "affc",
    "affdkey": "affd", "affecnnkey": "affe-cnn", "affetntkey": "affe-tnt",
    "afffkey": "afff",
}
for kid, spec in m["affiliates"].items():
    if kid not in priv:
        continue
    args = [f"{os.path.expanduser('~')}/bin-3529/moq", "token", "sign",
            "--key", f"{W}/keys/{priv[kid]}.jwk", "--root", "wbd",
            "--expires", exp]
    for ch in spec["licensed"]:
        args += ["--subscribe", ch]
    tok = subprocess.run(args, capture_output=True, text=True, check=True).stdout.strip()
    open(f"{W}/tok/{priv[kid]}.jwt", "w").write(tok)
    print(f"  {kid:12s} ({spec['role']:24s}) -> tok/{priv[kid]}.jwt  grants {spec['licensed']}")
PY
echo "T38 estate tokens signed"

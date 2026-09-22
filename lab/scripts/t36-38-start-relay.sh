#!/bin/bash

# Post-#3793 CLI flags (dual old/new binaries).
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"
# Detached relay launcher for the T36/T37/T38 rig.
# $1 = auth mode: "keydir" (T36) or "api" (T37/T38)
W=/tmp/t36
cd $W || exit 1

MODE="${1:-keydir}"
shift

COMMON=(
  "${RELAY_BIND[@]}" 127.0.0.1:9443
  "${RELAY_TLS[@]}" localhost
  "${RELAY_GSO[@]}"
  --web-http-listen 127.0.0.1:9080
  --log-level info
)

case "$MODE" in
  keydir) AUTH=(--auth-key-dir "$W/keydir") ;;
  api)    AUTH=(--auth-api "http://127.0.0.1:9401/auth") ;;
  mtls)   AUTH=(--auth-api "http://127.0.0.1:9401/auth" --server-tls-root "$W/mtls/ca.pem") ;;
  *) echo "unknown mode $MODE" >&2; exit 1 ;;
esac

exec ~/bin-3529/moq-relay "${COMMON[@]}" "${AUTH[@]}" "$@"

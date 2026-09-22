#!/bin/bash

# Post-#3793 CLI flags (dual old/new binaries).
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"
# Unauthenticated control relay, for T36 criterion 6: the admitted arms must be
# no worse on continuity/PCR than the same path with no authorization at all.
# Same host, same session, same clip, same groomer-free egress.
W=/tmp/t36
cd $W
exec ~/bin-3529/moq-relay \
  "${RELAY_BIND[@]}" 127.0.0.1:9453 \
  "${RELAY_TLS[@]}" localhost \
  "${RELAY_GSO[@]}" \
  "${RELAY_AUTH[@]}" \
  --web-http-listen 127.0.0.1:9090 \
  --log-level info

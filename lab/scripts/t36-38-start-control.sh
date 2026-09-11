#!/bin/bash
# Unauthenticated control relay, for T36 criterion 6: the admitted arms must be
# no worse on continuity/PCR than the same path with no authorization at all.
# Same host, same session, same clip, same groomer-free egress.
W=/tmp/t36
cd $W
exec ~/bin-3529/moq-relay \
  --server-bind 127.0.0.1:9453 \
  --tls-generate localhost \
  --server-quic-gso=false \
  --auth-public "" \
  --web-http-listen 127.0.0.1:9090 \
  --log-level info

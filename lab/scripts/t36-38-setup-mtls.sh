#!/bin/bash
# T38 Part 5: an affiliate PKI — one CA, one client certificate per affiliate.
# Used to test whether a per-affiliate CERTIFICATE can express a per-affiliate
# licensing matrix, as distinct from a per-affiliate JWT.
set -euo pipefail
W=/tmp/t36/mtls
rm -rf $W; mkdir -p $W
cd $W

# CA
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 \
  -subj "/CN=Affiliate PKI Root" >/dev/null 2>&1

client() {
  local name="$1"
  openssl req -newkey rsa:2048 -nodes -keyout $name.key -out $name.csr \
    -subj "/CN=$name" >/dev/null 2>&1
  openssl x509 -req -in $name.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -out $name.pem -days 2 >/dev/null 2>&1
  echo "  client certificate: CN=$name"
}

client affiliate-g
client affiliate-h

echo "CA and two affiliate client certificates written to $W"
openssl x509 -in affiliate-g.pem -noout -subject -issuer | sed 's/^/  /'

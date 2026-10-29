#!/usr/bin/env bash
# T59 offload: N receivers on one pathway at two CloudFront edges, then what that origin served.
#
#   t59-offload.sh [SECONDS] [RX_FETCHERS] [LOCAL_FETCHERS]     defaults 120 3 1
#
# RX_FETCHERS run on the receive host outside the leg namespaces, LOCAL_FETCHERS on the
# workstation, which CloudFront serves from another edge. Each is b8-hls-recv.py writing its TS to
# /dev/null and its log to the run directory. No groomer: offload counts requests, not media.
# Runs no leg; run it between cells. Results in ~/p59-local/offload-<UTC>/.

set -uo pipefail
SECS=${1:-120}
NRX=${2:-3}
NLOCAL=${3:-1}
PA=${PA:-moq-primary}
RX=${RX:-moq-tertiary}
P59_HOME=${P59_HOME:-$HOME/p59-local}
. "$P59_HOME/cf.env"
KEY=$(cat "$P59_HOME/viewer-key")
URL=https://$CF_DOMAIN/a/index.m3u8
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$P59_HOME/offload-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"

from=$(date +%s)
for i in $(seq 1 "$NRX"); do
	ssh -o BatchMode=yes "$RX" "python3 ~/p59/b8-hls-recv.py '$URL' /dev/null --seconds $SECS \
		--header 'X-P59-Key: $KEY' --log /tmp/offload-rx$i.jsonl >/dev/null 2>&1" &
done
for i in $(seq 1 "$NLOCAL"); do
	python3 "$HERE/b8-hls-recv.py" "$URL" /dev/null --seconds "$SECS" \
		--header "X-P59-Key: $KEY" --log "$OUT/local$i.jsonl" >/dev/null 2>&1 &
done
wait
to=$(date +%s)

for i in $(seq 1 "$NRX"); do
	scp -q "$RX:/tmp/offload-rx$i.jsonl" "$OUT/rx$i.jsonl" && ssh -o BatchMode=yes "$RX" "rm -f /tmp/offload-rx$i.jsonl"
done
scp -q "$PA:p59/ngx/access.log" "$OUT/origin-a-access.log"
# The first 20 s are the receivers' joins, which fetch the listed backlog at once.
python3 "$HERE/t59-offload.py" "$OUT/origin-a-access.log" $((from + 20)) "$to" "$OUT"/*.jsonl | tee "$OUT/offload.txt"

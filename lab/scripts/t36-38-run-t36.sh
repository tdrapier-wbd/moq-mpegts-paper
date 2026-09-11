#!/bin/bash
# T36 arm matrix. Each arm runs through its own self-terminating wiretap so the
# wire-level byte volume and the TS-structure scan are attributable per arm.
W=/tmp/t36
cd $W
FP=$(cat $W/fp.txt)
SECS="${SECS:-6}"
TAP=/Users/tdrapier/moq-mpegts-paper/lab/scripts/t36-wiretap.py
TAPPORT=9500
RESULTS=$W/results-t36.tsv
: > $RESULTS
: > $W/wiretap.jsonl

run_arm() {  # run_arm <id> <path> <broadcast> <tokenfile|none> <role> <expect>
  local ID="$1" PTH="$2" BC="$3" TOK="$4" ROLE="$5" EXPECT="$6"
  local port=$TAPPORT
  TAPPORT=$((TAPPORT+1))

  python3 "$TAP" --listen $port --forward 9443 --log $W/wiretap.jsonl \
      --mark "$ID" --seconds $((SECS+2)) > $W/logs/tap-$ID.log 2>&1 &
  local tap=$!
  sleep 0.5

  local URL
  if [ "$TOK" = "none" ]; then URL="https://127.0.0.1:$port/${PTH}"
  else URL="https://127.0.0.1:$port/${PTH}?jwt=$(cat $W/tok/$TOK)"; fi

  local RC
  if [ "$ROLE" = "pub" ]; then
    timeout "$SECS" bash -c "tsp -I file $W/clip.ts -P regulate -O file 2>/dev/null | \
      ~/bin-3529/moq --client-connect '$URL' --client-tls-fingerprint '$FP' \
      import --broadcast '$BC' ts" > $W/out/$ID.bin 2> $W/logs/$ID.log
    RC=$?
  else
    timeout "$SECS" ~/bin-3529/moq --client-connect "$URL" --client-tls-fingerprint "$FP" \
      export --broadcast "$BC" ts > $W/out/$ID.bin 2> $W/logs/$ID.log
    RC=$?
  fi

  wait $tap 2>/dev/null
  local BYTES=$(stat -f%z $W/out/$ID.bin 2>/dev/null || echo 0)
  local OUTCOME="refused"; [ "$BYTES" -gt 0 ] && OUTCOME="admitted"
  local S2C=$(python3 -c "
import json,sys
for l in open('$W/wiretap.jsonl'):
    r=json.loads(l)
    if r.get('mark')=='$ID': print(r['s2c_bytes'], r['s2c_datagrams'], r['ts_structure_hits'], r['largest_s2c']); break
else: print('NA NA NA NA')")
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$ID" "$PTH/$BC" "$TOK" "$ROLE" "$EXPECT" "$OUTCOME" "$BYTES" "$S2C" >> $RESULTS
  printf "  %-5s %-15s %-19s %-4s exp=%-9s got=%-9s payload=%-9s wire_s2c=%s\n" \
      "$ID" "$PTH/$BC" "$TOK" "$ROLE" "$EXPECT" "$OUTCOME" "$BYTES" "$(echo $S2C | awk '{print $1"B/"$2"dg"}')"
}

echo "T36 arm matrix — payload measured at the subscriber's OWN OUTPUT (decrypted);"
echo "wire_s2c is the wiretap's server->client volume (ciphertext, corroboration only)."
echo
run_arm A1   wbd   cnn      affa.jwt           sub admitted
run_arm A2   wbd   tnt      affa.jwt           sub refused
run_arm A3   rival cnn      affa.jwt           sub refused
run_arm A4   wbd   cnn      affa-expired.jwt   sub refused
run_arm A5   wbd   cnn      none               sub refused
run_arm A6a  wbd   cnn      mal-truncated.jwt  sub refused
run_arm A6b  wbd   cnn      mal-badsig.jwt     sub refused
run_arm A6c  wbd   cnn      mal-altered.jwt    sub refused
run_arm A7   wbd   cnn      affa-subonly.jwt   pub refused
run_arm A8   wbd   cnn      pubonly.jwt        sub refused
run_arm A9   wbd   cnn-intl affa.jwt           sub refused
run_arm A10  wbd   cnn      wbd-parent.jwt     sub admitted
echo
echo "results -> $RESULTS"

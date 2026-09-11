#!/bin/bash
W=/tmp/t36
cd $W
CFP=$(cat $W/cfp.txt)
exec tsp -I file $W/clip.ts --infinite -P regulate -O file 2>/dev/null \
  | ~/bin-3529/moq --client-connect "https://127.0.0.1:9453/wbd" \
      --client-tls-fingerprint "$CFP" import --broadcast cnn ts

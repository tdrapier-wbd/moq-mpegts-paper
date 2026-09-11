#!/bin/bash
# Bring up every channel in the estate as a live, paced publisher.
W=/tmp/t36
FP=$(cat $W/fp.txt)
cd $W

pub() {  # pub <root> <channel> <tokenfile>
  local root="$1" ch="$2" tok="$3"
  tsp -I file $W/clip.ts --infinite -P regulate -O file 2>/dev/null \
    | ~/bin-3529/moq \
        --client-connect "https://127.0.0.1:9443/${root}?jwt=$(cat $W/tok/$tok)" \
        --client-tls-fingerprint "$FP" \
        import --broadcast "$ch" ts \
    > $W/logs/pub-$root-$ch.log 2>&1 &
  echo "  publishing $root/$ch (pid $!)"
}

pub wbd   cnn      pub-cnn.jwt
pub wbd   cnn-intl pub-cnn-intl.jwt
pub wbd   tnt      pub-tnt.jwt
pub wbd   nobody   pub-nobody.jwt
pub rival cnn      pub-rival-cnn.jwt

echo "all publishers started"
wait

#!/bin/bash

# Post-#3793 CLI flags (dual old/new binaries).
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"
# Bring up every channel in the estate as a live, paced publisher.
W=/tmp/t36
FP=$(cat $W/fp.txt)
cd $W

pub() {  # pub <root> <channel> <tokenfile>
  local root="$1" ch="$2" tok="$3"
  tsp -I file $W/clip.ts --infinite -P regulate -O file 2>/dev/null \
    | ~/bin-3529/moq \
        "${MOQ_DIAL[1]}" "https://127.0.0.1:9443/${root}?jwt=$(cat $W/tok/$tok)" \
        "${MOQ_FP[@]}" "$FP" \
        import --broadcast "$ch" ts \
    > $W/logs/pub-$root-$ch.log 2>&1 &
  echo "  publishing $root/$ch (pid $!)"
}

pub bcast   ch1      pub-ch1.jwt
pub bcast   ch1-intl pub-ch1-intl.jwt
pub bcast   ch2      pub-ch2.jwt
pub bcast   nobody   pub-nobody.jwt
pub rival ch1      pub-rival-ch1.jwt

echo "all publishers started"
wait

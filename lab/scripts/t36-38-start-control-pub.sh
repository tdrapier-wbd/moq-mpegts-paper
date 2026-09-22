#!/bin/bash

# Post-#3793 CLI flags (dual old/new binaries).
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"
W=/tmp/t36
cd $W
CFP=$(cat $W/cfp.txt)
exec tsp -I file $W/clip.ts --infinite -P regulate -O file 2>/dev/null \
  | ~/bin-3529/moq "${MOQ_DIAL[1]}" "https://127.0.0.1:9453/wbd" \
      "${MOQ_FP[@]}" "$CFP" import --broadcast cnn ts

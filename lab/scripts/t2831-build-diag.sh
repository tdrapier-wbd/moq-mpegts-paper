#!/usr/bin/env bash
# Build the diagnostic relays that t2831-attrib.sh's `qlog-quinn`, `pthresh` and `thresh` phases need,
# one after another in one build tree so they share its target directory, and return the tree to the
# commit it was on. Each lands beside its build's release `moq`:
#
#   qlog-quinn    $HOME/bin-5d0991b9-qlog    `5d0991b9`'s relay on quinn, with qlog
#   thresh-noq    $HOME/bin-ffa5b81b-thresh  `ffa5b81b`'s relay on noq, with qlog and
#                                            t2831-loss-thresholds-noq.patch
#   thresh-quinn  $HOME/bin-5d0991b9-thresh  `5d0991b9`'s relay on quinn, with qlog and
#                                            t2831-loss-thresholds-quinn.patch
#
# The patches set the stack's loss-detection thresholds from MOQ_LAB_PACKET_THRESHOLD (packets, 3 by
# default) and MOQ_LAB_TIME_THRESHOLD (a multiple of the RTT, 9/8 by default), leaving either at its
# default when unset. They are a lab instrument, not a proposed change.
#
# Usage: t2831-build-diag.sh [target...]     (default: all three; SRC the build tree, default ~/moq-main)
set -euo pipefail
SRC=${SRC:-$HOME/moq-main}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
cd "$SRC"
back=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
trap 'git checkout -q -- . && git checkout -q "$back"' EXIT

relay() { # <sha> <features> <dest> <release bin dir for moq> [patch]
	git checkout -q -- .
	git checkout -q "$1"
	[ -n "${5:-}" ] && git apply "$HERE/$5"
	nice -n 19 cargo build --release -q -p moq-relay --bin moq-relay --no-default-features --features "$2"
	mkdir -p "$3"
	cp target/release/moq-relay "$3/"
	cp "$4/moq" "$3/"
	echo "built $3 at $(git rev-parse --short=9 HEAD) with $2${5:+ and $5}"
}

for target in ${*:-qlog-quinn thresh-noq thresh-quinn}; do
	case "$target" in
	qlog-quinn) relay 5d0991b9 quinn,websocket,uds,qlog "$HOME/bin-5d0991b9-qlog" "$HOME/bin-5d0991b9" ;;
	thresh-noq)
		relay ffa5b81b noq,websocket,uds,qlog "$HOME/bin-ffa5b81b-thresh" "$HOME/bin-ffa5b81b" \
			t2831-loss-thresholds-noq.patch
		;;
	thresh-quinn)
		relay 5d0991b9 quinn,websocket,uds,qlog "$HOME/bin-5d0991b9-thresh" "$HOME/bin-5d0991b9" \
			t2831-loss-thresholds-quinn.patch
		;;
	*) echo "unknown target $target"; exit 1 ;;
	esac
done

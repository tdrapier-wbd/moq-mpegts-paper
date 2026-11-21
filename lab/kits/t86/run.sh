#!/usr/bin/env bash
# Run one cell of the T86 kit on one implementation's pair, on loopback.
# usage: run.sh <fixtures-dir> <out-dir> <cell> <A|M>
#   cell r  conformance: base.ts and live.ts, received whole                  (T86 P2-r)
#        s  PCR events: s-A … s-F and the two unflagged switches              (P2-s)
#        t  restarts: the publisher, relay or receiver killed 60 s in; loop.ts (P2-t)
#        u  loss: 0, 1 and 3 % on the receiver's hop, 15 ms delay              (P2-u)
#        v  three programmes, the multiplex whole (U) and per programme (P)    (P2-v)
#        w  the live-feed shape: live.ts and live-splice.ts at 25 Mb/s         (P2-w)
#   arm  A  moq2ts-cli -> moq-relay -> moq2ts-receiver, MoQT draft 22
#        M  moq import ts -> moq-relay -> moq export ts, moq-lite-07
# Each sub-run writes <out-dir>/<cell>-<arm>/<name>/; grade them with grade.sh. Both arms need a
# moq-relay; the rigs live in ../../scripts.
# env: MOQ (directory holding moq and moq-relay), CLI (moq2ts-cli), RECV (moq2ts-receiver),
#      PORT (first UDP port, default 5100; each sub-run takes two)
set -u
FX=$(cd "${1:?usage: run.sh <fixtures-dir> <out-dir> <cell> <A|M>}" && pwd)
OUT=${2:?} CELL=${3:?} ARM=${4:?}
LAB=$(cd "$(dirname "$0")/../../scripts" && pwd)
export MOQ=${MOQ:?set MOQ} CLI=${CLI:?set CLI} RECV=${RECV:?set RECV}
port=${PORT:-5100}
dir="$OUT/$CELL-$ARM"
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)

# 250 ms of a stream, in whole packets: moq2ts-cli's object size
seg() { echo $(($1 / 8 / 4 / 188 * 188)); }

# loss <name> <clip> <b/s> [VAR=value ...]: one t86-loss.sh run, at the clip's constant bit rate
loss() {
	local name=$1 clip=$2 rate=$3
	shift 3
	echo "$(date -u +%T) $CELL-$ARM $name"
	env CLIP="$FX/$clip" RATE="$rate" REGULATE="--bitrate $rate" SEG="$(seg "$rate")" PORT="$port" \
		LOSS=0 DELAY_MS=0 "$@" bash "$LAB/t86-loss.sh" "$dir/$name" "$ARM" >/dev/null 2>&1
	port=$((port + 2))
}

case $CELL in
r)
	loss base base.ts 9945951
	loss live live.ts 25000000
	;;
s)
	for x in A B C D E F; do loss "$x" "s-$x.ts" 9945951; done
	loss switch-back switch-back.ts 6000000
	loss switch-forward switch-forward.ts 6000000
	;;
t)
	for kill in none pub relay recv; do
		echo "$(date -u +%T) $CELL-$ARM $kill"
		CLIP="$FX/base.ts" PORT=$port UDP=$((port + 500)) bash "$LAB/t86-restart.sh" "$dir/$kill" "$ARM" "$kill" \
			>/dev/null 2>&1
		port=$((port + 2))
	done
	echo "$(date -u +%T) $CELL-$ARM loop"
	CLIP="$FX/loop.ts" PORT=$port UDP=$((port + 500)) bash "$LAB/t86-restart.sh" "$dir/loop" "$ARM" none \
		>/dev/null 2>&1
	;;
u)
	tsp -I file "$FX/base.ts" -P until --packets $((9945951 * 60 / 8 / 188)) -O file "$dir/cut60.ts" 2>/dev/null
	for l in 0 1 3; do
		echo "$(date -u +%T) $CELL-$ARM loss $l"
		CLIP="$dir/cut60.ts" LOSS=$l PORT=$port bash "$LAB/t86-loss.sh" "$dir/L$l" "$ARM" >/dev/null 2>&1
		port=$((port + 2))
	done
	;;
v)
	for f in mpts3 mpts3-cc; do
		for c in U P; do
			echo "$(date -u +%T) $CELL-$ARM $f $c"
			CLIP="$FX/$f.ts" PORT=$port bash "$LAB/t86-mpts.sh" "$dir/$f-$c" "$ARM" "$c" >/dev/null 2>&1
			port=$((port + 2))
		done
	done
	;;
w)
	loss live live.ts 25000000
	loss splice live-splice.ts 25000000
	;;
*)
	echo "run.sh: unknown cell $CELL" >&2
	exit 2
	;;
esac
echo "$(date -u +%T) $CELL-$ARM done: $dir"

#!/usr/bin/env bash
# T78's ramp from the laptop (lab/test-78-*.md): t78-edge-load.py on the tertiary against the
# secondary's pathway origin, one step per N, with a 5 s sampler on the origin across the ramp.
#
#   t78-drive.sh "4 16 64 128" [SECONDS] [GAP]
#
# Writes ~/p59-local/t78/<run>/: step-N.json (the load's summary), origin.tsv (t78-sample.sh: unix
# time, nginx, segmenter and guard CPU ticks, host idle and total ticks, ens5 tx bytes),
# seg-tail.log (the segmenter's events over the ramp) and steps.tsv (each step's start and end).
# Stops before the next step if the host's CPU passed 75 % or the segmenter reset.
set -uo pipefail
STEPS=${1:?usage: t78-drive.sh "N1 N2 ..." [SECONDS] [GAP]}
SECS=${2:-120}
GAP=${3:-30}
ORIGIN=${ORIGIN:-moq-secondary}
LOAD=${LOAD:-moq-tertiary}
H=$(cd "$(dirname "$0")" && pwd)
OUT=$HOME/p59-local/t78/$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"
T=/opt/homebrew/bin/timeout
oip=$($T 30 ssh -n -o BatchMode=yes "$ORIGIN" "hostname -I | cut -d' ' -f1")
URL=http://$oip:18310/g/index.m3u8
$T 60 scp -q "$H/t78-edge-load.py" "$LOAD:p59/"
$T 60 scp -q "$H/t78-sample.sh" "$ORIGIN:p59/"
# shellcheck disable=SC2016 # expanded on the origin
$T 30 ssh -n -o BatchMode=yes "$ORIGIN" 'cd ~/p59; rm -f t78-origin.tsv; nohup setsid bash t78-sample.sh ~/p59/t78-origin.tsv > /dev/null 2>&1 < /dev/null & echo $! > t78-sampler.pid'
t_start=$(date +%s)
: >"$OUT/steps.tsv"
for n in $STEPS; do
	a=$(date +%s)
	echo "$(date -u +%T) step $n edges, ${SECS}s"
	$T $((SECS + 60)) ssh -n -o BatchMode=yes "$LOAD" \
		"python3 ~/p59/t78-edge-load.py '$URL' --edges $n --seconds $SECS --header X-P59-Origin:/home/ubuntu/p59/origin-secret" \
		>"$OUT/step-$n.json"
	b=$(date +%s)
	printf "%s\t%s\t%s\n" "$n" "$a" "$b" >>"$OUT/steps.tsv"
	jq -c '{edges, gbps, seg: .segment.total_ms, pl_ttfb: .playlist.ttfb_ms, errors}' "$OUT/step-$n.json"
	busy=$($T 30 ssh -n -o BatchMode=yes "$ORIGIN" "awk -v a=$a -v b=$b '\$1>=a && \$1<=b {if (!n++) {i0=\$5; t0=\$6} i1=\$5; t1=\$6} END {if (t1>t0) printf \"%.0f\", 100*(1-(i1-i0)/(t1-t0))}' ~/p59/t78-origin.tsv")
	resets=$($T 30 ssh -n -o BatchMode=yes "$ORIGIN" "awk -v a=$a '\$1>=a && / reset /' ~/p59/seg.log | wc -l")
	echo "  host cpu ${busy:-?} %, segmenter resets $resets"
	if [ "${busy:-0}" -gt 75 ] || [ "$resets" -gt 0 ]; then
		echo "stop rule: host cpu ${busy} %, resets $resets"
		break
	fi
	sleep "$GAP"
done
# shellcheck disable=SC2016 # expanded on the origin
$T 30 ssh -n -o BatchMode=yes "$ORIGIN" 'kill "$(cat ~/p59/t78-sampler.pid)"'
$T 60 scp -q "$ORIGIN:p59/t78-origin.tsv" "$OUT/origin.tsv"
$T 30 ssh -n -o BatchMode=yes "$ORIGIN" "awk -v a=$t_start '\$1>=a' ~/p59/seg.log" >"$OUT/seg-tail.log"
echo "results in $OUT"

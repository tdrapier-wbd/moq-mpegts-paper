#!/bin/bash
# T38 Part 4 — what entitlement costs the scaling model. Second rig.
#
# The first rig sampled `ps -o %cpu`, which on Darwin is a decaying average over
# up to a minute of real time. With a 12 s dwell per ladder step that average
# had not settled before the step ended, so each reading carried the previous
# step's load: the N=0 point read higher than N=5 in two of three arms. Those
# figures were discarded.
#
# This rig reads the process's CUMULATIVE cpu time either side of the dwell and
# divides by the wall interval, which is a true average over exactly the window
# of interest and needs no settling. RSS gets an idle settle period before each
# arm, because the relay holds the previous arm's peak for some seconds after
# teardown.
#
# Four arms: two re-check cadences from T37's sweep, an authenticated arm with
# no revalidation at all, and an UNAUTHENTICATED control on a second relay on
# the same host -- the only comparison that isolates authorization, since T26's
# baseline was measured on different hardware.
W=/tmp/t36
cd $W
FP=$(cat $W/fp.txt)
FPC=$(cat $W/fp-control.txt)
LADDER="${LADDER:-0 5 10 15 20}"
DWELL="${DWELL:-15}"
SETTLE="${SETTLE:-25}"
OUT=$W/cost2.tsv
: > $OUT

cputime_s() {
	ps -o cputime= -p "$1" 2>/dev/null | awk -F: '{ gsub(/ /,""); printf "%.2f", ($1*60)+$2 }'
}
rss_kb() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }

run_ladder() {
	local lbl="$1" cad="$2" rp port fp tok
	case "$cad" in
	unauth)
		port=9453
		fp=$FPC
		tok=""
		;;
	none)
		port=9443
		fp=$FP
		tok="?jwt=$(cat $W/tok/affa.jwt)"
		python3 $W/mkstate2.py --cache-control "" --mark "cost $lbl" >/dev/null
		;;
	*)
		port=9443
		fp=$FP
		tok="?jwt=$(cat $W/tok/affa.jwt)"
		python3 $W/mkstate2.py --cache-control "max-age=$cad" --mark "cost $lbl" >/dev/null
		;;
	esac
	rp=$(pgrep -f "moq-relay --server-bind 127.0.0.1:$port" | head -1)
	[ -z "$rp" ] && {
		echo "  $lbl: no relay on $port, skipped"
		return
	}

	sleep "$SETTLE"
	for n in $LADDER; do
		local pids=()
		for i in $(seq 1 "$n"); do
			timeout $((DWELL + 6)) ~/bin-3529/moq --backoff-timeout 100ms \
				--client-connect "https://127.0.0.1:$port/wbd$tok" \
				--client-tls-fingerprint "$fp" export --broadcast cnn ts \
				>/dev/null 2>/dev/null &
			pids+=($!)
		done
		sleep 4
		local t0 w0 t1 w1 r
		t0=$(cputime_s "$rp")
		w0=$(date +%s)
		sleep "$DWELL"
		t1=$(cputime_s "$rp")
		w1=$(date +%s)
		r=$(rss_kb "$rp")
		printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$lbl" "$n" "$t0" "$t1" "$((w1 - w0))" "$r" >>"$OUT"
		for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
		wait 2>/dev/null
		echo "  $lbl N=$n  cpu_s=$(echo "$t1 $t0" | awk '{printf "%.2f", $1-$2}')  rss=${r}KB"
		sleep 6
	done
}

echo "T38 cost ladder (rig 2): N = $LADDER, ${DWELL}s timed dwell"
run_ladder "unauth" unauth
run_ladder "no-recheck" none
run_ladder "cadence-10" 10
run_ladder "cadence-1" 1
echo "cost -> $OUT"

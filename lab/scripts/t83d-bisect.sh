#!/usr/bin/env bash
# T83 Part D's relay bisect on the real path, unattended, from the build host. Each step builds the
# relay at the bisect's commit, copies it to the publishing host beside the fixed client, starts
# `t83d-skip.sh`'s src role there, and posts the job on a board (`t83d-jobsrv.py`) that the receiving
# host's `t83d-bisect-rcv.sh` reads; the receiver uploads the eviction grade.
#
# Judge (T83 Part D, fixed before running): one run of BURSTS x REPS; bad at BAD_AT or more burst
# windows with an eviction, good at GOOD_AT or fewer; between, a second run decides at half the
# windows of both, flagged weak. Both endpoints run first; the bisect stops unless they separate.
# A binary identical to one judged takes its verdict; a commit that does not build is skipped.
#
#   SRC=<publishing host, private> RCV_IP=<receiver's public address> KEY=<ssh key to SRC> \
#     GOOD=<sha> BAD=<sha> GOOD_BIN=<relay> BAD_BIN=<relay> CLIENT=<moq dir on SRC> \
#     PATHS="<pathspec>" t83d-bisect.sh <work dir>
#
# Env: REPO (~/work/moq), ENV_SH (~/work/env.sh), BOARD_PORT (18490), DELAYS (5822ms),
#      BURSTS ("3 4"), REPS (4), CONTROL (30), GAP (25, the rig's), BAD_AT (5), GOOD_AT (1),
#      HALT (1: at the end, stop this host unless KEEP exists), KEEP (~/keep-running), MAX_STEPS (30),
#      AB_RUNS (0; N: no bisect, N judge runs alternating the endpoints BAD, GOOD, GOOD, BAD, ...).
# Builds `moq` beside the relay, as the endpoints were built, so features unify alike.
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
W=${1:?work dir}
SRC=${SRC:?publishing host}
RCV_IP=${RCV_IP:?receiver address}
KEY=${KEY:?ssh key}
GOOD=${GOOD:?good sha}
BAD=${BAD:?bad sha}
GOOD_BIN=${GOOD_BIN:?good relay}
BAD_BIN=${BAD_BIN:?bad relay}
CLIENT=${CLIENT:?moq dir on SRC}
read -ra PATHSPEC <<<"${PATHS:?pathspec}"
REPO=${REPO:-$HOME/work/moq}
ENV_SH=${ENV_SH:-$HOME/work/env.sh}
BOARD_PORT=${BOARD_PORT:-18490}
DELAYS=${DELAYS:-5822ms}
read -ra BURSTS <<<"${BURSTS:-3 4}"
REPS=${REPS:-4}
CONTROL=${CONTROL:-30}
GAP=${GAP:-25}
BAD_AT=${BAD_AT:-5}
GOOD_AT=${GOOD_AT:-1}
HALT=${HALT:-1}
KEEP=${KEEP:-$HOME/keep-running}
MAX_STEPS=${MAX_STEPS:-30}
AB_RUNS=${AB_RUNS:-0}
WINDOWS=$((${#BURSTS[@]} * REPS))
SECS=$((10 + CONTROL + WINDOWS * GAP + 10))
TREE=$W/tree
LOG=$W/bisect.log
SSH=(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 "ubuntu@$SRC")
declare -A SEEN

log() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }

mkdir -p "$W/www/result" "$W/relays"
python3 "$H/t83d-jobsrv.py" "$W/www" "$BOARD_PORT" >"$W/jobsrv.log" 2>&1 &
SRV=$!

finish() {
	echo "done" >"$W/www/job"
	git -C "$TREE" bisect log >"$W/bisect-log.txt" 2>/dev/null
	log "finished; the receiver reads done within its poll"
	sleep 40
	kill "$SRV" 2>/dev/null
	"${SSH[@]}" 'tmux ls -F "#S" 2>/dev/null | grep "^bs-" | xargs -rn1 tmux kill-session -t; rm -rf ~/bin-bisect; mkdir -p ~/t83d-bisect' </dev/null
	tar -C "$W" -cf - bisect.log bisect-log.txt www/result build-logs 2>/dev/null |
		"${SSH[@]}" 'tar -C ~/t83d-bisect -xf -'
	"${SSH[@]}" "sed -i '/t83-bisect-temp/d' ~/.ssh/authorized_keys" </dev/null
	rm -rf "$W/target"
	git -C "$TREE" bisect reset >/dev/null 2>&1
	git -C "$REPO" worktree remove --force "$TREE" 2>/dev/null
	if [ "$HALT" = 1 ] && [ ! -e "$KEEP" ]; then
		log "halting"
		sudo shutdown -h +1
	fi
}
trap finish EXIT

# judge <label> <relay>: one run; prints the burst windows with an eviction, or "err"
judge() {
	local label=$1 relay=$2 t0 res
	"${SSH[@]}" "for i in \$(seq 60); do tmux ls 2>/dev/null | grep -q '^bs-' || break; sleep 2; done
		mkdir -p ~/bin-bisect/$label && ln -sf $CLIENT/moq ~/bin-bisect/$label/moq" </dev/null >/dev/null || {
		echo err
		return
	}
	scp -i "$KEY" -o BatchMode=yes -q "$relay" "ubuntu@$SRC:bin-bisect/$label/moq-relay" || {
		echo err
		return
	}
	t0=$(($(date +%s) + 60))
	"${SSH[@]}" "cd ~/t83d && tmux new-session -d -s bs-$label 'QLOG= DELAYS=$DELAYS BURSTS=\"${BURSTS[*]}\" \
		REPS=$REPS CONTROL=$CONTROL OUT=\$HOME/t83d/bisect T0=$t0 ROLE=src PEER=$RCV_IP \
		BIN=\$HOME/bin-bisect/$label bash scripts/t83d-skip.sh $label > \$HOME/t83d/bisect-$label.log 2>&1'" </dev/null >/dev/null || {
		echo err
		return
	}
	local IFS=,
	echo "$label $t0 $DELAYS ${BURSTS[*]} $REPS $CONTROL" >"$W/www/job"
	unset IFS
	res=$W/www/result/$label.txt
	while [ ! -s "$res" ] && [ "$(date +%s)" -lt $((t0 + SECS + 300)) ]; do sleep 10; done
	if [ ! -s "$res" ]; then
		log "$label: no result"
		echo err
		return
	fi
	log "$label: $(head -1 "$res")"
	head -1 "$res" | tr ' ' '\n' | grep -cE '^[0-9.]+/[0-9]+:'
}

# verdict <label> <relay>: good, bad or err, by the judge
verdict() {
	local label=$1 relay=$2 a b
	a=$(judge "$label-a" "$relay")
	[ "$a" = err ] && a=$(judge "$label-r" "$relay")
	[ "$a" = err ] && {
		echo err
		return
	}
	if [ "$a" -ge "$BAD_AT" ]; then
		echo bad
	elif [ "$a" -le "$GOOD_AT" ]; then
		echo good
	else
		b=$(judge "$label-b" "$relay")
		[ "$b" = err ] && {
			echo err
			return
		}
		log "$label: weak, $((a + b)) of $((2 * WINDOWS))"
		if [ $((a + b)) -ge "$WINDOWS" ]; then echo bad; else echo good; fi
	fi
}

log "start: $GOOD..$BAD, judge ${BURSTS[*]} s x $REPS, bad >= $BAD_AT, good <= $GOOD_AT of $WINDOWS"
if [ "$AB_RUNS" -gt 0 ]; then
	log "replication: $AB_RUNS runs alternating BAD_BIN and GOOD_BIN, ABBA"
	for ((i = 1; i <= AB_RUNS; i++)); do
		case $((i % 4)) in 1 | 0) e=bad r=$BAD_BIN ;; *) e=good r=$GOOD_BIN ;; esac
		log "ab$i-$e: $(judge "ab$i-$e" "$r") of $WINDOWS"
	done
	exit 0
fi
for e in bad good; do
	if [ $e = bad ]; then r=$BAD_BIN; else r=$GOOD_BIN; fi
	v=$(verdict "ep-$e" "$r")
	log "endpoint $e: $v"
	if [ "$v" != $e ]; then
		log "endpoints do not separate on this judge: stop"
		exit 1
	fi
	SEEN[$(sha256sum "$r" | cut -c1-64)]=$v
done

mkdir -p "$W/build-logs"
git -C "$REPO" fetch -q origin main
git -C "$REPO" worktree add -q --detach "$TREE" "$BAD" || exit 1
cd "$TREE" || exit 1
git bisect start "$BAD" "$GOOD" -- "${PATHSPEC[@]}" >"$W/step.txt" 2>&1
cat "$W/step.txt" >>"$LOG"
step=0
until grep -qE "is the first bad commit|only .skip.ped commits left" "$W/step.txt"; do
	step=$((step + 1))
	if [ "$step" -gt "$MAX_STEPS" ]; then
		log "over $MAX_STEPS steps: stop"
		break
	fi
	c=$(git rev-parse HEAD)
	s8=${c:0:8}
	log "step $step: $s8 $(git log -1 --format=%s | cut -c1-90)"
	if (
		# shellcheck source=/dev/null
		. "$ENV_SH"
		CARGO_TARGET_DIR=$W/target nice -n 10 cargo build --release --bin moq --bin moq-relay
	) >"$W/build-logs/$s8.log" 2>&1; then
		cp "$W/target/release/moq-relay" "$W/relays/$s8"
		h=$(sha256sum "$W/relays/$s8" | cut -c1-64)
		if [ -n "${SEEN[$h]:-}" ]; then
			v=${SEEN[$h]}
			log "step $step: binary already judged, $v"
		else
			v=$(verdict "s$step-$s8" "$W/relays/$s8")
			[ "$v" = err ] || SEEN[$h]=$v
		fi
	else
		v=err
		log "step $step: build failed"
	fi
	log "step $step: $v"
	case $v in
	good | bad) git bisect "$v" >"$W/step.txt" 2>&1 ;;
	*) git bisect skip >"$W/step.txt" 2>&1 ;;
	esac
	head -1 "$W/step.txt" >>"$LOG"
done
cat "$W/step.txt" >>"$LOG"
log "bisect ended"

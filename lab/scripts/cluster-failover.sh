#!/usr/bin/env bash
# cluster-failover.sh — 1+1 source failover across a two-relay moq-relay mesh, on whichever CLI
# surface the build has. Every process is tracked by PID, never by name, so a standing relay or
# another rig on the same host is untouched.
#
#     pubA ──▶ relayA ◀──cluster── relayB ◀── pubB (joins at JOIN s)
#               ▲   ▲                ▲
#             sub1 sub2            sub3   (sub3 makes relayB carry pubA's broadcast through relayA)
#
# One live source feeds both publishers: `tsp … -P regulate --pcr-synchronous -P fork` sends the
# same stream to UDP FEED and FEED+1, and each publisher is `tsp -I ip <port> | moq import ts`. The
# standby therefore joins the active's media clock mid-stream rather than replaying a file from its
# start. relayB dials relayA (DIAL=both makes relayA dial relayB as well).
#
# Timeline, in seconds from the moment the subscribers attach (t=0 of sizes.csv):
#   JOIN   pubB connects to relayB, which is already carrying pubA's broadcast for sub3.
#   EVENT  pubA's source ends. EVENT=kill SIGKILLs its whole tsp | moq pipeline in one pass, which
#          sends no CONNECTION_CLOSE, so relayA learns of it only at the idle timeout. EVENT=eof
#          TERMs only its `tsp -I ip` reader, so the importer reads end of input and finishes the
#          broadcast cleanly. `moq` handles only SIGINT, so a SIGTERM to it is a hard kill and must
#          not stand in for a graceful exit.
#   END    EVENT + IDLE + 5 + OBS, so the window runs OBS seconds past CHECK 1's deadline.
#
# Graded, and printed as one RESULT line:
#   CHECK 1 (EVENT=kill)  sub1 on relayA resumes within IDLE + 5 s of the kill and is still alive and
#                         writing over the last 5 s of the window.
#   CHECK 2               sub3 on relayB survives pubB's arrival: its exporter is alive at EVENT and
#                         wrote in the 5 s before it, with no `Error:` line by then.
#   CHECK 3 (EVENT=eof)   no pass/fail: sub1 `failed-over` (alive and writing at the end),
#                         `terminated` (exporter exited) or `frozen` (alive, writing nothing).
#
# Env: HOP  one hop id for both publishers (`--hop`, or `--origin` on builds that predate it),
#           which declares them interchangeable. Default 424242; HOP= (empty) lets each mint its own.
#      SIDLE  the relays' QUIC idle timeout, e.g. 6s; QUIC uses the smaller of the two sides' values,
#           so it also bounds detection of a dead publisher. Unset = the build's default (30 s).
#           When set, the relays' keep-alive drops to 2 s, which must stay below it.
#      PORT_A / PORT_B (4480 / 5480), FEED (PORT_B + 1), JOIN (10), EVENT_AT (JOIN + 12), OBS (20),
#      RLOG (relay log filter, default info,moq_net::model=debug), KEEP_TS (0 deletes the captures
#      after grading and keeps their sizes in sizes.csv).
#
# Usage: cluster-failover.sh <bin-dir> <outdir>                    (SRC the source clip)
#   HOP=424242 SIDLE=6s EVENT=kill cluster-failover.sh ~/bin-<sha> out/shared-kill-r1
#   HOP=       SIDLE=6s EVENT=eof  cluster-failover.sh ~/bin-<sha> out/fresh-eof-r1
set -uo pipefail
BIN=${1:?bin dir with moq and moq-relay}
OUT=${2:?output directory}
SRC=${SRC:-$HOME/CNNiEMEA2.ts}
PORT_A=${PORT_A:-4480}
PORT_B=${PORT_B:-5480}
FEED=${FEED:-$((PORT_B + 1))}
HOP=${HOP-424242}
SIDLE=${SIDLE:-}
EVENT=${EVENT:-kill}
DIAL=${DIAL:-b}
JOIN=${JOIN:-10}
EVENT_AT=${EVENT_AT:-$((JOIN + 12))}
OBS=${OBS:-20}
KEEP_TS=${KEEP_TS:-0}
RLOG=${RLOG:-info,moq_net::model=debug}
IDLE=${SIDLE%s}
IDLE=${IDLE:-30}
DEADLINE=$((EVENT_AT + IDLE + 5))
END=$((DEADLINE + OBS))
BC=mesh.hang
MOQ="$BIN/moq"
RELAY="$BIN/moq-relay"
case $EVENT in kill | eof) ;; *) echo "EVENT must be kill or eof"; exit 1 ;; esac
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"
moq_cli_detect "$MOQ" "$RELAY"
HOPARG=()
if [ -n "$HOP" ]; then
	if "$MOQ" --help 2>&1 | grep -q -- '--hop <'; then HOPARG=(--hop "$HOP")
	elif "$MOQ" --help 2>&1 | grep -q -- '--origin <'; then HOPARG=(--origin "$HOP")
	else echo "this build has neither --hop nor --origin"; exit 1; fi
fi
if [ "$RELAY_CLI_NEW" -eq 1 ]; then RINSECURE=--connect-tls-insecure; else RINSECURE=--client-tls-disable-verify; fi
RIDLE=()
[ -n "$SIDLE" ] && RIDLE=("$RELAY_IDLE_FLAG" "$SIDLE" "${RELAY_IDLE_FLAG/idle-timeout/keep-alive}" 2s)
mkdir -p "$OUT"
rm -f "$OUT"/*.ts "$OUT"/*.log "$OUT"/*.exit "$OUT/sizes.csv" "$OUT/verdict.txt"
size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
now() { date +%s.%N; }
# Seconds since the sampler's t=0, for an epoch or an RFC 3339 log timestamp.
rel() { awk -v a="$1" -v b="$T0" 'BEGIN { printf "%.1f", a - b }'; }
logts() { date -d "$1" +%s.%N 2>/dev/null; }

PIDS=()
relayA="" relayB="" pubA="" sub1="" sub2="" sub3=""
T_JOIN="" T_EVENT=""
# Children are listed before their parents die, because an orphan no longer matches `-P`.
cleanup() {
	local kids
	[ "${#PIDS[@]}" -gt 0 ] || return 0
	kids=$(for p in "${PIDS[@]}"; do pgrep -P "$p"; done)
	# shellcheck disable=SC2086  # one PID per word
	kill -KILL "${PIDS[@]}" $kids 2>/dev/null
	pkill -f "[t]sp -I file - -O ip 127.0.0.1:$((FEED + 1))" 2>/dev/null
	PIDS=()
}
trap cleanup EXIT

start_relay() { # <name> <port> <cluster-id> [peer-port]
	moq_relay_public "127.0.0.1:$2" localhost --cluster-id "$3" "${RIDLE[@]+"${RIDLE[@]}"}"
	[ -n "${4:-}" ] && RELAY_ARGV+=(--cluster-connect "https://localhost:$4/" "$RINSECURE")
	RUST_LOG=$RLOG "$RELAY" "${RELAY_ARGV[@]}" >"$OUT/$1.log" 2>&1 &
	PIDS+=($!)
	printf -v "$1" %s "$!"
}
# The subshell records both pipeline members' exit statuses, so a clean finish is visible as moq=0.
start_pub() { # <name> <relay-port> <udp-port>
	(
		tsp -I ip "$3" -O file - 2>"$OUT/$1-tsp.log" |
			"$MOQ" "${MOQ_DIAL[@]}" "https://localhost:$2" "${MOQ_GSO[@]}" --broadcast "$BC" \
				"${HOPARG[@]+"${HOPARG[@]}"}" import ts >"$OUT/$1.log" 2>&1
		echo "$(date +%s.%N) tsp=${PIPESTATUS[0]} moq=${PIPESTATUS[1]}" >"$OUT/$1.exit"
	) &
	PIDS+=($!)
	printf -v "$1" %s "$!"
}
start_sub() { # <name> <relay-port>
	"$MOQ" "${MOQ_DIAL[@]}" "https://localhost:$2" "${MOQ_GSO[@]}" --broadcast "$BC" export ts \
		>"$OUT/$1.ts" 2>"$OUT/$1.log" &
	PIDS+=($!)
	printf -v "$1" %s "$!"
}

{
	moq_record_build "$MOQ" "$RELAY"
	[ -f "$BIN.sha" ] && echo "sha: $(cat "$BIN.sha")"
	echo "hop=${HOPARG[*]:-fresh} idle=${SIDLE:-default(30s)} event=$EVENT dial=$DIAL join=$JOIN event_at=$EVENT_AT deadline=$DEADLINE end=$END"
} | tee "$OUT/build.txt"

if [ "$DIAL" = both ]; then start_relay relayA "$PORT_A" 11111 "$PORT_B"; else start_relay relayA "$PORT_A" 11111; fi
start_relay relayB "$PORT_B" 22222 "$PORT_A"
sleep 3
for r in "$relayA" "$relayB"; do
	kill -0 "$r" 2>/dev/null || { echo "RELAY DID NOT START: $(tail -3 "$OUT"/relay*.log)"; exit 1; }
done
tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous \
	-P fork "tsp -I file - -O ip 127.0.0.1:$((FEED + 1))" -O ip "127.0.0.1:$FEED" 2>"$OUT/source.log" &
PIDS+=($!)
start_pub pubA "$PORT_A" "$FEED"
sleep 4
start_sub sub1 "$PORT_A"
start_sub sub2 "$PORT_A"
start_sub sub3 "$PORT_B"
T0=$(now)
echo "t,epoch,sub1,sub2,sub3,alive1,alive2,alive3,event" >"$OUT/sizes.csv"
for t in $(seq 0 "$END"); do
	sleep "$(awk -v a="$T0" -v t="$t" -v n="$(now)" 'BEGIN { d = a + t - n; print (d > 0) ? d : 0 }')"
	ev=""
	if [ "$t" -eq "$JOIN" ]; then
		start_pub pubB "$PORT_B" $((FEED + 1))
		T_JOIN=$(now)
		ev=pubB_join
	elif [ "$t" -eq "$EVENT_AT" ]; then
		T_EVENT=$(now)
		if [ "$EVENT" = kill ]; then pkill -KILL -P "$pubA" 2>/dev/null
		else pkill -TERM -P "$pubA" -f "^tsp -I ip" 2>/dev/null; fi
		ev=${EVENT}_pubA
	fi
	row="$t,$(now)"
	for s in sub1 sub2 sub3; do row="$row,$(size "$OUT/$s.ts")"; done
	for p in "$sub1" "$sub2" "$sub3"; do
		if kill -0 "$p" 2>/dev/null; then row="$row,1"; else row="$row,0"; fi
	done
	echo "$row,$ev" >>"$OUT/sizes.csv"
done
PUB_EXIT=()
for p in pubA pubB; do PUB_EXIT+=("$(cut -d' ' -f2- "$OUT/$p.exit" 2>/dev/null || echo "running at the end")"); done
cleanup

# Per subscriber: the last second it was alive, the first second after the event its capture grew
# again once it had stalled, and the longest run of seconds without growth in a window.
col() { case $1 in sub1) echo 3 ;; sub2) echo 4 ;; sub3) echo 5 ;; esac; }
alive_until() { awk -F, -v c=$(($(col "$1") + 3)) 'NR > 1 && $c == 1 { t = $1 } END { print t + 0 }' "$OUT/sizes.csv"; }
resumed() {
	awk -F, -v c="$(col "$1")" -v k="$2" 'NR > 1 && $1 > k && $c > prev && stalled { print $1; exit }
		NR > 1 { if ($1 > k && $c == prev) stalled = 1; prev = $c }' "$OUT/sizes.csv"
}
stall() { # <sub> <from> <to>
	awk -F, -v c="$(col "$1")" -v a="$2" -v b="$3" 'NR > 1 { if ($1 > a && $1 <= b) { run = ($c == prev) ? run + 1 : 0; if (run > max) max = run }; prev = $c }
		END { print max + 0 }' "$OUT/sizes.csv"
}
at() { awk -F, -v c="$(col "$1")" -v k="$2" 'NR > 1 && $1 == k { print $c }' "$OUT/sizes.csv"; }
first_error() { grep -m1 -E '^Error:' "$OUT/$1.log" | cut -c1-160; }
# The first ERROR line logged before the epoch. The exporter's closing `Error:` line carries no
# timestamp; an exit before the epoch is caught by the liveness column instead.
error_before() { # <sub> <epoch>
	local line ts
	while IFS= read -r line; do
		ts=$(logts "${line%% *}")
		if awk -v a="$ts" -v b="$2" 'BEGIN { exit !(a < b) }'; then echo "$line" | cut -c1-160; return; fi
	done < <(grep ' ERROR ' "$OUT/$1.log")
}
# Media subscriptions a publisher received, by phase: [start, JOIN), [JOIN, EVENT), [EVENT, END].
subs_by_phase() {
	local j=0 e=0 a=0 line ts
	[ -f "$OUT/$1.log" ] || { echo "-"; return; }
	while IFS= read -r line; do
		ts=$(logts "${line%% *}")
		if awk -v x="$ts" -v y="$T_JOIN" 'BEGIN { exit !(x < y) }'; then j=$((j + 1))
		elif awk -v x="$ts" -v y="$T_EVENT" 'BEGIN { exit !(x < y) }'; then e=$((e + 1))
		else a=$((a + 1)); fi
	done < <(grep 'subscribed started' "$OUT/$1.log" | grep -v 'track=catalog')
	echo "$j/$e/$a"
}
# The first dead-session line on relayA after the event, i.e. when relayA detected pubA had gone.
detect=""
while IFS= read -r line; do
	ts=$(logts "${line%% *}")
	if awk -v x="$ts" -v y="$T_EVENT" 'BEGIN { exit !(x >= y) }'; then detect=$(rel "$ts"); break; fi
done < <(grep -E 'connection (closed|error).*timed out' "$OUT/relayA.log")

R1=$(resumed sub1 "$EVENT_AT")
S1=$(stall sub1 "$EVENT_AT" "$END")
A1=$(alive_until sub1)
TAIL1=$(($(at sub1 "$END") - $(at sub1 $((END - 5)))))
A3=$(alive_until sub3)
GROW3=$(($(at sub3 "$EVENT_AT") - $(at sub3 $((EVENT_AT - 5)))))
E3=$(error_before sub3 "$T_EVENT")
PRE1=$(at sub1 "$JOIN")

{
	echo "== $OUT"
	echo "t0=$(date -u -d "@$T0" +%FT%T.%3NZ) join=$(rel "$T_JOIN") event=$(rel "$T_EVENT") ($EVENT) relayA_timeout=${detect:-none}"
	for s in sub1 sub2 sub3; do
		r=$(resumed "$s" "$EVENT_AT")
		echo "$s: alive_until=$(alive_until "$s") resumed=${r:-no-stall} stall_after_event=$(stall "$s" "$EVENT_AT" "$END")s stall_join_to_event=$(stall "$s" "$JOIN" "$EVENT_AT")s final=$(at "$s" "$END")B error=$(first_error "$s")"
	done
	i=0
	for p in pubA pubB; do
		echo "$p: media subscriptions before-join/join-to-event/after-event=$(subs_by_phase "$p") exit: ${PUB_EXIT[$i]}"
		i=$((i + 1))
	done

	if [ "${PRE1:-0}" -lt 1000000 ]; then
		echo "VOID: sub1 held ${PRE1:-0} B at the join, so the chain never carried media"
		c1=void c2=void c3=void
	else
		if [ "$A3" -ge "$EVENT_AT" ] && [ "$GROW3" -gt 0 ] && [ -z "$E3" ]; then c2=PASS; else c2=FAIL; fi
		c1=n/a c3=n/a
		if [ "$EVENT" = kill ]; then
			if [ "$A1" -ge "$END" ] && [ "$TAIL1" -gt 0 ] && { [ -z "$R1" ] || [ $((R1 - EVENT_AT)) -le $((IDLE + 5)) ]; }; then c1=PASS; else c1=FAIL; fi
		elif [ "$A1" -lt "$END" ]; then c3=terminated
		elif [ "$TAIL1" -gt 0 ]; then c3=failed-over
		else c3=frozen; fi
	fi
	echo "CHECK 2 (standby arrival): $c2 — sub3 alive_until=$A3, +${GROW3}B in the 5 s before the event, error before it: ${E3:-none}"
	[ "$EVENT" = kill ] && echo "CHECK 1 (failover): $c1 — sub1 resumed=${R1:-no-stall} (deadline t=$DEADLINE), alive_until=$A1 of $END, +${TAIL1}B over the last 5 s"
	[ "$EVENT" = eof ] && echo "CHECK 3 (graceful end): sub1 $c3 — alive_until=$A1 of $END, +${TAIL1}B over the last 5 s, $(first_error sub1)"
	echo "RESULT hop=${HOP:-fresh} idle=${IDLE}s event=$EVENT check1=$c1 check2=$c2 check3=$c3 event_t=$(rel "$T_EVENT") detect_t=${detect:-none} resumed_t=${R1:-none} stall1=${S1}s alive1=$A1/$END"
} | tee "$OUT/verdict.txt"

if [ "$KEEP_TS" != 1 ]; then rm -f "$OUT"/sub?.ts; fi

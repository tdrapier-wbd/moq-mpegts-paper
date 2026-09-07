#!/usr/bin/env bash
# F11: can one receiver degrade the service the other receivers get?
#
# Multi-tenancy is assumed by both economic models in this paper, and a relay
# holding per-subscription state is structurally more exposed than a cache
# serving idempotent GETs. The paper should either show that or stop implying
# it. Nothing in the campaign has tested it adversarially.
#
# One cell = one arm. Each cell is three phases on one clock, which is what
# makes "it degraded" and "it recovered" the same measurement rather than two:
#
#   settle          victims only, relay warm            [0, SETTLE)
#   baseline        victims only, measured              [SETTLE, T1)
#   abuse           the arm's abuser runs               [T1, T2)
#   recovery        abuser gone, victims still measured [T2, T3)
#
# The instrument is the *victims*, never the abuser: an abuser that gets poor
# service is not a finding, and an abuser that gets good service while the
# victims suffer is the whole point. Victims are graded on delivered programme
# (t8b-c3-span.py's keep_up and holes) and continuity, per phase, because a
# byte count cannot tell "held the live edge" from "fell behind cleanly".
#
# The relay is sampled per PID out of /proc, not by command-line signature:
# T21 attributed 137 MB of growth to a signature that also matched a wrapper
# shell, and the whole point here is attribution.
#
# Arms, all expressible through the `moq` CLI (which offers only import and
# export, so an abuser is a subscriber that behaves badly rather than a custom
# client):
#
#   control  no abuser at all. The reference every other arm is read against,
#            and it must be run in the same session as the arms — this box is
#            shared and a day-old baseline is not a baseline.
#   storm    NSTORM concurrent subscribers to the victims' own broadcast,
#            killed and relaunched every STORM_PERIOD s. Tests per-subscription
#            setup cost and whether fan-out churn on a track starves the
#            established readers of it.
#   ghost    subscribers to broadcasts that do not exist, respawned tightly.
#            Tests whether an unsatisfiable subscription costs the relay
#            anything it cannot reclaim — the cheapest abuse to mount, since it
#            needs no knowledge of what the relay carries.
#   churn    sessions opened and abandoned after CHURN_HOLD s without closing.
#            Tests connection-state reclamation; a session torn down without a
#            CONNECTION_CLOSE is served until the idle timeout expires.
#   slow     a subscriber that never drains its stdout, so its pipe fills and
#            it stops reading while remaining subscribed. Tests whether one
#            unresponsive reader's backpressure reaches the others — the arm
#            most likely to find something, because it is the one where the
#            relay must either buffer without bound or drop.
#
# Usage: f11-isolation.sh <arm> [label]
#        ARM in control|storm|ghost|churn|slow
set -uo pipefail

ARM=${1:?arm: control|storm|ghost|churn|slow}
LABEL=${2:-$ARM}

MOQ=${MOQ:-$HOME/bin-3006/moq}
RELAY=${RELAY:-$HOME/bin-3006/moq-relay}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
GRADER=${GRADER:-$HOME/f11/t8b-c3-span.py}
OUT=${OUT:-$HOME/f11}/$LABEL

PORT=${PORT:-4463}
MPORT=${MPORT:-9463}
NVICTIM=${NVICTIM:-2}
LATMAX=${LATMAX:-2s}

SETTLE=${SETTLE:-15}
BASE=${BASE:-45} # baseline phase length
ABUSE=${ABUSE:-60}
RECOVER=${RECOVER:-45}
CYCLES=${CYCLES:-1} # abuse+recovery repeats, against one relay

NSTORM=${NSTORM:-40}
STORM_PERIOD=${STORM_PERIOD:-5}
CHURN_HOLD=${CHURN_HOLD:-0.3}
NGHOST=${NGHOST:-40}

# The group cache is unbounded unless one of these is set (`moq-relay` config.rs:
# "Unbounded unless `cache.capacity` or `cache.headroom`"), so the default arms
# measure an unbounded cache and say so. Setting either turns the same arm into a
# test of the documented mitigation rather than a second measurement of the
# default, which is the only reason to vary it.
CACHE_HEADROOM=${CACHE_HEADROOM:-}
CACHE_CAPACITY=${CACHE_CAPACITY:-}

# The `storm` and `churn` arms SIGKILL their subscribers, so those sessions are
# served until the idle timeout expires (30 s by default, measured in T6). At a
# 5 s churn period that means several generations coexist inside the relay, and
# "40 abusers" understates what it is actually holding. Shortening the timeout
# scales that overlap down without changing anything else, which separates
# retention-times-churn-rate from a per-subscription cost that never comes back.
IDLE_TIMEOUT=${IDLE_TIMEOUT:-}

BCAST=f11.victim
T1=$SETTLE
T2=$((SETTLE + BASE))
# No T3: past the baseline the phase is a function of (elapsed - T2) modulo the
# abuse+recovery period, so `phase_of` computes the cycle rather than comparing
# against a fixed third boundary.
TOTAL=$((SETTLE + BASE + (ABUSE + RECOVER) * CYCLES))

for b in "$MOQ" "$RELAY"; do
	[ -x "$b" ] || {
		echo "f11: missing binary $b" >&2
		exit 1
	}
done
[ -f "$CLIP" ] || {
	echo "f11: missing clip $CLIP" >&2
	exit 1
}

# A relay already bound here would serve the cell silently and the numbers
# would belong to a process this script does not control.
if ss -ulnp 2>/dev/null | grep -q ":$PORT "; then
	echo "f11: something is already bound to UDP $PORT" >&2
	exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
KIDS=()

cleanup() {
	# Abusers first: a victim killed while an abuser still runs records a
	# recovery that never happened.
	pkill -f "[f]11\.ghost" 2>/dev/null
	pkill -f "[f]11\.victim" 2>/dev/null
	for p in "${KIDS[@]+${KIDS[@]}}"; do
		kill -9 "$p" 2>/dev/null
	done
	sleep 1
	pkill -f "[m]oq-relay.*:$PORT" 2>/dev/null
}
trap cleanup EXIT

echo "=== $(date -u +%FT%TZ) f11 arm=$ARM label=$LABEL ==="
echo "moq:   $("$MOQ" --version 2>&1 | head -1)"
echo "relay: $("$RELAY" --version 2>&1 | head -1)"
echo "phases: settle=$SETTLE base=$BASE abuse=$ABUSE recover=$RECOVER" \
	"cycles=$CYCLES total=${TOTAL}s"
echo "cache: headroom=${CACHE_HEADROOM:-unset} capacity=${CACHE_CAPACITY:-unset}" \
	"$([ -z "$CACHE_HEADROOM$CACHE_CAPACITY" ] && echo '(unbounded — the default)')"
echo "relay idle timeout: ${IDLE_TIMEOUT:-30s (default)}"

# ---- relay -----------------------------------------------------------------
# --stats-enabled=true is what exposes the traffic counters; --internal-listen
# alone serves only the accept series. Both are require_equals.
RELAY_ARGS=()
[ -n "$CACHE_HEADROOM" ] && RELAY_ARGS+=(--cache-headroom "$CACHE_HEADROOM")
[ -n "$CACHE_CAPACITY" ] && RELAY_ARGS+=(--cache-capacity "$CACHE_CAPACITY")
[ -n "$IDLE_TIMEOUT" ] && RELAY_ARGS+=(--server-quic-idle-timeout "$IDLE_TIMEOUT")

"$RELAY" --server-bind "127.0.0.1:$PORT" --tls-generate localhost --auth-public "" \
	--internal-listen "127.0.0.1:$MPORT" --stats-enabled=true \
	"${RELAY_ARGS[@]+${RELAY_ARGS[@]}}" \
	>"$OUT/relay.log" 2>&1 &
RELAY_PID=$!
KIDS+=("$RELAY_PID")
sleep 2
kill -0 "$RELAY_PID" 2>/dev/null || {
	echo "f11: relay died — see $OUT/relay.log" >&2
	exit 1
}

URL="https://127.0.0.1:$PORT/anon"
CONN=(--client-tls-disable-verify --client-connect "$URL")

# Record the metric names this build actually exposes, rather than trusting the
# names a previous experiment wrote down. A series that was renamed upstream
# reads as a flat zero, which is indistinguishable from "the abuse cost
# nothing" — the exact false negative this experiment must not return.
curl -s --max-time 3 "http://127.0.0.1:$MPORT/metrics" >"$OUT/metrics.names" 2>/dev/null
if [ -s "$OUT/metrics.names" ]; then
	echo "relay metrics exposed: $(grep -c '^moq_relay' "$OUT/metrics.names") moq_relay samples"
	grep -oE '^moq_relay[a-z_]+' "$OUT/metrics.names" | sort -u | tr '\n' ' '
	echo
else
	echo "f11: WARNING — /metrics returned nothing; resource columns will be zero" >&2
fi

# ---- publisher -------------------------------------------------------------
bash -c "tsp -I file $CLIP --infinite -P regulate --pcr-synchronous -O file - \
  | $MOQ ${CONN[*]} --broadcast $BCAST import ts" >"$OUT/pub.log" 2>&1 &
PUB_PID=$!
KIDS+=("$PUB_PID")
sleep 4

# ---- victims ---------------------------------------------------------------
# Started before the abuser and kept for the whole cell, so one capture spans
# all four phases and phase boundaries are offsets into it rather than
# separate runs with separate warm-ups.
VICTIMS=()
for i in $(seq 1 "$NVICTIM"); do
	bash -c "timeout $TOTAL $MOQ ${CONN[*]} --broadcast $BCAST export ts \
    --latency-max $LATMAX > $OUT/victim.$i.ts" >"$OUT/victim.$i.log" 2>&1 &
	VICTIMS+=("$!")
	KIDS+=("$!")
done

# ---- abuser ----------------------------------------------------------------
# Every abuser runs under `setsid`, and is stopped by killing its whole process
# group. Nothing here matches on a command line: the storm arm subscribes to
# the victims' *own* broadcast, so a `pkill -f` on the broadcast name cannot
# tell an abuser from a victim and would silently kill the instrument. That
# mistake reads as catastrophic degradation, which is exactly the answer this
# experiment is trying not to get wrong.
abuser() {
	# Rebuilt here rather than inherited: see the note at the call site.
	local CONN=(--client-tls-disable-verify --client-connect "$URL")
	# One child per arm keeps its stderr, and the rest are silenced. An
	# abuser whose output is entirely discarded cannot be told apart from
	# an abuser that never ran, so the arm's own liveness is unfalsifiable.
	: >"$ABLOG"
	case "$ARM" in
	control) : ;;
	storm)
		# Subscribers arrive in bursts and are dropped wholesale, so the
		# relay pays setup and teardown for NSTORM subscriptions to a
		# track it is already serving.
		while :; do
			local pids=() i=0
			for _ in $(seq 1 "$NSTORM"); do
				i=$((i + 1))
				if [ "$i" = 1 ]; then
					"$MOQ" "${CONN[@]}" --broadcast "$BCAST" export ts \
						--latency-max "$LATMAX" >/dev/null 2>>"$ABLOG" &
				else
					"$MOQ" "${CONN[@]}" --broadcast "$BCAST" export ts \
						--latency-max "$LATMAX" >/dev/null 2>&1 &
				fi
				pids+=("$!")
			done
			sleep "$STORM_PERIOD"
			for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null; done
			wait "${pids[@]}" 2>/dev/null
		done
		;;
	ghost)
		# Distinct names, so the relay cannot answer them all from one
		# cached failed lookup.
		local n=0
		while :; do
			local pids=() i=0
			for _ in $(seq 1 "$NGHOST"); do
				n=$((n + 1))
				i=$((i + 1))
				if [ "$i" = 1 ]; then
					"$MOQ" "${CONN[@]}" --broadcast "f11.ghost.$n.hang" \
						export ts >/dev/null 2>>"$ABLOG" &
				else
					"$MOQ" "${CONN[@]}" --broadcast "f11.ghost.$n.hang" \
						export ts >/dev/null 2>&1 &
				fi
				pids+=("$!")
			done
			sleep 2
			for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null; done
			wait "${pids[@]}" 2>/dev/null
		done
		;;
	churn)
		# Abandoned without a CONNECTION_CLOSE: SIGKILL rather than a
		# clean exit, so the relay must reclaim on its own timers.
		while :; do
			"$MOQ" "${CONN[@]}" --broadcast "$BCAST" export ts \
				>/dev/null 2>>"$ABLOG" &
			local p=$!
			sleep "$CHURN_HOLD"
			kill -9 "$p" 2>/dev/null
			wait "$p" 2>/dev/null
		done
		;;
	slow)
		# The pipe fills (64 KiB) and the reader never drains it, so the
		# subscriber stops reading while staying subscribed — the relay
		# must then either buffer without bound or drop.
		# shellcheck disable=SC2216 # piping to a process that never reads
		# stdin is the stimulus, not a mistake: it is what fills the pipe
		# and stops the subscriber reading while it stays subscribed.
		"$MOQ" "${CONN[@]}" --broadcast "$BCAST" export ts --latency-max "$LATMAX" \
			2>/dev/null | sleep 100000
		;;
	*)
		echo "f11: unknown arm $ARM" >&2
		exit 1
		;;
	esac
}

# ---- sample ----------------------------------------------------------------
# Per-PID out of /proc. wchar is bytes the victim has written to its capture,
# which is the delivered-rate series; RSS/threads/fds are the relay's.
rss() { awk '/VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }
thr() { awk '/^Threads/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }
fds() { find "/proc/$1/fd" -mindepth 1 2>/dev/null | wc -l; }
cpu() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
wch() { awk -F': *' '/^wchar/{print $2}' "/proc/$1/io" 2>/dev/null || echo 0; }

# One scrape per sample, then read several series out of it: the endpoint is
# cheap but not free, and sampling it five times a second would put the
# instrument in the measurement.
SCRAPE=$OUT/.scrape
scrape() { curl -s --max-time 2 "http://127.0.0.1:$MPORT/metrics" >"$SCRAPE" 2>/dev/null || :; }
# What `/metrics` actually carries on `moq-relay` 0.14.14 is the **accept**
# series and nothing else. The per-role traffic counters an earlier experiment
# read here are gone from this surface: `--stats-enabled` now publishes stats
# as a MoQ *broadcast* under `--stats-prefix` (default `.stats`), so reading
# them means subscribing to the relay rather than scraping it.
#
# That is no loss for this experiment and arguably a gain, because the two
# series that remain are direct isolation measures rather than proxies:
# `accept_failures_total{class="exhausted"}` says the relay refused a
# connection, and `accept_stalled_seconds` says how long it could not accept
# one at all — which is precisely "did the abuser stop other clients getting
# in". Delivered bytes are measured at the victims from /proc anyway, which is
# the better place for them: it is the receiver's view, not the relay's claim.
series() {
	awk -v k="$1" '$0 ~ "^"k"[{ ]" {s+=$NF} END{printf "%s", (s==int(s)?int(s):s)+0}' \
		"$SCRAPE" 2>/dev/null
}

CSV=$OUT/samples.csv
{
	printf 'elapsed,phase,relay_rss_kb,relay_threads,relay_fds,relay_cpu_ticks,'
	printf 'accept_failures,accept_stalled_s,abusers'
	for i in $(seq 1 "$NVICTIM"); do printf ',victim%s_wchar' "$i"; done
	printf '\n'
} >"$CSV"

ABUSER_PID=""
START=$(date +%s)
# With CYCLES=1 (the default) this is the four-phase run the file describes.
# With CYCLES=N the abuse and recovery phases repeat N times against **one**
# relay, which is the only way to ask whether a retained cost *ratchets*: the
# 6-minute recovery run established that the relay keeps most of what an abuse
# burst costs it, and "keeps 1.7 GB once" and "keeps 1.7 GB per burst" are an
# operational note and a denial of service respectively. Phase labels carry the
# cycle number so a per-phase grade can still separate them.
phase_of() {
	local e=$1
	[ "$e" -lt "$T1" ] && {
		echo settle
		return
	}
	[ "$e" -lt "$T2" ] && {
		echo baseline
		return
	}
	local into=$((e - T2))
	local period=$((ABUSE + RECOVER))
	local cyc=$((into / period + 1))
	[ "$cyc" -gt "$CYCLES" ] && {
		echo "recovery$CYCLES"
		return
	}
	if [ $((into % period)) -lt "$ABUSE" ]; then echo "abuse$cyc"; else echo "recovery$cyc"; fi
}
# The arm's phase, with the cycle number stripped, so the abuser start/stop
# logic does not have to know about cycling.
kind_of() { printf '%s' "${1%%[0-9]*}"; }

while :; do
	NOW=$(date +%s)
	E=$((NOW - START))
	[ "$E" -ge "$TOTAL" ] && break
	PH=$(phase_of "$E")
	KIND=$(kind_of "$PH")

	if [ "$KIND" = abuse ] && [ -z "$ABUSER_PID" ] && [ "$ARM" != control ]; then
		echo "=== $(date -u +%FT%TZ) +${E}s abuse starts ==="
		# Its own session, so the whole tree dies with one signal to the
		# group and no descendant outlives the abuse phase.
		# URL crosses into the child, not CONN: an array does not survive
		# the trip through `bash -c`, and a string that `abuser` then
		# expands as `"${CONN[@]}"` becomes a *single* argument, which
		# every abuser rejects as a CLI parse error before it opens a
		# connection. The arm then measures nothing and reports clean
		# victims — a control arm wearing the arm's name.
		setsid bash -c "$(declare -f abuser); ARM=$ARM MOQ=$MOQ BCAST=$BCAST \
      LATMAX=$LATMAX NSTORM=$NSTORM NGHOST=$NGHOST STORM_PERIOD=$STORM_PERIOD \
      CHURN_HOLD=$CHURN_HOLD URL=$URL ABLOG=$OUT/abuser.child.log abuser" \
			>"$OUT/abuser.log" 2>&1 &
		ABUSER_PID=$!
		KIDS+=("$ABUSER_PID")
	fi
	if [ "$KIND" = recovery ] && [ -n "$ABUSER_PID" ]; then
		echo "=== $(date -u +%FT%TZ) +${E}s abuse stops ==="
		# Negative PID = the process group setsid created. This is why the
		# abuser needed its own session: the storm arm's children are
		# indistinguishable from the victims by command line.
		kill -9 -- "-$ABUSER_PID" 2>/dev/null
		kill -9 "$ABUSER_PID" 2>/dev/null
		ABUSER_PID=""
		sleep 1
	fi

	# Everything in the abuser's process group, whatever it is called.
	NAB=0
	[ -n "$ABUSER_PID" ] && NAB=$(pgrep -g "$ABUSER_PID" 2>/dev/null | wc -l)

	scrape
	ROW="$E,$PH,$(rss "$RELAY_PID"),$(thr "$RELAY_PID"),$(fds "$RELAY_PID"),$(cpu "$RELAY_PID")"
	ROW="$ROW,$(series moq_relay_accept_failures_total),$(series moq_relay_accept_stalled_seconds),$NAB"
	for p in "${VICTIMS[@]}"; do ROW="$ROW,$(wch "$p")"; done
	echo "$ROW" >>"$CSV"
	sleep 1
done

echo "=== $(date -u +%FT%TZ) run complete, grading ==="
wait "${VICTIMS[@]}" 2>/dev/null

for i in $(seq 1 "$NVICTIM"); do
	f=$OUT/victim.$i.ts
	[ -s "$f" ] || {
		echo "victim $i: EMPTY CAPTURE"
		continue
	}
	echo "--- victim $i ---"
	echo "  bytes=$(stat -c%s "$f")"
	tsp -I file "$f" -P continuity -O drop 2>&1 | tail -3 | sed 's/^/  cc: /'
	python3 "$GRADER" "$TOTAL" "$f" 2>/dev/null | sed 's/^/  /'
done

echo "=== samples: $CSV ($(wc -l <"$CSV") rows) ==="

# The arm has to prove it ran. Without this, an abuser that dies on a CLI parse
# error produces pristine victims and the cell reports perfect isolation — the
# most dangerous result this rig can return, because it is indistinguishable
# from the answer we are hoping for. Assert the load existed before believing
# anything about how well it was survived.
if [ "$ARM" != control ]; then
	# Prefix match, not equality: with CYCLES>1 the phase is `abuse1`, and an
	# exact match would read 0 here — turning this guard into the very false
	# negative it exists to prevent.
	PEAK=$(awk -F, 'NR>1 && $2 ~ /^abuse/ {if ($9>m) m=$9} END{print m+0}' "$CSV")
	echo "=== abuser liveness: peak concurrent=$PEAK during abuse ==="
	if [ "$PEAK" -lt 2 ]; then
		echo "!!! ARM DID NOT RUN: peak abuser count $PEAK — victims' clean"
		echo "!!! result is meaningless. Check abuser.child.log:"
		head -5 "$OUT/abuser.child.log" 2>/dev/null | sed 's/^/!!!   /'
		exit 3
	fi
	if [ -s "$OUT/abuser.child.log" ]; then
		echo "--- abuser stderr (first lines) ---"
		head -3 "$OUT/abuser.child.log" | sed 's/^/  /'
	fi
fi

#!/usr/bin/env bash
# T8b P0-i — does `moq export ts` still exit under contention, and from which layer?
#
# C3 found subscribers exiting with `Error: hang: moq error: old` while sharing a congested
# bottleneck. The attribution to #3271 was withdrawn (it reproduces on both client arms and on
# both relay versions), so the failure is established and its *cause* is not. This rig exists to
# answer the cause, and it is built around the two mistakes the first attempt made.
#
# **Read every subscriber's log.** Each contended cell runs N subscribers and writes `sub.1.log`
# … `sub.N.log`. The first pass read only the first, turning a 9/15-against-3/15 result into a
# clean 6/0 split and a filed-then-withdrawn upstream issue. Every subscriber is classified here,
# and the per-subscriber count is the reported one; the per-cell count is derived from it.
#
# **Carry a positive control.** "It no longer reproduces" and "the rig no longer contends" look
# identical in the output. The `old` arm is a build known to produce the exit, run through the
# same rig in the same session, so a null on the new build is only believable beside a non-null
# on the old one.
#
# What the error text already tells us, and what this run has to settle. The exit message names
# its layer: `hang: moq error: old` is `moq_mux::Error::Hang(hang::Error::Moq(moq_net::Error::Old))`,
# and the `hang:` hop is the discriminator. A media group read that is evicted comes back through
# the container consumer's own skip path, which handles it — `poll_aborted` is consulted and the
# cursor jumps to the next buffered group, logging *current group evicted*. An `Old` that arrives
# as `hang::Error` instead has come through `Container::Error`, i.e. a frame read whose group the
# consumer did not recognise as aborted. The two candidate paths are therefore:
#
#   a) the read/abort race — `group.poll_read` returns `Err(Old)` while `group.poll_aborted`
#      is still false, so the skip is not taken and the error propagates;
#   b) the track-level read — `poll_read_finish`'s `track.poll_recv_group(waiter)?`, which has
#      no skip path at all and is fatal by construction.
#
# `RUST_LOG` is raised on both crates so the last events before the exit separate them: (a) is
# preceded by group reads on a sequence the consumer still holds, (b) by a subscription-level
# reset with no preceding eviction warning.
#
#   sudo t8b-export-death.sh <label> [replicates]
#
# Env: NEW, OLD (binary dirs), NFLOWS(2), CAP_MBIT(15), QDISC(bloat), SECS(90), LATMAX(2s),
#      CLIP, NETNS, OUT.
set -uo pipefail

# Post-#3793 CLI flags, detected per binary rather than assumed.
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:?label}
REPS=${2:-5}

NEW=${NEW:?set NEW to the build under test}
OLD=${OLD:-}
NFLOWS=${NFLOWS:-2}
CAP_MBIT=${CAP_MBIT:-15}
QDISC=${QDISC:-bloat}
SECS=${SECS:-90}
LATMAX=${LATMAX:-2s}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
NETNS=${NETNS:-$HOME/t8b-netns.sh}
OUT=${OUT:-$HOME/t8b-death}/$LABEL
PUBIP=10.99.0.1
PORT=4443

[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo)" >&2
	exit 1
}
for f in "$NETNS" "$CLIP" "$NEW/moq" "$NEW/moq-relay"; do
	[ -r "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done

rm -rf "$OUT"
mkdir -p "$OUT"
SUMMARY=$OUT/summary.csv
echo "arm,rep,subscribers,deaths,errors" >"$SUMMARY"

pub() { ip netns exec t8b-pub "$@"; }
sub() { ip netns exec t8b-sub "$@"; }

cleanup_procs() {
	pkill -9 -f "[m]oq-relay.*$PUBIP:$PORT" 2>/dev/null
	pkill -9 -f "t8bdeath" 2>/dev/null
	pkill -9 -f "[t]sp -I file $CLIP" 2>/dev/null
	sleep 1
}
trap 'cleanup_procs; bash "$NETNS" down >/dev/null 2>&1' EXIT

echo "=== $(date -u) t8b-export-death $LABEL ==="
"$NEW/moq" --version
[ -n "$OLD" ] && "$OLD/moq" --version

RATE_MBIT=$CAP_MBIT DELAY_MS=50 bash "$NETNS" up || exit 1
RATE_MBIT=$CAP_MBIT DELAY_MS=50 QUEUE_MS=500 bash "$NETNS" "$QDISC" || exit 1

# $1 arm name, $2 binary dir, $3 replicate index
run_cell() {
	local arm=$1 bin=$2 rep=$3
	local d="$OUT/$arm.$rep"
	mkdir -p "$d"
	cleanup_procs

	moq_cli_detect "$bin/moq" "$bin/moq-relay"

	# A broadcast name unique to the cell: a reused name can attach to the previous cell's
	# retained announce, and the capture is then the wrong run.
	local BC="t8bdeath.$arm.$rep.$$"

	# `RELAY_AUTH`, never a literal. `--auth-public` inverted at the CLI migration — `""` is
	# "everything" before it and "nothing" after — and the wrong value delivers nothing with no
	# error anywhere, which this rig would otherwise score as a subscriber that did not die. The
	# `old` arm is precisely a pre-migration binary, so a literal here voids the control.
	pub "$bin/moq-relay" "${RELAY_BIND[@]}" "$PUBIP:$PORT" "${RELAY_TLS[@]}" "$PUBIP" \
		"${RELAY_AUTH[@]}" "${RELAY_GSO[@]}" >"$d/relay.log" 2>&1 &
	sleep 3

	# Subscribers first: reservation gating publishes the catalog once tracks resolve.
	local i
	for i in $(seq 1 "$NFLOWS"); do
		sub env RUST_LOG="moq_mux=debug,moq_net=debug,warn" RUST_BACKTRACE=1 \
			bash -c "timeout $SECS '$bin/moq' ${MOQ_DIAL[*]} 'https://$PUBIP:$PORT/anon' \
                --broadcast '$BC.$i' export ts ${MOQ_LAT[*]} $LATMAX > '$d/out.$i.ts'" \
			>"$d/sub.$i.log" 2>&1 &
	done
	sleep 2

	for i in $(seq 1 "$NFLOWS"); do
		pub bash -c "tsp -I file '$CLIP' --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null \
            | '$bin/moq' ${MOQ_DIAL[*]} 'https://$PUBIP:$PORT/anon' --broadcast '$BC.$i' import ts" \
			>"$d/pub.$i.log" 2>&1 &
	done

	sleep $((SECS + 5))
	cleanup_procs

	# Classify every subscriber, not the first. `timeout` returns 124 on a clean expiry; any
	# other exit with an `Error:` line in the log is a death.
	#
	# A subscriber that captured nothing is VOID, not a survivor. A lane that silently delivers
	# no data — a mis-granted `--auth-public`, an announce that never resolved — presents here as
	# N processes that ran for 90 s and did not die, which is exactly the null this rig is trying
	# to distinguish from a real one.
	local deaths=0 void=0 errs=""
	for i in $(seq 1 "$NFLOWS"); do
		local log="$d/sub.$i.log"
		local bytes
		bytes=$(stat -c%s "$d/out.$i.ts" 2>/dev/null || echo 0)
		[ "$bytes" -lt 200000 ] && void=$((void + 1))
		if grep -qE '^Error: ' "$log" 2>/dev/null; then
			deaths=$((deaths + 1))
			local msg
			msg=$(grep -m1 -E '^Error: ' "$log" | cut -c1-120)
			errs="$errs|$msg"
			# The 60 lines before the exit are the attribution: whether an eviction warning
			# precedes it (the read/abort race) or nothing does (a track-level reset).
			grep -n -B60 -m1 -E '^Error: ' "$log" >"$d/context.$i.txt" 2>/dev/null
		fi
		# `grep -c` exits 1 on no match, so a `|| echo 0` fallback prints the count *and*
		# the zero. Take the count and discard the status instead.
		local evictions
		evictions=$(grep -cE 'current group evicted' "$log" 2>/dev/null) || true
		echo "   $arm.$rep sub$i: ${bytes}B ${evictions:-0} evictions$(grep -qE '^Error: ' "$log" && echo '  DIED')$([ "$bytes" -lt 200000 ] && echo '  VOID')"
	done
	[ "$void" -gt 0 ] && echo "   !! $void/$NFLOWS subscribers captured nothing — this cell grades nothing"
	echo "$arm,$rep,$NFLOWS,$deaths,\"${errs#|}\"" >>"$SUMMARY"
	# Captures are large and nothing here grades them; the logs are the measurement.
	rm -f "$d"/out.*.ts
}

for r in $(seq 1 "$REPS"); do
	echo
	echo "--- replicate $r/$REPS ---"
	run_cell new "$NEW" "$r"
	[ -n "$OLD" ] && run_cell old "$OLD" "$r"
done

echo
echo "=== summary: deaths per subscriber ==="
awk -F, 'NR>1{s[$1]+=$3; d[$1]+=$4} END{for(a in s) printf "%-6s %d/%d subscribers died\n", a, d[a], s[a]}' "$SUMMARY"
echo
echo "=== distinct exit messages ==="
grep -hoE 'Error: [^"|]*' "$SUMMARY" | sort | uniq -c | sort -rn
echo "=== $(date -u) done: $OUT ==="

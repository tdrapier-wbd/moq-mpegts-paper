# shellcheck shell=bash
# shellcheck disable=SC2034  # every variable here is consumed by the sourcing rig, not by this file.
#
# The MoQ CLI surface, detected rather than assumed, plus the two guards that would have caught
# most of what this campaign has lost time to. Source it from a rig script:
#
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"
#   moq_cli_detect "$MOQ" "$RELAY"
#   moq_relay_public "$BIND" "$TLS_NAME" --log-level warn   # -> RELAY_ARGV
#   "$RELAY" "${RELAY_ARGV[@]}" &
#   ...
#   moq_require_bytes "$OUT/capture.ts" 200000 "subscriber" || return 1
#
# Sets: MOQ_CLI_NEW RELAY_CLI_NEW MOQ_DIAL MOQ_LAT MOQ_FP MOQ_GSO
#       RELAY_BIND RELAY_TLS RELAY_GSO RELAY_AUTH RELAY_CC_FLAG RELAY_IDLE_FLAG RELAY_GREP
#
# ## Why this file exists rather than a set of literals in each rig
#
# Four flag-level gotchas have each cost a run, and three of them are silent.
#
# **1. `--auth-public` inverted its meaning at the #3793 CLI migration.** It takes a path glob, not
# a boolean, and a relay given the wrong value accepts both sessions, registers the announcement and
# then delivers nothing, with no error logged anywhere. Measured on one host, loopback, client
# dialling `https://…/anon`, everything else held (method-notes § "--auth-public inverted"):
#
#                       auth=""      auth="**"    auth="anon/**"
#   moq 0.9.15          15.4 MB      0            0
#   moq 0.11.2-5d0991b9 0            13.3 MB      0
#   moq 0.11.2-615d166d 0            14.5 MB      0
#
# The pre-migration surface reads "" as "everything is public"; the post-migration one reads it as
# "nothing is". `anon/**` serves nothing on any of them, because the `/anon` in the URL is the
# connection root and the path the relay matches is relative to it. A rig that hard-codes either
# literal cannot carry a build comparison across the migration — which is exactly what a positive
# control on a pre-migration binary is.
#
# **2. GSO must be off, and the flag was renamed — on both sides.** Generic segmentation offload
# on the relay's egress produces datagrams the capture tooling mis-accounts, so every
# carriage-overhead and pacing figure taken with it on is wrong. The relay's flag was
# `--server-quic-gso=false` pre-migration and `--quic-gso=false` after; the *client's* was
# `--client-quic-gso=false` and is now the same `--quic-gso=false`, which is why the merged name
# looks safe to hard-code and is not. Passing the wrong one is a hard error rather than a silent
# one, but only if something reads the exit status: a client spawned into a pipeline exits 2 and
# the rig sees an empty capture, not a flag error. Use `MOQ_GSO` and `RELAY_GSO`.
#
# **3. The default congestion controller is now BBRv3, and it is the one known to abort.** The flag
# takes `loss` (CUBIC) or `delay` (BBRv3) and **defaults to `delay`**. `lab/test-8-srt-vs-moq.md`
# records noq's BBRv3 aborting the process under high loss — precisely what the outage ladders
# create — so a rig that does not pin the controller gets a different one on each side of the
# migration and cannot attribute a difference to the code under test. Always pass `RELAY_CC_FLAG`.
# It was `--server-quic-congestion-control` pre-migration and `--quic-congestion-control` after.
#
# **4. The relay and the client can be different builds**, and usually are when a rig carries a
# control arm. They are therefore detected separately: `moq_cli_detect` takes both and sets
# `RELAY_*` from the relay binary and `MOQ_*` from the client.
#
# ## The QUIC backend is no longer selectable, and it changed under the campaign
#
# #3757 flipped the default from quinn to noq+iroh and #3811 deleted quinn outright, so every build
# from `615d166d` onward is noq whatever the rig asks for. #3866 then re-based that on `moq-noq`.
# Nothing here selects it — there is nothing to select — but any result crossing #3811 carries a
# backend change as well as a code change. State the backend with any figure that crosses it;
# `moq_record_build` writes the line for you.
#
# One consequence for GSO: the **iroh** backend cannot turn GSO off and rejects an explicit `false`.
# `ec2-build-main.sh` builds `--no-default-features --features noq,…`, which drops iroh, so
# `--quic-gso=false` is accepted. A build that kept the default feature set would fail on it.

# moq_cli_detect <moq-binary> [relay-binary]
#
# Detects each binary's surface independently. With no relay given, the relay flags follow the
# client's surface, which is right only when the two are the same build.
moq_cli_detect() {
	local moq="${1:?moq binary}"
	local relay="${2:-}"

	if "$moq" --connect https://localhost --help >/dev/null 2>&1; then
		MOQ_CLI_NEW=1
		MOQ_DIAL=(--connect-tls-insecure --connect)
		MOQ_LAT=(--max-age)
		MOQ_FP=(--connect-tls-fingerprint)
		MOQ_GSO=(--quic-gso=false)
	else
		MOQ_CLI_NEW=0
		MOQ_DIAL=(--client-tls-disable-verify --client-connect)
		MOQ_LAT=(--latency-max)
		MOQ_FP=(--client-tls-fingerprint)
		MOQ_GSO=(--client-quic-gso=false)
	fi
	# The export's latency flag was renamed separately: commits inside the `dev` branch that #3793
	# merged have the new dial flags and still `--latency-max`, so ask the subcommand itself.
	if "$moq" export ts --help 2>&1 | grep -q -- '--latency-max'; then
		MOQ_LAT=(--latency-max)
	elif "$moq" export ts --help 2>&1 | grep -q -- '--max-age'; then
		MOQ_LAT=(--max-age)
	fi

	RELAY_CLI_NEW=$MOQ_CLI_NEW
	if [ -n "$relay" ]; then
		if "$relay" --help 2>/dev/null | grep -q -- '--listen '; then
			RELAY_CLI_NEW=1
		elif "$relay" --help 2>/dev/null | grep -q -- '--server-bind'; then
			RELAY_CLI_NEW=0
		fi
	fi

	if [ "$RELAY_CLI_NEW" -eq 1 ]; then
		RELAY_BIND=(--listen)
		RELAY_TLS=(--listen-tls-generate)
		RELAY_GSO=(--quic-gso=false)
		RELAY_AUTH=(--auth-public '**')
		RELAY_CC_FLAG=--quic-congestion-control
		RELAY_IDLE_FLAG=--quic-idle-timeout
	else
		RELAY_BIND=(--server-bind)
		RELAY_TLS=(--tls-generate)
		RELAY_GSO=(--server-quic-gso=false)
		RELAY_AUTH=(--auth-public '')
		RELAY_CC_FLAG=--server-quic-congestion-control
		RELAY_IDLE_FLAG=--server-quic-idle-timeout
	fi
	# `--auth-public` became a glob separately from the `--listen` rename: inside the `dev` branch
	# it is still a prefix, where `**` matches nothing and `""` matches everything.
	if [ "$RELAY_CLI_NEW" -eq 1 ] && [ -n "$relay" ] &&
		! "$relay" --help 2>&1 | grep -A3 -- '--auth-public <' | grep -q 'Patterns'; then
		RELAY_AUTH=(--auth-public '')
	fi
	RELAY_GREP='[m]oq-relay'
}

# moq_relay_public <bind-addr> <tls-name> [extra args...]
#
# The complete argv for a relay serving everything publicly, with GSO off and the congestion
# controller pinned (override with MOQ_CC=loss|delay). Use it rather than assembling the arrays by
# hand: the point is that forgetting one becomes impossible. Result lands in RELAY_ARGV.
moq_relay_public() {
	local bind="${1:?bind addr}" tls="${2:?tls name}"
	shift 2
	: "${RELAY_BIND:?call moq_cli_detect first}"
	RELAY_ARGV=("${RELAY_BIND[@]}" "$bind" "${RELAY_TLS[@]}" "$tls"
		"${RELAY_AUTH[@]}" "${RELAY_GSO[@]}"
		"$RELAY_CC_FLAG" "${MOQ_CC:-delay}" "$@")
}

# moq_relay_authed <bind-addr> <tls-name> [extra args...]
#
# As above but with no public grant, for the token and auth-API experiments where the whole point
# is that access is *not* public. Named explicitly so that a missing --auth-public is visibly a
# choice rather than the omission that produces a silent zero-byte lane.
moq_relay_authed() {
	local bind="${1:?bind addr}" tls="${2:?tls name}"
	shift 2
	: "${RELAY_BIND:?call moq_cli_detect first}"
	RELAY_ARGV=("${RELAY_BIND[@]}" "$bind" "${RELAY_TLS[@]}" "$tls" "${RELAY_GSO[@]}"
		"$RELAY_CC_FLAG" "${MOQ_CC:-delay}" "$@")
}

# moq_require_bytes <file> <min-bytes> <label>
#
# The cheap guard that would have caught the auth inversion, the localhost-redirect loop and the
# empty multicast group on the day each appeared. A lane that silently delivers nothing is
# indistinguishable from a lane that worked until something counts the capture, and a rig that
# grades an empty file reports a confident null. Returns non-zero so a cell can mark itself void.
moq_require_bytes() {
	local f="${1:?file}" min="${2:?min bytes}" label="${3:-capture}"
	local n
	n=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
	if [ "$n" -lt "$min" ]; then
		echo "VOID: $label captured ${n}B, under the ${min}B floor — this cell grades nothing" >&2
		return 1
	fi
	return 0
}

# moq_record_build <moq-binary> [relay-binary]
#
# One line naming the build and backend, for the head of every run log. Any figure crossing #3811
# carries a QUIC backend change, so the log has to say which side of it the run is on. The backend is
# read from the binary, not inferred from the CLI generation: `5d0991b9` has the new CLI and can be
# built on either stack. The old CLI lists its backends in `--help`; the new one does not, and links
# only the stack it was built with, so its protocol crate names it.
moq_record_build() {
	local moq="${1:?moq binary}" relay="${2:-}" bin backends s
	bin="${relay:-$moq}"
	echo "build: $("$moq" --version 2>&1 | head -1)${relay:+ / $("$relay" --version 2>&1 | head -1)}"
	backends=$("$bin" --help 2>&1 | grep -A12 -E -- '--(server|client)-backend ' |
		sed -nE 's/^ +- (quinn|noq|quiche|iroh):.*/\1/p' | sort -u | paste -sd, -)
	if [ -z "$backends" ]; then
		for s in quinn noq quiche; do
			grep -aq "$s-proto-\|/$s-[0-9]" "$bin" && backends="${backends:+$backends,}$s"
		done
	fi
	echo "backend: ${backends:-unknown}"
}

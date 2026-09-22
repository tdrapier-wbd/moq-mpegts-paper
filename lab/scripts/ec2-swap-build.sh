#!/usr/bin/env bash
# Repoint the standing units at a freshly built binary directory, on either EC2 host.
#
#   ec2-swap-build.sh <new-bin-dir>
#
# It supersedes `~/swap-to-main.sh`, which hardcoded both the source and destination paths and
# still listed `moq-publisher` — a unit retired in September because ffmpeg's default stream
# selection reduced a 13-PID mux to 5. A swap script that names units which no longer exist
# fails halfway, having already repointed some of them.
#
# This one derives the current binary prefix from the units themselves, so it works on either
# host and after any previous swap, and it only touches units that actually exist and are
# enabled. Unit files are backed up before any edit.
set -euo pipefail

NEW="${1:?new bin dir, e.g. /home/ubuntu/bin-d518b61b}"
[ -x "$NEW/moq" ] && [ -x "$NEW/moq-relay" ] || {
	echo "need both $NEW/moq and $NEW/moq-relay" >&2
	exit 2
}

echo "=== new build ==="
"$NEW/moq" --version
"$NEW/moq-relay" --version
echo "  (the version NUMBER is known to go stale in this tree; the -<sha> suffix is the authority)"

ALL=(moq-relay srt-ingest moq-live-publisher moq-publisher-cnn-loop)
UNITS=()
for u in "${ALL[@]}"; do
	[ -f "/etc/systemd/system/$u.service" ] && UNITS+=("$u")
done
echo "=== units present: ${UNITS[*]} ==="

# Which binary directory are they on now? Take it from the units rather than assuming.
CUR=$(grep -ho '/home/ubuntu/bin-[a-zA-Z0-9._-]*/' /etc/systemd/system/*.service 2>/dev/null |
	sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
echo "=== current prefix: ${CUR:-<none found>} ==="
if [ -z "$CUR" ]; then
	echo "no /home/ubuntu/bin-*/ prefix in any unit; nothing to rewrite. Inspect by hand." >&2
	exit 3
fi
if [ "$CUR" = "$NEW/" ]; then
	echo "already on $NEW — restarting only."
fi

BK="/home/ubuntu/systemd-backup-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BK"
for u in "${UNITS[@]}"; do sudo cp "/etc/systemd/system/$u.service" "$BK/"; done
echo "=== units backed up to $BK ==="

for u in "${UNITS[@]}"; do
	sudo sed -i "s#${CUR}#${NEW}/#g" "/etc/systemd/system/$u.service"
	printf "  %-26s %s\n" "$u" "$(grep -o "${NEW}/[a-z-]*" "/etc/systemd/system/$u.service" | tr '\n' ' ')"
done

# Post-#3793 renames CLI flags; migrate unit files when the new binary exposes them.
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"
moq_cli_detect "$NEW/moq" "$NEW/moq-relay"
if [ "$MOQ_CLI_NEW" -eq 1 ]; then
	echo "=== migrating unit flags to post-#3793 names ==="
	for u in "${UNITS[@]}"; do
		f="/etc/systemd/system/$u.service"
		sudo sed -i \
			-e 's/--server-bind/--listen/g' \
			-e 's/--tls-generate/--listen-tls-generate/g' \
			-e 's/--server-quic-gso=/--quic-gso=/g' \
			-e 's/--server-quic-congestion-control/--quic-congestion-control/g' \
			-e 's/--server-quic-idle-timeout/--quic-idle-timeout/g' \
			-e 's/--client-tls-disable-verify/--connect-tls-insecure/g' \
			-e 's/--client-connect/--connect/g' \
			-e 's/--client-tls-fingerprint/--connect-tls-fingerprint/g' \
			-e 's/--latency-max/--max-age/g' \
			"$f"
	done

	# The *value* inverted too, and renaming the flags without correcting it is precisely how
	# both standing relays came to accept every session and serve nothing. Pre-migration
	# `--auth-public ""` means "everything is public"; post-migration it means "nothing is".
	echo "=== correcting the inverted --auth-public value ==="
	for u in "${UNITS[@]}"; do
		f="/etc/systemd/system/$u.service"
		grep -q -- '--auth-public' "$f" || continue
		sudo sed -i -e "s/--auth-public ''/--auth-public '**'/g" \
			-e 's/--auth-public ""/--auth-public "**"/g' "$f"
		printf "  %-26s %s\n" "$u" "$(grep -o -- '--auth-public [^ ]*' "$f" | head -1)"
	done
fi

# A publisher dialling `localhost` at a relay whose certificate and advertised origin are its
# Elastic IP gets an immediate redirect and loops until it times out, while systemd reports the
# unit active throughout. Refuse to leave a unit in that state.
if grep -lq -- '--connect https://localhost' /etc/systemd/system/moq-*.service 2>/dev/null; then
	echo "!! a publisher unit dials https://localhost — it will loop on a redirect and deliver nothing." >&2
	echo "   Point it at the address on the relay certificate (this host's Elastic IP)." >&2
fi

sudo systemctl daemon-reload

# Order matters: the relay first, then the ingest stage, then the thing that publishes into it.
echo "=== restarting ==="
for u in moq-relay srt-ingest moq-live-publisher moq-publisher-cnn-loop; do
	[ -f "/etc/systemd/system/$u.service" ] || continue
	# Do not start something that was deliberately left stopped.
	if [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "disabled" ] &&
		[ "$(systemctl is-active "$u" 2>/dev/null)" != "active" ]; then
		echo "  $u: left stopped (disabled and inactive)"
		continue
	fi
	sudo systemctl restart "$u" || echo "  $u: restart returned non-zero"
	sleep 3
done

sleep 5
echo "=== state after ==="
FAIL=0
for u in "${UNITS[@]}"; do
	A=$(systemctl is-active "$u" 2>/dev/null)
	R=$(systemctl show "$u" -p NRestarts --value 2>/dev/null)
	printf "  %-26s %-10s restarts=%s\n" "$u" "$A" "$R"
	[ "$A" = "active" ] || [ "$u" = "moq-publisher-cnn-loop" ] || FAIL=1
done

# Prove the relay is the new binary and is actually serving, not merely "active".
sleep 2
if PID=$(systemctl show moq-relay -p MainPID --value 2>/dev/null) && [ "$PID" -gt 0 ]; then
	echo "  relay exe: $(sudo readlink -f "/proc/$PID/exe" 2>/dev/null)"
fi

[ "$FAIL" -eq 0 ] || {
	echo "!! a unit is not active — roll back with: sudo cp $BK/*.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl restart ${UNITS[*]}" >&2
	exit 4
}

# `is-active` is not evidence that a pipeline is carrying anything: all three units reported
# active with NRestarts=0 throughout the period when the chain delivered nothing. The swap is
# not finished until a subscriber has counted bytes off the relay this host is now running.
echo "=== proving the relay serves, not merely that it is active ==="
SELF=$(hostname -I | awk '{print $1}')
ORIGIN=$(grep -ho -- '--listen-tls-generate [^ ]*' /etc/systemd/system/moq-relay.service 2>/dev/null | awk '{print $2}')
ORIGIN=${ORIGIN:-$SELF}
LOOPBC=$(grep -ho -- '--broadcast [^ ]*' /etc/systemd/system/moq-publisher-cnn-loop.service 2>/dev/null | awk '{print $2}' | head -1)
if [ -n "$LOOPBC" ] && [ "$(systemctl is-active moq-publisher-cnn-loop 2>/dev/null)" = active ]; then
	# 25 s, not 15: the publisher has just been restarted, and its first loop plus the announce
	# reaching a fresh subscriber takes most of 20 s. A short window here reads as a dead chain.
	timeout 25 "$NEW/moq" --connect-tls-insecure --connect "https://$ORIGIN:443/anon" \
		--broadcast "$LOOPBC" export ts --max-age 2s >/tmp/swap-verify.ts 2>/tmp/swap-verify.log
	N=$(stat -c%s /tmp/swap-verify.ts 2>/dev/null || echo 0)
	echo "  recovered ${N} bytes from $LOOPBC"
	[ "$N" -gt 1000000 ] || {
		echo "!! the relay is active and serving nothing. Check --auth-public, then the publisher's dial address." >&2
		echo "   rollback set is $BK" >&2
		exit 5
	}
else
	echo "  no loop publisher running; verify by hand before trusting this chain (see INSTRUCTIONS.local.md)"
fi
echo "=== done; rollback set is $BK ==="

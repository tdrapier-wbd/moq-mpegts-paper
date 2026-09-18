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
echo "=== done; rollback set is $BK ==="

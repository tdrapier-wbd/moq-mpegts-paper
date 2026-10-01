#!/usr/bin/env bash
# T47 — the fixed-delay export across hosts: relay and importer on one host, the export on another,
# so the export's release clock and the source's pacing run on independent oscillators.
#
#   t47-xhost.sh origin <label> <bin-dir> <origin-public-ip> [seconds]   # on the origin host
#   t47-xhost.sh sub    <label> <bin-dir> <origin-public-ip> [seconds]   # on the subscriber host
#
# Start the origin first; it publishes for `seconds` + 40 and then stops itself. The subscriber
# exports for `seconds` and keeps egress.ts for grading (ts-tstd.py, compliance.py, tsp).
#
# env: PORT (4443, UDP, must be reachable between the hosts), CC (delay = BBRv3 on noq),
#      CLIP (~/CNNiEMEA2.ts), LAT (1s, the export's --delay or --max-age value),
#      OUT (~/t47/xhost), and any MOQ_TS_* variables, which reach the export unchanged.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROLE=${1:?origin or sub}
LABEL=${2:?label}
BIN=${3:?bin dir with moq and moq-relay}
IP=${4:?origin public ip}
SECS=${5:-120}
PORT=${PORT:-4443}
CC=${CC:-delay}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
LAT=${LAT:-1s}
OUT=${OUT:-$HOME/t47/xhost}/$LABEL
BCAST="t47.xhost.$LABEL.hang"

# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"

mkdir -p "$OUT"
{
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	[ -f "$BIN.sha" ] && echo "sha: $(cat "$BIN.sha")"
	echo "role=$ROLE label=$LABEL origin=$IP:$PORT cc=$CC lat=$LAT secs=$SECS host=$(hostname)"
	env | grep '^MOQ_TS_' | sort
	echo "started=$(date -Is)"
} >"$OUT/$ROLE-meta.txt"

case "$ROLE" in
origin)
	MOQ_CC=$CC moq_relay_public "0.0.0.0:$PORT" "$IP" --log-level info
	"$BIN/moq-relay" "${RELAY_ARGV[@]}" >"$OUT/relay.log" 2>&1 &
	RELAY_P=$!
	sleep 2
	# A relay still holding the port from an earlier run would carry this one and take it down
	# when that run's origin stops.
	kill -0 "$RELAY_P" 2>/dev/null || {
		echo "relay exited at start; is port $PORT still held by an earlier origin?" >&2
		exit 1
	}
	timeout $((SECS + 40)) bash -c "tsp --realtime -I file '$CLIP' -P regulate --pcr-synchronous -O file - 2>/dev/null \
		| '$BIN/moq' $(printf '%q ' "${MOQ_DIAL[@]}") https://$IP:$PORT --broadcast '$BCAST' import ts" \
		>"$OUT/import.log" 2>&1
	kill "$RELAY_P" 2>/dev/null
	;;
sub)
	timeout "$SECS" "$BIN/moq" "${MOQ_DIAL[@]}" "https://$IP:$PORT" --broadcast "$BCAST" \
		export ts "${MOQ_LAT[@]}" "$LAT" >"$OUT/egress.ts" 2>"$OUT/export.log"
	echo "export_rc=$? (124 = ran the window)" >>"$OUT/$ROLE-meta.txt"
	moq_require_bytes "$OUT/egress.ts" 1000000 "$LABEL" || true
	;;
*)
	echo "role must be origin or sub" >&2
	exit 2
	;;
esac
echo "finished=$(date -Is)" >>"$OUT/$ROLE-meta.txt"

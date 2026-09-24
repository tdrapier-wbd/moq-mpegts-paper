#!/usr/bin/env bash
# T41 — build one single-elementary-stream transport stream per stream kind, each with its
# own PCR, so an import failure can be attributed to a stream kind rather than to whichever
# of eight PIDs happened to abort first.
#
#   t41-make-fixtures.sh <source.ts> [outdir]
#
# The source needs an H.264 video PID, an MPEG-1/2 (legacy) audio PID and an AC-3 audio PID.
# `lab/scripts/t13-grade.py` or `tsp -P analyze` will name them.
#
# Two gotchas, both measured:
#
#   * `tsp -P filter` keeps the PIDs asked for but does not move the PCR, so an audio-only
#     filter output has no PCR at all (`pcrbitrate=0`) and is not a valid transport stream.
#     `-P pcradjust` does not help: it rewrites existing PCRs and cannot mint them.
#   * ffmpeg's mpegts muxer does synthesise a PCR PID, so the audio arms are remuxed with
#     ffmpeg and only the video arm — which already carries the PCR — is cut with `tsp`.
#
# Validate every fixture before use: a fixture with `pcrbitrate=0` measures nothing.
set -euo pipefail

SRC="${1:?source transport stream}"
OUTDIR="${2:-$HOME}"
VPID="${VPID:-111}"
LEGACY_PID="${LEGACY_PID:-121}"
MUXRATE="${MUXRATE:-400000}"

[ -f "$SRC" ] || {
	echo "no source at $SRC" >&2
	exit 2
}
command -v ffmpeg >/dev/null || {
	echo "ffmpeg is required for the audio arms" >&2
	exit 2
}

echo "--- video arm: PID $VPID carries the PCR, so tsp can cut it directly ---"
tsp -I file "$SRC" -P filter --pid 0 --pid 100 --pid "$VPID" -O file "$OUTDIR/fx-h264.ts"

echo "--- audio arms: remuxed so the muxer mints a PCR ---"
ffmpeg -y -loglevel error -i "$SRC" -map 0:a:0 -c copy -muxrate "$MUXRATE" \
	-f mpegts "$OUTDIR/fx-legacy.ts"
ffmpeg -y -loglevel error -i "$SRC" -map 0:a:1 -c copy -muxrate "$MUXRATE" \
	-f mpegts "$OUTDIR/fx-ac3.ts"

echo
printf '%-11s %12s %12s  %s\n' fixture bytes pcrbitrate verdict
for f in fx-h264 fx-legacy fx-ac3; do
	p="$OUTDIR/$f.ts"
	pcr=$(tsp -I file "$p" -P analyze --normalized -O drop 2>/dev/null |
		grep -m1 '^ts:' | tr ':' '\n' | sed -n 's/^pcrbitrate=//p')
	if [ "${pcr:-0}" -gt 0 ] 2>/dev/null; then
		verdict="ok"
	else
		verdict="NO PCR — unusable"
	fi
	printf '%-11s %12s %12s  %s\n' "$f" "$(stat -c%s "$p")" "${pcr:-0}" "$verdict"
done

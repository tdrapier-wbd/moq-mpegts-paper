#!/usr/bin/env bash
#
# T8b — standing-RTT-under-load probe.
#
# Goodput alone cannot distinguish a good controller from a bloated one: CUBIC will
# happily fill a 500 ms queue and still report full goodput. The headline result is
# goodput AND standing RTT measured over the SAME window, so this samples RTT through
# the shaped bottleneck while a capture runs.
#
#   sample   ping the target, log epoch,rtt_ms to CSV
#   summary  min / p50 / p95 / max / loss for one or more CSVs, side by side
#
# Usage:
#   ./t8b-rtt-probe.sh sample <target> <seconds> <out.csv>
#   ./t8b-rtt-probe.sh summary idle.csv cubic.csv bbr.csv
#
# IMPORTANT (real-path rig): ICMP only measures the bottleneck if it is steered into
# the same shaped band as the media — t8b-shaper.sh setup does this by default
# (WITH_ICMP=1). Without it the probe bypasses the queue and reports the idle path.
#
# The QUIC endpoints' own RTT estimate is the cross-check (RUST_LOG=moq_net=debug);
# ICMP is the transport-independent reference that SRT and MoQ runs share.

set -euo pipefail

INTERVAL="${INTERVAL:-0.2}"

usage() { sed -n '2,24p' "$0"; exit 1; }

sample() {
  local target="${1:-}" secs="${2:-}" out="${3:-}"
  [ -n "$target" ] && [ -n "$secs" ] && [ -n "$out" ] || usage

  echo "epoch,rtt_ms" > "$out"
  # -D timestamps each reply, -n skips DNS; count derived from interval
  local count
  count=$(awk -v s="$secs" -v i="$INTERVAL" 'BEGIN{printf "%d", s/i}')
  ping -n -D -i "$INTERVAL" -c "$count" "$target" 2>/dev/null \
    | awk -F'time=' '/time=/ {
        ts = $1; sub(/^\[/, "", ts); sub(/\].*$/, "", ts);
        rtt = $2; sub(/ *ms.*$/, "", rtt);
        printf "%s,%s\n", ts, rtt
      }' >> "$out" || true

  local got
  got=$(( $(wc -l < "$out") - 1 ))
  echo "t8b-rtt-probe: $out — $got/$count replies over ${secs}s"
}

summary() {
  [ "$#" -ge 1 ] || usage
  printf "%-24s %8s %8s %8s %8s %8s\n" file replies min_ms p50_ms p95_ms max_ms
  for f in "$@"; do
    awk -F, -v name="$(basename "$f")" '
      NR>1 && $2 != "" { v[n++] = $2 + 0 }
      END {
        if (n == 0) { printf "%-24s %8s\n", name, "0"; exit }
        asort_n(v, n)
        printf "%-24s %8d %8.1f %8.1f %8.1f %8.1f\n",
          name, n, v[0], v[int(n*0.50)], v[int(n*0.95)], v[n-1]
      }
      function asort_n(a, len,   i, j, t) {
        for (i = 1; i < len; i++) {
          t = a[i]
          for (j = i - 1; j >= 0 && a[j] > t; j--) a[j+1] = a[j]
          a[j+1] = t
        }
      }' "$f"
  done
  echo
  echo "Reference: base RTT = 2 x the one-way netem delay. A controller holding standing"
  echo "RTT near that base is not bloating; one drifting toward base + queue depth is."
}

cmd="${1:-}"; shift || true
case "$cmd" in
  sample)  sample "$@" ;;
  summary) summary "$@" ;;
  *) usage ;;
esac

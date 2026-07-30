#!/usr/bin/env bash
#
# T8b — shaped-bottleneck (bufferbloat) lane for the media flows only.
#
# Builds a rate-limited, delayed, deep-queued path for the MoQ/SRT egress flows on a
# SHARED Linux host without touching SSH or anything else: a `prio` root leaves all
# default traffic in band 1, and explicit u32 filters steer only the media five-tuples
# into shaped band 4.
#
# Chain under band 4:  netem (base one-way delay) -> htb (bottleneck rate) -> leaf queue
#
#   bloat  bfifo sized to QUEUE_MS at RATE  — the headline bufferbloat condition (6a)
#   codel  fq_codel                         — AQM counterfactual, same bottleneck (6b)
#   cake   cake bandwidth RATE              — cake shapes and manages the queue itself
#
# The RTT probe only measures the shaped queue if its packets share that queue, so
# `setup` also steers ICMP to DSTIP into band 4 (disable with WITH_ICMP=0).
#
# Usage:
#   DSTIP=<subscriber-ip> ./t8b-shaper.sh setup     # prio root + filters (idempotent)
#   DSTIP=<subscriber-ip> ./t8b-shaper.sh bloat     # apply/replace the bottleneck
#   ./t8b-shaper.sh codel | cake | show | clear
#
# Env: IFACE (ens5) DSTIP(required) SPORTS("443 9010") RATE_MBIT(5) DELAY_MS(50)
#      QUEUE_MS(500) WITH_ICMP(1) WATCHDOG_MIN(90)

set -euo pipefail

IFACE="${IFACE:-ens5}"
SPORTS="${SPORTS:-443 9010}"
RATE_MBIT="${RATE_MBIT:-5}"
DELAY_MS="${DELAY_MS:-50}"
QUEUE_MS="${QUEUE_MS:-500}"
WITH_ICMP="${WITH_ICMP:-1}"
WATCHDOG_MIN="${WATCHDOG_MIN:-90}"

RATE="${RATE_MBIT}mbit"
# bytes that fit in QUEUE_MS at RATE — the bufferbloat knob (500 ms @ 5 Mb/s = 312500 B)
QBYTES=$(( QUEUE_MS * RATE_MBIT * 1000000 / 8 / 1000 ))
WD_PIDFILE="/tmp/t8b-shaper-watchdog.${IFACE}.pid"

TC=$(command -v tc || echo /sbin/tc)
[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo"

die() { echo "t8b-shaper: $*" >&2; exit 1; }
need_dstip() { [ -n "${DSTIP:-}" ] || die "DSTIP is required (the subscriber IP)"; }

# ---------------------------------------------------------------- root + filters

setup() {
  need_dstip
  clear_all

  # Band 1 carries everything by default (SSH included); band 4 is the shaped lane.
  $SUDO "$TC" qdisc add dev "$IFACE" root handle 1: prio bands 4 \
    priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0

  for sport in $SPORTS; do
    $SUDO "$TC" filter add dev "$IFACE" parent 1:0 protocol ip prio 1 u32 \
      match ip protocol 17 0xff \
      match ip sport "$sport" 0xffff \
      match ip dst "$DSTIP"/32 \
      flowid 1:4
  done

  if [ "$WITH_ICMP" = "1" ]; then
    # so t8b-rtt-probe.sh traverses the same bottleneck queue as the media
    $SUDO "$TC" filter add dev "$IFACE" parent 1:0 protocol ip prio 2 u32 \
      match ip protocol 1 0xff \
      match ip dst "$DSTIP"/32 \
      flowid 1:4
  fi

  arm_watchdog
  echo "t8b-shaper: lane up on $IFACE -> $DSTIP (udp sport: $SPORTS, icmp: $WITH_ICMP)"
  echo "t8b-shaper: no bottleneck applied yet — run 'bloat', 'codel' or 'cake'"
}

# ------------------------------------------------------------------ bottleneck

# $1 = leaf mode
apply() {
  local mode="$1"
  $SUDO "$TC" qdisc show dev "$IFACE" | grep -q 'prio 1:' \
    || die "run 'setup' first (no prio root on $IFACE)"

  # replace whatever is under band 4
  $SUDO "$TC" qdisc del dev "$IFACE" parent 1:4 2>/dev/null || true

  # stage 1 — base one-way delay. limit is deliberately huge: this stage must not
  # drop, the bottleneck queue below is what we are measuring.
  $SUDO "$TC" qdisc add dev "$IFACE" parent 1:4 handle 40: \
    netem delay "${DELAY_MS}ms" limit 100000

  if [ "$mode" = "cake" ]; then
    # cake is its own shaper + AQM, so it replaces the htb stage
    $SUDO "$TC" qdisc add dev "$IFACE" parent 40:1 handle 50: cake bandwidth "$RATE"
  else
    # stage 2 — the bottleneck itself
    $SUDO "$TC" qdisc add dev "$IFACE" parent 40:1 handle 50: htb default 1
    $SUDO "$TC" class add dev "$IFACE" parent 50: classid 50:1 \
      htb rate "$RATE" ceil "$RATE" burst 15k
    # stage 3 — the queue discipline under test
    case "$mode" in
      bloat) $SUDO "$TC" qdisc add dev "$IFACE" parent 50:1 handle 60: bfifo limit "$QBYTES" ;;
      codel) $SUDO "$TC" qdisc add dev "$IFACE" parent 50:1 handle 60: fq_codel ;;
      *)     die "unknown mode '$mode' (bloat|codel|cake)" ;;
    esac
  fi

  arm_watchdog
  echo "t8b-shaper: $mode — rate=$RATE base-delay=${DELAY_MS}ms/direction queue=${QUEUE_MS}ms (${QBYTES}B)"
  echo "t8b-shaper: expect ~$(( DELAY_MS * 2 )) ms idle RTT before the real path RTT is added"
}

# ---------------------------------------------------------------------- teardown

clear_all() {
  disarm_watchdog
  $SUDO "$TC" qdisc del dev "$IFACE" root 2>/dev/null || true
  echo "t8b-shaper: cleared $IFACE"
}

# A shaped lane left behind on a shared host is a trap for the next person; always
# self-clear unless explicitly disabled (WATCHDOG_MIN=0).
arm_watchdog() {
  disarm_watchdog
  [ "$WATCHDOG_MIN" -gt 0 ] || return 0
  $SUDO setsid bash -c \
    "sleep $(( WATCHDOG_MIN * 60 )); $TC qdisc del dev $IFACE root 2>/dev/null" \
    >/dev/null 2>&1 &
  echo $! > "$WD_PIDFILE"
}

disarm_watchdog() {
  [ -f "$WD_PIDFILE" ] || return 0
  $SUDO kill "$(cat "$WD_PIDFILE")" 2>/dev/null || true
  rm -f "$WD_PIDFILE"
}

show() {
  echo "== qdisc =="  ; $SUDO "$TC" -s qdisc show dev "$IFACE"
  echo "== class =="  ; $SUDO "$TC" -s class show dev "$IFACE" 2>/dev/null || true
  echo "== filter ==" ; $SUDO "$TC" filter show dev "$IFACE" parent 1:0 2>/dev/null || true
}

case "${1:-}" in
  setup) setup ;;
  bloat|codel|cake) apply "$1" ;;
  show)  show ;;
  clear) clear_all ;;
  *) sed -n '2,30p' "$0"; exit 1 ;;
esac

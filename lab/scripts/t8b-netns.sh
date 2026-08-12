#!/usr/bin/env bash
#
# T8b — self-contained bufferbloat rig in two network namespaces on one Linux host.
#
# A bufferbloat test measures a queue, not a geography: the 100 ms base RTT is supplied
# by netem either way, so running both endpoints locally removes access-link variability
# and makes the result reproducible on any Linux box. Prefer this over the real-path
# rig (t8b-shaper.sh) unless a real-path number is specifically wanted.
#
#   ns t8b-pub (10.99.0.1) ==veth== ns t8b-sub (10.99.0.2)
#
#   pub -> sub (downstream, the media direction): netem delay -> htb rate -> leaf queue
#   sub -> pub (upstream, acks only):             netem delay
#   => base RTT = 2 x DELAY_MS, bottleneck and queue on the downstream only.
#
# Usage:
#   sudo ./t8b-netns.sh up            # create namespaces + veth (no bottleneck yet)
#   sudo ./t8b-netns.sh bloat         # apply/replace the bottleneck (or: codel | cake)
#   sudo ./t8b-netns.sh pub <cmd...>  # run the relay/publisher side
#   sudo ./t8b-netns.sh sub <cmd...>  # run the subscriber side
#   sudo ./t8b-netns.sh show
#   sudo ./t8b-netns.sh down
#
# Env: RATE_MBIT(5) DELAY_MS(50) QUEUE_MS(500)

set -euo pipefail

NS_PUB="t8b-pub"
NS_SUB="t8b-sub"
VETH_PUB="veth-pub"
VETH_SUB="veth-sub"
IP_PUB="10.99.0.1"
IP_SUB="10.99.0.2"
PREFIX=24

RATE_MBIT="${RATE_MBIT:-5}"
DELAY_MS="${DELAY_MS:-50}"
QUEUE_MS="${QUEUE_MS:-500}"

RATE="${RATE_MBIT}mbit"
QBYTES=$(( QUEUE_MS * RATE_MBIT * 1000000 / 8 / 1000 ))

[ "$(id -u)" -eq 0 ] || { echo "t8b-netns: run as root" >&2; exit 1; }

die() { echo "t8b-netns: $*" >&2; exit 1; }

up() {
  down >/dev/null 2>&1 || true

  ip netns add "$NS_PUB"
  ip netns add "$NS_SUB"
  ip link add "$VETH_PUB" type veth peer name "$VETH_SUB"
  ip link set "$VETH_PUB" netns "$NS_PUB"
  ip link set "$VETH_SUB" netns "$NS_SUB"

  ip -n "$NS_PUB" addr add "$IP_PUB/$PREFIX" dev "$VETH_PUB"
  ip -n "$NS_SUB" addr add "$IP_SUB/$PREFIX" dev "$VETH_SUB"
  for pair in "$NS_PUB $VETH_PUB" "$NS_SUB $VETH_SUB"; do
    set -- $pair
    ip -n "$1" link set lo up
    ip -n "$1" link set "$2" up
    # segmentation offload defers work to the NIC and defeats accurate tc shaping
    ip netns exec "$1" ethtool -K "$2" tso off gso off gro off >/dev/null 2>&1 || true
  done

  # upstream: base delay only (acks)
  ip netns exec "$NS_SUB" tc qdisc add dev "$VETH_SUB" root \
    netem delay "${DELAY_MS}ms" limit 100000

  echo "t8b-netns: up — pub=$IP_PUB sub=$IP_SUB, base RTT ~$(( DELAY_MS * 2 )) ms"
  echo "t8b-netns: no bottleneck applied yet — run 'bloat', 'codel' or 'cake'"
}

apply() {
  local mode="$1"
  ip netns list | grep -q "$NS_PUB" || die "run 'up' first"

  ip netns exec "$NS_PUB" tc qdisc del dev "$VETH_PUB" root 2>/dev/null || true

  # stage 1 — base one-way delay; must not drop, the bottleneck queue below is the subject
  ip netns exec "$NS_PUB" tc qdisc add dev "$VETH_PUB" root handle 1: \
    netem delay "${DELAY_MS}ms" limit 100000

  if [ "$mode" = "cake" ]; then
    ip netns exec "$NS_PUB" tc qdisc add dev "$VETH_PUB" parent 1:1 handle 10: \
      cake bandwidth "$RATE"
  else
    ip netns exec "$NS_PUB" tc qdisc add dev "$VETH_PUB" parent 1:1 handle 10: htb default 1
    ip netns exec "$NS_PUB" tc class add dev "$VETH_PUB" parent 10: classid 10:1 \
      htb rate "$RATE" ceil "$RATE" burst 15k
    case "$mode" in
      bloat) ip netns exec "$NS_PUB" tc qdisc add dev "$VETH_PUB" parent 10:1 handle 20: \
               bfifo limit "$QBYTES" ;;
      codel) ip netns exec "$NS_PUB" tc qdisc add dev "$VETH_PUB" parent 10:1 handle 20: \
               fq_codel ;;
      *) die "unknown mode '$mode' (bloat|codel|cake)" ;;
    esac
  fi

  echo "t8b-netns: $mode — rate=$RATE delay=${DELAY_MS}ms/direction queue=${QUEUE_MS}ms (${QBYTES}B)"
}

show() {
  echo "== $NS_PUB downstream ($VETH_PUB) =="
  ip netns exec "$NS_PUB" tc -s qdisc show dev "$VETH_PUB"
  ip netns exec "$NS_PUB" tc -s class show dev "$VETH_PUB" 2>/dev/null || true
  echo "== $NS_SUB upstream ($VETH_SUB) =="
  ip netns exec "$NS_SUB" tc -s qdisc show dev "$VETH_SUB"
}

down() {
  ip netns del "$NS_PUB" 2>/dev/null || true
  ip netns del "$NS_SUB" 2>/dev/null || true
  ip link del "$VETH_PUB" 2>/dev/null || true
  echo "t8b-netns: down"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)   up ;;
  bloat|codel|cake) apply "$cmd" ;;
  pub)  exec ip netns exec "$NS_PUB" "$@" ;;
  sub)  exec ip netns exec "$NS_SUB" "$@" ;;
  show) show ;;
  down) down ;;
  *) sed -n '2,26p' "$0"; exit 1 ;;
esac

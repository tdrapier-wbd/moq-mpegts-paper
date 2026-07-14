# Relay

Status: working draft
Scope: the relay layer of the data plane — the component that performs
subscription-based fan-out and forwarding. This is the deep-dive companion to
[architecture](architecture.md) §5–§6; it assumes that context and develops the
relay-specific detail (topology, routing, resilience, capacity, and failure
behaviour) rather than restating the end-to-end system.

---

## 1. Purpose

The relay resembles commodity QUIC/HTTP-3 CDN infrastructure — in sharing the
substrate and commoditising trajectory, not in being a config-flag feature of an
existing HTTP cache. A MoQ relay is a *stateful live-subscription service*, not an
HTTP/3 object cache. Its job is narrow: terminate MoQ sessions, maintain per-track
subscription state, forward objects, and cache recent objects for late or
recovering subscribers. It does *not* groom for IRD conformance, transcode, or
make entitlement decisions beyond enforcing the authorization the control plane
already granted ([architecture](architecture.md) §5.4). Keeping the relay "dumb
and fast" lets the differentiated broadcast-grade logic live at the edge
([architecture](architecture.md) §7) and in the control plane — consistent with
the thesis that value migrates up the stack ([vision](vision.md) §6).

Its placement in the end-to-end path is between publishers and edge gateways: a
publisher publishes to a relay, relays fan the track out across the fabric, and
an edge gateway (or native subscriber) subscribes from the nearest relay.

## 2. Topology

The topology should be no more elaborate than the destination footprint
requires, and the sensible default is deliberately simple. In our practice to
date, a route is provisioned as a **redundant pair of flows** and endpoints
egress directly from those — the same pattern used with managed services such as
AWS MediaConnect, where a feed is carried flow-to-flow and region-to-region
across the provider backbone without any purpose-built relay hierarchy. For a
bounded, known set of destinations this is sufficient, and it keeps the topology,
the operational surface, and the cost model simple. A tree of relays is not free:
each additional fan-out point amplifies egress, so imposing a hierarchy where the
destination count does not warrant it adds cost without benefit.

The tiered fabric below is therefore an **option, not a requirement**. It becomes
appropriate specifically when there is a large number of destinations spread
across many geographies, where fanning out from a single pair of flows would
amplify egress and repeatedly cross expensive inter-region links. Where that
applies, relays can be organised into three tiers, though the boundaries are
logical rather than physical:

- **Core relays** sit close to publishers and to inter-region links. They carry
  aggregated traffic and are optimised for throughput and path diversity.
- **Regional relays** aggregate demand within a region so that a track crossing
  into the region traverses the expensive inter-region link once, regardless of
  how many endpoints in that region subscribe.
- **Edge relays** sit closest to endpoints and feed edge gateways. In some
  deployments the edge relay and edge gateway are co-located.

Where this fabric is used, relays within a region form a **cluster** that shares
subscription and cache state; clusters interconnect as a **mesh** to form the
fabric. That shared state is a property the platform has to implement and
operate — cross-relay subscription tracking, cache coherence, and consistent
behaviour under partition are distributed-systems work, not something the base
MoQ transport hands us for free; MoQ contributes the relay and subscription
semantics that such a cluster is built on. The mesh is not a static tree: a subscription propagates upstream toward
the publisher only as far as necessary, attaching to an existing flow wherever
one already carries the track. This is the mechanism by which fan-out scales
without re-originating traffic, and it is described with a diagram in
[architecture](architecture.md) §5.1. Its value is precisely at the scale that
justifies the added tiers; below that scale it is overhead, and the
redundant-pair model above is preferable.

A design tension worth naming, once a fabric is in play: co-locating edge relay
and edge gateway reduces the last-hop latency and simplifies operations, but
couples the commodity fan-out layer to the timing-sensitive grooming layer, which
have different scaling and failure characteristics (§6). Where a deployment
expects heavy grooming load, keeping them separate is preferable.

## 3. Data-path behaviour

### 3.1 Subscription flow

A subscriber presents a path-scoped token and subscribes to a track. The relay
validates the token's scope and expiry (deny-by-default; see
[entitlement](entitlement.md)) and, if valid, either attaches the subscriber to
an existing flow for that track or propagates the subscription upstream to obtain
it. Objects then flow downstream to the subscriber as they arrive.

### 3.2 Caching and forwarding

Relays cache recent objects so that a newly attached or recovering subscriber can
start promptly and recover from limited loss without a round-trip to the
publisher. For live linear primary distribution the cache is deliberately
*small* and retention *short*: the endpoints are live feeds where falling seconds
behind is itself a fault, so the cache is a recovery buffer, not a time-shift
store. The trade-off is between start-up latency, memory cost, and how far behind
live a recovering subscriber is permitted to fall.

### 3.3 Prioritisation and scheduling

QUIC's per-stream delivery lets a relay forward objects without one stream's loss
blocking another, and MoQ's prioritisation schedules higher-priority content ahead
of lower under contention — the contrast being a single strictly-ordered reliable
stream where recovery serialises everything behind a loss (not a claim that SRT,
Zixi, and RIST all block this way; see [transport](transport.md) §3.1). This
advantage is realised on the **default media-aware lane**, which exposes the
individual tracks a relay can prioritise. On the **opaque fallback lane**
([transport](transport.md) §4), a programme is a single object stream, so
relay-level prioritisation is useful only *across* tracks, not *within* a
programme — a limitation of the fallback, not of MoQ.

## 4. Routing strategy

The baseline is shortest-path routing over the cluster mesh. MoQ's relay and
subscription semantics are the building blocks, but the routing, shared state,
and failure behaviour of a multi-region mesh are implemented and operated by the
platform rather than provided by the base transport. On top of that baseline, the
control plane layers policy-aware routing ([architecture](architecture.md) §5.2, and
[control-plane](control-plane.md) §5.2):

- **Path selection** prefers the lowest-latency healthy path by default.
- **Policy constraints** may pin a route to particular regions (data sovereignty,
  rights), require two link-disjoint paths (redundancy), or exclude a degraded
  link.
- **Congestion-aware rerouting** shifts subscriptions away from links reporting
  elevated loss or latency, within the bounds the policy permits.

The deliberate division of responsibility is that *reachability and fan-out* live
in the transport/relay layer (efficient, commoditised) while *policy* lives in the
control plane (changes frequently, must survive a transport swap). Encoding
rights or sovereignty policy into the relay itself is rejected for both reasons.

## 5. Resilience model

Relay resilience is one layer of the end-to-end redundancy described in
[architecture](architecture.md) §14; it is not sufficient on its own.

- **Redundancy patterns.** For contracted content the fabric carries a route over
  two link-disjoint paths so that a single link, relay, or region impairment does
  not interrupt delivery. With active/active ingest, both paths are live and there
  is no failover-detection latency on the critical path.
- **Hitless switching lives at the edge, not the relay.** The relay's job is to
  keep both disjoint flows healthy; the *hitless* selection between them is
  performed at the egress as an ST 2022-7 dual-path hand-off to the IRD
  ([architecture](architecture.md) §14.1). This placement is deliberate: the IRD
  already implements ST 2022-7 seamless switching, so the last-hop failover
  requires no new receiver behaviour.
- **Degradation behaviour.** Under loss that redundancy cannot mask, QUIC's
  per-stream delivery degrades rather than stalls; the opaque-lane limitation of
  §3.3 applies.

## 6. Capacity planning

- **Throughput model.** Core and regional relays are throughput-bound and scale
  horizontally; their capacity is dominated by aggregate forwarded bandwidth and
  connection count.
- **Fan-out model.** Because a track is carried into a region once and fanned out
  locally, per-region egress scales with local subscriber count while inter-region
  bandwidth scales with the number of *distinct tracks* crossing the boundary, not
  the number of subscribers. This is the property that makes 1:N economical.
- **Hotspot mitigation.** A single popular track in a region is served from the
  regional cache/flow; hotspots are mitigated by adding edge relays and by cache
  fan-out within a cluster rather than by re-originating from the publisher.

Note the contrast with the edge gateway, whose capacity is dominated by
real-time timing headroom rather than throughput ([architecture](architecture.md)
§7.3). Relay and gateway therefore scale on different axes and should be
capacity-planned separately.

## 7. Operational controls

- **Admission control.** Relays admit subscriptions only within the tenant's
  quota and only with a valid entitlement; excess or unauthorised subscriptions
  are refused rather than best-effort served.
- **Rate limiting.** Per-tenant and per-connection limits bound the blast radius
  of a misbehaving publisher, subscriber, or automation loop
  ([control-plane](control-plane.md) §4.2).
- **Circuit breakers.** A relay that detects a persistently failing upstream or
  downstream path sheds or reroutes the affected subscriptions rather than
  amplifying the failure, and reports the state to observability.

## 8. Metrics and SLOs

The relay-specific signals that matter, feeding the observability model in
[operations](operations.md):

- **Relay/path latency budget** — added latency per relay hop and end-to-end
  across the fabric, so the total stays within the route's latency SLO.
- **Object/loss budget** — object loss and retransmission rates per path, as an
  early indicator before a broadcast-domain symptom appears at the gateway.
- **Cache hit/miss** — hit rate for late-subscriber and recovery serving, which
  bounds start-up latency and publisher back-pressure.
- **Subscription and session counts** — per track and per tenant, for capacity
  and hotspot detection.

As with the control-plane SLOs, specific numeric targets are deployment-specific
and should be treated as hypotheses to validate rather than committed figures.

## 9. Failure scenarios

- **Regional failure.** Routes are re-homed to another region by the control
  plane's routing engine; endpoints in the failed region are served by gateways in
  a neighbouring region at the cost of added path latency
  ([architecture](architecture.md) §14.3).
- **Link impairment.** The disjoint second path continues to deliver while the
  fabric reroutes affected subscriptions around the impaired link.
- **Overload.** Admission control and quotas cap load; excess demand is refused
  deterministically rather than degrading all tenants.
- **Control/data-plane partition.** Relays continue forwarding established flows
  on last-known-good state; only *new* subscriptions and policy changes are
  suspended until the control plane recovers ([architecture](architecture.md)
  §9.2). Existing entitlements remain valid until natural expiry, which is why the
  entitlement backstop ([entitlement](entitlement.md) §5) matters.

## 10. Open questions

- How much of MoQ's prioritisation/graceful-degradation advantage is recoverable
  under opaque transport-stream carriage, and does a media-aware secondary lane
  justify its interop cost to regain it? (Shared with [transport](transport.md) §8.)
- What cache size and retention best balance start-up latency against
  "how far behind live" for the specific case of live linear feeds?
- How well does mesh rerouting behave under *correlated* multi-path impairment
  (a shared upstream provider or a large BGP event), which disjoint-path routing
  reduces but does not eliminate ([architecture](architecture.md) §14.4)?

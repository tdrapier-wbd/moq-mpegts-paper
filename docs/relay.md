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

The clustering primitives this rests on are **shipped** in `moq-relay`
(`rs/moq-relay/src/cluster.rs`): a relay dials peers listed in `cluster.connect`
(full URLs), optionally discovers them by gossip (`cluster.node` + `cluster.mesh`)
or an external `cluster.connect_api` list, and prices links with `?cost=N`. Each
dial is a **bidirectional** session (the relay both publishes local content to the
peer and subscribes to the peer's announcements), configured peers **reconnect
forever** with 1 s→300 s backoff, and a stable `cluster.id` keeps a relay's
hop-chain identity across restarts. This was exercised directly: a two-relay
anonymous cluster formed over loopback, negotiated `moq-lite-05`, and carried the
media-aware TS feed end to end to subscribers on the far relay
([test-plan](test-plan.md) §10.5.2). So the *plumbing* of a mesh is real; what is
not yet delivered is automatic **source failover** across it (§4.1, §5.1).

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

### 4.1 Route reselection, standby routing, and the `moq-lite-06` state (measured)

The relay's forwarding core already contains a **multi-source route table**: an
origin holds every route it knows for a broadcast path and picks a winner by
`route_order` = (announced-before-offline, then cumulative **cost**, then hop-chain
length, then a stable hash tie-break), with the losers parked as silent standbys
(`rs/moq-net/src/model/origin.rs`, `best_route`/`reselect`). When a better route
attaches or the active source dies, `reselect` promotes the winner and live tracks
**re-splice at the next group boundary** — a behaviour covered by the unit test
`test_route_failover`. On paper this is exactly the standby-and-failover mechanism a
redundant fabric needs.

**What the drills showed, though, is that the shipped default wire does not *feed*
that table a second live route for the same broadcast** ([test-plan](test-plan.md)
§10.5.3). Two publishers on one relay do not form a standby pair — the second
announce makes the path `unroutable` and tears down both. Across a two-relay mesh the
pair coexists, but when the active publisher dies the carrying relay does **not**
fail over: announcements are **coalesced to one best route per path**, and the
split-horizon loop filter (`exclude_hop`) suppresses the return announcement, so the
relay serving the active source never learns the standby route and has nothing to
reselect. Route reselection therefore works *within an origin that already holds two
routes*, but the `moq-lite-05` topology does not put two routes for one broadcast in
front of the relay that needs them.

**Cost/standby routing (`moq-lite-06`) is necessary but not sufficient — tested.** The
intended ranking mechanism is explicit cost: `broadcast::Route` carries a cost a
standby seeds high (a cold transcoder, a warm backup) and that drops to 0 once it
starts carrying, so a standby is selected only when nothing cheaper exists
(`rs/moq-net/src/model/broadcast.rs`, `rs/moq-net/src/lite/announce.rs`; landed as
#2424). It lives in `moq-lite-06-wip`, which is **deliberately excluded from the default
advertised set and ALPN list** (`rs/moq-net/src/version.rs` — `Versions::all()` and
`ALPNS` both omit it, with a comment noting it is "otherwise a fully-defined version …
an opt-in set that includes it negotiates normally") and negotiates **only when both
peers opt in** via `--server-version` / `--client-version`. Re-running the two-relay
mesh drill with lite-06 negotiated end-to-end (cluster log:
`connected version=moq-lite-06-wip`) behaved **identically to `moq-lite-05`**: the pair
coexisted and then froze permanently on `pubA` death, with relay A's session log
showing it only ever held its **own** local route — relay B never advertised its
standby publisher across the cluster link ([test-plan](test-plan.md) §10.5.4). Cost
routing had nothing to rank, because the missing piece is **standby-route propagation
across the mesh**, not route pricing. So on `moq-dev @ 5eaf99bc`, cost-weighted
standby routing is real and negotiable but does **not** by itself deliver active/active
source failover; the standby-route propagation gap described above is the blocker, and
hop-based shortest-path routing is what runs by default.

## 5. Resilience model

Relay resilience is one layer of the end-to-end redundancy described in
[architecture](architecture.md) §14; it is not sufficient on its own.

- **Redundancy patterns.** For contracted content the fabric carries a route over
  two link-disjoint paths so that a single link, relay, or region impairment does
  not interrupt delivery. With active/active ingest, both paths are live and there
  is no failover-detection latency on the critical path. This is the *target*; the
  measured state (§5.1) is that the two live paths must be combined **downstream**
  (ST 2022-7 / IRD), because the relay does not yet perform the hitless switch
  itself on the shipped wire (§4.1).
- **Hitless switching lives at the edge, not the relay.** The relay's job is to
  keep both disjoint flows healthy; the *hitless* selection between them is
  performed at the egress as an ST 2022-7 dual-path hand-off to the IRD
  ([architecture](architecture.md) §14.1). This placement is deliberate: the IRD
  already implements ST 2022-7 seamless switching, so the last-hop failover
  requires no new receiver behaviour.
- **Degradation behaviour.** Under loss that redundancy cannot mask, QUIC's
  per-stream delivery degrades rather than stalls; the opaque-lane limitation of
  §3.3 applies. **Congestion-control choice is decisive here.** Because MoQ is
  hop-by-hop QUIC and CC is sender-local, a relay facing a lossy downstream can run
  **BBR** on that hop (`--server-quic-congestion-control delay`, §7), using the short
  relay-edge RTT as the retransmit loop rather than an end-to-end window. In testing,
  the default loss-based CUBIC collapsed under uniform loss/reordering/WAN while BBR
  held full rate on par with SRT — a per-connection change with no wire/interop impact
  ([transport](transport.md) §3.1, [test-plan](test-plan.md) §12.10,
  [evidence](evidence.md) §7).

### 5.1 Measured failover and reconnect behaviour (2026-07-23)

Drills on the media-aware lane ([test-plan](test-plan.md) §10.5,
[evidence](evidence.md) §8) pin down what the resilience model delivers *today*
versus what it is designed to deliver, and the two are not yet the same.

- **Confirmed working.** Fan-out to multiple subscribers is byte-identical and
  continuous (redundant *outputs* are free). A `moq import ts` **publisher survives a
  relay restart** — its reconnect loop redials and re-announces automatically. A
  two-relay cluster forms and carries the feed.
- **Confirmed limitation — no hitless source failover on `moq-lite-05`.** As §4.1
  details, neither a single-relay duplicate publisher nor a two-relay mesh gives
  automatic active/active source failover on the shipped wire; the relay keeps the
  active flow healthy but does not switch to a standby when the active source dies.
- **Confirmed limitation — the subscriber does not survive session loss.** A relay
  restart **kills every `moq export ts` subscriber** (`Error: json: dropped`): the
  transport reconnect loop is alive but the exporter's container pipeline treats the
  dropped catalog as fatal ([transport](transport.md) §8.3). This is a client-side
  bug filed upstream, but it means "keep both disjoint flows healthy" is currently
  undercut at the *edge subscriber*, not at the relay.

The consequence for this document's resilience model is a sharpening, not a reversal:
the relay's job — **keep the flows healthy and let hitless selection happen at the
edge** — is the right split, and the drills confirm the relay carries redundant flows
and reconnects publishers. But **the hitless switch must live downstream (ST 2022-7 /
IRD, [architecture](architecture.md) §14.1), because relay-mesh source failover is
not available today**, and the edge subscriber needs external supervision until the
exporter reconnect bug is fixed. The broadcast-grade posture is therefore the
fully-doubled chain (dual publishers, dual relays, dual pacers, receiver-side hitless
selection), with the relay providing reach, caching, fan-out, and per-leg transport
resilience rather than the switch itself.

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
- **Congestion control.** The relay's QUIC congestion controller is selectable per
  deployment ([PR #2432](https://github.com/moq-dev/moq/pull/2432)):
  `--server-quic-congestion-control {loss|delay}` (`loss` = CUBIC, `delay` = BBR).
  For relays serving lossy last-mile paths, **`delay` (BBR) is the recommended
  default** — it removed the loss/reorder/WAN throughput collapse in testing (§5,
  [test-plan](test-plan.md) §12.10) — and, being sender-local, it changes nothing on
  the wire and preserves interop with any QUIC subscriber.

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
  justify its interop cost to regain it? (Shared with [transport](transport.md) §9.)
- What cache size and retention best balance start-up latency against
  "how far behind live" for the specific case of live linear feeds?
- How well does mesh rerouting behave under *correlated* multi-path impairment
  (a shared upstream provider or a large BGP event), which disjoint-path routing
  reduces but does not eliminate ([architecture](architecture.md) §14.4)?

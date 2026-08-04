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
hop-chain identity across restarts. A two-relay anonymous cluster forms and carries the
media-aware TS feed end to end to subscribers on the far relay
([lab: T6](../lab/test-6-relay-resilience.md)). So the *plumbing* of a mesh is real; what is
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

### 4.1 Route reselection, standby routing, and source failover

The relay's forwarding core already contains a **multi-source route table**: an
origin holds every route it knows for a broadcast path and picks a winner by
`route_order` = (announced-before-offline, then cumulative **cost**, then hop-chain
length, then a stable hash tie-break), with the losers parked as silent standbys
(`rs/moq-net/src/model/origin.rs`, `best_route`/`reselect`). When a better route
attaches or the active source dies, `reselect` promotes the winner and live tracks
**re-splice at the next group boundary** — a behaviour covered by the unit test
`test_route_failover`. On paper this is exactly the standby-and-failover mechanism a
redundant fabric needs.

**On the shipped default wire, though, that table is never *fed* a second live route
for the same broadcast** ([lab: T6](../lab/test-6-relay-resilience.md)).
Two publishers on one relay do not form a standby pair — the second
announce makes the path `unroutable` and tears down both. Across a two-relay mesh the
pair coexists, but when the active publisher dies the carrying relay does **not**
fail over: announcements are **coalesced to one best route per path**, and the
split-horizon loop filter (`exclude_hop`) suppresses the return announcement, so the
relay serving the active source never learns the standby route and has nothing to
reselect. Route reselection therefore works *within an origin that already holds two
routes*, but the `moq-lite-05` topology does not put two routes for one broadcast in
front of the relay that needs them.

**Cost/standby routing (`moq-lite-06`) is necessary but not sufficient.** The intended
ranking mechanism is explicit cost: `broadcast::Route` carries a cost a standby seeds
high (a cold transcoder, a warm backup) and that drops to 0 once it starts carrying, so
a standby is selected only when nothing cheaper exists
(`rs/moq-net/src/model/broadcast.rs`, `rs/moq-net/src/lite/announce.rs`; landed as
#2424). It lives in `moq-lite-06-wip`, which is **deliberately excluded from the default
advertised set and ALPN list** (`rs/moq-net/src/version.rs` — `Versions::all()` and
`ALPNS` both omit it, with a comment noting it is "otherwise a fully-defined version …
an opt-in set that includes it negotiates normally") and negotiates **only when both
peers opt in** via `--server-version` / `--client-version`. With lite-06 negotiated
end-to-end the two-relay mesh behaves **identically to `moq-lite-05`**: the pair coexists
and then freezes permanently on active-source death, with the active-serving relay only ever
holding its **own** local route — the peer never advertises its standby publisher across the
cluster link ([lab: T6](../lab/test-6-relay-resilience.md)). Cost routing has nothing to rank, because the
missing piece is **standby-route propagation across the mesh**, not route pricing.
Cost-weighted standby routing is therefore real and negotiable but does **not** by itself
deliver active/active source failover; the propagation gap is the blocker, and hop-based
shortest-path routing is what runs by default.

**[#2473](https://github.com/moq-dev/moq/pull/2473) (issue #2461) closes the propagation gap and
ships on `main` (release `moq-net 0.2.5`).** It advertises, per peer, the best route whose hop chain
*excludes* that peer (so a peer inside the serving chain is offered the standby instead of nothing),
serves by the same exclusion, keys content identity on the publisher's first hop (declared in
**SETUP** rather than inferred per-`ANNOUNCE`), and adds a `moq --origin <id>` knob so a 1+1 pair
declares itself interchangeable. With it the two-relay drill passes end to end
([lab: T6](../lab/test-6-relay-resilience.md)): relay B, which advertises nothing while merely
carrying via relay A, emits a fresh `hops=2` announcement the instant the local standby publisher
joins, so relay A holds a second route *before* it needs one. When the active publisher is killed,
relay A reselects onto that standby and its subscriber resumes **~30–33 s later — one QUIC idle
timeout**. The mechanism is prompt; **detection dominates** (§5.1): a relay has no model of a
broadcast's expected cadence and so cannot treat silence as failure, and `--server-quic-idle-timeout`
bounds it today. [#2556](https://github.com/moq-dev/moq/pull/2556) does not move this — it speeds a
publisher reclaiming its *own* path on reconnect and leaves shared-origin 1+1 standbys alone.

**The binding precondition is a common source, not byte-identical segmentation.** A 1+1 pair works as
a redundant pair only if both publishers are two views of *one* feed: the moq group sequence number is
a per-importer counter reset to 0 at its first keyframe (`append_group()` in
`rs/moq-net/src/model/track.rs`), while track names and PTS come from the source bytes (PMT-derived
names, PCR/PTS from the TS). Feeding one ingest path into both publishers therefore gives them an
identical PMT/track layout and a consistent PTS timeline, which is what the reselect needs. Two runs on
`moq-relay 0.14.3` make the boundary precise ([lab: T6](../lab/test-6-relay-resilience.md)): with the
source fanned to two co-started importers the two subscribers' outputs are **byte-for-byte identical
before the kill**, and failover is clean; and — importantly for broadcast, where a publisher always
joins an already-running feed — a **standby that joins mid-stream** (so its group numbering is
*offset* from the active's) **still fails over cleanly**, because the exporter navigates by track and
live edge and simply skips to the standby's live edge rather than demanding group-number continuity
(it subscribes once and never reinitialises the catalog across the switch). Byte-identical numbering is
sufficient but not necessary; what a shared source rules out — a divergent track layout or codec across
the pair — is what would actually make failover impossible.

**"Continuity-clean" is not "hitless."** The resumed output carries **0 TS continuity-counter errors**
(the exporter's single output mux never resets), so it stays structurally valid and playable; the
~30 s outage instead appears as a **PCR/PTS discontinuity** — a content hole the media clock jumps
across (`tsp analyze` reports `pcrleap` on the PCR PID with CC errors at 0). This is
break-before-make. The window is the QUIC idle timeout and is tunable: at `--server-quic-idle-timeout
10s` the reselect completes in ~11 s, but tightening toward a few seconds gets fragile (a 5 s idle with
1 s keep-alive tore healthy sessions down and the switch did not complete). Sub-second / hitless is not
a relay-reselect property — it requires make-before-break at the *receiver* (ST 2022-7 dual-subscribe),
which the common-source result above is precisely what makes feasible (§5.1,
[architecture](architecture.md) §14.1).

One gap remains, and it is the operationally important one: **a graceful source exit is not failed
over at all.** When the active publisher terminates cleanly rather than dying, the relay does not
reselect — it propagates completion: both media tracks report `subscribe complete`, the catalog
subscription is `canceled (idle)`, and `moq export ts` terminates with `TS track layout changed after
PAT/PMT was emitted`, its muxer refusing a catalog that lost a track. The relay cannot distinguish
"this source is done, and so is the content" from "this source is done, but an interchangeable one
exists", so the shared `--origin` buys nothing on this path. Quite possibly intended semantics rather
than a defect — but it means failover covers the *harder* failure (host loss) and not the easier, far
more common one: SIGTERM to an encoder, a container rescheduled, a rolling restart. No merged code
addresses it; the only proposals are an announcement `epoch`
([#2330](https://github.com/moq-dev/moq/issues/2330)) or the typed lifecycle (#2216/#2217).

The investigation history behind this section — including two of the four original findings later
retracted as harness artefacts (a spurious standby-join stall, and a mis-graded failover window), the
real-but-pre-existing `Unroutable` teardown that #2473 also fixes, and the corrected drill contributed
upstream as [#2545](https://github.com/moq-dev/moq/pull/2545) — is preserved in the notebook
([lab: T6](../lab/test-6-relay-resilience.md), [evidence](evidence.md) §7).

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
  relay-edge RTT as the retransmit loop rather than an end-to-end window. The default
  loss-based CUBIC collapses under uniform loss/reordering/WAN while BBR holds full rate
  on par with SRT — a per-connection change with no wire/interop impact
  ([transport](transport.md) §3.1, [lab: T8](../lab/test-8-srt-vs-moq.md),
  [evidence](evidence.md) §6).

### 5.1 Failover and reconnect behaviour

Drills on the media-aware lane ([lab: T6](../lab/test-6-relay-resilience.md),
[evidence](evidence.md) §7) pin down what the resilience model delivers *today*
versus what it is designed to deliver, and the two are not yet the same.

- **Confirmed working.** Fan-out to multiple subscribers is byte-identical and
  continuous (redundant *outputs* are free). A `moq import ts` **publisher survives a
  relay restart** — its reconnect loop redials and re-announces automatically. A
  two-relay cluster forms and carries the feed. **The `moq export ts` subscriber now
  survives a relay restart too** — fixed by
  [#2469](https://github.com/moq-dev/moq/pull/2469) (broadcast *linger*): it rides out
  the outage and resumes automatically, bounded not hitless
  ([transport](transport.md) §8.3).
- **Confirmed limitation — no hitless source failover.** As §4.1 details, neither a
  single-relay duplicate publisher nor a two-relay mesh gives active/active source
  failover on the shipped wire; the relay keeps the active flow healthy but does not
  switch to a standby when the active source dies. [#2473](https://github.com/moq-dev/moq/pull/2473)
  closes that gap and the mesh drill passes on `main` (0.2.5), **provided both publishers share one
  source** (identical track layout + PTS; a mid-stream standby with offset group numbering still works,
  §4.1). Even so the switch is **bounded by the QUIC idle timeout (~30 s, tunable to ~10 s), not
  hitless** — the resumed TS is continuity-clean but carries a PCR/PTS discontinuity across the outage —
  so it protects against a dead source rather than replacing receiver-side hitless selection, and it
  does not cover a *graceful* source exit at all, which is the more common operational case (see §4.1).

The consequence for this document's resilience model is a sharpening, not a reversal:
the relay's job — **keep the flows healthy and let hitless selection happen at the
edge** — is the right split, and the drills confirm the relay carries redundant flows
and reconnects publishers (and, since #2469, the subscriber too). But **the hitless
switch must live downstream (ST 2022-7 / IRD, [architecture](architecture.md) §14.1)**:
relay-mesh source failover shipped in #2473 (0.2.5) but is bounded by failure detection
rather than hitless, and does not cover a graceful source exit at all, so it complements
receiver-side selection instead of replacing it. The broadcast-grade posture is therefore the
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
  default** — it removes the loss/reorder/WAN throughput collapse (§5,
  [lab: T8](../lab/test-8-srt-vs-moq.md)) — and, being sender-local, it changes nothing on
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

# Vision: Why Primary Distribution Is Changing

Status: working draft
Scope: strategic and architectural context for the rest of this repository.

---

## 1. Purpose

This document sets out *why* the primary distribution layer of professional broadcast is entering a period of structural change, and why an Internet-native distribution fabric is a plausible — though not yet proven — successor to the satellite, leased-fibre and MPLS architectures that have served the industry for four decades.

It deliberately does not begin with a protocol. Primary distribution has been re-architected before — analogue to digital, ASI to IP, SDI to ST 2110 — and each time the transport was the least interesting part of the transition: what changed the industry was the operating model the transport made possible. The focus here is therefore the forces acting on the market and the shape of system they imply, with Media over QUIC (MoQ) entering only near the end as a candidate that happens to fit requirements the market is generating on its own. Claims are marked *established*, *likely* or *uncertain* rather than presented uniformly as fact.

---

## 2. What primary distribution is

**Primary distribution is the "trunk" of linear television: a small number of extremely high-value feeds moved from a playout or origination facility to a set of *known, contracted* endpoints** — affiliate stations, cable and DTH headends, OTT origin/packaging facilities, partner broadcasters. Two adjacent problems are frequently conflated with it.

**Contribution** moves signals *toward* origination — venue, remote camera or bureau back to production — and is few-to-one or few-to-few with a different latency and cost envelope. **Distribution** (OTT/ABR, DTT, DTH to the home) moves the signal to the *consumer*: massively fan-out, best-effort, optimised for reach and per-stream cost rather than contractual determinism.

Primary distribution sits between them: comparatively few routes, each carrying a feed whose failure is a commercial and sometimes regulatory event, delivered to professional equipment operated by parties bound by carriage agreements. Its defining characteristics have been remarkably stable.

1. **Determinism dominates.** The expectation is not "high availability" in the web sense but something closer to "never fails visibly during contracted content". A dropped feed during a tier-one sporting event is a breach, not an incident to apologise for on a status page.
2. **The endpoints are professional and long-lived.** Hardware IRDs, professional decoders and ASI/SDI plant are capital equipment with a five-to-fifteen-year service life. They enforce TR 101 290 P1/P2 conformance, lock phase-locked loops to the transport stream's programme clock reference (PCR), and expect MPEG-2 transport stream semantics: stable PMT PIDs, SDT service identity, SCTE-35 splice signalling, teletext and subtitling, monotonic continuity counters.
3. **Trust and accountability are first-class.** Buyers optimise for "never fails" and for a counterparty contractually accountable when it does — hence long sales cycles, heavy procurement, and incumbents that stay sticky well beyond the point where a challenger is technically competitive.
4. **The topology is one-to-many but not internet-scale.** A national feed may fan out to tens or low hundreds of endpoints, not millions, so the properties that make a transport excellent at consumer-scale fan-out are not automatically the ones that matter here.

Any credible successor must satisfy all four, not merely the throughput and latency numbers that are easiest to benchmark.

---

## 3. Why the incumbents succeeded

Each incumbent solved the determinism problem in a way that matched the technology and economics of its era, and each retains properties that are genuinely difficult to replicate.

### 3.1 Satellite

Satellite is a physical-layer broadcast medium: one uplink illuminates a footprint, and every receiver within it sees the same signal at essentially the same time. That yields intrinsic one-to-many economics (the marginal cost of an additional receiver is close to zero), independence from terrestrial networks (immunity to congestion, BGP events and inter-region fibre cuts), and dedicated, capacity-reserved delivery. Its weaknesses are equally structural: half-second geostationary round trips, a widening disadvantage as terrestrial paths improve; rain fade; capital-intensive provisioning; footprint rigidity; and the spectrum and fleet-economics pressure in §4.6.

### 3.2 Leased fibre and MPLS

Leased fibre and MPLS-based managed IP (ST 2022-7 hitless redundancy, RTP/FEC, engineered class-of-service) brought lower latency and more flexible capacity than satellite. Their determinism is contractual and engineered: reserved-bandwidth label-switched paths with strict QoS, on a private overlay whose failure domains and security posture sit with a single operator, directly compatible with the IP plant broadcasters were already building internally. Their weaknesses are cost and agility: a new managed route is a procurement exercise measured in weeks or months, capacity is priced for dedicated use, and reach is bounded by carrier footprint and peering.

### 3.3 The common thread

All three succeed by *engineering determinism into a dedicated or managed layer* and *charging for that determinism*: the buyer is not paying for bandwidth but for the guarantee. Hence the fact to carry through the rest of this document — **any Internet-native successor is, from the buyer's perspective, proposing to move the guarantee from a managed layer onto a best-effort substrate.** That is a trust problem before it is a technology problem, and the reason a technically superior transport does not automatically win.

---

## 4. Pressures reshaping the market

**The incumbent model is not failing on its technical merits — it is being eroded by pressures largely exogenous to the transport itself.**

### 4.1 Cloud adoption in the media plant

Production, playout, origination and OTT packaging have moved decisively into cloud and cloud-adjacent infrastructure, so primary distribution is frequently the *outlier* — software-defined and API-driven on every side but still a physical or carrier-managed procurement itself. Every hand-off between a software-defined domain and a manually provisioned one adds latency, error and operational cost. The pressure is not "cloud is cheaper" (contested, §4.6); it is that the *shape* of distribution no longer matches the shape of everything it connects to.

### 4.2 Operational agility and API-driven workflows

Pop-up channels, event-scoped feeds, short-term rights windows and rapid partner onboarding are now routine commercial requests, and distribution is increasingly expected to expose the same APIs and infrastructure-as-code primitives as the rest of the plant: create a route, attach an endpoint, grant an entitlement, revoke it — auditable and versioned. An architecture whose unit of change is a multi-week provisioning ticket cannot serve a business whose unit of change is a same-day commercial decision, and this is increasingly the requirement on which the incumbent model fails.

### 4.3 Shrinking linear revenues

**Declining linear revenue removes the ability to fund distribution infrastructure the way it was historically funded** — the structural pressure most likely to force change even without a compelling technical alternative. Leased transponders and managed fibre were justified against large, stable linear revenues; as viewing migrates to direct-to-consumer streaming, the fixed cost of dedicated capacity becomes a larger and more scrutinised fraction of a declining pie. Linear will not disappear — news, sport and regulated public-service content persist for years — but its cost base must shrink in step.

### 4.4 Global, dynamic rights

Rights and audiences are increasingly global and dynamic: a rights holder may need to deliver a feed to partners across several continents for a single event, then tear the whole topology down. Satellite footprints are geographically rigid and managed-fibre reach is bounded by carrier footprint, whereas the public Internet *reaches everywhere a data centre reaches* — essentially everywhere the business needs to be. The pressure is reach-on-demand: global topology without global procurement.

### 4.5 A commodity software-defined substrate

Software-defined networking, commodity high-throughput servers and — critically — mature QUIC/HTTP-3 stacks operated at global scale by CDNs and hyperscalers mean the *substrate* for an Internet-native fabric now exists as a commodity. A decade ago "distribute broadcast over the Internet" meant building the network; today the network is there, and the open question is the layer above it.

### 4.6 Changing economics

The economic pressures are real but must be stated carefully, because the naive version of the argument is wrong (the full treatment is in [economics](economics.md)).

- **Spectrum and fleet economics are moving against satellite.** C-band reallocation to mobile broadband, more selective replacement-fleet investment, and a finite depreciation runway on existing capacity all mean the option value of satellite for primary distribution declines over a long horizon.
- **But "cloud is cheaper than satellite" is not established.** For an always-on, redundant feed with 24/7 support, the fully-loaded cost of an Internet-native path — egress, relay compute, redundancy, NOC — does not obviously beat a *depreciated* transponder or an existing IP contract at scale. The always-on case is now modelled at public list prices ([economics](economics.md) §4), and egress does dominate it: roughly 90 % of the transport bill, against single-digit percentages for compute and protocol overhead. Two findings from that model bound the optimism. Unicast IP cost is **linear in destinations** where satellite fan-out inside the footprint is free, so destination count — not bitrate, and nothing a transport can influence — decides the comparison; every candidate transport, MoQ and SRT and HLS alike, is unicast at the last mile, and a MoQ relay is a cache rather than an exception to this. And published cloud egress sits about an order of magnitude above what the same delivery costs on a commodity CDN or, costed all-in, on owned infrastructure — which makes this a question about commercial terms rather than engineering. What that spread implies is that **the market the delivery is bought in matters more than the protocol**: buying delivery where it has already been commoditised, or running it yourself, moves the viable range from tens of destinations to several hundred ([economics](economics.md) §4.7). The case remains *route-specific and unproven against real negotiated rates*: strongest where the incumbent case is weakest (dynamic, short-lived or long-tail topologies), and arguable for trunk routes well beyond where a cloud-priced model would put the limit.

This matters because the economic argument is the one most often overstated by advocates: the durable driver is not unit cost today but the mismatch between a *fixed, provisioned* cost model and a business that increasingly needs a *variable, on-demand* one.

---

## 5. Why Internet-native is increasingly likely

**Internet-native distribution is the *cleanest long-run fit* for the combined §4 pressures — not the only option, and a claim about eventual outcome rather than timing.** Those pressures are not independent: each of them pushes distribution toward a layer that is programmable, globally reachable and priced with use, and the substrate for such a layer now exists as a commodity. It is not the *only* resolution, though: an API-driven control plane over *existing managed IP* (MediaConnect-class services, orchestrated MPLS/SRT) narrows the same mismatch without a public-Internet data plane, and may clear the trust bar sooner.

The conclusion is not that satellite and managed fibre disappear, but that the *marginal* new route — and eventually the marginal re-provisioned route — increasingly lands on an Internet-native path, with the installed base migrating through attrition as dedicated capacity is not renewed rather than by a single switch-off.

The counter-argument is strong: the incumbent works, the buyer is conservative, and the trust barrier is high (§3.3). What is uncertain is the *rate*, set by how quickly the successor layer earns the guarantee the incumbent already provides — which transport performance alone does not deliver. The transition could take a decade, or stall on any route where the reliability bar is not met.

---

## 6. Why MoQ fits

**MoQ enters only now, as a candidate that happens to match requirements the market is generating on its own — not as a cause of the change.** It is a live-media transport being standardised in the IETF and implemented in the open, and what makes it *architecturally* interesting, as distinct from merely performant, is that several native properties line up with the §4 pressures:

- **Native relay and 1:N amplification (the advantage we put forward first).** One protocol carries a feed from contribution through a relay fabric that fans out point-to-multipoint, with subscription-based cluster routing and caching in the model rather than bolted on. This maps directly onto primary distribution's "trunk that must occasionally fan out globally and dynamically" shape (§4.4), and it is what an SRT/RTP point-to-point tunnel does not give you natively. Its *cost* value is narrower than its architectural value, though: the relay removes duplicated backhaul and uplink, while last-mile delivery stays linear in destinations for MoQ exactly as for everything else ([economics](economics.md) §4.8).
- **It is shaped like something a commodity delivery market can sell, which is the strongest economic argument in this paper and a claim about markets rather than a measurement.** A relay is a cache: it receives an object once and serves N subscribers over N unicast connections, which is what a CDN edge already does and already prices. SRT has no object model and no native relay, so fanning it out means running a stateful media gateway per stream per destination — a media-server business rather than a delivery business, which is why no CDN sells SRT relay as a commodity product and why one already sells MoQ relay. Openness is necessary but not sufficient here, since SRT is open too and produced no commodity relay market. If CDNs deploy MoQ relays and compete, relay capacity follows commodity delivery pricing rather than hyperscaler primary-distribution pricing, which moves the viable destination count by more than any engineering change available ([economics](economics.md) §4.9). The argument is contingent, not banked: it needs relay portability between implementations, which is currently absent in practice ([evidence](evidence.md) §9), because a market cannot commoditise a product buyers cannot switch between.
- **It rides QUIC/HTTP-3, the substrate the CDN and hyperscaler fabric already runs** (§4.5), so an operator fluent in that substrate has a head start. But "adopt MoQ" means standing up a new *stateful live-subscription service* — relay sessions, live-object caching, authorization at subscription, cluster routing, draft coexistence — not enabling a feature on an existing HTTP cache: both a strength and the reason the *transport itself is not a defensible asset*.
- **Delivery is subscription-oriented, and authorization has a native place in the session model.** A subscriber receives only the tracks it requests, and only while it requests them, and a relay can authorize or refuse that subscription at the point of subscription rather than behind an external gateway. Together these are the substrate for *dynamic entitlement* — a feed reaches an endpoint only while it holds a valid subscription (§4.2) — though the token profile this work assumes (path-scoped JWTs, mTLS, expiry) is layered on the hook rather than fixed by the wire protocol.
- **Loss resilience is a tunable rather than a protocol property, and it is now measured.** Head-to-head against SRT on a real internet path, MoQ collapses under loss with QUIC's default CUBIC controller, while switching the sender to BBR restores full-rate, byte-complete delivery *on par with SRT*, with no wire or draft change ([transport](transport.md) §3.1, [evidence](evidence.md) §6). The defensible claim is therefore parity under loss once the controller is chosen correctly, not superiority — QUIC's per-stream delivery avoids serialising a whole multiplex behind one lost packet, but the incumbent UDP transports do not share a single blocking flaw. Graceful multi-rendition degradation is strongest on the default media-aware lane and constrained on the opaque fallback ([architecture](architecture.md) §4.2, §14.2).

Where the fit is weakest ([transport](transport.md) §3.2 develops each):

- **The incremental advantage on the narrow job is real but narrow.** MoQ's strengths appear at fan-out scale and heterogeneity — exactly where primary distribution is *least* heterogeneous, so there is a real risk of bringing a distribution-protocol advantage to a contribution-shaped problem.
- **The protocol is pre-standard and wire-unstable** ("almost a completely new protocol" between drafts) against a broadcaster's five-to-ten-year horizon, architected around by keeping the media and control layers transport-independent.
- **"Demo-grade" MoQ is not "broadcast-grade" MoQ.** Its object/burst delivery produces a PCR that hardware IRDs reject on TR 101 290, and fixing that is unglamorous engineering the transport does not do for you: a downstream groomer (the public `mpegts-pacer`) delivers CBR/PCR conformance on file, with the hardware pass still outstanding ([evidence](evidence.md) §3).

MoQ is not the first protocol to point at an Internet-native future — low-latency DASH, WebRTC/SFU fan-out, TS-over-HTTP and its own WARP lineage share that ancestry, and TS-over-HTTP is a sound choice in several deployments today ([transport](transport.md) §3.3). What distinguishes MoQ is combining native relay/amplification, subscription-based delivery and token-scoped authorization in one standards-track, CDN-deployable protocol: a strong architectural fit for where the market is independently heading, but a necessary substrate rather than the value, which lives in the broadcast-grade layer above it.

---

## 7. The long-term vision: a distribution fabric

**The end-state is not "satellite, but over the Internet" but a qualitatively different operating model: a *distribution fabric*, a software-defined, globally reachable, multi-tenant layer over which linear feeds are provisioned, entitled, delivered and observed as software services** (assuming §5 holds and a transport such as MoQ provides the substrate). Its defining properties, as design goals rather than achievements:

1. **Routes are provisioned by API in minutes, not by procurement in weeks** — creating a route, attaching an endpoint and granting an entitlement are versioned, auditable, reversible operations.
2. **Entitlement is dynamic and revocable.** A feed reaches an endpoint only while that endpoint holds a valid entitlement, so rights windows, partner onboarding and emergency revocation become control-plane operations with bounded latency rather than manual receiver reconfiguration.
3. **The installed base keeps working.** Hardware IRDs, professional decoders and TR 101 290 monitoring continue to function unchanged, fed IRD-grade MPEG-TS groomed for PCR accuracy at the egress edge, with multicast, RTP/FEC and ST 2022-7 redundancy becoming *egress implementation details* rather than end-to-end architecture. This is the non-negotiable: a successor that requires replacing the receiving plant will not be adopted.
4. **Redundancy is engineered into the fabric, not bolted on** — dual-path and hitless switching, regional relay redundancy and graceful degradation expressed through policy rather than per-route engineering. Doubling the chain and letting the receiver select is now measured to be genuinely hitless — zero lost packets across a total leg blackout, path loss and differential delay, with a clean publisher shutdown invisible at the output — so the model itself is sound. Doing it with a *groomed* pair from two independent chains now works as well, once each groomer decides what goes in each slot from the stream's own clock rather than its own: the two legs come out byte-identical and the pair rides out the death of a publisher, a relay or an exporter. What is not yet solved is bringing a single leg back into a live pair — it returns carrying the right programme under the right numbering, but one byte per packet apart, because the exporter numbers continuity counters per process. Within the fabric, active/active *source* failover across a relay mesh passes end to end but is bounded by the QUIC idle timeout rather than hitless, and a source that exits cleanly is not failed over at all ([evidence](evidence.md) §7).
5. **Observability and multi-tenancy are first-class.** Every route, endpoint and entitlement is observable in the terms a broadcast operations centre already uses — signal conformance, path health, error-second counts — integrated with existing monitoring; and one fabric serves many broadcasters, partners and rights boundaries with per-tenant isolation and accountability, the precondition for shared rather than siloed infrastructure.
6. **The transport is interchangeable.** Because the durable value sits in the control, entitlement, egress and observability layers, the fabric treats MoQ as the preferred but not the only data plane, able to fall back to established transports where the protocol is not yet ready — a hedge against draft instability and an acknowledgement that migration is gradual.

Not all of this is proven. That the *substrate* can carry broadcast traffic is established, including over a real internet path through a cloud relay, and the control and entitlement model is likely buildable on MoQ's primitives; but the broadcast-grade egress layer is *demonstrable rather than demonstrated* on real hardware, source-level failover (item 4) ships only as a bounded reselect rather than the hitless switch broadcast expects, and the economics remain unproven for always-on trunk routes (§4.6). The rest of this repository exists to reduce these uncertainties, not to declare them resolved.

---

## 8. What must be true

**The vision in §7 holds only if a small number of conditions hold; if any fails, the direction of the conclusion changes.**

- **The reliability bar can be met on a best-effort substrate.** Graceful degradation, redundancy and grooming must produce delivery that professional equipment accepts and operations teams trust for contracted content. Part of this now has evidence — loss resilience matches SRT once the congestion controller is chosen correctly (§6) — but the hardware-IRD conformance pass remains open, and source failover, while shipped, is bounded by failure detection rather than hitless ([architecture](architecture.md) §14, [interoperability](interoperability.md)).
- **The transport stabilises on a timeline compatible with broadcast planning** — or, failing that, the architecture isolates the value layers from transport churn so instability is a manageable dependency rather than a fatal one.
- **The economics work on some real, identifiable class of routes:** most likely dynamic, short-lived or long-tail routes first, rather than a wholesale day-one replacement. Trunk routes are no longer purely a waiting game on the incumbent's cost base, though — the modelling in [economics](economics.md) §4.7 puts a transponder's worth of channels to several hundred destinations in contention *today*, provided the delivery is bought in a commodity market rather than at metered hyperscaler rates.
- **Relay capacity becomes something a buyer can shop.** The cost case treats relays as a commodity procurable from more than one supplier, and the strongest economic argument for MoQ (§6) assumes CDNs will compete to operate them. Measured today a feed traverses only relays from the publisher's own implementation ([evidence](evidence.md) §9), so this is a precondition rather than a property — and the one most directly in the project's own control, since it is an interoperability problem before it is a commercial one.
- **The value layer is genuinely defensible.** Since the transport commoditises, durable value must accrue in the control-plane, entitlement, egress-interop and observability layers. That is not guaranteed: the control-plane space is already crowded (MediaConnect, Zixi, LTN and others ship capable management planes), so defensibility has to come from doing this specific job materially better, not from being in the control plane at all.

These conditions are the connective tissue to the [architecture](architecture.md), which takes this vision as a requirement set and describes the system that would satisfy it, trade-offs and open questions included.

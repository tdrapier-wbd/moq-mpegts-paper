# Vision: Why Primary Distribution Is Changing

Status: working draft
Scope: strategic and architectural context for the rest of this repository.

---

## 1. Purpose

This document sets out *why* the primary distribution layer of professional broadcast is entering a period of structural change, and why an Internet-native distribution fabric is a plausible — though not yet proven — successor to the satellite, leased-fibre, and MPLS architectures that have served the industry for four decades.

It deliberately does not begin with a protocol. Primary distribution has been re-architected before — analogue to digital, ASI to IP, SDI to ST 2110 — and in each case the transport was the least interesting part of the transition: what changed the industry was the operating model the transport made possible. This document therefore concentrates on the forces acting on the market and on the shape of the system those forces imply. Media over QUIC (MoQ) enters only near the end, as a candidate that happens to fit requirements the market is generating on its own.

Throughout, we separate three categories of claim — *established*, *likely*, and *uncertain* — and say so explicitly rather than presenting an opinion as fact.

---

## 2. What primary distribution is

**Primary distribution is the "trunk" of linear television: a small number of extremely high-value feeds moved from a broadcaster's playout or origination facility to a set of *known, contracted* endpoints** — affiliate stations, cable and DTH headends, OTT origin/packaging facilities, and partner broadcasters. It is distinct from two adjacent problems that are frequently conflated with it:

- **Contribution** moves signals *toward* the point of origination — from a venue, a remote camera position, or a bureau back to a production or playout facility. Contribution is usually few-to-one or few-to-few, is often bidirectional in its control, and tolerates a different latency and cost envelope.
- **Distribution** (OTT/ABR streaming, DTT, DTH to the home) moves the signal to the *consumer*. It is massively fan-out, best-effort in its service guarantees, and optimised for reach and per-stream cost rather than for contractual determinism.

It sits between these: a comparatively small number of routes, each carrying a feed whose failure is a commercial and sometimes regulatory event, delivered to professional equipment operated by parties bound by carriage agreements.

Its defining characteristics have been remarkably stable:

1. Determinism dominates. The service-level expectation is not "high availability" in the web sense (three or four nines) but something closer to "never fails visibly during contracted content." A dropped feed during a tier-one sporting event is a breach, not an incident to be apologised for in a status page.
2. The endpoints are professional and long-lived. The receiving equipment — hardware IRDs, professional decoders, ASI/SDI plant — is capital equipment with a five-to-fifteen-year service life. It enforces conformance (TR 101 290 P1/P2), locks phase-locked loops to the transport stream's programme clock reference (PCR), and expects MPEG-2 transport stream semantics: stable PMT PIDs, service identity in the SDT, SCTE-35 splice signalling, teletext and subtitling, and monotonic continuity counters.
3. Trust and accountability are first-class requirements. Buyers optimise for "never fails" and for the existence of a counterparty who is contractually and operationally accountable when it does. This is why sales cycles are long, procurement is heavy, and incumbents are sticky far beyond the point where a challenger is technically competitive.
4. The topology is one-to-many but not internet-scale. A national feed may fan out to tens or low hundreds of endpoints, not millions. This matters: the properties that make a transport excellent at consumer-scale fan-out are not automatically the properties that matter here.

Any credible successor architecture must satisfy these characteristics, not merely the throughput and latency numbers that are easiest to benchmark.

---

## 3. Why the incumbents succeeded

Satellite, leased fibre, and MPLS-based managed networks did not dominate by accident: each solved the determinism problem in a way that matched the technology and economics of its era, and each has properties that remain genuinely difficult to replicate.

### 3.1 Satellite

Satellite distribution is, at its core, a physical-layer broadcast medium. A single uplink illuminates a footprint, and every receiver within that footprint sees the same signal at essentially the same time. This yields three properties that are hard to beat:

- **Intrinsic one-to-many economics.** The marginal cost of an additional receiver is close to zero. Adding the thousandth affiliate costs the uplink operator nothing incremental.
- **Topological independence from terrestrial networks.** The signal does not traverse anyone's IP backbone, so it is immune to terrestrial congestion, BGP events, and fibre cuts between regions.
- **Deterministic, capacity-reserved delivery.** A leased transponder segment is dedicated capacity. The bandwidth is simply there.

Its weaknesses are equally structural: high latency relative to terrestrial paths (fixed at roughly a half-second round trip for geostationary orbits, and a widening disadvantage as terrestrial paths improve), susceptibility to rain fade, long and capital-intensive provisioning, geographic footprint rigidity, and — increasingly — spectrum and fleet-economics pressure discussed in §4.

### 3.2 Leased fibre and MPLS

Leased fibre and MPLS-based managed IP networks (with ST 2022-7 hitless redundancy, RTP/FEC, and carefully engineered class-of-service) brought lower latency and higher, more flexible capacity than satellite for point-to-point and point-to-multipoint routes. Their success rested on:

- **Contractual determinism via traffic engineering.** MPLS label-switched paths with reserved bandwidth and strict QoS give a *managed* network the ability to offer hard guarantees that the public Internet does not. 
- **Separation from the public Internet.** The transport is a private overlay. Its failure domains, congestion behaviour, and security posture are all under a single operator's control. 
- **Direct compatibility with the IP-based plant** that broadcasters were already building internally.

Their weaknesses are cost and agility: provisioning a new managed route is a procurement exercise measured in weeks or months, capacity is priced for dedicated use, and geographic reach is bounded by the carrier's footprint and peering.

### 3.3 The common thread

All three incumbents succeed by *engineering determinism into a dedicated or managed layer* and by *charging for that determinism*. The buyer is not paying for bandwidth; the buyer is paying for the guarantee. This is the single most important fact to hold onto through the rest of this document: **any Internet-native successor is, from the buyer's perspective, proposing to move the guarantee from a managed layer onto a best-effort substrate.** That is a trust problem before it is a technology problem, and it is the reason a technically superior transport does not automatically win.

---

## 4. Pressures reshaping the market

**The incumbent model is not failing on its technical merits — it is being eroded by pressures largely exogenous to the transport itself.** Each is treated in turn, distinguishing structural forces from cyclical ones.

### 4.1 Cloud adoption in the media plant

Production, playout, origination, and OTT packaging have moved decisively into cloud and cloud-adjacent infrastructure. The centre of gravity of a modern broadcaster's technical estate is increasingly a set of software services running in a public cloud region or a private cloud, not a rack of dedicated appliances. In many cases, primary distribution is an *outlier*: the surrounding workflow is software-defined and API-driven, while distribution remains a physical or carrier-managed procurement.

This creates an architectural impedance mismatch. Every hand-off between a software-defined domain and a manually provisioned one is a source of latency, error, and operational cost. The pressure here is not "cloud is cheaper" (that is contested — see §4.7); it is that the *shape* of distribution no longer matches the shape of everything it connects to.

### 4.2 Operational agility

The tempo of the business has changed. Pop-up channels, event-scoped feeds, short-term rights windows, and rapid partner onboarding are now routine commercial requests. A distribution architecture whose unit of change is a multi-week provisioning ticket is structurally unable to serve a business whose unit of change is a same-day commercial decision. Agility is not a nice-to-have; it is increasingly the requirement that the incumbent model fails.

### 4.3 Shrinking linear revenues

**Declining linear revenue removes the ability to fund distribution infrastructure the way it was historically funded** — and this is the structural pressure most likely to force change even without a compelling technical alternative. Leased transponders and managed fibre were justified against large, stable linear revenues; as viewing migrates to direct-to-consumer streaming, the fixed cost of dedicated capacity becomes a larger and more scrutinised fraction of a declining pie. The pressure is not that linear disappears — it will persist for years, particularly for news, sport, and regulated public-service content — but that its cost base must shrink in step with its revenue.

### 4.4 API-driven workflows

Distribution increasingly needs to expose the same APIs and infrastructure-as-code primitives as the rest of the plant: create a route, attach an endpoint, grant an entitlement, and revoke it — all by API, all auditable, all versioned. A distribution layer whose unit of change is a manual ticket is an outlier in an otherwise programmable estate.

### 4.5 Global distribution

Content rights and audiences are increasingly global and increasingly dynamic. A rights holder may need to deliver a feed to partners across several continents for a single event and then tear the whole topology down. Satellite footprints are geographically rigid; managed fibre reach is bounded by carrier footprint. The public Internet, whatever its faults, *reaches everywhere a data centre reaches*, which is now essentially everywhere the business needs to be. The pressure here is reach-on-demand: the ability to stand up global topology without a corresponding global procurement.

### 4.6 Software-defined infrastructure

The maturation of software-defined networking, commodity high-throughput servers, and — critically — mature QUIC/HTTP-3 stacks operated at global scale by CDNs and hyperscalers, means that the *substrate* for an Internet-native distribution fabric now exists and is operated by multiple parties as a commodity. A decade ago, "distribute broadcast over the Internet" required building the network. Today the network is there; the open question is the layer above it.

### 4.7 Changing economics

The economic pressures are real but must be stated carefully, because the naive version of the argument is wrong.

- **Spectrum and fleet economics are moving against satellite.** Portions of C-band are being reallocated to mobile broadband in several regions, satellite operators are becoming more selective about replacement fleet investment, and the depreciation runway on existing capacity is finite. Over a long horizon, the option value of satellite for primary distribution is declining.
- **But "cloud is cheaper than satellite" is not established.** For an always-on, redundant, low-latency linear feed with 24/7 operational support, the fully-loaded cost of a cloud-based Internet-native path — egress, relay compute, redundancy, and NOC — does not obviously beat a *depreciated* transponder or an existing IP contract at scale. Egress pricing in particular can dominate the model. The honest position is that the economic case is *route-specific and still to be proven with numbers*: it is strongest and most immediate where the incumbent case is weakest — dynamic, short-lived, or long-tail topologies — and, on the horizon over which incumbent capacity is retired and egress pricing falls, increasingly achievable for always-on trunk routes too, rather than permanently out of reach.

We flag this explicitly because the economic argument is the one most often overstated by advocates. The durable economic driver is not unit cost today; it is the mismatch between a *fixed, provisioned* cost model and a business that increasingly needs a *variable, on-demand* one.

---



## 5. Why Internet-native is increasingly likely

**Internet-native distribution is the *cleanest long-run fit* for the combined §4 pressures — not the only option, and a claim about eventual outcome, not timing.** The pressures are not independent; they reinforce each other. Cloud adoption creates an impedance mismatch an Internet-native layer resolves cleanly — though not the *only* resolution: an API-driven control plane over *existing managed IP* (MediaConnect-class services, orchestrated MPLS/SRT) narrows the same mismatch without a public-Internet data plane, and may clear the trust bar sooner. Shrinking linear revenue forces fixed-to-variable cost; global, dynamic rights create reach-on-demand requirements rigid incumbents cannot meet cheaply; API-driven operations demand a distribution layer that speaks the same control-plane language as everything around it; and the software-defined substrate for all of this now exists as a commodity.

The conclusion is not that satellite and managed fibre disappear, but that the *marginal* new route, and eventually the *marginal* re-provisioned route, is increasingly likely to land on an Internet-native path. The installed base migrates through attrition — dedicated capacity is not renewed — rather than a single switch-off.

The counter-argument is strong: the incumbent works, the buyer is conservative, and the trust barrier is high (§3.3). This is a claim about *eventual outcome*, not *timing*: the transition could take a decade, or stall on any route where the reliability bar is not met. What is uncertain is the *rate* — determined by how quickly the successor layer earns the guarantee the incumbent already provides, which transport performance alone does not deliver.

---

## 6. Why MoQ fits

**MoQ enters the argument only now, as a candidate that happens to match requirements the market is generating on its own — not as a cause of the change.** It is a live-media transport being standardised in the IETF and implemented in the open; what makes it *architecturally* interesting here (as distinct from merely performant) is that several native properties line up with the §4 pressures:

- **Native relay and 1:N amplification (the advantage we put forward first).** A single protocol carries a feed from contribution through a relay fabric that fans out point-to-multipoint, with subscription-based cluster routing and caching as part of the model rather than a bolt-on. This is the property that maps most directly onto primary distribution's "trunk that must occasionally fan out globally and dynamically" shape (§4.5), and it is what an SRT/RTP point-to-point tunnel does not give you natively.
- **It rides QUIC/HTTP-3, the substrate the CDN and hyperscaler fabric already runs.** Broadcast distribution can, in principle, run on infrastructure that already exists and is operated by multiple competing parties (§4.6). An operator already fluent in QUIC/HTTP-3 has a head start — but "adopt MoQ" means standing up a new *stateful live-subscription service* (relay sessions, live-object caching, authorization at subscription, cluster routing, draft coexistence), not enabling a feature on an existing HTTP cache. This is both a strength and the reason the *transport itself is not a defensible asset*.
- **Delivery is subscription-oriented.** A subscriber receives only the tracks it requests, and only while it requests them — which maps directly onto *dynamic entitlement*: a feed reaches an endpoint only while it holds a valid subscription (§4.4).
- **Authorization has a native place in the session model.** A relay can authorize or refuse a subscription at the point of subscription rather than behind an external gateway. The token profile this work assumes (path-scoped JWTs, mTLS, expiry) is layered on that hook, not fixed by the wire protocol.
- **Congestion behaviour degrades rather than blocks.** QUIC's per-stream delivery avoids serialising a whole multiplex behind one lost packet; whether that beats a well-tuned SRT/RIST link is unmeasured, and the incumbent UDP transports do not share a single blocking flaw ([transport](transport.md) §3.1, §8). The advantage is strongest on the media-aware lane and constrained on the opaque fallback ([architecture](architecture.md) §14.2).

We must be equally clear about where the fit is weakest ([transport](transport.md) §3.2 develops each):

- **The incremental advantage on the narrow job is real but narrow.** MoQ's strengths appear at fan-out scale and heterogeneity — exactly where primary distribution is *least* heterogeneous, so there is a genuine risk of bringing a distribution-protocol advantage to a contribution-shaped problem.
- **The protocol is pre-standard and wire-unstable** ("almost a completely new protocol" between drafts), against a broadcaster's five-to-ten-year horizon — a risk architected around by keeping the media and control layers transport-independent.
- **"Demo-grade" MoQ is not "broadcast-grade" MoQ.** Its object/burst delivery produces a PCR that hardware IRDs reject on TR 101 290; making it acceptable to the installed base is real, unglamorous engineering the transport does not do for you — the platform's pacer/groomer now does it, delivering CBR/PCR conformance (file-validated; the hardware pass is pending).

MoQ is not the first protocol to point at an Internet-native future — low-latency DASH, WebRTC/SFU fan-out, and its own WARP lineage share that ancestry — but it is among the few whose architecture combines native relay/amplification, subscription-based delivery, and token-scoped authorization in a single standards-track, CDN-deployable protocol. The honest framing: a strong architectural fit for the future the market is independently moving toward, but a necessary substrate rather than the value — which lives in the broadcast-grade layer above it, the subject of the architecture document.

---



## 7. The long-term vision: a distribution fabric

**The end-state is not "satellite, but over the Internet" — it is a qualitatively different operating model: a *distribution fabric*, a software-defined, globally reachable, multi-tenant layer over which linear feeds are provisioned, entitled, delivered, and observed as software services** (assuming §5 holds and a transport such as MoQ provides the substrate).

Its defining properties, stated as design goals rather than achievements:

1. **Routes are provisioned by API in minutes, not by procurement in weeks.** Creating a distribution route, attaching an endpoint, and granting an entitlement are API operations that are versioned, auditable, and reversible.
2. **Entitlement is dynamic and revocable.** A feed reaches an endpoint only while that endpoint holds a valid entitlement. Rights windows, partner onboarding, and emergency revocation are control-plane operations with bounded, measurable latency — not manual reconfiguration of receivers.
3. **The installed base keeps working.** Hardware IRDs, professional decoders, and TR 101 290 monitoring continue to function unchanged. The fabric delivers IRD-grade MPEG-TS at the egress edge, groomed for PCR accuracy and conformance. Multicast, RTP/FEC, and ST 2022-7 redundancy become *egress implementation details* rather than end-to-end architecture. This is the single most important non-negotiable: a successor that requires replacing the receiving plant will not be adopted.
4. **Redundancy and reliability are engineered into the fabric, not bolted on.** Dual-path and hitless switching, regional relay redundancy, and graceful degradation are properties of the platform, expressed through policy rather than through per-route manual engineering.
5. **Observability is NOC-grade and native.** Every route, endpoint, and entitlement is observable in the terms a broadcast operations centre already uses — signal conformance, path health, error-second counts — integrated with existing monitoring rather than replacing it.
6. **Multi-tenancy and isolation are first-class.** A single fabric can serve many broadcasters, many partners, and many rights boundaries with strong isolation and per-tenant accountability, which is the precondition for the fabric being operated as shared infrastructure rather than as one silo per customer.
7. **The transport is interchangeable.** Because the durable value is in the control, entitlement, egress, and observability layers, the fabric should treat MoQ as the preferred but not the only data plane, remaining able to fall back to established transports where the protocol is not yet ready. This is both a hedge against draft instability and an acknowledgement that migration is gradual.

This is a vision, and it is worth naming which parts are uncertain. That the *substrate* can carry broadcast traffic is established. That the *control and entitlement model* is buildable on MoQ's primitives is likely. That the broadcast-grade egress layer can satisfy hardware IRDs is *demonstrable but must be demonstrated on real hardware* — it is not something to assume. And whether the resulting fabric is *economically superior* to the incumbent for always-on trunk routes remains, as discussed in §4.7, unproven in the general case. The rest of this repository exists to reduce these uncertainties, not to declare them resolved.

---



## 8. What must be true

**The vision in §7 holds only if a small number of conditions hold; if any fails, the direction of the conclusion changes.**

- **The reliability bar can be met on a best-effort substrate.** Graceful degradation, redundancy, and grooming must produce delivery that professional equipment accepts and that operations teams trust for contracted content. This is an engineering claim that must be proven, not assumed (see the high-availability treatment in [architecture](architecture.md) §14 and [interoperability](interoperability.md)).
- **The transport stabilises on a timeline compatible with broadcast planning.** Or, failing that, the architecture successfully isolates the value layers from transport churn so that instability is a manageable dependency rather than a fatal one.
- **The economics work on some real, identifiable class of routes.** Most likely the dynamic, short-lived, or long-tail routes first, expanding toward trunk routes as the incumbent cost base erodes — not a wholesale day-one replacement.
- **The value layer is genuinely defensible.** Since the transport commoditises, the control-plane, entitlement, egress-interop, and observability layers must be where durable value accrues. This is not guaranteed: the control-plane space is already crowded (MediaConnect, Zixi, LTN and others ship capable management planes), so defensibility has to come from doing this specific job materially better, not from being in the control plane at all. If these layers too commoditise instantly, the opportunity is thinner than it appears.

These conditions are the connective tissue between this vision and the architecture that follows. The architecture document takes the vision as a requirement set and describes, concretely, the system that would satisfy it — including the components, the trade-offs, and the places where the honest answer is still "we don't yet know."
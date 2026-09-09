# Economics

Status: working draft.
Layer: **cross-cutting** — the cost framework is data-plane agnostic; the data plane enters only as a
wire multiplier and a delivery price.
Scope: a cost framework for comparing Internet-native distribution against incumbent primary
distribution, **a numeric model of the always-on case built entirely from published rates**, and the two
ownership questions that follow a decision to proceed — whether to operate the fan-out or rent it (§7),
and where vendor value actually sits once the control plane is priced honestly (§8). The
full working, every rate card and the reproduction script are in
[`lab/cost-model.md`](../lab/cost-model.md); this document states the model's inputs, its four
results and what they do and do not support.

> **Confidentiality and provenance.** Every figure here is either published or derived in the open
> from something published. Published rates — hyperscaler egress tariffs, MediaConnect and its
> reserved tiers, CDN price pages, marketplace software rates, EC2 reserved-instance prices, surveyed
> IP transit — are public and verifiable. **Commercially sensitive inputs are excluded**: no customer
> pricing, no vendor contract or discount terms, no transponder or fibre lease rates, no incumbent's
> actual or depreciated route cost, and no third-party reports of what anyone pays at negotiated
> volume. Where the comparison needs the incumbent's side, §4.4 gives a **parity threshold** against
> our own figures instead of theirs.
>
> Three inputs are neither published nor measured, and each is labelled wherever it appears. The
> negotiated-discount column in §4.4 is a **hypothetical** percentage off published list —
> illustrative arithmetic, not anyone's terms. The CDN relay rates are **assumptions** about where a
> competitive market would land, since only one provider has announced a MoQ relay tariff. The
> self-hosted build-up is **illustrative**. Nothing here should be read as evidence that a particular
> rate is obtainable.

---

## 1. The question, and the answer that falls out of it

The economic question is narrower than "is cloud cheaper than satellite". It is: *for a specific
class of routes, does an Internet-native path deliver equivalent broadcast-grade service at a total
cost low enough, and with enough operational upside, to justify displacing the incumbent — given the
incumbent's trust advantage and the challenger's unproven status?*

Buyers weigh three things, in this order. **Reliability and trust** comes first, because no saving
justifies a visible failure during contracted content — so economics only enters the decision after the
reliability bar is cleared. Then **total cost of ownership** rather than sticker price, since redundancy,
operations and integration dominate over a contract lifetime. Then **operational optionality** — the
provisioning speed and dynamic reach that a per-route comparison misses entirely.

**Cost is set almost entirely by commercial egress terms, not by engineering.** Published cloud egress
sits about an order of magnitude above commodity CDN or owned-infrastructure delivery — while protocol
choice moves the total by single-digit percentages. Egress is roughly 90 % of a self-built transport bill.

**Destination count decides the rest** (§6): unicast is linear at the last mile; no protocol removes it.
**A technology comparison is not where this is won or lost.**

**The follow-on decisions are about ownership, not technology.** Renting fan-out from a CDN transfers
the commodity half and leaves the broadcast-grade half with the distributor on every data plane (§7); the
control plane is largely a build for large broadcasters (§8).

**Hypothesis, not result:** always-on trunk is the hardest case but not permanently lost — clearest for
dynamic, short-lived, long-tail or global-reach-on-demand routes.

---

## 2. What each side's cost structure looks like

**The incumbents.** Satellite is a large up-front, long-term commitment whose cost base is largely fixed
and often already depreciated — so the honest comparison is not cloud against satellite *list* price but
cloud against the **depreciated marginal** cost of incumbent capacity, with fan-out to many receivers
inside the footprint effectively free. Leased fibre and MPLS are priced for dedicated capacity with
contractual QoS, scaling with committed bandwidth and route count and bounded by carrier footprint;
delivery is typically at a few points of presence where clients cross-connect, which is efficient for
anyone already in those facilities and unattractive to everyone else, **because the quote excludes the
cost and lead time of reaching the meet-me point.** Existing IP transport (SRT, Zixi, RIST,
MediaConnect) is the most directly comparable baseline, being already Internet-based.

**A third incumbent line is easy to miss and can dominate the comparison: the receive estate.** Where
the broadcaster supplies receivers to its affiliates — usually because the chain is a vendor-specific
proprietary system — migrating to an equivalent competing system is a capex event across every receive
site rather than a transport decision. It sits outside the per-route comparison and is how a technically
superior challenger loses on economics that have nothing to do with transport (§7.4).

**The challenger's TCO** must sum at least: relay compute (scaling with connection count, only weakly
with bandwidth); egress (the line that dominates); the control plane (§8); 24/7 operations to the
broadcast standard; tooling and monitoring; the edge grooming and interop work; and the receiver at the
far end. A model counting only egress and compute understates the build and overstates how
substitutable the offering is.

**Two lines are excluded from every figure below and can exceed all of them at low route counts:**
staffing, and the control plane. At the single-route scale in §4, one on-call engineer costs more than
the entire modelled transport line. **This is a transport-line comparison, not a business case.**

---

## 3. The measured inputs

Two of the model's inputs are measured rather than assumed ([Evidence](evidence.md) §3.5, §3.6).

**Relay compute is not the constraint.** A subscriber session costs 0.34 % / 0.87 % / 1.18 % of a core
at 2 / 10 / 27 Mbps *co-resident*, so cost per delivered Mbps *falls* as bitrate rises and one core
forwards on the order of a gigabit. High-bitrate contribution feeds are the *cheapest per Mbps* to relay,
which cuts against the intuition that they are the expensive case. They are — but on the egress line.
**For a sizing decision use the cross-host figure instead**: with the relay alone on its own instance and
every subscriber elsewhere, a remote subscriber costs **0.806 % of a core** and the tier sizes as
**124–139 subscribers per core** ([Evidence](evidence.md) §3.6). Two cautions travel with it — a
GSO-disabled run understates relay CPU by ~29 %, and past the limit throughput *collapses* rather than
degrading, so the purchasable capacity is below the measured ceiling.

Cloud instances sustain well below headline network capacity — **relay sizing is an instance-family
decision before core count.**

**Carriage multiplier: 0.982 (MoQ media-aware) vs 1.037 (SRT)** on the same WAN path — MoQ declines
null stuffing the edge regenerates anyway (5.3 % wire saving on the reference clip). **Treat as wash
with upside**, not 5 % of banked egress: advantage tracks source stuffing ratio (§4.5).

---

## 4. The model, at published rates

### 4.1 Assumptions

**Always-on** — 8,760 hours a year, no diurnal or seasonal relief, which is what makes this the
pessimistic case for a usage-priced substrate. **Two bitrate profiles**, 10 and 25 Mbps.
**Active/active 1+1 throughout**, so every transport figure is doubled and held identical on both
sides of every comparison. **Carriage multipliers** as §3. **Regions** Ireland, N. Virginia or Oregon,
which share egress rates. **Excluded**: staffing, tooling, integration, control plane, receive-side
equipment and satellite uplink.

All rates are US dollars, ex-tax. One constant reconciles the pricing models: **one always-on Mbps
moves 3,942 GB a year** (3,671 GiB, which is how AWS bills), so per-hour, per-committed-Mbps and
per-port rates can all be restated as a price per GB.

### 4.2 The price ladder, and why the supplier matters more than the category

What a gigabyte of delivered traffic costs, grouped by **who operates the infrastructure**. Every row
is a published rate except the one marked *assumed*.

| Category | Option | $/GB |
|---|---|---|
| **Self-hosted** — own the egress; transit and ports, unmetered per GB | Surveyed IP transit, competitive hub, 10–100 GigE port — *bandwidth only* | 0.00015–0.00021 |
| | Illustrative all-in point of presence, 40–100 % utilised *(assumed)* | 0.0009–0.0023 |
| **Cloud** — own software on rented compute, metered egress | AWS / Azure / GCP list egress, first tier | 0.080–0.120 |
| | AWS / Azure / GCP, deepest published volume tier | 0.040–0.050 |
| **Vendor / managed** — buy delivery as an outcome | Zixi Broadcaster licence (Marketplace list) *on top of* AWS list egress | 0.140 |
| | Fastly CDN, list, North America | 0.120 |
| | CloudFront / Cloud CDN / Front Door, list, first tier, NA-EU | 0.080–0.085 |
| | AWS Elemental MediaConnect, reserved bandwidth, smallest (50 Mbps) tier | 0.052 |
| | Cloudflare MoQ relay, announced general-availability rate | 0.050 |
| | **MediaConnect, reserved bandwidth, largest (1500 Mbps) tier** | **0.017** |
| | **bunny.net CDN, standard network, NA-EU list** | **0.010** |
| | **bunny.net CDN, volume network, first 500 TB** | **0.005** |
| | bunny.net CDN, volume network, 1–2 PB | 0.002 |

**The category tells you almost nothing; the supplier tells you everything.** "Vendor / managed" spans
$0.002–$0.140; the cloud band sits in the middle, above commodity CDN and below premium managed products.

Surveyed transit against list cloud egress is a **four-hundredfold** gap, and it is the figure most
likely to be misquoted, because transit buys a port and a BGP session rather than a delivery service.
Loaded with facilities, hardware and transit diversity, self-hosted delivery lands at
**$0.001–0.004/GB — the same band as commodity CDN volume pricing** — so **the defensible gap between
running delivery and renting it from a hyperscaler is about tenfold.** That two independent routes to
delivery, one built and one bought, agree on the cost is the most useful thing in this table: it
suggests commodity CDN rates sit near the real cost of delivery at scale, and that most of what sits
above them is margin, product or positioning.

Independent CDN list is nine to forty-five times below cloud egress list, published on a public price
page with no negotiation; the hyperscalers' own CDNs are barely cheaper than their raw egress ($0.085
against $0.090), which says that spread is commercial positioning rather than cost. **One caveat belongs
with the cheapest rate:** the volume network runs far fewer points of presence, which matters much less
for a few hundred fixed professional endpoints than for a consumer audience — but it is the same reach
constraint that limits leased fibre. MediaConnect reserved bandwidth reaches $0.017/GB at its largest
tier, five times cheaper than first-tier data transfer out on the same cloud and a construct a
self-built fleet cannot buy, so the "build it and keep the service margin" instinct is **inverted at
list prices** — though a commodity CDN still undercuts it two- to threefold, making the inversion
specific to staying inside one hyperscaler.

**Procurement is the largest lever inside the cloud, and it cannot win the fan-out argument.** Even a 95 %
discount moves parity only from ~19 to ~385 destinations. **Supplier choice, not buying power, decides
whether delivery needed to be inside the cloud at all** (§4.6).

### 4.3 Owning the egress

Not buying metered egress at all is the largest structural lever. Owned/co-located relay fleets pay
transit, ports and facilities — unmetered per GB. Illustrative all-in PoP: **$0.001–0.004/GB** (~tenfold
below list egress; **distrust most** — illustrative facilities/hardware assumptions).

Open-source relay + standardised protocol lowers entry vs the SRT era; a relay is a cache (§4.4), so the
operational shape is familiar. Caveats: capex for opex, utilisation threshold, reach where built, control
plane still required. **Barrier lower, not absent.**

### 4.4 A transponder's worth of channels: the parity threshold

Like-for-like against a 36 MHz transponder (~8 HD services at 10 Mbps, 1+1, committed capacity only,
delivery cost):

| Destinations | Aggregate wire | Cloud, MediaConnect reserved *(published)* | Cloud, tiered list less 70 % *(hypothetical)* | CDN relay @ $0.010/GB *(assumed)* | CDN relay @ $0.005/GB *(assumed)* |
|---:|---|---:|---:|---:|---:|
| 1 | 157 Mbps | 52,400 | 14,900 | 6,200 | 3,100 |
| 8 | 1.3 Gbps | 122,700 | 83,200 | 49,500 | 24,800 |
| 32 | 5.0 Gbps | 445,800 | 290,900 | 198,200 | 99,100 |
| 128 | 20.1 Gbps | 1,610,100 | 1,121,500 | 792,800 | 396,400 |
| 512 | 80.4 Gbps | 6,297,300 | 4,444,000 | 3,171,200 | 1,585,600 |
| 1024 | 160.9 Gbps | 12,551,000 | 8,874,100 | 6,342,300 | 3,171,200 |
| *per destination, at scale* | | *10,500* | *8,700* | *6,200* | *3,100* |

Only MediaConnect is buyable at the price shown; 70 % column is **hypothetical**; CDN columns are
**assumed** (Cloudflare MoQ relay: $0.050/GB). **Parity** = incumbent space-segment cost ÷ per-destination
figure — per $1M/year normaliser: **~95** (committed cloud), **115** (70 % cloud), **162** ($0.010 CDN),
**323** ($0.005 CDN). Self-hosting (~970/destination at illustrative rates, parity ~1,000) omitted for
reach reasons (§4.3).

**Reclamation bound:** arguable to ~95 destinations on published cloud rates; commodity CDN to high
hundreds; 1,000+ out of reach for anything purchasable today. Incumbent free fan-out inside footprint
vs linear unicast columns — ceiling *moves*, not disappears.

**Transport choice moves the table by single digits; destination count by three orders** (§1). One
economic question: whether the far end needs the contribution mux back byte-for-byte.

| Transport | Wire multiplier | Latency | Fan-out topology | Standardisation |
|---|---|---|---|---|
| MoQ, media-aware | 0.982 *(measured; 0.973 with MTU discovery)* | **2,447 ms** P1-conformant, or **109 ms** on a build whose wire cannot be made conformant *(both measured over the internet, source to groomed egress)* | relay fans out; last mile is N unicast copies | IETF draft, open implementations — but carriage **fails against every third-party relay** ([Evidence](evidence.md) §3.7) |
| SRT | 1.037 *(measured, same path)* | **1,618 ms** at a 1 s jitter buffer *(measured, same path and window)* — sub-second is a matter of setting the buffer shallower | no native fan-out; N sessions or a re-origination tier | published spec, open source |
| Zixi | ~1.03 *(estimated)* | sub-second *(vendor claim, not measured here)* | broadcaster fans out | proprietary, per-GB licence |
| HLS with TS / DVB-DASH | **1.056 over HTTP/3, 1.029 over HTTP/2 on TCP** *(HTTP layer measured at 1.0006×; framing derived)* | **4,067 ms** *(measured, same path)*, and 9,286 ms at the depth that makes it P1-conformant; ~2–5 s low-latency mode, ~6 s on free TS tooling | cache fans out | *informational* spec, ETSI TS 103 285 — **not standards-track, yet carried by every cache, CDN and general-purpose client; the low-latency transport-stream receive path is the exception** ([Comparison](comparison.md) §6.1) |

*The latency column is source-to-groomed-egress over the public internet from a common EC2 origin, and
it carries an important non-economic condition: **a latency figure on this lane is meaningless without
the conformance of the same bytes.** Held at conformance the ordering is MoQ 2,447 ms, segmented HTTP
9,286 ms, and the transparent tunnels at whatever jitter buffer the operator sets — 1,618 ms at 1 s —
since their egress carries the source's own conformant grid ungroomed. **No conformant sub-second
configuration exists on any lane in this repository** ([Evidence](evidence.md) §3.11). These are
delivery figures, not camera-to-display.*

**No option breaks last-mile linearity** — a relay is a cache (§4.6); upstream collapses to one copy,
last mile stays N unicast. CDN brings a **price**, not a topology: commodity $0.005–0.010/GB vs $0.09
cloud egress; MoQ relay from one supplier at 5–10× commodity today.

### 4.5 Where relay fan-out changes the bill, and where it does not

**Relay fan-out does not reduce last-mile egress** — measured: 150 subscribers get **9.84 Mb/s each, a
full copy** ([Evidence](evidence.md) §3.6). What is nearly free is *state* (1.39 MB, 0.806 % core per
subscriber). Upstream backhaul economises where receivers cluster (~$11,500/yr flat vs $185,000 for
sixteen without relay on the eight-service model) — same topology as HTTP cache (§4.4). **Carriage
overhead is not where the money is** — 5.3 % wire saving is real but dwarfed by supplier choice (§3).

### 4.6 The market-structure argument

**Hypothesis about market structure, not a measured result** — MoQ could reach commodity pricing in the
sub-second band segmented HTTP already occupies elsewhere. Question: **who operates the replication point,
and which market prices it?**

| Data plane | Who runs the fan-out | Market it is priced in |
|---|---|---|
| Segmented HTTP | the commodity delivery market, a dozen suppliers, today | $0.005–0.010/GB commodity CDN list |
| MoQ | one CDN today; otherwise you | $0.050/GB published, or hyperscaler egress if self-run |
| SRT / Zixi / RIST | **you, or a managed media service** | own transit, or ~$0.09/GB metered egress, or per-flow premium |

Hyperscalers sell elasticity; always-on primary distribution should buy committed/commodity delivery
instead.

**A CDN can operate a MoQ relay; it cannot commoditise SRT** — a relay is a cache (§4.4); SRT fan-out
needs a stateful gateway per stream per destination (media-server business). SRT scales via
re-origination or own transit; CDNs take SRT as contribution ingest only. **Open spec + cache-shaped
relay primitive** enables multi-vendor competition — openness alone (SRT) did not.

**Limits this to sub-second routes.** Seconds-latency primary distribution favours segmented HTTP on
commodity economics; the broadcast-grade edge layer cost remains on either plane (§7.2).

**At its narrowest: MoQ could bring commodity pricing to the sub-second band** — parity ~95 vs ~323
destinations in §4.4, not a general cheapest-feed claim.

**Four things would falsify it, and none is settled.** Only one CDN has announced a MoQ relay, at
five to ten times commodity delivery. Professional contribution carries SLA, monitoring and support
obligations that consumer CDN pricing does not, so some of the gap is real cost rather than margin.
Relay portability between implementations is currently absent in practice
([Evidence](evidence.md) §3.7) — a market cannot commoditise a product buyers cannot switch between.
**And the band itself is not yet evidenced: no conformant sub-second configuration has been measured on
any lane** ([Comparison](comparison.md) §5.1), so the segment this argument addresses is at present a
projection. **The strongest economic case for MoQ therefore rests on an interoperability problem being
solved and on a conformance-at-latency result that does not yet exist.**

---

## 5. Value drivers beyond unit cost

A per-route cost comparison understates the challenger, because several advantages are economic but
not captured in a transport line item.

- **Per-destination customisation.** Each destination is an independent session rather than a shared
  carrier, so an IP path can deliver a *different* feed to each — regional ad insertion, alternate
  audio or subtitle sets, localised branding, blackout handling, per-affiliate bitrate. Satellite
  broadcasts one multiplex to the whole footprint, so the same thing means another carrier or
  equipment at every site. **This is the clearest case where unicast's cost structure buys something
  satellite cannot sell at any price**, and it partly offsets the fan-out disadvantage: some of those
  N copies are not duplicates.
- **A bridge, not only a destination.** Any of these transports can feed existing head-ends today
  through an IRD-facing gateway, so the transport can be modernised before receive-side equipment
  supports streaming formats natively — decoupling the two migrations and letting the expensive one
  run on its own schedule.
- **Provisioning speed.** "Channel in minutes, not months" converts lost revenue into recoverable
  value, and avoids the meet-me-point lead time.
- **Multi-tenant leverage.** Shared fabric amortises fixed cost across tenants, and committed-bandwidth
  discounts sell in coarse blocks that an aggregator can fill where no single tenant can — worth up to
  a fivefold reduction in the dominant line, larger than any efficiency in the transport itself.
- **Incident and operational reduction** *may* follow from API-driven, observable operation. **This is
  unproven and could be offset by a new platform's immaturity. A hypothesis, not a saving.**
- **Elasticity is not a value driver here.** Paying only for capacity in use is an advantage for
  variable demand and a penalty for steady demand, so for always-on trunk it earns nothing; the
  response is committed, commodity or owned capacity.

---

## 6. Where the comparison inverts

Two variables decide every case, and neither is a transport property: **destination count** and **the
market the delivery is bought in**.

| Scenario | Favours | Why |
|---|---|---|
| Always-on trunk, few destinations | challenger | Comfortable at any rate on the ladder; the constraint is the fixed cost around it, not the transport |
| Always-on trunk, tens of destinations | arguable | Turns on procurement inside the cloud, comfortable outside it (§4.3, §4.4) |
| Always-on trunk, hundreds | **depends entirely on the supplier** | Lost at metered cloud rates, arguable at committed ones, competitive on commodity delivery or owned infrastructure |
| Always-on trunk, a thousand or more | **incumbent** | Structural: every option is unicast at the last mile, and nothing purchasable today reaches parity. Only owned infrastructure comes close, and not at the reach this implies |
| Event, occasional, short-window | challenger | Fast provisioning and pay-for-use match the demand shape, though no commitment means no committed discount |
| Global or dynamic reach | challenger | Reach without global procurement or a meet-me point |
| Feeds that differ per destination | challenger | Satellite cannot sell it at any price (§5) |

**Sensitivities:** 1+1 doubles the dominant line (hold equivalent); staffing dominates at low route counts
(§2); carriage overhead varies with **source** stuffing, not protocol (§3).

---

## 7. Own the fan-out or rent it

§6 asks whether to displace the incumbent. This section asks the question that comes immediately after a
yes, and it is a different question with a different answer: **does the broadcaster operate the
replication points itself over its own transit, or rent public infrastructure to do it?** In practice
that is the choice between on-premise SRT or RIST tunnels on owned capacity, and segmented HTTP or MoQ
fanned out by a CDN.

### 7.1 Transport choice determines build-or-rent options

Data-plane choice largely sets the option set (§4.6 — relay-as-cache):

| Data plane | Can you rent the fan-out? | From how many suppliers |
|---|---|---|
| Segmented HTTP | yes, and it is a commodity | a dozen, at published rates |
| MoQ | yes | **one**, at 5–10× commodity |
| SRT / RIST | not to the destination — CDNs take it at the door as contribution ingest | you, or a managed media service at per-flow premium |

SRT ⇒ own replication. Segmented HTTP ⇒ *can* rent cheaply. MoQ today ⇒ build or single supplier (§4.6).

### 7.2 What renting transfers (§1)

A CDN takes fan-out, PoP operation, peering and capacity risk — **not** the conformance hand-off
(nothing off-the-shelf on MoQ lane; [Evidence](evidence.md) §3.2), TR 101 290 monitoring inside its
network, entitlement/control plane (§8), receive estate (§2), or broadcast-standard operations.

**Transferred complexity is bandwidth-shaped; retained is broadcast-shaped** — most of the *bill*, not
most of the *engineering*.

### 7.3 The on-prem SRT case is stronger than this paper's direction implies

- **No hand-off problem.** Byte-faithful SRT is transparent on every criterion over a real path — all 13
  PIDs, SI/splice, stuffing, source mux rate, PSI cadence, PCR grid, 0 continuity errors, **0
  PCR-accuracy violations at 481 ns P2, measured ungroomed** ([Evidence](evidence.md) §3.1). **Removes
  the entire edge-conformance workstream** MoQ cannot buy out of.
- **Primary distribution has little fan-out** (§4.5) — tens of destinations, N tunnels tractable; CDN
  fan-out economics barely apply.
- **Fixed costs already sunk** — NOC, monitoring, transit, receive estate; own transit is cheapest per
  byte (§4.6) and reach is not binding inside the footprint.

**Two measured qualifications cut the other way.** SRT continuity degrades under well-behaved AQM —
4,279 errors under FIFO but **17,652–22,365 under `codel`** at the same shortfall, where MoQ takes none
([Evidence](evidence.md) §3.3, [T8b](../lab/test-8b-congestion-control.md)) — byte transparency delivers
shortfall as corrupted bytes, not absent ones. SRT's latency advantage is a buffer setting, paid from the
resilience budget.

### 7.4 The criteria that actually decide it

Refining "capability, direction, appetite for engineering" into things a broadcaster can answer:

| Question | If yes | If no |
|---|---|---|
| **Is the latency budget sub-second?** | own tunnels — MoQ's architecture reaches the band but **no conformant sub-second configuration has been measured on any lane** ([Comparison](comparison.md) §5.1), so this discriminator is credible rather than evidenced | segmented HTTP over a CDN leads on commodity price, a dozen suppliers and delivery-path interoperability, with an off-the-shelf path back to TS at classic segment durations — **conditional on the receive path being bought or already in the estate, since nothing free receives the low-latency variant** ([Comparison](comparison.md) §6.1). Between roughly 2.5 s and 9 s, MoQ leads at conformance |
| **Do you already own transit and PoPs where the destinations are?** | on-prem is the cheapest base per byte | the meet-me-point cost and lead time is the hidden line that decides it (§2) |
| **Are there more than tens of destinations, clustered by region?** | rented fan-out starts to pay, because that is the topology where a relay economises backhaul (§4.5) | it buys little; the linearity is in the last mile either way |
| **Are you willing to own a conformance stage no vendor sells?** | MoQ is available to you | segmented HTTP or SRT, where the hand-off is bought or unnecessary |
| **Can you tolerate a single supplier for the replication tier?** | MoQ on a CDN is available today | segmented HTTP, or self-operate |
| **Is the receive estate vendor-specific?** | it may decide the question on its own, independent of transport (§2) | the transport decision is actually free |

Capability and appetite are **positions**, not preferences — own transit + NOC + tens of destinations
⇒ SRT on own infrastructure; rented fan-out obvious for those without that estate or beyond their
footprint (§6).

---

## 8. Where vendor value concentrates

The conventional reading is that because the transport commoditises, vendor value moves to the control
plane. The first half is right; the second does not survive contact with how a mature broadcaster is
actually built. Value does concentrate there — **but it is largely captured by the operator that builds
it rather than by a vendor that sells it** ([Control](control-plane.md)).

### 8.1 Integration is the product, and it does not generalise

A large broadcaster runs many long-lived, deliberately isolated systems: conditional access, rights,
scheduling, compression, network management, monitoring, service management, finance. A control plane
worth having interfaces with these, because that is what turns provisioning and entitlement work into
something automated rather than a form somebody fills in. **The integration is therefore not an adjunct
to the product; it is most of the value.**

And it does not generalise: every one of those systems is a different vintage, a different vendor or
in-house build, and a different data model at each broadcaster. An off-the-shelf control plane can
supply the parts that are the same everywhere and cannot supply the parts that are the reason to buy it,
so a vendor engagement at this end of the market resolves into a bespoke integration programme with a
licence attached — priced as a product, delivered as professional services, carrying the switching cost
of both. **The category is mis-specified for this buyer rather than merely expensive.**

### 8.2 But "no vendor value" is too coarse — the control plane has layers, and they differ

| Layer | Generalises? | Who should supply it |
|---|---|---|
| **Mechanism** — token issue and verification, key rotation, authorisation enforcement, revocation semantics | yes; it is protocol and cryptography | open source or a vendor. The *enforcement point* is native and verified to exist, but the credential profile above it is a deployment choice rather than a wire primitive, so this layer is generalisable in principle and not yet standardised in practice ([Evidence](evidence.md) §3.10) |
| **Orchestration** — provision a route, place a relay, configure a groomer, tear it down | partly; the primitives generalise, the topology and change process do not | vendor primitives, in-house policy |
| **Observability** — probes and conformance checks generalise; sinks, thresholds, escalation and runbooks are the operator's | partly | vendor probes, in-house integration |
| **Policy** — who is entitled to what, when, under which contract, and what happens when it changes | no; it lives inside the rights, scheduling and CA systems | in-house, necessarily |

**The vendor-addressable layer is real and thin; the company-specific layer is thick.** That is a more
useful conclusion than "zero", and it predicts the shape of a sensible build: buy or adopt the
mechanism, build the policy and the integration, and expect the latter to dominate the estimate.

Same division measured in the data plane: pacing primitive general and upstream; grooming stage
operator-specific ([lab/upstream-contributions.md](../lab/upstream-contributions.md) §8).

### 8.3 Why in-house is now tractable where it once was not

This conclusion would have implied a capital programme a decade ago and does not now, for specific
reasons rather than general optimism: the data plane beneath it is open source and standards-track, so
none of the transport has to be built or licensed; the systems it must integrate now mostly expose APIs
or a message bus, so integration is glue rather than middleware; and hosting it is operating expenditure
at a scale that rounds to nothing beside the egress line in §4. **What remains is a substantial software
engineering exercise whose cost has moved from capital to competence.** A broadcaster that cannot staff
it has not avoided the problem by buying a product, because the product's integration half will be
staffed from the same place.

### 8.4 Where that leaves the value, including one correction

- **Infrastructure providers — CDNs and hyperscalers — capture the durable value.** They sell fungible
  capacity per unit, the one input nobody self-supplies past a certain reach, and §4 puts it at roughly
  90 % of a self-built transport bill. The caveat is §4.6's: for MoQ specifically there is one supplier
  at five to ten times commodity, so the market premise the buyer is relying on is not yet met.
- **Control-plane vendors have a real market, and it is not the giants.** A smaller organisation has
  fewer systems to integrate and often no codified process for the work at all, so the vendor's
  opinionated model *is* the product — bought as a way of acquiring a process rather than automating
  one. That is exactly why the same product cannot be sold upmarket: a mature broadcaster already has
  the process, encoded across those isolated systems, and needs it honoured rather than replaced.
- **Data-plane vendor value has moved rather than disappeared.** There is little left in *transport*.
  But the campaign's own negative results are a product specification: nothing off the shelf turns a MoQ
  egress into a conformant transport stream ([Evidence](evidence.md) §3.2). **The value sits at the
  hand-off, not in the carriage** — the edge appliance, the IRD-facing gateway, the conformance stage —
  which is a smaller market than transport was, and a real one.

### 8.5 The consequence nobody is incentivised to fix

If the largest operators build in-house and vendors serve the small end, then **the interoperability
work has no commercial sponsor at the end of the market that could fund it.** This is not speculative:
relay portability between implementations is absent in practice today, and §4.6 identifies it as one of
four things that would falsify the strongest economic case for MoQ. The broadcasters with the resources
to fix interop are precisely the ones whose in-house builds make it a lower priority for them
individually, and the vendors who would otherwise carry it serve customers too small to pay for it.
**Cooperative or standards-body funding is the structural answer, and the absence of one is a risk to
the thesis rather than a detail of it.**

---

## 9. Open questions

**Commercial, and decisive.**

- **What is the real TCO delta against one broadcaster's *actual, depreciated* route cost?** The
  decisive question, and **unpublishable rather than unknown** — which is why §4.4 supplies the
  challenger's half as a parity threshold against a $1M normaliser. The arithmetic is linear, so
  substituting the incumbent's half is a one-line change an operator can make in private. **Treat the
  published numbers as an upper bound and a method, not a result awaiting data.**
- **Why does published cloud egress sit an order of magnitude above commodity CDN delivery, and does
  anything force that gap to close?** Two independent estimates of what delivery actually costs agree at
  $0.001–0.005/GB, so most of the spread above them is positioning rather than cost. Open: whether
  competition compresses it, and whether a new entrant without hyperscaler volume can buy transit,
  ports and facilities near the rates that make §4.3 work.
- **What will a CDN actually charge to operate a MoQ relay at committed volume?** §4.4 models a modest
  premium over commodity delivery, and **that assumption carries more of the reclamation case than any
  measurement in this repository** — the difference between parity at 95 destinations and at 323. The
  one announced rate is five to ten times higher. **The largest unvalidated input in the model.**
- **Can committed-egress terms be bought for general compute, or only inside a managed product?** §4.2's
  inversion holds only because reserved bandwidth is product-specific.

**Engineering, with a direct economic payoff.**

- **How much of MoQ's carriage advantage survives a different source?** The advantage *is* the 4.57 % of
  null stuffing the reference clip carries, so two more source profiles turn the model's largest
  carriage caveat into a range. The cheapest outstanding measurement on the deciding line
  ([Evidence](evidence.md) §5).
- **What does the opaque lane cost to carry?** Never measured, and it is the lane whose whole promise
  forgoes the null-stripping saving.
- **What is the overhead under loss beyond 1 %?** Both protocols are measured back-to-back at 1 % and
  neither moved by more than a point, but retransmission is charged differently by the two and the
  sender-side cost above 1 % is inferred rather than captured.
- **What does SRT actually cost to fan out?** N origin sessions or a re-origination tier, so a
  per-datagram framing comparison flatters SRT at exactly the topology broadcast uses.

**Platform maturity, which the model assumes away.**

- **Is relay capacity a market the buyer can shop?** The cost case treats it as a commodity procurable
  from more than one supplier; a feed currently traverses only relays from the same implementation as
  the publisher ([Evidence](evidence.md) §3.7).
- **What does relay memory cost to operate around?** A sizing line rather than a restart cycle, since it
  plateaus softly rather than climbing indefinitely — but **the ceiling's scaling term is open by a
  factor of two** and the cost lands on multi-channel relay density, not on audience: growth is flat
  across 0–4 subscribers ([Evidence](evidence.md) §3.6). Separately, **`moq import ts` grows linearly at
  +2.83 MB/h with no drawdown**, which is a restart cycle rather than a sizing line until it is fixed.
- **How much of the operational-saving hypothesis survives running an immature platform to a broadcast
  SLA?** One on-call engineer outweighs the entire modelled transport line at single-route scale.

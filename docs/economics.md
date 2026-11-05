# Economics

Status: working draft. Layer: **cross-cutting.** Scope: a cost framework for comparing Internet-native distribution against incumbent primary distribution, a numeric model of the always-on case built entirely from published rates, and the two ownership questions that follow a decision to proceed: whether to operate the fan-out or rent it (§7), and where vendor value actually sits once the control plane is priced honestly (§8). Reads with: [`lab/cost-model.md`](../lab/cost-model.md), which holds the full working, every rate card and the reproduction script.

**Contents**

- [In brief](#in-brief)
- [1. Question](#1-question)
- [2. Cost structures](#2-cost-structures)
- [3. Measured inputs](#3-measured-inputs)
- [4. Model](#4-model)
  - [4.1 Assumptions](#41-assumptions)
  - [4.2 Price ladder](#42-price-ladder)
  - [4.3 Owned egress](#43-owned-egress)
  - [4.4 Parity threshold](#44-parity-threshold)
  - [4.5 Last-mile egress](#45-last-mile-egress)
  - [4.6 Market structure](#46-market-structure)
- [5. Value drivers](#5-value-drivers)
- [6. Decision boundary](#6-decision-boundary)
  - [6.1 Satellite hybrid](#61-satellite-hybrid)
- [7. Build or rent](#7-build-or-rent)
  - [7.1 Options by transport](#71-options-by-transport)
  - [7.2 Risk transfer](#72-risk-transfer)
  - [7.3 On-prem SRT](#73-on-prem-srt)
  - [7.4 Decision criteria](#74-decision-criteria)
- [8. Vendor value](#8-vendor-value)
  - [8.1 Integration](#81-integration)
  - [8.2 Control-plane layers](#82-control-plane-layers)
  - [8.3 In-house tractability](#83-in-house-tractability)
  - [8.4 Where value lands](#84-where-value-lands)
  - [8.5 Unsponsored interoperability](#85-unsponsored-interoperability)
- [9. Limits](#9-limits)
- [10. Open questions](#10-open-questions)
- [11. References](#11-references)

## In brief

**The cost framework is data-plane agnostic: the data plane enters only as a carriage multiplier and a delivery price** (§3, §4.2).

**Cost is set almost entirely by commercial egress terms, not by engineering** (§4.2). Published cloud egress sits about an order of magnitude above commodity CDN or owned-infrastructure delivery — while protocol choice moves the total by single-digit percentages. Egress is roughly 90 % of a self-built transport bill.

**Destination count decides the rest** (§4.4, §6): unicast is linear at the last mile; no protocol removes it. **A technology comparison is not where this is won or lost.**

**The follow-on decisions are about ownership, not technology.** Renting fan-out from a CDN transfers the commodity half and leaves the broadcast-grade half with the distributor on every data plane (§7); the control plane is largely a build for large broadcasters (§8).

**Hypothesis, not result:** always-on trunk is the hardest case but not permanently lost — clearest for dynamic, short-lived, long-tail or global-reach-on-demand routes (§6).

**Every figure is published or derived in the open from something published, and commercially sensitive inputs are excluded**, so the incumbent's side is a parity threshold rather than a cost, and three inputs that are neither published nor measured are labelled wherever they appear. Staffing and the control plane are outside every figure: this is a transport-line comparison, not a business case (§9).

---

## 1. Question

**The economic question is narrower than "is cloud cheaper than satellite"**: _for a specific class of routes, does an Internet-native path deliver equivalent broadcast-grade service at a total cost low enough, and with enough operational upside, to justify displacing the incumbent — given the incumbent's trust advantage and the challenger's unproven status?_

Buyers weigh three things, in this order. **Reliability and trust** comes first, because no saving justifies a visible failure during contracted content — so economics only enters the decision after the reliability bar is cleared. Then **total cost of ownership** rather than sticker price, since redundancy, operations and integration dominate over a contract lifetime. Then **operational optionality** — the provisioning speed and dynamic reach that a per-route comparison misses entirely.

---

## 2. Cost structures

**Each side carries costs a per-route comparison misses: the incumbent's depreciated base and receive estate, and the challenger's operations, control plane and edge work.**

**The incumbents.** Satellite is a large up-front, long-term commitment whose cost base is largely fixed and often already depreciated — so the honest comparison is not cloud against satellite _list_ price but cloud against the **depreciated marginal** cost of incumbent capacity, with fan-out to many receivers inside the footprint effectively free. Leased fibre and MPLS are priced for dedicated capacity with contractual QoS, scaling with committed bandwidth and route count and bounded by carrier footprint; delivery is typically at a few points of presence where clients cross-connect, which is efficient for anyone already in those facilities and unattractive to everyone else, **because the quote excludes the cost and lead time of reaching the meet-me point.** Existing IP transport (SRT, Zixi, RIST, MediaConnect) is the most directly comparable baseline, being already Internet-based.

**A third incumbent line is easy to miss and can dominate the comparison: the receive estate.** Where the broadcaster supplies receivers to its affiliates — usually because the chain is a vendor-specific proprietary system — migrating to an equivalent competing system is a capex event across every receive site rather than a transport decision. It sits outside the per-route comparison and is how a technically superior challenger loses on economics that have nothing to do with transport (§7.4).

**The challenger's TCO** must sum at least: relay compute (scaling with connection count, only weakly with bandwidth); egress (the line that dominates); the control plane (§8); 24/7 operations to the broadcast standard; tooling and monitoring; the edge grooming and interop work; and the receiver at the far end. A model counting only egress and compute understates the build and overstates how substitutable the offering is; staffing and the control plane are excluded from every figure below (§9).

---

## 3. Measured inputs

**Two of the model's inputs are measured rather than assumed** ([Evidence](../lab/evidence.md) §3.5, §3.6).

**Relay compute is not the constraint.** A subscriber session costs 0.34 % / 0.87 % / 1.18 % of a core at 2 / 10 / 27 Mbps _co-resident_ (subscribers on the relay's own host), so cost per delivered Mbps _falls_ as bitrate rises and one core forwards on the order of a gigabit. High-bitrate contribution feeds are the _cheapest per Mbps_ to relay, which cuts against the intuition that they are the expensive case. They are — but on the egress line. **For a sizing decision use the cross-host figure instead**: with the relay alone on its own instance and every subscriber elsewhere, a remote subscriber costs **1.258 % of a core** on `moq-relay` 0.15.1 (noq), measured, which extrapolates to about 80 subscribers per core. An earlier build (`moq-relay` 0.14.15, on the quinn QUIC stack) measured 0.806 %, or 124–139 per core ([Evidence](../lab/evidence.md) §3.6). Three cautions travel with it. A host without GSO, a Linux setting ([Glossary](glossary.md)), overstates relay CPU: enabling it cut the cost by 25–29 % on both builds. Past the limit throughput _collapses_ rather than degrading, so the purchasable capacity is below the measured ceiling. And each carried channel adds memory of its own, about 60–69 MB for a 10 Mb/s channel at the relay's default retention window, which a setting trades against the history the relay can serve.

Cloud instances sustain well below headline network capacity — **relay sizing is an instance-family decision before core count.**

**The carriage multiplier is 0.982 for MoQ's media-aware lane against 1.037 for SRT** on the same WAN path, because MoQ declines to carry the null stuffing the edge regenerates anyway: a 5.3 % wire saving on the reference clip, 4.57 % nulls, and none on a stuffing-free live feed (1.033 against 1.035; the opaque lane 1.054). **Treat it as a wash with upside**, not as 5 % of egress banked, because the advantage is the source's stuffing ([Evidence](../lab/evidence.md) §3.5).

---

## 4. Model

**The model prices the always-on case, the pessimistic one for a usage-priced substrate, entirely from published rates**; its working and script are in the [cost model](../lab/cost-model.md).

### 4.1 Assumptions

**Always-on** — 8,760 hours a year, no diurnal or seasonal relief, which is what makes this the pessimistic case for a usage-priced substrate. **Two bitrate profiles**, 10 and 25 Mbps. **Active/active 1+1 throughout**, so every transport figure is doubled and held identical on both sides of every comparison. **Carriage multipliers** as §3. **Regions** Ireland, N. Virginia or Oregon, which share egress rates. **Excluded**: staffing, tooling, integration, control plane, receive-side equipment and satellite uplink.

All rates are US dollars, ex-tax. One constant reconciles the pricing models: **one always-on Mbps moves 3,942 GB a year** (3,671 GiB, which is how AWS bills), so per-hour, per-committed-Mbps and per-port rates can all be restated as a price per GB.

### 4.2 Price ladder

**The category tells you almost nothing; the supplier tells you everything.** What a gigabyte of delivered traffic costs, grouped by **who operates the infrastructure**. Every row is a published rate except the one marked _assumed_.

| Category | Option | $/GB |
| --- | --- | --- |
| **Self-hosted** — own the egress; transit and ports, unmetered per GB | Surveyed IP transit, competitive hub, 10–100 GigE port — _bandwidth only_ | 0.00015–0.00021 |
|  | Illustrative all-in point of presence, 40–100 % utilised _(assumed)_ | 0.0009–0.0023 |
| **Cloud** — own software on rented compute, metered egress | AWS / Azure / GCP list egress, first tier | 0.080–0.120 |
|  | AWS / Azure / GCP, deepest published volume tier | 0.040–0.050 |
| **Vendor / managed** — buy delivery as an outcome | Zixi Broadcaster licence (Marketplace list) _on top of_ AWS list egress | 0.140 |
|  | Fastly CDN, list, North America | 0.120 |
|  | CloudFront / Cloud CDN / Front Door, list, first tier, NA-EU | 0.080–0.085 |
|  | AWS Elemental MediaConnect, reserved bandwidth, smallest (50 Mbps) tier | 0.052 |
|  | Cloudflare MoQ relay, announced general-availability rate | 0.050 |
|  | moq.pro MoQ relay, first paid tier | 0.040 |
|  | **MediaConnect, reserved bandwidth, largest (1500 Mbps) tier** | **0.017** |
|  | **bunny.net CDN, standard network, NA-EU list** | **0.010** |
|  | **bunny.net CDN, volume network, first 500 TB** | **0.005** |
|  | bunny.net CDN, volume network, 1–2 PB | 0.002 |

"Vendor / managed" spans $0.002–$0.140; the cloud band sits in the middle, above commodity CDN and below premium managed products.

Surveyed transit against list cloud egress is a **four-hundredfold** gap, and it is the figure most likely to be misquoted, because transit buys a port and a BGP session rather than a delivery service. Loaded with facilities, hardware and transit diversity, self-hosted delivery lands at **$0.001–0.004/GB — the same band as commodity CDN volume pricing** — which puts **the defensible gap between running delivery and renting it from a hyperscaler at about tenfold.** That build-up is _illustrative_ rather than a rate anyone has been quoted, so the agreement is between one published route to delivery and one modelled one. It is still the most useful thing in this table: it suggests commodity CDN rates sit near the real cost of delivery at scale, and that most of what sits above them is margin, product or positioning.

Independent CDN list is nine to forty-five times below cloud egress list, published on a public price page with no negotiation; the hyperscalers' own CDNs are barely cheaper than their raw egress ($0.085 against $0.090), which says that spread is commercial positioning rather than cost. **One caveat belongs with the cheapest rate:** the volume network runs far fewer points of presence, which matters much less for a few hundred fixed professional endpoints than for a consumer audience — but it is the same reach constraint that limits leased fibre. MediaConnect reserved bandwidth reaches $0.017/GB at its largest tier, five times cheaper than first-tier data transfer out on the same cloud and a construct a self-built fleet cannot buy, so the "build it and keep the service margin" instinct is **inverted at list prices** — though a commodity CDN still undercuts it two- to threefold, making the inversion specific to staying inside one hyperscaler.

**Procurement is the largest lever inside the cloud, and it cannot win the fan-out argument.** Even a _hypothetical_ 95 % discount off first-tier list moves parity only from ~19 to ~385 destinations. **Supplier choice, not buying power, decides whether delivery needed to be inside the cloud at all** (§4.6).

### 4.3 Owned egress

**Not buying metered egress at all is the largest structural lever.** An owned or co-located relay fleet pays for transit, ports and facilities, none of it metered per gigabyte, at §4.2's _illustrative_ $0.001–0.004/GB: the figure here to **distrust most**, because its facilities and hardware inputs are assumptions rather than quotes.

An open-source relay and a standardised protocol lower the cost of entry against the SRT era, and because a relay is a cache (§4.6) the operational shape is familiar. The caveats are that it trades opex for capex, pays only above a utilisation threshold, reaches only where it is built, and still needs a control plane. **The barrier is lower, not absent.**

### 4.4 Parity threshold

**Against a transponder, each further destination costs thousands of dollars a year on every purchasable option, so parity is a destination count, which a better rate moves rather than removes.** Like-for-like against a 36 MHz transponder (~8 HD services at 10 Mbps, 1+1, committed capacity only, delivery cost), each further destination costs, at scale, about **$10,500 a year** on MediaConnect reserved _(published)_, **$8,700** on tiered cloud list less 70 % _(hypothetical)_, and **$6,200** and **$3,100** on a CDN relay at $0.010 and $0.005/GB _(assumed)_ ([cost model](../lab/cost-model.md) §6). Only MediaConnect is buyable at the price shown; the published MoQ relay rates are moq.pro's $0.040/GB and Cloudflare's announced $0.050/GB. **Parity** is the incumbent's space-segment cost divided by the per-destination figure. Per $1M a year of that cost it falls at **~95** destinations on committed cloud, **115** at the _hypothetical_ 70 % discount, **162** at an _assumed_ $0.010 CDN rate and **323** at an _assumed_ $0.005. Self-hosting, at ~970 per destination on _illustrative_ rates and parity ~1,000, is omitted for reach reasons (§4.3).

**The reclamation bound follows.** Displacing the incumbent is arguable to ~95 destinations on published cloud rates, and to the high hundreds if a relay can be rented at commodity CDN rates, which is an _assumption_ and not a rate anyone has announced. A thousand or more is out of reach for anything purchasable today. The incumbent's fan-out inside its footprint is free while every option here is linear in destinations, so a better rate _moves_ the ceiling rather than removing it.

**Transport choice moves these figures by single-digit percentages; destination count moves them by three orders of magnitude** ([cost model](../lab/cost-model.md) §10). The one economic question transport choice does raise is whether the far end needs the contribution mux back byte-for-byte.

| Transport | Carriage multiplier | Latency | Fan-out topology | Standardisation |
| --- | --- | --- | --- | --- |
| MoQ, media-aware | 0.982 _(measured on a 4.57 %-stuffed clip; 0.973 with MTU discovery; 1.033 on a stuffing-free feed)_ | **2,447 ms** P1/P2-conformant, or **141 ms** on a build whose wire cannot be made conformant _(both measured over the internet, source to groomed egress)_ | relay fans out; last mile is N unicast copies | IETF draft, open implementations; carriage passes eight of nine other relays after the join, five for a late subscriber ([Evidence](../lab/evidence.md) §3.7) |
| SRT | 1.037 _(measured, same path; 1.035 on the feed)_ | **1,623 ms** at a 1 s jitter buffer _(measured, same path and window)_ — sub-second is a matter of setting the buffer shallower | no native fan-out; N sessions or a re-origination tier | published spec, open source |
| Zixi | ~1.03 _(estimated)_ | sub-second _(vendor claim, not measured here)_ | broadcaster fans out | proprietary, per-GB licence |
| HLS with TS segments | **1.056 over HTTP/3, 1.029 over HTTP/2 on TCP** _(HTTP layer measured at 1.0006×; framing derived)_ | **2,604 ms** P1/P2- and buffer-model-conformant, on one-second segments _(measured, same path)_; ~2–5 s low-latency mode, ~6 s through the free TS clients | cache fans out | _informational_ spec, RFC 8216 and its second edition; DVB-DASH (ETSI TS 103 285) profiles ISOBMFF only — **not standards-track, yet carried by every cache, CDN and general-purpose client; how a receiver rebuilds a transport stream from it is specified nowhere** ([Comparison](comparison.md) §4.4, §9.1) |

_The latency column is source-to-groomed-egress over the public internet from a common EC2 origin, and it carries an important non-economic condition: **a latency figure on this lane is meaningless without the conformance of the same bytes.** Held at TR 101 290 P1/P2 conformance MoQ and segmented HTTP are level, at 2,447 and 2,604 ms, and the transparent tunnels sit at whatever jitter buffer the operator sets — 1,623 ms at 1 s — since their egress carries the source's own conformant grid ungroomed. No sub-second configuration has been measured conformant on MoQ (§4.6). These are delivery figures, not camera-to-display._

### 4.5 Last-mile egress

**Relay fan-out does not reduce last-mile egress.** Measured, 150 subscribers each receive **9.84 Mb/s, a full copy** ([Evidence](../lab/evidence.md) §3.6). What is nearly free is _state_: 2.62 MB and 1.258 % of a core per subscriber on `moq-relay` 0.15.1, and 1.39 MB and 0.806 % on `moq-relay` 0.14.15. Where receivers cluster, the relay economises upstream backhaul instead, ~$11,500 a year flat against $185,000 for sixteen destinations without a relay on the eight-service model, which is the same topology an HTTP cache exploits (§4.6). **Carriage overhead is not where the money is**: the wire saving, at most the source's stuffing, is real, but supplier choice dwarfs it (§3).

### 4.6 Market structure

**This is a hypothesis about market structure, not a measured result**: that MoQ could bring to the sub-second band the commodity pricing segmented HTTP already enjoys at longer latencies. It turns on **who operates the replication point, and which market prices it**.

| Data plane | Who runs the fan-out | Market it is priced in |
| --- | --- | --- |
| Segmented HTTP | the commodity delivery market, a dozen suppliers, today | $0.005–0.010/GB commodity CDN list |
| MoQ | three CDNs today (Cloudflare, Akamai, moq.pro); otherwise you | $0.040–0.050/GB published by two of them, or hyperscaler egress if self-run |
| SRT / Zixi / RIST | **you, or a managed media service** | own transit, or ~$0.09/GB metered egress, or per-flow premium |

Hyperscalers sell elasticity, so always-on primary distribution should buy committed or commodity delivery instead.

**A CDN can operate a MoQ relay; it cannot commoditise SRT.** A relay is a cache and holds no per-destination state a CDN would have to operate, whereas SRT fan-out needs a stateful gateway per stream per destination, which is a media-server business. SRT therefore scales through re-origination or owned transit, and CDNs take it only as contribution ingest. **An open specification combined with a cache-shaped relay primitive** is what enables multi-vendor competition; openness alone, in SRT's case, did not.

**The argument is limited to sub-second routes.** At seconds of latency, primary distribution favours segmented HTTP on commodity economics, and the cost of the broadcast-grade edge layer remains on either plane (§7.2). **The price follows the product, not the HTTP version**: classic HLS rides HTTP/1.1 and Low-Latency HLS needs HTTP/2 or HTTP/3, and CloudFront and Akamai publish no surcharge for HTTP/3 delivery, so either segmented mode sits in a delivery contract already negotiated, where a MoQ relay is a separate product with its own rate.

**At its narrowest, then, the claim is about the sub-second band and is not a general cheapest-feed claim**: parity at ~95 destinations on published cloud rates against ~323 at an _assumed_ commodity relay rate (§4.4). The whole of that gap is the assumption.

**Four things would falsify it, and none is settled.** Only two CDNs publish a MoQ relay rate, at four to ten times commodity delivery. Professional contribution carries SLA, monitoring and support obligations that consumer CDN pricing does not, so some of the gap is real cost rather than margin. Relay portability between implementations is partial: five of nine other relays serve a subscriber joining mid-stream ([Evidence](../lab/evidence.md) §3.7), and a market cannot commoditise a product buyers cannot reliably switch between. **And the band itself is not yet evidenced for MoQ: no conformant sub-second configuration has been measured on it, and none has passed a whole capture on any lane** ([Comparison](comparison.md) §5.1), so the segment this argument addresses is at present a projection. **The strongest economic case for MoQ therefore rests on an interoperability problem being solved and on a conformance-at-latency result that does not yet exist.**

---

## 5. Value drivers

**A per-route cost comparison understates the challenger, because several advantages are economic but not captured in a transport line item.**

- **Per-destination customisation.** Each destination is an independent session rather than a shared carrier, so an IP path can deliver a _different_ feed to each — regional ad insertion, alternate audio or subtitle sets, localised branding, blackout handling, per-affiliate bitrate. Satellite broadcasts one multiplex to the whole footprint, so the same thing means another carrier or equipment at every site. **This is the clearest case where unicast's cost structure buys something satellite cannot sell at any price**, and it partly offsets the fan-out disadvantage: some of those N copies are not duplicates.
- **A bridge, not only a destination.** Any of these transports can feed existing head-ends today through an IRD-facing gateway, so the transport can be modernised before receive-side equipment supports streaming formats natively — decoupling the two migrations and letting the expensive one run on its own schedule.
- **Provisioning speed.** "Channel in minutes, not months" converts lost revenue into recoverable value, and avoids the meet-me-point lead time.
- **Multi-tenant leverage.** Shared fabric amortises fixed cost across tenants, and committed-bandwidth discounts sell in coarse blocks that an aggregator can fill where no single tenant can — worth up to a fivefold reduction in the dominant line, larger than any efficiency in the transport itself.
- **Incident and operational reduction** _may_ follow from API-driven, observable operation. **This is unproven and could be offset by a new platform's immaturity. A hypothesis, not a saving.**
- **Elasticity is not a value driver here.** Paying only for capacity in use is an advantage for variable demand and a penalty for steady demand, so for always-on trunk it earns nothing; the response is committed, commodity or owned capacity.

---

## 6. Decision boundary

**Two variables decide every case, and neither is a transport property: destination count and the market the delivery is bought in.**

| Scenario | Favours | Why |
| --- | --- | --- |
| Always-on trunk, few destinations | challenger | Comfortable at any rate on the ladder; the constraint is the fixed cost around it, not the transport |
| Always-on trunk, tens of destinations | arguable | Turns on procurement inside the cloud, comfortable outside it (§4.3, §4.4) |
| Always-on trunk, hundreds | **depends entirely on the supplier** | Lost at metered cloud rates, arguable at committed ones, competitive on commodity delivery or owned infrastructure |
| Always-on trunk, a thousand or more | **incumbent** | Structural: every _Internet-native_ option is unicast at the last mile, and nothing purchasable today reaches parity. Only owned infrastructure comes close, and not at the reach this implies. This is the square the satellite-hybrid model contests, on the drivers in §6.1 |
| Event, occasional, short-window | challenger | Fast provisioning and pay-for-use match the demand shape, though no commitment means no committed discount |
| Global or dynamic reach | challenger | Reach without global procurement or a meet-me point |
| Feeds that differ per destination | challenger | Satellite cannot sell it at any price (§5) |

**Sensitivities:** 1+1 doubles the dominant line (hold equivalent); staffing dominates at low route counts (§9); carriage overhead varies with **source** stuffing, not protocol (§3).

### 6.1 Satellite hybrid

**The satellite-hybrid model is favoured where hundreds of sites in one footprint share one feed and fades are rare and scattered; ten drivers decide it, all of them reasoned and none priced here.** The table above reads "incumbent" at a thousand destinations because every Internet-native option is unicast at the last mile. **The satellite-hybrid model of [Comparison](comparison.md) §1.2 is the incumbent's move in that square:** it keeps the space segment as the fan-out and buys internet capacity only for repair, which lets an operator trade fade margin — moving to a higher band, or running less of it — without ceding the route. No figure in this document prices it. There is no published satellite capacity rate to put on the ladder in §4.2, this repository has no fade statistics for any real estate, and nothing about the hybrid path has been measured here, so what follows is a decision framework rather than a model, and it is _reasoned_ throughout.

| Driver | Pushes toward satellite-hybrid | Pushes toward fully Internet-native |
| --- | --- | --- |
| **Destinations inside one footprint** | hundreds to thousands, where satellite's marginal cost is already ~0 | tens, which never reach satellite's break-even and where IP linearity is cheap |
| **Feed commonality** | one feed common to every site | per-destination variants, regionalisation or differing formats, which satellite cannot sell at any price (§6) |
| **Fade profile** | rare, short, geographically scattered fades | frequent, long, or regionally correlated fades |
| **Full-stream fallback** | needed seldom, and for few sites at a time | needed as a standing guarantee for most of the estate |
| **Per-site IP capacity** | modest and bursty is sufficient | already provisioned and diverse enough to carry the whole feed continuously |
| **Terrestrial, 4G/5G or LEO availability** | patchy or costly at some sites, which satellite covers and repair fills in | uniformly good, which erodes the reason to keep a space segment at all |
| **Path independence** | genuine space-versus-terrestrial diversity, valued as redundancy | correlated failure modes — weather, local power, a single access provider — that undercut the diversity argument |
| **Receiver estate** | a refresh already due, so hybrid capability rides an existing cycle | recently refreshed, or client-owned with no upgrade path, which makes hybrid capability unbuyable at any protocol price |
| **Satellite commitment** | capacity, antennas and uplink sunk with runway left | a commitment expiring, or a renewal that is itself the decision under review |
| **Operational tolerance** | willing to run two coupled paths, a recovery tier and splice behaviour | one delivery model to operate and staff |

**Three asymmetries decide more than the table suggests.** First, **the saving is in bytes and the bill is often in capacity.** Repair traffic is a small fraction of continuous unicast when counted in bytes transferred, but provisioning — and committed or peak-based pricing — follows the correlated peak rather than the duty cycle. Where credible fallback means many sites could need the full feed at once, the recovery tier approaches full-unicast sizing and the byte saving does not convert proportionally into a lower bill. Second, **the hybrid adds a tier rather than replacing one.** It retains the transponder, antennas and uplink _and_ adds a recovery-server estate, an IP path to every site, and a receiver upgrade, so it is cheaper than plain satellite only if the band or margin trade it unlocks saves more than that tier costs. That comparison turns on negotiated capacity pricing which is not published, so it has to be modelled per case and labelled as modelled wherever it appears. Third, **the receiver capex sits with the client** ([Problem](problem.md) §1.5), so the distributor's business case can be positive while the estate's is not — and the estate then sets the rollout pace. That is the same shape as the edge-stage problem the Internet-native planes have, and it constrains the hybrid just as hard.

**What would actually decide it for a real estate**, none of which this repository holds: per-site fade statistics and, critically, their _joint_ distribution across the estate, from ITU-R P.618 and P.837 modelling of the real site coordinates plus the operator's own outage history; the correlated peak number of sites that could plausibly need full-stream fallback simultaneously; per-site IP capacity, cost basis and measured independence from fade; the age, ownership and refresh schedule of the receiving estate; the negotiated capacity price under both the current and the proposed band; and a conformance measurement of spliced output on hardware, which no public source establishes.

---

## 7. Build or rent

**Renting the fan-out moves most of the bill and little of the engineering, and positions the broadcaster already holds decide between owning and renting (§7.4).** §6 asks whether to displace the incumbent. This section asks the question that comes immediately after a yes, and it is a different question with a different answer: **does the broadcaster operate the replication points itself over its own transit, or rent public infrastructure to do it?** In practice that is the choice between on-premise SRT or RIST tunnels on owned capacity, and segmented HTTP or MoQ fanned out by a CDN.

### 7.1 Options by transport

**Data-plane choice largely sets the build-or-rent options**, for the relay-as-cache reason in §4.6, whose table prices them: SRT or RIST means owning the replication, since CDNs take it only as contribution ingest; segmented HTTP means it _can_ be rented from a dozen suppliers at commodity rates; and MoQ today means building it or renting from one of **three**, the two that publish a rate at four to ten times commodity.

### 7.2 Risk transfer

**A CDN takes on the fan-out, point-of-presence operation, peering and capacity risk.** It does **not** take the conformance hand-off, for which nothing off the shelf exists on the MoQ lane ([Evidence](../lab/evidence.md) §3.2); TR 101 290 monitoring inside its network; the entitlement and control plane (§8); the receive estate (§2); or operations to the broadcast standard.

**The complexity transferred is bandwidth-shaped and the complexity retained is broadcast-shaped**: renting moves most of the _bill_, not most of the _engineering_.

### 7.3 On-prem SRT

**The on-prem SRT case is stronger than this paper's direction implies.**

- **No hand-off problem.** Byte-faithful SRT is transparent on every criterion over a real path — all 13 PIDs, SI/splice, stuffing, source mux rate, PSI cadence, PCR grid, 0 continuity errors, **the source's PCR accuracy intact, ungroomed** ([Evidence](../lab/evidence.md) §3.1). **Removes the grooming workstream** MoQ cannot buy out of; the IRD-facing RTP egress, and an identical pair of it for ST 2022-7, remain on every lane.
- **Primary distribution has little fan-out** (§4.5) — tens of destinations, N tunnels tractable; CDN fan-out economics barely apply.
- **Fixed costs already sunk** — NOC, monitoring, transit, receive estate; own transit is cheapest per byte (§4.6) and reach is not binding inside the footprint.

**Two measured qualifications cut the other way.** SRT continuity degrades under well-behaved AQM — 4,279 errors under FIFO but **17,652–22,365 under `codel`** at the same shortfall ([Evidence](../lab/evidence.md) §3.3, [T8b](../lab/test-8b-congestion-control.md)) — byte transparency delivers shortfall as corrupted bytes, not absent ones. MoQ's counters read zero there, but by construction: its exporter writes its own continuity counters, so its shortfall surfaces as absent content instead, and the zero is not a measurement of it. SRT's latency advantage is a buffer setting, paid from the resilience budget.

### 7.4 Decision criteria

**Six questions a broadcaster can answer decide it**, refining "capability, direction, appetite for engineering":

| Question | If yes | If no |
| --- | --- | --- |
| **Is the latency budget sub-second?** | own tunnels — MoQ's architecture reaches the band, but nothing conformant has been measured in it (§4.6), so this discriminator is credible rather than evidenced | segmented HTTP over a CDN leads on commodity price, a dozen suppliers and delivery-path interoperability, with an off-the-shelf path back to TS at classic segment durations — **conditional on the receive path being bought or already in the estate, since nothing free receives the low-latency variant** ([Comparison](comparison.md) §9.1); at P1/P2 conformance the two deliver level, from about 2.5 s |
| **Do you already own transit and PoPs where the destinations are?** | on-prem is the cheapest base per byte | the meet-me-point cost and lead time is the hidden line that decides it (§2) |
| **Are there more than tens of destinations, clustered by region?** | rented fan-out starts to pay, because that is the topology where a relay economises backhaul (§4.5) | it buys little; the linearity is in the last mile either way |
| **Are you willing to own a conformance stage no vendor sells?** | MoQ is available to you | segmented HTTP or SRT, where the hand-off is bought or unnecessary |
| **Can you tolerate three suppliers, the two that publish a rate both at a premium, for the replication tier?** | MoQ on a CDN is available today | segmented HTTP, or self-operate |
| **Is the receive estate vendor-specific?** | it may decide the question on its own, independent of transport (§2) | the transport decision is actually free |

Capability and appetite are **positions**, not preferences. A broadcaster with its own transit, a NOC and tens of destinations lands on SRT over its own infrastructure; rented fan-out is the obvious answer for one without that estate, or for routes beyond its footprint (§6).

---

## 8. Vendor value

**Value does concentrate in the control plane, but it is largely captured by the operator that builds it rather than by a vendor that sells it** ([Control](control-plane.md)). The conventional reading is that because the transport commoditises, vendor value moves to the control plane. The first half is right; the second does not survive contact with how a mature broadcaster is actually built.

### 8.1 Integration

**Integration is the product, and it does not generalise.** A large broadcaster runs many long-lived, deliberately isolated systems: conditional access, rights, scheduling, compression, network management, monitoring, service management, finance. A control plane worth having interfaces with these, because that is what turns provisioning and entitlement work into something automated rather than a form somebody fills in. **The integration is therefore not an adjunct to the product; it is most of the value.**

And it does not generalise: every one of those systems is a different vintage, a different vendor or in-house build, and a different data model at each broadcaster. An off-the-shelf control plane can supply the parts that are the same everywhere and cannot supply the parts that are the reason to buy it, so a vendor engagement at this end of the market resolves into a bespoke integration programme with a licence attached — priced as a product, delivered as professional services, carrying the switching cost of both. **The category is mis-specified for this buyer rather than merely expensive.**

### 8.2 Control-plane layers

**"No vendor value" is too coarse: the control plane has layers, and they differ.**

| Layer | Generalises? | Who should supply it |
| --- | --- | --- |
| **Mechanism** — token issue and verification, key rotation, authorisation enforcement, revocation semantics | yes; it is protocol and cryptography | open source or a vendor. The _enforcement point_ is native and verified to exist, but the credential profile above it is a deployment choice rather than a wire primitive, so this layer is generalisable in principle and not yet standardised in practice ([Evidence](../lab/evidence.md) §3.10) |
| **Orchestration** — provision a route, place a relay, configure a groomer, tear it down | partly; the primitives generalise, the topology and change process do not | vendor primitives, in-house policy |
| **Observability** — probes and conformance checks generalise; sinks, thresholds, escalation and runbooks are the operator's | partly | vendor probes, in-house integration |
| **Policy** — who is entitled to what, when, under which contract, and what happens when it changes | no; it lives inside the rights, scheduling and CA systems | in-house, necessarily |

**The vendor-addressable layer is real and thin; the company-specific layer is thick.** That is a more useful conclusion than "zero", and it predicts the shape of a sensible build: buy or adopt the mechanism, build the policy and the integration, and expect the latter to dominate the estimate.

Same division measured in the data plane: pacing primitive general and upstream; grooming stage operator-specific ([lab/upstream-contributions.md](../lab/upstream-contributions.md) §8).

### 8.3 In-house tractability

**In-house is now tractable where it once was not.** This conclusion would have implied a capital programme a decade ago and does not now, for specific reasons rather than general optimism: the data plane beneath it is open source and standards-track, so none of the transport has to be built or licensed; the systems it must integrate now mostly expose APIs or a message bus, so integration is glue rather than middleware; and hosting it is operating expenditure at a scale that rounds to nothing beside the egress line in §4. **What remains is a substantial software engineering exercise whose cost has moved from capital to competence.** A broadcaster that cannot staff it has not avoided the problem by buying a product, because the product's integration half will be staffed from the same place.

### 8.4 Where value lands

**Value lands in three places, and the third corrects the conventional reading: data-plane vendor value has moved to the hand-off rather than disappeared.**

- **Infrastructure providers — CDNs and hyperscalers — capture the durable value.** They sell fungible capacity per unit, the one input nobody self-supplies past a certain reach, and the [cost model](../lab/cost-model.md) §5 puts it at roughly 90 % of a self-built transport bill. The caveat is §4.6's: for MoQ the market premise the buyer relies on is not yet met.
- **Control-plane vendors have a real market, and it is not the giants.** A smaller organisation has fewer systems to integrate and often no codified process for the work at all, so the vendor's opinionated model _is_ the product — bought as a way of acquiring a process rather than automating one. That is exactly why the same product cannot be sold upmarket: a mature broadcaster already has the process, encoded across those isolated systems, and needs it honoured rather than replaced.
- **Data-plane vendor value has moved rather than disappeared.** There is little left in _transport_. But the campaign's own negative results are a product specification: nothing off the shelf turns a MoQ egress into a conformant transport stream ([Evidence](../lab/evidence.md) §3.2), and the campaign's own groomer does so only as far as P1/P2 (§3.16 of the same document). **The value sits at the hand-off, not in the carriage** — the edge appliance, the IRD-facing gateway, the conformance stage — which is a smaller market than transport was, and a real one.

### 8.5 Unsponsored interoperability

**If the largest operators build in-house and vendors serve the small end, then the interoperability work has no commercial sponsor at the end of the market that could fund it.** This is not speculative: relay portability between implementations is still partial, and §4.6 identifies it as one of four things that would falsify the strongest economic case for MoQ. The broadcasters with the resources to fix interop are precisely the ones whose in-house builds make it a lower priority for them individually, and the vendors who would otherwise carry it serve customers too small to pay for it. **Cooperative or standards-body funding is the structural answer, and the absence of one is a risk to the thesis rather than a detail of it.**

**On segmented HTTP the unsponsored piece is smaller and sits with the distributor.** Delivery is already multi-supplier, and one CDN origin group fails over between origins itself ([Architecture](architecture.md) §5.3); what no specification covers is how a receiver rebuilds an IRD-ready transport stream from HLS and reports what it lost, and the HLS-input receivers on the market align on nothing beyond HLS. Which kind of input a product is decides whether the DVB layer reaches the IRD: one that hands on the segments' packets keeps every table, and one that remuxes keeps none ([Comparison](comparison.md) §4.4, measured on software stacks). A distributor that publishes that receive profile, with an open reference receiver, lets its affiliates choose among conforming products without the distributor adopting a closed one — a sponsorship one large distributor can fund alone, as the relay-interop work above is not.

---

## 9. Limits

**Every figure here is either published or derived in the open from something published.** Published rates — hyperscaler egress tariffs, MediaConnect and its reserved tiers, CDN price pages, marketplace software rates, EC2 reserved-instance prices, surveyed IP transit — are public and verifiable. The evidence-wide limits, software receivers above all, are [Evidence](../lab/evidence.md) §4's and are not restated here.

- **The incumbent's side is a parity threshold, not a cost.** Commercially sensitive inputs are excluded: no customer pricing, no vendor contract or discount terms, no transponder or fibre lease rates, no incumbent's actual or depreciated route cost, and no third-party reports of what anyone pays at negotiated volume. This qualifies §4.4 and §6, which compare against our own figures instead of theirs. Only an operator can discharge it, in private, by substituting its own route cost into the linear arithmetic (§10).
- **Three inputs are neither published nor measured, and each is labelled wherever it appears.** The negotiated-discount figure in §4.4 is a **hypothetical** percentage off published list — illustrative arithmetic, not anyone's terms. The CDN relay rates are **assumptions** about where a competitive market would land, since only two providers publish a MoQ relay tariff. The self-hosted build-up is **illustrative**. Nothing here should be read as evidence that a particular rate is obtainable. No attempt yet: a committed-volume relay quote would discharge the second, which carries the most (§10).
- **Staffing and the control plane are outside every figure**, and at low route counts they can exceed all of them: at the single-route scale in §4, one on-call engineer costs more than the entire modelled transport line. **This is a transport-line comparison, not a business case**, and no attempt has been made to price them.
- **The carriage multiplier is measured on two sources** (§3), and on both MoQ's advantage is the source's stuffing. It qualifies the deciding line in §4.4; [Evidence](../lab/evidence.md) §5 row 8 would discharge it.
- **The rented-relay market premise is not yet met:** relay portability between implementations is partial, so the suppliers in §4.6 and §7.1 are not interchangeable. [Evidence](../lab/evidence.md) §5 row 9.
- **The satellite hybrid is reasoned, not priced** (§6.1): no satellite capacity rate is published, no fade statistics for a real estate are held, and nothing on the hybrid path has been measured. No attempt yet.

---

## 10. Open questions

**Commercial, and decisive.** No experiment answers these; an operator's own cost or a supplier's quote does.

- **What is the real TCO delta against one broadcaster's _actual, depreciated_ route cost?** The decisive question, and **unpublishable rather than unknown** — which is why §4.4 supplies the challenger's half as a parity threshold against a $1M normaliser. The arithmetic is linear, so substituting the incumbent's half is a one-line change an operator can make in private. **Treat the published numbers as an upper bound and a method, not a result awaiting data.**
- **Why does published cloud egress sit an order of magnitude above commodity CDN delivery, and does anything force that gap to close?** Published commodity CDN delivery and an _illustrative_ self-hosted build-up agree at $0.001–0.005/GB, so most of the spread above them is likely positioning rather than cost. Open: whether competition compresses it, and whether a new entrant without hyperscaler volume can buy transit, ports and facilities near the rates that make §4.3 work.
- **What will a CDN actually charge to operate a MoQ relay at committed volume?** §4.4 models a modest premium over commodity delivery, and **that assumption carries more of the reclamation case than any measurement in this repository** — the difference between parity at 95 destinations and at 323. The two published rates are four to ten times higher. **The largest unvalidated input in the model.**
- **Can committed-egress terms be bought for general compute, or only inside a managed product?** §4.2's inversion holds only because reserved bandwidth is product-specific.

**Engineering, with a direct economic payoff.**

- **How much of MoQ's carriage advantage survives a third source?** On two it _is_ the source's stuffing: 5.3 % against SRT on a clip 4.57 % nulls, none on a stuffing-free live feed. A loosely filled carrier would bound the range. The cheapest outstanding measurement on the deciding line ([Evidence](../lab/evidence.md) §5 row 8).
- **What is the overhead on a lossy real path?** Both protocols are measured back-to-back at 1 % random loss and neither moved by more than a point; random loss beyond that stresses a transport rather than models a route, and the sender-side cost is inferred rather than captured. No attempt yet.
- **What does SRT actually cost to fan out?** N origin sessions or a re-origination tier, so a per-datagram framing comparison flatters SRT at exactly the topology broadcast uses. No attempt yet.

**Platform maturity, which the model assumes away.**

- **Is relay capacity a market the buyer can shop?** The cost case treats it as a commodity procurable from more than one supplier; relay portability is partial (§4.6; [Evidence](../lab/evidence.md) §5 row 9).
- **What does relay memory cost to operate around?** A sizing line rather than a restart cycle, since it plateaus softly rather than climbing indefinitely — **budgeted at about 2–2.5× the slot ceiling per publisher** — and the cost lands on multi-channel relay density, not on audience: growth is flat across 0–4 subscribers ([Evidence](../lab/evidence.md) §3.6). That plateau was measured on the quinn build; on the noq build one 24 h re-soak read the relay flat, so whether the budget is a property of the design or of the QUIC stack is open. No experiment is scheduled.
- **How much of the operational-saving hypothesis survives running an immature platform to a broadcast SLA?** Staffing already outweighs the modelled transport line at single-route scale (§9). Only operation to an SLA would answer it.

---

## 11. References

The rate cards behind every published figure, with their retrieval and the reproduction script, are in the [cost model](../lab/cost-model.md) and its references. The sources named here:

- AWS: [EC2 on-demand pricing, including data transfer](https://aws.amazon.com/ec2/pricing/on-demand/), [Elemental MediaConnect pricing](https://aws.amazon.com/mediaconnect/pricing/) and [CloudFront pricing](https://aws.amazon.com/cloudfront/pricing/).
- Microsoft: [Azure bandwidth pricing](https://azure.microsoft.com/en-us/pricing/details/bandwidth/) and [Azure Front Door pricing](https://azure.microsoft.com/en-us/pricing/details/frontdoor/).
- Google Cloud: [network pricing](https://cloud.google.com/vpc/network-pricing) and [Cloud CDN pricing](https://cloud.google.com/cdn/pricing).
- [Bunny.net pricing](https://bunny.net/pricing/) and [Fastly pricing](https://www.fastly.com/pricing).
- Cloudflare, [MoQ: Refactoring the Internet's real-time media stack](https://blog.cloudflare.com/moq/).
- RFC 8216, [HTTP Live Streaming](https://www.rfc-editor.org/rfc/rfc8216), and [HTTP Live Streaming 2nd Edition](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/), the Internet-Draft revising it.
- ETSI TS 103 285, [DVB-DASH](https://www.etsi.org/deliver/etsi_ts/103200_103299/103285/).
- ITU-R [P.618](https://www.itu.int/rec/R-REC-P.618/), propagation for Earth-space links, and [P.837](https://www.itu.int/rec/R-REC-P.837/), rainfall characteristics.

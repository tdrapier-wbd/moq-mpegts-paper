# Economics

Status: working draft.
Layer: **cross-cutting** — the cost framework is data-plane agnostic; the data plane enters only as a
wire multiplier and a delivery price.
Scope: a cost framework for comparing Internet-native distribution against incumbent primary
distribution, **and a numeric model of the always-on case built entirely from published rates**. The
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

Buyers weigh three things, in this order: **reliability and trust** (no saving justifies a visible
failure, so economics only enters after the reliability bar is cleared); **total cost of ownership**
rather than sticker price, since redundancy, operations and integration dominate over a contract
lifetime; and **operational optionality**, the provisioning speed and dynamic reach a per-route
comparison misses.

**Two conclusions from the model are worth stating before the detail, because they decide everything
after it.**

**Cost is set almost entirely by commercial egress terms, not by engineering.** Published cloud
egress sits about an order of magnitude above what the same delivery costs on a commodity CDN or,
costed all-in, on owned infrastructure — while protocol choice moves the total by single-digit
percentages. Egress is roughly 90 % of a self-built transport bill.

**Destination count decides the rest.** Unicast is linear in destinations where satellite fan-out
inside a footprint is free. Every candidate transport is unicast at the last mile, so the rate
obtained moves the viable ceiling from tens of destinations to high hundreds, and no protocol removes
the linearity. **A technology comparison is not where this is won or lost.**

The position argued toward, as a hypothesis rather than a result: always-on trunk is the *hardest*
case but achievable rather than permanently lost, and achievable further up the destination range
than a cloud-priced model suggests. The case remains clearest for **dynamic, short-lived, long-tail
or global-reach-on-demand routes**, where the incumbent's fixed-cost model fits worst.

---

## 2. What each side's cost structure looks like

**The incumbents.** Satellite is large up-front, long-term commitments with a cost base that is
largely fixed and often already depreciated — so the comparison is not "cloud against satellite list
price" but "cloud against the *depreciated marginal* cost of incumbent capacity", and fan-out to many
receivers inside the footprint is near-free. Leased fibre and MPLS are priced for dedicated capacity
with contractual QoS, scaling with committed bandwidth and route count, with reach bounded by carrier
footprint; a common delivery model is a small number of points of presence in central data centres
where clients cross-connect, which is efficient for anyone already in those facilities and
unattractive to everyone else, because the quote excludes the cost and lead time of reaching the
meet-me point. Existing IP transport (SRT, Zixi, RIST, MediaConnect) is the *most directly comparable*
baseline, because it is already Internet-based.

**A third incumbent line is easy to miss and can dominate the comparison: the receive estate.** Where
the broadcaster supplies receivers to its affiliates — usually because the chain is a vendor-specific
proprietary system — the estate is a switching cost in its own right, since migrating to an
equivalent competing system is a capex event across every receive site rather than a transport
decision. It sits outside the per-route comparison and is how a technically superior challenger loses
on economics that have nothing to do with transport.

**The challenger's TCO** must sum at least: relay compute (scaling with *connection count*, only
weakly with bandwidth); egress (the line that dominates); the control plane (does not scale with
bitrate, but is a substantial build-or-buy decision and **where much of the vendor value in this
market sits** — a model counting only egress and compute understates the build and overstates how
substitutable the offering is); 24/7 operations and support to the broadcast standard; tooling and
monitoring; the edge grooming and interop work; and the receiver at the far end.

**Two lines are excluded from every figure below and can exceed all of them at low route counts:**
staffing, and the control plane. At the single-route scale in §4, one on-call engineer costs more
than the entire modelled transport line. **This is a transport-line comparison, not a business case.**

---

## 3. The measured inputs

Two of the model's inputs are measured rather than assumed ([Evidence](evidence.md) §3.5, §3.6).

**Relay compute is not the constraint.** A subscriber session costs 0.34 % / 0.87 % / 1.18 % of a core
at 2 / 10 / 27 Mbps, so cost per delivered Mbps *falls* as bitrate rises and one core forwards on the
order of a gigabit. High-bitrate contribution feeds are the *cheapest per Mbps* to relay, which cuts
against the intuition that they are the expensive case. They are — but on the egress line.

Not all of that headroom is purchasable: cloud instances are sold with a *sustained* network
allowance well below their headline figure, and a general-purpose 2-vCPU instance sustains under
1 Gbps against the ~2.2 Gbps its cores could forward. **Relay sizing is an instance-family decision
before it is a core-count decision.**

**Carriage overhead is a multiplier of 0.982 for MoQ's media-aware lane against SRT's 1.037** — IP
wire bytes against the source TS rate, both measured on the same WAN path with the same clip. MoQ
delivers the service in 5.3 % less bandwidth, because it declines to carry the clip's 4.57 % null
stuffing, which a byte pipe cannot refuse and which the edge groomer regenerates locally anyway.

**Read that input as "carriage does not count against MoQ", not as 5 % of banked egress.** The size
of the advantage *is* the source's stuffing ratio: a tightly packed carrier converges the two to the
~1.2-point floor that QUIC's mandatory authentication tag imposes, and a loosely filled one widens
the gap well past 5 %. §4 therefore treats this input as a wash with upside.

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

Four conclusions.

**The category tells you almost nothing; the supplier tells you everything.** "Vendor / managed"
spans $0.002 to $0.140 — a seventieth to the whole — so it contains both the most and the least
expensive way to move a gigabyte. Buying an outcome is not inherently expensive and building is not
inherently cheap: the cloud band sits in the *middle*, above every commodity CDN and below the
premium managed products.

**Quote the right multiple on the egress gap.** A gigabyte across surveyed IP transit costs two
hundredths of a cent against nine cents of list cloud egress, and that four-hundredfold gap is the
figure most likely to be misquoted, because transit buys a port and a BGP session rather than a
delivery service. Loaded with facilities, hardware and transit diversity, self-hosted delivery lands
at **$0.001–0.004/GB — the same band as commodity CDN volume pricing** — so **the defensible gap
between running delivery and renting it from a hyperscaler is about tenfold.** That two independent
routes to delivery, one built and one bought, agree on the cost is the most useful thing in this
table: it suggests commodity CDN rates sit near the real cost of delivery at scale, and that most of
what sits above them is margin, product or positioning.

**The CDN market has already commoditised what the cloud still meters.** Independent CDN *list*
pricing is nine to forty-five times below cloud egress list, published on a public price page, with
no negotiation. Meanwhile the hyperscalers' own CDNs are barely cheaper than their raw egress
($0.085 against $0.090), which says that spread is commercial positioning rather than cost. One
caveat belongs with the cheapest rate: the volume network runs far fewer points of presence, which
matters much less for a few hundred fixed professional endpoints than for a consumer audience — but
it is the same reach constraint that limits leased fibre.

**The managed service is cheaper than the platform it runs on.** MediaConnect reserved bandwidth
reaches $0.017/GB at its largest tier, five times cheaper than first-tier data transfer out on the
same cloud, and it is a managed-product construct a self-built fleet cannot buy. The "build it and
keep the service margin" instinct is **inverted at list prices** — though a commodity CDN still
undercuts it two- to threefold, so the inversion is specific to staying inside one hyperscaler.

**Procurement is the largest lever inside the cloud, and it cannot win the fan-out argument.** Any
global media organisation buys under a negotiated agreement, and a 50 % discount halves the dominant
line while the entire measured carriage difference between MoQ and SRT is 5 % of it. But even a 95 %
discount — far beyond anything plausible — moves parity only from about 19 destinations to about 385.
**Two orders of magnitude of commercial leverage buy one order of magnitude of destinations, and the
curve stays linear throughout.** Negotiation changes which routes are viable; it does not change the
shape of the problem. That is an argument for a different *supplier*, not against the fan-out case:
**buying power decides how far a broadcaster gets inside the cloud; supplier choice decides whether
it needed to be inside the cloud at all.**

### 4.3 Owning the egress

The one lever larger than procurement is not buying metered egress at all, and it is the most
consequential structural option in this document. A relay fleet on owned hardware in owned or
co-located facilities pays for transit, ports, space, power and hardware — none of it metered per GB
— so the egress line changes character rather than merely shrinking.

Loaded properly, an illustrative point of presence delivers at **$0.001–0.004 per GB depending on how
full the port runs**, which is roughly an order of magnitude below list egress — **not the two or
three the raw transit rate implies**, and the honest comparison, since nobody delivers video from a
bare transit port. A tenfold structural advantage is still the largest here, and it is where a vendor
or broadcaster competes with hyperscalers rather than reselling them. **It is also the number to
distrust most:** the facilities and hardware lines behind it are illustrative assumptions rather than
published rates, and they are the weakest inputs anywhere in the model.

**It is the route by which a new entrant can compete, which is a change from the SRT era.** The
bandwidth requirement is unchanged — both are unicast at the last hop. What has changed is everything
above the wire: the relay is open source and the protocol is being standardised in the open, so the
software cost of entry is a deployment rather than a licence negotiation or a gateway fleet to build;
and because a relay is a cache (§4.4), the operational shape is one that anyone running commodity
infrastructure already understands.

The caveats bound who can do it: it trades metered opex for capex and commitment, pays only above a
utilisation threshold, reintroduces the reach constraint that limits the leased-fibre model — owned
infrastructure reaches where it is built — and it still requires a control plane that no open-source
relay supplies. **The barrier is lower than it was, not absent.**

### 4.4 A transponder's worth of channels: the parity threshold

This is the table a broadcaster or vendor facing C-band reclamation will look at. Channel count is
taken from the incumbent so the comparison is like-for-like: a 36 MHz-class transponder at DVB-S2
8PSK 2/3 carries about 58.8 Mbps of useful payload, which under statistical multiplexing is 6 to 10
HD services; **the model uses 8**. The transponder sets the channel *count* only.

**On-demand list pricing is deliberately excluded.** A transponder is leased for years, so the honest
counterpart is committed capacity. Eight services, 1+1, at 10 Mbps, annual USD, delivery cost only:

| Destinations | Aggregate wire | Cloud, MediaConnect reserved *(published)* | Cloud, tiered list less 70 % *(hypothetical)* | CDN relay @ $0.010/GB *(assumed)* | CDN relay @ $0.005/GB *(assumed)* |
|---:|---|---:|---:|---:|---:|
| 1 | 157 Mbps | 52,400 | 14,900 | 6,200 | 3,100 |
| 8 | 1.3 Gbps | 122,700 | 83,200 | 49,500 | 24,800 |
| 32 | 5.0 Gbps | 445,800 | 290,900 | 198,200 | 99,100 |
| 128 | 20.1 Gbps | 1,610,100 | 1,121,500 | 792,800 | 396,400 |
| 512 | 80.4 Gbps | 6,297,300 | 4,444,000 | 3,171,200 | 1,585,600 |
| 1024 | 160.9 Gbps | 12,551,000 | 8,874,100 | 6,342,300 | 3,171,200 |
| *per destination, at scale* | | *10,500* | *8,700* | *6,200* | *3,100* |

Only the MediaConnect column can actually be bought today at the price shown. The 70 % column applies
a **hypothetical** discount to the tiered list bill; the two CDN columns are **assumptions** about
where a competitive MoQ relay market would land, since no CDN has published a MoQ relay tariff except
Cloudflare at $0.050/GB. All columns assume capacity can be bought at proportional rates at all,
which at 161 Gbps is itself a question.

**Parity is the incumbent's annual space-segment cost divided by the per-destination figure.** Per
$1M a year of incumbent cost that is about **95 destinations** at the published committed cloud rate,
**115** at a hypothetical 70 % private cloud rate, **162** at an assumed $0.010/GB CDN relay and
**323** at $0.005/GB. **That $1M is a normaliser, not an estimate** — no transponder rate is asserted
anywhere here, and real space-segment cost varies widely with orbital slot, capacity, term and
depreciation. Substitute a real figure; the arithmetic is linear.

*Self-hosting is not a column, though §4.3 argues it is the largest lever.* At the illustrative
all-in rates the multiplex costs around $970 per destination-year, which would put parity near 1,000
destinations. It is left out because that figure would not survive the reach problem: serving several
hundred sites from owned infrastructure means points of presence near all of them, and the build-up
prices one. The number belongs in the text as an indication of where the structural ceiling sits, not
in a column implying it can be bought.

**So the reclamation conclusion is bounded, and the bound is wider than a cloud-only model suggests.
Up to roughly 95 destinations the IP path is arguable on published cloud rates alone; commodity CDN
economics move that into the high hundreds; a thousand destinations is out of reach of everything
here that can actually be purchased today.** Because the incumbent's fan-out inside a footprint is
free while every column is linear in destinations, the ceiling *moves* rather than disappears.

**The transport choice barely registers, and what little it moves is one decision rather than five.**
Every option lands within about 7 % of the same wire volume, so the choice among them moves this
table by single digits while destination count moves it by three orders of magnitude. And the rows do
not vary independently: **the only thing that puts a row below 1.0× is declining to carry the
multiplex verbatim.** So there is one economic question here, and it is not which protocol but
whether the far end needs the contribution mux back byte-for-byte.

| Transport | Wire multiplier | Latency | Fan-out topology | Standardisation |
|---|---|---|---|---|
| MoQ, media-aware | 0.982 *(measured; 0.973 with MTU discovery)* | **109 ms** *(measured over the internet, source to groomed egress)* | relay fans out; last mile is N unicast copies | IETF draft, open implementations — but carriage **fails against every third-party relay** ([Evidence](evidence.md) §3.7) |
| SRT | 1.037 *(measured, same path)* | **1,618 ms** at a 1 s jitter buffer *(measured, same path and window)* — sub-second is a matter of setting the buffer shallower | no native fan-out; N sessions or a re-origination tier | published spec, open source |
| Zixi | ~1.03 *(estimated)* | sub-second *(vendor claim, not measured here)* | broadcaster fans out | proprietary, per-GB licence |
| HLS with TS / DVB-DASH | **1.056 over HTTP/3, 1.029 over HTTP/2 on TCP** *(HTTP layer measured at 1.0006×; framing derived)* | **4,067 ms** *(measured, same path)*, and 9,286 ms at the depth that makes it P1-conformant; ~2–5 s low-latency mode, ~6 s on free TS tooling | cache fans out | *informational* spec, ETSI TS 103 285 — **not standards-track, yet universally interoperable** |

*The latency column is source-to-groomed-egress over the public internet from a common EC2 origin, each
plane at its shallowest runnable groomer cushion, and it carries an important non-economic condition:
the MoQ figure is not TR 101 290 P1-conformant on PCR repetition where the other two are
([Evidence](evidence.md) §3.11). It is a delivery figure, not camera-to-display.*

**No option breaks the linearity, and the common intuition that HTTP caching does is wrong.** A CDN
edge cache fetches a segment once and serves it to N receivers over N unicast connections; a relay
receives an object once and serves it to N subscribers over N unicast connections. **These are the
same topology under different names — a relay is a cache** — so both collapse *upstream* carriage to
one copy and both leave the last mile as N copies. The per-destination figures apply to every row.

**What a CDN brings is a price, not a topology.** Commodity CDN list is $0.005–0.010/GB against
$0.09 of cloud egress. That is not intrinsic to HTTP — it is what a competitive delivery market
charges, and it reaches MoQ as CDNs operate MoQ relays. The real asymmetry is maturity: HTTP delivery
can be bought from a dozen CDNs at commodity rates today, MoQ relay from one, at five to ten times
commodity. **That is what an uncontested early market looks like rather than what the topology
costs.**

### 4.5 Where relay fan-out changes the bill, and where it does not

MoQ's 1:N amplification is the advantage usually cited first, so it deserves an honest accounting:
**it does not reduce last-mile egress.** Delivering to N receivers outside the cloud costs N copies
of internet egress whether or not the protocol has a native relay, because the expensive hop is the
one leaving the cloud.

What a relay removes is duplicated *upstream* carriage. For the eight-service redundant multiplex
backhauled between continents, a regional relay collapses N copies of backhaul into one, holding it
flat at about $11,500 a year however many receivers share the region — against $23,000 for two and
$185,000 for sixteen without it. **So the advantage is real, bounded and specific: it economises
backhaul and uplink, not delivery**, and it only pays where receivers cluster — the same clustering
that favours satellite's free fan-out, so the two advantages compete for the same topologies.

This is exactly what an HTTP cache does, and neither more nor less. The relay is not a differentiator
against CDN-based delivery on cost grounds; it is the same economics reached natively rather than
through segment polling and cache hierarchies, which is an architectural argument and not an economic
one.

**In that context carriage overhead is not where the money is, in either direction.** MoQ's 5.3 %
lower wire rate saves on the order of $360 a year for one redundant 10 Mbps channel to one
destination and $26,000 for eight channels to sixteen — real, but smaller than the gap between two
providers' list prices and a fraction of what committed pricing saves. **Carriage efficiency is the
wrong basis for choosing a transport either way**, which is the same conclusion this section reached
when the measurement pointed the other way.

### 4.6 The market-structure argument

This is the strongest economic case for MoQ in this document and it rests on none of the measurements
above. **It is a hypothesis about market structure, not a result** — and a narrow one, because the
position it argues MoQ could reach is one segmented HTTP already occupies everywhere except the
sub-second band.

The question it answers is **who operates the replication point, and which market prices it.**

| Data plane | Who runs the fan-out | Market it is priced in |
|---|---|---|
| Segmented HTTP | the commodity delivery market, a dozen suppliers, today | $0.005–0.010/GB commodity CDN list |
| MoQ | one CDN today; otherwise you | $0.050/GB published, or hyperscaler egress if self-run |
| SRT / Zixi / RIST | **you, or a managed media service** | own transit, or ~$0.09/GB metered egress, or per-flow premium |

**Hyperscalers are not expensive by accident; they sell elasticity, and elasticity is the wrong
product for this workload.** The premium in metered egress buys the right to stop tomorrow — worth a
great deal to a bursty consumer service and worth nothing to a broadcaster running the same feed at
the same rate for a decade. Primary distribution is the most predictable traffic in the industry,
which is precisely the profile that should command the deepest discount. The commodity CDNs price
nearer that floor to begin with because delivery, unlike elasticity, is a contested market.

**A CDN can operate a MoQ relay as an extension of what it already does, and cannot do the same for
SRT.** A relay is a cache: MoQ has a native object model, publish/subscribe and relays as first-class
protocol elements, so relaying maps onto machinery a CDN already runs at scale. SRT has no object
model and no native relay primitive — fanning it out means a stateful media gateway per stream per
destination, which is a media-server business rather than a delivery business. **That is why no CDN
sells SRT relay as a commodity product, and why one already sells MoQ relay. The absence is
structural, not historical.**

**SRT can nonetheless be scaled, and saying otherwise would be wrong.** The mechanism is a
re-origination or gateway tier, so a DIY relay platform is a serious answer rather than a workaround.
What the market does not sell is that replication *to the destination*: CDNs support SRT at the door,
as contribution ingest into a packaging tier that then fans out as segmented HTTP. An SRT trunk to N
professional endpoints therefore resolves to one of three cost bases — own transit and PoPs (cheapest
per byte, bounded by reach); a gateway fleet in a hyperscaler (easiest, and structurally the most
expensive, because every copy leaves through metered egress at roughly ten times commodity delivery);
or a managed media service with premium per-flow pricing and structural rather than elastic quotas,
such as a transport-stream flow allowing **50 outputs, not increasable**, past which the topology
becomes chained flows each paying egress again.

**Openness is a necessary condition rather than the distinguishing one**, and the two are easily
conflated. An open, royalty-free specification is what allows *many* suppliers to implement the same
relay and compete on price — a proprietary protocol commoditises only as far as its licensor permits,
which is why a per-GB licence sits on top of every rate rather than falling with them. But SRT is
open too and produced no commodity relay market, because openness without a cache-shaped relay
primitive gives a delivery business nothing it can sell. **It is the combination — an open
specification and an architecture a CDN can already operate — that makes multi-vendor competition
possible.**

**The obvious objection is the strongest one, and it limits this argument to part of the market.** If
a route's latency budget is seconds rather than sub-second — which covers *most* primary distribution
— then segmented HTTP has commodity economics *and* sufficient latency *and* interop MoQ has not
demonstrated *and* an off-the-shelf path back to a transport stream, and this entire section stops
applying to that route. What choosing it does not avoid is the cost of the broadcast-grade edge
layer, which the distributor owns on either data plane.

**Stated at its narrowest: MoQ is the first transport that could bring *commodity* pricing to the
sub-second band.** It is not a general claim that MoQ is the cheapest way to move a broadcast feed
over the internet. On the model in §4.4, that is the difference between parity at 95 destinations and
323.

**Three things would falsify it, and none is settled.** Only one CDN has announced a MoQ relay, at
five to ten times commodity delivery. Professional contribution carries SLA, monitoring and support
obligations that consumer CDN pricing does not, so some of the gap is real cost rather than margin.
And relay portability between implementations is currently absent in practice
([Evidence](evidence.md) §3.7) — a market cannot commoditise a product buyers cannot switch between.
**The strongest economic case for MoQ therefore rests on an interoperability problem being solved.**

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

The last of the trunk rows is the clearest limit on the thesis, and the one above it is where the
argument is actually contested — a range a cloud-only model would have written off entirely.

**Three sensitivities bound all of it.** *Redundancy level*: 1+1 doubles the dominant line exactly and
must be held equivalent on both sides or the comparison is meaningless. *SLA and staffing*: fixed, and
dominant at low route counts — one on-call engineer costs more than the entire modelled transport
line at single-route scale, which is the strongest argument against reading §4 as a business case.
*Like-for-like carriage*: hold each transport to its own measured overhead rather than to a nominal TS
rate, and note that the sensitivity is on **the source**, not the protocol (§3).

---

## 7. Open questions

**Commercial, and decisive.**

- **What is the real TCO delta against one broadcaster's *actual, depreciated* route cost?** This is
  the decisive question, and it is **unpublishable rather than unknown**. That is why §4.4 supplies
  the challenger's half as a parity threshold: the arithmetic is linear, so substituting the
  incumbent's half is a one-line change the operator can make in private. **Treat the published
  numbers as an upper bound and a method, not a result awaiting data.**
- **Why does published cloud egress sit an order of magnitude above commodity CDN delivery, and does
  anything force that gap to close?** The trunk question lives inside that spread. Two independent
  estimates of what delivery actually costs agree at $0.001–0.005/GB, which says most of the spread
  above them is positioning rather than cost. What remains open is whether competition compresses it,
  and whether a *new entrant* without hyperscaler-scale volume can buy transit, ports and facilities
  near the rates that make §4.3 work.
- **What will a CDN actually charge to operate a MoQ relay at committed volume?** §4.4 models it at a
  modest premium over commodity CDN delivery, and **that assumption carries more of the reclamation
  case than any measurement in this repository**: it is the difference between parity at 95
  destinations and at 323. The one announced rate is five to ten times higher. Until a second
  provider quotes, this is the largest unvalidated input in the model.
- **Can committed-egress terms be bought for general compute, or only inside a managed product?**
  §4.2's finding that the service undercuts the platform fivefold holds only because reserved
  bandwidth is product-specific.

**Engineering, with a direct economic payoff.**

- **How much of MoQ's carriage advantage survives a different source?** The advantage *is* the 4.57 %
  of null stuffing the reference clip carries. Two more source profiles turn the model's largest
  carriage caveat into a range, and it is the cheapest outstanding measurement on the deciding line
  ([Evidence](evidence.md) §5).
- **What does the opaque lane cost to carry?** The measured figure is the media-aware lane; the
  fallback — the one taken where an intact multiplex must reach an IRD untouched — has never been
  measured, and it is the lane whose whole promise forgoes the null-stripping saving.
- **What is the overhead under loss beyond 1 %?** Both protocols are measured back-to-back at 1 % and
  neither moved by more than a point, but retransmission is charged differently by the two and the
  sender-side cost above 1 % is inferred rather than captured.
- **What does SRT actually cost to fan out?** Serving many destinations over a point-to-point protocol
  needs either N origin sessions or a re-origination tier, so a per-datagram framing comparison
  flatters SRT at exactly the topology broadcast uses.

**Platform maturity, which the model assumes away.**

- **Is relay capacity a market the buyer can shop?** The cost case treats it as a commodity procurable
  from more than one supplier; a feed currently traverses only relays from the same implementation as
  the publisher.
- **What does relay memory growth cost to operate around?** Now understood to plateau rather than climb
  indefinitely, it is a sizing line rather than a restart cycle, and the stream-limit lever reduces it
  sub-proportionally with a ~20–30 MB floor. A 14 h soak puts the ceiling at **2.03× the slot
  arithmetic** — ~200 MB rather than ~100 MB above baseline — decaying monotonically but not flat when it
  ended. **The cost lands on multi-channel relay density and not on audience**: growth rate is flat across
  0–4 subscribers, and five connections reach the same range as two, so this is a per-channel line
  ([Evidence](evidence.md) §3.6).
- **How much of the operational-saving hypothesis survives running an immature platform to a broadcast
  SLA?** One on-call engineer outweighs the entire modelled transport line at single-route scale.

# Economics

Status: working draft
Scope: a cost framework for comparing an Internet-native MoQ distribution path
against incumbent primary-distribution methods, **and a numeric model of the always-on
case built entirely from published rates** (§4). This is the companion to the economic
risk raised in the [README](../README.md).

> **Confidentiality and provenance note.** Every figure here is either published or
> derived in the open from something published. *Published* rates — hyperscaler egress
> tariffs, AWS Elemental MediaConnect and its reserved tiers, CDN delivery price pages,
> marketplace software rates, EC2 reserved-instance prices, surveyed IP transit — are
> public, verifiable and modelled openly in §4 alongside our own lab measurements
> (§3.1). *Commercially sensitive* inputs are excluded: no customer pricing, no vendor
> contract or discount terms, no transponder or fibre lease rates, no incumbent's actual
> or depreciated route cost, and no third-party reports of what anyone pays at
> negotiated volume. Where the comparison needs the incumbent's side, §4.7 gives a
> **parity threshold** against our own figures instead of theirs.
>
> Three inputs are neither published nor measured, and each is labelled wherever it
> appears. The discount ladder in §4.3 and the 70 % column in §4.7 are **hypothetical
> percentages off published list** — illustrative arithmetic, not anyone's terms, and
> not a claim that such a discount has been offered or achieved. The CDN relay rates in
> §4.5 and §4.7 are **assumptions** about where a competitive market would land, since
> only one provider has announced a MoQ relay tariff. The self-hosted build-up behind
> §4.4 uses **illustrative** facilities and hardware costs. Nothing in this document
> should be read as evidence that a particular rate is obtainable.

---

## 1. Purpose

The economic question is narrower than "is cloud cheaper than satellite." It is:
*for a specific class of routes, does an Internet-native MoQ path deliver
equivalent broadcast-grade service at a total cost of ownership (TCO) low enough,
and with enough operational upside, to justify displacing the incumbent — given
the incumbent's trust advantage and the challenger's unproven status?*

Buyers weigh three things, in this order: **reliability and trust** (no saving
justifies a visible failure, so economics only enters after the reliability bar is
cleared — [vision](vision.md) §3.3); **total cost of ownership** rather than sticker
price, since redundancy, operations and integration dominate over a contract
lifetime; and **operational optionality**, the provisioning speed and dynamic reach
that a per-route comparison misses (§5).

The position argued toward, as a hypothesis rather than a result: always-on trunk is the
*hardest* case but **achievable rather than permanently lost**, and achievable further
up the destination range than a cloud-priced model suggests. What decides it is not the
protocol but **which market the delivery is bought in** — metered hyperscaler egress
loses, commodity delivery and owned infrastructure are competitive into the high
hundreds of destinations (§4.7, §4.9). The case remains **clearest for dynamic,
short-lived, long-tail or global-reach-on-demand routes**, where the incumbent's
fixed-cost model fits worst.

Two conclusions from the model (§4) are worth stating before the detail. **Cost is set
almost entirely by commercial egress terms, not by engineering** — published cloud
egress sits about an order of magnitude above what the same delivery costs on a
commodity CDN or, costed all-in, on owned infrastructure, while protocol choice
moves the total by single-digit percentages. And **destination count decides the
rest**: unicast is linear in destinations where satellite fan-out inside a footprint is
free. Every candidate transport — MoQ, SRT, Zixi, HLS, DVB-DASH — is unicast at the last
mile, so the rate obtained moves the viable ceiling from tens of destinations to high
hundreds, and no protocol removes it. A technology comparison is not where this is won
or lost.

Those two together produce the document's main argument for MoQ, set out in §4.9 and
flagged here because it is a claim about markets rather than a measurement: MoQ is the
first sub-second, broadcast-grade transport that a *commodity* delivery market can sell,
because a relay is a cache and CDNs already operate caches at scale. SRT cannot be sold
that way, which is why no CDN offers it. If that competition materialises it moves the
deciding line by more than any engineering change available.

## 2. Baseline cost models (the incumbents)

Each incumbent has a characteristic *cost structure* a comparison must model,
independent of the actual rates:

- **Satellite.** Large up-front, long-term commitments with a cost base that is
*largely fixed and often already depreciated*. The trap for a challenger: the marginal
cost of an *already-leased* transponder carrying an *already-running* feed is very low,
so the comparison is not "cloud vs satellite list price" but "cloud vs the
*depreciated marginal* cost of incumbent capacity." Fan-out to many receivers is
near-free.
- **The receive estate, where the broadcaster owns it.** In some territories the
broadcaster supplies receivers or decoders to its affiliates, usually because the chain
is a *vendor-specific proprietary system* — which makes the estate a switching cost in
its own right, since migrating to an equivalent competing system is a capex event
across every receive site rather than a transport decision. It sits outside the
per-route comparison and can dominate it, which is how a technically superior
challenger loses on economics that have nothing to do with transport.
- **Leased fibre / MPLS.** Priced for dedicated or managed capacity with contractual
QoS; cost scales with committed bandwidth and route count, reach is bounded by carrier
footprint, and provisioning is a procurement exercise the sticker price omits. A common
delivery model is a small number of **points of presence in central data centres where
clients cross-connect** — efficient for anyone already in those facilities and
unattractive to everyone else, because the quote excludes the cost and lead time of
reaching the meet-me point. Reach is the part of this baseline the price list does not
show.
- **Existing IP transport (SRT / Zixi / RIST / AWS MediaConnect).** Licence or service
fees plus underlying network and cloud cost. The *most directly comparable* baseline,
because it is already Internet-based; the MoQ question against it is largely "does MoQ
change the cost structure at all, or only the technology?"

## 3. Proposed model components (the MoQ path)

The challenger's TCO must sum at least the following, per route and in aggregate:

- **Compute / relay cost.** Scales primarily with *connection count* and only weakly
with forwarded bandwidth ([relay](relay.md) §6; measured in §3.1). Shared across
tenants, which is where multi-tenant leverage helps (§5).
- **Egress / network cost.** **The line that dominates and swings the entire
comparison** — §4 puts it at roughly 90 % of a self-built transport bill, spanning an
eightfold range across published options alone. Because primary distribution is
always-on and high-bitrate, an egress-metered network is the worst-matched pricing
model available for it, so the terms on this one line deserve more scrutiny than every
other component combined.
- **Control plane.** Provisioning, entitlement, orchestration and multi-tenant
isolation ([control-plane](control-plane.md), [entitlement](entitlement.md)). It does
not scale with bitrate, but it is a substantial build-or-buy decision and **where much
of the vendor value in this market sits**: the transport is increasingly commodity,
while the system that turns it into provisioned, revocable, auditable services is not.
A model counting only egress and compute understates the challenger's build and
overstates how substitutable the offering is.
- **Operations and support.** 24/7 NOC, on-call and incident response to the broadcast
standard ([operations](operations.md) §8) — substantial, often underestimated, and it
does not shrink because the transport is cheaper.
- **Tooling and monitoring.** Observability, TR 101 290 probing, audit
([operations](operations.md) §3).
- **Integration and grooming.** The edge/interop work that makes output IRD-acceptable
([interoperability](interoperability.md), [architecture](architecture.md) §7).
- **The receiver.** Part of that boundary, but worth naming separately because the
buyer's posture varies and so does the cost: a free open-source receiver (costs
integration effort), an existing vendor agreement for receive technology (costs
commercial negotiation), or a deployed IRD estate that becomes addressable only when
MoQ reaches decoder firmware (costs waiting). Until the third arrives, an edge gateway
handing the existing estate an IRD-acceptable stream is a permanent line in the model,
not a transitional one.

### 3.1 Relay compute and carriage overhead, measured and decomposed

Two of the inputs above no longer need to be assumed. Test 9
([test-9-performance](../lab/test-9-performance.md)) measures them on Linux (2 vCPU)
with the current relay release, MPEG-TS at 2 / 10 / 27 Mbps, fan-out to 85 concurrent
subscribers.


| Per-stream bitrate | CPU per subscriber session | Sessions per core | Egress per core |
| ------------------ | -------------------------- | ----------------- | --------------- |
| 2 Mbps             | 0.34 %                     | ~300              | ~0.6 Gbps       |
| 10 Mbps            | 0.85 %                     | ~120              | ~1.2 Gbps       |
| 27 Mbps            | 1.18 %                     | ~85               | ~2.1 Gbps       |


Nearly fourteen times the bitrate costs about three and a half times the CPU, so cost
per delivered Mbps *falls* as bitrate rises. **Compute is therefore not the
constraint** — one core forwards on the order of a gigabit — and high-bitrate
contribution feeds are the *cheapest per Mbps* to relay, which cuts against the
intuition that they are the expensive case. They are, but on the egress line. CPU rose
with session count without a knee until the host saturated and memory is not a sizing
constraint, so capacity planning is linear; "sessions per core" is a ceiling at full
occupancy, not a sizing target.

**Carriage overhead is a multiplier of 0.98 on the dominant line, and SRT's is 1.04** —
IP wire bytes against the source TS rate, both measured on the same WAN path with the
same clip. MoQ delivers the service in **5.3 % less bandwidth than SRT**, or 6.2 % less
with path MTU discovery enabled, a flag that exists and is off by default. It applies
directly to egress, and a 1+1 path carries it twice, so the sign of this line matters
more than its size. An earlier version of this document put MoQ at 1.12x and priced a
carriage penalty from it; that figure was an artefact of the measuring rig, not a
property of the protocol ([lab: T9](../lab/test-9-performance.md) Corrections).

**MoQ wins because it declines to carry null stuffing.** The reference clip is 4.57 %
nulls, which a byte pipe cannot refuse and the media-aware lane strips on import, the
edge groomer regenerating them from stream position as it does anyway
([architecture](architecture.md) §7). Against the delivered payload MoQ costs +2.79 %,
of which 2.54 points are IP and UDP headers and 0.25 is every QUIC, moq-lite and
container header combined. Priced from the protocol, a QUIC packet spends ~64 bytes on
IP, UDP, its own header, the mandatory authentication tag and stream framing: 5.5 % of a
1200-byte datagram against SRT's 3.3 % for seven TS packets in 1360 bytes, so **the
irreducible penalty against SRT is about 1.2 points**, nearly all of it the 16-byte AEAD
tag QUIC requires and SRT does not. Not carrying stuffing repays that several times
over.

**The advantage grows with stuffing ratio**, so it is largest exactly where broadcast
carriers run loose: 1.9 Mbps of content in a 4 Mbps carrier costs SRT 4.13 Mbps against
roughly half that. **Not carrying stuffing is a structural bandwidth advantage over
every byte-pipe protocol.** The 1+1 objection has gone: a groomer whose stuffing is a
function of stream position produces byte-identical legs while each regenerates its own
nulls, which is measured ([evidence](evidence.md) §7,
[architecture](architecture.md) §14.1).

**The debits, so §4 does not over-claim.** MoQ's return path is eight times SRT's —
1.16 % of the forward rate against 0.13 % — which leaves it 4.3 % cheaper counting both
directions rather than 5.3 %. The measurement is one clip on one clean path, so the
size of the advantage travels with the source's stuffing ratio; a tightly packed carrier
would narrow it towards the 1.2-point AEAD floor, which is why §4 treats this input as a
wash rather than banking 5 % on egress. Under 1 % forward loss both protocols'
overhead rose by about the loss rate and the ranking held. The opaque lane remains
unmeasured ([lab: T9](../lab/test-9-performance.md), [evidence](evidence.md) §8).

**Not all of that compute headroom is purchasable.** Cloud instances are sold with a
*sustained* network allowance well below their headline "up to" figure, which is burst
credit and irrelevant to a 24/7 feed. A general-purpose 2-vCPU instance sustains under
1 Gbps against the ~2.2 Gbps its cores could forward, so **the network allowance
discards more than half the relay's measured capacity**; a network-optimised instance
of the same size sustains 3 Gbps and restores it for roughly 20 % more. Relay sizing is
an instance-family decision before it is a core-count decision.

**Caveats.** Loopback, with subscribers co-resident with the relay: no WAN packet
handling, no NIC cost, no congestion control against real loss, and the carriage figure
additionally measured on one lane with the path MTU pinned at QUIC's minimum. Treat the
*shapes* as the result and the constants as indicative.

## 4. The cost model, at published rates

The framework above is populated here for the hardest case: always-on 24/7/365 linear
distribution, fully redundant. The model, its inputs and its limitations are in
[lab: cost model](../lab/cost-model.md), and
[`cost-model.py`](../lab/cost-model.py) regenerates the figures.

### 4.1 Assumptions

**Always-on** — 8,760 hours a year, no diurnal or seasonal relief, which is what makes
this the pessimistic case for a usage-priced substrate. **Two bitrate profiles**, 10 and
25 Mbps, round numbers bracketing plausible primary-distribution rates.
**Active/active 1+1 throughout**, so every transport figure is doubled
([architecture](architecture.md) §14), held identical on both sides of every
comparison. **Carriage multipliers** of 0.982x for MoQ and 1.037x for SRT, both measured
on the same path with the same clip and both clean-path (§3.1). Both are specific to a
source carrying 4.57 % null stuffing: a tightly packed carrier would converge the two to
within ~1.2 points, and a loosely filled one would widen the gap sharply, so the sensible
reading of this input is that **carriage is a wash or a small MoQ advantage**, not that
MoQ banks 5 % on egress in every case.
**Regions** Ireland, N. Virginia or Oregon, which share egress rates. **Excluded**:
staffing, tooling, integration, receive-side equipment and satellite uplink — a
transport-line comparison only, and §3 is explicit that the excluded lines can dominate
at low route counts.

All rates are **US dollars, ex-tax**. One constant reconciles the pricing models:
**one always-on Mbps moves 3,942 GB a year** (3,671 GiB, which is how AWS bills), so
per-hour, per-committed-Mbps and per-port rates can all be restated as a price per GB.

### 4.2 The price ladder

What a gigabyte of delivered traffic costs, across every published option found, grouped
by **who operates the infrastructure** — which turns out to matter more than which
protocol runs over it. Every row is a published rate except the one marked *assumed*,
which is the illustrative self-hosted build-up from
[lab: cost model](../lab/cost-model.md) §10.1 and is included because the bandwidth-only
transit rate above it would otherwise be read as a delivery price:


| Category | Option                                                              | $/GB        |
| -------- | ------------------------------------------------------------------- | ----------- |
| **Self-hosted** — own the egress; transit and ports, unmetered per GB | Surveyed IP transit, competitive hub, 10–100 GigE port — *bandwidth only* | 0.00015–0.00021 |
| | Illustrative all-in point of presence, 40–100 % utilised *(assumed)* | 0.0009–0.0023 |
| **Cloud** — own software on rented compute, metered egress | AWS / Azure / GCP list egress, first tier            | 0.080–0.120 |
| | AWS / Azure / GCP, deepest published volume tier                    | 0.040–0.050 |
| **Vendor / managed** — buy delivery as an outcome | Zixi Broadcaster licence (Marketplace list) *on top of* AWS list egress | 0.140 |
| | Fastly CDN, list, North America                                     | 0.120       |
| | CloudFront / Cloud CDN / Front Door, list, first tier, NA-EU        | 0.080–0.085 |
| | AWS Elemental MediaConnect, reserved bandwidth, smallest (50 Mbps) tier | 0.052    |
| | Cloudflare MoQ relay, announced general-availability rate           | 0.050       |
| | **AWS Elemental MediaConnect, reserved bandwidth, largest (1500 Mbps) tier** | **0.017** |
| | **bunny.net CDN, standard network, NA-EU list**                     | **0.010**   |
| | **bunny.net CDN, volume network, first 500 TB**                     | **0.005**   |
| | bunny.net CDN, volume network, 1–2 PB                               | 0.002       |


On a log axis, because the ladder spans three orders of magnitude and a linear one
would erase everything the argument depends on:

```
                                                1e-4        0.001       0.01        0.1         1
                                                |-----------|-----------|-----------|-----------|
SELF-HOSTED (own the egress; transit and ports, unmetered per GB)
  IP transit, 100 GigE port -- bandwidth only   ##  0.00015
  IP transit, 10 GigE port -- bandwidth only    ####  0.00021
  Illustrative all-in PoP, 60% utilised         ##############  0.0015
CLOUD (rent compute, pay metered egress, run your own software)
  AWS / Azure / GCP list egress, first tier     ###################################  0.09
  AWS / Azure / GCP, deepest volume tier        ################################  0.045
VENDOR / MANAGED SERVICE (buy delivery as an outcome)
  Zixi Broadcaster licence + AWS list egress    ######################################  0.14
  Fastly CDN, list, North America               #####################################  0.12
  AWS CloudFront, list, first tier NA/EU        ###################################  0.085
  MediaConnect reserved, 50 Mbps tier           #################################  0.052
  Cloudflare MoQ relay, announced GA rate       ################################  0.05
  MediaConnect reserved, 1500 Mbps tier         ###########################  0.017
  bunny.net CDN, standard network, NA/EU        ########################  0.01
  bunny.net CDN, volume network, <500 TB        ####################  0.005
  bunny.net CDN, volume network, 1-2 PB         ################  0.002
                                                |-----------|-----------|-----------|-----------|
```

Full rate cards, tier boundaries and sources are in
[lab: cost model](../lab/cost-model.md) §3. Five conclusions:

**The category tells you almost nothing; the supplier tells you everything.** "Vendor /
managed service" spans $0.002 to $0.140 — a seventieth to the whole — so it contains
both the most and the least expensive way to move a gigabyte. Buying an outcome is not
inherently expensive, and building is not inherently cheap: the cloud band sits in the
*middle*, above every commodity CDN and below the premium managed products.

**Egress pricing, not carriage, is the whole cost — but quote the right multiple.** A
gigabyte across surveyed IP transit costs two hundredths of a cent against nine cents of
list cloud egress, and that four-hundredfold gap is the figure most likely to be
misquoted, because transit buys a port and a BGP session rather than a delivery service.
Loaded with facilities, hardware and transit diversity, self-hosted delivery lands at
$0.001–0.004/GB — *the same band as commodity CDN volume pricing* — so the defensible gap
between running delivery and renting it from a hyperscaler is about tenfold. That two
independent routes to delivery, one built and one bought, agree on the cost is the most
useful thing in this table: it suggests commodity CDN rates sit near the real cost of
delivery at scale, and that most of what sits above them is margin, product or
positioning. Either way the model is very nearly linear in this one input — compute,
instance family, region and protocol each move the total by single-digit percentages — so
the only levers worth pulling are the three commercial ones: which supplier category you
buy in (this section), what you negotiate within it (§4.3), and whether you meter egress
at all (§4.4).

**The CDN market has already commoditised what the cloud still meters.** Independent CDN
*list* pricing is $0.010/GB in NA-EU and $0.005/GB on a volume network, falling to
$0.002/GB at 1–2 PB — nine to forty-five times below cloud egress list, published on a
public price page, with no negotiation and no request fees. Meanwhile the hyperscalers'
own CDNs are barely cheaper than their raw egress ($0.085 against $0.090), which says
that spread is commercial positioning rather than cost. **This is the largest published
discount anywhere in the model, and §4.7 argues it is available to MoQ as much as to
HTTP.** One caveat belongs with the cheapest rate: the volume network runs far fewer
points of presence than the standard one, which matters much less for a few hundred
fixed professional endpoints than for a consumer audience, but it is the same reach
constraint that limits leased fibre in §2.

**The managed service is cheaper than the platform it runs on.** MediaConnect reserved
bandwidth reaches $0.017/GB at its largest tier, five times cheaper than first-tier
data transfer out on the same cloud, and it is a managed-product construct a self-built
EC2 fleet cannot buy. The "build it and keep the service margin" instinct is **inverted
at list prices** — though a commodity CDN still undercuts it two- to threefold, so the
inversion is specific to staying inside one hyperscaler.

**Committed pricing is granular, and the grain is coarse.** Reserved bandwidth sells in
fixed blocks on a twelve-month commitment: one redundant 10 Mbps channel (≈21 Mbps of
wire) cannot fill the smallest block, so on-demand wins, while a redundant 25 Mbps
channel can and saves about a third. The discount rewards predictable scale, which a
trunk portfolio has and a single route does not.

### 4.3 Procurement is the largest lever on that ladder

Any global media organisation buys cloud under a negotiated agreement, not at list, so
the enterprise discount is not a footnote to the arithmetic — it is the model's most
consequential unknown, and worth modelling explicitly. Applying a hypothetical
discount to first-tier list egress and carrying it through the eight-service redundant
multiplex of §4.7:


| *Hypothetical* discount off first-tier list | Effective $/GB | Marginal $/destination-year | Destinations to parity per $1M/yr of incumbent cost |
| ----------------- | -------------- | --------------------------- | --------------------------------------------------- |
| list              | 0.0900         | 51,900                      | 19                                                  |
| 5 %               | 0.0855         | 49,300                      | 20                                                  |
| 10 %              | 0.0810         | 46,700                      | 21                                                  |
| 15 %              | 0.0765         | 44,100                      | 23                                                  |
| 20 %              | 0.0720         | 41,500                      | 24                                                  |
| 25 %              | 0.0675         | 38,900                      | 26                                                  |
| 30 %              | 0.0630         | 36,300                      | 28                                                  |
| 35 %              | 0.0585         | 33,700                      | 30                                                  |
| 40 %              | 0.0540         | 31,100                      | 32                                                  |
| 45 %              | 0.0495         | 28,600                      | 35                                                  |
| 50 %              | 0.0450         | 26,000                      | 39                                                  |
| 55 %              | 0.0405         | 23,400                      | 43                                                  |
| 60 %              | 0.0360         | 20,800                      | 48                                                  |
| 65 %              | 0.0315         | 18,200                      | 55                                                  |
| 70 %              | 0.0270         | 15,600                      | 64                                                  |
| 75 %              | 0.0225         | 13,000                      | 77                                                  |
| 80 %              | 0.0180         | 10,400                      | 96                                                  |
| 85 %              | 0.0135         | 7,800                       | 128                                                 |
| 90 %              | 0.0090         | 5,200                       | 193                                                 |
| 95 %              | 0.0045         | 2,600                       | 385                                                 |


Three things follow, and the third is the important one.

**Discounts and committed tiers reach the same floor rather than compounding.** An
80 % discount lands at $0.018/GB — essentially the $0.017/GB that MediaConnect's
largest reserved tier publishes openly. The deepest published rate is already worth
roughly an 80 % enterprise discount, so expect to reach that floor by one route or the
other, not by stacking both.

**Procurement outweighs every engineering decision in this paper.** A 50 % discount
halves the dominant line; the entire measured carriage difference between MoQ and SRT is
5 % of it, in MoQ's favour (§4.8). Effort should be allocated accordingly.

**But discounting alone cannot win the fan-out argument.** Even a 95 % discount — far
beyond anything plausible — moves parity only from about 19 destinations to about 385.
Two orders of magnitude of commercial leverage buy one order of magnitude of
destinations, and the curve stays linear throughout. **Negotiation changes which routes
are viable; it does not change the shape of the problem.**

That is an argument for a different *supplier*, not against the fan-out case. These
figures are per $1M a year of incumbent cost and measured against cloud first-tier list,
the most pessimistic starting point available: §4.7 runs the same arithmetic from the
deepest published *committed* rate and from commodity delivery, where parity starts near
95 and 323 destinations rather than 19 — reached by buying in a cheaper market rather
than by negotiating harder in an expensive one. **Buying power decides how far a
broadcaster gets inside the cloud; supplier choice decides whether it needed to be
inside the cloud at all.**

One arithmetic caution, because the same percentage appears in both places and does not
mean the same thing. This ladder discounts *first-tier* list and ignores volume tiering,
which is the pessimistic reading; §4.7's "70 % private" column discounts the **tiered**
bill an operator at that scale would actually face, which is already near the deepest
band. The same nominal 70 % therefore reaches parity at 64 destinations here and 115
there. Neither is wrong — they are discounts off different starting points, and the gap
between them is itself a reminder that a headline discount percentage means nothing
without the rate card it is applied to.

### 4.4 Owning the egress

The one lever larger than procurement is not buying metered egress at all, and it is
the most consequential structural option in this document. A relay fleet on owned
hardware in owned or co-located facilities pays for transit, ports, space, power and
hardware — none of it metered per GB — so the egress line changes character rather than
merely shrinking.

The size of that change needs stating carefully, because the headline transit rate
overstates it. Surveyed transit alone prices 2.5 Gbps at roughly $2,100 a year against
$509,000 at list egress, but transit is a port and a BGP session, not a delivery service.
Loaded with a second transit provider for diversity, colocation, power, cross-connects
and amortised hardware, an illustrative point of presence delivers at **$0.001–0.004 per
GB depending on how full the port runs** ([lab: cost model](../lab/cost-model.md) §10.1),
which puts that same 2.5 Gbps between $22,000 and $35,000 a year. **That is roughly an
order of magnitude below list egress, not the two or three the raw transit rate implies**
— and the honest comparison, since nobody delivers video from a bare transit port.

A tenfold structural advantage is still the largest in this document, and it is where a
vendor or broadcaster competes with hyperscalers rather than reselling them. It is also
the number to distrust most: the facilities and hardware lines behind it are illustrative
assumptions rather than published rates, and they are the weakest inputs anywhere in the
model.

**It is also the route by which a new entrant can compete, which is a change from the
SRT era.** The bandwidth requirement is unchanged — both are unicast at the last hop, so
both need upstream capacity linear in destination count, and the relay economises
backhaul and uplink rather than delivery (§4.8). What has changed is everything above
the wire. The relay is open source and the protocol is being standardised in the open,
so the software cost of entry is a deployment rather than a licence negotiation or a
gateway fleet to build; and because a relay is a cache (§4.7), the operational shape is
one that anyone running commodity infrastructure already understands. A challenger with
a few racks in competitive hubs and open-source relays can therefore reach a per-GB cost
below any *published* hyperscaler rate, committed tiers included — which is the mechanism
behind the market-structure argument in §4.9, seen from the supply side rather than the
buyer's.

The caveats are real and they bound who can actually do it: it trades metered opex for
capex and commitment, pays only above a utilisation threshold, reintroduces the reach
constraint that limits the leased-fibre model (§2) — owned infrastructure reaches where
it is built — and it still requires a control plane that no open-source relay supplies
(§4.5). The barrier is lower than it was, not absent.

### 4.5 One channel, one destination, and how each figure is built

Annual cost in **US dollars**, egress plus compute only, for a single channel
delivered 1+1 to one off-cloud destination:


| Category | Option                                            | 10 Mbps     | 25 Mbps       |
| -------- | -------------------------------------------------- | ----------- | ------------- |
| **Self-hosted** *(marginal transit only)* | MoQ on owned infrastructure       | ~16         | ~41           |
| | SRT on owned infrastructure                                  | ~17         | ~44           |
| **Cloud** | MoQ, self-built on EC2                                      | 7,400       | 16,800        |
| | — of which egress                                            | 6,400       | 15,800        |
| | — of which compute                                           | 1,000       | 1,000         |
| | SRT, self-built on EC2, same footprint                       | 7,700       | 17,700        |
| | MoQ, self-built on Azure transit routing / GCP standard tier | 5,900–6,100 | 14,000–14,300 |
| **Vendor / managed** | Zixi Broadcaster licence + self-built on EC2      | 11,800      | 27,900        |
| | AWS Elemental MediaConnect, on-demand egress                 | 9,500       | 19,500        |
| | AWS Elemental MediaConnect, cheapest reserved mix            | 9,500       | 13,500        |
| | MoQ on Cloudflare's relay, announced rate                    | 3,900       | 9,700         |
| | **MoQ relay on a commodity CDN @ $0.010/GB** *(assumed)*      | **770**     | **1,940**     |
| | **MoQ relay on a commodity CDN @ $0.005/GB** *(assumed)*      | **390**     | **970**       |


The same figures at 10 Mbps, on a log axis:

```
                                                10          100         1,000       10,000      100,000
                                                |-----------|-----------|-----------|-----------|
SELF-HOSTED (marginal transit only; excludes ports, facilities, staff, control plane)
  SRT self-hosted on owned infrastructure       ###  17
  MoQ self-hosted on owned infrastructure       ###  16
CLOUD (own software on rented compute, metered egress)
  MoQ, DIY on Azure transit routing             #################################  6,098
  SRT, DIY on EC2                               ###################################  7,749
  MoQ, DIY on EC2                               ##################################  7,385
VENDOR / MANAGED SERVICE
  MoQ relay on CDN @ $0.005/GB (assumed)        ###################  387
  MoQ relay on CDN @ $0.010/GB (assumed)        #######################  774
  MoQ on Cloudflare, announced rate             ###############################  3,871
  MediaConnect (SRT), cheapest reserved         ####################################  9,548
  Zixi Broadcaster on EC2                       #####################################  11,837
                                                |-----------|-----------|-----------|-----------|
```

**The vendor band straddles everything.** A commodity CDN relay is an order of magnitude
below any cloud build, and a licensed managed product is above all of them — the same
seventy-fold spread §4.2 found, reproduced on one route. Whether "buy" beats "build"
depends entirely on *which* vendor, and on this ladder the cheapest credible option and
the most expensive are both things you buy.


Every row is built the same way: **wire volume** (bitrate × 2 for 1+1 × that
transport's carriage multiplier × 8,760 hours) priced through that option's rate card
from §4.2, **plus** any fixed per-flow or licence fee, **plus** compute where the row
is self-built. Taking the Zixi row at 10 Mbps as the worked example:

- Wire rate 10 × 2 × 1.037 = **20.74 Mbps**, which is 76,107 GiB a year.
- AWS egress, first tier $0.09/GiB, less the 100 GB/month free allowance = **$6,748**.
- Zixi Broadcaster licence, AWS Marketplace list, $0.05 per GB of transport traffic on
  81,726 GB = **$4,086**. The licence is charged *on top of* the cloud's own egress,
  which is why this row is the most expensive in the table.
- Compute, two 1-year all-upfront reserved `c6gn.large` instances (one per leg),
  Ireland, $502 each = **$1,004**.
- Total **$11,837**.

Other rows differ only in which of those four terms apply. MediaConnect adds a flow
fee of $0.16 per hour per flow ($1,402 a flow-year, two flows for 1+1) and carries no
compute since the service provides it; its reserved row buys the cheapest combination
of 50/150/500/1500 Mbps committed blocks covering the wire rate, remainder on-demand.
Cloudflare is a flat $0.05/GB on MoQ wire volume, no compute or flow fee. The
self-built rows differ only in rate card and carriage multiplier.

**The two self-hosted rows are marginal costs, not fully-loaded ones, and the difference
is large enough to change the conclusion.** With egress unmetered the only *marginal*
per-channel cost is transit: 19.6 Mbps of MoQ wire at surveyed 10 GigE rates is about
$16 a year, against $6,400 on metered cloud egress. That 390-fold ratio is real but it
compares a delivery service against a bare port, and quoting it unqualified would be the
most misleading number in this paper.

Loaded properly — ports, cross-connects, facilities, hardware and transit diversity, at
the illustrative rates in [lab: cost model](../lab/cost-model.md) §10.1 — the same
channel costs **$70 to $180 a year depending on port utilisation, so 35 to 90 times less
than cloud egress rather than 390.** Still the largest single saving available anywhere
in this document, and still an order of magnitude better than any rate that can be
bought; just not the two or three orders the marginal row suggests. At one channel the
fixed base *is* the entire cost and the $16 is meaningless: the row describes a slope,
and becomes a level only above the utilisation threshold in §4.4.

**They also exclude a control plane, which none of the managed rows do.** Provisioning,
entitlement, orchestration and monitoring arrive inside a managed service's price and
must be built or licensed for a self-hosted deployment (§3). **No figure is offered
because none can be responsibly assumed** — it turns on build-versus-buy and on terms
nobody publishes — but at low channel counts it is plausibly the largest single line in a
self-hosted build, and it is why these rows are not a 390-fold saving on the total.

**Egress is 86 % of the self-built bill at 10 Mbps and 94 % at 25 Mbps**, against
about a thousand dollars a year of compute. §3.1's "compute is not the constraint" now
has a price attached, and both transports land within a few hundred dollars of each other
on the line that decides the outcome — MoQ marginally the cheaper, for declining to carry
stuffing. Compute is a floor rather than a slope here — two instances run two legs
regardless of load — which is why the 10 and 25 Mbps compute figures are identical.

### 4.6 Fan-out: one channel to N destinations

The same redundant 10 Mbps channel delivered to N independent receiving sites, at AWS
list egress plus the fixed instance pair:


| Destinations | Aggregate wire | Annual total | Per destination |
| -----------: | -------------- | -----------: | --------------: |
| 1            | 20 Mbps        | 7,400        | 7,400           |
| 2            | 39 Mbps        | 13,800       | 6,900           |
| 4            | 79 Mbps        | 26,000       | 6,500           |
| 8            | 157 Mbps       | 50,500       | 6,300           |
| 16           | 314 Mbps       | 91,500       | 5,700           |
| 32           | 628 Mbps       | 163,000      | 5,100           |
| 64           | 1.3 Gbps       | 278,300      | 4,300           |
| 128          | 2.5 Gbps       | 509,100      | 4,000           |
| 256          | 5.0 Gbps       | 970,500      | 3,800           |
| 512          | 10.1 Gbps      | 1,893,400    | 3,700           |
| 1024         | 20.1 Gbps      | 3,739,300    | 3,700           |


**Unicast has no fan-out economy at the last hop, so one-to-many is one-to-one
repeated.** Per-destination cost falls by half across a thousandfold scale-up and then
stops, asymptoting at the deepest volume tier — and all of that improvement comes from
volume bands and from amortising the fixed instance pair, none of it from the transport.
A single channel to a thousand sites is $3.7M a year at cloud list.

The linearity is structural and survives every price regime; the *level* does not. The
same thousand destinations cost roughly $400,000 on commodity CDN delivery at $0.005/GB
and are a transit and port bill self-hosted (§4.4). Read this table for the shape, and
§4.7 for what the shape costs once bought in the right market.

### 4.7 A transponder's worth of channels — the reclamation comparison

This is the table a broadcaster or vendor facing C-band reclamation will look at: what
it costs to replace a transponder's payload with an IP path, at the destination counts
satellite actually serves.

Channel count is taken from the incumbent so the comparison is like-for-like. A
36 MHz-class transponder at DVB-S2 8PSK 2/3 carries about 58.8 Mbps of useful payload
(EBU Technical Review 300), which under statistical multiplexing is **6 to 10 HD
services; the model uses 8**. The transponder sets the channel *count* only — DTH
emission rates are well below the 10/25 Mbps primary-distribution profiles used here,
and the two should not be conflated.

**On-demand list pricing is deliberately excluded from this table.** A transponder is
leased for years, so the honest counterpart is committed capacity, not a rate that
assumes the traffic could stop tomorrow. The columns are therefore the deepest
published *committed* rate and a ladder of hypothetical negotiated rates. Eight
services, 1+1, at 10 Mbps, annual USD:


| Destinations | Aggregate wire | Cloud, MediaConnect reserved *(published)* | Cloud, tiered list less 70 % *(hypothetical)* | CDN relay @ $0.010/GB *(assumed)* | CDN relay @ $0.005/GB *(assumed)* |
| -----------: | -------------- | ---------------------------: | ------------------: | --------------------: | --------------------: |
| 1            | 157 Mbps       | 52,400                       | 14,900              | 6,200                 | 3,100                 |
| 2            | 314 Mbps       | 79,100                       | 27,100              | 12,400                | 6,200                 |
| 4            | 628 Mbps       | 108,400                      | 48,600              | 24,800                | 12,400                |
| 8            | 1.3 Gbps       | 122,700                      | 83,200              | 49,500                | 24,800                |
| 16           | 2.5 Gbps       | 222,900                      | 152,400             | 99,100                | 49,500                |
| 32           | 5.0 Gbps       | 445,800                      | 290,900             | 198,200               | 99,100                |
| 64           | 10.1 Gbps      | 816,300                      | 567,700             | 396,400               | 198,200               |
| 128          | 20.1 Gbps      | 1,610,100                    | 1,121,500           | 792,800               | 396,400               |
| 256          | 40.2 Gbps      | 3,155,200                    | 2,229,000           | 1,585,600             | 792,800               |
| 512          | 80.4 Gbps      | 6,297,300                    | 4,444,000           | 3,171,200             | 1,585,600             |
| 1024         | 160.9 Gbps     | 12,551,000                   | 8,874,100           | 6,342,300             | 3,171,200             |
| *per destination, at scale* | | *10,500*                     | *8,700*             | *6,200*               | *3,100*               |


All columns are **delivery cost only** — no relay compute, which §4.5 puts in the low
single-digit percentages at this scale and §3.1 covers directly. The MediaConnect column
is the published reserved-block optimum on the SRT wire rate plus its per-flow fee — the
only column here that anyone can actually buy today at the price shown. The 70 % column
applies a **hypothetical** discount to the tiered list bill on the MoQ wire rate, chosen
as an illustrative large-enterprise agreement; it is *not* a rate anyone is known to have
been offered or to have achieved, and §4.3 gives the full ladder and explains why a
percentage means little without its starting point. **The two CDN columns are assumptions,
not quotes**: no CDN has published a MoQ relay tariff except Cloudflare, at $0.050/GB, so
these model a CDN-operated relay at a modest premium over the *published* commodity CDN
delivery rates in §4.2 under committed volume — the rate an established delivery market
would be expected to reach, not one anyone currently offers. All columns assume capacity
can be bought at proportional rates at all, which at 161 Gbps is itself a question.

**Parity is the incumbent's annual space-segment cost divided by the per-destination
figure.** Per $1M a year of incumbent cost that is about **95 destinations** at the
published committed cloud rate, **115** at a hypothetical 70 % private cloud rate,
**162** at an assumed $0.010/GB CDN relay and **323** at $0.005/GB. That $1M is a **normaliser, not
an estimate** — no transponder rate is asserted anywhere here, and real space-segment
cost varies widely with orbital slot, capacity, term and how far the lease is already
depreciated. Substitute a real figure; the arithmetic is linear.

**Self-hosting is not a column here, though §4.4 argues it is the largest lever.** At the
illustrative all-in rates in [lab: cost model](../lab/cost-model.md) §10.1 the multiplex
costs around $970 per destination-year, which would put parity near 1,000 destinations —
the only option on the ladder that approaches the top of the range. It is left out of the
table because that figure would not survive the reach problem: serving several hundred
sites from owned infrastructure means points of presence near all of them, and the
build-up prices one. The number belongs in the text as an indication of where the
structural ceiling sits, not in a column implying it can be bought.

So the reclamation conclusion is bounded, and the bound is wider than a cloud-only model
suggests. **Up to roughly 95 destinations the IP path is arguable on published cloud
rates alone; commodity CDN economics move that into the high hundreds; a thousand
destinations is out of reach of everything here that can actually be purchased today.**
The ceiling moves a long way with procurement and with buying delivery from the market
that has already commoditised it — but because the incumbent's fan-out inside a footprint
is free while every column here is linear in destinations, it moves rather than
disappears.

**The transport choice barely registers.** Every option lands within a few percent of
the same wire volume, so the choice among them moves this table by single digits while
destination count moves it by three orders of magnitude. MoQ is the cheapest row on this
column, because it is the only one that can decline to carry null stuffing — but the
margin is a few percent and it travels with the source's stuffing ratio, which is why
this is a footnote to the destination-count result rather than a reason to choose a
transport:


| Transport             | Wire multiplier    | Latency        | Fan-out topology                                     | Standardisation |
| --------------------- | ------------------ | -------------- | ---------------------------------------------------- | --------------- |
| MoQ                   | 0.982 *(measured; 0.973 with MTU discovery on, §3.1)* | sub-second     | relay fans out; last mile is N unicast copies        | IETF draft, open implementations |
| SRT                   | 1.037 *(measured, same path)* | sub-second     | no native fan-out; N origin sessions or a re-origination tier | published spec, open source |
| Zixi                  | ~1.03 *(estimated)*| sub-second     | broadcaster fans out; last mile is N unicast copies  | proprietary, per-GB licence |
| TS over HTTP/1.1      | ~1.05 *(estimated)*| seconds        | cache fans out; last mile is N unicast copies        | **no agreed standard — vendor-specific in practice** |
| HLS / DVB-DASH        | ~1.05 *(estimated)*| seconds–tens   | cache fans out; last mile is N unicast copies        | RFC 8216 / ETSI TS 103 285 |


**No option on that list breaks the linearity, and the common intuition that HTTP
caching does is wrong.** A CDN edge cache fetches a segment once and serves it to N
receivers over N unicast connections; a MoQ relay receives an object once and serves it
to N subscribers over N unicast connections. These are the same topology under different
names — **a MoQ relay is a cache** — so both collapse *upstream* carriage to one copy
and both leave the last mile as N copies, exactly as §4.8 describes. The
per-destination figures above therefore apply to every row.

What a CDN brings is **a price, not a topology**, and §4.2 shows the price is large:
commodity CDN list is $0.005–0.010/GB against $0.09 of cloud egress. That is not
intrinsic to HTTP — it is what a competitive delivery market charges, and it reaches MoQ
as CDNs operate MoQ relays. The real asymmetry is maturity: HTTP delivery can be bought
from a dozen CDNs at commodity rates today, MoQ relay from one, at five to ten times
commodity. That is what an uncontested early market looks like rather than what the
topology costs, which is why the CDN columns are modelled as an assumption about where a
competitive MoQ relay market lands.

The standardisation column carries the other correction. **TS over HTTP/1.1 has no
agreed standard** — continuous MPEG-TS over chunked HTTP is an arrangement of standard
parts, implemented incompatibly by several vendors ([transport](transport.md) §3.3), so
choosing it buys a vendor rather than a protocol. That is a lock-in risk of the same kind
as the receive estate in §2, and it disqualifies the row as a neutral baseline even
though it looks among the cheapest to build.

### 4.8 Where relay fan-out changes the bill, and what carriage costs

MoQ's 1:N amplification is the paper's first-stated advantage
([README](../README.md)), so it deserves an honest accounting: **it does not reduce
last-mile egress.** Delivering to N receivers outside the cloud costs N copies of
internet egress whether or not the protocol has a native relay, because the expensive
hop is the one leaving the cloud.

What a relay removes is duplicated *upstream* carriage. For the eight-service
redundant multiplex backhauled between continents, a regional relay collapses N copies
of backhaul into one, holding it flat at about $11,500 a year however many receivers
share the region — against $23,000 for two and $185,000 for sixteen without it. So the
advantage is real, bounded and specific: **it economises backhaul and uplink, not
delivery**, and it only pays where receivers cluster — the same clustering that favours
satellite's free fan-out, so the two advantages compete for the same topologies.

This is also exactly what an HTTP cache does, and neither more nor less (§4.7). The
relay is not a differentiator against CDN-based delivery on cost grounds; it is the
same economics reached natively rather than through segment polling and cache
hierarchies, which is an architectural argument ([transport](transport.md) §3.3) and
not an economic one.

In that context carriage overhead is not where the money is, in either direction. MoQ's
5.3 % *lower* wire rate against SRT saves on the order of $360 a year for one redundant
10 Mbps channel to one destination and $26,000 for eight channels to sixteen — real, but
smaller than the gap between two providers' list prices and a fraction of what committed
pricing saves, and it would shrink towards nothing on a tightly packed source.
**Carriage efficiency is the wrong basis for choosing a transport either way**, which is
the same conclusion this section reached when the measurement pointed the other way.

### 4.9 The market-structure argument: why MoQ can reach commodity pricing and SRT cannot

The preceding sections price today's options. This one states the argument for why the
prices should be expected to move, because it is the strongest economic case for MoQ in
this document and it rests on none of the measurements above. **It is a hypothesis about
market structure, not a result.**

Start with what the pricing ladder actually shows. **Hyperscalers are not expensive by
accident; they sell elasticity, and elasticity is the wrong product for this workload.**
The premium in metered egress buys the right to stop tomorrow — worth a great deal to a
bursty consumer service and worth nothing to a broadcaster running the same feed at the
same rate for a decade. Primary distribution is the most predictable traffic in the
industry, which is precisely the profile that should command the deepest discount, and
§4.3 shows the discount ladder reaching the same floor that MediaConnect's largest
reserved tier already publishes. The commodity CDNs price nearer that floor to begin
with because delivery, unlike elasticity, is a contested market.

Now the part that is specific to MoQ. **A CDN can operate a MoQ relay as an extension of
what it already does, and cannot do the same for SRT.** §4.7 established that a relay is
a cache: MoQ has a native object model, publish/subscribe and relays as first-class
protocol elements, so relaying maps onto the fan-out machinery a CDN already runs at
scale. SRT has no object model and no native relay primitive — fanning it out means
running a stateful media gateway per stream per destination, which is a media-server
business rather than a delivery business. **That is why no CDN sells SRT relay as a
commodity product, and why one already sells MoQ relay.** The absence is structural, not
historical.

Openness is a necessary condition rather than the distinguishing one, and it is worth
separating the two because they are easily conflated. An open, royalty-free
specification is what allows *many* suppliers to implement the same relay and compete on
price — a proprietary protocol commoditises only as far as its licensor permits, which
is why Zixi's per-GB licence sits on top of every rate in §4.2 rather than falling with
them. But SRT is open too and produced no commodity relay market, because openness
without a cache-shaped relay primitive gives a delivery business nothing it can sell.
**It is the combination — an open specification and an architecture a CDN can already
operate — that makes multi-vendor competition possible, and MoQ is the first
broadcast-grade low-latency transport to have both.**

The consequence is the argument: MoQ is the first sub-second, broadcast-grade transport
whose architecture lets the *commoditised* delivery market sell it. HTTP-based formats
already have commodity economics but not the latency; SRT and Zixi have the latency but
are structurally confined to premium, per-stream pricing. If CDNs deploy MoQ relays and
compete, relay capacity follows CDN delivery down the ladder rather than sitting at
hyperscaler primary-distribution rates — and that competitive pressure reaches a segment
that has never felt it, because SRT never gave the commodity market a product to sell.
On the model in §4.7, that is the difference between parity at 95 destinations and 323,
which is what makes a transponder's worth of channels to several hundred destinations an
arguable proposition rather than an obviously losing one.

Three things would falsify it, and none is settled. Only one CDN has announced a MoQ
relay, and at five to ten times commodity delivery. Professional contribution carries
SLA, monitoring and support obligations that consumer CDN pricing does not, so some of
the gap is real cost rather than margin. And relay portability between implementations
is currently absent in practice ([evidence](evidence.md) §9), which is a precondition
for the competition this argument depends on — a market cannot commoditise a product
buyers cannot switch between. **The strongest economic case for MoQ therefore rests on an
interoperability problem being solved, which is the connection between this document and
the rest of the paper.**

## 5. Value drivers (beyond unit cost)

A per-route cost comparison understates the challenger, because several advantages are
economic but not captured in a transport line item:

- **Per-destination customisation.** Each destination is an independent session rather
than a shared carrier, so an IP path can deliver a *different* feed to each — regional
ad insertion, alternate audio or subtitle sets, localised branding, blackout handling,
per-affiliate bitrate. Satellite broadcasts one multiplex to the whole footprint, so
the same thing means another carrier or equipment at every site. This is the clearest
case where unicast's cost structure buys something satellite cannot sell at any price,
and it partly offsets the fan-out disadvantage: some of those N copies are not
duplicates.
- **A bridge, not only a destination.** MoQ, SRT and Zixi can feed existing head-ends
today through an IRD-facing gateway, so the transport can be modernised before
receive-side equipment supports streaming formats natively — decoupling the two
migrations and letting the expensive one (§2's receive estate) run on its own schedule.
- **Provisioning speed.** "Channel in minutes, not months" converts lost revenue into
recoverable value, and avoids the meet-me-point lead time in §2.
- **Incident and operational reduction.** API-driven, observable operation *may* reduce
toil, but this is unproven and could be offset by a new platform's immaturity. A
hypothesis, not a saving.
- **Utilisation and elasticity.** Paying only for capacity in use is a genuine advantage
for variable demand and a penalty for steady demand, so for always-on trunk it is not a
value driver at all — the reason is in §4.9, and the response is committed, commodity or
owned capacity. Elasticity earns its premium only on the event and short-window cases
in §6.
- **Multi-tenant leverage.** Shared fabric amortises fixed cost across tenants
([architecture](architecture.md) §13). §4.2 supplies the mechanism: committed-bandwidth
discounts sell in coarse blocks, and an aggregator can fill a block no single tenant
can — worth up to a fivefold reduction in the dominant line, larger than any efficiency
in the transport itself.

## 6. Where the comparison inverts

Two variables decide every case, and neither is a transport property: **destination
count** and **the market the delivery is bought in**.


| Scenario                                | Favours     | Why                                                                                  |
| --------------------------------------- | ----------- | ------------------------------------------------------------------------------------ |
| Always-on trunk, few destinations       | challenger  | Comfortable at any rate on the ladder; the constraint is the fixed cost around it (§7), not the transport |
| Always-on trunk, tens of destinations   | arguable    | Turns on procurement inside the cloud (§4.3), comfortable outside it (§4.4, §4.7)     |
| Always-on trunk, hundreds               | **depends entirely on the supplier** | Lost at metered cloud rates, arguable at committed ones, competitive on commodity delivery or owned infrastructure (§4.7) |
| Always-on trunk, a thousand or more     | **incumbent** | Structural: every option is unicast at the last mile, and nothing purchasable today reaches parity. Only owned infrastructure comes close, and not at the reach this implies (§4.7) |
| Event, occasional, short-window         | challenger  | Fast provisioning and pay-for-use match the demand shape, though no commitment means no committed discount |
| Global or dynamic reach                 | challenger  | Reach without global procurement or a meet-me point (§2)                              |
| Feeds that differ per destination       | challenger  | Satellite cannot sell it at any price (§5)                                            |


The last of the trunk rows is the clearest limit on the thesis in this document, and the
one above it is where the argument is actually contested — a range that a cloud-only
model would have written off entirely.

## 7. Remaining sensitivities

- **Redundancy level.** 1+1 doubles the dominant line exactly
([architecture](architecture.md) §14), and must be held equivalent on both sides or
the comparison is meaningless.
- **SLA and staffing.** Fixed, and dominant at low route counts: at §4.5's scale one
on-call engineer costs more than the entire modelled transport line, which is the
strongest argument here against reading §4 as a business case.
- **Like-for-like carriage.** Hold each transport to its own measured overhead (§3.1) —
0.982x for MoQ's media-aware lane, 1.037x for SRT — rather than comparing either against
a *nominal* TS rate. The discipline used to be a caution against flattering MoQ; now it
is what establishes MoQ's advantage, and the sensitivity has moved to **the source**.
MoQ's 5.3 % is the stuffing ratio of the clip measured: a tightly packed carrier
converges the two multipliers to the ~1.2-point AEAD floor, a loosely filled one widens
the gap well past 5 %. Model it as a wash and treat the advantage as upside, and note
that a deployment requiring byte-verbatim carriage forgoes it entirely.

## 8. Commercial packaging options

Stated generically, without terms or pricing:

- **Managed service** — the platform operates the distribution; the customer buys an
outcome. Highest operational cost to the provider, highest trust bar.
- **Software / OEM** — the capability is licensed to an operator or vendor who runs it.
Lower operational burden, different margin structure.
- **Hybrid** — control plane as a service over customer- or partner-operated data
plane; matches the transport-swappable hedge ([transport](transport.md) §5.2).

§4.2 constrains all three, and the constraint is that **the cheapest published delivery
is not on raw cloud at all** — it is on commodity CDN, an order of magnitude below cloud
egress, with an incumbent managed service in between. A challenger's viable positions
are therefore to operate relays on commodity delivery or owned infrastructure and sell
an outcome (§4.4, §4.9), to buy wholesale cloud capacity at committed rates and resell
it, or to compete on something other than transport unit cost. Reselling list-priced
hyperscaler egress is not viable at any packaging, and a margin built on the spread
between cloud list and commodity delivery is not durable — that spread is the thing
§4.9 expects competition to compress.

## 9. Open questions

**Commercial, and decisive.**

- What is the real TCO delta against one broadcaster's *actual, depreciated* route
cost — the single most important unanswered question here, shared with the
[README](../README.md). §4.7 supplies the challenger's half of the arithmetic; the
incumbent's half is the only thing missing.
- **Why does published cloud egress sit an order of magnitude above commodity CDN
delivery, and does anything force that gap to close?** The trunk question lives inside
that spread. Two independent estimates of what delivery actually costs — the published
commodity CDN rate and the all-in self-hosted build-up behind §4.4 — agree at
$0.001–0.005/GB, which says most of the spread above them is positioning rather than
cost. What remains open is whether competition compresses it, and whether a *new
entrant* without hyperscaler-scale volume can buy transit, ports and facilities near the
rates that make §4.4 work — the difference between a route open to incumbents with
buying power and one open to challengers.
- **What will a CDN actually charge to operate a MoQ relay at committed volume?** §4.7
models it at a modest premium over commodity CDN delivery, and that assumption carries
more of the reclamation case than any measurement in this paper: it is the difference
between parity at 95 destinations and at 323. The one announced rate is five to ten
times higher. Until a second provider quotes, this is the largest unvalidated input in
the model.
- Can committed-egress terms be bought for general compute, or only inside a managed
product? §4.2's finding that the service undercuts the platform fivefold holds only
because reserved bandwidth is product-specific.

**Engineering, with a direct economic payoff.**

- **How much of MoQ's carriage advantage survives a different source?** This replaces the
older "why is MoQ's overhead ~12 % where SRT's is ~3 %", which was answered by finding the
measurement wrong (§3.1). The advantage is now measured at 5.3 %, but it *is* the 4.57 % of
null stuffing the reference clip carries, so a tightly packed source should shrink it to the
~1.2-point AEAD floor and a loosely filled one should roughly double it. Two more source
profiles turn the model's largest carriage caveat into a range, and it is the cheapest
outstanding measurement on the deciding line.
- **What does the opaque lane cost to carry?** The measured figure is the media-aware lane;
the lane this paper prefers for hardware IRDs has never been measured, and it is the lane
whose whole promise — byte-verbatim carriage — is what forgoes the null-stripping saving.
Derivation puts verbatim carriage near SRT and null-stripped carriage near the media-aware
lane, which makes this the difference between carriage being a wash and being an advantage
for the receiver population that most needs the lane.
- **What is the overhead under loss beyond 1 %?** Both protocols are now measured
back-to-back at 1 % and neither moved by more than a point, but retransmission is charged
differently by the two, and the sender-side cost above 1 % is inferred rather than captured.
- **What does SRT actually cost to fan out?** Serving many destinations over a
point-to-point protocol needs either N origin sessions or a re-origination tier, and
neither is free, so a per-datagram framing comparison flatters SRT at exactly the
topology broadcast uses.
- Does the measured compute profile survive a real path? Loopback removes NIC, WAN
packet handling and congestion-control work.

**Platform maturity, which the model assumes away.**

- Is relay capacity a market the buyer can shop? The cost case treats it as a commodity
procurable from more than one supplier, but a feed currently traverses only relays from
the same implementation as the publisher ([evidence](evidence.md) §9).
- What does relay memory growth cost to operate around? The reference relay accumulates
per-connection QUIC stream state that cache tuning does not bound (§3.1). Now that this
is understood to plateau at roughly 100 MB per publisher connection rather than climb
indefinitely, it is a sizing line rather than a restart cycle — but one that scales with
channels carried, not audience, so it lands on multi-channel relay density.
- How much of the operational-saving hypothesis (§5) survives running an immature
platform to a broadcast SLA? §7 notes one on-call engineer outweighs the entire
modelled transport line at single-route scale.

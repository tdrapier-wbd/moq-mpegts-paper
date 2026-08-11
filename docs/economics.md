# Economics

Status: working draft
Scope: a cost framework for comparing an Internet-native MoQ distribution path
against incumbent primary-distribution methods, **and a first numeric model of the
always-on case built entirely from public list prices** (§4). This is the companion
to the economic risk raised in the [README](../README.md).

> **Confidentiality note.** Two kinds of number are treated differently here.
> *Published* rates — hyperscaler egress tariffs, AWS Elemental MediaConnect and its
> reserved-bandwidth tiers, marketplace software rates, EC2 reserved-instance prices,
> surveyed IP transit prices — are public, verifiable, and modelled openly in §4,
> alongside our own lab capacity measurements (§3.1). *Commercially sensitive* inputs
> remain excluded: no customer pricing, no vendor contract or discount terms, no
> transponder or fibre lease rates, and no incumbent's actual or depreciated route
> cost. Where the comparison needs the incumbent's side, §4.4 states a **parity
> threshold** derived from our own modelled figures instead of the incumbent's price,
> which answers the question without disclosing anything. The consequence is worth
> stating plainly: because real deployments buy at negotiated rates well below list,
> every absolute figure in §4 is an **upper bound**, and the ranking between options
> can invert under contract.

---

## 1. Purpose

The economic question is narrower than "is cloud cheaper than satellite." It is:
*for a specific class of routes, does an Internet-native MoQ path deliver
equivalent broadcast-grade service at a total cost of ownership (TCO) low enough,
and with enough operational upside, to justify displacing the incumbent — given
the incumbent's trust advantage and the challenger's unproven status?*

The buyer's decision criteria, in the order they actually weigh them:

1. **Reliability/trust first.** No cost saving justifies a visible failure on
   contracted content. Economics only enters *after* the reliability bar is
   cleared ([vision](vision.md) §3.3).
2. **Total cost of ownership, not sticker price.** Transport cost is only one line;
   redundancy, operations, and integration dominate over a contract lifetime.
3. **Operational optionality.** Speed of provisioning, elasticity, and the ability
   to serve dynamic topologies have real economic value that a per-route cost
   comparison misses (§5).

The position this document argues toward, stated as a hypothesis rather than a
result: always-on trunk is the *hardest* case, but **achievable rather than
permanently lost** — *if* incumbent capacity retires and egress pricing falls on
the horizon assumed here. That "if" is doing real work: both premises are
forecasts, and a depreciated transponder or committed fibre route can stay
cheapest for years. The case is **clearer for dynamic, short-lived, long-tail, or
global-reach-on-demand routes**, where the incumbent's fixed-cost model fits
worst.

The first numeric model (§4) sharpens this rather than settling it, and it moves
the argument in a direction worth stating up front: **the cost of an always-on
Internet-native path is set almost entirely by commercial egress terms, not by
engineering.** Published egress sits two to three orders of magnitude above the
surveyed price of IP transit, the protocol choice moves the total by single-digit
percentages, and the cheapest published rate for always-on video on AWS turns out
to be *inside* the managed video service rather than on the raw platform. A
technology comparison is therefore not where this is won or lost.

## 2. Baseline cost models (the incumbents)

Each incumbent has a characteristic *cost structure* that a comparison must
model, independent of the actual rates:

- **Satellite.** Large up-front and long-term commitments (transponder/segment
  leases), with a cost base that is *largely fixed and often already depreciated*
  on existing capacity. The economic trap for a challenger: the marginal cost of
  an *already-leased* transponder carrying an *already-running* feed is very low,
  so the comparison is not "cloud vs satellite list price" but "cloud vs the
  *depreciated marginal* cost of incumbent capacity." Fan-out to many receivers is
  near-free (broadcast medium).
- **Leased fibre / MPLS.** Priced for dedicated or managed capacity with
  contractual QoS; cost scales with committed bandwidth and route count, and
  reach is bounded by carrier footprint. Provisioning is a procurement exercise
  (weeks/months), which is a hidden cost the sticker price omits.
- **Existing IP transport (SRT / Zixi / RIST / AWS MediaConnect).** A mix of
  licence/service fees plus underlying network/cloud cost. This is the *most
  directly comparable* baseline, because it is already Internet/cloud-based; the
  MoQ question against this baseline is largely "does MoQ change the cost structure
  at all, or only the technology?"

## 3. Proposed model components (the MoQ path)

The challenger's TCO must sum at least the following, per route and in aggregate:

- **Compute / relay cost.** Relay fabric compute, scaling primarily with
  *connection count* and only weakly with forwarded bandwidth
  ([relay](relay.md) §6; measured in §3.1). Shared across tenants, which is where
  multi-tenant leverage helps (§5).
- **Egress / network cost.** Data transfer out of cloud/CDN networks. **This is the
  line that dominates and swings the entire comparison** — no longer a prediction:
  §4 puts it at roughly 90 % of a self-built transport bill, spanning an eightfold
  range across published options alone. Because primary distribution is always-on and
  high-bitrate, an egress-metered network is the worst-matched pricing model
  available for it, so the terms obtained on this one line deserve more scrutiny
  than every other component combined.
- **Operations and support.** 24/7 NOC, on-call, and incident response to the
  broadcast standard ([operations](operations.md) §8). This is a real,
  substantial, and often underestimated cost, and it does not shrink just because
  the transport is cheaper.
- **Tooling and monitoring.** Observability, TR 101 290 probing, audit — build or
  buy ([operations](operations.md) §3).
- **Integration and grooming.** The edge/interop work that makes output
  IRD-acceptable ([interoperability](interoperability.md), [architecture](architecture.md)
  §7). One-time and ongoing.

### 3.1 Measured relay compute and carriage overhead

Two of the inputs above no longer need to be assumed. Test 9
([test-9-performance](../lab/test-9-performance.md)) measures them directly, on Linux
(2 vCPU) with the current relay release, MPEG-TS at 2 / 10 / 27 Mbps and fan-out to 85
concurrent subscribers.

**Relay CPU scales with session count, not with bitrate.** Cost per subscriber session
rises far more slowly than the bitrate it carries:

| Per-stream bitrate | CPU per subscriber session | Sessions per core | Egress per core |
|---|---:|---:|---:|
| 2 Mbps | 0.34 % | ~300 | ~0.6 Gbps |
| 10 Mbps | 0.85 % | ~120 | ~1.2 Gbps |
| 27 Mbps | 1.18 % | ~85 | ~2.1 Gbps |

Nearly fourteen times the bitrate costs about three and a half times the CPU, so cost per
delivered Mbps *falls* as bitrate rises. Three consequences for the model:

- **Compute is not the constraint, and egress dominance is now a measured conclusion
  rather than an assumption.** One core forwards on the order of a gigabit; the compute
  line is small beside the egress line it accompanies.
- **Primary distribution is the favourable regime for relay compute.** Contribution-grade
  high-bitrate feeds are the *cheapest per Mbps* to relay, so moving up-market in bitrate
  improves the compute economics instead of degrading them. This cuts against the
  intuition that high-bitrate always-on feeds are the expensive case — they are, but on
  the egress line, not the compute line.
- **Capacity planning is linear and predictable.** CPU rose linearly with session count
  with no knee until the host itself saturated, and memory is not a sizing constraint
  (roughly a fixed tens-of-MB working set plus ~2 MB per session; bounding the cache
  explicitly cost nothing measurable, so it is free insurance rather than a cost trade).

The "sessions per core" column extrapolates to full core occupancy and is a ceiling, not a
sizing target; practical sizing needs headroom for churn, retransmission, and the failover
transients in [architecture](architecture.md) §14.

**Carriage overhead is a multiplier of roughly 1.12 on the dominant line.** Measured IP
wire bytes against the source TS rate came to ~12 % at both 10 and 27 Mbps, plus well
under 1 % on the return path for acknowledgements. Because egress is the line most likely
to dominate (§3, §7), this multiplier applies directly to it — and a 1+1 redundant path
carries it twice.

This is also the clearest place where MoQ is structurally *worse* than the most directly
comparable baseline. SRT's framing over a datagram of seven TS packets costs a few
percent, so MoQ consumes materially more bandwidth for the same service, on exactly the
line that dominates the comparison. That belongs in the model explicitly rather than being
netted off against MoQ's compute efficiency, which sits on the line that does not dominate.

**Host configuration is a first-order cost lever.** The same relay version measured around
six times more CPU per Mbps on macOS loopback with UDP GSO disabled than on Linux with GSO
enabled. Whatever the split between operating system and offload, relay compute is
sensitive to kernel and offload configuration by a larger factor than any plausible code
optimisation, so host tuning is a model input, not an implementation detail.

**Not all of that measured compute headroom is purchasable.** Cloud instances of this size
are sold with a *sustained* network allowance well below their headline "up to" figure,
which is burst credit and irrelevant to a 24/7 feed. At published baselines, a
general-purpose 2-vCPU instance sustains under 1 Gbps against the ~2.2 Gbps its cores could
forward, so **the network allowance discards more than half the relay's measured capacity**;
a network-optimised instance of the same size sustains 3 Gbps and restores it, for roughly
20 % more per instance. Relay sizing is therefore an instance-family decision before it is a
core-count decision, and "sessions per core" must be read against the interface the sessions
have to leave through.

**Caveats.** These are loopback measurements with subscriber processes co-resident with the
relay: no WAN packet handling, no NIC or cross-machine cost, and no congestion control
working against real loss. Treat the *shapes* — linear in sessions, sublinear in memory,
falling cost per Mbps as bitrate rises, ~1.12x carriage — as the result and the absolute
constants as indicative. A real path with loss and retransmission costs more on both lines.

## 4. A first cost model, at published rates

The framework above is populated here for the hardest case: always-on 24/7/365
linear distribution, fully redundant. Rates were retrieved on 2026-08-10 from
providers' machine-readable price lists where available; the model, its inputs and
its limitations are in [lab: cost model](../lab/cost-model.md), and
[`lab/cost-model.py`](../lab/cost-model.py) regenerates every figure below.

### 4.1 Assumptions

- **Always-on**: 8,760 hours a year. No diurnal or seasonal relief, which is what
  makes this the pessimistic case for a usage-priced substrate.
- **Two bitrate profiles**: 10 Mbps today, 25 Mbps as the ambition. Both are
  arbitrary round numbers chosen to bracket plausible primary-distribution rates.
- **Active/active 1+1 throughout**: two live full-rate copies at all times
  ([architecture](architecture.md) §14), so every transport figure is doubled. This
  is held identical on both sides of every comparison.
- **Carriage multipliers**: MoQ 1.12x measured (§3.1); SRT 1.033x derived from its
  framing of seven TS packets per datagram. Both are clean-path figures.
- **Regions**: Ireland, N. Virginia or Oregon — which carry identical egress rates.
- **Excluded**: staffing, tooling, integration, receive-side equipment, and
  satellite uplink/teleport. This is a transport-line comparison only, and §3 is
  explicit that the excluded lines can dominate at low route counts.

One constant does most of the work: **one always-on Mbps moves 3,942 GB a year**.
Because bitrate and volume are interchangeable under a 24/7 assumption, every rate
in this section can be quoted as a cost per Mbps-year, which makes otherwise
incomparable pricing models — per GB, per hour, per committed Mbps, per port —
directly comparable.

### 4.2 The price of a Mbps-year

| Option | $/GB-equivalent | $/Mbps-year |
|---|---:|---:|
| Commercial transport software licence + list cloud egress | 0.140 | 528 |
| Hyperscaler list egress, first tier | 0.087–0.090 | 330–343 |
| Managed video service, reserved outbound bandwidth, smallest tier | 0.052 | 203 |
| MoQ-native relay service, announced general-availability rate | 0.050 | 197 |
| Hyperscaler list egress, deepest published volume tier | 0.040–0.050 | 158–184 |
| **Managed video service, reserved outbound bandwidth, largest tier** | **0.017** | **67** |
| Surveyed IP transit, competitive hub, 10–100 GigE port | 0.0002 | 0.60–0.84 |

Three conclusions:

**Egress pricing, not carriage, is the whole cost.** A Mbps-year of surveyed IP
transit costs under a dollar; the same Mbps-year of list cloud egress costs several
hundred. Nothing about moving an always-on 10 Mbps feed is intrinsically expensive
— usage-metered egress is. This is why §7's sensitivity has one input that matters
and why the trunk case turns on commercial terms rather than on engineering.

**The managed service is cheaper than the platform it runs on.** Reserved outbound
bandwidth on a managed video service reaches $0.017/GB at its largest committed
tier — roughly five times cheaper than raw first-tier data transfer out on the same
cloud, and three times cheaper than the announced MoQ-native relay rate. That
construct is specific to the managed product; a self-built relay fleet on general
compute cannot buy it. The "build it and keep the service margin" instinct is
therefore **inverted at list prices** for always-on traffic, and any DIY case has
to be argued against the managed price, not against list egress.

**Committed pricing is granular, and the grain is coarse.** Reserved bandwidth is
sold in fixed blocks with a twelve-month commitment. One redundant 10 Mbps channel
(≈21 Mbps of wire) cannot fill the smallest block, so on-demand per-GB wins; a
redundant 25 Mbps channel can, and saves about a third. The discount is a reward for
predictable scale, which an always-on trunk portfolio has and a single route does not.

### 4.3 One channel, one destination, fully redundant

Annual transport cost, egress plus compute, for a single channel delivered 1+1 to
one off-cloud destination:

| | 10 Mbps | 25 Mbps |
|---|---:|---:|
| MoQ, self-built on reserved cloud compute | 8,300 | 19,000 |
| — of which egress | 7,300 | 18,000 |
| — of which compute | 1,000 | 1,000 |
| SRT, self-built, same footprint | 7,700 | 17,600 |
| Commercial software licence + self-built | 11,800 | 27,800 |
| Managed video service, on-demand egress | 9,500 | 19,400 |
| Managed video service, cheapest reserved mix | 9,500 | 13,400 |
| MoQ-native relay service, announced rate | 4,400 | 11,000 |
| MoQ, self-built on another hyperscaler's cheapest published option | 6,800–7,000 | 15,600–16,100 |

**Egress is 88 % of the self-built bill at 10 Mbps and 95 % at 25 Mbps.** The
compute line — the one where MoQ's measured efficiency lives — is about a thousand
dollars a year against seven to eighteen thousand of transfer. §3.1's "compute is
not the constraint" now has a price attached, and the corollary is uncomfortable:
*the line MoQ is good at is the line that does not matter, and the line it is 8 %
worse at is the line that decides the outcome.*

Compute is also a floor rather than a slope at this scale. Two instances are needed
to run two legs regardless of load, and one channel occupies a few percent of one,
which is why the 10 and 25 Mbps compute figures are identical. Compute only becomes
proportional — and MoQ's efficiency only becomes worth anything — at fan-out counts
far above a single route.

Fanning that same redundant channel out to more destinations buys almost no relief.
At list rates the cost per destination falls from about $8,300 to $6,400 a year
between one and sixteen destinations — a 23 % improvement across a sixteenfold
scale-up, and all of it from volume bands and from spreading the fixed pair of
instances, none of it from the transport. Unicast has no fan-out economy at the last
hop, so **one-to-many is one-to-one repeated**, and that near-linearity is what §4.4
turns into a threshold against satellite. The one discontinuity worth planning for is
that the managed service overtakes the self-built option at around eight
destinations, where the aggregate finally justifies a reserved block.

### 4.4 A transponder's worth of channels, and the fan-out asymmetry

To keep the comparison like-for-like, channel count is taken from the incumbent. A
36 MHz-class transponder at DVB-S2 8PSK 2/3 carries about 58.8 Mbps of useful
payload (EBU Technical Review 300), which under statistical multiplexing is **6 to
10 HD services; the model uses 8**. The transponder sets the channel *count* only —
DTH emission rates are well below the 10/25 Mbps primary-distribution profiles
modelled here, and the two should not be conflated.

Eight services, 1+1, at 10 Mbps, delivered to N off-cloud destinations:

| Destinations | Aggregate wire | List egress | Deepest volume tier | Reserved managed service | MoQ relay service |
|---:|---:|---:|---:|---:|---:|
| 1 | 179 Mbps | 55,800 | 32,900 | 52,200 | 35,300 |
| 4 | 717 Mbps | 178,200 | 131,600 | 107,600 | 141,300 |
| 16 | 2,867 Mbps | 572,900 | 526,300 | 222,900 | 565,100 |

Two structural points, both more important than the absolute figures.

**Unicast IP is linear in destinations; satellite fan-out inside the footprint is
free.** This is the incumbent's genuine architectural advantage and no pricing
change removes it. Each additional destination for the whole eight-service
redundant multiplex costs roughly $59,000 a year at list, $33,000 at the deepest
volume tier, and $12,000 on reserved managed bandwidth. Expressed without
disclosing anyone's rates: **for each $1M a year of incumbent space-segment cost,
the IP path stops being cheaper somewhere between about 17 and 84 destinations**,
depending entirely on which egress price applies. A broadcaster serving a handful
of affiliates sits comfortably on the IP side of that line; one serving a large
receive population does not, and no amount of transport engineering moves it.

**Flat rates win small and lose large.** A flat $0.05/GB beats tiered list pricing
at low volume, but the crossover arrives at about 20 destinations of this multiplex —
roughly 1,200 TB a month — where the tiered provider's deepest band undercuts the flat
rate. Two consequences: pricing *shape* interacts with deployment scale, so a
provider comparison made at one scale does not transfer to another; and because
volume tiers accumulate across a whole account, the deep-tier rates in these tables
are only available to an operator whose *total* traffic reaches them, which favours
the aggregator over the single broadcaster.

### 4.5 Where relay fan-out actually changes the bill

MoQ's 1:N amplification is the paper's first-stated advantage
([README](../README.md)), so it deserves an honest accounting: **it does not reduce
last-mile egress.** Delivering to N receivers outside the cloud costs N copies of
internet egress whether or not the protocol has a native relay, because the
expensive hop is the one leaving the cloud.

What a relay does remove is duplicated *upstream* carriage. For the eight-service
redundant multiplex above, backhauled between continents at inter-region rates, a
regional relay collapses N copies of backhaul into one, holding it flat at about
$13,000 a year however many receivers share the region — against $26,000 for two
receivers and $211,000 for sixteen without it. The origin's contribution uplink
likewise carries the multiplex once rather than once per receiver, which is a
link-sizing saving rather than a cloud invoice line.

So the fan-out advantage is real, bounded, and specific: **it economises backhaul
and uplink, not delivery.** Any claim that relaying reduces distribution cost has
to name the hop it means. The claim also only pays where receivers cluster —
which is the same clustering that favours satellite's free fan-out, so the two
advantages compete for the same topologies.

### 4.6 What the carriage penalty costs

The 1.12x measured MoQ overhead against SRT's 1.033x is an 8.4 % higher wire rate
for the same service, applied to the dominant line. At list egress that is about
$570 a year for one redundant 10 Mbps channel to one destination, $1,350 at 25 Mbps,
and $41,000 for eight channels to sixteen destinations. It is a permanent tax of
roughly the same magnitude as the gap between two providers' list prices — material,
worth engineering away, and not decisive. Set against the commercial levers it is
small: about a tenth of what moving from on-demand to committed pricing saves, and
under a tenth of the spread between list egress and transit. **A transport chosen
for its cost efficiency on this line would be the wrong basis for choosing MoQ** —
the argument has to rest on architecture, and §5's value drivers, instead.

## 5. Value drivers (beyond unit cost)

A pure per-route cost comparison understates the challenger, because several of
its advantages are economic but not captured in a transport line item:

- **Provisioning speed.** "Channel in minutes, not months" converts lost revenue
  and opportunity cost from slow provisioning into recoverable value — most
  significant for event and short-window content.
- **Incident/operational reduction.** API-driven, observable operation *may*
  reduce incident cost and manual toil, but this is unproven and could equally be
  offset by the immaturity of a new platform. State it as a hypothesis, not a
  saving.
- **Utilisation and elasticity.** Paying for capacity in use rather than
  committed capacity favours variable and bursty demand; it *disfavours*
  steady always-on demand, where committed/depreciated incumbent capacity is
  cheapest.
- **Multi-tenant leverage.** Shared fabric amortises fixed cost across tenants
  ([architecture](architecture.md) §13) — a genuine structural advantage, but only
  realisable at sufficient scale and only for an operator serving multiple tenants.
  §4.2 adds a specific mechanism: committed-bandwidth discounts are sold in coarse
  blocks, and an aggregator can fill a block that no single tenant can. On the
  modelled rates that is worth up to a fivefold reduction in the dominant line —
  larger than any efficiency in the transport itself.

## 6. Scenario analysis

The comparison inverts across scenarios, which is the central insight:

- **Always-on linear trunk feeds.** The hardest case, and the one modelled in §4 —
  but achievable rather than lost. Steady high-bitrate demand is where egress cost
  bites hardest and where depreciated satellite / committed fibre is cheapest
  *today*, so the challenger's case here rests on the horizon over which incumbent
  capacity is retired and egress pricing falls, and on the substrate, operational,
  and reach advantages, more than on day-one sticker price. The elasticity
  advantage is worth little here; the rest of the case carries it. The numbers
  sharpen rather than soften this: high-bitrate always-on feeds are the *cheap* case
  for relay compute and the *expensive* case for egress, and egress is ~90 % of the
  modelled bill, so the trunk scenario is decided almost entirely by the rate
  negotiated on one line item.
- **Event / occasional / short-window feeds.** Challenger-favoured. No committed
  capacity, fast provisioning, and pay-for-use align with the demand shape; the
  incumbent's fixed-cost model is poorly suited. Note the trade §4.2 exposes: the
  same absence of commitment that suits event demand forfeits the committed-bandwidth
  discounts that make the always-on case viable.
- **Single-region vs global distribution.** Global, dynamic reach favours the
  challenger (reach-on-demand without global procurement); dense single-region
  fan-out to many endpoints favours satellite's near-free broadcast fan-out. §4.4
  puts a threshold on it: per $1M/year of incumbent space-segment cost, unicast IP
  stops being cheaper somewhere between roughly 17 and 84 destinations depending on
  the egress rate obtained. **Destination count, not bitrate, is the variable that
  decides this scenario** — and it is one no transport choice can influence.

## 7. Sensitivity analysis

The model's output is dominated by a small number of inputs, and §4 quantifies how
few:

- **Bandwidth / egress cost — the dominant sensitivity, by a wide margin.** Holding
  everything else fixed, the published options alone span roughly eightfold
  ($0.14 to $0.017 per GB), and surveyed transit sits a further 80x below the
  cheapest of them. Every other modelled quantity — compute, instance family,
  region, protocol — moves the total by single-digit percentages. Apply the measured
  ~1.12x carriage multiplier (§3.1) to the MoQ side and hold the baseline to its own
  overhead — comparing MoQ wire bytes against a *nominal* TS rate flatters the
  challenger on precisely the line that decides the outcome.
- **Which price the buyer can actually obtain.** Given that spread, *procurement* is
  a larger lever than any technical decision in this paper. A model built on list
  prices, as §4 is, therefore bounds the answer from above rather than estimating
  it, and the first sensitivity any real model should run is over the rate its owner
  can actually sign.
- **Redundancy level.** Active/active 1+1 doubles the dominant line exactly
  ([architecture](architecture.md) §14). The comparison must hold redundancy
  *equivalent* on both sides, or it is meaningless.
- **Destination count.** Cost is linear in destinations on the challenger's side and
  flat on satellite's (§4.4), so this is the input that flips the conclusion rather
  than scaling it.
- **SLA / staffing.** The 24/7 operational cost is comparatively fixed and can
  dominate at low route counts; it amortises only as the route/tenant count grows.
  At the §4.3 scale — one channel, ~$8,000 a year of transport — a single on-call
  engineer costs more than the entire modelled transport line, which is the strongest
  argument in the document against reading §4 as a business case.

## 8. Commercial packaging options

Stated generically, without terms or pricing:

- **Managed service** — the platform operates the distribution; the customer buys
  an outcome. Highest operational cost to the provider, highest trust bar.
- **Software / OEM** — the capability is licensed to an operator or vendor who
  runs it. Lower operational burden, different margin structure.
- **Hybrid** — control plane as a service over customer- or partner-operated data
  plane; matches the transport-swappable hedge ([transport](transport.md) §5.2).

§4.2 constrains all three. Because the cheapest published egress for always-on
video sits inside an incumbent managed service rather than on raw cloud, a
challenger's viable positions are to buy wholesale capacity at committed rates and
resell an outcome, to run on a substrate that does not meter egress at hyperscaler
rates, or to compete on something other than transport unit cost. Reselling
list-priced hyperscaler egress is not a viable position at any packaging.

## 9. Evidence required

To move any conclusion here from "directional" to "established," the model needs:

- **Real route inputs from a design partner** — actual bitrates, redundancy,
  reach, and the *depreciated marginal* cost of the incumbent path they would
  displace (not list price). This is the missing half of §4.4's parity threshold.
- **One real negotiated egress rate.** §4 is arithmetic on published rates, which
  makes it an upper bound; a single enterprise or committed-spend rate would move it
  from indicative to decision-grade, and is the cheapest of all the items here to
  obtain.
- **Whether committed-egress terms exist for general cloud compute.** §4.2's most
  consequential finding — the managed service undercutting the platform fivefold —
  holds only because reserved outbound bandwidth is product-specific. If an
  equivalent commitment can be bought for a self-built fleet, the DIY case is
  restored; nobody publishes an answer.
- **The carriage comparison measured rather than derived.** MoQ's 1.12x is measured;
  SRT's 1.033x is derived from framing, and neither includes retransmission under
  loss. A back-to-back wire-byte measurement on an impaired path closes the only
  place §4 mixes evidence classes.
- **Capacity measurements over a WAN path** rather than loopback (§3.1 caveats).
- **A fully-loaded operational cost** for both sides to the same SLA
  ([operations](operations.md) §10) — which §7 argues may exceed the entire
  transport line at low route counts.
- **Third-party validation** of the reliability equivalence that the whole
  comparison presupposes ([interoperability](interoperability.md) §10).

## 10. Decision thresholds

Framework only — thresholds are set per deployment and per buyer:

- **Minimum required saving.** A challenger must typically beat the incumbent by a
  meaningful margin, not break even, to overcome switching risk and the trust
  gap. The required margin is a buyer-specific input.
- **Payback period.** Integration and migration cost must pay back within the
  buyer's planning horizon.
- **Risk-adjusted acceptance.** The saving must survive discounting for the
  platform's immaturity and the transport's instability
  ([transport](transport.md) §5). A nominal saving that evaporates under
  risk-adjustment is not a saving.

## 11. Open questions

- What is the real TCO delta versus one broadcaster's *actual, depreciated* route
  costs — the single most important unanswered economic question (shared with the
  [README](../README.md) open questions)? §4.4 now expresses the challenger's half
  of that arithmetic, so the incumbent's half is all that is missing.
- At what egress price and tenant/route scale does the always-on trunk case reach
  parity and then advantage, and how quickly is that point arriving as incumbent
  capacity is retired and egress pricing falls?
- **Why is published egress two to three orders of magnitude above the surveyed
  price of transit, and does anything force that gap to close?** §4.2 shows the
  entire trunk question sitting inside this spread. If it is durable margin rather
  than cost, the challenger's route to viable economics runs through procurement or
  a different substrate, not through protocol engineering — which would reframe much
  of this paper's premise.
- How much of the "operational saving" hypothesis (§5) is real once the cost of
  running an immature platform to a broadcast SLA is included? §7 suggests one
  on-call engineer outweighs the whole modelled transport line at single-route
  scale.
- Does the ~1.12x carriage overhead (§3.1) hold over a real WAN path once retransmission
  under loss is included, and how does it compare against the same measurement taken on
  an SRT path? This is the sharpest quantified disadvantage the model carries, so it is
  worth measuring rather than estimating.
- Does the measured compute profile survive a real path? Loopback removes NIC, WAN packet
  handling, and congestion-control work; if per-session CPU rises materially over a real
  path, the "compute is not the constraint" conclusion needs revisiting.
- Is relay capacity actually a competitive market the buyer can shop? The cost case assumes
  relay capacity is a commodity procurable from more than one supplier, but a feed currently
  traverses only relays from the same implementation as the publisher
  ([evidence](evidence.md) §9). Until that is fixed, pricing power sits with a single
  supplier per deployment, and the commodity-egress assumption is doing work the evidence
  does not yet support.
- What does relay memory instability cost to operate around? The reference relay grows under
  sustained load in a way cache tuning does not bound (§3.1), so a realistic model carries
  headroom and a planned restart cycle rather than steady-state capacity alone.

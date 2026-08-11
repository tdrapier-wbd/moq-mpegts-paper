# Desk analysis — always-on primary-distribution cost model (v1)

**Type:** desk model, not a rig experiment. No measurements were taken here; this combines the
capacity constants measured in [T9](test-9-performance.md) and [T8](test-8-srt-vs-moq.md) with
**public list prices** to produce the numeric cost model behind the always-on trunk case.

**State:** complete. Findings promoted to [economics](../docs/economics.md) §4.

**Reproduce:** `python3 lab/cost-model.py` — prints every table below. All rates are
constants at the top of that script, so re-pricing is a one-line edit per rate.

**Rates retrieved:** 2026-08-10. The AWS figures come from the machine-readable price list
(`AmazonEC2` / `AWSDataTransfer` / `AWSMediaConnect` offer files, publication version
`20260810185419`), not from the rendered pricing pages, so they are exact rather than transcribed.

---

## 1. Objective and framing

The question asked of this model:

> For always-on (24/7/365) primary distribution at 10 and 25 Mbps, fully redundant
> active/active 1+1, what does an Internet-native path actually cost per year at public list
> prices — for one channel to one destination, and for a transponder's worth of channels to many
> destinations — how does MoQ compare against SRT and against the managed services that already
> sell this, and how much does the answer depend on which supplier market the delivery is bought in?

That last clause turns out to carry the result. Protocol choice moves the total by single-digit
percentages; supplier category moves it by more than an order of magnitude.

Deliberately excluded: staffing and NOC cost (fixed, dominant at low route counts, and a separate
exercise); customer pricing; any incumbent's actual or depreciated route cost. Satellite appears
only as a *parity threshold* expressed against our own modelled numbers, so no transponder rate is
disclosed or needed.

## 2. Assumptions

| Assumption | Value | Basis |
|---|---|---|
| Availability | 24/7/365 — 8,760 h, 31,536,000 s | always-on trunk, the hardest case |
| Bitrate profiles | 10 Mbps and 25 Mbps TS | arbitrary but representative; 10 Mbps now, 25 Mbps aspirational |
| Redundancy | active/active 1+1, both legs always live | [architecture](../docs/architecture.md) §14; two full-rate copies at all times |
| Regions | EU (Ireland), US East (N. Virginia), US West (Oregon) | egress rates are identical across all three |
| MoQ carriage multiplier | **1.12x** source TS rate on the wire | T9 measured (10 and 27 Mbps both ~12 %) |
| SRT carriage multiplier | **1.033x** | *derived, not measured*: 7 × 188 B TS + 16 B SRT + 8 B UDP + 20 B IPv4 = 1,360 / 1,316 |
| MoQ ingest CPU | 0.34 core per 10 Mbps feed | T8, `moq import ts` on 2-vCPU EC2 |
| SRT ingest CPU | ~0.01 core per feed | T8, `tsp regulate` + SRT carriage |
| Relay CPU per session | 0.865 % core at 10 Mbps; 1.175 % at 25 Mbps | T9 bitrate sweep (25 Mbps uses the 27 Mbps point) |
| Instance sizing | 60 % target utilisation, sized on the *worse* of cores and sustained network baseline | see §7 |
| Billing unit | AWS in GiB, Azure/Cloudflare in decimal GB, GCP in GiB | each provider's own stated convention |

**One Mbps held for a year moves 3,942 GB (3,671 GiB).** That constant does all the work in an
always-on model: bitrate and volume are interchangeable, so every rate can be quoted as
`$/Mbps-year`, which is what §4 does.

## 3. Published rates used

Internet egress, per GB/GiB, monthly tiers (all $USD, EMEA/NA):

| Provider / product | Free | Tier 1 | Tier 2 | Tier 3 | Tier 4 |
|---|---|---|---|---|---|
| AWS data transfer out (EC2, MediaConnect) | 100 GB | 0.09 (→10 TB) | 0.085 (→50 TB) | 0.07 (→150 TB) | 0.05 (>150 TB) |
| Azure, Microsoft premium backbone | 100 GB | 0.087 | 0.083 | 0.07 | 0.05 |
| Azure, routing-preference transit ISP | 100 GB | 0.08 | 0.065 | 0.06 | 0.04 |
| GCP premium tier (to NA/EU) | 1 GiB | 0.12 (→1 TiB) | 0.11 (→10 TiB) | 0.08 (>10 TiB) | — |
| GCP standard tier | 200 GiB | 0.085 (→10 TiB) | 0.065 (→150 TiB) | 0.045 (>150 TiB) | — |
| Cloudflare MoQ relay | tech preview is free | 0.05 announced GA self-serve, inbound free | — | — | — |

AWS tier boundaries are binary (`10 TB` = 10,240 GB in the price list), so AWS volumes are billed in
GiB here. Azure states 1 TB = 1,000 GB.

CDN delivery, per GB, NA/EU list (retrieved from each provider's own pricing page):

| Provider / product | Rate |
|---|---|
| AWS CloudFront | 0.085 (first 10 TB) → ~0.020 at 5 PB+ |
| Fastly | 0.12 (North America), 0.085 (Europe) |
| Google Cloud CDN / Azure Front Door | 0.080 / 0.0825 first tier |
| **bunny.net standard network (119 PoPs)** | **0.01** |
| **bunny.net volume network (10 PoPs)** | **0.005** (<500 TB) · 0.004 (500 TB–1 PB) · 0.002 (1–2 PB) |

The independent CDNs matter to the model more than the hyperscaler CDNs do: bunny.net's volume
network publishes $0.005/GB on a public page with no request fees and no negotiation, an order of
magnitude below cloud egress list, while the hyperscalers' own CDNs price within a few percent of
their raw egress. The volume network runs far fewer points of presence, which is a reach
constraint rather than a delivery-quality one and matters much less for a few hundred fixed
professional endpoints than for a consumer audience.

Third-party reports of what large CDN customers pay at negotiated volume are **deliberately not
modelled**. They are unverifiable, they vary by an order of magnitude between sources, and quoting
them would imply a rate is obtainable when no one has published it. Every rate in this model is
either on a public price page or derived in the open from one that is; where a rate is assumed, it
is labelled.

**No MoQ relay rate is published by any CDN except Cloudflare.** Where this model prices a
CDN-operated MoQ relay it does so as an explicit assumption — a modest premium over the commodity
delivery rates above at committed volume — and labels it as such.

Other published rates:

| Item | Rate |
|---|---|
| AWS inter-region, Ireland → US East / US West | $0.02 / GiB |
| MediaConnect transport-stream flow | $0.16 / hour / flow (all three regions) = $1,402 / flow-year |
| MediaConnect reserved outbound bandwidth, 1 yr | 50 Mbps $1.161/h · 150 Mbps $2.834/h · 500 Mbps $6.474/h · 1500 Mbps $11.444/h |
| Zixi Broadcaster (AWS Marketplace, public list) | $0.05 / GB "Broadcaster Transport Traffic", *on top of* AWS egress and compute |
| Zixi ZEN Master (AWS Marketplace, public list) | $0.025 / GB |
| EC2 1-yr standard reserved, all-upfront, Linux, Ireland | c7g.large $420/yr · c7g.xlarge $839/yr · c6gn.large $502/yr · c6gn.xlarge $1,004/yr |
| Same, US East (N. Virginia) | c7g.large $391/yr · c7g.xlarge $781/yr · c6gn.large $446/yr · c6gn.xlarge $892/yr |
| EC2 sustained network baseline | c7g.large 0.937 Gbps · c7g.xlarge 1.876 · c6gn.large 3.0 · c6gn.xlarge 6.3 (burst 12.5–25) |
| IP transit, lowest posted, competitive hubs, Q2 2025 | $0.07 / Mbps / month (10 GigE port), $0.05 (100 GigE) — TeleGeography |

Zixi and Net Insight otherwise sell by private offer, so the Marketplace lines above are the only
public commercial-software rates found. Haivision publishes none.

## 4. Result — the price ladder

What it costs to deliver one always-on unidirectional Mbps for a year, and the same rate
expressed per GB. Grouped by who operates the infrastructure — the grouping
[economics](../docs/economics.md) §4.2 uses — and ordered by price within each group:

| Category | Option | $/GB-equiv | $/Mbps-yr | × transit |
|---|---|---:|---:|---:|
| **Self-hosted** — own the egress, unmetered per GB | IP transit, 10 GigE port, competitive hub *(bandwidth only — see §10.1)* | 0.00021 | 0.84 | 1× |
| | IP transit, 100 GigE port, competitive hub *(bandwidth only — see §10.1)* | 0.00015 | 0.60 | 1× |
| | *Illustrative all-in PoP, 40–100 % utilised (§10.1)* | *0.0009–0.0023* | *3.5–9.1* | *4–11×* |
| **Cloud** — own software on rented compute, metered egress | AWS / Azure list, first tier | 0.0900 | 330 | 393× |
| | Azure premium backbone, first tier | 0.0870 | 343 | 408× |
| | Azure transit routing, first tier | 0.0800 | 315 | 375× |
| | GCP premium, >10 TiB/mo | 0.0800 | 294 | 350× |
| | AWS, >150 TB/mo marginal tier | 0.0500 | 184 | 219× |
| | GCP standard tier, >150 TiB/mo | 0.0450 | 165 | 197× |
| | Azure transit routing, >150 TB/mo | 0.0400 | 158 | 188× |
| **Vendor / managed** — buy delivery as an outcome | Zixi Broadcaster licence + AWS list egress | 0.1400 | 528 | 628× |
| | MediaConnect reserved, 50 Mbps tier | 0.0516 | 203 | 242× |
| | Cloudflare MoQ, announced GA self-serve | 0.0500 | 197 | 235× |
| | MediaConnect reserved, 150 Mbps tier | 0.0420 | 166 | 197× |
| | MediaConnect reserved, 500 Mbps tier | 0.0288 | 113 | 135× |
| | **MediaConnect reserved, 1500 Mbps tier** | **0.0170** | **67** | **80×** |
| | bunny.net CDN, standard network, NA/EU | 0.0100 | 39 | 47× |
| | bunny.net CDN, volume network, <500 TB | 0.0050 | 20 | 23× |
| | bunny.net CDN, volume network, 1–2 PB | 0.0020 | 8 | 9× |

The `$/Mbps-yr` column is the model's working unit and the bridge between a port rate and a
per-GB rate; `$/GB-equiv` is the comparable figure and the only one the paper quotes. The two
columns rank AWS and Azure differently — AWS's $0.090 is per GiB and Azure's $0.087 per GB, so
AWS is the cheaper of the two once the 7.4 % unit difference is applied, which is exactly why
`$/GB-equiv` is the column to compare on. Three things fall out:

1. **The cheapest published delivery is not on cloud at all; it is on commodity CDN.** bunny.net
   publishes $0.005/GB, and $0.002/GB at 1–2 PB, against $0.09 first-tier cloud egress — 18× to 45×
   cheaper, on a public page, with no negotiation. The hyperscalers' own CDNs sit within a few
   percent of their raw egress, so that spread reflects commercial positioning rather than cost.
2. **Within a single hyperscaler, the managed video product undercuts the platform it runs on.**
   MediaConnect reserved outbound bandwidth at the 1500 Mbps tier is $0.017/GB — 5.3× cheaper than
   raw EC2 data transfer out at first-tier list. A DIY relay fleet on EC2 cannot buy that rate; it
   is a MediaConnect-only construct. So the "build it ourselves and save the service margin"
   instinct is **inverted at list prices** — but only inside that hyperscaler, since a commodity CDN
   undercuts MediaConnect by a further 2–8×.
3. **List cloud egress is two to three orders of magnitude above the cost of raw carriage, and
   about one order above the cost of delivery.** At $0.07/Mbps/month a Mbps-year of IP transit is
   $0.84 against $330 on AWS list — but transit is a port and a BGP session, not a delivery
   service. Loaded with facilities, hardware and diversity, self-hosted delivery lands at
   $0.001–0.004/GB (§10.1), which is the same band as commodity CDN list. **Two independent routes
   to delivery, one built and one bought, agree on the cost; cloud egress sits ten times above
   both.** That is the single most important result in the model, and it says the trunk case is
   decided by commercial terms rather than by engineering. Quote the tenfold figure, not the
   four-hundredfold one — §10.1 explains why the latter is not a rate anyone can transact at.

## 5. Result — one channel, one destination, 1+1

Annual USD, EU (Ireland), egress + compute, no staffing:

| Category | Option | 10 Mbps | 25 Mbps |
|---|---|---:|---:|
| **Self-hosted** *(marginal transit only)* | MoQ wire rate at IP transit list price | 19 | 47 |
| | SRT wire rate at IP transit list price | 17 | 43 |
| **Cloud** | MoQ, DIY on EC2 | **8,297** | **18,986** |
| | — of which egress | 7,293 | 17,982 |
| | — of which compute (2 × c6gn.large reserved) | 1,004 | 1,004 |
| | SRT, DIY on EC2 | 7,725 | 17,635 |
| | MoQ, DIY on Azure transit routing | 6,968 | 16,071 |
| | MoQ, DIY on GCP standard tier | 6,786 | 15,617 |
| **Vendor / managed** | Zixi Broadcaster on EC2 (licence + egress + compute) | 11,799 | 27,819 |
| | MediaConnect (SRT), on-demand egress | 9,524 | 19,434 |
| | MediaConnect (SRT), cheapest reserved mix | 9,524 | 13,418 |
| | MoQ on Cloudflare, announced GA rate | 4,415 | 11,038 |
| | MoQ relay on a commodity CDN @ $0.010/GB *(assumed)* | 883 | 2,208 |
| | MoQ relay on a commodity CDN @ $0.005/GB *(assumed)* | 442 | 1,104 |

Both legs of the 1+1 pair are tiered as one volume, because volume bands and the monthly free
allowance accrue per account, not per flow. Pricing each leg separately would grant the free
allowance twice and miss the band crossing that appears at 25 Mbps.

**The self-hosted rows are marginal transit only and are not comparable totals.** They exclude
ports, facilities, hardware, staff and any control-plane or provisioning software, which the cloud
and managed rows include or do not need. §10.1 builds the all-in figure; treat these two rows as
the wire cost of the bytes, not the cost of running the service.

Observations:

- **Egress is 88 % of the DIY bill at 10 Mbps and 95 % at 25 Mbps.** The measured compute
  advantage sits on a line that barely registers. T9's "compute is not the constraint" now has a
  number: about a thousand dollars a year against seven to eighteen thousand of egress.
- **Reserved bandwidth is granular, and the grain matters.** At one channel 1+1 (20.7 Mbps) the
  smallest 50 Mbps block over-buys, so on-demand per-GB wins; at 25 Mbps 1+1 (51.7 Mbps) the
  reserved mix is 31 % cheaper than on-demand MediaConnect. Reserved pricing rewards filling the
  tier, which is a scale and planning question, not a technology one.
- **Compute is a floor, not a slope, at this scale.** Two instances are needed for two legs
  whatever the traffic, and one channel uses ~4 % of one. The 10 and 25 Mbps compute figures are
  identical for exactly that reason.

### 5.1 One channel to many destinations

Same channel at 10 Mbps, 1+1, fanned out to N independent receiving sites:

| Destinations | MoQ wire | AWS list | Cloudflare | MediaConnect reserved | AWS $/destination |
|---|---:|---:|---:|---:|---:|
| 1 | 22 Mbps | 8,297 | 4,415 | 9,524 | 8,297 |
| 2 | 45 Mbps | 15,491 | 8,830 | 12,974 | 7,745 |
| 4 | 90 Mbps | 29,471 | 17,660 | 23,144 | 7,368 |
| 8 | 179 Mbps | 56,779 | 35,320 | 32,593 | 7,097 |
| 16 | 358 Mbps | 102,831 | 70,641 | 59,515 | 6,427 |
| 32 | 717 Mbps | 179,169 | 141,281 | 87,999 | 5,599 |
| 64 | 1,434 Mbps | 310,747 | 282,563 | 103,053 | 4,855 |
| 128 | 2,867 Mbps | 573,904 | 565,125 | 203,302 | 4,484 |
| 256 | 5,734 Mbps | 1,100,218 | 1,130,250 | 403,801 | 4,298 |
| 512 | 11,469 Mbps | 2,152,846 | 2,260,500 | 724,890 | 4,205 |
| 1024 | 22,938 Mbps | 4,258,101 | 4,521,001 | 1,435,884 | 4,158 |

Cost is near-linear in destinations. Unicast has no fan-out economy at the last hop, so
"one to many" is "one to one" repeated: per-destination cost halves across a thousandfold
scale-up and then asymptotes at the deepest volume band, and all of that improvement comes from
volume bands and from amortising the fixed pair of instances — none of it from the transport.
MediaConnect crosses below DIY at 8 destinations, where the aggregate finally justifies a reserved
block. Cloudflare's flat rate wins at small scale and loses above ~128 destinations, where enough
volume falls into AWS's deep bands.

The linearity is structural and holds under every price regime; only the *level* moves. The same
thousand destinations cost $4.26M at cloud list and roughly $450,000 at commodity CDN rates.

## 6. Result — a transponder's worth of channels

Channel count derived from the incumbent, so the comparison is like-for-like. EBU Technical Review
300 (Morello & Mignone, *DVB-S2 — ready for lift-off*) gives **58.8 Mbps useful** for a 36 MHz-class
transponder at DVB-S2 8PSK 2/3, 29.7 Mbaud, and counts 6 AVC HD programmes on it. Dividing by
statmux averages: 9.8 Mbps → 6 services, 7.3 → 8, 5.9 → 10. **The model uses 8 HD services**, with
6–10 as the honest range.

Note the profile mismatch and do not conflate the two: the transponder sets the *channel count*,
while the 10/25 Mbps profiles are primary-distribution rates well above DTH emission rates.

On-demand cloud list is deliberately not a column here: a transponder is leased for years, so the
honest counterpart is committed or commodity capacity, not a rate that assumes the traffic could
stop tomorrow. Eight services × 10 Mbps × 1+1, delivery cost only, no relay compute, annual USD:

| Destinations | Aggregate wire | MediaConnect reserved | Cloud at 70 % private | CDN @ $0.010/GB *(assumed)* | CDN @ $0.005/GB *(assumed)* | IP transit *(bandwidth only)* |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 179 Mbps | 52,215 | 16,732 | 7,064 | 3,532 | 151 |
| 2 | 358 Mbps | 79,138 | 30,548 | 14,128 | 7,064 | 301 |
| 4 | 717 Mbps | 107,622 | 53,449 | 28,256 | 14,128 | 602 |
| 8 | 1,434 Mbps | 122,675 | 92,923 | 56,513 | 28,256 | 1,204 |
| 16 | 2,867 Mbps | 222,924 | 171,870 | 113,025 | 56,513 | 2,408 |
| 32 | 5,734 Mbps | 445,849 | 329,764 | 226,050 | 113,025 | 4,817 |
| 64 | 11,469 Mbps | 811,789 | 645,552 | 452,100 | 226,050 | 9,634 |
| 128 | 22,938 Mbps | 1,590,060 | 1,277,129 | 904,200 | 452,100 | 19,268 |
| 256 | 45,875 Mbps | 3,155,229 | 2,540,282 | 1,808,400 | 904,200 | 38,535 |
| 512 | 91,750 Mbps | 6,297,284 | 5,066,588 | 3,616,801 | 1,808,400 | 77,070 |
| 1024 | 183,501 Mbps | 12,494,318 | 10,119,201 | 7,233,602 | 3,616,801 | 154,141 |

Marginal cost of one additional destination for the whole 8-service 1+1 multiplex (179.2 Mbps):

| Price point | $/destination-yr | Destinations to parity per $1M/yr of incumbent cost |
|---|---:|---:|
| AWS first tier | 59,210 | 16.9 |
| Cloudflare MoQ, announced | 35,320 | 28.3 |
| AWS deepest tier | 32,895 | 30.4 |
| MediaConnect reserved, 1500 Mbps tier | 11,976 | 83.5 |
| CDN MoQ relay @ $0.010/GB *(assumed)* | 7,064 | 141.6 |
| CDN MoQ relay @ $0.005/GB *(assumed)* | 3,532 | 283.1 |
| IP transit, 10 GigE *(bandwidth only, §10)* | 151 | 6,643 |

The parity column is a normaliser, not a price: divide the incumbent's real annual space-segment
cost by the $/destination figure to get the destination count at which unicast IP stops being
cheaper. **This is the structural asymmetry, and it is not a pricing artefact:** satellite fan-out
inside the footprint is free, unicast IP is linear in destinations.

But the *level* at which that asymmetry bites is set entirely by which market the delivery is
bought in, and the range is wide: parity moves from about 17 destinations at cloud first-tier list
to 83 at the deepest published committed rate and 283 at assumed commodity CDN rates. **A
cloud-priced model would write off the several-hundred-destination case that the commodity market
puts back in contention** — which is the finding this table exists to support, and the basis of
the market-structure argument in [economics](../docs/economics.md) §4.9.

Two mechanics worth noting. Cloudflare's flat $0.05/GB *loses* to AWS at 20 destinations and above
(3,584 Mbps, ~1,177 TB/month), where enough volume falls in AWS's $0.05/GiB (= $0.0466/GB) band to
undercut it — flat rates win at small scale and lose at large. And AWS volume tiers accumulate per
*account*, across services and regions, so the deep-tier columns are only reachable by an operator
whose total traffic gets there.

## 7. What actually binds a relay instance

Combining T9's ~1.1 Gbps per core with published sustained-network baselines contradicts the
intuition that CPU is what you buy:

| Instance | vCPU | Net baseline | CPU-limited | Net-limited | Binds |
|---|---:|---:|---:|---:|---|
| c7g.large | 2 | 0.937 Gbps | 2.20 Gbps | 0.94 Gbps | **network** |
| c7g.xlarge | 4 | 1.876 Gbps | 4.40 Gbps | 1.88 Gbps | **network** |
| c6gn.large | 2 | 3.0 Gbps | 2.20 Gbps | 3.00 Gbps | cores |
| c6gn.xlarge | 4 | 6.3 Gbps | 4.40 Gbps | 6.30 Gbps | cores |

Sessions per instance at 11.2 Mbps of MoQ wire rate: c7g.large 231 by CPU but **84** by network
baseline; c6gn.large 231 by CPU and 268 by network, so 231. **On a general-purpose instance the
sustained network allowance throws away more than half the relay's measured compute headroom.**
The "up to 12.5 Gbps" headline is burst credit, irrelevant to a 24/7 feed. Network-optimised
families cost ~20 % more per instance and remove the ceiling, which is the correct trade for an
always-on relay.

## 8. Where relay fan-out changes the bill — and where it does not

Fan-out to N receivers *outside* the cloud costs N copies of internet egress whether the protocol
has a relay or not. MoQ's 1:N amplification changes only the hops before the last one. For the
8-service 1+1 multiplex, backhauled Ireland → US at $0.02/GiB:

| Receivers in one remote region | Naive per-receiver backhaul | With a regional relay | Saved |
|---:|---:|---:|---:|
| 2 | 26,316 | 13,158 | 13,158 |
| 4 | 52,631 | 13,158 | 39,474 |
| 8 | 105,263 | 13,158 | 92,105 |
| 16 | 210,526 | 13,158 | 197,368 |

The origin uplink likewise carries 16 streams once rather than once per receiver — a
contribution-link sizing saving rather than a cloud invoice line. **So the relay's economic value is
real but bounded and specific: it removes duplicated backhaul and duplicated uplink, not
last-mile egress.** Any claim that MoQ's fan-out reduces distribution cost must say which hop it
means, or it is wrong.

The same is true of HTTP caching, and the symmetry matters: a CDN edge fetches a segment once and
serves N receivers over N unicast connections, exactly as a relay receives an object once and
serves N subscribers over N unicast connections. **A MoQ relay is a cache.** Neither breaks
last-mile linearity, so the tables above apply to segmented HTTP formats as much as to MoQ, and no
transport on the list has a fan-out advantage over another. What differs between them is the price
the operator charges, not the topology — which is why §4's ladder, not §8's mechanism, is where the
fan-out case is won or lost.

## 9. The carriage penalty, priced

MoQ's 1.12x against SRT's 1.033x is an **8.4 % higher wire rate for the same service**, on the line
that dominates. At AWS list:

| Scenario | Extra $/yr | Extra % |
|---|---:|---:|
| 1 channel, 1 destination, 10 Mbps | 572 | 8.5 % |
| 1 channel, 1 destination, 25 Mbps | 1,351 | 8.1 % |
| 8 channels, 4 destinations, 10 Mbps | 10,170 | 6.1 % |
| 8 channels, 16 destinations, 10 Mbps | 40,679 | 7.6 % |

Percentages fall below 8.4 % only because the extra volume lands in cheaper tiers. This is a real
and permanent tax, roughly the same size as the difference between two providers' list prices — so
it matters, but it is not decisive. It is smaller than the reserved-versus-on-demand gap and an
order of magnitude smaller than the gap between supplier categories in §4, which is the model's
central point: **an 8 % carriage penalty is not worth optimising against a 45× procurement
decision.** Reducing it is still worth doing, since it is permanent and applies to every byte, but
it cannot decide the trunk case either way.

## 10. Egress price sensitivity, and what the transit floor is not

8 services × 1+1 × 4 destinations = 717 Mbps = 2,826 TB/yr:

| Egress price ($/GB) | Annual egress | vs AWS list | What this rate is |
|---:|---:|---:|---|
| 0.0900 | 254,306 | 100 % | cloud first-tier list |
| 0.0700 | 197,794 | 78 % | — |
| 0.0500 | 141,281 | 56 % | cloud deepest published tier; Cloudflare announced MoQ rate |
| 0.0170 | 48,036 | 19 % | MediaConnect reserved, largest tier |
| 0.0100 | 28,256 | 11 % | commodity CDN list, standard network |
| 0.0050 | 14,128 | 6 % | commodity CDN list, volume network |
| 0.0020 | 5,651 | 2 % | commodity CDN list, 1–2 PB tier |
| 0.0010 | 2,826 | 1 % | *illustrative* self-hosted all-in at high utilisation (below) |
| 0.00021 | 593 | 0.2 % | **wholesale transit bandwidth only — not a delivery rate** |
| 0.00010 | 283 | 0.1 % | below anything observed; included to show the floor is asymptotic |

The output is very nearly linear in a single input. Every other modelled quantity — compute,
protocol overhead, instance family, region — moves the total by single-digit percentages, while
the egress rate spans 18× across the *published* ladder in §3 and §4 alone.

### 10.1 Where $0.0002/GB comes from, and why it is not an achievable rate

The bottom of the ladder is derived, not quoted, and it is the number most likely to be misread,
so the arithmetic is given in full. TeleGeography's lowest posted IP transit price at competitive
hubs is **$0.07 per Mbps per month** on a 10 GigE port ($0.05 on 100 GigE). One Mbps held for a
year costs $0.84 and moves 3,942 GB, so:

> $0.84 ÷ 3,942 GB = **$0.000213/GB** (10 GigE) · $0.60 ÷ 3,942 GB = **$0.000152/GB** (100 GigE)

**This is the price of wholesale bandwidth at 100 % port utilisation for 8,760 hours. It is not an
egress rate, not a CDN rate, and not a discount anyone can negotiate on any of them.** Four things
separate it from a rate a buyer could actually transact at:

- **It is a different product.** Cloud egress and CDN delivery bundle a global network, PoPs,
  routing, DDoS absorption, support and an SLA. IP transit is a port and a BGP session. No
  enterprise discount programme converts one into the other, and **nothing in this model should be
  read as suggesting a hyperscaler or CDN rate can approach it.**
- **It assumes the port is full.** Real deployments size for peak and run well below it; at 40 %
  average utilisation the effective rate is 2.5× higher before anything else is counted.
- **It is bandwidth only.** No ports, cross-connects, colocation, power, hardware, IP space,
  routers, transit diversity, or staff.
- **It is the lowest posted rate at the most competitive hubs**, available at large commitment —
  not a typical price, and not available everywhere a broadcaster needs to land traffic.

An illustrative all-in build-up shows the gap. A 10 Gbps-capable point of presence with transit
from two providers for diversity, rack, power, cross-connects and amortised hardware comes to
roughly $36,000 a year on the assumptions below — of which the transit itself is under half:

| Line | Annual USD | Basis |
|---|---:|---|
| Transit, 10 Gbps committed | 8,400 | $0.07/Mbps/mo, lowest posted |
| Second transit provider (diversity) | 8,400 | same rate; assumed, not required by any published source |
| Colocation, power, cross-connects | 15,000 | **illustrative** — no public rate modelled |
| Hardware, 2 relay servers over 4 years | 4,000 | **illustrative** |
| **Total** | **35,800** | |

| Average port utilisation | Effective all-in $/GB |
|---:|---:|
| 100 % | 0.0009 |
| 60 % | 0.0015 |
| 40 % | 0.0023 |
| 25 % | 0.0036 |

**A realistic self-hosted operation therefore lands around $0.001–0.004/GB, four to seventeen times
the bandwidth-only floor** — and, notably, in the same band as commodity CDN volume pricing
($0.002–0.005/GB). That coincidence is the useful result: it suggests the published commodity CDN
rates are close to the real cost of operating delivery at scale, which makes them a credible
reference point for what a competitive MoQ relay market would charge, and confirms that $0.0002/GB
is an asymptote nobody transacts at rather than a target anybody should quote. The colocation and
hardware lines are illustrative assumptions, not published rates, and are the weakest inputs
anywhere in this model.

## 11. Limitations

- **List prices only.** Enterprise discount programmes, private pricing, committed-spend
  agreements and Cloudflare's "usual media delivery pricing" for enterprise are all materially
  below list and all confidential. Every DIY and managed figure here is therefore an *upper* bound,
  and the ranking between them can invert under real contracts.
- **Cloudflare's $0.05/GB is announced, not in force.** It is free in tech preview, with commercial
  pricing signposted for 2026 H2. Modelling it as a firm rate is a forward assumption.
- **No CDN publishes a MoQ relay rate.** The $0.010 and $0.005/GB relay columns apply commodity CDN
  *delivery* rates to a MoQ relay service that does not yet exist as a product. They assume such a
  service would price near commodity delivery rather than at a large premium, which is an argument
  from market structure, not an observed price.
- **The self-hosted all-in build-up in §10.1 is illustrative.** Colocation, power and hardware
  lines carry no published source, and no control-plane, provisioning or software-licensing cost is
  included on the self-hosted path — which is not free and cannot be assumed away.
- **SRT's 1.033x is derived, not measured.** It follows from framing arithmetic on a 1,316-byte
  payload, and it ignores retransmission under real loss, which raises both transports. The
  comparison to MoQ's measured 1.12x is therefore not strictly like-for-like — the honest reading is
  "MoQ costs roughly 8 % more wire on a clean path," pending the measured back-to-back run.
- **Both carriage figures are clean-path.** Under loss, retransmission raises the wire rate on both
  sides, and the ratio between them is unmeasured.
- **The GiB/GB convention shifts AWS figures by 7.4 %.** AWS's binary tier boundaries imply GiB
  billing and that is what is modelled; a decimal-GB reading raises every AWS number by 7.4 %.
- **The 100 GB/month AWS free tier is applied per scenario**, whereas it is per account. Worth up
  to ~$108/yr per scenario — noise here, but wrong if scenarios are summed.
- **No staffing, tooling, monitoring, integration or grooming cost.** For a small route count these
  plausibly exceed everything modelled here.
- **No receive-side cost on either side**, and no satellite uplink, teleport or IRD cost. The
  comparison is transport-only.
- **Ingest CPU at 25 Mbps is assumed linear in bitrate** from the 10 Mbps measurement. It is not
  measured, and it does not matter: the whole compute line is ~5 % of the total.
- **One region-pair, one currency, no tax.** Rates are USD ex-VAT for Ireland / N. Virginia /
  Oregon, which happen to share identical egress pricing.

## 12. What to measure or obtain next

1. **MoQ vs SRT wire bytes back-to-back under loss**, on the same path — closes the one place the
   model uses a derived rather than measured constant, and it is already on the T9 list.
2. **Whether reserved-bandwidth-equivalent terms exist for raw egress.** The model's most
   surprising within-hyperscaler finding — the managed service undercutting the platform by 5× —
   turns entirely on this being a MediaConnect-only construct. If a committed-egress agreement can
   reach $0.017/GB on plain EC2, the DIY case on cloud is restored.
3. **Whether a CDN will operate MoQ relays at delivery-rate pricing.** The several-hundred-
   destination case in §6 rests on it. Cloudflare's announced $0.05/GB is the only published MoQ
   relay rate and sits 10× above that provider's own commodity delivery pricing, so whether relay
   service converges toward delivery rates or holds a premium is the single largest open commercial
   question in the model.
4. **A control-plane cost for the self-hosted path.** §10.1 prices bandwidth and iron but not
   provisioning, monitoring or orchestration, which is where vendors price and where the
   self-hosted case is most likely to be overstated.

## References

- Model script: [`cost-model.py`](cost-model.py)
- Measured inputs: [T9](test-9-performance.md) (carriage overhead, relay CPU, memory),
  [T8](test-8-srt-vs-moq.md) (ingest CPU, SRT comparison)
- Promoted to: [`docs/economics.md`](../docs/economics.md) §4
- AWS price list bulk API: `pricing.us-east-1.amazonaws.com/offers/v1.0/aws/{AmazonEC2,AWSDataTransfer,AWSMediaConnect}/current/`
- Azure bandwidth pricing; Google Cloud VPC network pricing
- Cloudflare, *MoQ: Refactoring the Internet's real-time media stack* (announced GA rate)
- CDN list pricing: bunny.net pricing page (standard and volume networks); AWS CloudFront,
  Fastly, Google Cloud CDN and Azure Front Door pricing pages
- AWS Marketplace listings: Zixi Broadcaster, Zixi ZEN Master
- EBU Technical Review 300, Morello & Mignone, *DVB-S2 — ready for lift-off*
- TeleGeography, *State of the Network 2026* / IP transit price erosion analyses

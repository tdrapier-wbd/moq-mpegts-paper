# Desk analysis — always-on primary-distribution cost model (v1)

**Type:** desk model, not a rig experiment. No measurements were taken here; this combines the
capacity constants measured in [T9](test-9-performance.md) and [T8](test-8-srt-vs-moq.md) with
**public list prices** to produce the first numeric cost model for the always-on trunk case.

**State:** complete for a first pass. Findings promoted to [economics](../docs/economics.md) §4.

**Reproduce:** `python3 lab/cost-model.py` — prints every table below. All rates are
constants at the top of that script, so re-pricing is a one-line edit per rate.

**Rates retrieved:** 2026-08-10. The AWS figures come from the machine-readable price list
(`AmazonEC2` / `AWSDataTransfer` / `AWSMediaConnect` offer files, publication version
`20260810185419`), not from the rendered pricing pages, so they are exact rather than transcribed.

---

## 1. Objective and framing

The economics document had a framework and no numbers. The question asked of this model:

> For always-on (24/7/365) primary distribution at 10 and 25 Mbps, fully redundant
> active/active 1+1, what does an Internet-native path actually cost per year at public list
> prices — for one channel to one destination, and for a transponder's worth of channels to many
> destinations — and how does MoQ compare against SRT and against the managed services that
> already sell this?

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
| OCI | 10 TB/month | rates thereafter geography-dependent; Oracle's own list renders dynamically and was not machine-readable — **not modelled**, treated as a low-price outlier to verify at quote time | | | |

AWS tier boundaries are binary (`10 TB` = 10,240 GB in the price list), so AWS volumes are billed in
GiB here. Azure states 1 TB = 1,000 GB.

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

Cost of delivering **one** always-on unidirectional Mbps for a year:

| Option | $/GB-equiv | $/Mbps-yr | × transit |
|---|---:|---:|---:|
| Zixi Broadcaster licence + AWS list egress | 0.1400 | 528 | 628× |
| Azure premium backbone, first tier | 0.0870 | 343 | 408× |
| AWS / Azure list, first tier | 0.0900 | 330 | 393× |
| Azure transit routing, first tier | 0.0800 | 315 | 375× |
| GCP premium, >10 TiB/mo | 0.0800 | 294 | 350× |
| MediaConnect reserved, 50 Mbps tier | 0.0516 | 203 | 242× |
| Cloudflare MoQ, announced GA self-serve | 0.0500 | 197 | 235× |
| AWS, >150 TB/mo marginal tier | 0.0500 | 184 | 219× |
| MediaConnect reserved, 150 Mbps tier | 0.0420 | 166 | 197× |
| GCP standard tier, >150 TiB/mo | 0.0450 | 165 | 197× |
| Azure transit routing, >150 TB/mo | 0.0400 | 158 | 188× |
| MediaConnect reserved, 500 Mbps tier | 0.0288 | 113 | 135× |
| **MediaConnect reserved, 1500 Mbps tier** | **0.0170** | **67** | **80×** |
| IP transit, 10 GigE port, competitive hub | 0.0002 | 0.84 | 1× |
| IP transit, 100 GigE port, competitive hub | 0.0002 | 0.60 | 1× |

Two things fall out immediately, and both were unexpected:

1. **The cheapest published egress on AWS is inside the managed video product, not the platform.**
   MediaConnect reserved outbound bandwidth at the 1500 Mbps tier is $0.017/GB — 5.3× cheaper than
   raw EC2 data transfer out at first-tier list, and 2.9× cheaper than Cloudflare's announced MoQ
   rate. A DIY relay fleet on EC2 cannot buy that rate; it is a MediaConnect-only construct. So the
   "build it ourselves and save the service margin" instinct is **wrong at list prices** for
   always-on traffic, and inverted: the service is cheaper than the platform it runs on.
2. **List egress is two to three orders of magnitude above the cost of carriage.** At
   $0.07/Mbps/month, a Mbps-year of IP transit is $0.84 against $330 on AWS list. Nothing about
   always-on video is expensive; *cloud egress pricing* is. This is the single most important number
   in the model, because it means the trunk case is decided by commercial terms, not by engineering.

## 5. Result — one channel, one destination, 1+1

Annual USD, EU (Ireland), egress + compute, no staffing:

| | 10 Mbps | 25 Mbps |
|---|---:|---:|
| MoQ, DIY on EC2 | **8,297** | **18,986** |
| — of which egress | 7,293 | 17,982 |
| — of which compute (2 × c6gn.large reserved) | 1,004 | 1,004 |
| SRT, DIY on EC2 | 7,725 | 17,635 |
| Zixi Broadcaster on EC2 (licence + egress + compute) | 11,799 | 27,819 |
| MediaConnect (SRT), on-demand egress | 9,524 | 19,434 |
| MediaConnect (SRT), cheapest reserved mix | 9,524 | 13,418 |
| MoQ on Cloudflare, announced GA rate | 4,415 | 11,038 |
| MoQ, DIY on Azure transit routing | 6,968 | 16,071 |
| MoQ, DIY on GCP standard tier | 6,786 | 15,617 |
| MoQ wire rate at IP transit list price | 19 | 47 |

Both legs of the 1+1 pair are tiered as one volume, because volume bands and the monthly free
allowance accrue per account, not per flow. Pricing each leg separately would grant the free
allowance twice and miss the band crossing that appears at 25 Mbps.

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

Cost is near-linear in destinations. Unicast has no fan-out economy at the last hop, so
"one to many" is "one to one" repeated: per-destination cost falls only ~23 % across a
sixteenfold scale-up, and all of that comes from volume bands and from amortising the fixed
pair of instances — none of it from the transport. MediaConnect crosses below DIY at 8
destinations, where the aggregate finally justifies a reserved block.

## 6. Result — a transponder's worth of channels

Channel count derived from the incumbent, so the comparison is like-for-like. EBU Technical Review
300 (Morello & Mignone, *DVB-S2 — ready for lift-off*) gives **58.8 Mbps useful** for a 36 MHz-class
transponder at DVB-S2 8PSK 2/3, 29.7 Mbaud, and counts 6 AVC HD programmes on it. Dividing by
statmux averages: 9.8 Mbps → 6 services, 7.3 → 8, 5.9 → 10. **The model uses 8 HD services**, with
6–10 as the honest range.

Note the profile mismatch and do not conflate the two: the transponder sets the *channel count*,
while the 10/25 Mbps profiles are primary-distribution rates well above DTH emission rates.

8 services × 10 Mbps × 1+1, annual USD:

| Destinations | Aggregate wire | AWS list | AWS deepest tier | MediaConnect reserved | Cloudflare announced | IP transit |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 179 Mbps | 55,775 | 32,895 | 52,215 | 35,320 | 151 |
| 2 | 358 Mbps | 101,827 | 65,789 | 79,138 | 70,641 | 301 |
| 4 | 717 Mbps | 178,165 | 131,578 | 107,622 | 141,281 | 602 |
| 8 | 1,434 Mbps | 309,743 | 263,157 | 122,675 | 282,563 | 1,204 |
| 16 | 2,867 Mbps | 572,900 | 526,314 | 222,924 | 565,125 | 2,408 |
| 32 | 5,734 Mbps | 1,099,214 | 1,052,628 | 445,849 | 1,130,250 | 4,817 |

Marginal cost of one additional destination for the whole 8-service 1+1 multiplex (179.2 Mbps):

| Price point | $/destination-yr | Destinations to parity per $1M/yr of incumbent cost |
|---|---:|---:|
| AWS first tier | 59,210 | 16.9 |
| Cloudflare announced | 35,320 | 28.3 |
| AWS deepest tier | 32,895 | 30.4 |
| MediaConnect reserved, 1500 Mbps tier | 11,976 | 83.5 |
| IP transit, 10 GigE | 151 | 6,643 |

The parity column is a normaliser, not a price: divide the incumbent's real annual space-segment
cost by the $/destination figure to get the destination count at which unicast IP stops being
cheaper. **This is the structural asymmetry, and it is not a pricing artefact:** satellite fan-out
inside the footprint is free, unicast IP is linear in destinations. Note also that Cloudflare's flat
$0.05/GB *loses* to AWS at 20 destinations and above (3,584 Mbps, ~1,177 TB/month), where enough of
the volume falls in AWS's $0.05/GiB (= $0.0466/GB) band to undercut it — flat rates win at small
scale and lose at large. AWS volume tiers also accumulate per *account*, across services and
regions, so the deep-tier columns are only reachable by an operator whose total traffic gets there.

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
it matters, but it is not decisive, and it is far smaller than the reserved-versus-on-demand gap.

## 10. Egress price sensitivity

8 services × 1+1 × 4 destinations = 717 Mbps = 2,826 TB/yr:

| Egress price ($/GB) | Annual egress | vs AWS list |
|---:|---:|---:|
| 0.0900 | 254,306 | 100 % |
| 0.0700 | 197,794 | 78 % |
| 0.0500 | 141,281 | 56 % |
| 0.0170 | 48,036 | 19 % |
| 0.0085 | 24,018 | 9 % |
| 0.0002 | 565 | 0.2 % |

The output is very nearly linear in a single input. Every other modelled quantity — compute,
protocol overhead, instance family, region — moves the total by single-digit percentages, while
the egress rate spans 8× across the published ladder in §4 alone and 450× once transit is
included as the floor.

## 11. Limitations

- **List prices only.** Enterprise discount programmes, private pricing, committed-spend
  agreements and Cloudflare's "usual media delivery pricing" for enterprise are all materially
  below list and all confidential. Every DIY and managed figure here is therefore an *upper* bound,
  and the ranking between them can invert under real contracts.
- **Cloudflare's $0.05/GB is announced, not in force.** It is free in tech preview, with commercial
  pricing signposted for 2026 H2. Modelling it as a firm rate is a forward assumption.
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
2. **A real quote.** Every conclusion above is list-price arithmetic. One enterprise egress rate,
   or one MediaConnect private offer, would move this from indicative to decision-grade.
3. **Whether reserved-bandwidth-equivalent terms exist for raw egress.** The model's most
   surprising finding — the managed service undercutting the platform by 5× — turns entirely on
   this being a MediaConnect-only construct. If a committed-egress agreement can reach $0.017/GB on
   plain EC2, the DIY case is restored.
4. **OCI (and other low-egress providers) priced properly**, since a $0.0085/GB-class rate would
   change the answer by an order of magnitude. Oracle's list did not yield to machine-readable
   retrieval and third-party trackers disagree on whether egress is now zero-rated.
5. **The satellite side of the parity calculation**, from a design partner's actual depreciated
   cost — the missing half of §6, and the [economics](../docs/economics.md) §10 headline question.

## References

- Model script: [`cost-model.py`](cost-model.py)
- Measured inputs: [T9](test-9-performance.md) (carriage overhead, relay CPU, memory),
  [T8](test-8-srt-vs-moq.md) (ingest CPU, SRT comparison)
- Promoted to: [`docs/economics.md`](../docs/economics.md) §4
- AWS price list bulk API: `pricing.us-east-1.amazonaws.com/offers/v1.0/aws/{AmazonEC2,AWSDataTransfer,AWSMediaConnect}/current/`
- Azure bandwidth pricing; Google Cloud VPC network pricing; Oracle Cloud networking pricing
- Cloudflare, *MoQ: Refactoring the Internet's real-time media stack* (announced GA rate)
- AWS Marketplace listings: Zixi Broadcaster, Zixi ZEN Master
- EBU Technical Review 300, Morello & Mignone, *DVB-S2 — ready for lift-off*
- TeleGeography, *State of the Network 2026* / IP transit price erosion analyses

#!/usr/bin/env python3
"""Always-on primary-distribution cost model.

Reproduces every figure in lab/cost-model.md and docs/economics.md §4.
No arguments; prints all tables. Rates are public list prices captured 2026-08-10
(sources in the lab file). Capacity constants are T9/T8 lab measurements.

    python3 lab/cost-model.py
"""

HOURS_YEAR = 8760                 # 365 d, always-on
SECONDS_YEAR = 31_536_000
GIB = 1 << 30
GB = 10**9

# ---------------------------------------------------------------- measured constants
MOQ_CARRIAGE = 0.982             # T9: IP wire bytes / source TS rate, measured on a WAN path.
                                 # Below 1.0 because the media-aware lane strips the source's
                                 # null stuffing (4.57% of this clip) and the edge groomer
                                 # regenerates it. 0.973 with path MTU discovery enabled.
SRT_CARRIAGE = 1.037             # T9: measured on the same path, same clip. Matches the framing
                                 # arithmetic 1360/1316 = 1.0334 (7x188 TS + 16 SRT + 8 UDP + 20 IPv4).
MOQ_IMPORT_CORES_AT_10 = 0.34    # T8: `moq import ts`, 2-vCPU EC2
SRT_CARRIAGE_CORES_AT_10 = 0.01  # T8: `tsp regulate` + SRT carriage
RELAY_CORE_PER_SESSION = {10: 0.00865, 25: 0.01175}   # T9 bitrate sweep (25 uses the 27 Mbps point)

# ---------------------------------------------------------------- published rates
# AWS: tier boundaries are binary (10 TB == 10240 GB), so AWS volumes are billed in GiB.
AWS_DTO = [(100, 0.0), (10_240, 0.09), (51_200, 0.085), (153_600, 0.07), (None, 0.05)]
AZURE_PREMIUM = [(100, 0.0), (10_100, 0.087), (50_100, 0.083), (150_100, 0.07), (None, 0.05)]
AZURE_TRANSIT = [(100, 0.0), (10_100, 0.08), (50_100, 0.065), (150_100, 0.06), (None, 0.04)]
GCP_PREMIUM = [(1, 0.0), (1_024, 0.12), (10_240, 0.11), (None, 0.08)]
GCP_STANDARD = [(200, 0.0), (10_240, 0.085), (153_600, 0.065), (None, 0.045)]
CLOUDFLARE_MOQ = [(None, 0.05)]  # announced GA self-serve rate; free in tech preview
ZIXI_BROADCASTER = 0.05          # AWS Marketplace software rate, per GB, on top of egress

# CDN delivery. Hyperscaler CDNs price close to their own egress; the independent
# market has commoditised well below it. List rates, NA/EU first tier, July 2026.
CLOUDFRONT = [(10_240, 0.085), (51_200, 0.080), (153_600, 0.060), (None, 0.020)]
FASTLY_NA = [(None, 0.12)]
BUNNY_STANDARD = [(None, 0.01)]   # NA/EU flat
BUNNY_VOLUME = [(None, 0.005)]    # NA/EU flat
# A CDN-operated MoQ relay: ASSUMPTION, not a published rate. Only Cloudflare has
# announced one ($0.05/GB); these model a competitive market at a modest premium
# over commodity CDN delivery on committed volume. See docs/economics.md §4.4.
CDN_MOQ_RELAY_ASSUMED = [(None, 0.010)]
CDN_MOQ_RELAY_FLOOR = [(None, 0.005)]

MEDIACONNECT_FLOW_HOUR = 0.16
MEDIACONNECT_RESERVED = {50: 1.161, 150: 2.834, 500: 6.474, 1500: 11.444}  # Mbps -> $/hour, 1yr

AWS_INTERREGION = 0.02           # $/GiB, EU (Ireland) -> US East / US West

# EC2 1-yr standard reserved, all-upfront, Linux, annual USD per instance.
EC2 = {
    "c7g.large":   {"eu-west-1": 420, "us-east-1": 391, "vcpu": 2, "net_baseline_gbps": 0.937},
    "c7g.xlarge":  {"eu-west-1": 839, "us-east-1": 781, "vcpu": 4, "net_baseline_gbps": 1.876},
    "c6gn.large":  {"eu-west-1": 502, "us-east-1": 446, "vcpu": 2, "net_baseline_gbps": 3.0},
    "c6gn.xlarge": {"eu-west-1": 1004, "us-east-1": 892, "vcpu": 4, "net_baseline_gbps": 6.3},
}

TRANSIT_10GE = 0.07   # $/Mbps/month, lowest posted, competitive hubs (TeleGeography Q2 2025)
TRANSIT_100GE = 0.05


def tiered_monthly_cost(units_per_month, tiers):
    """Cost of a monthly volume against cumulative tier boundaries."""
    cost, prev = 0.0, 0
    for bound, rate in tiers:
        top = units_per_month if bound is None else min(units_per_month, bound)
        if top > prev:
            cost += (top - prev) * rate
        prev = bound if bound is not None else prev
        if bound is not None and units_per_month <= bound:
            break
    return cost


def annual_cost(mbps, tiers, unit=GIB):
    """Annual cost of a continuous wire rate, tiered on its own monthly volume."""
    bytes_month = mbps * 1e6 * SECONDS_YEAR / 12 / 8
    return 12 * tiered_monthly_cost(bytes_month / unit, tiers)


def volume(mbps, unit=GIB):
    return mbps * 1e6 * SECONDS_YEAR / 8 / unit


def mediaconnect_egress(wire_mbps):
    """Cheapest annual outbound cost: any mix of reserved blocks, remainder on-demand.

    Reserved blocks may be stacked, so fill with the cheapest $/Mbps tier first and
    price the remainder both ways (one more block vs per-GB) taking the lower.
    """
    best = annual_cost(wire_mbps, AWS_DTO)          # all on-demand
    tiers = sorted(MEDIACONNECT_RESERVED, reverse=True)
    for i, tier in enumerate(tiers):
        blocks, cost, remaining = wire_mbps // tier, 0.0, wire_mbps
        cost += blocks * MEDIACONNECT_RESERVED[tier] * HOURS_YEAR
        remaining -= blocks * tier
        if remaining > 0:
            options = [annual_cost(remaining, AWS_DTO)]
            options += [MEDIACONNECT_RESERVED[t] * HOURS_YEAR
                        for t in MEDIACONNECT_RESERVED if t >= remaining]
            for smaller in tiers[i + 1:]:
                sub_blocks = remaining // smaller
                if sub_blocks:
                    rest = remaining - sub_blocks * smaller
                    options.append(sub_blocks * MEDIACONNECT_RESERVED[smaller] * HOURS_YEAR
                                   + min([annual_cost(rest, AWS_DTO)]
                                         + [MEDIACONNECT_RESERVED[t] * HOURS_YEAR
                                            for t in MEDIACONNECT_RESERVED if t >= rest]))
            cost += min(options)
        best = min(best, cost)
    return best


def rule(width=104):
    print("-" * width)


def _money(value):
    """Trim trailing zeros so 0.00015 and 0.14 both read cleanly on one axis."""
    text = f"{value:.5f}".rstrip("0").rstrip(".")
    return text if text else "0"


def log_bars(rows, lo_decade, hi_decade, label_width=48, per_decade=12, fmt=_money):
    """Horizontal log-scale bar chart for values spanning several orders of magnitude.

    `rows` is a list of (label, value), or (heading, None) for a category break.
    Linear bars would erase everything below the top decade, which is precisely the
    part of these ladders that carries the argument.
    """
    import math
    width = (hi_decade - lo_decade) * per_decade
    axis = "".join("|" + "-" * (per_decade - 1)
                   for _ in range(hi_decade - lo_decade)) + "|"
    ticks = ""
    for d in range(lo_decade, hi_decade + 1):
        tick = f"1e{d}" if not -3 <= d <= 5 else f"{10.0**d:,.0f}" if d >= 0 else f"{10.0**d:g}"
        ticks += tick.ljust(per_decade) if d < hi_decade else tick
    print(" " * label_width + ticks)
    print(" " * label_width + axis)
    for label, value in rows:
        if value is None:
            print(label)
            continue
        n = max(1, round((math.log10(value) - lo_decade) / (hi_decade - lo_decade) * width))
        print(f"  {label[:label_width - 4]:<{label_width - 2}}" + "#" * n + "  " + fmt(value))
    print(" " * label_width + axis)


# ================================================================ 1. price ladder
print("\n=== 1. Cost per Mbps-year of always-on delivery (one unidirectional copy) ===\n")
print(f"{'Option':<52}{'$/GB-equiv':>12}{'$/Mbps-yr':>12}{'x transit':>12}")
rule()
ladder = []
for name, tiers, unit in [
    ("AWS / Azure list, first tier", [(None, 0.09)], GIB),
    ("Azure premium backbone, first tier", [(None, 0.087)], GB),
    ("GCP premium, >10 TiB/mo", [(None, 0.08)], GIB),
    ("Azure transit routing, first tier", [(None, 0.08)], GB),
    ("AWS, >150 TB/mo marginal tier", [(None, 0.05)], GIB),
    ("Cloudflare MoQ, announced GA self-serve", CLOUDFLARE_MOQ, GB),
    ("GCP standard tier, >150 TiB/mo", [(None, 0.045)], GIB),
    ("Azure transit routing, >150 TB/mo", [(None, 0.04)], GB),
]:
    per_mbps_yr = annual_cost(1, tiers, unit)
    ladder.append((name, per_mbps_yr))
    print(f"{name:<52}{tiers[0][1]:>12.4f}{per_mbps_yr:>12,.0f}{per_mbps_yr / (TRANSIT_10GE * 12):>11,.0f}x")

for mbps, rate in sorted(MEDIACONNECT_RESERVED.items()):
    per_mbps_yr = rate * HOURS_YEAR / mbps
    name = f"MediaConnect reserved outbound, {mbps} Mbps tier"
    ladder.append((name, per_mbps_yr))
    print(f"{name:<52}{per_mbps_yr / volume(1, GB):>12.4f}{per_mbps_yr:>12,.0f}"
          f"{per_mbps_yr / (TRANSIT_10GE * 12):>11,.0f}x")

zixi_total = annual_cost(1, [(None, ZIXI_BROADCASTER)], GB) + annual_cost(1, [(None, 0.09)], GIB)
print(f"{'Zixi Broadcaster licence + AWS list egress':<52}{0.14:>12.4f}{zixi_total:>12,.0f}"
      f"{zixi_total / (TRANSIT_10GE * 12):>11,.0f}x")

for name, rate in [("IP transit, 10 GigE port, competitive hub", TRANSIT_10GE),
                   ("IP transit, 100 GigE port, competitive hub", TRANSIT_100GE)]:
    per_mbps_yr = rate * 12
    ladder.append((name, per_mbps_yr))
    print(f"{name:<52}{per_mbps_yr / volume(1, GB):>12.4f}{per_mbps_yr:>12,.2f}"
          f"{per_mbps_yr / (TRANSIT_10GE * 12):>11,.0f}x")

print(f"\nOne Mbps held for a year moves {volume(1, GB):,.0f} GB ({volume(1):,.0f} GiB).")

# ---- 1b. the same ladder grouped by who operates the infrastructure ----
print("\n--- Price ladder by category ($/GB delivered, log scale) ---\n")
log_bars([
    ("SELF-HOSTED (own the egress; transit and ports, unmetered per GB)", None),
    ("IP transit, 100 GigE port -- bandwidth only", TRANSIT_100GE * 12 / volume(1, GB)),
    ("IP transit, 10 GigE port -- bandwidth only", TRANSIT_10GE * 12 / volume(1, GB)),
    ("Illustrative all-in PoP, 60% utilised (10.1)", 0.0015),
    ("CLOUD (rent compute, pay metered egress, run your own software)", None),
    ("AWS / Azure / GCP list egress, first tier", 0.09),
    ("AWS / Azure / GCP, deepest volume tier", 0.045),
    ("VENDOR / MANAGED SERVICE (buy delivery as an outcome)", None),
    ("Zixi Broadcaster licence + AWS list egress", 0.14),
    ("Fastly CDN, list, North America", 0.12),
    ("AWS CloudFront, list, first tier NA/EU", 0.085),
    ("MediaConnect reserved, 50 Mbps tier", 0.052),
    ("Cloudflare MoQ relay, announced GA rate", 0.05),
    ("MediaConnect reserved, 1500 Mbps tier", 0.017),
    ("bunny.net CDN, standard network, NA/EU", 0.01),
    ("bunny.net CDN, volume network, <500 TB", 0.005),
    ("bunny.net CDN, volume network, 1-2 PB", 0.002),
], lo_decade=-4, hi_decade=0)

# ================================================================ 2. carriage
print("\n=== 2. Wire rate after carriage overhead and 1+1 ===\n")
print(f"{'TS profile':<14}{'MoQ wire':>12}{'SRT wire':>12}{'MoQ 1+1':>12}{'SRT 1+1':>12}{'MoQ vs SRT':>14}")
rule(76)
for ts in (10, 25):
    m, s = ts * MOQ_CARRIAGE, ts * SRT_CARRIAGE
    print(f"{ts:>2} Mbps{'':<7}{m:>9.2f} Mb{s:>9.2f} Mb{2*m:>9.2f} Mb{2*s:>9.2f} Mb"
          f"{(m/s - 1)*100:>12.1f} %")

# ================================================================ 3. one channel, one destination
print("\n=== 3. One channel, one destination, 1+1 active/active (annual USD) ===\n")


def diy_compute(feeds, sessions, ts_mbps, wire_mbps_per_leg, region="eu-west-1",
                itype="c6gn.large", target_util=0.6, moq=True):
    """Instances per leg, sized on cores and on sustained network baseline."""
    spec = EC2[itype]
    ingest = (MOQ_IMPORT_CORES_AT_10 if moq else SRT_CARRIAGE_CORES_AT_10) * (ts_mbps / 10)
    cores = feeds * ingest + (sessions * RELAY_CORE_PER_SESSION[ts_mbps] if moq else 0)
    by_cpu = cores / (spec["vcpu"] * target_util)
    by_net = (wire_mbps_per_leg / 1000) / (spec["net_baseline_gbps"] * target_util)
    n = max(1, -(-max(by_cpu, by_net) // 1))
    return int(n), spec[region] * int(n), cores, by_cpu, by_net


print(f"{'':<44}{'10 Mbps':>16}{'25 Mbps':>16}")
rule(76)
rows = {}
for ts in (10, 25):
    moq_wire, srt_wire = ts * MOQ_CARRIAGE, ts * SRT_CARRIAGE
    n_moq, comp_moq, *_ = diy_compute(1, 1, ts, moq_wire, moq=True)
    n_srt, comp_srt, *_ = diy_compute(1, 1, ts, srt_wire, moq=False)
    # Tier on the aggregate: volume discounts and the monthly free allowance accrue
    # per account, not per leg, so 1+1 is priced as one 2x volume.
    egress_moq = annual_cost(2 * moq_wire, AWS_DTO)
    egress_srt = annual_cost(2 * srt_wire, AWS_DTO)
    mc_flows = 2 * MEDIACONNECT_FLOW_HOUR * HOURS_YEAR
    mc_od = mc_flows + egress_srt
    mc_res = mc_flows + mediaconnect_egress(2 * srt_wire)
    cf = annual_cost(2 * moq_wire, CLOUDFLARE_MOQ, GB)
    rows[ts] = dict(
        moq_diy=egress_moq + 2 * comp_moq, srt_diy=egress_srt + 2 * comp_srt,
        mc_od=mc_od, mc_res=mc_res, cf=cf,
        egress_moq=egress_moq, egress_srt=egress_srt, comp_moq=2 * comp_moq,
        comp_srt=2 * comp_srt, n_moq=n_moq,
        zixi=egress_srt + 2 * comp_srt + annual_cost(2 * srt_wire, [(None, ZIXI_BROADCASTER)], GB),
        moq_azure=annual_cost(2 * moq_wire, AZURE_TRANSIT, GB),
        moq_gcp=annual_cost(2 * moq_wire, GCP_STANDARD),
        transit=2 * moq_wire * TRANSIT_10GE * 12,
        srt_transit=2 * srt_wire * TRANSIT_10GE * 12,
        cdn_moq=annual_cost(2 * moq_wire, CDN_MOQ_RELAY_ASSUMED, GB),
        cdn_moq_lo=annual_cost(2 * moq_wire, CDN_MOQ_RELAY_FLOOR, GB),
    )
for label, key in [("MoQ, DIY on EC2 (egress + reserved compute)", "moq_diy"),
                   ("  of which egress", "egress_moq"),
                   ("  of which compute", "comp_moq"),
                   ("SRT, DIY on EC2", "srt_diy"),
                   ("  of which egress", "egress_srt"),
                   ("  of which compute", "comp_srt"),
                   ("Zixi Broadcaster on EC2 (licence + egress)", "zixi"),
                   ("MediaConnect (SRT), on-demand egress", "mc_od"),
                   ("MediaConnect (SRT), cheapest reserved mix", "mc_res"),
                   ("MoQ on Cloudflare (announced GA rate)", "cf"),
                   ("MoQ, DIY on Azure transit routing", "moq_azure"),
                   ("MoQ, DIY on GCP standard tier", "moq_gcp"),
                   ("MoQ relay on CDN @ $0.010/GB (assumed)", "cdn_moq"),
                   ("MoQ relay on CDN @ $0.005/GB (assumed)", "cdn_moq_lo"),
                   ("MoQ self-hosted, transit only", "transit"),
                   ("SRT self-hosted, transit only", "srt_transit")]:
    print(f"{label:<44}{rows[10][key]:>16,.0f}{rows[25][key]:>16,.0f}")
print("\nReserved outbound bandwidth is a 12-month commitment sold in 50/150/500/1500 Mbps blocks,")
print("so at one channel the smallest block over-buys and on-demand per-GB wins.")

print("\n--- One channel, 1+1, one destination, by category (annual USD, log scale) ---\n")
log_bars([
    ("SELF-HOSTED (marginal transit only; excludes ports, facilities, staff, control plane)", None),
    ("SRT self-hosted on owned infrastructure", rows[10]["srt_transit"]),
    ("MoQ self-hosted on owned infrastructure", rows[10]["transit"]),
    ("CLOUD (own software on rented compute, metered egress)", None),
    ("MoQ, DIY on Azure transit routing", rows[10]["moq_azure"]),
    ("SRT, DIY on EC2", rows[10]["srt_diy"]),
    ("MoQ, DIY on EC2", rows[10]["moq_diy"]),
    ("VENDOR / MANAGED SERVICE", None),
    ("MoQ relay on CDN @ $0.005/GB (assumed)", rows[10]["cdn_moq_lo"]),
    ("MoQ relay on CDN @ $0.010/GB (assumed)", rows[10]["cdn_moq"]),
    ("MoQ on Cloudflare, announced rate", rows[10]["cf"]),
    ("MediaConnect (SRT), cheapest reserved", rows[10]["mc_res"]),
    ("Zixi Broadcaster on EC2", rows[10]["zixi"]),
], lo_decade=1, hi_decade=5, fmt=lambda v: f"{v:,.0f}")

print("\n--- One channel, 1+1, to N destinations (annual USD) ---\n")
print(f"{'Destinations':<14}{'MoQ wire':>12}{'AWS list':>12}{'Cloudflare':>12}"
      f"{'MC reserved':>13}{'$/dest':>10}")
rule(73)
for dests in (1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024):
    moq_wire = 10 * MOQ_CARRIAGE * 2 * dests
    srt_wire = 10 * SRT_CARRIAGE * 2 * dests
    aws = annual_cost(moq_wire, AWS_DTO) + 2 * EC2["c6gn.large"]["eu-west-1"]
    cf = annual_cost(moq_wire, CLOUDFLARE_MOQ, GB)
    mc = mediaconnect_egress(srt_wire) + 2 * MEDIACONNECT_FLOW_HOUR * HOURS_YEAR
    print(f"{dests:<14}{moq_wire:>9,.0f} Mb{aws:>12,.0f}{cf:>12,.0f}{mc:>13,.0f}{aws/dests:>10,.0f}")
print("\nCost is near-linear in destinations: unicast has no fan-out economy at the last hop, so")
print("'one to many' is 'one to one', N times. Per-destination cost halves over a thousandfold")
print("scale-up and then asymptotes at the deepest volume tier -- all of it from volume bands")
print("and amortising the fixed compute pair, none of it from the transport.")

# ================================================================ 4. transponder equivalence
print("\n=== 4. Transponder-equivalent multiplex ===\n")
TRANSPONDER_MBPS = 58.8      # EBU Tech Review 300: 36 MHz-class, DVB-S2 8PSK 2/3, 29.7 Mbaud
for statmux_avg in (5.9, 7.3, 9.8):
    print(f"  {TRANSPONDER_MBPS:.1f} Mbps useful / {statmux_avg:.1f} Mbps average HD service "
          f"= {TRANSPONDER_MBPS/statmux_avg:.1f} services")
CHANNELS = 8
print(f"\nModelled multiplex: {CHANNELS} HD services.\n")

print(f"{'Destinations':<14}{'Aggregate':>12}{'MC reserved':>14}{'Cloud 70% priv':>16}"
      f"{'CDN $0.010':>14}{'CDN $0.005':>14}{'Transit':>12}")
rule(96)
for dests in (1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024):
    moq_wire = CHANNELS * 10 * MOQ_CARRIAGE * 2 * dests
    srt_wire = CHANNELS * 10 * SRT_CARRIAGE * 2 * dests
    flows = 2 * CHANNELS * max(1, -(-dests // 20))   # a TS flow carries up to 20 outputs
    mc = mediaconnect_egress(srt_wire) + flows * MEDIACONNECT_FLOW_HOUR * HOURS_YEAR
    priv = annual_cost(moq_wire, AWS_DTO) * 0.30
    cdn = annual_cost(moq_wire, CDN_MOQ_RELAY_ASSUMED, GB)
    cdn_lo = annual_cost(moq_wire, CDN_MOQ_RELAY_FLOOR, GB)
    tr = moq_wire * TRANSIT_10GE * 12
    print(f"{dests:<14}{moq_wire:>9,.0f} Mb{mc:>14,.0f}{priv:>16,.0f}"
          f"{cdn:>14,.0f}{cdn_lo:>14,.0f}{tr:>12,.0f}")

marginal_moq = CHANNELS * 10 * MOQ_CARRIAGE * 2
print(f"\nMarginal cost of one more destination for the whole {CHANNELS}-service 1+1 multiplex "
      f"({marginal_moq:.1f} Mbps):")
for name, tiers, unit in [("AWS first tier", [(None, 0.09)], GIB),
                          ("AWS deepest tier", [(None, 0.05)], GIB),
                          ("Cloudflare MoQ, announced", CLOUDFLARE_MOQ, GB),
                          ("MediaConnect reserved 1500 Mbps tier",
                           [(None, MEDIACONNECT_RESERVED[1500] * HOURS_YEAR / 1500 / volume(1, GB))], GB),
                          ("CDN MoQ relay, assumed premium", CDN_MOQ_RELAY_ASSUMED, GB),
                          ("CDN MoQ relay, commodity floor", CDN_MOQ_RELAY_FLOOR, GB),
                          ("IP transit 10 GigE", [(None, TRANSIT_10GE * 12 / volume(1, GB))], GB)]:
    per_dest = annual_cost(marginal_moq, tiers, unit)
    print(f"  {name:<38}{per_dest:>12,.0f} /destination-yr   "
          f"(reaches parity per $1M/yr of incumbent cost at {1_000_000/per_dest:>5.1f} destinations)")

# Enterprise procurement is the largest single lever on the dominant line, so model it
# as a ladder of hypothetical discounts off first-tier list rather than a single guess.
print("\n--- Procurement: hypothetical discount off first-tier list egress ---\n")
print(f"{'Discount':<12}{'$/GiB':>10}{'$/destination-yr':>20}{'Destinations to parity per $1M/yr':>36}")
rule(78)
for pct in range(0, 100, 5):
    rate = 0.09 * (1 - pct / 100)
    per_dest = annual_cost(marginal_moq, [(None, rate)])
    label = "list" if pct == 0 else f"{pct} %"
    print(f"{label:<12}{rate:>10.4f}{per_dest:>20,.0f}{1_000_000/per_dest:>36,.0f}")

# ================================================================ 5. sizing constraint
for dests in range(1, 200):
    w = CHANNELS * 10 * MOQ_CARRIAGE * 2 * dests
    if annual_cost(w, AWS_DTO) < annual_cost(w, CLOUDFLARE_MOQ, GB):
        print(f"\nA flat $0.05/GB stops winning at {dests} destinations ({w:,.0f} Mbps, "
              f"{volume(w, GB)/12/1000:,.0f} TB/month), where AWS's tiered bands undercut it.")
        break

print("\n=== 5. What binds the relay: cores or the instance's network allowance ===\n")
print(f"{'Instance':<14}{'vCPU':>6}{'Baseline':>11}{'CPU-limited':>14}{'Net-limited':>14}{'Binds':>10}")
rule(69)
for itype, spec in EC2.items():
    cpu_gbps = spec["vcpu"] * 1.1                      # T9: ~1.1 Gbps per core at 10 Mbps
    binds = "network" if spec["net_baseline_gbps"] < cpu_gbps else "cores"
    print(f"{itype:<14}{spec['vcpu']:>6}{spec['net_baseline_gbps']:>9.3f} G"
          f"{cpu_gbps:>12.2f} G{spec['net_baseline_gbps']:>12.2f} G{binds:>10}")
print(f"\nSessions purchasable per instance at 10 Mbps of MoQ wire rate "
      f"({10 * MOQ_CARRIAGE:.1f} Mbps each):")
for itype, spec in EC2.items():
    by_cpu = spec["vcpu"] / RELAY_CORE_PER_SESSION[10]
    by_net = spec["net_baseline_gbps"] * 1000 / (10 * MOQ_CARRIAGE)
    print(f"  {itype:<14}{by_cpu:>6.0f} by CPU{by_net:>8.0f} by network baseline "
          f"-> {min(by_cpu, by_net):.0f} usable")

# ================================================================ 6. sensitivity
print("\n=== 6. Egress price sensitivity, 8 services x 1+1 x 4 destinations ===\n")
wire = CHANNELS * 10 * MOQ_CARRIAGE * 2 * 4
print(f"Wire rate {wire:,.0f} Mbps, {volume(wire, GB)/1000:,.0f} TB/yr\n")
SENSITIVITY = [
    (0.09,    "cloud first-tier list"),
    (0.07,    ""),
    (0.05,    "cloud deepest published tier; Cloudflare announced MoQ rate"),
    (0.017,   "MediaConnect reserved, 1500 Mbps tier"),
    (0.010,   "commodity CDN list, standard network"),
    (0.005,   "commodity CDN list, volume network"),
    (0.002,   "commodity CDN list, 1-2 PB tier"),
    (0.001,   "ILLUSTRATIVE self-hosted all-in at high utilisation"),
    (0.00021, "wholesale transit bandwidth ONLY -- not a delivery rate"),
    (0.00010, "below anything observed; shows the floor is asymptotic"),
]
print(f"{'Egress price ($/GB)':<22}{'Annual egress':>15}{'vs list':>10}  What this rate is")
rule(110)
base = annual_cost(wire, [(None, 0.09)], GB)
for price, note in SENSITIVITY:
    c = annual_cost(wire, [(None, price)], GB)
    print(f"{price:<22.5f}{c:>15,.0f}{c/base:>9.1%}  {note}")

# The transit floor is the number most likely to be misread as a negotiable rate, so the
# derivation and an all-in counter-example are printed alongside it rather than left implicit.
print("\n--- Where the transit floor comes from (cost-model.md 10.1) ---\n")
gb_per_mbps_year = volume(1, GB)
for label, per_mbps_mo in (("10 GigE port", TRANSIT_10GE), ("100 GigE port", TRANSIT_100GE)):
    yr = per_mbps_mo * 12
    print(f"  {label:<16}${per_mbps_mo}/Mbps/mo -> ${yr:.2f}/Mbps-yr / "
          f"{gb_per_mbps_year:,.0f} GB = ${yr / gb_per_mbps_year:.6f}/GB")
print("\n  Wholesale bandwidth at 100% port utilisation. NOT an egress rate, NOT a CDN rate,")
print("  and NOT a discount obtainable on either. Illustrative all-in for a 10 Gbps PoP:\n")
POP_TRANSIT = 10_000 * TRANSIT_10GE * 12
POP_LINES = [("Transit, 10 Gbps committed", POP_TRANSIT),
             ("Second transit provider (diversity)", POP_TRANSIT),
             ("Colocation, power, cross-connects [illustrative]", 15_000),
             ("Hardware, 2 servers over 4 years [illustrative]", 4_000)]
pop_total = sum(v for _, v in POP_LINES)
for label, v in POP_LINES:
    print(f"    {label:<50}{v:>10,.0f}")
print(f"    {'TOTAL':<50}{pop_total:>10,.0f}\n")
for util in (1.0, 0.6, 0.4, 0.25):
    delivered = 10_000 * gb_per_mbps_year * util
    print(f"    at {util:>4.0%} average utilisation -> ${pop_total / delivered:.4f}/GB")
print("\n  So a realistic self-hosted operation lands at $0.001-0.004/GB -- 4-17x the")
print("  bandwidth-only floor, and in the same band as commodity CDN volume pricing.")
print("\nAWS volumes above are billed in GiB (its tier boundaries are binary: 10 TB = 10,240 GB).")
print(f"On a decimal-GB reading every AWS figure rises by {GIB/GB - 1:.1%}.")

# ================================================================ 7. MoQ vs SRT delta
print("\n=== 7. Where relay fan-out actually changes the bill ===\n")
print("Fan-out to N off-cloud receivers costs N copies of internet egress either way; a relay")
print("changes only the hops *before* the last one. For the 8-service 1+1 multiplex:\n")
per_leg = CHANNELS * 10 * MOQ_CARRIAGE * 2
for dests in (2, 4, 8, 16):
    naive = dests * annual_cost(per_leg, [(None, AWS_INTERREGION)])
    relayed = annual_cost(per_leg, [(None, AWS_INTERREGION)])
    print(f"  {dests:>2} receivers in one remote region: inter-region backhaul "
          f"{naive:>10,.0f} -> {relayed:>9,.0f}  (saves {naive - relayed:,.0f})")
print(f"\nThe origin uplink also carries {CHANNELS * 2} streams once rather than once per receiver,")
print("which is a contribution-link sizing saving rather than a cloud invoice line.")

print(f"\n=== 8. What the {MOQ_CARRIAGE}x vs {SRT_CARRIAGE}x carriage difference costs ===\n")
print("Negative = MoQ cheaper, because it does not carry the source's null stuffing.")
print(f"{'Scenario':<44}{'Delta $/yr':>13}{'Delta %':>10}")
rule(67)
for label, chans, dests, ts in [("1 channel, 1 destination, 10 Mbps", 1, 1, 10),
                                ("1 channel, 1 destination, 25 Mbps", 1, 1, 25),
                                ("8 channels, 4 destinations, 10 Mbps", 8, 4, 10),
                                ("8 channels, 16 destinations, 10 Mbps", 8, 16, 10)]:
    m = chans * ts * MOQ_CARRIAGE * 2 * dests
    s = chans * ts * SRT_CARRIAGE * 2 * dests
    cm, cs = annual_cost(m, AWS_DTO), annual_cost(s, AWS_DTO)
    print(f"{label:<44}{cm-cs:>13,.0f}{(cm/cs - 1):>9.1%}")
print()

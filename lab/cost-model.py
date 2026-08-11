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
MOQ_CARRIAGE = 1.12              # T9: IP wire bytes / source TS rate
SRT_CARRIAGE = 1360 / 1316       # derived: 7x188 TS + 16 SRT + 8 UDP + 20 IPv4
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

# ================================================================ 2. carriage
print("\n=== 2. Wire rate after carriage overhead and 1+1 ===\n")
print(f"{'TS profile':<14}{'MoQ wire':>12}{'SRT wire':>12}{'MoQ 1+1':>12}{'SRT 1+1':>12}{'MoQ penalty':>14}")
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
                   ("MoQ wire rate at IP transit list price", "transit")]:
    print(f"{label:<44}{rows[10][key]:>16,.0f}{rows[25][key]:>16,.0f}")
print("\nReserved outbound bandwidth is a 12-month commitment sold in 50/150/500/1500 Mbps blocks,")
print("so at one channel the smallest block over-buys and on-demand per-GB wins.")

print("\n--- One channel, 1+1, to N destinations (annual USD) ---\n")
print(f"{'Destinations':<14}{'MoQ wire':>12}{'AWS list':>12}{'Cloudflare':>12}"
      f"{'MC reserved':>13}{'$/dest':>10}")
rule(73)
for dests in (1, 2, 4, 8, 16):
    moq_wire = 10 * MOQ_CARRIAGE * 2 * dests
    srt_wire = 10 * SRT_CARRIAGE * 2 * dests
    aws = annual_cost(moq_wire, AWS_DTO) + 2 * EC2["c6gn.large"]["eu-west-1"]
    cf = annual_cost(moq_wire, CLOUDFLARE_MOQ, GB)
    mc = mediaconnect_egress(srt_wire) + 2 * MEDIACONNECT_FLOW_HOUR * HOURS_YEAR
    print(f"{dests:<14}{moq_wire:>9,.0f} Mb{aws:>12,.0f}{cf:>12,.0f}{mc:>13,.0f}{aws/dests:>10,.0f}")
print("\nCost is near-linear in destinations: unicast has no fan-out economy at the last hop, so")
print("'one to many' is 'one to one', N times. Per-destination cost falls only ~23% over a")
print("16-fold scale-up, from volume tiers and amortising the fixed compute pair.")

# ================================================================ 4. transponder equivalence
print("\n=== 4. Transponder-equivalent multiplex ===\n")
TRANSPONDER_MBPS = 58.8      # EBU Tech Review 300: 36 MHz-class, DVB-S2 8PSK 2/3, 29.7 Mbaud
for statmux_avg in (5.9, 7.3, 9.8):
    print(f"  {TRANSPONDER_MBPS:.1f} Mbps useful / {statmux_avg:.1f} Mbps average HD service "
          f"= {TRANSPONDER_MBPS/statmux_avg:.1f} services")
CHANNELS = 8
print(f"\nModelled multiplex: {CHANNELS} HD services.\n")

print(f"{'Destinations':<14}{'Aggregate':>12}{'AWS DTO':>14}{'AWS deep':>14}"
      f"{'MC reserved':>14}{'Cloudflare':>14}{'Transit':>12}")
rule(94)
for dests in (1, 2, 4, 8, 16, 32):
    moq_wire = CHANNELS * 10 * MOQ_CARRIAGE * 2 * dests
    srt_wire = CHANNELS * 10 * SRT_CARRIAGE * 2 * dests
    aws = annual_cost(moq_wire, AWS_DTO)
    deep = annual_cost(moq_wire, [(None, 0.05)])
    flows = 2 * CHANNELS * max(1, -(-dests // 20))   # a TS flow carries up to 20 outputs
    mc = mediaconnect_egress(srt_wire) + flows * MEDIACONNECT_FLOW_HOUR * HOURS_YEAR
    cf = annual_cost(moq_wire, CLOUDFLARE_MOQ, GB)
    tr = moq_wire * TRANSIT_10GE * 12
    print(f"{dests:<14}{moq_wire:>9,.0f} Mb{aws:>14,.0f}{deep:>14,.0f}{mc:>14,.0f}{cf:>14,.0f}{tr:>12,.0f}")

marginal_moq = CHANNELS * 10 * MOQ_CARRIAGE * 2
print(f"\nMarginal cost of one more destination for the whole {CHANNELS}-service 1+1 multiplex "
      f"({marginal_moq:.1f} Mbps):")
for name, tiers, unit in [("AWS first tier", [(None, 0.09)], GIB),
                          ("AWS deepest tier", [(None, 0.05)], GIB),
                          ("Cloudflare announced", CLOUDFLARE_MOQ, GB),
                          ("MediaConnect reserved 1500 Mbps tier",
                           [(None, MEDIACONNECT_RESERVED[1500] * HOURS_YEAR / 1500 / volume(1, GB))], GB),
                          ("IP transit 10 GigE", [(None, TRANSIT_10GE * 12 / volume(1, GB))], GB)]:
    per_dest = annual_cost(marginal_moq, tiers, unit)
    print(f"  {name:<38}{per_dest:>12,.0f} /destination-yr   "
          f"(reaches parity per $1M/yr of incumbent cost at {1_000_000/per_dest:>5.1f} destinations)")

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
print("\nSessions purchasable per instance at 10 Mbps of MoQ wire rate (11.2 Mbps each):")
for itype, spec in EC2.items():
    by_cpu = spec["vcpu"] / RELAY_CORE_PER_SESSION[10]
    by_net = spec["net_baseline_gbps"] * 1000 / (10 * MOQ_CARRIAGE)
    print(f"  {itype:<14}{by_cpu:>6.0f} by CPU{by_net:>8.0f} by network baseline "
          f"-> {min(by_cpu, by_net):.0f} usable")

# ================================================================ 6. sensitivity
print("\n=== 6. Egress price sensitivity, 8 services x 1+1 x 4 destinations ===\n")
wire = CHANNELS * 10 * MOQ_CARRIAGE * 2 * 4
print(f"Wire rate {wire:,.0f} Mbps, {volume(wire, GB)/1000:,.0f} TB/yr\n")
print(f"{'Egress price ($/GB)':<24}{'Annual egress':>16}{'vs AWS list':>14}")
rule(54)
for price in (0.09, 0.07, 0.05, 0.017, 0.0085, 0.0002):
    c = annual_cost(wire, [(None, price)], GB)
    base = annual_cost(wire, [(None, 0.09)], GB)
    print(f"{price:<24.4f}{c:>16,.0f}{c/base:>13.1%}")
print("\n0.017 = MediaConnect reserved at the 1500 Mbps tier; 0.0085 = OCI-class list rate;")
print("0.0002 = IP transit at $0.07/Mbps/month expressed per GB.")
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

print("\n=== 8. What the 1.12x vs 1.033x carriage difference costs ===\n")
print(f"{'Scenario':<44}{'Extra $/yr':>13}{'Extra %':>10}")
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

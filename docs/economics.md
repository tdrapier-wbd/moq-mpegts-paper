# Economics

Status: working draft
Scope: a cost *framework and methodology* for comparing an Internet-native MoQ
distribution path against incumbent primary-distribution methods. This is the
companion to the economic risk raised in the [README](../README.md).

> **Confidentiality note.** This document deliberately contains **no specific
> figures** — no route costs, transponder lease rates, cloud egress prices,
> customer pricing, or vendor contract terms. Those are commercially sensitive
> and/or route-specific, and publishing them here would be both a disclosure risk
> and technically misleading (the numbers only mean something in the context of a
> specific deployment). What follows is the *structure* of the comparison and the
> *questions* a real model must answer, so that anyone with access to real inputs
> can populate it. The headline conclusions below are directional, not numeric.

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
   comparison misses (§4).

The position this document argues toward, stated as a hypothesis rather than a
result: always-on trunk is the *hardest* case, but **achievable rather than
permanently lost** — *if* incumbent capacity retires and egress pricing falls on
the horizon assumed here. That "if" is doing real work: both premises are
forecasts, and a depreciated transponder or committed fibre route can stay
cheapest for years. The case is **clearer for dynamic, short-lived, long-tail, or
global-reach-on-demand routes**, where the incumbent's fixed-cost model fits
worst. None of this is settled without the real numbers §8 asks for; the analysis
*leans* "plausibly economic for trunk over time, better suited to dynamic routes
now" — a direction to test, not a conclusion to rely on.

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

- **Compute / relay cost.** Relay fabric compute, scaling with forwarded
  bandwidth and connection count ([relay](relay.md) §6). Shared across tenants,
  which is where multi-tenant leverage helps (§4).
- **Egress / network cost.** Data transfer out of cloud/CDN networks. **This is
  the line most likely to dominate and to swing the entire comparison.** Because
  primary distribution is always-on and high-bitrate, egress-priced networks can
  make the model unattractive quickly; egress terms therefore deserve the most
  scrutiny and the most sensitivity analysis (§6).
- **Operations and support.** 24/7 NOC, on-call, and incident response to the
  broadcast standard ([operations](operations.md) §8). This is a real,
  substantial, and often underestimated cost, and it does not shrink just because
  the transport is cheaper.
- **Tooling and monitoring.** Observability, TR 101 290 probing, audit — build or
  buy ([operations](operations.md) §3).
- **Integration and grooming.** The edge/interop work that makes output
  IRD-acceptable ([interoperability](interoperability.md), [architecture](architecture.md)
  §7). One-time and ongoing.

## 4. Value drivers (beyond unit cost)

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

## 5. Scenario analysis

The comparison inverts across scenarios, which is the central insight:

- **Always-on linear trunk feeds.** The hardest case, and the one to model first —
  but achievable rather than lost. Steady high-bitrate demand is where egress cost
  bites hardest and where depreciated satellite / committed fibre is cheapest
  *today*, so the challenger's case here rests on the horizon over which incumbent
  capacity is retired and egress pricing falls, and on the substrate, operational,
  and reach advantages, more than on day-one sticker price. The elasticity
  advantage is worth little here; the rest of the case carries it.
- **Event / occasional / short-window feeds.** Challenger-favoured. No committed
  capacity, fast provisioning, and pay-for-use align with the demand shape; the
  incumbent's fixed-cost model is poorly suited.
- **Single-region vs global distribution.** Global, dynamic reach favours the
  challenger (reach-on-demand without global procurement); dense single-region
  fan-out to many endpoints favours satellite's near-free broadcast fan-out.

## 6. Sensitivity analysis

The model's output is dominated by a small number of inputs; a credible analysis
must show how the conclusion moves as each varies:

- **Bandwidth / egress cost.** The dominant sensitivity. The break-even is likely
  set here more than anywhere else; the model should show the egress price at
  which the challenger reaches parity for each scenario.
- **Redundancy level.** End-to-end disjoint-path redundancy roughly doubles
  transport/egress cost ([architecture](architecture.md) §14). The comparison must
  hold redundancy *equivalent* on both sides, or it is meaningless.
- **SLA / staffing.** The 24/7 operational cost is comparatively fixed and can
  dominate at low route counts; it amortises only as the route/tenant count grows.

## 7. Commercial packaging options

Stated generically, without terms or pricing:

- **Managed service** — the platform operates the distribution; the customer buys
  an outcome. Highest operational cost to the provider, highest trust bar.
- **Software / OEM** — the capability is licensed to an operator or vendor who
  runs it. Lower operational burden, different margin structure.
- **Hybrid** — control plane as a service over customer- or partner-operated data
  plane; matches the transport-swappable hedge ([transport](transport.md) §5.2).

## 8. Evidence required

To move any conclusion here from "directional" to "established," the model needs:

- **Real route inputs from a design partner** — actual bitrates, redundancy,
  reach, and the *depreciated marginal* cost of the incumbent path they would
  displace (not list price).
- **Measured egress and compute cost** for an equivalent-redundancy MoQ path on a
  real provider.
- **A fully-loaded operational cost** for both sides to the same SLA
  ([operations](operations.md) §10).
- **Third-party validation** of the reliability equivalence that the whole
  comparison presupposes ([interoperability](interoperability.md) §9).

## 9. Decision thresholds

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

## 10. Open questions

- What is the real TCO delta versus one broadcaster's *actual, depreciated* route
  costs — the single most important unanswered economic question (shared with the
  [README](../README.md) open questions)?
- At what egress price and tenant/route scale does the always-on trunk case reach
  parity and then advantage, and how quickly is that point arriving as incumbent
  capacity is retired and egress pricing falls?
- How much of the "operational saving" hypothesis (§4) is real once the cost of
  running an immature platform to a broadcast SLA is included?

# The Problem, and What a Successor Must Do

Status: working draft.
Layer: **the requirement** — what Internet-native primary distribution has to do, before any data
plane is chosen.

This document states the problem, why the incumbent architectures solved it well, what is eroding
them, and — in §5 — the numbered requirement set that every later document is scored against. It
deliberately does not name a protocol until the requirements are fixed. Primary distribution has been
re-architected before (analogue to digital, ASI to IP, SDI to ST 2110) and each time the transport
was the least interesting part of the transition: what changed the industry was the operating model
the transport made possible.

Claims here are marked *established*, *likely* or *uncertain*. Nothing in this document is a
measurement; the measurements are in [Evidence](evidence.md).

---

## 1. What primary distribution is

**Primary distribution is the trunk of linear television: a small number of extremely high-value
feeds moved from a playout or origination facility to a set of *known, contracted* endpoints** —
affiliate stations, cable and DTH headends, OTT origin/packaging facilities, partner broadcasters.

Two adjacent problems are frequently conflated with it. **Contribution** moves signals *toward*
origination — venue, remote camera or bureau back to production — and is few-to-one or few-to-few
with a different latency and cost envelope. **Distribution** (OTT/ABR, DTT, DTH to the home) moves
the signal to the *consumer*: massively fan-out, best-effort, optimised for reach and per-stream cost
rather than contractual determinism.

Primary distribution sits between them, and its defining characteristics have been stable for
decades (*established*). They are numbered here because the requirement set in §5 refers back to
them.

**§1.1 — Determinism dominates.** The expectation is not "high availability" in the web sense but
something closer to "never fails visibly during contracted content". A dropped feed during a
tier-one sporting event is a breach, not an incident to apologise for on a status page.

**§1.2 — The endpoints are professional and long-lived.** Hardware IRDs, professional decoders and
ASI/SDI plant are capital equipment with a five-to-fifteen-year service life. They enforce
TR 101 290 P1/P2 conformance, lock phase-locked loops to the transport stream's programme clock
reference (PCR), and expect MPEG-2 transport stream semantics: stable PMT PIDs, SDT service
identity, SCTE-35 splice signalling, teletext and subtitling, monotonic continuity counters.

**§1.3 — Trust and accountability are first-class.** Buyers optimise for "never fails" and for a
counterparty contractually accountable when it does — hence long sales cycles, heavy procurement, and
incumbents that stay sticky well beyond the point where a challenger is technically competitive.

**§1.4 — The topology is one-to-many but not internet-scale.** A national feed may fan out to tens or
hundreds of endpoints, sometimes low thousands, not millions, so the properties that make a transport
excellent at consumer-scale fan-out are not automatically the ones that matter here.

**§1.5 — A distributor no longer supplies its clients' receiving equipment.** This one is newer and
decides more than it looks (*established*). The era of shipping an IRD to every affiliate is over — the
receive estate is the client's capex and the client's choice. What survives from that era is the
*contract*: a conformant transport stream, correctly paced, over ASI or IP, at an agreed demarcation
point. This is developed in [Comparison](comparison.md) §4.1, where it
turns out to determine which side of the demarcation the expensive engineering falls on.

---

## 2. Why the incumbents succeeded

Each incumbent solved the determinism problem in a way that matched the technology and economics of
its era, and each retains properties that are genuinely difficult to replicate.

**Satellite** is a physical-layer broadcast medium: one uplink illuminates a footprint, and every
receiver within it sees the same signal at essentially the same time. That yields intrinsic
one-to-many economics (the marginal cost of an additional receiver is close to zero), independence
from terrestrial networks (immunity to congestion, BGP events and inter-region fibre cuts), and
dedicated, capacity-reserved delivery. Its weaknesses are equally structural: half-second
geostationary round trips, a widening disadvantage as terrestrial paths improve; rain fade;
capital-intensive provisioning; footprint rigidity; and the spectrum and fleet-economics pressure in
§3.6.

**Leased fibre and MPLS-based managed IP** (ST 2022-7 hitless redundancy, RTP/FEC, engineered
class-of-service) brought lower latency and more flexible capacity than satellite. Their determinism
is contractual and engineered: reserved-bandwidth label-switched paths with strict QoS, on a private
overlay whose failure domains and security posture sit with a single operator, directly compatible
with the IP plant broadcasters were already building internally. Their weaknesses are cost and
agility: a new managed route is a procurement exercise measured in weeks or months, capacity is
priced for dedicated use, and reach is bounded by carrier footprint and peering.

**The common thread**, and the fact to carry through everything that follows: all of them succeed by
*engineering determinism into a dedicated or managed layer and charging for that determinism*. The
buyer is not paying for bandwidth but for the guarantee. **Any Internet-native successor is, from the
buyer's perspective, proposing to move the guarantee from a managed layer onto a best-effort
substrate.** That is a trust problem before it is a technology problem, and it is why a technically
superior transport does not automatically win.

---

## 3. What is changing

**The incumbent model is not failing on its technical merits — it is being eroded by pressures
largely exogenous to the transport itself.**

**3.1 Cloud adoption in the media plant** (*established*). Production, playout, origination and OTT
packaging have moved decisively into cloud and cloud-adjacent infrastructure, so primary distribution
is frequently the *outlier*: software-defined and API-driven on every side but still a physical or
carrier-managed procurement itself. Every hand-off between a software-defined domain and a manually
provisioned one adds latency, error and operational cost. The pressure is not "cloud is cheaper"
(contested, §3.6); it is that the *shape* of distribution no longer matches the shape of everything
it connects to.

**3.2 Operational agility** (*established*). Pop-up channels, event-scoped feeds, short-term rights
windows and rapid partner onboarding are routine commercial requests, and distribution is
increasingly expected to expose the same APIs and infrastructure-as-code primitives as the rest of
the plant. An architecture whose unit of change is a multi-week provisioning ticket cannot serve a
business whose unit of change is a same-day commercial decision.

**3.3 Shrinking linear revenues** (*established*). Leased transponders and managed fibre were
justified against large, stable linear revenues; as viewing migrates to direct-to-consumer streaming,
the fixed cost of dedicated capacity becomes a larger and more scrutinised fraction of a declining
pie. Linear will not disappear — news, sport and regulated public-service content persist for years —
but its cost base must shrink in step. This is the structural pressure most likely to force change
even without a compelling technical alternative.

**3.4 Global, dynamic rights** (*likely*). A rights holder may need to deliver a feed to partners
across several continents for a single event, then tear the whole topology down. Satellite footprints
are geographically rigid and managed-fibre reach is bounded by carrier footprint, whereas the public
Internet *reaches everywhere a data centre reaches*. The pressure is reach-on-demand: global topology
without global procurement.

**3.5 A commodity software-defined substrate** (*established*). Mature QUIC/HTTP-3 stacks operated at
global scale by CDNs and hyperscalers mean the *substrate* for an Internet-native fabric now exists
as a commodity. A decade ago "distribute broadcast over the Internet" meant building the network;
today the network is there, and the open question is the layer above it.

**3.6 Changing economics** (*uncertain*, and the naive version is wrong). Spectrum and fleet
economics move against satellite over a long horizon — C-band reallocation, more selective
replacement-fleet investment, a finite depreciation runway. But **"cloud is cheaper than satellite"
is not established.** The always-on case is modelled at published list prices in
[Economics](economics.md), and two findings from that model bound the optimism:

- Unicast IP cost is **linear in destinations** where satellite fan-out inside the footprint is free,
  so destination count — not bitrate, and nothing a transport can influence — decides the comparison.
  Every candidate is unicast at the last mile, and a MoQ relay is a cache rather than an exception.
- Published cloud egress sits about an order of magnitude above what the same delivery costs on a
  commodity CDN or, costed all-in, on owned infrastructure — which makes this a question about
  commercial terms rather than engineering.

The durable driver is therefore not unit cost today but the mismatch between a *fixed, provisioned*
cost model and a business that increasingly needs a *variable, on-demand* one.

---

## 4. Why Internet-native is the likely direction

**Internet-native distribution is the cleanest long-run fit for the combined §3 pressures — not the
only option, and a claim about eventual outcome rather than timing** (*likely*). Those pressures are
not independent: each pushes distribution toward a layer that is programmable, globally reachable and
priced with use, and the substrate for such a layer now exists as a commodity.

It is not the *only* resolution. An API-driven control plane over *existing managed IP*
(MediaConnect-class services, orchestrated MPLS/SRT) narrows the same mismatch without a
public-Internet data plane, and may clear the trust bar sooner.

The conclusion is not that satellite and managed fibre disappear, but that the *marginal* new route —
and eventually the marginal re-provisioned route — increasingly lands on an Internet-native path,
with the installed base migrating through attrition as dedicated capacity is not renewed rather than
by a single switch-off. What is uncertain is the *rate*, set by how quickly the successor layer earns
the guarantee the incumbent already provides.

---

## 5. The requirement set

Everything downstream is scored against this list. It merges the characteristics of §1, the transport
properties primary distribution imposes, and the contract the installed base enforces. **R1–R4 are
transport requirements; R5–R9 sit above the transport and are required whichever data plane is
chosen** — which is the observation the rest of this repository turns out to be about.

| # | Requirement | Why | Where it is assessed |
|---|---|---|---|
| **R1** | **Bounded, stable latency.** Sub-second is desirable; for most primary distribution a few seconds is tolerable — but the budget must be bounded and stable, because a drifting buffer is itself a fault for downstream playout and ad insertion. "Tolerable" has to be answered per route, not once: a geostationary path delivers a fraction of a second, and a 2–5 s replacement consumes most of a downstream budget that was previously free, at every destination. | §1.1, §1.2 | [Comparison](comparison.md) §5, [Evidence](evidence.md) §3.11 |
| **R2** | **Graceful behaviour under loss and congestion.** The transport must degrade predictably rather than stall, and must not convert a single lost packet into a multi-second gap. | §2 (best-effort substrate) | [Comparison](comparison.md) §3, [Evidence](evidence.md) §3.3 |
| **R3** | **Faithful carriage of MPEG-2 transport streams.** Service identity (SDT), programme structure (PMT PIDs), SCTE-35 splice signalling, teletext/subtitling and continuity must survive transit intact. A transport that silently discards or reorders these is unusable for the installed base regardless of its performance. | §1.2 | [Comparison](comparison.md) §8, [Evidence](evidence.md) §3.1 |
| **R4** | **A fan-out model.** One-to-many to tens or hundreds of endpoints, sometimes low thousands, without publisher-side replication or a per-endpoint tunnel the operator must run. | §1.4 | [Comparison](comparison.md) §2 |
| **R5** | **IRD-conformant egress.** A conformant MPEG-2 transport stream over the supported interface (RTP/UDP, frequently multicast), TR 101 290 P1/P2 conformant — above all conformant PCR timing — with stable service signalling and, where the facility uses it, ST 2022-7 dual-path input. **No Internet-native transport delivers this without an edge stage**, and because the distributor does not supply the receiver, that stage sits on the distributor's side of the demarcation. | §1.2, §1.5 | [Architecture](architecture.md) §4, [Evidence](evidence.md) §3.2 |
| **R6** | **Engineered redundancy meeting "no visible failure during contracted content".** In practice 1+1 with hitless selection at the receiver, because that is what the installed base already implements. | §1.1 | [Architecture](architecture.md) §5, [Evidence](evidence.md) §3.4 |
| **R7** | **Dynamic, revocable entitlement.** A feed reaches an endpoint only while that endpoint holds a valid grant, with a bounded worst-case revocation time — so rights windows, partner onboarding and emergency takedown are control-plane operations rather than manual receiver reconfiguration. | §3.2 | [Control](control-plane.md) |
| **R8** | **Observability in broadcast terms.** Signal conformance, error seconds and PCR integrity, correlatable with systems-domain telemetry, so a broadcast NOC can operate the platform without adopting a new vocabulary. | §1.3 | [Architecture](architecture.md) §8 |
| **R9** | **A stability horizon compatible with broadcast planning**, or an architecture that isolates the value layers from transport churn so instability is a manageable dependency rather than a fatal one. | §1.3 | [Architecture](architecture.md) §9 |

Two notes on how this list is used.

**R5 is the requirement this repository spends most of its effort on**, and it is the one neither
candidate specification addresses. The HLS document contains zero occurrences of PCR, constant bit
rate, stuffing or null packet; MoQ has no notion of them either. That is not a criticism of either —
it is the boundary of what a transport specification is for — but it means R5 is *built*, on either
data plane.

**R1 and R5 may not be independent.** The edge stage that satisfies R5 buys its PCR conformance with
buffer depth, and buffer depth is latency. Whether a route can satisfy both at once is measured at
two points and unresolved between them ([Evidence](evidence.md) §3.2, §5).

---

## 6. What must be true

**The direction in §4 holds only if a small number of conditions hold. If any fails, the conclusion
changes.** These are the conditions the rest of the repository exists to test.

- **The reliability bar can be met on a best-effort substrate.** Part of this now has evidence: loss
  resilience matches SRT once the congestion controller is chosen correctly, and a doubled chain with
  receiver-side selection is hitless against a reference receiver ([Evidence](evidence.md) §3.3,
  §3.4). The hardware-IRD conformance pass remains open, and it is the make-or-break gate.
- **The transport stabilises on a timeline compatible with broadcast planning** — or the architecture
  isolates the value layers from transport churn (R9).
- **The economics work on some real, identifiable class of routes.** Most likely dynamic, short-lived
  or long-tail routes first. Trunk routes are contested rather than lost: the modelling in
  [Economics](economics.md) §4 puts a transponder's worth of channels to several hundred destinations
  in contention *today*, provided the delivery is bought in a commodity market rather than at metered
  hyperscaler rates.
- **Relay capacity becomes something a buyer can shop.** The cost case treats relays as a commodity
  procurable from more than one supplier. Measured today a feed traverses only relays from the
  publisher's own implementation ([Evidence](evidence.md) §3.7), so this is a precondition rather
  than a property — and the one most directly in the project's own control, since it is an
  interoperability problem before it is a commercial one.
- **The value layer is genuinely defensible.** Since the transport commoditises, durable value must
  accrue in the control-plane, entitlement, egress-interop and observability layers. Two things
  qualify this. The control-plane market is crowded — MediaConnect, Zixi and LTN all ship capable
  management planes — so occupying the layer is necessary and not sufficient. And **the layer is
  itself almost entirely unbuilt and unmeasured in this work** ([Control](control-plane.md) states
  this at the top), which is the largest untested assumption in the thesis and is not of the same
  kind as the engineering gaps.
- **A route exists that needs sub-second delivery.** This is the condition on which MoQ
  *specifically*, rather than Internet-native distribution generally, depends — and it is now the *only*
  condition, because the capability itself has stopped being in doubt: MoQ delivers a picture across the
  public internet in 109 ms against segmented HTTP's 4,067 ms over the same path
  ([Evidence](evidence.md) §3.11). Every other axis on which the two data planes differ favours segmented
  HTTP, so if no real route needs sub-second delivery then MoQ addresses a preference rather than a
  requirement, whatever its measured margin ([Comparison](comparison.md) §5).

---

## 7. Where this goes next

[Comparison](comparison.md) evaluates the two candidate Internet-native data planes — MoQ, and
segmented HTTP carrying MPEG-TS — against R1–R4, and against the point-to-point incumbents.
[Architecture](architecture.md) develops R5, R6, R8 and R9, which is where nearly all the measured
work sits. [Evidence](evidence.md) is the method, the results and the limits.
[Economics](economics.md) is R-independent and cross-cutting.

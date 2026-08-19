# The Problem, and What a Successor Must Do

Status: working draft.
Layer: **the requirement** — what Internet-native primary distribution has to do, before any data
plane is chosen.

**The problem is not that broadcasters are unwilling to move primary distribution onto IP. They have
already done it.** Zixi has carried professional feeds over the public internet for years, SRT has been
adopted broadly and rapidly on top of that, and managed services — AWS Elemental MediaConnect, LTN,
Zixi's own platform and several smaller specialists — sell it as a product today. IP primary
distribution is not a proposal. It is an incumbent.

**What it has not done is replace satellite, and the reason is a ceiling on destination count.** The
adopted architectures are point-to-point tunnels, so serving N destinations means N sessions originated
from the source, or a re-origination tier the operator builds and runs. That is comfortable at tens of
endpoints and runs out shortly after (AWS Elemental MediaConnect caps flows at
50 outputs) (§2.3). Beyond that the operator
is building fan-out infrastructure, and paying for every copy. Satellite, by contrast, illuminates every
receiver in its footprint for the price of one. **So the question this repository asks is not "can
broadcast move to IP" but "can an IP path serve hundreds to low thousands of delivery points
economically" — because that is what replacing a transponder requires.**

This document states that problem, why the incumbent architectures solved their part of it well, what
is eroding them, and — in §5 — the numbered requirement set that every later document is scored
against. It deliberately does not name a candidate protocol until the requirements are fixed. Primary
distribution has been re-architected before (analogue to digital, ASI to IP, SDI to ST 2110) and each
time the transport was the least interesting part of the transition: what changed the industry was the
operating model the transport made possible.

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

**§1.4 — The topology is one-to-many but not millions.** A national feed may fan out to tens or
hundreds of endpoints, sometimes low thousands — not the millions a consumer CDN is built for. That
cuts both ways, and both directions matter. The properties that make a transport excellent at
consumer-scale fan-out are not automatically the ones that matter here; but the range that *is*
required — hundreds to low thousands — is precisely the range the adopted point-to-point
architectures do not reach (§2.3).

**§1.5 — A distributor no longer supplies its clients' receiving equipment.** This one is newer and
decides more than it looks (*established*). The era of shipping an IRD to every affiliate is over — the
receive estate is the client's capex and the client's choice. What survives from that era is the
*contract*: a conformant transport stream, correctly paced, over ASI or IP, at an agreed demarcation
point. This is developed in [Comparison](comparison.md) §4.1, where it
turns out to determine which side of the demarcation the expensive engineering falls on.

---

## 2. The incumbents, and where the IP incumbent stops

Three architectures carry primary distribution today. Each solved the determinism problem in a way
that matched the technology and economics of its era, and each retains properties that are genuinely
difficult to replicate. The third is the one usually left out of this comparison, and it is the one
that defines the actual problem.

### 2.1 Satellite

A physical-layer broadcast medium: one uplink illuminates a footprint, and every receiver within it
sees the same signal at essentially the same time. That yields intrinsic one-to-many economics — **the
marginal cost of an additional receiver is close to zero, which is the property everything else in this
document is measured against** — plus independence from terrestrial networks (immunity to congestion,
BGP events and inter-region fibre cuts) and dedicated, capacity-reserved delivery.

Its weaknesses are equally structural: half-second geostationary round trips, a widening disadvantage
as terrestrial paths improve; rain fade; capital-intensive provisioning; footprint rigidity; and the
spectrum and fleet-economics pressure in §3.1.

### 2.2 Leased fibre and MPLS-based managed IP

ST 2022-7 hitless redundancy, RTP/FEC and engineered class-of-service brought lower latency and more
flexible capacity than satellite. Determinism here is contractual and engineered: reserved-bandwidth
label-switched paths with strict QoS, on a private overlay whose failure domains and security posture
sit with a single operator, directly compatible with the IP plant broadcasters were already building
internally. Weaknesses are cost and agility: a new managed route is a procurement exercise measured in
weeks or months, capacity is priced for dedicated use, and reach is bounded by carrier footprint and
peering.

### 2.3 Point-to-point IP over the public internet — adopted, and capped

**This is the part usually described as the future when it is in fact the present** (*established*).
Zixi has carried professional feeds over commodity internet for years with its own protocol and
broadcaster-operated fan-out; SRT, published as an open protocol with an open-source implementation,
was adopted quickly and widely on top of that; and the capability is sold as a managed product by AWS
Elemental MediaConnect, LTN, Zixi and a number of smaller specialists. A broadcaster wanting to move a
feed from London to a partner in Singapore over the internet, with retransmission, encryption and a
management plane, buys that today.

**What none of them changes is the shape of the delivery, and the shape is what caps it.** All are
point-to-point tunnels with per-session state. Serving N destinations means N sessions originated from
the source, or a re-origination tier the operator builds, runs and pays for. Nothing in the path is a
cache, so the marginal destination costs a marginal session and a marginal copy of the bitrate — the
opposite of the satellite property in §2.1.

Where the exact commercial ceiling sits varies with bitrate,
region and negotiated terms, and it may be somewhat below or above 50 — but that is the region, and it
is an order of magnitude short of a transponder's fan-out.

The architectural escape is to chain flows or stand up a re-origination tier, and it is available
today. What it is not is free: each tier is another hop of latency, another failure domain, another
egress bill on the same bytes, and another thing to operate. Fan-out by replication is a cost that
grows with the estate; fan-out by caching is not.

### 2.4 The common thread, and the one property that is missing

All three succeed by *engineering determinism into a dedicated or managed layer and charging for that
determinism*. The buyer is not paying for bandwidth but for the guarantee, which is why a technically
superior transport does not automatically win.

**The trust argument that blocked the first two has already been settled by the third, and this is the
most under-appreciated fact in the field.** Moving the guarantee onto a best-effort substrate was
supposed to be the hard part; §2.3 did it, in production, on contracted feeds, and the industry bought
it. Retransmission, encryption, monitoring and an accountable counterparty turned out to be enough.
Anyone arguing that broadcast cannot trust the public internet is arguing against deployed practice.

**So what remains is not a trust gap but a topology gap, and it is specific: satellite's marginal cost
per destination approaches zero and every adopted IP architecture's does not.** That gap has its own
trust question attached, and it is a narrower one — not "can the public internet be trusted" but "can a
*shared caching layer somebody else operates* be trusted, and can it be bought from more than one
supplier". Everything after this section is about whether the topology gap can be closed, and what else
must then be true for the result to be usable by the installed base.

---

## 3. What is changing

**The incumbent model is not failing on its technical merits — it is being eroded by pressures largely
exogenous to the transport itself.** They are ordered here by how much each is actually driving the
transition: the economics first, then the enablers that make a response possible, then the operational
pull.

### The forcing pressure

**3.1 Changing economics** (*the pressure is established; the naive version of it is wrong*). This is
the main driver. Spectrum and fleet economics move against satellite over a long horizon — C-band
reallocation, more selective replacement-fleet investment, a finite depreciation runway. But **"cloud
is cheaper than satellite" is not established.** The always-on case is modelled at published list
prices in [Economics](economics.md), and two findings from that model bound the optimism:

- Unicast IP cost is **linear in destinations** where satellite fan-out inside the footprint is free,
  so destination count — not bitrate, and nothing a transport can influence — decides the comparison.
  Every candidate is unicast at the last mile, and a MoQ relay is a cache rather than an exception.
- Published cloud egress sits about an order of magnitude above what the same delivery costs on a
  commodity CDN or, costed all-in, on owned infrastructure — which makes this a question about
  commercial terms rather than engineering.

The first of those is the same fact as the ceiling in §2.3, seen from the invoice rather than the
service quota, and it is why this driver leads: **the pressure to leave satellite and the difficulty of
replacing it are the same arithmetic.** The durable driver is therefore not unit cost today but the
mismatch between a *fixed, provisioned* cost model and a business that increasingly needs a *variable,
on-demand* one.

**3.2 Shrinking linear revenues** (*established*). Leased transponders and managed fibre were justified
against large, stable linear revenues; as viewing migrates to direct-to-consumer streaming, the fixed
cost of dedicated capacity becomes a larger and more scrutinised fraction of a declining pie. Linear
will not disappear — news, sport and regulated public-service content persist for years — but its cost
base must shrink in step. This is what gives §3.1 its teeth: it makes distribution cost a line item under
active scrutiny, so change gets forced even where no compelling technical alternative has appeared.

### What makes a response possible now

**3.3 The head-ends are now well connected** (*established*). The receiving estate has quietly stopped
being the constraint. Affiliate stations, cable head-ends and partner facilities that a decade ago had
a modest business line for management traffic now typically have robust, often diverse and
multi-gigabit internet connectivity, provisioned for their own cloud production and OTT workflows. A
destination that can absorb a multi-megabit contribution-grade feed over the public internet no longer
has to be specially built to do so, which is a precondition for anything in this document and one that
was not true when the incumbent architectures were designed.

**3.4 A commodity software-defined substrate** (*established*). Mature QUIC/HTTP-3 stacks operated at
global scale by CDNs and hyperscalers mean the *substrate* for an Internet-native fabric now exists as
a commodity. A decade ago "distribute broadcast over the Internet" meant building the network; today
the network is there, and the open question is the layer above it.

**3.5 Open standards and open source are disrupting the supply side** (*established*). The pattern is
already visible in the incumbent generation: SRT displaced a good deal of proprietary contribution
tooling largely because it was published with a usable open implementation, and RIST was specified in
the open for the same reason. That changes who can build, who can integrate, and what a buyer can
insist on — a protocol with more than one implementation is a market rather than a supplier
relationship. It is also why the data-plane candidates evaluated in [Comparison](comparison.md) are
open specifications with open implementations, and why relay portability between them is treated as a
precondition rather than a detail: an open standard that only interoperates with itself delivers the
disruption in name only.

### What the business is asking for

**3.6 Cloud adoption in the media plant** (*established*). Production, playout, origination and OTT
packaging have moved decisively into cloud and cloud-adjacent infrastructure, so primary distribution
is frequently the *outlier*: software-defined and API-driven on every side but still a physical or
carrier-managed procurement itself. Every hand-off between a software-defined domain and a manually
provisioned one adds latency, error and operational cost. The pressure is not "cloud is cheaper"
(§3.1); it is that the *shape* of distribution no longer matches the shape of everything it connects
to.

**3.7 Operational agility** (*established*). Pop-up channels, event-scoped feeds, short-term rights
windows and rapid partner onboarding are routine commercial requests, and distribution is increasingly
expected to expose the same APIs and infrastructure-as-code primitives as the rest of the plant. An
architecture whose unit of change is a multi-week provisioning ticket cannot serve a business whose
unit of change is a same-day commercial decision.

**3.8 Global, dynamic rights** (*likely*). A rights holder may need to deliver a feed to partners
across several continents for a single event, then tear the whole topology down. Satellite footprints
are geographically rigid and managed-fibre reach is bounded by carrier footprint, whereas the public
Internet *reaches everywhere a data centre reaches*. The pressure is reach-on-demand: global topology
without global procurement.

---

## 4. What a successor has to change

**The direction of travel is not "move primary distribution to IP" — §2.3 is that, and it is already
happening. The open move is from *tunnels* to a *fan-out fabric*** (*likely*). Each pressure in §3
pushes distribution toward a layer that is programmable, globally reachable and priced with use, and
the substrate for such a layer now exists as a commodity. But the specific thing the adopted
architectures cannot do is serve hundreds to low thousands of destinations without replicating the
stream once per destination from the source, and that is a property of the data plane rather than of
the operator's competence or the network's quality.

So a successor has to put something in the path that behaves like a cache: a stage that receives a
feed once and serves it to many, that the operator does not have to originate a session for, and that
can be bought from more than one supplier. That is a strong constraint, and it is what narrows the
field to the two candidates [Comparison](comparison.md) evaluates.

**It is not the only possible resolution, and the honest alternative is worth naming.** An API-driven
control plane over *existing* managed IP or tunnelled transport — MediaConnect-class services,
orchestrated MPLS/SRT, a re-origination tier operated as a product — narrows the agility and
provisioning mismatch without a new data plane at all, on procurement, tooling and staff skills that are
already in place. That is a real advantage and it will win some routes. What it does not do is change the
marginal economics of the thousandth destination, which is the one thing §2.3 cannot fix from the control
plane.

The conclusion is not that satellite and managed fibre disappear, but that the *marginal* new route —
and eventually the marginal re-provisioned route — increasingly lands on an Internet-native path, with
the installed base migrating through attrition as dedicated capacity is not renewed rather than by a
single switch-off. What is uncertain is the *rate*, set by how quickly the successor layer earns the
guarantee the incumbent already provides.

---

## 5. The requirement set

Everything downstream is scored against this list. It merges the characteristics of §1, the transport
properties primary distribution imposes, and the contract the installed base enforces.

The order is deliberate. **R1–R3 are the requirements that decide whether a candidate is usable at
all** — carry the multiplex, fan it out at the scale that matters, and hand it over in a form the
installed base accepts. R4–R8 are then the requirements that decide whether it is *good*. And **R3 and
R6–R8 sit above the transport and are required whichever data plane is chosen**, which is the
observation the rest of this repository turns out to be about.

| # | Requirement | Why | Where it is assessed |
|---|---|---|---|
| **R1** | **Faithful carriage of MPEG-2 transport streams.** Service identity (SDT), programme structure (PMT PIDs), SCTE-35 splice signalling, teletext/subtitling and continuity must survive transit intact. A transport that silently discards or reorders these is unusable for the installed base regardless of its performance. | §1.2 | [Comparison](comparison.md) §8, [Evidence](evidence.md) §3.1 |
| **R2** | **A fan-out model whose marginal cost per destination approaches zero.** One-to-many to hundreds or low thousands of endpoints, without publisher-side replication or a per-endpoint tunnel the operator must run. **This is the requirement the adopted IP architectures fail**, and the reason the problem is still open (§2.3). | §1.4, §2.3 | [Comparison](comparison.md) §2, [Economics](economics.md) |
| **R3** | **IRD-conformant egress.** A conformant MPEG-2 transport stream over the supported interface (RTP/UDP, frequently multicast), TR 101 290 P1/P2 conformant — above all conformant PCR timing — with stable service signalling and, where the facility uses it, ST 2022-7 dual-path input. **No Internet-native transport delivers this without an edge stage**, and because the distributor does not supply the receiver, that stage sits on the distributor's side of the demarcation. | §1.2, §1.5 | [Architecture](architecture.md) §4, [Evidence](evidence.md) §3.2 |
| **R4** | **Bounded, stable latency.** Sub-second is desirable; for most primary distribution a few seconds is tolerable — but the budget must be bounded and stable, because a drifting buffer is itself a fault for downstream playout and ad insertion. "Tolerable" has to be answered per route, not once: a geostationary path delivers a fraction of a second, and a 2–5 s replacement consumes most of a downstream budget that was previously free, at every destination. | §1.1, §1.2 | [Comparison](comparison.md) §5, [Evidence](evidence.md) §3.11 |
| **R5** | **Graceful behaviour under loss and congestion.** The transport must degrade predictably rather than stall, and must not convert a single lost packet into a multi-second gap. | §2.4 (best-effort substrate) | [Comparison](comparison.md) §3, [Evidence](evidence.md) §3.3 |
| **R6** | **Engineered redundancy meeting "no visible failure during contracted content".** In practice 1+1 with hitless selection at the receiver, because that is what the installed base already implements. | §1.1 | [Architecture](architecture.md) §5, [Evidence](evidence.md) §3.4 |
| **R7** | **Dynamic, revocable entitlement.** A feed reaches an endpoint only while that endpoint holds a valid grant, with a bounded worst-case revocation time — so rights windows, partner onboarding and emergency takedown are control-plane operations rather than manual receiver reconfiguration. | §3.7 | [Control](control-plane.md) |
| **R8** | **Observability in broadcast terms.** Signal conformance, error seconds and PCR integrity, correlatable with systems-domain telemetry, so a broadcast NOC can operate the platform without adopting a new vocabulary. | §1.3 | [Architecture](architecture.md) §8 |

Three notes on how this list is used.

**R2 is the requirement that makes the problem a problem.** It is also the one most easily waved
through, because every candidate "scales" in the sense of working at ten destinations. The test is
whether the thousandth destination costs what the tenth did, and that is a question about caching in
the path, not about throughput.

**R3 is the requirement this repository spends most of its effort on**, and it is the one neither
candidate specification addresses. The HLS document contains zero occurrences of PCR, constant bit
rate, stuffing or null packet; MoQ has no notion of them either. That is not a criticism of either —
it is the boundary of what a transport specification is for — but it means R3 is *built*, on either
data plane.

**R3 and R4 looked coupled and are not.** The edge stage that satisfies R3 appeared to buy its PCR
conformance with buffer depth, and buffer depth is latency — which would have made every recommendation
a trade between conformance and delay. Measurement separated them: on the media-aware lane the
repetition figure does not move with buffer depth at all, and the residual failure is an upstream
carriage defect rather than a price paid out of latency ([Evidence](evidence.md) §3.2, §3.11).

---

## 6. Where this goes next

[Comparison](comparison.md) evaluates the two candidate Internet-native data planes — MoQ, and
segmented HTTP carrying MPEG-TS — against R1, R2, R4 and R5, and against the point-to-point
incumbents of §2.3. [Architecture](architecture.md) develops R3, R6 and R8, which is where nearly all
the measured work sits. [Evidence](evidence.md) is the method, the results and the limits.
[Economics](economics.md) is cross-cutting, and is where R2's arithmetic is actually done.

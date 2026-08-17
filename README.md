# MoQ for Broadcast Primary Distribution
Internet-Native Primary Distribution for Professional Broadcast

**A technical evaluation of Media over QUIC (MoQ) as a candidate transport for broadcast-grade primary distribution.**

Status: working draft. This paper is deliberately critical: the goal is to find the fastest way to *disprove* the thesis, not to sell it. AI assistance was used in drafting.

> **In one line.** *Media over QUIC (MoQ)* is a live-media transport being standardised in the IETF and built on the same QUIC / HTTP-3 substrate that CDNs and hyperscalers already operate globally. This paper asks a narrow, technical question: **does MoQ deserve serious evaluation as a future primary distribution technology for professional broadcast workflows?**

---

## What this paper is — and is not

**It is:**
- A technical argument that the pressures reshaping broadcast (cloud-native plants, API-driven operations, shrinking linear revenue, global/dynamic rights) are pushing primary distribution toward an Internet-native model, and that MoQ is among the few live-media transports whose *architecture* fits that model — chiefly through native relay and 1:N amplification.
- A reference architecture for a broadcast-grade distribution platform built on MoQ, including the unglamorous interop, grooming, entitlement, and observability layers above the transport.
- Explicit about what remains unproven, and about where MoQ's advantage over existing IP transports is narrow.

**It is not:**
- A claim that MoQ is production-ready today. The wire protocol is pre-standard and unstable (see [Transport](docs/transport.md)).
- A claim that Internet-native distribution is *already* economically superior to a depreciated satellite transponder or an existing IP contract. The always-on case is modelled numerically, and the headline is that **cost is decided by commercial terms rather than by transport engineering**: which market delivery is bought in moves the bill by an order of magnitude, the choice of transport by a few percent ([Economics](docs/economics.md) §4).

  It is modelled on **public list prices** by necessity rather than oversight. Real negotiated rates and depreciated route costs are commercially sensitive and cannot be published, and they sit below list on *both* sides of the comparison. The IP-side figures here are therefore an *upper* bound, and the comparison is stated as a **parity threshold** an operator substitutes its own incumbent cost into privately — a method, not a verdict on anyone's economics ([Contributing](CONTRIBUTING.md)).
- A product pitch or a business plan.

---

## Bottom line up front

MoQ is a credible **transport foundation**. It is open-source, standards-track, and prototypes show it works: the media-aware lane carries a full contribution mux end-to-end over a public-internet cloud relay with 0 continuity errors, a downstream groomer takes the bursty egress to exact CBR (0 % of PCR intervals > 40 ms where the carrier rate is matched to the content, and no PCR outside TR 101 290's ±500 ns accuracy limit on file), and switching the sender off QUIC's default CUBIC to BBR holds full-rate, byte-complete delivery on par with SRT under loss — though which BBR generation suits a permanent fixed-rate trunk is not yet settled ([Evidence](docs/evidence.md) §1, §3 and §6; campaign record in [lab](lab/README.md)). The engineering that matters for broadcast is the **broadcast-grade layer above the transport**: IRD-accurate egress and PCR grooming, entitlement and multi-tenant control, redundancy, observability, and interop with the installed base (MPEG-TS, RTP, SRT/Zixi, hardware IRDs). Whether that layer can meet broadcast's trust bar on a best-effort substrate is a real, testable question, and it is *not yet proven*.

**Operational maturity is a separate risk from the protocol being pre-standard, and it cuts both ways.** Most of what this evaluation found wanting sits in the implementations and tooling being built alongside the standard rather than in MoQ itself: defaults tuned for demos rather than trunk routes, memory held by the QUIC library beneath the relay, thin observability, and interop conventions the drafts leave open to more than one reading. That is the expected shape of implementations maturing *with* a specification rather than after it, and several gaps found here closed upstream during the campaign. The counterweight is that a broadcaster procures an implementation, not a specification — so much of what reads as "MoQ does X" is really "this build does X", and an evaluation of a pre-1.0 ecosystem is tracking a moving target ([Evidence](docs/evidence.md) §1, §8 and §9).

---

## Why a new approach at all

Traditional primary distribution — satellite, leased fibre, MPLS — succeeds by *engineering determinism into a dedicated or managed layer and charging for the guarantee*. That model works and its buyers are structurally conservative. But the plant around it has gone software-defined and API-driven, linear revenue is declining (pressuring the fixed cost of dedicated capacity), rights are increasingly global and dynamic, and the QUIC/HTTP-3 substrate needed for an Internet-native alternative now exists as a commodity. The full argument, with the strongest counter-cases, is in [Vision](docs/vision.md).

## Why MoQ, and how it differs from the alternatives

There are two classes of incumbent, and MoQ has to answer both. SRT, Zixi and RIST already move a linear feed reliably from A to B; segmented HTTP (HLS carrying MPEG-TS, and DVB-DASH) already delivers over commodity CDN at seconds of latency with interop MoQ does not yet have. MoQ's *incremental* advantage on the narrow point-to-point job is real but narrow, and against segmented HTTP it reduces to four things — sub-second capability, verbatim multi-programme carriage, subscription-native entitlement, and push rather than manifest polling ([Transport](docs/transport.md) §3.3–§3.4). What distinguishes it is architectural, not raw performance:

- **Native relay and 1:N amplification** (the advantage we put forward first): a single protocol carries a feed from contribution through a relay fabric that fans out point-to-multipoint, with caching, on the QUIC/HTTP-3 substrate CDNs and hyperscalers already run. The economic value of that fan-out is narrower than it sounds — it removes duplicated backhaul and uplink, not last-mile egress, which stays linear in destinations for every transport including this one ([Economics](docs/economics.md) §4.8).
- **A shape a commodity delivery market can sell** — the strongest economic argument here, and a claim about markets rather than a measurement. A MoQ relay *is* a cache, so relaying maps onto machinery CDNs already run at scale; SRT has no object model or native relay, so fanning it out means a stateful media gateway per stream per destination. That is why no CDN sells SRT relay as a commodity product and one already sells MoQ relay, and why MoQ is the first *sub-second* broadcast-grade transport whose price could follow commodity delivery down rather than sitting at hyperscaler rates ([Economics](docs/economics.md) §4.9). The word sub-second is load-bearing: segmented HTTP already has the commodity delivery market, so this argument is about the latency band it cannot reach, not about delivery economics in general.
- **Subscription-oriented delivery**, which maps directly onto dynamic, revocable entitlement.
- **A native authorization point** at subscription (the platform layers path-scoped tokens, mTLS, and expiry on it).
- **Per-stream delivery** — a lost packet stalls only its own object, not the whole multiplex — with **graceful multi-rendition degradation** (strongest on the default media-aware lane, constrained on the opaque fallback). Loss resilience itself is a controller choice, not a free protocol property: QUIC's default CUBIC *collapses* under loss, while BBR restores full-rate delivery *on par with* SRT — parity, not superiority ([Transport](docs/transport.md) §3.1, [Evidence](docs/evidence.md) §6).

These matter most at fan-out scale and heterogeneity — precisely where primary distribution is *least* heterogeneous, so the fit must be tested, not assumed. Developed in [Vision](docs/vision.md) and [Transport](docs/transport.md).

## Why this might fail

The strongest reasons the thesis fails, each testable rather than rhetorical:

- **The transport isn't stable enough (highest technical risk).** MoQ is pre-standard; recent drafts are "almost a completely new protocol," while broadcasters need 5–10 year stability. *Mitigation:* keep the media and control layers transport-independent (already done — see [Evidence](docs/evidence.md)), so the control plane can run over today's transports if MoQ slips ([Transport](docs/transport.md) §5.2).
- **MoQ's advantage over SRT/Zixi/RIST is too narrow for *this* job (highest thesis risk).** The head-to-head has run, and it moved the sign on the line carrying most of the cost: MoQ's media-aware lane puts 0.982x the source TS rate on the wire against SRT's 1.037x ([Evidence](docs/evidence.md) §8). But that ~5 % is the null stuffing MoQ declines to carry, so it travels with the source's stuffing ratio — a tightly packed carrier converges the two to a ~1.2-point floor, and byte-verbatim carriage forgoes it entirely. The narrow case is therefore still open, and the thesis cannot rest on bandwidth.
- **A specified, universally interoperable alternative already carries MPEG-TS (newly the strongest challenge).** HLS has carried MPEG-TS since 2009, and its current edition folds in low-latency mode. It is explicitly *not* an Internet standard, yet it interoperates across essentially every CDN, packager and analyser — while MoQ, which *is* standards-track, currently carries media only within a single implementation. On carriage interop, delivery economics and maturity, segmented HTTP is ahead today, and its 2–5 s latency sits inside the tolerance this paper states. *Test (not run):* a head-to-head on one real route, measuring latency at equal conformance, what each preserves from a real DVB mux, wire cost, and multi-programme carriage ([Transport](docs/transport.md) §3.4).
- **Hardware IRDs reject groomed MoQ output (potential showstopper).** MoQ's object/burst model yields PCR that hardware IRDs flag on TR 101 290 P1/P2 — inherent, not a bug. Grooming addresses it but must be *proven on real hardware*. *Test (not yet run):* a clean P1/P2 pass on real IRDs ([Evidence](docs/evidence.md), [Architecture](docs/architecture.md) §7.2 and §17). Note this risk is transport-independent: no Internet-native transport, MoQ or HTTP-based, delivers IRD-conformant timing without an edge grooming stage.
- **Relay portability never arrives, which removes the strongest economic argument.** The commodity-relay case assumes a feed can be carried over a relay somebody else operates, and treating relay capacity as a substitutable commodity is what [Economics](docs/economics.md) §4.9 rests on. Measured against all eight other registered public relays, no media arrives at all. Version negotiation is *not* the obstacle — the nearest cause is an announce convention the draft permits either way — but the eight failures have at least four distinct causes, so no single fix restores portability ([Evidence](docs/evidence.md) §9). Until it is demonstrated, single-vendor dependence is the realistic position and "commodity relay" is an aspiration.

---

## MoQ in broadcast terms

The documents below use MoQ's vocabulary. This is the whole of it, in the nearest broadcast equivalent:

| MoQ term | What it means here |
|---|---|
| **Broadcast** | One named feed, roughly a service or channel. Note it does not mean "broadcast" in the RF sense. |
| **Track** | One elementary stream inside that feed: video, an audio pair, or data such as SCTE-35. |
| **Group** | A self-contained run of a track that starts at a keyframe, and the point a new subscriber can join at. The closest analogue is a GOP. |
| **Object** | The individual unit of delivery within a group, roughly a frame's worth of bytes. Loss stalls one object rather than the whole multiplex. |
| **Catalog** | The manifest saying which tracks exist and how they are coded. The closest analogue is PAT/PMT. |
| **Announce** | How a publisher advertises that a feed exists, so relays learn where to route it from. |
| **Origin** (`--origin <id>`) | An identifier by which two publishers declare they carry interchangeable content, i.e. a 1+1 pair. |
| **Route reselect** | A relay switching from a failed publisher to a standby carrying the same feed. |
| **Publisher / subscriber** | The sending and receiving endpoints. In this paper they are `moq import ts` and `moq export ts`, which convert between MPEG-TS and MoQ tracks. |

---

## Repository

Read [Vision](docs/vision.md) for the *why*, [Transport](docs/transport.md) for *why MoQ specifically*, [Architecture](docs/architecture.md) for *how it would be engineered*, and [Implementation](docs/implementation.md) for *how to build and test it*. The remaining documents are topic deep-dives.

### The paper (`docs/`) — the design and what we've learned

| Document | Description |
|----------|-------------|
| [Vision](docs/vision.md) | Why broadcast primary distribution is changing — industry problem, opportunity, and critical analysis. |
| [Transport](docs/transport.md) | Why MoQ specifically; QUIC/WebTransport, MPEG-TS/MSFTS carriage, and draft-stability strategy. |
| [Architecture](docs/architecture.md) | End-to-end reference architecture for a broadcast-grade MoQ distribution platform. |
| [Implementation](docs/implementation.md) | Components, prerequisites, reference deployment, and the test path to the hardware-IRD proof. |
| [Relay](docs/relay.md) | Relay fabric, routing, fan-out, federation, and resilience. |
| [Control Plane](docs/control-plane.md) | Provisioning and orchestration. |
| [Entitlement](docs/entitlement.md) | Dynamic, revocable distribution rights. |
| [Security](docs/security.md) | Identity, authentication, and threat model. |
| [Interoperability](docs/interoperability.md) | IRDs, MPEG-TS, RTP, ST 2022-7, SRT, Zixi. |
| [Operations](docs/operations.md) | NOC model, SLOs, monitoring, and runbooks. |
| [Economics](docs/economics.md) | Cost framework, and a numeric model of the always-on case at published rates — MoQ against SRT, managed services, commodity CDN delivery and satellite. |
| [Evidence](docs/evidence.md) | What the working prototype proved — the empirical basis for the claims above. |

### The validation campaign (`lab/`) — what was planned and measured

| Document | Description |
|----------|-------------|
| [Laboratory Notebook](lab/README.md) | The validation campaign — both the *plan* (objectives, acceptance-gate mapping, and the pass criteria agreed before the numbers) and the *executed* work: exact procedures, commands, and **measured results** per test (baseline TS characterisation, transport transparency on both lanes, remote end-to-end over the public internet, impairment and congestion-control behaviour, resilience, resource envelope, and cross-implementation interop). Where a result was later corrected, the per-test file states the current finding and records what the earlier reading got wrong. |

### Code (`interop/`) — what this project contributes back

| Component | Description |
|----------|-------------|
| [Media-level interop test client](interop/README.md) | A test client for the community [MOQ Interop Runner](https://github.com/englishm/moq-interop-runner), carrying an MPEG-TS fixture through a relay and validating what comes out — continuity counters make the fixture check itself, so no decoder or frame capture is needed. Offered in support of [runner #32](https://github.com/englishm/moq-interop-runner/issues/32) as an argument that media-level interop can be tested automatically. |

The CBR grooming component is a separate public crate, [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer).

---

## Contributing and feedback

This is a public, living reference whose purpose is to be tested and challenged.
Corrections, counter-evidence, and disagreement are actively wanted — see
[CONTRIBUTING](CONTRIBUTING.md) for how to raise an issue, start a discussion, or
propose a change, and for the editorial and confidentiality conventions.

---

## Open questions

- Does the parity threshold survive substitution of a real operator's own two numbers? This is the decisive commercial question and it is deliberately *not* answered here: the model is built on public list prices and expressed as a threshold precisely so it can be re-run in private against negotiated and depreciated costs that cannot be published. It is a test only the operator can run. ([Economics](docs/economics.md) §4.7)
- Why does published cloud egress sit roughly an order of magnitude above commodity CDN delivery and above the all-in cost of running delivery yourself, and does anything force that gap to close? The always-on trunk case lives entirely inside that spread. ([Economics](docs/economics.md) §4.2)
- Does groomed MoQ output pass TR 101 290 P1/P2 on real hardware IRDs? ([Evidence](docs/evidence.md))
- How much of the IRD-facing egress layer should be public? The groomer's placement is settled — downstream of the transport, as a public crate — but FEC, ST 2022-7 pairing, start gating and egress TR 101 290 monitoring are not, and publishing them trades differentiation for credibility. ([Implementation](docs/implementation.md) §9)
- What does the opaque lane cost on the wire? It is the lane preferred for hardware IRDs and the only one unmeasured on the line that dominates the cost model — derivation puts verbatim carriage near SRT and null-stripped carriage near the media-aware lane, which is the difference between carriage being a wash and being an advantage. ([Economics](docs/economics.md) §9)
- Which congestion controller suits a permanent fixed-rate trunk? The ranking inverts by regime: the generation that best resists non-congestive loss is not the one that behaves best under a shaped bottleneck, and the provisioned-path conditions that would settle it are unrun, so no single recommendation covers both. ([Evidence](docs/evidence.md) §6)
- Does the relay's per-connection memory ceiling really hold over weeks rather than hours? The plateau is confirmed but soft — still creeping ~8 MB/hour past the knee — and the only lever that binds it works sub-proportionally. ([Evidence](docs/evidence.md) §8)
- Can one leg of a live 1+1 pair be restarted on its own? Only for some receivers. A recovering leg regains its numbering, slots and phase, but not byte-identity, because `moq export ts` renders continuity counters from process state — so an **input-select** receiver is protected again immediately while a **sequence-merge** receiver needs the pair restarted together. That is an upstream fix rather than an edge one ([moq-dev/moq#2779](https://github.com/moq-dev/moq/issues/2779), [Evidence](docs/evidence.md) §7).
- Can a broadcast feed traverse a relay somebody else operates? Measured today it cannot — carriage works within one implementation and fails against all eight other public relays, which makes "commodity relay" an aspiration rather than a property. ([Evidence](docs/evidence.md) §9, [Interoperability](docs/interoperability.md) §9.6)

---

## Author

**Thomas Drapier**  
Senior Director, Service Management & Partner Services  
Broadcast Distribution Engineering

This repository represents research and engineering work on Media over QUIC for
broadcast primary distribution. Parts of the documents were drafted with AI
assistance and then reviewed (see [CONTRIBUTING](CONTRIBUTING.md)).

LinkedIn: https://www.linkedin.com/in/tdrapier/

---

## References

A comparison of the implementations below — what each covers, where they
interoperate, and where they do not — is in
[Interoperability](docs/interoperability.md) §9.

**Implementations**

- MOQ-dev (media-aware lane; publisher, relay, subscriber): https://github.com/moq-dev/moq
- Cloudflare `moq-rs` (IETF-aligned transport library + production relay, media-agnostic): https://github.com/cloudflare/moq-rs
- Cloudflare MoQ relay service and provisioning API: https://developers.cloudflare.com/moq/
- `moq2ts` (transparent MPEG-TS publisher): https://github.com/mondain/moq2ts
- `moqxr` / OpenMOQ Publisher (the transport SDK beneath it): https://github.com/mondain/moqxr
- MPEG-TS VBR to CBR Pacer: https://github.com/tdrapier-wbd/mpegts-pacer

**Standards and formats**

- IETF MOQ working group: https://datatracker.ietf.org/group/moq/about/
- MOQ Transport working area: https://github.com/moq-wg/moq-transport
- MOQT Streaming Format (MSF), adopted WG draft: https://datatracker.ietf.org/doc/draft-ietf-moq-msf/
- CMSF (CMAF profile of MSF): https://datatracker.ietf.org/doc/draft-ietf-moq-cmsf/
- MSFTS (MPEG-TS profile): https://github.com/mondain/msfts
- OpenMOQ: https://openmoq.org/
- HTTP Live Streaming 2nd Edition (obsoletes RFC 8216; includes Low-Latency HLS and MPEG-TS segment carriage — the closest specified alternative, [Transport](docs/transport.md) §3.4): https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/

**Testing and background**

- MOQ Interop Runner: https://github.com/englishm/moq-interop-runner
- MPEG-TS over MOQ: https://edis.mx/insights/mpeg-ts-over-moq.html
- MPEG-TS over MOQ — PCR: https://edis.mx/insights/mpeg-ts-over-moq-pcr.html
- MPEG-TS over MOQ — pacing: https://edis.mx/insights/mpeg-ts-over-moq-pacing.html

---

*This is a living document. Its purpose is to be proven wrong quickly and cheaply.*

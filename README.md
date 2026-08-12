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
- A claim that Internet-native distribution is *already* economically superior, today, to a depreciated satellite transponder or an existing IP contract for always-on trunk routes. The always-on case is now modelled numerically at public list prices, and the result is that **cost is decided by commercial terms rather than by transport engineering**: egress is ~90 % of the bill, the MoQ-versus-SRT difference is ~8 % of it, and published cloud egress sits an order of magnitude above what the same delivery costs to buy on a commodity CDN or to run on owned infrastructure. The corollary is that *which market the delivery is bought in* decides the outcome, and the two cheapest routes — commodity CDN delivery at published rates, and self-hosted infrastructure costed all-in — land in the same band, which puts a transponder's worth of channels to several hundred destinations in contention rather than out of reach. What remains unproven is the comparison against one broadcaster's *actual, depreciated* route cost at *negotiated* rates (see [Economics](docs/economics.md)).
- A product pitch or a business plan.

---

## Bottom line up front

MoQ is a credible **transport foundation**. It is open-source, standards-track, and prototypes show it works: the working prototype carries a full contribution mux end-to-end over a public-internet cloud relay with 0 continuity errors, grooms the bursty egress to exact CBR (0 % of PCR intervals > 40 ms, 0 `pcrverify` violations at ±500 ns on file), and — once the sender is switched to BBR — holds full-rate, byte-complete delivery on par with SRT under loss ([Evidence](docs/evidence.md); campaign record in [lab](lab/README.md)). The engineering that matters for broadcast is the **broadcast-grade layer above the transport**: IRD-accurate egress and PCR grooming, entitlement and multi-tenant control, redundancy, observability, and interop with the installed base (MPEG-TS, RTP, SRT/Zixi, hardware IRDs). Whether that layer can meet broadcast's trust bar on a best-effort substrate is a real, testable question, and it is *not yet proven*.

The implementations are also not yet operationally mature, which is a separate risk from the protocol being pre-standard. Publisher and subscriber processes hold memory flat over a day and a half, but the relay grows about 27 MB/hour under sustained subscriber load across two consecutive releases — and the documented cache bound does not contain it, so cache tuning is not a mitigation ([Evidence](docs/evidence.md) §8). Nothing about that is architectural, and it is being characterised for an upstream report rather than treated as a deployment workaround; but a transport whose reference relay needs a planned restart cycle is not yet one a broadcaster would put an always-on trunk route on.

---

## Why a new approach at all

Traditional primary distribution — satellite, leased fibre, MPLS — succeeds by *engineering determinism into a dedicated or managed layer and charging for the guarantee*. That model works and its buyers are structurally conservative. But the plant around it has gone software-defined and API-driven, linear revenue is declining (pressuring the fixed cost of dedicated capacity), rights are increasingly global and dynamic, and the QUIC/HTTP-3 substrate needed for an Internet-native alternative now exists as a commodity. The full argument, with the strongest counter-cases, is in [Vision](docs/vision.md).

## Why MoQ, and why it differs from SRT/Zixi/RIST

SRT, Zixi and RIST already move a linear feed reliably from A to B. MoQ's *incremental* advantage on that narrow job is real but narrow; what distinguishes it is architectural, not raw performance:

- **Native relay and 1:N amplification** (the advantage we put forward first): a single protocol carries a feed from contribution through a relay fabric that fans out point-to-multipoint, with caching, on the QUIC/HTTP-3 substrate CDNs and hyperscalers already run. The economic value of that fan-out is narrower than it sounds — it removes duplicated backhaul and uplink, not last-mile egress, which stays linear in destinations for every transport including this one ([Economics](docs/economics.md) §4.8).
- **A shape a commodity delivery market can sell** — the strongest economic argument here, and a claim about markets rather than a measurement. A MoQ relay *is* a cache, so relaying maps onto machinery CDNs already run at scale; SRT has no object model or native relay, so fanning it out means a stateful media gateway per stream per destination. That is why no CDN sells SRT relay as a commodity product and one already sells MoQ relay, and why MoQ is the first sub-second broadcast-grade transport whose price could follow commodity delivery down rather than sitting at hyperscaler rates ([Economics](docs/economics.md) §4.9).
- **Subscription-oriented delivery**, which maps directly onto dynamic, revocable entitlement.
- **A native authorization point** at subscription (the platform layers path-scoped tokens, mTLS, and expiry on it).
- **Per-stream delivery** — a lost packet stalls only its own object, not the whole multiplex — with **graceful multi-rendition degradation** (strongest on the default media-aware lane, constrained on the opaque fallback). Loss resilience itself is a controller choice, not a free protocol property: QUIC's default CUBIC *collapses* under loss, while BBR restores full-rate delivery *on par with* SRT — parity, not superiority ([Transport](docs/transport.md) §3.1, [Evidence](docs/evidence.md) §6).

These matter most at fan-out scale and heterogeneity — precisely where primary distribution is *least* heterogeneous, so the fit must be tested, not assumed. Developed in [Vision](docs/vision.md) and [Transport](docs/transport.md).

## Why this might fail

The strongest reasons the thesis fails, each testable rather than rhetorical:

- **The transport isn't stable enough (highest technical risk).** MoQ is pre-standard; recent drafts are "almost a completely new protocol," while broadcasters need 5–10 year stability. *Mitigation:* keep the media and control layers transport-independent (already done — see [Evidence](docs/evidence.md)), so the control plane can run over today's transports if MoQ slips ([Transport](docs/transport.md) §5.2).
- **MoQ's advantage over SRT/Zixi/RIST is too narrow for *this* job (highest thesis risk).** *Test:* a real head-to-head lab ([Implementation](docs/implementation.md) §6) and a TCO model built on one broadcaster's actual route costs ([Economics](docs/economics.md)). The list-price model already argues the narrow case: on the line that carries ~90 % of the cost, MoQ is ~8 % *worse* than SRT, and its efficiency advantage sits on the line that barely registers.
- **Hardware IRDs reject groomed MoQ output (potential showstopper).** MoQ's object/burst model yields PCR that hardware IRDs flag on TR 101 290 P1/P2 — inherent, not a bug. Grooming addresses it but must be *proven on real hardware*. *Test (not yet run):* a clean P1/P2 pass on real IRDs ([Evidence](docs/evidence.md), [Architecture](docs/architecture.md) §7.2 and §17).

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

- What is the real TCO delta versus one broadcaster's actual routes, at negotiated rather than list rates? ([Economics](docs/economics.md))
- Why does published cloud egress sit roughly an order of magnitude above commodity CDN delivery and above the all-in cost of running delivery yourself, and does anything force that gap to close? The always-on trunk case lives entirely inside that spread. ([Economics](docs/economics.md) §4.2)
- Does groomed MoQ output pass TR 101 290 P1/P2 on real hardware IRDs? ([Evidence](docs/evidence.md))
- Where does the groomer (PCR-accuracy work) ultimately live — upstream or downstream — and if downstream, open/interoperable or closed/licensed? ([Architecture](docs/architecture.md) §17)
- Can a relay hold memory flat under sustained fan-out for weeks, not hours? ([Evidence](docs/evidence.md) §8)
- Can a leg **rejoin** a 1+1 pair after it recovers or restarts? A pair that is both groomed and mergeable from two independent chains now works: two groomers keyed to stream position rather than to their own emit clocks produce byte-identical legs and stay hitless through publisher, relay and exporter death, which the groom-once-and-duplicate topology cannot cover. A leg that recovers or joins late gets its numbering, its slots and its phase back — within about 10 ms of its partner — but not byte-identity: `moq export ts` numbers continuity counters from process state, so two exporters that did not start together differ by a constant in one byte of every packet, and 97–98 % of a recovered leg's datagrams are otherwise identical. That is an upstream fix, not an edge one, and it is filed as [moq-dev/moq#2779](https://github.com/moq-dev/moq/issues/2779). ([Evidence](docs/evidence.md) §7, [Architecture](docs/architecture.md) §14.1)
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

**Testing and background**

- MOQ Interop Runner: https://github.com/englishm/moq-interop-runner
- MPEG-TS over MOQ: https://edis.mx/insights/mpeg-ts-over-moq.html
- MPEG-TS over MOQ — PCR: https://edis.mx/insights/mpeg-ts-over-moq-pcr.html
- MPEG-TS over MOQ — pacing: https://edis.mx/insights/mpeg-ts-over-moq-pacing.html

---

*This is a living document. Its purpose is to be proven wrong quickly and cheaply.*

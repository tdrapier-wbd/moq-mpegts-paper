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
- A claim that Internet-native distribution is *already* economically superior, today, to a depreciated satellite transponder or an existing IP contract for always-on trunk routes. The analysis argues the trunk case is achievable over the horizon on which incumbent capacity retires and egress pricing falls — and stronger still for dynamic routes — but it is route-specific and not yet proven with numbers (see [Economics](docs/economics.md)).
- A product pitch or a business plan.

---

## Bottom line up front

MoQ is a credible **transport foundation**. It is open-source, standards-track, and prototypes show it works. The engineering that matters for broadcast is the **broadcast-grade layer above the transport**: IRD-accurate egress and PCR grooming, entitlement and multi-tenant control, redundancy, observability, and interop with the installed base (MPEG-TS, RTP, SRT/Zixi, hardware IRDs). Whether that layer can meet broadcast's trust bar on a best-effort substrate is a real, testable question, and it is *not yet proven*.

---

## Why a new approach at all

Traditional primary distribution — satellite, leased fibre, MPLS — succeeds by *engineering determinism into a dedicated or managed layer and charging for the guarantee*. That model works and its buyers are structurally conservative. But the plant around it has gone software-defined and API-driven, linear revenue is declining (pressuring the fixed cost of dedicated capacity), rights are increasingly global and dynamic, and the QUIC/HTTP-3 substrate needed for an Internet-native alternative now exists as a commodity. The full argument, with the strongest counter-cases, is in [Vision](docs/vision.md).

## Why MoQ, and why it differs from SRT/Zixi/RIST

SRT, Zixi and RIST already move a linear feed reliably from A to B. MoQ's *incremental* advantage on that narrow job is real but narrow; what distinguishes it is architectural, not raw performance:

- **Native relay and 1:N amplification** (the advantage we put forward first): a single protocol carries a feed from contribution through a relay fabric that fans out point-to-multipoint, with caching, on the QUIC/HTTP-3 substrate CDNs and hyperscalers already run.
- **Subscription-oriented delivery**, which maps directly onto dynamic, revocable entitlement.
- **A native authorization point** at subscription (the platform layers path-scoped tokens, mTLS, and expiry on it).
- **Graceful congestion behaviour** instead of head-of-line blocking (strongest on the default media-aware lane, constrained on the opaque fallback).

These matter most at fan-out scale and heterogeneity — precisely where primary distribution is *least* heterogeneous, so the fit must be tested, not assumed. Developed in [Vision](docs/vision.md) and [Transport](docs/transport.md).

## Why this might fail

The strongest reasons the thesis fails, each testable rather than rhetorical:

- **The transport isn't stable enough (highest technical risk).** MoQ is pre-standard; recent drafts are "almost a completely new protocol," while broadcasters need 5–10 year stability. *Mitigation:* keep the media and control layers transport-independent (already done — see [Evidence](docs/evidence.md)), so the control plane can run over today's transports if MoQ slips ([Transport](docs/transport.md) §5.2).
- **MoQ's advantage over SRT/Zixi/RIST is too narrow for *this* job (highest thesis risk).** *Test:* a real head-to-head lab ([Implementation](docs/implementation.md) §6) and a TCO model built on one broadcaster's actual route costs ([Economics](docs/economics.md)).
- **Hardware IRDs reject groomed MoQ output (potential showstopper).** MoQ's object/burst model yields PCR that hardware IRDs flag on TR 101 290 P1/P2 — inherent, not a bug. Grooming addresses it but must be *proven on real hardware*. *Test (in progress):* a clean P1/P2 pass on real IRDs ([Evidence](docs/evidence.md), [Architecture](docs/architecture.md) §7.2 and §17).

---

## Repository

Read [Vision](docs/vision.md) for the *why*, [Transport](docs/transport.md) for *why MoQ specifically*, [Architecture](docs/architecture.md) for *how it would be engineered*, and [Implementation](docs/implementation.md) for *how to build and test it*. The remaining documents are topic deep-dives.

| Document | Description |
|----------|-------------|
| [Vision](docs/vision.md) | Why broadcast primary distribution is changing — industry problem, opportunity, and critical analysis. |
| [Transport](docs/transport.md) | Why MoQ specifically; QUIC/WebTransport, MPEG-TS/MSFTS carriage, and draft-stability strategy. |
| [Architecture](docs/architecture.md) | End-to-end reference architecture for a broadcast-grade MoQ distribution platform. |
| [Implementation](docs/implementation.md) | Components, prerequisites, reference deployment, and the test path to the hardware-IRD proof. |
| [Test Plan & Results](docs/test-plan.md) | The validation campaign: methodology, pass criteria, and **measured results** — baseline TS characterisation, transport transparency on both lanes, remote end-to-end over the public internet, and network-impairment behaviour, plus the roadmap to the hardware-IRD proof. |
| [Relay](docs/relay.md) | Relay fabric, routing, fan-out, federation, and resilience. |
| [Control Plane](docs/control-plane.md) | Provisioning and orchestration. |
| [Entitlement](docs/entitlement.md) | Dynamic, revocable distribution rights. |
| [Security](docs/security.md) | Identity, authentication, and threat model. |
| [Interoperability](docs/interoperability.md) | IRDs, MPEG-TS, RTP, ST 2022-7, SRT, Zixi. |
| [Operations](docs/operations.md) | NOC model, SLOs, monitoring, and runbooks. |
| [Economics](docs/economics.md) | Cost model and operational comparison. |
| [Evidence](docs/evidence.md) | What the working prototype proved — the empirical basis for the claims above. |

---

## Contributing and feedback

This is a public, living reference whose purpose is to be tested and challenged.
Corrections, counter-evidence, and disagreement are actively wanted — see
[CONTRIBUTING](CONTRIBUTING.md) for how to raise an issue, start a discussion, or
propose a change, and for the editorial and confidentiality conventions.

---

## Open questions

- What is the real TCO delta versus one broadcaster's actual routes? ([Economics](docs/economics.md))
- Does groomed MoQ output pass TR 101 290 P1/P2 on real hardware IRDs? ([Evidence](docs/evidence.md))
- Where does the groomer (PCR-accuracy work) ultimately live — upstream or downstream — and if downstream, open/interoperable or closed/licensed? ([Architecture](docs/architecture.md) §17)

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

- MOQ-dev implementation: https://github.com/moq-dev/moq
- MPEG-TS VBR to CBR Pacer : https://github.com/tdrapier-wbd/mpegts-pacer
- OpenMOQ: https://openmoq.org/
- IETF MOQ working group: https://datatracker.ietf.org/group/moq/about/
- MOQ Transport IETF working group working area https://github.com/moq-wg/moq-transport
- MSFTS: https://github.com/mondain/msfts
- MPEG-TS over MOQ: https://edis.mx/insights/mpeg-ts-over-moq.html
- MPEG-TS over MOQ — PCR: https://edis.mx/insights/mpeg-ts-over-moq-pcr.html
- MPEG-TS over MOQ — pacing: https://edis.mx/insights/mpeg-ts-over-moq-pacing.html
- MOQ Interop Runner: https://github.com/englishm/moq-interop-runner

---

*This is a living document. Its purpose is to be proven wrong quickly and cheaply.*

# Internet-Native Primary Distribution for Professional Broadcast

**A technical evaluation of the two data planes that can carry it: Media over QUIC (MoQ), and segmented HTTP carrying MPEG-TS (HLS).**

Status: working draft. AI assistance was heavily used in drafting.

---

## The decision question

**Broadcast's trunk layer has already moved onto the public internet — it just hasn't scaled.** Zixi and SRT carry contracted feeds over commodity internet today. What they cannot do is replace a satellite transponder, because they are point-to-point tunnels: serving N destinations costs N sessions, where satellite serves a whole footprint for the price of one.

The question is **whether an IP path can serve hundreds to low thousands of delivery points economically, at broadcast conformance and broadcast reliability** — which needs a cache in the path rather than a better tunnel ([Problem](docs/problem.md)).

## The conclusion

**The transport is not the decision.** Both candidates are unicast at the last mile, and both need the same broadcast-grade edge stage to produce a TR 101 290-conformant transport-stream hand-off — a stage neither specification mentions and which the taker must own, because broadcasters no longer supply its clients' receivers. Most of the engineering, and most of the risk, sits _above_ the transport ([Comparison](docs/comparison.md), [Architecture](docs/architecture.md)).

**Segmented HTTP has a mature cache-delivery model and, at classic segment durations, an off-the-shelf receive path.** The IRD estate does not consume HLS, so a stage must reassemble and groom it into a transport stream: free tools do so to TR 101 290 P1/P2 in software, but none survives an origin failure, and the commercial receivers that take HLS align on nothing beyond HLS itself. A segment lost at one edge is refetched from another, so its recovery advantage is real in the protocol and conditional on a resilient, observable receive stage, which a distributor could specify and open to vendors ([Comparison](docs/comparison.md) §6.2, §4, §9.1; [Economics](docs/economics.md) §8.5).

**The two Internet-native planes are level on latency at the configurations measured TR 101 290-conformant in software**, so latency no longer makes MoQ’s case on a multi-second route. Nor, at conformance, does MoQ necessarily beat the point-to-point incumbents it would displace. Nothing below about one second was conformant over a whole capture on any lane, so MoQ’s strategic sub-second case is architecturally credible but not yet evidenced ([Comparison](docs/comparison.md) §5.1, [Evidence](lab/evidence.md) §3.11).

**Two things separate a credible evaluation from a deployable one, and neither is a transport property.** The make-or-break conformance gate, on hardware receivers and analysers, has never been attempted. And relay capacity is not yet substitutable: a MoQ feed crosses most other implementations' relays tested, but fewer for a subscriber joining mid-stream, and the economic case for MoQ depends on relay capacity being a market the buyer can shop ([Evidence](lab/evidence.md) §3.7, [Economics](docs/economics.md) §4.6).

**On cost, the protocol barely registers.** The bill is set by destination count and by which delivery market the capacity is bought in; the entire measured difference between the transports is a few percent of it ([Economics](docs/economics.md)).

## What constrains it

- **The TR 101 290 P1/P2 gate was met in software on both planes**, in the edge stage ([Evidence](lab/evidence.md) §3.2). That is not full conformance on MoQ's media-aware lane, which splits the transport stream into per-track media: as a transmux it discards the source's packet schedule, and its wire fails the 13818-1 buffer model, which segmented HTTP's wire passes. Only a re-multiplexer repairs it, which upstream's subscriber builds in, graded in software ([Evidence](lab/evidence.md) §3.16).
- **A fully Internet-native path is not the only answer to the same pressure.** Satellite-hybrid architectures keep the space segment as the fan-out and use IP only to repair what an individual site lost. They concede latency and footprint, need a hybrid-capable receiver at every site that is to benefit, and nothing here measures them — but they are the live alternative on exactly the large, single-footprint estates where both planes above are weakest ([Problem](docs/problem.md) §4, [Comparison](docs/comparison.md) §1.2, [Economics](docs/economics.md) §6.1).

---

## The documents

| Document | Layer | What it is |
| --- | --- | --- |
| [Primer](docs/primer.md) | Background | How MPEG-TS, SRT, segmented HTTP and MoQ work |
| [Problem](docs/problem.md) | Requirement | Why primary distribution is changing, and the requirement set (R1–R8) everything else is scored against |
| [Comparison](docs/comparison.md) | **Data plane** | The head-to-head, each requirement scored lane by lane |
| [Architecture](docs/architecture.md) | **Above the transport** | The reference architecture; the edge gateway and 1+1 redundancy come first as the measured part |
| [Control, Entitlement and Security](docs/control-plane.md) | Above the transport | Provisioning, entitlement, threat model. **Design, except the enforcement layer, which is measured** |
| [Evidence](lab/evidence.md) | Lab record | Method, instruments, results by question, and the limits of the evidence |
| [Economics](docs/economics.md) | Cross-cutting | Cost framework, the always-on model at published rates, and the ownership questions that follow |
| [Getting started](docs/getting-started.md) | Hands-on | MoQ and segmented HTTP end to end on one machine, with released tools and checks |
| [Glossary](docs/glossary.md) | — | The two vocabularies side by side, in broadcast terms |

**The engineering record** is the laboratory notebook in [`lab/`](lab/README.md): the campaign plan with pass criteria fixed before the numbers, per-experiment procedures and results, the measurement rules in [`lab/method-notes.md`](lab/method-notes.md), and what was reported and verified in other projects in [`lab/upstream-contributions.md`](lab/upstream-contributions.md).

**Code contributed back** is a media-level test client for the community [MOQ Interop Runner](https://github.com/englishm/moq-interop-runner), in [`lab/interop/`](lab/interop/README.md), and the grooming component, a separate public crate, [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer).

---

## Contributing

This is a public, living reference whose purpose is to support primary distribution discussions. Corrections, counter-evidence and disagreement are welcome.

## Author

**Thomas Drapier** — Skydance (Warner Bros. Discovery), Senior Director, Service Management & Partner Services, Broadcast Distribution Engineering (EMEA). [LinkedIn](https://www.linkedin.com/in/tdrapier/)

---

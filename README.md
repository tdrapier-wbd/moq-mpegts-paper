# Internet-Native Primary Distribution for Professional Broadcast

**A technical evaluation of the two data planes that can carry it: Media over QUIC (MoQ), and segmented HTTP carrying MPEG-TS (HLS).**

Status: working draft. AI assistance was heavily used in drafting.

---

## The decision question

**Broadcast's trunk layer has already moved onto the public internet — it just hasn't scaled.** Zixi and SRT carry contracted feeds over commodity internet today. What they cannot do elegantly is replace a satellite transponder, because they are point-to-point tunnels: serving N destinations costs N sessions, where satellite serves a whole footprint for the price of one.

The question is **whether an IP path can serve hundreds to low thousands of delivery points economically, at broadcast conformance and broadcast reliability** — which needs a cache in the path rather than a better tunnel ([Problem](docs/problem.md)).

## The conclusion

**The transport is not the decision.** Both candidates are unicast at the last mile, and both need the same broadcast-grade edge stage to produce a TR 101 290-conformant transport-stream hand-off — a stage neither specification mentions and which the taker must own, because broadcasters no longer supply its clients' receivers. Most of the engineering, and most of the risk, sits _above_ the transport ([Comparison](docs/comparison.md), [Architecture](docs/architecture.md)).

**For an IRD estate, MoQ's passthrough lane leads and segmented HTTP is the hedge.** The passthrough lane carries the source's bytes, scrambled and multi-programme feeds included, so an IRD is judged on the source's own conformance, and its legs merge hitlessly when started apart; what it lacks is evidence of permanence. MoQ's media-aware lane, which rebuilds the multiplex, is held for routes that need per-track delivery ([Comparison](docs/comparison.md) §11).

**Segmented HTTP has a mature cache-delivery model and, at classic segment durations, an off-the-shelf receive path.** Free tools reassemble and pace it into a transport stream to TR 101 290 P1/P2 in software, but none survives an origin failure, and the commercial receivers that take HLS align on nothing beyond HLS itself. Its recovery advantage is real in the protocol and conditional on a resilient, observable receive stage ([Comparison](docs/comparison.md) §6.2, §4, §9.1; [Economics](docs/economics.md) §8.5).

**The two Internet-native planes are level on latency at the configurations measured TR 101 290-conformant in software**, so latency does not make MoQ's case on a multi-second route, and nothing below about one second was conformant over a whole capture on any lane ([Comparison](docs/comparison.md) §5.1, [Evidence](lab/evidence.md) §3.11).

**Three things separate a credible evaluation from a deployable one, and none is a transport property.** The make-or-break gate, a hardware IRD fed for a sustained period, has not been run; the receiving site's own monitors have watched every lane for about a week, without an IRD behind them. Relay capacity is not yet substitutable: a MoQ feed crosses most other implementations' relays tested, but fewer for a subscriber joining mid-stream, and MoQ's economics depend on relay capacity being a market the buyer can shop ([Evidence](lab/evidence.md) §3.7, [Economics](docs/economics.md) §4.6). And nothing yet operates it at fleet scale: provisioning, monitoring and a receiver a third party installs unaided are design, not product ([Problem](docs/problem.md) §5, [Control](docs/control-plane.md) §2.3).

**On cost, the protocol barely registers.** The bill is set by destination count and by which delivery market the capacity is bought in; the entire measured difference between the transports is a few percent of it ([Economics](docs/economics.md)).

## What constrains it

- **In software, both planes' hand-offs meet TR 101 290 P1/P2, and the passthrough lane delivers the source's own packet schedule**, so an IRD sees what the source sent; segmented HTTP's paced wire also passes the 13818-1 buffer model. The media-aware lane's rebuilt multiplex fails it, one reason that lane is held ([Evidence](lab/evidence.md) §3.2, §3.16).
- **A fully Internet-native path is not the only answer to the same pressure.** Satellite-hybrid architectures keep the space segment as the fan-out and use IP only to repair what an individual site lost. They concede latency and footprint, need a hybrid-capable receiver at every site that is to benefit, and nothing here measures them — but they are the live alternative on exactly the large, single-footprint estates where both planes above are weakest ([Problem](docs/problem.md) §4, [Comparison](docs/comparison.md) §1.2, [Economics](docs/economics.md) §6.1).

---

## The documents

| Document | Layer | What it is |
| --- | --- | --- |
| [Primer](docs/primer.md) | Background | How MPEG-TS, SRT, segmented HTTP and MoQ work |
| [Problem](docs/problem.md) | Requirement | Why primary distribution is changing, and the requirement set (R1–R9) everything else is scored against |
| [Comparison](docs/comparison.md) | **Data plane** | The head-to-head, each requirement scored lane by lane |
| [Architecture](docs/architecture.md) | **Above the transport** | The reference architecture; the edge gateway and 1+1 redundancy come first as the measured part |
| [Control, Entitlement and Security](docs/control-plane.md) | Above the transport | Provisioning, entitlement, threat model. **Design, except the enforcement layer, which is measured** |
| [Evidence](lab/evidence.md) | Lab record | Method, instruments, results by question, and the limits of the evidence |
| [Economics](docs/economics.md) | Cross-cutting | Cost framework, the always-on model at published rates, and the ownership questions that follow |
| [Getting started](docs/getting-started.md) | Hands-on | MoQ and segmented HTTP end to end on one machine, with released tools and checks |
| [Glossary](docs/glossary.md) | — | The two vocabularies side by side, in broadcast terms |

**The engineering record** is the laboratory notebook in [`lab/`](lab/README.md): the campaign plan with pass criteria fixed before the numbers, per-experiment procedures and results, the measurement rules in [`lab/method-notes.md`](lab/method-notes.md), and what was reported and verified in other projects in [`lab/upstream-contributions.md`](lab/upstream-contributions.md).

**Code contributed back** is a media-level test client for the community [MOQ Interop Runner](https://github.com/englishm/moq-interop-runner), in [`lab/interop/`](lab/interop/README.md), and the pacing component, a separate public crate, [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer).

---

## Contributing

This is a public, living reference whose purpose is to support primary distribution discussions. Corrections, counter-evidence and disagreement are welcome.

## Author

**Thomas Drapier** — Skydance (Warner Bros. Discovery), Senior Director, Service Management & Partner Services, Broadcast Distribution Engineering (EMEA). [LinkedIn](https://www.linkedin.com/in/tdrapier/)

---

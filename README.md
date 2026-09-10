# Internet-Native Primary Distribution for Professional Broadcast

**A technical evaluation of Internet-native primary distribution for professional broadcast, on the
two data planes that can carry it: Media over QUIC (MoQ), and segmented HTTP carrying MPEG-TS (HLS).**

Status: working draft. AI assistance was heavily used in drafting.

---

## The decision question

**Broadcast's trunk layer has already moved onto the public internet — it just hasn't scaled.** Zixi and
SRT carry contracted feeds over commodity internet today, sold as a product by AWS Elemental
MediaConnect, LTN and others. What they cannot do is replace a satellite transponder, because they are
point-to-point tunnels: serving N destinations costs N sessions, where satellite serves a whole
footprint for the price of one.

So the question is not whether broadcast can trust the internet. It is **whether an IP path can serve
hundreds to low thousands of delivery points economically, at broadcast conformance and broadcast
reliability** — which needs a cache in the path rather than a better tunnel
([Problem](docs/problem.md)).

## The conclusion

**The transport is not the decision, and that is the most consequential finding here.** Both candidates are unicast at the last mile, both land within a few percent of the same wire volume,
and both need the same broadcast-grade edge stage to produce a TR 101 290-conformant transport-stream hand-off — a stage
neither specification mentions and which the taker must own, because broadcasters no longer supply its clients'
receivers. Most of the engineering, and most of the risk, sits *above* the transport
([Comparison](docs/comparison.md), [Architecture](docs/architecture.md)).

**Segmented HTTP has a mature cache-delivery model, not an out-of-box broadcast receiver path.** Named segments can be served through commodity CDN infrastructure and retried from another edge while they remain within their availability window. But the target IRD estate does not consume HLS directly: it still needs distributor-owned reassembly, grooming and TS-egress stage. This evaluation did not demonstrate an interoperable, low-latency TS-in-HLS receiving path: free receivers fell back to whole segments, while the commercial ABR-to-TS path remains untested. The measured recovery advantage is therefore conditional and does not establish end-to-end receiver interoperability ([Comparison](docs/comparison.md) §3.2, §4, §5.1).

**MoQ beats the other Internet-native plane decisively on latency at the configurations measured conformant in software.** That makes the case for MoQ on routes with a roughly two-to-nine-second delivery budget. But at conformance it does not necessarily beat the point-to-point incumbents it would displace, which carry their source’s own conformant timing and buy their latency with a jitter buffer the operator sets. No conformant sub-second configuration was produced on any lane, so MoQ’s strategic sub-second case is architecturally credible but not yet evidenced ([Comparison](docs/comparison.md) §5.1, ([Evidence](docs/evidence.md) §3.11).

**Two things separate a credible evaluation from a deployable one, and neither is a transport property.**
The make-or-break conformance gate has never been attempted — nothing here has been fed to a hardware
receiver or graded by a hardware analyser, so every conformance result is software. And a MoQ feed
carries no media through any third-party relay tested, which matters commercially rather than
technically, because the economic case for MoQ depends on relay capacity being a market the buyer can
shop ([Evidence](docs/evidence.md) §3.7, [Economics](docs/economics.md) §4.6).

**On cost, the protocol barely registers.** The bill is set by destination count and by which delivery
market the capacity is bought in — published cloud egress sits about an order of magnitude above
commodity delivery, while the entire measured difference between the transports is a few percent of it
([Economics](docs/economics.md)).

## What decides or constrains that conclusion

- **The conformance gate was met and sustained in software on both planes**, on the media-aware lane
  over a full day. It closed downstream in the edge stage, after three upstream fixes that were each
  necessary and none sufficient ([Evidence](docs/evidence.md) §3.2).
- **Conformance is not free of latency there, though buffer depth is not the price.** Part of the cost is
  an identified upstream regression that could be recovered; the rest is structural, because a demuxed
  lane moves the contribution encoder's buffer budget downstream into the edge gateway
  ([Comparison](docs/comparison.md) §5.1).
- **A fully Internet-native path is not the only answer to the same pressure.** Satellite-hybrid
  architectures keep the space segment as the fan-out and use IP only to repair what an individual site
  lost, which answers the economics of the thousandth destination without an IP data plane at all. They
  concede latency and footprint, need a hybrid-capable receiver at every site that is to benefit, and
  nothing here measures them — but they are the live alternative on exactly the large, single-footprint
  estates where both planes above are weakest ([Problem](docs/problem.md) §4,
  [Comparison](docs/comparison.md) §10.2, [Economics](docs/economics.md) §6.1).

---

## The documents

Three layers, because that is the argument: if the conclusion is that the data plane is the small part of
the problem, the structure should show which part is which.

| Document | Layer | What it is |
|---|---|---|
| [Problem](docs/problem.md) | Requirement | Why primary distribution is changing, and the requirement set (R1–R8) everything else is scored against |
| [Comparison](docs/comparison.md) | **Data plane** | The head-to-head, with the evidence type marked on every verdict row |
| [Architecture](docs/architecture.md) | **Above the transport** | The reference architecture; the edge gateway and 1+1 redundancy come first as the measured part |
| [Control, Entitlement and Security](docs/control-plane.md) | Above the transport | Provisioning, entitlement, threat model. **Design only — nothing here is built or measured** |
| [Evidence](docs/evidence.md) | Cross-cutting | Method, instruments, results by question, and the limits of the evidence |
| [Economics](docs/economics.md) | Cross-cutting | Cost framework, the always-on model at published rates, and the ownership questions that follow |
| [Glossary](docs/glossary.md) | — | The two vocabularies side by side, in broadcast terms |

**The engineering record** is the laboratory notebook in [`lab/`](lab/README.md): the campaign plan with
pass criteria fixed before the numbers, and per-experiment procedures, commands and measured results.
[`lab/method-notes.md`](lab/method-notes.md) collects the measurement rules the campaign learned the hard
way, and [`lab/upstream-contributions.md`](lab/upstream-contributions.md) records what was found,
reported and verified in other projects.

**Code contributed back** is in [`interop/`](interop/README.md) — a media-level test client for the
community [MOQ Interop Runner](https://github.com/englishm/moq-interop-runner), on the argument that a
transport stream checks itself, so no decoder or frame capture is needed. The grooming component is a
separate public crate, [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer).

---

## Contributing

This is a public, living reference whose purpose is to support primary distribution discussions. Corrections,
counter-evidence and disagreement are welcome.

## Author

**Thomas Drapier** — Warner Bros. Discovery, Senior Director, Service Management & Partner Services, Broadcast Distribution Engineering. [LinkedIn](https://www.linkedin.com/in/tdrapier/)

---
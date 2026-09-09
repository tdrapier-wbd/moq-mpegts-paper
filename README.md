# Internet-Native Primary Distribution for Professional Broadcast

**A technical evaluation of Internet-native primary distribution for professional broadcast, on the
two data planes that can carry it: Media over QUIC (MoQ), and segmented HTTP carrying MPEG-TS.**

Status: working draft. This is deliberately critical: the goal is to find the fastest way to
*disprove* the thesis, not to sell it. AI assistance was used in drafting
([Contributing](CONTRIBUTING.md)).

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

**The transport is not the decision, and that is the most consequential finding here.** Both candidates
ride QUIC, both are unicast at the last mile, both land within a few percent of the same wire volume,
and both need the same broadcast-grade edge stage before a hardware receiver will lock to them — a stage
neither specification mentions and which the distributor owns, because it no longer supplies its clients'
receivers. Most of the engineering, and most of the risk, sits *above* the transport
([Comparison](docs/comparison.md), [Architecture](docs/architecture.md)).

**Segmented HTTP is the better engineering choice today for any route that can absorb seconds.** It is
universally interoperable, sells over commodity delivery now, has the more robust recovery model and an
off-the-shelf path back to a transport stream, and — measured — is verbatim in payload for a single
programme, so the carriage-fidelity advantage usually assumed for MoQ survives only on a multi-programme
mux ([Comparison](docs/comparison.md) §14).

**MoQ's distinguishing claim is latency, and it holds in a narrower form than the headline figure
suggests.** That figure was measured on a configuration whose wire cannot be made conformant to
TR 101 290. Held at the conformance a hardware receiver actually
requires, MoQ still beats the other Internet-native plane decisively — a real margin, and the case for
MoQ on routes in roughly the two-to-nine-second band. But at conformance it no longer beats the
point-to-point incumbents it would displace, which carry their source's own conformant timing and buy
their latency with a jitter buffer the operator sets. **No conformant sub-second configuration was
produced on any lane**, so the band on which MoQ's strategic case rests is architecturally credible and
not yet evidenced ([Comparison](docs/comparison.md) §5.1, [Evidence](docs/evidence.md) §3.11).

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
- **A conformant result currently depends on which build is deployed** — two known defects sit in
  different builds, so every available build carries one of them ([Evidence](docs/evidence.md) §3.13).
- **Hitless 1+1 is measured end to end on both planes and scoped differently on each**, and a healthy
  transport does not imply a live programme: detecting a partial media-plane failure needs per-stream
  instrumentation no conformance check provides ([Evidence](docs/evidence.md) §3.4, §3.12).

## What is not established

No hardware conformance pass on either plane; no conformant sub-second configuration on any lane; no
cross-implementation interop; no measurement beyond a day; latency measured only on healthy paths;
multi-programme carriage through a real CDN; and one publisher-side resource leak that blocks permanent
operation in that role. The full accounting is [Evidence](docs/evidence.md) §4 and §5.

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

This is a public, living reference whose purpose is to be tested and challenged. Corrections,
counter-evidence and disagreement are actively wanted — see [Contributing](CONTRIBUTING.md) for how to
raise an issue, and for the editorial and confidentiality conventions.

## Author

**Thomas Drapier** — Senior Director, Service Management & Partner Services, Broadcast Distribution
Engineering. [LinkedIn](https://www.linkedin.com/in/tdrapier/)

---

*This is a living document. Its purpose is to be proven wrong quickly and cheaply.*

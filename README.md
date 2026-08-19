# Internet-Native Primary Distribution for Professional Broadcast

**A technical evaluation of Internet-native primary distribution for professional broadcast, on the
two data planes that can carry it: Media over QUIC (MoQ), and segmented HTTP carrying MPEG-TS.**

Status: working draft. This is deliberately critical: the goal is to find the fastest way to
*disprove* the thesis, not to sell it. AI assistance was used in drafting
([Contributing](CONTRIBUTING.md)).

---

## The question

**Broadcast's trunk layer has already moved onto the public internet — it just hasn't scaled.** Zixi and
SRT carry contracted feeds over commodity internet today, sold as a product by AWS Elemental
MediaConnect, LTN and others. What they cannot do is replace a satellite transponder, because they are
point-to-point tunnels: serving N destinations costs N sessions. Satellite serves everyone in its footprint for the price
of one.

So the question is not whether broadcast can trust the internet — that argument is over and the internet
won. It is **whether an IP path can serve hundreds to low thousands of delivery points economically**,
which needs a cache in the path rather than a better tunnel. This repository asks what such a replacement
has to do ([Problem](docs/problem.md)), and which data plane can do it.

## The answer, in three sentences

**The transport is not the decision.** Both candidate data planes ride QUIC, both are unicast at the
last mile, both land within 7 % of the same wire volume, and — measured — both need the same edge
stage before a hardware IRD will lock to them, which neither specification mentions and which the
distributor owns because it no longer supplies its clients' receivers.

**Segmented HTTP is ahead today where it counts commercially** — universally interoperable, sells
over commodity delivery now, the more robust recovery model, an off-the-shelf path back to a
transport stream, and, measured, byte-verbatim for a single programme, so the fidelity advantage
usually assumed for MoQ survives only on a multi-programme mux.

**What MoQ has is an egress two orders of magnitude easier to pace, ~7 % less wire volume, and a
measured 109 ms across the public internet** — 15× lower than SRT over the same path. That last figure
matters most, because the sub-second band is the only ground on which MoQ's case rests, and it is now a
measurement rather than an inference.

## What is proven, and what is not

| Standing | What the evidence shows |
|---|---|
| **Demonstrated** | A live contribution mux traverses the whole chain over the public internet with 0 continuity errors. Grooming restores exact CBR and P2-limit PCR accuracy **on file**. A doubled chain with two stream-clocked groomers is byte-identical and hitless through publisher, relay and exporter death, against a reference receiver, on single-track content. Loss resilience reaches parity with SRT once the congestion controller is chosen. Segmented HTTP is byte-verbatim for one programme and ~240× burstier to groom. Against segmented HTTP the two planes have **disjoint weaknesses and the ranking inverts** — MoQ on BBR holds 0.96 of source rate through 10 % loss where segmented HTTP over TCP falls to 0.17, and under 25 % reordering they swap exactly, 0.98 against 0.19 — while segmented HTTP never corrupts what it does deliver. |
| **Measured, and positive** | **MoQ delivers a picture from an EC2 origin to a groomed transport-stream egress here in 109 ms** — 15× lower than SRT and 37× lower than segmented HTTP over the same path in the same window, and on loopback lower even than a plain-UDP control carrying no transport buffer at all. The path costs its round trip and nothing more. |
| **Measured, and negative** | A MoQ feed carries media through **none** of eight third-party relays. The MoQ lane fails P1 PCR repetition on the wire at **every** buffer depth — 489–504 intervals above 40 ms, unchanged by depth, by removing groomer starvation, or by the path — because the exporter emits PCRs too rarely for any groomer to place them. |
| **Not established** | **No hardware IRD has ever been fed by this chain.** Whether fixing the exporter's PCR cadence clears the gate is untested, and it is the question that now decides the thesis. The latency measurements were taken on healthy paths, and the impairment ladder ran against a single plain origin rather than a CDN edge, so the failover half of segmented HTTP's recovery model is still specification-only. |

The full accounting, with every limit stated in one place, is [Evidence](docs/evidence.md) §4 and §5.

---

## The documents

Three layers, because that is the argument. If the conclusion is that the data plane is the small
part of the problem, the structure should show which part is which.

| Document | Layer | What it is |
|---|---|---|
| [Problem](docs/problem.md) | Requirement | Why primary distribution is changing, and the numbered requirement set (R1–R8) everything else is scored against |
| [Comparison](docs/comparison.md) | **Data plane** | The head-to-head: MoQ against segmented HTTP carrying MPEG-TS, and against SRT/Zixi/RIST, on twelve axes with the evidence type marked on each |
| [Architecture](docs/architecture.md) | **Above the transport** | The reference architecture. The edge gateway and 1+1 redundancy come first because they are the substance and the measured part |
| [Control, Entitlement and Security](docs/control-plane.md) | Above the transport | Provisioning, entitlement and the threat model. **Design only — nothing here has been built or measured** |
| [Evidence](docs/evidence.md) | Cross-cutting | Method, instruments, results by question, and the limits of the evidence |
| [Economics](docs/economics.md) | Cross-cutting | Cost framework, and a numeric model of the always-on case at published rates |
| [Glossary](docs/glossary.md) | — | The two vocabularies side by side, in broadcast terms |

**The engineering record** is the laboratory notebook in [`lab/`](lab/README.md): the campaign plan
with pass criteria fixed before the numbers, and per-experiment procedures, commands and measured
results. [`lab/method-notes.md`](lab/method-notes.md) collects the measurement rules the campaign
learned the hard way, which are as transferable as the results.

**Code contributed back** is in [`interop/`](interop/README.md) — a media-level test client for the
community [MOQ Interop Runner](https://github.com/englishm/moq-interop-runner), carrying an MPEG-TS
fixture through a relay and validating what comes out, on the argument that a transport stream checks
itself so no decoder or frame capture is needed. The CBR grooming component is a separate public
crate, [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer).

---

## Contributing

This is a public, living reference whose purpose is to be tested and challenged. Corrections,
counter-evidence and disagreement are actively wanted — see [Contributing](CONTRIBUTING.md) for how
to raise an issue, and for the editorial and confidentiality conventions.

## Author

**Thomas Drapier** — Senior Director, Service Management & Partner Services, Broadcast Distribution
Engineering. [LinkedIn](https://www.linkedin.com/in/tdrapier/)

---

## References

**Implementations**

- MOQ-dev (media-aware lane; publisher, relay, subscriber): https://github.com/moq-dev/moq
- Cloudflare `moq-rs` (IETF-aligned transport library and production relay, media-agnostic): https://github.com/cloudflare/moq-rs
- Cloudflare MoQ relay service and provisioning API: https://developers.cloudflare.com/moq/
- `moq2ts` (transparent MPEG-TS publisher): https://github.com/mondain/moq2ts
- `moqxr` / OpenMOQ Publisher: https://github.com/mondain/moqxr
- MPEG-TS VBR to CBR pacer: https://github.com/tdrapier-wbd/mpegts-pacer
- `rawsendmpeg2ts` (datagram sender): https://github.com/EDIS-mx/rawsendmpeg2ts

**Standards and formats**

- IETF MOQ working group: https://datatracker.ietf.org/group/moq/about/
- MOQT Streaming Format (MSF), adopted WG draft: https://datatracker.ietf.org/doc/draft-ietf-moq-msf/
- CMSF (CMAF profile of MSF): https://datatracker.ietf.org/doc/draft-ietf-moq-cmsf/
- MSFTS (MPEG-TS profile): https://github.com/mondain/msfts
- HTTP Live Streaming 2nd Edition (obsoletes RFC 8216; includes Low-Latency HLS and MPEG-TS segment carriage): https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/
- DVB-MABR, adaptive media streaming over IP multicast (ETSI TS 103 769): https://dvb.org/?standard=adaptive-media-streaming-over-ip-multicast

**Testing and background**

- MOQ Interop Runner: https://github.com/englishm/moq-interop-runner
- MPEG-TS over MOQ: https://edis.mx/insights/mpeg-ts-over-moq.html
- MPEG-TS over MOQ — PCR: https://edis.mx/insights/mpeg-ts-over-moq-pcr.html
- MPEG-TS over MOQ — pacing: https://edis.mx/insights/mpeg-ts-over-moq-pacing.html

---

*This is a living document. Its purpose is to be proven wrong quickly and cheaply.*

# Internet-Native Primary Distribution for Professional Broadcast

**A technical evaluation of Internet-native primary distribution for professional broadcast, on the
two data planes that can carry it: Media over QUIC (MoQ), and segmented HTTP carrying MPEG-TS.**

Status: working draft. This is deliberately critical: the goal is to find the fastest way to
*disprove* the thesis, not to sell it. AI assistance was used in drafting
([Contributing](CONTRIBUTING.md)).

---

## The question

**Broadcast's trunk layer has already moved onto the public internet — it just hasn't scaled.** Zixi
and SRT carry contracted feeds over commodity internet today, sold as a product by AWS Elemental
MediaConnect, LTN and others. What they cannot do is replace a satellite transponder, because they
are point-to-point tunnels: serving N destinations costs N sessions. Satellite serves everyone in its
footprint for the price of one.

So the question is not whether broadcast can trust the internet — that argument is over and the
internet won. It is **whether an IP path can serve hundreds to low thousands of delivery points
economically**, which needs a cache in the path rather than a better tunnel. This repository asks what
such a replacement has to do ([Problem](docs/problem.md)), and which data plane can do it.

## The answer

**The transport is not the decision.** Both candidate data planes ride QUIC, both are unicast at the
last mile, both land within 7 % of the same wire volume, and — measured — both need the same edge
stage before a hardware IRD will lock to them, which neither specification mentions and which the
distributor owns because it no longer supplies its clients' receivers
([Comparison](docs/comparison.md) §4 and §14, [Evidence](docs/evidence.md) §3.2, §3.5).

**Segmented HTTP is ahead today where it counts commercially** — universally interoperable, sells over
commodity delivery now, the more robust recovery model, an off-the-shelf path back to a transport
stream, and, measured, verbatim in payload for a single programme, so the fidelity advantage usually
assumed for MoQ survives only on a multi-programme mux ([Comparison](docs/comparison.md) §6, §8).

**What MoQ has is an egress two orders of magnitude easier to pace, ~7 % less wire volume, and a
measured 109 ms across the public internet.** That last one matters most: the sub-second band is the
only ground on which MoQ's case rests, and it is now a measurement rather than an inference.

## The strongest positive results

- **A live contribution mux crosses the public internet with 0 continuity errors**, service layer
  intact — identity, PMT and PCR PIDs, AC-3 typing, teletext and all three SCTE-35 PIDs
  ([Evidence](docs/evidence.md) §3.1).
- **All three lanes carry a broadcast mux**, each departing from verbatim differently: SRT on no
  criterion, segmented HTTP by one injected PAT/PMT pair per segment, the media-aware lane by stuffing,
  mux rate, PSI density and PCR spacing ([Evidence](docs/evidence.md) §3.1).
- **MoQ delivers a picture from an EC2 origin to a groomed transport-stream egress in 109 ms** — 15×
  lower than SRT and 37× lower than segmented HTTP over the same path in the same window, and on
  loopback lower even than a plain-UDP control carrying no transport buffer at all. The path costs its
  round trip and nothing more ([Evidence](docs/evidence.md) §3.11).
- **Loss does not separate the two data planes; reordering does.** At a matched congestion controller
  both hold full rate through 10 % loss and both collapse under CUBIC, while under 25 % reordering the
  media-aware lane reads 0.19 against segmented HTTP's 0.98 on either controller
  ([Evidence](docs/evidence.md) §3.3).
- **A segmented 1+1 pair sharing one feed and one naming scheme fails over with no measurable
  interruption and no receiver-side merge**, where the media-aware floor is one detection interval. On
  the media-aware lane, two stream-clocked groomers are byte-identical and hitless through publisher,
  relay and exporter death, against a reference receiver, on single-track content
  ([Evidence](docs/evidence.md) §3.4).
- **One groomer serves both data planes**, and on the segmented lane off-the-shelf TSDuck reaches all
  four grading criteria where the MoQ lane needs a purpose-built stage. Grooming restores exact CBR and
  P2-limit PCR accuracy **on file**, and on the segmented lane it is conformant to ~11.5 Mbps across
  four reference clips ([Evidence](docs/evidence.md) §3.2).

## The strongest negative results

- **A MoQ feed carries media through none of eight third-party relays.** Version negotiation is not the
  cause; an announce convention the draft permits either way is, and the eight failures have at least
  four distinct causes ([Evidence](docs/evidence.md) §3.7).
- **The MoQ lane fails TR 101 290 P1 PCR repetition on the wire at *every* buffer depth** — 489–504
  intervals above 40 ms out of ~3,200–3,300 PCRs in a 90 s cell, unchanged by depth, by removing
  groomer starvation, or by the path. The exporter conserves the number of PCRs and destroys their
  spacing, emitting 85 % of them within 11 µs of each other and leaving gaps up to 1.8 s. It is an
  upstream placement defect, not the price of the lane's latency ([Evidence](docs/evidence.md) §3.2).
  A shorter 25 s window on the grooming rig reads 131–159 for the same defect: the counts scale with
  the observation window, not with the lane.
- **Segmented HTTP fails silently once the client falls out of the origin's availability window.** It
  does not corrupt what it delivers inside that window; past it the client re-anchors and leaves holes
  of 7–82 s, with the origin returning nothing but 200s ([Evidence](docs/evidence.md) §3.3).

## What is not established

- **No hardware IRD has ever been fed by this chain.** Every conformance figure is file arithmetic, a
  socket capture on a general-purpose OS, or a reference software receiver. The make-or-break gate has
  never been attempted ([Evidence](docs/evidence.md) §4).
- **Whether fixing the exporter's PCR placement clears the gate** — the question that now decides the
  thesis, and the cheapest high-leverage measurement outstanding
  ([Evidence](docs/evidence.md) §5).
- **The latency measurements were taken on healthy paths**, so nothing exercised the recovery the
  point-to-point tunnels exist for — the case that should favour them
  ([Evidence](docs/evidence.md) §4).
- **The segmented redundancy result used one filesystem** standing in for a distributed segment store,
  with the standby always co-started; and the impairment ladder ran against a single plain origin
  rather than a CDN edge, so edge and Pathway selection remain specification-only
  ([Evidence](docs/evidence.md) §3.3, §3.4).
- **Grooming the segmented lane above ~11.5 Mbps is untested rather than failing** — the test host's
  pacing stage saturates before the lane does ([Evidence](docs/evidence.md) §3.2).

The full accounting, with every limit stated in one place, is [Evidence](docs/evidence.md) §4 and §5.

---

## The documents

Three layers, because that is the argument. If the conclusion is that the data plane is the small part
of the problem, the structure should show which part is which.

| Document | Layer | What it is |
|---|---|---|
| [Problem](docs/problem.md) | Requirement | Why primary distribution is changing, and the numbered requirement set (R1–R8) everything else is scored against |
| [Comparison](docs/comparison.md) | **Data plane** | The head-to-head: MoQ against segmented HTTP carrying MPEG-TS, and against SRT/Zixi/RIST, with the evidence type marked on every verdict row |
| [Architecture](docs/architecture.md) | **Above the transport** | The reference architecture. The edge gateway and 1+1 redundancy come first because they are the substance and the measured part |
| [Control, Entitlement and Security](docs/control-plane.md) | Above the transport | Provisioning, entitlement and the threat model. **Design only — nothing here has been built or measured** |
| [Evidence](docs/evidence.md) | Cross-cutting | Method, instruments, results by question, and the limits of the evidence |
| [Economics](docs/economics.md) | Cross-cutting | Cost framework, and a numeric model of the always-on case at published rates |
| [Glossary](docs/glossary.md) | — | The two vocabularies side by side, in broadcast terms |

**The engineering record** is the laboratory notebook in [`lab/`](lab/README.md): the campaign plan
with pass criteria fixed before the numbers, and per-experiment procedures, commands and measured
results. [`lab/method-notes.md`](lab/method-notes.md) collects the measurement rules the campaign
learned the hard way, which are as transferable as the results, and
[`lab/upstream-contributions.md`](lab/upstream-contributions.md) records what was found, reported and
verified in other projects.

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

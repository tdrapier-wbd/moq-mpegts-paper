# Interoperability

Status: working draft
Scope: how the platform coexists with the installed base of professional
broadcast equipment and the transports that feed it (MPEG-TS, RTP/FEC, SRT, ST 2110-7, unicast and multicast, hardware IRDs) — on ingest and on egress. This is the deep-dive companion to
[architecture](architecture.md) §4.1, §7, and §8, and to the carriage discussion
in [transport](transport.md) §4. The empirical basis for the harder claims is in
[evidence](evidence.md).

---

## 1. Purpose

Interoperability is the precondition for adoption, not a feature. The vision's
non-negotiable is that the existing receiving plant keeps working unchanged
([vision](vision.md) §7, [architecture](architecture.md) §8): a design that
requires replacing IRDs, re-cabling plant, or changing monitoring will not clear
the trust bar. This document treats the installed base as a fixed constraint and
describes what the platform must do to satisfy it, on ingest and egress, and
where the residual risks are.

The scope boundary: the *transport-level* interop (which MoQ draft, media-layer
profile alignment) is in [transport](transport.md), where the community
[`moq-interop-runner`](https://github.com/englishm/moq-interop-runner) is the
relevant external test harness. That harness exercises MoQ-implementation interop
at the protocol handshake (session, namespace, subscription) and deliberately
does not touch the broadcast-level concerns — MPEG-TS carriage fidelity, TR 101
290, IRD egress — that this document is about. This document covers
*broadcast-level* interop — the formats, signalling, and conformance the media
plant expects.

## 2. The installed-base contract

A hardware IRD or professional decoder expects, at minimum
([architecture](architecture.md) §8.1):

- A conformant MPEG-2 transport stream over its supported interface (ASI, or
  increasingly RTP/UDP over IP, frequently multicast).
- TR 101 290 P1/P2 conformance — above all, conformant PCR timing.
- Stable service signalling: a consistent PMT PID, correct SDT service identity,
  and preserved SCTE-35, teletext, and subtitling.
- ST 2022-7 dual-path input for redundancy, where the facility uses it.

Everything in this document exists to honour that contract. From the IRD's
perspective, adopting the platform changes nothing it can observe: same interface,
same conformance, same redundancy scheme, same monitoring.

## 3. Ingest

The platform ingests the transports broadcasters already use for contribution
and origination, adapting each to an internal transport-stream representation
([architecture](architecture.md) §4.1). In descending order of near-term
importance:

- **RTP/UDP MPEG-TS, including SMPTE 2022-1 FEC and ST 2022-7 dual-path** — the
  established managed-network IP format.
- **SRT** — the dominant IP contribution transport. The platform must
  ingest it to coexist with existing workflows rather than demand replacement.
- **ST 2110 essence** (longer term) — for uncompressed-IP plants; this requires
  encode/mux before publication and is a heavier integration with its own timing
  and PTP considerations.

The design decision is to treat ingest as a pluggable adaptation layer with no
privileged input, so that the internal representation — and everything downstream
of it — is independent of how the feed arrived.

## 4. Media carriage fidelity

The single most important interop property is that carriage across MoQ preserves
what the installed base depends on:

- **Service identity (SDT)** and the exact **PMT PID** layout.
- **SCTE-35** splice/ad signalling, intact and correctly timed relative to the
  programme.
- **Teletext and subtitling** streams.
- **Continuity counters** and programme structure.

The default media-aware lane ([transport](transport.md) §4.1) must preserve or
faithfully regenerate this signalling; doing so reliably across real contribution
feeds is exactly the upstream work still in progress ([evidence](evidence.md) §4).
The **opaque fallback** preserves all of it *verbatim by construction* — the
MPEG-TS is carried byte-for-byte — which is why it is the safe choice for the
feeds or endpoints where exact preservation is required and the media-aware path
cannot yet guarantee it. The verbatim approach is validated by round-trip and
property tests ([evidence](evidence.md) §1 and §4); its cost — forgoing per-track
prioritisation — is discussed in [transport](transport.md) §4.1 and
[relay](relay.md) §3.3.

## 5. Egress

The edge gateway produces IRD-grade output ([architecture](architecture.md) §7).
The egress formats supported:

- **MPEG-TS over RTP/UDP (payload type 33)** and **raw UDP**, unicast or
  multicast.
- **SMPTE 2022-1 FEC** for loss protection on the egress network.
- **ST 2022-7 hitless dual-path** for seamless redundancy into IRDs that support
  it — the platform's last-hop failover mechanism ([architecture](architecture.md)
  §14.1).
- **Decoder-safe start gating and de-jitter pacing** so the IRD starts cleanly and
  sees a smoothly paced stream.

Multicast, FEC, and ST 2022-7 are treated as *egress implementation details*
rather than end-to-end architecture: they are reconstructed at the edge to match
what the local plant expects, decoupled from how the feed traversed the fabric.

## 6. TR 101 290 conformance

Conformance is where interoperability is won or lost, and it is the subject of the
platform's single most important open validation.

MoQ's object/burst delivery produces a reconstructed stream whose PCR is
smooth-but-not-byte-accurate; hardware IRDs lock a PLL to PCR and raise TR 101 290
P1/P2 alarms in response ([evidence](evidence.md) §3 measured ~24% of PCR
intervals exceeding the 40 ms limit before grooming). The edge grooming layer —
byte-locked CBR, monotonic PCR re-stamp, PCR re-insertion — restores conformant
timing: measured on file it takes the bursty egress from 13–26% of PCR intervals
> 40 ms to **0%** with 0 `pcrverify` violations at 500 µs
([lab: T2](../lab/test-2-media-aware-transparency.md), [architecture](architecture.md) §7.2),
subject to the hardware caveat below.

> Grooming is file-validated and structurally sound, but **must be proven to pass
> P1/P2 on real hardware IRDs**: file analysis confirms the PCR arithmetic, not
> the live-wire pacing jitter or PCR_accuracy (±500 ns) that only a hardware
> analyser can measure ([architecture](architecture.md) §7.2). Until that evidence
> exists (Sencore analyser plus real IRDs, in progress per [evidence](evidence.md)
> §3), conformance is "expected" not "demonstrated." This is the make-or-break
> interop claim.

## 7. Non-ideal source feeds

Real contribution feeds are not clean. The platform must be robust to what
actually arrives, not to an idealised stream:

- **Open-GOP encodes using recovery-point SEI rather than IDR frames** (e.g. a
  broadcast capture with roughly one IDR per 15 s) have historically
  defeated naive keyframe detection that keys only on IDR NAL type, causing
  media-aware import to fail to produce a video rendition and to emit misleading
  downstream errors ([evidence](evidence.md) §4). This is common for contribution,
  not an edge case; upstream has begun addressing it in main/dev, though the fix
  is not yet independently validated here.
- The **opaque lane sidesteps this entire failure class** by carrying the TS
  verbatim without depending on those fixes — which is exactly why it is retained
  as the fallback for feeds like this one, until the media-aware default handles
  them. Media-aware re-muxing remains the default and preferred lane
  ([architecture](architecture.md) §4.2).

Other non-ideal conditions to be characterised: irregular PCR in the *source*
feed, discontinuities, PID changes mid-stream, and multi-programme transport
streams where only some services are entitled.

## 8. Compatibility matrix

The following is the intended compatibility posture. The **Status** column
reflects *validation maturity*, not merely whether a capability exists: "Prototype"
means implemented in the working prototype ([evidence](evidence.md) §2) but not yet
demonstrated on hardware; entries marked *to be validated* or *Roadmap* are design
intent, not results. A dash (—) in the Ingest/Egress column means the feature does
not apply on that side — multicast, FEC, and ST 2022-7 are egress reconstruction
details (§5), not ingest concerns.

| Interface / feature | Ingest | Egress | Status |
|---|---|---|---|
| SRT | Yes | — | Prototype |
| RTP/UDP MPEG-TS | Yes | Yes | Prototype |
| SMPTE 2022-1 FEC | — | Yes | Prototype; to be validated on hardware |
| ST 2022-7 dual-path | — | Yes | Hitless against a reference receiver, either from one groomer duplicated onto both paths or from two independent *stream-clocked* groomers, which also protects the chain behind them ([evidence](evidence.md) §7); a pair from two arrival-clocked groomers does not merge; to be validated on hardware |
| ST 2110 essence | No | — | Longer term; heavier integration |
| Multicast | — | Yes | Prototype; to be validated on hardware |
| TR 101 290 P1/P2 to hardware IRD | — | Yes | **To be validated on real hardware** |
| SCTE-35 / teletext / SDT preservation | Yes | Yes | Test-validated in file ([evidence](evidence.md) §4) |

## 9. The implementation landscape

Until mid-2026 this paper could treat "MPEG-TS over MoQ" as a single-implementation question. That
is no longer true: there is now a dedicated MPEG-TS-over-MoQ effort with its own working-group
format, a second independent publisher, and a production relay from a major CDN. That changes the
argument from "can this be made to work?" to "which parts of it are converging, and where does an
operator still have to choose?" This section maps the field. *The survey in §9.2–§9.5 is assessed
from repositories, drafts and public documentation only; §9.6 is measured against running relays.*
It crosses the scope line drawn in §1, because draft-version interop nominally belongs in
[transport](transport.md), but an implementation is more useful assessed whole than split in two.

### 9.1 A terminology note: "transparent", not "opaque"

This paper has used **opaque lane** for carrying the transport stream through MoQ untouched. The
MPEG-TS-over-MoQ work uses **transparent passthrough** for the same idea. Both names describe the
same property from opposite ends: *opaque* says the transport cannot see into the payload,
*transparent* says the payload arrives unaltered. The industry term is settling on **transparent**,
and it is the better word — it names the guarantee the broadcaster is buying rather than the
limitation the transport is accepting. This paper keeps "opaque lane" for continuity with the
experiments and earlier sections, but the two are interchangeable and external material should be
read accordingly.

### 9.2 Who is building what

| | `moq-dev` | `moq2ts` / `moqxr` | Cloudflare `moq-rs` | This project |
|---|---|---|---|---|
| Lane | media-aware (+ opaque prototype) | **transparent TS** | none — transport only | **transparent TS** + grooming |
| Scope | publisher, relay, subscriber | **publisher only** | protocol library, **relay**, sample clients | publisher + egress + pacer |
| Media format | `hang` catalog/container | MSF + MSFTS (`packaging: "m2ts"`) | **deliberately none** | verbatim TS |
| Format standing | no IETF draft | **adopted WG format** + individual draft | N/A | internal |
| Wire versions | moq-lite 03–06, **MOQT 14–19** | MOQT 16, 18 (example: 14/17) | MOQT **14 and 16**, 18 in progress | inherits `moq-dev` |
| Transport stack | Rust (quinn / quiche / noq) | C++20, picoquic/picotls | Rust | Rust |
| Source failover | route reselection via `--origin` | N/A (publisher) | **none — publisher loss is terminal** | relies on `moq-dev` |
| Deployment | self-hosted | self-hosted | **managed, provisioned by API** | self-hosted |

Two structural facts fall out of that table and matter more than any individual feature.

**No one else does the broadcast-specific layer.** `moq2ts` is publisher-only; Cloudflare is
transport-and-relay only. Neither carries PCR-accurate egress, CBR grooming, TR 101 290 conformance
or IRD-facing output. The layer this paper argues is the hard part remains unclaimed, which is
evidence for the thesis rather than against it.

**Transparent carriage is no longer a single-vendor idea.** With an adopted working-group format
(MSF) and more than one implementer, the profile question in [transport](transport.md) §9 moves from
"will anyone else do this?" to "will it be adopted widely enough?".

### 9.3 `moq2ts` / `moqxr`: the transparent publisher

Media object payloads are concatenations of whole 188-byte TS or 192-byte M2TS source packets with no
private wrapper, sync-byte validated. It targets `draft-gregoire-moq-msfts` layered on
[`draft-ietf-moq-msf-01`](https://datatracker.ietf.org/doc/draft-ietf-moq-msf/), the MOQT Streaming
Format — an **adopted MoQ working-group document**. The catalog declares `packaging: "m2ts"` with
TS-specific fields (packet size, packets per object, programme number, PMT/PCR PIDs, random-access
flag) and carries PAT/PMT as Base64 initialisation data in source-packet form. Groups are key-frame
aligned; SRT ingest drops oldest whole packets rather than stalling.

Two choices stand out. It selects **one programme out of an MPTS**, keeping PAT, that programme's
PMT, PCR PID and elementary PIDs while discarding other programmes **and null packets**. And it
publishes a `.timeline` **side track** mapping media presentation time to Unix wall-clock
milliseconds as `[mediaTimeMs, [groupId, objectId], wallclockMs]`, without modifying the TS payload.

Compared with the two lanes this project has built:

| | `moq-dev` media-aware | `moq2ts` transparent | This project's opaque lane |
|---|---|---|---|
| Unit of carriage | one track per elementary stream | whole TS packets in objects | whole TS packets in objects |
| PSI/SI | reconstructed on export (#2440) | selected programme's PAT/PMT | preserved verbatim, incl. TDT/TOT |
| Null packets / CBR stuffing | stripped | **stripped** | preserved |
| Multi-programme TS | demuxed | **one programme only** | carried verbatim |
| Wall-clock correlation | none in-band | `mediatimeline` side track | PCR/CBR restored downstream |

The key distinction the comparison draws out: **transparent does not automatically mean verbatim.**
`moq2ts` strips nulls just as the media-aware lane does, so it also needs downstream re-pacing to
restore CBR and cannot be assumed to hold a TR 101 290-conformant bitrate on its own. Being
SPTS-out-of-MPTS, it does not answer the multi-programme question either. Where it is ahead of us is
**standards posture**, and its side-track approach to wall clock is a cleaner answer to timing
correlation than anything currently in this architecture.

### 9.4 Cloudflare `moq-rs`, and the argument for a format-blind transport

[`cloudflare/moq-rs`](https://github.com/cloudflare/moq-rs) is the IETF-aligned Rust implementation —
originally Luke Curley's code, maintained as an IETF fork by Mike English, now by Cloudflare. It ships
`moq-transport` (protocol library), `moq-relay-ietf` (production relay with subscription
deduplication and caching), `moq-api` (origin discovery and relay coordination) and sample clients.
Relays are **provisioned by API or dashboard** as isolated scopes with separately scoped publish and
subscribe tokens, and the provisioning model is itself being standardised as an Internet-Draft so
that several CDNs can share it — which is directly relevant to
[control-plane](control-plane.md) and [entitlement](entitlement.md), where this paper has assumed
such a mechanism would have to be built rather than adopted.

The architecturally interesting point is what it deliberately omits. `moq-transport` is described as
**media-agnostic**: it carries namespaces, tracks, groups and objects and has no catalog or container
opinion at all. It does not implement `hang`. The argument for that separation, which this project
should take seriously:

- **Any streaming format can ride it** — MSF, MSFTS, CMSF, `hang`, or raw TS. The transport does not
  have to be revised when a media format changes.
- **The transport can standardise on its own timeline**, decoupled from format churn. Relays need not
  be upgraded when catalogs evolve.
- **Relays stay simple**, which is exactly what a transparent TS lane wants: a relay that cannot
  misinterpret the payload cannot corrupt it.

The counter-argument is equally real, and is presumably why a media-aware stack exists at all. A
relay that understands the media can behave intelligently under pressure: prioritise tracks, drop
non-key-frame groups first, evict cache by media semantics. MoQ's congestion response *is* dropping
groups, so a format-blind relay thins less intelligently than an aware one. And an agnostic transport
with N incompatible formats above it delivers no end-to-end interoperability at all — a single
reference format is what makes an ecosystem work in practice.

**Our position.** For primary distribution the split favours a format-blind relay with format-aware
endpoints. Broadcast semantics — PCR, exact CBR, PSI/SI, TR 101 290 — cannot be expressed in a
generic catalog anyway, so a relay's media awareness buys us little while its inability to alter the
payload buys us a great deal. The cost is real and already recorded: we forgo relay-side graceful
degradation, which [transport](transport.md) §9 lists as an open question for the opaque lane. That
trade is the right way round for contribution-grade carriage and the wrong way round for consumer ABR
— which is a reasonable summary of why both stacks exist.

One further Cloudflare detail matters for [architecture](architecture.md) §14. Its relay documents
that **if the publisher disconnects, subscribers receive an error and do not recover, even if a new
publisher reuses the path**. There is no source takeover. The route reselection this project has been
testing (`moq --origin`, bounded by the QUIC idle timeout) is a `moq-dev` capability, not a property
of MoQ relays generally. Any 1+1 design that assumes relay-side source failover is therefore
implementation-locked, which strengthens the case already made for **receiver-side dual-subscribe**
as the primary redundancy mechanism.

### 9.5 What can actually be tested, and when

The `moq2ts` release is publisher-only, so the full test suite cannot be pointed at it yet — there is
no subscriber to capture an egress from and no way to close the loop. Two things are testable now,
and a third when they ship a subscriber.

- **Does a `moq-dev` client carry its lane over a third-party relay?** Run, and the answer is no —
  see §9.6. Version negotiation was never the obstacle; the announce convention is.
- **Now: does a `moq2ts` broadcast traverse a `moq-dev` relay?** Publisher-only is sufficient for
  this, since the question is whether the relay forwards objects whose catalog it cannot parse.
  Confirming traversal without a subscriber requires observing the relay's forwarding behaviour
  rather than decoding the output, which is a weaker but still meaningful result.
- **When a `moq2ts` subscriber exists: run the full suite against it.** T1–T3 transparency, T7 timing
  integrity and TR 101 290 conformance, measured on their implementation and contrasted with ours.
  That is the comparison that would actually settle which lane preserves what, and it is worth
  planning for now.

The natural framework for the first two is the community
[`moq-interop-runner`](https://github.com/englishm/moq-interop-runner), already referenced in this
project's index. It currently exercises the protocol handshake only and deliberately stops short of
media-layer concerns. Contributing a **broadcast profile** to it — TS carriage fidelity, PSI/SI
survival, PCR integrity across a relay — would extend an existing shared harness rather than build a
private one, and would give the transparent-TS profile a neutral conformance target. That is probably
the single highest-leverage contribution this project could make to the wider ecosystem.

### 9.6 Measured: relay neutrality does not hold across implementations today

Everything above is a desk survey. This is what happened when the project's own lane was pointed at
every registered public MoQ relay ([lab: T11](../lab/test-11-interop.md)). The test carries a
20-second MPEG-TS fixture through a relay and checks continuity counters and PSI/SI at egress — an
oracle that needs no decoder, because a transport stream checks itself.

The result is stark. Against `moq-dev`'s own relay it passes, locally and over the public internet,
with a byte-identical egress in both cases and a late subscriber joining mid-stream cleanly.
**Against all eight other public relays — Meta, Google, Cisco, Nokia, Meetecho, Cloudflare, OzU and
openmoq — no media flows at all.**

The cause is not the one this paper expected. Draft-version negotiation, the thing §9.6 previously
listed as the obvious hazard, works better than advertised: `moq-transport-19` was negotiated
against two relays, above the ceiling `moq-dev`'s own help text claims. The blocker is a convention
above the version. **`moq-dev`'s publisher is demand-driven: it withholds its `PUBLISH_NAMESPACE`
announcement until the peer explicitly asks for it with a `SUBSCRIBE_NAMESPACE`.** Its own relay
interrogates every publisher session unconditionally, so the chain completes and everything works.
No third-party relay does that, because in MOQT a publisher is expected to announce proactively on
connect and a relay has no reason to interrogate a session that has claimed nothing. So the
publisher connects, negotiates a modern draft, reports no error — and then emits not one control
message for the rest of its life. Instrumenting both ends confirms the silence is real rather than a
logging artefact, and that it is not downstream demand propagating: with no subscriber attached at
all, `moq-dev`'s relay still asks and its publisher still announces.

**Neither implementation is doing anything wrong, which is what makes this important.** The draft
says a publisher *MAY* announce proactively and *MUST* answer a namespace subscription; announcing
unprompted is permitted, not required. `moq-dev` is therefore fully conformant and simultaneously
unable to interoperate with any relay that does not interrogate publishers — the normal case. A
second, independent issue sits behind it: `moq-dev` opens discovery with an *empty* namespace prefix,
which one relay rejects outright, and the draft is internally inconsistent about whether that is
legal ([moq-wg/moq-transport#1457](https://github.com/moq-wg/moq-transport/issues/1457)). Both are
interop hazards produced by underspecification, not bugs, and the first is now reported upstream as
[moq-dev/moq#2730](https://github.com/moq-dev/moq/issues/2730).

Three relays fail earlier still, at connection or SETUP, and are undiagnosed. So the eight failures
are at least four distinct causes, not one.

Two conclusions follow, and they pull in opposite directions.

**The transport substrate is sound; the ecosystem around it is not yet joined up.** Forcing the same
media test over `moq-transport-14` against a local relay passes cleanly, so the IETF path carries
broadcast MPEG-TS perfectly well. Nothing here indicts MoQ as an architecture, and nothing here is
hard to fix — the blocking behaviour is a client-side default. But "a MoQ relay is a neutral
transport fabric", which [architecture](architecture.md) treats as load-bearing, is **an assumption
this project can no longer make on the evidence**. It holds within one implementation. Across
implementations, today, it does not hold at all. For a broadcaster the practical reading is that
multi-vendor relay portability — the property that makes an Internet-native trunk route
substitutable, and therefore the property that underwrites the economic argument — is unproven and
currently absent, even though the protocol permits it.

**The conformance gap this exposes is worse than the failure itself.** The community interop matrix
is control-plane only. Against the relay above, a `setup-only` check reports green while not a single
media byte crosses. An entire class of failure is invisible to the test everyone reads, which is the
strongest available argument for the media-level profile proposed in §9.5 and now offered upstream as
a working test client ([`interop/`](../interop/README.md)).

One incidental finding is worth an operator's attention: the client abandons QUIC for a WebSocket
fallback on a fixed 200 ms timer, so **any relay more than about 100 ms away is silently carried over
TCP** — head-of-line blocking included. That is a confound for interop measurement, since the
transport under test is not the one you think it is, and a genuine concern for long-haul broadcast
carriage.

### 9.7 Interoperability boundaries, as currently understood

- **Transport versions overlap and are not the obstacle** — measured, not assumed (§9.6). `moq-dev`
  14–19, `moqxr` 16/18, Cloudflare 14/16, and negotiation succeeds in practice across vendors.
- **Relays are format-blind, and that is not sufficient.** Cloudflare's is explicitly media-agnostic;
  `moq-dev`'s routes without parsing catalogs. Cross-format traversal should therefore work — but
  §9.6 shows media failing to flow for reasons that never reach the payload, so format-blindness
  buys nothing on its own.
- **Endpoints will not interoperate across formats.** `moq export ts` reads `hang`, not MSF/MSFTS. A
  subscriber must be built for the format it consumes; this is a format choice, not a defect.
- **The announce convention, not the wire version, is what breaks interop.** Relays split into two
  camps on track preannounce: some accept an early `PUBLISH` and answer `PUBLISH_OK`, while others
  resolve a namespace only once a subscriber appears. Cloudflare is in the first camp (draft-16
  `PUBLISH` is a headline feature); `moq-dev` is firmly in the second, which §9.6 measures as the
  blocking cause of every "connects but no media" failure. `moqxr`
  [PR #21](https://github.com/mondain/moqxr/pull/21) independently reports the same split from the
  other side, including the case where an early `PUBLISH` disturbs namespace registration so that
  every later `SUBSCRIBE` is rejected; it resolved this by making preannounce opt-in and
  default-off. **Relay neutrality is a property to verify per pairing, not to assume** — and on
  current evidence it fails for every pairing outside a single implementation.

That same PR independently reproduces a finding of ours: a publisher with no subscriber attached dies
at ~32 s to the default QUIC idle timeout, fixed with a 5 s keepalive. It matches the ~30 s bound
measured here ([evidence](evidence.md) §7) from an entirely different stack, which is useful
corroboration that the idle timeout is a first-order operational constraint rather than an artefact of
one implementation.

## 10. Testing and acceptance

- **Round-trip fidelity.** Byte-level preservation of SDT/PMT/PIDs/SCTE-35/
  teletext/continuity across carriage ([evidence](evidence.md) §1).
- **Conformance on hardware.** TR 101 290 P1/P2 pass on real IRDs, captured and
  analysed (TSDuck `pcrverify`/`analyze`, Sencore) — the decisive acceptance test.
- **Non-ideal-source robustness.** A suite of real contribution captures
  (open-GOP, discontinuities, mid-stream PID changes) carried end-to-end without
  loss of service.
- **Redundancy.** Hitless ST 2022-7 switching at the egress under induced path
  failure — **passes against a reference receiver** (zero lost packets under leg
  blackout, 1 % and 3 % loss, and differential delay to 200 ms), both for a pair
  produced by one groomer duplicated onto both paths and for two independent
  stream-clocked groomers; the on-hardware pass is outstanding, and a pair from two
  *arrival*-clocked groomers is not mergeable at all
  ([evidence](evidence.md) §7). Acceptance should therefore state which egress
  topology is being accepted, and confirm the receiver's differential-delay window
  covers the pair's measured skew.

## 11. Open questions

- Does groomed MoQ output pass TR 101 290 P1/P2 on the range of hardware IRDs in
  real use, not just one model? (The central open question of the whole thesis;
  shared with [architecture](architecture.md) §17 and [evidence](evidence.md) §3.)
- How should the platform handle multi-programme transport streams where
  entitlement differs per service — carry verbatim and filter at egress, or
  demux earlier?
- What is the correct behaviour on source-side discontinuities and PID changes:
  pass through transparently, or normalise, and at which layer? Half of this is now
  settled upstream: an audio elementary stream losing frame sync used to abort the
  whole publisher while video resynchronised, and since `moq-mux` 0.9.5 the audio
  parsers resync too, at a measured cost of one 24 ms frame. Two things remain open.
  **Whether a recovered gap should be visible downstream** — today it is signalled
  nowhere, so a feed losing audio is indistinguishable from a healthy one. And at a
  *splice* rather than a bit error the ingest edge did not lose a frame but
  **substituted** one, publishing bytes from both sides of the discontinuity as
  though they were real audio. The transport-layer signal that settles that — the
  continuity counter, carried in every packet and previously read only for private
  sections — is now applied to elementary streams too
  ([#2823](https://github.com/moq-dev/moq/pull/2823)), and the substituted frame is
  gone from the feed that produced it. What remains is that the check has one input:
  a wrap that happens to leave the counter contiguous is still invisible, and the
  demuxer publishes the mixed frame exactly as before
  ([lab T9](../lab/test-9-performance.md)).
- Does a `moq2ts` MSFTS broadcast traverse a `moq-dev` relay (§9)? Relay neutrality
  is a load-bearing assumption of this architecture and is currently untested
  across implementations.

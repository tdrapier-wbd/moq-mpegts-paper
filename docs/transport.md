# Transport: Why MoQ, and How Media Is Carried

Status: working draft
Scope: the transport-layer rationale that bridges the *why* of [vision](vision.md)
and the *how* of [architecture](architecture.md). This document answers three
questions the vision leaves open and the architecture assumes settled: **why MoQ
specifically** (as opposed to any other Internet-native transport), **how
broadcast media is carried over it** without losing what the installed base
depends on, and **how the pre-standard instability of the protocol is managed**
so that a five-to-ten-year broadcast commitment is even conceivable.

It deliberately does not restate the market argument (that is [vision](vision.md))
or the system design (that is [architecture](architecture.md)). It also does not
duplicate the measured results that justify its claims; those live in
[evidence](evidence.md) and are cited where relevant.

---

## 1. The bridge

The vision concludes that primary distribution is moving toward an
Internet-native model and that MoQ *appears* to fit; the architecture takes a
capable transport as given. Between them sits a question neither answers: *given
the requirements primary distribution imposes, is MoQ the right transport, and on
what terms?* This document states the transport requirements as a checklist
derived from broadcast practice, evaluates MoQ against them honestly (including
where the answer is "not yet" or "narrowly"), and defines the carriage and
versioning strategy the rest of the architecture depends on.

---

## 2. Transport requirements from broadcast practice

Any transport for primary distribution must satisfy the following, which are
derived from the characteristics set out in [vision](vision.md) §2–§3, not
invented here:

- **Latency low enough for linear operation.** Sub-second glass-to-glass is
  desirable and, for most primary distribution, a few seconds is tolerable — but
  latency must be *bounded and stable*, because a drifting or unbounded buffer is
  itself a fault for downstream playout and ad insertion.
- **Graceful behaviour under loss and congestion.** The public Internet delivers
  variable loss and jitter. The transport must degrade predictably rather than
  stall, and must not impose head-of-line blocking that converts a single lost
  packet into a multi-second gap.
- **Reliability approaching the broadcast expectation.** Not "high availability"
  in the web sense but "no visible failure during contracted content" — which the
  transport contributes to but cannot deliver alone (it requires the redundancy
  and grooming layers in [architecture](architecture.md) §7 and §14).
- **Faithful carriage of MPEG-2 transport streams.** Service identity (SDT),
  programme structure (PMT PIDs), SCTE-35 splice signalling, teletext/subtitling,
  and continuity counters must survive transit intact. A transport that silently
  discards or reorders these is unusable for the installed base, regardless of its
  performance.
- **A native authorization primitive.** Because dynamic, revocable entitlement is
  a core requirement ([architecture](architecture.md) §11), a transport whose
  access control is an external bolt-on is weaker than one where scoped,
  expiring authorization is part of the session model.
- **A fan-out model.** Primary distribution is one-to-many (tens to low hundreds
  of endpoints). A transport with a native relay/subscription model avoids
  publisher-side replication and per-endpoint point-to-point tunnels.
- **A stability horizon compatible with broadcast planning.** This is the
  requirement MoQ currently fails, and it is treated separately in §5.

---

## 3. MoQ against the requirements

**MoQ is selected on comparative, architectural grounds — not because it dominates the mature incumbents (SRT, Zixi, RIST, RTP over managed IP, TS-over-HTTP) on the narrow task.** The case must therefore be stated with its weaknesses attached.

### 3.1 Where MoQ is differentiated

- **It rides QUIC / WebTransport, the same substrate as HTTP-3.** This is the
  decisive property: broadcast distribution can, in principle, run on the global
  CDN and hyperscaler fabric that already exists rather than a purpose-built
  overlay. QUIC's per-stream delivery is the structural fix for the head-of-line
  blocking that occurs *wherever a single, strictly in-order reliable byte stream
  is used* (most obviously TCP), where in-order recovery serialises everything
  behind a lost packet. The incumbent UDP transports are not uniform on this and
  should not be collapsed together: SRT drops once its configured latency window
  is exhausted rather than blocking; RIST is RTP with packet-level retransmission;
  Zixi is proprietary. So the fair claim is narrow: MoQ's per-stream model avoids
  serialising an entire multiplex behind one loss, but whether that yields a
  *measurable* advantage over a well-tuned SRT/RIST deployment is unproven (§8).
- **One protocol spans contribution and 1:N distribution.** MoQ's relay model
  provides subscription-based fan-out, cluster routing, and caching as part of the
  protocol rather than as external infrastructure. This matches the "trunk that
  must occasionally fan out globally and dynamically" shape of primary
  distribution.
- **Delivery is subscription-oriented.** A subscriber receives
  only the tracks it requests, and only while it requests them. This is not merely
  an efficiency property; it is the substrate for dynamic, revocable entitlement
  (a feed reaches an endpoint only while a valid subscription exists), which is
  otherwise an external enforcement problem.
- **Authorization has a native place in the session model.** MoQ carries
  authorization information at the point of subscription and lets a relay accept or
  refuse a subscription there, rather than requiring a separate auth proxy in front
  of the transport. The specific credentials this platform uses — path-scoped JWTs,
  mTLS peer identity, and session-lifetime expiry — are a *deployment profile* built
  on that hook, not wire-format primitives that MoQ itself defines and guarantees
  across implementations. The differentiator is that the transport gives
  authorization a native place to live and enforce; the credential format is our
  choice. See [evidence](evidence.md) §6 for what has been verified.

### 3.2 Where the case is weak

- **The incremental advantage on the narrow job is narrow.** For "move one linear
  feed reliably from A to B," a well-run Zixi or MediaConnect deployment is
  already good. MoQ's strongest advantages (graceful multi-rendition degradation,
  subscription-based fan-out, one protocol for everything) matter most at fan-out scale
  and heterogeneity — precisely where primary distribution is *least*
  heterogeneous. There is a real risk of bringing a distribution-protocol
  advantage to a contribution-shaped problem.
- **Graceful degradation depends on the carriage lane.** As §4 explains, the
  default media-aware lane exposes per-track prioritisation, letting MoQ shed
  low-priority renditions under stress. The opaque *fallback* lane carries a whole
  programme as a single opaque object stream, which limits that. The degradation
  advantage is therefore fully realised on the media-aware default and constrained
  wherever the opaque fallback is in use.
- **The object/burst model creates a broadcast-specific problem.** MoQ delivers
  objects in bursts, which produces reconstructed-stream timing that hardware IRDs
  reject (§4.3, [evidence](evidence.md) §3). This is inherent, not a defect, and
  it is why the grooming layer in [architecture](architecture.md) §7 exists.
- **It is pre-standard (§5).**

The honest summary: MoQ is selected as the *preferred* data plane on
architectural grounds, not because it dominates incumbents on the narrow task.
The architecture is deliberately built so the transport is swappable
([architecture](architecture.md) §2, principle 2), which is both a hedge against
these weaknesses and an admission that the transport case is not yet closed.

### 3.3 A closer comparison: TS-over-HTTP

**TS-over-HTTP (TSoHTTP) is the closest Internet-native alternative to MoQ for
this job, and a sound choice in several deployments; MoQ looks like the stronger
long-term fit on architectural grounds, not because TSoHTTP is deficient.**
TSoHTTP carries an MPEG-TS as an HTTP payload — typically a chunked response over
a persistent TCP connection — and its strengths are real:

- **Native MPEG-TS carriage.** The transport stream *is* the payload, so service
  signalling (SDT, PMT, SCTE-35, teletext, continuity) survives by construction —
  the same property the opaque MoQ lane provides (§4), reached without a new
  packaging profile.
- **Operational simplicity and ecosystem maturity.** It reuses ubiquitous,
  battle-tested HTTP/TCP infrastructure — CDNs, caches, load balancers, proxies,
  TLS, and firewall-friendly transit on TCP 443. That tooling is more mature than
  any MoQ implementation today, a genuine advantage given MoQ's pre-standard state
  (§5).
- **Proven fan-out.** HTTP caching and CDN distribution scale to very large
  audiences and are well understood operationally.

The architectural differences that favour MoQ for *primary distribution
specifically*:

- **Transport substrate (TCP/HTTP vs QUIC).** Classic TSoHTTP rides a single
  reliable, in-order TCP byte stream. Recovery is by TCP retransmission — so it is
  *not* without error recovery — but that recovery is in-order: a lost segment
  stalls delivery of everything behind it until it is retransmitted
  (head-of-line blocking, an inherent property of one ordered byte stream, §3.1).
  QUIC's independent streams confine a loss to its own stream, which matters most
  on the lossy public-Internet paths primary distribution sometimes crosses.
- **Latency under loss.** Both can be low-latency on a clean path; under loss,
  TCP's ordered retransmission and congestion response make bounded latency harder
  to hold than QUIC's per-stream model — though whether the difference is
  *material* against a well-tuned deployment is unproven (§8).
- **Delivery model.** TSoHTTP is request/response: live fan-out is arranged around
  it (chunked responses, segment polling, cache hierarchies). MoQ's subscription
  model is native publish/subscribe, which maps directly onto dynamic, revocable
  entitlement (a feed reaches an endpoint only while a valid subscription exists,
  §3.1) and onto relay-based 1:N amplification as part of the protocol rather than
  as external orchestration.
- **Openness and standardisation.** Both build on open components (HTTP, TLS,
  MPEG-TS). TSoHTTP is generally an arrangement of standard parts and **vendor-specific** rather than a
  single standardised live-media transport; MoQ is being standardised as one in
  the IETF, though it is not yet stable. Neither position is fixed, and this is not
  a claim about what TSoHTTP could become.

**The nuanced conclusion:** where HTTP infrastructure is already in place, latency
budgets are relaxed, and native TS carriage is the priority, TSoHTTP is a sound,
low-risk choice — and in those cases may be the better one. For broadcast
*primary* distribution — where the target model is dynamic entitlement,
relay-based fan-out, and graceful behaviour on best-effort paths — MoQ's per-stream
transport and native subscription/relay model are a closer architectural fit,
which is why this paper treats it as the more compelling long-term candidate. That
judgement is contingent on MoQ reaching wire stability (§5).

---

## 4. Media packaging and carriage

How broadcast media is mapped onto MoQ is more consequential than which transport
draft is used, because it determines whether the installed base survives transit.

### 4.1 Two carriage lanes

The platform supports two carriage strategies, and the choice between them is
genuinely contested; the trade-offs are set out in full in
[architecture](architecture.md) §4.2 and only summarised here:

- **Media-aware re-muxing** republishes the elementary streams as native MoQ
  tracks. It is the **intended default and preferred path** — the natural fit for
  MoQ, favoured by both this work and upstream/core, and what exploits native
  relay and 1:N amplification with per-track prioritisation. But "intended" is the
  operative word: its historical weaknesses for contribution feeds (open-GOP
  keyframe detection, loss of SDT/PMT/SCTE-35/teletext/continuity on re-mux — see
  [evidence](evidence.md) §5) are being addressed upstream but are *not yet
  independently validated here*, so for hardware IRDs today it is the target, not
  the proven path.
- **Opaque transport-stream carriage** carries the MPEG-TS verbatim as an opaque
  payload, packaged per the `m2ts` profile of `draft-gregoire-moq-msfts` (MSFTS),
  which extends the MoQ Transport Streaming Format (MSF) catalog to carry MPEG-2
  TS packets verbatim. It preserves service signalling by construction and is the
  **fallback**: the safe choice for feeds and IRDs the media-aware path cannot yet
  serve (certain open-GOP feeds, or decoders needing an exactly intact TS).

The trade-off that matters at the transport layer is explicit: opaque carriage
preserves everything the installed base needs but forgoes MoQ's per-track
prioritisation and selective subscription, because it treats a multiplexed
programme as a single opaque object stream. The rule is therefore "media-aware
unless a specific feed or endpoint forces the fallback," not a free choice between
equals.

**T-STD (buffer-model) conformance is a muxing property, distinct from PCR pacing.**
The MPEG-2 Systems T-STD (Transport Stream System Target Decoder) is the reference
buffer model every conformant multiplex must respect: per-PID transport buffers drain
at defined leak rates, and a compliant stream must never over- or underflow them given
the PCR-derived arrival schedule. This has two faces. The *timing* face — keeping the
PCR-to-PTS/DTS relationship valid — is a grooming concern (architecture §7). The
*occupancy* face is a re-mux concern: a media-aware exporter that emits an access unit's
packets contiguously produces "clustered" per-PID delivery that a strict T-STD model can
flag as a transient buffer overflow, even though real IRDs (with larger-than-minimum
buffers) usually decode it cleanly. A broadcast-grade media-aware lane should therefore
interleave elementary-stream packets in a T-STD-aware way. This is separate from CBR/PCR
pacing (a pacer cannot fix it, since it does not re-order packets) and separate from the
SI-signalling gap; it is currently observed only as a compliance-tool shape warning and
has not been root-caused to the exporter's interleaving versus the source content.

### 4.2 Track, group, and object mapping

Under the opaque lane, the transport stream is segmented into MoQ objects grouped
for delivery, with the MSF catalog advertising the track so a subscriber can
discover and attach to it. The mapping is defined by the MSFTS profile rather
than by this platform, which is deliberate: it keeps the carriage aligned with an
emerging community/standards profile rather than a proprietary framing, so that
independent implementations can interoperate at the media layer even if they
differ elsewhere.

### 4.3 Byte-accuracy expectations

The critical property a subscriber must understand is that opaque MoQ carriage
preserves the transport stream's *bytes* but not its *wire timing*. The bytes —
PCR *values*, PIDs, PES, SCTE-35 — are delivered intact and in order; what is lost
is the constant inter-packet *cadence*, because objects arrive in bursts. The
reconstructed stream is therefore byte-faithful but not byte-*accurately-timed* at
the PCR level. (This is distinct from the media-aware lane, which re-derives PCR
from decoded timing and so has a separate timing-regeneration problem.) The burst
cadence is acceptable for software consumers and unacceptable for hardware IRDs,
which lock a PLL to PCR and raise TR 101 290 P1/P2 alarms. Restoring byte-accurate
timing is therefore not a transport responsibility — it is the job of the edge
grooming layer ([architecture](architecture.md) §7.2), placed at egress because
only there is the full accumulated path jitter known. The transport's contract is
"deliver the bytes intact and in order"; the platform's contract is "restore
conformant timing at the edge."

One precision on "byte-accurate": the round-trip byte-identity claimed here and in
§7 holds *under reliable, complete delivery* — every published object arrives and
is reassembled in order. It is measured at the TS-packet payload level and
explicitly excludes (a) null packets removed for transport and re-inserted at
egress, and (b) the deliberate PCR re-stamp during grooming. It is *not* a claim
that the wire output is identical to the source under loss: if an object is lost
and not recovered, or is abandoned to stay close to live, the reassembled stream is
no longer byte-identical, and the affected continuity counters will show the gap.
That is precisely why loss handling must be deterministic for the ST 2022-7 hitless
case ([architecture](architecture.md) §14.1) and why the integrity guarantee is
stated as "intact and in order *when delivered*," not "identical regardless of
loss."

### 4.4 What happens to the transport stream

One misconception changes what the platform has to do. Under the opaque lane, MoQ
does **not** demultiplex and re-multiplex the transport stream; it treats the
188-byte-packet MPEG-TS as an opaque byte stream and *segments* it into objects,
with nothing inside the TS (PIDs, PES, PCR, SCTE-35) parsed or rewritten in
transit. So the timing problem does not arise from re-multiplexing — it arises
because **MoQ is a bursty, object-delivery protocol, not a constant-rate pipe.**

The end-to-end transformation, step by step:

1. **Ingest.** A contribution feed arrives as an MPEG-TS, typically constant bit
   rate (CBR): the multiplex is padded to a fixed rate with **null packets**
   (PID `0x1FFF`, "stuffing") so the instantaneous rate equals the nominal mux
   rate at all times. That constant cadence is precisely what an IRD's clock
   recovery locks to.
2. **(Optional) null-packet removal.** Null packets carry no information; they
   exist only to pad the stream to CBR. Because carrying them over a
   congestion-adaptive transport wastes bandwidth, they can be stripped before
   transport, turning a CBR stream into a lower-rate variable-rate stream on the
   wire. This is a standard broadcast-IP optimisation, not unique to MoQ, and its
   consequence is that CBR must be *reconstructed* downstream (step 6).
3. **Segmentation into objects/groups.** The (possibly null-stripped) TS byte
   stream is cut into MoQ objects, grouped per the MSFTS `m2ts` profile, and
   published. Object boundaries are a packaging/delivery concern and do not
   preserve TS-packet wire timing.
4. **Bursty QUIC delivery across the fabric.** Relays forward objects as they
   arrive and as congestion control permits, so objects reach the edge in bursts
   with inter-object gaps that bear no relation to the original cadence. The
   *bytes* are intact and in order; the *timing* is gone (§4.3).
5. **Reassembly.** The edge gateway concatenates the objects back into a
   contiguous MPEG-TS byte stream, byte-identical at the TS-packet level to what
   was published — minus any null packets removed in step 2.
6. **Re-pacing to CBR, null re-insertion, and PCR correction (grooming).** To
   hand off to an IRD the gateway must restore a constant cadence: it re-inserts
   null packets to pad back to the target mux rate, paces the output at that rate,
   and re-stamps / re-inserts PCR so the PCR values are byte-accurate against the
   reconstructed CBR clock rather than merely approximately correct. This is *why*
   grooming is necessary rather than cosmetic. The egress mechanism and its
   placement are detailed in [architecture](architecture.md) §7.2.
7. **Egress to the IRD.** The groomed CBR stream is emitted over RTP/UDP or raw
   UDP (optionally with SMPTE 2022-1 FEC and ST 2022-7 dual-path), and the IRD
   locks to it exactly as it would to a satellite or managed-fibre feed.

The **media-aware lane** differs precisely at step 3: it *does* demultiplex the
TS into elementary streams and republish them as native MoQ media tracks, which is
what enables per-track prioritisation and MoQ's relay/amplify benefits. It is the
default and preferred path (§4.1). Where a specific feed defeats it — historically,
open-GOP contribution using recovery-point SEI, or a case where service signalling
must be preserved exactly ([evidence](evidence.md) §5) — the opaque lane is the
fallback for that feed. The CBR/null/PCR work in steps 2 and 6 is required either
way, because both lanes ride the same bursty transport.

---

## 5. Draft and version strategy

MoQ's pre-standard instability is the single largest transport risk, and it is
managed by architecture rather than wished away.

### 5.1 The problem

The MoQ wire protocol is moving substantially between drafts. The platform
currently pins **draft-14** (`moq-transport` 0.14.2 — the production Rust
transport available when the platform was built), while later drafts change the
ALPN identifier, the control-message set, the parameter encoding, and the
data-plane encoding to the point that the working group describes them as "almost
a completely new protocol." Broadcasters plan on five-to-ten-year horizons; a
transport that re-writes its wire format between drafts is, on its face,
incompatible with that planning horizon.

The scale of the fragmentation is visible in the community
[`moq-interop-runner`](https://github.com/englishm/moq-interop-runner) registry,
which as of mid-2026 catalogues production implementations spanning draft-13
through draft-18, with **draft-18** the current interop target. Draft-19 now exists. 
Two qualifications that registry makes visible are worth stating honestly, because they cut 
against an overly bleak reading. First, a draft-14-only endpoint and a draft-18-only
endpoint genuinely cannot negotiate a common ALPN — the hard-partition case is
real. But second, an increasing number of implementations (moxygen, moq-dev,
imquic, and others — now including Rust transports at draft-16–18) negotiate
several drafts from a single build, so the ecosystem is trending toward
multi-draft implementations that bridge the gap rather than a static partition.
The platform's own draft-14 pin, not the protocol's fragmentation as such, is
what currently places it at the older end of that range.

### 5.2 The mitigation

The mitigation is the layering discipline stated as principle 2 in
[architecture](architecture.md) §2 and demonstrated in [evidence](evidence.md) §1:
**the media packaging, catalog, reassembly, control, and entitlement layers are
specified and tested independently of the MoQ transport draft.** The transport
draft governs how bytes move on the wire; the MSFTS/m2ts framing governs what the
bytes mean; the control plane governs who may receive them. Because these are
decoupled and the media layer is covered byte-for-byte by round-trip and property
tests, a transport-draft upgrade is a thin-glue swap *at the media layer* rather
than a media-layer rewrite. That is a narrower claim than "migration is easy":
what the decoupling buys is that the tested media/packaging and grooming code does
not have to change. The *fleet-level* migration is still substantial engineering —
a new ALPN, changed control-message semantics and parameter encoding, relay and
gateway builds that speak the new draft, a period of multi-draft coexistence while
peers upgrade at different rates, phased rollout, and rollback — and that work is
real even when the media layer is untouched.

This has two consequences the rest of the architecture relies on. First, the
platform can track the standards process (adopting draft-18/19 when a production
implementation lands) without destabilising the broadcast-facing layers. Second,
the same decoupling makes the transport genuinely swappable for a *different*
transport entirely (SRT, RIST, RTP) where MoQ is not yet ready — so a control
plane built on it can run over today's transports if MoQ slips.

### 5.3 The residual risk

Decoupling reduces but does not eliminate the risk. If the standard stabilises in
a form that is hostile to opaque transport-stream carriage, or if no production
implementation reaches broadcast-required stability on an acceptable timeline, the
transport choice must change. The architecture survives this (by design), but the
specific "MoQ" framing of the thesis would need revisiting. This is stated as an
open dependency rather than a solved problem.

---

## 6. Interoperability posture

At the transport and carriage layer, interoperability has two faces:

- **Upstream/standards interoperability.** By conforming to the MSFTS `m2ts`
  profile and publishing an MSF catalog, the platform aims to interoperate at the
  media layer with other MoQ implementations that adopt the same profile, even
  where the transport draft differs. Divergence at the transport draft is expected
  and managed (§5); divergence at the media profile would be more damaging and is
  therefore where standards alignment is prioritised. Transport-level interop —
  that two implementations can complete the SETUP, ANNOUNCE, and SUBSCRIBE
  exchanges across a draft boundary — is externally testable via
  [`moq-interop-runner`](https://github.com/englishm/moq-interop-runner), and
  registering the platform's endpoint there is the natural way to demonstrate it
  (§7). That harness deliberately stops at the protocol handshake: it does not
  exercise the MSFTS `m2ts` media profile, verbatim TS carriage fidelity, or
  TR 101 290 conformance. It therefore answers "can the implementations talk?"
  but not "does the installed base survive?" — so the media-profile and
  IRD-conformance validation this platform depends on remains its own
  responsibility, complementary to and not covered by the runner.
- **Downstream/installed-base interoperability.** This is handled entirely at the
  edge gateway ([architecture](architecture.md) §7–§8) and is out of scope for the
  transport itself: the transport delivers intact bytes, and the gateway produces
  IRD-grade output. The detailed compatibility matrix (IRDs, RTP/FEC, ST 2022-7,
  SRT ingest) belongs in [interoperability](interoperability.md).

Known incompatibilities and non-ideal-source behaviour (open-GOP feeds, missing
IDR frames) are documented in [evidence](evidence.md) §5; the opaque lane exists
specifically to be robust to them.

---

## 7. Acceptance criteria

The transport layer's claims are only credible if measured. The criteria that
matter at this layer:

- **Media-layer round-trip fidelity.** The reconstructed transport stream must be
  byte-identical to the source at the payload level (SDT, PMT, PIDs, SCTE-35,
  teletext, continuity counters preserved). This is verified by the round-trip and
  property tests referenced in [evidence](evidence.md) §1.
- **Delivery behaviour under loss/jitter.** Bounded, stable latency and graceful
  degradation under representative public-Internet conditions, characterised in a
  head-to-head lab against SRT/Zixi/RIST ([implementation](implementation.md) §6,
  [economics](economics.md) §8).
- **Downstream conformance after grooming.** A clean TR 101 290 P1/P2 pass on real
  hardware IRDs. This is the make-or-break acceptance criterion for the whole
  thesis; it is a property of transport-plus-grooming, not transport alone, and it
  is tracked in [evidence](evidence.md) §3 and [architecture](architecture.md) §17.
- **Transport-level interoperability with the ecosystem.** The platform's MoQ
  endpoint completes the standard session, namespace, and subscription exchanges
  against independent implementations, demonstrated by registering in and running
  against [`moq-interop-runner`](https://github.com/englishm/moq-interop-runner).
  This is necessary but not sufficient: it proves wire-level interop, not the
  media-layer fidelity or downstream conformance criteria above.

---

## 8. Open questions

- Which MoQ draft will the industry converge on, and on what timeline will a
  production implementation of it reach broadcast-required stability? The
  [`moq-interop-runner`](https://github.com/englishm/moq-interop-runner) registry
  (currently targeting draft-18) is the best running indicator of where that
  convergence is heading and when the platform's draft-14 pin should move.
- Will the MSFTS `m2ts` profile be adopted widely enough to give real media-layer
  interoperability, or will opaque TS carriage remain a minority profile?
- How much of MoQ's graceful-degradation advantage is recoverable under opaque TS
  carriage, and is a media-aware secondary lane worth the interop cost to regain
  it?
- Does the per-stream, subscription-based model deliver a measurable reliability advantage
  over well-run SRT/Zixi/RIST on real routes, or is the advantage swamped by the
  grooming and redundancy layers that all approaches require?

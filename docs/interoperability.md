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
feeds is exactly the upstream work still in progress ([evidence](evidence.md) §5).
The **opaque fallback** preserves all of it *verbatim by construction* — the
MPEG-TS is carried byte-for-byte — which is why it is the safe choice for the
feeds or endpoints where exact preservation is required and the media-aware path
cannot yet guarantee it. The verbatim approach is validated by round-trip and
property tests ([evidence](evidence.md) §1 and §5); its cost — forgoing per-track
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
byte-locked CBR, monotonic PCR re-stamp, PCR re-insertion — is designed to restore
conformant timing ([architecture](architecture.md) §7.2).

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
  downstream errors ([evidence](evidence.md) §5). This is common for contribution,
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
| ST 2022-7 dual-path | — | Yes | Prototype; to be validated on hardware |
| ST 2110 essence | No | — | Longer term; heavier integration |
| Multicast | — | Yes | Prototype; to be validated on hardware |
| TR 101 290 P1/P2 to hardware IRD | — | Yes | **To be validated on real hardware** |
| SCTE-35 / teletext / SDT preservation | Yes | Yes | Test-validated in file ([evidence](evidence.md) §5) |

## 9. Testing and acceptance

- **Round-trip fidelity.** Byte-level preservation of SDT/PMT/PIDs/SCTE-35/
  teletext/continuity across carriage ([evidence](evidence.md) §1).
- **Conformance on hardware.** TR 101 290 P1/P2 pass on real IRDs, captured and
  analysed (TSDuck `pcrverify`/`analyze`, Sencore) — the decisive acceptance test.
- **Non-ideal-source robustness.** A suite of real contribution captures
  (open-GOP, discontinuities, mid-stream PID changes) carried end-to-end without
  loss of service.
- **Redundancy.** Verified hitless ST 2022-7 switching at the egress under induced
  path failure.

## 10. Open questions

- Does groomed MoQ output pass TR 101 290 P1/P2 on the range of hardware IRDs in
  real use, not just one model? (The central open question of the whole thesis;
  shared with [architecture](architecture.md) §17 and [evidence](evidence.md) §3.)
- How should the platform handle multi-programme transport streams where
  entitlement differs per service — carry verbatim and filter at egress, or
  demux earlier?
- What is the correct behaviour on source-side discontinuities and PID changes:
  pass through transparently, or normalise, and at which layer?

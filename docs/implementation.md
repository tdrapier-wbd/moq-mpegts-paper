# Implementation and Testing

Status: working draft
Scope: the bridge from the reference architecture to a running, testable system —
which components are required, where to obtain the public ones, what prerequisites
they impose, a minimal reference deployment, and the test methodology that leads
to the make-or-break hardware-IRD proof. This is the practical companion to
[architecture](architecture.md) and [transport](transport.md).

> **Confidentiality note.** The platform's own publisher/subscriber and grooming
> components are, at the time of writing, a private repository. This document
> references them only by *role*; it does not disclose their internals. Everything
> else here is public, standards-track, or standard broadcast tooling.

---

## 1. Purpose

This document describes *what you would assemble* to stand up an end-to-end path
and prove it works. It is not a step-by-step install guide (versions and commands
move too fast for a reference document) but a map of the components, their
dependencies, and the validation pipeline, with enough specificity to reproduce
the setup.

The end-to-end path being assembled is the one in [architecture](architecture.md)
§3: publisher → cloud relay → edge/subscriber → egress → IRD (or analyser).

## 2. Components

| Role | Component | Source | Public? |
|---|---|---|---|
| MoQ transport (relay + endpoints) | `moq` (moq-dev) / Cloudflare `moq-rs` / `kixelated/moq` | github.com/moq-dev/moq; the wider MoQ implementations | Public |
| Media packaging profile | MSFTS `m2ts` (`draft-gregoire-moq-msfts`) | github.com/mondain/msfts; IETF draft | Public |
| TS analysis / conformance | TSDuck (`tsp`, `pcrverify`, `analyze`) | tsduck.io | Public |
| Publisher (ingest → MoQ) | `moq import ts` on the default media-aware lane; the platform's opaque `m2ts` publisher as the transparency reference | Public (moq-dev) / private repository | Mixed |
| CBR/PCR groomer | [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) — byte-locked CBR, PCR re-stamp, RTP/multicast egress, stream-clocked 1+1 pairing | github.com/tdrapier-wbd/mpegts-pacer | Public |
| Subscriber + egress | `moq export ts` plus the groomer above; the platform subscriber (FEC, ST 2022-7, start gate, egress TR 101 290) as the reference | Public (moq-dev) / private repository | Mixed |
| Control plane | Provisioning/entitlement/observability services | Design ([control-plane](control-plane.md)); not yet a public artifact | **No** |
| Relay host | Cloud VM (e.g. AWS EC2) with public reachability | Any cloud/CDN with QUIC/UDP egress | Public |
| Validation hardware | Hardware IRD(s) and a TR 101 290 analyser (e.g. Sencore) | Broadcast equipment | n/a |

The split has moved since this document was first written, and in the direction the
thesis predicted ([vision](vision.md) §6). The *transport, packaging and the
CBR/PCR grooming stage* are now all reproducible from public sources: the
media-aware lane is upstream, and the groomer is a public crate. What remains
private is the rest of the IRD-facing egress (FEC, ST 2022-7 pairing, start gating,
egress TR 101 290 monitoring) and the control plane. So a reader can reproduce the
whole path from contribution to a conformant CBR RTP egress today, and the
grooming logic is no longer the undisclosed part.

## 3. Prerequisites

- **Toolchain.** A Rust toolchain matching the targeted MoQ implementation
  (the MoQ transport crates are Rust). Standard build tooling for the surrounding
  services.
- **Transport runtime.** QUIC / HTTP-3 support end to end, which in practice means
  UDP reachability (not just TCP/443 proxies) between publisher, relay, and
  subscriber, and a working TLS 1.3 stack. Middleboxes that block or throttle UDP
  will break or degrade the path.
- **Identity / PKI.** Certificates for mTLS between data-plane peers and a signing
  key for subscriber entitlement tokens ([security](security.md) §2, §4). For a
  lab, a private CA is sufficient.
- **Network.** A publicly reachable relay endpoint; on the egress side, the
  ability to emit UDP/RTP and, for realistic tests, IP **multicast** and an
  ST 2022-7 dual-path network path to the IRD.
- **Wire-version pinning.** Neither lane sits on the ecosystem's interop target. The
  preferred media-aware lane rides **moq-lite**, upstream's own simplified wire
  protocol, so it tracks upstream releases rather than the IETF draft series; the
  opaque prototype pins **draft-14** (`moq-transport` 0.14.2). Treat the wire version
  as a pinned dependency and plan migration explicitly ([transport](transport.md) §5).
- **Validation gear.** At least one hardware IRD and, ideally, a TR 101 290
  analyser. File-based analysis (TSDuck) is a necessary but *not sufficient*
  substitute for hardware (§6).

## 4. Reference deployment topology

A minimal but representative end-to-end lab:

```mermaid
flowchart LR
    SRC["Source TS\n(file or live contribution:\nSRT/RTP)"]
    PUB["Publisher\n(media-aware: moq import ts)"]
    RELAY["Cloud relay\n(MoQ, public IP)"]
    SUB["Subscriber + groomer\n(moq export ts → CBR/PCR, egress)"]
    IRD["Hardware IRD\n+ TR 101 290 analyser"]

    SRC --> PUB -->|MoQ over QUIC,\npublic internet| RELAY -->|MoQ over QUIC| SUB -->|"RTP/UDP\n(multicast, ST 2022-7)"| IRD
```

This is the lane that has been run end-to-end over the public internet via a cloud
relay ([evidence](evidence.md) §1); the opaque prototype exercises the same shape on
loopback only. Scaling to the full reference architecture adds relay federation
([relay](relay.md) §6), regional edge gateways, and the control plane, but the
single-path lab above is the unit that must work first.

## 5. Build and run outline

At a high level, and without reproducing sensitive detail:

1. Build/obtain the MoQ relay and stand it up on a publicly reachable host with a
   valid TLS certificate and the pinned ALPN for the targeted draft.
2. Configure the publisher to ingest the source (file or live contribution),
   demultiplex it onto media-aware tracks, publish its catalog, and connect to the
   relay — or, on the fallback lane, package the TS verbatim under an MSF catalog.
3. Configure the subscriber to authenticate, subscribe to the advertised tracks,
   re-mux, groom to CBR with PCR correction, and emit the configured egress.
4. Point the egress at the IRD/analyser and confirm lock and conformance (§6).

## 6. Testing and validation

The validation pyramid below is the conceptual ordering; the formal, executable
plan that operationalises it — with per-test methodology, `tc`/`netem` impairment
profiles, result tables, and pass criteria — is in the [laboratory notebook](../lab/README.md).

The validation pyramid, from cheapest/fastest to most decisive:

1. **Unit / property tests.** Byte-level round-trip fidelity of the media layer,
   *under complete, lossless carriage*: a TS in must reconstruct byte-identically
   at the TS-packet payload level, excluding null packets stripped for transport, and
   service signalling (SDT, NIT, PMT PIDs, `stream_type`, SCTE-35, teletext) must be
   preserved. Continuity counters and the wall clock are *regenerated* on the
   media-aware lane rather than relayed, so they belong to the output mux's own
   correctness rather than to this check ([evidence](evidence.md) §4). This establishes the packaging/reassembly
   contract in the no-loss case; behaviour under object loss (where byte-identity
   necessarily breaks) is a separate concern tested via the redundancy and
   deterministic-grooming path ([architecture](architecture.md) §14.1). These are
   transport-draft-independent by design ([transport](transport.md) §5.2).
2. **End-to-end integration over a real network.** Run the topology of §4 over the
   public internet via the cloud relay and confirm continuous delivery under real
   loss/jitter.
3. **File-based conformance.** Capture the subscriber's egress to file and analyse
   with TSDuck (`pcrverify`, `analyze`) for PCR interval conformance and structural
   integrity. This catches gross problems cheaply but does **not** prove hardware
   acceptance.
4. **Hardware TR 101 290 conformance (the decisive test).** Feed the egress to a
   real hardware IRD and analyser and confirm a clean **P1/P2 pass**. This is the
   single most important acceptance gate in the whole project; until it passes,
   grooming is "structurally sound and file-validated," not "broadcast-acceptable"
   ([architecture](architecture.md) §7.2 and §17, [interoperability](interoperability.md)
   §6).
5. **Non-ideal-source robustness.** Repeat with real contribution captures
   (open-GOP with recovery-point SEI, damaged and spliced audio, discontinuities,
   mid-stream PID changes). This step has done real work: it is what surfaced both
   media-aware import defects that upstream has since fixed
   ([interoperability](interoperability.md) §7).
6. **Redundancy drill.** Induce path failure and confirm hitless ST 2022-7
   switching at the IRD ([architecture](architecture.md) §14). The software half is
   done — a reference receiver loses nothing across leg blackout, path loss and
   differential delay — so the drill's remaining job is the hardware merge, plus
   stating which egress topology is being accepted, since a mergeable *and* groomed
   pair requires either one groomer duplicated onto both paths (protecting the last
   hop only) or two **stream-clocked** groomers, and two arrival-clocked groomers do
   not merge at all ([evidence](evidence.md) §7).
7. **Comparative lab (optional but recommended).** Head-to-head against SRT under matched conditions, feeding the economic model
   ([economics](economics.md) §9).

## 7. Acceptance gates

- **Gate 1 — media fidelity:** round-trip and non-ideal-source tests pass (steps 1,
  5). Cheap, do first.
- **Gate 2 — hardware conformance:** TR 101 290 P1/P2 pass on real IRDs (step 4).
  **Make-or-break;** if this fails, fix grooming before anything else.
- **Gate 3 — resilience:** hitless redundancy drill passes (step 6). Passed in
  software against a reference receiver; the on-hardware merge remains open.

## 8. Version and migration considerations

The wire version is a pinned, tracked dependency, not a stable platform. Plan for
migration as a thin-glue change enabled by the transport-independent layering
([transport](transport.md) §5.2). The
implementation should make the ALPN, control-message set, and data-plane encoding
swappable behind the stable media/packaging interface so that a draft upgrade does
not touch the tested media layer or the grooming logic.

## 9. Open questions

- How is the hardware-IRD test matrix defined (which IRD models, which analyser
  settings) so that a P1/P2 pass is credible across the installed base rather than
  on a single decoder ([interoperability](interoperability.md) §11)?
- Now that the grooming stage is public and the remaining private surface is the
  IRD-facing egress and control plane, does publishing that egress layer buy more in
  credibility than it costs in differentiation? The answer changed once
  [T13](../lab/test-13-downstream-grooming.md) showed the grooming *requirement* can
  be documented with off-the-shelf tools, which removes the argument that keeping the
  groomer private protected anything defensible.

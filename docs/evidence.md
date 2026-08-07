# Evidence: What Has Been Built and Measured

Status: working draft.

The empirical basis for the claims in the [README](../README.md), [transport](transport.md)
and [architecture](architecture.md), for the one question this paper asks: *is MoQ a credible
transport for broadcast primary distribution?* The plan (objectives, gates, pass criteria) and the
executed procedures, commands and full result tables are in the laboratory notebook
([`lab/`](../lab/README.md)). Everything below is measured at
**P1 (file/analyser)**; nothing here
is a hardware IRD pass, and that gate (§3) is still open.

---

## What exists today, and where

Results come from three code bases, and it matters which produced which.

- **Upstream `moq-dev` — the media-aware lane** (`moq import ts` → `moq-relay` →
  `moq export ts`; moq-lite-04 on the wire), which demultiplexes the transport stream into MoQ
  tracks and re-muxes at the subscriber. This is the **preferred path**
  ([architecture](architecture.md) §4.2), the lane deployed over the public internet, and the
  lane most results below were measured on.
- **[`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) (public, ours)** — a
  transport-agnostic CBR/PCR groomer downstream of any MoQ subscriber; not part of the
  transport, deliberately (§3).
- **`moq-publisher-subscriber` (private prototype, ours) — the opaque `m2ts` prototype** (draft-14, MSFTS
  `m2ts` packaging per `draft-gregoire-moq-msfts`, plus an IRD-facing egress). Its role here is
  **reference and benchmark**: it shows what byte-for-byte transparency looks like, so the
  media-aware lane's residual gaps are measured rather than asserted.

| Property | Media-aware lane (`moq-dev` + `mpegts-pacer`) | Opaque prototype (reference) |
|---|---|---|
| Wire version exercised | moq-lite-04 | `moq-transport` draft-14 |
| Elementary streams, original PIDs, SCTE-35 | preserved | preserved verbatim |
| Service layer (SDT/NIT, PMT PID, TSID/ONID) | preserved | preserved verbatim |
| TDT/TOT, EIT | not currently preserved | preserved verbatim |
| CBR and PCR cadence | restored downstream by `mpegts-pacer` | CBR preserved, restored downstream by `mpegts-pacer` |
| IRD egress (RTP/UDP, multicast, FEC, ST 2022-7, de-jitter, start gate, TR 101 290 monitoring) | RTP/UDP multicast by `mpegts-pacer` | implemented (prototype) |
| Public-internet (EC2) operation | yes | yes |
| Congestion-control selection | BBR | quinn default (CUBIC) |

---

## 1. The transport works end-to-end, but the wire is moving

Live MPEG-TS traverses the whole chain over the public internet — SRT contribution into an AWS
EC2 host, `moq import ts` → `moq-relay` → a local `moq export ts` — with **0 continuity
errors** ([lab: T4](../lab/test-4-remote-e2e-srt.md)), and the full ~9.93 Mbps contribution mux
comes home over QUIC at **9.48 Mbps sustained for four minutes, 0 CC**
([lab: T8](../lab/test-8-srt-vs-moq.md)).
The deployed cloud path is the media-aware lane.

**But the wire protocol is moving.** The opaque prototype pins draft-14; the upstream binary
speaks moq-lite-04; the interop target has moved on ([transport](transport.md) §5.1). Drafts
15–18 are, in the working group's words, "almost a completely new protocol" — new ALPN, control
model, parameter and data-plane encodings — so draft-14 and draft-18 endpoints cannot even
agree on an ALPN, and draft-19 now exists. The opaque prototype absorbs that by keeping its
MPEG-TS/MSFTS layer (framing, catalog, reassembly) *independent of the MoQT draft* and covered
byte-for-byte by round-trip and property tests, making an upgrade thin glue rather than a
media-layer rewrite ([transport](transport.md) §5.2). The media-aware lane is better placed
still: its TS↔track mapping is *upstream's* code, so draft churn is absorbed in core. That is
an argument for the preferred lane on stability grounds alone.

## 2. Broadcast-grade egress belongs above the transport

The IRD-facing egress layer built in the opaque prototype (RTP/UDP PT 33 and raw UDP,
multicast, SMPTE 2022-1 FEC, ST 2022-7 hitless dual-path, de-jitter pacing, a decoder-safe
start gate, TR 101 290 monitoring) has no upstream counterpart. Upstream has reasonably scoped
both an opaque TS lane (#1861: "breaks interop with players that don't support TS") and a
generic egress sink (#1839) out of core for the time being — a sensible boundary that marks where
broadcast-specific adaptation belongs. On the preferred lane that layer is re-hosted downstream
of `moq export ts`, alongside the pacer, rather than being intrinsic to a carriage lane.
(Supports [architecture](architecture.md) §4.2 and §7.)

## 3. "Broadcast-grade" ≠ "plays in ffplay" — the PCR problem is inherent

MoQ delivers objects in bursts, so a reconstructed transport stream has PCR *intervals* that no
longer track a constant mux rate: the bytes, PCR values included, are intact; the delivery
*cadence* is not. Soft players tolerate this; **hardware IRDs lock a PLL to PCR and raise
TR 101 290 P1/P2 alarms.** On the media-aware lane 13–26 % of PCR intervals exceeded the 40 ms
limit depending on source, on loopback and over the EC2 path alike
([lab: T2](../lab/test-2-media-aware-transparency.md), [T4](../lab/test-4-remote-e2e-srt.md)); the
opaque prototype fed the raw stream holds **0 % > 40 ms**
([lab: T3](../lab/test-3-opaque-transparency.md)), which isolates cadence loss to the re-mux rather
than to QUIC.
Cadence loss is inherent to the object model, and distinct from the PCR/PTS *regeneration* that
only the media-aware re-mux performs.

The fix is built and public:
[`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) — byte-locked CBR, monotonic PCR
re-stamp, PCR re-insertion, null stuffing, no demux. Fed the bursty media-aware egress it takes
that 13–26 % to **0 %**, with **0 `pcrverify` violations at 500 µs** and 0 CC errors
([lab: T2](../lab/test-2-media-aware-transparency.md), [T7](../lab/test-7-timing-integrity.md)), so the preferred lane plus a downstream pacer
is CBR/PCR-conformant at P1. That is *necessary but not sufficient*: file analysis confirms the
re-stamp arithmetic, not software-pacer jitter or PCR_accuracy (±500 ns) at the physical
output. **The hardware pass remains the open, load-bearing test.** (Supports
[architecture](architecture.md) §7.2.)

## 4. Real feeds broke naive media-aware import — and the gaps closed upstream

A CNN International capture (open-GOP H.264 signalling recovery-point SEI, roughly one IDR every
15 s) produced no video rendition through media-aware import, because keyframe detection keyed
only on the IDR NAL type — and open-GOP is common on contribution feeds, not a niche quirk.

Upstream has since closed most of that gap. #2072 (catalog-reservation gating) and #2066
(recovery-point-SEI detection) make the same feed round-trip deterministically with every
elementary stream, PID, `stream_type` and PMT descriptor intact, all three SCTE-35 splice PIDs
included; PR [#2440](https://github.com/moq-dev/moq/pull/2440) threads the DVB service layer
through the `mpegts` catalog (SDT service name/provider/type, NIT, PMT PID, TSID, ONID). **The
residual media-aware gap is the dynamic TDT/TOT and EIT tables**
([lab: T2](../lab/test-2-media-aware-transparency.md), [T3](../lab/test-3-opaque-transparency.md)),
which the opaque prototype bounds precisely by reproducing the source
byte-for-byte, those tables included.

The same pattern holds beyond the TS mapping: the congestion-control selector (#2432), exporter
survival across session loss (#2469) and standby-route propagation (#2473) are upstream changes
rather than local workarounds (§6, §7). Media-aware is the right default partly for this
reason — its known gaps close in core, on the reference implementation, rather than downstream
of it.

## 5. The entitlement substrate exists

MoQ's authorization hook at subscription time, with its relay and caching semantics, is a
credible *substrate* for dynamic, revocable, multi-tenant entitlement. Two boundaries: the
credential profile enforced there (path-scoped JWTs, mTLS peer identity, `exp` expiry) is a
deployment choice, not a wire primitive MoQ guarantees across implementations, and the
multi-region cluster mesh is distributed-systems work the platform must build. (Supports
[architecture](architecture.md) §10–§11.)

## 6. Loss resilience is a congestion-control choice, and BBR closes the gap to SRT

MoQ's loss resilience is set by its QUIC congestion controller, not by the protocol. Under
quinn's **default loss-based CUBIC**, a head-to-head against SRT over the real EC2→home path
collapses under uniform loss ≥ 2 % (53 % delivered at 2 %, 13 % at 10 %), 25 % reordering
(20 %) and a combined WAN profile (14 %), while SRT holds full rate throughout: loss-based CC
misreads random loss as congestion. Switching to **BBR**
(`--server/client-quic-congestion-control=delay`, PR
[#2432](https://github.com/moq-dev/moq/pull/2432); BBRv1 on quinn) removes the collapse
entirely — full-rate and byte-complete through 10 % loss, 25 % reordering and the WAN profile,
**on par with SRT** ([lab: T8](../lab/test-8-srt-vs-moq.md)). The change is **sender-local and
per-connection**: not on the wire, not negotiated, interop preserved, and because MoQ is
hop-by-hop QUIC it can be enabled on just the lossy relay→subscriber hop. (Supports the
graceful-congestion claim in the [README](../README.md), [transport](transport.md) §3.1 and
[relay](relay.md) §5.)

The residual weakness is **reordering, not delay variation**: in-order jitter (`netem slot`)
delivers **97 %** at 60 ± 30 ms, while non-ordered jitter of the same magnitude collapses to
~7–13 % under every controller. That is QUIC in-order-stream head-of-line blocking, a
loss-detection item rather than a CC or protocol flaw; terrestrial paths reorder far less than
`netem`'s model, making it largely an emulator artefact, with unbounded reordering mainly a
LEO/mobile-handover concern ([lab: T8](../lab/test-8-srt-vs-moq.md),
[planned](../lab/planned-experiments.md)).

Two boundaries: this is a single home path with forward-path-only impairment, and an
over-provisioned matrix measures *loss tolerance* rather than congestion control proper (congestion
control under a shaped bottleneck has only a first-pass, not-yet-validated result,
[lab: T8b](../lab/test-8b-congestion-control.md)). BBR generation is backend-specific — quinn-BBRv1 and
noq-BBRv3 strongest, quiche-BBRv2 weakest, with v1 fairness and a very-high-loss cliff
uncharacterised — so quinn-BBRv1 is the pragmatic default today. The first-pass congestion run
(T8b) complicates this for a *permanent fixed-rate* trunk — quinn-BBRv1 showed intermittent bloat
there — but that result is not yet validated and does not change this recommendation.

## 7. Transport resilience holds; active/active source failover ships only as a bounded reselect

The redundancy model MoQ is built around is sound: thin, auto-reconnecting endpoints, redundancy
in the relay mesh, hitless selection at the receiver. Crate inspection plus drills on the
media-aware lane ([lab: T6](../lab/test-6-relay-resilience.md)) establish what it delivers today; the
full drill history — including two of the four original findings later retracted as harness
artefacts, and the corrected drill contributed upstream as
[#2545](https://github.com/moq-dev/moq/pull/2545) — is preserved in the notebook.

**Working.** Two independent `moq export ts` subscribers produce byte-identical, continuous
captures of the same broadcast, so fan-out to N subscribers → N pacers → N IRDs needs no extra
machinery. `moq import ts` redials the same relay with jittered exponential backoff and
re-announces on every session, and two-relay clustering carries the feed
while tolerating a duplicate publisher. The exporter survives session loss and resumes
(fixed by [#2469](https://github.com/moq-dev/moq/pull/2469)): under a relay kill and restart
both exporters stay alive, skip the evicted group, reconnect and resume byte-identical output
about 17 s later — automatic and bounded rather than hitless, the gap being a clean
object-boundary skip that downstream ST 2022-7 / IRD selection absorbs.
[#2647](https://github.com/moq-dev/moq/pull/2647) (re-verified on `main` `a6dd44a6`, 2026-08-06)
tightens this: the reconnect backoff ceiling drops 30 s → 5 s and the retry loop is now
time-bounded (~10 s give-up) rather than the old 5-minute loop, so on a relay restart the
exporter re-attaches within one ~5 s poll of the relay returning (measured ~4 s), and a *dead*
relay now surfaces an error in tens of seconds (bounded by the connect timeout, hence tunable)
instead of retrying silently — the axis that matters for supervisor-driven subscriber re-home
([transport](transport.md) §8.4). [#2615](https://github.com/moq-dev/moq/pull/2615)'s new 30 s
media-track retention (and `moq import --latency-max`) does **not** change this: the subscription
still follows the live edge, so resume skips to the newest group rather than replaying retained
history (verified — the resume drained a few seconds, not 30 s). Re-verified again on the **0.14.8
release** (2026-08-07), which carries [#2701](https://github.com/moq-dev/moq/pull/2701) — a fix for a
takeover **livelock** that could spin every relay worker inside a single poll and leave the process
alive but serving nothing, triggered by cluster peer churn. It changes none of the measurements here,
but it was latent in every build this section reports on, and it is the reason relay monitoring has to
test liveness rather than process existence ([operations](operations.md) §3).

**Bounded by detection.** Detection on a hard kill is gated by the QUIC idle timeout (default
30 s, which must stay above the 5 s keep-alive), so every recovery time below is dominated by
detection, not by the ~1 s backoff. This is architectural rather than incidental: a relay has no
model of a broadcast's expected cadence, so it cannot treat silence as failure the way an
application that knows its own frame rate could — it must wait for the transport to declare the
peer gone. Upstream is considering a lower default (~10 s) as a separate change.

**Active/active source failover: a bounded route reselect, not a seamless merge.** Before
[#2473](https://github.com/moq-dev/moq/pull/2473), two publishers of the *same* broadcast at one
relay made the path `unroutable` and tore down both, and across a two-relay mesh the pair coexisted
without the relay failing its source over — the standby's route was never propagated back, because
a relay advertised one best route per path and skipped the announce entirely when that chain
contained the peer. Cost and standby routing (#2424, in the opt-in `moq-lite-06-wip` version) could
not help, since the blocker was route *propagation*, not pricing. #2473 fixes that by advertising,
per peer, the best route whose hop chain *excludes* the requester, plus a `moq --origin <id>` knob
by which a 1+1 pair **declares its two feeds interchangeable — an explicit promise of identical
content, which the relay never infers**: as the maintainer confirms, the relay is content-agnostic
(the bytes are either the same or different, and it will not rewrite timestamps to bridge two
broadcasts). It ships on `main` (release `moq-net 0.2.5`).

**The two-relay drill passes end to end** ([lab: T6](../lab/test-6-relay-resilience.md)): relay B advertises
the standby to relay A the instant the standby publisher joins, and when the active publisher is
killed relay A splices onto that standby, with the subscriber resuming **~30–33 s after the kill** —
one idle timeout; detection dominates and the reselect itself is essentially free, provided the
publisher pipeline is killed atomically. A later fix,
[#2556](https://github.com/moq-dev/moq/pull/2556), targets the distinct case of a publisher
reclaiming *its own* path on reconnect and leaves shared-origin 1+1 standbys unchanged; its recency
tie-break does not fire here because the active and standby routes differ on cost, so the failover
time is governed by detection either way.

**The requirement is a common source, not byte-identical segmentation** (single-source study on
`moq-relay 0.14.3-b87d4e92`, 2026-08-03; re-verified on the **0.14.7 release** — cluster extension
[#2629](https://github.com/moq-dev/moq/pull/2629), namespace-detach
[#2616](https://github.com/moq-dev/moq/pull/2616), and resume/route hardening
[#2666](https://github.com/moq-dev/moq/pull/2666) — 2026-08-05, unchanged). A moq group sequence number
is a per-importer counter reset
to 0 at the first keyframe (`append_group()`), while track names and PTS come from the source bytes,
so two publishers are interchangeable when they are two views of *one* feed. Fed a single source, two
co-started importers produce essentially identical subscriber output up to the kill (byte-for-byte on
0.14.3; on 0.14.7 a constant 4-packet, 752-byte startup preamble differs, with identical per-second
deltas thereafter — the steady-state content is the same), and failover
is clean. Crucially for broadcast — where a publisher always joins an already-running feed — a standby
that joins **mid-stream** (its group numbering therefore *offset* from the active's) **still fails over
cleanly**: the exporter subscribes once, never reinitialises the catalog, and skips to the standby's
live edge, so byte-identical numbering is sufficient but not necessary. What a shared source rules out
— a divergent track layout or codec across the pair — is what would actually make failover impossible.

**Continuity-clean, but not hitless.** The resumed capture carries **0 TS continuity-counter errors**
(the exporter's single output mux never resets), so it is structurally valid; the outage instead
appears as a **PCR/PTS discontinuity** (`tsp analyze` reports `pcrleap` on the PCR PID at CC=0) — a
content hole the media clock jumps across, i.e. break-before-make. The window is the QUIC idle timeout
and is tunable: `--server-quic-idle-timeout 10s` gives an ~11 s reselect, but a 5 s idle (1 s
keep-alive) is fragile — the switch failed to complete. Sub-second / hitless is not a relay-reselect
property; it must live at the receiver (ST 2022-7 dual-subscribe over the common source), which the
identical-broadcast result is exactly what makes feasible.

**Spec vs. implementation, precisely.** The behaviour above is *this implementation's*, not MOQT's
ceiling. The IETF draft (draft-ietf-moq-transport-19 §9.3) does envisage relay-level *object*
de-duplication — "Relays … SHOULD attempt to deduplicate Objects before forwarding, subject to
implementation constraints" — keyed on Full Track Name + Group ID + Object ID (§9.1, first-copy-wins),
with a mismatched payload for the same identifier making the track *Malformed* and the relay terminating
downstream subscriptions (§2.4.2). So hitless active/active by relay dedup is the *standard's* model, and
`moq-dev`/`moq-lite` simply implements the permitted alternative (content-agnostic route selection) rather
than object dedup. Two caveats keep this from changing the recommendation. First, even spec-conformant
dedup requires *identical object identifiers*, not merely identical media bytes: a moq group sequence
number is a per-importer counter reset at the first keyframe, so two independent publishers do not
naturally share Group/Object IDs, and a dedup relay would not treat offset objects as duplicates —
conformant dedup therefore needs encoder+publisher determinism down to MoQ object segmentation and
numbering, the object-layer analogue of ST 2022-7's aligned RTP sequence numbers and a strictly stronger
bar than "bit-for-bit identical." Second, what is out of scope in *both* spec and implementation is
bridging two *different* broadcasts (timestamp rewriting) — that is the Malformed case, and the "won't
merge two broadcasts" the maintainer describes. Receiver-side ST 2022-7 selection over a common source
therefore remains the robust, buildable-today path, now *reinforced* rather than merely necessitated.

One caveat remains, and it is the operationally important one: **graceful
departure of the active source is not failed over at all.** When the active publisher exits
cleanly rather than dying, the relay does not reselect onto the standby — it propagates
completion. Both media tracks report `subscribe complete`, the catalog subscription is
`canceled (idle)`, no route change is attempted, and the subscriber's `moq export ts` terminates
with `TS track layout changed after PAT/PMT was emitted`. The relay cannot distinguish "this source
is done, and so is the content" from "this source is done, but an interchangeable one exists", so a
shared `--origin` buys nothing here. This is now confirmed to be **intended semantics rather than a
defect**: upstream's model tests assert it directly, requiring that a clean finish leave *no*
lingering broadcast to splice into, on the reading that a source which finishes has declared its
content over. The consequence for broadcast is unchanged and awkward — the failover path covers the
*harder* failure mode (host loss) and not the easier, far more common one: SIGTERM to an encoder, a
container rescheduled, a rolling restart. The remedy is a *semantic* one, giving a consumer the bit
that separates "this source finished" from "this content is over". That work is now consolidated in
[#2610](https://github.com/moq-dev/moq/issues/2610) (which supersedes the earlier announcement-epoch
issue #2330): a publisher-minted, strictly increasing **epoch** per path, where equal non-zero epochs
splice and a higher epoch takes over, plus an explicit `Ended` flag distinguishing live from complete
content. That is precisely the missing bit, so it is the upstream thread worth tracking — but it is
specified, not shipped.

**Posture buildable now.** With the exporter crash fixed, no external subscriber supervisor is
needed for relay maintenance or transient loss. Service redundancy still comes from a fully
doubled chain — dual publishers → dual relays → dual subscribers → dual pacers → downstream
ST 2022-7 / IRD failover — letting the *receiver* do hitless selection. Relay-mesh source
failover does not change that recommendation now that #2473 has landed: at one idle timeout it is
**bounded, not hitless**, protecting against a dead source rather than delivering the seamless
switch a broadcast chain expects, and on the graceful-exit path it does not protect at all. A
*seamless* relay-side merge is out of scope for *this implementation* (the draft specifies object-dedup
only as a hedged SHOULD, and `moq-lite` takes the route-selection alternative; see the spec cross-check
above) — the content-agnostic relay will not bridge two broadcasts, so a gap-free switch needs either
wall-clock-aligned encoders
(Elemental's approach) or a receiver that reinitialises on the switch. That makes relay reselect a
**bounded nice-to-have**; the load-bearing resilience stays the doubled chain with the *receiver*
making the hitless decision. The two are complementary — the mesh keeps both
flows healthy and reachable, the receiver makes the hitless decision. (Supports
[transport](transport.md) §8, [relay](relay.md) §5.1, and [architecture](architecture.md) §14.)

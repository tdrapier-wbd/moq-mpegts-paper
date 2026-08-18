# Evidence: What Has Been Built and Measured

Status: working draft.
Layer: **cross-cutting** — measurements from every layer. §1–§9 are the MoQ data plane, because that is
what the prototype runs on; §10 measures segmented HTTP against it; the grooming and redundancy results
belong to the layer above the transport and apply to both.

The empirical basis for the claims in the [README](../README.md), [transport](transport.md)
and [architecture](architecture.md), for the question this paper asks: *what does an Internet-native
primary-distribution path have to do to be broadcast-grade, and which data plane should carry it?* Most
of what follows is measured on MoQ, because that is what the prototype runs on; §10 measures the
alternative. The plan (objectives, gates, pass criteria) and the executed procedures, commands and full
result tables are in the laboratory notebook ([`lab/`](../lab/README.md)). Every conformance figure below
is measured at **P1 (file/analyser)** or against a reference software receiver; nothing here is a
hardware IRD pass, and that gate (§3) is still open.

---

## What exists today, and where

Results come from four code bases, and it matters which produced which.

- **Upstream `moq-dev` — the media-aware lane** (`moq import ts` → `moq-relay` →
  `moq export ts`; moq-lite-04 on the wire), which demultiplexes the transport stream into MoQ
  tracks and re-muxes at the subscriber. This is the **preferred path**
  ([architecture](architecture.md) §4.2), the lane deployed over the public internet, and the
  lane almost every result below was measured on.
- **[`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) (public, ours)** — a
  CBR/PCR groomer, deliberately outside the transport (§3). Every result below exercises it on a
  MoQ egress; §10 measures what a segmented-HTTP egress would ask of it instead.
- **`moq-publisher-subscriber` (private prototype, ours) — the opaque `m2ts` prototype** (draft-14,
  MSFTS `m2ts` packaging per `draft-gregoire-moq-msfts`, with its own IRD-facing egress). Its role
  here is **reference and benchmark**: it shows what byte-for-byte transparency looks like, so the
  media-aware lane's residual gaps are measured rather than asserted. It has only ever run on
  loopback.
- **TSDuck's `hls` output and input plugins — the segmented-HTTP leg** (§10). Not a MoQ component at
  all: it is the *alternative* data plane, published and reassembled with the same tool that serves as
  the same oracle used throughout, so its results are directly comparable with the MoQ rows.

| Property | Media-aware lane (`moq-dev` + `mpegts-pacer`) | Opaque prototype (reference) |
|---|---|---|
| Wire version exercised | moq-lite-04 | `moq-transport` draft-14 |
| Elementary streams, original PIDs, SCTE-35 | preserved | preserved verbatim |
| Service layer (SDT/NIT, PMT PID, TSID/ONID) | preserved | preserved verbatim |
| TDT/TOT | not preserved, by design (§4) | preserved verbatim |
| EIT | present/following round-trips byte-identically on an open upstream PR, so no released build carries it; schedule and p/f-other excluded by design | preserved verbatim |
| CBR and PCR cadence | restored downstream by `mpegts-pacer` | preserved end to end by the prototype's own pacer |
| IRD egress (RTP/UDP, multicast, FEC, ST 2022-7, de-jitter, start gate, TR 101 290 monitoring) | RTP/UDP by `mpegts-pacer`, with ST 2022-7 pairing measured at a receiver (§7) | implemented; measured here only for the start gate, CBR pacing and egress monitoring |
| Public-internet (EC2) operation | yes | no — never deployed off loopback |
| Congestion-control selection | BBR | quinn default (CUBIC) |

---

## 1. The transport works end-to-end, but the wire is moving

Live MPEG-TS traverses the whole chain over the public internet — SRT contribution into an AWS
EC2 host, `moq import ts` → `moq-relay` → a local `moq export ts` — with **0 continuity
errors** ([lab: T4](../lab/test-4-remote-e2e-srt.md)), and the full ~9.93 Mbps contribution mux
comes home over QUIC at **9.48 Mbps sustained for four minutes, 0 CC**
([lab: T8](../lab/test-8-srt-vs-moq.md)). The deployed cloud path is the media-aware lane; the
opaque prototype has never left loopback, which is a deployment gap rather than a transport one.

**But the wire protocol is moving.** The opaque prototype pins draft-14, the upstream binary
speaks moq-lite-04, and the interop target has moved on ([transport](transport.md) §5.1). Drafts
15–18 are, in the working group's words, "almost a completely new protocol" — new ALPN, control
model, parameter and data-plane encodings — so draft-14 and draft-18 endpoints cannot even agree
on an ALPN, and draft-19 now exists. The opaque prototype absorbs that by keeping its
MPEG-TS/MSFTS layer (framing, catalog, reassembly) *independent of the MoQT draft* and covered
byte-for-byte by round-trip tests, making an upgrade thin glue rather than a media-layer rewrite
([transport](transport.md) §5.2). The media-aware lane is better placed still: its TS↔track
mapping is *upstream's* code, so draft churn is absorbed in core. That is an argument for the
preferred lane on stability grounds alone.

## 2. Broadcast-grade egress belongs above the transport

The IRD-facing egress layer built in the opaque prototype — RTP/UDP and raw UDP, multicast,
SMPTE 2022-1 FEC, ST 2022-7 dual-path, de-jitter pacing, a decoder-safe start gate and read-only
TR 101 290 monitoring — has no upstream counterpart. Upstream has reasonably scoped both an opaque
TS lane and a generic egress sink out of core, the first because it "breaks interop with players
that don't support TS" — a sensible boundary that marks where broadcast-specific adaptation
belongs. On the preferred lane that layer is re-hosted downstream of `moq export ts`, alongside the
pacer, rather than being intrinsic to a carriage lane. (Supports
[architecture](architecture.md) §4.2 and §7.)

## 3. "Broadcast-grade" ≠ "plays in ffplay" — the PCR problem is inherent to bursty delivery

Bursty delivery leaves a reconstructed transport stream with PCR *intervals* that no
longer track a constant mux rate: the bytes, PCR values included, are intact; the delivery
*cadence* is not. Soft players tolerate this; **hardware IRDs lock a PLL to PCR and raise
TR 101 290 P1/P2 alarms.** The figures below are MoQ's, because that is what the prototype runs on;
**§10 measures the same effect on segmented HTTP and finds it two orders of magnitude worse**, so
nothing in this section should be read as a MoQ-specific penalty.

On the media-aware lane 13–26 % of PCR intervals exceeded the 40 ms
limit depending on source, on loopback and over the EC2 path alike
([lab: T2](../lab/test-2-media-aware-transparency.md), [T4](../lab/test-4-remote-e2e-srt.md));
the opaque prototype fed the raw stream holds **0 % > 40 ms**
([lab: T3](../lab/test-3-opaque-transparency.md)), which isolates cadence loss to the re-mux
rather than to QUIC. Cadence loss is inherent to object delivery over any congestion-adaptive
transport, and distinct from the PCR/PTS *regeneration* that only the media-aware re-mux performs.

The fix is built and public:
[`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) — byte-locked CBR, monotonic PCR
re-stamp, PCR re-insertion, null stuffing, no demux. Fed the bursty media-aware egress it takes
that 13–26 % to **0 %**, with **0 `pcrverify` violations at 500 µs** and 0 CC errors
([lab: T2](../lab/test-2-media-aware-transparency.md), [T7](../lab/test-7-timing-integrity.md)),
so the preferred lane plus a downstream pacer is CBR/PCR-conformant at P1. Tightening the check
to TR 101 290's PCR_accuracy limit of ±500 ns does not change the verdict: **0 of 2 598 PCRs
outside it on a groomed output, against 1 523 of 1 524 for the same feed delivered ungroomed**
([lab: T12](../lab/test-12-dual-path-handoff.md)). Two qualifications keep this honest. The 0 %
interval result is measured at a carrier rate matched to the content; a 4 Mbps carrier for a
1.9 Mbps feed leaves 1.4 % of intervals above 40 ms even with a clean source, and whether that is
inherent to heavy stuffing or a groomer defect is unresolved. And all of it is *necessary but not
sufficient*: file analysis confirms the re-stamp arithmetic, not software-pacer jitter at the
physical output. **The hardware pass remains the open, load-bearing test.** (Supports
[architecture](architecture.md) §7.2.)

**The grooming stage is not locked to one implementation, but nothing off the shelf does the whole
job.** Graded against the same oracle, the standard tools each fail a different one of the three
requirements — restore CBR stuffing, hold PCR accuracy, preserve signalling — and none paces the
wire. TSDuck preserves the mux byte-for-byte and passes ±500 ns via `pcradjust`, but cannot inflate a
stream to a nominal service rate at all (`tsp` overwrites existing nulls rather than adding them), and
rewrites PTS/DTS. The regenerating muxers fix rate, repetition and accuracy — FFmpeg to 8.8 µs,
GStreamer to 25 µs — by rebuilding the mux, which costs signalling: FFmpeg keeps every PID but retypes
SCTE-35, GStreamer types SCTE-35 correctly on one PID and discards all PSI beyond PAT and PMT. Neither
emits a usable wire shape, oscillating 8–13 Mb/s with gigabit peaks or falling silent for up to 284 ms,
against a paced chain's 9.70–9.73 Mb/s and no gap beyond 15 ms
([lab: T13](../lab/test-13-downstream-grooming.md)). So the requirement is documentable with standard
tools where signalling is not contractual and the receiver tolerates a bursty wire; a mux carrying full
signalling to a hardware receiver still needs a purpose-built stage.

## 4. Real feeds broke naive media-aware import — and the gaps closed upstream

A CNN International capture (open-GOP H.264 signalling recovery-point SEI, roughly one IDR every
15 s) produced no video rendition through media-aware import, because keyframe detection keyed only
on the IDR NAL type — and open-GOP is common on contribution feeds, not a niche quirk. Upstream has
since closed that gap, and it is verified here rather than taken on trust: with catalog-reservation
gating and recovery-point-SEI detection the same feed round-trips deterministically with every
elementary stream, PID, `stream_type` and PMT descriptor intact, all three SCTE-35 splice PIDs
included, and [#2440](https://github.com/moq-dev/moq/pull/2440) threads the DVB service layer
(SDT service name/provider/type, NIT, PMT PID, TSID, ONID) through the catalog. Neither open-GOP
encoding nor the DVB service layer is any longer a reason to prefer the opaque lane.

**What the media-aware lane must now regenerate rather than relay is the clock, not the tables.**
Reading the import gate suggests a residual of "TDT/TOT and EIT". Measured
on a synthetic fixture — no capture held here carries EIT — both were confirmed absent at egress,
and the measurement then split them, because they revise at opposite rates. EIT repeats
byte-identically between event transitions, so carrying it through the catalog costs ~12 updates and
~1.3 kB over ten minutes, the same order as SDT and NIT. Every TDT/TOT section is new content, so
every one is a republish, for a table that says nothing but "now" and that an exporter can mint more
accurately than it can relay. Upstream PR
[#2824](https://github.com/moq-dev/moq/pull/2824) acts on that split and carries EIT
present/following actual through the round-trip **byte-identically**, including a clean version roll
and correct suppression of sections not yet in force, while excluding EIT schedule and p/f *other*
by design. Two caveats: **the PR is open, so no released build carries EIT**, and dropping TDT/TOT
matters more once the EPG survives, because a receiver with no wall clock has nothing to place the
EPG against ([lab: T2](../lab/test-2-media-aware-transparency.md),
[T3](../lab/test-3-opaque-transparency.md)).

**Carrying service information in the catalog is cheap for the tables that shipped and expensive for
the one that has not.** The catalog is whole-state, so one changed section rewrites the whole
document and every subscriber pays for it at join. SDT and NIT cost nothing after acquisition —
neither turns over — but EIT's cost is the product of two growing terms, the number of republishes at
a programme junction and the size of each document: at 40 services a junction costs 61 republishes of
an 18 kB catalog within 1.27 s, against 2 republishes of 2.2 kB at one service. The bandwidth is
noise; what the numbers indict is the *join* (18 kB read before media discovery, 93 % of it service
information) and the *parsing*. A second finding is not about scale at all: a multi-section table is
assembled in the catalog **in public**, so an exporter re-emitting a half-assembled SDT puts a table
on the wire that announces two sections and transmits one — incomplete rather than merely stale.
These are the measurements behind [#2882](https://github.com/moq-dev/moq/issues/2882), which asks
whether carried service information belongs in the catalog or on its own snapshot track; they support
the move on coherence grounds, and also show that the tables #2440 shipped would gain nothing from
it.

**A second real-feed defect, of a more serious kind, closed the same way.** Until recently a single
damaged byte in an MP2, AC-3 or E-AC-3 frame header terminated the publisher outright and took every
other track — video, teletext, all three SCTE-35 PIDs — with it, while the video path resynchronised
through identical corruption. That is the wrong way round for a contribution feed, where a momentary
bit error should cost a few milliseconds of audio rather than a session teardown. Reported and fixed
within two days ([#2729](https://github.com/moq-dev/moq/issues/2729),
[#2751](https://github.com/moq-dev/moq/pull/2751)) and verified here against both builds: the same
damaged capture that killed the previous release now costs **exactly one 24 ms audio frame**, with
every other track intact and nothing spurious emitted. The fix also reached a defect we had not
found — AAC frames split across a PES boundary were never reassembled at all, so a legal mux could
kill a broadcast with no corruption involved.

**A bit error and a splice are not the same defect, and closing the first left the second open.**
Where the damage is a corrupt byte, the parser rejects the frame and drops it. Where it is a
*splice* — a feed restarting, a dropped PES, a looping file wrapping mid-frame — the header is intact
and only the bytes after it are foreign, so the frame is published: not a frame lost but a frame
**substituted**, carrying audio from both sides of the discontinuity. That is the harder case to
detect downstream, because a substituted frame of the right length in the right place leaves the
timeline intact — no continuity error, no discontinuity flag, evenly spaced timestamps — whereas a
dropped frame at least shows up in a frame count. The mechanism that catches it was already in the
stream and already implemented next door: the transport continuity counter, which the same demuxer
checked for private sections but not for elementary streams. Upstream adopted exactly that
([#2823](https://github.com/moq-dev/moq/pull/2823)), and the substituted frame is gone from the
capture that produced it.

Two residuals survive that fix, both measured. The guard trusts one signal, so where a wrap happens
to leave the counter *contiguous* — about one cut point in sixteen — the splice is invisible again
and the mixed frame returns. A codec CRC would close that, and AC-3's rejects every mixed frame
measured, but it cannot be the general answer because MP2 carries no CRC at all in this feed. And
the fix has a cost that falls unevenly: the truncated PES is meant to be flushed so the whole frames
it already carried still publish, which MP2 gets and AC-3 does not — about **256 ms of good audio
lost per splice on AC-3**, where MP2 loses nothing.

One further residual, which is a gap rather than a fault: **a recovered stream is signalled
nowhere**, whether the recovery dropped a frame or substituted one. There is no continuity error, no
discontinuity indicator, no log line and no counter; the audio timeline simply steps over the hole.
A feed quietly losing frames is indistinguishable from a healthy one, which is a real loss of
diagnostic signal in exchange for the robustness. For an architecture that treats the ingest edge as
the place where a contribution feed's defects are absorbed, the absorbing needs to be observable
([#2798](https://github.com/moq-dev/moq/issues/2798), [lab: T9](../lab/test-9-performance.md)).

The same pattern holds beyond the TS mapping: the congestion-control selector (#2432), exporter
survival across session loss (#2469) and standby-route propagation (#2473) are upstream changes
rather than local workarounds (§6, §7). Media-aware is the right default partly for this reason —
its known gaps close in core, on the reference implementation, rather than downstream of it.

## 5. The entitlement substrate exists

MoQ's authorization hook at subscription time, with its relay and caching semantics, is a
credible *substrate* for dynamic, revocable, multi-tenant entitlement. This is an architectural
reading of the protocol rather than a measurement, and it carries two boundaries: the
credential profile enforced there (path-scoped JWTs, mTLS peer identity, `exp` expiry) is a
deployment choice, not a wire primitive MoQ guarantees across implementations, and the
multi-region cluster mesh is distributed-systems work the platform must build. (Supports
[architecture](architecture.md) §10–§11.)

## 6. Loss resilience is a congestion-control choice, and BBR closes the gap to SRT

MoQ's loss resilience is set by its QUIC congestion controller, not by the protocol. Under quinn's
**default loss-based CUBIC**, a head-to-head against SRT over the real EC2→home path collapses
under uniform loss ≥ 2 % (53 % delivered at 2 %, 13 % at 10 %), 25 % reordering (20 %) and a
combined WAN profile (14 %), while SRT holds full rate throughout: loss-based CC misreads random
loss as congestion. Switching to **BBR on the quinn backend**
(`--server/client-quic-congestion-control=delay`, [#2432](https://github.com/moq-dev/moq/pull/2432);
BBRv1 there) removes the collapse entirely — full-rate and byte-complete through 10 % loss, 25 %
reordering and the WAN profile, **on par with SRT** ([lab: T8](../lab/test-8-srt-vs-moq.md)). The
change is **sender-local and per-connection**: not on the wire, not negotiated, interop preserved,
and because MoQ is hop-by-hop QUIC it can be enabled on just the lossy relay→subscriber hop.
(Supports the graceful-congestion claim in the [README](../README.md), [transport](transport.md)
§3.1 and [relay](relay.md) §5.)

The residual weakness is **reordering, not delay variation**: in-order jitter delivers **97 %** at
60 ± 30 ms, while non-ordered jitter of the same magnitude collapses under every controller — 2 %
under CUBIC, 7–13 % under quinn-BBRv1, unstable under BBRv3. That is QUIC in-order-stream
head-of-line blocking, a loss-detection item rather than a CC or protocol flaw; terrestrial paths
reorder far less than the emulator's model, so unbounded reordering is mainly a LEO/mobile-handover
concern ([lab: T8](../lab/test-8-srt-vs-moq.md), [planned](../lab/planned-experiments.md)).

Two boundaries. This is a single home path with forward-path-only impairment, and an
over-provisioned matrix measures *loss tolerance* rather than congestion control proper. **BBR
generation is backend-specific**, and the ranking inverts between the two regimes: against
non-congestive impairment quinn-BBRv1 and noq-BBRv3 are strongest and quiche-BBRv2 still collapses
to 25–31 % under bounded reordering, so quinn-BBRv1 is the pragmatic default today; under a shaped
bottleneck quinn-BBRv1 instead shows intermittent queue bloat, which would disqualify it for a
permanent fixed-rate trunk ([lab: T8b](../lab/test-8b-congestion-control.md)). Pin the controller
explicitly either way, because the resolved default differs per backend. The provisioned-path
conditions that would settle the trunk case are unrun, so no single controller recommendation covers
both regimes yet.

## 7. Transport resilience holds; source failover is bounded; the receiver-side 1+1 splice is hitless

**Transport-level resilience is essentially free.** Two independent `moq export ts` subscribers
produce byte-identical continuous captures of one broadcast, so fan-out to N subscribers → N pacers
→ N IRDs needs no extra machinery. The importer redials its relay with jittered backoff and
re-announces on every session, two-relay clustering carries the feed while tolerating a duplicate
publisher, and since [#2469](https://github.com/moq-dev/moq/pull/2469) the exporter survives a relay
kill and restart — it skips the evicted group and resumes byte-identical output automatically, a
clean object-boundary gap that downstream ST 2022-7 selection absorbs.
[#2647](https://github.com/moq-dev/moq/pull/2647) tightened this further, so the exporter re-attaches
within seconds of a relay returning while a genuinely *dead* relay now errors in tens of seconds
instead of retrying silently — the axis that matters for a supervisor deciding to re-home a
subscriber ([transport](transport.md) §8.3). Three operational boundaries: a redundant publisher
pair needs a **relay mesh**, because two publishers on a single relay make the path unroutable and
tear both down; a publisher reconnecting under a *fresh* identity kills the exporter, where one
reconnecting under a shared `--origin` survives; and a takeover livelock fixed in
[#2701](https://github.com/moq-dev/moq/pull/2701) could pin every relay worker while leaving the
process alive, which is why relay monitoring must test liveness rather than process existence
([operations](operations.md) §3).

**Source failover across a relay mesh works, and is bounded by detection rather than recovery.**
[#2473](https://github.com/moq-dev/moq/pull/2473) made a 1+1 pair usable at all: a relay advertises,
per peer, the best route whose hop chain *excludes* the requester, and a `moq --origin <id>` flag
lets two publishers **declare their feeds interchangeable** — explicitly, because the relay is
content-agnostic and will not infer it. The two-relay drill then passes end to end, the standby being
advertised the instant its publisher joins. But nothing downstream learns of a hard failure until the
QUIC **idle timeout** expires, so the subscriber resumes one idle timeout later (~30 s at the
default, ~11 s with it set to 10 s) and the reselect itself is free by comparison. That wait is
architectural rather than incidental: a relay has no model of a broadcast's expected cadence, so it
cannot treat silence as failure.

**The precondition is a common source, not byte-identical segmentation.** MoQ numbers groups with a
per-publisher counter reset at the first keyframe, while track names and timestamps come from the
source bytes, so two publishers are interchangeable when they are two views of *one* feed. A standby
that joins **mid-stream**, with group numbering offset from the active's, still fails over cleanly:
the subscriber never reinitialises its catalog and skips to the standby's live edge. What a shared
source rules out is a divergent track layout or codec across the pair.

**Continuity-clean is not hitless.** The resumed capture carries **0 continuity-counter errors**,
because the subscriber's output mux never resets, so the file stays structurally valid; the outage
appears instead as a **PCR/PTS discontinuity** — break-before-make across a content hole. Sub-second
switching is not a relay-reselect property at all. The IETF draft does envisage relays
de-duplicating *objects* from redundant sources, which would be a seamless merge, but it hedges that
as a SHOULD and keys it on identical object *identifiers* rather than identical bytes; independent
publishers do not naturally share those, so conformant dedup demands determinism down to object
segmentation and numbering — a stricter bar than bit-for-bit identical payloads. `moq-dev` implements
the permitted alternative, content-agnostic route selection, and bridging two genuinely *different*
broadcasts is out of scope in the spec and the implementation alike.

**The operationally important gap: a graceful exit is not failed over at all.** When the active
publisher shuts down cleanly rather than dying, the relay propagates completion instead of
reselecting, and the subscriber terminates; a shared `--origin` buys nothing on that path, because
the relay cannot distinguish "this source is done, and so is the content" from "this source is done,
but an interchangeable one exists". This reads as **intended semantics rather than a defect** — it is
covered by upstream's model tests, on the reading that a source which finishes has declared its
content over. The consequence for broadcast is awkward all the same, because failover covers the
*harder* failure mode (host loss) and not the easier, far more common one: a SIGTERM to an encoder, a
container rescheduled, a rolling restart. The remedy is semantic — the bit that separates "this source
finished" from "this content is over" — and is specified in
[#2610](https://github.com/moq-dev/moq/issues/2610) as a publisher-minted epoch plus an explicit
`Ended` flag. Specified, not shipped ([lab: T6](../lab/test-6-relay-resilience.md);
[relay](relay.md) §5.1).

**So the load-bearing redundancy belongs at the receiver, and it is hitless — measured end to end.**
Two concurrently live delivery legs carrying one programme, terminated by a reference ST 2022-7
receiver, lose **zero** TS packets across a total blackout of one leg, 1 % and 3 % path loss, and
differential delay to 200 ms ([lab: T12](../lab/test-12-dual-path-handoff.md)). The graceful-exit gap
disappears entirely: a `SIGTERM` to publisher A, which terminates a single-leg subscriber outright, is
invisible at a merged output. Measured skew tracks injected delay to within 60 µs, so the merge buffer
a pair demands is simply its path delta. Upstream reached the same conclusion independently — *"if you
really want redundancy, you would do active-active … always pull both broadcasts and splice them"* —
so dual-subscribe-and-splice is the intended posture rather than a workaround for a missing relay
feature. The broadcast-grade chain is therefore fully doubled (dual publishers → dual relays → dual
subscribers → receiver-side selection), with relay reselect a bounded complement that keeps both flows
reachable. (Supports [transport](transport.md) §8, [relay](relay.md) §5.1,
[architecture](architecture.md) §14.)

**How the egress is produced decides whether the pair merges, and only one topology gives both
identity and whole-chain protection.** The two legs must be packet-identical with aligned RTP
sequence numbers:

| Egress topology | Mergeable? | IRD-presentable? | Protects |
|---|---|---|---|
| Ungroomed, RTP framing pinned on both legs | **yes** — 100 % alignment in 12/12 cells | **no** — 1 523 of 1 524 PCRs outside ±500 ns; not a constant-rate transport | the whole chain |
| One *arrival-clocked* groomer per leg | **no** — 30–53 % alignment, never merges | yes | nothing mergeable; input-select still works on it |
| One groomer, datagrams duplicated to both paths | **yes** — 100 %, hitless under every path injection | yes — CBR, every PCR within ±500 ns | **the last hop only** |
| One *stream-clocked* groomer per leg | **yes** — byte-identical on every datagram, on a co-started single-track feed | yes — CBR | **the whole chain**, including publisher, relay and exporter death |

The middle row fails **structurally, not through re-stamped PCR**: of the conflicting datagrams
sampled, none differs only in the PCR field, 39.5 % disagree on PID order and 28.2 % carry a different
number of null packets. Each groomer strips the arriving nulls and chooses its own content/stuffing
interleave against its own emit clock, so the two produce different transports rather than the same
transport differently stamped, and no receiver can patch that.

The last row is the fix. Placing every packet on the absolute output slot its source PCR implies at
the locked mux rate — and deriving the emitted PCR, RTP sequence number and RTP timestamp from that
slot — makes what a leg sends a function of the stream rather than of when its process started or when
the OS ran its timer. Two such groomers sharing no process, clock or messages emit identical bytes
under identical numbers, and the pair stays hitless through a publisher `SIGKILL` or `SIGTERM`, a relay
kill and an exporter kill — none of which the groom-once topology survives, having one of each.

**A groomer must stop when its content stops, and only the groomer can.** Asked only to hold a rate, a
groomer holds it against a dead source: when a groomed leg's publisher is killed the leg keeps emitting
a byte-perfect CBR carrier — full rate, valid TS, PCRs present and accurate — containing **no programme
packets at all**. Every failure signal a 1+1 receiver keys on is then absent, and an input-select policy
performs **zero** switches at every threshold from 50 to 500 ms while a sequence merge prefers the dead
leg over its live partner. The information the receiver needs was destroyed upstream of it. The groomer
therefore has to detect the silence and mute: treating content silence past a grace period as absence
rather than jitter, holding the output byte clock but stopping the PCR that made the dead carrier look
conformant. With that in place, publisher `SIGKILL`, publisher `SIGTERM`, relay kill and egress kill each
stop the leg with its content and produce exactly **one** switch at every threshold, costing 1–3
continuity errors. This does not arise on an ungroomed leg, which stops when its content stops.
Monitoring must still test for programme content rather than packet arrival
([operations](operations.md) §3), because muting is what a *correctly configured* groomer does and any
other groomed leg will hold the same dead carrier.

**A leg can rejoin in phase but not byte-identically, and what is missing comes from the exporter, not
the edge.** Stream clocking makes rejoining free: a leg returning from a 15 s blackout resumes with a
numbering deficit of **zero** and rejoins both the numbering and the schedule, where an arrival-clocked
leg comes back thousands of datagrams behind because RTP numbering counts datagrams *sent* rather than
position in the stream. Phase is not the obstacle either — a leg brought up 20 s late sends each shared
sequence number a median of 10 ms from its partner. What a pair does not reach is byte-identity, and the
residual divergence is three values `moq export ts` renders from **process state** rather than from the
broadcast. Grooming conceals none of them: it supplies the common slot grid that makes two legs
comparable, then carries every difference faithfully. Each leg stays internally continuity-clean, so the
divergence appears only when a receiver compares them
([#2779](https://github.com/moq-dev/moq/issues/2779)).

- **Continuity counters**, numbered from process state, leave exporters that did not start together
  permanently offset by a constant — the single field whose masking lifts agreement to ~98 %.
- **SI emission cadence**, anchored to process start, landed tables on slots where the partner carried
  video; [#2825](https://github.com/moq-dev/moq/pull/2825) fixes it and takes a single-track pair to
  **100 %**.
- **Audio/video interleave**: the exporter emits the earliest *available* frame rather than the earliest
  frame, so legs whose bytes arrive at different moments order the same media differently. Ordinary
  multi-track content therefore stops at **94–96 %** even when co-started — agreeing on every table
  while placing different numbers of audio and video packets
  ([#2829](https://github.com/moq-dev/moq/issues/2829)).

The counter is no longer a question of feasibility, only of adoption and cost. Restarting each PID's
counter at the video keyframe boundary and padding every span to a multiple of 16 packets takes the same
pair from 0.4 % to **99.9 %** identical on single-track content and from 24.6 % to **93.6 %** on
multi-track, its interleave ceiling, with both legs continuity-clean. The cost is small in aggregate and
regressive in detail: 1.5–1.7 % of packets, but **10–18 kb/s per PID almost regardless of what that PID
carries**, because a PID emitting one or two packets per group is nearly always 14 or 15 short of a
multiple of 16. A 10 Mb/s video PID pays 9.6 kb/s; a low-rate data PID pays several times its own
payload.

**One constraint on operating a pair.** Failure detection cannot be faster than a leg's own burstiness.
An ungroomed leg has inter-datagram gaps to 242 ms, so a silence threshold below ~250 ms mistakes normal
delivery for failure (413–446 spurious switches at 50 ms), while a groomed leg's gaps stay at 3.8–4.3 ms
clean and 8.3–8.4 ms under 3 % loss, making 50 ms safe. The pacer is therefore what makes prompt
failover detection possible, quite apart from its TR 101 290 role.

**Scope limits on this section.** The receiver is a reference implementation of the ST 2022-7 selection
rules, not a hardware IRD's merge engine, so these results can disprove mergeability but cannot
substitute for the Gate 2 conformance run. Both legs ran on one host over loopback, so skew was injected
rather than natural and path diversity is untested. And the byte-identity results are measured on a
**single-track** source, with the stream-clocked pair's differential delay taken to 50 ms where the
ungroomed and groom-once pairs were taken to 200 ms.

## 8. Relay compute is cheap and predictable; carriage costs less than SRT, not more

The operational envelope is measured on Linux with the current release, MPEG-TS at 2–27 Mbps and
fan-out to 85 concurrent subscribers ([lab: T9](../lab/test-9-performance.md)).

**Relay cost tracks session count, not bitrate.** A subscriber session costs ~0.34 % / 0.87 % / 1.18 %
of a core at 2 / 10 / 27 Mbps, so nearly fourteen times the bitrate costs about three and a half times
the CPU. Cost per Mbps therefore *falls* as bitrate rises, and one core carries roughly a gigabit — about
110–120 sessions at 10 Mbps, bounded in practice by the instance's sustained network baseline rather than
its cores. Fan-out is linear with no relay knee. Count sessions rather than gigabits, and note that
contribution-grade high-bitrate feeds are the *cheapest per Mbps* to relay: the expensive part of an
always-on high-bitrate service is egress, not compute. **Host configuration outweighs anything else
measured** — the same relay version cost ~6x more CPU per Mbps on macOS loopback with UDP GSO disabled
than on Linux with it enabled, which makes host tuning a first-order deployment decision.

**Carriage on the media-aware lane costs 0.982x the source TS rate on the wire, against SRT's 1.037x for
the same clip over the same path — MoQ delivers the service in 5.3 % less bandwidth**, or 6.2 % with path
MTU discovery enabled, a flag that exists and is off by default. A 9.95 Mbps service therefore needs
~9.8 Mbps of IP capacity, not the ~11.2 Mbps a rig artefact once suggested
([lab: T9](../lab/test-9-performance.md) Corrections).

**MoQ wins because it declines to carry null stuffing, and that outweighs everything QUIC charges.** The
reference clip is 4.57 % nulls. SRT, a byte pipe, cannot refuse them; the media-aware lane strips them on
import and the downstream groomer regenerates them from stream position, which the architecture does
anyway for TR 101 290 reasons ([architecture](architecture.md) §7). Against the *delivered* payload MoQ's
overhead is +2.79 %, decomposing exactly into 2.54 points of IP and UDP headers and 0.25 for every QUIC,
moq-lite and hang header combined. Priced from the protocol, **the irreducible QUIC-versus-SRT penalty is
~1.2 points, almost all of it the 16-byte authentication tag QUIC mandates and SRT does not** — which null
stripping repays several times over. The saving scales with the stuffing ratio, so it is much larger where
carriers run loose: 1.9 Mbps of content in a 4 Mbps carrier would cost SRT 4.13 Mbps of IP against roughly
half that on the media-aware lane (derived, not measured). It is bankable on a 1+1 pair too, which it was
not while each groomer chose its own stuffing — §7 shows that stuffing derived from stream position keeps
two legs byte-identical while each regenerates its own nulls.

**The debits, so the advantage is not overstated.** MoQ's return path is eight times SRT's (1.16 % of the
forward rate against 0.13 %), which does not reverse the result: counting both directions MoQ is 4.3 %
cheaper. The measurement is one 9.95 Mbps clip on one clean path, and the advantage's size *is* that clip's
stuffing ratio, so a tightly packed carrier narrows it towards the 1.2-point floor. Under 1 % forward loss
both protocols rose by about the loss rate and the ranking held. All of it is the media-aware lane: **the
opaque lane's carriage cost is unmeasured**, and derivation puts it near SRT if it carries stuffing verbatim
and near the media-aware lane if it does not — which is also the choice between byte-verbatim carriage and
the saving. Bandwidth remains the line most likely to dominate a cost comparison
([economics](economics.md) §3.1); it is simply no longer the line on which MoQ loses.

**Publisher and subscriber roles are stable over a day and a half; the relay still fails its stability
criterion.** Across two 26.5-hour soaks the publisher and subscriber processes held memory flat (+0.03 and
+0.15 MB/hour, against run-to-run noise several times larger), with descriptors unchanged and no restarts.
The relay instead retains memory in proportion to content carried: ~27 MB/hour at 9.3 Mbps, identical
across two consecutive releases and not returned when the subscribers leave. The criterion agreed in
advance was a growth slope of zero, and the relay does not meet it.

**The cause is a QUIC library rather than MoQ, and it bounds the growth.** `quinn-proto` keeps a slot per
stream a peer may open and recycles a freed stream's reassembly buffer rather than releasing it; MoQ opens
a stream per group, so **every group the relay ingests permanently converts one empty slot into an occupied
one — about 9 KiB** ([moq-dev/moq#2745](https://github.com/moq-dev/moq/issues/2745)). Three measured
properties follow from that and from nothing about MoQ. Growth is **flat in subscriber count** (28.7, 27.9,
28.0, 28.1 MB/hour from one to eight subscribers), because only streams the *peer* opens take slots — so
fan-out is free and it is hours of programming carried, not audience, that drives the cost. Growth is
**proportional to group rate**, confirmed by prediction: doubling the group rate at identical bitrate
doubled it to within 0.3 %, which means the rate scales with how aggressively a deployment is tuned for
low latency, roughly 18 MB/hour at a two-second group against 62 MB/hour at a half-second one. And **no
cache setting binds it**: capping the group cache at 32 MiB left the relay running to more than twice that
cap above baseline at an unchanged slope, and an age ceiling did the same, because the memory is not the
relay's to evict.

**It plateaus, and the ceiling is the number to budget.** Growth stops once every slot is occupied, which
at `moq-relay`'s 10,000 streams per connection is **~100 MB above baseline per publisher connection**,
reached after ~10,000 groups — around three hours at the rate tested. Any run shorter than that reads as
unbounded growth, which is why an hourly slope extrapolated to a daily figure overstates the cost. A
dedicated run confirmed the knee on our own rig within 11 % of the predicted ceiling and independently
bracketed the per-slot cost at 9.1–10.5 KiB against the 9.9 KiB upstream derived by instrumenting the
library. So a relay is **sizeable rather than fragile**: budget the ceiling per publisher connection and
treat scheduled restarts as prudence rather than necessity. A separate and far more severe defect is
genuinely gone — an older release grew ~21 MB/hour *with no subscribers at all* to an out-of-memory kill
after six days, and no current build reproduces that.

Two qualifications, both operational. The plateau is **soft**, still creeping at ~8 MB/hour past the knee,
so alarm thresholds belong above the ceiling rather than at it. And the one lever that works,
`--server-quic-max-streams`, is **sub-proportional**: cutting slots by 9.8× reduced retained memory by only
3.3×, because 20–30 MB of the ceiling is slot-independent. It is a real mitigation on a memory-constrained
host, at the cost of concurrent-stream headroom, but not a way to configure the overhead away, and no
released version of the QUIC library removes it. Bounding the cache is separately worth doing — measured
free, at identical CPU and within 1.5 MB of resident memory — because it caps the blast radius of any
future regression ([operations](operations.md) §3).

Two measurement caveats apply throughout. These are loopback rigs with subscribers co-resident with the
relay, so they price neither the NIC nor congestion control doing real work — and the Linux sweep showed why
that matters, since co-located subscribers cost 2.4x the relay and the observed fan-out knee was the *host*
saturating, not the relay. And `moq import` costs about three times more CPU on a trickle-fed live source
than on a file-paced one, independently of bitrate, which is the normal live contribution topology. Treat
the shapes as the result and the constants as indicative.

## 9. Relay neutrality holds within one implementation and fails across all others

Every result above was measured against `moq-dev` peers. That makes "a MoQ relay is a neutral transport
fabric" — load-bearing in [architecture](architecture.md), and the basis for treating relay capacity as a
substitutable commodity in [economics](economics.md) — and an assumption normally granted without test.
Testing it needs a media-level check rather than a handshake, so the fixture is a 20-second transport
stream and the oracle is its own continuity counters and PSI/SI: a TS validates itself, with no decoder,
player or frame capture ([lab: T11](../lab/test-11-interop.md); the client is public in
[`interop/`](../interop/README.md)).

**The lane passes against `moq-dev`'s relay locally and over the public internet, with byte-identical
egress in both cases, and returns no media whatsoever through all eight other registered public relays** —
Meta, Google, Cisco, Nokia, Meetecho, Cloudflare, OzU and openmoq.

Draft-version incompatibility, the expected culprit, is not the cause: negotiation succeeds widely,
reaching `moq-transport-19` against two relays. The blocking cause is a convention above the version.
**`moq-dev`'s publisher withholds its namespace announcement until a peer explicitly asks for it, and only
`moq-dev`'s own relay asks.** Every other relay expects a publisher to announce on connect, so the
publisher negotiates, reports no error, and then sends no control message at all. Both behaviours are
permitted by the draft — announcing unprompted is a MAY — so this is underspecification surfacing as an
interop hazard rather than a defect in anyone's code, and it is reported upstream on that basis
([moq-dev/moq#2730](https://github.com/moq-dev/moq/issues/2730)). Forcing the same media test over an IETF
draft against a local relay passes cleanly, which confirms the transport itself carries broadcast MPEG-TS
correctly.

The eight failures are at least four distinct causes, so fixing the announce convention alone would not
clear them. A second hazard of the same kind sits behind it: the subscriber opens discovery on an *empty*
namespace prefix, which one relay rejects outright and about which the draft is internally inconsistent.
Three further relays fail earlier still, at connection or SETUP, and are undiagnosed.

For this paper's thesis the finding cuts two ways. Nothing here indicts MoQ as an architecture — the
substrate works, and the blocking behaviour is a client-side default that is straightforward to change. But
**multi-vendor relay portability is currently absent in practice**, and that property is what makes an
Internet-native trunk route substitutable between providers, which is what the economic argument assumes.
Until a broadcast feed demonstrably traverses a relay someone else operates, relay neutrality is an
aspiration of the protocol rather than a property of the ecosystem, and any deployment design that assumes
portability between vendors is unsupported by evidence.

A secondary result matters for how such claims get tested at all. The community interop matrix is
control-plane only, so a `setup-only` check reports success against relays through which not one media byte
flows — an entire class of failure is invisible to the test the ecosystem reads. That is the argument for a
media-level interop profile ([interoperability](interoperability.md) §9.5), which this project has
contributed rather than merely proposed. One incidental finding from the same runs is a confound worth
naming: the client abandons QUIC for a WebSocket fallback on a fixed 200 ms timer, so any relay much
further away than that is silently carried over TCP, head-of-line blocking included.

---

## 10. The alternative data plane is easier to receive, harder to hand off cleanly, and ~7 % dearer on the wire

The comparison in [alternatives](alternatives.md) grades MoQ against **segmented HTTP carrying
MPEG-TS**. Most of its segmented-HTTP rows rest on specification text or a vendor datasheet; three rest
on measurement, taken on one route with both legs fed from the same source. The first two are
instrumented at the same point — the *ungroomed* egress, i.e. what the reassembly stage hands the groomer
— and the third at the HTTP layer ([lab: T14](../lab/test-14-data-plane-comparison.md)).

**The egress a groomer has to pace is two orders of magnitude coarser on segmented HTTP.** At 2 s
segments, from the same source through the same instrument:

| | MoQ | Segmented HTTP |
|---|---|---|
| Median burst | 12.4 kB | **2.95 MB** |
| Gaps above 1 s in 60 s | **none** | **24** |
| Largest gap | 149 ms | **4.01 s** |
| 10 ms peak/mean | 24× | **231×** |

The silences fall at exactly the segment duration, occasionally at two segment periods: the client fetches
a completed segment at line rate, then waits for the next to exist. **Burst size is segment size**, which
makes the grooming burden and the latency floor one knob rather than two — neither can be paid down
without partial segments, and while those can be *published* with MPEG-TS, no free client fetches them
(§10.1). A groomer for
this leg needs seconds of buffer where a MoQ groomer needs milliseconds, so the `--stall-ms` timeouts
documented for a MoQ egress are an order of magnitude too tight.

The consequence for the comparison is that "easier to receive" and "easier to hand off cleanly" are
different claims. Reassembly *is* off the shelf for segmented HTTP — TSDuck's `tsp -I hls` and ffmpeg both
read a playlist, against MoQ's single `moq export ts` — but grooming, the half that decides whether a
hardware IRD locks, is unsolved off the shelf on both and measurably harder on the alternative. Since a
distributor does not supply its clients' receivers, that obligation sits on the distributor's side of the
demarcation either way ([alternatives](alternatives.md) §4).

**Carriage fidelity for a single programme is a wash, against the expectation that MoQ leads on it.**
An MPEG-TS segment is byte-identical to its source but for **one byte in one packet type**: the continuity
counter on the PAT and PMT that the segmenter injects at each segment head. Media, audio, teletext, all
three SCTE-35 PIDs with correct typing, the null stuffing and the whole DVB service layer (NIT, SDT,
TDT/TOT) travel unchanged, with zero continuity errors across segment boundaries — not because the HLS
specification provides for them, which it does not, but because nothing in the path parses the payload.
Segmented HTTP is therefore as verbatim as the opaque MoQ lane here and better than the media-aware lane,
which regenerates continuity counters and drops stuffing. **MoQ's fidelity advantage narrows to the
multi-programme mux alone**, which HLS excludes normatively and which remains untested in practice.

**Wire cost follows from the same property, and it is the fidelity result priced.** Because segmented HTTP
carries the mux verbatim it carries this clip's 4.57 % null stuffing and every TS packet header, and the
media-aware MoQ lane carries neither:

| Data plane | Wire vs source TS |
|---|---:|
| MoQ, media-aware, 1200 B / 1452 B | **0.982× / 0.973×** measured on a real path (§8) |
| Segmented HTTP over HTTP/3, 1200 B / 1452 B | **1.056× / 1.046×** |
| Segmented HTTP over HTTP/2 on TCP+TLS, 1500 B | 1.029× |
| SRT, byte-verbatim, same real path | 1.037× |

**MoQ carries this service in ~7.0 % less bandwidth than segmented HTTP, and the figure does not depend on
the datagram size** — both ride QUIC and pay identical framing, so the saving is 7.0 % at 1200 B and 7.0 %
at 1452 B. Read the table down rather than across and the pattern is not MoQ-against-HTTP: **every verbatim
data plane sits between 1.03× and 1.06×, and the only thing that gets below 1.0× is declining to be
verbatim.** SRT is a cheaper verbatim carriage than segmented HTTP over HTTP/3; the two differ only in
framing. So the fidelity wash above and this 7 % are one finding read twice, and the 7 % is contingent on
the source — an unstuffed mux narrows it to roughly 2.5 points of TS packet headers and uncarried SI.

Two components resist estimation and had to be measured. **HTTP's own overhead is negligible**: response
headers and playlist re-fetching total 0.06 % of payload at 2.4 s segments and 0.09 % at 1.26 s, with the
request bytes back a further 0.01 %, all scaling as 1/segment-duration and playlist re-fetching the larger
forward term throughout. Extrapolated to the 200–330 ms parts low-latency HLS needs, that is ~0.4–0.6 % —
so **the chattiness of
LL-HLS is not a bandwidth argument against it**, which is often assumed. And **HTTP/3 is the more expensive
substrate by ~2.6 points**, since QUIC's minimum 1200 B datagram charges 5.5 % framing against a 1500 B TCP
path's 2.7 %: moving segmented HTTP to HTTP/3 buys loss resilience at a real cost, a point of which is
recoverable at 1452 B.

The measured input is the HTTP layer at **1.0006× source TS bytes**, which is a byte-to-byte ratio and so
path-independent; per-packet framing is added from §8's real-path measurement rather than measured here,
because loopback's 16384 B MTU makes packet counts meaningless. This vindicates the *number* in
[economics](economics.md) §4.7's ~1.05× estimate while falsifying its *mechanism*: the estimate assumed the
packager strips stuffing, and it does not.

### 10.1 Low-latency HLS with MPEG-TS is free to publish and impossible to receive

The HLS specification permits partial segments in MPEG-TS, and the low-latency ecosystem standardised on
CMAF/fMP4 regardless. Measured rather than read off documentation, the resulting gap turns out to sit
entirely on one side of the pipeline.

**Publishing works, free, first time.** Apple's `mediastreamsegmenter --format=transport
--part-target-duration-ms=300` emits a conformant playlist with `EXT-X-PART` entries pointing at MPEG-TS
parts of 0.28–0.30 s and 240–430 kB, `INDEPENDENT=YES` where a part carries an IDR, and a preload hint for
the part still being written. The tools are closed-source and macOS-only, but they are free and they took
one command.

**Nothing free receives it.** Both freely available clients that can turn HLS back into a transport stream
fetched **zero** parts from an origin advertising them, and fell back to whole segments. Repeated against
two origins — a static one, and Apple's own `ll-hls-origin-example.go` advertising
`CAN-BLOCK-RELOAD=YES` and `PART-HOLD-BACK=0.900` and validating with zero MUST-fix issues — with the same
outcome, and **zero blocking playlist reloads** from either client, so neither even attempted the
low-latency handshake:

| 45 s window, 300 ms parts, 2 s segments | MoQ | Classic HLS | LL-HLS + `tsp -I hls` | LL-HLS + FFmpeg |
|---|---|---|---|---|
| Partial segments fetched | — | — | **0** | **0** |
| Median burst | **12.4 kB** | 2.95 MB | **2.27 MB** | **2.34 MB** |
| Largest gap | **149 ms** | 4.01 s | 2.01 s | 2.09 s |
| 10 ms peak/mean | **24×** | 231× | 217× | **428×** |

**So low-latency HLS with MPEG-TS does not reduce the grooming burden in practice**: the ~20 % smaller
burst is explained by Apple's segmenter producing clean 2.00 s segments where TSDuck overshoots to 2.38 s,
not by parts. The control that makes this a statement about clients rather than about the rig is Apple's
own `mediastreamvalidator`, which over the same origins fetched 21 parts against 5 segments, and 17
against 7 using 12 blocking reloads — the parts are real, conformant and actively advertised. TSDuck's
limitation is proven outright: pointed at a live edge where the playlist legitimately holds only parts,
it exits with `empty HLS media playlist`. It cannot see parts at all.

**The practical envelope for TS-in-HLS therefore remains nearer 6 s than the 2–5 s the hold-back arithmetic
implies — and the reason is a market rather than an immaturity.** The missing stage is the receive stage,
which is exactly what Synamedia's MEG and Ateme's TITAN Edge sell as ABR-to-TS hardware. An operator
unwilling to buy a receiver gets classic HLS whatever the publisher emits.

This is worth holding beside §9. HLS has no normative reference implementation at all — it is an
Apple-authored informational document — and its authoritative implementation is closed-source, yet it
interoperates everywhere. MoQ is standards-track with open implementations and no cross-implementation
media interop. Open source and interoperability are not the same axis, and here they point in opposite
directions.

**Limits.** One route, one clip, one run per leg, single host, loopback, no packet loss; burst granularity
and fidelity at one segment duration, wire cost at three. Loopback inflates burst *rate*, so the peak-rate
figures are an upper bound — but burst *size* is set by segment size and the silences by the publish cadence,
so those are structural. Per-packet framing is derived, not measured, for the reason given above. Two cells
of the comparison remain unrun, both blocked on ABR-to-TS hardware or a CDN account
([lab](../lab/planned-experiments.md)).

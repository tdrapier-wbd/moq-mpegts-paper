# Evidence: What Has Been Built and Measured

Status: working draft.

The empirical basis for the claims in the [README](../README.md), [transport](transport.md)
and [architecture](architecture.md), for the one question this paper asks: *is MoQ a credible
transport for broadcast primary distribution?* The plan (objectives, gates, pass criteria) and the
executed procedures, commands and full result tables are in the laboratory notebook
([`lab/`](../lab/README.md)). Everything below is measured at **P1 (file/analyser)**; nothing here
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
is CBR/PCR-conformant at P1. Tightening the check to the TR 101 290 PCR_accuracy limit of ±500 ns
does not change the verdict on a groomed output — 0 of 2 598 PCRs outside it, against 1 523 of 1 524
for the same feed delivered ungroomed, which is the sharpest statement yet of what the pacer is for
([lab: T12](../lab/test-12-dual-path-handoff.md)). Two qualifications keep this honest. The 0 %
interval result is measured at a carrier rate matched to the content; running a 4 Mbps carrier for a
1.9 Mbps feed leaves 1.4 % of intervals above 40 ms even with a clean source, and whether that is
inherent to heavy stuffing or a groomer defect is unresolved. And all of it is *necessary but not
sufficient*: file analysis confirms the re-stamp arithmetic, not software-pacer jitter at the
physical output. **The hardware pass remains the open, load-bearing test.** (Supports
[architecture](architecture.md) §7.2.)

**The grooming stage does not depend on that one implementation, but no off-the-shelf tool does the
whole job.** Graded against the same oracle, TSDuck's `regulate` changes nothing about conformance
(1 527 of the 1 567 checked PCRs still outside ±500 ns) because it paces without grooming, and
TSDuck cannot restore stuffing at all: `tsp` overwrites existing null packets rather than inflating a
stream, so `mux` fed a null file inserts **zero** packets into a MoQ egress. `pcradjust` at the
stream's own content rate does pass the ±500 ns gate with the mux preserved byte-for-byte and
duration fidelity exact, but leaves 299 PCR intervals above 40 ms and rewrites PTS/DTS, and it can
only run at the content rate rather than a nominal service rate. The two regenerating muxers fix
rate, repetition and accuracy — FFmpeg's `-muxrate` to 8.8 µs, GStreamer's `mpegtsmux bitrate=` to
25 µs — at the cost of rebuilding the mux, and they lose different things: FFmpeg keeps every PID but
retypes SCTE-35, while GStreamer keeps SCTE-35 correctly typed on one PID and discards the rest of
the signalling, including all PSI beyond PAT and PMT. Neither is a paced wire. Measured live, FFmpeg
delivered 46.3 Mb/s in its first second and then oscillated 8–13 Mb/s per second with 1.3 Gb/s peaks
inside 10 ms windows; GStreamer's clock-synchronised sink holds the nominal rate but bursts, falling
silent for up to 284 ms, 376 times in 25 s; against 9.70–9.73 Mb/s and no gap beyond 15 ms for a
paced chain ([lab: T13](../lab/test-13-downstream-grooming.md)). So the requirement is documentable
with standard tools for feeds whose signalling is not contractual and whose receiver tolerates a
bursty wire; a mux carrying full signalling to a hardware receiver still needs a purpose-built stage.

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

**A second real-feed defect, of a more serious kind, closed the same way.** Until recently a single
damaged byte in an MP2, AC-3 or E-AC-3 frame header terminated the publisher outright and took every
other track — video, teletext, all three SCTE-35 PIDs — with it, while the video path resynchronised
through the identical corruption. That is the wrong way round for a contribution feed, where a
momentary bit error should cost a few milliseconds of audio rather than a session teardown and a
reconnect. It surfaced here as a looping test source accumulating 216 publisher restarts, one per wrap;
a one-byte reproducer then showed no discontinuity was needed at all. Reported and fixed within two
days ([#2729](https://github.com/moq-dev/moq/issues/2729),
[#2751](https://github.com/moq-dev/moq/pull/2751)), and verified here against both builds: the same
damaged capture that killed the previous release now costs **exactly one 24 ms audio frame**, with
every other track intact and nothing spurious emitted. The fix also reached a defect we had not found —
AAC frames split across a PES boundary were never reassembled at all, so a legal mux could kill a
broadcast with no corruption involved.

One residual, which is a gap rather than a fault: **a recovered stream is signalled nowhere**. There is
no continuity error, no discontinuity indicator, no log line and no counter — the audio timeline simply
steps over the hole. A feed quietly losing frames is therefore indistinguishable from a healthy one,
which is a real loss of diagnostic signal in exchange for the robustness
([lab: T9](../lab/test-9-performance.md)).

**A bit error and a splice are not the same defect, and closing the first left the second open.** Where
the damage is a corrupt byte the parser rejects the frame and drops it. Where it is a *splice* — a feed
restarting, a dropped PES, a looping file wrapping mid-frame — the header at that point is intact and
only the bytes after it are foreign, so the frame is published: not a frame lost but a frame
**substituted**, carrying audio from both sides of the discontinuity. That is the harder case to detect
downstream, because a substituted frame of the right length in the right place leaves the timeline intact
— no continuity error, no discontinuity flag, evenly spaced timestamps — whereas a dropped frame at least
shows up in a frame count. Measured on a looped broadcast feed it happened once per wrap on both MP2 and
AC-3, and the first upstream fix for it did not reach that content at all: it guarded a frame split
across a PES boundary, whereas a real wrap splices *inside* one. The mechanism that does catch it was
already in the stream and already implemented next door — the transport continuity counter, which the
same demuxer checked for private sections but not for elementary streams. Upstream adopted exactly that,
generalising the section-level continuity rules and applying them to PES PIDs
([#2823](https://github.com/moq-dev/moq/pull/2823)), and the substituted frame is now gone from the same
capture. The residual is that the guard trusts one signal: where a wrap happens to leave the counter
*contiguous* — about one cut point in sixteen, which a constructed clip demonstrates — the splice is
invisible again and the mixed frame returns. Codec CRC would close that (AC-3 mandates one per frame and
it rejects every mixed frame measured) but cannot be the general answer, because MP2 carries no CRC at
all in this feed. For an architecture that treats the ingest edge as the place where a contribution
feed's defects are absorbed, the absorbing needs to be observable — and a resync is still signalled
nowhere ([lab: T9](../lab/test-9-performance.md)).

The same pattern holds beyond the TS mapping: the congestion-control selector (#2432), exporter
survival across session loss (#2469) and standby-route propagation (#2473) are upstream changes
rather than local workarounds (§6, §7). Media-aware is the right default partly for this
reason — its known gaps close in core, on the reference implementation, rather than downstream
of it, and the two-day turnaround on the audio abort is the strongest evidence yet for that claim.

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
control under a shaped bottleneck is characterised only in the under-provisioned failure case,
[lab: T8b](../lab/test-8b-congestion-control.md)). BBR generation is backend-specific — quinn-BBRv1 and
noq-BBRv3 strongest, quiche-BBRv2 weakest, with v1 fairness and a very-high-loss cliff
uncharacterised — so quinn-BBRv1 is the pragmatic default today. That recommendation is scoped to
non-congestive impairment: under a shaped bottleneck quinn-BBRv1 shows intermittent bloat, which would
matter for a *permanent fixed-rate* trunk, but the provisioned-path conditions that would settle it
are unrun.

## 7. Transport resilience holds; source failover is bounded, and the receiver-side 1+1 splice now has numbers

MoQ's redundancy model is sound: thin, auto-reconnecting endpoints, redundancy in the relay mesh,
and hitless selection left to the receiver. Drills on the media-aware lane
([lab: T6](../lab/test-6-relay-resilience.md)) establish what it delivers today.

**What works.** Two independent `moq export ts` subscribers produce byte-identical, continuous
captures of the same broadcast, so fan-out to N subscribers → N pacers → N IRDs needs no extra
machinery. The importer redials its relay with jittered backoff and re-announces on every session,
and two-relay clustering carries the feed while tolerating a duplicate publisher. The exporter
survives a relay kill and restart ([#2469](https://github.com/moq-dev/moq/pull/2469)): both
exporters stay alive, skip the evicted group, and resume byte-identical output automatically. The
gap is a clean object-boundary skip that downstream ST 2022-7 / IRD selection absorbs.
[#2647](https://github.com/moq-dev/moq/pull/2647) tightened the reconnect further, so the exporter
re-attaches within a few seconds of the relay returning, and a genuinely *dead* relay now surfaces
an error in tens of seconds instead of retrying silently. That second axis is the one that matters
for a supervisor deciding to re-home a subscriber ([transport](transport.md) §8.4).

One operational caveat surfaced along the way: a takeover **livelock**, fixed in
[#2701](https://github.com/moq-dev/moq/pull/2701), could spin every relay worker and leave the
process alive but serving nothing. It changes none of the measurements here, but it is why relay
monitoring has to test liveness rather than process existence ([operations](operations.md) §3).

**Everything is bounded by detection, not by recovery.** On a hard kill, nothing downstream learns
of the failure until the QUIC **idle timeout** expires (default 30 s, which must stay above the 5 s
keep-alive). Every recovery time below is therefore dominated by that wait, not by the ~1 s
reconnect. The reason is architectural rather than incidental: a relay has no model of a
broadcast's expected cadence, so it cannot treat silence as failure the way an application that
knows its own frame rate could. It has to wait for the transport to declare the peer gone. Upstream
is open to a lower default (~10 s) as a separate change.

**Active/active source failover is a bounded route reselect, not a seamless merge.**
[#2473](https://github.com/moq-dev/moq/pull/2473) made a 1+1 pair usable at all: a relay now
advertises, per peer, the best route whose hop chain *excludes* the requester, and a `moq --origin
<id>` flag lets the two publishers **declare their feeds interchangeable**. That promise has to be
explicit because the relay never infers it: the relay is content-agnostic, and it will not rewrite
timestamps to bridge two broadcasts. Before #2473 the pair coexisted with no failover at all: the
relay serving the active source never reselected onto the standby, graded well past the detection
window.

The two-relay drill now passes end to end ([lab: T6](../lab/test-6-relay-resilience.md)). The
standby is advertised the instant its publisher joins, and when the active publisher is killed the
relay splices onto it, with the subscriber resuming **one idle timeout later** (~30–33 s at the
default, ~11 s with the timeout at 10 s). The reselect itself is essentially free; detection is the
whole cost.

**The requirement is a common source, not byte-identical segmentation.** MoQ numbers groups with a
per-publisher counter that resets at the first keyframe, while track names and timestamps come from
the source bytes. Two publishers are therefore interchangeable when they are two views of *one*
feed. Fed a single source, two co-started publishers produce equivalent subscriber output up to the
kill, and failover is clean. Crucially for broadcast, where a publisher always joins an
already-running feed, a standby that joins **mid-stream** (so its group numbering is *offset* from
the active's) **still fails over cleanly**: the subscriber subscribes once, never reinitialises its
catalog, and skips to the standby's live edge. Identical numbering is sufficient but not necessary.
What a shared source rules out is a divergent track layout or codec across the pair, which is what
would genuinely make failover impossible.

**Continuity-clean, but not hitless.** The resumed capture carries **0 TS continuity-counter
errors**, because the subscriber's single output mux never resets, so the file is structurally
valid. The outage appears instead as a **PCR/PTS discontinuity**: a content hole that the media
clock jumps across, i.e. break-before-make. The window is the idle timeout and is tunable, though a
5 s setting proved too aggressive for the switch to complete. Sub-second switching is not a
relay-reselect property at all. It has to live at the receiver (ST 2022-7 dual-subscribe over the
common source), and the common-source result is exactly what makes that feasible.

**This is an implementation choice, not MoQ's ceiling.** The IETF draft does envisage relays
de-duplicating *objects* from redundant sources, so hitless active/active is the standard's model;
`moq-dev` implements the permitted alternative, content-agnostic route selection. Two things keep
that from changing the recommendation. First, the draft hedges dedup as a SHOULD and keys it on
identical object *identifiers*, not identical media bytes. Two independent publishers do not
naturally share those identifiers, so conformant dedup would demand determinism down to object
segmentation and numbering: the object-layer analogue of ST 2022-7's aligned RTP sequence numbers,
and a stricter bar than "bit-for-bit identical". Second, bridging two genuinely *different*
broadcasts is out of scope in the spec and the implementation alike. Receiver-side selection over a
common source therefore remains the robust, buildable-today path
([lab: T6](../lab/test-6-relay-resilience.md) holds the clause-level spec cross-check).

**The operationally important gap: a graceful exit is not failed over at all.** When the active
publisher shuts down cleanly rather than dying, the relay propagates completion instead of
reselecting onto the standby, and the subscriber terminates. The relay cannot distinguish "this
source is done, and so is the content" from "this source is done, but an interchangeable one
exists", so a shared `--origin` buys nothing here. This is **intended semantics rather than a
defect**: upstream's model tests assert it directly, on the reading that a source which finishes has
declared its content over. The consequence for broadcast is awkward all the same, because the
failover path covers the *harder* failure mode (host loss) and not the easier, far more common one:
a SIGTERM to an encoder, a container rescheduled, a rolling restart. The remedy is semantic, giving
a consumer the bit that separates "this source finished" from "this content is over", and it is
specified in [#2610](https://github.com/moq-dev/moq/issues/2610) as a publisher-minted epoch plus an
explicit `Ended` flag. Specified, not shipped, and the upstream thread worth tracking.

**Posture buildable now.** With the exporter crash fixed, no external subscriber supervisor is
needed for relay maintenance or transient loss. Service redundancy still comes from a fully doubled
chain (dual publishers → dual relays → dual subscribers → downstream ST 2022-7 / IRD failover),
letting the *receiver* make the hitless decision — with the caveat measured below, that the
*grooming* stage of that chain cannot simply be doubled. Relay-mesh source failover does not
change that recommendation: at one idle timeout it is **bounded, not hitless**, and on the
graceful-exit path it does not protect at all. A gap-free switch would need either wall-clock-aligned
encoders (Elemental's approach) or a receiver that reinitialises across the switch. That makes relay
reselect a **bounded nice-to-have**, complementary to the real mechanism rather than a substitute
for it: the mesh keeps both flows healthy and reachable, and the receiver does the switching.
Upstream reached the same conclusion independently and said so plainly when closing our drill: *"if
you really want redundancy, you would do active-active. Don't wait for the QUIC idle timeout; always
pull both broadcasts and splice them"*
([#2545](https://github.com/moq-dev/moq/pull/2545)). Dual-subscribe-and-splice at the
receiver is therefore the intended posture, not a workaround for a missing relay feature. (Supports
[transport](transport.md) §8, [relay](relay.md) §5.1, and [architecture](architecture.md) §14.)

**That posture works, and it is hitless — measured end to end at the receiver.** Two concurrently
live delivery legs carrying one programme, terminated by a reference ST 2022-7 receiver, lose
**zero** TS packets across a total blackout of one leg, 1 % and 3 % path loss, and differential delay
to 200 ms ([lab: T12](../lab/test-12-dual-path-handoff.md)). The graceful-exit gap above disappears
entirely: a `SIGTERM` to publisher A, which terminates a single-leg subscriber outright, is invisible
at a merged output — the surviving leg covers 5 339 datagrams and continuity is unbroken. Measured
skew tracks injected delay to within 60 µs, so the merge buffer a pair demands is simply its path
delta. This is the first redundancy result in the campaign denominated in lost packets rather than
seconds to recovery.

**How the egress is produced decides whether the pair merges, and only one topology gives both
identity and full-chain protection.** The two legs must be packet-identical with aligned RTP
sequence numbers:

| Egress topology | Mergeable? | IRD-presentable? | Protects |
|---|---|---|---|
| Ungroomed, RTP framing pinned on both legs | **yes** — 100 % alignment in 12/12 cells | **no** — 1 523 of 1 524 PCRs outside ±500 ns; not a constant-rate transport | the whole chain |
| One *arrival-clocked* groomer per leg | **no** — 30–53 % alignment, never merges | yes | nothing mergeable; input-select still works on it |
| One groomer, datagrams duplicated to both paths | **yes** — 100 %, hitless under every path injection | yes — CBR, every PCR within ±500 ns | **the last hop only** |
| One *stream-clocked* groomer per leg | **yes** — 100 %, byte-identical on every datagram, on a single-track feed with both legs co-started; see the exporter's three per-process values below for what a second track or a late join costs | yes — CBR | **the whole chain**, including publisher, relay and exporter death |

The middle row fails **structurally, not through re-stamped PCR**: across 400 sampled conflicting
datagrams, none differs only in the PCR field, 39.5 % do not agree on PID order and 28.2 % carry a
different number of null packets. Each groomer strips the arriving nulls and chooses its own
content/stuffing interleave against its own emit clock, so two groomers produce different transports
rather than the same transport differently stamped, and no receiver can patch that.

The last row is the fix, and it is now built and measured. Placing every packet on the absolute
output slot its source PCR implies at the locked mux rate — and deriving the emitted PCR, the RTP
sequence number and the RTP timestamp from that slot — makes what a leg sends a function of the
stream rather than of when its process started or when the OS ran its timer. Two such groomers,
sharing no process, no clock and no messages, emit identical bytes under identical numbers, and the
pair stays hitless through a publisher `SIGKILL` or `SIGTERM`, a relay kill and an exporter kill —
none of which the groom-once topology can survive, because it has only one of each.

**A groomer must stop when its content stops, and only the groomer can.** Asked only to hold a rate,
a groomer holds it against a dead source: when a groomed leg's publisher is killed the leg keeps
emitting a byte-perfect constant-bitrate carrier — full rate, valid TS, PCRs present and accurate —
containing **no programme packets at all**, for as long as it is left running. Every failure signal a
1+1 receiver keys on is then absent: no loss, no continuity errors, no silence, and an input-select
policy performs **zero** switches at every threshold from 50 to 500 ms, while a sequence merge
prefers the dead leg over its live partner. The information the receiver needs has been destroyed
upstream of it, so no receiver-side policy recovers it.

The groomer therefore has to detect the silence itself and mute: `mpegts-pacer` treats content
silence past a grace period (1 s here) as absence rather than jitter, stops emitting while holding
its output byte clock, and stops minting the PCR that made the dead carrier look conformant. With
that in place the same four upstream failures — publisher `SIGKILL`, publisher `SIGTERM`, relay kill
and egress kill — each produce a leg that stops with its content (zero carrier after the last
programme packet) and exactly **one** input-select switch at every threshold, costing 1–3 continuity
errors. This does not arise on the ungroomed leg, which stops when its content stops.

Monitoring must still test for programme content rather than packet arrival
([operations](operations.md) §3): muting is what a *correctly configured* groomer does, and a leg
groomed by anything else — or with the grace period disabled — carries the same dead carrier.

**Stopping is not the same as coming back, and what a returning leg still lacks is one byte.**
An arrival-clocked leg whose delivery is interrupted and restored resumes at the next RTP sequence
number it would have sent, while its partner has advanced by the whole outage: 8 756 datagrams
behind after a 23 s interruption, because RTP numbering counts datagrams *sent* rather than position
in the stream. A stream-clocked leg returns from the same injection with a numbering deficit of
**zero** and 5 526 of its next 5 658 datagrams carrying programme — it rejoins both the numbering and
the schedule.

What it does not do is become byte-identical again, and the reason is upstream of the groomer.
Masking one field lifts the recovered leg from 68.6 % to **98.2 %** agreement, and a leg that joined
20 s late from 0.09 % to **97.1 %**: that field is the continuity counter, which `moq export ts`
numbers from its own process state, leaving two exporters that did not start together permanently
offset by a constant (+2 on the video PID, +8 on PSI, unchanging over a 60 s run). Each leg is
internally continuous — 0 continuity errors on either — so the divergence appears only when a
receiver compares them.

The counter is one of three values the exporter renders from its own process state rather than from
the broadcast, and grooming conceals none of them — it supplies the common slot grid that makes two
legs comparable at all, and then carries every difference faithfully. The 2.9 % the mask leaves is
the second: the emission cadence for SI tables was anchored to process start, and in that capture
**31 of 31** SDT emissions land on a slot where the other leg carries video, displacing every packet
after them. [#2825](https://github.com/moq-dev/moq/pull/2825), now merged, fixes it and takes a
single-track pair from 96.4 % to **100.0 %**. The third is the audio/video interleave: the exporter
emits the earliest *available* frame rather than the earliest frame, so two legs whose bytes arrive
at different moments order the same media differently, and on ordinary multi-track content the pair
stops at **94–96 %** ([#2829](https://github.com/moq-dev/moq/issues/2829)). That ceiling is not about
restarting — two legs started at the same instant sit in the same band, agreeing on every table while
placing different numbers of audio and video packets. **A byte-identical pair therefore waits on the
exporter, not on the edge** ([#2779](https://github.com/moq-dev/moq/issues/2779), #2825, #2829).

The counter itself is no longer an open question of feasibility, only of adoption. Restarting each
PID's counter at the video keyframe boundary and padding every span to a multiple of 16 packets —
prototyped as a filter below the exporter, so it can be measured before it is built — takes the same
pair from 0.4 % to **99.9 %** identical on single-track content and from 24.6 % to **93.6 %** on
multi-track, which is its interleave ceiling. Both groomed legs stay continuity-clean, so the
constant-bitrate stage below absorbs the filler. The cost is small in aggregate and regressive in
detail: 1.5–1.7 % of packets, but **10–18 kb/s per PID almost regardless of what that PID carries**,
because a PID emitting one or two packets per group is nearly always 14 or 15 short of a multiple of
16. A 10 Mb/s video PID pays 9.6 kb/s; a low-rate data PID pays several times its own payload.

**One further constraint on operating a pair.** Failure detection cannot be faster than the leg's
own burstiness: an ungroomed leg has inter-datagram gaps to 242 ms, so a silence threshold below
~250 ms mistakes normal delivery for failure (413–446 spurious switches at 50 ms), while a groomed
leg's gaps stay at 3.8–4.3 ms clean and 8.3–8.4 ms under 3 % loss, so a 50 ms threshold is safe — the
pacer is what makes prompt failover detection possible, quite apart from its TR 101 290 role. And a
leg that joins late joins *in phase*: a stream-clocked leg brought up 20 s after its partner sends
each shared sequence number a median of **10 ms** from it, and varying the groomer's release latency
between 500 ms and 2 s moves that by tens of milliseconds, not seconds. Phase is therefore not the
obstacle to independent restart; the exporter's per-process rendering above is the whole of it.

Two scope limits. The receiver is a reference implementation of the selection rules, not a hardware
IRD's merge engine, so this can disprove mergeability but cannot substitute for the Gate 2
conformance run; and both legs ran on one host over loopback, so skew was injected rather than
natural and path diversity is untested.

## 8. Relay compute is cheap and predictable; carriage costs less than SRT, not more

The operational envelope is now measured rather than assumed
([lab: T9](../lab/test-9-performance.md)), on Linux with the current release, MPEG-TS at 2-27 Mbps
and fan-out to 85 concurrent subscribers.

**Relay cost tracks session count, not bitrate.** A subscriber session costs ~0.34 % / 0.85 % /
1.18 % of a core at 2 / 10 / 27 Mbps, so nearly fourteen times the bitrate costs about three and a
half times the CPU. Cost per Mbps therefore *falls* as bitrate rises, and one core carries roughly a
gigabit — about 110-120 sessions at 10 Mbps. Fan-out is linear with no relay knee, and memory scales
sublinearly (tens of MB fixed plus ~2 MB per session), so memory is not a sizing constraint. For
capacity planning, count sessions rather than gigabits, and note that contribution-grade high-bitrate
feeds are the *cheapest per Mbps* to relay — the expensive part of an always-on high-bitrate service
is egress, not compute.

**Host configuration outweighs anything else measured.** The same relay version cost ~6x more CPU per
Mbps on macOS loopback with UDP GSO disabled than on Linux with it enabled. Relay compute is more
sensitive to kernel and offload configuration than to any plausible code change, which makes host
tuning a first-order deployment decision rather than an implementation detail.

**Carriage on the media-aware lane costs 0.982x the source TS rate on the wire, against SRT's 1.037x
for the same clip over the same path — MoQ delivers the service in 5.3 % less bandwidth.** Turning on
path MTU discovery, a flag that exists and is off by default, takes it to 0.973x and 6.2 %. A
9.95 Mbps service therefore needs ~9.8 Mbps of IP capacity rather than the ~11.2 Mbps previously
recorded here, and the earlier figure was a measurement artefact rather than a property of the protocol
([lab: T9](../lab/test-9-performance.md) Corrections).

**MoQ wins because it declines to carry null stuffing, and that is worth more than everything QUIC
charges.** The reference clip is 4.57 % nulls. SRT, a byte pipe, has no way to refuse them; the
media-aware lane strips them on import and the downstream groomer regenerates them from stream
position, which the architecture does anyway for TR 101 290 reasons
([architecture](architecture.md) §7). Against the *delivered* payload MoQ's overhead is +2.79 %, and it
decomposes exactly: 2.54 points are IP and UDP headers, and 0.25 is every QUIC, moq-lite and hang
header combined. Priced from the protocol, a QUIC packet spends ~64 bytes on IP, UDP, its own header,
the AEAD tag and stream framing — 5.5 % of a 1200-byte datagram against SRT's 3.3 % for seven TS
packets in 1360 bytes, so **the irreducible QUIC-versus-SRT penalty is ~1.2 points, almost all of it
the 16-byte authentication tag QUIC mandates and SRT does not.** Null stripping repays that several
times over.

**The saving scales with the stuffing ratio, so it is much larger where carriers run loose:** 1.9 Mbps
of content in a 4 Mbps carrier costs SRT 4.13 Mbps of IP against roughly half that on the media-aware
lane. It is bankable on a 1+1 pair as well, which it was not while each groomer chose its own stuffing:
§7 above shows that two groomers whose stuffing is a deterministic function of stream position produce
byte-identical legs while each regenerating its own nulls ([architecture](architecture.md) §14.1).
What stripping still costs is byte-verbatim carriage, which is a separate decision.

**The debits, so the advantage is not overstated.** MoQ's return path is eight times SRT's (1.16 % of
the forward rate against 0.13 %), which does not reverse the result — including both directions MoQ is
4.3 % cheaper. The measurement is one 9.95 Mbps clip on one clean path, and the advantage's size
depends on the source's stuffing ratio, so a tightly packed carrier would narrow it towards the
1.2-point AEAD floor. Under 1 % forward loss both protocols' overhead rose by about the loss rate and
the ranking held. Everything above is the media-aware lane; **the opaque lane's carriage cost is still
unmeasured**, and derivation puts it near SRT if it carries stuffing verbatim and near the media-aware
lane if it does not. Bandwidth remains the line most likely to dominate a cost comparison
([economics](economics.md) §3.1) — it is simply no longer the line on which MoQ loses.

**Publishers and subscribers are stable over a day and a half. The relay retains memory per unit of
content carried — bounded, but not by anything an operator can configure.** Two 26.5-hour soaks plus a
controlled build comparison were run. The publisher and subscriber processes held memory flat (+0.03
and +0.15 MB/hour, against run-to-run noise several times larger), with descriptors unchanged and no
restarts — those roles pass.

The relay grows. Holding the workload fixed — one publisher, four steady subscribers, a private relay
with no prior history — and varying only the binary, two consecutive releases both grew **at about
27 MB/hour, with no decay across two and a half hours**. Five successive half-hourly windows on the
older build read between +25 and +28 MB/hour. It is not a regression in the newer build: the two agree
to within 2 %. An earlier soak that appeared flat for 26 hours simply carried a lighter load. With no
subscriber attached the relay is flat, so what grows tracks *served load* rather than uptime, and it
is not returned when the subscribers leave.

Two things sharpen this into a practical concern rather than a curiosity, and both are now measured
rather than suspected. First, the growth is far too small to be cached media: the relay retains
roughly 0.6 % of the bytes it carries, where retained history would be three orders of magnitude
larger. Second, and decisively, **the relay's documented memory bound does not stop it.** Re-run with
the group cache capped at 32 MiB — a bound small enough that it must engage within the hour — the
relay ran to more than twice that cap above its baseline at the same ~27 MB/hour, with no change of
slope at the point where the cap should have taken hold. `--cache-capacity` can only evict memory the
cache pool accounts for, and whatever is growing here is not accounted there.

That moves this from a tuning question to a defect. Across two consecutive releases and three cache
settings the answer is the same ~27 MB/hour, and the one control an operator is told to reach for has
no effect on it.

**Where the cost actually falls is now measured, and it is not where fan-out lives.** Sweeping
subscriber count from one to eight leaves the growth rate untouched — 28.70, 27.86, 28.00 and
28.13 MB/hour — while the relay's own counters show it ingesting a constant 3,200 groups per hour and
serving exactly N times that. Dividing the two constants gives **about 9 KiB retained for every group
the relay ingests, regardless of how many subscribers consume it**. Eight times the audience costs
nothing extra in growth.

That matters commercially in both directions. Per-subscriber state is real but *bounded*: each session
adds a fixed 3.2 MB at join and then stops, so fan-out itself is well-behaved and the relay-density
economics in [economics](economics.md) §4 stand. The growth scales instead with *content ingested* —
with hours of programming carried, not with audience — so it is indifferent to how many viewers a relay
serves. For always-on primary distribution that would be the worse of the two shapes, since the load
driving it never stops; the ceiling established below is what saves it.

**This is causation, not correlation, and it was confirmed by prediction.** Two re-encodes of the same
content at an identical 9.3 Mbps, differing only in how often a key frame starts a new group, make
group rate the single variable. Doubling it was predicted to double the leak, and did: 31.22 against
62.30 MB/hour, a ratio of 1.995 where the group rate ratio is 2.000, with the retained-bytes-per-group
figure agreeing to three significant figures across the pair.

Group cadence is also the knob MoQ uses to trade latency, so the growth *rate* is proportional to how
aggressively a deployment is tuned for the property MoQ is chosen for: roughly 18 MB/hour at a
two-second group against 62 MB/hour at a half-second one. As the root cause below shows, this changes
how quickly the ceiling arrives rather than how high it is.

**Neither documented control stops it.** `--cache-capacity` bounds payload bytes and this is not
payload; `--cache-duration`, the age ceiling on retained history, was tested at five seconds and left
the rate unchanged at 27 MB/hour. There is no setting an operator can apply to the cache. It was filed
as [moq-dev/moq#2745](https://github.com/moq-dev/moq/issues/2745).

**The root cause is a QUIC library, not MoQ — and it bounds the growth.** The maintainer reproduced
and root-caused the report within a day, and the answer sits a layer below the protocol. `quinn-proto`
keeps a slot for every stream a peer may open, and when a received stream is freed it recycles the
stream's state *including its reassembly buffer*, cleared but not released. MoQ opens a QUIC stream
per group, so every group the relay ingests permanently converts one empty slot into an occupied one.
That explains every property measured above without any of them being about MoQ: only streams the peer
opens consume slots, so egress — which the relay opens itself — costs nothing and the growth is flat in
audience; and a cache control cannot evict memory held by the transport library beneath it.

It also supplies the ceiling. Growth stops once every slot is occupied, which for `moq-relay`'s limit
of 10,000 streams per connection is **about 99 MB above baseline per publisher connection**, reached
after roughly 10,000 groups — around three hours at the rate tested. **Every leg in this campaign was
shorter than that**, which is why the growth looked unbounded, and the earlier reading here of "650 MB
a day, indefinitely" was an extrapolation past the range the measurements covered. It was also the
wrong way round on latency: a shorter group reaches the same ceiling sooner rather than climbing
higher, because what is retained is set by frame size and slot count, not by group duration. Two
results previously recorded as anomalies now fit — a soak whose growth visibly decayed towards the end,
and a long-running relay that sat flat at 224 MB for hours, had both simply filled their slots.

This changes the operational conclusion materially. The severe historical defect is genuinely gone — an
older release grew ~21 MB/hour *with no subscribers at all* to an out-of-memory kill after six days,
and neither current build reproduces that. What replaces it is not an unbounded leak but a **bounded
per-connection overhead of order 100 MB, arriving over the first few hours of a connection's life**.
A relay is therefore sizeable rather than fragile: budget the ceiling per publisher connection, and
scheduled restarts are prudence, not a necessity. The one lever that does work is the stream limit
itself — `--server-quic-max-streams` caps the ceiling proportionally, at the cost of concurrent-stream
headroom on busy connections. There is no released version of the QUIC library that fixes this, so the
overhead should be planned for rather than waited out.

**The plateau then reproduced on our own rig, closely.** A four-hour leg on the default slot count held
~+60 MB/hour for three half-hourly windows and broke in exactly the window containing the predicted
knee — the point at which the ten-thousandth group is ingested — falling to 13 % of its pre-knee rate
and staying there. Memory at the knee was 108 MB above baseline against a predicted 97 MB, an 11 %
error on a prediction derived on different hardware under a different workload. A second leg capping
the limit at 1,024 streams was flatter still, level to measurement resolution for its final ninety
minutes and finishing at 91 MB where the uncapped leg reached 190 MB on identical media. Solving the
ceiling as a per-slot cost plus a constant, from the two legs independently at the knee and at their
ends, puts the per-slot figure at 9.1 and 10.5 KiB — bracketing the 9.9 KiB upstream derived from
instrumenting the library. The diagnosis is confirmed.

Two qualifications survive that confirmation, and both are operational rather than diagnostic. Growth
does not stop at the knee so much as slow sharply, continuing at ~8 MB/hour and adding a further 25 MB
over the following two and a half hours, so the ceiling is soft and a longer run is needed to see
whether it truly converges. And the ceiling does not fall in proportion to the slot count: cutting
slots by 9.8× reduced retained memory by only 3.3×, because 20–30 MB of it is independent of slots
altogether. Lowering the stream limit is a real mitigation, but a sub-proportional one with a floor
beneath it.

**Bounding the relay cache is free.** With `--cache-capacity` set, CPU was identical and RSS differed
by under 1.5 MB, because a healthy working set sits far below any sensible bound. The cache is
unbounded unless configured, so bound it anyway: it costs nothing and it caps the blast radius of any
future regression ([operations](operations.md) §3).

One measurement caveat applies throughout: these are loopback rigs with subscribers co-resident with
the relay, so they price neither the NIC nor congestion control doing real work — and the Linux sweep
showed why that matters, since co-located subscribers cost 2.4x the relay and the observed fan-out
knee was the *host* saturating, not the relay. Treat the shapes as the result and the constants as
indicative.

---

## 9. Relay neutrality holds within one implementation and fails across all others

Every result above was measured against `moq-dev` peers. That makes "a MoQ relay is a neutral
transport fabric" — load-bearing in [architecture](architecture.md), and the basis for treating relay
capacity as a substitutable commodity in [economics](economics.md) — an assumption this campaign had
never actually tested. Testing it required a media-level check rather than a handshake, so the
fixture is a 20-second transport stream and the oracle is its own continuity counters and PSI/SI:
a TS validates itself, with no decoder, player or frame capture ([lab: T11](../lab/test-11-interop.md);
the client is public in [`interop/`](../interop/README.md)).

**The lane passes against `moq-dev`'s relay locally and over the public internet, with byte-identical
egress in both cases, and returns no media whatsoever through all eight other registered public
relays** — Meta, Google, Cisco, Nokia, Meetecho, Cloudflare, OzU and openmoq.

Draft-version incompatibility, the expected culprit, is not the cause: negotiation succeeds widely,
reaching `moq-transport-19` against two relays. The blocking cause is a convention above the version.
**`moq-dev`'s publisher withholds its namespace announcement until a peer explicitly asks for it, and
only `moq-dev`'s own relay asks.** Every other relay expects a publisher to announce on connect, so
the publisher negotiates, reports no error, and then sends no control message at all. Both behaviours
are permitted by the draft — announcing unprompted is a MAY — so this is underspecification surfacing
as an interop hazard rather than a defect in anyone's code, and it is reported upstream on that basis
([moq-dev/moq#2730](https://github.com/moq-dev/moq/issues/2730)). Forcing the same media test over an
IETF draft against a local relay passes cleanly, which confirms the transport itself carries broadcast
MPEG-TS correctly; three further relays fail earlier, at connection or SETUP, and are undiagnosed.

For this paper's thesis the finding cuts two ways and both should be stated plainly. Nothing here
indicts MoQ as an architecture — the substrate works, and the blocking behaviour is a client-side
default that is straightforward to change. But **multi-vendor relay portability is currently absent in
practice**, and that property is precisely what makes an Internet-native trunk route substitutable
between providers, which is what the economic argument assumes. Until a broadcast feed demonstrably
traverses a relay someone else operates, relay neutrality should be treated as an aspiration of the
protocol rather than a property of the ecosystem, and any deployment design that assumes portability
between vendors is unsupported by evidence.

A secondary result matters for how such claims get tested at all. The community interop matrix is
control-plane only, so a `setup-only` check reports success against relays through which not one media
byte flows — an entire class of failure is invisible to the test the ecosystem reads. That is the
argument for a media-level interop profile ([interoperability](interoperability.md) §9.5), which this
project has contributed rather than merely proposed.

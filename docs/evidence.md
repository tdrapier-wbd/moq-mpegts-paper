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
control under a shaped bottleneck is characterised only in the under-provisioned failure case,
[lab: T8b](../lab/test-8b-congestion-control.md)). BBR generation is backend-specific — quinn-BBRv1 and
noq-BBRv3 strongest, quiche-BBRv2 weakest, with v1 fairness and a very-high-loss cliff
uncharacterised — so quinn-BBRv1 is the pragmatic default today. That recommendation is scoped to
non-congestive impairment: under a shaped bottleneck quinn-BBRv1 shows intermittent bloat, which would
matter for a *permanent fixed-rate* trunk, but the provisioned-path conditions that would settle it
are unrun.

## 7. Transport resilience holds; active/active source failover ships only as a bounded reselect

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
timestamps to bridge two broadcasts. Before #2473 the standby's route was simply never propagated
back across a mesh, so the pair coexisted with no failover at all.

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
chain (dual publishers → dual relays → dual subscribers → dual pacers → downstream ST 2022-7 / IRD
failover), letting the *receiver* make the hitless decision. Relay-mesh source failover does not
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

## 8. Relay compute is cheap and predictable; bandwidth overhead is the real cost

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

**Carriage costs about 1.12x the source TS rate on the wire**, essentially independent of bitrate: a
9.95 Mbps service needs ~11.2 Mbps of IP capacity and a 27.5 Mbps service ~30.8 Mbps, plus well under
1 % on the return path for acknowledgements. Against the *delivered* payload the figure is ~17-18 %,
the difference being the source's null packets, which MoQ strips rather than carries. This is the one
place the measurements show MoQ structurally *worse* than the closest comparable baseline: SRT's
framing costs a few percent, so MoQ consumes materially more bandwidth for the same service — on
precisely the line most likely to dominate a cost comparison
([economics](economics.md) §3.1).

**Publishers and subscribers are stable over a day and a half. The relay is not, under sustained
subscriber load.** Two 26.5-hour soaks plus a controlled build comparison were run. The publisher and
subscriber processes held memory flat (+0.03 and +0.15 MB/hour, against run-to-run noise several times
larger), with descriptors unchanged and no restarts — those roles pass.

The relay does not. Holding the workload fixed — one publisher, four steady subscribers, a private
relay with no prior history — and varying only the binary, two consecutive releases both grew
**linearly at about 27 MB/hour, with no decay across two and a half hours**. Five successive
half-hourly windows on the older build read between +25 and +28 MB/hour. That is roughly 650 MB a day,
and it is not a regression in the newer build: the two agree to within 2 %. An earlier soak that
appeared flat for 26 hours simply carried a lighter load. With no subscriber attached the relay is
flat, so what grows tracks *served load* rather than uptime, and it is not returned when the
subscribers leave.

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
economics in [economics](economics.md) §4 stand. The leak scales with *content ingested* — with hours
of programming carried, not with audience — so it is indifferent to how many viewers a relay serves
and proportional to how long it has been carrying a channel. For always-on primary distribution that
is the worse of the two shapes, because the load that drives it never stops.

**This is causation, not correlation, and it was confirmed by prediction.** Two re-encodes of the same
content at an identical 9.3 Mbps, differing only in how often a key frame starts a new group, make
group rate the single variable. Doubling it was predicted to double the leak, and did: 31.22 against
62.30 MB/hour, a ratio of 1.995 where the group rate ratio is 2.000, with the retained-bytes-per-group
figure agreeing to three significant figures across the pair.

That result carries an unwelcome implication. Group cadence is the knob MoQ uses to trade latency:
shorter groups mean a tighter live edge. So the leak is proportional to how aggressively a deployment
is tuned for the very property MoQ is chosen for. The same channel costs roughly 18 MB/hour at a
two-second group and 62 MB/hour — 1.5 GB a day — at a half-second one. **The lower the latency target,
the faster the relay leaks.**

**Neither documented control stops it.** `--cache-capacity` bounds payload bytes and this is not
payload; `--cache-duration`, the age ceiling on retained history, was tested at five seconds and left
the rate unchanged at 27 MB/hour. There is no setting an operator can apply. That is what makes this a
defect to be fixed upstream rather than a deployment parameter to be tuned, and it is now filed as
such.

The severe historical defect is genuinely gone — an older release grew ~21 MB/hour *with no
subscribers at all* to an out-of-memory kill after six days, and neither current build reproduces that
idle behaviour. But it would be wrong to read that as long-run relay memory stability. What replaces
it is a load-dependent growth that is larger in absolute terms under real subscriber load, and that
the documented cache bound does not contain. **Until there is a fix, a production relay needs
supervision that restarts on a memory trend, headroom sized for at least a day of growth, and a
planned drain-and-restart cycle — cache tuning alone is not a mitigation.** This is being
characterised for an upstream report rather than left as a deployment workaround.

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

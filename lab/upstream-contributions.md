# Upstream contributions

What this campaign found, reported and verified in other people's projects. It is kept separate from
the experiment record for two reasons: it is a different argument from "does MoQ suit broadcast
primary distribution", and it accounts for a large share of the campaign's effort in a way the
results alone do not show.

**Why it belongs in the repository at all.** [Comparison](../docs/comparison.md) §14 scores
operational maturity against a pre-1.0 ecosystem. This file is the concrete form of that: what a
broadcaster procures is an implementation, not a specification, so much of what reads as "MoQ does X"
is really "this build does X" — and several gaps recorded here have since closed. That is the
expected shape of implementations maturing *with* a specification rather than after it, and it cuts
both ways: the gaps were real, and they closed fast.

Each item states what was found, how it was verified, and what remains open. Where a fix was verified
here rather than taken on trust, the before/after rigs are named.

Four kinds of thing are recorded. Defects found and verified against before-and-after builds. Test
coverage and fixtures contributed, because several of these questions could not be argued about until
something in the tree could produce the stream in dispute. A review of the *specification* rather than
an implementation (§7). And requirements this campaign filed early and then withdrew on its own
measurements (§8), where the ratio is the point rather than an embarrassment.

---

## 1. Media-aware carriage: what a real contribution feed breaks

### The lane this campaign measures did not exist when it started

The first reports were about whether a broadcast feed survives the round-trip at all, and it did not.
A real contribution capture published and subscribed back produced continuously undecodable H.264
(`non-existing PPS 0 referenced`), because the import/export path kept a single SPS and a single PPS,
so a source carrying several lost all but the last seen. PES **DTS was not authored at all**, so
B-frame content — 12,480 B-frames in the capture — emitted a decode timeline a player had to be told
to ignore. Reported as [#1798](https://github.com/moq-dev/moq/issues/1798) and
[#1836](https://github.com/moq-dev/moq/issues/1836), fixed by
[#1812](https://github.com/moq-dev/moq/pull/1812) and
[#1843](https://github.com/moq-dev/moq/pull/1843).

Those were defects. The larger question — how a whole transport stream should be carried — was put as
[#1799](https://github.com/moq-dev/moq/issues/1799), which presented media-aware and byte-opaque
carriage as two options **neutrally** and asked for a direction decision instead of advocating one.
Upstream's answer is the lane everything since has been measured against: verbatim per-PID carriage
under an `mpegts` catalog section ([#1815](https://github.com/moq-dev/moq/pull/1815)), so the
ancillary PIDs a real multiplex carries — DVB teletext, AC-3, all three SCTE-35 PIDs — survive as
opaque tracks while video and audio stay typed and playable without TS support. That PR listed CLI
wiring as out of scope, leaving the lane library-only, which is what
[#1835](https://github.com/moq-dev/moq/issues/1835) →
[#1842](https://github.com/moq-dev/moq/pull/1842) closed.

### The harness that found most of what follows

The MPEG-TS/IRD compliance harness this campaign uses to grade its own output was offered upstream as
[#2024](https://github.com/moq-dev/moq/pull/2024): a round trip through a relay, TSDuck parsing the
capture, and the model arithmetic — PCR interval and accuracy, mux-rate stability, continuity — done
against what an IRD expects rather than against what plays. It was folded into the tree as
[#2011](https://github.com/moq-dev/moq/pull/2011) and hardened from review in
[#2043](https://github.com/moq-dev/moq/pull/2043), wired as `just test ts`.

It earned its place immediately, and in the useful direction: the open-GOP break below was found by
pointing the merged harness at a real capture, and its verdict on the source file was clean. The round
trip was what failed.

### Open-GOP keyframe detection — closed

A CNN International capture (open-GOP H.264 signalling recovery-point SEI, roughly one IDR every
15 s) produced **no video rendition at all** through media-aware import, because keyframe detection
keyed only on the IDR NAL type. Open-GOP is common on contribution feeds, not a niche quirk. Reported
as [#2050](https://github.com/moq-dev/moq/issues/2050).

Closed upstream by two changes the round-trip needs **together** — catalog-reservation gating
([#2072](https://github.com/moq-dev/moq/pull/2072)), which makes the exporter withhold PSI until every
PMT-reserved track resolves, and recovery-point-SEI detection
([#2066](https://github.com/moq-dev/moq/pull/2066)), without which an IDR-less feed's video never
resolves and the gate stays shut. With #2072 alone the catalog never publishes.

Verified here rather than taken on trust ([T2](test-2-media-aware-transparency.md)): the same feed
round-trips deterministically with every elementary stream, PID, `stream_type` and PMT descriptor
intact, and all three SCTE-35 splice PIDs included.

### Open-GOP leading pictures at tune-in — fixture and measurement contributed as [#4501](https://github.com/moq-dev/moq/pull/4501)

#2066 made a recovery point start a group, but nothing in the tree exercised an open-GOP stream end
to end. Upstream's consumer-side quest for leading pictures — decoded after a recovery point,
presented before it, and referencing the previous GOP — was waiting on a measurement of what a viewer
actually does with them ([#2067](https://github.com/moq-dev/moq/issues/2067)). The fixture that issue
proposed, `kyrion_dirtystart.ts`, turned out not to be open GOP. Parsed PES by PES, every keyframe is
an IDR, it carries no recovery-point SEI, and no picture after a keyframe is presented before it.

**Contributed as [#4501](https://github.com/moq-dev/moq/pull/4501)** (`test(ts)` and quest files
only), merged as `12f23811a`. On `main` at `6f1a9e33` it still round-trips 60 of 60. `just test ts --open-gop` round-trips a generated x264 `open-gop=1` clip with three
leading pictures per recovery point, and grades the capture against its source access unit by access
unit. The round-trip itself is clean: 60 of 60 leading pictures across 20 recovery points come back in
decode order. The random-access indicator is set on every random-access access unit, the
recovery-point SEI survives, and `compliance.py` passes on the output.

**The viewer is where it breaks, and how it breaks depends on the decoder.** Measured through
`<moq-watch>` in Chromium 153 on macOS, over a 120 s version of the clip, with one continuous
subscriber and eight cold joins per decoder setting:

- **Continuous playback** decoded every leading picture on both decoder paths, and the two paths'
 frames were identical.
- **VideoToolbox at a cold join** (the macOS default) never outputs the orphaned leading pictures,
 with no error and no corrupt frame, so the viewer simply starts at the keyframe.
- **The software decoder at a cold join** (`prefer-software`) raised `EncodingError` in 8 of 8 joins
 before any frame, and `<moq-watch>` then closes its decoder, so the join shows no video at all.
- **A control with the leading pictures removed** joined cleanly in 8 of 8 software joins. The error
 is the leading pictures, not starting at a non-IDR keyframe.
- **A latency skip** into a later group orphans that group's leading pictures in the same way.

The numbers now sit in the upstream leading-picture quest (`quest/m1/open-gop-leading-pictures.md`),
which the PR unblocks. They decide that its trim has to happen before decode, and that its test has to
drive the software decoder.

**Found along the way, reported in the PR and not fixed: the TS exporter authors DTS after PTS on B
pictures.** It does so on 374 of 500 access units on the open-GOP clip, worst by 119.8 ms, and on
360 of 500 on the closed-GOP clip, so it is not open-GOP specific. The exporter's decode-clock reserve
is meant to follow the catalog's reorder depth. The catalog update returns once PAT/PMT has been
written, before the reserve is refreshed, and the importer only publishes the depth after the first
group, so the reserve stays at its 16-tick default. Fixed by #4500, below.

**Open:**

- the consumer-side trim itself;
- Linux, which was not measured. The software-decoder outcome is the expected one wherever no
 hardware H.264 decoder is available, but that is inference. The arm that would settle it is the same
 cold-join rig in Chromium on Linux.

Painted-frame counts are not used: the measurement host was heavily loaded, and media arrived slower
than real time in one run.

### The exporter locked its PSI on half a catalog — closed, by a better fix than the one proposed

`export ts` built PAT and PMT as soon as a header and a video track had resolved, then aborted with
`TS track layout changed after PAT/PMT was emitted` when a later track arrived. The race is decided by
codec, not by timing luck: AAC registers its rendition on its first PES, H.264 waits for a keyframe's
inline SPS, so an audio-first stream reliably locks PSI on an audio-only layout
([#1979](https://github.com/moq-dev/moq/issues/1979)).

The fix proposed here gated PSI on the PMT's declared elementary-stream count, carried in the catalog
as `expected_tracks` ([#1980](https://github.com/moq-dev/moq/pull/1980)). Upstream's reading was that
the problem was not MPEG-TS's — *"there's a lot of containers that are final, but we don't have a good
way of signalling that or waiting"* — and closed it with catalog reservation gating
([#2072](https://github.com/moq-dev/moq/pull/2072)): a reservation per PMT-declared track, held until
its config resolves, with the catalog withheld until the last one drops. Same rule, no
container-specific field in the catalog, and it is the gate the open-GOP fix above needs in order to
be worth anything.

### The DVB service layer — closed

The `mpegts` catalog modelled per-PID PMT info and verbatim elementary streams only, with no field for
service identity or standalone SI, so `export ts` rebuilt just PAT and PMT. Service name and provider,
service type, NIT, TSID, ONID and the PMT's own PID were all lost. Reported as
[#2433](https://github.com/moq-dev/moq/issues/2433) and prototyped as
[#2434](https://github.com/moq-dev/moq/pull/2434), which captured the transport/service identity from
the PAT and carried SDT Actual and NIT Actual verbatim in a DVB-shaped `Service` record.

Upstream declined the shape rather than the ask — *"I don't really want to support DVB specifically,
but instead proxy PIDs?"* — and [#2440](https://github.com/moq-dev/moq/pull/2440) threads a service
record through the catalog and rebuilds the SI on export, keyed by PID. Measured before and after in
[T2](test-2-media-aware-transparency.md).

**That generalisation is load-bearing later.** Because carriage is keyed by PID and not by table, an
intercepted PID carries whatever sections it holds, including a table nobody has heard of — which is
why the EIT question below turns out to be about one PID carrying two tables rather than about adding
a field.

### EIT, and where carried SI should live — the question we priced

#2440 left EIT and TDT/TOT out. Measuring the residual on a synthetic fixture — no capture held here
carries EIT — split the two, because **they revise at opposite rates**: EIT repeats byte-identically
between event transitions, so carrying it costs little, while every TDT/TOT section is new content and
therefore a republish, for a table that says nothing but "now". Reported with that census as
[#2800](https://github.com/moq-dev/moq/issues/2800).

**The fixtures had to be contributed before the behaviour could be argued about**, because the one PID
under discussion is the one nothing in the tree exercised.
[#2828](https://github.com/moq-dev/moq/pull/2828) synthesises an EIT from any clip using TSDuck alone,
deriving the service triplet from the stream's own PAT and SDT and anchoring the EPG to its TDT — an
EIT whose triplet disagrees with the SDT describes nothing, and that failure is invisible, since the
packets are present, the sections parse, and a receiver is right to ignore them. It also pads a
generated clip to CBR first and says so, because `tsp` replaces packets rather than creating them, so
the table has to come out of existing stuffing; a real capture keeps its exact mux rate, which is what
makes the census believable. [#2920](https://github.com/moq-dev/moq/pull/2920) adds the two shapes the
snapshot-track work needed and nothing in-tree could produce — a sparse multi-day schedule and a
pending-version section — and, on review, wires them into `just test` so something actually executes
them, with a source-side positive control on every assertion so a broken generator fails the run
instead of making it vacuous.

The first attempt at carriage was [#2824](https://github.com/moq-dev/moq/pull/2824), EIT
present/following in the catalog — and it took that shape because the ask as filed was wrong. Carriage
is keyed by PID, and 0x0012 holds present/following *and* schedule, so "add 0x0012 to the allowlist" is
not the one-line change it looked like, and a census that bounded only p/f could not price what it
would let in. Verified here byte-identical across a version roll (v0 ×27 then v1 ×28, no flapping, no
stale version left behind); **closed unmerged** when the design moved off the catalog and onto tracks,
so that measurement grades a design step rather than shipped behaviour.

The design question behind it — **does carried SI belong in the catalog or on its own track?** — was
raised as [#2882](https://github.com/moq-dev/moq/issues/2882), and this campaign priced it rather than
arguing it. The catalog is whole-state, so one changed section rewrites the whole document and every
subscriber pays at join. Measured against service count:

| services | standing catalog | SI share | junction cost |
|---|---:|---:|---|
| 1 | 2,180 B | 34.8 % | 2 republishes in 0.11 s |
| 12 | 6,746 B | 79.2 % | 20 republishes in 0.11 s |
| 40 | 18,428 B | 92.7 % | 61 republishes in 1.27 s |

**The bandwidth is noise** — 1.12 MB against a multiplex of tens of Mb/s. What the numbers indict is
the *join* (18 kB read before media discovery, 93 % of it service information) and the *parsing*.

And a second finding was not about scale at all: **a multi-section table is assembled in the catalog
in public.** At 40 services the SDT sits at 1 of its 2 sections for 5.2 s across 53 publishes, and
section 0 declares `last_section_number = 1` — so an exporter re-emitting that state puts a table on
the wire that announces two sections and transmits one. Incomplete rather than merely stale. No
tuning of the catalog fixes it; the fault is that a whole-state document is revised one section at a
time.

Those measurements supported the move to per-table snapshot tracks **on coherence grounds rather than
bandwidth grounds**, and also showed that the tables #2440 shipped would gain nothing from it. The
question is settled in favour of tracks and implemented in
[#2909](https://github.com/moq-dev/moq/pull/2909), reviewed here by measuring it
([T17](test-17-si-snapshot-tracks.md)) — including the sparse-schedule case that cannot be validated
by counting sections.

### TDT/TOT — carriage closed, emission timing open

Reported as [#2914](https://github.com/moq-dev/moq/issues/2914), where the exclusion was deliberate and
defended on the ground that a clock is not state and an upstream multiplexer's time carries unknown
delay. Two findings from this campaign moved the argument, and one of them corrects a position this
repository had itself supplied upstream:

- **A clock synthesised from the host would break the EPG that now survives.** EIT event times are
  absolute UTC, so a clock and the schedule read against it must share one time base. Relaying EIT
  verbatim while minting TDT locally misplaces every event by the offset between the two clocks.
- **TOT carries policy, not merely time.** DST transition dates and per-country offsets are the
  operator's, and no exporter has a basis on which to invent them.

Both tables are now proxied from the source, on a latest-value slot that also removed the content-hash
identity a clock-like table would have churned through. Measured on the result: the tables arrive and
TOT's descriptors are byte-identical to the source's.

**What the fix did not settle is emission timing**, and this is the difference between the two classes of
stage. A constant-delay tunnel forwards each tick — RIST and SRT deliver TDT with inter-section gaps
matching a no-transport control to two decimal places ([T15](test-15-point-to-point-cadence.md)). A stage
that rebuilds the multiplex re-emits a stored section on its own grid, so it is late by however long it
held one (~14 s against a source true to half a second) and, below that grid's rate, re-sends a time it
has already asserted — stepping a trusting receiver's clock backwards. Filed as
[#2934](https://github.com/moq-dev/moq/issues/2934) with the narrow fix: treat the interval as a floor on
repetition and emit on change. **Closed** via [#3793](https://github.com/moq-dev/moq/pull/3793); upstream
`export_test::si_revision_does_not_wait_for_the_interval` passes on `5d0991b9`.

### A liveness risk introduced by the fix — closed by deleting the gate

As proposed, export opened its output only once every SI entry either held a snapshot or had reached a
terminal state. Terminal *failure* was handled deliberately: the track logged and kept its last snapshot
rather than killing the mux. **A track that neither succeeded nor failed was not covered**, leaving the
gate shut and the exporter emitting no TS at all, media included, with nothing logged past the subscribe
attempt. Before SI moved to its own tracks it lived in the catalog and could not independently gate media.

The first fix bounded the wait; the second removed the gate entirely, which is the better answer and the
one the join measurement supports. Nothing in SI is something a stream cannot begin without: PAT and PMT
are built locally, a receiver acquires the service layer mid-stream by design, and an entry resolving
late is indistinguishable from tuning in just before an SDT repetition. Any gate lets one stale announce
hold the programme dark, and no timeout constant makes that trade principled — while the measured 15 ms
time-to-first-byte means the healthy case still leads with its tables, it simply no longer promises to.

### PCR clustering — reported, fixed upstream in a day, and the fix moved the defect rather than removing it

The exporter conserves the PCR *mean* and destroys the PCR *spacing*. A source profiled at a flat 24.4 ms
grid, maximum 24.95 ms, nothing above 40 ms, comes back with the mean conserved to 0.7 ms, monotonic, and
carrying *more* PCRs than the source sent — while 1,123 of its 1,307 intervals fall under a millisecond
and the residual time collects into 107 gaps of up to 319.94 ms. PCR-bearing packets leave in
near-simultaneous clusters. PCR values are timestamps, so none of this is the stripped stuffing.

**This was known for months and deliberately not reported, because the campaign's own answer to it was a
downstream CBR groomer and the assumption was that the groomer absorbed it.**
[T18](test-18-delivery-latency.md) tested the assumption and it is false: the repetition figure is
identical to three significant figures across a cushion ladder spanning eight times the depth, unchanged
when groomer starvation is removed entirely (18,070 underruns to 5, stuffing to 0.0 %), and unchanged over
a real internet path.

**The load-bearing evidence is that the groomer inserted PCRs and it changed nothing.** This groomer
places a PCR of its own only into a slot it was already going to stuff, so its insertion budget is the
carrier's rate surplus. Across the ladder that surplus runs 4.1 % → 3.2 % → 0.8 % → 0.0 % and the
insertions run **137 → 103 → 28 → 0** with it, while the violations hold flat at **491, 489, 503, 502**.
Four different insertion rates, one conformance result. 137 insertions were never going to cover ~490
gaps, because a spare slot falls wherever the carrier runs ahead of the content and that is uncorrelated
with where the exporter left a gap. Scaling from the measured point, covering them all needs a carrier
running far enough above content rate to reproduce #1992's own abandoned first horn — ~20 % empty
PCR-only windows — reached from the downstream side. So the division of labour is measured rather than
asserted: **placement is the exporter's because buying it downstream costs exactly the carrier efficiency
the downstream stage exists to provide.**

**A later rig supplied the control the original report lacked, and it sharpens the ask from a rate to a
rule.** [T8b](test-8b-congestion-control.md)'s provisioned-path matrix writes `moq export ts` straight to
a file with no groomer downstream, and carries the same clip on the same PID over SRT and two segmented
clients in the same session — so the source train and the exporter's can be compared directly rather than
inferred through a pacer. The source reads an even PCR every 24.65 ms with **zero** intervals above 40 ms
and a 25.0 ms maximum, confirmed independently on all three transparent lanes. The exporter reads 31–36
PCRs a second against the source's 41, a median interval of **0.011 ms**, 85 % of intervals below 1 ms,
and 361–399 intervals above 100 ms with maxima of 0.54–1.84 s. **The count of clock samples very nearly
survives; only their positions do not** — which means a *denser* cadence, the reading a threshold count
invites, would add PCRs inside the existing 11 µs clusters and leave every violation standing.

The code path is `rs/moq-mux/src/container/ts/export.rs`: the adaptation field carrying PCR is attached
under a `first && (unit.is_pcr || unit.keyframe)` guard, i.e. to the first TS packet of each PES unit on
the PCR PID and to no other packet, with the value taken as `dts.unwrap_or(pts)` for that unit. There is
no interval-based insertion path in the exporter at all, so PCR cadence is a side-effect of unit
boundaries and unit ordering. That locates the mechanism without explaining it — one PCR per unit on a
25 fps clip predicts a 40 ms cadence, not 36/s at 11 µs spacing — so the remaining unknown is what the
unit ordering or the clock choice does, and answering it needs the per-unit DTS sequence logged against
packet position.

Filed as [#2937](https://github.com/moq-dev/moq/issues/2937), and the filing had to engage with a history
rather than report a defect. Upstream had already built this fix and abandoned it: a dense uniform PCR ramp
([#1989](https://github.com/moq-dev/moq/pull/1989)), folded into ~20 ms PCR-led windows
([#1992](https://github.com/moq-dev/moq/pull/1992)) with delivery spreading
([#1988](https://github.com/moq-dev/moq/pull/1988)) — all closed after an independent tester reported that
no operating point on a Sencore IRD was both smooth and stable, because without null stuffing the gap
between carrier and content rate surfaces either as ~20 % empty PCR-only windows or as an unbounded queue.

**What this campaign contributes is that the dilemma has a resolution and it is not in the exporter.** Both
horns were measured from the downstream side and a bounded CBR buffer absorbs both — a 3.2 % surplus is
18,070 underruns the groomer fills with nulls at a standing depth of 87 ms, and a 0 % surplus is 5
underruns at a depth that holds its commanded 824 ms. Neither collapses, and the stage costs 109 ms of
delivery latency over the public internet. So the argument put upstream is a division of labour: the
exporter owns PCR *placement* in the time domain, since nothing downstream can move a PCR it received in a
cluster, and a CBR egress stage owns the byte domain, which it already does at 0 continuity errors and 0
accuracy violations at the 481 ns gate. Placement and delivery are separable; #1992 coupled them.

**#2937 as filed asks for the right change; this repository's shorthand for it did not.** The issue says
"it is not sparsity", reports the mean conserved to 0.7 ms, and asks for PCR-bearing packets at a bounded
*interval* — which the control above confirms is exactly the fix. What drifted was the in-house paraphrase:
"the exporter emits PCRs too rarely" and "a denser cadence would clear the gate" had propagated into
`docs/evidence.md`, `docs/comparison.md`, `docs/architecture.md`, the top-level `README.md`, T13 and T16,
and would have misdirected anyone acting on our evidence. Corrected throughout to placement. The
placement framing is also the one least likely to re-open #1992's dilemma, since it adds no PCRs the
source did not already justify and therefore creates none of the empty PCR-only windows that sank the
earlier attempt.

**Two things were added to the issue as a follow-up, and both narrow it rather than restating it.** The
filed report left the mechanism explicitly open — "consistent with group-wise reassembly … inferred from
the distribution and not confirmed against the code". The `export.rs` guard above closes half of that:
PCR placement is a per-PES-unit side-effect with no interval path, so whatever the ordering does, there
is nothing in the exporter that *could* hold an interval. And the three-lane control is a stronger form
of the evidence the issue already carries, because it puts the source, a byte-transparent carriage of it,
and two independent segmented carriages of it beside the exporter in one session — so "the source is
conformant and the count survives" is measured three ways rather than profiled once. The comment also
flags, for [#1838](https://github.com/moq-dev/moq/issues/1838), that a monitor reporting only "intervals
above 40 ms" cannot distinguish this defect from ordinary loss, since a lossy SRT lane posts 538
crossings with its median interval unmoved at 24.8 ms and 0.0 % of intervals under 1 ms.

**The fix landed within a day of the follow-up and it is exact.**
[#2967](https://github.com/moq-dev/moq/pull/2967) merged as `61678fd32`, decoupling PCR from PES units
entirely: it rides its own adaptation-field-only packets, one per 25 ms slot of an absolute media-time
grid. Verified here on our clip and our instruments against the immediately preceding build
([T19](test-19-pcr-grid-verification.md)): every one of 2,472 consecutive intervals is exactly
**25.000 ms**, minimum and maximum alike; intervals above 40 ms go **210 → 0**; the sub-millisecond
clustering goes **85.40 % → 0.00 %**; the PCR rides only the announced PID on payload-less packets that
correctly do not advance the continuity counter. It also answers the mechanism the follow-up left open,
from the code rather than the distribution: on reordered content the authored decode clock is a saw, and
each B-frame dipping below it is nudged exactly one 90 kHz tick — **11.1 µs** — past the previous DTS,
which is the 11 µs median measured.

**It repaired a second defect we never found.** The six reserved bits of the PCR field were being
written as zeros where ISO 13818-1 requires ones. Eighteen experiments missed it because every
instrument we pointed at the stream read the PCR *value* and none checked the field's padding; the PR
found it while hand-laying the new packet. Our own before/after confirms it: `0x00` on every PCR in the
control build, `0x3F` on every PCR in the fixed one. A related improvement worth recording is that
TSDuck's reference bitrate for the exported stream goes from a meaningless 20.7 Gb/s to a credible
9.57 Mb/s, because the clustered values had been poisoning every rate estimate derived from them —
including any a monitoring probe would alarm on.

**And it does not yet meet the requirement it closes, which is the part to take back upstream.** #2937
was filed on the claim that no downstream CBR stage can repair the defect, so the test is the wire and
not the muxer. #2967 returns each PCR as its own output `Frame` stamped at its slot boundary, and
`moq export ts` writes to stdout, which carries no timestamps — so the computed spacing is discarded at
the exporter's only public interface. Measured on the exported bytes, **87.2 % of consecutive PCR
packets sit back-to-back**, in bursts to 13, with 11.9 % separated by more than 200 packets and gaps
reaching 2,730 packets (411 ms of carrier at 10 Mb/s). The clustering changed domain: even values at
clustered positions, where it was clustered values at even positions.

The consequence is measured on two independent groomers, and it is why this is worth reporting rather
than absorbing. Off-the-shelf `tsp -P pcradjust`, which re-stamps PCR from byte position, converts the
clustered positions straight back into clustered values — **293 intervals above 40 ms and 87.9 %
sub-millisecond**, the original distribution regenerated from scratch, and a near-exact match to the
87.2 % of input packets that arrive back-to-back. Our own byte-locking groomer, whose placement model is
what makes two legs of a 1+1 pair byte-identical, **drops 45.9 % of content** and it is structural
rather than a buffer size. End to end on the wire the lane is worse than before the fix: continuity 0 →
824 errors, worst interval 228 → 375 ms, delivery latency 118 → 769 ms.

**So the remaining ask is narrow, and reading the code makes it narrower than a pacing request.** #2967's
own doc comments state a caller-side contract in as many words — each PCR is returned as its own frame
stamped at its slot boundary *"so the caller's pacer places the PCR at"* its slot — and the burst is that
contract working as designed, because `PCR_BACKFILL` fills every slot a coarse frame crossed and drains
them over successive polls. **One in-tree caller has the shape of the contract and the other has
nothing.** `moq-srt` derives `send_at = anchor + (ts - base)` from the frame timestamp and waits
(`rs/moq-srt/src/server.rs:413`); `moq-cli`'s `run_ts` is `write_all(&frame.payload)` and never reads
`frame.timestamp` (`rs/moq-cli/src/subscribe.rs`). That `moq-srt` pacer turned out to be broken for
media frames — the correction is in
[test-19](test-19-pcr-grid-verification.md#corrections) — but the asymmetry the report rested on is the
one #3006 confirmed as its root cause. So the report is not "add pacing to a transport
library" — which we withdrew on [#1839](https://github.com/moq-dev/moq/issues/1839) and still would —
but "your new code specifies a caller contract, one caller implements it, the other silently discards
it, and what it discards is not recoverable downstream."

That distinction is what keeps the report consistent with our own filed positions. On
[#1838](https://github.com/moq-dev/moq/issues/1838) we argued that byte cadence at moq's egress is not a
defect and that repairing it is the groomer's job, and that still holds: a groomer can fix *when* bytes
leave, but it cannot reconstruct which media bytes a PCR was meant to sit beside once thirteen slots of
clock have been written to one byte position. The fallback ask — emit the PCR packet adjacent to the
media bytes of the slot it labels — needs no timing at all, but it is a larger change in `moq-mux` and is
offered rather than pressed.

**It is a new issue rather than a comment on either neighbour.**
[#2978](https://github.com/moq-dev/moq/issues/2978) is the same class of defect and the maintainer found
it himself in his adversarial review of #2967 — a frame's pacing timestamp lost where bytes are handed on
— but it is scoped to `moq-srt`, is bounded by one 1316-byte chunk (~1 ms), and its own text puts it
"orders of magnitude below the clusters #2937 measured". Filing ours there would get an unbounded loss on
a different component mis-scoped as a minor variant of something already discounted. Reopening #2937
would be worse: the fix did exactly what the issue asked for, inside the boundary the issue named.

**Filed as [#2984](https://github.com/moq-dev/moq/issues/2984).** It leads with the fix being exact,
credits the reserved-bits repair and the mechanism the PR explained, and states plainly that the
end-to-end regression is the interaction rather than the change — because the end-to-end arm was run
first here and would have been reported as a regression in #2967 had the no-groomer arm not followed it.

**#2984 was accepted and fixed in [#3006](https://github.com/moq-dev/moq/pull/3006)**, which paces the
stdout writer on each frame's timestamp — the ask, granted as asked, with the root cause stated as ours
was: `run_ts` never read `frame.timestamp`. Two things came out of the fix that are worth recording.
It had to extract a `Pacer` into `moq-mux` and **repair `moq-srt`'s own pacer on the way**, because that
implementation — the exemplar this report cited — collapsed cross-scale timestamp pairs onto the anchor
and never paced media frames at all; the correction is in
[test-19](test-19-pcr-grid-verification.md#corrections). And
[#2978](https://github.com/moq-dev/moq/issues/2978), which we had recorded as left open by #3006 as the
bounded sub-chunk case, is in fact **closed as completed on 2026-08-21, the day before #3006 merged** —
so the scoping argument this report made for filing separately stands, but not for the reason we wrote
down.

**Graded, the fix does what it says and does not move the lane.** At the pipe the on-grid share doubles
(27.4 % → 56.9 %) and gate failures halve (18.26 % → 7.45 %), median interval 24.69 ms. End to end the
deployed chain is unchanged: 120.0 → 771.6 ms and 0 → 1,166 continuity errors, against the laptop rig's
118 → 769 ms on #2967 *alone* — a build with no pacing in it, which is what rules out the new lead
budget as the cause. **A groomer consumes bytes, not arrival times**, so the outstanding ask is now the
fallback this report offered rather than the one taken up: emit each PCR packet adjacent to the media
bytes of the slot it labels.

**That ask now has a located root cause, and it is not the one the fallback assumed.** It is filed as
[#3334](https://github.com/moq-dev/moq/issues/3334), drafted in
[#3334](https://github.com/moq-dev/moq/issues/3334),
and is not simply "please also fix the positions". Reading the current code,
`Export::poll_next` advances the PCR grid only as far as `slot(next pending media frame's timestamp)`,
and `pick_next_track` only considers tracks that already hold a pending frame — so **the clock is a
function of frame arrival rather than of the passage of media time**, and cannot lead the media it
exists to lead. A backfilled run therefore falls due only once the frame proving those slots elapsed has
landed, by which point every slot in the run is already late to write; and because `write_frame` emits a
whole media frame as one payload written by one `write_all`, a PCR packet can only ever be placed
*between* media frames. Measurement 7 of [T19](test-19-pcr-grid-verification.md) shows the two
consequences are one phenomenon — 615 of 626 early releases are exactly the byte-adjacent packets — and
that the residue is the exporter's rather than the host's, identical at 7.45 % on two and on eight vCPU
at zero CPU pressure.

**The ask was granted, and verifying it is the strongest confirmation this report has had.**
[#3351](https://github.com/moq-dev/moq/pull/3351) slices the export on the PCR grid instead of on media
frames, closing #3334 and folding in #3335's harness as the evidence. Graded here against **its own
merge-base**, one host, one variable: adjacency **50.31 % → 0 %**, releases outside ±10 ms
**491/799 → 0 to 4/745**, p95 **70.3 → 1.5 to 1.9 ms**, continuity 0 on both. The control reproduces the
mechanism above exactly, with 43.4 % of its PCR packets both adjacent *and* early, which is the single
cause appearing as one measured quantity in a build the maintainer did not write the fix against. The
buffer the fix introduces converges to **480 ms against a 500 ms `--latency-max`** and then holds to
0.017 ms/s over 40 s; the publisher alone drifts ±0.8 ms per decile, so the lag is the exporter's and it
is a constant offset rather than a rate error. The maintainer's own recorded limit, that byte position
stays uniform on one rendition but goes lumpy across two, is the same defect this campaign measured from
the other side on [#2829](https://github.com/moq-dev/moq/issues/2829) with the two-host merge oracle
(single rendition 46,778/46,778 identical; a 7-stream mux 75.56 %, the residue reordering rather than
damage). Reported on the PR with the numbers, the control, and the caveat that this grades the pipe and
not the wire.

**It merged as `4cf216149`, the wire was graded, and #3334 is discharged as filed.** The invariant #3334
stated — that PCR byte position and release instant stop being functions of frame arrival — holds on the
merged build against a real contribution clip: adjacency 0.0 %, releases outside ±10 ms 2 of 4,779 at a
p95 of 1.70 ms. **The lane still fails its own conformance gate**, at 12.2 % of intervals above 40 ms
and 811 continuity errors end to end, and that is worth stating precisely because it is *not* a residue
of #3334. #3351 places each slot's bytes at the media time the slot asserts; a coded frame's bytes
belong to its own 40 ms however large the frame is, so a 417 kB I-frame is 357 ms of carrier for 40 ms
of media. The smoothing that a CBR mux supplies against a T-STD buffer is not encoded in decode
timestamps, so **no exporter working from them can reconstruct it** — the requirement belongs
downstream, and downstream can meet it: cushioned past the bounded 761 ms displacement our groomer
conserves 99.6 % of the programme at 0 continuity errors and exact CBR. **Nothing further is owed
upstream on this line**, and no new issue was filed.

**One gap in upstream's own gate is worth knowing about, and it is a scope gap rather than a defect.**
`pcr-timing.py`'s `pcr-position` check grades *adjacency*, which is what #3334 was about. On upstream's
generated fixture the worst positional gap is 115 packets; on a 1080i25 contribution capture it is
**4,641**, and the check passes both. A gate built on adjacency alone will not see a frame-shaped
export meeting a byte-locking consumer. Not filed: the check does what it was written to do, the
quantity it misses is the one this campaign has just shown is not the exporter's to fix, and an issue
asking for a threshold on someone else's content would be spending their attention badly.

**Two things governed how it was filed, and both are about not spending someone else's attention badly.**
It is a **new issue** rather than a comment: #2937 and #2984 are closed as completed and correctly so —
#2967 delivered the contract #2937 asked for, and #3006 delivered #2984's — so a residual buried in either
thread would be lost, and reopening a correctly closed issue misrepresents the work that closed it. And
the report states the **invariant as a requirement** and then offers three implementation directions with
their trade-offs, saying explicitly that the choice belongs to whoever owns the `Frame` contract. The
code points at a finer emission unit; the issue does not press for it. Every code excerpt was re-read
against current upstream `main` before posting rather than against the local worktree, which
intentionally predates #2967.

**The #2829/#2779 connection was posted as a code reading and marked as one.** Comments on
[#2829](https://github.com/moq-dev/moq/issues/2829) and
[#2779](https://github.com/moq-dev/moq/issues/2779) say the PCR-position finding *may* be another
manifestation of the same underlying property — output derived from process state rather than from stream
position — and say plainly that this is untested, that the mechanisms differ in their details, and that
it should not be read as a claim that the three are one defect. If it holds, the three want one change
rather than three; that is worth a maintainer knowing and is not worth asserting.

**Review found six real defects in that test tooling, and they were worth having.** Two automated
reviewers (Codex and CodeRabbit) went over #3335; the substantive findings were all correct and are
fixed at `faac801`, each with a before/after test against a purpose-built fixture rather than by
inspection. `parse_pcr` read six PCR bytes without checking `adaptation_field_length` covered them, so a
short field yielded a value assembled from stuffing and reported a **95,441,900 ms** interval. The
`continuity` check — a *hard* check — failed two constructions ISO 13818-1 2.4.3.3 permits, the
duplicate packet and the `discontinuity_indicator` jump, so a conforming stream failed the run. PCR
values were not unwrapped across the 33-bit rollover, and a backwards PCR was invisible because only the
upper bound was tested. Accumulated release drift was documented as bounded, reported in the detail and
never gated the verdict: it passed at 251 ms. And `--live` blocked in `read()` past its deadline, so a
producer holding the pipe open without writing suspended `--seconds` indefinitely — the likeliest state
while diagnosing the very stall the tool exists to catch. **No campaign number is affected**: the
continuity figures quoted in T19 come from TSDuck, and the tool's report on a real 393,311-packet
capture is unchanged. One suggestion was declined with a reason: counting *non-positive* intervals as
defects fails a conforming stream, because a legal duplicate repeats its PCR exactly and yields an
interval of zero. The first attempt at that fix did exactly that, and the duplicate fixture caught it.

**One of those six fixes was itself wrong, and grading #3351 is what exposed it.** The new drift bound
was given a 250 ms default, which is derived from nothing and sits *below* the 500 ms that
`export ts --latency-max` entitles the sender to hold, so it failed a correct pipeline three runs out of
three. The defect was conceptual, not arithmetic: a sender that buffers builds a standing lag once and
then runs at the media rate, and a pipe running slow never stops accumulating, but both present as
"accumulated drift" and only the second is a defect. Corrected at `bbe2ec5`: the total is bounded at the
budget the sender may hold, defaulting to 500 ms to match `--latency-max` and documented as something to
set to it, and the tail's drift rate is reported beside it, which is what separates the two shapes. A
pipe whose per-interval error sits inside any percentage allowance but which never stops accumulating
still fails on the total, so the term keeps its teeth. Reported as a correction on #3335 rather than
quietly amended. The same commit folds in #3351's `--release-pct-max` so the two copies of the file do
not diverge, and #3351 was told to take `bbe2ec5` because its copy predates the whole review.

**Two more followed at `e7f1e3cc`, and they came from building fixtures for the conditions the
standard *permits*.** Four of the original six were the analyser failing conforming input, and its own
tests were all of the form "does it catch a break", so the accept path was whatever the implementation
happened to do. Given a legal fixture per condition, two more fell out. A **signalled discontinuity**
failed twice over: 2.4.3.3 licenses the counter jump, which the earlier fix handled, but 2.4.3.4
licenses the *clock* jump with it, so the value check read a splice as an 820 ms repetition breach and
the release check as seconds of lateness, with the unwrap logic close to absorbing it as a rollover.
Intervals spanning a declared new time base are now dropped from both and counted separately, and
drift is summed over graded intervals so it telescopes identically on an unspliced sample. Separately,
**Codex's insufficient-sample finding on #3351 was correct**: `check_release` returned a hard pass
labelled "not measured" below three timestamped PCRs, which is right for a file and inverted for a
pipe, where too few stamps means the producer died rather than that the stream was clean. On this rig
the exporter exits early on most runs, so a truncated capture carrying the timing gate green was a
live route rather than a hypothetical, and on the merged-build verification it would have been a false
pass on the very question the run exists to answer. Live now floors both the sample count and the share
of the window it spans. `just fix` and `just check` clean, each verified against its own fixture, and a
real broadcast capture plus the x264 source used to grade #3351 return identical verdicts before and
after — so nothing already measured moves. The two automated reviewers on #3351 had meanwhile re-found
**four of the six earlier defects independently**, which is the strongest argument available for that
PR taking this branch's copy of the file.

**A test contribution went with it as a PR**, [#3335](https://github.com/moq-dev/moq/pull/3335), adding
`test/ts/pcr-timing.py` and its README entry and **nothing else** — no core behavioural change, which
is the line this campaign holds between reporting a defect and implementing someone else's fix:
[`ts-pcr-timing.py`](scripts/ts-pcr-timing.py) grades value, release and position in one pass against
the stream's own PCR values — no reference clock, no source file, no declared mux rate, `python3` only.
It has a clear upstream home beside `test/ts/compliance.py`, the harness this campaign originated and
which Luke committed as #2011/#2043. That harness states that its timing basis is the stream's own PCR
clock and that it therefore *"needs no wall-clock capture"* — which is the right choice for what it
grades and precisely why it cannot see #3006, whose whole effect is on wall-clock release. So **#3006's
contract has no regression test upstream today**, and this is the gap. Each build fails a different pair of checks
(pre-#2967 fails value and release and *passes* position; post-#3006 passes value and fails the other
two), which is what makes it a test of the defect rather than an assertion about an implementation.
It passes upstream's own gate — `just fix` then `just check` from a clean worktree — and the whitespace
convention there is not ours, so the script was re-run after the formatter rewrote it.

**The half of this defect that is ours was fixed on our side of the boundary, not asked for upstream.**
The byte-locking groomer read source PCR value cadence and byte-position cadence as interchangeable,
which is an assumption about the source that no source is obliged to satisfy, and on the T19 fixture it
exited *zero* having shed 67.2 % of the programme. That is a `mpegts-pacer` defect and it is guarded
there — T19 measurement 8. Upstream owns the placement; we own having assumed it.

The prediction that an even 20–25 ms interval clears the P1 gate **remains a prediction**: the clock
arriving at the edge is even and its timing now survives to a real-time consumer, but no conformant wire
has yet been produced from it, so the rig still has to re-run against a build whose *byte positions*
carry the spacing. And the effect size varies
by clip for reasons not established: 25.2 % of intervals above 40 ms on a synthetic CBR reference, 13.9 %
and 9.1 % on two contribution captures, and 0 % on a 27.5 Mb/s broadcast mux whose native cadence is
27 ms. That exception is unexplained and was reported as unexplained.

### A rewound timeline stalls the whole programme, not just the SI cadence — measurements contributed, issue fixed and closed, **fix later found to regress the complement** (next section)

[#2833](https://github.com/moq-dev/moq/issues/2833) is the maintainer's own, and it already had the
mechanism: the exporter's stored last-emission only moves forward, so after a backwards jump nothing is
due until the timeline catches up. Its closing paragraph asks for the PCR and `discontinuity_indicator`
question to be handled together with it. So this is a comment, not a new issue —
[#2833 (comment)](https://github.com/moq-dev/moq/issues/2833#issuecomment-5554907607) — carrying what
[T23](test-23-pcr-discontinuity-classes.md) measured that the issue did not have.

**What the measurements add.** The title scopes the stall to SDT/NIT repetition; in fact the exporter
stops emitting *everything*, so a rewind is a hole in the programme rather than a gap in the tables.
The cost is **linear in the rewind** — 1 s → 268 ms, 2 s → 1,487 ms, 5 s → 4,514 ms, 10 s → 9,446 ms,
44.7 s → 44,049 ms — which is what "until the timeline catches up" predicts exactly, and which turns a
qualitative defect into a budget. Recovery is a **single 18.3 MB burst** that overran our groomer's 8 s
cushion, so a consumer that survives the outage can still be broken by the re-entry.

**And what it removes from the issue's scope**, which is the more useful half. Forward jumps recover in
238 ms, so only the backwards case needs handling. The **33-bit PCR base rollover is carried correctly
end to end** — 30.080 ms across the boundary in modulo arithmetic, 6,259 PCRs within ±500 ns, zero
continuity errors — so the `due` comparison never sees one, and whatever threshold or signal is chosen
should keep that true. On the flag itself: `discontinuity_indicator: false` is hardcoded at
`rs/moq-mux/src/container/ts/export.rs:1102` on `2a6d9ebdf`, and it shows on the forward case too,
where the exporter reproduces its own +29.05 s timebase change with the flag clear.

**Outcome: fixed and closed, on these measurements.**
[#3375](https://github.com/moq-dev/moq/pull/3375) opened citing the comment as its motivation — *"Still
needed after #3351. t0ms's controlled tests on merged main found that rewinds stop the entire program
output until timestamps catch up, then release the accumulated backlog"* — and merged as `0e61e3520`,
closing #2833 as completed. It restarts the exporter on a rewind rather than waiting the timeline out:
uncommitted media discarded, timing and table state reset, **the first new PCR flagged**, and the
continuity counters of discarded bytes rolled back so recovery introduces no gap. Each of those
answers one of the things measured above. It also adds
`moq_mux::container::ts::Export::discontinuity()` so a consumer can see the event, which is what the
issue's closing paragraph had asked for.

**We supplied the verification the fix shipped without.** The maintainer states plainly that his
validation is *"the repository harness, not a rerun of t0ms's external stimulus campaign"* — upstream's
own 20 s and 120 s arms plus new unit regressions — so nothing had graded the fix against a placed
timeline event through a full lane. Re-running all six arms unchanged against `d88c2ee99` puts every
one at the control's content gap, and the before/after table, the three-point timeline evidence and
the collapse of the downstream buffer requirement went back as
[#3375 (comment)](https://github.com/moq-dev/moq/pull/3375#issuecomment-5557693602). It asks for
nothing; the detail is in [T23 § against the fix](test-23-pcr-discontinuity-classes.md#against-the-fix-3375).

**One part of the campaign outlived the fix, and has since been fixed by
[#3529](https://github.com/moq-dev/moq/pull/3529).** `quest/m0/ts-forward-discontinuity.md`, one of
three follow-ups left open, was built on this campaign and directed its implementer to *"use the
stimuli and oracle linked from the issue comment"*: the forward-jump arm's missing flag was not
discharged by #3375, because rewind recovery handles the container consumer's signal without
establishing that every input adaptation-field flag reaches it. #3529 discharges it, **deleting that
quest file as complete**, and its end-to-end regression test
`a_signalled_reset_reaches_the_exported_clock` is documented as *"the end-to-end shape the #2833
stimulus campaign graded"* — this campaign's arm C, asserted upstream as a unit test. Re-running arm C
unchanged confirms it on current `main`: the flag is emitted, the exported jump is faithful to 11 ms
instead of 961 ms short, and a starvation this lab had attributed to its own groomer goes with it
([T23 § against #3529](test-23-pcr-discontinuity-classes.md#against-3529-current-main)). The other two
follow-ups carry the same signal into SRT egress pacing and the JavaScript consumer.

**A guarantee we did not ask for, and one semantic worth noting.** #3529 also fixes the direction of
the decision: the exporter reports what the source *declared* and will not infer a break from a
timestamp step. An **unsignalled** jump therefore still reaches the wire unflagged, by design. In this
lane it is `mpegts-pacer` that flags such a step — measured, and on the pre-#3529 build it was
covering for the exporter on the *signalled* case too, putting one flag on the groomed wire where the
export carried none. That dependency is now discharged: conformance on a signalled forward jump no
longer requires our groomer.

The earlier draft, written from T21's looping stimulus, claimed the exporter latches its PCR and emits
a counter permanently. No arm of T23 reproduces that, and the draft was retired rather than filed. See
[method notes](method-notes.md) §6.

### #3375 regressed the complement: a *non*-rewinding source now stalls video and primary audio — reported as [#3533](https://github.com/moq-dev/moq/issues/3533)

**This is the campaign's own fix, and it traded one failure for its opposite.** #3375 was written
because of the T23 measurements above, and against its target case it works — that is measured below,
not assumed. But on a source whose timeline is **continuous** and whose *content* restarts, the fixed
exporter stalls video and MPEG-1 audio permanently. From [T27](test-27-liveness-detector.md):

**Bisected to one commit.** 53 commits between the build T21 soaked for 24 h and the build under
test; `git bisect run` over them, each step building the CLI and crossing several content joins with
the candidate *and* a known-good binary in the same run. First bad commit **`0e61e35` — #3375,
"fix(moq-mux): recover buffered TS output after a rewind"** — which changed
`rs/moq-mux/src/container/ts/export.rs`, the exporter that stalls. Confirmed against its own parent
`025613d` with two replicates per build against one publisher and one relay: parent **9.0–9.8 Mb/s**
across seven joins, #3375 **0.31 Mb/s** from the first join onward, never recovering.

**The two cases, same clip, same relay, only the source's timeline differing:**

| source | parent `025613d` | `#3375` `0e61e35` |
|---|---|---|
| **true rewind** — `tsp --infinite`, every 30 s | **0.00 Mb/s** from t = 40 s, total stall — the #2833 behaviour this PR fixed | **8.66 Mb/s** mean, dipping to ~7.4 at each rewind then recovering |
| **continuous timeline, content join** every 30 s | **9.0–9.8 Mb/s** throughout | **0.31 Mb/s** — only PSI, AC-3 and teletext survive |

**The exporter introduces a rewind that is not on the wire.** A per-PID liveness detector on each
build's output at the same join: the parent records **0 delivered-clock discontinuities** and keeps
video and MPEG-1 audio live with zero outages, while #3375 records a step **backwards by 119.35 s —
one pass length** — after which PID 111 (AVC) and PID 121 (MPEG-1 audio) go dead and never clear.
Since the parent, on the same bytes, sees no discontinuity, the rewind is generated inside the new
recovery path rather than delivered to it. The importer logs an MPEG-2 audio resync at the join
(`resyncs=2 discarded=714`); whether that is the trigger is inference and is offered as such.

**Attribution is bounded.** Not the source: two passes accumulate 1200.0 s of media with **0 backward
PCR steps**. Not the relay or publisher: while 60 incumbent subscribers were stuck a **freshly
joining subscriber was served perfectly** (8.9 Mb/s, 143,872 video packets in 25 s) from the same
broadcast, with relay CPU at 0.54 of 2 cores. Not `--latency-max` and not fan-out: at N = 4,
subscribers at 500 ms and 3 s stalled together within one 10 s sample.

**Why this matters more than the case it replaced**, stated for the report: a continuous timeline
carrying content joins is what a real encoder emits; a rewinding one is an artefact of looping a
file. The pre-#3375 failure needed a stimulus the lab had to manufacture. This one arrives on its own.

**The code path is named, from the diff.** `Track::admit` discards a frame from any track still in an
older generation unless it *both* changes its discontinuity counter *and* steps backwards on that
track's own timeline; and `rewind()` leaves every track that already has a timeline in the old
generation whenever the boundary is backwards. **One track reporting a backwards step therefore fences
all the others, and a fenced track whose source never rewinds can never re-join.** A prediction from
that reading was tested rather than assumed: the fence needs a bystander, so a single-track source
should be immune — and a video-only source is clean on both builds across five joins (1.88–2.00 against
1.88–2.02 Mb/s). What is *not* established is which comparison in the audio path yields
`backwards = true` on a source with 0 backward PCR steps; the report says so rather than guessing.

**Filed as [#3533](https://github.com/moq-dev/moq/issues/3533)**, carrying the bisect, the
paired-replicate confirmation against the parent, the two-source contrast, the named code path, the
video-only bystander control and the permanence figure. The reproducer is a ~30 s clip replayed on a
continuous timeline, which fails within one join. What the report explicitly does **not** claim is
which comparison in the audio path yields `backwards = true` on a source with 0 backward PCR steps —
that is left to the maintainer rather than guessed at, which is the lesson of the retired draft above.

**Accepted upstream, and the maintainer supplied the part the report withheld** — the legacy audio
importer re-locking a sub-frame below its extrapolated high-water mark, fencing peers through
`Track::admit`. **Closed** by [#3784](https://github.com/moq-dev/moq/pull/3784) in
[#3793](https://github.com/moq-dev/moq/pull/3793) (`5d0991b9`): `export_test` passes and
[T40](test-40-continuous-join-through-srt.md) no longer reads the 0.31 Mb/s stall through the SRT chain.

**What remains on the dev line is not the stall signature.** On homogeneous `5d0991b9`,
`moq import ts` exits at the first content join with *frame timestamp is below the live edge*
([T40](test-40-continuous-join-through-srt.md) § `main-5d0991b9-swap`) — a monotonic-timeline
enforcement from the dev merge, separate from #3533's export-side fence. Root cause: `reanchor()` from
the #3533 fix applies to legacy audio only; H.264 and verbatim PES paths call `Producer::write` without
it. Filed as [#3798](https://github.com/moq-dev/moq/issues/3798). Continuous-source permanence and any
long run on `ts-continuous-source.py` were blocked by it until upstream `main` fixed it (see *#3798's
plan asks for a reproduction* below).

### The mux rate the lane could not carry — closed upstream, citing this campaign's groomer

**The finding.** `moq export ts` emitted content only: MPEG-TS null packets are not carried across
MoQ, so the reconstructed stream had no stuffing and declared no multiplex rate. A downstream IRD or
groomer had to be told the rate out of band or measure it, and the campaign's own tool said so —
[`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer)'s README states that the mux rate is
*"not recoverable from MoQ"*. That sentence is quoted in the fix's problem statement.

**Closed** by [#3831](https://github.com/moq-dev/moq/pull/3831). Import measures the whole-multiplex
rate off the PCR PID — every packet including nulls, over the 27 MHz ticks between clocks, pooled into
half-second samples and published only once a window agrees within 2 % — and records it in the catalog
as an additive `mpegts.muxRate`. Export settles a fixed-point packet balance before each clock packet
and emits `floor(max(balance, 0))` nulls ahead of it; media is never delayed or dropped, and both debt
and credit are capped at one second. `moq export ts --mux-rate <bps>` overrides the catalog. A
broadcast that recorded no rate exports byte-identically to before.

**Verified here** ([T13](test-13-downstream-grooming.md) § *The exporter now stuffs and declares a
rate*, file domain, `0.11.2-615d166d`): stuffing returns at **4.93 %** against the source's 4.69 %, and
the output declares **9,981,799 b/s** against a 9,945,951 b/s source — **+0.36 %**. The explicit
`--mux-rate` path lands at +0.25 %. Continuity stays clean.

**What it does not do, measured rather than assumed.** Padding is a composition change. **PCR accuracy
and PCR repetition are unmoved** — 0 of 1,807 PCRs inside the 481 ns P2 gate, 11.34 % of intervals above
the 40 ms P1 limit, against 0 of 1,892 and 11.21 % on the previous build. The useful consequence is that
the P2 gate becomes *answerable* on the ungroomed egress for the first time, because there is now a
declared rate to grade against; it is answered with a comprehensive failure. A groomer remains required
on this lane for both PCR criteria.

**Still owed from here.** The absent-rate path is untested: filtering nulls out of a CBR source leaves
the PCR values intact and therefore still yields a stable, lower rate (import recorded 9,486,940 b/s
and padded to it), so a genuinely variable source is needed to exercise the omitted-field case.

---

## 2. Audio robustness: three defects, two closed

### Frame-sync loss killed the whole publisher — closed in two days

**The finding.** A single damaged byte in an MP2, AC-3 or E-AC-3 frame header terminated the
publisher outright and took every other track with it — video, teletext, all three SCTE-35 PIDs —
while the video path resynchronised through identical corruption. For a contribution feed that is the
wrong way round to fail.

**Why the report was strong rather than marginal**, and this generalises to reporting into any
upstream project:

- A **deterministic minimal reproducer** with no timeline discontinuity of any kind: one valid MP2
  frame, then a second with its sync word changed from `0xFF` to `0xFE`, same PID, monotonic PTS, no
  loop. A single flipped bit is sufficient.
- A **one-line root cause**: the legacy-audio PES loop propagates a header-parse failure straight out
  of the demuxer with `?`. There is no attempt to scan forward for the next sync word, so a lost sync
  is unrecoverable by construction rather than by policy.
- A **documented design principle the behaviour contradicts** — the module's own doc comment says
  malformed input is *"rejected, never mis-described"*, and resyncing to the next valid frame honours
  that exactly. Rejecting the damaged frame is right; killing the session is the part that does not
  follow.
- **Two in-repo precedents for the correct behaviour**: the TS container layer resyncs byte-wise with
  three tests pinning it, and the video path resyncs structurally through Annex-B start-code
  scanning — which is precisely why a video-only loop survives.

Reported as [#2729](https://github.com/moq-dev/moq/issues/2729), fixed by
[#2751](https://github.com/moq-dev/moq/pull/2751) within two days. The upstream change scans forward
to the next sync-word candidate and **confirms it before trusting it** — a frame is accepted only once
a second header parses exactly where the first says the frame ends, the same confirm-before-trust rule
the TS layer already applied. The scan is bounded at 64 KiB and only a *confirmed* frame resets that
budget.

**Verified here against both builds**, on three copies of a 20 s cut of a real 9.95 Mbps DVB capture
each differing from the clean original by **exactly one byte**:

| Arm | one-byte change | pre-fix | post-fix |
|---|---|---|---|
| MP2 header | sync `0xFF` → `0xFE` | **died at 12 s**, rc=1 | ran to end of file, rc=0 |
| H.264 start code (control) | `0x01` → `0x00` | survived | survived |
| Full A/V looped | none — `--infinite` wrap | **died at the first wrap** | survived 2+ wraps |

Comparing the damaged run against a clean control **by PTS set on every elementary stream**: exactly
one 24 ms MP2 frame dropped at the damage point, nothing published that the clean run did not publish,
and video, AC-3, teletext and all three SCTE-35 PIDs untouched. One damaged byte cost one 24 ms audio
frame instead of the whole broadcast.

The fix also reached a defect we had not found — AAC frames split across a PES boundary were never
reassembled at all, so a legal mux could kill a broadcast with no corruption involved.

**A correction to our own report.** The video+AC-3 row of the original table does not reproduce as
stated: re-run, the pre-fix build survived a looped video+AC-3 clip for 50 s. **A loop wrap is fatal
only when it splits an audio frame**, which is a property of where the cut falls, not of the codec.
The codec-generality claim rests on the unit reproducers and on AC-3 having the identical parse shape,
not on that row. The MP2 single-bit arm is unaffected and remains decisive.

### A splice publishes a *substituted* frame — closed, with two measured residuals

**A bit error and a splice are not the same defect, and closing the first left the second open.**
Where the damage is a corrupt byte, the parser rejects the frame and drops it. Where it is a *splice*
— a feed restarting, a dropped PES, a looping file wrapping mid-frame — the header is intact and only
the bytes after it are foreign, so the frame is published: **not a frame lost but a frame
substituted**, carrying audio from both sides of the discontinuity. That is the harder case to detect
downstream, because a substituted frame of the right length in the right place leaves the timeline
intact — no continuity error, no discontinuity flag, evenly spaced timestamps.

**Detection is decidable without a listening test.** A frame is *alien* if its bytes appear nowhere in
the source's audio elementary stream — a frame assembled across a splice is made of bytes from both
sides of it, so it can match nothing in the source. `ts-splice-audit.py` does exactly that.

Split out upstream as [#2802](https://github.com/moq-dev/moq/issues/2802) and first fixed in
[#2823](https://github.com/moq-dev/moq/pull/2823) by extending frame confirmation to a frame beginning
in a carried tail. **Tested here against real content, and the first fix changed nothing**: 3 alien
frames per audio PID before and after, same hashes, same positions, with the audio byte-identical
between the arms across three wraps. The reason is the finding rather than the null result — this mux
never splits an audio frame across a PES boundary, so the carried tail the fix guards is always empty,
and at the wrap the foreign bytes join the *same* truncated PES rather than the next one. The
confirmation *rule* would have caught it; it is the gate that misses.

**The route that does work was already in the stream and already implemented next door.** The wrap
breaks the transport continuity counter on every PID, and `SectionReassembler` in the same file
already drops its partial on a counter gap, a declared discontinuity or a transport error — for
private sections. The PES path never read the counter. Reported with that argument, upstream
reproduced it in-tree before touching anything and **rescoped the PR from one commit to five**,
generalising those continuity rules into a shared check applied to PES PIDs too. Merged; re-verified
here across four arms, and the mixed frame is gone from both audio PIDs on current `main`.

**Two residuals survive, both measured.**

- **The guard trusts one signal, so a counter-contiguous wrap is invisible again.** A cut whose last
  packet on a PID leaves the counter equal to the one the file opens with wraps contiguously — about
  one cut point in sixteen per PID, and 4,062 of 30,000 positions scanned do it for at least one audio
  PID. Cutting at exactly such a point puts the original bug back on merged `main`: 1 alien AC-3 frame
  per wrap, each rejected by its own `crc1`. **The guard is sound; its trigger is probabilistic on the
  one signal it consults.** A codec CRC would close it, and AC-3's rejects every mixed frame measured
  — but it cannot be the general answer, because 0 of this clip's 826 MP2 frames carry a CRC at all.
- **The salvage does not deliver what it promises, for AC-3.** On a break the truncated PES is meant
  to be flushed so the whole frames it already carried still publish. MP2 behaves that way — its 7
  complete frames publish before and after the fix. AC-3 does not: its 8 complete frames are published
  pre-fix and **absent from every wrap post-merge**, searched by hash across the whole capture. That
  is **~256 ms of good audio lost per splice on AC-3**, where MP2 loses nothing. Both PIDs take the
  same branch of the same match, so the asymmetry is downstream of it.

### A recovered stream is signalled nowhere — closed, exactly as asked, and it exposed a bigger gap

Reported as [#2798](https://github.com/moq-dev/moq/issues/2798), scoped to observability rather than
correctness. **Closed by [#3372](https://github.com/moq-dev/moq/pull/3372)** (merged `d554c75d5`),
which implemented both halves of the ask and nothing else: a `tracing::warn!` on a *completed* resync,
and per-PID counters on `Import::stats` — `resyncs`, `discarded`, `unconfirmed` — documented as "the
counters an operator alarms on … what an operator alarms on is the rate". No protocol change, as
predicted.

**Verified independently.** [T24](test-24-partial-media-plane-stall.md) suppressed the audio
elementary streams of a live feed for 60 s and the publisher emitted, unprompted:

```
WARN moq_mux::container::ts::import: audio stream lost frame sync and resynced pid=121 track=".mp2" discarded=466 resyncs=1
```

That is the whole ask, working, on a stimulus built for a different experiment.

**Two residues, and the second is now the architecturally important one.** The warning fires on
*recovery* rather than on the outage, so it is late by the outage's duration — right for "this feed is
losing audio", not for "audio is off air now". And **it exists for audio only**: T24 measured a 57 s
absence of *video* access units through the same importer and it produced no log line, no counter and
no stats entry, because `Stats` is an audio-frame-sync structure by design. Since the importer already
parses every elementary stream in order to demux it, it is the one component in the chain that knows a
track has gone quiet for free — and, unlike a relay forwarding an opaque payload, it is structurally
able to. **Filed as [#3489](https://github.com/moq-dev/moq/issues/3489)**, scoped as an extension of
the surface #3372 created — `StreamStats` over every elementary stream plus a last-access-unit
liveness figure — and explicitly not a behaviour change. Verified before filing that `import.rs` on
`origin/main` carries no video liveness signal (four `warn!` sites, none of them one) rather than
inferring it from log silence, and linked to [#1838](https://github.com/moq-dev/moq/issues/1838) as
the monitoring parent. Implemented in two PRs, both merged: § *Per-stream liveness in the TS
importer*, below.

The original report, kept because it is what #3372 answered:

The subscriber's TS after a resync carries **0 continuity errors** (identical to the clean control),
**0 signalled discontinuities** on any PID, and an audio timeline that simply steps 24 ms → 48 ms
across the hole. Nor is it visible above the TS: the resync path emits no log call at any level,
exposes no counter, and does not touch the discontinuity counter that already exists for timeline
rewinds. The upstream doc comment states the policy deliberately, so the silence is intended rather
than an oversight.

**A TR 101 290 monitor at egress therefore sees a fully conformant stream with no indication that
anything was lost.** For an architecture that treats the ingest edge as the place where a contribution
feed's defects are absorbed ([Architecture](../docs/architecture.md) §6.2), **the absorbing needs to
be observable.**

Two things sharpen it. The splice case was worse while it stood — a *substituted* frame leaves no
evidence at all, where a dropped frame at least shows in a frame count — and #2823 turned the
substitution back into a gap while leaving the reporting half untouched. And **the 1+1 worry does not
survive measurement**, which is worth saying: two importers fed the same damaged source dropped
precisely the same frame, so the resync is deterministic on identical input and this is not a
redundancy risk. What remains is narrower and still real: **the fix converted a maximally loud failure
into a completely silent one.** Our own source was only discovered to be wrapping mid-frame *because*
it crashed 216 times; the same condition now produces a stream that looks healthy. The ask was a
warning on a completed resync and a counter to alarm on a *rate* of them, neither of which touches the
protocol — and that is precisely what shipped.

### Per-stream liveness in the TS importer — contributed as [#4502](https://github.com/moq-dev/moq/pull/4502) and [#4506](https://github.com/moq-dev/moq/pull/4506), both merged

**The defect.** This is #3489, as filed above. `Import::stats` had a row only for audio that had lost
frame sync, so a video, Opus, verbatim-PES or SCTE-35 PID had none, and an absent row meant healthy. The
upstream quest (`quest/m1/3489-ts-import-stream-liveness.md`) fixed the shape of the answer. Every
elementary stream gets a row with an access-unit count and the gap since the last unit, measured on the
transport clock. There is no threshold, and the catalog `stalled` bit is untouched. A second quest
(`quest/m1/srt-import-stats.md`) asked for the same rows from the SRT gateway, which read none.

**The contribution.** #4502 gives every carried elementary stream a `StreamStats` row: H.264, H.265,
AAC, Opus, MP2/AC-3, verbatim PES, SCTE-35 and other private sections, and MPEG-1/2 video read only for
its clock. Each row has `units`, the access units delivered, and `quiet`, the transport time since the
last one or since the PMT declared the PID. `quiet` runs on the PCR rather than on the importer's media
clock, which follows the video PTS and so stops with the very stream it has to catch. The PCR is summed
one interval at a time, and a step over the mux-rate meter's 1 s bound adds nothing. Without that bound,
one corrupt PCR would add hours of silence to every PID, the failure [T27](test-27-liveness-detector.md)'s
detector hit. `moq import ts` samples the stats once a second and logs `elementary stream stopped
delivering access units` once per silence. The line keys on the count, not on `quiet`. #4506, stacked on
#4502, moves that logger into `moq-mux` as `ts::StatsLog`, and has the SRT publisher sample it at the
same cadence under an `srt{path=…}` span, so a server carrying several ingests names the one affected.

**Verification**, P0, on the PR builds before merge: in-process tests on fixture files, with no wire and no cross-host
run. The stimulus is #3489's. One PID's PES is suppressed for a window, its PCR is kept in
adaptation-only packets, the other packets become null stuffing, and continuity is renumbered. A check
asserts that the result keeps the fixture's length, PCR sequence and per-PID continuity-error map. The
arms suppress HEVC video and MP2 audio from 1.5 s to 3.5 s, and SCTE-35 from 2.5 s to 3.5 s. In each
arm the count stops across the window where the unsuppressed control advances, `quiet` grows within
50 ms of the elapsed program clock, a peer stream keeps counting, and the stream recovers afterwards.
For SRT, the fixture is fed as 1316-byte payloads paced on paused time, once intact and once with its
video suppressed. Only the suppressed feed's video PID is logged, and removing the sampling from the
publisher makes the test fail. There is no *before* figure, because `main` has neither the fields nor
the rows. Upstream CI passed on #4502. #4506's local gate ran a scoped equivalent of `just check`,
which passed, rather than the full workspace test pass, which the shared disk could not hold.

**Open.** Both are merged on `main`: #4502 as `395a92cbd` and #4506 as `c2e7b5815`. No threshold and
no TR 101 290 `PID_error` counter exists yet. The monitoring plan
[#4496](https://github.com/moq-dev/moq/pull/4496), since merged as a quest, adopts these rows as that
check. If the PCR PID itself
stops, every `quiet` freezes instead of growing. The CLI and SRT lines still fire, because they compare
counts, but a consumer reading `quiet` alone would miss it. A sparse stream such as SCTE-35 is logged as
stopped between cues, by design. Neither PR has run against a live feed; the arm that would settle that
is T24's 60 s video suppression, repeated on the PR build.

### Per-stream liveness at the TS exporter — contributed as [#4577](https://github.com/moq-dev/moq/pull/4577), merged

**The defect.** This is the egress half of [#3489](https://github.com/moq-dev/moq/issues/3489). In
[#3533](https://github.com/moq-dev/moq/issues/3533), video and primary audio stalled at the
exporter while PSI and the other PIDs kept flowing and the relay kept transmitting, and only
[T27](test-27-liveness-detector.md)'s per-PID detector on a subscriber found it. `Export` reported
nothing per PID. The upstream quest (`quest/m2/ts-export-liveness.md`, planned in
[#4496](https://github.com/moq-dev/moq/pull/4496)) settled the shape: the importer's rows at egress,
with `quiet` measured on the output's own PCR, no ETSI counters, and no window in-tree. It also listed a
stale attribution. The exporter's comment and the `test/ts` graders' defaults gave TR 101 290 a 40 ms
PCR repetition limit, where V1.4.1 sets 100 ms; its Note 2 records that the 40 ms precondition was
removed from TS 101 154 in 2005.

**The contribution.** `Export::stats` returns `ts::Stats`, one row per elementary stream in the PMT. Each
row is named by the track suffix an import of the output would give that PID. The exporter runs the
importer's own liveness meter on the PCR it writes, reset wherever it flags a discontinuity. `units`
counts the PES or section written for each frame, credited when the span leaves the mux buffer, so a
rewind does not count what it discards. The frame-sync counters stay zero. `moq export ts` samples the
stats once a second through the same logger `moq import ts` uses. The PR also moves the `test/ts`
repetition defaults to 100 ms, and replaces the README's "VBR, no null packets, PCR once per frame" with
what the exporter does now: it pads to the recorded multiplex rate and writes a PCR every 25 ms of media
time.

**Verification** `[unmerged]`, P0 and P1. At P0, two in-process tests cover H.264 plus two AAC tracks. A
healthy export advances every row, each quiet for under 200 ms. With video and one audio track stopped
halfway through a 6 s run, those two rows freeze and their `quiet` reaches 2.975 s and 3.0 s of the 3 s
stall, while the surviving audio's row keeps counting and the PAT keeps repeating. At P1, `CNNiEMEA2.ts`
was PCR-paced into `import ts` on a local relay, with the MP2 PID dropped about 19 s in by
`tsp -P filter --negate --pid 121 --after-packets 132000`. `export ts` logged `pid=121 track=".mp2"
units=729 quiet=Some(850ms)` once, about a second after the publisher's own line for that PID. In the
capture, PID 121 falls to zero PES starts per 5 s after the drop, while the PAT (13–15 per 5 s), video,
AC-3 and teletext hold their rates. There is no *before* figure, because `main` has no egress rows.
The local `just check` and the four `test/ts` arms passed, and so did upstream CI.

**Merged** into `main`, with the maintainer deleting the quest it implemented. The verification above
ran on the PR before the merge of `main` into it and has not been repeated on the merged build.

**Open.** Sparse SCTE-35 PIDs flap in
the shared logger at its 1 s interval, somewhat more at egress than at ingest (21 lines against 16 over
the same run), where the exporter delivers by group. Picking a window is left to a consumer that names its
monitoring point. A whole-programme stall is not reported at egress: the output PCR stops with it, so
every `quiet` freezes, and the CLI samples only when a frame goes out, so no line is logged. That stays
the job of the wire monitoring downstream. The corrected default loosens `pcr-value-interval`, a hard
check, from 40 ms to 100 ms, so a regression that spaced PCRs between the two would now pass by
default. Nothing has run against a live feed cross-host.

---

## 3. Resilience and redundancy

### The exporter died on session loss — closed

`moq export ts` exited the instant its session dropped, which was the single most consequential
transport-resilience gap for primary distribution, since a broadcast subscriber must ride out relay
maintenance unattended. The reconnect loop stayed alive; the sink task was fatal, so the process died
with `json: dropped` while nominally supervised
([#2459](https://github.com/moq-dev/moq/issues/2459)). Closed by
[#2469](https://github.com/moq-dev/moq/pull/2469) (broadcast *linger*): the relay keeps the broadcast
announced for the reconnect window and a re-attaching source splices back into the same broadcast,
while a clean unannounce still tears down immediately. Measured surviving a relay kill and restart,
resuming byte-identical output automatically.

[#2647](https://github.com/moq-dev/moq/pull/2647) tightened it further, so the exporter re-attaches
within seconds of a relay returning while a genuinely *dead* relay errors in tens of seconds instead
of retrying silently — the axis that matters for a supervisor deciding to re-home a subscriber.

### A cancelled write dropped bytes and said nothing — closed, in a different repository

Exporting over the WebSocket fallback transport produced a flood of `WrongSize` / `FrameTooLarge` group
evictions and then killed the process, while the identical broadcast over QUIC on the same path was
clean. Reported as [#2265](https://github.com/moq-dev/moq/issues/2265) as two defects rather than one,
because a framing fault and a fatal-on-one-bad-frame fault warrant separate fixes.

The framing half root-caused out of `moq` entirely. `SendStream::write_buf` removed bytes from the
caller's buffer and *then* awaited queue capacity, so dropping that future stranded the chunk: gone
from the buffer, never queued, no error raised, the stream finishing cleanly **with a hole in the
middle** that the peer decodes as a truncated or garbage frame
([moq-dev/web-transport#323](https://github.com/moq-dev/web-transport/pull/323)). Callers hit it
constantly rather than rarely, because the publisher races `write_all` against a priority-change
channel that fires on every group boundary of every track while the outbound queue holds eight frames
for a whole session — so on a link slower than the broadcast, the write is always parked and the cancel
window is always open.

**The trigger is egress backpressure, not WebSocket.** The fallback transport is only where this rig
was slow enough to see it, which matters for reading §6: a client that abandons QUIC on a 200 ms timer
lands on the transport where a corrupt frame was reachable. Both halves of the report closed with that
fix — with the corrupt frames gone there was nothing left to be fatal about — so the resilience half
was never addressed on its own terms. §2's audio work is the part of that argument that did land.

### Active/active source failover — shipped, bounded

**The problem as found.** Two publishers announcing the same broadcast to one relay did not form a
standby pair: the moment the second announced, the relay declared the path unroutable and tore down
**both**. Across a two-relay mesh the pair coexisted but never failed over — graded well beyond one
full idle timeout, so this was the mechanism and not the detection budget.

The relay's forwarding core already contained a multi-source route table with a `reselect` path
covered by a unit test; the drill never reached it. What was missing was the *selection* rule that
makes a relay offer a peer a route other than the one it is already serving through.

[#2473](https://github.com/moq-dev/moq/pull/2473) (issue
[#2461](https://github.com/moq-dev/moq/issues/2461)) supplies it: per-peer announce selection
advertising the best route whose hop chain *excludes* the requesting peer, exclusion-aware serving,
first-hop content identity declared in SETUP rather than inferred per announce, and a
`moq --origin <id>` knob so a 1+1 pair declares itself interchangeable — explicitly, because the relay
is content-agnostic and will not infer it. [#2629](https://github.com/moq-dev/moq/pull/2629) later
generalised the same routing policy to the IETF draft-17+ path.

Cost routing alone ([#2424](https://github.com/moq-dev/moq/pull/2424)) could not close it: with both
relays and all clients opted in, the mesh behaved exactly as before, because **pricing decides between
the routes a relay is willing to offer and does not create one.**

**What remains open.** A graceful source exit is not failed over at all: the relay propagates
completion and the subscriber terminates, because it cannot distinguish "this source is done, and so
is the content" from "this source is done, but an interchangeable one exists". This reads as intended
semantics rather than a defect — it is covered by upstream's model tests — but failover then covers
the *harder* failure mode (host loss) and not the easier, far more common one. The remedy is semantic
and is specified in [#2610](https://github.com/moq-dev/moq/issues/2610) as a publisher-minted epoch
plus an explicit `Ended` flag. **Specified, not shipped.**

**On the build under test the failover picture has moved, and both new findings are reported.**
`ffa5b81b` renamed the knob to `--hop <id>` and refuses `--origin`. On one relay two publishers now
coexist and a hard kill fails over within the idle timeout; in the mesh a hard kill fails over for the
dead publisher's relay, bounded by the later of detection and the standby's group lag
([T6](test-6-relay-resilience.md) § *Single-relay standby on the current build*, § *Mesh source
failover*).

- **A shared-hop standby that arrives after the subscribers ends every one of them with `not found`
  — reported as [#4352](https://github.com/moq-dev/moq/issues/4352).** Identical routes rank by
  recency, the front switches to the newcomer before it has created its tracks, and each track's
  `NotFound` from it is recorded as an authoritative refusal. It is the race the mesh drill once
  found as `Unroutable`, back on these builds on one relay and in the mesh: two of two runs on one
  relay on `ffa5b81b`, two of two on `main` at `2b689c24`, and on the standby's relay in the mesh ten
  of ten on `ffa5b81b` and twelve of twelve on `main`, with the code path cited in T6. In the one run
  where the publishers arrived together it did not occur. **Open**; the before/after verification is
  owed when a fix lands.
- **A fast switch to a same-hop standby ends `export ts` with `TimestampRewind`.** On `ffa5b81b` a
  SIGINT made the relay move to the standby and the exporter abort. On `main`, where the CLI closes
  the session on SIGTERM as well, every clean exit (SIGINT, SIGTERM, end of input) is switched at
  the signal and aborts the exporter: six of six, whether the publishers started 2 s apart or
  together. A diagnostic exporter shows what it is handed at the switch: the standby's groups under
  higher sequence numbers than the last one read, carrying media from 0.17–5.6 s before the live
  edge, co-started or not (T6 § *What the exporter is handed at the switch*). **Reported as
  [#4354](https://github.com/moq-dev/moq/issues/4354)**, with the mesh splice floor included as
  the converse case. On `main` that converse case is fatal too: in the mesh, every splice that
  waited for the standby's numbering to reach the floor ended relay A's exporters on the same
  live-edge error, 8 of 8, and only the two runs whose standby was already past the floor resumed
  (T6 § *Mesh source failover*). That this is the same check is inferred from the message; the
  diagnostic build was not run in the mesh. Why the two importers' numbering differs and why the
  relay hands over older media are not established. **Open**; the mesh result on `main` is on the
  issue, and so is the twelve-of-twelve on #4352.

Two more mesh findings on `ffa5b81b` are not reported separately. Without
a shared hop, the standby relay's own subscriber freezes silently at the failover; `main` no longer
fails over between publishers that declare no shared hop, which its front rules make deliberate, so
the freeze describes a configuration `main` does not offer as a pair. The splice floor, which makes
the standby's group lag add to the outage, is the group-sequence floor of #2534 met by a 1+1 standby,
and the maintainer's position on #2545 covers it; rather than a separate report it went into #4354
as the converse of the rewind, since both compare group sequence across two publishers.

### A multi-programme TS through `import ts` — reported

The importer scopes itself to single-programme input in a code comment, and a real MPTS shows what
that costs ([T10](test-10-mpts-multiservice.md)). On both builds the exporter flattens the multiplex
into one PAT entry and one PMT carrying every programme's streams, while the carried SDT and EIT still
list the other services. On `ffa5b81b` programmes on independent clocks abort the publisher with
*frame timestamp is below the live edge*. On `main` at `2b689c24` the same input completes with exit
0 and loses most of two programmes' video, and even on a common clock SCTE-35 and part of programme
1's audio are lost; programme 1 alone is clean. The ask is framed as "refuse an MPTS loudly, or
select one programme on purpose", not as MPTS support. Reported as
[#4353](https://github.com/moq-dev/moq/issues/4353). Bisected since: #3997 (every TS elementary
stream re-anchors below the live edge) removed the refusal, and #4122 (stdin imports publish on the
broadcast clock) introduced the common-clock loss, each against a directly graded parent. The
bisect is on the issue. The mechanism first offered for #4122, a section lane stepping back past
`MAX_REORDER`, was refuted by a dose run and corrected on the issue. The measured one is the lane
through which every programme's video advances the section clock: it steps back across programmes
and re-anchors the whole source forward on each step. A build that gives that clock one lane per
video PID removes every re-anchor and restores SCTE-35 and audio to the parent's level (T10 § *On
upstream `main`*). Upstream's planned default refusal of multi-programme input, and its removal of
the anchor, would each moot it; the A/B result is on the issue. **Open**; the before/after verification is owed when a fix lands,
on `mpts3.ts` and `mpts3-cc.ts` with the T10 rig.

### A selected programme still carried the whole multiplex's SI — contributed as [#4580](https://github.com/moq-dev/moq/pull/4580), in review

**The defect.** [#4505](https://github.com/moq-dev/moq/pull/4505) answered the selection half of
[#4353](https://github.com/moq-dev/moq/issues/4353): `moq import ts --program <n>` imports one programme
of a multiplex, and `--program all` publishes each as its own broadcast. SI capture was left as it was,
so a selected programme's broadcast still carried the source's SDT actual and every service's EIT.
Measured on `main` at `6f1a9e33` with a three-service MPTS and `--program 1`, the `export ts` output
carries only programme 1's PIDs, yet `tsp -P analyze` counts three services, two of them with no PIDs,
and EIT present/following rides along for all three. A receiver scanning that stream finds two ghost
services. Taking one service out of a contribution multiplex is the primary-distribution case, so this
is the defect a distribution user meets first.

**The contribution.** The upstream quest (`quest/m2/ts-program-si.md`, planned in
[#4507](https://github.com/moq-dev/moq/pull/4507)) settled the shape, and the PR follows it. Under an
explicit selection, the importer's SI capture drops EIT actual sub-tables for other service_ids and
rebuilds each SDT actual snapshot as one section holding only the selected service's entry, with its
header kept and a fresh CRC-32/MPEG-2. A service the SDT does not list gets no SDT actual, a later SDT
version that drops the service retires the earlier one with its catalog entry, and a table filtered to
nothing gets no track. NIT, BAT, SDT other, EIT other and TDT/TOT pass through, and an import without a
selection is unchanged.

**Verification** `[unmerged]`, P0 and P1. At P0, five in-process tests use a synthetic two-service
multiplex whose SDT spans two sections. They cover each selected import (one SDT section, a valid CRC,
only its own EIT), the unselected import (verbatim), a selection the SDT does not list, retirement and
relisting across SDT versions, and a re-export that parses and re-imports to the same tables; four of
them fail with the selection disabled. At P1, a 30 s build of T10's `mpts3.ts`
([`make-real-mpts.sh`](scripts/make-real-mpts.sh): CNNi as programme 1, a video-only clip as 2, a
0.3 Mb/s AV clip as 3) was PCR-paced into `import ts --program <n>` on a local relay and captured from
`export ts`:

| Build | `--program` | `tsp -P analyze` | SDT actual lists | EIT p/f services |
|---|---|---|---|---|
| `main` `6f1a9e33` | 1 | 3 services, 2 and 3 without PIDs | 1, 2, 3 | 1, 2, 3 |
| #4580 | 1 | 1 service | 1 (one 59-byte section) | 1 |
| #4580 | 3 | 1 service | 3 (one 38-byte section) | 3 |

TSDuck decodes the rebuilt SDT, so its CRC holds, and its TSID and ONID match the source's. The local
`just check` passed, as did the `test/ts` default, real-capture and open-GOP arms, and so did upstream CI.

**Open.** The PR is in review. The `test/ts` `--pair` arm fails its NIT
and SDT/BAT anchor checks on `main` at `6f1a9e33` and on the branch alike: the grader attributes both
exporters' emission points to a timer started with each exporter rather than to the media. That arm is
not in CI and has no quest. Nothing has run against a live multi-programme feed or cross-host.

### A PSI table spanning packets, or one bad CRC, ended a TS ingest — contributed as [#4584](https://github.com/moq-dev/moq/pull/4584), merged

**The defect.** The importer read the PAT and PMT through the `mpeg2ts` 0.6.1 reader, which parses a
table from a single packet, rejects a nonzero `pointer_field`, and ends the import on any error. A
valid PMT too long for one packet (many audio languages, long descriptors), a PAT listing more than
about 40 programmes, or one flipped bit in a PAT repetition's CRC therefore ended `moq import ts`.
`--program all` found the PAT in a single packet too.

**The contribution.** The upstream quest (`quest/m1/ts-psi-reassembly.md`, planned in
[#4507](https://github.com/moq-dev/moq/pull/4507)) settled the shape, and the PR follows it. The
importer owns the packet demux: the PAT and every PMT go through the section reassembler already used
for SCTE-35 and SI, and the PAT, PMT and PES header are parsed in moq-mux. A section whose
CRC-32/MPEG-2 fails is dropped whole and the last good table stays in force; each drop counts in a
stream-wide `crc_error` in the importer's stats and is logged with the other counters. `--program all`
reads the PAT the same way.

**Verification** `[unmerged]`, P0 and P1. At P0, tests cover a PMT spanning two packets, a PAT behind a
nonzero `pointer_field`, a two-packet PAT of fifty programmes read by `--program` and by
`--program all`, a corrupt PAT and a corrupt PMT between good repetitions (each dropped and counted
once while the layout holds, a later PMT revision still applied), and a feed whose only PAT is corrupt
(nothing published, one drop counted). `decode` throughput on `kyrion_mpeg2av_ac3.ts` doubled: 876–894
MB/s on `main` at `6f1a9e33`, 1,780–1,815 MB/s on the branch. At P1, the `test/ts` default,
real-capture and open-GOP arms gave the same hard-check results on both builds, and two crafted
variants of the harness's ffmpeg clip were PCR-paced through the same rig:

| Clip | `main` `6f1a9e33` | #4584 |
|---|---|---|
| One bit flipped in the 20th PAT's CRC | publisher exits after 0.5 s: *CRC32 mismatch* | one section dropped and counted; every check passes |
| PMT padded to 226 bytes, two packets | publisher exits at the first PMT: *failed to fill whole buffer* | imports to the end; `export ts` then fails (below) |

The local `just check` passed, as did upstream CI.

**Merged** into `main`. Before merging, the maintainer changed how `--program all` hands the PAT to
each programme's importer: the scanner now seeds each importer with the assembled table instead of
replaying the bytes it held, which closes three review findings. The verification above predates that
change and has not been repeated on the merged build.

**Open.** The exporter still writes the PMT through `mpeg2ts`, which
cannot emit a section longer than one packet (*failed to write whole buffer*), so a long PMT now
imports but does not round-trip; it is left for upstream planning. Sections dropped for other reasons
(a malformed adaptation field, a parse failure) are not counted yet, since the TS import health quest
owns `PAT_error` and `PMT_error`. Nothing has run against a live feed with long PSI.

### Three values the exporter mints per process — one closed, one declined, one open

A 1+1 pair cannot be byte-identical while the exporter renders anything from its own process state
rather than from the broadcast. Three such values were isolated ([T12](test-12-dual-path-handoff.md)):

- **SI emission cadence**, anchored to process start, landed tables on slots where the partner carried
  video: measured at **0.00 %** frame agreement for SDT and NIT over a 45 s overlap. Fixed by
  [#2825](https://github.com/moq-dev/moq/pull/2825), which takes a single-track pair to 100 %. The
  review mattered: the form first proposed inflated PSI (PAT 1,959/1,946 across two legs against
  111/111 for the merged form) and **landed inconsistently, costing 5.9 points of agreement** — a
  one-character change from `!=` to `>` in the due check, which stops a backwards timestamp counting
  as a new slot. **It merged in the `>` form, changing its own measured result**, which is the
  argument for treating unmerged-code evidence as provisional. **A residual survives the fix and is
  now measured**: #2825 moved the cadence from wall-clock into media time, but its *origin* is still
  the first frame the exporter saw, so two legs that join at different moments run the same period at
  different phase and never coincide — see *The residual #2825 left* below.
- **Continuity counters**, numbered from process state, leave exporters that did not start together
  permanently offset by a constant — the single field whose masking lifts agreement to ~98 %. Filed as
  [#2779](https://github.com/moq-dev/moq/issues/2779), and prototyped here rather than only
  described: restarting each PID's counter at the video keyframe boundary and padding every span to a
  multiple of 16 packets takes the same pair from 0.4 % to 99.9 % identical on single-track content
  and from 24.6 % to 93.6 % on multi-track, with both legs continuity-clean. The cost is small in
  aggregate and regressive in detail — 1.5–1.7 % of packets, but **10–18 kb/s per PID almost
  regardless of what that PID carries**, because a PID emitting one or two packets per group is nearly
  always 14 or 15 short of a multiple of 16.
  **Declined upstream.** [#3868](https://github.com/moq-dev/moq/pull/3868) closed the issue and deleted
  its quest; the PR body records the decision as *"2779 is abandoned (close #2779 as won't-fix on
  merge)"*, and the replanned #2829 quest states the reason — *"a late-joining exporter cannot know the
  packet count of every earlier group, so per-process counters stay"*. GitHub shows the issue as closed
  *completed*, which is the mechanical state and not the decision. No code changed: `Export::counters`
  on `615d166d` is still `HashMap<u16, ContinuityCounter>` filled by `entry(pid).or_default()`, so the
  measurements above stand against current `main` and are not at risk of going stale. **The consequence
  for this campaign is that byte-identical 1+1 from two independent exporters is not obtainable from
  upstream and will not become so**; it needs the padding filter above, or a receiver that merges on
  something other than the whole packet.
- **Audio/video interleave**: the exporter emits the earliest *available* frame rather than the
  earliest frame, so legs whose bytes arrive at different moments order the same media differently.
  Multi-track content therefore stops at 94–96 % even when co-started, and at 75.56 % once the two
  chains are fully independent. Filed as
  [#2829](https://github.com/moq-dev/moq/issues/2829). **Fixed by
  [#4001](https://github.com/moq-dev/moq/pull/4001)**, verified below (§ *#2829 and #3948, closed by
  #4001*). The counter fix above was conditional on it: the counter becomes an index within a span,
  so wherever the legs order media differently the renumbering diverges with it.
  **Now measured on fully independent chains and posted to the issue.** A publisher, relay, exporter and
  groomer per host across two availability zones, sharing nothing but a verified-identical source file:
  a single-track feed is byte-identical on all 46,778 shared datagrams, and a seven-stream mux over the
  same topology reaches 75.56 %. The legs carry the *same packets in a different order* — every media
  PID has an identical packet count, 99.9528 % of packets are common as a multiset, and 98.414 % align
  once displacement is allowed. Re-read against `main` `5eea9e3c8`, `pick_next_track` takes the minimum
  of `(timestamp, pid, name)` over the tracks that have a *pending* frame, so the tiebreak is
  deterministic and the candidate set is not. The invariant was stated as a requirement — the emission
  order should be a function of the media timeline — with the design left to the maintainer.

### The residual #2825 left, and the measurement that can see it — contributed as [#3947](https://github.com/moq-dev/moq/pull/3947)

The maintainer asked for exactly one thing on [#2825](https://github.com/moq-dev/moq/pull/2825), and
said why nothing in-tree could supply it: the two late-join tests there compare two exporters *inside
one process* over a synthetic broadcast, so both legs inherit one start point and the tests are blind
to anything keyed to it. He asked for a measurement that works against a real stream, runnable
against `test/smoke/` fixtures so it could be a gate rather than a one-off.

`test/ts/table-anchor.py` plus a `run.sh --pair` mode is that measurement, ported to the repository's
shape. `--pair` subscribes twice against one broadcast with the second leg joining late — the late
join is the whole point, since two exporters started together can agree on a cadence by having
started together. The statistic is the PTS of the frame each table was emitted against, and
**agreement** is the emission points both legs used over those either used, counted only inside the
media time the two captures share so a late join costs nothing.

**It separates the tables that are anchored from the one that is not.** On a 30 s round-trip with the
second leg joining 8 s in, PAT and PMT reach 94.37 % agreement, while SDT reaches 0.00 % — both legs
running a 2.005 s period, 0.512 s out of phase. It reproduces at other join offsets (6 s in: 5.26 %
at 0.480 s of phase), and the offset is simply wherever the second exporter started.

**This is a residual of #2825 rather than a regression of it.** The fix moved the SI cadence from
wall-clock into media time, which is what made a single-track, same-start pair reach 100 %. It did
not move the cadence's *origin*, which is still the first frame the exporter saw. Two legs that join
at different moments therefore run the same period at different phase, permanently — no amount of
running time brings them together, which is what distinguishes this from a settling transient.

The defect is filed separately as [#3948](https://github.com/moq-dev/moq/issues/3948), so the PR
stays a test contribution and the product decision has its own thread. No fix was proposed with
either. SDT is the one table in this set with no natural media anchor, which is plausibly why it
ended up on a timer at all, so where that cadence should be anchored is upstream's call — the
issue sets out three options and says plainly that accepting the divergence and documenting it is
a legitimate answer. The mode is opt-in and no CI arm invokes it, so nothing turns red while that
is decided.

Grader validation, since a comparison tool that cannot fail is not evidence: a capture graded against
itself gives 100 % on every table, and nulling every second PAT/PMT emission on one leg drops those
two to 50.60 % and 51.63 % and fails while the untouched tables stay at 100 %.

**Merged 2026-09-23 as `d571aed2`, and it reports the defect from inside the tree.** Run as
`test/ts/run.sh --pair` on `ffa5b81b`, against the harness's own generated clip with the second leg
joining 5 s in and a 40.5 s shared media window:

| Table | Anchored? | Agreement | What the grader says |
|---|---|---:|---|
| PAT | yes | **97.58 %** | — |
| PMT 0x1000 | yes | **97.58 %** | — |
| SDT/BAT | **no** | **0.00 %** | both legs emit every 2.000 s, 0.261 s out of phase — *"a timer started with the exporter, not an anchor in the media"* |

The figures are the same phenomenon as the pre-merge run at a different join offset, which is what
the mechanism predicts: the period is identical between legs and the phase is wherever the second
exporter started. [#3948](https://github.com/moq-dev/moq/issues/3948) was then fixed by
[#4001](https://github.com/moq-dev/moq/pull/4001), which puts unchanged SI repeats on the media-time
grid; on the same gate and the CNN clip, SDT/BAT reads 90.91 % (§ *#2829 and #3948, closed by #4001*).

### A takeover livelock — closed

A relay could stay *running* and stop *serving*: a livelock pinned every worker thread inside one
poll, leaving the process alive at 100 % CPU with no logs, no health endpoint and no accepts for
hours, triggered by cluster peer churn. Fixed by
[#2701](https://github.com/moq-dev/moq/pull/2701). The operational lesson outlived the fix and is in
[Architecture](../docs/architecture.md) §9.1: **relay monitoring must test liveness rather than
process existence.**

### A drill offered, and the coverage that landed instead

The two method rules the redundancy work produced — grade beyond one full idle timeout, and never
start a redundancy test's sources independently — were baked into an end-to-end drill offered upstream
as [#2545](https://github.com/moq-dev/moq/pull/2545) (`just test failover`): two real relays, real
publishers whose tracks the demuxer creates lazily, the QUIC idle timeout in the loop, and a
load-bearing third subscriber that forces one relay to carry the broadcast via the other, without which
the interesting case never arises. It generates its own source clip, so it depends on no private
capture.

**It was declined, and correctly**: upstream had by then covered the same behaviour with model unit
tests, which run on every PR where a hand-run drill never does. The drill's value transferred anyway —
run against the tree it reproduced our out-of-band numbers (resumption 14 s after killing the active
publisher at a 10 s idle timeout, against ~11 s measured here, so detection dominates and the reselect
itself is essentially free). What did land is
[#2713](https://github.com/moq-dev/moq/pull/2713), which takes the drill's one load-bearing insight
into those unit tests: every takeover, linger and reselect test subscribed to a *single* track, so
nothing pinned that a reselect is decided and served **per track**. A broadcast contribution feed is
multi-track by construction, and a takeover that re-splices video while audio silently stalls is a
partial recovery a single-track test cannot tell from a whole one. Two tests, no production changes,
with deliberately unequal group counts so the per-track resume boundaries differ.

**Two of our four reports from that work were artefacts of our own harness**, and both are recorded
with their method rules in [method-notes](method-notes.md) §1 and §5. That ratio is worth stating
openly: a drill that finds bugs in the system under test will also find bugs in itself, and telling
them apart is most of the work.

---

## 4. Congestion control

The loss collapse this campaign measured under QUIC's default CUBIC was reported into the discussion
on [#2432](https://github.com/moq-dev/moq/pull/2432), which exposes
`--server/client-quic-congestion-control {loss|delay}`. Upstream has since made **BBRv1 the default on
quinn** ([#2468](https://github.com/moq-dev/moq/pull/2468)), with the defaults now backend-specific —
quiche to BBRv2, and noq back to CUBIC because BBRv3 carries a subtract-overflow panic under high loss
([noq #768](https://github.com/n0-computer/noq/issues/768)).

**Upstream methodology guidance, adopted here:** the one meaningful congestion-control test is
bufferbloat under a shaped bottleneck, not random loss — *"the best congestion control in the face of
random loss is zero congestion control"* — so the CUBIC-collapse result is about **loss-signal
interpretation**, not congestion-control quality. That is why
[T8b](test-8b-congestion-control.md) exists and why its results are scoped the way they are.

The open question put back to the maintainer on #2432 is whether BBRv2 on quiche is a first-class
supported choice for a permanent fixed-rate trunk, or whether the quinn-BBRv1 intermittency observed
under a shaped bottleneck is a fixable bug. **Unanswered, and one under-provisioned condition is not
enough to press it.**

### The subscriber dies under contention — reported, fixed on the media path, then on the catalog track

[**#3491**](https://github.com/moq-dev/moq/issues/3491) — ***closed 2026-09-08*** by
[**#3515**](https://github.com/moq-dev/moq/pull/3515), one day after filing. **That fix was
incomplete**: the same failure reproduced through the catalog consumer, was re-reported as
[**#3897**](https://github.com/moq-dev/moq/issues/3897) and closed by
[**#3907**](https://github.com/moq-dev/moq/pull/3907) — both within the same day — and the residual
is verified closed here (see the end of this section). `moq export ts`
exits with `Error: hang: moq error: old` when two subscribers pull separate broadcasts through one
relay across a shared, under-provisioned bottleneck.

**The cause was in `moq-net`, and it was a cursor confusion.** `GroupState::poll_finished()` returned
the group's final frame count as soon as the *producer* finished, even if that particular consumer had
not read that far. When retention later aborted the finished group to release its cached frames,
`moq-mux` had already been told the group ended cleanly — so the `Old` read error that followed
propagated out of the export instead of being understood as an eviction. The fix makes
`Consumer::finished()` answer for its own read cursor, keeps the producer's total on `frame_count()`,
and lets the container consumer skip transport eviction (`Old` or `Lagged`) while still propagating
genuine payload decode errors. No wire or API signature change.

**Verified here incidentally but at much larger scale than the report.**
[T26](test-26-cross-host-fanout.md) put **450 subscriber sessions** through cross-host fan-out on a
build containing #3515, including two episodes where per-subscriber delivery fell to 3–37 % of nominal
for 45 s — deeper and more sustained eviction pressure than the two-flow contention that produced the
original exits. **No session exited with `Old`, or with any error at all**; the only process exits
anywhere were the subscriber host's OOM kills, which are a property of the rig. This is not a designed
regression test and is not claimed as one, but it is a stronger load than the reproduction. On the current released pair (`moq` 0.9.15 /
`moq-relay` 0.14.14) it takes **6 of 8 cells and 7 of 16 subscribers**; one cell lost both subscribers
16 s apart. Every graded capture has **0 continuity errors**, so what a downstream monitor sees is a
perfectly conformant stream that simply stops — a transport-side instance of the silent-failure class
[T24](test-24-partial-media-plane-stall.md) is about. A *steady* shortfall does not cause it (0 of 12
single-flow cells at 36 % of the required rate, despite thousands of evictions), so the condition
appears to be flows competing rather than a flow starved.

The report deliberately does not name a cause, and the reason is a correction. **An earlier draft
attributed this to [#3271](https://github.com/moq-dev/moq/pull/3271) and was withdrawn before filing.**
It was built the right way — isolating one-file merge-base pair, single relay binary, interleaved
replicates — and reported 6 of 14 cells against 0 of 14, p ≈ 0.016, deaths clustered at 54–57 s, with a
mechanism traced through the client's own log. Two faults made that split:

- **The death detector read one of each cell's two subscriber logs.** Re-reading every log gives 9 of
  15 against 3 of 15, p ≈ 0.060; all three pre-arm deaths sit in `sub.2.log`. The same re-read finds
  the exit in a cell recorded months earlier, on a client predating #3271.
- **The relay was pinned to a July build** while the mechanism runs through relay group eviction. A
  crossed 20-cell matrix gives 6 of 10 pre against 5 of 10 post — no client-side effect at all — and
  eviction counts that differ by two orders of magnitude between relay versions without the exit rate
  following them.

So #3491 reports the reproduction and the crossed matrix, and offers the `poll_read` propagation path
explicitly as a lead a maintainer may discard. **Nothing about the withdrawn result's shape betrayed
the error** — it was significant, tightly clustered and mechanically explicable — which is why both
method rules it produced are recorded in [`method-notes.md`](method-notes.md) §1.

**The residual was on the catalog track, and it is now fixed.** Re-run as its own experiment with a
pre-fix build as a positive control ([T8b](test-8b-congestion-control.md) § *#3491 survives on the
catalog track*), three concurrent flows:

| arm | container fix | catalog fix | exited | message | track |
|---|---|---|---:|---|---|
| `moq 0.9.15` (`046893254`) | no | no | 4 / 15 | `hang: moq error: old` | media container |
| `moq 0.11.2-615d166d`, `84b34f54` | yes | no | **1 / 15**, **1 / 10** | `json: old` | `catalog.json` |
| `moq 0.11.2` (`53f8aa99d`) | yes | **yes** | **0 / 10** | — | — |

`#3515` gave the *container* consumer a skip for an evicted group and corrected `moq-net`'s cursor so
it triggers. `moq export ts` also reads a **JSON catalog track**, whose consumer had no such skip:
`moq-json`'s error type declared `Net(#[from] moq_net::Error)` as `#[error(transparent)]`, so a lost
catalog group propagated out unclassified and unlogged and exited the process. On a snapshot track
`Error::Old` means *the value you hold has been superseded* — the correct response is to take the
newer group, not to terminate.

**Reported as [#3897](https://github.com/moq-dev/moq/issues/3897) and closed the same day by
[#3907](https://github.com/moq-dev/moq/pull/3907)**, which took both asks and went further than
either: the snapshot consumer now discards a group it cannot finish and waits for the replacement,
covering `Old`, `Evicted` and `Lagged` rather than only the reported `Old`; the discarded group is
logged, as are the container consumer's equivalent sites; and the same treatment was extended to
`moq-binary`, which had the identical unguarded path and was not in the report. Two regression
tests were added, one for the lost group and one for a lost group on a finished track.

**The verification is consistent with the fix and does not establish it on its own.** The re-run
put `53f8aa99d` against `84b34f54` in the same session on the same rig; the control reproduced
`json: old` and the fixed arm recorded nothing. But 0 of 10 is also the commonest outcome of an
unchanged build at this event rate, so the weight sits on the conjunction — closed code path,
upstream regression tests, and a control that still provokes the condition on demand — rather than
on the count. **Method rule: a low-rate failure needs its control in the same session, and a null
against it is corroboration rather than proof.**

A registered prediction was also tested and **failed**: exits do not fall monotonically with the
drift budget (6/9 at 500 ms, 4/15 at 2 s, 3/9 at 8 s on the pre-fix build), so the budget aggravates
the failure without explaining it, and the frame-expiry hypothesis is not supported.

**A second exit on the same track, when the publisher goes away, was filed as a question rather than
a defect**, and is tracked in § *The liveness exit* and § *Four of these were closed as completed*.

### The qlog loss trigger is computed backwards — fixed in quinn, PR open on noq

Both QUIC stacks the lane has run on label every declared loss in their qlog by the reordering
threshold, whichever rule fired. The trigger is computed as
`time_sent.saturating_duration_since(now) >= loss_delay`, which subtracts the present from the send
time, saturates to zero and is never true, so the `TimeThreshold` branch is dead. The line is
identical in `quinn-proto` 0.11.17 and on quinn's `main`, and in the noq fork (`noq-proto` 1.3.0); no
quinn issue about it was found. It cost the campaign a published attribution that had to be withdrawn
([T28](test-28-failure-injection-matrix.md) § *Corrections*). The fix is reversing the operands.
**Reported** as [quinn-rs/quinn#2895](https://github.com/quinn-rs/quinn/issues/2895) and pointed to
from [n0-computer/noq#825](https://github.com/n0-computer/noq/issues/825).

**quinn: fixed on `main`** by [quinn-rs/quinn#2896](https://github.com/quinn-rs/quinn/pull/2896),
with a regression test that forces one loss by each rule and reads the trigger back from the qlog.
The test fails without the fix, with both losses labelled `ReorderingThreshold`, and passes with it.
It is gated on the `qlog` feature, which quinn's PR CI does not enable. No quinn release carries the
fix yet: `main` is the unreleased 0.12 line, and `quinn-proto` 0.11.19, released after the fix
merged, still carries the reversed operands. So 0.11.17 through 0.11.19 labels are still unreliable.

**noq: PR open** as [n0-computer/noq#827](https://github.com/n0-computer/noq/pull/827). It has the
same fix, with the test adapted to noq's qlog factory and per-path statistics, and it fails and
passes the same way. noq's CI runs it, since its tests run with all features. The maintainers also
merge quinn's `main` into noq periodically, so the fix would arrive by that route too. Until one of
the two lands, `noq-proto` 1.2.0 and 1.3.0 labels are unreliable.

T28's attribution depends on neither, because it rests on the acknowledgement frames.

---

## 5. Relay memory

The relay retained memory in proportion to content carried — ~27–31 MB/hour on a 9.3 Mbps channel —
bounded by neither documented cache control. Reported as
[#2745](https://github.com/moq-dev/moq/issues/2745) with a controlled GOP pair confirming causation
(at identical bitrate and content, doubling the group rate doubled the slope: +31.22 → +62.30 MB/h,
ratio 1.995 against 2.000).

**Root-caused upstream within a day, and the correction is partly against us**: it is `quinn-proto`
recycling one receive-stream state, with its assembler chunk heap, per stream the connection has ever
accepted — **not moq state at all**. And it **plateaus** once every slot is filled, at ~100 MB above
baseline per publisher connection, reached after ~10,000 ingested groups. Every leg we had measured
was shorter than that knee, so the original "linear, 650 MB/day, fails the stability criterion"
reading was a measurement-window artefact ([method-notes](method-notes.md) §3).

Confirmed on our own rig afterwards: the slope holds for three windows and breaks in exactly the
window containing the predicted knee, at baseline + 108 MB against a predicted + 97 MB, with two
independent fits putting the per-slot cost at 9.14 and 10.54 KiB against upstream's predicted 9.9 KiB.
Two caveats the prediction did not cover: growth continues at ~8 MB/h past the knee rather than
stopping, and capping streams reduces the ceiling only 3.3× for a 9.8× slot reduction, because
20–30 MB of it is slot-independent.

**No released version of the QUIC library removes it**, so plan for the overhead rather than waiting
for it to go away.

**A 14 h soak has since answered the question we left open there, and it is worth reporting because we
offered the run.** The confirmation comment closed with two things that did not follow from the model,
the first being the soft plateau — *"is there anything else expected to grow per-group once the slot table
is full, or should we read that as noise plus allocator drift? We can run a 12 h leg if it's useful."*
[T8b](test-8b-congestion-control.md) C6 is that leg at 14.006 h, and the answer is that it is **not**
noise: growth past the knee adds another ~100 MB, converging asymptotically on baseline + 200.5 MB —
**2.03× the ceiling** — with the slope decaying monotonically from +24.60 to +1.82 MB/h and still not flat
when the run ended. So the operational figure is about twice the slot arithmetic, arriving over ten-plus
hours rather than three.

**The reading that has to be resisted is per-connection scaling**, and resisting it needed no new run.
C6 carried one publisher and one subscriber, so 2× a per-publisher figure on two connections is exactly
what a per-connection cost would produce. But the evidence against it is in #2745 already, posted by us:
the pre-knee slope is flat across N = 0, 1, 2 and 4 subscribers, and the four-subscriber 4 h leg — five
connections — reached baseline + 108.1 MB at its knee and 189.5 MB at 4 h, which is neither five times
anything nor materially above what two connections reach. The mechanism agrees, since the retained pool
is for streams the *peer* may open and a subscriber connection is one the relay opens streams on. Filing
an audience-scaling claim would have contradicted our own published table.

**Reported as a data point on the closed issue** ([comment
`5367857020`](https://github.com/moq-dev/moq/issues/2745#issuecomment-5367857020)), not as a re-open: the
conclusion there stands, the lever still works, and what changed is the constant a deployment budgets.
The comment states the RSS-only instrument limit, closes off the per-connection reading explicitly so the
tidy story is not left hanging, and offers the capped 14 h arm plus the third slot count the `A + B ×
slots` fit still wants.

### The relay's plateau is confirmed at 24 h — and the publisher is the role that actually leaks

The question C6 could not close was whether the soft second term converges: it was still +1.82 MB/h
when that run ended at 14 h, so "bounded" was the direction the evidence pointed rather than a thing it
established. [T21](test-21-permanence-soak.md)'s 24 h soak closes it. Fitted past the warm-up, the
relay's growth follows a **logarithm at R²=0.9895 against 0.9097 for a line**, with its quarterly slope
halving — 9.85, 4.56, 2.42, 1.75 MB/h. **The convergence is real; the constant is not the one C6
predicted.** This run passes C6's baseline + 200.5 MB asymptote, reaching baseline + 242.6 MB at 24 h,
with the log fit extrapolating to ~519 MB at a year — so the answer to the question we asked on #2745 is
that the soft second term *does* converge, but the budget is about 2.5× the slot arithmetic rather than
the 2.03× C6 measured. **Posted as the promised follow-up on #2745** — a data point on a closed
issue, not a re-open — stating plainly that an extrapolated asymptote is not an observed plateau and
that both legs are single runs on one topology.

**The same run found something that is not the relay's**, and would have been missed by looking at
end-point growth alone: over 24 h the relay grew 243 MB and **`moq import ts` grew 137 MB**, so the
relay looks like the worse of the two and is the better one. The publisher fits a **line** at
R²=0.9898 against 0.8960 for a logarithm and 0.9655 for a square root, its quarterly slopes hold from
first to last (2.36, 2.87, 2.81, 2.57 MB/h), and its largest drawdown from a running peak across the
whole day is 9.2 MB — so it ratchets rather than caching. At +2.83 MB/h that is ~24 GB in a year.

For a lane whose entire case is permanent primary distribution, the publisher is the process that is
never supposed to restart, and restarting it is a timeline event this campaign has priced. **No
upstream issue describes publisher RSS growth over long runs** — #2745 and #3128 are both the relay.

[**#3493**](https://github.com/moq-dev/moq/issues/3493) — **closed** via [#3793](https://github.com/moq-dev/moq/pull/3793)
(`5d0991b9`). Re-soaks **`3493-check-2h`** (continuous) and **`3493-loop-2h`** (loop) both **invalidated**
when import hit [#3798](https://github.com/moq-dev/moq/issues/3798) at ~600 s / ~631 s respectively.
A 2 h slope confirmation on homogeneous `5d0991b9` remains blocked. The report was
**deliberately held** until it could be attributed per process: the soak sampled RSS by command-line
signature, which for the publisher also matched its wrapper shell, and a shell not growing 137 MB is an
argument rather than a measurement. A 6 h re-run of the same lane on the same build, sampling each PID
separately, puts the growth at **+2.91 MB/h in `moq import ts` itself** against the signature's +2.83,
with the largest half-hour increment 17 % of total growth — a ramp, not a jump. The issue carries the
quarterly slopes, the three competing fits, the per-PID confirmation, and two caveats the short run
raised on its own: the exporter stepped +14.5 MB once at 5 h rather than converging smoothly, and 6 h
cannot read the relay's shape at all. Both are stated so a maintainer re-running sees what we saw.

**The held-then-confirmed sequence is the point.** The figure moved by 0.08 MB/h between the argued
and the measured version, so the delay changed nothing about the conclusion — and it is the only reason
the report can say "per process" at all, which is the first thing a maintainer would have asked.

---

## 5b. Authorization, entitlement and subscriber observability

Three filings from the control-plane work were answered together, and **all three were accepted in
substance**. The maintainer's summary of the area was *"I agree, the auth stuff needs a rethinking"*,
and [#3619](https://github.com/moq-dev/moq/pull/3619) planned all of them into quests in one pass.
None is a defect report; each says a design does not generalise, which is the weaker kind of claim to
make and the harder kind to have granted.

### The mTLS identity never reaches the authorization decision — open, and conceded on every point

[#3603](https://github.com/moq-dev/moq/issues/3603) argued that a client certificate authenticates a
peer and is then discarded, so mTLS can only express unrestricted access. The reply granted all three
parts and supplied the current state of each: the auth-proxy API on `dev` **already** forwards the
mTLS identity per connection so the auth server can answer for it, and the default token path cannot
because its cache is keyed per key — *"I think we could do something similar with mTLS though, like we
cache the response per identity instead of unrestricted"*. On scoping, mTLS is what the maintainer
uses for cluster sync, and *"really what you want is per identity scoping, not some global"* — which
is a stronger position than the config-file option the issue proposed. On the startup warning:
*"I currently use this approach which I agree is confusing and not a great security practice as a
result."*

Planned as `quest/m1/auth/relay.md`, on the dev line. **The correction this campaign posted before
anyone spent time on it is the reason the third ask was judged on its merits**: the issue had claimed
a precedent — an existing startup warning for configurations where nothing can authenticate — that
does not exist, and said so in a comment rather than letting the asserted consistency argument stand.

### The revalidation window — closed, and folded into a rethink of the whole auth line

[#3605](https://github.com/moq-dev/moq/issues/3605) reported that `max-age=0` and an omitted
`Cache-Control` silently disable revalidation permanently, and that the 2× revocation window is
undocumented outside the source. Closed as completed and absorbed into
[#3682](https://github.com/moq-dev/moq/pull/3682), *"plan the auth server line on dev"*, alongside
`moq auth serve` becoming the reference auth server. **The ask is no longer tracked as its own quest**,
which is worth stating plainly: the behaviour was accepted as wrong, and the remedy is a replacement
of the surface rather than a fix to it. Whether the replacement closes the specific hazard is not yet
checkable, and the T37 revocation-window measurements are against a component that is being redesigned.

### Subscriber-reported health telemetry — accepted, and became a four-part questline

[#3608](https://github.com/moq-dev/moq/issues/3608) was filed **as aspirational**, on the reasoning
that no control plane or transport in current use gives an origin this visibility, so there was no
convention to copy and no adoption decision turned on it. That framing is now out of date in the one
direction the campaign did not predict: upstream took the direction, went further than the proposal,
and planned it as `quest/m2/qos/stats/` with four sub-quests (schema and library, Rust reporters,
browser reporters, encoder feedback) that **close #3608 when the questline finishes**.

The reply opened *"wall of thought, will distill into a plan later"* and the plan differs from the
proposal in four ways worth recording, because three of them are better:

- **It reuses `moq-stats` rather than adding a catalog section.** `moq_stats::Producer<E>` takes an
  extension flattened beside `Traffic`, `()` for the relay and `hang::Stats` for a media client, so
  one consumer reads the relay's delivery counters and a client's media counters on one layout. The
  proposal's `wall + pts` correlation is not used.
- **The convention is a broadcast-name suffix, not a catalog flag.** One `.stats` broadcast per client
  at a path its token allows — `pilot/feedback.stats` — so a dashboard can tell telemetry from content
  by name, which is what makes filtering 50 feedback broadcasts per producer tractable.
- **It is bidirectional.** Publisher self-reports ride the same layout, explicitly so that a
  subscriber's late frames can be correlated against the publisher's own CPU starvation. The proposal
  covered the subscriber half only.
- **It closes the loop.** `quest/m2/qos/stats/encoder-feedback.md` has a Rust encoder subscribe to its
  viewers' stats and adapt its bitrate. The proposal stopped at reporting.

Two constraints in the plan bound what the capability can be used for, and both agree with this
campaign's position: reporting is opt-in *because reading is* — *"a publisher subscribes to a prefix it
chose, never to every viewer"* — and **"self-reports are diagnostics: never billing, authorization, or
route-selection input"**. The relay's own half stays aggregated: no per-subscriber or per-session row
reaches the wire, only byte-weighted cumulative histograms. The goal is stated as an
unknown/healthy/degraded/unhealthy verdict per broadcast *"the way CMSD does for HLS"*, which is the
comparison [`docs/comparison.md`](../docs/comparison.md) draws.

It lands on `dev`, because `moq-stats` is published and the generic producer is a breaking change.
**So the gap is no longer unaddressed, but nothing is implemented**, and the campaign's own position —
that this is not a route to take through `mpegts-pacer` — is unchanged and now has an upstream
alternative to wait for instead.

### Where the specification half of this belongs, and it is mostly not MSFTS

The upstream questline settles the *mechanism*. The open question is where the **convention** is
written down, and MSFTS is the wrong home for almost all of it. MSFTS is a packaging extension with a
disciplined scope — §4's list of what it does not define is the best-kept part of the draft — and
subscriber health reporting applies identically to LOC, CMAF and `m2ts`. A competing design inside one
packaging extension would also fragment work that is already further along in `moq-dev`. A separate
draft, or a contribution into MSF itself, is the right venue.

**One paragraph does belong in MSFTS, and it is the part nowhere else can write.** A generic telemetry
convention can carry buffer occupancy and object counts; it cannot know that for a transport stream
the broadcast-meaningful counters are TR 101 290 P1, PCR repetition and accuracy, and per-PID
access-unit rate — nor that **the standard P1 set does not detect the failures this carriage actually
produces.** That is measured twice over: 57 s of missing video with 0 continuity errors and a PCR
interval identical to the control ([T24](test-24-partial-media-plane-stall.md)), and #3533's signature of
PSI, AC-3 and teletext continuing while video and primary audio stop, so a receiver locks and shows
nothing while every mux-presence monitor reports health. The `m2ts`-specific claim is therefore that
health assessment of an `m2ts` track requires per-PID access-unit observation *in addition to* P1
counters, with the reporting mechanism explicitly out of scope — an Implementation Considerations
paragraph that plants the finding and points at the separate work.

### BISS-CA over MoQ: the native mechanism answers access, not operator-blindness

Two vendors at IBC 2026 proposed BISS-CA on top of MoQ for conditional access. Assessed from the
specifications; **nothing about scrambling is measured here** — the Gate 2 pass table records "Not
exercised: nothing in the campaign scrambles" against its scrambled-packet rows.

The question turns entirely on whether the platform operator must be unable to *see* the content, and
the campaign's own measurements put MoQ on both sides of that line. Admission works — eight refusing
arms delivered zero payload bytes ([T36](test-36-entitlement-enforcement.md)) — and the key estate
scales, flat from 10 to 20,000 keys for 96 kB of RSS, with key-file deletion revoking immediately and
without restart ([T38](test-38-entitlement-estate.md)). But the relay terminates the session and sees
plaintext, so the native mechanism decides *who may subscribe*, not *who may comprehend*. Token
scoping stops at the relay, and the delivered artefact — a transport stream on UDP or RTP into an
IRD — has no MoQ protection on its final hop at all. BISS-CA, being in-content and
receiver-terminated, covers exactly the gap the native mechanism does not.

**The decisive technical constraint is that BISS-CA forecloses the media-aware lane.** CISSA scrambles
TS packet payloads, so PES cannot be reassembled and the demuxing importer cannot produce media
tracks; PSI and the ECM/EMM tables stay clear, but the media does not. BISS-CA over MoQ therefore
requires transparent carriage — MSFTS mode 1 — which is the lane with the worse measured latency and
which `moq-dev` does not implement on `main` at all. Choosing BISS-CA chooses the opaque lane, which
inverts the architecture's headline and is the part most likely to be missed in a vendor conversation.

**Verdict: do not build it.** Establish whether any rights deal actually requires operator-blind
carriage; if one does, note that MSFTS §10 already permits BISS-CA over transparent carriage so
nothing needs inventing, and the missing thing is evidence. Recorded in
`docs/upstream/biss-ca-over-moq.local.md`, with the two secondary points that a second entitlement
plane gives two answers to one commercial question, and that BISS-CA puts key transport out of scope
and so relocates rather than solves the integration problem the campaign has never measured.

**Promoted to [`control-plane.md`](../docs/control-plane.md) §7.3 and §9** on the operator's approval,
with his framing, which sharpens the verdict: for primary distribution the segments MoQ leaves
unprotected — source to publisher, subscriber to IRD — are local and are carried in the clear today
behind SRT and Zixi on the same basis, so inside a trusted facility this is the status quo and not a
regression. The gap only becomes material where those environments, or the operator, are not trusted.
The §9 open question now separates the two halves and says which one decides it: the technical half is
answered (BISS-CA works, at the price of opaque carriage), and the commercial half — whether any
contract requires it — is unanswered, with vendor appetite explicitly not counted as a requirement.

### FEC is a transport question, and the campaign's contribution to it is the comparison

Raised as a possible MSFTS topic; it is not one. FEC trades latency against loss below the object
layer and applies to every streaming format equally, so it belongs in the transport or QoS discussion.
Two things this campaign can bring there, neither of them MPEG-specific but both measured here:

- **MoQ sheds whole groups, so its loss granularity is a GOP, and FEC and ARQ recover partial damage.**
  Measured: impairments shed programme in group-sized units, with the continuity count at 0 by
  construction because the exporter writes its own counters, and on content the lane loses more
  picture than a 5 s outage lasted in all but one of the cells measured ([T28](test-28-failure-injection-matrix.md),
  [T31](test-31-congestion-capacity-ladders.md)). For broadcast a clean group drop may be preferable to
  a partially corrupt GOP, which weakens the FEC case relative to RTP — but it also means loss that
  would have been a brief artefact becomes a full GOP outage. The trade is visible in those ladders.
- **FEC and the relay's latency budget compete for the same milliseconds.** Any proposal has to be
  scored against simply raising `--latency-max` by the same amount, and against what SRT's ARQ already
  buys a contribution engineer at an equivalent budget. The working figure — a 2000 ms buffer spanning
  roughly 100 round trips at the 18.6 ms RTT measured here — is a heuristic rather than a specified
  SRT property, since achievable attempt count also depends on NAK timing, loss pattern and sender
  buffer retention. The ladders are the right instrument for the comparison and it has not been run.

**The venue is the IETF MoQ list first, not a GitHub issue.** The working group's documents are at
`github.com/moq-wg`, with `moq-wg/moq-transport` tracking `draft-ietf-moq-transport` — the right place
for a change to a document, and the wrong place to open the question, because there is no document
that FEC would change and a new-mechanism issue against a draft heading for publication would be
triaged out. `moq@ietf.org` is where "is there a problem here" gets settled.

**And the message should wait for the SRT arm.** The two structural observations above are worth
making, but the ladders currently exist for the MoQ lane only, at one sample per cell, with the
latency-budget non-monotonicity still *likely rather than established*. "We measured this, here is
the table" is a much stronger opening than a reframing plus an invitation, and the missing arm is the
same rig again. Position recorded in `docs/upstream/fec-arq-venue.local.md`.

### The determinism measurement, posted to #2829 — and the correction it needed first

The head-to-head's pair comparison was posted as a comment on
[#2829](https://github.com/moq-dev/moq/issues/2829): two `moq export ts` processes of one broadcast
share **4.97 %** of their packets over a 50,000-packet window, 94.02 % differing in continuity
counter and 27.93 % in the interleave the issue is about, reproduced to the packet
([T13](test-13-downstream-grooming.md) § *The head-to-head*).

**The first draft of that comment was wrong and was not sent.** It claimed
[#2779](https://github.com/moq-dev/moq/issues/2779) — the continuity-counter half — had been closed
*by accident*, swept up in [#3868](https://github.com/moq-dev/moq/pull/3868)'s `quest/next` grooming,
and invited a reopen. #3868's body says the opposite in one line: "`2779` is abandoned (close #2779 as
won't-fix on merge and remove its `quest` label)." A deliberate decision, with a rationale already on
record. The posted version instead accepts the closure and draws the consequence, which is the
stronger argument anyway: with the counter permanently out of scope upstream, renumbering has to
happen downstream, and a downstream filter is then capped by the interleave — 100.00 % on
single-track with the counter masked against 94.09 % on the real multi-track feed. That made #2829
the whole of what remained in-tree for the interleave, and #4001 has since fixed it; what is left is
the byte schedule (§ *#2829 and #3948, closed by #4001*). Method rule in
[`method-notes.md`](method-notes.md) §6.

### The byte schedule — a successor to #3334, not a reopen of it

Filed as [**#3925**](https://github.com/moq-dev/moq/issues/3925), and it is the most consequential
thing the campaign has reported: conformant egress, a deterministic 1+1 pair and
[#3923](https://github.com/moq-dev/moq/issues/3923)'s sink all wait on it, and the issue says so.

**The care it needed was in not reading as a regression report.**
[#3334](https://github.com/moq-dev/moq/issues/3334) is closed-completed and
[#3351](https://github.com/moq-dev/moq/pull/3351) genuinely closed it — verified here against
#3351's own merge-base: PCR packets adjacent to their predecessor **50.31 % → 0 %**, release
intervals outside ±10 ms **491/799 → 0–4/745**, worst release error 91.4 → 3.9 ms
([T19](test-19-pcr-grid-verification.md) measurements 9 and 10). The filing opens by saying so.

What it reports is the **next property along, which #3351's merged checks do not grade: not-adjacent
is not evenly spaced.** On `53f8aa99d` the PCR values are exact (25.00 ms at min, median and max, 0
of 6,173 over the 40 ms P1 bound) and #3831's padding lands the aggregate rate within 0.21 % — while
the bytes between consecutive PCRs run 188 B to 870,628 B against the 31,081 B the declared rate
needs. The mean is 31,147 B, correct to 0.21 % and the same fact as the aggregate rate; the median is
1,316 B, **4.2 % of the mean**. Bimodal, not noisy. Only 3.3 % of intervals carry an instantaneous
rate within 1 % of nominal ([T13](test-13-downstream-grooming.md) § *The residual measured*).

**The grader is contributed as [#4493](https://github.com/moq-dev/moq/pull/4493)** (`test(ts)`
only), merged as `18d7c2530`. It is the grading half of the quest #3987 filed for #3925,
`quest/m1/ts-export-byte-schedule.md`, which asks for the bytes between consecutive PCRs to be graded
in the existing TS recipe; the schedule itself is left to the quest. It adds `pcr-schedule` to
`test/ts/pcr-timing.py`, the grader that began as our #3335: for consecutive PCRs on one PID, never
pooled, the bytes carried against the bytes `--mux-rate` implies for that interval. The tolerance is
±1 % or one packet, whichever is larger, because PCR packets sit on packet boundaries. It is
report-only unless `--schedule-pct-min` is given, and `run.sh` now runs it on the default arm's capture
as well as under `--live`. Verified both ways on upstream `main` `9d2a4f6e9`, file domain, loopback
round-trip through upstream's own harness:

| Stream | Intervals within tolerance | Median bytes between PCRs / nominal |
|---|---:|---:|
| `CNNiEMEA2.ts`, 60 s cut, 9,945,951 b/s | 100 % | 30,644 / 30,644 B |
| `moq export ts` of that cut | **3.09 %** (exit 1 at `--schedule-pct-min 99`) | **1,316 / 31,081 B** |
| the harness's generated `ffmpeg -muxrate` clip | 100 % | 25,004 / 25,004 B |
| `moq export ts` of the generated clip, three 20 s runs | 92–97 % | 31,208 / 31,250 B |

The export of the real clip reproduces the T13 residual, while its aggregate rate was within 16 b/s
of nominal. **The harness's own fixture does not reproduce it.** The generated clip is 89 % padding,
so no keyframe outgrows a PCR slot. Against it, the exporter misses only near-empty intervals at its
unpadded start: the first ~550 ms in the run inspected, enough to pull a total-bytes rate estimate
~3 % low over a 20 s window. For that reason `run.sh` passes the declared rate rather than letting the
grader estimate it.

**Open:** the schedule itself (#3925, reopened after the planning PR closed it, with the residual
unchanged on `main` at `6f1a9e33`: 3.27 %, [T13](test-13-downstream-grooming.md)); a fixture in the recipe whose bursts exceed a slot, without which the check cannot be
made a gate; the unpadded start; and `pcr-value-interval`, which pools PCRs across PIDs. All four are
listed as follow-ups on the PR.

### The byte schedule itself — contributed as [#4579](https://github.com/moq-dev/moq/pull/4579), overtaken by the maintainer's fixed-delay export

**The defect** is #3925's: with a mux rate, export padded to the right average but heaped each
keyframe between two PCRs, so a receiver clocking off arrival could not lock. On upstream `main`
`6f1a9e33`, a 60 s cut of `CNNiEMEA2.ts` at `--bitrate 11000000` came back with **3.27 %** of PCR
intervals within ±1 %, median gap 1,316 B against 31,087 B, T-STD TB overflows 384,910 and
pcr-jitter p95 205,936 µs.

**The contribution** implements `quest/m1/ts-export-byte-schedule.md` and deletes it. With a rate,
closed spans queue in a backlog and every 25 ms slot goes out as its PCR, media up to the rate, then
nulls, so a PCR's value follows its byte position. A keyframe is spread over the slots before it
decodes; the output trails the media by a buffer delay that grows to the largest burst seen, capped
by `--max-age`. A burst the cap cannot fit goes out above the rate before its decode time, with a
warning, and later slots repay it from their nulls. Without a rate the output is byte-identical.
The harness's generated clip was replaced with one whose keyframes (110-140 kB) outgrow a slot, and
`pcr-schedule` now gates on it at 80 %, which CI's runners pass at 89 %. Measured on the same
loopback harness, `main` → branch (→ `export ts --max-age 1s`):

| Stream | pcr-schedule | TB overflows | pcr-jitter p95 | added delay |
|---|---:|---:|---:|---:|
| CNN, 60 s | 3.27 % → **75.3 %** (→ **99.1 %**) | 384,910 → 90,150 (→ 19,830) | 205,936 → 24,246 µs (→ 92 µs) | 500 ms cap (→ 706 ms) |
| generated clip, 20 s | 34.5 % → **93.5 %** | 67,960 → 5,450 | 58,454 → 24,389 µs | ~250 ms |

Open-GOP stays 60/60, CC clean, no new PCR discontinuities, and `--pair` agreement is equal or better
on every table (NIT 71 → 100 %, SDT/BAT 92 → 100 %, TDT/TOT 0 → 20 %).

**Open:** the 500 ms `--max-age` default is too short for CNN, whose bursts want 0.7-0.9 s, so a
quarter of its intervals still overrun and repay; media goes first in each slot and nulls after,
which leaves TB overflows that interleaving would cut; the first ~2 s stay VBR until the importer
publishes `mpegts.muxRate`; and the `--live` release check was flaky on a loaded machine for `main`
and the branch alike on the new clip (main 6-321 of ~640 releases off, branch 9-356), which the
nightly job may inherit.

**State.** The PR is open and conflicts with `main`. The maintainer's
[#4645](https://github.com/moq-dev/moq/pull/4645) (draft, below) replaces the span machinery this PR
reworks with a constant-rate schedule paced against a fixed `--delay`, and makes a burst that does not
fit the delay fail the export rather than overrun the rate. This PR was closed by its author in favour
of #4645, with the measurements above left in the closing comment as the before-state #4645 has to
beat on a real broadcast clip.

### T-STD conformance of the TS export — taken up upstream as a questline; its rework carries a broadcast clip, with its system clock out of tolerance

**What prompted it.** [T44](test-44-tstd-grading.md) graded the lane's P1/P2-conformant wire against
the 13818-1 T-STD and found it fails on the lane's packet order, and [T45](test-45-live-tstd-remux.md)
showed a live re-multiplexer repairs it on one host. Together with the MSFTS co-author's review of
transmux carriage, that moved the maintainer to treat a TS export as a remux with a fixed delay.

**Upstream state.**

- **The plan**, `quest/m1/tstd/`, merged in [#4637](https://github.com/moq-dev/moq/pull/4637). It has
  three children: a fixed-delay release stage, a full T-STD check in `test/ts/compliance.py`, and
  PCRs on the mux-rate byte grid. The release stage works like an SRT receiver's TSBPD: each frame
  leaves at its first-arrival anchor plus its DTS plus `--delay`, in `(DTS, PID)` order, and a late
  frame is dropped and counted. The questline's proof is the loss rig of
  [#4613](https://github.com/moq-dev/moq/issues/4613) (10 % loss, a real ~10 Mb/s broadcast TS)
  passing the strict check, nightly. Its README says that without it only a passthrough lane can carry
  primary distribution. No quest owned that lane, and `quest/m2/msfts-convergence.md` listed
  transporting TS verbatim as a non-goal. We proposed both in the draft
  [#4670](https://github.com/moq-dev/moq/pull/4670), planned in upstream's quest interview format:
  - `quest/m1/ts-passthrough.md` is MSFTS `mpeg2ts` whole-packet carriage, paced on the source PCR at
    a fixed delay.
  - The PR also re-points `msfts-convergence.md`'s non-goal at passthrough.

  It also proposed `quest/m1/release-clock-recovery.md`: the release stage steered against a
  publisher clock off by up to ±30 ppm, within 13818-1's slew limits, ahead of `delay.md`'s "only if
  measured" on the derived exposure. The maintainer took that spec into #4645 to implement directly,
  with one change: a source beyond tolerance fails the export as well as being counted. At his
  request the quest was dropped from #4670, which now plans passthrough only.

  Its one failing check was `main`'s quest lint, on `admission-bench.md` and `cluster-shims.md`,
  two files the PR does not touch. [#4666](https://github.com/moq-dev/moq/pull/4666) fixed it on
  `main`, and `main` is merged into the branch, which passes the pinned `quest check`.
- **The check** merged in [#4643](https://github.com/moq-dev/moq/pull/4643), into the questline's
  branch `quest/m1/tstd/README`, which #4645 also targets, not into `main`. There `test/ts` still
  carries the approximate TB-only check with fixed leak rates. It is hand-rolled from
  H.222.0 and the codec specifications, since TSDuck has no T-STD analyser, and validated on a real
  broadcast capture and on PCR-restamped controls that must fail. It models TB, MB and EB for AVC and
  HEVC, and TB and B for ADTS, MPEG-1/2 audio, AC-3, E-AC-3 and Opus, the last with borrowed buffer
  sizes. On the harness's generated clip it fails current `moq export ts` with video EB underflow and
  audio TB and B overflow, the failure classes T44 measured on a broadcast clip. It reports only, until
  the delay lands.
- **The implementation**, [#4645](https://github.com/moq-dev/moq/pull/4645), is open in draft at
  head `2dc542b4a`, the maintainer's two rounds of rework on the findings below; what they changed
  and how they grade are at the end of this entry. What follows in this bullet describes the first head,
  `4b7158d6c00d`. His first review asked for one blocking fix, a stale generation
  muxed after a rewind. We posted design feedback on it: clock drift under first-arrival anchoring
  with strict late drop, the 1+1 anchor, the 500 ms default against broadcast send-ahead, and the
  start-up settle. Measurements were to follow. It deletes
  the hold, the stall and the span machinery. With a rate, the output is constant-rate and runs up to
  two delays behind the source, reordered DTS is frame-spaced, and a burst that does not fit the delay
  fails the export. On the generated 20 s clip it passes the strict check at 10 and 2 Mb/s on a clean
  path. The loss rig and a real broadcast clip were not run.
- **A catalog `burst` field**, the encoder's VBV bound sizing the send-ahead so that `--delay` is only
  network margin, was planned in [#4649](https://github.com/moq-dev/moq/pull/4649) and closed unmerged.

**Relation to the measurements here.** The upstream check and [`ts-tstd.py`](scripts/ts-tstd.py) are
independent implementations, cross-validated in [T46](test-46-tstd-check-cross-validation.md) on 35
files: the source clip, the T44 and T45 captures, and upstream's own Kyrion controls. With
`ts-tstd.py`'s six defects fixed, they agree on 24, and each of the other 11 traces to upstream's
check: three defects against H.222.0 (10/2014) and one convention.

- **TB-to-B delivery by whole packet** (2.4.2.3). Five clean files fail on a false audio underflow,
  by 0.27–0.45 ms.
- **Floating-point drift in the AVC leak** (2.14.3.1). Its 10⁻⁹ B tolerance is below a double's
  resolution at 286 MB of accumulated output: one false underflow.
- **Units decoded after the last packet are not assessed** (2.4.2.6). On the 4× and 15× Kyrion
  restamps it misses 132 and 142 audio units per PID held over 1 s. It still fails both files on
  other conditions, so its verdict there is right.
- **A capture's truncated last access unit is graded as an underflow**, a convention rather than a
  defect, which decides an audio condition on five files.

**Reported** ([#4640](https://github.com/moq-dev/moq/pull/4640#issuecomment-5938368125), the open
questline PR that carries the check). These are measured against the questline branch's head
`8df1e438`, which is still #4640's head. Each was reported with its clause, the arithmetic of its
first violating unit, and an offer of synthetic controls for the first two, since our captures are
of a clip we cannot share.
The first two fail clean streams, which matters once the check gates CI; the third under-reports
STD delay.

**The send-ahead the closed `burst` quest would have declared.** On `ffa5b81b`, T45 found the
exporter hands each video frame over at its own decode time, so a conformant output of the CNN clip
needed about 0.55–0.6 s of send-ahead through the video's transport buffer.

**Graded here** ([T47](test-47-fixed-delay-export.md), #4645's first head `4b7158d6c00d`,
loopback, one run per cell):

- **On the broadcast clip the export stops within seconds** with a schedule overrun, at every
  `--delay` tried up to 3 s. The video alone does it, and upstream's own harness reproduces it at the
  defaults (`just test ts --source`).
- **A generated clip with the same 0.7 s send-ahead**, which passes `compliance.py` as a source,
  cannot start at the 500 ms default. At 2 s it passes both T-STD checks.
- **Where it runs, nearly every PCR misses ±500 ns, by up to ±75 µs** (1,868 of 1,880 after
  start-up). PCR values are slot times, and byte
  positions are whole packets.
- Delivery latency at 2 s is 6.83 s on loopback.

**Reported.** The four T47 findings were posted on
[#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5929711256) against
`4b7158d6c00d`: the broadcast clip stops; a shareable generated fixture fails at the default delay;
nearly every PCR is outside ±500 ns; and delivery latency is 6.83 s at 2 s.

**Located since, and corrected upstream**
([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5930108733)). The first report said the schedule was "starved of frames
rather than overfull". It is overfull. `schedule.rs` sends each unit as late as the rate allows,
seeing one window ahead, so a stretch whose decode timeline outruns the rate for about a window
cannot be met. CNN's field-coded passages are such stretches, though its video never exceeds 150
of the export's 156 packets per slot on the source wire. The authored DTS compounds it: the
decode clock holds back a fixed number of pictures, which is a different time in frame and field
coding. An offline replay ([T47](test-47-fixed-delay-export.md#where-the-broadcast-clip-fails))
predicted that the export stops at 5 s and runs at 8 s on the video alone, and the real export did
both. Earliest deadline first, limited by the decoder buffer, fits from 1 s in the replay.

**Built, and reported** ([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5930759235)). A scratch patch sends the video earliest deadline first within its EB.
On the full clip at 1 s it runs the capture, and the video and MP2 pass every buffer. Where the
export runs the full clip, its audio fails the T-STD, patched or not. Unpatched at 8 s, MP2's and
AC-3's B overflow and AC-3's TB overflows. Patched, AC-3 still fails both. See
[T47](test-47-fixed-delay-export.md#a-buffer-limited-schedule-built). One mechanism in that report is
wrong: it said a unit's packets go out back to back. The layout spreads each PID's packets through
the slot, and the overflow is the number per slot.

**Built since, and reported** ([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5931658024),
with the correction above). A second scratch patch admits each PID's packets against its own
transport and decoder buffers, earliest deadline first across PIDs. It takes AC-3's deadlines frame
by frame, because the export passes through the source's PES, nine frames that together exceed
AC-3's buffer. On the full clip it passes every buffer of `ts-tstd.py` and `compliance.py` at 1 s
and 750 ms. At 500 ms it stops; a replay puts that on the export's authored DTS. PCR accuracy still
fails, from the unchanged stamping.

**Found since, and reported** ([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5932637231)). Across hosts, the release stage's generations split audio and
video at the join. A video group skipped at the join counts as a discontinuity. Video, the only
track to cross it, opens a generation of its own, anchored no earlier than the deadlines already
given to the others. On one pair of hosts, four of five traced joins put the video's clock 959–979 ms
behind the other tracks' for the whole run, and one 200 ms. In the run on the PR head's own
schedule, the export stopped on its fatal overrun within seconds; on the per-PID patch it runs, and
the output fails the buffer model for the late side. Timestamps are unaffected. The release stage's
own per-frame slack measures the offset, so a maintainer can see it with one debug line. A second,
smaller item: the per-PID patch's occupancy model resets on a grid restart, which under 1 % loss
overfilled the audio buffers once. That one is the patch's, not the PR's, so it was not reported;
it stands as a requirement on any shipped schedule.

**Found after the report, and reported** ([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5932968381)). The split happens on one host too: six traced
co-resident joins (loopback and the T8b namespace rig at 0 %) all skipped a video group. Two left
the video 200 ms behind and passed. Two put it 1,200 ms *ahead*, and every MP2 unit then reached
the schedule 8 slots late. One put it 960 ms behind, and in one an evicted MP2 group gave the
audio generations of its own. The earlier loopback pass at 1 s has the 200 ms state's margins, so
the per-PID result reported earlier holds for that join state only; the follow-up says so.

**Built since, and reported** ([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5936219991)). A scratch release stage that keeps the tracks on one clock: a
frame that lands on the latest clock keeps it, and a track on an older generation follows the
newest at its first frame not late there. All eleven joins, six on one host and five across hosts,
pass every buffer in every window with one set of margins. It breaks four of the PR's
discontinuity tests (two per change), because the release stage cannot tell a skip at the join from
a publisher's timeline restart. The report argues for the mechanism and the test conflict, not the
patch: the distinction belongs in the consumer or in the discontinuity it reports. The diff is
offered as an env-gated scratch branch on the t0ms fork
([`6f59c78`](https://github.com/t0ms/moq-dev/commit/6f59c785c84fded3328e9ef773f59453129fdf77)),
marked not for merge.

**The maintainer's plan** ([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5936022692)).
He took the findings as the rework's scope:
- fix the join-time generation split;
- admit each PID earliest deadline first against buffers derived from the stream, with AC-3
  deadlines per frame;
- carry the importer's DTS rather than authoring one;
- stamp PCR from byte position;
- track drift, and derive the 1+1 anchor and PCR from the stream;
- add the generated `hrd9m.ts` as a CI fixture and fix the 6.83 s start-up overshoot.

`--delay` stays 500 ms by default. He asked for the per-PID patch as a branch, which the one-clock
comment had already offered, and for mocked-time tests against `ts::Export`.

**Built, and reported** ([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5938316576)).
Eight such tests, one new module on `4b7158d6c`, are on the t0ms fork as branch
`tests/4645-export-timing`
([`d763fd6`](https://github.com/t0ms/moq-dev/commit/d763fd6b043a9f67157b91c9a28313ab0004f8cb)). They run a live H.264 + AAC broadcast on tokio's paused clock,
with receivers that read on their own cadences. They cover a skip at the join and mid-stream, a
source clock at ±0.5 %, and 1+1 identity: clean, at a fractional packet rate, across a skip, and on
a drifting source. Seven fail on the PR head and are `#[ignore]`d with the reason, so they can be
switched on as the fixes land. On the head, the clock cases reproduce the field's split from a
skip alone (video released 296 ms ahead of audio, or 264 ms behind). They need the tracks sent out
of step, as a TS source sends them; sent together, the anchor clamp hides the split. On the
one-clock scratch branch the clock cases pass, and the skip pair still fails with the audio late,
where the joiner rewinds.

Writing them found three things the earlier reports did not:
- **The fractional packet per slot is carried from each receiver's own start.** At any rate that is
  not a whole number of packets per 25 ms, a 1+1 pair pads different slots (at 2 Mb/s one slot
  rendered 6,204 B on one leg and 6,392 B on the other).
- **A skip rewinds the slot grid** by 475–800 ms, at a point that differs per receiver.
- **The skip path is not deterministic on the head.** Identical paused-clock runs give the joiner
  187 or 200 slots after the skip. Its source was not located.

**The rework** ([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5938450157), head
`49efbc9a1`, still a draft). Nine commits, one per point, each with a mocked-time test that fails on
the previous head:
- **One jitter clock.** A discontinuity before any output keeps the clock; after release it opens a
  generation that every track's next frame follows, and generations go out in turn. This is the
  scratch branch's *follow* without its *rejoin*: telling a skip from a restart is left open, as
  needing the consumer to say which.
- **DTS authored in time**, a reorder delay early, not a picture count. On the maintainer's PAFF
  fixture the exported DTS equals the source's.
- **Per-PID admission**, taken from the scratch patch: earliest deadline first across PIDs, capped
  per slot at the TB drain (Rbx for video) and in bytes at the decoder buffer. EB comes from the
  SPS's NAL HRD, else the level's MaxCPB; B is set per 13818-1 stream type. Teletext and SCTE-35 go
  out uncapped in the slot before they are due.
- **AC-3 one sync frame per PES**, each due on its own.
- **PCR from the slot's first byte**, with packets per slot a function of the slot index, so a
  padded slot is laid alike in every exporter.
- **Drift**: the jitter buffer steers its clock's rate within 500 ppm, and the export lays slots on
  that clock; the CLI's own pacer is removed.
- **CI**: `just test ts --hrd` grades the `hrd9m` recipe at 500 ms under the strict check, and
  `pcrverify` gates whenever the rate is known. The quest README records the result.

On 1+1 he reports packet identity except the continuity counter, numbered from what each leg sent.
He suggests a counter derived from the media, and leaves whether ST 2022-7 identity is a goal to
the maintainer. He asked for the broadcast capture to be re-graded, MP2 and teletext especially.

**Re-graded, and reported** ([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5939420739)).
On the broadcast clip, with no environment variable, the head passes every buffer in every window
at 1 s, 750 ms and 500 ms, with every PCR within ±500 ns and presentation latency of 1.4–2.2 s
([T47](test-47-fixed-delay-export.md#the-rework-49efbc9a1), loopback, one run each). The reply
reported three further things:
- **The steered clock takes the output out of 13818-1's tolerance.** The PCR runs on the jitter
  buffer's clock. A mid-group joiner anchors on a stale frame, and the steering wears the lead away
  at its 500 ppm limit, against 30 ppm and 0.075 Hz/s. That is 497.8 ppm in mocked time, and about
  500 ppm on the wire by a PCR clock fit (the reply gave a 290–370 ppm latency trend, corrected in
  the next round). The reply argues that the lead has to be removed before the
  first output, and that only slow, slew-limited following fits the tolerance; the clock-recovery
  quest proposed in #4670 sets out the steering half against those limits.
- **The last AC-3 PES of a capture is a partial sync frame**, which the export passes on, and at
  1 s exits on.
- **The tests, rebased** to `49efbc9a1` on the t0ms fork as branch `tests/4645-on-49efbc9`
  ([`44f3a91`](https://github.com/t0ms/moq-dev/commit/44f3a910e9896a496d5899c6b2c1be772df9bf4c)),
  nine cases. Seven pass, including both clock cases and every drift case. The earlier drift cases
  ran the source 0.5 % off, ten times the steering limit, and are now ±400 ppm over five minutes.
  Two fail and are `#[ignore]`d with the reason: a new case holding a joiner's system clock to
  2.4.2.1, at +433.5 ppm, and the skip pair, which still diverges. The earlier run-to-run variation
  on the skip path is gone. Of the three things the first tests found, the fractional padding is
  fixed (its test passes) and the non-determinism no longer occurs. Whether the grid still
  rewinds at a skip was not measured separately on this head.

The reply also answered his two questions. Teletext has a buffer model, EN 300 472's 480 B TB at
6.75 Mb/s. For primary distribution 1+1 identity is a goal, since the installed base's hitless
selection is ST 2022-7.

**The second rework** ([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5940803068),
head `2dc542b4a`, still a draft). Three commits:
- **The clock keeps to 2.4.2.1.** It estimates the source's rate as the least-squares slope of the
  least slack over 10 min, runs at it, and pulls the slack back within 30 ppm and 0.075 Hz/s. A
  source beyond 30 ppm fails the export.
- **The export joins at the live edge.** Video and audio subscribe to the newest group only, then
  widen to the delay. Verbatim tracks keep the delay's reach.
- **A skip keeps the clock and a declared restart breaks it.** The consumer counts declared restart
  markers apart from other playhead jumps.

He then took the clock-recovery spec into #4645, our tests into it under our authorship, and the
re-grade's partial-sync-frame, closed-track and teletext points. He left 1+1 counter identity to an
m2 follow-up, and put the acquire-before-release anchor under discussion.

**Re-graded, and reported** ([#4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-5941919874)).
The clock is fixed: the output's PCR clock fits within about 1 ppm of the source's over 540 s on
loopback, and within 3.4 ppm of the receiving host across hosts. At 1 s the export conforms on
loopback over 540 s, across hosts, and under 1 % loss, the first run through loss on this clip as
pushed ([T47](test-47-fixed-delay-export.md#the-live-edge-join-and-the-30-ppm-clock-2dc542b4a)). The
reply reported three further things:
- **The join decides whether audio survives.** On some joins a whole audio track misses every
  deadline for the whole run. Across hosts at 500 ms, every MP2, AC-3 and teletext unit was dropped;
  shifting the join point on one host at 500 ms moved presentation latency from 480 to 1,089 ms with
  the audio loss. The reasoned cause is an anchor taken from whichever frame arrives first, and the
  reply proposes choosing it from the least slack across tracks before the first release.
- **The buffer-model graders pass these outputs**, because they grade only the units present.
- **At 500 ms the export exits** on a missed video deadline, 157 s and 202 s into two 540 s runs.
  Under loss it exits at 10 % at 1 s and at 1 % at 500 ms. The reply asks whether the exit is
  intended, since a flagged drop would suit a primary-distribution receiver better.

The tests were updated as branch `tests/4645-on-2dc542b`
([`0920d80`](https://github.com/t0ms/moq-dev/commit/0920d8079990667e31245ceff2d2d7e3666db68a)). All ten
pass on the head, including the two ignored on `49efbc9a1`. The drift cases now run at ±25 ppm,
since the head refuses ±400 ppm by design. A new case sends one track 700 ms after the other at a
500 ms delay and passes, so it does not reproduce the wire's join loss.

### The liveness exit — filed as a question, deliberately

[**#3926**](https://github.com/moq-dev/moq/issues/3926). `export ts` does **not** mint a dead carrier
when its publisher dies, which is the important liveness property and the one #3831's null generator
put at risk; output stops about five seconds after the kill. It exits `Error: json: dropped` instead
and recovers nothing from a restarted publisher (0 B over 25 s, two runs).

**Filed as a question rather than a defect** because the exit arrives at the track level, which
#3907's own added comment deliberately left alone — *"a group whose content is gone is never fatal…
A track- or session-level failure still arrives through `poll_next_group` above."* Asserting it is a
bug would be a judgement about intent the code does not support, which is the error the #2779 draft
made earlier in the same session. The issue asks which of the two it is, and separates the half worth
having either way: a clean exit for "publisher gone" against an error for "something broke", so a
supervisor can tell them apart.

**The same exit on the subscriber's own session loss is by design, and not reported.** A relay
restart, or an outage that reaches the idle timeout, ends the exporter the same way on every build
since upstream's `dev` merge, and the change is [#2704](https://github.com/moq-dev/moq/pull/2704),
*"remove linger; a broadcast closes with its last source"* — bisected in
[T28](test-28-failure-injection-matrix.md) § *The build bisection* and re-drilled in
[T6](test-6-relay-resilience.md) § *Transport-resilience drills*. The removed linger was what let
consumers "ride out a relay restart instead of tearing down", so this is a deliberate trade and not a
defect to file. What it leaves open is the distinction #3926 already asks for: a supervisor restarting
the exporter cannot tell a session loss from a publisher that has gone.

The linger and the exit-code split are now contributed and merged, in § *The liveness exit, implemented*
below.

### A UDP sink for `export ts` — asked once, declined, withdrawn, and re-asked narrowly

[**#1839**](https://github.com/moq-dev/moq/issues/1839), *"feat(egress): generic TS output sink
(UDP/RTP/FEC/ST 2022-7) + PCR-aware pacing"*, was closed **not planned** by this campaign in July
2026, after kixelated declined the general shape twice: *"right now we're just targeting WebRTC, not
RTP in general"*, and *"I don't want to add an import/export module for every possible transport…
I think I need a concrete customer ask first."* The decline was reasonable and the generic layer
stays closed.

**Re-asked as [#3923](https://github.com/moq-dev/moq/issues/3923), filed, deliberately smaller**: one sink,
`--udp <addr:port>` unicast or multicast with a datagram-size and the usual TTL and interface
controls, and the pluggable-transport part explicitly abandoned — no RTP, no FEC, no ST 2022-7, no
trait. What justifies re-opening a question the maintainer has already answered is a change in the
facts rather than a change in how much the campaign wants it:
[#3831](https://github.com/moq-dev/moq/pull/3831) made `export ts` measure the source's multiplex
rate and pad its output back to it, so the TS egress is now attempting to be a constant-rate stream,
and in July the answer to "why would export write to UDP" was that it is not one.

**The filing subordinates its own ask, and that is the point of it.** The same issue reports that the
byte schedule is absent — 3.3 % of PCR slots carry the bytes the declared rate requires, measured on
`53f8aa99d` ([T13](test-13-downstream-grooming.md) § *The head-to-head*) — and states that a socket
would therefore emit a stream an IRD still cannot clock off, that the schedule is worth more than the
sink, and that the sink should wait behind it. Filing the weaker ask alongside the evidence against
prioritising it is the honest form when the campaign is not a customer and cannot supply the customer
ask that was requested.

### Four of these were closed as completed, by a planning document that changed no code

On 2026-09-23 [#3798](https://github.com/moq-dev/moq/issues/3798),
[#3925](https://github.com/moq-dev/moq/issues/3925),
[#3926](https://github.com/moq-dev/moq/issues/3926) and
[#3731](https://github.com/moq-dev/moq/issues/3731) were all closed as *completed via*
[#3987](https://github.com/moq-dev/moq/pull/3987). **#3987 is eight files of Markdown under
`quest/` and no code at all**, and each document it adds ends with the line *"close this issue when
the quest finishes"*. The closures moved the tracker; they did not move the defects, and the
documents say as much in their own present tense — #3798's records *"Known triggers, none yet
reproduced in-tree"*, and #3925's says *"Today the average rate is right (#3831) but the bytes
clump"*.

This is a reasonable way to run a backlog and it is not a complaint. It matters here only because
**a closed issue is the campaign's usual signal to re-test and unblock**, and on this occasion
re-testing found every defect intact. All four were therefore re-verified on `ffa5b81b` — from the
source as well as the wire, since a closure is exactly the circumstance in which inferring from a
changelog is cheapest and least safe:

| Issue | Re-verified on `ffa5b81b` | How |
|---|---|---|
| [#3798](https://github.com/moq-dev/moq/issues/3798) | **live** — import exits *frame timestamp is below the live edge* at the first content join | [T40](test-40-continuous-join-through-srt.md) rig; `reanchor` still only in `impl LegacyStream` |
| [#3925](https://github.com/moq-dev/moq/issues/3925) | **live** — median PCR byte gap **1,316 B** against a 31,124 B nominal, 3.8 % of intervals within 1 % | [T13](test-13-downstream-grooming.md) § *The residual measured*, `pcr-residual.py` |
| [#3926](https://github.com/moq-dev/moq/issues/3926) | **live** — no `--linger` flag exists; export exits 1 on a clean publisher exit 0; 0 B recovered after restart | [T13](test-13-downstream-grooming.md) § *Liveness* |
| [#3731](https://github.com/moq-dev/moq/issues/3731) | **not actionable either way** — the quest defers to msfts#33, which the MSFTS revision has since answered and which is now closed, with the two remaining convergence differences in its closing comment | `quest/m4/msfts-convergence.md` |

The practical consequence on `ffa5b81b` was that **nothing the campaign had blocked on these was
unblocked**; #3798 has since been fixed on `main` (below). On `ffa5b81b` the #3493 permanence
re-soak still cannot run a continuous source ([T21](test-21-permanence-soak.md)),
the deterministic-groomer experiment still has no byte schedule to work against
([planned-experiments](planned-experiments.md) P1-o), and the real-encoder arm still needs its
publisher pinned or its importer fixed ([T34](test-34-real-encoder-severity.md)). Method rule in
[`method-notes.md`](method-notes.md) § *A closed issue is a claim about a tracker, not about a
binary*.

### #2829 and #3948, closed by #4001 — real code, and verified

On 2026-09-25 [#2829](https://github.com/moq-dev/moq/issues/2829) and
[#3948](https://github.com/moq-dev/moq/issues/3948) were closed as completed via
[#4001](https://github.com/moq-dev/moq/pull/4001) (`66440a6c`), which, unlike #3987, changes the
exporter: the earliest pending frame waits, bounded by `max_age`, until every other track has shown
it cannot precede it, and unchanged SI repeats are floored on the media-time grid. Re-verified on the
primary against `84b34f54`, two replicates each, on the raw exporter output
([T12](test-12-dual-path-handoff.md) § *After the media-time interleave*):

| Issue | `84b34f54` | `66440a6c` | Verdict |
|---|---|---|---|
| #2829 — interleave by arrival | 98.33 %, 98.90 % of cross-PID adjacent pairs in the same order | **100.00 %, 100.00 %** | **fixed** |
| #3948 — SI phase set by exporter start | SDT 0.00 %, NIT 0.00 % | **SDT 91.67 %, 95.65 %**; NIT 66.67 %, 80.00 % | **fixed for the repeats**; the late leg adds one or two emissions of each table |

What it leaves is outside both issues. TDT/TOT stays off the shared grid (0.00 %, 20.00 %). The legs
still differ by one or two PCR-only packets per 40 s, which with the join-time tables is enough to
defeat a slot-level merge (24.7–24.9 % of groomed slots identical, masked). And continuity counters
remain per process, since [#2779](https://github.com/moq-dev/moq/issues/2779) was abandoned rather
than fixed. The byte-identical multi-track pair therefore waits on a byte schedule and on
downstream renumbering, and no longer on the interleave. The byte schedule that
[#3925](https://github.com/moq-dev/moq/issues/3925) asked for is now the T-STD questline's
([#4645](https://github.com/moq-dev/moq/pull/4645), below). That anchors each exporter's release at
its own first arrival, so by itself it would give two legs the same packet order but not the same
PCRs. Nothing is to be filed: the residue is that questline's territory, and the anchor point was
raised on #4645.

**#4001 costs the subscriber most of its delivery under random loss.** At 10 % uniform loss with no
rate cap, a subscriber built at #4001 delivers 0.49–0.67 Mb/s where its parent `044ca571` delivers
10.40 Mb/s, on either congestion controller, against either relay, and on the older protocol version
too. At 0 % loss the builds are indistinguishable. Bisected with relay and importer held fixed
([T8b](test-8b-congestion-control.md) § *C7*). Still present on `main` at `6f1a9e33`, with every role
on that build: 15–18 % of its 0 % control. **Reported as
[#4613](https://github.com/moq-dev/moq/issues/4613), root cause measured and posted there, fix
contributed as [#4618](https://github.com/moq-dev/moq/pull/4618), merged as `e488e699`.** Each source skip under loss
is a rewind, and `rewind()` renewed the hold's full `max_age` budget, so the hold held the sources a
budget behind and their next stall skipped again. An instrumented build of `main` at `5124f8134` with
only the hold varied gives 1.13 Mb/s at 10 % loss as it stands, 9.80 with the hold disabled and 8.37
with it capped at 200 ms. On the PR before merge, with the hold kept across a rewind, it gives 9.70
and 9.87, and 9.84 at 0 % loss against 9.85 unfixed. The PR reverses #4001's two tests that asserted
the renewal and adds one for repeated rewinds. The merged commit also clears the stall in `resume()`,
so a replacement broadcast starts with a fresh budget; the measured arms predate that change.
**Open:** a rerun of C7 on the merged build.

### The video DTS reserve froze at the PMT — contributed as [#4500](https://github.com/moq-dev/moq/pull/4500), merged and verified on `main`

**The defect.** `moq export ts` sized each video rendition's decode-clock reserve from the catalog
`jitter` only until it wrote the PMT, and a rendition with no `jitter` held a 16-tick fallback. Two
legs of one broadcast could therefore run different DTS and PCR values for the whole run, and B-frames
on the fallback decode after they are presented. The upstream quest (`quest/m1/ts-export-jitter.md`)
also has a late B-frame misordering the audio/video interleave. That does not happen: since #4001 a
video frame is muxed only once every other track has passed its PTS, whatever the reserve, and an
arrival-order test renders identical bytes on `main`. The reserve decides DTS and PCR values only, and
the PR says so.

**The contribution.** After the PMT, the reserve keeps following the catalog's `jitter` and
`framerate`. Without `jitter`, it is the reorder depth the SPS declares (H.264
`max_num_reorder_frames`, HEVC `sps_max_num_reorder_pics`) times the frame period at a fixed rate.
Otherwise it grows to cover the deepest reordering muxed so far: grow-only, capped at 2 s, and logged.
Both paths use the parsers the crate already has. The declared depth undercounts how far below the
high-water mark a picture lands. IBBP declares 1 and lands 2 frames down, and the 25i broadcast
capture declares 120 ms and lands 240 ms down. So observed reordering may raise a declared value too,
which the PR flags. The margin is one tick per frame decoded since the frame that set the high-water
mark. In x264's B-pyramid the deepest B-frame decodes two frames after the P-frame above it, and a
one-tick margin left it a tick late. The PR's unit rig missed this because no pyramid group recurred
after the reserve had settled; a live source with the structure in every group found it.

**Before and after**, on the PR before merge, P1 (the exporters' captured output): two `export ts` legs on one
relay, the second joining 10–20 s in, upstream `main` at `9d2a4f6e` against the PR. The TS source ran
twice per build, the FLV source once.

| Source | `main` | PR |
|---|---|---|
| x264 B-pyramid over FLV: no `jitter`, no fixed frame rate | Both legs stay on 16 ticks; 347 of 672 and 233 of 455 frames decode after their PTS, for the whole run | Both legs settle at 10,802 ticks (3 frames + 2) within their first group; 4 late frames per leg, all before that; the joiner then matches the runner, and every shared PCR interval is identical with continuity counters masked |
| 25i broadcast H.264 over TS: `jitter` in the catalog before the tables | 0 late frames; 36,000 ticks on both legs; overlapping frames identical in PTS, DTS and length | The same |

On the TS source neither build's legs are byte-identical: null packets land in different slots, which
is #3925's byte schedule, and continuity counters stay per process (#3868).

**After merge** (`7efe9b5ea`), P1, on `main` at `6f1a9e33`. The four
[T10](test-10-mpts-multiservice.md) per-programme captures of the 25i H.264 programme each hold
4 late frames of 2,063, always access units 2–5. The exporter logs the reserve rising from the
16-tick default to 36,000 ticks from the catalog within the first group. The source's own count is
0. Programme 2's video has 0 late frames of 1,468. So the reserve settles in the first group
and holds, as the PR measured. The automated review's one finding was valid and was fixed before
merge. It was that the HEVC picture period, read from the publisher's `hvcC`, was computed with
unchecked arithmetic, so a malformed SPS could panic a debug build or wrap to an undersized reserve.
An overflowing period now counts as no declaration. Since
[#4574](https://github.com/moq-dev/moq/pull/4574), a reserve that grows flags a PCR discontinuity.

**Open.** No live source here publishes `jitter` after the tables, so that path rests on
the unit test. Streams from x264 defaults over a non-TS importer still learn their depth by observation, because x264
sets no fixed frame rate and the H.264 importer publishes no `framerate`. Until that is published, a
late joiner on such a stream differs from a running exporter until it has muxed the deepest
reordering. FLV export keeps its own catalog-only reserve, which the PR does not touch.

### The liveness exit, implemented — contributed as [#4504](https://github.com/moq-dev/moq/pull/4504), merged and verified on `main`

**The defect.** #3926's plan became the upstream quest `quest/m1/export-linger.md`. On upstream `main`
at `9d2a4f6e` a clean publisher end already exits 0, because
[#4303](https://github.com/moq-dev/moq/pull/4303) finishes the catalog at stdin EOF while it still
lists the renditions. A drop still exits 1 and still recovers nothing from a restarted publisher, and
it reports itself as `TS track layout changed after PAT/PMT was emitted: '0.avc3' removed`. That message
comes from a race, not a layout change: a publisher retires its renditions as its tracks end, and the
catalog update can reach the exporter before the tracks' own end. The FLV exporter had the same check
(`FLV track … removed mid-stream`), and either would have ended a linger before it started.

**The contribution.** `--linger <duration>` for `export ts`, default `0s`. Any end (a clean catalog
finish, a drop, any other failure) waits out the linger for the path to be routed again. A returned
broadcast resumes under the PIDs already announced, with the PCR discontinuity indicator set and
PAT/PMT re-sent. Nothing is written while the broadcast is gone, so carrier and content liveness stay
one event, which is the property #3926 opened by crediting. On expiry the exit code is the last end's:
0 for a clean catalog finish, 1 for a drop or any other failure. The other stdout formats refuse a
non-zero linger at startup, which is the smallest option the quest allows. The TS and FLV exporters now
read a track that leaves the catalog to its own end, so the track decides between finish and drop; a
track added after the tables is still refused.

**Before and after**, on the PR before merge, P1 (the exporter's captured output). A local relay, `CNNiEMEA2.ts`
PCR-paced into `import ts` (H.264, MPEG audio and verbatim streams), and one `export ts`. The
publisher is interrupted at about 7 s, and a new one starts 3 s later and runs 6 s to EOF. `main` at
`9d2a4f6e` against the PR on the same base.

| | `main` | PR, `--linger 10s` |
|---|---|---|
| Publisher interrupted | exit 1, `… '0.avc3' removed`; nothing left to receive a restarted publisher | output stops and the export waits |
| Publisher restarted within the linger | — | output resumes; the first PCR after the return (11.95 s to 9.15 s) carries the discontinuity indicator, and PAT/PMT are re-sent |
| Final clean end | — | exit 0, about 12 s after the second publisher's EOF |

The two expiry verdicts, exit 1 after a drop and exit 0 after a clean finish, rest on the PR's
relay-backed CLI tests rather than on this rig.

**After merge** (`42a1fb5f3`), P1, on `main` at `6f1a9e33`: `--linger` resumes across both a clean end
and a SIGKILLed publisher, and the exit code is 0 on a clean end and 1 on a failure, which closes
#3926 as specified ([T13](test-13-downstream-grooming.md)). Two things are new and open. A killed
publisher sends no close, so the relay holds its broadcast until the QUIC idle timeout, 30 s by
default, and output resumes about 30 s after the kill however soon the publisher returns. And the
resume flags the break on the PCR PID only: in one of two clean-end runs an audio PID's continuity
counter came back 4 ahead with no discontinuity indicator. The exporter's own session
dropping, as in a relay restart, is untested.

**Also open.** Linger for fMP4 and MKV is not implemented, nor is MKV's equivalent removed-track check, nor a returned catalog that adds a
track, which fails as a layout change where a new PMT version would carry it. In the rig the returned
output also carried one or two further discontinuities within about a second of the return. Each was
raised by a single track's reader bumping its own discontinuity, not by the resume. The same kind of
break appears mid-broadcast on this capture with no restart, but one late-joining control showed none,
so why they cluster after a return is unexplained; more control runs are the arm that would settle it.
The drop's error text is whatever the reader hit when the path went away (`json: not found` and
`moq: unroutable` in these runs), so it is still not a discriminator; the exit code is.

### #3798's plan asks for a reproduction, and the campaign has one — plus a correction to its scope

The quest for #3798 names three triggers and states that none is reproduced in-tree. Its second
claim — that `LegacyStream::reanchor` *"is set once, so a second unflagged loop wrap lands below the
edge again"* — is the one that decides whether the fix is "apply the re-anchor everywhere" or "apply
it **and** make it cumulative". [T41](test-41-import-reanchor-coverage.md) measures it: with one
elementary stream per fixture, H.264 aborts on wrap **1.00** and legacy audio on wrap **1.98**. The
claim holds, and the offset has to grow rather than merely exist.

The same measurement corrects the plan's scope. It describes the re-anchoring path as *"legacy MPEG
audio"* and lists AC-3 among the kinds that abort immediately, but AC-3 measures identically to
MPEG-1 Layer II at wrap 1.98 — because `StreamType::DolbyDigitalUpToSixChannelAudio` dispatches to
`legacy_stream` and `LegacyStream` is documented in-tree as carrying *"MP2, AC-3, E-AC-3"*. The
dividing line is the type, not the codec, and it already spans three codecs. **Posted to #3798**
(2026-09-24) as a comment on the closed thread rather than a new issue, with the fixture recipe and
an offer — not an unasked contribution — to write the in-tree tests the quest already enumerates.

**Verified fixed on upstream `main` at `9d2a4f6e`.** The same fixtures survive three unflagged wraps
on every stream kind, where `ffa5b81b` aborted at wraps 1.00 and 1.98
([T41](test-41-import-reanchor-coverage.md)), and the SRT chain holds full export rate through five
content joins ([T40](test-40-continuous-join-through-srt.md)). The fixing commit is not bisected;
[#3997](https://github.com/moq-dev/moq/pull/3997), which makes every TS elementary stream re-anchor,
is the likely one. The permanence re-soak it blocked can now run on `main`.

The exit-code baseline for [#3926](https://github.com/moq-dev/moq/issues/3926) went to its thread the
same way: the plan there specifies *"0 when the catalog track finished cleanly, 1 when it was
dropped"*, and the original filing recorded only the error text, so the comment supplies the "before"
side — **1 in both cases, including a publisher that exits 0** — and notes that the error string is
not a discriminator either.

### A loop wrap moved audio against video — contributed as [#4513](https://github.com/moq-dev/moq/pull/4513), closed in favour of [#4543](https://github.com/moq-dev/moq/pull/4543)

**The defect.** #3997 made every TS elementary stream survive an unflagged wrap by growing its own
shift until it cleared its own live edge. Each edge is that track's last frame, and each track's tail
ends where the loop's cut falls in it, so audio and video grow by different amounts and move apart at
every wrap. The upstream quest (`quest/m1/ts-import-shared-shift.md`) estimated about 12 ms a wrap from
frame durations alone. On a byte-cut loop of a broadcast capture the drift is far larger (below). It
appears only where the importer publishes the source's own timestamps: the SRT gateway, and every
importer once upstream's `remove-live` quest lands. `moq import ts` in live mode translates through a
clock anchor that re-anchors every lane by one offset, and there the drift was already constant at
under one 90 kHz tick. This matters to any permanence soak that loops a clip through the gateway, and
to a contribution feed, which must keep lip sync through any number of wraps.

**The contribution.** One shift per importer, applied by every stream. The first stream to land below
its edge opens a hold. Each stream's new pass is queued, and so is every section, while anything a
stream still sends from the old pass goes out at once on the old shift. Once every live stream has
shown its new PTS, the shift grows once by the largest need, which keeps the source's inter-stream
offsets. The hold is bounded on the program clock: one second of PCR, the T-STD delivery bound. On
expiry it commits over the streams seen so far, and a stream that returns later takes the committed
shift clamped to its own edge. A PCR discontinuity publishes what was held and clears the shift. An
overlap of up to 10 ms is clamped where it lands rather than treated as a wrap, so an AAC PTS rounded
to 90 kHz does not open a hold. Four in-tree tests: a muxed H.264 + AAC loop over three wraps, an
old-pass PES completing inside a hold, hold expiry with and without the clamp, and a discontinuity
under a hold. The first fails on `main`, where the offset goes 6.7, 50.7, 94.7 and 138.7 ms over four
passes, against a source offset of 6.7 ms.

**Before and after** `[unmerged]`, P1 (the exporter's captured output), co-resident on one host. The
first 100,000 packets of `CNNiEMEA.ts` (about 15 s; H.264, MP2 and AC-3) are looped by `tsp
--infinite`, PCR-paced for 56 s, through a local relay, and captured from `export ts`. Upstream `main`
at `6a016409` is compared against the PR on the same base. The figure is the drift of each pass's
opening A-V offset from the source's. The first picture after each keyframe is paired with the first
audio frame at or after it, and both are matched to the source by payload hash within ±1 s.

| Pass | `main`, `import srt`: AC-3 | `main`, `import srt`: MP2 | PR, `import srt`: AC-3 | PR, `import srt`: MP2 |
|---|---|---|---|---|
| 1 | 448 ms | 832 ms | 0.000 ms | 0.000 ms |
| 2 | 776 ms | beyond ±1 s | 0.000 ms | 0.000 ms |
| 3 | 984 ms | beyond ±1 s | 0.000 ms | 0.000 ms |

Through `import ts` both builds hold a constant drift, on every pass and for both codecs: 0.000 ms
for MP2, and one 90 kHz tick of rounding for AC-3 (+0.011 ms on `main`, −0.011 ms on the PR).

**Closed, superseded by a different design.** Upstream declined to repair the re-anchor and removed
it instead. #4543, merged to `dev`, publishes source timestamps verbatim, anchors the catalog clock
from the first frame, and ends the import on any TS rewind, flagged or not. That covers loop wraps
and encoder restarts alike. A flagged *forward* discontinuity still publishes, with break markers.
Whether the SRT gateway should republish after a rewind is deferred to upstream's broadcast-epoch
work, which mints an epoch per ingest connection, not per discontinuity. The decision removes the
defect above rather than fixing it: nothing shifts, so nothing can drift. It also keeps the source's
PTS, which a carried SCTE-35 cue's splice time refers to, and no re-anchor path in the importer
rewrote `pts_adjustment`. Review of the PR had found two further defects in the hold: a late
stream's lag was replaced rather than accumulated, and the hold queue was unbounded if the PCR
stopped. Neither is pursued, because the code is gone. The drift table stands as the record against
`main`, which carries it until `dev` is released.

**What `dev` does instead, measured** `[dev]`, P1 (arrival-timed output of `export ts`), co-resident
on one host. The build is `dev` at `9a80e875`, with `main` at `6a016409` as the control. The stimuli
are the [T23](test-23-pcr-discontinuity-classes.md) arms, cut from the first 480,000 packets of
`CNNiEMEA2.ts` (about 72 s; H.264, MP2, AC-3 and teletext), with the event at 30 s. The source is
PCR-paced for 60 s through a local relay. It enters either as `moq import ts` on a pipe, or as `moq
import srt --listen` fed by `srt-live-transmit` as caller, which redials by default, as an encoder
does. The `--linger` column is `dev` with [#4504](https://github.com/moq-dev/moq/pull/4504)
cherry-picked, because #4504 is merged to `main` and not yet on `dev`. "Stall" is the longest gap
between reads at the subscriber's output.

| Stimulus at 30 s | Pipe, `import ts` | SRT, `export ts` | SRT, `export ts --linger 10s` |
|---|---|---|---|
| A: 1 s back, flagged | import exits 1 at the event | the caller redials within 25 ms, but the subscriber exits 1 and output ends at the event | resumes: 1.38 s and 1.14 s stalls (two runs) |
| E: encoder restart, flagged | import exits 1 at the event | as A | resumed with a 1.46 s stall in one run; in the other, the returned broadcast published no catalog within 10 s and the subscriber exited 1 |
| C: 30 s forward, flagged | full window, exit 0 | see the parse failures below | full window; 0.45 s stall at the event |
| F: control | full window | full window | full window |

The error at every rewind is *frame timestamp is below the previous group's start*. On `main`, all
four arms publish through the whole window by either path. The operational result is that a flagged
backward discontinuity, a legal event in TS, now costs a pipe-fed importer the whole feed. Through
the SRT gateway, with a caller that redials and a subscriber that lingers, it cost 1.1–1.5 s in four
of the five lingering runs of A and E. For a subscriber that does not linger, it costs the whole
feed. A pipe-fed importer has no equivalent of the
redial. No upstream quest covered a new epoch *within* one connection at a signalled discontinuity,
so it was **reported as [#4582](https://github.com/moq-dev/moq/issues/4582)**, as the automatic
republish that #4543 deferred, limited to a rewind the stream signals itself. Upstream has since
planned it as a quest in [#4587](https://github.com/moq-dev/moq/pull/4587). The E run that did not resume was not
reproduced in its replicate, and its cause is not established. Every SRT arm here was fed through
`srt-live-transmit`, which injects zero-filled bytes (below), and that run's second session also
ended on a parse error, so the sender artefact is a candidate. The stall figures are timed from the
rewind, which the artefact does not produce.

**The content join through SRT on `dev`** `[dev]`, same host and relay. The
[T40](test-40-continuous-join-through-srt.md) clip (first 200,000 packets of `CNNiEMEA2.ts`, one pass
30.25 s) runs for 100 s through a looping generator. With the generator corrected to rebase every PES
stream (see [the method note](method-notes.md#a-looped-source-is-continuous-only-if-every-pids-timestamps-are)),
`dev` holds full rate through all three joins on both paths: 123.6 MB (SRT) and 123.7 MB (pipe),
against 123.9 MB on `main` (pipe). The MP2 track loses frame sync twice at each join (184 and 530
bytes discarded) and recovers, as on `9d2a4f6e`, and no rewind is raised. So #3533's join on this
clip is not fatal on `dev`. The join is a hard cut at an IDR, and [T34](test-34-real-encoder-severity.md)
remains the arm for a real encoder's. With the uncorrected generator, `dev` ended the import at the
first join on both paths, because AC-3 and teletext stepped back about 30 s. `main`, which
re-anchors each stream, survived the same stream.

### One malformed packet ends a TS ingest — reported as [#4581](https://github.com/moq-dev/moq/issues/4581)

Upstream has planned it as a quest, together with #4582, in
[#4587](https://github.com/moq-dev/moq/pull/4587).

**The defect.** `moq import ts` and the SRT gateway through it end the whole ingest on the first
packet they cannot parse. `decode` propagates a PES-header or adaptation-field error from the TS
reader, and a codec error from the packet handler, as the end of the import. A packet flagged with
`transport_error_indicator` is already dropped, and that is the right model for the rest.

**Measured** `[dev]` and on `main`, P1, co-resident on one host, through a pipe. The input is the
same 72 s excerpt of `CNNiEMEA2.ts`, PCR-paced, with one damaged packet at 20 s:

| Damage | `dev` @ `9a80e875` | `main` @ `6a016409` |
|---|---|---|
| One video PES header's flag and timestamp bytes zeroed, TEI clear | exits 1: *Unexpected marker bits* | same |
| One H.264 NAL header with `forbidden_zero_bit` set | exits 1: *h264: forbidden zero bit is not zero* | same |
| The same PES damage with TEI set | carries on | carries on |
| About two dozen seven-packet (one-datagram) losses, as continuity gaps | carries on | carries on |

**How it was found, and what was a rig artefact.** Over local SRT, the gateway ended sessions on
*Unexpected marker bits*, *Expected stuffing byte 0xFF*, *Expected packet start code prefix*, *CRC32
mismatch* and *h264: forbidden zero bit is not zero*. Across 4-minute runs, the count ranged from
none to fifteen, and it followed host load, not the build: on the same host, a later round with
`main` saw five against `dev`'s three. The sender's counters showed 0.3–6 % of packets reported lost,
nearly all retransmitted, with no sender drops. In the aligned-chunk arm, every loss was
retransmitted, and it still ended ten sessions. A measurement-only build of the gateway that copies
each received payload to a file located the damage. Where a pipe read came up short,
`srt-live-transmit` 1.5.6 had sent a full chunk padded with zeros. A deterministic writer forcing
short reads produces the same zero-filled slots at a libsrt listener as at the gateway, so the sender
is the source. In `ConsoleSource::Read`, the payload is never shrunk to the byte count `read()`
returned, where the SRT and UDP sources do shrink it. **Reported as
[Haivision/srt#3388](https://github.com/Haivision/srt/issues/3388)**, with an `srt-live-transmit`
to `srt-live-transmit` reproduction: at `-chunk:1316`, 1,020 packets arrived in order with 79
zero-filled slots, and at the default 1456 only 26 packets were intact. **Fix proposed as
[Haivision/srt#3389](https://github.com/Haivision/srt/pull/3389)**, which shrinks the payload to the
bytes read. It was merged unchanged into master as `4b8813f1`, which closed the issue, and is
milestoned for v1.5.8. No release carries it yet: v1.5.7 is the latest, and it still pads. The same
reproduction, with master at 74d7083 as the sender and a stock 1.5.6 receiver, shows no zero-filled
slots at either chunk size after the fix. 74d7083 is the commit the fix was merged onto, so that
verification is of what master now holds. At 1456, all 1,040 packets arrive in
order, against 26 before. The rule it yields is in
[method notes](method-notes.md#srt-live-transmit-fed-from-a-pipe-pads-every-short-read-with-zeros).
The rig produced the damage, but the importer ending on it is the defect, and the pipe arms above
reproduce that without SRT.

**Open.** The SRT loss rate on loopback is itself unexplained. Reported loss reached 6 % at
10 Mb/s. A libsrt-to-libsrt comparison on the same host would say whether the gateway's receiver is
the bottleneck, and this rig's attempt at it did not produce a usable capture.

---

## 6. Interoperability

### The announce convention — reported as a hazard, not a bug

`moq-dev`'s publisher withholds its namespace announcement until a peer explicitly asks for it, and
only `moq-dev`'s own relay asks. Every other relay expects a publisher to announce on connect, so the
publisher negotiates, reports no error, and then sends no control message at all.

**Checked against the drafts before reporting, because "interop hazard" and "protocol violation"
warrant very different reports.** Announcing proactively is a **MAY**; the obligation only bites once
someone has subscribed. So `moq-dev` is fully conformant and simultaneously unable to interoperate
with any relay that does not interrogate publishers — which is the normal case. Reported on that basis
as [#2730](https://github.com/moq-dev/moq/issues/2730).

### The empty namespace prefix — a specification inconsistency

The subscriber opens discovery on an *empty* namespace prefix, which one relay rejects outright. The
draft says a namespace of zero fields is a protocol violation, while the working group intends to allow
an empty tuple for exactly this "give me everything" discovery case. **Neither implementation is wrong;
the text they were built against is.** The working group settled that inconsistency in favour of the
empty tuple in [moq-wg/moq-transport#1457](https://github.com/moq-wg/moq-transport/issues/1457), which
is closed — so this is now an implementation-convergence problem rather than an open specification
question, and our contribution is a data point that the divergence outlived the resolution.

### A media-level interop profile — contributed

The community interop matrix is control-plane only, so a `setup-only` check reports green against
relays through which not one media byte flows. **An entire class of failure is invisible to the test
the ecosystem reads.**

The argument made to [englishm/moq-interop-runner#32](https://github.com/englishm/moq-interop-runner/issues/32)
is that validating media-level interop does *not* require capturing video frames as played back by a
player: **pick a fixture container that checks itself.** Every PID in a transport stream carries a
4-bit continuity counter, so loss, duplication and reordering are detectable from the received bytes
alone. The whole oracle reduces to one command, and its sensitivity to all three failure modes is
demonstrated rather than asserted. The client is public in [`interop/`](../interop/README.md).

Two harness-level suggestions went with it: a control-plane test for zero-field namespace-subscription
handling (which would generate data for moq-wg#1457), and recording the transport actually used
alongside the negotiated draft — because the client abandons QUIC for a WebSocket fallback on a fixed
200 ms timer, so **any relay much further away than that is silently carried over TCP**, and the
transport under test is not the one you think.

### A flag-alias regression — reported, fixed, verified, closed

Dial-side flags renamed on the development branch warned and then did not take effect: isolated one at a
time, both the connect flag and a QUIC tuning flag failed independently, and in each case the warning
fired naming the correct replacement, so the alias was parsed and only the propagation was missing.
Reported as [#2913](https://github.com/moq-dev/moq/issues/2913). Found only because a merge-base control
was run ([method-notes](method-notes.md) §1).

**Fixed on the development branch, verified from this rig, and closed.** Both the client and the relay
now reject the renamed settings outright and print the mapping instead of warning and applying nothing.
The report argued that a hard error is *strictly better* than the compatibility shim rather than merely
different, and that is the form the fix took: the failure mode being replaced was invisible — GSO stayed
on, the session stalled on macOS loopback, and nothing was logged — so a shim that warns and no-ops is
worse than no shim, because every existing script keeps running and stops working.

One consequence outlives the fix. The relay's `--server-quic-gso` moved to `--quic-gso` in the same
rename, so a rig that updates only the client half still fails at the relay, and the two named branches
disagree about which spelling is correct. Scripts written since detect the surface (`moq --connect …
--help`) rather than assuming either.

### Corroboration from an independent stack

`moqxr` [PR #21](https://github.com/mondain/moqxr/pull/21) independently reports the same
preannounce split from the other side — including the case where an early publish disturbs namespace
registration so that every later subscribe is rejected — and resolved it by making preannounce opt-in
and default-off. The same PR reports the same idle-timeout behaviour we measured: a publisher with no
subscriber attached dies at ~32 s to the default QUIC idle timeout. **Useful corroboration from an
entirely different stack that the idle timeout is a first-order operational constraint rather than an
artefact of one implementation.**

---

## 6b. FFmpeg: an HLS client that asks for HTTP/3 and carries the media over HTTP/1.1

Not every upstream in this campaign is a MoQ implementation. Building the HTTP/3 acquisition path for
[T20](test-20-segmented-http3.md) turned up a defect in FFmpeg that matters well beyond this paper,
because it silently invalidates any measurement of HLS over HTTP/3 taken with the obvious command.

**The defect.** FFmpeg master carries a `libcurl` protocol (`--enable-libcurl`,
`libavformat/libcurl.c`) whose `http_version` option accepts `3` and `3only`. The HLS demuxer builds
the option set for its child connections with `ffio_copy_url_options()`, which copies a fixed
whitelist of names from the parent:

```c
"headers", "user_agent", "cookies", "http_proxy", "referer", "rw_timeout", "icy", "prefer_libcurl"
```

`prefer_libcurl` is present, so segments are fetched *by libcurl*. `http_version` is absent, so they
are fetched at libcurl's *default* version. Running

```bash
ffmpeg -prefer_libcurl 1 -http_version 3only -i https://origin/index.m3u8 ...
```

the origin logs the playlist as `proto=HTTP/3.0 alpn=h3`, while FFmpeg's own trace of the next segment
reads `ALPN: curl offers http/1.1` / `ALPN: server accepted http/1.1`. **The playlist goes over
HTTP/3 and every media byte goes over HTTP/1.1, and nothing in the client reports it.**

`tls_verify` and `ca_file` are missing from the same list, which is the only reason the defect
surfaced: against a self-signed origin the segment connection fails verification and the run dies with
`Error when loading first segment`. Against a publicly trusted origin it does not fail — it succeeds,
over TCP, quietly.

**The fix**, verified here, is a three-name addition to that whitelist:

```c
"headers", "user_agent", "cookies", "http_proxy", "referer", "rw_timeout", "icy", "prefer_libcurl",
"http_version", "tls_verify", "ca_file", NULL };
```

**Verification.** With the patch, an nginx vhost carrying **no TCP listener** serves a full 60 s HLS
acquisition in which the origin logs 54 of 54 requests as `HTTP/3.0 alpn=h3`, and a packet capture of
the run holds 109,657 UDP datagrams and zero TCP. Without it the same command cannot complete at all
against that origin, and completes over TCP against a trusted one. The media output with the patch is
byte-identical (md5 `7f3402ea…`) to the same client's HTTP/1.1 arm, so the patch changes the transport
and nothing else.

**Why it is worth reporting.** This is the paper's own subject reproduced inside a tool: a lane that
reports one substrate and carries another, with no diagnostic anywhere in the path. Any published
comparison of HLS over HTTP/3 built on FFmpeg's HLS demuxer and this option is, unless the authors
checked ALPN at the origin, a measurement of HTTP/1.1.

**Status: reported** as [FFmpeg issue #24752](https://code.ffmpeg.org/FFmpeg/FFmpeg/issues/24752).
The whitelist and the libcurl options are unchanged on master `45f3fecca` (2026-09-22) by reading.
Open PR [#24565](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/24565) fixes the same class of bug for
`local_addr` on the same line; the report cites it. The patch remains local to this campaign's build
and is documented in T20's environment block so the experiment reproduces.

---

## 7. The carriage specification: MSFTS

Almost everything above is about an *implementation*. `draft-gregoire-moq-msfts` is the other kind of
target: it registers `m2ts` packaging in the MSF catalog, so it is where whole-transport-stream carriage
is fixed for **anyone's** implementation rather than for one build. It was reviewed from a single
declared position — a whole multiplex handed to a hardware IRD at the far end, the way SRT, Zixi and
RIST carry it today — because a fidelity requirement means nothing without saying who is receiving.

The review went in as [mondain/msfts#7](https://github.com/mondain/msfts/issues/7) and every point was
turned into a self-contained draft change by the author. What the draft said, and what it says now:

| Found | Changed |
|---|---|
| The per-programme retain list — nulls, a rewritten PAT, the selected PMT, the PIDs that PMT references — silently drops every SI table living on a fixed PID: NIT 0x0010, SDT/BAT 0x0011, EIT 0x0012, TDT/TOT 0x0014, and the ATSC PSIP equivalents. A publisher implementing it verbatim emits a stream with **no service identity, no EPG and no broadcast time** | [#11](https://github.com/mondain/msfts/pull/11) states the loss, adds retention guidance and an `m2tsSiPids` field declaring which SI PIDs survived |
| Removing null packets is at the publisher's discretion, but it changes the byte distance between successive PCRs — which is what a CBR receiver uses to recover the mux clock, so a downstream device must re-derive a rate it was never told | [#10](https://github.com/mondain/msfts/pull/10) warns, and adds an advisory `m2tsMuxRate` |
| Continuity counters and PIDs were *described* as remaining inside the carried packets. A description is not a prohibition, so a conforming publisher could rewrite either — both silent disqualifiers at an IRD, one breaking decode and the other breaking demultiplexing and conditional access | [#12](https://github.com/mondain/msfts/pull/12) makes both MUST NOT, and adds a non-normative note on inter-packet PCR timing |
| No transparent whole-multiplex mode existed: a single-programme track was defined only as the *output of filtering* an MPTS | [#8](https://github.com/mondain/msfts/pull/8) adds `m2tsMpts`, named for its content rather than for publisher behaviour |
| **Filtering an MPTS implies rewriting the SI, and that was unstated** ([#13](https://github.com/mondain/msfts/issues/13)) — a retained SDT or EIT carried verbatim out of a multiplex still advertises every programme in it, which is non-conformant for a derived single-programme track | [#19](https://github.com/mondain/msfts/pull/19) adds the rewrite requirement, closing the gap #11 left |
| **A native SPTS had no first-class mode** ([#14](https://github.com/mondain/msfts/issues/14)) saying "this is already one programme; carry it unchanged". Applying the filter rules to it is unnecessary and harmful: no PAT rewrite is needed, and the rules guide a publisher to strip SI that was already correctly scoped | [#18](https://github.com/mondain/msfts/pull/18) adds verbatim single-programme carriage |

### Three open, one of them answered in substance

- **The 192-octet arrival-time prefix has no specified clock, units, bit layout or wrap behaviour**
  ([#15](https://github.com/mondain/msfts/issues/15)). Two implementations therefore cannot
  interoperate on its meaning, and a receiver cannot use it programmatically — which forfeits the one
  thing it exists for: letting a downstream pacer reproduce the source's inter-packet timing, as a
  timestamped-TS workflow does.
- **`m2tsMuxRate` does not say who owns the clock**
  ([#16](https://github.com/mondain/msfts/issues/16)). An egress should recover its output clock from
  the carried PCR, which is authoritative, and treat the declared rate as a stuffing target rather than
  a timing source; otherwise a reconstructed clock drifts against the carried PTS/DTS. The
  188-versus-192-octet basis of the figure is also unstated. Both bite when the receiver is a device
  locking a PLL to PCR.
- **Null-packet removal is now declared, but not distinguishably**
  ([#17](https://github.com/mondain/msfts/issues/17)). The required `m2tsModified` boolean added by
  [#21](https://github.com/mondain/msfts/pull/21) tells a subscriber the publisher changed the stream,
  with null-packet removal one of four things that sets it — so an egress deciding whether to re-stuff
  to CBR no longer has to inspect, which is what the issue was filed for. It still cannot tell removal
  apart from programme selection or a PAT rewrite. Open.

**None of this is measurement, and the distinction matters.** The only `m2ts` carriage this campaign has
run is a private loopback prototype ([T3](test-3-opaque-transparency.md)), and the public implementation
strips nulls and derives an SPTS per programme — so *transparent* in a shipped `m2ts` publisher does not
mean *byte-verbatim* either. What the review establishes is that the specification no longer permits the
silent version of that.

### The three named modes are published, and the gap they leave is output timing

§5.5 "Source Handling and Carriage Modes" is now in the draft, subsuming #8, #14, #18 and #19 into one
structure: **(1) unmodified carriage, SPTS or whole-multiplex; (2) modified carriage at programme
level; (3) modified ES-level carriage.** Naming a media-aware lane in the specification is the larger
change, because it is the lane this campaign has spent most of its measurements on and it had not
previously been in `m2ts` scope at all.

**The requirement none of the three modes carries is that the egress be able to *time* its MPEG-TS
output, and that is the contribution to make** — held here rather than filed.

The case is measured rather than argued. A media-aware lane reconstructs a multiplex from tracks and
therefore has no mux rate at all: raw `moq export ts` egress carries no stuffing, thins PSI from 8.04
to 2.51 PAT/s, puts 8.19 % of PCR intervals above 40 ms with a worst of 319.94 ms out of a source
with none above 40 ms anywhere in 600 s, and presents an apparent instantaneous rate of 15.66 Gb/s on
~10 Mb/s content ([T4](test-4-remote-e2e-srt.md), three-lane arm; **wire**, cross-host, `eab960192`).
The file-domain loopback figures are worse still — 13.7–25.5 % above 40 ms
([T2](test-2-media-aware-transparency.md)) — but their multi-hundred-millisecond maxima carry a
join/capture-stop artefact, so the percentage is the robust half and the wire figures above are the
ones to quote. With a
rate-controlled egress in front of it the same lane measures IRD-grade — 0 of 20,193 PCR intervals
above 40 ms over 300 s, and the same across a 24.01 h soak ([T19](test-19-pcr-grid-verification.md),
[T21](test-21-permanence-soak.md)). So a specification can define mode 3 completely, have two
implementations conform to it exactly, and still have neither produce a stream a hardware receiver
will hold, because **the property that decides that is not in the mode definition.** Byte accuracy is
specified in detail and time accuracy is not, and for MPEG-2 Systems the two are not separable: 13818-1
defines a transport stream through the T-STD timing model, in which PCR *arrival* recovers the system
clock. A byte-perfect stream delivered with arbitrary inter-packet spacing is not a conformant
transport stream at the point of delivery.

**The draft already concedes the point, in the weakest available form, and that form came from us.**
[#12](https://github.com/mondain/msfts/pull/12) added the §5.6 note that hardware IRDs recover the mux
clock from PCR arrival rate, that MOQT does not preserve inter-packet timing, and that deployments
"may require a rate-controlled egress". It is non-normative, it uses lowercase "should", and it is
framed as a deployment concern rather than a requirement on any mode. The ask is to promote it.

Four specific changes, in descending order of how hard they are to get accepted:

- **`m2tsMuxRate` MUST be absent for ES-level tracks** (§6.9), so mode 3 — the mode most likely to be
  used for a broadcast workflow — has no way to declare a rate at all, while §5.5.3 and §8 require the
  subscriber to recombine those tracks into a TS output. It is told to build a PAT and a PMT and
  interleave packets, and not at what rate. Making the field available and RECOMMENDED in mode 3 is
  small, self-contained, and fixes the worst instance.
- **Promote the §5.6 note to a normative subsection on egress timing**, placing the obligation on the
  *subscriber producing a TS output* rather than on the publisher — which is the correct party, because
  MoQ genuinely cannot preserve the timing, so the duty belongs at the reconstruction point. That
  framing also avoids any objection that the draft is constraining the transport.
- **Say that 192-octet arrival-time packets are the means, not a curiosity.** Mode 1 with
  `m2tsPacketSize: 192` and `m2tsTimestampMode: "arrival-time"` is the only configuration in the draft
  where the per-packet source timing survives, and so the only one where an egress can reproduce it
  exactly rather than approximate it. The draft never connects §6.12 to §5.6. Doing so gives the timing
  requirement a mechanism that already exists in the document, and it converts
  [#15](https://github.com/mondain/msfts/issues/15) from a loose end into a dependency.
- **`m2tsPsiInterval` describes the source, and mode 3's egress will not honour it.** Measured: PAT
  repetition fell 8.04 → 2.51/s across the media-aware lane. An egress SHOULD restore the declared
  cadence; at present §6.8 declares an expectation nobody is asked to meet.

It is adjacent to #15 and #16 and is neither. #15 asks what the arrival-time prefix *means*; #16 asks
who owns the clock when `m2tsMuxRate` is declared. Both describe timing that already exists. This asks
for the egress to be required to *impose* timing that the carriage destroyed.

**The commercial objection cuts the other way, and that is worth saying to the author.** A co-author's
employer is undecided on whether to keep its pacing component proprietary. Specifying the requirement
does not specify the implementation, and the implementation is where the value is — this campaign's own
grooming work found that PCR slot pre-emption, the rate estimator, and stream-clocked versus
arrival-clocked operation all decide the result — the last of them between byte-identical and 30–53 %
aligned — while the one parameter an implementer would reach for first, cushion depth, turns out not
to be the variable at all ([T19](test-19-pcr-grid-verification.md),
[T18](test-18-delivery-latency.md), [T12](test-12-dual-path-handoff.md)). A
specification that states the target and leaves the method open creates the market for such a
component. One that is silent persuades every implementer they do not need one, and is discovered to
be wrong by the first IRD that fails to lock.

### The 2026-09-17 round: eleven issues filed, plus one comment and one cross-venue pair

The whole review was filed on 2026-09-17, as `t0ms` to stay consistent with #7 and #13–#17.

| Filed | What it asks |
|---|---|
| [#24](https://github.com/mondain/msfts/issues/24) | §5.2's semantics cover syntax but not the delivery schedule |
| [#25](https://github.com/mondain/msfts/issues/25) | `m2tsMuxRate` MUST be absent in the one mode that cannot do without it |
| [#26](https://github.com/mondain/msfts/issues/26) | `m2tsPsiInterval` binds the publisher and nothing at the output |
| [#27](https://github.com/mondain/msfts/issues/27) | The retain list drops the CAT, so conditional access cannot survive filtering |
| [#28](https://github.com/mondain/msfts/issues/28) | The carriage mode is not a field |
| [#29](https://github.com/mondain/msfts/issues/29) | `m2tsModified: false` is declared and unverifiable |
| [#30](https://github.com/mondain/msfts/issues/30) | A fixed object count does not bound group duration |
| [#31](https://github.com/mondain/msfts/issues/31) | §5.5.3's group-alignment MUST has no literal solution |
| [#32](https://github.com/mondain/msfts/issues/32) | Output timing is unspecified — the substantive ask |
| [#33](https://github.com/mondain/msfts/issues/33) | What ES-level carriage is for |
| [#34](https://github.com/mondain/msfts/issues/34) | TR 101 290 P1 does not detect this carriage's failure mode |
| [#15 comment](https://github.com/mondain/msfts/issues/15#issuecomment-5714034547) | The arrival-time mechanism, **not** filed separately |
| [moq-dev#3731](https://github.com/moq-dev/moq/issues/3731) | Six convergence decisions, cross-linked with #33 |

**Outcome: the round is answered and closed, five days after filing.** The editor replied to every
issue and merged [#35](https://github.com/mondain/msfts/pull/35) on 2026-09-22; eleven are closed.
The draft gained an **Egress Timing** section carrying #32's conditional MUST, a §5.4 table mapping
the three fields to four carriages (#28), a §5.2 delivery-schedule paragraph with the ISO/IEC
13818-1 §2.4.2 pointer (#24), a BDAV definition of the 192-octet arrival-time prefix (#15), the CAT
and CA-descriptor PIDs in the retain list (#27), and `mpeg2tsMuxRate` recommended rather than
prohibited on ES-level tracks (#25). `m2ts` is renamed `mpeg2ts` throughout, and `m2tsPsiInterval`
is deleted — which dissolved half of #26 rather than answering it.

**Three asks were declined with reasons, and the reasons are better than the asks.** Field reduction
accounts for #17 and #27's CA-PID list. For #29's source PID inventory the editor's objection is the
decisive one and we had not seen it: *an inventory generated by the same pipeline that dropped the
PIDs would agree with its own output*, so the field helps only when the inventory comes from an
independent inspection. #34 was declined because our measurement comes from a lane that regenerates
PSI, continuity counters and PCR — a fourth mode the draft does not define — and modified carriage
as drafted passes the elementary-stream packets through with their original counters, so P1 does
fire. Both hold.

**#33 was answered by the next revision and is closed, and #15 is now closed too.**
[#36](https://github.com/mondain/msfts/pull/36) replaced the three fields with one `mpeg2tsMode` of
six values and took #33's second route: `es-units` carries PES packets or sections and
`media-frames` carries decoded frames in LOC tracks, which is access-unit carriage, with the PAT and
PMT published as tracks so descriptors survive. We closed #33 against it, noting the two differences
a convergence mapping with the moq-dev draft must bridge: where the program tables live (tracks
in MSFTS, the catalog in moq-dev), and the `es-units` unit (the whole PES packet against the payload
plus `stream_id`). #15 was held open on one sentence the merge left inconsistent: Egress Timing closed
with *"Reproducing it requires timing information that this document does not define"*, and the
arrival-time stamps now define exactly that — an artefact of two changes landing separately, raised
in three lines. [#40](https://github.com/mondain/msfts/pull/40) fixed the sentence and closed it.
The follow-on round is below, under *The output contract*.

Three decisions inside that round worth keeping:

- **The arrival-time ask went as a comment, not an issue.** #15 already asked for the 192-octet
  semantics *and* for a note permitting egress re-pacing, so a new issue would have duplicated it.
  What the comment adds is that §5.6's premise — MOQT does not preserve inter-packet timing — is false
  for that carriage, that the note should be SHOULD rather than MAY, and that #15 is therefore a
  blocking dependency for #32 rather than a loose end. *Check the existing tracker before filing a
  follow-up; half of this one was already open under a title that did not look like it.*
- **#32's ask is a conditional MUST paired with a SHOULD NOT**, not a bare MUST and not a SHOULD. A
  SHOULD would have traded a lowercase "should" in a note for an uppercase one in a subsection and
  left two conforming implementations indistinguishable. A bare MUST would have been wrong, because
  re-pacing costs latency equal to its buffer — 109 ms ungroomed against 2,447 ms groomed, different
  topologies and no deployment having both — so mandating it for file writers, software decoders and
  downstream multiplexers would make the format worse. Stating where the requirement does *not* apply
  is what makes it narrow enough to accept, and the draft asks for the behaviour to be configurable
  because nothing in the catalog knows what an output is for.
- **#33 went without waiting for a reply to moq-dev#3731.** Nothing in it depends on the reply: it
  argues the mode's cost/benefit from the draft's own text, and the divergence is worth settling
  regardless of which way the implementer jumps. The two are cross-linked so neither looks like a
  single-venue complaint.

### moq-dev#3731 answered, and our re-assessment returned: agreement on the diagnosis, a concession on mux rate, one structural disagreement left

The implementer replied within hours, and the useful content is narrower than the agreement suggests.

| Asked | Answered |
|---|---|
| Is MSFTS compatibility an objective? | Convergence is a goal, but **on conversion, not verbatim transport** — *"my goal is to convert TS to/from MoQ, not to transport a legacy protocol verbatim"*, on the same reasoning that there is no RTP-over-MoQ or RTMP-over-MoQ |
| Is mode 3 the right design? | No — *"the worst of both worlds… all of the overhead of TS and it's still a separate format that players must explicitly support"* |
| Does the timing reference travel with the media? | Carrying PCR is *"kind of dumb… intended for hardware decoders that don't have their own clocks"*, followed by *"IDK it doesn't really matter"* |
| Accept §5.5.3's group-alignment MUST? | No — *"use timestamps for synchronization, not group IDs"*, **but optional is acceptable** |
| SI in the catalog or as tracks? | *"IDK"* — no position |
| Will the observed mux rate be recorded? | **Yes** — put it in the catalog, report it as `maxBitrate` on import, and **pad to it on export** |

**The mux-rate answer is the result, and it was volunteered.** It is what msfts#25 asks the draft
for, offered unprompted by the implementation, which means the two venues can converge on this one
field without anyone being argued into it.

**One correction is owed, and it is the same correction msfts#32 exists to make.** He floats *"or
frankly just always pad I guess"*. Always padding is exactly the bare-MUST error #32 was written to
avoid: re-pacing costs latency equal to its buffer, and for a file, a software decoder or a
downstream multiplexer it buys nothing — which is why #32's ask is a conditional MUST paired with a
SHOULD NOT and a request that the behaviour be configurable. The reply should carry that shape rather
than let "always pad" become the implementation.

**The PCR dismissal needs clarifying rather than contesting, and it is the one answer that could
cost us.** He is right that transmitting PCR across the network is not what recovers a decoder's
clock, and our architecture agrees — the egress *re-synthesises* PCR on its own grid, which is what
T19 grades. The risk is that *"kind of dumb"* hardens into a reason not to regenerate PCR correctly
either, and the entire IRD-facing case depends on that regeneration. Worth a short reply saying
plainly which of the two we need, because on the current text it reads as though we disagree when we
do not.

**On group alignment the optional formulation is enough for us**, and it is worth saying so: msfts#31
argues the MUST has no literal solution because audio and video access units do not share a grid, and
"optional" resolves that without anyone having to concede the stronger claim.

**The reply was held until the revision published, and went once, on 2026-09-22.** The thread's open
questions all turned on how far the draft's ES-level carriage moved toward the implementation, which
only the revision could decide; answering earlier would have meant answering twice. It reports
**four of six points resolved, three in the direction the implementer argued for**, and names the
payload unit — filtered 188-octet packets against access units — as the single structural
disagreement, tracked at msfts#33 and left with its editor rather than pushed.

Of the three points the delay was protecting, two went as planned and the third was made in a
different form:

1. **The mux-rate offer is banked.** Both venues landed it in the same week and agree on the
   semantics: a stuffing target, not a timing source, counted over 188-octet packets and declared
   once the publisher has removed nulls. `mpegts.muxRate` and `mpeg2tsMuxRate` are the same quantity.
2. **"Just always pad" was corrected on the substance rather than as a drafting ask** — that padding
   to a rate makes the *total* correct without making the byte *positions* correct, and a receiver
   clocking off packet arrival grades the positions. The measurements sizing that gap were kept out
   of a design thread deliberately and filed as
   [#3925](https://github.com/moq-dev/moq/issues/3925) instead.
3. **The PCR clarification was carried implicitly, not stated.** The reply endorses the revision's
   Egress Timing position — that delivery-schedule conformance belongs to how the *subscriber* hands
   packets to its receiver — which is the regeneration-at-egress point in the draft's own words. It
   never says in as many words that we regenerate PCR rather than transmit it. The residual risk is
   unchanged but small: *"kind of dumb"* hardening into a reason not to regenerate PCR either. **Not
   worth a message of its own**; fold it into the next substantive reply on the thread.

### The maintainer's objection to the round, and why the volume half of it is right

The draft's editor has objected to the **volume** of issues and to their being **AI-generated**,
on the grounds of the work it creates for him. The two halves deserve different answers.

**On volume he is right, and the repository's own history proves it rather than his impression.**
Every one of the sixteen merged pull requests on that draft — including #10, #11, #12, #18 and #19,
which closed our earlier findings — was **authored by the editor himself.** Our contribution model
has therefore been to file an issue and have him write the specification text, which means the more
useful our review has been, the more work it has created for exactly one person. Eleven issues in a
single day is eleven patches on a volunteer editor's desk. That is a real cost and it is not
answered by the issues being individually correct, which is the answer we gave.

**The remedy is to send the text, not the defect.** Most of the eleven already contain proposed
wording — #24, #25, #26 and #32 all do — and the draft is kramdown in a git repository we can fork.
Converting them to pull requests moves the work from him to us at close to zero marginal cost, and
it happens to answer the provenance objection too, since a patch that builds is evidence of review
in a way an issue is not. Two further cheap moves: **consolidate** #28–#31, which are four defects in
one section, into a single pull request; and **state a priority order** rather than leaving eleven
equal-looking items, because "if you only take one, take #32" is information only we have.

**On AI provenance the objection is weaker but should not be argued with.** The `moq-dev`
repository openly labels its own drafts as AI-generated from the implementation
([#3728](https://github.com/moq-dev/moq/pull/3728)), and the maintainer there reads ours the same way
— he opened his reply to #3731 with *"I agree with mr AI"*. So provenance is not a norm being
breached. But the thing he is actually objecting to is **review burden**, and burden is what the
pull-request remedy reduces. Arguing about the label addresses the sentence and not the complaint.

**Method rule:** *a review that only files issues is a review that subcontracts its own conclusions.
Where the artefact is text and the text is in a repository, send the text.*

**The earlier issues were not converted.** The cadence was handled directly with the editor as a
relationship matter rather than by converting issues to pull requests, which would have added eleven
more notifications to the thing he objected to. The draft's co-author and repository owner later
asked for the points put to the group to be filed as issues, and that round (*The output contract*,
below) was sized by this objection: one new issue, one reopen, one closure.

**One point of his to accept without qualification:** that the `moq-dev` implementer is not the
reference for the draft. Our #33 leans on the implementation's choices as evidence that mode 3 sits
between two coherent designs; the argument stands on the draft's own text and the base
specifications, and should be made that way in that venue. Where the two projects disagree, that is a
convergence question for both, not a standard one of them sets.

### The output contract: what a rebuilding subscriber emits, filed as #37 and merged

The points put to the drafting group after #36 were filed at the co-author's request as three
tracker actions rather than one issue each, because most of them are one change seen from different
sides.

| Action | Carries |
|---|---|
| [#37](https://github.com/mondain/msfts/issues/37), new | What a subscriber that rebuilds a TS must output: every table at its standard's interval, including SI carried as section tracks; the first output after a join; never re-emitting an unchanged TDT/TOT; the output where an Object is missing; the `es-units` schedule caveat extended to recombined `es-packets` tracks. And that two subscribers produce the same packets, which needs every regenerated field (interleave, table phase and `version_number`, continuity counters, PCR placement, stuffing) to be a function of the tracks, and a media time on every Object, sections included |
| [#34](https://github.com/mondain/msfts/issues/34), reopened | Its declined condition is now met: `es-units` and `media-frames` regenerate counters, adaptation fields and PCR, so a stopped elementary stream arrives as clean syntax |
| [#33](https://github.com/mondain/msfts/issues/33), closed | Answered by #36; the two convergence differences recorded in the closing comment |

**Cross-referenced against the moq-dev line before filing, and it changed two asks.**

- **Identical output** is already the implementer's goal: #4001 fixed the interleave and the SI
  phase in the name of an ST 2022-7 pair, and the `ts-export-jitter` quest targets byte-identical legs.
  But he kept continuity counters per process (#3868) because a late joiner cannot know earlier packet
  counts. #37 names that constraint and the keyframe-restart prototype's cost rather than asking for
  deterministic counters as though they were free.
- **TDT/TOT**: the group note said "regenerate from the clock, not replay". The moq-dev exporter
  instead forwards each new source value and never re-sends an unchanged one, on the grounds that EIT
  event times are on the source's clock and TOT's local-time offsets are operator data. The failure
  both avoid is the repeated time, so #37 asks only for that rule and leaves the method open.

**Point 4 narrowed on reading MSF.** MSF's Media Timeline track already maps Groups to media time,
so joining by time does not need a per-Object time. The argument that survives is determinism: a
subscriber interleaving by media time can place a PES by its PTS, but it has nothing to place a
section by.

**Not filed, with reasons.**

- *An unrecognised mode MUST be rejected.* This only affects an MSFTS-aware player meeting a future
  mode value on a `loc` track, because MSF parsers ignore unknown fields. It carries no weight for
  a TS-output subscriber.
- *The metadata model and the PES unit.* These are cross-draft convergence choices, not defects in
  either draft, and they sit in #33's closing comment, where the moq-dev convergence quest waits.
- *Test vectors.* Offered in one line of #37.
- *The timing question and FEC.* The first is a question to the editor. The second is transport-level
  and belongs on the IETF list.

**The text went as pull requests, one per open issue**, following *send the text, not the defect*:
[#40](https://github.com/mondain/msfts/pull/40) for #15,
[#38](https://github.com/mondain/msfts/pull/38) for #34, and
[#39](https://github.com/mondain/msfts/pull/39) for #37. Their hunks touch separate sections, so they
merge in any order, and each builds cleanly with `kramdown-rfc` and `xml2rfc`. **All three are
merged**, which closed #15, #34 and #37. An independent
critical review changed #39 in three places, and the changes carry lessons for any further drafting:

- **A continuity-counter jump on loss went from MUST to SHOULD-with-example**, and it applies only to
  subscribers that generate counters. A deliberate P1 continuity error is a design choice the editor
  should make, and ES-Packets tracks already carry the source's counters.
- **The section timestamp is the ISO/IEC 13818-1 §2.4.2 byte arrival time, and it applies to
  `"section"` Objects only.** Mixing PTS for PES packets with arrival time for sections, and ordering
  by PTS in the presence of B-frames, does not give one coherent timeline, so the interleave
  algorithm was dropped rather than specified.
- **Identical output is asked of two instances of one implementation, not across implementations.**
  Cross-implementation identity would need a normative placement algorithm.

#38 is scoped to the PCR PID. A stream that stops on any other PID still trips P1 PID error, so the
reopen comment on #34 was broader than the claim that survives.

### The retain list drops the CAT, so conditional access cannot survive program-level filtering

Filed as [#27](https://github.com/mondain/msfts/issues/27). The sharpest of the round, and it came
from asking a deployment question rather than from reading the draft again — see the BISS-CA
assessment below.

§10 claims the packaging "preserves any scrambling or conditional access information present in the
MPEG-2 Transport Stream". §5.5.2's per-program retain list keeps the PAT, the selected PMT, and "all
packets whose PID is listed in the Program Map Table … including the PCR_PID and the PIDs of all
elementary streams" — and the **Conditional Access Table at PID 0x0001 is not in that list**, nor in
the paragraph that carefully enumerates the other fixed-PID tables the filter drops (NIT 0x0010, SDT
0x0011, EIT 0x0012, TDT/TOT 0x0014).

That matters because of the reference direction. ISO/IEC 13818-1 requires system-wide conditional
access management information to be referenced from the CAT, and the CA_descriptor's meaning depends
on where it sits — EBU Tech 3292-s1 §4.2.2.2 restates it: in the CAT, `CA_PID` is the **EMM** PID; in
the PMT or an ES loop, the **ECM** PID. So the EMM stream is not reachable from the PMT at all, and
dropping the CAT leaves nothing in the track pointing at it. The ECM PID *is* referenced from the
PMT, but by a CA_descriptor rather than in the elementary-stream loop, so the retain list's
"PIDs of all elementary streams" wording puts it at risk too.

The failure is silent and total: the receiver gets scrambled elementary streams and Entitlement
Control Messages, has no Entitlement Management Messages, can therefore never obtain the session key,
and never descrambles a packet — while every validation rule in §5.1 and §8 passes. §5.5.2's saving
clause ("Publishers filtering scrambled transport streams MUST also retain the conditional access
packets required for descrambling") is correct but does not tell the implementer that the table
locating those packets is the one the retain list just discarded.

Same shape as the accepted #11 and #13/#19 findings: a table on a fixed PID, outside the PAT/PMT
reference graph, dropped by a filter that only follows that graph. **Nothing here is measured** —
nothing in this campaign scrambles anything — so the finding is a reading of two specifications, not
an observed product defect. Filed as
[mondain/msfts#27](https://github.com/mondain/msfts/issues/27), now closed.

A second, structural half: **ES-level carriage cannot carry scrambled content at all.** An ES-level
track excludes PAT, PMT and nulls, and `m2tsSiPids`, `m2tsPmtPid` and `m2tsScte35Pid` MUST all be
absent, so there is no carriage path for the CAT, for the PMT's CA_descriptors, or for any association
between a scrambled stream and the ECM stream keying it. Independently, a publisher cannot identify
access points or reassemble PES inside encrypted packet payloads. §10's claim cannot hold for mode 3
and the draft should say so.

### Three further defects in the new sections, and one unimplementable MUST

Found reading the published §5.5 against the implementation; none filed.

- **The mode is not a field.** There is no `m2tsMode`. A receiver derives the mode from
  `m2tsModified` plus the presence of `m2tsEsPid` plus `m2tsMpts`, a decision table stated once in
  prose in §5.5 and never given as a table. Worse, `m2tsMpts` is Optional (§6.15) while §5.5.1 reasons
  about it being "false" — so absent and false must be equivalent, and the draft never says so. Either
  add the enumerated field or state the equivalence and give the table normatively.
- **`m2tsModified: false` is an unverifiable assertion, and the common toolchain violates it
  silently.** The draft gives the receiver framing validation (§5.1: sync byte, integer multiple of
  packet size) but nothing against which to check the byte-for-byte claim. Measured here:
  `ffmpeg -c copy -f mpegts` reduces a 13-PID mux to 5, dropping NIT, TDT/TOT, a second audio,
  teletext and all three SCTE-35 PIDs, and renumbering the rest
  ([T4](test-4-remote-e2e-srt.md)) — a publisher built on it would set the flag false in good faith and
  be wrong. The remedy is the shape the draft already has for SI: an optional source PID inventory the
  receiver can check the arriving stream against, and a Security Considerations note that the flag is
  an assertion.
- **A fixed object count does not bound group duration.** §5.5.1 tells an MPTS publisher that cannot
  identify random access points to "start a new Group after a fixed number of Objects". On a VBR
  multiplex that is a fixed *byte* span, not a fixed *time* span, and join latency is a time. Combined
  with §8's look-back rule and §6.8's demotion of `m2tsPsiInterval` to advisory for MPTS, worst-case
  join time for transparent MPTS is unbounded in the draft. Bound group duration in time instead.
- **§5.5.3's group-alignment MUST cannot be met literally.** It requires publishers of multiple
  ES-level tracks to align Group boundaries "so that matching Group numbers correspond to the same
  presentation position". Audio and video access units do not share a grid — a 1024-sample AAC frame at
  48 kHz is 21.333 ms against a 40 ms video frame at 25 fps — so exact correspondence is unachievable
  without splitting or padding, and the requirement also sweeps in sparse signalling tracks such as
  SCTE-35, whose sections have no presentation time of their own. It should be restated as a
  presentation-time *correspondence* requirement — the subscriber must be able to locate the matching
  position in another track — rather than a group-numbering one. MoQ Group IDs are a poor
  synchronisation primitive across tracks with different natural cadences, which is exactly what the
  implementation shows next.

### Mode 3 and the reference implementation are not the same thing, and that is the convergence problem

The draft's ES-level carriage and `moq-dev`'s media-aware lane are routinely spoken of as the same
mode. They are not, and the difference is structural rather than cosmetic. Read from `origin/main`
(`rs/moq-mux/src/container/ts/{import,export,catalog}.rs`):

| | MSFTS mode 3 (§5.5.3) | `moq-dev` on `origin/main` |
|---|---|---|
| Track payload | **188-octet TS packets**, filtered to one PID | **Decoded access units** — `N.avc3` length-prefixed NALUs, `N.aac` ADTS frames; reassembled PES payloads (`N.ts`) for undecoded ES; complete sections for SCTE-35 |
| Continuity counters | Preserved inside the carried packets | Observed for resync, then **discarded**; regenerated at export |
| PAT / PMT | Carried out of band in `initDataList`; subscriber **constructs** a PMT | **Regenerated** at export from catalog identity, re-emitted at keyframes and every 500 ms |
| PCR | Carried in the track where `m2tsPcrPid == m2tsEsPid`; subscriber sources it from there | **Not carried.** Export synthesises a uniform 25 ms grid; the source PCR PID survives as an identifier only |
| Group boundaries | MUST align across ES tracks at the same presentation position | Video cuts at keyframes; **audio cuts every frame**; verbatim PES per PES; sections per section |
| SI tables | Separate ES-level tracks with `role: nit/sdt/eit/tdt` | NIT and SDT as **opaque section sets in the catalog** (`mpegts.si`, with an `interval`); **EIT and TDT/TOT dropped** |
| Mux rate | `m2tsMuxRate`, though MUST be absent in this mode | No `mux_rate` concept anywhere in the TS code |
| Catalog | MSF, `packaging: "m2ts"` | **Hang** catalog with a typed `mpegts` extension; `moq-msf`'s `Packaging` enum has no `m2ts` |
| MPTS | Mode 1 with `m2tsMpts: true` | **First non-zero programme in the PAT only**; export rebuilds a single-programme PSI |

**So the reference implementation is not mode 3. It is a fourth mode the draft does not have:
access-unit carriage with transport-stream re-synthesis at egress.** Both are defensible, and the
trade is real. Filtered-TS carriage preserves continuity counters, adaptation fields and PES framing
exactly, and is a PID filter rather than a demuxer, so it carries what the publisher does not
understand. Access-unit carriage is what makes the lane media-aware: keyframes define group boundaries
so joins land on an IDR by construction, per-frame objects give frame-level priority and shedding, and
codec configuration reaches the catalog so a subscriber initialises without parsing TS. That is the
mechanism behind this campaign's latency result, and its price is precisely what the measurements show
lost — continuity counters, stuffing, mux rate and PCR spacing, all of which the egress must
reconstruct.

**The draft's mode 3 currently sits between the two and collects the costs of both.** It takes on
per-ES complexity — cross-track group alignment, PAT/PMT reconstruction, PCR sourced from a different
track, re-interleaving to a single mux under T-STD — without taking the benefit that justifies it,
because carrying TS packets per PID buys selective component subscription and not media awareness. It
should resolve one way or the other: pulled back toward mode 2 and presented honestly as selective
component subscription, or pushed forward to access-unit carriage with the TS re-synthesis specified.
The implementation is the evidence for the second, which is why the author's suggestion of having
`moq-dev` contribute to this mode is the right instinct.

**What to ask for, if that contribution happens.** Not a general account of the demux lane — four
specific things where the implementation holds information the draft lacks:

1. **Why access units rather than filtered TS packets** — settles what mode 3 is for.
2. **Why audio cuts a group per frame rather than aligning to video** — one QUIC stream per frame so a
   lost audio frame does not head-of-line-block the next, where §5.5.3's MUST would cost up to a GOP of
   audio latency. Settles the alignment requirement.
3. **Why SI travels in the catalog rather than as tracks** — a joining subscriber gets SDT and NIT
   immediately instead of waiting a repetition cycle, and `mpegts.si`'s `interval` is the same idea as
   `m2tsPsiInterval`. The draft should permit both and say when to choose each. Against that, the
   implementation's coverage is short: EIT and TDT/TOT are dropped on `origin/main`, and broadcast time
   is something an IRD wants ([T2](test-2-media-aware-transparency.md),
   [T17](test-17-si-snapshot-tracks.md)).
4. **What the exporter must reconstruct and what it cannot** — the synthetic PCR grid, regenerated
   continuity counters and PSI, and the absent mux rate. This is the output-timing gap arriving from
   the implementation rather than from us, and the two arguments should be coordinated: measurement
   showing the wire fails conformance, implementation showing why the information is unavailable at
   egress. Either alone is dismissible; together they are not.

**The cheapest convergence win is a declared mux rate.** `moq-dev` strips nulls at import, which is a
genuine bandwidth gain — the reference clip is 4.57% stuffing and the lane runs ~5.3% below SRT
([`evidence.md`](../docs/evidence.md) §3.5) — and it is exactly the case §5.5.2 anticipates. Recording
the observed rate in the `mpegts` catalog section would make the egress re-pacable by a generic groomer
without any catalog convergence at all. Null-stripping is the win; the declared rate is what makes it
safe.

---

## 8. What was asked for at the start, what was retracted, and on what evidence

Four issues here are requirements rather than defects, filed in the campaign's first days before most
of what is in this repository had been measured. **Three are now closed, and we closed all three
ourselves.** That is a result rather than an admission: the asks were what a broadcaster assumes it
needs, measurement said otherwise, and leaving three wrong requirements standing in someone else's
backlog would have been the worse outcome. A retraction is part of the contribution record, so each
is logged with what was filed, what we did about it and the measurement that forced the change:

| Filed | Asked for | What we did | What forced it |
|---|---|---|---|
| [#1799](https://github.com/moq-dev/moq/issues/1799) | a direction decision between media-aware and byte-opaque carriage | **closed by us** once its children resolved | the direction was settled by its children, not withdrawn |
| [#1861](https://github.com/moq-dev/moq/issues/1861) | a second, byte-verbatim opaque lane | **retracted by us** | #2440 shrank the gap to EIT alone; the wire measurement reversed the economics; byte-identical 1+1 legs were reached another way |
| [#1839](https://github.com/moq-dev/moq/issues/1839) | a generic TS egress sink with PCR-aware pacing | **partly landed, remainder retracted by us** | the pacing primitive shipped as [#1845](https://github.com/moq-dev/moq/pull/1845); the maintainer declined a module per transport, and the grooming stage does not belong in a transport library |
| [#1838](https://github.com/moq-dev/moq/issues/1838) | TR 101 290 monitoring | **corrected in place rather than retracted**; since closed by the maintainer when a planning PR ([#4496](https://github.com/moq-dev/moq/pull/4496)) moved it into upstream's quest backlog — planned, not implemented | half the checks were aimed at a stream no IRD sees; the requirement itself survives, restated |

Only #1839's remainder turned on maintainer push-back, and even there the replacement was built
outside the tree on its own merits. The rest were retracted because a measurement in this repository
contradicted the ask.

**That retraction has since been tested against a live temptation and held.** #2967's PCR grid does not
reach the wire because the exporter's stdout writer discards the frame timestamps (§1), and the obvious
report to write — "pace the exporter's output" — is #1839's declined half almost word for word, and would
also contradict what we argued on #1838. [#2984](https://github.com/moq-dev/moq/issues/2984) was framed
instead as a **caller-contract** defect: #2967's own doc comments specify a caller-side pacer, `moq-srt`
implements it, `moq-cli`'s `run_ts` discards it. Same fix, different and defensible claim — and a
demonstration that a retracted ask stays retracted even when a later measurement would have made it easy
to re-file.

- **A broadcast contribution profile** ([#1799](https://github.com/moq-dev/moq/issues/1799)) — the
  parent proposal, presenting media-aware and byte-opaque carriage as two options and asking for a
  direction decision. Closed once its children resolved; the direction chosen is the lane this whole
  campaign measures.
- **An opaque, byte-verbatim TS lane** ([#1861](https://github.com/moq-dev/moq/issues/1861)) — filed on
  the claim that *only* an opaque lane delivers contribution-grade fidelity, which was true of the lane
  as it stood when filed and is not true now. Withdrawn on three grounds, and the middle one was the
  surprise:
  - #2440 carries the service layer, so of the gaps the issue listed only EIT was left — a much smaller
    ask than a second lane, and filed as one.
  - **The economics were backwards.** Byte-verbatim carriage looked like the neutral choice and
    demux/re-mux the costly one. Measured over a WAN against SRT on the same path, the media-aware lane
    puts **0.982×** the source TS rate on the wire where SRT puts **1.037×**, almost entirely because it
    declines to carry null stuffing that a receiver regenerates locally for free
    ([T9](test-9-performance.md), [T14](test-14-data-plane-comparison.md)). Verbatim carriage is exactly
    what forgoes that saving.
  - The one property still worth defending — two legs of a 1+1 pair being byte-identical, which
    re-muxing obstructs twice over — was reached another way, by deriving every stream-position quantity
    from the stream rather than from the process ([T12](test-12-dual-path-handoff.md)). So it is an
    argument about how much machinery a redundant pair needs, not about which lane it can be built on.

  What stays genuinely out of reach for a demux/re-mux lane is scrambled/CAS carriage and true MPTS.
  Neither is measured here and neither is on this path, and both belong to an MSF-packaging discussion
  (§7) rather than to an implementation's issue tracker.
- **A generic TS egress sink with PCR-aware pacing** ([#1839](https://github.com/moq-dev/moq/issues/1839))
  — UDP/RTP, FEC and ST 2022-7 outputs inside the tree. Half of it landed as a PTS-exposing export API
  and PCR-paced SRT egress ([#1845](https://github.com/moq-dev/moq/pull/1845)), which is the pacing
  primitive the request was really after. The rest was withdrawn: the maintainer declined an
  import/export module per transport without a concrete customer ask, and the grooming stage does not
  belong inside a transport library anyway. What replaced it is a transport-agnostic pacer with no moq
  or QUIC dependency, for which a MoQ subscriber is merely one possible source
  ([T13](test-13-downstream-grooming.md)).
- **TR 101 290 monitoring requirements** ([#1838](https://github.com/moq-dev/moq/issues/1838)) —
  **corrected rather than withdrawn**, because the requirement is real while the issue as filed aims
  half of it at the wrong stream. The maintainer has since closed it by moving it into upstream's
  quest backlog ([#4496](https://github.com/moq-dev/moq/pull/4496)), so it is planned there and not
  implemented. Three changes, and the third is the one worth having:
  - **The PCR and mux-rate checks measure a stream no IRD ever sees**, and on a healthy chain they would
    sit permanently in alarm: 0–26 % of PCR intervals at moq's egress exceed 40 ms depending on the clip,
    and 1,523 of 1,524 PCRs fall outside ±500 ns ungroomed, against 0 % and 0 of 2,598 after grooming
    ([T7](test-7-timing-integrity.md), [T13](test-13-downstream-grooming.md)). That is what object
    delivery over a congestion-adaptive transport does to byte cadence, not a defect, and repairing it is
    the groomer's job. Those checks belong out of scope on the moq side.
  - **What grooming does not restore is the defensible egress list.** A CBR pacer shapes transmission
    timing; it does not demux, rewrite PSI or touch continuity counters, so sync, PAT/PMT, continuity,
    PID, transport-error, CRC and PTS faults seen at moq's egress are still true at the IRD.
  - **TR 101 290 is blind to the worst failure this chain has.** A groomer asked only to hold a rate will
    hold it against a dead upstream, emitting a byte-perfect CBR carrier — correct rate, valid TS,
    PAT/PMT and accurate PCRs present — containing **no programme packets at all**, with every P1 and P2
    check green; measured, an input-select receiver performed **zero** switches at every threshold from
    50 to 500 ms ([T12](test-12-dual-path-handoff.md)). The requirement that answers it is
    **programme-packet presence**, counting packets that are neither null *nor adaptation-field-only*,
    because a groomer's own PCR insertions are neither null nor content and the naive version reads
    healthy too.

  At ingest the same issue leads with the wrong instrument for the same reason: after the resync fix, a
  lost-sync importer emits a genuinely conformant stream (§2), so the highest-value ingest signals are
  **moq-layer counters** — resyncs and bytes discarded, per track — surfaced alongside the ETSI list
  rather than the ETSI list alone.

---

## 9. Documentation

The upstream review of [#2830](https://github.com/moq-dev/moq/pull/2830) objected to a grooming recipe
that invoked a tool with no supported installation path. That objection is what prompted
[T13](test-13-downstream-grooming.md), which graded every off-the-shelf candidate an engineer would
reach for and concluded that **the requirement should be stated precisely with the off-the-shelf
options and their measured limits named, rather than any single tool being named as the answer.**

That conclusion holds whether or not our own tool can be installed — which it now can — because it was
never contingent on that. The installability gap is closed: the egress adapter is now the crate's own
binary rather than an example.

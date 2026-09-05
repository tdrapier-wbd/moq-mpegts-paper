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
repetition and emit on change.

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
[`docs/upstream/pcr-output-position.local.md`](../docs/upstream/pcr-output-position.local.md),
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

### A rewound timeline stalls the whole programme, not just the SI cadence — measurements contributed to an open issue

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

The earlier draft, written from T21's looping stimulus, claimed the exporter latches its PCR and emits
a counter permanently. No arm of T23 reproduces that, and the draft was retired rather than filed. See
[method notes](method-notes.md) §6.

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

### A recovered stream is signalled nowhere — open, and it is the architecturally important one

Reported as [#2798](https://github.com/moq-dev/moq/issues/2798), scoped to observability rather than
correctness.

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
it crashed 216 times; the same condition now produces a stream that looks healthy. The ask is a
warning on a completed resync and a counter to alarm on a *rate* of them, neither of which touches the
protocol.

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

### Three values the exporter mints per process — one closed, two open

A 1+1 pair cannot be byte-identical while the exporter renders anything from its own process state
rather than from the broadcast. Three such values were isolated ([T12](test-12-dual-path-handoff.md)):

- **SI emission cadence**, anchored to process start, landed tables on slots where the partner carried
  video: measured at **0.00 %** frame agreement for SDT and NIT over a 45 s overlap. Fixed by
  [#2825](https://github.com/moq-dev/moq/pull/2825), which takes a single-track pair to 100 %. The
  review mattered: the form first proposed inflated PSI (PAT 1,959/1,946 across two legs against
  111/111 for the merged form) and **landed inconsistently, costing 5.9 points of agreement** — a
  one-character change from `!=` to `>` in the due check, which stops a backwards timestamp counting
  as a new slot. **It merged in the `>` form, changing its own measured result**, which is the
  argument for treating unmerged-code evidence as provisional.
- **Continuity counters**, numbered from process state, leave exporters that did not start together
  permanently offset by a constant — the single field whose masking lifts agreement to ~98 %. Filed as
  [#2779](https://github.com/moq-dev/moq/issues/2779). **Open**, and prototyped here rather than only
  described: restarting each PID's counter at the video keyframe boundary and padding every span to a
  multiple of 16 packets takes the same pair from 0.4 % to 99.9 % identical on single-track content
  and from 24.6 % to 93.6 % on multi-track, with both legs continuity-clean. The cost is small in
  aggregate and regressive in detail — 1.5–1.7 % of packets, but **10–18 kb/s per PID almost
  regardless of what that PID carries**, because a PID emitting one or two packets per group is nearly
  always 14 or 15 short of a multiple of 16.
- **Audio/video interleave**: the exporter emits the earliest *available* frame rather than the
  earliest frame, so legs whose bytes arrive at different moments order the same media differently.
  Multi-track content therefore stops at 94–96 % even when co-started, and at 75.56 % once the two
  chains are fully independent. Filed as
  [#2829](https://github.com/moq-dev/moq/issues/2829). **Open**, and the counter fix above is
  conditional on it: the counter becomes an index within a span, so wherever the legs order media
  differently the renumbering diverges with it.
  **Now measured on fully independent chains and posted to the issue.** A publisher, relay, exporter and
  groomer per host across two availability zones, sharing nothing but a verified-identical source file:
  a single-track feed is byte-identical on all 46,778 shared datagrams, and a seven-stream mux over the
  same topology reaches 75.56 %. The legs carry the *same packets in a different order* — every media
  PID has an identical packet count, 99.9528 % of packets are common as a multiset, and 98.414 % align
  once displacement is allowed. Re-read against `main` `5eea9e3c8`, `pick_next_track` takes the minimum
  of `(timestamp, pid, name)` over the tracks that have a *pending* frame, so the tiebreak is
  deterministic and the candidate set is not. The invariant was stated as a requirement — the emission
  order should be a function of the media timeline — with the design left to the maintainer.

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

**Status: not yet filed.** The patch is local to this campaign's build and is documented in T20's
environment block so the experiment reproduces.

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
| [#1838](https://github.com/moq-dev/moq/issues/1838) | TR 101 290 monitoring | **open, corrected in place rather than retracted** | half the checks were aimed at a stream no IRD sees; the requirement itself survives, restated |

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
  **still open, and corrected rather than closed**, because the requirement is real while the issue as
  filed aims half of it at the wrong stream. Three changes, and the third is the one worth having:
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

# Upstream contributions

What this campaign found, reported and verified in other people's projects. It is kept separate from
the experiment record because the argument is different from "does MoQ suit broadcast primary
distribution", and because much of the campaign's effort lives here in a way the per-experiment results
alone do not show.

**Why it belongs in the repository at all.** [Comparison](../docs/comparison.md) §14 scores
operational maturity against a pre-1.0 ecosystem. This file is the concrete form: what a broadcaster
procures is an implementation, not a specification, so much of what reads as "MoQ does X" is really
"this build does X" — and several gaps recorded here have since closed. That is implementations
maturing *with* a specification rather than after it; the gaps were real, and they closed fast.

Each item states what was found, how it was verified, and what remains open. Where a fix was verified
here rather than taken on trust, the before/after rigs are named.

Four kinds of thing are recorded: defects verified against before-and-after builds; test coverage and
fixtures contributed where the tree could not yet produce the stream in dispute; a review of the
*specification* rather than an implementation (§7); and requirements filed early and then withdrawn on
this campaign's own measurements (§8), where the ratio is the point.

---

## 1. Media-aware carriage: what a real contribution feed breaks

### The lane this campaign measures did not exist when it started

The first reports asked whether a broadcast feed survives the round-trip at all; it did not. A real
contribution capture published and subscribed back produced continuously undecodable H.264
(`non-existing PPS 0 referenced`), because the import/export path kept a single SPS and a single PPS
and a source carrying several lost all but the last seen. PES **DTS was not authored at all**, so
B-frame content — 12,480 B-frames in the capture — emitted a decode timeline a player had to be told
to ignore. Reported as [#1798](https://github.com/moq-dev/moq/issues/1798) and
[#1836](https://github.com/moq-dev/moq/issues/1836), fixed by
[#1812](https://github.com/moq-dev/moq/pull/1812) and
[#1843](https://github.com/moq-dev/moq/pull/1843).

The larger carriage question went to [#1799](https://github.com/moq-dev/moq/issues/1799), which
presented media-aware and byte-opaque options **neutrally** and asked for a direction rather than
advocating one. Upstream chose verbatim per-PID carriage under an `mpegts` catalog section
([#1815](https://github.com/moq-dev/moq/pull/1815)), so ancillary PIDs — DVB teletext, AC-3, all three
SCTE-35 PIDs — survive as opaque tracks while video and audio stay typed and playable without TS
support. CLI wiring was out of scope in that PR, leaving the lane library-only until
[#1842](https://github.com/moq-dev/moq/pull/1842) closed
[#1835](https://github.com/moq-dev/moq/issues/1835).

### The harness that found most of what follows

The MPEG-TS/IRD compliance harness this campaign uses was offered upstream as
[#2024](https://github.com/moq-dev/moq/pull/2024): relay round trip, TSDuck parsing, and PCR interval,
accuracy, mux-rate stability and continuity graded against IRD expectations. It landed as
[#2011](https://github.com/moq-dev/moq/pull/2011), hardened in
[#2043](https://github.com/moq-dev/moq/pull/2043), as `just test ts`. The open-GOP break below was
found by pointing the merged harness at a real capture whose source file was clean; the round trip
failed.

### Open-GOP keyframe detection — closed

A CNN International capture (open-GOP H.264 with recovery-point SEI, roughly one IDR every 15 s)
produced **no video rendition at all** through media-aware import, because keyframe detection keyed
only on the IDR NAL type. Open-GOP is common on contribution feeds. Reported as
[#2050](https://github.com/moq-dev/moq/issues/2050).

Closed upstream by two changes the round-trip needs **together**: catalog-reservation gating
([#2072](https://github.com/moq-dev/moq/pull/2072)), withholding PSI until every PMT-reserved track
resolves, and recovery-point-SEI detection ([#2066](https://github.com/moq-dev/moq/pull/2066)); with
#2072 alone the catalog never publishes. Verified here ([T2](test-2-media-aware-transparency.md)): the
same feed round-trips deterministically with every elementary stream, PID, `stream_type` and PMT
descriptor intact, including all three SCTE-35 splice PIDs.

### Open-GOP leading pictures at tune-in — fixture and measurement contributed as [#4501](https://github.com/moq-dev/moq/pull/4501)

#2066 made a recovery point start a group, but nothing in the tree exercised open GOP end to end.
Upstream's consumer-side quest for leading pictures — decoded after a recovery point, presented before
it, referencing the previous GOP — waited on a measurement of what a viewer does with them
([#2067](https://github.com/moq-dev/moq/issues/2067)). The fixture that issue proposed,
`kyrion_dirtystart.ts`, is not open GOP: every keyframe is an IDR, there is no recovery-point SEI, and
no picture after a keyframe is presented before it.

**Contributed as [#4501](https://github.com/moq-dev/moq/pull/4501)** (`test(ts)` and quest files only),
merged as `12f23811a`. On `main` at `6f1a9e33` the Kyrion clip still round-trips 60 of 60. `just test
ts --open-gop` round-trips a generated x264 `open-gop=1` clip with three leading pictures per recovery
point, grading the capture access unit by access unit: 60 of 60 leading pictures across 20 recovery
points in decode order, random-access indicator set on every random-access access unit, recovery-point
SEI intact, `compliance.py` passing.

**The viewer is where it breaks, and how depends on the decoder.** Measured through `<moq-watch>` in
Chromium 153 on macOS, 120 s clip, one continuous subscriber and eight cold joins per decoder setting:

- **Continuous playback** decoded every leading picture on both decoder paths; frames were identical.
- **VideoToolbox at a cold join** (macOS default) never outputs the orphaned leading pictures, with
  no error — the viewer starts at the keyframe.
- **Software decoder at a cold join** (`prefer-software`) raised `EncodingError` in 8 of 8 joins before
  any frame, and `<moq-watch>` closed its decoder, so the join showed no video.
- **Control with leading pictures removed** joined cleanly in 8 of 8 software joins; the error is the
  leading pictures, not starting at a non-IDR keyframe.
- **Latency skip** into a later group orphans that group's leading pictures the same way.

The numbers sit in the upstream leading-picture quest (`quest/m1/open-gop-leading-pictures.md`), which
the PR unblocks: trim before decode, and drive the software decoder in the test.

**Found in the PR, fixed separately:** the TS exporter authors DTS after PTS on B pictures (374 of 500
access units on the open-GOP clip, worst by 119.8 ms; 360 of 500 on the closed-GOP clip) because the
decode-clock reserve stays at its 16-tick default until after the first group. Fixed by #4500, below.

**Open:** the consumer-side trim itself; Linux (not measured — the software-decoder outcome is expected
where no hardware H.264 exists, but the settling arm is the same cold-join rig in Chromium on Linux).
Painted-frame counts were not used: the host was heavily loaded and media arrived slower than real time
in one run.

### The exporter locked its PSI on half a catalog — closed, by a better fix than the one proposed

`export ts` built PAT and PMT once a header and video track had resolved, then aborted with
`TS track layout changed after PAT/PMT was emitted` when a later track arrived — a race decided by
codec, not timing: AAC registers on its first PES, H.264 waits for inline SPS in a keyframe, so
audio-first streams reliably lock PSI on an audio-only layout
([#1979](https://github.com/moq-dev/moq/issues/1979)).

This campaign proposed gating PSI on the PMT's declared elementary-stream count as `expected_tracks`
([#1980](https://github.com/moq-dev/moq/pull/1980)). Upstream read the problem as container-finality
signalling in general, not MPEG-TS alone, and closed it with catalog reservation gating
([#2072](https://github.com/moq-dev/moq/pull/2072)): one reservation per PMT-declared track until its
config resolves, catalog withheld until the last drops — the same rule without a container-specific
catalog field, and the gate the open-GOP fix above requires.

### The DVB service layer — closed

The `mpegts` catalog modelled per-PID PMT info and verbatim elementary streams only, so `export ts`
rebuilt just PAT and PMT and lost service name and provider, service type, NIT, TSID, ONID and the
PMT's own PID. Reported as [#2433](https://github.com/moq-dev/moq/issues/2433), prototyped as
[#2434](https://github.com/moq-dev/moq/pull/2434). Upstream declined DVB-specific shape in favour of
proxying PIDs ([#2440](https://github.com/moq-dev/moq/pull/2440): service record through the catalog,
SI rebuilt on export keyed by PID). Measured before and after in
[T2](test-2-media-aware-transparency.md).

**That generalisation is load-bearing later.** Carriage keyed by PID, not by table, means an intercepted
PID carries whatever sections it holds — which is why the EIT question below is one PID carrying two
tables rather than adding a field.

### EIT, and where carried SI should live — the question we priced

#2440 left EIT and TDT/TOT out. On a synthetic fixture (no capture here carries EIT), census showed
**opposite revision rates**: EIT repeats byte-identically between event transitions; every TDT/TOT
section is new content and therefore a republish for a table that says only "now". Reported as
[#2800](https://github.com/moq-dev/moq/issues/2800).

Fixtures had to land before behaviour could be argued about: [#2828](https://github.com/moq-dev/moq/pull/2828)
synthesises EIT from any clip (TSDuck, service triplet from PAT/SDT, EPG anchored to TDT; CBR padding
because `tsp` replaces rather than creates packets); [#2920](https://github.com/moq-dev/moq/pull/2920)
adds sparse multi-day schedule and pending-version shapes, wired into `just test` with source-side
positive controls. Procedure and census in
[T2](test-2-media-aware-transparency.md#eit-measured-on-a-synthetic-fixture-and-what-carrying-it-would-cost).

The first carriage attempt was [#2824](https://github.com/moq-dev/moq/pull/2824) (EIT p/f in the
catalog), shaped by a mis-filed ask: carriage is keyed by PID, 0x0012 holds present/following *and*
schedule, so an allowlist change that bounded only p/f could not price what it would admit. Verified
here byte-identical across a version roll (v0 ×27 then v1 ×28, no flapping, no stale version);
**closed unmerged** when design moved to snapshot tracks — the measurement grades a design step, not
shipped behaviour
([T2](test-2-media-aware-transparency.md#eit-pf-survives-the-round-trip-on-2824s-branch-verified-on-the-same-fixture)).

**Does carried SI belong in the catalog or on its own track?**
[#2882](https://github.com/moq-dev/moq/issues/2882); this campaign priced it. The catalog is
whole-state, so one changed section rewrites the document and every subscriber pays at join.
Measured against service count
([T2](test-2-media-aware-transparency.md#what-carried-si-costs-the-catalog-and-why-it-is-a-scaling-question)):

| services | standing catalog | SI share | junction cost |
|---|---:|---:|---|
| 1 | 2,180 B | 34.8 % | 2 republishes in 0.11 s |
| 12 | 6,746 B | 79.2 % | 20 republishes in 0.11 s |
| 40 | 18,428 B | 92.7 % | 61 republishes in 1.27 s |

**The bandwidth is noise** — 1.12 MB against a multiplex of tens of Mb/s. What the numbers indict is
the *join* (18 kB read before media discovery, 93 % of it service information) and the *parsing*.

**A multi-section table is assembled in the catalog in public:** at 40 services the SDT sits at 1 of 2
sections for 5.2 s across 53 publishes while section 0 declares `last_section_number = 1` — incomplete
rather than merely stale; no catalog tuning fixes a whole-state document revised one section at a time.

Those measurements supported per-table snapshot tracks on **coherence grounds rather than bandwidth**,
while showing the tables #2440 shipped would gain nothing from it. Settled in favour of tracks in
[#2909](https://github.com/moq-dev/moq/pull/2909), reviewed here in
[T17](test-17-si-snapshot-tracks.md), including the sparse-schedule case that section counting cannot
validate.

### TDT/TOT — carriage closed, then emission timing

Reported as [#2914](https://github.com/moq-dev/moq/issues/2914), where exclusion was deliberate (a
clock is not state; upstream multiplexer time carries unknown delay). Two findings moved the argument,
one correcting a position this repository had supplied upstream:

- **A clock synthesised from the host would break the EPG that now survives** — EIT times are absolute
  UTC, so clock and schedule must share one time base; relaying EIT verbatim while minting TDT locally
  misplaces every event by the offset between clocks.
- **TOT carries policy, not merely time** — DST dates and per-country offsets are the operator's; no
  exporter can invent them.

Both tables are now proxied from the source on a latest-value slot that removed the content-hash
identity a clock-like table would have churned through. Measured: tables arrive and TOT descriptors are
byte-identical to the source's.

**Emission timing remains the stage distinction.** A constant-delay tunnel forwards each tick — RIST and
SRT deliver TDT with inter-section gaps matching a no-transport control to two decimal places
([T15](test-15-point-to-point-cadence.md)). A stage that rebuilds the multiplex re-emits on its own
grid (~14 s late against a source true to half a second, and below that rate re-sends a time already
asserted, stepping a trusting receiver's clock backwards). Filed as
[#2934](https://github.com/moq-dev/moq/issues/2934): treat the interval as a floor on repetition and
emit on change. **Closed** via [#3793](https://github.com/moq-dev/moq/pull/3793);
`export_test::si_revision_does_not_wait_for_the_interval` passes on `5d0991b9`.

### A liveness risk introduced by the fix — closed by deleting the gate

As proposed, export opened only once every SI entry held a snapshot or reached a terminal state.
Terminal failure was handled (log, keep last snapshot); **a track that neither succeeded nor failed
was not**, leaving the gate shut with no TS emitted, media included, and nothing logged past the
subscribe attempt.

The first fix bounded the wait; the second removed the gate entirely — the answer the join measurement
supports. Nothing in SI is required before a stream begins: PAT/PMT are built locally, receivers
acquire the service layer mid-stream by design, and a late entry matches tuning in just before an SDT
repetition. Any gate lets one stale announce hold the programme dark, and no timeout makes that trade
principled — while the measured 15 ms time-to-first-byte
([T17](test-17-si-snapshot-tracks.md#3-the-join-cost-is-small-and-scales-with-bytes-rather-than-track-count))
means the healthy case still leads with its tables without promising to.

### PCR clustering — reported, fixed upstream in a day, and the fix moved the defect rather than removing it

The exporter conserves the PCR *mean* and destroys the PCR *spacing*. A source profiled at a flat
24.4 ms grid, maximum 24.95 ms, nothing above 40 ms, comes back with the mean conserved to 0.7 ms,
monotonic, and carrying *more* PCRs than the source sent — while 1,123 of its 1,307 intervals fall
under a millisecond and the residual time collects into 107 gaps of up to 319.94 ms. PCR-bearing
packets leave in near-simultaneous clusters; PCR values are timestamps, so none of this is stripped
stuffing.

**This was known for months and deliberately not reported** because the campaign assumed a
downstream CBR groomer would absorb it. [T18](test-18-delivery-latency.md) disproves that: the
repetition figure is identical to three significant figures across a cushion ladder spanning eight
times the depth, unchanged when groomer starvation is removed (18,070 underruns to 5, stuffing to
0.0 %), and unchanged over a real internet path (public internet, cross-host, wire/P1). The groomer
places a PCR only into a slot it was already going to stuff, so insertions track carrier surplus
(**137 → 103 → 28 → 0** as surplus runs 4.1 % → 3.2 % → 0.8 % → 0.0 %) while violations hold flat at
**491, 489, 503, 502** — four insertion rates, one conformance result. **137 insertions were never
going to cover ~490 gaps**, because a stuffing slot falls wherever the carrier runs ahead of
content, uncorrelated with exporter gaps; scaling from the measured point implies a carrier far
above content rate — the ~20 % empty PCR-only windows #1992 abandoned from the downstream side.
**Placement is the exporter's**, because buying it downstream costs the carrier efficiency the
downstream stage exists to provide.

[T8b](test-8b-congestion-control.md)'s provisioned-path matrix writes `moq export ts` straight to a
file with no groomer, with the same clip on the same PID beside SRT and segmented clients in one
session. The source reads an even PCR every 24.65 ms with **zero** intervals above 40 ms; the
exporter reads 31–36 PCRs/s against the source's 41, median interval **0.011 ms**, 85 % below 1 ms,
and 361–399 intervals above 100 ms. **The count of clock samples very nearly survives; only their
positions do not** — a denser cadence would add PCRs inside existing clusters and leave every
violation standing. In `rs/moq-mux/src/container/ts/export.rs`, PCR rides on the first TS packet of
each PES unit on the PCR PID under a `first && (unit.is_pcr || unit.keyframe)` guard, with no
interval-based path at all.

Filed as [#2937](https://github.com/moq-dev/moq/issues/2937), engaging upstream history: dense
uniform PCR ([#1989](https://github.com/moq-dev/moq/pull/1989)), ~20 ms PCR-led windows
([#1992](https://github.com/moq-dev/moq/pull/1992)) with delivery spreading
([#1988](https://github.com/moq-dev/moq/pull/1988)) — all closed after no Sencore IRD operating
point was both smooth and stable without null stuffing. **This campaign's contribution** is that
both horns were measured from the downstream side and a bounded CBR buffer absorbs both (3.2 %
surplus: 18,070 underruns at 87 ms depth; 0 % surplus: 5 underruns at 824 ms depth), at 109 ms
delivery latency over the public internet — so the exporter should own PCR *placement* in the time
domain and CBR egress the byte domain. The issue asked for bounded *interval* placement, not
sparsity; in-house paraphrases ("too rarely", "denser cadence clears the gate") that had reached
`docs/evidence.md`, `docs/comparison.md`, `docs/architecture.md`, and T13/T16 were corrected to
**placement**. A follow-up closed half the open mechanism question from the code (`export.rs` guard)
and added the three-lane control; it also noted for
[#1838](https://github.com/moq-dev/moq/issues/1838) that a monitor reporting only intervals above 40
ms cannot distinguish this defect from loss — a lossy SRT lane posts **538** crossings with median
interval still **24.8 ms** and **0.0 %** under 1 ms.

[#2967](https://github.com/moq-dev/moq/pull/2967) merged as `61678fd32`: one PCR per 25 ms
media-time grid on adaptation-field-only packets, decoupled from PES units. On
[T19](test-19-pcr-grid-verification.md) measurement 1 against the immediately preceding build
(`0.9.12-61678fd32`, **file**, P0): all **2,472** consecutive intervals are **25.000 ms**; intervals
above 40 ms **210 → 0**; sub-millisecond clustering **85.40 % → 0.00 %**; PCR on the announced PID
only, continuity discipline correct. The PR also fixed PCR reserved bits (**0x00 → 0x3F**), which
eighteen prior experiments missed because instruments read values not padding; TSDuck's reference
bitrate for the export went from a meaningless 20.7 Gb/s to 9.57 Mb/s once clustered values stopped
poisoning rate estimates. On reordered content the authored decode clock is a saw and each B-frame
below it is nudged one 90 kHz tick (**11.1 µs**) past the previous DTS — the **11 µs** median the
distribution showed before the code was read. **It does not yet meet the requirement #2937 named:**
#2967 stamps each PCR as its own `Frame`, but `moq export ts` to stdout discards timestamps — on
exported bytes **87.2 %** of consecutive PCR packets sit back-to-back (bursts to 13). Clustering
changed domain: even values at clustered positions.

Filed as [#2984](https://github.com/moq-dev/moq/issues/2984) as a **new issue** rather than
reopening #2937 (the grid fix did what that issue asked inside the boundary it named) or commenting
on [#2978](https://github.com/moq-dev/moq/issues/2978) (bounded sub-chunk loss on `moq-srt`, orders
of magnitude below these clusters). #2967's doc comments state a caller contract: each PCR is its
own frame stamped at its slot so the caller's pacer places it there. **`moq-srt` derives `send_at`
from the frame timestamp; `moq-cli`'s `run_ts` is `write_all` without reading `frame.timestamp`.**
The report is not "add pacing to a transport library" — withdrawn on
[#1839](https://github.com/moq-dev/moq/issues/1839) — but that one stdout caller silently discards
what is not recoverable downstream. [T19 corrections](test-19-pcr-grid-verification.md#corrections):
the `moq-srt` exemplar was broken for media frames; #3006 repaired it while fixing #2984.
**[#3006](https://github.com/moq-dev/moq/pull/3006)** paces stdout on each frame's timestamp as
asked. At the pipe, on-grid share **27.4 % → 56.9 %**, gate failures **18.26 % → 7.45 %**, median
interval **24.69 ms**; **end to end unchanged** on the laptop rig: **118 → 769 ms** latency and **0
→ 1,166** continuity errors on #2967 alone versus **120.0 → 771.6 ms** with #3006 — a build with no
pacing in the regression arm, which rules out the new lead budget as cause. **A groomer consumes
bytes, not arrival times**, so the outstanding ask shifted to byte adjacency. Off-the-shelf `tsp -P
pcradjust` converts clustered positions back into clustered values (**293** intervals above 40 ms,
**87.9 %** sub-millisecond, near-exact match to **87.2 %** back-to-back input); end to end on #2967
alone the lane was worse than before the fix (continuity **0 → 824**, worst interval **228 → 375
ms**, delivery **118 → 769 ms**). The byte-locking groomer **drops 45.9 %** of content structurally
([T19](test-19-pcr-grid-verification.md) measurements 2–3, 6, wire/P1).

**Root cause for residual placement:** [#3334](https://github.com/moq-dev/moq/issues/3334) —
`Export::poll_next` advances the grid only to the slot of the next *pending* media frame, so the
clock follows frame arrival; `write_frame` emits whole media frames in one `write_all`, so PCR can
sit only *between* frames ([T19](test-19-pcr-grid-verification.md) measurement 7: **615 of 626**
early releases are byte-adjacent packets; **7.45 %** gate residue identical on two and eight vCPU).
**[#3351](https://github.com/moq-dev/moq/pull/3351)** merged `4cf216149`, slicing export on the PCR
grid; graded on merge-base `8ed756a31` vs head, one host, **file/pipe**
([T19](test-19-pcr-grid-verification.md) measurements 9–10): adjacency **50.31 % → 0 %**, releases
outside ±10 ms **491/799 → 0–4/745**, p95 **70.3 → 1.5–1.9 ms**, continuity 0; the control
reproduces #3334 with **43.4 %** of PCR packets both adjacent and early as one measured quantity.
Buffer converges to **480 ms** against **500 ms** `--latency-max`, publisher drift ±0.8 ms per
decile — standing lag in the exporter, constant offset not rate error. Against #2967 on the same
rig, byte back-to-back falls **87.2 % → 0.0 %** (measurement 10). **Wire graded** on a real
contribution clip: adjacency **0.0 %**, releases outside ±10 ms **2 of 4,779**, p95 **1.70 ms** —
#3334's invariant holds. **The lane still fails its own conformance gate:** **12.2 %** of intervals
above 40 ms and **811** continuity errors end to end, because a coded frame's bytes belong to their
40 ms of media and CBR smoothing is not in decode timestamps — downstream meets it (cushioned past
**761 ms** displacement the groomer conserves **99.6 %** at 0 continuity errors, exact CBR;
[T19](test-19-pcr-grid-verification.md) measurement 11). **Nothing further is owed upstream on this
line.**

Test contribution [#3335](https://github.com/moq-dev/moq/pull/3335) added upstream
`test/ts/pcr-timing.py` only — no core behavioural change — beside `test/ts/compliance.py`. This
campaign's [`scripts/ts-pcr-timing.py`](scripts/ts-pcr-timing.py) grades value, release and position
in one pass from the stream's own PCR clock; upstream's compliance harness therefore cannot see
#3006's wall-clock release effect, and **#3006's contract has no regression test upstream today**.
Pre-#2967 fails value and release and passes position; post-#3006 passes value and fails the other
two — a test of the defect class, not one implementation. Automated review on #3335 found six real
analyser defects (short adaptation fields, permitted continuity constructions, PCR unwrap, drift
gating, `--live` blocking); fixed at `faac801`, `bbe2ec5`, `e7f1e3cc`. **No campaign number moves:**
T19 continuity figures come from TSDuck. Upstream's `pcr-position` check grades adjacency only
(passes **115**-packet worst gap on a generated fixture and **4,641** on a 1080i25 capture); not
filed — the quantity it misses is downstream's to fix. **Ours:** the byte-locking groomer treated
value cadence and byte-position cadence as interchangeable and on the T19 fixture exited having shed
**67.2 %** — guarded in `mpegts-pacer` ([T19](test-19-pcr-grid-verification.md) measurement 8). On
[#1838](https://github.com/moq-dev/moq/issues/1838) we still hold that byte cadence at moq egress is
the groomer's job; a groomer cannot reconstruct which media bytes a PCR belonged beside once
thirteen slots of clock were written to one byte position.

**The cadence question is settled, negatively.** With all three exporter domains fixed (values,
stdout release, byte placement), the wire above still carried **12.2 %** of intervals above 40 ms,
so an even exporter cadence does not by itself clear the P1 gate; what clears it is the downstream
groomer ([T19](test-19-pcr-grid-verification.md) measurements 10 and 11, and `docs/evidence.md`
§3.2). **Open:** intervals above 40 ms vary by clip (**25.2 %** synthetic CBR, **13.9 %** and **9.1
%** on two contribution captures, **0 %** on a 27.5 Mb/s broadcast mux at native **27 ms** cadence),
unexplained.

### A rewound timeline stalls the whole programme, not just the SI cadence — measurements contributed, issue fixed and closed, **fix later found to regress the complement** (next section)

[#2833](https://github.com/moq-dev/moq/issues/2833) already described the mechanism — the exporter's
last-emission time only advances, so after a backwards jump nothing is due until the timeline
catches up — and asked for PCR and `discontinuity_indicator` handling together. This campaign added
a [comment](https://github.com/moq-dev/moq/issues/2833#issuecomment-5554907607) with what
[T23](test-23-pcr-discontinuity-classes.md) measured, not a new issue.

**What the measurements add.** The title scopes the stall to SDT/NIT repetition; in fact the
exporter stops emitting *everything*, so a rewind is a hole in the programme rather than a gap in
the tables. The cost is **linear in the rewind** — 1 s → 268 ms, 2 s → 1,487 ms, 5 s → 4,514 ms, 10
s → 9,446 ms, 44.7 s → 44,049 ms — which is what "until the timeline catches up" predicts, and which
turns a qualitative defect into a budget. Recovery is a **single 18.3 MB burst** that overran our
groomer's 8 s cushion, so a consumer that survives the outage can still be broken by the re-entry.
Forward jumps recover in **238 ms**; only the backwards case needed handling. **33-bit PCR base
rollover is carried correctly end to end** — 30.080 ms across the boundary in modulo arithmetic,
6,259 PCRs within ±500 ns, zero continuity errors — so the `due` comparison never sees one. On
`2a6d9ebdf`, `discontinuity_indicator: false` is hardcoded at
`rs/moq-mux/src/container/ts/export.rs:1102`, and it shows on the forward case too, where the
exporter reproduces its own +29.05 s timebase change with the flag clear.

**Outcome.** [#3375](https://github.com/moq-dev/moq/pull/3375) opened citing the comment — *"Still
needed after #3351… rewinds stop the entire program output until timestamps catch up"* — and merged
as `0e61e3520`, closing #2833. It restarts the exporter on rewind: uncommitted media discarded,
timing and table state reset, **the first new PCR flagged**, continuity counters of discarded bytes
rolled back, plus `moq_mux::container::ts::Export::discontinuity()` so a consumer can see the event.
**We supplied the verification the fix shipped without:** the maintainer's validation is the
repository harness, not a rerun of the external stimulus campaign, so nothing had graded a placed
timeline event through a full lane. Re-running all six arms unchanged against `d88c2ee99` puts every
one at the control's content gap; the before/after table, three-point timeline evidence and collapse
of the downstream buffer requirement went back in a [#3375
comment](https://github.com/moq-dev/moq/pull/3375#issuecomment-5557693602). Detail is in [T23 §
against the fix](test-23-pcr-discontinuity-classes.md#against-the-fix-3375).

**Follow-ups.** [#3529](https://github.com/moq-dev/moq/pull/3529) discharges the forward-jump flag
gap #3375 left: arm C unchanged on current `main` now emits the flag and a faithful **11 ms** jump
(not **961 ms** short), with upstream's `a_signalled_reset_reaches_the_exported_clock` as the
end-to-end shape the campaign graded ([T23 § against
#3529](test-23-pcr-discontinuity-classes.md#against-3529-current-main)). #3529 also fixes policy:
the exporter reports what the source **declared** and will not infer a break from a timestamp step;
unsignalled jumps remain unflagged by design, and signalled forward conformance no longer depends on
`mpegts-pacer`. An earlier draft from T21's looping stimulus claimed permanent PCR latch; no T23 arm
reproduces that — see [method notes](method-notes.md) §6.

### #3375 regressed the complement: a *non*-rewinding source now stalls video and primary audio — reported as [#3533](https://github.com/moq-dev/moq/issues/3533)

**The trade.** #3375 fixes the measured rewind case ([T23](test-23-pcr-discontinuity-classes.md))
but on a **continuous** timeline with **content joins**, the fixed exporter stalls video and MPEG-1
audio permanently ([T27](test-27-liveness-detector.md)). `git bisect` over 53 commits names first
bad **`0e61e35`** (#3375) in `export.rs`; parent `025613d` held **9.0–9.8 Mb/s** across seven joins,
#3375 **0.31 Mb/s** from the first join with no recovery.

| source | parent `025613d` | `#3375` `0e61e35` |
|---|---|---|
| **true rewind** — `tsp --infinite`, every 30 s | **0.00 Mb/s** from t = 40 s (the #2833 behaviour) | **8.66 Mb/s** mean, recovering after each rewind |
| **continuous timeline, content join** every 30 s | **9.0–9.8 Mb/s** throughout | **0.31 Mb/s** — only PSI, AC-3 and teletext survive |

**The exporter introduces a rewind that is not on the wire.** Per-PID liveness on each build's
output at the same join: parent **0 delivered-clock discontinuities**, video and MPEG-1 audio live;
#3375 a step **backwards by 119.35 s — one pass length** — after which PID 111 (AVC) and PID 121
(MPEG-1 audio) go dead and never clear. Since the parent sees no discontinuity on the same bytes,
the rewind is generated inside the new recovery path. **Attribution is bounded:** not the source
(**0 backward PCR steps** over two 1200 s passes); not relay or publisher — while 60 incumbent
subscribers stuck, a **freshly joining subscriber** was served at **8.9 Mb/s** (143,872 video
packets in 25 s) from the same broadcast; not `--latency-max` or fan-out (N = 4 stalled together).
Continuous timeline with content joins is what a real encoder emits; the pre-#3375 failure needed a
rewinding stimulus the lab manufactured.

**Mechanism (from the diff).** `Track::admit` fences tracks in an older generation unless a track
both increments its discontinuity counter and steps backwards; `rewind()` leaves every track with a
timeline in the old generation on a backwards boundary — one backwards report fences the rest, and a
fenced track whose source never rewinds cannot re-join. Video-only sources stay clean on both builds
(**~1.9 Mb/s** across five joins). Which audio comparison yields `backwards = true` with zero
backward PCR steps is **not** established.

Filed as [#3533](https://github.com/moq-dev/moq/issues/3533). **Closed** by
[#3784](https://github.com/moq-dev/moq/pull/3784) in
[#3793](https://github.com/moq-dev/moq/pull/3793) (`5d0991b9`): `export_test` passes and
[T40](test-40-continuous-join-through-srt.md) no longer reads the **0.31 Mb/s** stall through SRT.
On homogeneous `5d0991b9`, `moq import ts` can still exit at the first join with *frame timestamp is
below the live edge* ([T40](test-40-continuous-join-through-srt.md) § `main-5d0991b9-swap`) —
monotonic-timeline enforcement separate from the export fence, filed as
[#3798](https://github.com/moq-dev/moq/issues/3798) because `reanchor()` from the #3533 fix applies
to legacy audio only.

### The mux rate the lane could not carry — closed upstream, citing this campaign's groomer

**The finding.** `moq export ts` carried content only: null packets do not cross MoQ, so
reconstructed streams had no stuffing and no declared multiplex rate —
[`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer)'s README line that the rate is *"not
recoverable from MoQ"* is quoted in the fix.

**Closed** by [#3831](https://github.com/moq-dev/moq/pull/3831): import measures whole-multiplex
rate on the PCR PID (nulls included), publishes `mpegts.muxRate` once half-second windows agree
within 2 %; export balances null stuffing ahead of each clock packet without delaying media;
`--mux-rate` overrides; absent rate exports byte-identically to before.

**Verified here** ([T13](test-13-downstream-grooming.md) § *The exporter now stuffs and declares a
rate*, file domain, `0.11.2-615d166d`): stuffing **4.93 %** vs source **4.69 %**; declared
**9,981,799 b/s** vs **9,945,951 b/s** (**+0.36 %**); explicit `--mux-rate` **+0.25 %**; continuity
clean. **PCR accuracy and repetition are unmoved** (P2: 0/1,807 vs 0/1,892 inside 481 ns; P1: 11.34
% vs 11.21 % above 40 ms) — the P2 gate becomes answerable on ungroomed egress but still fails
comprehensively; a groomer remains required for both PCR criteria. The absent-rate path is untested
on a genuinely variable source (filtering nulls from CBR still yields a stable lower rate).

---

## 2. Audio robustness: three defects, two closed

### Frame-sync loss killed the whole publisher — closed in two days

**The finding.** A single damaged byte in an MP2, AC-3 or E-AC-3 frame header terminated the
publisher outright and took every other track with it — video, teletext, all three SCTE-35 PIDs —
while the video path resynchronised through identical corruption. The report paired a deterministic
one-bit reproducer (monotonic PTS, no discontinuity) with a one-line root cause — the legacy-audio
PES loop propagates header-parse failure with `?` and never scans for the next sync word — against
the module's own *"rejected, never mis-described"* principle and the TS and video resync precedents
already in-tree.

Reported [#2729](https://github.com/moq-dev/moq/issues/2729), fixed
[#2751](https://github.com/moq-dev/moq/pull/2751) within two days: scan forward to the next
sync-word candidate and **confirm before trust** (64 KiB bound), matching the TS layer's rule.
Verified on three one-byte mutants of a 20 s DVB capture:

| Arm | one-byte change | pre-fix | post-fix |
|---|---|---|---|
| MP2 header | sync `0xFF` → `0xFE` | **died at 12 s**, rc=1 | end of file, rc=0 |
| H.264 start code (control) | `0x01` → `0x00` | survived | survived |
| Full A/V looped | none — `--infinite` wrap | **died at first wrap** | 2+ wraps |

By PTS set: one **24 ms** MP2 frame dropped at the damage point; video, AC-3, teletext and SCTE-35
untouched. The fix also closed AAC split across a PES boundary. **Correction:** the original
video+AC-3 loop row does not reproduce — wrap fatality depends on cut position splitting an audio
frame, not codec alone; the MP2 single-bit arm remains decisive.

### A splice publishes a *substituted* frame — closed, with two measured residuals

A corrupt byte drops a frame; a splice with an intact header publishes a **substituted** frame
(bytes from both sides), invisible on continuity or timestamps. Alien detection: a frame whose bytes
appear nowhere in the source elementary stream (`ts-splice-audit.py`).

Split [#2802](https://github.com/moq-dev/moq/issues/2802); first fix
[#2823](https://github.com/moq-dev/moq/pull/2823) extended confirmation to a frame beginning in a
carried tail. **Tested on real content, the first fix changed nothing:** 3 alien frames per audio
PID before and after, same hashes and positions — this mux never splits audio across a PES boundary,
so the carried tail is always empty and foreign bytes join the same truncated PES at the wrap. The
route that works was already implemented for sections: `SectionReassembler` drops partials on
continuity gap, discontinuity or transport error; the PES path had not read the counter. Upstream
reproduced in-tree and **rescoped the PR to five commits**, generalising those rules to PES PIDs.
Merged; re-verified across four arms — mixed frame gone on current `main`.

**Two measured residuals.** (1) Counter-contiguous wraps (~one cut in sixteen per PID; **4,062 of
30,000** positions contiguous for at least one audio PID) bypass the guard — **1 alien AC-3 frame**
per wrap at such a cut; AC-3 CRC would catch it but **0 of 826 MP2 frames** here carry CRC. (2) AC-3
salvage: **~256 ms** of good audio lost per splice post-merge (8 complete frames absent by hash);
MP2 loses nothing on the same branch.

### A recovered stream is signalled nowhere — closed, exactly as asked, and it exposed a bigger gap

Reported [#2798](https://github.com/moq-dev/moq/issues/2798), scoped to observability. **Closed by
[#3372](https://github.com/moq-dev/moq/pull/3372)** (`d554c75d5`): `tracing::warn!` on a *completed*
resync and per-PID counters on `Import::stats` — `resyncs`, `discarded`, `unconfirmed` — documented
as what an operator alarms on, with no protocol change. [T24](test-24-partial-media-plane-stall.md)
verified independently on 60 s suppressed audio (`discarded=466 resyncs=1`). **Two residues:** the
warning fires on recovery, so it is late by the outage's duration; and it exists for **audio only**
— T24 measured **57 s** without video access units and got no log, counter or stats entry, because
`Stats` was audio-frame-sync by design, though the importer already demuxes every elementary stream.
Filed [#3489](https://github.com/moq-dev/moq/issues/3489) as an extension, not a behaviour change;
implemented in the next section.

What #3372 answered: after resync the subscriber TS carries **0 continuity errors**, **0 signalled
discontinuities**, and audio stepping 24 ms → 48 ms across the hole, with no log, counter or
discontinuity signal above TS — policy in the doc comment, so silence is intended. **A TR 101 290
monitor at egress therefore sees a fully conformant stream with no indication that anything was
lost** ([Architecture](../docs/architecture.md) §6.2). While the splice defect stood, substitution
was worse than a drop; #2823 turned substitution back into a gap without touching reporting. Two
importers on identical input dropped the same frame — not a 1+1 redundancy risk. What remains: **the
fix converted a maximally loud failure into a completely silent one** — the lab discovered mid-frame
wrap only because the source crashed 216 times.

### Per-stream liveness in the TS importer — contributed as [#4502](https://github.com/moq-dev/moq/pull/4502) and [#4506](https://github.com/moq-dev/moq/pull/4506), both merged

**The defect** is #3489, as filed above. `Import::stats` had a row only for audio that had lost frame
sync, so a video, Opus, verbatim-PES or SCTE-35 PID had none, and an absent row read as healthy.

**The contribution.** #4502 gives every carried elementary stream a `StreamStats` row with `units`, the
access units delivered, and `quiet`, the transport time since the last one or since the PMT declared
the PID. `quiet` runs on the PCR rather than on the importer's media clock, which follows the video PTS
and so stops with the very stream it has to catch, and a PCR step over the mux-rate meter's 1 s bound
adds nothing, so one corrupt PCR cannot add hours of silence to every PID, the failure
[T27](test-27-liveness-detector.md)'s detector hit. `moq import ts` logs `elementary stream stopped
delivering access units` once per silence, keyed on the count. #4506 moves that logger into `moq-mux` as
`ts::StatsLog` and has the SRT publisher sample it under an `srt{path=…}` span, so a server carrying
several ingests names the one affected. Merged as `395a92cbd` and `c2e7b5815`.

**Verification**, P0, on the PR builds before merge: in-process tests on fixture files, with no wire
and no cross-host run. With #3489's stimulus (one PID's PES suppressed for a window, its PCR kept in
adaptation-only packets, continuity renumbered), the HEVC, MP2 and SCTE-35 arms each stop counting
across the window while the unsuppressed control advances; `quiet` grows within 50 ms of the elapsed
program clock, a peer stream keeps counting, and the stream recovers afterwards. Through SRT, only the
suppressed feed's video PID is logged. There is no *before* figure, because `main` had neither the
fields nor the rows.

**Open.** No threshold and no TR 101 290 `PID_error` counter exist; the monitoring plan
[#4496](https://github.com/moq-dev/moq/pull/4496) adopts these rows as that check. If the PCR PID itself
stops, every `quiet` freezes instead of growing; the log lines still fire, because they compare counts,
but a consumer reading `quiet` alone would miss it. A sparse stream such as SCTE-35 is logged as stopped
between cues, by design. Nothing has run against a live feed; the arm that would settle it is T24's
60 s video suppression, repeated on a build that carries both changes.

### Per-stream liveness at the TS exporter — contributed as [#4577](https://github.com/moq-dev/moq/pull/4577), merged

**The defect** is the egress half of [#3489](https://github.com/moq-dev/moq/issues/3489). In
[#3533](https://github.com/moq-dev/moq/issues/3533), video and primary audio stalled at the exporter
while PSI and the other PIDs kept flowing, and only [T27](test-27-liveness-detector.md)'s per-PID
detector on a subscriber found it; `Export` reported nothing per PID. The upstream quest set the shape:
the importer's rows at egress, `quiet` on the output's own PCR, and no ETSI counters. It also corrected a
stale attribution: the exporter and the `test/ts` graders gave TR 101 290 a 40 ms PCR repetition limit,
where V1.4.1 sets 100 ms, and its Note 2 records that the 40 ms precondition was removed from
TS 101 154 in 2005.

**The contribution.** `Export::stats` returns one `ts::Stats` row per elementary stream in the PMT,
named by the track suffix an import of the output would give that PID. The importer's liveness meter
runs on the PCR the exporter writes, reset wherever it flags a discontinuity, and `units` is credited
when a span leaves the mux buffer, so a rewind does not count what it discards. `moq export ts` logs
through the logger `moq import ts` uses. The PR also moves the `test/ts` repetition defaults to 100 ms,
and replaces the README's "VBR, no null packets, PCR once per frame" with what the exporter now does:
it pads to the recorded multiplex rate and writes a PCR every 25 ms of media time.

**Verification**, P0 and P1, on the PR before `main` was merged into it; it has not been repeated on the
merged build. At P0, on H.264 plus two AAC tracks, stopping video and one audio track halfway through a
6 s run freezes those two rows, whose `quiet` reaches 2.975 s and 3.0 s of the 3 s stall, while the
surviving audio keeps counting and the PAT keeps repeating. At P1, live and co-resident on a local
relay, `CNNiEMEA2.ts` with its MP2 PID dropped about 19 s in made `export ts` log `pid=121
track=".mp2" units=729 quiet=Some(850ms)` once, about a second after the publisher's own line, while
the PAT, video, AC-3 and teletext held their rates. There is no *before* figure, because `main` had no
egress rows.

**Open.** Sparse SCTE-35 PIDs flap in the shared logger, somewhat more at egress than at ingest (21
lines against 16 over the same run), because the exporter delivers by group. A whole-programme stall is
not reported at egress: the output PCR stops with it, so every `quiet` freezes, and the CLI samples
only when a frame goes out; that stays the job of the wire monitor downstream. The corrected default
loosens the hard `pcr-value-interval` check from 40 ms to 100 ms, so a regression that spaced PCRs
between the two would now pass. Nothing has run against a live feed cross-host.

### TR 101 290 counters at ingest — contributed as [#4750](https://github.com/moq-dev/moq/pull/4750), merged

**The defect** is the ingest half of [#1838](https://github.com/moq-dev/moq/issues/1838). `moq import
ts` and the SRT gateway graded nothing of the feed they received beyond PSI CRCs and the liveness rows
above, so a feed that lost sync, dropped packets, ran its PAT late or gapped its PCR was invisible at
ingest until something downstream failed. The upstream quest set the scope: the TR 101 290 V1.4.1
checks a contribution feed is graded on, at ETSI's fixed limits, as counters only.

**The contribution.** A private `ts::health` module counts `TS_sync_loss`, `Sync_byte_error`,
`PAT_error_2`, `Continuity_count_error`, `PMT_error_2`, `Transport_error`, `PCR_repetition_error`,
`PCR_discontinuity_indicator_error` and `PTS_error` beside the existing `CRC_error`, and changes nothing
published. Sync is graded on its own 188-byte grid with ISO 13818-1 Annex G.1 hysteresis, lost after
two corrupt sync bytes and acquired after five; table and PTS intervals run on the PCR-stepped program
clock the liveness rows already use; a packet with TEI set counts `Transport_error` and nothing else.
The shared logger writes one line with every total whenever any of them moves, so the CLI and the SRT
gateway both report them. `PID_error` is left to the liveness rows, and `PCR_accuracy_error` is not
measured, because the importer has no arrival clock of the precision it needs.

**Verification on the PR**, P0 and P1 (file domain at P0, live and co-resident at P1), before the
maintainer's one pre-merge fix. At P0 there are 13 tests, one stimulus per check with a control each
way, each imported both in whole packets and in 100-byte pieces; five of six mutants of the checks were
killed and one is equivalent. Every `test_data` capture reads zero except `kyrion_mpeg2av_ac3.ts`,
which reads two `PAT_error_2` and two `PMT_error_2` against a PAT repetition TSDuck measures at 811 ms.
On the 72 s `t23_F` excerpt of `CNNiEMEA2.ts` the clean file reads zero, twenty packet-aligned 7-packet
drops read 28 continuity errors (split 20, 3, 4 and 1 over four PIDs, exactly TSDuck's `continuity`
plugin on the same file), one TEI packet reads one transport error, and twenty unaligned 1,456-byte cuts
read 20 sync losses and 40 sync-byte errors. At P1, PCR-paced by `tsp` into `moq import ts` on a local
relay, the same counts are logged. Through `moq-srt`, fed by `srt-live-transmit` 1.5.6 from a pipe,
`ts_sync_loss` climbs from the first second, before any drop, to 900: that is the sender's zero-padding
of short reads, recorded under [#4581](https://github.com/moq-dev/moq/issues/4581) below, which the
counter now shows directly. Decode throughput, best of 20, is 1,091 MB/s before and 1,054–1,086 MB/s
after on the excerpt.

**On the merged build** (`main` at `83ce47fe`, which also carries
[#4733](#one-malformed-packet-ends-a-ts-ingest--reported-as-4581-fixed-by-4733-merged); P1, live,
co-resident, the same rig and excerpt) the counts are unchanged. The clean feed logs no line, two
repeats of the aligned drops each read `continuity_count_error=28`, TEI on the video PID and on the
audio PID each read `transport_error=1`, and the SRT arm, whose padding is not deterministic, reads
906 sync losses and 29 continuity errors against 900 and 29 on the PR.

**Merge.** On `main` as `19563812f` since 2026-10-03, after the maintainer fixed the one defect review
found: a PMT revision that dropped a stream left its PTS timer running, so `PTS_error` grew on a PID the
programme no longer listed. It is not in the 2026-10-03 releases (moq-cli 0.14.0, moq-relay 0.17.0),
which ship from the `release` branch. Review also raised a resource point that holds. Every importer now
keeps continuity state, including the last payload packet, for every non-null PID it sees, where before
only routed PIDs had any; that is at most about 1.5 MB per importer, and `Programs` does not cap how many
importers the first PAT creates. We offered two follow-ups, keeping the packet only for PIDs the PMT
lists or grading the all-PID checks once in `Programs`, and have had no answer.

**Open.** An unsignalled forward PCR jump below the importer's 1 s step bound stretches the program
clock, so the PCR checks count the jump and any table or PTS the stretch makes late counts as well; the
tests assert this rather than hide it. Interval resolution is the PCR spacing. The counters stop at
ingest, which leaves egress grading to the wire monitor downstream. Nothing has run cross-host.

---

## 3. Resilience and redundancy

### The exporter died on session loss — closed

`moq export ts` exited the instant its session dropped — the single most consequential
transport-resilience gap for primary distribution, because a broadcast subscriber must ride out relay
maintenance unattended. The reconnect loop stayed alive; the sink task was fatal
([#2459](https://github.com/moq-dev/moq/issues/2459)). Closed by
[#2469](https://github.com/moq-dev/moq/pull/2469) (broadcast *linger*): the relay keeps the broadcast
announced for the reconnect window and a re-attaching source splices back; a clean unannounce still
tears down immediately. Measured surviving relay kill and restart with byte-identical output.
[#2647](https://github.com/moq-dev/moq/pull/2647): re-attach within seconds of a relay returning; a
dead relay errors in tens of seconds — the axis for a supervisor deciding to re-home a subscriber.

### A cancelled write dropped bytes and said nothing — closed, in a different repository

Exporting over the WebSocket fallback transport produced a flood of `WrongSize` / `FrameTooLarge` group
evictions and then killed the process, while the identical broadcast over QUIC on the same path was
clean. Reported as [#2265](https://github.com/moq-dev/moq/issues/2265) as two defects rather than one.
The framing half root-caused in `web-transport`: `SendStream::write_buf` removed bytes from the
caller's buffer and *then* awaited queue capacity, so dropping that future stranded the chunk with no
error — the stream finishing cleanly **with a hole in the middle**
([moq-dev/web-transport#323](https://github.com/moq-dev/web-transport/pull/323)). Callers hit it
constantly because the publisher races `write_all` against a priority-change channel on every group
boundary while the outbound queue holds eight frames. **The trigger is egress backpressure, not
WebSocket.** The fallback transport is only where this rig was slow enough to see it, which matters for
§6 clients that abandon QUIC on a 200 ms timer. Both halves closed with that fix — with corrupt frames
gone there was nothing left to be fatal about — so the resilience half was never addressed on its own
terms; §2's audio work is the part that did land.

### Active/active source failover — shipped, bounded

**The problem as found.** Two publishers announcing the same broadcast to one relay did not form a
standby pair: the moment the second announced, the relay declared the path unroutable and tore down
**both**. Across a two-relay mesh the pair coexisted but never failed over — graded well beyond one
full idle timeout, so this was the mechanism and not the detection budget. What was missing was the
*selection* rule that makes a relay offer a peer a route other than the one it is already serving
through.

[#2473](https://github.com/moq-dev/moq/pull/2473) (issue
[#2461](https://github.com/moq-dev/moq/issues/2461)) supplies per-peer announce selection advertising
the best route whose hop chain *excludes* the requesting peer, exclusion-aware serving, first-hop
content identity in SETUP rather than inferred per announce, and `moq --origin <id>` so a 1+1 pair
declares itself interchangeable — explicitly, because the relay is content-agnostic.
[#2629](https://github.com/moq-dev/moq/pull/2629) generalised the same policy to draft-17+. Cost
routing alone ([#2424](https://github.com/moq-dev/moq/pull/2424)) could not close it: with both relays
and all clients opted in the mesh behaved as before, because **pricing decides between the routes a
relay is willing to offer and does not create one.**

**What remains open.** A graceful source exit is not failed over: the relay propagates completion and
the subscriber terminates, because it cannot distinguish "this source is done, and so is the content"
from "this source is done, but an interchangeable one exists". Covered by upstream model tests as
intended semantics — failover covers host loss, not the common clean exit. Remedy specified in
[#2610](https://github.com/moq-dev/moq/issues/2610) (publisher-minted epoch plus `Ended`).
**Specified, not shipped.**

**On the build under test the failover picture has moved, and both new findings are reported.**
`ffa5b81b` renamed the knob to `--hop <id>` and refuses `--origin`. On one relay two publishers now
coexist and a hard kill fails over within the idle timeout; in the mesh a hard kill fails over for the
dead publisher's relay, bounded by the later of detection and the standby's group lag
([T6](test-6-relay-resilience.md) § *Single-relay standby on the current build*, § *Mesh source
failover*).

- **A shared-hop standby that arrives after the subscribers ends every one of them with `not found`
  — reported as [#4352](https://github.com/moq-dev/moq/issues/4352).** Measured as the race the mesh
  drill once found as `Unroutable`: two of two runs on one relay on `ffa5b81b`, two of two on `main`
  at `2b689c24`, and on the standby's relay in the mesh ten of ten on `ffa5b81b` and twelve of
  twelve on `main` (T6). In the one run where the publishers arrived together it did not occur.
  Upstream's quest
  [`quest/m1/hop-aligned-import.md`](https://github.com/moq-dev/moq/blob/main/quest/m1/hop-aligned-import.md)
  — now titled *Same-epoch importers publish identical tracks* and listing Closes #4352 and #4354 —
  diagnoses it as a standby refusing every track until it has parsed its PMT. **Open**; the planned
  fix is not landed; our counts are the before-measurement on the issue.
- **A fast switch to a same-hop standby ends `export ts` with `TimestampRewind`.** On `ffa5b81b` a
  SIGINT made the relay move to the standby and the exporter abort. On `main`, where the CLI closes
  the session on SIGTERM as well, every clean exit (SIGINT, SIGTERM, end of input) is switched at
  the signal and aborts the exporter: six of six, whether the publishers started 2 s apart or
  together. A diagnostic exporter shows what it is handed at the switch: the standby's groups under
  higher sequence numbers than the last one read, carrying media from 0.17–5.6 s before the live
  edge (T6 § *What the exporter is handed at the switch*). **Reported as
  [#4354](https://github.com/moq-dev/moq/issues/4354)**, with the mesh splice floor included as the
  converse case. On `main` every splice that waited for the standby's numbering to reach the floor
  ended relay A's exporters on the live-edge error, 8 of 8, and only the two runs whose standby was
  already past the floor resumed (T6 § *Mesh source failover*). Upstream's same quest diagnoses
  #4354 as each importer numbering groups from its own per-process counter, so after a failover
  `export ts` sees a timestamp rewind. Its plan derives a group's sequence from its keyframe's PTS
  and announces only once tracks are known; it requires hop removal
  ([`quest/m0/broadcast-epoch/hop-removal.md`](https://github.com/moq-dev/moq/blob/main/quest/m0/broadcast-epoch/hop-removal.md),
  gating the next release), where `--epoch` replaces `--hop`, and a redundant pair shares an
  explicit epoch. Open PR [#4741](https://github.com/moq-dev/moq/pull/4741) makes the path the only
  broadcast identity — *restarting group numbering requires a new broadcast name*. **Open**; fix
  planned, not shipped. Current `main` replaced the consumer's live-edge floor with a rule that
  group starts must not fall, which cuts the
  [#4733](#one-malformed-packet-ends-a-ts-ingest--reported-as-4581-fixed-by-4733-merged) failure
  class but should still refuse this one, since the standby's groups start before the last group
  read; the same-hop switch arm of [T6](test-6-relay-resilience.md) on a current `main` build is the
  before-measurement for that quest.

Without a shared hop on `ffa5b81b`, the standby relay's own subscriber freezes silently at the
failover; `main` no longer fails over between publishers that declare no shared hop, which its front
rules make deliberate. The splice floor — standby group lag adding to the outage — is the
group-sequence floor of #2534 met by a 1+1 standby; the maintainer's position on #2545 covers it, and
it went into #4354 as the converse of the rewind rather than a separate report.

### A multi-programme TS through `import ts` — reported, and answered by programme selection

The importer scopes itself to single-programme input in a code comment, and a real MPTS shows what
that costs ([T10](test-10-mpts-multiservice.md)). On both builds the exporter flattens the multiplex
into one PAT entry and one PMT carrying every programme's streams, while the carried SDT and EIT still
list the other services. On `ffa5b81b` programmes on independent clocks abort the publisher with
*frame timestamp is below the live edge*. On `main` at `2b689c24` the same input completes with exit
0 and loses most of two programmes' video, and even on a common clock SCTE-35 and part of programme
1's audio are lost; programme 1 alone is clean. The ask is framed as "refuse an MPTS loudly, or select
one programme on purpose", not as MPTS support. Reported as
[#4353](https://github.com/moq-dev/moq/issues/4353). Bisected since: #3997 removed the refusal, and
#4122 introduced the common-clock loss; the bisect is on the issue. The measured mechanism is the
section lane through which every programme's video advances the section clock; a build that gives that
clock one lane per video PID removes every re-anchor and restores SCTE-35 and audio to the parent's
level (T10 § *On upstream `main`*). Upstream's planned default refusal of multi-programme input, and
its removal of the anchor, would each moot it; the A/B result is on the issue.

**The refusal has since landed, with selection**, in [#4505](https://github.com/moq-dev/moq/pull/4505)
(next entry). On `main` at `6f1a9e33` an unselected multiplex is refused with exit 1, and on the T10
rig every programme is carried on `mpts3.ts` and `mpts3-cc.ts` alike, independent clocks included, in
four of four runs (T10 § *The split on the T10 rig*). The issue itself is still open on the tracker.
What a selected programme still carried of the other services is the next entry.

### A selected programme still carried the whole multiplex's SI — contributed as [#4580](https://github.com/moq-dev/moq/pull/4580), merged

**The defect.** [#4505](https://github.com/moq-dev/moq/pull/4505) answered the selection half of
[#4353](https://github.com/moq-dev/moq/issues/4353): `moq import ts --program <n>` imports one programme
of a multiplex, and `--program all` publishes each as its own broadcast. SI capture was left as it was,
so a selected programme's broadcast still carried the source's SDT actual and every service's EIT.
Measured on `main` at `6f1a9e33` with a three-service MPTS and `--program 1`, the `export ts` output
carries only programme 1's PIDs, yet `tsp -P analyze` counts three services, two of them with no PIDs,
and EIT present/following rides along for all three. A receiver scanning that stream finds two ghost
services.

**The contribution.** The upstream quest (`quest/m2/ts-program-si.md`, planned in
[#4507](https://github.com/moq-dev/moq/pull/4507)) settled the shape, and the PR follows it. Under an
explicit selection, the importer's SI capture drops EIT actual sub-tables for other service_ids and
rebuilds each SDT actual snapshot as one section holding only the selected service's entry, with a
fresh CRC-32/MPEG-2. NIT, BAT, SDT other, EIT other and TDT/TOT pass through.

**Verification**, P0 and P1. At P0, five in-process tests use a synthetic two-service multiplex whose
SDT spans two sections; four fail with the selection disabled. At P1, a 30 s PCR-paced build of T10's
`mpts3.ts` was run through `import ts --program <n>` on a local relay and captured from `export ts`: on
`main` `6f1a9e33` with `--program 1`, three services and three EIT present/following services; on the
#4580 branch, one service and one EIT for each selected programme (including one 59-byte SDT section for
programme 1 and one 38-byte section for programme 3). TSDuck decodes the rebuilt SDT; local
`just check`, the `test/ts` default, real-capture and open-GOP arms, and upstream CI passed. These
figures were measured on the PR before merge and have not been repeated on the merged build.

**Merged** into `main`. Review added CRC rejection for corrupt SDT sections and committing a selected
SDT revision only once every section has arrived.

**Open.** The `test/ts` `--pair` arm fails its NIT and SDT/BAT anchor checks on `main` at `6f1a9e33` and
on the branch alike: the grader attributes both exporters' emission points to a timer started with each
exporter rather than to the media. That arm is not in CI and has no quest. Nothing has run against a
live multi-programme feed or cross-host.

### A PSI table spanning packets, or one bad CRC, ended a TS ingest — contributed as [#4584](https://github.com/moq-dev/moq/pull/4584), merged

**The defect.** The importer read the PAT and PMT through the `mpeg2ts` 0.6.1 reader, which parses a
table from a single packet, rejects a nonzero `pointer_field`, and ends the import on any error. A valid
PMT too long for one packet, a PAT listing more than about 40 programmes, or one flipped bit in a PAT
repetition's CRC therefore ended `moq import ts`. `--program all` found the PAT in a single packet too.

**The contribution.** The upstream quest (`quest/m1/ts-psi-reassembly.md`, planned in
[#4507](https://github.com/moq-dev/moq/pull/4507)) settled the shape, and the PR follows it. The
importer owns the packet demux: the PAT and every PMT go through the section reassembler already used
for SCTE-35 and SI. A section whose CRC-32/MPEG-2 fails is dropped whole and the last good table stays
in force; each drop counts in a stream-wide `crc_error` in the importer's stats.

**Verification**, P0 and P1. At P0, tests cover a PMT spanning two packets, a PAT behind a nonzero
`pointer_field`, a fifty-programme PAT, and corrupt repetitions. `decode` throughput on
`kyrion_mpeg2av_ac3.ts` roughly doubled: from 876–894 MB/s on `main` at `6f1a9e33` to 1,780–1,815 MB/s
on the branch. At P1, the `test/ts` default, real-capture and open-GOP arms matched on both builds; one
bit flipped in the 20th PAT's CRC made the publisher on `main` exit after 0.5 s with *CRC32 mismatch*,
while the branch dropped one section and passed every check; a PMT padded to two packets imported on the
branch but `export ts` then failed on write length. Local `just check` and upstream CI passed. These
figures were measured on the PR before merge and have not been repeated on the merged build (including
the maintainer's change to `--program all`, which seeds each programme's importer with the assembled PAT
rather than replaying bytes).

**Merged** into `main`.

**Open.** The exporter still writes the PMT through `mpeg2ts`, which cannot emit a section longer than
one packet (*failed to write whole buffer*), so a long PMT now imports but does not round-trip. Sections
dropped for other reasons (a malformed adaptation field, a parse failure) are not counted yet, since the
TS import health quest owns `PAT_error` and `PMT_error`. Nothing has run against a live feed with long
PSI.

### Three values the exporter mints per process — two closed, one declined and since planned as an opt-in

A 1+1 pair cannot be byte-identical while the exporter renders anything from its own process state
rather than from the broadcast. Three such values were isolated ([T12](test-12-dual-path-handoff.md)):

- **SI emission cadence**, anchored to process start, landed tables on slots where the partner carried
  video: measured at **0.00 %** frame agreement for SDT and NIT over a 45 s overlap. Fixed by
  [#2825](https://github.com/moq-dev/moq/pull/2825), which takes a single-track pair to 100 %. The
  review mattered: the form first proposed inflated PSI and **landed inconsistently, costing 5.9 points
  of agreement** — a one-character change from `!=` to `>` in the due check, which stops a backwards
  timestamp counting as a new slot. **It merged in the `>` form, changing its own measured result**,
  which is the argument for treating evidence measured only on a pre-merge PR as provisional. **A
  residual survives the fix**: #2825 moved the cadence from wall-clock into media time, but its
  *origin* is still the first frame the exporter saw, so two legs that join at different moments run
  the same period at different phase — see *The residual #2825 left* below.
- **Continuity counters**, numbered from process state, leave exporters that did not start together
  permanently offset by a constant — the single field whose masking lifts agreement to ~98 %. Filed as
  [#2779](https://github.com/moq-dev/moq/issues/2779), and prototyped here: padding each span to a
  multiple of 16 packets takes the same pair from 0.4 % to 99.9 % on single-track content and from 24.6 %
  to 93.6 % on multi-track, at **10–18 kb/s per PID** almost regardless of payload. **Declined upstream.**
  [#3868](https://github.com/moq-dev/moq/pull/3868) closed the issue as won't-fix. **Byte-identical 1+1
  from two independent exporters is not obtainable from upstream today** without the padding filter or a
  receiver that merges on something other than the whole packet. **`export ts --sync`** is planned in
  `quest/m2/ts-hitless.md` ([#4680](https://github.com/moq-dev/moq/pull/4680)); nothing of it is
  implemented.
- **Audio/video interleave**: the exporter emits the earliest *available* frame rather than the earliest
  frame, so legs whose bytes arrive at different moments order the same media differently. Multi-track
  content therefore stops at 94–96 % even when co-started, and at **75.56 %** once the two chains are
  fully independent. Filed as [#2829](https://github.com/moq-dev/moq/issues/2829). **Fixed by
  [#4001](https://github.com/moq-dev/moq/pull/4001)** (§ *#2829 and #3948, closed by #4001*). Measured
  on fully independent chains across two availability zones: a single-track feed is byte-identical on
  all **46,778** shared datagrams; a seven-stream mux reaches **75.56 %**, with identical per-PID packet
  counts and **98.414 %** alignment once displacement is allowed (T12). The counter fix above was
  conditional on it.

### The residual #2825 left, and the measurement that can see it — contributed as [#3947](https://github.com/moq-dev/moq/pull/3947)

The maintainer asked for a measurement against a real stream, runnable on `test/smoke/` fixtures,
because the two late-join tests in [#2825](https://github.com/moq-dev/moq/pull/2825) compare two
exporters *inside one process* and are blind to anything keyed to process start.
`test/ts/table-anchor.py` plus `run.sh --pair` subscribes twice against one broadcast with the second
leg joining late; **agreement** is the PTS of the frame each table was emitted against, counted only
inside the media time the two captures share.

On a 30 s round-trip with the second leg joining 8 s in, PAT and PMT reach **94.37 %** agreement, while
SDT reaches **0.00 %** — both legs running a 2.005 s period, 0.512 s out of phase; it reproduces at
other join offsets (6 s in: 5.26 % at 0.480 s of phase). **This is a residual
of #2825 rather than a regression of it.** The fix moved the SI cadence from wall-clock into media time,
which is what made a single-track, same-start pair reach 100 %; it did not move the cadence's *origin*,
which is still the first frame the exporter saw. Filed separately as
[#3948](https://github.com/moq-dev/moq/issues/3948). The mode is opt-in and no CI arm invokes it.

**Merged 2026-09-23** as `d571aed2`. Run as `test/ts/run.sh --pair` on `ffa5b81b`, with the second leg
joining 5 s in: PAT and PMT **97.58 %**, SDT/BAT **0.00 %** — both legs emit every 2.000 s, 0.261 s out
of phase (*"a timer started with the exporter, not an anchor in the media"*).
[#3948](https://github.com/moq-dev/moq/issues/3948) was then fixed by
[#4001](https://github.com/moq-dev/moq/pull/4001); on the same gate and the CNN clip, SDT/BAT reads
**90.91 %** (§ *#2829 and #3948, closed by #4001*).

### A takeover livelock — closed

A relay could stay *running* and stop *serving*: cluster peer churn pinned every worker thread inside
one poll, leaving the process alive at 100 % CPU with no logs, no health endpoint and no accepts for
hours. Fixed by [#2701](https://github.com/moq-dev/moq/pull/2701). The operational lesson is in
[Architecture](../docs/architecture.md) §9.1: **relay monitoring must test liveness rather than process
existence.**

### A drill offered, and the coverage that landed instead

The two method rules the redundancy work produced — grade beyond one full idle timeout, and never start
redundancy test sources independently — were baked into an end-to-end drill offered upstream as
[#2545](https://github.com/moq-dev/moq/pull/2545) (`just test failover`): two real relays, lazy track
creation, QUIC idle timeout in the loop, and a load-bearing third subscriber that forces one relay to
carry the broadcast via the other. It generates its own source clip and depends on no private capture.

**It was declined, and correctly**: upstream had by then covered the same behaviour with model unit
tests. The drill still reproduced our out-of-band numbers (resumption ~14 s after killing the active
publisher at a 10 s idle timeout, against ~11 s measured here). What did land is
[#2713](https://github.com/moq-dev/moq/pull/2713), which takes the drill's load-bearing insight into
those tests: every takeover test subscribed to a *single* track, so nothing pinned that reselect is
decided **per track** — a partial recovery a single-track test cannot tell from a whole one. Two tests,
no production changes, with deliberately unequal group counts so resume boundaries differ.

**Two of our four reports from that work were artefacts of our own harness**, recorded with their method
rules in [method-notes](method-notes.md) §1 and §5.

---

## 4. Congestion control

The loss collapse this campaign measured under QUIC's default CUBIC was reported into the discussion on
[#2432](https://github.com/moq-dev/moq/pull/2432), which exposes
`--server/client-quic-congestion-control {loss|delay}`. Upstream has since made **BBRv1 the default on
quinn** ([#2468](https://github.com/moq-dev/moq/pull/2468)), with the defaults described as
backend-specific — quiche to BBRv2, and noq back to CUBIC because BBRv3 carries a subtract-overflow
panic under high loss ([noq #768](https://github.com/n0-computer/noq/issues/768)). The noq half is not
what the code does: from `fd4f5d82e` to `ffa5b81b` every backend resolves an unset controller to
`delay`, which on noq is BBRv3 ([method-notes](method-notes.md) § *The default congestion controller
changed to the one known to abort*). noq #768 was closed on 2026-09-20 with no fix linked to it, so
whether the noq a current build links still panics is not established here.

**Upstream methodology guidance, adopted here:** the one meaningful congestion-control test is
bufferbloat under a shaped bottleneck, not random loss — *"the best congestion control in the face of
random loss is zero congestion control"* — so the CUBIC-collapse result is about **loss-signal
interpretation**, not congestion-control quality. That is why [T8b](test-8b-congestion-control.md)
exists. The open question on #2432 — whether BBRv2 on quiche is a first-class supported choice for a
permanent fixed-rate trunk — is **unanswered**, and one under-provisioned condition is not enough to
press it.

### The subscriber dies under contention — reported, fixed on the media path, then on the catalog track

[**#3491**](https://github.com/moq-dev/moq/issues/3491) — ***closed 2026-09-08*** by
[**#3515**](https://github.com/moq-dev/moq/pull/3515). **That fix was incomplete**: the same failure
reproduced through the catalog consumer, was re-reported as
[**#3897**](https://github.com/moq-dev/moq/issues/3897) and closed by
[**#3907**](https://github.com/moq-dev/moq/pull/3907), and the residual is verified closed here.
`moq export ts` exits with `Error: hang: moq error: old` when two subscribers pull separate broadcasts
through one relay across a shared, under-provisioned bottleneck.

**The cause was in `moq-net`, and it was a cursor confusion.** `GroupState::poll_finished()` returned
the group's final frame count as soon as the *producer* finished, even if that particular consumer had
not read that far. When retention later aborted the finished group to release its cached frames,
`moq-mux` had already been told the group ended cleanly — so the `Old` read error propagated out of the
export. The fix makes `Consumer::finished()` answer for its own read cursor and lets the container
consumer skip transport eviction (`Old` or `Lagged`) while still propagating genuine payload decode
errors.

**Verified here incidentally but at much larger scale than the report.**
[T26](test-26-cross-host-fanout.md) put **450 subscriber sessions** through cross-host fan-out on a
build containing #3515, including episodes where per-subscriber delivery fell to 3–37 % of nominal for
45 s — **no session exited with `Old`**, or with any error at all; the only process exits were the
subscriber host's OOM kills. On the current released pair (`moq` 0.9.15 / `moq-relay` 0.14.14) it takes
**6 of 8 cells and 7 of 16 subscribers**; every graded capture has **0 continuity errors**, so what a
downstream monitor sees is a perfectly conformant stream that simply stops — the silent-failure class
[T24](test-24-partial-media-plane-stall.md) is about. A *steady* shortfall does not cause it (0 of 12
single-flow cells at 36 % of the required rate, despite thousands of evictions), so the condition
appears to be flows competing rather than a flow starved.

The report deliberately does not name a cause in its filing text. **An earlier draft attributed this to
[#3271](https://github.com/moq-dev/moq/pull/3271) and was withdrawn before filing.** The split was wrong
because the death detector read one of each cell's two subscriber logs, and re-reading every log gives 9
of 15 against 3 of 15, p ≈ 0.060, while the relay was pinned to a July build even though the mechanism
runs through relay group eviction. Both method rules are in [`method-notes.md`](method-notes.md) §1.
#3491 reports the reproduction and crossed matrix, and offers the `poll_read` propagation path as a
lead a maintainer may discard.

**The residual was on the catalog track, and it is now fixed.** Re-run as its own experiment with a
pre-fix build as a positive control ([T8b](test-8b-congestion-control.md) § *#3491 survives on the
catalog track*), three concurrent flows: on `moq 0.9.15` without either fix, **4 of 15** cells saw the
exporter exit on the media container with `hang: moq error: old`; on `moq 0.11.2-615d166d` with #3515
but no catalog fix, **1 of 15** and **1 of 10** exited with `json: old` on `catalog.json`; on
`moq 0.11.2` (`53f8aa99d`) with both fixes, **0 of 10** exited. `#3515` gave the *container* consumer a
skip for an evicted group; `moq export ts` also reads a **JSON catalog track** whose consumer had no
such skip — `moq-json`'s transparent `Net` error propagated `Old` out unclassified and unlogged. On a
snapshot track `Error::Old` means *the value you hold has been superseded*, not *terminate*.

**Reported as [#3897](https://github.com/moq-dev/moq/issues/3897) and closed the same day by
[#3907](https://github.com/moq-dev/moq/pull/3907)**, which made the snapshot consumer discard a group it
cannot finish and wait for the replacement, covering `Old`, `Evicted` and `Lagged`; the same treatment
went to `moq-binary`. **The verification is consistent with the fix and does not establish it on its
own.** The re-run put the fixed and control builds in the same session on the same rig; 0 of 10 is also
the commonest outcome of an unchanged build at this event rate, so the weight sits on the conjunction —
closed code path, upstream regression tests, and a control that still provokes the condition on demand.
**Method rule: a low-rate failure needs its control in the same session, and a null against it is
corroboration rather than proof.** A registered prediction was also tested and **failed**: exits do not
fall monotonically with the drift budget (6 of 9 at 500 ms, 4 of 15 at 2 s, 3 of 9 at 8 s on the
pre-fix build).

**A second exit on the same track, when the publisher goes away, was filed as a question rather than a
defect**, tracked in § *The liveness exit* and § *Four of these were closed as completed*.

### The qlog loss trigger is computed backwards — fixed in quinn and in noq, released in neither

Both QUIC stacks the lane has run on label every declared loss in their qlog by the reordering
threshold, whichever rule fired. The trigger is computed as
`time_sent.saturating_duration_since(now) >= loss_delay`, which subtracts the present from the send
time, saturates to zero and is never true, so the `TimeThreshold` branch is dead. The line is identical
in `quinn-proto` 0.11.17 and on quinn's `main`, and in the noq fork (`noq-proto` 1.3.0). It cost the
campaign a published attribution that had to be withdrawn
([T28](test-28-failure-injection-matrix.md) § *Corrections*). The fix is reversing the operands.
**Reported** as [quinn-rs/quinn#2895](https://github.com/quinn-rs/quinn/issues/2895) and pointed to from
[n0-computer/noq#825](https://github.com/n0-computer/noq/issues/825).

**quinn: fixed on `main`** by [quinn-rs/quinn#2896](https://github.com/quinn-rs/quinn/pull/2896), with
a regression test that forces one loss by each rule and reads the trigger back from the qlog. The test
fails without the fix, with both losses labelled `ReorderingThreshold`, and passes with it. It is gated
on the `qlog` feature, which quinn's PR CI does not enable. No quinn release carries the fix yet:
`quinn-proto` 0.11.19 still carries the reversed operands, so 0.11.17 through 0.11.19 labels are still
unreliable.

**noq: fixed on `main`** by [n0-computer/noq#827](https://github.com/n0-computer/noq/pull/827). It has
the same fix, with the test adapted to noq's qlog factory and per-path statistics, and it fails and
passes the same way. noq's CI runs it, since its tests run with all features. No noq release carries it
yet: `noq-proto` 1.3.0 predates the merge, so `noq-proto` 1.2.0 and 1.3.0 labels are unreliable.

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
was shorter than that knee, so the original "linear, 650 MB/day" reading was a measurement-window
artefact ([method-notes](method-notes.md) §3). Confirmed afterwards: baseline +108 MB against +97 MB
predicted; per-slot cost 9.14 and 10.54 KiB against upstream's 9.9 KiB; ~8 MB/h past the knee; capping
streams cuts the ceiling only 3.3× for a 9.8× slot reduction because 20–30 MB is slot-independent.
**No released version of the QUIC library removes it**, so plan for the overhead.

[T8b](test-8b-congestion-control.md) C6 (14.006 h), offered on #2745, shows post-knee growth is **not**
noise: another ~100 MB toward baseline +200.5 MB (**2.03×** the slot ceiling), slope decaying from
+24.60 to +1.82 MB/h and still not flat at end. Pre-knee slope is flat across N = 0, 1, 2 and 4
subscribers; the four-subscriber leg reached baseline +108.1 MB at its knee and 189.5 MB at 4 h —
neither five times a per-connection cost nor materially above two connections. Posted as a data point
([comment `5367857020`](https://github.com/moq-dev/moq/issues/2745#issuecomment-5367857020)), not a
re-open: what changed is the constant a deployment budgets.

### The relay's plateau is confirmed at 24 h — and the publisher is the role that actually leaks

The question C6 could not close was whether the soft second term converges (+1.82 MB/h at 14 h).
[T21](test-21-permanence-soak.md)'s 24 h soak closes it: relay growth past warm-up follows a
**logarithm** (R²=0.9895 vs 0.9097 for a line), quarterly slopes halving — 9.85, 4.56, 2.42, 1.75 MB/h.
The run reaches baseline +242.6 MB at 24 h, past C6's +200.5 MB asymptote; log extrapolation ~519 MB at
a year. Posted on #2745 as promised follow-up (data point, not re-open), stating that extrapolated
asymptote is not observed plateau and both legs are single runs on one topology.

**The same run found growth that is not the relay's:** over 24 h the relay grew 243 MB and
**`moq import ts` grew 137 MB**, so end-point totals make the relay look worse when it is the better
process. The publisher fits a **line** (R²=0.9898 vs 0.8960 log / 0.9655 sqrt; quarterly slopes
2.36–2.87 MB/h; largest drawdown 9.2 MB) at +2.83 MB/h (~24 GB/year) — it ratchets rather than caching.
For permanent primary distribution the publisher is the process never meant to restart. **No upstream
issue describes publisher RSS over long runs** (#2745 and #3128 are relay-side).

[**#3493**](https://github.com/moq-dev/moq/issues/3493) — **closed** via
[#3793](https://github.com/moq-dev/moq/pull/3793) (`5d0991b9`). Re-soaks **`3493-check-2h`** and
**`3493-loop-2h`** invalidated when import hit [#3798](https://github.com/moq-dev/moq/issues/3798)
at ~600 s / ~631 s. On upstream `main` `9d2a4f6e`, 24 h re-soak `p0h-24h` confirms the fix: importer
slope +0.23 MB/h vs original +2.83 ([T21 § *The #3493
re-soak*](test-21-permanence-soak.md#the-3493-re-soak)). The report was **deliberately held** until
per-process attribution: RSS by command-line signature also matched the wrapper shell. A 6 h re-run
sampling each PID puts growth at **+2.91 MB/h in `moq import ts` itself** vs +2.83 by signature; the
issue carries fits, per-PID confirmation, and caveats (exporter +14.5 MB at 5 h; 6 h cannot read
relay shape).

---

## 5b. Authorization, entitlement and subscriber observability

Three filings from the control-plane work were answered together, and **all three were accepted in
substance**. The maintainer's summary was *"I agree, the auth stuff needs a rethinking"*;
[#3619](https://github.com/moq-dev/moq/pull/3619) planned them into quests in one pass. None is a
defect report; each says a design does not generalise. Upstream's trunk is now **`main`** (the
former integration `dev` line, to 2026-10-02); tagged releases ship from **`release`**.

### The mTLS identity never reaches the authorization decision — open, and conceded on every point

[#3603](https://github.com/moq-dev/moq/issues/3603) argued that a client certificate authenticates a
peer and is then discarded, so mTLS can only express unrestricted access. The reply granted all three
parts: the auth-proxy API on **`main`** **already** forwards the mTLS identity per connection so the auth
server can answer for it, and the default token path cannot because its cache is keyed per key. On scoping,
mTLS is what the maintainer uses for cluster sync, and per-identity scoping is preferred over a global
config option; on the startup warning the maintainer agreed the current approach is confusing and not good
security practice. Planned as `quest/m1/auth/relay.md` on **`main`**. **The correction this campaign
posted before anyone spent time on it** is why the third ask was judged on its merits: the issue had claimed
a startup-warning precedent that does not exist, and said so in a comment.

### The revalidation window — closed, and folded into a rethink of the whole auth line

[#3605](https://github.com/moq-dev/moq/issues/3605) reported that `max-age=0` and an omitted
`Cache-Control` silently disable revalidation permanently, and that the 2× revocation window is
undocumented outside the source. Closed as completed and absorbed into
[#3682](https://github.com/moq-dev/moq/pull/3682), *"plan the auth server line on dev"* (title quoted
verbatim), alongside `moq auth serve` becoming the reference auth server — the planned auth-server line
now targets **`main`**. **The ask is no longer tracked as its own quest:** the behaviour was accepted as
wrong, and the remedy is replacement of the surface rather than a patch to it. Whether the replacement
closes the specific hazard is not yet checkable; T37 measurements are against a component being redesigned.

### Subscriber-reported health telemetry — accepted, and became a four-part questline

[#3608](https://github.com/moq-dev/moq/issues/3608) was filed **as aspirational** because no control
plane in current use gives an origin this visibility. Upstream planned `quest/m2/qos/stats/` with four
sub-quests (schema and library, Rust reporters, browser reporters, encoder feedback) that **close #3608
when the questline finishes**. The plan reuses **`moq-stats`** rather than a catalog section:
`moq_stats::Producer<E>` flattens an extension beside `Traffic`, so one consumer reads relay delivery
counters and client media counters on one layout. The convention is a **`.stats` broadcast suffix** at a
path the token allows (e.g. `pilot/feedback.stats`). Reporting is **bidirectional** — publisher
self-reports correlate subscriber late frames against publisher CPU starvation — and **closes the loop**
with encoder feedback from viewers' stats. Reporting is opt-in because reading is, and **self-reports are
diagnostics only — never billing, authorization, or route-selection input**; the relay emits aggregated
histograms only. Goal: unknown/healthy/degraded/unhealthy per broadcast *as CMSD does for HLS*
([`docs/comparison.md`](../docs/comparison.md)). It lands on **`main`** because `moq-stats` is published
and the generic producer is a breaking change. **The gap is no longer unaddressed, but nothing is
implemented**, and the campaign position — not via `mpegts-pacer` — is unchanged.

### Where the specification half of this belongs, and it is mostly not MSFTS

The upstream questline settles the *mechanism*. The open question is where the **convention** is written
down, and MSFTS is the wrong home for almost all of it: subscriber health applies identically to LOC,
CMAF and `m2ts`, and MSFTS §4's disciplined scope list is the reason not to fork the work into one
packaging extension. **One paragraph does belong in MSFTS:** a generic telemetry convention cannot know
that transport-stream health needs TR 101 290 P1, PCR repetition and accuracy, and per-PID access-unit rate
— nor that **the standard P1 set does not detect the failures this carriage actually produces** (57 s
missing video with 0 continuity errors and PCR identical to the control
[T24](test-24-partial-media-plane-stall.md); #3533's signature of PSI, AC-3 and teletext continuing while
video stops). The `m2ts`-specific claim is per-PID access-unit observation *in addition to* P1 counters,
with the reporting mechanism out of scope — an Implementation Considerations paragraph pointing at the
separate quest work.

### BISS-CA over MoQ: the native mechanism answers access, not operator-blindness

Two vendors at IBC 2026 proposed BISS-CA on top of MoQ for conditional access. Assessed from the
specifications; **nothing about scrambling is measured here** — the Gate 2 pass table records "Not
exercised: nothing in the campaign scrambles" against its scrambled-packet rows. The question is whether
the platform operator must be unable to *see* the content. Admission works — eight refusing arms delivered
zero payload bytes ([T36](test-36-entitlement-enforcement.md)) — and the key estate scales
([T38](test-38-entitlement-estate.md)). But the relay terminates the session and sees plaintext, so the
native mechanism decides *who may subscribe*, not *who may comprehend*; the transport stream on UDP or
RTP into an IRD has no MoQ protection on its final hop. BISS-CA, in-content and receiver-terminated,
covers that gap.

**The decisive constraint is that BISS-CA forecloses the media-aware lane:** CISSA scrambles TS
payloads, so the demuxing importer cannot produce media tracks; it requires transparent MSFTS mode 1
— the lane with worse measured latency that `moq-dev` does not implement on `main`. **Verdict: do
not build it** unless a rights deal requires operator-blind carriage; MSFTS §10 already permits
BISS-CA on transparent carriage. Recorded in `docs/upstream/biss-ca-over-moq.local.md`. **Promoted
to [`control-plane.md`](../docs/control-plane.md) §7.3 and §9:** facility segments MoQ leaves
unprotected are local and often clear today; the gap matters where operator or environment is not
trusted; technical half answered (BISS-CA at price of opaque carriage), commercial half open.

### FEC is a transport question, and the campaign's contribution to it is the comparison

Raised as a possible MSFTS topic; it is not one. FEC trades latency against loss below the object layer
and applies to every streaming format equally, so it belongs in the transport or QoS discussion. **MoQ
sheds whole groups**, so loss granularity is a GOP while FEC and ARQ recover partial damage. Measured:
impairments shed programme in group-sized units; the lane loses more picture than a 5 s outage lasted in
all but one cell ([T28](test-28-failure-injection-matrix.md),
[T31](test-31-congestion-capacity-ladders.md)). **FEC and the relay's latency budget compete for the same
milliseconds**, and any proposal must be scored against raising `--latency-max` and against SRT ARQ at an
equivalent budget (2000 ms spanning ~100 RTT at 18.6 ms RTT here is heuristic, not an SRT property).

**The matched SRT arm has been run** ([T28](test-28-failure-injection-matrix.md) § *The matched ladder*;
[`docs/evidence.md`](../docs/evidence.md) *Matched against SRT, and graded on content*). At measurement
point P1, on a single host at 20 Mb/s and 100 ms RTT, build `53f8aa99d`, SRT's `--latency` was set to the
MoQ lane's measured median at each budget. Unimpaired, both grade 0.000 s lost. **Graded on content, SRT
loses less programme than the media-aware lane under every impairment shape run** — under a 5 s outage, MoQ
loses roughly three to four times the video duration SRT loses at every `--max-age`, while MoQ delivery
latency rises with the allowance and is not bounded by it. How much MoQ loses depends on build and QUIC
stack; continuity-error counts must not rank the lanes because the MoQ exporter re-synthesises counters.
MoQ-only ladder non-monotonicity remains *likely rather than established* at one sample per cell. **Venue:
IETF MoQ list first** (`moq@ietf.org`); position in `docs/upstream/fec-arq-venue.local.md`. **A list
message can now open with the measured MoQ-versus-SRT table and its qualifications.**

### The determinism measurement, posted to #2829 — and the correction it needed first

The head-to-head pair comparison was posted on [#2829](https://github.com/moq-dev/moq/issues/2829): two
`moq export ts` processes of one broadcast share **4.97 %** of packets over 50,000; 94.02 % differ in
continuity counter and 27.93 % in the interleave ([T13](test-13-downstream-grooming.md) § *The
head-to-head*).

**The first draft of that comment was wrong and was not sent.** It claimed
[#2779](https://github.com/moq-dev/moq/issues/2779) had been closed by accident in
[#3868](https://github.com/moq-dev/moq/pull/3868); #3868's body abandons #2779 as won't-fix. The
posted version accepts closure: with the counter out of scope upstream, renumbering must happen
downstream, and a downstream filter is capped by the interleave — 100.00 % on single-track with the
counter masked against 94.09 % on the real multi-track feed. #4001 has since fixed the interleave;
the byte schedule remains ([method-notes](method-notes.md) §6).

### The byte schedule — a successor to #3334, not a reopen of it

Filed as [**#3925**](https://github.com/moq-dev/moq/issues/3925): conformant egress, a deterministic 1+1
pair and [#3923](https://github.com/moq-dev/moq/issues/3923)'s sink all wait on it. **The care needed was
not to read as regression:** [#3334](https://github.com/moq-dev/moq/issues/3334) and
[#3351](https://github.com/moq-dev/moq/pull/3351) genuinely fixed adjacency (50.31 % → 0 % adjacent PCR;
491/799 → 0–4/745 releases outside ±10 ms) ([T19](test-19-pcr-grid-verification.md) meas. 9–10). What
#3925 reports is the **next property #3351 does not grade: not-adjacent is not evenly spaced.** On
`53f8aa99d`, PCR values are exact at 25.00 ms (0/6,173 over 40 ms P1) and aggregate rate is within 0.21 %,
while bytes between consecutive PCRs run 188 B to 870,628 B (median **1,316 B**, 4.2 % of mean); only
**3.3 %** of intervals carry an instantaneous rate within 1 % of nominal
([T13](test-13-downstream-grooming.md) § *The residual measured*).

**The grader is [#4493](https://github.com/moq-dev/moq/pull/4493)**, merged as `18d7c2530` (`test(ts)` only).
It adds `pcr-schedule` to `test/ts/pcr-timing.py` — bytes between consecutive PCRs on one PID, never
pooled, against `--mux-rate`, tolerance ±1 % or one packet — report-only unless `--schedule-pct-min` is set.
Verified on upstream `main` `9d2a4f6e9`, file domain, harness loopback: `moq export ts` of the real CNN cut
returns **3.09 %** of intervals within tolerance (exit 1 at `--schedule-pct-min 99`) and median **1,316 /
31,081 B**, reproducing the T13 residual while the source clip grades 100 % (30,644 / 30,644 B). The
harness's generated `ffmpeg -muxrate` clip grades 100 % (25,004 / 25,004 B) and its export 92–97 % over
three 20 s runs (31,208 / 31,250 B), because that fixture is mostly padding, which is why a burst fixture
is listed below.

**Open:** [#3925](https://github.com/moq-dev/moq/issues/3925) is **open** with state **reopened**; residual
on `main` at `6f1a9e33` is **3.27 %** ([T13](test-13-downstream-grooming.md)); a burst fixture for the
recipe gate; unpadded export start; and `pcr-value-interval` pooling across PIDs.

### The byte schedule itself — contributed as [#4579](https://github.com/moq-dev/moq/pull/4579), overtaken by the maintainer's fixed-delay export

**The defect** is #3925's: with a mux rate, export padded to the right average but heaped each keyframe
between two PCRs, so a receiver clocking off arrival could not lock. On upstream `main` `6f1a9e33`, a 60 s
cut of `CNNiEMEA2.ts` at `--bitrate 11000000` returned **3.27 %** of PCR intervals within ±1 %, median gap
1,316 B against 31,087 B, T-STD TB overflows 384,910 and pcr-jitter p95 205,936 µs.

**The contribution** implements the byte-schedule quest: with a rate, closed spans queue in a backlog and
every 25 ms slot emits its PCR, media up to the rate, then nulls, so a PCR's value follows its byte
position; output trails the media by a delay that grows to the largest burst seen, capped by `--max-age`.
Without a rate the output is byte-identical. The harness fixture was replaced with keyframes that outgrow a
slot, and `pcr-schedule` gates at 80 %. **Measured on the PR branch against `main` at `6f1a9e33`**, on
the loopback harness (the PR was never merged): on the CNN cut, pcr-schedule rose from **3.27 %** to
**75.3 %** (to **99.1 %** with `export ts --max-age 1s`), TB overflows and pcr-jitter p95 fell sharply,
and the schedule added about 500–706 ms of delay; on the generated clip it rose from **34.5 %** to
**93.5 %**. Open-GOP stayed 60/60 with continuity clean.

| Stream | pcr-schedule | TB overflows | pcr-jitter p95 | added delay |
|---|---:|---:|---:|---:|
| CNN, 60 s | 3.27 % → **75.3 %** (→ **99.1 %**) | 384,910 → 90,150 (→ 19,830) | 205,936 → 24,246 µs (→ 92 µs) | 500 ms cap (→ 706 ms) |
| generated clip, 20 s | 34.5 % → **93.5 %** | 67,960 → 5,450 | 58,454 → 24,389 µs | ~250 ms |

Figures in brackets are with `export ts --max-age 1s`.

**Open:** the 500 ms default `--max-age` is too short for CNN bursts (0.7–0.9 s); media-before-nulls leaves
TB overflows interleaving would cut; the first ~2 s stay VBR until the importer publishes `mpegts.muxRate`;
and the `--live` release check was flaky under load on both `main` and the branch. **State:**
[#4579](https://github.com/moq-dev/moq/pull/4579) was closed by its author in favour of
[#4645](https://github.com/moq-dev/moq/pull/4645), which **remains open and in draft** (not merged): it
replaces span machinery with a constant-rate schedule paced against fixed `--delay` and fails export when a
burst does not fit the delay. The closing comment on #4579 retains the measurements above as the
before-state #4645 must beat on a real broadcast clip.

### T-STD conformance of the TS export — taken up upstream as a questline; its current head carries every track of a broadcast clip, with its clock in tolerance

**What prompted it.** [T44](test-44-tstd-grading.md) graded the lane's P1/P2-conformant wire against
13818-1 T-STD and found it fails on the lane's packet order; [T45](test-45-live-tstd-remux.md) showed a
live re-multiplexer repairs it on one host. Together with the MSFTS co-author's review of transmux
carriage, that moved the maintainer to treat a TS export as a remux with a fixed delay.

**Upstream state.** The plan in `quest/m1/tstd/` merged in
[#4637](https://github.com/moq-dev/moq/pull/4637): a fixed-delay release stage, a full T-STD check
in `test/ts/compliance.py`, and PCRs on the mux-rate byte grid.
[#4681](https://github.com/moq-dev/moq/pull/4681), merged into the questline branch, caps send-ahead
within `--delay` (default 1 s) and holds the mux rate until measured so the export is constant-rate
from its first packet. The release stage releases each frame at first-arrival anchor plus DTS plus
`--delay`, in `(DTS, PID)` order, dropping late frames; the loss rig of
[#4613](https://github.com/moq-dev/moq/issues/4613) (10 % loss, ~10 Mb/s broadcast TS) is the
questline's nightly proof. We proposed TS passthrough and clock-recovery quests in
[#4670](https://github.com/moq-dev/moq/pull/4670); the maintainer merged passthrough
(`quest/m1/ts-passthrough.md`, whole-packet carriage paced on source PCR) and took clock recovery
into [#4645](https://github.com/moq-dev/moq/pull/4645) directly, dropping the separate quest. A
catalog `burst` field for encoder VBV send-ahead was planned in
[#4649](https://github.com/moq-dev/moq/pull/4649), reviewed to a definition question — largest access
unit against VBV/`cpb_size` — and then abandoned by the maintainer, who kept `--delay` covering both
the hold and the send-ahead window. Neither burst quest was added.

The check merged in [#4643](https://github.com/moq-dev/moq/pull/4643) on the questline branch and
reached `main` with [#4640](https://github.com/moq-dev/moq/pull/4640) (`87141092`), replacing the
approximate TB-only check there. The hand-rolled grader models
buffers for AVC, HEVC and common audio codecs; on the harness clip it fails current `moq export ts` with
the same failure classes T44 saw on a broadcast clip, reporting only until the delay lands. The first
[#4645](https://github.com/moq-dev/moq/pull/4645) head (`4b7158d6c`) removed mux hold and stall machinery:
with a measured rate the output is constant-rate, runs up to two delays behind the source, reorders DTS
frame-spaced, and fails bursts that do not fit the delay. On the generated 20 s clip it passed the strict
check at 10 and 2 Mb/s on a clean path; the loss rig and broadcast clip were not run on that head.
[#4645](https://github.com/moq-dev/moq/pull/4645) remains an open draft through maintainer rework heads
`49efbc9a1`, `2dc542b4a`, `559a35244` and `fe7cec106`, the last with `main` merged in rather than
rebased. Under the `--linger` rig, `559a35244` ended the export within 7 s of joining a broadcast as it
starts, and `--linger` then waited for a replacement broadcast while the one it was reading was still
live. Reported (issuecomment-6013366214), with an offer to do the CLI side; the maintainer agrees the
misread is wrong, leaves it as a follow-up and invited us to do `subscribe.rs`. The session-start exit
itself is gone on `fe7cec106`.

**Cross-validation.** Upstream's check and [`ts-tstd.py`](scripts/ts-tstd.py) were cross-validated in
[T46](test-46-tstd-check-cross-validation.md) on 35 files (file domain). With six defects in
`ts-tstd.py` fixed, the two agree on 24; the other 11 trace to upstream's check: three H.222.0 defects
(two fail clean streams, one under-reports STD delay) and one convention on truncated last access
units. Reported on [#4640](https://github.com/moq-dev/moq/pull/4640#issuecomment-5938368125) against questline
head `8df1e438`, with clause references and violating-unit arithmetic: TB-to-B delivery by whole packet
(false audio underflow on five clean files by 0.27–0.45 ms); floating-point drift in the AVC leak (one
false underflow at large output); units after the last packet not assessed (132 and 142 audio units missed
on Kyrion restamps, verdict still correct on other conditions); truncated last access unit graded as
underflow (convention). The first two fail clean streams, which matters once the check gates CI.
All four were fixed before [#4640](https://github.com/moq-dev/moq/pull/4640) merged to `main`
(`87141092`): re-graded on the merged check, the two agree on all 35 files
([T46](test-46-tstd-check-cross-validation.md#on-upstream-mains-merged-check)).

**Send-ahead.** On `ffa5b81b`, T45 found the exporter hands each video frame at its decode time, so a
conformant CNN clip needed about 0.55–0.6 s of send-ahead through the video transport buffer.

**First implementation head (`4b7158d6c`, [T47](test-47-fixed-delay-export.md), loopback, one run
per cell).** On the broadcast clip the export stopped within seconds with a schedule overrun at
every `--delay` up to 3 s (video alone; upstream's harness reproduces at defaults). A generated clip
with 0.7 s send-ahead that passes `compliance.py` as a source could not start at the 500 ms default;
at 2 s it passed both T-STD checks. Where it ran, 1,868 of 1,880 PCRs after start-up missed ±500 ns
by up to ±75 µs. Delivery latency at 2 s delay was 6.83 s. The overrun is an overfull schedule, not
starvation: `schedule.rs` sends each unit as late as the rate allows with one window of lookahead,
which CNN's field-coded passages and authored DTS outrun. An offline replay
([T47](test-47-fixed-delay-export.md#where-the-broadcast-clip-fails)) predicted stop at 5 s and run
at 8 s on video alone; the export matched. An EB-limited video scratch patch ran the full clip at 1
s with video and MP2 passing every buffer; audio still failed T-STD (MP2 and AC-3 B overflow and
AC-3 TB overflow at 8 s unpatched; AC-3 still failed both when patched). A per-PID admission scratch
passed every buffer of `ts-tstd.py` and `compliance.py` at 1 s and 750 ms on the full clip; at 500
ms it stopped (replay attributes that to authored DTS). PCR accuracy still failed from unchanged
stamping. Join-time generation split: skipped video groups at joins left video 959–979 ms behind
other tracks on four of five cross-host joins (one 200 ms); co-resident joins also skipped video
groups, with states from 200 ms behind to 1,200 ms ahead (MP2 then eight slots late). A scratch
one-clock release stage passed every buffer on eleven traced joins but broke four discontinuity
tests ([T47](test-47-fixed-delay-export.md#keeping-the-tracks-on-one-clock-scratch)); the
distinction between skip and publisher restart belongs in the consumer. Eight mocked-time export
tests on the t0ms fork cover join skip, mid-stream skip, ±0.5 % source clock, and 1+1 identity;
seven failed on `4b7158d6c` and were `#[ignore]`d pending fixes, reproducing the field split from
skip alone when tracks are sent out of step. Writing them found three things the earlier reports had not: the
fractional packet per slot is carried from each receiver's own start, so at a rate that is not a whole
number of packets per 25 ms a 1+1 pair pads different slots (at 2 Mb/s one slot rendered 6,204 B on one
leg and 6,392 B on the other); a skip rewinds the slot grid by 475–800 ms, at a point that differs per
receiver; and the skip path was not deterministic on that head (187 or 200 slots after the skip in
identical paused-clock runs).

**Maintainer rework scope and heads.** He scoped rework to join-time generation fix, per-PID
buffer-limited admission (AC-3 per sync frame), carry importer DTS, PCR from byte position, drift
tracking, CI fixture `hrd9m.ts`, and mocked-time tests against `ts::Export` (offered on the t0ms
fork). Rework `49efbc9a1` added one jitter clock across tracks, DTS authored in time with reorder
delay, per-PID admission capped at TB drain and decoder buffers (EB from SPS NAL HRD), AC-3 one sync
frame per PES, PCR from the slot's first byte, drift steering within 500 ppm with CLI pacer removed,
and CI `just test ts --hrd` at 500 ms. On that head he reported 1+1 packet identity except
continuity counter (numbered per leg). On rework head `49efbc9a1` the broadcast clip passed every
buffer at 500 ms–1 s with every PCR within ±500 ns and presentation latency 1.4–2.2 s
([T47](test-47-fixed-delay-export.md#the-rework-49efbc9a1), loopback), but the steered clock
exceeded 13818-1 2.4.2.1 (497.8 ppm in mocked time, about 500 ppm on the wire by PCR clock fit);
partial last AC-3 PES of a capture passes through. Teletext has EN 300 472's 480 B TB at 6.75 Mb/s;
for primary distribution 1+1 byte identity is a goal (ST 2022-7 hitless selection). Rebasing the
mocked tests to `49efbc9a1`: seven pass including drift at ±400 ppm over five minutes; two remain
ignored (joiner system clock at +433.5 ppm against 2.4.2.1, and skip pair). On `2dc542b4a` the clock
fit within about 1 ppm loopback and 3.4 ppm across hosts over 540 s; at 1 s the export conformed on
loopback, across hosts, and under 1 % loss
([T47](test-47-fixed-delay-export.md#the-live-edge-join-and-the-30-ppm-clock-2dc542b4a)), though
join anchor choice could drop entire audio tracks and at 500 ms the export still exited on missed
video deadlines (157 s and 202 s in two 540 s runs; under loss exit at 10 % at 1 s and 1 % at 500
ms). Buffer graders pass outputs that drop whole tracks because they grade only units present. All
ten mocked tests pass on `2dc542b4a` at ±25 ppm drift; a late-track case sent one track 700 ms after
the other at 500 ms delay and passes, so it does not reproduce wire join loss. On `559a35244`
(acquire-before-release, clock recovery as specified, teletext buffer in `compliance.py`) the clock
held but on most joins every audio and teletext frame was dropped as late at 1 s and 750 ms loopback
and at 500 ms across hosts
([T47](test-47-fixed-delay-export.md#acquiring-before-release-and-the-anchor-on-the-most-slack-559a35244)):
both acquisition and steering took the most slack across all tracks, which on a TS source is video
sent up to 0.97 s ahead. A scratch fix anchors and steers on the least slack per track, waits up to
two delays for every catalog track, and on the wire carried every track conformantly at 500 ms–1 s
on loopback and across hosts, with presentation latency twice the delay plus about 275 ms; the 540 s
run at 500 ms still stopped at about 157 s on the same video schedule limit, and at 10 % loss under
1 s the scratch build stopped at 25 s while the head ran through with almost no media. At 500 ms the
head stopped within 30 s; `moq export ts` prints none of `ts::export::Stats` at exit (requested like
`import ts`). A mocked late-track case on `559a35244` fails, dropping 543–556 frames with audio sent
later and 285–293 with video sent later. Over 540 s at 1 s, and under 0 % and 1 % loss at 500 ms and
1 s, the scratch fix carries every track with nothing late. Remaining start-up latency (two delays,
the 6.83 s overshoot on the first head) is planned separately in
[#4681](https://github.com/moq-dev/moq/pull/4681) as one budget with send-ahead capped at
decoder-buffer reach.

**Taken up on `fe7cec106`.** The maintainer cherry-picked our late-track test and anchor fix with
authorship, limited the wait to audio, video and PES tracks, released equal decode times by PID (the
1+1 tie we traced), and merged `main` in. Re-graded
([T47](test-47-fixed-delay-export.md#anchored-on-the-track-sent-latest-fe7cec106)): every track on
every join tried, on loopback, across hosts and under 0 % and 1 % loss, at 500 ms to 1 s; the
session-start exits under `--linger` are gone; at 500 ms the join moves the presentation
latency between 993 and 1,383 ms with the same multiplex, cause not located. A co-started 1+1 pair stays byte-identical through
the groomer, and with counters rewritten the only remaining difference between two exporters is where
each places a TDT revision, on the first frame muxed after the snapshot arrives
([T13](test-13-downstream-grooming.md#on-4645s-pcr-grid-the-deterministic-mode-runs-and-a-co-started-pair-merges-at-the-byte)).
Two things are `main`'s rather than the PR's: across a publisher `SIGKILL` the replacement publisher
exits with *rendition is not published* when the relay resumes the route onto it, and at 10 % loss
the video is lost to group eviction on every head run.

**Open:** where TDT/TOT revisions are placed, which decides a late-joining 1+1 pair; release-clock
statistics that count neither a skipped group nor an absent track, and an `out_of_tolerance` count
that climbs through every start; the replacement-publisher exit across a `SIGKILL`, reproduced on
`main` alone and filed as [#4945](https://github.com/moq-dev/moq/issues/4945); the join-dependent latency at 500 ms; and the latency
[#4681](https://github.com/moq-dev/moq/pull/4681) recovers. Detail, tables and reproduction live in [T44](test-44-tstd-grading.md),
[T45](test-45-live-tstd-remux.md), [T46](test-46-tstd-check-cross-validation.md), and
[T47](test-47-fixed-delay-export.md); summarised measurement points in
[`docs/evidence.md`](../docs/evidence.md) §3.16.

### The liveness exit — filed as a question, deliberately

[**#3926**](https://github.com/moq-dev/moq/issues/3926). `export ts` does **not** mint a dead
carrier when its publisher dies — the liveness property #3831's null generator put at risk — and
output stops about five seconds after the kill. It exits `Error: json: dropped` instead and recovers
nothing from a restarted publisher (0 B over 25 s, two runs). **Filed as a question rather than a
defect** because the exit arrives at the track level, which #3907 deliberately left alone: a group
whose content is gone is never fatal, but track- or session-level failure still arrives through
`poll_next_group`. The issue asks which of the two it is, and separates a clean exit for "publisher
gone" from an error for "something broke" so a supervisor can tell them apart
([T13](test-13-downstream-grooming.md) § *Liveness*).

**The same exit on the subscriber's own session loss is by design, and not reported.** A relay
restart or idle timeout ends the exporter the same way on every build since
[#2704](https://github.com/moq-dev/moq/pull/2704) removed linger — bisected in
[T28](test-28-failure-injection-matrix.md) § *The build bisection*, re-drilled in
[T6](test-6-relay-resilience.md) § *Transport-resilience drills*. What linger removed was the
ability to ride out a relay restart; that trade is not a defect to file. It leaves open the
distinction #3926 asked for: a supervisor restarting the exporter cannot tell session loss from a
dead publisher. **#3926 is now closed by [#4504](https://github.com/moq-dev/moq/pull/4504)** —
linger and the exit-code split — in § *The liveness exit, implemented* below.

### A UDP sink for `export ts` — asked once, declined, withdrawn, re-asked narrowly, and deferred

[**#1839**](https://github.com/moq-dev/moq/issues/1839) was closed **not planned** after kixelated
declined the general egress layer twice (WebRTC focus; no import/export module per transport without
a concrete customer ask). **Re-asked as [#3923](https://github.com/moq-dev/moq/issues/3923)**: one
`--udp` sink with datagram size and the usual multicast controls, explicitly abandoning RTP, FEC, ST
2022-7 and any pluggable trait. [#3831](https://github.com/moq-dev/moq/pull/3831) changed the facts:
`export ts` now measures the source multiplex rate and pads back to it, so constant-rate TS egress
is in scope where it was not in July.

The filing subordinates its own ask: the byte schedule is absent — 3.3 % of PCR slots carry the
bytes the declared rate requires on `53f8aa99d` ([T13](test-13-downstream-grooming.md) § *The
head-to-head*) — so a socket would emit a stream an IRD still cannot clock off. **Deferred and
closed not planned on 2026-09-24** after agreeing `tsp` already does the socket work; the maintainer
noted a sink adds little until the schedule lands ([planned-experiments](planned-experiments.md) §
*The UDP sink*).

### Four of these were closed as completed, by a planning document that changed no code

On 2026-09-23 [#3798](https://github.com/moq-dev/moq/issues/3798),
[#3925](https://github.com/moq-dev/moq/issues/3925),
[#3926](https://github.com/moq-dev/moq/issues/3926) and
[#3731](https://github.com/moq-dev/moq/issues/3731) were closed as *completed via*
[#3987](https://github.com/moq-dev/moq/pull/3987). **#3987 is eight Markdown files under `quest/`
and no code**; each ends with *"close this issue when the quest finishes"*. Closures moved the
tracker, not the defects — #3798's quest still records *"Known triggers, none yet reproduced
in-tree"*, and #3925's says the average rate is right (#3831) but the bytes clump.

**A closed issue is the campaign's usual signal to re-test**, and re-testing on `ffa5b81b` found
every defect intact (source and wire):

| Issue | Re-verified on `ffa5b81b` | How |
|---|---|---|
| [#3798](https://github.com/moq-dev/moq/issues/3798) | **live** — import exits *frame timestamp is below the live edge* at the first content join | [T40](test-40-continuous-join-through-srt.md) rig; `reanchor` still only in `impl LegacyStream` |
| [#3925](https://github.com/moq-dev/moq/issues/3925) | **live** — median PCR byte gap **1,316 B** against a 31,124 B nominal, 3.8 % of intervals within 1 % | [T13](test-13-downstream-grooming.md) § *The residual measured*, `pcr-residual.py` |
| [#3926](https://github.com/moq-dev/moq/issues/3926) | **live** — no `--linger` flag exists; export exits 1 on a clean publisher exit 0; 0 B recovered after restart | [T13](test-13-downstream-grooming.md) § *Liveness* |
| [#3731](https://github.com/moq-dev/moq/issues/3731) | **not actionable either way** — quest defers to msfts#33, since answered and closed | `quest/m4/msfts-convergence.md` |

On `ffa5b81b` **nothing blocked was unblocked**; #3798 has since been fixed on `main` and #3926
closed by #4504 (both below), and the maintainer reopened #3925 and #3731 on 2026-09-28. Method
rule: [`method-notes.md`](method-notes.md) § *A closed issue is a claim about a tracker, not about a
binary*.

### #2829 and #3948, closed by #4001 — real code, and verified

On 2026-09-25 [#2829](https://github.com/moq-dev/moq/issues/2829) and
[#3948](https://github.com/moq-dev/moq/issues/3948) closed via
[#4001](https://github.com/moq-dev/moq/pull/4001) (`66440a6c`), which changes the exporter: the
earliest pending frame waits, bounded by `max_age`, until every other track has shown it cannot
precede it, and unchanged SI repeats are floored on the media-time grid. Re-verified on the primary
against `84b34f54`, two replicates each, raw exporter output ([T12](test-12-dual-path-handoff.md) §
*After the media-time interleave*):

| Issue | `84b34f54` | `66440a6c` | Verdict |
|---|---|---|---|
| #2829 — interleave by arrival | 98.33 %, 98.90 % of cross-PID adjacent pairs in the same order | **100.00 %, 100.00 %** | **fixed** |
| #3948 — SI phase set by exporter start | SDT 0.00 %, NIT 0.00 % | **SDT 91.67 %, 95.65 %**; NIT 66.67 %, 80.00 % | **fixed for the repeats**; the late leg adds one or two emissions of each table |

Residue outside both issues: TDT/TOT off-grid; one–two PCR-only packets per 40 s between legs
(24.7–24.9 % groomed slots identical); CC per process
([#2779](https://github.com/moq-dev/moq/issues/2779) abandoned). Byte-identical pairs now wait on
[#3925](https://github.com/moq-dev/moq/issues/3925) /
[#4645](https://github.com/moq-dev/moq/pull/4645), not interleave.

**#4001 costs the subscriber most of its delivery under random loss.** At 10 % uniform loss with no
rate cap, a subscriber built at #4001 delivers 0.49–0.67 Mb/s where its parent `044ca571` delivers
10.40 Mb/s, on either congestion controller and against either relay; at 0 % loss the builds are
indistinguishable ([T8b](test-8b-congestion-control.md) § *C7*). It was still present on `main` at
`6f1a9e33`, at 15–18 % of its 0 % control. **Reported as [#4613](https://github.com/moq-dev/moq/issues/4613),
fixed by our [#4618](https://github.com/moq-dev/moq/pull/4618), merged as `e488e699`.** Each source skip
under loss is a rewind, and `rewind()` renewed the hold's full `max_age` budget, so the next stall
skipped again. An instrumented build of `main` at `5124f8134` with only the hold varied gives 1.13 Mb/s
at 10 % loss as it stands, 9.80 with the hold disabled and 8.37 with it capped at 200 ms; the PR before
merge gives 9.70 and 9.87 at 10 % loss, and 9.84 at 0 % against 9.85 unfixed. The merged commit also
clears the stall in `resume()`, which the measured arms predate. **Open:** a rerun of C7 on the merged
build.

### The video DTS reserve froze at the PMT — contributed as [#4500](https://github.com/moq-dev/moq/pull/4500), merged and verified on `main`

**The defect.** `moq export ts` sized each video rendition's decode-clock reserve from catalog
`jitter` only until the PMT; without `jitter`, a 16-tick fallback held for the whole run, so two
legs of one broadcast could run different DTS and PCR values and B-frames on the fallback decoded
after presentation. Since #4001, mux order is interleaved regardless; the reserve affects DTS and
PCR values only.

**The contribution.** After the PMT, the reserve follows `jitter` and `framerate`, or without
`jitter` the SPS reorder depth times frame period at a fixed rate, grow-only to 2 s. Observed
reordering can exceed declared depth (IBBP declares 1, lands 2; 25i declares 120 ms, lands 240 ms).
One tick per frame decoded since the high-water frame covers x264 B-pyramid.

**Before and after**, PR before merge, P1, two `export ts` legs on one relay (second joining 10–20 s
in), `main` at `9d2a4f6e` vs PR:

| Source | `main` | PR |
|---|---|---|
| x264 B-pyramid over FLV: no `jitter`, no fixed frame rate | Both legs stay on 16 ticks; 347 of 672 and 233 of 455 frames decode after their PTS | Both legs settle at 10,802 ticks within the first group; 4 late frames per leg before that; joiner matches runner; shared PCR intervals identical with CC masked |
| 25i broadcast H.264 over TS: `jitter` in catalog before tables | 0 late frames; 36,000 ticks both legs | The same |

Neither build's TS legs are byte-identical (null slot placement — #3925; CC per process — #3868).

**After merge** (`7efe9b5ea`), P1, `main` at `6f1a9e33`: [T10](test-10-mpts-multiservice.md) 25i
programme captures show 4 late frames of 2,063 (access units 2–5), reserve rising 16 → 36,000 ticks
in the first group; programme 2 video has 0 late of 1,468. Since
[#4574](https://github.com/moq-dev/moq/pull/4574), a growing reserve flags PCR discontinuity.
**Open:** no live source publishes `jitter` after the tables (unit test only); x264/FLV paths
without published `framerate` leave a late joiner differing until deepest reordering is muxed; FLV
export reserve unchanged.

### The liveness exit, implemented — contributed as [#4504](https://github.com/moq-dev/moq/pull/4504), merged and verified on `main`

**The defect.** The quest is `quest/m1/export-linger.md`. On `main` at `9d2a4f6e` a clean publisher
end already exited 0 ([#4303](https://github.com/moq-dev/moq/pull/4303)), but a drop still exited 1
with `TS track layout changed… '0.avc3' removed`. That message reported a race, renditions retiring
before their tracks ended, rather than a real layout change; the FLV exporter had the same check.

**The contribution.** `export ts --linger <duration>`, default `0s`. Any end of the broadcast waits
for its path to return. The resume keeps the announced PIDs, sets the PCR discontinuity indicator
and re-sends PAT and PMT, and nothing is written while the broadcast is gone, so carrier liveness
and content liveness stay one event. The exit code is the last end's: 0 for a clean end, 1 for a
drop or failure. Tracks that leave the catalog are read to their own end.

**Before and after**, on the PR before merge, at P1: `CNNiEMEA2.ts` PCR-paced, the publisher
interrupted after about 7 s and restarted 3 s later, then 6 s to end of file, `main` at `9d2a4f6e`
against the PR with `--linger 10s`:

| | `main` | PR, `--linger 10s` |
|---|---|---|
| Publisher interrupted | exit 1, layout-changed error; no recovery | output stops and waits |
| Restart within linger | — | resumes; first PCR after return carries discontinuity; PAT/PMT re-sent |
| Final clean end | — | exit 0 ~12 s after second EOF |

The exit-code split rests on the PR's relay-backed CLI tests as well as on this rig.

**After merge** (`42a1fb5f3`), checked on `main` at `6f1a9e33` at P1: `--linger` carries the
exporter across a clean end and across a `SIGKILL`, and the exit code is 0 or 1 as specified, which
**closes #3926** ([T13](test-13-downstream-grooming.md) § *Liveness*).

**On `main` at `83ce47fe`**, graded per PID across 24 resumes (18 clean-end, 6 after `SIGKILL`),
no PID's continuity counter jumped, so the audio jump one `6f1a9e33` run showed is not reproduced.
A crash now costs the 10 s idle timeout of [#4606](https://github.com/moq-dev/moq/pull/4606) rather
than 30 s. What the grading did find is that **one resume sets the discontinuity indicator one to
four times**. An instrumented exporter shows that each extra flag is a whole-programme rewind
triggered by a single track's consumer changing generation within 2.5 s of the resume; a sparse
passthrough track did it twice in one resume.
Reported, with the instrumented log, as [#4767](https://github.com/moq-dev/moq/issues/4767), with a
follow-up locating the generation change: the consumer's catch-up walk over groups that never arrive
during the join, at the default `--max-age 500ms`, consistent with the publisher's age gate. At `--max-age 2s` every resume flags once
([T13](test-13-downstream-grooming.md) § *Liveness*). Upstream closed #4767 against a plan, not code:
the quest audit [#4845](https://github.com/moq-dev/moq/pull/4845) folds it into `quest/m1/tstd/delay.md`,
on the reasoning that [#4645](https://github.com/moq-dev/moq/pull/4645)'s jitter generations break the
PCR clock only on a declared restart. On #4645's head `559a35244` the replay arm flags each resume
once ([T47](test-47-fixed-delay-export.md) § *A broadcast that restarts under `--linger`*), and so
does `fe7cec106`, so the fix reaches `main` with #4645.

**On `main` at `edd671fff`, after [#4741](https://github.com/moq-dev/moq/pull/4741)'s route resume,
the crash case regressed.** The relay hands a replacement publisher the killed session's
subscriptions before it has published, and in two of three runs `moq import ts` exits with
*rendition is not published*; in the third the export stalls and ends on a catalog protocol
violation. Filed as [#4945](https://github.com/moq-dev/moq/issues/4945), with the `83ce47fe` runs as
the before-state ([T13](test-13-downstream-grooming.md) § *Liveness*).

`--linger` also carries the exporter across a relay restart, which `--linger 0s` does not survive
(one run each, [T13](test-13-downstream-grooming.md) § *Liveness*).

**An export failure read as the broadcast ending — contributed as
[#4947](https://github.com/moq-dev/moq/pull/4947), at the maintainer's invitation on #4645.** On
`main` at `edd671fff` every failed end lingers, so an export that fails on its own while the broadcast
stays up waits out the whole linger for a return that cannot come, then exits 1. The fix lingers on a
failed end only if the broadcast closes within a 1 s grace, since a killed publisher's tracks can
error just before its close arrives. A relay-backed CLI test with an AV1 publisher kept up and
`--linger 20s` exits after 23.3 s on `main` and passes on the fix. On the linger rig (local relay,
P1), with the publisher SIGKILLed and replaced, the three-session arm resumes in 3 of 4 runs on the
fix and 2 of 3 on `main`, and the two-session arm in none of 3 on either; a relay restart lingers and
resumes once on both. The new path fired in no run, and across the nine failed ends that lingered the
broadcast closed within 13.8 ms of the first track error, on loopback. Every run that does not
resume is #4945's.

**Still open:** the multi-flag resume on `main` until #4645 merges; the crash-case regression of #4945; the fMP4 and MKV exporters have no linger; the error text does not discriminate a
crash from a clean end, only the exit code does.

### #3798's plan asks for a reproduction, and the campaign has one — plus a correction to its scope

Quest #3798 names three triggers and reproduces none of them in-tree. Its claim that
`LegacyStream::reanchor` is set only once, so that a second unflagged loop wrap lands below the
live edge again, is what decides between a cumulative and a one-shot fix.
[T41](test-41-import-reanchor-coverage.md) confirms it: H.264 aborts on wrap **1.00** and legacy
audio on wrap **1.98**, so the offset must grow with each wrap. **It also corrects the quest's
scope.** AC-3 fails at the same 1.98 as MPEG-1 Layer II because `DolbyDigitalUpToSixChannelAudio`
goes through `legacy_stream`, which the tree documents as covering MP2, AC-3 and E-AC-3; the
dividing line is the stream type, not the codec. Both points were posted to #3798 with the fixture
recipe.

**Verified fixed on `main` at `9d2a4f6e`:** every stream kind on which `ffa5b81b` aborted survives
three unflagged wraps ([T41](test-41-import-reanchor-coverage.md)), and the SRT chain holds full
export rate through five joins ([T40](test-40-continuous-join-through-srt.md)). The likely fix is
[#3997](https://github.com/moq-dev/moq/pull/3997), and the permanence re-soak is unblocked on that
build. On `main` after the branch flip the question is moot rather than reopened: from #4543 every
unflagged wrap ends the import by design, on every stream kind (`83ce47fe`,
[T41](test-41-import-reanchor-coverage.md)). The exit-code baseline for #3926 went to that issue the same way: its plan specifies 0 for a
clean end and 1 for a drop, while the filing had recorded only the error text, and the build of the
time exited **1 in both cases, including when the publisher itself exited 0**.

### A loop wrap moved audio against video — contributed as [#4513](https://github.com/moq-dev/moq/pull/4513), closed in favour of [#4543](https://github.com/moq-dev/moq/pull/4543)

**The defect.** #3997 let each elementary stream grow its own shift at each unflagged wrap; audio
and video tails differ, so A-V drift grows every pass (quest estimated ~12 ms; byte-cut loop
measures far more). Visible where the importer publishes source timestamps (SRT gateway; all
importers once `remove-live` lands). `import ts` live mode re-anchors one offset — drift already
under one 90 kHz tick.

**[#4513](https://github.com/moq-dev/moq/pull/4513):** one shift per importer, PCR-bounded hold;
fails on `main` at 6.7 → 138.7 ms over four passes (6.7 ms source).

**Before and after** `[unmerged]`, P1, co-resident: first 100,000 packets of `CNNiEMEA.ts` looped 56
s, `main` at `6a016409` vs PR:

| Pass | `main`, `import srt`: AC-3 | MP2 | PR both codecs |
|---|---|---|---|
| 1 | 448 ms | 832 ms | 0.000 ms |
| 2 | 776 ms | beyond ±1 s | 0.000 ms |
| 3 | 984 ms | beyond ±1 s | 0.000 ms |

`import ts`: constant 0.000 ms (MP2) or one tick (AC-3) every pass.

**Superseded by [#4543](https://github.com/moq-dev/moq/pull/4543)**, which landed on the `dev` line
that became `main` on 2026-10-02: the importer publishes verbatim timestamps and **ends on any
rewind**, while a flagged forward discontinuity still publishes. The drift table is the record
against the pre-flip `main`.

**What #4543 does instead**, P1, co-resident: the `dev` line at `9a80e875` (since become `main`)
against the pre-flip `main` at `6a016409`; [T23](test-23-pcr-discontinuity-classes.md) arms from
`CNNiEMEA2.ts`, event at 30 s, 60 s PCR-paced ([T23](test-23-pcr-discontinuity-classes.md)). The
`--linger` column cherry-picks #4504, which was then on the pre-flip `main` only.

| Stimulus at 30 s | Pipe `import ts` | SRT `export ts` | SRT `--linger 10s` |
|---|---|---|---|
| A: 1 s back, flagged | import exit 1 | subscriber exit 1; caller redials | resumes, 1.38 s / 1.14 s stalls |
| E: encoder restart, flagged | import exit 1 | as A | 1.46 s stall one run; other run no catalog in 10 s → exit 1 |
| C: 30 s forward, flagged | full window | parse failures below | full window; 0.45 s stall |
| F: control | full window | full window | full window |

Error: *frame timestamp is below the previous group's start*. Flagged backward discontinuity now
kills a pipe-fed importer; SRT with redial + linger costs 1.1–1.5 s in four of five A/E runs;
without linger, whole feed. **Reported [#4582](https://github.com/moq-dev/moq/issues/4582)** for
in-connection republish after a signalled rewind. **Upstream now plans
`quest/m0/broadcast-epoch/ts-restart.md`** ([#4587](https://github.com/moq-dev/moq/pull/4587)): a
**flagged** rewind finishes the broadcast and continues the same input as a new broadcast under a
fresh epoch in the same process; an **unsignalled** rewind stays fatal — gates the next release. E
non-resume run not reproduced; `srt-live-transmit` zero-fill artefact is a candidate
([method-notes](method-notes.md#srt-live-transmit-fed-from-a-pipe-pads-every-short-read-with-zeros)).

**Content join on the `dev` line** (`9a80e875`): [T40](test-40-continuous-join-through-srt.md) clip
100 s, generator rebasing every PES ([method
note](method-notes.md#a-looped-source-is-continuous-only-if-every-pids-timestamps-are)): full rate
both paths (123.6–123.7 MB vs 123.9 MB `main` pipe); MP2 loses sync twice per join then recovers.
With the uncorrected generator the `dev` line ends at the first join (AC-3/teletext stepped back ~30
s); `main` re-anchored survived.

### One malformed packet ends a TS ingest — reported as [#4581](https://github.com/moq-dev/moq/issues/4581), fixed by [#4733](https://github.com/moq-dev/moq/pull/4733), merged

Planned with #4582 in [#4587](https://github.com/moq-dev/moq/pull/4587);
**[#4733](https://github.com/moq-dev/moq/pull/4733) merged to `main` 2026-10-03** (`9f94d85db`) and
**closed #4581**. Post-`aae930a23` review fixes: dedicated PCR PID damage gets a clock-only stats
row; a PES start whose header fails to parse flushes the prior unbounded PES and refuses only the
new unit. On desync, H.264/H.265 call `import.cut(None)` so the group closes at the break (already
in `aae930a23`).

**The defect.** `import ts` and the SRT gateway end the whole ingest on the first unparseable
packet; `transport_error_indicator` drops are already correct.

**Measured** on the `dev` line and on the pre-flip `main`, P1, co-resident pipe, 72 s
`CNNiEMEA2.ts`, one damage at 20 s:

| Damage | `dev` @ `9a80e875` | `main` @ `6a016409` |
|---|---|---|
| Video PES header/timestamp zeroed, TEI clear | exit 1 *Unexpected marker bits* | same |
| H.264 NAL `forbidden_zero_bit` set | exit 1 | same |
| Same PES damage, TEI set | carries on | carries on |
| ~24 seven-packet continuity gaps | carries on | carries on |

SRT parse storms traced to **`srt-live-transmit` zero-padding short reads**
([srt#3388](https://github.com/Haivision/srt/issues/3388)/[#3389](https://github.com/Haivision/srt/pull/3389),
merged unreleased —
[method-notes](method-notes.md#srt-live-transmit-fed-from-a-pipe-pads-every-short-read-with-zeros)).
Pipe arms isolate the importer defect.

**The fix, measured on #4733 PR head `aae930a23`** (before the last review fixes on merged
`9f94d85db`; re-run posted on the PR, and the same arms on merged `main` at `83ce47fe3` posted as
unchanged): refuses damaged PES/adaptation/access unit whole, clears PID,
resumes video at next keyframe. Same pipe rig: PES and NAL arms run full 60 s with one `dropped a
damaged TS unit` line vs exit 1 on pre-flip base `764b2868b`; TEI and twenty aligned 7-packet drops
complete. Earlier head on pre-flip base could end `export ts` on drops (*frame timestamp is below
the live edge*) from a keyframe-only group closing at the next GOP — `main`'s group-start rework
removed that check on the rebased head. P0 frame counts on the same capture:

| Input | `764b2868b` | #4733 at `aae930a23` |
|---|---|---|
| Clean | 2,492 | 2,492 |
| One TEI on video | 2,491 | 2,479 |
| Twenty aligned 7-packet drops | 2,471 | 2,114 |

A drop costs one frame on the base and the rest of its GOP on #4733 (~1.2 s here) — intentional, but
trades concealed artefacts for up to one GOP freeze per break (15 % vs 1 % video on this feed).
Misaligned-drop arm through `tsp` stops at 6.6 s on every build (file input desync), grading none.

**On the merged build** (`main` at `83ce47fe`, which also carries #4750; P1, the same pipe rig and
capture) every arm completes. The PES-header and NAL arms and TEI on the video and on the audio PID each
run the full 61.7 s with one `dropped a damaged TS unit` line, and two repeats of the twenty aligned
drops complete. Each arm delivers the same 73,849,972 B as on `aae930a23`, a figure the padded mux rate
sets rather than the content. The P0 frame counts were not repeated on the merged build.

**Open.** Loopback SRT loss rate unexplained (to 6 % at 10 Mb/s); libsrt-to-libsrt comparison not yet usable.

---

## 6. Interoperability

### The announce convention — reported as a hazard, not a bug

`moq-dev`'s publisher withholds its namespace announcement until a peer explicitly asks for it, and only
`moq-dev`'s own relay asks. Other relays expect announcement on connect, so the publisher negotiates,
reports no error, and sends no control message. **Checked against the drafts before reporting:** proactive
announce is a **MAY**; obligation bites only after subscribe — so `moq-dev` is fully conformant and
simultaneously unable to interoperate with relays that do not interrogate publishers (the normal case).
Reported as interop hazard [#2730](https://github.com/moq-dev/moq/issues/2730), not as protocol violation.

### The empty namespace prefix — a specification inconsistency

The subscriber opens discovery on an *empty* namespace prefix, which one relay rejects. The draft once
called a zero-field namespace a violation while the working group intended an empty tuple for
"give me everything". [moq-wg/moq-transport#1457](https://github.com/moq-wg/moq-transport/issues/1457)
closed in favour of the empty tuple, so this is implementation convergence rather than an open spec
question; our report is a data point that the divergence outlived the resolution.

### A media-level interop profile — contributed

The community interop matrix is control-plane only, so `setup-only` can report green where no media byte
flows — **an entire failure class is invisible to the matrix the ecosystem reads.** The argument to
[englishm/moq-interop-runner#32](https://github.com/englishm/moq-interop-runner/issues/32) is that
media-level validation does not require decoding played video: **pick a fixture container that checks
itself.** Every MPEG-TS PID carries a 4-bit continuity counter, so loss, duplication and reordering are
detectable from the received bytes alone, and the client demonstrates sensitivity to all three failure
modes rather than asserting it. The whole oracle reduces to one command. The client is public in
[`interop/`](../interop/README.md).

Two harness-level suggestions went with the proposal. The runner should include a control-plane test for
zero-field namespace-subscription handling, which would generate data for moq-wg#1457. It should also
record the transport actually negotiated alongside the draft version, because the client abandons QUIC for
a WebSocket fallback on a fixed 200 ms timer. Any relay much farther away than that is silently carried
over TCP, and the transport under test is not the one you think.

### A flag-alias regression — reported, fixed, verified, closed

Dial-side flags renamed on the development branch warned and then did not take effect: isolated one at a
time, connect and QUIC tuning flags failed independently while warnings named the correct replacement —
alias parsed, propagation missing ([#2913](https://github.com/moq-dev/moq/issues/2913)), found via a
merge-base control ([method-notes](method-notes.md) §1). **Fixed on the development branch, verified
here, and closed:** client and relay reject renamed settings outright and print the mapping. The report
argued hard error is strictly better than a compatibility shim: the replaced failure was invisible — GSO
stayed on, macOS loopback stalled, nothing logged — so scripts kept running and silently misconfigured.
**Still open operationally:** relay `--server-quic-gso` moved to `--quic-gso` in the same rename; rigs
updating only the client half still fail, and named branches disagree on spelling. Detect the surface from
`moq --connect … --help` rather than assuming either.

### Corroboration from an independent stack

`moqxr` [PR #21](https://github.com/mondain/moqxr/pull/21) reports the same preannounce split from the
publisher side — including early publish disturbing namespace registration so later subscribes fail — and
resolved it with preannounce opt-in, default-off. The same PR reports idle-timeout behaviour we measured:
a publisher with no subscriber dies at ~32 s to the default QUIC idle timeout. Corroboration that idle
timeout is a first-order operational constraint, not a single-stack artefact.

---

## 6b. FFmpeg: an HLS client that asks for HTTP/3 and carries the media over HTTP/1.1

Building the HTTP/3 path for [T20](test-20-segmented-http3.md) surfaced a defect that invalidates naive
HLS-over-HTTP/3 measurements with FFmpeg.

**The defect.** FFmpeg's HLS demuxer builds child URL options with `ffio_copy_url_options()`, whitelisting
names from the parent — including `prefer_libcurl` but not `http_version`, `tls_verify` or `ca_file`
(`libavformat/libcurl.c`). Segments therefore fetch by libcurl at libcurl's default HTTP version. With
`-prefer_libcurl 1 -http_version 3only`, the playlist negotiates HTTP/3 while segment connections offer
`http/1.1`; origin logs show `proto=HTTP/3.0 alpn=h3` on the playlist and `ALPN: server accepted
http/1.1` on media. Nothing in the client reports the split. Missing TLS options surface the bug on
self-signed origins (`Error when loading first segment`); publicly trusted origins succeed over TCP
quietly.

**The fix** (local to this campaign's build, documented in T20) adds `http_version`, `tls_verify` and
`ca_file` to that whitelist. **Verification:** against an nginx vhost with no TCP listener, a 60 s HLS
run logs 54 of 54 requests as `HTTP/3.0 alpn=h3` and the capture holds 109,657 UDP datagrams and zero
TCP; media md5 matches the HTTP/1.1 arm (`7f3402ea…`). Without the patch the same command cannot
complete against a TCP-less origin and completes over TCP against a trusted one.

Any published HLS-over-HTTP/3 comparison using FFmpeg's demuxer without checking segment ALPN at the
origin measures HTTP/1.1 — the same substrate mismatch this paper scores in the MoQ lanes.

**Status:** [FFmpeg #24752](https://code.ffmpeg.org/FFmpeg/FFmpeg/issues/24752); whitelist unchanged
on master `45f3fecca` (2026-09-22) by reading; open PR
[#24565](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/24565) fixes a related whitelist gap for
`local_addr`.

---

## 7. The carriage specification: MSFTS

Almost everything above targets an *implementation*. `draft-gregoire-moq-msfts` registers `m2ts`/`mpeg2ts`
packaging in the MSF catalog, so it fixes whole-transport-stream carriage for any implementation. It was
reviewed from one declared position — a whole multiplex to a hardware IRD, as SRT, Zixi and RIST carry
it today — because fidelity requirements need a named receiver.

The review opened as [mondain/msfts#7](https://github.com/mondain/msfts/issues/7); the author turned each
point into draft text. Summary of the first wave:

| Found | Changed |
|---|---|
| Per-programme retain list silently drops fixed-PID SI (NIT, SDT/BAT, EIT, TDT/TOT, ATSC PSIP) — **no service identity, EPG or broadcast time** if implemented verbatim | [#11](https://github.com/mondain/msfts/pull/11): states the loss, retention guidance, `m2tsSiPids` |
| Null removal changes byte distance between PCRs (CBR clock recovery) | [#10](https://github.com/mondain/msfts/pull/10): warns, advisory `m2tsMuxRate` |
| Continuity counters and PIDs *described* but not forbidden to rewrite | [#12](https://github.com/mondain/msfts/pull/12): MUST NOT rewrite; note on inter-packet PCR timing |
| No transparent whole-multiplex mode | [#8](https://github.com/mondain/msfts/pull/8): `m2tsMpts` |
| Filtering MPTS without SI rewrite ([#13](https://github.com/mondain/msfts/issues/13)) | [#19](https://github.com/mondain/msfts/pull/19) |
| No first-class native SPTS ([#14](https://github.com/mondain/msfts/issues/14)) | [#18](https://github.com/mondain/msfts/pull/18) |

Three further first-revision findings
([#15](https://github.com/mondain/msfts/issues/15)–[#17](https://github.com/mondain/msfts/issues/17)):
the 192-octet arrival-time prefix had no clock, units, layout or wrap — two implementations could
not interoperate on pacing; `m2tsMuxRate` did not say the egress recovers clock from carried PCR
(rate is stuffing target) nor whether the figure counts 188- or 192-octet packets; null removal was
declared via [#21](https://github.com/mondain/msfts/pull/21)'s `m2tsModified` but not
distinguishable from programme filter or PAT rewrite. #16 and #17 closed with
[#35](https://github.com/mondain/msfts/pull/35) on 2026-09-22 (#16 fixed as above; #17 declined on
field reduction). #15 closed after [#40](https://github.com/mondain/msfts/pull/40) reconciled Egress
Timing with the arrival-time definition (outcomes also under *The 2026-09-17 round*).

**Not measurement.** The only `m2ts` carriage run here is a private loopback prototype
([T3](test-3-opaque-transparency.md)); the public implementation strips nulls and derives SPTS per
programme — so shipped "transparent" is not byte-verbatim either. The review establishes the
specification no longer permits the silent version.

### The three named modes are published, and the gap they leave is output timing

§5.5 "Source Handling and Carriage Modes" subsumed #8, #14, #18 and #19 into **(1) unmodified SPTS or
whole-multiplex; (2) modified programme-level; (3) modified ES-level** — naming media-aware carriage in
spec scope for the first time. **None of the three modes requires the egress to *time* its MPEG-TS
output**; that was [#32](https://github.com/mondain/msfts/issues/32) in the 2026-09-17 round, with a
conditional MUST in Egress Timing after [#35](https://github.com/mondain/msfts/pull/35).

The case is measured ([T4](test-4-remote-e2e-srt.md) three-lane arm, **wire**, cross-host, `eab960192`):
raw `moq export ts` thins PAT 8.04 → 2.51/s, puts 8.19 % of PCR intervals above 40 ms (worst 319.94 ms
vs none above 40 ms in 600 s on source), and `analyze` reads ~15.66 Gb/s on ~10 Mb/s content. File
loopback percentages are worse ([T2](test-2-media-aware-transparency.md)) with join artefacts in maxima;
wire figures are the ones to quote. Rate-controlled egress measures IRD-grade — 0 of 20,193 intervals
> 40 ms over 300 s and the same over 24.01 h ([T19](test-19-pcr-grid-verification.md),
[T21](test-21-permanence-soak.md)). Two conforming implementations can still fail a hardware receiver
because **the property that decides lock is not in the mode definition.** Byte accuracy is specified in
detail; time accuracy is not; for 13818-1, PCR *arrival* recovers the system clock, so byte-perfect
delivery with arbitrary spacing is not a conformant transport stream at delivery.

[#12](https://github.com/mondain/msfts/pull/12)'s §5.6 note (non-normative, lowercase "should",
deployment-framed) concedes hardware IRDs recover mux clock from PCR arrival, that MOQT does not preserve
inter-packet timing, and that deployments "may require a rate-controlled egress". Four changes were asked
for, in descending priority.

First, **`mpeg2tsMuxRate` on ES-level tracks.** The original ask was that the field MUST be absent in
mode 3 ([#25](https://github.com/mondain/msfts/issues/25)); #35 instead made it RECOMMENDED, but mode 3
still left the subscriber obliged to recombine tracks without a declared rate. Second, **promote egress
timing** to a normative obligation on the subscriber that produces TS output, because MoQ cannot preserve
timing and the duty belongs at reconstruction. Third, **connect §6.12 arrival-time to §5.6**, so mode 1
with 192-octet stamped packets is the specified mechanism rather than an unused curiosity
([#15](https://github.com/mondain/msfts/issues/15)). Fourth, require the egress to **honour
`mpeg2tsPsiInterval` at output** ([#26](https://github.com/mondain/msfts/issues/26)), where measurement
showed PAT repetition fall 8.04 → 2.51/s. That fourth ask is adjacent to #15 and #16, which describe
timing that already exists on the wire, but it is not the same ask: it requires the egress to *impose*
timing that carriage destroyed.

Commercially, stating the target without mandating the method preserves a market for pacing components.
PCR slot pre-emption, the rate estimator, and stream- versus arrival-clocked operation decide whether
output is byte-identical or materially misaligned ([T19](test-19-pcr-grid-verification.md),
[T18](test-18-delivery-latency.md), [T12](test-12-dual-path-handoff.md)). A specification that stays
silent persuades implementers they need no such component until the first IRD fails to lock.

### The 2026-09-17 round: eleven issues filed, plus one comment and one cross-venue pair

Filed 2026-09-17 as `t0ms` (consistent with #7, #13–#17). Substantive asks included delivery
schedule ([#24](https://github.com/mondain/msfts/issues/24)), mux rate on ES tracks
([#25](https://github.com/mondain/msfts/issues/25)), PSI interval at output
([#26](https://github.com/mondain/msfts/issues/26)), CAT
([#27](https://github.com/mondain/msfts/issues/27)), enumerated carriage mode
([#28](https://github.com/mondain/msfts/issues/28)), verifiable `mpeg2tsModified`
([#29](https://github.com/mondain/msfts/issues/29)), group duration bound
([#30](https://github.com/mondain/msfts/issues/30)), group alignment
([#31](https://github.com/mondain/msfts/issues/31)), **output timing**
([#32](https://github.com/mondain/msfts/issues/32)), purpose of ES carriage
([#33](https://github.com/mondain/msfts/issues/33)), TR 101 290 gap
([#34](https://github.com/mondain/msfts/issues/34)), plus a [#15
comment](https://github.com/mondain/msfts/issues/15#issuecomment-5714034547) on arrival-time
mechanism and [moq-dev#3731](https://github.com/moq-dev/moq/issues/3731) (six convergence decisions)
cross-linked with #33.

**Outcome.** The editor replied to every issue and merged
[#35](https://github.com/mondain/msfts/pull/35) on 2026-09-22. The draft gained an Egress Timing
section carrying #32's conditional MUST, a §5.4 table mapping carriage fields to permitted modes
(#28), a §5.2 delivery-schedule paragraph with the ISO/IEC 13818-1 §2.4.2 pointer (#24), a BDAV
definition of the 192-octet arrival-time prefix (#15), the CAT and CA-descriptor PIDs in the retain
list (#27), and a recommendation rather than a prohibition of `mpeg2tsMuxRate` on ES-level tracks
(#25). The draft renamed `m2ts` to `mpeg2ts` throughout and deleted `m2tsPsiInterval`, which
dissolved half of #26 rather than answering it outright. Three asks were declined with reasons:
field reduction (#17 and #27's CA-PID list), #29's source PID inventory (an inventory from the same
pipeline that dropped PIDs would agree with its own output), and #34 (modified carriage as drafted
passes TR 101 290 P1 on the elementary-stream packets it carries). Later,
[#36](https://github.com/mondain/msfts/pull/36) replaced three fields with one `mpeg2tsMode` of six
values and added `es-units` and `media-frames`, which closed #33 with two convergence differences
noted for moq-dev. [#40](https://github.com/mondain/msfts/pull/40) fixed inconsistent Egress Timing
wording against the arrival-time definition and closed #15.

**Worth keeping from that round.** Issue #32 was written as a conditional MUST paired with a SHOULD NOT,
not as a bare MUST, because re-pacing costs latency equal to its buffer (109 ms ungroomed against 2,447 ms
groomed on different topologies, and no deployment has both). The #15 comment argued that arrival-time
carriage makes §5.6's premise that MOQT does not preserve inter-packet timing false for mode 1 with
stamps, and that #15 is therefore a blocking dependency for #32 rather than a loose end. Before filing a
follow-up, check the tracker for an open issue whose title does not already cover half the ask.

### moq-dev#3731 answered, and our re-assessment returned: agreement on the diagnosis, a concession on mux rate, one structural disagreement left

| Asked | Answered |
|---|---|
| MSFTS compatibility objective? | Convergence on **conversion, not verbatim transport** |
| Mode 3 right design? | No — "worst of both worlds" |
| Timing reference with media? | PCR "kind of dumb"; "IDK it doesn't really matter" |
| §5.5.3 group-alignment MUST? | Prefer timestamps; **optional acceptable** |
| SI in catalog or tracks? | No position |
| Observed mux rate recorded? | **Yes** — catalog `maxBitrate`, pad on export |

**The mux-rate answer is banked.** Both venues landed the same semantics in the same week: a stuffing
target rather than a timing source, counted over 188-octet packets after null removal, with
`mpegts.muxRate` and `mpeg2tsMuxRate` naming the same quantity.

**"Just always pad" was corrected on substance.** Padding to a declared rate makes the *total* bitrate
correct without making byte *positions* correct, and a receiver that clocks on packet arrival grades the
positions. The measurements that size that gap were kept out of the design thread deliberately and filed
as [#3925](https://github.com/moq-dev/moq/issues/3925).

**PCR needs clarifying rather than contesting.** Transmitting PCR across the network is not what recovers
a decoder's clock, and this campaign's architecture agrees: the egress re-synthesises PCR on its own grid
([T19](test-19-pcr-grid-verification.md)). The risk is that *"kind of dumb"* hardens into a reason not
to regenerate PCR correctly either, and the entire IRD-facing case depends on that regeneration. The reply
endorsed the draft's Egress Timing position that delivery-schedule conformance belongs where the
subscriber hands packets to its receiver, but it never stated explicitly that we regenerate rather than
transmit PCR.

**Group alignment is settled for us in the optional formulation**
([#31](https://github.com/mondain/msfts/issues/31)). The reply went once, on 2026-09-22, after
[#35](https://github.com/mondain/msfts/pull/35) published; it reported four of six points resolved,
with the payload unit (filtered 188-octet packets against access units) left with the editor at #33.

### The maintainer's objection to the round, and why the volume half of it is right

The editor objected to **volume** and **AI-generated** issues. On volume he is right: every one of sixteen
merged PRs on the draft — including #10–#12, #18, #19 from the first review — was **authored by him**
after our issues; filing defects had him write normative text, so eleven issues in one day is eleven patches
on one volunteer.

**Remedy.** Most of the eleven already contained proposed wording (#24, #25, #26 and #32 among them), and
the draft is kramdown in a repository we can fork. Converting asks to pull requests moves the drafting
work from the editor to us at close to zero marginal cost, and a patch that builds is evidence of review
in a way an issue alone is not. Two further cheap moves consolidate #28–#31, which are four defects in
one section, into a single pull request, and state a priority order rather than leaving eleven equal items,
because only we can say "if you only take one, take #32".

On AI provenance the objection is weaker but should not be argued with. The `moq-dev` repository openly
labels its own drafts as AI-generated ([#3728](https://github.com/moq-dev/moq/pull/3728)), and the
maintainer opened his reply to #3731 with *"I agree with mr AI"*. Provenance is not a norm being breached;
review burden is, and pull requests reduce burden. **Method rule:** *a review that only files issues
subcontracts its conclusions; where the artefact is text in a repository, send the text.* The first
sixteen issues were not converted, because the cadence was handled directly with the editor as a
relationship matter. The co-author later asked for group points to be filed as issues, and the *output
contract* round was sized by this objection to one new issue, one reopen and one closure. **One point to
accept without qualification:** the `moq-dev` implementer is not the reference for the draft. Argument
#33 makes stands on the draft's own text and the base specifications in that venue, not on implementation
choices, wherever the two projects disagree that is a convergence question for both.

### The output contract: what a rebuilding subscriber emits, filed as #37 and merged

After [#36](https://github.com/mondain/msfts/pull/36), the co-author asked that the points put to the
drafting group be filed as three tracker actions rather than eleven separate issues, because most of them
describe one change seen from different sides.

Issue [#37](https://github.com/mondain/msfts/issues/37) asked what a subscriber that rebuilds a transport
stream must output: every table at its standard's interval, including SI carried as section tracks; the
first output after a join; never re-emitting an unchanged TDT/TOT; the output where an Object is missing;
the `es-units` schedule caveat extended to recombined tracks; and that two subscribers produce the same
packets, which requires every regenerated field (interleave, table phase and `version_number`, continuity
counters, PCR placement, stuffing) to be a function of the tracks, with a media time on every Object so
sections can be placed. Issue [#34](https://github.com/mondain/msfts/issues/34) was reopened because
`es-units` and `media-frames` now regenerate counters, adaptation fields and PCR, so a stopped elementary
stream arrives as clean syntax. Issue [#33](https://github.com/mondain/msfts/issues/33) was closed as
answered by #36, with the two convergence differences recorded in the closing comment.

Before filing, the asks were cross-referenced against the moq-dev line, and that review changed two
of them. Byte-identical output is already the implementer's goal
([#4001](https://github.com/moq-dev/moq/issues/4001) fixed interleave and SI phase for an ST 2022-7
pair, and the `ts-export-jitter` quest targets byte-identical legs), but continuity counters remain
per process ([#3868](https://github.com/moq-dev/moq/issues/3868)) because a late joiner cannot know
earlier packet counts. #37 names that constraint and the keyframe-restart prototype's cost rather
than asking for deterministic counters as though they were free. On TDT/TOT, the group note said
"regenerate from the clock, not replay", while the moq-dev exporter forwards each new source value
and never re-sends an unchanged one; both sides forbid the repeated time, so #37 asks only for that
rule and leaves the method open. We did not file an unrecognised-mode MUST, because it affects only
an MSFTS-aware player on a future mode value and MSF parsers ignore unknown fields. We did not file
the metadata model or PES unit as defects, because those are cross-draft convergence choices in
#33's closing comment. Test vectors were offered in one line of #37; FEC belongs on the IETF list.

The text went as pull requests, one per open issue
([#38](https://github.com/mondain/msfts/pull/38)–[#40](https://github.com/mondain/msfts/pull/40));
**all three merged**. An independent critical review changed
[#39](https://github.com/mondain/msfts/pull/39) in three places. A continuity-counter jump on loss
went from MUST to SHOULD-with-example, and applies only to subscribers that generate counters. The
section timestamp is the ISO/IEC 13818-1 §2.4.2 byte arrival time, and it applies to `"section"`
Objects only, because mixing PTS for PES with arrival time for sections does not yield one coherent
timeline, so the interleave algorithm was dropped rather than specified. Identical output is
required of two instances of one implementation, not across implementations, which would need a
normative placement algorithm. #38 is scoped to the PCR PID; the reopen comment on #34 claimed
any-PID stop, which is broader than the claim that survives in #38.

### The retain list drops the CAT, so conditional access cannot survive program-level filtering

Filed as [#27](https://github.com/mondain/msfts/issues/27). §10 claims the packaging preserves scrambling
and conditional-access information present in the source transport stream. §5.5.2's per-programme retain
list keeps the PAT, the selected PMT, and packets whose PID is listed in the PMT, including the PCR_PID
and the PIDs of all elementary streams, but it does **not** include the Conditional Access Table at PID
0x0001, even though the paragraph that enumerates dropped fixed-PID tables names NIT, SDT, EIT and
TDT/TOT explicitly.

That omission matters because of the reference direction in the standards. ISO/IEC 13818-1 requires
system-wide conditional-access management information to be referenced from the CAT, and EBU Tech
3292-s1 §4.2.2.2 restates that in the CAT a `CA_PID` names the **EMM** stream, while in the PMT or an
elementary-stream loop it names the **ECM** stream. The EMM stream is not reachable from the PMT at all,
and dropping the CAT leaves nothing in the retained track pointing at it. The ECM PID is referenced from
the PMT, but by a CA_descriptor rather than in the elementary-stream loop, so the retain list's wording
also puts ECM at risk.

The failure is silent and total. The receiver gets scrambled elementary streams and entitlement control
messages, has no entitlement management messages, can never obtain the session key, and never descrambles
a packet, while every validation rule in §5.1 and §8 passes. §5.5.2's saving clause requires publishers
filtering scrambled streams to retain the conditional-access packets required for descrambling, but it
does not tell the implementer that the table locating those packets is the one the retain list discarded.
The finding has the same shape as the accepted #11 and #13/#19 work: a table on a fixed PID, outside the
PAT/PMT reference graph, dropped by a filter that only follows that graph. **Nothing here is measured** —
this campaign scrambles nothing — so the finding is a reading of specifications, not an observed product
defect. It was filed from a BISS-CA deployment question and closed when the CAT entered the retain list in
the #35 round.

A second, structural half remains for demuxed carriage in -01: ES-level tracks exclude PAT, PMT and nulls,
and the SI and programme fields MUST be absent, so there is no carriage path for the CAT, for CA_descriptors
in the PMT, or for any association between a scrambled stream and its ECM. A publisher also cannot identify
access points or reassemble PES inside encrypted payloads. §10's preservation claim cannot hold for that
mode, and the draft should have said so (-01 scope; demuxed modes removed in -02, below).

### Three further defects in the new sections, and one unimplementable MUST

Issues #28–#31 were found reading published §5.5 against the implementation and filed in the 2026-09-17
round. All four closed with [#35](https://github.com/mondain/msfts/pull/35).

Issue #28 noted that carriage mode was not a field: a receiver inferred mode from `m2tsModified`, the
presence of `m2tsEsPid` and `m2tsMpts`, with absent and false never stated equivalent for optional
`m2tsMpts`. #35 answered with a §5.4 table mapping the three fields to permitted carriages. Issue #29
noted that `m2tsModified: false` was an unverifiable assertion that common tooling violates silently:
`ffmpeg -c copy -f mpegts` reduces a 13-PID mux to five, dropping NIT, TDT/TOT, a second audio,
teletext and all three SCTE-35 PIDs ([T4](test-4-remote-e2e-srt.md)). #35 added a Security Considerations
note and declined the optional source PID inventory for the reason given in the round summary. Issue #30
noted that a fixed object count bounds byte span, not time, on a VBR multiplex, so join latency was
unbounded; #35 deleted the object-count SHOULD. Issue #31 noted that §5.5.3's group-alignment MUST cannot
be met literally across AAC and video cadences; #35 relaxed alignment to SHOULD with a note on differing
frame durations.

### Mode 3 and the reference implementation are not the same thing, and that is the convergence problem

At #33 filing, MSFTS mode 3 carried **188-octet TS packets** per PID with counters inside the
packets; `moq-dev` carried **decoded access units** (and `N.ts` PES, SCTE sections), discarded
counters, regenerated PCR on a 25 ms grid, and cut groups at keyframes (video) or every audio frame.
PAT/PMT lived in `initDataList` in MSFTS versus catalog regeneration in moq-dev; SI as ES tracks
versus catalog snapshots (EIT/TDT/TOT were gaps on `origin/main` then, since closed on snapshot
tracks). [#36](https://github.com/mondain/msfts/pull/36) added `media-frames` LOC carriage as the
second route; #33 closed noting catalog-vs-tracks and PES-unit differences for moq-dev convergence.

**Fourth mode.** The reference implementation is not MSFTS mode 3 as first published. It is
access-unit carriage with transport-stream re-synthesis at egress, a fourth mode the -01 draft did
not name as such. Filtered-TS carriage preserves continuity counters, adaptation fields and PES
framing exactly, and is a PID filter rather than a demuxer, so it carries what the publisher does
not understand. Access-unit carriage is what makes the lane media-aware: keyframes define group
boundaries so joins land on an IDR by construction, per-frame objects give frame-level priority and
shedding, and codec configuration reaches the catalog so a subscriber initialises without parsing
TS. That is the mechanism behind this campaign's latency result, and its price is precisely what the
measurements show lost: continuity counters, stuffing, mux rate and PCR spacing, all of which the
egress must reconstruct. Draft ES-level carriage sat between the two coherent designs and collected
cost without benefit. If `moq-dev` contributes demuxed spec text, four implementation-held facts
matter: why access units rather than filtered TS packets, why audio cuts a group per frame, whether
SI belongs in the catalog or as tracks, and what the exporter must reconstruct and cannot,
coordinated with wire conformance measurements. The cheapest convergence win, a declared mux rate
after null strip, landed on both sides ([#3831](https://github.com/moq-dev/moq/pull/3831) and draft
#25; [`evidence.md`](../docs/evidence.md) §3.5).

### The -02 revision: verbatim-only carriage ([#41](https://github.com/mondain/msfts/pull/41))

[#41](https://github.com/mondain/msfts/pull/41) ("Keep the verbatim family and simplify the draft
for -02") **merged 2026-10-03** (`ca29d6aa`). **Datatracker:** latest submitted revision remains
**-01** (2026-09-24); **-02 text is in the repository but not yet submitted.**

**Scope.** -02 is **verbatim-only**: `es-units`, `media-frames`, LOC tracks and the Rebuilt Output
section are **removed**; demuxed carriage is **deferred** to `draft-lcurley-moq-mpegts`. Sections
above through #36–#39 describe the -01 demuxed design; they remain the record of that round and the
convergence argument with `moq-dev`, not the current MSFTS scope.

**Adopted from our feedback:** a **188-octet `unmodified-program` baseline** every TS-output
subscriber **MUST** support; an **output rule** for unmodified modes (pass the reconstructed stream
unchanged apart from switching signals, catalog PAT/PMT at join, prefix removal), making **byte
identity between subscribers** a black-box test; optional **reference programme** on a multiplex
(`mpeg2tsProgramNumber` / `mpeg2tsPcrPid`) to pace on; **Groups SHOULD NOT last longer than 2
seconds**; softer continuity-counter wording ("can show" a gap) with subscriber **SHOULD** report
each gap's Location and duration; one-sentence **scope-out of error correction**;
[#42](https://github.com/mondain/msfts/issues/42) (**T-STD** conformance in unmodified modes)
answered for conformance testing.

**Not taken up:** a normative time reference; the `es-packets` schedule; CAT rewrite, peak-rate window,
`version_number` after a switch, `discontinuity_indicator` on non-continuity PIDs. Egress-timing promotion
 ([#32](https://github.com/mondain/msfts/issues/32)) is partially addressed by unmodified output rules and
#42 T-STD scope for verbatim modes; demuxed timing and ES recombination obligations that lived in -01 are
out of MSFTS until `draft-lcurley-moq-mpegts`.

**Round-two feedback has been sent to the co-author's group, by email.** It raises six points on
the -02 text: the 2-second Group bound against the random access rule, a multiplex without a reference
program having nothing to pace on, where a timing method would go, `es-packets` without arrival times,
whether a baseline subscriber can take `per-program`, and the two meanings of
`mpeg2tsProgramNumber`. It offers neither the test vectors the co-author asked for nor a companion
draft on TS-output health. Their reply is
awaited.

---

## 8. What was asked for at the start, what was retracted, and on what evidence

Four early requirements, filed before most measurements. **Three closed by us** — measurement contradicted
the ask; retraction is part of the contribution record:

| Filed | Asked for | What we did | What forced it |
|---|---|---|---|
| [#1799](https://github.com/moq-dev/moq/issues/1799) | direction: media-aware vs byte-opaque | **closed by us** when children resolved | direction settled by children |
| [#1861](https://github.com/moq-dev/moq/issues/1861) | second byte-verbatim opaque lane | **retracted by us** | #2440 → EIT-only gap; wire economics reversed; 1+1 byte identity another way |
| [#1839](https://github.com/moq-dev/moq/issues/1839) | generic TS egress sink with PCR-aware pacing | **partly landed, remainder retracted** | [#1845](https://github.com/moq-dev/moq/pull/1845); maintainer declined per-transport modules |
| [#1838](https://github.com/moq-dev/moq/issues/1838) | TR 101 290 monitoring | **corrected in place**; issue closed via [#4496](https://github.com/moq-dev/moq/pull/4496); ingest liveness ([#4502](https://github.com/moq-dev/moq/pull/4502)/[#4506](https://github.com/moq-dev/moq/pull/4506)), egress liveness ([#4577](https://github.com/moq-dev/moq/pull/4577)), TR 101 290 ingest counters ([#4750](https://github.com/moq-dev/moq/pull/4750), `main` `19563812f` 2026-10-03, not yet in a release) merged — detail §2 | half the original checks targeted moq egress timing; requirement restated; programme presence and moq-layer counters still open |

**Retraction held under temptation.** Issue #2967's PCR grid does not reach the wire because the
exporter's stdout writer discards frame timestamps (§1). The obvious report would re-file #1839's
declined half almost word for word and would contradict what we argued on #1838.
[#2984](https://github.com/moq-dev/moq/issues/2984) was framed instead as a **caller-contract**
defect: #2967's doc comments specify a caller-side pacer, `moq-srt` implements it, and `moq-cli`'s
`run_ts` discards it. Same fix, different and defensible claim.

- **[#1799](https://github.com/moq-dev/moq/issues/1799)** — The parent proposal presented media-aware and
  byte-opaque carriage as two options and asked for a direction decision. We closed it once its children
  resolved. The direction chosen is the lane this whole campaign measures.

- **[#1861](https://github.com/moq-dev/moq/issues/1861)** — We filed a second opaque lane on the claim that
  only byte-verbatim carriage delivers contribution-grade fidelity, which was true of the lane as it stood
  when filed and is not true now. We withdrew on three grounds. Pull request #2440 carries the service
  layer, so of the gaps the issue listed only EIT was left, a much smaller ask filed separately. **The
  economics were backwards:** byte-verbatim carriage looked like the neutral choice and demux/re-mux the
  costly one, but measured over a WAN against SRT on the same path the media-aware lane puts **0.982×** the
  source TS rate on the wire where SRT puts **1.037×**, almost entirely because it declines to carry null
  stuffing that a receiver regenerates locally for free ([T9](test-9-performance.md),
  [T14](test-14-data-plane-comparison.md)). The property still worth defending, two legs of a 1+1 pair
  being byte-identical, was reached another way by deriving every stream-position quantity from the stream
  rather than from the process ([T12](test-12-dual-path-handoff.md)). Scrambled or CAS carriage and true
  MPTS remain genuinely out of reach for a demux/re-mux lane; neither is measured here and both belong in
  the MSF-packaging discussion (§7), not on an implementation issue tracker.

- **[#1839](https://github.com/moq-dev/moq/issues/1839)** — We asked for UDP/RTP, FEC and ST 2022-7 outputs
  inside the tree with PCR-aware pacing. Half landed as a PTS-exposing export API and PCR-paced SRT egress
  ([#1845](https://github.com/moq-dev/moq/pull/1845)), which is the pacing primitive the request was
  really after. We retracted the remainder after the maintainer declined an import/export module per
  transport without a concrete customer, and because the grooming stage does not belong inside a transport
  library. What replaced it is a transport-agnostic pacer with no moq or QUIC dependency, for which a MoQ
  subscriber is merely one possible source ([T13](test-13-downstream-grooming.md)).

- **[#1838](https://github.com/moq-dev/moq/issues/1838)** — **Corrected rather than withdrawn**,
  because the requirement is real while the issue as filed aimed half of it at the wrong stream. The
  maintainer closed the issue when planning PR [#4496](https://github.com/moq-dev/moq/pull/4496)
  moved monitoring into upstream's quest backlog, but much of the ingest side has since **merged to
  `moq-dev` `main`** and is documented in §2. Per-stream liveness rows at ingest
  ([#4502](https://github.com/moq-dev/moq/pull/4502) and
  [#4506](https://github.com/moq-dev/moq/pull/4506)) and at egress
  ([#4577](https://github.com/moq-dev/moq/pull/4577)) are merged. TR 101 290 counters at ingest
  ([#4750](https://github.com/moq-dev/moq/pull/4750), merged as `19563812f` on 2026-10-03, **not yet
  in a release**) cover the Priority 1 checks except **`PID_error`**, which remains with the
  liveness rows, plus **`Transport_error`**, **`PCR_repetition_error`**,
  **`PCR_discontinuity_indicator_error`** and **`PTS_error`**, and **not** **`PCR_accuracy_error`**.
  The TS exporter still reports **no** TR 101 290 counters. Three corrections to the original filing
  stand. **First**, PCR and mux-rate timing checks on moq's egress target a stream no IRD ever sees;
  on a healthy chain they would sit permanently in alarm (0–26 % of PCR intervals exceed 40 ms
  depending on clip, and 1,523 of 1,524 PCRs fall outside ±500 ns ungroomed against 0 % and 0 of
  2,598 after grooming — [T7](test-7-timing-integrity.md), [T13](test-13-downstream-grooming.md)).
  That is what object delivery over a congestion-adaptive transport does to byte cadence, not a
  defect, and repairing it is the groomer's job; those timing checks belong out of scope on the moq
  side. **Second**, what grooming does not restore is the defensible egress list: a CBR pacer shapes
  transmission timing but does not demux, rewrite PSI or touch continuity counters, so sync,
  PAT/PMT, continuity, PID, transport-error, CRC and PTS faults seen at moq's egress are still true
  at the IRD. **Third**, TR 101 290 remains blind to the worst failure this chain has: a groomer
  asked only to hold a rate will hold it against a dead upstream, emitting a byte-perfect CBR
  carrier with valid TS, PAT/PMT and accurate PCRs but **no programme packets at all**, with every
  P1 and P2 check green; measured, an input-select receiver performed **zero** switches at every
  threshold from 50 to 500 ms ([T12](test-12-dual-path-handoff.md)). The requirement that answers
  that failure is **programme-packet presence**, counting packets that are neither null nor
  adaptation-field-only, because a groomer's own PCR insertions are neither null nor content and the
  naive version reads healthy too. At ingest the same issue leads with the wrong instrument for the
  same reason: after the resync fix, a lost-sync importer emits a genuinely conformant stream (§2),
  so the highest-value ingest signals remain **moq-layer counters** (resyncs and bytes discarded,
  per track) surfaced alongside the ETSI list rather than the ETSI list alone.

---

## 9. Documentation

Upstream review of [#2830](https://github.com/moq-dev/moq/pull/2830) objected to a grooming recipe invoking
a tool with no supported install path — prompting [T13](test-13-downstream-grooming.md), which graded
off-the-shelf options and concluded the **requirement should be stated with named options and measured
limits**, not a single mandated tool. That holds whether or not our tool installs; the gap is closed (egress
adapter is the crate binary, not an example).

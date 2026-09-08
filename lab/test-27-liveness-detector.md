# Test 27 — The per-PID liveness detector: built, and made to work in a real lane

**State: the detector is complete and validated. Five synthetic arms, three cross-host in-lane arms,
a fault-injection arm against the detector itself — and one fixed-N soak in which the detector found
a client-side defect, now bisected to a single upstream commit:
[#3375](https://github.com/moq-dev/moq/pull/3375), the rewind fix this campaign's own T23
measurements motivated, stalls video and primary audio permanently on a source that does *not*
rewind. Ready to report upstream.**

[T24](test-24-partial-media-plane-stall.md) concluded that per-PID access-unit liveness was the only
detector that caught every partial media-plane failure, and reached that conclusion with an offline
grader over a finished capture on one host. **This turns the recommendation into a running process
and finds out whether it survives contact with the distribution path.** It does, and the strongest
single result is a coincidence of two independent instruments:

| Same 60 s video suppression | Instrument | Delivered outage |
|---|---|---|
| [T24](test-24-partial-media-plane-stall.md) | offline grader, capture, loopback | 57.22 s |
| this test | live detector, cross-host lane, after the CBR groomer | **57.212 s** |

Different topology, different code, different measurement method, three decimal places apart. The
fine structure a liveness detector depends on **crosses a relay on another machine, the exporter's
PCR regeneration and a CBR groomer intact.**

The other results that matter:

- **The audio case is caught in 0.7–1.4 s.** T24's best wire-observable detector, the stuffing
  ratio, could not see a dead audio stream *at all* — 27.0 % against a control that peaks at 27.1 %.
  In the lane, all three non-video streams alarm within 1.4 s of the injection and the video PID
  stays silent. The detector's sensitivity is not proportional to the stream's share of the mux,
  which was the whole reason for building it.
- **Nothing fires on a healthy lane.** 180 s cross-host and 300 s of real broadcast material
  locally: zero alarms, and the 90 min N = 60 soak below adds to that.
- **Three of the failures found during this work were in the detector, not the lane.** A detector
  that blocks on `read()` cannot notice silence — it missed a *total* stall outright. A detector that
  takes media time as an absolute distance from the first PCR can be made to invent a 23,861 s outage
  by corrupting one byte. And learning across the lane's start-up transient set every threshold ~7×
  too wide. All three are fixed and each has an arm that fails without the fix, because a monitoring
  tool's own failure modes are the ones that produce a confident wrong answer.
- **The detector then earned its keep by finding something the campaign was not looking for.** A
  fixed-N soak meant as a false-positive test instead hit a **client-side stuck state at the source's
  first content-loop join**: the delivered clock stepped back 596.9 s, video and MPEG-1 audio stopped
  and never returned, and 60 exporters went on consuming 587 Mb/s while emitting 0.31 Mb/s each — for
  13 minutes, while a *newly joining* subscriber was served perfectly. Cause not yet established;
  recorded as an open defect with a control below, not as a conclusion.

Rig: [`ts-liveness.py`](scripts/ts-liveness.py) is the detector,
[`t27-liveness-inlane.sh`](scripts/t27-liveness-inlane.sh) the in-lane harness,
[`ts-partial-stall.py`](scripts/ts-partial-stall.py) the stimulus (unchanged from T24), and
[`f5-soak-side.sh`](scripts/f5-soak-side.sh) the fixed-N soak.

## Objective

T24 left the recommendation one step short of usable. Three things were unproven, and each of them
could have invalidated it:

1. **That the signal survives the lane.** T24 graded the delivered stream, so it knew the outage
   arrived. It did not ask whether the *evidence a detector needs* — access-unit spacing, which is
   exactly the fine structure a store-and-forward hop is entitled to rearrange — is still legible at
   the monitoring point, on the far side of a relay, an exporter that regenerates PCR, and a groomer
   that rebuilds the wire.
2. **That a threshold can be set at all in a real lane.** Delivered access-unit spacing is far more
   variable than a file's. A detector whose threshold is set by lane jitter rather than by media
   cadence is either insensitive or false-positive prone.
3. **That it is a detector rather than a grader.** Constant memory, no disk, no foreknowledge of the
   PID layout, and useful while the stream is still running.

## The detector

Five design decisions are load-bearing. Each is a correctness matter, and three of them were forced
by a failure recorded below rather than anticipated.

**An access unit is a PES start, and all three conditions are required** —
`payload_unit_start_indicator` set, a payload present, and the payload beginning `00 00 01`. T24's
stimulus, and a real encoder whose video path has died behind a running mux, emits
adaptation-field-only packets carrying PCR on the video PID. A packet with no payload must not be
read as a picture (ISO 13818-1 2.4.3.3), and a detector that counted packets rather than units would
report that dead stream as live.

**The expected stream set comes from the PMT.** A detector that watches the PIDs it has observed
cannot alarm on a PID it has never observed, so an encoder that comes up with its video path already
dead looks like a service that simply has no video. This is the `never started` arm, and it is a
case T24's method could not have produced.

**Thresholds are learned per PID, and streams without a cadence are declared unmonitorable rather
than watched.** Access-unit spacing across one mux spans orders of magnitude — 40 ms for 25 fps
video, 32 ms for AC-3, about a second for this clip's teletext, and unbounded for SCTE-35, which is
silent between breaks. T24 measured the analogous problem for the stuffing ratio; the same
proportionality defeats any single threshold. SCTE-35 and DVB subtitling are excluded by kind, and
saying so is more useful than watching them against an invented number. DVB signals AC-3 and
teletext both as private PES, so the kind comes from the descriptors, not from `stream_type` alone.

**Learning skips the lane's own start-up.** Measured against the raw exporter output with no warm-up,
every threshold in the mux was learned at **8,550 ms** — all four identical, because a single
media-time discontinuity during start-up was absorbed into all of them and set them ~7× too wide.
Discarding the first 5 s of media time brings the same measurement to 1,000–1,950 ms.

**It runs on two clocks, and they are not redundant.** Gaps are *measured* in media time from the
stream's own PCR, so a reading is a property of the stream rather than of how fast the pipe drained —
which is what makes 57.212 s comparable with T24's 57.22 s. But media time cannot measure its own
absence: if PCR stops, media time stops and a per-PID gap never grows again. Wall clock therefore
runs alongside as a dead man's handle on the clock itself.

## Environment

- **Relay host:** EC2 primary, `c6in.large`, 2 vCPU, `eu-west-1`. Relay only.
- **Publisher and subscriber host:** EC2 secondary, `c6in.2xlarge`, 8 vCPU / 15.7 GB, `eu-west-1b`.
- **Cross-host,** 0.72 ms RTT (mean TCP handshake; ICMP is blocked), GSO enabled both ends.
- **Build:** `moq` / `moq-relay` at the merge that closed
  [#3491](https://github.com/moq-dev/moq/issues/3491) via
  [#3515](https://github.com/moq-dev/moq/pull/3515); `mpegts-pacer` `5ab84cd`.
- **Chain, in-lane arms:** `ts-partial-stall.py` → `tsp -P regulate --pcr-synchronous` →
  `moq import ts` → relay (other host) → `moq export ts --latency-max 500ms` → `mpegts-pacer -
  11000000 --latency-ms 1000 --max-latency-ms 2500 --stall-ms 1000 --on-stall mute` →
  `ts-liveness.py`. `--latency-max 500ms` matches T24 so the two are comparable.
- **Local synthetic arms:** `CNNiEMEA.ts`, 1,983,892 packets, 299.976 s of media, graded from file.
- **Measurement point: after the groomer.** That is where an operator monitors, and it is not the
  same as the exporter's output — see the placement result below.

## Arms and results

### Synthetic, from file — does it fire when it should, and stay quiet when it should

Injection at t = 30 s of media time for 60 s. Detector defaults: 5 s warm-up, 20 s learning, so
armed at t = 25 s.

| Arm | Alarms | Which PID, and when | Delivered outage vs 60 s injected |
|---|---|---|---|
| `control` | **0** | — | — |
| `video` | 1 | 111 at t = 31.19, gap 1.195 s | **60.074 s** |
| `audio` | 3 | 131 at 31.02, 121 at 31.14, 123 at 31.73 | 60.049 / 60.272 / 60.197 s |
| `never started` | 1 | 111 at arming, reason `never started` | 19.997 s from arming to first unit |

Thresholds learned on the control and identical across the first three arms — 111 : 1,482 ms,
121 : 1,374 ms, 123 : 1,818 ms, 131 : 1,000 ms (the floor) — so the arms differ only in the
stimulus. **Zero alarms across 300 s of real broadcast material** is the reading that makes the rest
worth having.

The `never started` arm exposed a defect worth recording because it is the kind that leaves a
detector quietly useless: on recovery the stream was cleared but never given a threshold, so it ran
unwatched for the remaining four minutes. A recovered stream now re-learns — the outage it has just
emerged from is not evidence of its cadence — and the `WATCHING` event at t = 65.129 is that
re-arming being stated rather than assumed.

### The clock-stop arm — the case a media-time detector cannot see

A live pipe, 20 s of stream, 12 s of complete silence, 15 s more. This is [T22](test-22-silent-media-plane-failure.md)'s
total stall, and it is here because it is the failure a per-PID media-time detector is *structurally*
blind to.

| | Reading |
|---|---|
| clock stopped, declared at | **3.069 s** of wall silence (`--pcr-timeout 3`) |
| outage measured on resume | **12.096 s** against 12 s injected |
| per-PID outages reported | **0 — correctly** |

The last row is the point. In media time nothing happened: the clock stopped, so every stream's gap
froze where it was. Both clocks are needed and neither covers the other.

**The first version of this arm detected nothing at all**, because the detector was sitting in a
blocking `read()` waiting for a packet that was never going to arrive, so its loop never ran. A pipe
is now waited on with a timeout and the timeout expiring is itself an observation. *A detector that
blocks on input cannot detect silence* — and the failure it misses is the easiest one in the set.

### The corrupt-PCR arm — fault injection against the detector

One byte of one PCR base altered, 1,500 PCRs into an otherwise healthy stream.

| | Without the guard | With the guard (default) |
|---|---|---|
| alarms | **4 — every watched PID at once** | **0** |
| phantom outage | 23,861 s | — |
| media span reported | 23,906 s | **45.303 s, correct** |
| discontinuities | — | 2 (the jump, and the return) |

Taking media time as the absolute distance from the first PCR lets a single bad value move the whole
timeline, after which every stream appears to have been silent for as long as the error was large.
This is not hypothetical: it is what produced a **94,847 s** "outage" in a real run, when a broken
pipe fed the detector garbage. Media time is now accumulated step by step, and a step that is
backwards or further forward than `--pcr-jump` (5 s) is reported as a discontinuity rather than
absorbed as elapsed time.

### In-lane, cross-host — the arms that decide the question

Injection at t = 60 s of media time for 60 s, 180 s per arm, detector after the groomer.

| Arm | Alarms | Detected, relative to injection | Delivered outage vs 60 s |
|---|---|---|---|
| `control` | **0** | — | — |
| `video` | 1 — pid 111 | **+1.24 s** | **57.212 s** |
| `audio` | 3 — pids 131, 121, 123 | **+0.74 / +0.81 / +1.41 s** | 59.802 / 59.953 / 60.434 s |

Thresholds learned in the lane, stable across all three arms to within 4 ms — 111 : 1,083 ms,
121 : ~2,052 ms, 123 : ~3,110 ms, 131 : 1,985 ms.

Three things follow.

**The signal survives the path.** 57.212 s here against T24's 57.22 s, by an unrelated instrument on
a different topology. T24 recorded a 2.8 s discrepancy between the 60.02 s it injected and the
57.22 s it delivered, and flagged it as unexplained; this reproduces the discrepancy rather than
resolving it, which at least establishes it is a property of the lane and not of T24's grader.

**The audio case works, and that is the whole point.** T24's verdict on the stuffing ratio was that
it "works for video, **fails for audio**" — a dead audio stream moved the peak stuffing ratio to
27.0 % against a control peaking at 27.1 %, which is not a detection. Here the two audio streams and
the teletext each alarm inside 1.4 s, and the video PID does not alarm, so the detector also
*localises* the fault. Nothing in the delivered stream's whole-stream statistics does either.

**Detection latency is the threshold, and the lane sets it.** For the same content, the achievable
thresholds are 1.0–1.8 s from a file and 1.0–3.1 s at the groomed monitoring point: the lane widens
the small streams' thresholds by up to 1.7×. That is a real cost in sensitivity on exactly the
streams that need a per-PID detector, and it is stated rather than averaged away.

### Where the detector is placed changes what it can see

The exporter's output is not a groomed wire, and the same content measured at the two points learns
different thresholds:

| PID | From file | Raw `moq export ts` | After the CBR groomer |
|---|---|---:|---:|
| 111 video | 1,482 ms | 1,950 ms | **1,000 ms** |
| 121 mp1a | 1,374 ms | 1,000 ms | 2,084 ms |
| 123 ac3 | 1,818 ms | 1,800 ms | 2,936 ms |
| 131 teletext | 1,000 ms | 1,000 ms | 2,031 ms |

Neither point is uniformly better and the honest summary is that they trade: grooming tightens the
video threshold to the floor and loosens the small streams'. Measured directly on the exporter's
output, 102 media-time gaps over 0.3 s appeared in 39 s, simultaneously on every PID — PCR-only
stretches between bursts of PES, which is the exporter delivering by group rather than by packet.
**The monitoring point must be stated with any threshold figure**, and the operational point is the
groomed wire, because that is what leaves the building.

### The soak that was meant to be a false-positive test, and found a regression instead

The detector was attached to one of 60 remote subscribers for a fixed-N soak, intended as a
false-positive test at length and under load rather than as a fan-out measurement. **It found a real
failure at 590 s, and the detector is how the failure was characterised** — which is a better
validation than the clean run would have been, and a worse result for the lane.

At the source's **first pass join** — the point where `ts-continuous-source.py` restarts the clip's
content on a continuous timeline, at 600 s of media — the detector reported, in this order:

| t (media) | Event |
|---|---|
| 590.250 | `DISCONTINUITY jump_s=-596.9` — the delivered clock stepped **backwards by one pass length** |
| 591.275 | `ALARM pid=121 mp1a` — gap 1.025 s against a 1.000 s threshold |
| 592.250 | `ALARM pid=111 avc` — gap 2.125 s against a 2.100 s threshold |

Neither alarm ever cleared. Delivery did not recover for the **13 further minutes** the run was left
in that state.

**The source is not the cause, and that is measured rather than assumed.** Two passes of
`ts-continuous-source.py` through the same clip accumulate **1200.0 s of media with 0 backward PCR
steps and no step above 5 s** — the fixture does exactly what it claims. The copy on the subscriber
host is byte-identical to the repository's.

**The relay and publisher are not the cause either.** While the 60 incumbent subscribers were stuck,
a **subscriber joining afterwards was served perfectly**: 27.8 MB in 25 s — 8.9 Mb/s, with 143,872
video packets on PID 111 — from the same broadcast on the same relay.

**What the stuck state actually is.** All 60 exporters stayed alive, and each continued to *receive*:
the relay was still transmitting **642 Mb/s** and the subscriber host still receiving **587 Mb/s**,
with every EC2 allowance counter at zero and relay CPU at 0.54 of its 2 cores. Each exporter was
emitting **0.31 Mb/s**, identically — consistent with the tracks that did *not* alarm (AC-3,
teletext and PSI) continuing while video and the MPEG-1 audio stopped. **Bytes were being consumed
and not delivered, indefinitely.** The relay's own resource series stayed flat throughout, so this is
a client-side stuck state and not relay saturation.

**Why [T21](test-21-permanence-soak.md) did not see this.** T21 crossed about 144 of these joins in
24 h without a mark, which makes the difference between the two runs the entire question. T21 was
N = 1, loopback, `--latency-max 500ms`, with a pacer draining the exporter; this soak was N = 60,
cross-host, `--latency-max 3s`, draining to `/dev/null`.
[`t27-join-control.sh`](scripts/t27-join-control.sh) varies exactly one of those — four subscribers
at 500 ms and 3 s against one publisher across one join, at a fan-out too low for the relay to be
the constraint.

**Neither the buffer setting nor fan-out is the discriminator.** At N = 4, all four subscribers
stalled together at the join, to the same figure, within one 10 s sample:

| t (s) | 500 ms | 500 ms | 3 s | 3 s |
|---|---:|---:|---:|---:|
| 591 | 9.46 | 9.80 | 9.59 | 9.74 |
| 602 | 1.30 | 1.30 | 1.49 | 1.07 |
| 612 → 672 | **0.31** | **0.31** | **0.31** | **0.31** |

`--latency-max 500ms` — T21's own setting — behaves exactly like 3 s, and N = 4 exactly like N = 60.
So the two most obvious explanations are eliminated, and 0.31 Mb/s is reproducible to two decimal
places across four independent clients, which is what a deterministic timeline condition looks like
rather than a resource one.

**So the client build is the discriminator, and it bisects to one commit.** T21 ran on a build
predating the one under test, which leaves the build itself as the only untested difference. Shrinking
the clip to ~30 s turns the 600 s pass into a 30 s one, so a join arrives every half minute and a
verdict costs two minutes instead of twenty — the discriminator is the *join*, not the pass length.
With that, [`t27-bisect-step.sh`](scripts/t27-bisect-step.sh) drives `git bisect run` over the 53
commits between T21's build and today's, building the CLI at each and crossing several joins with the
candidate **and a known-good binary in the same run** as an in-run control. Six steps, every control
sample healthy at 9.1 Mb/s:

**First bad commit: [#3375](https://github.com/moq-dev/moq/pull/3375), `0e61e35` —
*"fix(moq-mux): recover buffered TS output after a rewind"*.** The fix this campaign's T23
measurements motivated, and verified, is the regression. It changed
`rs/moq-mux/src/container/ts/export.rs`, which is exactly the exporter that stalls.

**Confirmed against its own parent, which is also the commit the bisect passed.** Two replicates per
build, one publisher, one relay, ~7 joins in 240 s:

| t (s) | `025613d` parent | `#3375` | `025613d` parent | `#3375` |
|---|---:|---:|---:|---:|
| 10 → 20 | 9.51 | 9.22 | 8.67 | 9.19 |
| 30 (first join) | 9.49 | 1.33 | 9.28 | 1.40 |
| 40 → 241 | **9.0–9.8** | **0.31** | **9.0–9.8** | **0.31** |

**What the fixed exporter does to the timeline it is given.** Running the detector on each build's
output at once, on the same source, relay and join:

| | parent `025613d` | `#3375` `0e61e35` |
|---|---|---|
| delivered-clock discontinuities | **0** | **−119.35 s**, one pass length |
| video PID 111 | live, 0 outages | **DEAD**, never clears |
| MPEG-1 audio PID 121 | live, 0 outages | **DEAD**, never clears |
| AC-3 123 / teletext 131 | 8.0 s / 8.2 s outage, then `CLEAR` | live throughout |
| media span | 197.050 s | — |

Two things follow. The surviving PIDs are **exactly** the 0.31 Mb/s residue seen at N = 60, so the
small-scale reproducer and the soak are the same fault. And the parent sees **zero** discontinuities
on the same wire, so **the backward step is not on the wire** — the rewind the detector sees is
introduced inside the fixed exporter, which then cannot emit past it. The importer logs an MPEG-2
audio resync at the join (`resyncs=2 discarded=714`), which is the kind of event the new
rewind-detection path plausibly mis-reads, but the internal trigger is not established here and is
left as inference.

**The fix works on the case it was written for. It has been traded for its complement.** Same two
builds, same clip, only the source's timeline differs — `tsp --infinite` really does rewind:

| source | parent `025613d` | `#3375` `0e61e35` |
|---|---|---|
| **true rewind**, every 30 s | **0.00 Mb/s** from t = 40 s — total stall, the #2833 behaviour | **8.66 Mb/s** mean, dipping to ~7.4 at each rewind and recovering |
| **continuous timeline**, content join every 30 s | **9.0–9.8 Mb/s** throughout | **0.31 Mb/s**, video and MPEG-1 audio dead |

Neither build carries both. Pre-#3375 a rewinding source costs everything; post-#3375 a
**non**-rewinding source whose content restarts costs video and primary audio. For primary
distribution the second is the worse trade, because a continuous timeline with content joins is what
a real encoder emits and a rewind is not.

### The code path, and why only some PIDs die

The fence is readable in the diff, and one prediction from it was tested rather than asserted.
#3375 adds a program *generation* (`epoch`) to the exporter and a re-admission test to each track:

```rust
fn admit(&mut self, pending: Pending, epoch: u64) -> Option<Pending> {
    if self.epoch == epoch
        || (pending.discontinuity != self.discontinuity
            && self.timeline.is_none_or(|last| pending.frame.timestamp < last))
    { return Some(pending); }
    self.discontinuity = pending.discontinuity;
    None                     // frame discarded
}
```

`rewind()` bumps the generation, and on a **backwards** boundary it deliberately leaves every track
that already has a timeline behind:

```rust
if !backwards || track.timeline.is_none() { track.epoch = self.epoch; }
```

So after one track reports a backwards step, every *other* track is fenced into the old generation,
and the only way back is a frame that both changes its discontinuity counter **and** steps backwards
on that track's own timeline. **A track whose source never rewinds can never satisfy that**, and its
frames are discarded indefinitely — which is the permanent loss of PID 111 and PID 121, while the
passthrough `.ts` track carrying PSI, AC-3 and teletext is unaffected and keeps the lane at
0.31 Mb/s.

**Two elementary streams are required, and that is the tested part.** If the fence needs one track to
rewind while another does not, a source with a *single* track cannot exhibit it: the triggering track
re-joins the new generation itself, and there is no bystander to fence. A video-only source across
five joins, same two builds, same relay:

| t (s) | parent `025613d` | `#3375` `0e61e35` |
|---|---:|---:|
| 10 → 151, five joins | 1.88–2.00 | **1.88–2.02** |

Identical, and both clean. So the multi-track case is necessary, which is consistent with the
importer's MPEG-2 audio resync at the join (`resyncs=2 discarded=714`) supplying the one backwards
step. **What remains inference** is precisely which comparison inside the audio path yields
`backwards = true` on a source measured at 0 backward PCR steps — a track's own high-water mark is
not the programme clock, and cross-track skew at a hard cut is a plausible source of a small local
step. The report names the fence, which is actionable, and says this much and no more about the
trigger.

Raw captures — the bisect log with per-step control readings, the paired-replicate confirmation, the
true-rewind contrast and both detector event streams — are in
[`results/t27-3375/`](results/t27-3375/), and the report is drafted at
`docs/upstream/3375-continuous-source-regression.local.md`.

**What this does and does not say about the lane.** It is a client-side defect in one build of one
exporter, on one stimulus, and it is neither a relay limit nor a property of media-aware carriage:
the relay served a fresh subscriber perfectly while 60 incumbents were stuck, at 0.54 of 2 cores with
every allowance counter at zero. [T23](test-23-pcr-discontinuity-classes.md) measured the six
discontinuity *classes* and found all six survivable; this is a **different** stimulus — a continuous
timeline whose content restarts — and the two must not be conflated. T23's verdict on its own arms
still holds against #3375; what T23 could not have caught is this case, because no T23 arm ran a
continuous source.

## What this establishes

1. **T24's recommendation is implementable and works in the distribution path.** Per-PID
   access-unit liveness, running live at the groomed monitoring point behind a cross-host relay,
   caught every arm at its true length and fired nothing on either control. The outage length agrees
   with T24's independent offline measurement to three decimal places.
2. **The media-aware lane preserves the evidence that per-PID monitoring needs.** This is the
   architectural result. A demuxing carriage layer could have destroyed access-unit spacing while
   still delivering conformant bytes, which would have made the only sufficient detector unusable in
   the very architecture that needs it. It does not.
3. **A dead audio stream is detectable in about a second.** The failure mode with no wire-observable
   signature at all in T24 — 4 % of the mux, invisible to the stuffing ratio, invisible to every P1
   check — is caught and localised to the PID.
4. **Detection latency is bounded and knowable in advance.** It equals the learned threshold, the
   detector reports its thresholds when it arms, and an operator can therefore be told what their
   detection time will be per stream before a fault occurs.
5. **The detector's own failure modes are characterised.** Blocking input defeats silence detection;
   absolute media time lets one corrupt PCR fabricate an outage across every PID; learning across a
   lane's start-up transient desensitises every threshold by ~7×. All three are fixed, and each has
   an arm that fails without the fix.
6. **The detector paid for itself on its first real run, which is the practical case for it.** It was
   attached as a false-positive control and instead localised a fault to two PIDs and named the
   delivered-clock step that precedes them — a fault whose *wire* remained conformant and whose byte
   counters at the relay showed 642 Mb/s of healthy transmission. Neither the relay's resource series,
   nor P1/P2 conformance, nor a rate check at the relay would have shown it. That is exactly T24's
   argument, now demonstrated on an unplanned failure rather than an injected one.
7. **A regression in a merged upstream fix was attributed to one commit in about an hour**, by
   shrinking the reproducer's period and bisecting with a known-good binary as an in-run control. The
   method is reusable and is written down in [method notes](method-notes.md).

## What this does not establish

- **Nothing about a frozen picture**, exactly as in T24. Every arm here removes access units. An
  encoder emitting *valid* access units carrying an unchanging picture advances PCR, PTS, DTS and the
  continuity counters, holds its bitrate, and defeats this detector too. That needs decoding and
  comparing pictures, it is equally undetectable under opaque carriage or over SDI, and it is a limit
  of transport monitoring in general.
- **One clip, one PID layout, one mux.** The thresholds are this programme's; the *method* of
  learning them is what transfers. A mux with PCR on its own PID, or with a sparse subtitling stream
  that a broadcaster does expect to be live, would need the classification revisited.
- **The learned threshold is only as good as its learning window.** 20 s of observation sets a
  threshold from the worst spacing seen in 20 s. A lane whose jitter has a longer tail than that
  would false-positive later, and this run is too short to bound that tail. `--gap` exists so a
  threshold can be derived from the format instead — which is more defensible, since a broadcaster
  knows its frame rate — and that path is tested but not soaked.
- **Nothing about a multi-programme mux.** One service throughout. The PMT walk handles several
  programmes by construction and that construction is untested.
- **Nothing about detection-to-response.** As in T24, this measures when the signal becomes
  available, not what an operations system does with it.
- **The detector is a reference implementation, not a product.** Pure Python at 11 Mb/s costs
  roughly a core; it demonstrates that the measurement is available and cheap in principle, and says
  nothing about the cost of doing it at scale across many services.

## Open

**A per-track liveness signal in `moq import ts`**, carried over from T24 and unchanged by this test.
The publisher already parses each elementary stream in order to demux it, logs a warning when the
*audio* parser loses frame sync, and has no equivalent for video. Everything measured here is done
by a downstream observer reconstructing what the publisher already knew. Still drafted for upstream.

**Whether the 2.8 s compression of the outage is the exporter's PCR regeneration.** T24 measured
60.02 s injected against 57.22 s delivered and could not explain the sign; this reproduces it at
57.212 s across a different topology, which makes it a property of the lane. One focused run.

**Whether the lane's spacing jitter has a tail longer than the learning window.** The 90 min soak is
a start and 90 minutes is not a permanence claim.

## Corrections

**The exporter's per-process memory is not fixed, and T26's reading of it is superseded.**
[T26](test-26-cross-host-fanout.md) recorded the client's cost as "~96 MB, fixed per process rather
than buffer-driven, and no attempt was made to attribute it". Holding N constant and letting time be
the only variable shows it is a **cache filling to a plateau**, and the three signatures of that are
all present at two fan-out levels:

| Fixed-N run | Mean RSS per exporter | Largest single process | Log fit | Linear fit | Second-half slope | Largest drawdown |
|---|---|---:|---:|---:|---:|---:|
| N = 10, 703 s | 49.0 → **119.1 MB** peak | 124.4 MB | **r² = 0.904** | r² = 0.602 | **−0.21 MB/min** | 9.4 MB |
| N = 60, 547 s | 66.4 → **116.7 MB** | 134.2 MB | **r² = 0.973** | r² = 0.793 | +2.54 MB/min | 3.7 MB |

A logarithm beats a line on both, growth decelerates to nothing at N = 10, and **memory is given
back** — 9.4 MB of drawdown from a running peak, which a leak does not do. Past 300 s the mean sits
in the **106–119 MB** band, which is where [T21](test-21-permanence-soak.md) independently found the
exporter from 0.5 h to 4.5 h (119–122 MB). T26's figure was this fill measured at 45 s, not the
steady state; **~120 MB per session is the figure to plan against.**

The method rule this yields: *a per-N ramp cannot measure anything that develops over time, because
N and elapsed time move together in every reading.*

**A "high fan-out permanence soak at N = 100" is not runnable on a 15.7 GB host, and the first
attempt at one misattributed its own failure.** 100 subscribers × ~120 MB is 12 GB before the
publisher, the graders and the kernel, so the host OOM-killed a subscriber at about nine minutes
after 38 M direct-reclaim scans. The run was configured to stop on a *delivery* threshold and duly
reported "per-subscriber delivery fell to 78.5 % at n=100" — but `rx_bytes` was constant at
~12.86 GB per cell across every cell including that one, and relay egress held 990 Mb/s throughout.
**The bytes never stopped arriving; the harness stopped being able to account for them.** A delivery
threshold measures the harness's own thrashing. The soak rig now stops on `MemAvailable` instead,
which fires while the readings still mean something and names the harness as the cause.

**Two harness collisions, both mine, both now prevented in the scripts.** An unscoped
`pkill -f ts-liveness.py` in the in-lane rig's cleanup killed a detector belonging to a *different*
experiment on the same host, breaking that experiment's subscriber pipe and ending its run — and it
was the resulting garbage that produced the 94,847 s phantom outage. Separately, reusing one
broadcast name across back-to-back arms cost a run: [T25](test-25-isolation-under-abuse.md)'s
retention means the relay holds an abandoned session until the QUIC idle timeout, so the next arm's
subscriber attached to the previous arm's broadcast and died with `json: dropped` when the new
publisher replaced it. Each arm now gets its own broadcast name, and every kill pattern is scoped to
the run rather than to the tool.

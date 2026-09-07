# T21 — the permanence soak of the complete media-aware lane

> **State: complete. The 24 h soak on a continuous timeline passes on the media plane and fails F2 on
> resources, in one role.** 24.01 h, 632,199,204 packets, 5,947,298 PCRs: **zero** continuity errors,
> zero PCR intervals over 40 ms, zero absolute PCR failures at ±500 ns, zero drops, **zero underruns**,
> zero respawns, and a worst programme gap of **27 ms across the whole day**. The 33-bit rollover was
> crossed in flight at 19.4 h and cost nothing. The groomer's own resident memory is **flat**, and the
> buffer walk that [P0-3b](planned-experiments.md) was opened for **did not occur**.
>
> The one failure is upstream and it is in the publisher: **`moq import ts` resident memory grows
> linearly at +2.83 MB/h** and holds that slope across all four quarters of the run, which on this host
> is exhaustion in about seven and a half months. F2's criterion was fixed in advance and this trips it.
> The relay, by contrast, is **logarithmic and bounded**, which settles a question T8b left open.
> Recorded in [§ The 24 h soak](#the-24-h-soak-on-a-continuous-timeline).
>
> **The first run is superseded.** Its source was `tsp --infinite`, which restarts the clip and
> therefore its clock. [T23](test-23-pcr-discontinuity-classes.md) has since measured what that costs —
> a rewind of N seconds costs N seconds of programme — so that run was measuring recovery from a rewind
> it manufactured, roughly every 665 s, and could not have measured permanence whatever it found. **Its
> findings stand as findings and are kept below**; what does not stand is the reading of them as a
> permanence result.

> **The first run.** This was the first long run in the
> campaign to put the **groomer inside the measurement**: [T8b](test-8b-congestion-control.md) C6 soaked
> `moq export ts` with `tsp count` behind it and [T9](test-9-performance.md) soaked the relay, so the
> stage that makes this lane conformant had never been run for longer than a single 300 s cell.
>
> **The wire stayed conformant and the groomer did not stay in its operating state.** Across that run:
> **0 continuity errors, 0 PCR intervals above 40 ms, worst interval 30.08 ms, mux rate exactly
> 11,000,000 b/s, 0 dropped packets, 0 late drops, 0 respawns**, and programme content conserved at the
> source rate throughout. Every check an operator could point at the stream passes.
>
> **Behind that wire, the groomer's release loop has come apart.** At about nine minutes the recovered
> media-rate estimate leaves the true rate and ramps **linearly and without bound** — 9.34 Mb/s at
> t=541 s, 34.7 Mb/s at t=601 s, **2.58 Gb/s at t=1,202 s** and **6.98 Gb/s at t=2,404 s**, gaining a
> steady ~250 Mb/s per minute with no sign of turning over. The de-jitter buffer it is supposed to hold collapses with it, from a
> standing **10,587 packets (~1.4 s) to 0**, and buffer underruns accumulate at **~970 per second**
> thereafter.
>
> **Nothing downstream can see this.** Programme is conserved, so no content check fires; the carrier
> holds its rate, so no bitrate check fires; PCR repetition and continuity are untouched, so
> TR 101 290 P1 does not fire. What has been lost is the cushion itself — the groomer has become a
> pass-through with no jitter absorption at all — and the only instrument that shows it is the groomer's
> own counters, which is why they were added before this run.
>
> **The mechanism is now located, and the first attribution was wrong.** The trigger is the source's
> PCR discontinuity — `tsp --infinite` reaching the end of the clip and looping, at 600 s. The
> publisher's input takes it in its stride: captured before MoQ sees it, the source carries **exactly
> one** discontinuity, PCR 26,225.6 s → 25,625.6 s at packet 3,967,658, and resumes its clean 25 ms
> grid immediately. The exporter's output carries **zero** discontinuities, because it never follows
> the wrap. It **latches the last pre-wrap value and thereafter emits a PCR that advances by exactly
> one 90 kHz tick per PCR packet** — 0.0111 ms, a counter and not a clock — and never recovers. After
> that, 100,000 packets of programme carry **6.9 ms** of PCR where they should carry 15,880 ms.
>
> **The class is characterised in [T23](test-23-pcr-discontinuity-classes.md), and this stimulus is not
> representative of it.** Deliberate signalled discontinuities produce a *withhold-and-burst* — output
> stops for exactly the size of the rewind, then the backlog is released — with a healthy clock either
> side and no counter anywhere. Forward jumps and the 33-bit rollover are carried correctly. What
> generalises from T21 is that the exporter does not act on `discontinuity_indicator`; the counter
> degeneration measured here does not.
>
> **So the defect that starts it is upstream's, and the defect that amplifies it is ours.** The pacer's
> rate estimator was arithmetically faithful to an input that had stopped telling the truth: it divided
> real packets by a media time that had stopped advancing, got a rate two orders of magnitude above
> anything the carrier could hold, released on it, and drained its own cushion. Both halves are now
> addressed — the estimator is fixed and regression-tested here, the exporter behaviour is reported
> upstream — and they must not be conflated. *An earlier reading of this experiment called the whole
> thing ours on the strength of a clean exporter log. The log is clean; the exporter is not.*
>
> **The consequence for the paper is a scope, not a retraction.**
> [T19](test-19-pcr-grid-verification.md) measurement 11's conformance result stands for the window it
> was measured over. It was a 300 s window, the divergence begins at about 540 s, and so the claim that
> the media-aware lane produces a conformant CBR wire **is established for minutes and is not yet
> established for hours** — the re-soak that would establish it is the next run, not this one.

## Objective

Does the complete media-aware lane — publisher, relay, exporter, groomer — remain in a *stable
operating state* as uptime grows, or does it merely survive?

The distinction is the whole point. Survival was never in doubt; T8b C6 ran 14 h with zero continuity
errors. What a permanent feed is graded on is whether the quantities that are supposed to be
stationary stay stationary: resident memory, thread and descriptor counts, delivery latency, and — new
here — the groomer's buffer occupancy against its set point.

The groomer had to be inside the measurement for two reasons. It is the stage that makes this lane
conformant, so a soak without it does not soak the lane. And it now contains a **control loop**: the
release rate is trimmed by the buffer's distance from the cushion. A loop that is stable for five
minutes is not thereby stable for a week — it can drift, hunt, or settle onto a different set point
once the transient it started in has decayed. Nothing in the campaign had tested that.

## Environment

- **Host:** EC2 primary, `c6in.large`, 2 vCPU / 3.8 GB, `eu-west-1a`. Loopback, no shaping, no netns —
  impairment is a different experiment ([T5](test-5-network-impairment.md),
  [T8b](test-8b-congestion-control.md)), and mixing the two would leave a drift unattributable between
  the loop and the path.
- **Build under test:** `moq 0.9.11-eab96019` / `moq-relay 0.14.11-eab96019` (`main` @ `eab960192`,
  carries [#3351](https://github.com/moq-dev/moq/pull/3351)); `mpegts-pacer` at `41e6181`.
- **Source:** `~/CNNiEMEA2.ts`, `md5 364ce82c…`, looped by `tsp -I file --infinite -P regulate
  --pcr-synchronous`. The loop wraps about every 665 s, so a multi-hour run crosses it dozens of times.
- **Chain:** `tsp` → `moq import ts` → relay → `moq export ts --latency-max 500ms` → `mpegts-pacer -
  11000000 --latency-ms 1000 --max-latency-ms 2500 --stall-ms 1000 --on-stall mute` → `tsp -P continuity
  -P pcrverify --absolute --jitter-max 500 --bitrate 11000000 -P count` → `t21-pcr-monitor.py`.
- **Rig:** `lab/scripts/t21-lane-soak.sh`, sampling every 60 s.

Nothing is stored. A conformant 11 Mb/s wire is 119 GB a day; every check runs in flight and the whole
record of the run is a few hundred kilobytes of text.

## Instruments

Two were built for this run, because the existing ones answer a different question.

**`mpegts-pacer --stats-interval-ms`** and **`Stats::buffer_packets`**. The groomer previously reported
only when it stopped, and `buffer_high_water` only ever rises — an hour after one transient it still
reports the transient, so it cannot say whether the loop is *still* holding its set point. The standing
depth sampled on a timer is the loop's error signal, and it is the reading that found this.

**`lab/scripts/t21-pcr-monitor.py`**. `ts-pcr-timing.py` grades a window and exits, which is right for
"is this build conformant" and wrong for "is it still conformant at hour forty". The monitor prints one
line per minute for as long as the feed runs, and keeps only counters.

It was validated against all ten `ts-pcr-fixtures.py` boundary conditions before use, and against
TSDuck on the source clip, where it returns the same packet count (3,967,645) and the same zero
continuity errors. The two that matter: it handles the **33-bit PCR wrap** without reporting a
26-hour interval, and it does **not** read a `PCR_flag` on an adaptation field too short to hold one —
the trap that produced a 95,441,900 ms reading in an earlier analyser. It accepts a legal duplicate
packet without calling it a continuity error, and it detects the signalled discontinuity, the
loss-recovery gap and the over-limit spacing fixture.

## Results

### The wire

| Metric | Result over that run |
|---|---|
| Continuity errors | **0** |
| PCR intervals > 40 ms | **0** |
| Worst PCR interval | **30.08 ms** |
| `pcrverify` absolute failures at ±500 ns | **0** |
| Mux rate | **11,000,000 b/s** (occasional 10,999,999 rounding) |
| Programme conserved | yes — content advances at 6,348 pkt/s ≈ **9.55 Mb/s**, the source rate |
| Dropped / late-dropped packets | **0 / 0** |
| Respawns | **0** |

The stream an IRD would receive is clean and stays clean while everything below goes wrong.

### The groomer's release loop

Sampled every 60 s from the groomer's own counters:

| t (s) | buffer (pkts) | arrival lead (ms) | recovered media rate | underruns |
|---:|---:|---:|---:|---:|
| 60 | 10,348 | 850 | 9.49 Mb/s | 0 |
| 240 | 11,578 | 1,082 | 9.40 Mb/s | 0 |
| 420 | 10,522 | 1,254 | 8.14 Mb/s | 0 |
| 541 | 10,587 | 1,265 | 9.34 Mb/s | 0 |
| **601** | **2,494** | **5** | **34.68 Mb/s** | 0 |
| 661 | 824 | 0 | 299.7 Mb/s | 55,754 |
| 781 | 767 | 0 | 819.3 Mb/s | 171,959 |
| 901 | 592 | 0 | 1,328.3 Mb/s | 287,820 |
| 1,022 | 0 | 0 | 1,832.1 Mb/s | 403,871 |
| 1,202 | 65 | 0 | 2,576.8 Mb/s | 580,412 |
| 1,383 | — | 0 | — | 754,612 |
| 1,746 | — | 0 | 4,658.2 Mb/s | 1,103,580 |
| 2,404 | — | 0 | 6,984.4 Mb/s | 1,746,357 |

Three things are worth separating.

**The estimate ramps linearly, not exponentially.** The increments are 250.2, 251.7, 248.9, 249.9,
246.0 Mb/s per minute — flat to within 2 %, and still 212.0 and 212.2 Mb/s per minute at 29 and 40
minutes, so the slope neither saturates nor runs away. A ratio whose numerator grows linearly while its
denominator stays put produces exactly this, and it is the shape that rules out a merely noisy
estimator: something is accumulating and nothing is taking it out again.

**The buffer collapse is a consequence, not a second fault.** Release is the estimate trimmed by the
occupancy error, and the trim is clamped, so an estimate two orders of magnitude high releases
everything the moment it arrives whatever the clamp does. Occupancy therefore pins at the floor and
stays there.

**The underruns cost nothing here and would not elsewhere.** They are slots that emitted stuffing
because media had not yet arrived; the media still goes out, which is why programme is conserved and
`dropped` stays at zero. On a loopback path the arrival jitter they are absorbing is negligible. But
the cushion is the *only* thing between arrival jitter and the wire, and the lane no longer has one, so
the conformance result cannot be assumed to transfer to a path that jitters.

### Resources

**Superseded by the 24 h soak's resource table below**, which is the run long enough to fit a slope.
These readings are kept only because the two thread-count anomalies were first seen here. At
t=1,385 s, well inside the warm-up:

| Role | RSS start → now | threads | fds |
|---|---|---:|---:|
| Relay | 24.5 → 104.4 MB | 3 | 11 |
| `moq import ts` | 37.7 → 102.2 MB | 21 → 69 | 13 |
| `moq export ts` | 29.2 → 100.9 MB | 9 → 11 | 13 |
| `mpegts-pacer` | 9.1 → 10.9 MB | 10 → 74 | 9 |

The relay's early climb is the `quinn-proto` slot fill T9 characterised and T8b C6 measured to a
~200 MB per-channel asymptote; nothing here contradicts it and the run is far too short to add to it.
The **publisher thread count climbing 21 → 69** reproduces T9 soak #2's unresolved 22 → 86 over 26 h.
The **groomer's own thread count climbing 10 → 74 on a 2-vCPU host** is new and unexplained, and is now
an open item in its own right — it is a tokio worker pool that should not be growing.

## What this does and does not establish

- **Establishes:** the complete media-aware lane, as built, did not hold its operating state for as
  long as an hour on an unimpaired path. Reproduced four times on the 2-vCPU primary at the same
  trigger, and deterministically offline from a capture.
- **Establishes:** the trigger is a **source PCR discontinuity the exporter does not act on** — an
  ordinary event on a permanent feed, produced by a splice, a source failover or an encoder restart.
  It is upstream's and it is silent. [T23](test-23-pcr-discontinuity-classes.md) bounds it: the
  exposure is a **rewind**, whose cost is its own duration in programme, and *not* the 33-bit PCR
  rollover, which is carried correctly.
- **Establishes:** a defect of this class is **undetectable from the wire**. Programme conserved,
  continuity clean, PCR repetition clean, exact CBR — every check an operator has, passing, over a
  stage with no jitter absorption left and a source with no timebase at all. That is a finding about
  monitoring rather than about this bug; [T22](test-22-silent-media-plane-failure.md) measures the same
  asymmetry deliberately, and together they are why the groomer's own counters are load-bearing.
- **Establishes:** a groomer must not take its input's timebase on trust. Ours did, and that is the
  half of the failure that is ours. It is fixed and regression-tested.
- **Does not establish:** that media-aware carriage is unsound. Both faults are implementation faults
  in identified components, one upstream and one ours, and neither is a property of demuxing MPEG-TS
  into tracks.
- **Establishes, from the 24 h soak:** the lane holds its operating state for a day on a continuous
  timeline — zero continuity errors, zero underruns, a 27 ms worst programme gap and a bounded buffer
  over 632 million packets — so [T19](test-19-pcr-grid-verification.md)'s conformance result now
  extends from minutes to a day rather than being scoped to minutes.
- **Establishes, from the 24 h soak:** the groomer's resident memory and the relay's are both
  provisionable — flat and logarithmic respectively — and **`moq import ts`'s is not**, growing
  linearly at +2.83 MB/h with the slope intact across four quarters. Permanence is blocked by one
  upstream role, not by the architecture.
- **Does not establish:** that the publisher's growth is `moq import ts`'s rather than its wrapper's.
  The soak summed a process signature; the per-PID run is what settles it.
- **Does not establish:** anything about a *real* encoder's timeline. The continuous source is a
  synthetic clock over a repeating clip, which is honest about pacing and PCR and says nothing about
  encoder restarts, GOP structure changes or drifting source clocks.

## Mechanism

Three instruments settled it, and each ruled out a class the previous one could not.

**1. The two accumulators, reported separately.** The rate is `decayed_packets / decayed_secs`, and a
ratio that has gone wrong says nothing about which half did. Emitting them separately answered it in
one reading: across the departure the **denominator does not move** — `rate_dsecs` sits at 2.15 s
before, during and after — while the **numerator ramps linearly**, 13,702 → 51,101 → 616,677, gaining
+6,280 packets per second. That is the packet arrival rate exactly, which says the numerator had
stopped decaying rather than started growing. It also predicts the observed slope: 6,280 packets/s
over a 2.15 s window is 4.40 Mb/s per second, or **264 Mb/s per minute**, against the ~250 measured.

**2. The interval tail.** The mean interval stayed normal at 188 packets throughout, and
`rate_max_packets_in_interval` froze at 1,832 — so no single monster interval was responsible. What
moved was `rate_sub_ms_intervals`: in the last window before the departure, **all 494 admitted
intervals were shorter than a millisecond of media time**. The window decays on media time, so an
interval that carries none removes nothing from the sum while still adding its packets. Once every
interval is that interval, `decayed_packets` is a plain running total.

**3. Capture and replay, on both sides of MoQ at once.** The estimator consults no clock, so a capture
of the pacer's input replays its whole trajectory deterministically — which turns a defect needing ten
minutes of live lane into a file and three seconds of CPU. It reproduces exactly. Capturing the
*publisher's* input in the same run then attributes it:

| | source (`tsp` output, before MoQ) | exported (after the round trip) |
|---|---|---|
| PCR interval grid | clean **25.0 ms**, ~650 PCRs per 100k packets | clustered; 345 of 398 sub-ms, gaps to 320 ms |
| media time per 100k packets, before | 15,850 ms | 15,880 ms |
| media time per 100k packets, after | **15,850 ms — unchanged** | **6.9 ms** |
| PCR discontinuities in the run | **1**, at packet 3,967,658: 26,225.6 s → 25,625.6 s | **0** |

The source loops the clip and signals it. The exporter never passes that discontinuity on: it latches
the last pre-wrap value, 26,226.2 s, and emits PCR incrementing by one 90 kHz tick per PCR packet
thereafter, permanently. Note the exporter's PCR was already unlike its input before the failure —
clustered byte-adjacent with 320 ms gaps against a clean 25 ms grid, and about 38 % of the source's
PCRs not carried at all.

**Why the earlier elimination was wrong.** The first pass ruled out the loop wrap by feeding the same
looped clip *straight into the groomer with MoQ removed*, and the estimate held. That control removes
the component that fails, so it could only ever return a null. The rule it yields is in
[method notes](method-notes.md) §1: a control that removes the suspect stage tests the stimulus, not
the system, and cannot exonerate anything downstream of what it removed.

## The correction, and what it is not

Two separate faults, and conflating them would misattribute both.

**Upstream — the exporter does not act on a signalled discontinuity.** Reported; see
[upstream contributions](upstream-contributions.md). Nothing in `mpegts-pacer` can fix a source whose
clock has stopped, and this is the defect that starts the failure. Stated at the class level by
[T23](test-23-pcr-discontinuity-classes.md): a **rewind** costs its own duration in programme, while
forward jumps and the 33-bit rollover are carried correctly. The claim this experiment could support —
"the exporter's PCR does not survive a source discontinuity" — was broader than its single stimulus
warranted.

**Ours — the estimator integrated an input it should have distrusted.** Two changes, both small and
both justified independently of the trigger:

1. **Coalesce intervals too short to be a sample.** A PCR interval below 10 ms carries too little media
   time to say anything about rate, and — because the window decays on media time — too little to decay
   anything out of it either. Packets now accumulate with their media time until the pending span is a
   usable sample, which keeps every packet paired with the time it actually arrived in (the property
   the ratio-of-sums exists to preserve) and guarantees every decay is driven by a real span. Ten
   milliseconds is well inside the 40 ms a conformant source must repeat PCR within, so a working
   source always clears it. On a clean 25 ms grid the change is a no-op, measured: identical figures
   to six significant digits.
2. **A recovered content rate above the carrier's is not a content rate.** The groomer emits this
   stream at the mux rate, stuffing included, so over a window of seconds the media inside it cannot
   arrive faster than the carrier holds. Over one interval it certainly can, which is what the buffer
   is for, so the ceiling is applied to the windowed estimate and not to a sample. When the sums say
   otherwise, the packets are real and the media time is not: the pacer holds its last credible rate
   and raises `rate_clock_stalled`.

Validated against the captured failure, replayed through the fixed estimator:

| packets | raw ratio | **release rate** | `clock_stalled` | true rate |
|---:|---:|---:|:--|---:|
| 3,500,000 | 6,549 pps | **6,549 pps** | false | 6,331 |
| 4,000,000 | 71,185 pps | **6,368 pps** | **true** | 6,722 |
| 4,500,000 | 309,267 pps | **6,368 pps** | **true** | 7,561 |
| 5,000,000 | 524,220 pps | **6,368 pps** | **true** | 8,401 |

The raw ratio still climbs, because the input still lies. What the pacer releases on no longer does.

**And live, on the same host, against the same trigger.** The lane re-run with the fixed groomer meets
the discontinuity at the same t=601 s and holds:

| | unfixed | **fixed** |
|---|---|---|
| recovered rate at t=601 | 35.7 Mb/s, ramping | **9,575,263 b/s, frozen** |
| recovered rate at t=691 | 431.4 Mb/s | **9,575,263 b/s** |
| buffer occupancy at t=691 | 601 packets | **5,684 packets** |
| underruns at t=691 | **84,977** | **0** |
| dropped | 0 | 0 |
| operator-visible alarm | none | **`clock_stalled=true` at t=601** |

The frozen 9.575 Mb/s is the last credible estimate and the true content rate is ~9.5 Mb/s, so the
groomer keeps releasing correctly through a source that has stopped telling it the time. `rate_pending`
climbs into the tens of thousands and stays there, which is the stalled clock made legible: packets
held back from an estimate they cannot inform.

The alarm is the part that matters most for the architecture. The exporter defect is still there and is
still invisible to every check on the wire — but it is no longer invisible to the operator, because the
one stage that must read the source's timebase now says when that timebase has stopped.

**The deterministic regression** feeds a healthy 25 ms grid, checks the estimate settles, then switches
to one 90 kHz tick per PCR packet at the same packet rate. Against the unfixed estimator it reads
1,520,675 pps for a true 6,400 — a 238× overshoot, the field failure in miniature — and it asserts the
stall is visible in the counters, because nothing on the wire is.

## The 24 h soak, on a continuous timeline

### The source, and why one had to be built

Every clip in this lab is five to ten minutes long and there is no live feed. The only way anyone had
stretched one was `tsp -I file --infinite`, which restarts the file and so restarts its clock, and
[T23](test-23-pcr-discontinuity-classes.md) has now priced that: a rewind costs its own duration in
programme. A soak on that source measures recovery from a manufactured rewind every 665 s. That is a
real property of the lane, it is already measured, and it is not permanence.

`lab/scripts/ts-continuous-source.py` replays the clip and advances the timeline across the join, so
the output is what a continuous encoder emits. **It was graded before it was trusted**, because a
source that only looks continuous would confound the run it is supposed to clean up. Two passes of
`CNNiEMEA2.ts`, 49,148 PCRs:

| | measured | required |
|---|---|---|
| backward PCR steps | **0** | 0 |
| `discontinuity_indicator`s | **0** | 0 |
| continuity errors (TSDuck) | **0** | 0, matching the unmodified clip |
| PCR interval across the join | 24.640 ms, 24.497 ms | indistinguishable from the 24.648 ms median |
| worst interval anywhere | 24.951 ms | below the 40 ms gate |
| span over two passes | 1,199.974 s | 2 × 599.999 s |

The join is a hard content cut at an IDR, which is an ordinary scene change and not a timing event.
What the source does **not** reproduce is stated in the script and bounds the result: TDT/TOT and
SCTE-35 payloads repeat each pass and nothing depending on them should be graded here, and the
bitrate profile repeats with the content, so a slow oscillation at the 600 s pass period is the
source rather than the lane.

**The 33-bit rollover is not avoided, deliberately.** The clip's PCR origin is 25,625.6 s, so a
continuous run crosses the modulus about **19.4 h in**, unsignalled, exactly as a real feed does every
26.51 h. T23 established the lane carries that correctly in a placed 105 s arm; a run that passes
through it tests the same finding live, at length, and without the placement.

### Configuration

`SOURCE_MODE=continuous`, 24 h target, EC2 secondary (8 vCPU, idle, nothing else timing-sensitive on
the host). Merged upstream `main` — `moq` 0.10.0 / `moq-relay` 0.14.15, built on the host at
`222cc72`, containing [#3351](https://github.com/moq-dev/moq/pull/3351) — with `mpegts-pacer` built
from `5ab84cd`. 11,000,000 b/s, cushion 1,000 ms, cap 2,500 ms, `--latency-max 500ms`, sampled every
60 s. The `loop` mode is retained in the rig so the two sources can be compared deliberately rather
than by accident.

### The wire, over 24 hours

24.01 h (86,436 s), 1,437 samples at 60 s, graded continuously in flight.

| Metric | Result | F2 criterion |
|---|---|---|
| Duration | **86,436 s = 24.01 h** | ≥ 24 h |
| Packets delivered / counted | **632,199,204 / 632,199,204** | conserved |
| Continuity errors | **0**, in every one of 1,437 samples | 0 |
| PCRs verified | **5,947,298** | — |
| Absolute PCR failures at ±500 ns | **0** | no regression on the 1 h baseline |
| PCR intervals > 40 ms | **0** | 0 |
| Worst PCR interval | **30.08 ms** | < 40 ms |
| Mux rate | **11,000,000 b/s** exact | exact |
| Dropped / late-dropped | **0 / 0** | 0 |
| Underruns / stalls / muted / resyncs | **0 / 0 / 0 / 0** | 0 |
| Respawns | **0** — no role restarted once | 0 |
| Worst programme gap, whole run | **27 ms** | — |

Two of those deserve separating out from the list, because they are the readings the experiment was
built to get and neither was available before it.

**Zero underruns over 632 million packets.** The first run accumulated them at ~970 per second within
ten minutes. The distinction matters more than the count: an underrun is a slot that emitted stuffing
because media had not arrived, so it is the groomer reporting that its cushion was empty at that
instant. None in 24 h means the cushion was *never* empty — the lane kept a full jitter budget in hand
for a day, which is the property [T19](test-19-pcr-grid-verification.md)'s 300 s conformance result
could not speak to.

**A worst programme gap of 27 ms across the entire day.** This is the same figure the T23 control arm
returns over 105 s, so a day of uptime widened the worst hole in the programme by nothing at all. It
covers 144 source pass joins and the 33-bit rollover.

### The 33-bit rollover, crossed in flight

The clip's PCR origin puts the modulus at ~19.4 h, and the run went through it unsignalled, as a real
feed does every 26.51 h. Across the crossing the per-minute monitor reads `gap_ms=0 cc=0 gt40=0` with
the mux rate exact and the worst interval unchanged at 30.08 ms. T23 established this in a placed
105 s arm; it now holds live, at length, and without the placement.

### The release loop, and P0-3b

[P0-3b](planned-experiments.md) was opened because on a nine-minute arm the buffer drifted 9,008 →
18,105 packets monotonically against a 6,300 set point, and a servo with ±5 % authority cannot correct
a standing error larger than that — so the concern was a walk to a rail. **It did not happen.**

| | at 9 min (the P0-3b reading) | over 24 h |
|---|---|---|
| buffer occupancy | 9,008 → 18,105, monotone | oscillates; **6,469 at the end** |
| buffer high water | rising | **9,903, set early and never beaten** |
| cushion held | — | **1,000 ms**, lead 507 ms |
| media-rate estimate | healthy | **9,180,341 b/s** against a true ~9.5 Mb/s |
| `rate_dsecs` (the denominator) | 2.15 s | **2.012526 s**, the decayed window's steady state |
| `pcr_rebases` | — | **0** |
| `clock_stalled` | false | **false** throughout |
| underruns | 0 | **0** |

The high-water mark is the decisive number. It was set in the opening minutes and not approached again
in the following twenty-three hours, so the occupancy series is a bounded oscillation about the set
point and not a walk. The ±7 % estimator oscillation noted at nine minutes is real and it is
*self-limiting*: it tracks the clip's own bitrate profile, which repeats every 600 s with the content,
so it is the source's shape and not an accumulating error. **P0-3b is closed by this run.**

The groomer's thread count also settles: **13 → 15 over 24 h** on the 8-vCPU secondary, against the
10 → 74 seen on the 2-vCPU primary in the first run. The pool grows by two and stops. The 2-vCPU
reading is not explained by this and is not reproduced by it either; it stays open as a small-host
question rather than a groomer defect.

### Resources — the one failure

Sampled every 60 s. Slopes are fitted on `t > 2 h` to exclude the warm-up, and quoted per quarter of
the remainder, because a slope that *holds* is the thing that distinguishes a leak from a cache filling.

| Role | RSS start → end | growth | Q1 | Q2 | Q3 | Q4 | shape | 1 yr |
|---|---|---:|---:|---:|---:|---:|---|---:|
| `mpegts-pacer` | 8.7 → 9.1 MB | **+0.5 MB** | 0.00 | 0.00 | 0.00 | −0.00 | **flat** | flat |
| `moq export ts` | 32.5 → 151.4 MB | +118.9 MB | 1.43 | 0.63 | 0.15 | −0.19 | **converged, turned over** | bounded |
| `moq-relay` | 28.0 → 270.6 MB | +242.6 MB | 9.85 | 4.56 | 2.42 | 1.75 | **logarithmic** | ~519 MB |
| **`moq import ts`** | 36.4 → 173.7 MB | +137.2 MB | **2.36** | **2.87** | **2.81** | **2.57** | **linear** | **~24 GB** |

Quarterly slopes are MB/h. Thread counts: relay **9, flat**; export 11 → 13; pacer 13 → 15; import
12 → 16. File descriptors **flat at 11/13/13/9** for all four roles — nothing leaks a handle. Host load
averaged 0.79 on 8 vCPU and available memory moved 14,864 → 14,337 MB.

**Three of the four roles pass, and one of those closes an older question.** The groomer is flat, which
is the reading we most needed since the groomer is ours. The relay fits a logarithm at R²=0.9895
against R²=0.9097 for a line, and its slope halves every quarter — so [T8b](test-8b-congestion-control.md)
C6's asymptotic reading, taken at 14 h when the slope was still +1.82 MB/h and therefore arguable, is
**confirmed** at 24 h. Extrapolated on the log fit the relay reaches ~519 MB in a year, which is a
number an operator can provision for.

**`moq import ts` does not pass.** It fits a line at R²=0.9898, against R²=0.8960 for a logarithm and
R²=0.9655 for a square root, and the slope is 2.36, 2.87, 2.81, 2.57 MB/h across the four quarters —
essentially unchanged from first to last. A cache that is filling loses its slope; this does not. Nor
does it give memory back: the largest drawdown from a running peak in the whole run is 9.2 MB against
137 MB of growth. At +2.83 MB/h the publisher reaches ~24 GB in a year and would exhaust this 15.3 GB
host in about **seven and a half months** of continuous operation.

F2's criterion was fixed before the run — *any series still rising at a rate that would exhaust the
host inside a year is a fail* — and this trips it. **F2 therefore passes on the media plane and fails
on resources, in the publisher only.**

The attribution needs one qualification, which is why a follow-up run is recorded below rather than an
upstream report being filed straight off this data. The soak sampled RSS by `pgrep -f` on a
*signature*, and the publisher's signature matches its wrapper shell as well as `moq import ts`,
because the wrapper's argv contains the whole pipeline text. A shell does not grow 137 MB, so the
growth is not the wrapper's — but that is an argument rather than a measurement, and a defect reported
upstream should rest on the latter.

## Open

**The publisher's memory slope, per process.** `lab/scripts/t21-role-memory.sh` re-runs the same lane
for 6 h sampling each PID separately and labelled, which both isolates `moq import ts` from its wrapper
and gives the relay's logarithm a second, independent read. Nothing upstream is reported until it
lands. No issue upstream describes publisher RSS growth over long runs, so this is new if it holds.

**The groomer's thread count on a 2-vCPU host.** 10 → 74 in the first run, not reproduced on 8 vCPU
(13 → 15). A small-host question, unexplained.

**What 24 h does not reach.** The rollover recurs every 26.51 h and this run crossed it once, so a
second crossing is untested; and the campaign has no true live source, so the joins are content cuts
on a continuous synthetic clock rather than encoder behaviour. Both are stated in
[F2](planned-experiments.md#f2-permanence-soak) as the bounds of the claim.

## Corrections

**A control loop was accepted into the lane on five minutes of evidence.** The closed-loop release in
`mpegts-pacer` was introduced to fix a genuine defect — open-loop release integrates rate-estimate
error without bound — and it was validated on a 300 s live arm that showed stable latency and no
underruns. That validation was real and it was not sufficient: the replacement's own failure mode takes
about nine minutes to appear, so the test that qualified it could not have seen it.

The method rule is not "test for longer", which is unbounded. It is that **a stage which integrates
should be graded over a window longer than its integration time**, and the release loop's window is set
by how long the estimator's accumulators take to depart, which nobody had asked. Where a change
replaces an open loop with a closed one, the qualifying run has to outlast the loop's own time
constants or it has qualified only the transient.

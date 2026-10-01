# T21 — the permanence soak of the complete media-aware lane

> **State: complete. The 24 h soak on a continuous timeline passes on the media plane and fails F2 on
> resources, in one role, on `d518b61b`; the 24 h resource re-soak on upstream `main` at `9d2a4f6e`
> passes F2 in every role.** On `d518b61b`: 24.01 h, 632,199,204 packets, 5,947,298 PCRs: **zero** continuity errors,
> zero PCR intervals over 40 ms, zero absolute PCR failures at ±500 ns, zero drops, **zero underruns**,
> zero respawns, and a worst programme gap of **27 ms across the whole day**. The 33-bit rollover was
> crossed in flight at 19.4 h and cost nothing. The groomer's own resident memory is **flat**, and the
> buffer walk that [P0-3b](planned-experiments.md) was opened for **did not occur**.
>
> **Those are TR 101 290 P1/P2 figures, and this lane's wire is not T-STD-conformant.** Nothing was
> stored, so the day was not graded against the buffer model. The same lane and groomer re-captured
> for 300 s overflow the video, audio and PSI transport buffers throughout, with audio decoder buffers
> illegal at every PCR offset ([T44](test-44-tstd-grading.md)).
>
> The one failure on `d518b61b` is upstream and it is in the publisher: **`moq import ts` resident
> memory grows linearly at +2.83 MB/h** and holds that slope across all four quarters of the run,
> which on this host is exhaustion in about seven and a half months. F2's criterion was fixed in
> advance and this trips it. The relay, by contrast, is **logarithmic and bounded**, which settles a
> question T8b left open. Recorded in [§ The 24 h soak](#the-24-h-soak-on-a-continuous-timeline).
>
> **The leak is fixed on upstream `main`.** Re-soaked for 24.0 h on `9d2a4f6e` with the same source,
> clip and groomer, the importer grows **+0.23 MB/h** over the settled window, with quarterly slopes of
> +0.61, +0.41, +0.60 and −0.15 MB/h against the original 2.36–2.87. That is about 2 GB a year on a
> 15.3 GB host, below F2's exhaustion rate, and the last quarter is falling. Relay and groomer are flat.
> The exporter is flat apart from one +11.8 MB step at 11.0 h, the second such step in two long runs
> ([§ The #3493 re-soak](#the-3493-re-soak)). This re-soak graded resources, continuity and the
> groomer's counters, not PCR accuracy. Both 24 h runs used a generator that left the clip's AC-3 and
> teletext timestamps stepping back 600 s at every join, which both importers re-anchored. It is a
> `main` result, not one for the build under test
> `ffa5b81b`, which cannot run a continuous source ([#3798](https://github.com/moq-dev/moq/issues/3798)).
>
> **The first run is superseded.** Its source was `tsp --infinite`, which restarts the clip and
> therefore its clock. [T23](test-23-pcr-discontinuity-classes.md) has since measured what that costs —
> a rewind of N seconds costs N seconds of programme — so that run was measuring recovery from a rewind
> it manufactured, roughly every 665 s, and could not have measured permanence whatever it found. **Its
> findings stand as findings and are kept below**; what does not stand is the reading of them as a
> permanence result.

> **The first run (superseded for permanence; kept as discontinuity-mechanism record).** Stimulus:
> `tsp --infinite` on a looped clip — a rewind-recovery test, not a permanence test; see
> [Corrections](#corrections). The wire stayed conformant throughout (**0** continuity errors, **0**
> PCR intervals above 40 ms, exact **11,000,000 b/s**, programme conserved). Behind it the groomer's
> recovered media rate left the truth at about **nine minutes** and ramped **linearly without bound**
> to **6.98 Gb/s**; the de-jitter buffer collapsed from **10,587 packets (~1.4 s) to 0** with
> underruns at **~970/s**. Nothing downstream could see it. **Trigger (upstream):** the exporter did
> not act on the signalled discontinuity — PCR degenerated to one 90 kHz tick per packet. **Amplifier
> (ours):** the estimator divided real packets by a media time that had stopped. Both halves are
> addressed — estimator fixed and regression-tested below; exporter behaviour reported upstream. The
> fixed/unfixed comparison at [§ The correction](#the-correction-and-what-it-is-not) holds the rate at
> **9,575,263 b/s** with **0** underruns where the unfixed run ramped to 35.7 Mb/s and beyond.

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

**Primary — the 24 h permanence soak** ([§ The 24 h soak](#the-24-h-soak-on-a-continuous-timeline)):

- **Host:** EC2 secondary, 8 vCPU, idle, nothing else timing-sensitive on the host.
- **Build under test:** merged upstream `main` — `moq` 0.10.0 / `moq-relay` 0.14.15, built on the host at
  `222cc72`, containing [#3351](https://github.com/moq-dev/moq/pull/3351); `mpegts-pacer` built from
  `5ab84cd`.
- **Source:** `SOURCE_MODE=continuous` — `lab/scripts/ts-continuous-source.py` replays `~/CNNiEMEA2.ts`
  with the timeline advancing across the join (graded before use; see [§ The source](#the-source-and-why-one-had-to-be-built)).
- **Chain:** continuous source → `moq import ts` → relay → `moq export ts --latency-max 500ms` →
  `mpegts-pacer - 11000000 --latency-ms 1000 --max-latency-ms 2500 --stall-ms 1000 --on-stall mute` →
  `tsp -P continuity -P pcrverify --absolute --jitter-max 500 --bitrate 11000000 -P count` →
  `t21-pcr-monitor.py`.
- **Target:** 24 h; 11,000,000 b/s, cushion 1,000 ms, cap 2,500 ms; sampled every 60 s.
- **Rig:** `lab/scripts/t21-lane-soak.sh`. The `loop` mode is retained so the two sources can be compared
  deliberately rather than by accident.

**Variant — first run (discontinuity-mechanism record only; superseded for permanence):**

- **Host:** EC2 primary, `c6in.large`, 2 vCPU / 3.8 GB, `eu-west-1a`. Loopback, no shaping, no netns.
- **Build under test:** `moq 0.9.11-eab96019` / `moq-relay 0.14.11-eab96019` (`main` @ `eab960192`,
  carries [#3351](https://github.com/moq-dev/moq/pull/3351)); `mpegts-pacer` at `41e6181`.
- **Source:** `~/CNNiEMEA2.ts`, `md5 364ce82c…`, looped by `tsp -I file --infinite -P regulate
  --pcr-synchronous`. The loop wraps about every 665 s.
- **Chain and rig:** as above, with `tsp --infinite` in place of the continuous source.

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

### 24 h permanence soak — current verdict

Full tables and resource breakdown: [§ The 24 h soak](#the-24-h-soak-on-a-continuous-timeline). Summary:

| | Media plane (F2) | Resources (F2) |
|---|---|---|
| Verdict, `d518b61b` | **pass** — 24.01 h, **632,199,204** packets, **0** continuity errors, **0** underruns, worst programme gap **27 ms**, 33-bit rollover crossed at 19.4 h | **fail** — **`moq import ts` +2.83 MB/h linear**; relay logarithmic and bounded; groomer flat |
| Verdict, re-soak on `main` `9d2a4f6e` | not fully graded — 24.0 h, 632 M packets, **0** continuity errors, **0** underruns, stalls or drops; PCR accuracy and programme gap not measured by this rig | **pass** — `moq import ts` **+0.23 MB/h**, last quarter −0.15; relay and groomer flat; exporter flat but for one +11.8 MB step |
| Detail | [§ The wire, over 24 hours](#the-wire-over-24-hours), [§ The release loop](#the-release-loop-and-p0-3b) | [§ Resources — the one failure](#resources--the-one-failure), [§ The #3493 re-soak](#the-3493-re-soak) |

### First run — discontinuity-mechanism record (superseded for permanence)

These readings are from the **`tsp --infinite` variant** above. They characterise what happens when the
exporter does not act on a source PCR discontinuity; they do **not** state the permanence verdict,
which is the 24 h row above.

#### The wire (first run)

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

#### The groomer's release loop (first run)

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

#### Resources (first run)

**Superseded by the 24 h soak's resource table** — the run long enough to fit a slope. These readings
are kept only because the two thread-count anomalies were first seen here. At t=1,385 s, well inside
the warm-up:

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

- **Establishes (24 h soak — current permanence verdict):** the complete media-aware lane **passes F2 on
  the media plane without qualification** — 24.01 h, zero continuity errors, zero underruns, a **27 ms**
  worst programme gap and a bounded buffer over **632 million** packets — so
  [T19](test-19-pcr-grid-verification.md)'s conformance result extends to a day on a continuous timeline.
- **Establishes (24 h soak):** the groomer's resident memory and the relay's are both provisionable —
  flat and logarithmic respectively — and **`moq import ts`'s is not**, growing linearly at **+2.83 MB/h**
  with the slope intact across four quarters. **F2 fails on resources in one role** (the publisher), not
  on the architecture.
- **Establishes (24 h re-soak on `main` `9d2a4f6e`):** the publisher's leak is fixed upstream. Every
  role is below F2's exhaustion rate, so on that build the lane passes F2 on resources as well. It does
  not establish the same for the build under test, which cannot run the source.
- **Establishes (first run — discontinuity mechanism, not permanence):** when the exporter does not act
  on a source PCR discontinuity, the groomer's rate estimator amplifies the fault — wire conformant,
  cushion gone, undetectable downstream. [T23](test-23-pcr-discontinuity-classes.md) bounds the class;
  [T22](test-22-silent-media-plane-failure.md) measures the monitoring asymmetry deliberately. The
  estimator fix is regression-tested in [§ The correction](#the-correction-and-what-it-is-not). The first
  run's reading that the lane "did not hold its operating state for as long as an hour" is **superseded**
  by the 24 h result; that run was a rewind-recovery test on `tsp --infinite`, not a permanence soak.
- **Does not establish:** that media-aware carriage is unsound. The faults found are implementation
  faults in identified components.
- **Does not establish:** that the publisher's growth is `moq import ts`'s rather than its wrapper's —
  the per-PID run discharges this.
- **Does not establish:** anything about a *real* encoder's timeline. The continuous source is a
  synthetic clock over a repeating clip.

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

The first run used `tsp --infinite`; that stimulus is wrong for a permanence soak — see
[Corrections](#corrections) and [method notes](method-notes.md) §1 (*A looped clip is not a long clip*).

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

The grade read PCR and continuity counters, not PES timestamps, and it missed a defect in the
generator. The generator rebased PTS and DTS only for stream IDs `0xC0`–`0xEF`, so the clip's AC-3
and teletext (private stream 1) stepped back one pass span, 600 s, at every join. PCR and every
other PID stayed continuous. `d518b61b` re-anchors each stream on its own and carried both. None of this soak's metrics reads those two PIDs' timestamps. It does, however, mean the source
was not "what a continuous encoder emits" on every PID. The script has since been corrected, and
[`ts-join-scan.py`](scripts/ts-join-scan.py) now checks each PID's timestamps across the joins
([method notes](method-notes.md#a-looped-source-is-continuous-only-if-every-pids-timestamps-are)).

The join is a hard content cut at an IDR, which is an ordinary scene change and not a timing event.
What the source does **not** reproduce is stated in the script and bounds the result: TDT/TOT and
SCTE-35 payloads repeat each pass and nothing depending on them should be graded here, and the
bitrate profile repeats with the content, so a slow oscillation at the 600 s pass period is the
source rather than the lane.

**The 33-bit rollover is not avoided, deliberately.** The clip's PCR origin is 25,625.6 s, so a
continuous run crosses the modulus about **19.4 h in**, unsignalled, exactly as a real feed does every
26.51 h. T23 established the lane carries that correctly in a placed 105 s arm; a run that passes
through it tests the same finding live, at length, and without the placement.

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
**confirmed in shape** at 24 h — but not in constant, and the difference is what an operator sizes a
host with. C6 put the asymptote at baseline + 200.5 MB; this run passes that, reaching **baseline +
242.6 MB at 24 h**, with the log fit extrapolating to **~519 MB at a year**. So the budget is roughly
**2.5× the slot arithmetic rather than C6's 2.03×**. Both are single runs on one topology, and ~519 MB
is an extrapolation from a fit rather than an observed plateau, which is the limit on the figure.

**`moq import ts` does not pass.** It fits a line at R²=0.9898, against R²=0.8960 for a logarithm and
R²=0.9655 for a square root, and the slope is 2.36, 2.87, 2.81, 2.57 MB/h across the four quarters —
essentially unchanged from first to last. A cache that is filling loses its slope; this does not. Nor
does it give memory back: the largest drawdown from a running peak in the whole run is 9.2 MB against
137 MB of growth. At +2.83 MB/h the publisher reaches ~24 GB in a year and would exhaust this 15.3 GB
host in about **seven and a half months** of continuous operation.

F2's criterion was fixed before the run — *any series still rising at a rate that would exhaust the
host inside a year is a fail* — and this trips it. **F2 therefore passes on the media plane and fails
on resources, in the publisher only.**

The attribution rested on one qualification, now discharged. The soak sampled RSS by `pgrep -f` on a
*signature*, and the publisher's signature matches its wrapper shell as well as `moq import ts`,
because the wrapper's argv contains the whole pipeline text — an argument rather than a measurement,
and a defect reported upstream should rest on the latter.

### The #3493 re-soak

**`3493-check-2h` — invalid.** Same lane as the 6 h confirmation but on `moq`/`moq-relay`
`0.11.2-5d0991b9` / `0.14.18-5d0991b9`, `SOURCE_MODE=continuous`, 2 h target. Import exited at
~600 s (first content join) with *frame timestamp is below the live edge* — [#3798](https://github.com/moq-dev/moq/issues/3798), not a #3493 regression. `roles.csv` holds 240 rows; import RSS reads 0 after exit; media counters are not a slope confirmation.

**`3493-loop-2h` — invalid (same blocker).** `SOURCE_MODE=loop` (`tsp --infinite`) on the same build.
Import exited at the first loop wrap (~631 s) with the same [#3798](https://github.com/moq-dev/moq/issues/3798)
error. Import RSS grew from ~38 MB to ~112 MB before exit (571 s of samples); a 2 h slope confirmation
is **blocked until #3798 is fixed** — neither continuous nor loop source modes survive.

**Still blocked on `ffa5b81b`, and the closure of #3798 does not change that.** The issue was closed
as completed by [#3987](https://github.com/moq-dev/moq/pull/3987), which added a plan and no code;
re-measured on the current build, the importer still exits *frame timestamp is below the live edge*
at the first join. [T41](test-41-import-reanchor-coverage.md) additionally shows why no source mode
escapes it: non-legacy streams abort on the first backward timestamp and legacy audio on the second,
so a clip carrying video fails at wrap 1 whatever its length. **Upstream `main` at `9d2a4f6e` no
longer exits:** [T40](test-40-continuous-join-through-srt.md) holds full rate through five content
joins, and [T41](test-41-import-reanchor-coverage.md)'s three stream kinds survive three wraps. The
re-soaks below therefore ran on that build.

**`p0h-24h` on `9d2a4f6e` — the fix for [#3493](https://github.com/moq-dev/moq/issues/3493) is
confirmed.** `moq` 0.12.8 / `moq-relay` 0.15.8, `SOURCE_MODE=continuous`, the same clip and
11 Mb/s pacer as the 6 h confirmation, all roles co-resident on the 8-vCPU, 15.3 GB secondary, 30 s
samples. It ran 86,423 s (24.0 h). It was graded as the 24 h soak was: `t21-role-fit.py
--settle 7200`, with slopes on `t > 2 h` quoted per quarter. A slope that holds across the quarters
is a leak, and one that decays is a cache filling.

| role | RSS at 2 h → end | settled range | MB/h | Q1 | Q2 | Q3 | Q4 | largest step | grader |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| `moq import ts` | 122.6 → 131.3 MB | 120.4–135.1 | **+0.23** | +0.61 | +0.41 | +0.60 | **−0.15** | +2.9 | ambiguous (r² 0.407 line / 0.419 log) |
| `moq-relay` | 126.1 → 132.9 MB | 117.4–139.1 | +0.12 | +0.58 | −0.13 | +0.29 | −0.14 | +2.2 at 22.5 h | step, slope not meaningful |
| `moq export ts` | 136.2 → 158.8 MB | 124.7–165.2 | +1.32 | +0.68 | +4.49 | +0.14 | −0.22 | **+11.8 at 11.0 h** | step, slope not meaningful |
| groomer / source / `tsp` | 5.7 → 5.6 MB | — | +0.00 | 0.00 | 0.00 | −0.00 | −0.00 | +0.0 | flat |

- **The importer's leak is gone.** Its slope is a twelfth of the +2.83 MB/h the `d518b61b` soak measured,
  no quarter exceeds +0.61 MB/h, and the last quarter is negative, where the original held
  2.36–2.87 MB/h in every quarter at R² 0.9898. The grader cannot separate a line from a logarithm at
  this amplitude (8.7 MB over 22 h, inside a 15 MB band), so the residual shape is unresolved. The
  resource verdict does not depend on it: +0.23 MB/h is about 2 GB a year on a 15.3 GB host, below
  F2's exhaustion rate, and the series is not rising at the end.
- **The relay is flat on this build.** It holds 117–139 MB throughout, with no quarterly trend. The
  `d518b61b` soak's relay rose logarithmically from 28 to 271 MB. That build runs on quinn
  and this one on noq, so this is a different relay rather than a second reading of the same one.
- **The exporter steps once and is flat on either side.** It swings about ±5 MB between samples
  throughout, and rises 143.8 → 158.7 MB within 1 min at 11.1 h. Its quarters outside that step are
  +0.68, +0.14 and −0.22 MB/h. See [§ Open](#open).
- **The media plane held as far as this rig reads it.** 632,086,920 packets reached the counter, with 0
  continuity errors in all 2,878 samples and all six roles alive to the end. The groomer counted 0
  underruns, stalls, drops, late drops or mutes. The longest silence in its input was 310 ms, against
  a 1,000 ms cushion. The rig does not grade PCR accuracy, PCR intervals or programme gaps, so none of
  the `d518b61b` soak's wire figures is re-established here. The clip's 33-bit rollover falls at about
  19.4 h, and no role logged anything there.
- **One importer warning per content join.** Every 600 s the importer logged `audio stream lost frame
  sync and resynced` on PID 121 (MPEG-1 audio), discarding 72 bytes, 144 times in all. That is the
  audio frame the content cut splits, discarded rather than carried. Nothing else was logged before
  the teardown second.
- **The source was the uncorrected generator, as in the `d518b61b` soak.** Its copy on the host advanced
  PTS and DTS only for stream IDs `0xC0`–`0xEF`, so the clip's AC-3 and teletext stepped back 600 s at
  every one of the 144 joins, while PCR and the other PIDs stayed continuous. `main`'s importer
  re-anchors each stream on its own and carried both without logging. So the comparison with the
  `d518b61b` soak is like-for-like, but the resource result is for a source that rewinds two PIDs every
  10 min. Upstream's `dev` branch ends the import at any such rewind, by design, so this run would not
  survive its first join there.

A 2 h run on the same build (`p0h-2h`, default 1,200 s settle) read the importer at +4.99 MB/h,
r² 0.643 line against 0.626 log, and could not decide. The 24 h run shows why. Its importer rises
117.4 → 124.0 MB between 20 min and 1.5 h and then levels off, so a window that starts at 20 min
measures the warm-up. The rule this yields is in [`method-notes.md`](method-notes.md), under
*Distinguish a leak from a cache*.

**Per-PID confirmation, 6 h on the merged build** (`moq` 0.10.0 / `moq-relay` 0.14.15,
`lab/scripts/t21-role-memory.sh`, graded by `lab/scripts/t21-role-fit.py`), 157 M packets at 0
continuity errors:

| role | RSS start → end | MB/h | tail MB/h | largest ½ h step | shape |
|---|---|---:|---:|---:|---|
| `moq import ts` | 104.0 → 121.7 MB | **+2.91** | +3.55 | +3.0 | **linear — leak** |
| `moq-relay` | 116.4 → 131.1 MB | +2.23 | +2.72 | +2.3 | no discrimination at 6 h |
| `moq export ts` | 117.6 → 138.8 MB | +2.73 | +7.50 | **+14.5** | **step at 5.0 h, not a slope** |
| groomer / source / `tsp` | — | +0.00 | +0.00 | +0.0 | flat to two decimals |

**The publisher result holds and the figure barely moves**: +2.91 MB/h per process against +2.83 MB/h
from the signature, with the largest half-hour increment only 17 % of total growth, so it is a ramp
rather than a jump. That is what [#3493](https://github.com/moq-dev/moq/issues/3493) reports.

**Two things the shorter run says that the `d518b61b` soak does not.** The
exporter here is *not* the smooth convergence the `d518b61b` soak's table shows: it sat between 119 and 122 MB from
0.5 h to 4.5 h and then stepped +14.5 MB inside one half-hour. And 6 h is too short to read the relay's
shape at all — its tail slope slightly *exceeds* its overall slope and the two fits do not separate
(r² 0.538 linear against 0.492 log), where 24 h separated them cleanly. Neither disturbs the publisher
conclusion. The 24 h per-PID re-soak on `main` reads the exporter's step again, and reads its relay
as flat.

## Open

**Whether the relay converges on the build under test.** On `d518b61b` the relay is logarithmic at
R²=0.9895 over 24 h, sampled by signature. On `main` `9d2a4f6e` it is flat at 117–139 MB over 24 h,
sampled per PID. Those are different relay builds, and neither is `ffa5b81b`, so the relay's 24 h
shape on the build under test is unmeasured. It can be measured only once that build, or its
successor, runs a continuous source for 24 h.

**What the exporter's step is.** It has now appeared in two of the three valid per-PID runs: +14.5 MB at
5.0 h in the 6 h run on the merged build, and +11.8 MB at 11.0 h in the 24 h re-soak on `9d2a4f6e`,
flat on either side both times. It did not appear in the 2 h run. At most one step per 24 h, and not
at a fixed period, it is not a resource failure under F2. But it is unexplained, and a step that
repeats without releasing memory would become one over a week. Reading `/proc/<pid>/smaps_rollup` on
the exporter at 1 min cadence through a 24 h run would show whether the step is heap or mapped
memory. The 7-day arm of [P0-g](planned-experiments.md#p0--could-change-a-viability-conclusion)
would show whether it accumulates.

**The groomer's thread count on a 2-vCPU host.** 10 → 74 in the first run, not reproduced on 8 vCPU
(13 → 15). A small-host question, unexplained.

**Whether the rate servo's ±5 % authority has enough margin.** `RATE_SERVO_GAIN` clamps the servo at
±5 %, so a standing rate-estimate error beyond that saturates it and occupancy runs either to the cap
or to zero regardless of the control law. Over this soak the estimator read **9,180,341 b/s against a
true ~9.5 Mb/s** — about 3.4 % low, inside the clamp but with under two points of headroom, and on
one host. What is not established is whether that margin holds on a slower box or on content with a
different peak-to-mean ratio. If it does not, the cushion is not a designed quantity but an accident
of host speed, and the control constant is the wrong one. Reading `buffer_packets` against
`latency_target_ms` on the existing diagnostic lane over hours, on both hosts, would settle it
without changing anything.

**What 24 h does not reach.** The rollover recurs every 26.51 h and this run crossed it once, so a
second crossing is untested; and the campaign has no true live source, so the joins are content cuts
on a continuous synthetic clock rather than encoder behaviour. Both are stated in
[P0-g](planned-experiments.md#p0--could-change-a-viability-conclusion) as the bounds of the claim.

## Corrections

**Believed:** `tsp -I file --infinite` is an acceptable way to stretch a clip into a multi-hour soak.
**True:** restarting the file restarts its clock; [T23](test-23-pcr-discontinuity-classes.md) priced a
rewind at its own duration in programme, so the first run injected a manufactured discontinuity every
~665 s and measured rewind recovery, not permanence. **Rule:** the property under test must survive how
the stimulus was extended — see [method notes](method-notes.md) §1.

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

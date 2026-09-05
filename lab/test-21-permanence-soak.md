# T21 — the permanence soak of the complete media-aware lane

> **State:** running, and it has already failed its own criterion. This is the first long run in the
> campaign to put the **groomer inside the measurement**: [T8b](test-8b-congestion-control.md) C6 soaked
> `moq export ts` with `tsp count` behind it and [T9](test-9-performance.md) soaked the relay, so the
> stage that makes this lane conformant had never been run for longer than a single 300 s cell.
>
> **The wire stays conformant and the groomer does not stay in its operating state.** Across the run so
> far: **0 continuity errors, 0 PCR intervals above 40 ms, worst interval 30.08 ms, mux rate exactly
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

| Metric | Result over the run so far |
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

Too early for a slope past the conventional one-hour warm-up. The readings so far, at t=1,385 s:

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
- **Establishes:** the trigger is a **source PCR discontinuity that the exporter does not survive** —
  an ordinary event on a permanent feed, where a splice, an encoder restart or a clock rewrap will
  produce one. It is upstream's, it is silent, and until it is fixed any permanent deployment of this
  lane meets it the first time its source discontinues.
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
- **Does not establish:** that the lane now holds its state for hours. The fix is validated
  deterministically and on a short live arm; the re-soak has not been run.
- **Does not yet establish:** the resource question the soak was also for. That needs a full run that
  is not chasing a known defect.

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

**Upstream — the exporter's PCR does not survive a source discontinuity.** Reported; see
[upstream contributions](upstream-contributions.md). Nothing in `mpegts-pacer` can fix a source whose
clock has stopped, and this is the defect that starts the failure.

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

## Open

**The re-soak.** The fix is validated deterministically and on a short live arm; it has not yet been
run for hours. That is the next run and it is what would let the conformance claim extend past minutes.

**Also open:** the groomer's thread count on a 2-vCPU host, and the resource slopes, which need a full
run that is not chasing a known defect.

**A second release-loop question, not yet answered.** On the 8-vCPU secondary the estimate stayed
healthy for the whole run and the buffer still drifted — 9,008 packets to 18,105 over nine minutes,
monotonically, against a 6,300-packet set point. The servo's authority is `±RATE_SERVO_GAIN`, ±5 %, so
any standing rate error beyond 5 % saturates it and the buffer walks to a rail. That is a different
failure from this one, it is ours, and it is unaddressed.

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

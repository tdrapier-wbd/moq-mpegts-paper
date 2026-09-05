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
> **This is a defect in `mpegts-pacer`, ours, not in `moq-dev`.** The exporter's log is clean for the
> whole run: no evictions, no errors, no reconnects, eight subscribes at start-up and nothing after. The
> mechanism is not yet located (see *Open* below) and the fix is deliberately not guessed at.
>
> **The consequence for the paper is a scope, not a retraction.**
> [T19](test-19-pcr-grid-verification.md) measurement 11's conformance result stands for the window it
> was measured over. It was a 300 s window, the divergence begins at about 540 s, and so the claim that
> the media-aware lane produces a conformant CBR wire **is established for minutes and is not
> established for hours**.

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

- **Establishes:** the complete media-aware lane does not hold its operating state for as long as an
  hour on an unimpaired path. The failure is in the groomer's release loop, it is reproducible in the
  sense that it appeared once and persisted for the remaining two hours without recovering, and it is
  invisible to every conformance and content check applied to the output.
- **Establishes:** a groomer defect of this class is undetectable from the wire. That is a finding about
  monitoring, not only about this bug — see [T22](test-22-silent-media-plane-failure.md), which
  measures the same asymmetry deliberately.
- **Does not establish:** anything about MoQ or about media-aware carriage. The exporter behaved
  correctly and said nothing because there was nothing to say. This is our code.
- **Does not establish:** that the lane cannot be made to hold its state. The loop is ours to fix, and
  the ramp's linearity says the mechanism is a single unbounded accumulation rather than an
  instability in the control law.
- **Does not yet establish:** the resource question the soak was also for. That needs the run to finish.

## Open

**The mechanism is not located, and three candidates were eliminated rather than one confirmed.**

- *Not the source loop wrap.* Feeding the same clip, looped by the same `tsp --infinite -P regulate`,
  **directly into the groomer with MoQ removed from the path** holds the estimate at 9.48–9.50 Mb/s
  across several wraps over 150 s. The wrap alone does not do it.
- *Not an upstream event.* The exporter log is clean for the whole run.
- *Not simply degenerate PCR intervals.* The obvious candidate was that the estimator's window decays
  on *media* time, so a run of near-zero PCR intervals — which T19 measured the exporter emitting as
  byte-adjacent pairs — would add packets to the numerator while decaying almost nothing out. A
  regression test that alternates one-tick and 25 ms intervals over 4,000 intervals **does not**
  reproduce the ramp, so that pattern by itself is not sufficient either.

The next step is diagnostic rather than speculative: emit `decayed_packets` and `decayed_secs`
separately in the counter line, which distinguishes a numerator that grows from a denominator that
vanishes in a single reading. Shipping a fix before that would be guessing.

**Also open:** the groomer's thread count on a 2-vCPU host, and the resource slopes, which need the
full run.

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

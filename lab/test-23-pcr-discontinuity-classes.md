# T23 — which PCR discontinuity classes the media-aware lane survives

> **State: re-graded against the fix these measurements prompted, and the rewind defect is gone.**
> The results below were measured on `f8236680b`, which contained #3351 but not
> [#3375](https://github.com/moq-dev/moq/pull/3375). That PR opened citing this campaign, merged as
> `0e61e3520`, and closed [#2833](https://github.com/moq-dev/moq/issues/2833). Re-running all six arms
> unchanged against `d88c2ee99` — which contains it — is in
> [§ Against the fix](#against-the-fix-3375). **Every arm now matches the control, the rewinds
> included**, and the one residue is the forward arm's missing flag, which upstream has recorded as a
> separate open item on the strength of this campaign. Read everything before that section as the
> behaviour of builds earlier than `0e61e3520`.

## Objective

T21 found the exporter's timebase failing after a source PCR discontinuity, but its only
stimulus was `tsp --infinite` looping a clip: one event, of one class, arriving by accident,
at one magnitude, in one direction. That cannot say which discontinuities the lane survives,
and it cannot support an upstream report — a maintainer could fairly read the whole result
as an artefact of the looper.

This grades the timeline event as a controlled variable. Each arm places exactly one event,
of a known class, size and direction, at a known point, and the same quantity is read at all
three points of the lane: at the source, after the MoQ round trip, and after grooming.

The question the campaign exists to answer for primary distribution is narrower than "does a
discontinuity work". A permanent feed does not get to avoid these. **The 33-bit PCR base
wraps every 26.51 h unconditionally**, in every conformant stream that has ever existed, so
a lane that cannot cross that boundary cannot run permanently at all, whatever else it does.

## Environment

| | |
|---|---|
| Host | primary laptop, single host, loopback relay |
| MoQ | `~/bin-3351/` — `moq` 0.10.0-f8236680b, `moq-relay` 0.14.15-f8236680b (merged #3351) |
| Groomer | `mpegts-pacer` `5ab84cd` (carrying the T21 rate-estimator fix) |
| Source | 150 s synthetic clip, H.264 + MP2, 4,000,000 b/s mux, 20 ms PCR period |
| Lane | `tsp regulate --pcr-synchronous` → `import ts` → relay → `export ts --latency-max 3s` → `mpegts-pacer - 4000000` |
| Window | 105 s per arm; the event is placed at 45 s |

Scripts: `lab/scripts/t23-pcr-stimuli.py` (generator), `t23-discontinuity.sh` (lane),
`t23-grade.py` (three-point comparison).

## Method

### The stimuli shift PTS and DTS, not only PCR

The exporter does not copy the source's PCR — it reconstructs one, scheduling from media
timestamps. A stimulus that moved PCR alone would exercise a path the lane does not use and
would return a confident null. Shifting all three is also what a real source does: an encoder
that restarts restarts its whole timebase, not one field of it.

### Two classes of event, which must not be conflated

- A **signalled discontinuity** (ISO 13818-1 2.4.3.4) is the source declaring a new time
  base. `discontinuity_indicator` is set on the first affected packet and the receiver is
  required to re-acquire. Splices, encoder restarts and source failovers are all this.
- A **33-bit rollover** is *not* a discontinuity and must not be flagged as one. The base is
  modulo 2^33 at 90 kHz, so it returns to zero every 26.51 h of any stream, and a receiver
  is required to handle it as ordinary modulo arithmetic. Flagging it would itself be a bug.

Arm D is placed rather than waited for: the whole clip is rebased so the boundary falls 45 s
in, which makes the mandatory 26.51 h event a 105 s test.

### Not `--infinite`

The loop wrap is itself a discontinuity, so looping would put a second, uncontrolled event of
the class under test into every arm, including the control. Each clip is played once and the
window is sized to fit inside it.

### The instrument is the rate of PCR advance, not its value

T21's exporter emitted perfectly well-formed PCR values while its timebase was gone, so every
check that reads PCR as a value passed. Rate of advance is what distinguishes a clock from a
counter. It is measured per 100,000 packets rather than per second because a file capture has
no arrival times in it, and reported as a ratio against each capture's own pre-event baseline.

## Arms

| Arm | Event at 45 s | Signalled |
|---|---|---|
| A | backward 1 s | yes |
| B | backward 600 s (origin lifted to 700 s so the jump clears zero) | yes |
| C | forward 30 s | yes |
| D | 33-bit base rollover | **no** — correctly |
| E | encoder restart: timebase to 1.0 s, continuity counters reset | yes |
| F | control, timeline untouched | — |

Arm B is lifted clear of zero first. Subtracting 600 s from a clip starting at zero does not
produce a backward jump, it produces a value 600 s below the modulus — legal arithmetic, but
a rollover wearing a discontinuity's clothes, which would confound arm B with arm D instead
of isolating it. This was caught by verifying the fixtures before running any lane.

## Results

### The three-point timeline

`disc` counts `discontinuity_indicator`s on that wire; `roll` counts modulus crossings; the
ratio is the rate of PCR advance at the end of the run against that capture's own baseline.

| Arm | point | disc | roll | rate ratio | timeline event seen |
|---|---|---|---|---|---|
| A | source / export / paced | 1 / **0** / **0** | 0 / 0 / 0 | 1.000 / 1.006 / 1.000 | −0.989 s / — / — |
| B | source / export / paced | 1 / **0** / **0** | 0 / 0 / 0 | 1.000 / 0.979 / 1.000 | −599.989 s / — / — |
| C | source / export / paced | 1 / **0** / 1 | 0 / 0 / 0 | 1.000 / 1.002 / 1.000 | +30.011 s / **+29.050 s unsignalled** / +28.977 s |
| D | source / export / paced | 0 / 0 / 0 | **1 / 1 / 1** | 1.000 / 1.007 / 1.000 | rollover / rollover / rollover |
| E | source / export / paced | 2 / **0** / 1 | 0 / 0 / 0 | 1.000 / 1.018 / 1.000 | −44.690 s / — / +42.670 s unsignalled |
| F | source / export / paced | 0 / 0 / 0 | 0 / 0 / 0 | 1.000 / 1.002 / 1.000 | none |

**`discontinuity_indicator` is never propagated.** Four arms present it at the source and the
exported wire carries zero in all four.

### The media outcome, which is the one that counts

Graded on the paced wire. `gap` is the longest interval with no programme content.

| Arm | continuity errors | PCR > 40 ms | worst PCR | programme gap | groomer drops | verdict |
|---|---|---|---|---|---|---|
| A backward 1 s | 0 | 0 | 30.08 ms | 268 ms | 0 | recovers |
| B backward 600 s | 0 | 0 | 30.08 ms | **62,760 ms** | 0 | **fails** |
| C forward 30 s | 0 | 0 | 30.08 ms | 238 ms | 0 | recovers |
| D rollover | 0 | 0 | 30.08 ms | 52 ms | 0 | **clean** |
| E encoder restart | **103** | 0 | 30.08 ms | **44,049 ms** | **54,168** | **fails** |
| F control | 0 | 0 | 30.08 ms | 26 ms | 0 | clean |

Arm B's 62.8 s is not the size of the failure, only the size of the window: the exporter went
silent at the event and had not resumed when the run ended. On the law below it owed 600 s.

### The backward jump costs exactly its own size in programme

Sweeping the magnitude with everything else held:

| backward jump | 1.0 s | 2.0 s | 5.0 s | 10.0 s | 44.7 s | 600 s |
|---|---|---|---|---|---|---|
| programme gap | 268 ms | 1,487 ms | 4,514 ms | 9,446 ms | 44,049 ms | ≥62,760 ms |

The gap tracks the jump one-for-one, to within about half a second, across three orders of
magnitude. This is not a threshold, a budget or a timeout — it is a linear law, and it
identifies the mechanism without needing to read the source: **the exporter's scheduler is
monotonic in media time.** A frame stamped earlier than one already sent is not evidence of a
new time base, it is simply not due yet, so the exporter withholds output until the new
timeline overtakes the old and then releases the backlog in one burst.

That burst is what does the extra damage in arm E: 97,225 packets (18.3 MB) arriving at once
against a groomer cushion of 8,000 ms, which is where the 54,168 drops and 103 continuity
errors come from. A backward jump alone (`bk2`–`bk10`, arm B) drops nothing; it is the
*recovery* from one, when the jump is large enough to build a substantial backlog, that
overruns the groomer.

### The recovery burst is a groomer sizing choice; the programme hole is not

> **Superseded by [#3375](#against-the-fix-3375), which removes the burst.** Kept because the
> attribution it establishes is the reusable part, and because it was the live reading for every build
> before `0e61e3520`.

The encoder-restart arm lost two different things and they have different owners. Sweeping the
groomer's hard cap — the depth past which input is dropped oldest-first — with the same arm E
stimulus separates them:

| groomer hard cap | drops | continuity errors | programme gap | buffer high water |
|---|---|---|---|---|
| 8,000 ms (adaptive ceiling, the default) | 54,168 | 103 | 44,049 ms | 42,555 |
| 20,000 ms | 43,170 | 107 | 44,079 ms | 53,193 |
| 50,000 ms | **0** | **0** | 44,009 ms | 96,179 |
| 90,000 ms | **0** | **0** | 44,046 ms | 96,231 |

The threshold falls between 20 s and 50 s against a 44.69 s rewind, which is the prediction
recorded before the sweep: the withheld backlog is exactly the rewind, so a cap that can hold
the rewind absorbs it and a cap that cannot discards the difference. **The drops and the
continuity errors are ours and they are a configuration, not a defect.** The programme gap is
unmoved at ~44 s by any cap, because it is the exporter withholding rather than the groomer
discarding, and nothing downstream can return media that was never sent.

**The headroom is free when it is not needed.** Pinning the cushion at 1 s — the operating
point, as distinct from the cap — and varying only the cap:

| arm | cap | drops | continuity | buffer high water | steady lead | pcrverify |
|---|---|---|---|---|---|---|
| F control | 2,500 ms | 0 | 0 | 2,449 | 135 ms | 6,239 OK, 0 fail |
| F control | 50,000 ms | 0 | 0 | **2,447** | 148 ms | 6,245 OK, 0 fail |
| E restart | 50,000 ms | **0** | **0** | 98,035 | — | 5,024 OK, 0 fail |

A cap twenty times larger changes the steady-state occupancy by two packets. The buffer only
grows when there is a backlog to absorb, so the cap is headroom rather than latency, and the
cushion continues to set the operating point. Arm E at a pinned 1 s cushion and a 50 s cap
loses **nothing**: 0 drops, 0 continuity errors, and PCR still within ±500 ns.

The cost is memory, and it is the rewind that sizes it: absorbing 44.7 s at this rig's 4 Mb/s
took a high-water mark of 98,035 packets, **18.4 MB**. That scales with both the rewind to be
survived and the feed's rate, so an operator choosing this is choosing roughly
*rewind × bitrate* of buffer per feed — at 11 Mb/s and a 60 s rewind, about 82 MB each, which
is a real number at a few hundred feeds and is a provisioning decision rather than a default.
**No pacer change is made here.** The right cap is a property of the deployment's worst
expected rewind, the drops are already counted and visible when it is set too low, and a large
default would spend memory on every feed to insure against an event most of them never meet.

### The rollover is handled correctly, at every point

Arm D crosses 2^33 on the paced wire exactly once:

```
pkt  118245  base= 8589932560   95443.695120 s
pkt  118325  base=        676       0.007511 s   <-- boundary
pkt  118340  base=       1183       0.013151 s
step across the boundary, modulo 2^33: 30.080 ms
```

30.080 ms is the worst normal PCR interval elsewhere in the same stream. In modulo arithmetic
the crossing is not an event at all, which is exactly right. TSDuck agrees: **6,259 PCRs OK,
0 with jitter above ±500 ns absolute, 0 continuity errors**, against 6,217 / 0 / 0 for the
control. No `discontinuity_indicator` is set anywhere in the arm, correctly, and none is
needed.

### T23 does not reproduce T21's signature

T21 reported the exporter latching its PCR and thereafter advancing it by one 90 kHz tick per
PCR packet — a counter rather than a clock, permanently. **No arm here shows that**: across
arms B, C and E the count of intervals advancing by three ticks or fewer is 0 of 1,789, 0 of
4,270 and 0 of 2,533. What a deliberate discontinuity produces is a clean withhold-and-burst,
with the clock healthy either side of it.

Both are the exporter failing to act on a declared new time base, and they may well share a
root cause, but T23 cannot demonstrate that and does not claim it. See Corrections.

## Conclusions

1. **The 26.51 h PCR rollover does not threaten permanent operation.** It is carried
   correctly through ingest, the round trip and grooming, with no measurable disturbance at
   any of the three points. This was the single mandatory, unavoidable timeline event in the
   evaluation, and it is discharged.
2. **Forward discontinuities recover**; the lane loses 238 ms and re-acquires.
3. **Backward discontinuities cost their own duration in programme**, linearly, because the
   exporter treats a declared new time base as a timestamp that is merely not due yet. Below
   about a second this is absorbed. Above it, it is a programme outage of the same length.
4. **An encoder restart is the worst realistic case** and the one most likely in service: it
   is a backward jump *and* it triggers a backlog burst large enough to overrun the groomer,
   costing 44 s of programme, 54,168 dropped packets and the lane's only continuity errors.
   **The two halves have different owners.** The 44 s hole is the exporter withholding and no
   downstream stage can recover it. The 54,168 packets and the 103 continuity errors are the
   groomer's hard cap being smaller than the rewind: at a cap above the rewind the same arm
   loses nothing, and the headroom costs two packets of steady-state occupancy when unused.
   That is a provisioning decision (*rewind × bitrate* of buffer per feed), not a defect.
5. **`discontinuity_indicator` is neither consumed nor produced.** Not consumed: (3) and (4)
   are the consequence. Not produced: in arm C the exporter emits its own +29.05 s timebase
   change with the flag clear, which is a stream error for any downstream device, and it is
   only conformant on our wire because the groomer independently re-derives it.
6. **Wire conformance again fails to see a programme failure.** Arm B holds 0 continuity
   errors, 0 PCR intervals above 40 ms and exact CBR across a 62.8 s hole in the programme.
   This is the third independent instance of the T21/T22 lesson.

## Pass criteria, fixed before the runs

| criterion | result |
|---|---|
| Control unchanged from a normal run | met — F is byte-identical to the base clip and grades clean |
| Rollover crosses with no continuity error, no PCR interval above 40 ms, no programme gap beyond the control's | met — 52 ms against the control's 26 ms |
| Each arm's class assigned recovers / fails on the media outcome, not on session state | met |
| Any upstream report rests on behaviour demonstrably inconsistent with ISO 13818-1 for that stimulus | met for 2.4.3.4, both directions |

## Against the fix (#3375)

Same six stimulus files, same rig, same groomer binary, same 105 s window and same 45 s event
placement; the only variable is the MoQ build — `d88c2ee99`, which contains `0e61e3520`, against the
`f8236680b` above. Nothing was re-generated, so the comparison is of one build against another and
nothing else.

| arm | event | gap before | **gap after** | drops before | **after** | CC before | **after** | flag before | **after** |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| A | backward −1 s | 268 ms | **26 ms** | 0 | **0** | 0 | **0** | 0 | **1** |
| B | backward −600 s | 62,760 ms | **27 ms** | 0 | **0** | 0 | **0** | 0 | **1** |
| C | forward +30 s | 238 ms | **27 ms** | 0 | **0** | 0 | **0** | 0 | **0** |
| D | 33-bit rollover | 52 ms | **27 ms** | 0 | **0** | 0 | **0** | 0 | **0** |
| E | encoder restart | 44,049 ms | **37 ms** | 54,168 | **0** | 103 | **0** | 0 | **1** |
| F | control | 26 ms | **27 ms** | 0 | **0** | 0 | **0** | 0 | **0** |

**Every arm is now indistinguishable from the control**, and the two that failed no longer do: the
600 s rewind costs 27 ms of programme where it cost 62.8 s, and the encoder restart costs 37 ms and
loses nothing where it cost 44 s, 54,168 packets and the lane's only continuity errors. PCR accuracy
holds throughout — 6,175–6,246 PCRs per arm within ±500 ns, one marginal sample in arm A.

The exporter now **follows** the new timeline instead of waiting it out. Read at all three points,
arm B's source signals −599.989 s and the export signals −599.525 s with the rate ratio at 1.004; arm
E's export signals −43.850 s against the source's −44.690 s. Before the fix the export carried no
event at all and withheld until the old timeline was overtaken.

**The flag is emitted, and on exactly the right arms.** A, B and E — the three signalled events — each
carry one `discontinuity_indicator` on the exported wire, where every arm previously carried zero.
D carries none, which is the point: a 33-bit rollover is ordinary arithmetic and flagging it would be
the defect. F carries none.

**Two residues, one upstream and one ours.**

- **The forward jump propagates unflagged.** Arm C's export reproduces the source's timebase change as
  `unsignalled +29.050 s`: the media outcome is now the control's, but a downstream device is given a
  29 s jump with no announcement. Upstream has this recorded as `quest/m0/ts-forward-discontinuity.md`,
  built on this campaign and pointing its implementer at these stimuli, so it is a known open item
  rather than a new finding. **Still a stream error for any third-party receiver.**
- **A small cushion starves on a forward jump.** Arm C took 3,300 underruns against 4–6 in the others,
  at a 200 ms adaptive cushion — the smallest any arm chose. No programme was lost (0 drops, 27 ms
  gap): the carrier emitted stuffing where content was momentarily unavailable. It is a groomer sizing
  behaviour at a small cushion, not a content failure, and worth knowing before a cushion is pinned
  that low.

**The buffer requirement collapses, which supersedes the sizing result above.** With no backlog to
absorb, the groomer's adaptive cushion settles at 200–348 ms rather than 8,000 ms, and the buffer high
water falls from 98,035 packets to **1,102–1,417**. The *rewind × bitrate* provisioning rule derived
from the cap sweep — about 82 MB per feed for a 60 s rewind at 11 Mb/s — is therefore **discharged for
builds containing `0e61e3520`**. It was a correct reading of the build it was measured on, and that
build is superseded. What remains true is the shape of the argument: a stage downstream of an exporter
that withholds must be sized for what it withholds.

## Corrections

**Believed:** the exporter's response to a source PCR discontinuity is to latch the last PCR
and emit a counter (T21).
**True:** that is what T21 measured, but it is not what a deliberate signalled discontinuity
produces. Five arms across three classes and six magnitudes produce a withhold-and-burst with
a healthy clock either side, and none reproduces the counter.
**Rule:** an upstream report drawn from an incidental stimulus states the stimulus's
behaviour, not the class's. Characterise the class before filing, or the report describes a
symptom the maintainer cannot reproduce and the defect that is actually there goes unfixed.

**Believed (during this run):** subtracting 600 s from a clip that starts at zero produces a
600 s backward jump.
**True:** it produces a value 600 s below the modulus, which is a rollover, not a
discontinuity — arm B would have measured arm D.
**Rule:** verify a fixture asserts what it claims before spending a lane run on it. Reading
the generated stimuli back through the analyser cost two minutes and caught this.

## Open

- Whether T21's counter degeneration and T23's withhold-and-burst share a root cause. The
  T21 captures are no longer on disk, and both behaviours are now absent from the current build, so
  this is unlikely ever to be settled and no longer blocks anything.
- ~~Whether the arm E burst overruns the groomer at larger cushions.~~ **Answered**: a hard cap above
  the rewind absorbs it losslessly and the headroom is free when unused — then **superseded** by
  #3375, which removes the burst, so the requirement no longer arises.
- **The forward jump's missing `discontinuity_indicator`**, which #3375 does not address and upstream
  tracks as `quest/m0/ts-forward-discontinuity.md`. Our stimuli are the verification instrument it
  names, so re-running arm C is the cheap check when that lands.
- Whether the arm C cushion starvation (3,300 underruns at a 200 ms adaptive cushion, no content lost)
  matters at a pinned production cushion. Ours, small, and untested above 200 ms.

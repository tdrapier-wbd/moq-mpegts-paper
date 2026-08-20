# T16 — grooming a segmented-HTTP egress

## Objective

[T14](test-14-data-plane-comparison.md) measurement 2 established that a segmented-HTTP egress is ~240×
coarser than a MoQ egress by median burst size, and stopped there on purpose: the measurement point was
the *ungroomed* egress, because the question was burst granularity. That left the consequence unmeasured.
[evidence](../docs/evidence.md) §3.2 said so in as many words — "the equivalent grooming
pass on a segmented-HTTP egress is unmeasured, and would need a larger buffer" — and T14's observations
disposed of it in one sentence:

> `mpegts-pacer`'s `--stall-ms` / `--on-stall mute` machinery was built for a MoQ egress whose worst gap
> is 149 ms; it is the right mechanism, but the timeouts documented for leg A are an order of magnitude
> too tight for a segment-fetching leg. **That is a configuration finding, not a defect.**

This inserts a groomer into the identical chain arm B1 measured, changing nothing else:

```
tsp -O hls -> HTTP origin -> tsp -I hls -> [mpegts-pacer] -> instrument
```

and runs it four ways: once sizing its own buffer from the arrival pattern, and three times at points in
the parameter space T14 was proposing to adjust — including T14's proposal taken literally. So the run
answers two questions off one publisher: whether a segmented-HTTP egress can be groomed to the standard
[T13](test-13-downstream-grooming.md) reached on the MoQ lane, and whether reaching it is a matter of
setting the documented flags differently.

### Pass criteria (fixed before the runs)

1. **Timing.** The groomed egress meets the gates T13 held `mpegts-pacer` to on the MoQ lane: zero PCR
   violations at `pcrverify --absolute --jitter-max 13` (481 ns), zero PCR repetition intervals above
   40 ms, zero continuity errors.
2. **Cadence.** No silence beyond the ~15 ms scale T13's paced legs reached, and a 10 ms coefficient of
   variation of the same order as the MoQ lane's groomed 0.079 rather than arm B1's 12.5.
3. **Carriage.** Grooming costs nothing T14 measurement 4 credited segmented HTTP with: all PIDs, the
   DVB service layer, all three SCTE-35 PIDs with typing.
4. **Nothing deleted.** Zero dropped and zero muted packets. A groomer that meets the first three
   criteria by discarding programme has not groomed anything.
5. **No tuning.** Criteria 1–4 with the pacer told the output rate and nothing else. If it has to be
   told the segment duration or the buffer depth, T14's "configuration finding" stands and
   [architecture](../docs/architecture.md) §4.5 does not.

---

## Environment

| Component | Detail |
|---|---|
| Source | `CNNiEMEA2.ts` — CNN EMEA HD, 9,945,951 bps CBR, open-GOP, 3× SCTE-35, full DVB SI |
| Host | single macOS host, loopback path, all five arms in one session off one publisher |
| Publisher | TSDuck 3.44-4676 `tsp -O hls`, 2 s target, `--intra-close --align-first-segment --live 6 --live-extra-segments 3` |
| Origin | `python3 -m http.server`, as T14 measurement 2 |
| Receiver | TSDuck 3.44-4676 `tsp -I hls --live`, bounded by `-P until --seconds` so the groomer sees a clean end of stream and flushes |
| Groomer | `mpegts-pacer` 0.1.0 with adaptive sizing, `examples/ts_egress` — the same code has since become the crate's `mpegts-pacer` binary, and the rig builds whichever the checkout has |
| Output rate | 11,437,843 b/s — the source's PCR-derived content rate (9,945,951) plus the pacer's 15 % default headroom, pinned so every arm is graded against one byte clock |
| Instrument | [`t13-cadence.py`](scripts/t13-cadence.py): `pipe` mode for arm A (64 kB reads, as T14), `capture` mode for the groomed arms (loopback UDP, as T13's MoQ lane) |
| Grading | [`t13-grade.py`](scripts/t13-grade.py) over `compliance.py`, plus `tsp -P pcrverify`, `-P continuity` and `-P analyze` directly |
| Rig | [`t16-groom-segmented.sh`](scripts/t16-groom-segmented.sh) |
| Capture | 60 s per arm, sequential, one run each |

**Five arms. C, D and E are three points in the configuration space, which is what makes T14's claim
testable rather than arguable.**

| Arm | Groomer configuration | What it tests |
|---|---|---|
| **A** | none — ungroomed | T14 arm B1's measurement point, reproduced as the control |
| **B** | rate only, no depth flags | criterion 5: the pacer sizing itself from arrival |
| **C** | `--latency-ms 200 --max-latency-ms 2000 --stall-ms 1000` | the depths T13 ran on the MoQ lane, unchanged |
| **D** | `--latency-ms 200 --max-latency-ms 2000 --stall-ms 9000` | T14's proposal taken literally: same depths, timeout raised past the worst gap |
| **E** | `--latency-ms 8000 --max-latency-ms 16000 --stall-ms 9000` | every depth a flag reaches, set to what arm B derived |

Each arm is timestamped where its output actually goes — arm A on a pipe, because that is what
`tsp -I hls` writes to and what T14 measured; the groomed arms on a UDP socket, because that is a
groomer's output and what T13 measured. That keeps each column comparable with the campaign that
produced it.

### What this environment cannot show

- **Loopback inflates burst rate,** exactly as in T14. Burst *size* and the silences between bursts are
  structural, so the input the groomer sees is representative; the peak-rate figures are an upper bound.
- **The two instruments are not interchangeable.** Arm A resolves bursts at 64 kB reads; the groomed
  arms resolve every 1,316-byte datagram. A finer instrument sees more variance, not less, so the
  cadence improvement below is a lower bound.
- **Arm A's window carries more media than 60 s of real time,** because `tsp -I hls --live` drains the
  live window faster than real time before settling. That makes cross-arm *duration* ratios meaningless;
  see Corrections.
- **Nothing was ever missing, only late.** Every arm is loopback, so no segment failed to arrive. This
  measures absorption of a bursty delivery, not recovery from a lossy one.
- One clip, one segment duration, one run per arm, single host.

---

## Procedure

```bash
# All five arms, off one publisher, 60 s each, 2 s segments
PACER_REPO=~/mpegts-pacer lab/scripts/t16-groom-segmented.sh ~/CNNiEMEA2.ts ~/t16 60 2
```

The rig derives the output rate from the source's PCR timeline, starts publisher and origin, captures
arm A on a pipe and the groomed arms on loopback UDP, then reports cadence with `t13-cadence.py report`
and structure with `t13-grade.py grade`. Each pacer's closing statistics are collected, which is how the
buffer depth it chose for itself gets recorded.

---

## Results

### Measurement 1 — cadence: the burst structure is gone, and it did not need to be told anything

| 60 s window | A — ungroomed | **B — adaptive** | C — MoQ depths | D — stall only | E — every flag |
|---|---|---|---|---|---|
| Records | 22,799 reads | 65,186 dgrams | 53,998 | 65,187 | 65,186 |
| Delivered rate | 10.457 Mb/s | **11.438 Mb/s** | 9.475 Mb/s | 11.438 Mb/s | 11.438 Mb/s |
| Bursts (1 ms separation) | **28** | 50,144 | 40,222 | 47,347 | 50,959 |
| Median burst | **2.967 MB** | **1.3 kB** | 1.3 kB | 1.3 kB | 1.3 kB |
| Max burst | 3.753 MB | 22 kB | 20 kB | 20 kB | 14 kB |
| Gaps > 200 ms | 24 | **0** | 7 | **0** | **0** |
| Largest gap | **4,011.9 ms** | **17.2 ms** | 1,542.4 ms | 16.2 ms | 9.8 ms |
| 10 ms peak/mean | **236.39×** | **2.21×** | 2.44× | 2.02× | 1.66× |
| 10 ms CoV | **12.381** | **0.068** | 0.465 | 0.083 | 0.088 |

Arm A reproduces T14 arm B1 within run-to-run noise (28 bursts against 28, median 2.967 MB against
2.95 MB, CoV 12.381 against 12.514), which is the check that this is the same chain.

**Arm B's cadence is not merely better than the ungroomed egress, it is as good as the groomed MoQ
lane.** T13's pacer control on the MoQ egress measured 10 ms CoV 0.079 and a largest gap of 10.4 ms;
arm B reads 0.068 and 17.2 ms — from an input whose largest gap is 4.01 s, 27× the MoQ egress's worst
silence. Two columns within a factor of two of each other, from inputs two orders of magnitude apart:
**on a paced egress the arrival pattern has stopped being visible.**

The 1 s rate series shows the mechanism. Arm A alternates between 0.00 and 23–30 Mb/s; arm B reads
11.42–11.45 Mb/s in every one of the 59 whole seconds in the window, with no exceptions; arm C, on the
MoQ-lane depths, collapses to zero seven times:

```
A:  19.91 0.00 23.43 0.00 24.22 0.00 0.00 0.00 24.19 0.00 23.76 0.00 24.03 0.00 ...
B:  11.44 11.44 11.43 11.44 11.43 11.42 11.45 11.43 11.43 11.44 11.44 11.44 ...
C:  11.46 11.43  4.67 2.05 11.44 11.44 11.43 11.43 11.43 11.45 11.42 11.44 ...
```

**Cadence alone does not separate the arms, and that is the trap this measurement nearly fell into.**
Arms D and E look as good as B on every row of this table. Measurement 3 is where they part.

### Measurement 2 — timing and structure

`t13-grade.py grade`, arm A's capture as the structural reference:

| variant | packets | stuff % | Mb/s | PCR > 481 ns | PCR > 500 µs | > 40 ms | CC | max jitter | structure |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| A — ungroomed | 406,406 | 4.6 | 9.948 | 2,506 | 0 | 0 | 0 | 302.3 µs | preserved |
| **B — adaptive** | 456,302 | 16.9 | **11.442** | **0** | **0** | **0** | **0** | **13.7 µs** | **preserved** |
| C — MoQ depths | 377,986 | 19.3 | 9.479 | 2,036 | 7 | 7 | **348** | 1,537,659.7 µs | **FAIL: continuity** |
| D — stall only | 456,309 | 21.8 | 11.440 | **0** | **0** | 2 | **220** | 7.9 µs | **FAIL: continuity** |
| E — every flag | 456,302 | 16.9 | 11.441 | **0** | **0** | **0** | **0** | 10.1 µs | preserved |

Confirmed on arm B with `pcrverify` directly rather than only through `compliance.py`: **2,496 PCR OK,
0 with jitter > 13** under `--absolute` (481 ns), 0 at the campaign's looser `--jitter-max 500` (500 µs),
and 0 at `--absolute --jitter-max 500` (18 µs) — a gate tighter than any the campaign has quoted, which
this arm also passes. `tsp -P analyze` reports `pcrbitrate=11437843` against a commanded 11,437,843 —
the stream's PCR timeline and its byte clock agree exactly, which T13 identified as the pair of checks
that catches a stream claiming a rate it does not carry.

**Arm D is the reason criterion 4 exists.** It posts a *perfect* PCR record — 0 violations at 481 ns
over 2,723 PCRs, 0 at 18 µs, max jitter 7.9 µs, the best of any arm — and a perfect cadence, and it
is a corrupt stream: 220 continuity errors in the grading, 231 discontinuities under `tsp -P continuity`,
including on two of the three SCTE-35 PIDs. This is **T13's "passing every PCR check is not the same as
being right" recurring in a new rig**, and in a nastier form: T13's failing variant at least declared a
wrong rate, where arm D's rate, PCR arithmetic and wire cadence are all exactly right.

Carriage survives grooming intact on arm B. PID census against the ungroomed capture:

| PID | Content | A — ungroomed | B — groomed |
|---|---|---:|---:|
| 0x0000 / 0x0064 | PAT / PMT (own PID kept) | 518 / 518 | 508 / 508 |
| 0x0010 / 0x0011 / 0x0014 | NIT / SDT-BAT / TDT-TOT | 12 / 59 / 4 | 12 / 57 / 4 |
| 0x006F | AVC video | 368,645 | 360,526 |
| 0x0079 / 0x007B | MPEG-1 audio / AC-3 (typing kept) | 8,250 / 8,108 | 8,066 / 7,927 |
| 0x0083 | Teletext | 1,536 | 1,502 |
| 0x008D / 0x008E / 0x008F | SCTE-35 splice info, all three | 60 / 61 / 60 | 59 / 59 / 59 |
| 0x1FFF | Stuffing | 18,575 | 77,015 |

Every PID present, all three splice PIDs correctly typed, the DVB service layer including the TDT/TOT
the MoQ lane does not relay. The ~2 % lower counts are the window boundary, not loss (Corrections); the
stuffing rises from 4.6 % to 16.9 % because that is what pacing to a nominal rate above the content rate
*is*.

### Measurement 3 — the configuration space, tested

Closing statistics from the four groomed arms — the pacer reporting on its own input and its own
behaviour:

| | **B — adaptive** | C — MoQ depths | D — stall only | E — every flag |
|---|---|---|---|---|
| Dropped (buffer overflow) | **0** | 94,844 | 20,960 | **0** |
| Muted (carrier dropped) | **0** | 112,882 | **0** | **0** |
| Underruns (nulls mid-stream) | **1** | 35 | **125,296** | 3 |
| Stalls declared | **0** | 10 | **0** | **0** |
| Deliveries observed | 56 | 41 | 47 | 41 |
| Largest delivery | 3.48 MB | 6.03 MB | 3.75 MB | 3.32 MB |
| Arrival lead observed | 4,313 ms | 4,931 ms | 4,620 ms | 4,209 ms |
| Cushion in force | **8,000 ms (derived)** | 200 ms | 200 ms | 8,000 ms (set) |
| Buffer high-water | 69,711 pkt (13.1 MB) | 15,210 (2.9 MB) | 15,210 (2.9 MB) | 73,463 (13.8 MB)|
| Verdict | **pass** | fail | fail | pass |

**C — the documented MoQ depths — deletes a sixth of the programme.** 94,844 packets of the 536,611 it
was handed, 17.7 %, 17.8 MB, on a
feed that arrived complete. A 2,000 ms cap at this rate holds 2.9 MB and deliveries reach 6.03 MB, so
the buffer overflows on segments it has nothing else to do with; then, because a 1,000 ms timeout is a
quarter of the 4 s worst gap, it declares the source dead ten times and mutes 112,882 packets. Muting
compounds the overflow rather than relieving it — the byte clock advances but the buffer does not drain
— which is why C's drop count is 4.5× arm D's on the same cap.

**D — T14's proposal, taken literally — stops the muting and corrupts the stream instead.** Raising
only the timeout does exactly what T14 predicted: no stalls, no muting, a flat wire. It leaves the cap
untouched, so the buffer still overflows (20,960 packets), and it leaves the 200 ms start gate
untouched, so the pacer begins output holding 200 ms of media with the next segment 1.8 s away and then
pads the shortfall with nulls: **125,296 underrun packets, 21.8 % stuffing, 548 PCRs it had to insert
itself.** The result is the arm that passes criteria 1, 2 and 3 and fails 4. **So the sentence "the
mechanism is right, the timeouts are too tight" is not true: the timeout was the least of the three
things that were wrong.**

**E — every depth set to what arm B derived — passes.** So the parameter space *does* contain a passing
configuration, reachable with flags that predate this work: an 8 s cushion, a 16 s cap, a 9 s timeout.
That is the honest limit on how much of T14 this run corrects, and it is also the whole argument, because
those three numbers are not properties of `mpegts-pacer`. They are properties of the egress it was
pointed at — 8 s is 2.5× the 4.2 s lead this feed builds, and at 6 s segments it would be wrong. Arm B
reaches the same place having been told the output rate and nothing else. **The difference between B and
E is not what the wire looks like; it is whether the operator has to characterise the egress before
grooming it.**

**The cushion arm B chose is the ceiling, not the factor.** Observed lead 4,313 ms × the 2.5 default
factor is 10.8 s, clamped to the 8 s default ceiling. This run therefore does not test the factor; it
tests whether 8 s suffices for 2 s segments, and it does, with the buffer peaking at 13.1 MB against a
4.01 s worst gap. A 6 s segment duration would need the ceiling raised, which is the remaining knob and
the honest statement of it.

**What this run does not separate.** Arms B and E differ in *when* output starts — B waits until it
holds a full cushion and the input is between deliveries, E waits 8 s on a timer — and on a rate-matched
delivery those coincide, because 8 s of wall time accumulates ~8 s of media. So the content-based start
gate is unfalsified here rather than demonstrated. What distinguishes it is a first delivery that is
partial or a feed that is not rate-matched, neither of which this rig produces.

### Against the pass criteria

| Criterion | Result |
|---|---|
| 1. Timing | **Met.** 0 PCR violations at 481 ns over 2,496 PCRs, and 0 at 18 µs and 500 µs; 0 repetition intervals above 40 ms; 0 continuity errors; `pcrbitrate` exactly the commanded rate. The T13 standard, on the other data plane. |
| 2. Cadence | **Met, beyond the criterion.** 10 ms CoV 0.068 against arm A's 12.381 and T13's MoQ-lane 0.079; largest silence 17.2 ms against 4,011.9 ms. Measured with a finer instrument than arm A's, so it is a lower bound. |
| 3. Carriage | **Met.** Every PID, the DVB service layer, all three SCTE-35 PIDs with typing. |
| 4. Nothing deleted | **Met.** 0 dropped, 0 muted, 0 stalls, 1 underrun packet. Arms C and D, on configurations reachable by flag, deleted 17.7 % and 3.8 % of the programme respectively. |
| 5. No tuning | **Met.** Arm B was given an output rate. Segment duration, cushion, cap, start condition and stall timeout were all derived from arrival at run time. Arm E shows the tuned equivalent exists; it does not reach itself. |

---

## Observations

**T14's "configuration finding, not a defect" was right in the weak sense and wrong in the sense that
mattered.** A passing configuration exists — arm E — so the parameter space was adequate, as claimed.
But the claim named the wrong parameter and the wrong magnitude: the operative change is the *cushion*,
from 200 ms to 8 s, a factor of 40, and the timeout follows from it rather than the other way round.
Arm D is the claim implemented exactly as written and it corrupts the stream. **The generalisable form:
when a tool fails on a new input and the diagnosis is "the mechanism is right, the numbers are wrong",
that diagnosis is worthless until the numbers are named, because "adjust the timeouts" and "multiply the
buffer by forty and re-derive two other quantities from it" are different findings that read
identically.**

**The substantive result is that one groomer serves both data planes.** The pacer was built and measured
against a MoQ egress whose worst silence is 149 ms. Handed an egress whose worst silence is 4.01 s it
reaches the same timing gates and a better cadence figure, with no flag changed and no separate code
path, because the quantity it sizes against — the lead the input builds ahead of real time — is measured
rather than assumed. This matters for the paper's framing beyond the tool: the grooming obligation sits
on the distributor's side of the demarcation on *both* planes
([comparison](../docs/comparison.md) §4.1), and it is dischargeable by one stage rather than two.

**A perfect wire is not evidence of a good groomer, and arm D is the proof.** Arm D's cadence
(CoV 0.083, no silence beyond 16 ms) and PCR record (0 violations, 7.9 µs max jitter — the best of any
arm) are indistinguishable from a correct result, over a stream carrying 231 discontinuities including
on SCTE-35. Every measure that looks at *when* bytes leave was satisfied; the failure is only visible in
measures of *which* bytes left. Any grading of a pacing stage needs a packet-conservation column beside
the timing ones, which is why criterion 4 is stated separately above and why the pacer's own drop and
underrun counters are reported per arm.

**The cost of absorption is start-up latency and resident memory, and it is arithmetic.** Arm B held
output back until it had 7.5 s of programme and ran a 13.1 MB buffer. A groomer cannot ride out a gap it
has not stored programme for, so T14's latency-floor finding survives grooming unchanged: segment
duration sets the floor and grooming adds a further multiple of it. What grooming does *not* do is leave
that latency visible to the receiver as a cadence problem.

**Detection time is the honest asymmetry between the planes.** Arm B's stall timeout is derived as
cushion plus grace, landing at 9 s against the 1 s the MoQ lane runs. On a segmented plane a dead origin
and a slow publish are indistinguishable faster than a segment period, so the deep cushion that buys
clean cadence necessarily buys slow failure detection with it. An operator taking segmented HTTP for
primary distribution gets off-the-shelf reassembly and pays ~9 s of failure detection for it. That is a
property of the data plane, not of the groomer, and not a defect to fix.

**What limits PCR placement is the egress, not live operation and not the cushion.** T13 measured 0 PCR
repetition intervals above 40 ms on a file against 131 in 25 s on the wire, and concluded that a stage
re-timing a stream as it arrives cannot place PCRs as freely as one reading a file. Arm B posts 0 on
the wire, which disposes of the file-versus-live reading. It looked at the time as though depth were
the replacement — Arm B carries seconds of cushion where the MoQ legs carried about one — and that was
the wrong variable, because the two runs also differed in the data plane. Two later measurements
separate them. [T18](test-18-delivery-latency.md) swept the MoQ lane's cushion across eight times the
depth and found **no crossing point and no trade**: repetition holds at ~490 intervals above 40 ms with
a 228 ms maximum, and stays there when groomer starvation is removed altogether. And
[T13](test-13-downstream-grooming.md)'s segmented pass-through leg posts 0 while holding almost no
buffer at all.

The determinant is what the egress delivers. A segmented egress arrives with **0** intervals above
40 ms, because the packager preserved a conformant broadcast mux's PCR spacing; a MoQ egress arrives
with 163, because `export ts` emits PCRs too rarely, and `pcr_inserted=0` on the rate-matched cell
confirms the groomer added none of its own. A stage that carries PCR inherits exactly what it was
given. Depth does not buy placement on either lane — it only prevents a stage from *adding* intervals
by running dry, which is a different defect with a different signature (T13's 1 s segmented leg:
1.85 s of silence, 311 continuity errors). **The good news for the paper is that the trade feared here
does not exist:** depth is latency, latency is MoQ's only lead, and repetition turns out not to be
buyable with it on either plane.

---

## Conclusion

**The unmeasured cell in [evidence](../docs/evidence.md) §3.2 is closed, and the answer is
yes.** A segmented-HTTP egress grooms to the same standard T13 reached on the MoQ lane — 0 PCR violations
at 481 ns, 0 repetition intervals above 40 ms, 0 continuity errors, 10 ms CoV 0.068, largest silence
17.2 ms, every PID and all three SCTE-35 PIDs preserved — by the same tool, in the same chain, with
nothing dropped and nothing muted.

**Reaching it needed the buffer to be sized from arrival, not the flags to be set differently, and the
distinction is narrower than it looks.** A flag-only configuration passes (arm E), so T14 was right that
the parameter space was adequate. It was wrong about which parameter and by how much, and its literal
proposal — raise the timeout — produces a stream with 231 continuity errors and an immaculate PCR record
(arm D). The three numbers arm E needs are properties of the egress rather than of the tool, so
somebody has to measure the arrival pattern; the result here is that the groomer can do it itself, from
the output rate alone.

**The paper's two-plane framing gets stronger and its latency framing does not move.** One groomer
serves both egresses, so no *custom* stage has to be written twice. The lanes are not equivalent in
what they require of that stage, though, and the asymmetry runs the other way from the one this
experiment was looking for: [T13](test-13-downstream-grooming.md) later graded the off-the-shelf
candidates against a segmented egress and found that `tsp -P pcradjust -P regulate` passes all four
criteria with the mux intact, because this lane hands a groomer the stuffing, the declared mux rate
and the PCR spacing that `moq export ts` drops. On this plane the pacer is a better option; on the MoQ
plane it is the only one. What segmented HTTP still costs is 7.5 s before the first byte, 13.1 MB
resident and ~9 s to notice a dead source — all three set by segment duration, none of them removable
by a better groomer.

### Still open

Protocols for these are in [planned-experiments.md](planned-experiments.md).

| Cell | Needs |
|---|---|
| The adaptive factor, tested rather than clamped | a segment duration whose 2.5 × lead lands under the 8 s ceiling — 1 s segments. This run only shows the ceiling was adequate |
| 6 s segments through the same chain | the default ceiling raised. T14 measurement 5 published at 6 s, so the fixture exists |
| The content start gate, distinguished from a timer | a feed that is not rate-matched, or a join mid-segment. On this rig the two coincide |
| Grooming a *lossy* segmented egress | a path that drops segments rather than delivering them late. Nothing was ever missing here, only late |
| The same grading against a hardware IRD | [T7](test-7-timing-integrity.md)'s open Gate 2, which this inherits rather than advances |

---

## Corrections

> The general method rules extracted from this section, together with those from every other
> experiment, are collected in [method-notes.md](method-notes.md). What stays here is the
> specific record of what this experiment got wrong.

**A conclusion was drafted from arithmetic and the run contradicted it.** The first version of this file
stated that no configuration of the documented flags passes, reasoning correctly that a 2,000 ms cap
cannot hold a 3.9 MB delivery and that the 200 ms start gate is not exposed as a flag — and concluding
incorrectly, because `--latency-ms 8000` moves the start gate as a side effect of moving the cushion.
Arms D and E were added to test the claim instead of asserting it, and arm E passes. The corrected
finding is narrower and more useful than the one it replaced: the configuration exists, the numbers in
it are properties of the input, and the disagreement with T14 is about *which* parameter, not about
whether tuning can work. *Lesson: a claim about what a tool cannot be configured to do is a claim about
its whole parameter space, and the cost of running two more arms is far below the cost of publishing the
inference. This nearly went out as "no configuration passes" on the strength of two correct facts about
three parameters.*

**Duration fidelity cannot be compared across these captures, and the grading table reports it anyway.**
The `dur` column reads 0.976 for every groomed arm, which looks like a stream running 2.4 % short and is
not: the structural reference is arm A's capture, and `tsp -I hls --live` drains the live window faster
than real time before settling, so arm A's 58.45 s of wall time carries more media than the groomed
arms' 60.00 s do. The ~2 % shortfall in every PID count above has the same single cause. This is
**T9's loopback span artefact recurring for the third time in this campaign** — T9 recorded it, T14
measurement 5 hit it again and fixed it by removing wall clocks from the ratio — and it recurs because
each new rig re-derives a comparison from whatever captures it happens to have. The check that *is*
valid here is intrinsic to one stream: `pcrbitrate` equals the commanded rate exactly, so the groomed
output carries the media time it claims. *Lesson: a ratio between two captures is only valid when both
windows cover the same media; a rig that grades arms against each other should assert that rather than
assume it.*

**`pcrverify --jitter-max` changes units depending on another flag, and this run was graded twice
because of it.** Mid-analysis the 500 in the harness's second gate was read as 500 PCR units — 18 µs —
and a correction was drafted against T13's procedure text and against
[`t13-grade.py`](scripts/t13-grade.py)'s header, both of which say 500 µs. Both were right and the
correction was wrong: **`--jitter-max` is microseconds by default and PCR ticks only under
`--absolute`**, so the campaign's `--jitter-max 500` gate has always been the 500 µs it claims. The
arms were re-measured at both readings, which is why the results above quote 500 µs and 18 µs
separately; arm B passes at both, so nothing moved. The script's header now states the dependency.
*Lesson: an option whose units depend on a sibling flag will be misread eventually, and the tell that
it had been misread here was `pcrverify` printing its own conversion — "jitter > 13,500 (500
micro-seconds)" — in the output that was already on screen. Read the tool's echo of the threshold, not
the flag.*

---

## References

- [T14](test-14-data-plane-comparison.md) — the ungroomed egress this grooms, and the "configuration
  finding" this narrows
- [T13](test-13-downstream-grooming.md) — the grooming standard on the MoQ lane, whose criteria and
  gates are reused verbatim, and whose "passing every PCR check is not the same as being right"
  observation arm D reproduces
- [T9](test-9-performance.md) — the loopback span artefact recorded in Corrections
- [architecture](../docs/architecture.md) §4.5 — the work this measures
- [evidence](../docs/evidence.md) §3.2 — the unmeasured cell this closes
- Rigs: [`t16-groom-segmented.sh`](scripts/t16-groom-segmented.sh),
  [`t13-cadence.py`](scripts/t13-cadence.py), [`t13-grade.py`](scripts/t13-grade.py)

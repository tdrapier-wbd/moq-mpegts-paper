# T7 — Timing integrity (TR 101 290)

## Objective

Prove that the groomed egress is timing-conformant: PCR accuracy and interval, PTS/DTS continuity,
and mux-rate stability all within TR 101 290 limits — first on file (P1, cheap), then on the live
wire (P2) on a real hardware IRD. P2 is the make-or-break gate (Gate 2).

Both data planes are graded, and the question is different on each. On the **media-aware** lane the
exporter re-muxes, so grooming has damage to repair and the measurement is whether it repairs it. On
the **segmented** lane the segments are byte-verbatim slices of the source, so there is nothing to
repair and the measurement is whether grooming a burst-arrival feed introduces damage of its own.
[T16](test-16-grooming-segmented-http.md) answered that for one clip; what is untested is whether the
answer holds for *whatever the lane is given*, which is what four clips of deliberately different
bitrate, chroma format, GOP structure and native PCR cadence are for.

## Environment

- Full media-aware lane + `mpegts-pacer`: `~/CNNiEMEA2.ts` (and the three other T1 clips) →
  `tsp regulate` → `moq import ts` → `moq-relay` → `moq export ts` → `mpegts-pacer` (`cbr_file`,
  `auto regenerate`) → TSDuck.
- Build under test: `moq-dev` `feat/mux-ts-dvb-service-layer` (`moq` 0.8.7, `moq-relay` 0.13.7,
  `moq-native` 0.18.3 — carrying #2072/#2066 and the #2440 service layer), so the exporter
  round-trips the CNN open-GOP + triple-SCTE-35 feed deterministically and **keeps the PMT PID at
  0x0064** (no longer renumbered). `mpegts-pacer` 0.1.0; TSDuck 3.44.
- Segmented lane, same laptop, same four clips, same groomer:
  `tsp -I file --infinite -P regulate --pcr-synchronous` → `tsp -O hls` (2 s segments,
  `--intra-close --align-first-segment`, 6-segment live window) → `python3 -m http.server` on
  loopback → `tsp -I hls --live` → `mpegts-pacer` sizing its own buffer from the arrival pattern →
  loopback UDP socket → TSDuck. The groomer is given the output rate and nothing else, which is the
  configuration T16 found sufficient. Output rate is 1.15 × the clip's own content rate.

## Procedure

1. **File (P1).** Capture groomed egress; run TSDuck `pcrverify` (interval/accuracy), `pcrextract`
   (jitter distribution) and `analyze` (structure, mux rate). Confirms the re-stamp arithmetic. Per
   clip: raw media-aware egress → paced (see `lab/README.md` for the analysis commands).
2. **Segmented lane, live (P1 as delivered).** Per clip, two arms off one publisher: the ungroomed
   egress `tsp -I hls` produces, and the same egress through `mpegts-pacer` onto a loopback UDP
   socket. Both arms are graded from the delivered bytes with `pcrextract` (repetition), `pcrverify
   --absolute --jitter-max 13` (accuracy at ±500 ns), `continuity`, and `analyze` (declared rate
   against PCR-implied rate). Nothing here is offline file arithmetic: the groomer is pacing a live
   stream in both cases. `lab/scripts/t7-segmented-clip.sh`, driven for the four clips by
   `t7-segmented-sweep.sh`.
3. **Hardware (P2) — not yet run.** Feed the live egress to a hardware IRD and TR 101 290 analyser;
   confirm PLL lock and a clean P1/P2 result over a sustained soak of **≥ 72 h**, which is set by the
   PCR base's 26.51 h wrap period rather than chosen — a 24 h run can contain no wrap at all
   ([method-notes](method-notes.md) §3); run jointly with the T9 resource soak. Exercise the correctness
   boundaries a groomer must handle beyond steady state: source-clock drift, PCR discontinuities /
   33-bit wrap, mid-stream PID/PCR-PID change. **Each of those has a synthesisable substitute that
   should be run against the groomer here first**, so a failure on hardware is attributable to the
   receiver rather than to an untested precondition of ours. Corroborate with a second analyser
   (Elecard/R&S/Tektronix/Ateme) where access exists. See
   [planned-experiments.md](planned-experiments.md).

## Results

> **Every media-aware figure below is file arithmetic, and one of them does not survive the wire.**
> (The segmented-lane figures further down are live throughout, and are labelled where they sit.) The
> 0 % PCR interval result is the campaign's most-quoted number and it is a *precondition*, not a
> delivered result: measured on the socket at the cushion this lane runs,
> [T13](test-13-downstream-grooming.md) puts the same tool at **131 intervals above 40 ms in 25 s on
> the laptop rig and 159 on the EC2 rig, with a 227.4 ms maximum**. Quote 0 % only with "on file"
> attached. The P2 accuracy caveat below was always stated; the P1 repetition caveat is now measured.

### Media-aware lane

P1 (file) figures are the range across four groomed clips; P2 remains the load-bearing open item.

| Metric | Unit | Limit | P1 (file) | P2 (hardware) |
|---|---|---|---|---|
| PCR accuracy | ns | ±500 (P2) | **0 viol. @ ±500 ns; ≤ 74 ns floor¹** | **TBM (load-bearing)** |
| PCR interval — max | ms | ≤ 40 | **30.6–32.2**⁴ | TBM |
| PCR interval — % > 40 ms | % | 0 | **0.0000 %** (all 4 clips)⁴ | TBM |
| PTS/DTS continuity | pass/fail | no gaps | **pass** (no gaps; DTS authored) | TBM |
| Mux-rate stability | Mbps/jitter | CBR | **exact CBR** (bitrate = pcrbitrate) | TBM |
| TR 101 290 P1 | pass/fail | pass | **pass** (file-level)⁴ | **TBM** |
| TR 101 290 P2 | pass/fail | pass | n/a (file) | **TBM** |
| IRD PLL lock (sustained) | hh:mm | stable | n/a | TBM (≥ 72 h: the PCR base wraps at 26.51 h) |
| Drift / discontinuity / wrap | pass/fail | pass | **0 disc. (steady state)²** | TBM |

¹ File arithmetic, not wire timing: `pcrverify` records 0 violations at ±500 ns on all four clips;
tightest floor ≤ 74 ns (≤ 2 units) on `testloop_clean`, ≤ 37 ns (≤ 1 unit) on the other three.
Because the pacer byte-locks PCR to output position, file jitter is near-zero by construction — the
wire (P2) test is the one that decides PCR_accuracy. ² 0 CC errors and 0 PCR discontinuities in
steady state; boundary cases (drift, 33-bit wrap, mid-stream PID change) are not exercised by these
clips and remain TBM. ⁴ These are the rows the wire disagrees with, and the disagreement is measured
rather than anticipated: on the socket at this lane's cushion the same tool posts 131–159 intervals
above 40 ms in 25 s, up to 227.4 ms, which is a P1 failure as delivered
([T13](test-13-downstream-grooming.md)). The hardware column stays TBM because a socket capture on a
general-purpose OS is not an IRD either.

### File-based (P1) per clip — media-aware lane + `mpegts-pacer`

| Clip (paced CBR) | Raw egress > 40 ms | Paced > 40 ms | Paced PCR max (ms) | Mux rate (exact CBR) | `pcrverify` > 500 µs | CC err |
|---|---|---|---|---|---|---|
| `testloop_clean` (synthetic) | 25.15 % | **0 %** | 32.15 | **9.731 Mbps** | **0** | 0 |
| `testloop` (27.5 Mbps 4:2:2) | 0 %³ | **0 %** | 30.64 | **30.085 Mbps** | **0** | 0 |
| `CNNiEMEA` (CNN, 5 min) | 13.92 % | **0 %** | 31.84 | **11.006 Mbps** | **0** | 0 |
| `CNNiEMEA2` (CNN, 10 min) | 9.08 % | **0 %** | 31.84 | **11.006 Mbps** | **0** | 0 |

³ `testloop`'s native 27 ms PCR cadence is already < 40 ms before grooming; pacing still converts it
to exact CBR (`bitrate = pcrbitrate = userbitrate`) with byte-locked PCR. For every clip the pacer
inserts byte-locked PCR-only packets where source spacing exceeds 40 ms (117–737 per clip) and stuffs
12.7–13.0 % nulls, dropping 0 content packets.

Known baseline (pre-groom, file, P1): ~24 % of PCR intervals exceeded 40 ms, up to 133 ms — the
problem grooming exists to solve.

### Segmented lane, delivered — the same four clips

Live throughout, so these are delivered figures with no file-domain column to be misread. 45 s
window, 2 s segments, groomer told the output rate and nothing else.

| Clip | Content rate | Ungroomed max (ms) | Ungroomed > 40 ms | Groomed max (ms) | Groomed > 40 ms | `pcrverify` @ ±500 ns | CC err | Declared vs PCR-implied rate |
|---|---|---|---|---|---|---|---|---|
| `testloop_clean` (synthetic) | 10.00 Mbps | 20.00 | **0** | 38.45 | **0** | **0** | 0 | 11,500,029 / 11,500,005 b/s |
| `testloop` (27.5 Mbps 4:2:2) | 27.51 Mbps | 28.16 | **0** | 48.59 | **1** (0.058 %) | **0** | 0 | 31,633,990 / 31,633,990 b/s |
| `CNNiEMEA` (CNN, 5 min) | 9.95 Mbps | 24.95 | **0** | 35.50 | **0** | **0** | 0 | 11,437,843 / 11,437,843 b/s |
| `CNNiEMEA2` (CNN, 10 min) | 9.95 Mbps | 24.95 | **0** | 34.19 | **0** | **0** | 0 | 11,437,842 / 11,437,843 b/s |

**The ungroomed column is 0 by construction and that is the finding, not a null result.** A segment
is a byte-verbatim slice of the source, so the source's own PCR spacing arrives intact and there is
nothing for a groomer to repair. The media-aware lane's equivalent column reaches 9.08–25.15 % above
40 ms on the three clips whose native cadence is not already inside the limit, because its exporter
re-muxes. The two lanes ask the groomer for different things: repair on one, cadence and CBR on the
other.

**Three clips pass; the 27.5 Mbps one does not, and the reason is the instrument.** `testloop`
reproduces its failure across four runs — 1, 3, 4 and 8 intervals above 40 ms, worst 50.0 ms — so it
is not noise. Three controls locate it, and none of them is the lane:

| Configuration on `testloop` | Intervals > 40 ms | Max (ms) | What it rules out |
|---|---|---|---|
| Adaptive cushion (8 s ceiling), 4 runs | 1, 3, 4, 8 | 46.2–50.0 | nothing — this is the condition under test |
| Cushion ceiling raised to 16 s | 3 | 43.74 | the adaptive sizer's ceiling |
| 1 s segments (source gap halved, 3798 → 1878 ms) | 5 | 50.97 | segment size and arrival gap |
| **Local file straight into the groomer — no lane at all**, same 31.63 Mbps output | **9** | **49.59** | **the segmented lane** |

The last row is decisive. Fed a smooth local file whose largest content gap is 51 ms and whose
arrival bursts are 0.28 MB, the groomer still posts nine intervals above 40 ms at this output rate —
worse than any run through the segmented lane. Every failing configuration also reports pacer
underruns (1–6). So at ~31.6 Mbps the pacing stage on this laptop misses the 40 ms deadline on *any*
input, and `testloop` measures where the instrument saturates rather than where the lane does. The
segmented lane is **unmeasured above ~11.5 Mbps on this rig**, not failed.

Accuracy and continuity are unaffected throughout: `pcrverify` records 0 violations at ±500 ns on
every groomed capture including the failing ones, and no capture on either arm has a continuity
error. `pcrverify` on the *ungroomed* arm is not reported because it has nothing stable to grade
against — the same capture reads 0, 17, 22 and 782 violations across runs, since the arm has no
declared CBR for the tool to measure jitter from.

## Observations

- P1 on file is a pass on the media-aware lane across a synthetic CBR reference, a 27.5 Mbps 4:2:2
  mux, and two real CNN contribution captures.
- **P1 file analysis is optimistic by construction:** it cannot see the software CBR pacer's
  scheduling jitter on a general-purpose OS/NIC, which is exactly what PCR_accuracy (±500 ns) tests on
  the wire. Only P2 decides it.
- **The same construction flatters PCR *repetition*, and that half is no longer hypothetical.**
  Reading a file, the stage places PCRs wherever the arithmetic wants them; delivering live it can
  only place one when it has a packet ready at the deadline, which at this lane's cushion it often
  does not. The 0 % above is therefore a statement about the re-stamp and not about what an IRD would
  receive.
- A single IRD model is not the installed base; a credible pass needs a defined IRD test matrix
  (models, analyser settings).
- **On the segmented lane the two domains do not diverge, because there is no offline stage to
  diverge from.** Every segmented figure here was taken live, and three of four clips are conformant
  as delivered — which is the thing the media-aware lane has never been able to show.
- **Clip diversity earned its keep, but not in the direction expected.** The one clip that behaves
  differently does so because of its bitrate and not its chroma format, GOP structure or PCR cadence,
  and what its bitrate exposes is the rig. A single-clip run at ~10 Mbps would have reported a clean
  pass and concealed that the instrument has a ceiling at all.

## Conclusion

The media-aware lane + `mpegts-pacer` is CBR/PCR-conformant **at P1 on file** across four clips
(0 % > 40 ms, exact CBR, 0 `pcrverify` violations @ ±500 ns, 0 CC), and the opaque-lane P1 is shown in
[T3](test-3-opaque-transparency.md). *Necessary but not sufficient* is not a formality here: on the
one axis where a wire measurement has since been taken, the file result did not carry over
([T13](test-13-downstream-grooming.md), 131–159 intervals above 40 ms in 25 s). So the grooming
design is "structurally sound and file-validated", and on P1 PCR repetition as delivered it is
"measurably not conformant at the depth currently run" — not "proven broadcast-acceptable". **The
hardware (P2) pass remains the open, load-bearing test**, and a cushion sweep on the MoQ lane is the
cheaper one that would settle the P1 half ([planned-experiments.md](planned-experiments.md)).
Recorded as a permanent finding in [`docs/evidence.md`](../docs/evidence.md) §3.2.

**On the segmented lane the same four clips are conformant as delivered at ~10 Mbps** — 0 intervals
above 40 ms, 0 `pcrverify` violations at ±500 ns, 0 continuity errors, and declared rate agreeing with
PCR-implied rate to within a few parts per million — and this is a live result, not file arithmetic. Two things follow, and the second
matters more than the first. The lane needs no PCR *repair*, because verbatim segments carry the
source's spacing; grooming there buys cadence and CBR, not conformance. And the campaign's most
valuable number on this lane is now bounded rather than open: it holds up to ~11.5 Mbps, and above
that the pacing stage on this laptop runs out before the lane does, so **27.5 Mbps is untested rather
than failing**. Establishing it needs a host that can pace 30 Mbps without underrunning, which is a
rig upgrade and not an experiment ([planned-experiments.md](planned-experiments.md)).

## Corrections

> The general method rules extracted from this section, together with those from every other
> experiment, are collected in [method-notes.md](method-notes.md). What stays here is the
> specific record of what this experiment got wrong.

- **A file-domain conformance figure was reported as the conformance figure.** This experiment's
  headline — 0 % of PCR intervals above 40 ms after grooming — was quoted downstream as what a
  receiver would get, and for several revisions five documents carried it without naming the domain.
  It is a statement about the re-stamp arithmetic only. On the socket, at this lane's cushion, the
  same tool posts 131–159 intervals above 40 ms in 25 s
  ([T13](test-13-downstream-grooming.md)). **Method rule:** where an offline analyser and a hardware
  receiver would grade a number differently, the number is not reportable without the domain that
  produced it — and a file result is the precondition for a wire result, never a substitute.
- **A conformance failure was nearly published against the lane that was on trial.** The segmented
  arm's 27.5 Mbps clip failed P1 repetition reproducibly, and the lane under test was the obvious
  culprit — the arrival pattern is bursty, the buffer is sized from it, and two plausible mechanisms
  (the adaptive ceiling, the segment gap) were available to explain it. Both were wrong. Removing the
  lane entirely and feeding the groomer a local file at the same output rate produced a *worse*
  result, which is the only control that could have distinguished the instrument from the subject.
  **Method rule:** before a measurement is attributed to the thing under test, run it once with the
  thing under test removed — and where a stage's own throughput could be the limit, that control is
  not optional, because a saturated instrument fails in the direction that looks like a finding.
- **A rig with a fixed port and no identity check grades whoever answers it.** Two sweeps overlapping
  on one port produced a full set of plausible, conformant, wrong results, each clip graded against
  whichever stream happened to be serving. This is the same defect [T6](test-6-relay-resilience.md)
  found and fixed on its own rig, re-encountered on a rig written afterwards, because the fix had been
  recorded as a T6 correction rather than as a property every rig here needs.

## References

- The segmented lane's single-clip grooming result this arm generalises:
  [T16](test-16-grooming-segmented-http.md).
- Wire-domain PCR repetition on the same tool: [T13](test-13-downstream-grooming.md).
- P1 vs wire caveat, boundary cases: [`docs/architecture.md`](../docs/architecture.md) §4.2.
- Hardware-soak protocol (not yet run), and the cushion sweep that would settle the P1 half:
  [planned-experiments.md](planned-experiments.md).
- Finding: [`docs/evidence.md`](../docs/evidence.md) §3.2.

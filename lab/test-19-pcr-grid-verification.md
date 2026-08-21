# T19 — verifying the upstream PCR grid fix, and where it stops

> **State:** complete, on the laptop rig, one clip, before/after against the same binaries' predecessor.
> **The exporter's defect is fixed completely and the lane's is not.** `moq export ts` now emits a
> flawless uniform PCR grid — every interval exactly 25.000 ms, 0 above the 40 ms P1 gate, and the 85 %
> sub-millisecond clustering that [T18](test-18-delivery-latency.md) measurement 6 diagnosed is gone
> entirely — and it fixes a second conformance defect this campaign never found. But the PCR packets'
> *positions in the exported byte stream* are bunched where their values are not: **87.2 % sit
> back-to-back**, in bursts up to 13, separated by gaps to 2,730 packets. The fix places each PCR in its
> own output frame stamped at its slot boundary, and `moq export ts` writes to stdout, which carries no
> timestamps — so the property holds inside the muxer and is unobservable to every byte-stream consumer.
> **Any downstream stage that re-derives PCR from byte position therefore reproduces the original
> defect**, measured: off-the-shelf `tsp -P pcradjust` yields 293 intervals above 40 ms and 87.9 %
> sub-millisecond, the original shape. Our own byte-locking groomer drops **45.9 % of content**. End to
> end on the wire the MoQ lane is *worse* than before the fix.

## Objective

[#2967](https://github.com/moq-dev/moq/pull/2967) closed
[#2937](https://github.com/moq-dev/moq/issues/2937), the PCR placement defect this campaign reported.
Verify the claim independently, on our clip and our instruments, and establish what it changes for the
edge stage — because the reported defect was never "the exporter's file looks wrong", it was "no
downstream CBR stage can repair this", and only the second half decides whether the lane can be
groomed.

Two questions, and the second is the one that matters:

1. Does the exporter now emit PCR at a bounded interval? *(The PR's own claim.)*
2. Does a groomer downstream of it now produce a conformant wire? *(The campaign's requirement.)*

## Pass criteria (fixed before the runs)

The gate is [T13](test-13-downstream-grooming.md)'s, unchanged, because the point of the fix is to let
that gate be met:

1. **PCR spaced within the repetition limit** — no intervals above 40 ms, at the exporter *and* after
   grooming.
2. **The mux survives** — every PID, stream type and PSI table intact, 0 continuity errors.
3. **Continuity discipline on the new packet type** — the fix relies on ISO 13818-1 2.4.3.3, that a
   packet carrying no payload must not advance the continuity counter. A stream that breaks that rule is
   broken for every receiver, whatever its PCR looks like.
4. **No regression in delivery latency**, since the lane's whole case rests on it
   ([T18](test-18-delivery-latency.md): 109 ms across the internet).

## Environment

| | |
|---|---|
| Rig | One laptop (macOS, Apple silicon), loopback |
| Source | `~/CNNiEMEA2.ts` — 1080i25 H.264, 9,945,951 b/s CBR, 4.57 % null stuffing, video PID 111 |
| Publisher | `tsp -I file --infinite -P regulate --pcr-synchronous --wait-min 5` |
| **Build under test** | `moq 0.9.12-61678fd32` — the #2967 merge commit, built from a detached worktree so the working checkout is untouched |
| **Control build** | `moq 0.9.10-eab960192` — `~/bin-main`, the binaries every prior result was measured on |
| Groomer | `mpegts-pacer` 0.1.0 at `12f41ad`, both `cbr_file` (file domain) and the main binary (live RTP egress) |
| Off-the-shelf groomer | TSDuck 3.44-4676, `tsp -P pcradjust` — T13's closest-passing off-the-shelf stage |
| Rigs | [`t19-pcr-grid.sh`](scripts/t19-pcr-grid.sh) for the exporter's own output; [`t18-arm.sh`](scripts/t18-arm.sh) unaltered for the end-to-end arm |
| Window | 60 s per exporter capture, 90 s per end-to-end arm, 250 ms groomer cushion |

**The exporter is graded with no groomer in the path.** This campaign's groomer regenerates PCR, so
putting it in the path measures the pair and would mask or manufacture the result either way. That is
the mistake T18 measurement 6 had to borrow another experiment's rig to avoid, and
[`t19-pcr-grid.sh`](scripts/t19-pcr-grid.sh) exists so the control is native from here on.

## Measurement 1 — the exporter: the fix is complete, and it does more than it claims

Same clip, same instrument, same 60 s window; only the binary changes.

| | control (`0.9.10`) | **fixed (`#2967`)** |
|---|---:|---:|
| PCRs in the window | 2,123 | 2,472 |
| Mean interval | 28.959 ms | **25.000 ms** |
| Min interval | 0.011 ms | **25.000 ms** |
| Max interval | 319.9 ms | **25.000 ms** |
| Intervals > 40 ms (P1 gate) | 210 (9.89 %) | **0 (0.00 %)** |
| Intervals < 1 ms (the clustering) | 1,813 (85.40 %) | **0 (0.00 %)** |
| Continuity errors | 0 | **0** |
| PCR packet shape | adaptation **+ payload** | adaptation-only, **no payload** |
| PCR on any PID but the announced one | no | **no** (2,473 packets, all PID 111) |
| Payload-less packets advancing the continuity counter | 0 | **0** (ISO 13818-1 2.4.3.3) |
| Reserved bits in the PCR field | **`0x00`** | **`0x3F`** |
| TSDuck's reference bitrate for the stream | 20,677,758,476 b/s | **9,571,694 b/s** |

**The grid is exact.** Minimum, mean and maximum interval are all 25.000 ms across 2,472 consecutive
intervals — a single histogram bin. The defect T18 measurement 6 characterised as "85 % of PCRs within
11 µs of the one before, with the residue in 100 ms to 1.8 s holes" is not reduced, it is absent.

**Two things improved that we never reported, and one of them we never found.** The reserved six bits of
the PCR field were being written as zeros where ISO 13818-1 requires ones — a conformance defect a
strict analyser flags and this campaign missed through eighteen experiments, because every instrument we
pointed at the stream read the PCR *value* and none checked the field's padding. The PR found it while
hand-laying the new packet and fixed it in passing. Separately, TSDuck's reference bitrate for the
exported stream goes from a meaningless 20.7 Gb/s to a credible 9,571,694 b/s: the old clustered values
made every rate estimate derived from them nonsense, which is worth knowing because it is the number a
monitoring probe would have alarmed on.

**The mechanism is now explained, which measurement 6 could not do.** T18 recorded that one PCR per PES
unit on a 25 fps clip should give a ~40 ms cadence and could not account for 36/s at 11 µs spacing. The
PR names it: on reordered content the authored decode clock is a saw, a reference frame leaps a whole
reorder span ahead and each B-frame that dips below the clock is nudged exactly **one 90 kHz tick —
11.1 µs** — past the previous DTS. That is the 11 µs median, arrived at from the code rather than from
the distribution, and it closes the one loose end in that measurement.

## Measurement 2 — the byte stream: the clustering changed domain rather than going away

The PCR *values* are a perfect grid. Their *positions among the exported bytes* are not.

| gap between consecutive PCR packets, in packets | share |
|---|---:|
| **1 — back-to-back** | **87.2 %** (2,155) |
| 2–8 | 0.7 % (17) |
| 9–200 | 0.2 % (6) |
| **> 200** | **11.9 %** (294) |

The back-to-back packets arrive in bursts: 13 at most, and 192 of the 294 bursts are 10 or longer. The
gaps on the other side of them run to **2,730 packets, which is 411 ms of carrier** at the 10 Mb/s the
groomer runs. Put beside measurement 1, that is the same bimodal shape the original defect had — dense
runs separated by long holes — with the two domains swapped: it was clustered values at even positions,
it is now even values at clustered positions.

**This is not a bug in the fix so much as the limit of where the fix can reach.** #2967 returns each PCR
as its own output `Frame` stamped at its slot boundary, precisely so a caller's pacer can deliver it at
the time it asserts. The mechanism is sound and it depends entirely on the caller honouring frame
timestamps. `moq export ts` has one output — stdout — and one option, `--latency-max`. A byte stream
carries no timestamps, so **the spacing the fix computes is discarded at the exporter's only public
interface**, which is also the interface every MPEG-TS toolchain in this campaign and in the industry
attaches to.

The consequence is that the exported stream is internally inconsistent as a transport stream. Thirteen
PCR packets sitting back-to-back while their values advance 25 ms apart assert that 2,444 bytes take
325 ms to arrive — a 60 kb/s mux — inside a stream whose other bytes run at 9.57 Mb/s. Measured against
byte position, **every PCR in the fixed stream misses by a constant 24,842 µs** (`pcrverify --absolute`:
0 of 2,472 OK), where the control missed by varying amounts (48 of 2,123 OK). A constant error is the
better failure — it is arithmetically repairable and a varying one is not — but it is not a pass, and
P2 on a rate-less media-aware egress remains the undefined measurement this campaign has always said it
is.

## Measurement 3 — the groomer: the lane is worse than before the fix

Two groomers, both fed the captured exporter output, file domain, no timing involved.

| | control export | **fixed export** |
|---|---:|---:|
| **`mpegts-pacer`, `regenerate` at 10 Mb/s** | | |
| Input packets | 390,918 | 393,311 |
| Content placed | 390,918 | 212,825 |
| **Dropped** | **0** | **180,486 (45.9 %)** |
| Stuffing | 4.2 % | 56.5 % |
| Continuity errors out | **0** | **849** |
| Intervals > 40 ms out | **0** | 172 (6.20 %) |
| Max interval out | 34.1 ms | 410.6 ms |
| **`tsp -P pcradjust`** *(off the shelf)* | — | |
| Continuity errors out | — | 0 |
| Intervals > 40 ms out | — | **293** |
| Intervals < 1 ms out | — | **2,172 (87.9 %)** |
| Max interval out | — | 430.3 ms |

**`tsp -P pcradjust` reproduces the original defect almost exactly, and that is the finding.** It
re-stamps PCR from byte position, so it converts clustered positions straight back into clustered
values: 87.9 % of its output intervals are sub-millisecond against the 87.2 % of input PCR packets that
sit back-to-back. The two figures are the same measurement seen from either end. **A fix that does not
survive the stage it exists to enable has not yet reached the requirement it was filed against** — and
T13's whole point was that grooming is where this lane's conformance has to be recovered.

**Our own groomer fails differently and worse.** `mpegts-pacer` byte-locks placement: it treats a PCR as
a statement about where on the timeline the following packets belong, spreads each inter-PCR run across
the slots between them, and spills a peak into the slots after it. That model is correct for a
conformant TS and is what makes two independent groomers byte-identical, which is the whole basis of
[T12](test-12-dual-path-handoff.md)'s ST 2022-7 result. Handed a stream where 13 PCRs claim 325 ms at one
byte position, it computes a grid 166 slots wide for a run of one packet and then a run of ~1,300
packets for the same width, so the placement queue backs up by the difference on every media frame and
overflows. **It is structural, not a buffer size**: raising the carrier to 12 Mb/s still drops 165,468
packets and pushes stuffing to 63.7 %.

## Measurement 4 — end to end on the wire, which is the number that counts

[`t18-arm.sh`](scripts/t18-arm.sh) unaltered, `moq` arm, 250 ms cushion, 90 s, both builds.

| | control (`0.9.10`) | **fixed (`#2967`)** | T18's recorded baseline |
|---|---:|---:|---:|
| Pictures matched | 3,111 / 3,111 | 1,990 / 1,990 | — |
| Delivery latency, median | **118.3 ms** | **768.7 ms** | 127 ms |
| Delivery latency, max | 231.3 ms | 911.6 ms | — |
| Continuity errors | **0** | **824** | 0 |
| PCR jitter > 481 ns | **0** | **53** | 0 |
| Repetition > 40 ms | 488 / 3,246 | 341 / 3,296 | 490 / 3,249 |
| Max interval | 228.0 ms | **375.1 ms** | 228.0 ms |

**The control reproduces T18's recorded figures to within noise** — 488/3,246 against 490/3,249, an
identical 228.0 ms maximum — which is what licenses reading the second column as an effect of the build
rather than of the rig.

And on that column the lane fails three of the four pass criteria it previously passed. Repetition
improves (488 → 341) because the exporter is now feeding the groomer a better clock, but it does not
approach the gate, the worst interval gets **65 % worse**, continuity goes from clean to 824 errors, and
delivery latency — the axis the entire case for this lane rests on — degrades **6.5×**. Criterion 4 was
written to catch exactly this.

## Conclusion

**The fix is right, complete, and does not yet help.** Judged as what it says it is — a change to how
`moq export ts` places PCR — it is unimprovable: an exact 25 ms grid, the clustering gone, the reserved
bits corrected, the continuity discipline observed, the mechanism explained, and a defect we never
found repaired along the way. Judged against the requirement #2937 was filed under — that a downstream
CBR stage be able to produce a conformant wire — it has moved the obstruction rather than removed it.

**What changed is which stage the defect lives upstream of.** Before, the exporter's PCR *values* were
unusable and no groomer could repair them. Now the values are perfect and the *positions* are unusable,
which breaks a byte-locking groomer outright and lets a re-stamping groomer regenerate the original
distribution from scratch. The reason is a single interface fact: the spacing exists as per-frame
timestamps inside the muxer, and stdout does not carry them.

**So the remaining ask is small and specific, and it is not a re-litigation of #2937.** Either the
exporter's stdout writer paces its output — placing each frame at the time the frame already says it
belongs, which is information it has and discards — or it emits the PCR packet adjacent to the media
bytes of the slot it labels, so position and value agree for a consumer that has only bytes. The first
is the better fix and matches what a hardware IRD expects off a wire; the second needs no timing at all.
This is the same class of defect as
[#2978](https://github.com/moq-dev/moq/issues/2978), which the maintainer's own adversarial review of
#2967 raised against the SRT egress: a frame's pacing timestamp lost at the boundary where bytes are
handed on. Ours is that defect at the stdout boundary, where it is total rather than bounded by one chunk.

**One conclusion is unaffected and worth stating plainly.** The 40 ms repetition gate is now reachable
on this lane — the clock arriving at the edge is even for the first time, and T18's prediction that an
evenly spaced exporter cadence would clear the gate at the depth the lane already runs is still the
open question, not a refuted one. What T19 establishes is that reaching it needs one more change on the
exporter's output path, and that until then the deployable configuration is the pre-fix build.

## Limits

- **One clip, one rig, one window.** 60 s exporter captures and 90 s end-to-end arms on loopback, on a
  single 1080i25 H.264 contribution capture. The grid result is exact and would be hard to make less so,
  but the *effect size* of the original defect varied by clip (0 % to 25.2 % of intervals above 40 ms),
  so the positional-bunching figures should be read as this clip's shape and not as a constant.
- **The end-to-end arm was run at one cushion**, 250 ms. That is the deployable one and the one T18's
  ladder shows to be representative, but a regression measured at one rung is not a ladder.
- **The reserved-bit and continuity-discipline checks are new instruments**, written for this experiment.
  They were validated in the only way available — the control build reads `0x00` and the fixed build
  `0x3F`, which is the documented change — and not against an independently damaged fixture.
- **`moq import ts` round-tripping the new export is not tested.** The PR claims it, our chain never does
  it, and nothing here confirms or denies it.
- **P2 accuracy on a rate-less egress remains undefined** as a verdict; only the constant-versus-varying
  shape of the error is used, and only as a diagnostic.

## Corrections

- **Believed:** the PCR defect was wholly upstream of the groomer, so fixing the exporter's placement
  would let the existing edge stage produce a conformant wire. **True:** the exporter and its *output
  interface* are separate stages, and fixing placement inside the muxer moved the defect to the
  interface. **Method rule:** when a defect is attributed to a component, name the boundary the
  measurement was taken at, because a fix verified inside that boundary can be invisible outside it.
- **Believed:** a verified upstream fix is safe to adopt. **True:** this one regresses the chain it was
  meant to repair, on continuity and on latency, and only an end-to-end arm showed it. **Method rule:**
  grade an upstream fix on the deployed chain and not only on the claim it makes; the claim was true.
- **Believed:** `pcrverify --absolute` failing on a media-aware egress carries no information, since the
  egress has no mux rate. **True:** it carries the *shape* of the failure, and constant-versus-varying
  error is the difference between a groomer-repairable stream and an unrepairable one. **Method rule:**
  an undefined measurement can still be a usable diagnostic if the statistic read is the distribution
  rather than the verdict.

## References

- Upstream: [#2937](https://github.com/moq-dev/moq/issues/2937) (the report, closed by the fix),
  [#2967](https://github.com/moq-dev/moq/pull/2967) (the fix, merged `61678fd32`),
  [#2978](https://github.com/moq-dev/moq/issues/2978) (the same class of defect on the SRT egress).
- Diagnosed in [test-18-delivery-latency.md](test-18-delivery-latency.md) measurement 6; the gate is
  [test-13-downstream-grooming.md](test-13-downstream-grooming.md) criterion 3.
- The byte-locking model the fix breaks is [test-12-dual-path-handoff.md](test-12-dual-path-handoff.md).
- Findings destination: [`docs/evidence.md`](../docs/evidence.md) §3.2.

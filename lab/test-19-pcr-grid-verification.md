# T19 — the PCR grid, and reconstructing a CBR wire from a media-aware source

> **State:** complete. [#2967](https://github.com/moq-dev/moq/pull/2967) graded on the laptop rig;
> [#3006](https://github.com/moq-dev/moq/pull/3006) on the EC2 primary, where the *time* domain is
> measurable and the file domain is not; [#3351](https://github.com/moq-dev/moq/pull/3351) on the merged
> build (measurement 10); and the downstream reconstruction that the merged build left to be done, on
> the live wire and on three sources of differing burstiness (measurement 11).
>
> **Four domains, and the last one is ours.** #2967 put the PCR *values*
> on a flawless grid — every interval exactly 25.000 ms, 0 above the 40 ms P1 gate, the 85 %
> sub-millisecond clustering gone — and repaired a reserved-bit defect this campaign never found. It did
> not move the PCR packets' *positions in the byte stream*, which stayed bunched, and because
> `moq export ts` writes to stdout the grid was unobservable to every consumer.
> [#3006](https://github.com/moq-dev/moq/pull/3006) closed that boundary by making the export a
> real-time pipe: it paces each write on the frame's timestamp, so the spacing now reaches a consumer as
> *arrival time*. Measured at the pipe, that **halves the P1 gate failures (18.26 % → 7.45 %) and
> doubles the on-grid fraction (27.4 % → 56.9 %), with the median interval at 24.69 ms**.
>
> **It is a large improvement and it is not a pass.** 7.45 % of intervals still exceed 40 ms, to a worst
> case of 277 ms, and 28.9 % arrive in a sub-millisecond burst — the distribution is now bimodal rather
> than merely wrong, with roughly three stalls a second each followed by a burst of about four PCRs.
> **That residue is the exporter's, not the instrument's:** the same arm on four times the cores returns
> the same 7.45 % at zero CPU pressure, and the errors run 4.6:1 *early*, which no starved reader
> produces. **Its cause is located** — the PCR grid is advanced by media-frame arrival rather than by the
> passage of media time, so a backfilled run of slots falls due only once the frame that proves they
> elapsed has landed, by which point every one of them is already late to write. The clustered positions
> and the bursty releases are then one phenomenon and not two: 615 of the 626 early releases are exactly
> the byte-adjacent packets (measurement 7).
> **The byte-stream positions are unchanged and cannot be changed by a timing fix**, so any downstream
> stage that re-derives PCR from byte position still reproduces the original defect: off-the-shelf
> `tsp -P pcradjust` yielded 293 intervals above 40 ms and 87.9 % sub-millisecond, and our own
> byte-locking groomer dropped 45.9 % of content. What #3006 buys is a lane whose cadence is recoverable
> by a stage that reads the pipe in real time; what it does not buy is a conformant wire.
>
> **The residue was filed as [#3334](https://github.com/moq-dev/moq/issues/3334)** with the invariant
> stated as a requirement rather than an implementation, and the instrument this experiment should have
> had from the start is offered upstream as
> [#3335](https://github.com/moq-dev/moq/pull/3335) (test tooling only). The half of the defect that is
> *ours* — a groomer that read source PCR value cadence and positional cadence as interchangeable — is
> fixed and guarded in `mpegts-pacer` (measurement 8).
>
> **The positional ask was granted and [#3351](https://github.com/moq-dev/moq/pull/3351) has merged.**
> At the pipe the fix is everything it claims: adjacency **87.2 % → 0.0 %**, releases outside ±10 ms
> **2/4,779** at a p95 of **1.70 ms**, and upstream's own gate passes on the merged build. On the wire it
> *wins* content against #3351's own merge-base — the byte-locking groomer drops **211,957 → 134,769**
> packets and stuffing falls **49.9 % → 28.8 %** — and on its own it does not reach the gate
> (measurement 10).
>
> **The residual was never upstream's to fix, and it is now fixed downstream.** #3351 places each slot's
> bytes at the media time the slot asserts, which is correct. But a coded frame's bytes belong to *its
> own* 40 ms however large the frame is, so a 417 kB I-frame lands as ~1,400 packets in one 25 ms slot —
> while the source's CBR mux had spread those same bytes over many frame periods against a T-STD buffer.
> **A media-aware lane cannot recover a mux schedule from decode timestamps, because the schedule was
> never in them.** The groomer has to build a new one, and measurement 11 establishes that it can:
> **the lane now passes all four criteria on the live wire.**
>
> **What was in the way was three defects in our groomer, not one property of the lane** — none of them
> visible on a source that arrives at its own mux rate, all three found by instrumenting rather than by
> raising the cushion. PCR re-insertion was *opportunistic*, taking only slots the content scheduler
> declined, and a burst declines nothing: every one of the 71 over-40 ms intervals in the graded output
> contained **zero** null slots. The media-rate estimator averaged per-interval *ratios* on intervals
> carrying 1 to 4,631 packets each, and read **23 % low**. And release was open-loop on that estimate, so
> the residual error integrated against uptime — **+1.8 s of delivery latency across 90 s**, then
> shedding. Pre-empting content for the PCR, estimating the rate as a ratio of sums, and closing the
> release loop on buffer occupancy fixes all three.
>
> **On the same 90 s live arm, at an unchanged cushion, cap and exporter budget:** continuity errors
> **527 → 0**, groomer drops **109,516 → 0**, PCR intervals over 40 ms **432/3,882 → 0/5,892** (worst
> **286.2 → 30.1 ms**), stuffing **32.1 % → 13.4 %**, and median delivery latency **4,181 → 2,447 ms**.
> Over a 300 s arm: **0 dropped, 0 continuity errors, 0 underruns, 0/20,193 intervals over 40 ms, exact
> 10,999,999 b/s CBR, 0 PCRs outside ±500 ns**, buffer flat at 1.26 s. **The media-aware lane produces a
> conformant CBR wire.** Its price is buffering, and the buffer is content-dependent: it is set by the
> **peak coded frame**, not by the bitrate (measurement 11).
>
> **The ~480 ms standing lag is neither B-frame reorder depth nor the latency budget** — the ambiguity
> measurement 9 left open is closed. An otherwise-identical `bframes=0` clip still carries **428.6 ms**
> of it against `bframes=3`'s 481.2 ms, and moving `--latency-max` across 500 ms / 1 s / 2 s moves it
> between 428.6, 414.9 and 451.5 ms. It is a fixed filling offset of roughly 420–490 ms.
>
> **The instrument itself now has a test, which it did not when any of the above was measured.**
> `ts-pcr-fixtures.py` synthesises all nine PCR boundary conditions and `ts-pcr-selftest.py` asserts the
> verdict each must produce, 38 assertions. **The 33-bit wrap is placed 400 ms into a fixture** rather
> than soaked 26.51 h for, which is what the eventual 72-hour hardware run needed to avoid a 27-hour
> preliminary. Building it found two further analyser defects, both of it failing conforming input
> (corrections).

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

**Measurement 10 (the merged #3351) ran on the laptop rig**, all arms in one session so the four builds
are the only variable.

| | |
|---|---|
| **Build under test** | `moq 0.10.0-f8236680b` — `origin/main` carrying #3351's merge `4cf216149`, pinned to `~/bin-3351/` |
| **Isolating control** | `moq 0.10.0-8ed756a31` — #3351's own merge-base (`4cf216149^`), pinned to `~/bin-3351base/` |
| Prior controls | `~/bin-2967` (`0.9.12-61678fd32`) and `~/bin-main` (`0.9.10-eab960192`) |
| Groomer | `mpegts-pacer` 0.1.0 at `71e242d`, the build carrying the positional guard |
| B-frame control clips | 140 s, upstream's own ffmpeg line, `bframes=3` and `bframes=0`, `has_b_frames` 2 and 0 |
| Graders | upstream's `test/ts/pcr-timing.py` (merged by #3351), plus this repository's `t19-pcr-grid.sh`, `t19-pcr-positions.py` and `ts-pcr-timing.py` |

**Measurement 11 (the downstream reconstruction) also ran on the laptop rig**, against the same merged
`~/bin-3351` exporter throughout, so the groomer is the only variable in the before/after and the source
is the only variable in the content-dependence arms.

| | |
|---|---|
| Exporter | `moq 0.10.0-f8236680b` (`~/bin-3351`), `--latency-max 500ms`, unchanged across every arm |
| **Groomer under test** | `mpegts-pacer` at `64595f6` |
| **Groomer control** | `mpegts-pacer` at `71e242d`, the build measurement 10 used |
| Sources | `~/CNNiEMEA2.ts`; `burst-moderate.ts` and `burst-high.ts` from [`t19-make-burst-sources.sh`](scripts/t19-make-burst-sources.sh) |
| Rigs | [`t18-arm.sh`](scripts/t18-arm.sh) unaltered for the wire; [`t19-cushion-sweep.sh`](scripts/t19-cushion-sweep.sh) for the file domain; [`t19-frame-burst.py`](scripts/t19-frame-burst.py) for the source burst profile |
| Window | 90 s per wire arm, plus one 300 s arm; 20 s export capture for the file sweep |
| Mux rate | 11,000,000 b/s on every arm |

**Measurements 5 and 6 (#3006) ran on the EC2 primary**, not the laptop, because #3006 is a fix to
release timing and the time domain needs a host that is not also running the operator's desktop.

| | |
|---|---|
| Rig | EC2 primary, `c6in.large` (2 vCPU / 3.8 GB), Ubuntu 26.04, loopback |
| **Build under test** | `moq 0.9.15` / `moq-relay 0.14.14` — the release pair, both ancestors of #3006's merge `489e3647` |
| **Control build** | `moq 0.9.11-eab96019` / `moq-relay 0.14.11-eab96019`, the on-box source build, which predates #2967 |
| Rigs | [`t19-arrival.sh`](scripts/t19-arrival.sh) + [`t19-pcr-arrival.py`](scripts/t19-pcr-arrival.py) for the time domain; [`t19-pcr-positions.py`](scripts/t19-pcr-positions.py) for byte position; [`ts-pcr-timing.py`](scripts/ts-pcr-timing.py) for all three at once; [`t18-arm.sh`](scripts/t18-arm.sh) unaltered end to end |
| Window | 60 s file captures, 45 s arrival captures, 90 s end-to-end arms |

**Measurement 7 ran on the EC2 secondary** — `c6in.2xlarge`, 8 vCPU, eu-west-1b, Ubuntu 26.04, the same
TSDuck 3.44-4676 build installed from the same `.deb`, and the primary's own binaries and clip copied
across (MD5-verified) so the host is the only variable. The box carried no other work.

There is **no middle arm on this platform**, and it is not for want of trying: `moq-cli-v0.9.12` was
tagged ten minutes *before* #2967 merged and so does not contain it, and `v0.9.13`/`v0.9.14` are tags
with no published binaries and both postdate #3006. A #2967-only arm on Linux would need a source build
at `61678fd32`; measurement 6's attribution comes from the laptop rig's #2967 numbers instead, and the
comparison is stated as cross-platform where it is used. The loop publisher was stopped for every arm
here, since its `ffmpeg -re` is CPU noise landing directly on a timing measurement.

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

Two groomers, both fed the captured exporter output, file domain, no timing involved. *Read the 45.9 %
with the cushion correction at the end of this file: the loss is bounded and a groomer buffered past the
displacement recovers it. Measurement 10 re-runs this table against the merged #3351.*

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

[`t18-arm.sh`](scripts/t18-arm.sh) unaltered, `moq` arm, 250 ms cushion, 90 s, both builds. *Measurement
10 re-runs this against the merged #3351 and its own merge-base.*

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

## Measurement 5 — #3006: the ask was granted, and it moved the gate without clearing it

[#3006](https://github.com/moq-dev/moq/pull/3006) is the fix measurement 2 asked for. `run_ts` now
sleeps until each frame's paced instant before writing, on a `Pacer` extracted into `moq-mux`, with a
`with_lead` budget of `--latency-max` for stdout. Run on the EC2 primary — Linux, two vCPU, both arms
back to back under identical load — against the on-box pre-#2967 build as the control.

**The file domain cannot grade it, and that is the first thing to get right.** #3006 changes *when* the
bytes are released, not where they sit in the stream. Capturing the export to a file flattens exactly
the timing the fix creates, so a positional histogram of the capture measures the mux layout and says
nothing either way about pacing. It confirms the layout is untouched, as it must be:

| domain | pre-#2967 (0.9.11) | post-#3006 (0.9.15) |
|---|---:|---:|
| PCR value interval, mean / min / max | 28.959 / 0.011 / 319.9 ms | **25.000 / 25.000 / 25.0 ms** |
| values above the 40 ms gate | 9.89 % | **0 %** |
| positional gap, median | 116 packets | **1 packet** |
| positionally back-to-back | 0 % | 69.3 % |
| PCR carriage | adaptation+payload | adaptation-only |
| reserved bits | `0x00` | **`0x3F`** (conformant) |
| continuity events | 0 | 0 |

So the positional bunching persists, and no timing fix could have removed it. Reading a positional
result as a verdict on #3006 would have been the same category error measurement 2 diagnosed, one
domain further on.

**Do not read 87.2 % → 69.3 % as an improvement.** Measurement 2's figure is macOS on `0.9.12`; this one
is Linux on `0.9.15`, and there is no #2967-only arm on this platform to sit between them. The two
numbers agree that the layout is bunched and differ by an amount this experiment cannot apportion
between platform, build and clip. The within-platform comparison is the control column, where PCR rode
payload packets and so was naturally spread — a median gap of 116 packets against the fixed build's 1.

**The time domain is where the fix lives.** [`t19-arrival.sh`](scripts/t19-arrival.sh) pipes the export
live into an oracle that timestamps every PCR-bearing packet as it arrives, at 188-byte read
granularity, so a write burst reads as a run of sub-millisecond intervals and a paced write reads as the
interval it was paced to. 45 s per arm:

| PCR inter-arrival at the pipe | pre-#2967 (0.9.11) | post-#3006 (0.9.15) |
|---|---:|---:|
| mean / median | 26.64 / 21.46 ms | 24.84 / **24.69 ms** |
| on the grid (22–28 ms) | 27.4 % | **56.9 %** |
| above the 40 ms P1 gate | 18.26 % | **7.45 %** |
| arrived in a burst (< 1 ms) | 1.48 % | 28.88 % |
| worst interval | 232.5 ms | 277.1 ms |
| standard deviation | 31.47 ms | 36.65 ms |

**The fix works, and the gate still fails.** The median interval is now within 0.31 ms of the grid and
the on-grid share doubles, which is the pacing arriving as designed. But the standard deviation *rises*,
because the distribution has become bimodal rather than uniform: a large correct mode at 25 ms plus a
burst mode below 1 ms, with 7.45 % of intervals still over 40 ms to a worst case of 277 ms. The residue
has structure — roughly 135 stalls across the 45 s window, about three a second, each followed by a
burst of about four PCRs — which is the shape of a per-group flush rather than of random jitter, and
points at the group boundary as the remaining source.

**The measurement's own ceiling had to be stated, and measurement 7 removes it.** The oracle is a Python
reader on a two-vCPU host sharing the box with `tsp`, the importer, the relay and the export, so a
scheduling delay in the reader is indistinguishable from a late write. Both arms ran under the same
load, so the *comparison* always held; the absolute 7.45 % was read as an upper bound until the arm was
re-run on four times the cores, which it now has been.

## Measurement 6 — end to end with #3006: the deployed chain is unchanged

[`t18-arm.sh`](scripts/t18-arm.sh) unaltered, `moq` arm, 250 ms cushion, 90 s, on the EC2 primary, both
builds back to back with the loop publisher stopped.

| moq arm, 250 ms cushion | pre-#2967 (0.9.11) | post-#3006 (0.9.15) |
|---|---:|---:|
| pictures matched | 3,112 / 3,112 (100 %) | 1,993 / 1,993 (100 %) |
| delivery latency, median | **120.0 ms** | **771.6 ms** |
| min / p95 / max | 35.2 / 191.0 / 243.0 ms | 643.1 / 799.9 / 916.2 ms |
| continuity errors | **0** | **1,166** |
| PCR repetition > 40 ms | 487 / 3,248 (15.0 %) | 349 / 3,315 (10.5 %) |
| worst repetition interval | 228.0 ms | 392.7 ms |
| PCR jitter > 481 ns | 0 | 0 |

**This reproduces the #2967 regression rather than relieving it**, and it reproduces it closely enough
to settle where the regression comes from. The laptop rig measured 118 → 769 ms and 0 → 824 continuity
errors on #2967 *alone*, a build with no output pacing in it whatsoever. This run measures 120.0 →
771.6 ms and 0 → 1,166 on a build that paces. Two platforms, two builds, one number: the latency
regression is a property of the positional clustering meeting a groomer, and **#3006 neither causes nor
cures it.** That also disposes of the reading the timing was inviting — that the export's new lead
budget is what buys the extra 650 ms — because the arm without a lead budget had already paid it.

The one thing that does move is repetition, from 15.0 % of intervals over the gate to 10.5 %: the
groomer, fed a stream that now *arrives* on a cadence, regenerates a slightly better one. It is an
improvement of the kind that matters only if it reaches zero, and it does not.

## Measurement 7 — the residual is the exporter's, and both failures have one cause

Measurement 5 left two things open: whether the 7.45 % was the exporter or a two-vCPU host, and what the
residue's structure meant. Both are now settled, on the eight-vCPU secondary (`c6in.2xlarge`,
eu-west-1b), with the primary's binaries copied across so only the host changes, and with the same 45 s
window and the same publisher.

| PCR inter-arrival at the pipe, post-#3006 | 2 vCPU (primary) | **8 vCPU (secondary)** |
|---|---:|---:|
| above the 40 ms P1 gate | 7.45 % | **7.45 %** |
| on the grid (22–28 ms) | 56.9 % | 54.6 % |
| median | 24.69 ms | 24.62 ms |
| p95 / p99 | — | 102.80 / 227.31 ms |
| worst interval | 277.1 ms | 283.5 ms |
| host `%idle` during the arm | — | 92.8–97.5 % |
| `/proc/pressure/cpu` `some avg10` | — | **0.00 throughout** |
| reader's involuntary preemptions | — | **6 in 45 s (0.1/s)** |

**The gate metric is identical to two decimal places on four times the cores**, with zero CPU pressure
and a reader that was preempted six times while 135 gate failures occurred. The pre-#2967 control moves
just as little (18.26 % → 18.38 %). The residual is the exporter's.

**A second, independent argument says the same thing, and it does not depend on the host at all.** A
starved *reader* lengthens one interval and shortens the next, so it produces late and early intervals
in balance. Graded against each PCR's own asserted interval rather than against a nominal 25 ms, the
post-#3006 arm is **626 early against 136 late** — a 4.6:1 asymmetry that no reader artefact produces.

**Grading against the stream's own values is the instrument this experiment should have had from the
start**, and it is now [`ts-pcr-timing.py`](scripts/ts-pcr-timing.py): one pass over the pipe, three
independent verdicts, no reference clock and no declared mux rate. It is also checked in the direction
that matters for a gate — **a real contribution capture that never went through moq passes every
check** (1,318 PCRs, median interval 24.648 ms, worst 24.951 ms, 0 % adjacent at a median gap of 163
packets), while the same command over a pre-#2967 export capture fails `pcr-value-interval` alone at
the characteristic 0.011 ms median. Each build fails a different pair, which is what makes it a test of
the defect rather than of an implementation:

| | value | release | position |
|---|---|---|---|
| pre-#2967 (`0.9.11`) | FAIL (156/1,689 over 40 ms, median 0.011 ms) | FAIL (1,076/1,689; 919 late) | **PASS** (0 % adjacent, median gap 116) |
| post-#3006 (`0.9.15`) | **PASS** (0/1,811, median and max 25.000 ms) | FAIL (762/1,811; 626 early) | FAIL (56.5 % adjacent, median gap 1) |

**And the two remaining failures are one phenomenon.** Cross-tabulating each interval's release error
against its byte gap, in the same pass:

| | early | on time | late |
|---|---:|---:|---:|
| **adjacent** | **615** | 408 | 0 |
| **spaced** | 11 | 641 | **136** |

98 % of the early releases are the byte-adjacent ones and every late release is a spaced one. As a
sequence: the grid stalls once at a spaced position, then the backfilled run drains at once as a burst
of adjacent, early packets — ~136 stalls in 45 s, about three a second, ~4.6 PCRs a burst. The 408
`adjacent + on time` cells are the slots whose instant had not yet passed, where #3006's pacer *did*
sleep; that is the fix working, on the minority of slots where the information it needs still exists.

**The mechanism is in the code, and it is one line's consequence.** `Export::poll_next` calls
`write_pcr(timestamp)` with the timestamp of the *next pending media frame*, and `write_pcr` refuses any
slot at or below `slot(that timestamp)`. `pick_next_track` only considers tracks that already hold a
`pending` frame. So the grid can never advance past the media that has arrived: **the clock is a
function of frame arrival, not of the passage of media time**, and it cannot lead the media it exists to
lead. When a group lands and the minimum pending timestamp jumps, every intervening slot falls due at
once, each correctly stamped at an instant that has already elapsed — so `Pacer::pace` returns a
`send_at` behind `now` and the sleep is a no-op. Positionally the same emission model does the rest:
`write_frame` packetizes a whole media frame into one `Frame` payload written by one `write_all`, so a
PCR packet can only ever be placed *between* media frames and never among the bytes of the slot it
labels.

This retires the "group-boundary flush" hypothesis measurement 5 offered, in favour of a located cause,
and it means **neither remaining failure can be fixed by a timing change**: the position needs a finer
emission unit, and the release needs the grid to stop being gated on arrival. The upstream package is
drafted in [`docs/upstream/pcr-output-position.local.md`](../docs/upstream/pcr-output-position.local.md).

**One further reading, offered as a code reading and not as a measurement.** The same `pick_next_track`
dependence on `pending` is what
[#2829](https://github.com/moq-dev/moq/issues/2829) reports as audio/video interleave decided by arrival
timing. If that holds, #2829 and the positional ask want one change rather than two, and
[#2779](https://github.com/moq-dev/moq/issues/2779)'s continuity numbering is a third face of the same
property — output derived from process state rather than from stream position. Untested here.

## Measurement 8 — what the positional defect does to a downstream groomer, and the guard for it

Measurement 3 recorded that the byte-locking groomer dropped 45.9 % of content on this lane. That was
graded as a *lane* result. It is also a defect in the groomer, and the two are separable: the exporter
places its PCR badly, and the groomer assumed it would not. Only the first belongs upstream
(#3334); the second is ours to fix, and this measurement is the fix's before/after.

The fixture is a post-#3006 export capture (`~/t19-pcrfix/exp-new/export.ts`, first 20 MB — 106,382
packets, 16.5 s, 9.581 Mb/s of content). **It passes every check an instrument can make from the values
alone**, which is what makes it the right regression case:

| `ts-pcr-timing.py` on the fixture | |
|---|---|
| `pcr-value-interval` | **PASS** — 0/660 over the 40 ms gate, median *and* worst 25.000 ms |
| `continuity` | **PASS** — 0 discontinuities |
| `pcr-position` | **WARN** — 86.67 % of PCRs byte-adjacent, median gap 1.0 packet, worst 2,730 |

Delivered at its media rate into the stream-clocked groomer at 11 Mb/s with a 300 ms cap — the
configuration a 1+1 pair uses. **Regulating the input is load-bearing:** piping the file in at disk speed
buries the positional defect under ordinary buffer overrun, which is a rig artefact and not the finding.

```bash
tsp -I file export.ts -P regulate --pcr-synchronous -O file - \
  | mpegts-pacer - 11000000 --stream-clock --max-latency-ms 300 [--require-pcr-position] >out.ts
```

| | before the guard | with `--require-pcr-position` |
|---|---|---|
| exit status | **0 — "done."** | **1**, `SourcePcrPosition`, 0.4 s in |
| content packets emitted | 32,455 of 106,382 | — |
| **content discarded as late** | **71,504 (67.2 %)** | — |
| stuffing | 72.4 % | — |
| output `continuity` | **FAIL — 106 discontinuities** | not produced |
| output `pcr-value-interval` | **FAIL — 43/533 over 40 ms, worst 263 ms** | not produced |
| positional displacement reported | 3,294 packets (**450 ms**), 85 overrun intervals | 2,541 packets (**347 ms**), 1 interval |

**The old behaviour is the bad one: it succeeds.** The groomer exited zero, reported a correct output
rate and a PCR grid exact by construction, and had thrown away two thirds of the programme and
introduced 106 discontinuities of its own. Nothing in its exit status, and nothing in a value-domain
check of *either* its input or its output, says which stage caused that. This is the same failure as
measurement 3 seen from inside, and 45.9 % against 67.2 % is the cap: a shallower buffer sheds more.

**The mechanism is that one PCR interval was being read as two things at once.** Stream clocking maps a
source PCR value to an absolute output slot, and then assumes the packets between two PCRs are about
what that interval's media time is worth at the locked rate. Every source that muxes as it encodes
satisfies that. The exporter does not: `write_frame` emits a whole coded frame as one payload and
stamps the clock between frames, so the values are a perfect grid while 86.67 % of the packets carrying
them are adjacent. Placement then runs ahead of where the bytes are, and content arrives for slots the
pacer has already emitted as stuffing. **Source PCR value cadence and source PCR positional cadence are
independent, and the groomer had them interchangeable.**

The guard makes that assumption a measured quantity rather than an implicit one. Each interval's
placement is compared against its own span; overruns are counted, and the high-water displacement is
kept. **The displacement, not the overrun count, is the discriminating statistic** — any VBR peak
overruns its own span, so a count is nearly always non-zero and says nothing. A peak's displacement is
bounded and returns on the next trough; a source whose positions do not track its values displaces
monotonically. Comparing displacement against `max_latency` is what makes the test correct rather than a
threshold: a displacement the cushion absorbs is a peak the pacer handles, and one past the cushion is
content that cannot arrive in time whatever else is configured. Default policy is `Report` — the
counters print with the stats and pacing continues, so no stream that worked before now fails; `Fail`
(`--require-pcr-position`) is for a contribution egress where a silently thinned feed is worse than
none.

**The displacement is the right order of magnitude for the damage seen elsewhere on this lane, and no
more than that.** 347 ms at the point the guard trips and a 450 ms high-water over the run, against
[T18](test-18-delivery-latency.md)'s 651 ms delivery-latency step on the fixed build. Same scale, which
is what a common cause predicts; not a quantitative match, and it is not offered as one — the two are
measured on different clips over different windows with different buffer configurations, so only the
order carries.

Five tests were added and all 81 pass ([`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer)):
three unit tests that a clustered source displaces the grid and is counted, that a rate peak is *not*
read as a positional defect, and that clustering does not break byte identity; and two integration tests
that a clustered source is refused under `Fail` and paced under `Report` when the buffer can absorb it.
**No existing test changed and byte identity was not weakened** — the byte-identity test is asserted on
the clustered source specifically, so the guard cannot be satisfied by relaxing placement.

## Measurement 9 — the positional ask, granted and verified at the pipe

**Objective.** [#3351](https://github.com/moq-dev/moq/pull/3351) claims to close
[#3334](https://github.com/moq-dev/moq/issues/3334) by slicing the TS export on the PCR grid rather than
on media frames. Verify it independently, against a control that isolates the change, and establish
whether the standing lag the design introduces is bounded.

**Environment.** Laptop rig, loopback relay, release profile, default `--latency-max` (500 ms). Upstream's
own live arm (`test/ts/run.sh --live`: an ffmpeg CBR clip with a 20 ms PCR, published through
`tsp -P regulate --pcr-synchronous --wait-min 5`), graded by `ts-pcr-timing.py --live`. The only variable
is the `moq` binary: #3351's head against **its own merge-base**, both built from one worktree and one
target directory, sharing a single relay binary.

**Procedure.** `TSC_MOQ=<arm> test/ts/run.sh --live`, at 20 s, 45 s and 120 s windows. Nothing else
timing-sensitive on the host.

**Results.**

| Check | merge-base | #3351 |
|---|---|---|
| `pcr-position`, share adjacent to the previous PCR | **50.31 %** | **0 %** (0.25 % on one run) |
| `pcr-release-timing`, intervals outside ±10 ms | **491/799** (356 early, 135 late) | **0 to 4 / 745** |
| release error p95 \| worst | **70.3 ms** \| 91.4 ms | **1.5 to 1.9 ms** \| 3.9 ms |
| `continuity` | 0 | 0 |
| `pcr-value-interval` | 25.000 ms | 25.000 ms |

The control reproduces #3334 as filed, down to its shape: **43.4 % of its PCR packets are both adjacent
to the previous one and released early**, which is the clustering and the no-op sleep appearing as one
quantity. On #3351 both are gone and all six checks pass.

**The standing lag is real, bounded, and converges.** Slicing on the grid makes the exporter run behind
the media clock by the depth of its mux buffer. Measured over 120 s (4,738 intervals), as drift
accumulated per tenth of the sample: **+232.8, +99.5, +115.1, +33.2** ms, then **−0.4, +0.5, −0.4, +1.0,
−0.3, +0.3**. The lag builds to **480 ms over the first ~48 s and then stops**, adding **+0.7 ms across
the remaining 70 s** (a tail rate of −0.017 ms/s), against a `--latency-max` of 500 ms. So it converges
just under the budget rather than merely being bounded by it in principle.

**The rig does not supply that ramp.** Grading the publisher alone, with no `moq` in the path, gives a
signed mean of **−0.019 ms** per interval and **±0.8 ms of drift per decile** across deciles 1 to 9, all
of its −42.9 ms total landing in two startup intervals. The lag is the exporter's, and by design.

**What this does not establish** is the wire. The measurement is at the pipe, on a single-rendition
generated clip, and the requirement #2937 was filed under is that a byte-locking groomer downstream
produce a conformant stream. Measurement 10 grades that.

## Measurement 10 — the merged build on the wire: content improves, the gate does not open

**Objective.** #3351 merged as `4cf216149`. Re-run measurements 3, 4 and 6 against a merged build and
decide the requirement, not the claim.

**Build provenance, because the PR head moved after measurement 9 graded it.** `origin/main`
`f8236680b` contains `4cf216149`; `git diff` over `rs/moq-mux/` between the merged head `9c870e64d` and
the merge commit is empty, and nothing has touched `rs/moq-mux/src/container/ts/` or `pace.rs` in `main`
since. The PR head measurement 9 tested was `87502b85e`, which was **force-updated** before merge — the
exporter itself is identical across that move, but the re-verification was run from `main` regardless.
Binaries pinned to `~/bin-3351/` (`moq 0.10.0-f8236680b`). Three controls, all measured in the same
session on the same host: `~/bin-main` (0.9.10, pre-fix), `~/bin-2967` (0.9.12), and — to separate
#3351 from eight weeks of unrelated `main` — **`~/bin-3351base/` (`0.10.0-8ed756a31`, #3351's own
merge-base**, `4cf216149^`).

**The merged build passes upstream's own gate**, which is what licenses reading everything below as a
property of our content rather than of our build. `test/ts/run.sh --live` at 120 s: release timing
**0/4,731** outside ±10 ms, p95 1.498 ms; `pcr-position` 0.04 % adjacent, median gap 4 packets, **worst
115**; drift 494.7 ms at −0.008 ms/s.

### The exporter on a real contribution clip

60 s captures, `~/CNNiEMEA2.ts`, [`t19-pcr-grid.sh`](scripts/t19-pcr-grid.sh) and
[`t19-pcr-positions.py`](scripts/t19-pcr-positions.py). The value domain is unchanged from #2967 and
still exact: 2,378 intervals, min = mean = max = 25.000 ms, 0 above 40 ms, 0 sub-millisecond, PCR on PID
111 only, adaptation-only packets, reserved bits `0x3F`, 0 continuity events.

| PCR byte position | #2967 | **merged #3351** |
|---|---:|---:|
| back-to-back (gap = 1) | **87.2 %** | **0.0 %** (1 of 2,432) |
| clustered (gap ≤ 5) | 87.9 % | 30.9 % |
| median gap | 1.0 packet | 7.0 packets |
| p95 \| worst gap | — \| 2,730 | 1,545 \| **4,641** |
| the same gaps as intervals, above 40 ms | 11.81 % | **11.14 %** |

**Adjacency is fixed and the gate figure is not**, and the second is the one a groomer feels. Upstream's
own clip gives a worst gap of 115 packets; ours gives 4,641. The mechanism is visible in the packet
sequence and in `Export::emit`: the exporter lays a span's bytes across the slots the span covers,
proportionally — which is right — but **a coded frame's bytes belong to its own 40 ms however large the
frame is.** Measured on this clip, 59.2 % of contiguous video runs exceed one 25 ms slot's worth of
bytes and carry 94.8 % of the video; the largest is 2,274 packets, 417 kB, **357 ms of carrier for
40 ms of media.** The source's CBR mux had spread exactly those bytes across many frame periods against
a T-STD buffer, and that schedule is not recoverable from decode timestamps because it was never in
them.

### Measurement 3 re-run — the file-domain groomers

Both groomers fed the merged export, 10 Mb/s, as before.

| | #2967 | **merged #3351** |
|---|---:|---:|
| **`mpegts-pacer` `regenerate`** | | |
| Dropped | 180,486 (**45.9 %**) | 156,886 (**40.8 %**) |
| Stuffing | 56.5 % | 50.6 % |
| Continuity errors out | **849** | **0** |
| Intervals > 40 ms out | 172 (6.20 %) | 176 (6.55 %) |
| Max interval out | 410.6 ms | 343.4 ms |
| **`tsp -P pcradjust`** | | |
| Continuity errors out | 0 | 0 |
| Intervals > 40 ms out | 293 | 287 (11.80 %) |
| Intervals < 1 ms out | **2,172 (87.9 %)** | **751 (30.88 %)** |
| Max interval out | 430.3 ms | 780.2 ms |

`pcradjust`'s sub-millisecond output tracks input adjacency down from 87.9 % to 30.9 %, which is the two
figures being one measurement seen from either end, as before. Neither groomer reaches the gate.

### The displacement is bounded, and sizing the buffer past it conserves the programme

The positional guard (measurement 8), same fixture size, same 11 Mb/s stream-clocked configuration.
Both arms are deterministic — two replicates returned the identical displacement to the packet.

| | #2967 | **merged #3351** |
|---|---:|---:|
| overrun intervals | 85 | 104 |
| **positional displacement** | 3,294 packets (**450 ms**) | 5,567 packets (**761 ms**) |

**#3351 makes the displacement worse, because moving the PCR packets off the media bytes and onto the
grid widens the gap they have to describe.** But it is bounded, and a cushion past it recovers
everything — which measurements 3 and 8 could not see, having been run at one cushion:

| cushion (stream-clocked, 11 Mb/s) | 300 ms | 800 ms | **1500 ms** | 2500 ms | 4000 ms |
|---|---:|---:|---:|---:|---:|
| content placed, of 106,382 | 18,248 | 21,452 | **105,959** | 105,714 | 105,714 |
| late drops | 84,508 | 84,930 | **423** | 668 | 668 |

At 1,500 ms the merged build conserves **99.6 %** of the programme with **0 continuity errors**, exact
CBR (`bitrate` = `pcrbitrate` = 11,000,004 b/s) and **0 PCRs outside ±500 ns**. The #2967 control
recovers there too, at 98.8 %. **The 45.9 % and 67.2 % losses recorded in measurements 3 and 8 were
therefore a cushion result as much as a lane result**, and the correction is at the end of this file.
What survives the buffer is the repetition gate: even at 1,500 ms the output carries **71/680 intervals
over 40 ms, worst 633 ms**.

### Measurements 4 and 6 re-run — end to end on the wire

[`t18-arm.sh`](scripts/t18-arm.sh) unaltered, `moq` arm, 250 ms cushion, 90 s, all in one session.
`--latency-max` is held at **500 ms** across the last two columns, because the rig's 3 s default lets
#3351's standing lag ramp for longer than the window and reads as unbounded growth when it is not
(corrections).

| | pre-fix `0.9.10` | #2967 `0.9.12` | merge-base `8ed756a31` | **merged `f8236680b`** |
|---|---:|---:|---:|---:|
| pictures matched | 3,112/3,112 | 1,993/1,993 | 2,103/2,103 | 2,493/2,493 |
| delivery latency, median | **119.9 ms** | 768.0 ms | **776.8 ms** | **2,126.2 ms** |
| first third → last third | −73.7 | −11.4 | −11.4 | −24.6 |
| continuity errors | **3** | 850 | 989 | **811** |
| PCR repetition > 40 ms | 489/3,245 (15.1 %) | 345/3,314 | 342/3,174 (10.8 %) | 402/3,290 (**12.2 %**) |
| worst repetition interval | 217.5 ms | 375.1 ms | 380.7 ms | 541.3 ms |
| groomer: content placed | 547,517 | 323,268 | 339,045 | **407,733** |
| groomer: dropped | **165** | 227,746 | 211,957 | **134,769** |
| groomer: stuffing | **4.1 %** | 50.1 % | 46.1 % | **28.8 %** |

**Against its own merge-base, #3351 buys content and pays latency.** The groomer drops 36 % fewer
packets, places 20 % more content and halves the stuffing — a real improvement, and the first movement
on content conservation this lane has had. Delivery latency goes the other way, 776.8 → 2,126.2 ms,
and the repetition gate does not open: 10.8 % → 12.2 %.

**Three of the four pass criteria fail against this groomer.** Criterion 1 (no intervals above 40 ms
after grooming) fails at 12.2 %. Criterion 2 (0 continuity errors) fails at 811. Criterion 4 (no
regression in delivery latency) fails at 18× the pre-fix control. Only criterion 3, continuity
discipline on payload-less packets, passes — as it has since #2967.

**All three failures are the groomer's, and measurement 11 removes them at an unchanged exporter.** This
row is retained because it is the control the reconstruction is measured against, not because it is the
lane's verdict.

### The B-frame control

Measurement 9 left open whether the ~480 ms standing lag is `Pacer::absorb` reading B-frame reorder
depth or a fixed filling offset. Two otherwise-identical 140 s clips, generated with upstream's own
ffmpeg line and differing only in `bframes`, graded by upstream's `pcr-timing.py --live` over 120 s:

| | `bframes=3` | `bframes=0` |
|---|---:|---:|
| drift | **481.2 ms** | **428.6 ms** |
| tail rate | +0.008 ms/s (converged) | +3.696 ms/s (still climbing) |
| releases outside ±10 ms | 3/4,779 | 1/4,782 |
| `pcr-position` median \| worst gap | 4 \| 115 | 19 \| 115 |

**Removing the reorder depth entirely leaves about 90 % of the lag**, and the `bframes=0` arm had not
finished converging when the window closed, so its asymptote is higher than the 428.6 ms shown. Nor is
it the latency budget: on the same `bframes=0` clip, `--latency-max` of 500 ms, 1 s and 2 s gives
**428.6, 414.9 and 451.5 ms**. The lag is a fixed filling offset of roughly 420–490 ms, and it is
neither of the two mechanisms that were in question. On our own clip it reads **494.1 ms at
−0.044 ms/s** — converged, and within 1 ms of upstream's generated clip.

## Measurement 11 — reconstructing the CBR schedule downstream

Measurement 10 left one question: the exporter is correct, the displacement is bounded, and a big enough
buffer conserves the programme — so what is left holding the repetition gate shut? The answer is not a
property of the media-aware representation. It is three defects in our own groomer, none of which a
source arriving at its own mux rate can expose.

### Why a bigger cushion recovers packets and never closes the gate

The graded 1,500 ms output from measurement 10, re-read for what sat *between* the PCRs:

| | |
|---|---:|
| PCR intervals over 40 ms (292 packets at 11 Mb/s) | 71 |
| …of those, intervals containing at least one null slot | **0** |
| …containing none | **71** |
| worst interval | 4,631 packets (633 ms), 0 nulls inside |
| stuffing across the whole output | 15.5 % |

**PCR re-insertion was opportunistic: it could only occupy a slot the content scheduler had declined.**
A media-aware export delivers a coded frame as one burst, so its groomed output has ample stuffing
*overall* and none at all *inside* a burst. The deadline therefore always fell where every slot was
spoken for, no spare slot appeared until the burst had drained, and the interval ran to the length of
the frame. No cushion shortens a frame, which is exactly why the sweep recovered content and left the
gate untouched.

### What the groomer has to work with, and what it does with it

At the point it schedules a packet the groomer holds: arrival time, the source PCR *value* and the slot
it implies, PES/frame boundaries (payload-unit-start), the PID and PSI structure, the continuity state,
its own target mux rate, and its buffer occupancy. That is sufficient — the output schedule is a
function of the target rate and the PCR deadline, and neither needs the source's byte schedule. Three
things were wrong with how it used them:

1. **PCR re-insertion waited for a spare slot** (above). It now **pre-empts**: a slot on the deadline is
   taken for the PCR whatever else wanted it, and the displaced content packet waits one slot in a
   deferral queue that drains at the next stuffing slot. The cost is one packet of carrier per PCR —
   0.34 % at a 40 ms limit and 11 Mb/s.
2. **The media-rate estimator averaged per-interval ratios.** That assumes each PCR interval carries a
   comparable number of packets. On the 20 s export the intervals sit on an exact 25.0 ms grid and carry
   **1 to 4,631 packets each, median 8**, so the per-interval rates have a **median of 320 pps against a
   true 6,191**. The smoothed average sat far below the truth for most of its life: the groomer reported
   **7,135,067 b/s** against a real **9.31 Mb/s**, a 23 % under-read, and released media 21 % too slowly
   while the wire ran a third stuffing. Summing the packets and the media seconds over a 2 s window and
   dividing **once** is unbiased however the packets fall between the intervals; the same run then reads
   **9,142,408 b/s**.
3. **Release was open-loop on that estimate.** `rate × elapsed` integrates every error in `rate` against
   *uptime*, so a 2.5 % under-read costs 2.5 % of the run in buffer depth. Measured: **+1,792.9 ms of
   delivery latency across a 90 s window** and 10,279 packets shed once the bound was reached, at a
   bound the burst did not need. Trimming the release rate by the buffer's distance from the cushion
   bounds it, and the loop settles where occupancy equals the cushion — which is by definition where the
   groomer is releasing at the rate it is being delivered.

None of the three needs information the media-aware representation does not carry.

### The ablation, on the wire

[`t18-arm.sh`](scripts/t18-arm.sh) unaltered, `moq` arm, 90 s, 1,000 ms cushion, `--latency-max 500ms`,
11 Mb/s, the merged `~/bin-3351` exporter throughout. Each row adds one change to the row above.

| groomer | cap | continuity errors | PCR > 40 ms | worst | groomer drops | stuffing | median latency | trend |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| control `71e242d` | 1,500 ms | 736 | 394/3,354 (11.7 %) | 401.6 ms | 118,979 | 33.6 % | 3,046.6 ms | −23.4 |
| control `71e242d` | 2,500 ms | 527 | 432/3,882 (11.1 %) | 286.2 ms | 109,516 | 32.1 % | 4,181.3 ms | +0.8 |
| + PCR pre-emption | 1,500 ms | 727 | **0/4,901** | **30.1 ms** | 116,274 | 32.1 % | 3,051.1 ms | −25.0 |
| + ratio-of-sums rate | 2,500 ms | 60 | **0/5,931** | **30.1 ms** | 10,279 | 16.3 % | 3,949.6 ms | **+1,792.9** |
| + occupancy loop | 2,500 ms | **0** | **0/5,892** | **30.1 ms** | **0** | 13.4 % | **2,447.3 ms** | +293.5 |

Each change is separately attributable. Pre-emption alone closes the repetition gate and touches nothing
else — same continuity, same drops, same latency to within the run-to-run spread. The rate fix alone
recovers most of the content and exposes the open loop, which the latency trend then reports as a ramp.
The occupancy loop removes the ramp and the last of the loss.

### The passing wire

Same arm at 300 s, all three changes in:

| | |
|---|---:|
| pictures matched | **10,838/10,838 (100.0 %)** |
| continuity errors | **0** |
| PCR intervals > 40 ms | **0/20,193**, worst **30.1 ms** |
| PCR accuracy (`pcrverify --absolute`, ±500 ns) | **0 failures** |
| mux rate (`bitrate` = `pcrbitrate`) | **10,999,999 b/s** against a nominal 11,000,000 |
| PSI | PAT, PMT, NIT, SDT intact; 1 service, service name preserved |
| groomer drops / late drops / underruns / resyncs / stalls | **0 / 0 / 0 / 0 / 0** |
| stuffing | 12.8 % |
| max buffer occupancy | 9,235 packets (**1.26 s**) against a 2.5 s bound |
| median delivery latency | **2,466.1 ms** |
| latency trend across the window | +60.6 ms (from +293.5 ms over 90 s — converging, not ramping) |

**All four pass criteria are met.** Criterion 1 (no intervals above 40 ms after grooming): 0 of 20,193.
Criterion 2 (mux survives, 0 continuity errors): met. Criterion 3 (continuity discipline on payload-less
packets): met, as since #2967. Criterion 4 (no regression in delivery latency): the groomer's own
contribution falls, 4,181 → 2,447 ms at an identical configuration — though the lane's absolute latency
is still an order of magnitude above the 119 ms pre-#2967 control, which is #2967's regression and not
this stage's (measurement 6).

### The file-domain sweep, isolating the pre-emption

[`t19-cushion-sweep.sh`](scripts/t19-cushion-sweep.sh) on the same 20 s export, stream-clocked at
11 Mb/s. Stream clocking places by slot and does not use the media clock at all, so this arm grades the
PCR change alone; the two groomers were run at every cushion in the same session.

| cushion | conserved | continuity errors | PCR > 40 ms, control | PCR > 40 ms, fixed | worst, control | worst, fixed | max buffer |
|---|---:|---:|---:|---:|---:|---:|---:|
| 250 ms | 17.2 % | 0 | 1.22 % | 0.50 % | 847.3 ms | 557.6 ms | 5,082 |
| 500 ms | 21.2 % | 0 | 1.37 % | 0.16 % | 733.3 ms | 557.6 ms | 5,077 |
| 800 ms | 20.2 % | 0 | 1.55 % | 0.16 % | 733.3 ms | 646.4 ms | 6,028 |
| **1,000 ms** | **99.37 %** | 0 | 10.46 % | **0.00 %** | 633.2 ms | **30.1 ms** | 6,715 |
| 1,500 ms | 99.60 % | 0 | 10.44 % | **0.00 %** | 633.2 ms | **30.1 ms** | 6,946 |
| 2,000 ms | 99.37 % | 0 | 10.46 % | **0.00 %** | 633.2 ms | **30.1 ms** | 6,708 |

Conservation, continuity, buffer depth and late drops are **identical to the packet** between the two
groomers at every rung: the change costs 348 inserted packets and 0.3 pp of stuffing, and buys the gate.
The recovery point is between 800 ms and 1,000 ms, consistent with the 761 ms displacement. Below it the
arm is shedding 80 % of its content and resyncing, and the gate figure there is not meaningful — those
rungs fail on conservation.

> The accuracy column is graded with `pcrverify --bitrate 11000000` rather than against TSDuck's own
> estimate. On a rung that has shed most of its content the estimate lands tens of kb/s off nominal, and
> every PCR then fails against it — which reads as a PCR defect and is an artefact of grading the PCRs
> against a rate derived from the PCRs.

### Is the buffer requirement a property of the lane or of the content?

Two synthetic sources from [`t19-make-burst-sources.sh`](scripts/t19-make-burst-sources.sh), built to
differ in burst profile and in nothing else: both 1080p25, both 9.4 Mb/s CBR video with
`nal-hrd=cbr` in an 11 Mb/s mux at a 20 ms PCR, both with an MP2 audio track. What differs is GOP
length, B-frame depth, VBV size and content entropy — pushed the same way, so the peak-to-mean frame
size separates by a factor of eighteen while the mean rate does not move.

| | synthetic moderate | real 1080i25 clip | synthetic high |
|---|---:|---:|---:|
| structure | 0.5 s GOP, no B, 100 ms VBV | ~2 s open GOP, B-frames | 2 s GOP, 3 B, 3 s VBV |
| programme rate | 9.86 Mb/s | 9.49 Mb/s | 9.84 Mb/s |
| mean coded frame | 256 packets | 183 packets | 256 packets |
| p95 coded frame | 256 packets | 728 packets | 686 packets |
| **peak coded frame** | **256 packets** | **1,826 packets** | **4,562 packets** |
| peak / mean | 1.0× | 10.0× | 17.9× |
| peak frame as carriage at source rate | **39 ms** | **289 ms** | **697 ms** |
| reference CBR output | 0 continuity errors, 11,000,000 b/s, worst PCR 20.2 ms, 0 accuracy failures | — | 0 continuity errors, 11,000,000 b/s, worst PCR 20.2 ms, 0 accuracy failures |

Both synthetic references pass the same validation the real clip does before anything is done to them,
which is what makes them usable as ground truth. They are then published and exported through the same
merged MoQ chain; the reference file's byte schedule is never an input to the groomer.

Live wire, fixed groomer, 90 s per arm, `--latency-max 500ms`, 11 Mb/s. **Continuity errors** shown; every
arm in this table returned **0 PCR intervals above 40 ms, worst 30.1 ms, and 0 accuracy failures**,
including the arms that lost content.

| source | cushion 250 / cap 500 | 250 / 750 | 250 / 1,000 | 250 / 1,750 | 500 / 2,000 | 1,000 / 1,750 | 250 / 2,500 | 1,000 / 2,500 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| synthetic moderate | **0** | — | — | **0** | **0** | — | — | **0** |
| real clip | — | **0** | **0** | **0** | **0** | — | — | **0** |
| synthetic high | — | — | — | 30 | 15 | 32 | **0** | **0** |

**The cap governs loss and the cushion does not.** The two cells that separate them are the high-burst
source at cushion 250 ms under a 2,500 ms cap — 0 continuity errors — and the same source at cushion
1,000 ms under a 1,750 ms cap — 32. Quadrupling the cushion under the smaller bound does not help;
holding the cushion at its smallest under the larger bound is clean.

**The cushion governs underrun.** Underruns are not programme loss — nothing is dropped and the wire
stays conformant — but they are the buffer running dry and stuffing, and they say the cushion is
marginal:

| source | cushion 250 ms | 500 ms | 1,000 ms |
|---|---:|---:|---:|
| real clip | 24,292 | 11,295 | 2 |
| synthetic high | 34,231 | 6 | 2 |
| synthetic moderate | — | 0 | 5 |

**The requirement is content-dependent, and it is the peak coded frame that sets it — not the bitrate.**
All three sources run 9.5–9.9 Mb/s of programme in an 11 Mb/s mux, and the bound that conserves 100 % of
two of them loses content on the third. What separates them is the largest thing the lane ever hands the
groomer at once: 256, 1,826 and 4,562 packets. On the sources measured, a bound of **3.6× the peak coded
frame's carriage duration** was sufficient in every case and **2.5× was not** — the high-burst source
needs more than 1,750 ms for a 697 ms peak, and clears at 2,500 ms.

That figure is available before deployment rather than by experiment: a coded frame's carriage duration
at the mux rate *is* the encoder's VBV occupancy for that picture. **The media-aware lane moves the
encoder's VBV budget downstream into the groomer's buffer**, because the T-STD schedule that used to
carry it was in the source's byte spacing and the demuxed representation does not have it.

## Conclusion

**The media-aware lane reaches a conformant CBR wire, and the last thing in the way was ours.** Over
300 s on the live chain: 100 % of pictures matched, 0 continuity errors, 0 groomer drops, 0 underruns,
0 of 20,193 PCR intervals above 40 ms at a worst of 30.1 ms, 0 PCRs outside ±500 ns, 10,999,999 b/s
against a nominal 11,000,000, PSI intact. Three upstream PCR fixes were necessary and none of them was
sufficient; what closed the gate was the groomer reserving a slot for the PCR instead of waiting for one
the content scheduler declined. **The demuxed representation carries everything the reconstruction
needs** — arrival time, PCR values and the slots they imply, PES boundaries, PID and PSI structure,
continuity state — and what the lane costs is buffer, sized by the peak coded frame. The rest of this
section is how each stage got there.

**#2967 was right, complete, and did not help.** Judged as what it says it is — a change to how
`moq export ts` places PCR — it is unimprovable: an exact 25 ms grid, the clustering gone, the reserved
bits corrected, the continuity discipline observed, the mechanism explained, and a defect we never
found repaired along the way. Judged against the requirement #2937 was filed under — that a downstream
CBR stage be able to produce a conformant wire — it has moved the obstruction rather than removed it.

**What changed is which stage the defect lives upstream of.** Before, the exporter's PCR *values* were
unusable and no groomer could repair them. Now the values are perfect and the *positions* are unusable,
which breaks a byte-locking groomer outright and lets a re-stamping groomer regenerate the original
distribution from scratch. The reason is a single interface fact: the spacing exists as per-frame
timestamps inside the muxer, and stdout does not carry them.

**The ask measurement 2 made was granted, and it was the right ask that did not get the wanted
result.** [#3006](https://github.com/moq-dev/moq/pull/3006) paces the stdout writer on each frame's
timestamp, which is the first of the two fixes offered above and the better one. Measured at the pipe it
does what it says: the median interval lands on the grid and gate failures halve. Measured on the
deployed chain it changes almost nothing, and the reason is the second fix was the one this lane needed.
**A groomer consumes bytes, not arrival times.** Re-derive PCR from byte position and the positional
bunching — untouched, and untouchable by a timing fix — regenerates the original distribution; lock to
byte position and the stream is unusable. The remaining ask was therefore the fallback offered above
rather than the one first taken up: **emit the PCR packet adjacent to the media bytes of the slot it
labels**, so position and value agree for a consumer that has only bytes. It needs no timing at all and
it is a larger change in `moq-mux`.

**That ask was granted, it merged, and it is the first thing on this lane to move content** —
[#3351](https://github.com/moq-dev/moq/pull/3351) at `4cf216149`, graded in measurements 9 and 10.
Slicing the export on the grid puts adjacency at 0 % and release error inside ±10 ms, and against
#3351's own merge-base the byte-locking groomer drops 36 % fewer packets, places 20 % more content and
halves its stuffing. On its own it does not open the gate: at that point 12.2 % of intervals still
exceeded 40 ms on the wire and continuity was 811 errors.

**The last obstruction was not a defect upstream, which is why no further upstream ask follows from
it.** #3351 places each slot's bytes at the media time the slot asserts; a coded frame's bytes belong to
*its own* 40 ms however large the frame is, so a 417 kB I-frame arrives as 357 ms of carrier for 40 ms
of media. The source's CBR mux had spread those bytes over many frame periods against a T-STD buffer,
and **that schedule is not in the decode timestamps, so no exporter working from them can reconstruct
it.** Building a new one is the downstream stage's job, and measurement 11 is that stage being made able
to do it.

**It can, and the lane passes.** 0 continuity errors, 0 groomer drops, 0 underruns, 0 of 20,193 PCR
intervals above 40 ms at a worst of 30.1 ms, 0 PCRs outside ±500 ns, 10,999,999 b/s against a nominal
11,000,000, PSI intact, over 300 s on the live chain. What was in the way was three defects in our own
groomer — an opportunistic PCR re-inserter that never found a spare slot inside a burst, a rate
estimator that averaged ratios across intervals carrying 1 to 4,631 packets, and an open release loop
that integrated the resulting error against uptime. **None of them needed information the media-aware
representation does not carry**, which is the finding: the demuxed lane is sufficient to reconstruct a
conformant CBR wire, and what it costs is buffer.

**The buffer is the encoder's VBV, moved downstream.** It is content-dependent and it is not a function
of bitrate: three sources at 9.5–9.9 Mb/s of programme need bounds differing by more than 3×, tracking
peak coded frames of 256, 1,826 and 4,562 packets. A bound of 3.6× the peak frame's carriage duration
sufficed on all three and 2.5× did not. That figure is a published property of a contribution encoder,
so the buffer can be sized rather than discovered — which is what an operator needs, and what a single
lucky cushion from one clip would not have given.

**The end-to-end regression is #2967's and #3006 does not repair it** — measurement 6 below, and the
attribution is available because the two arms were run on different builds and different platforms and
agree. #2967 alone on the laptop rig delivered 769 ms against a 118 ms control; #2967 plus #3006 on the
EC2 primary delivers **771.6 ms against a 120.0 ms control**. A pacing fix cannot be the cause of a
regression that was already fully present in a build with no pacing in it.

**T18's prediction is tested and it does not hold, though the gate it predicted is now met by another
route.** The expectation was that an evenly spaced exporter cadence would clear the 40 ms repetition
gate at the depth the lane already runs. It does not: the cadence is even at the pipe to a p95 release
error of 1.70 ms and the gate still failed on the wire at 12.2 %, because the *bytes*, not the clock,
are what a groomer has to place. What clears the gate is the groomer reserving the slot, which is
independent of both the exporter cadence and the cushion — it holds at every rung of the sweep, on every
source, including arms that are shedding 80 % of their content.

## Limits

- **One rig.** Everything is loopback on one laptop. Measurement 11 adds two more sources but no more
  paths: the arrival pattern the groomer sees has the exporter's burstiness in it and none of a real
  network's. A WAN path adds jitter on top of the burst, and the bound would have to cover both.
- **The longest passing arm is 300 s.** The latency trend across it is +60.6 ms, down from +293.5 ms
  across 90 s, which is the shape of a loop converging rather than one ramping — but a converging trend
  measured over five minutes is not a soak. Whether the occupancy loop holds over 24 h or 7 days is
  the open item, and it is the one that matters for permanent distribution.
- **Three sources, two of them synthetic.** The content-dependence result rests on one real contribution
  capture and two deliberately constructed extremes. It establishes that the requirement moves with the
  peak coded frame and not with the bitrate; it does not establish the constant, and "3.6× sufficed,
  2.5× did not" is a bracket from three points rather than a measured coefficient.
- **The effect size of the original positional defect varied by clip** (0 % to 25.2 % of intervals above
  40 ms), so the positional-bunching figures should be read as this clip's shape and not as a constant.
- **The synthetic sources are 1080p25 progressive**, where the real clip is 1080i25. That difference is
  not controlled for; it is not thought to matter to a transport-level burst measurement, but nothing
  here tests that.
- **The reserved-bit and continuity-discipline checks are new instruments**, written for this experiment.
  They were validated in the only way available — the control build reads `0x00` and the fixed build
  `0x3F`, which is the documented change — and not against an independently damaged fixture.
- **`moq import ts` round-tripping the new export is not tested.** The PR claims it, our chain never does
  it, and nothing here confirms or denies it.
- **P2 accuracy on a rate-less egress remains undefined** as a verdict; only the constant-versus-varying
  shape of the error is used, and only as a diagnostic.
- **The arrival oracle's floor was the host and is no longer a live caveat**, because measurement 7 ran
  the same arm on four times the cores. It remains true that a Python reader cannot distinguish its own
  scheduling delay from a late write *in a single interval*; what measurement 7 establishes is that
  across the window the reader's contribution is negligible, so the 7.45 % may now be quoted as the
  exporter's rather than as an upper bound.
- **Measurement 6's attribution is cross-platform.** The #2967-only figures come from the laptop rig and
  the #2967+#3006 figures from EC2. The inference — that a pacing fix cannot cause a regression already
  present without pacing — does not depend on the platforms matching, but the 769 versus 771.6 ms
  agreement should be read as two consistent measurements rather than one repeated one.
- **Measurements 5 and 6 have no #2967-only arm on their own platform**, for the release-tag reason in
  the environment block. Every within-platform comparison here is pre-#2967 against post-#3006, so it
  brackets both fixes together and cannot apportion between them on Linux alone.

## Corrections

- **Believed:** the media-aware lane could not reach the 40 ms repetition gate, and the remaining cost
  of the lane was latency rather than lost content. **True:** both halves were our groomer's, not the
  lane's. The gate was held shut by an implementation choice with no defence — re-inserting PCR only
  into slots the content scheduler had declined, on a source whose bursts decline nothing — and the lost
  content by a rate estimator that averaged ratios and an open release loop. The lane clears the gate at
  every cushion once the groomer reserves the slot, and conserves 100 % of the programme once the bound
  covers the peak coded frame. **Method rule:** when a stage fails a gate at every setting of the one
  knob available, the knob is the wrong hypothesis — read what the stage is actually doing at the moment
  of failure. Counting what sat *between* the failing PCRs took one pass over an output already on disk
  and settled in minutes what four cushion sweeps had not.
- **Believed:** a smoothed average of per-PCR-interval rates recovers the source's content rate.
  **True:** only where the intervals carry comparable numbers of bytes. A mean of ratios is not the ratio
  of the means, and on a media-aware source the two differ by 23 %: the intervals sit on an exact 25 ms
  grid and carry 1 to 4,631 packets each. **Method rule:** an estimator validated on a source that
  arrives at its own mux rate has been validated on the case where the distribution does not matter.
- **Believed:** with a good enough rate estimate, releasing at `rate × elapsed` paces a permanent feed.
  **True:** no estimate is good enough, because nothing bounds the integral. A 2.5 % residual error cost
  1.8 s of delivery latency in 90 s and then began shedding. **Method rule:** for anything that runs
  permanently, prefer a loop closed on the quantity you care about (here, buffer occupancy) to an open
  loop on an estimate of it — and read a latency *trend* as the integral of a rate error before reading
  it as a transport property.
- **Believed:** the byte-locking groomer's 45.9 % (measurement 3) and 67.2 % (measurement 8) content
  losses were what the positional defect costs. **True:** they are what it costs *at the cushion those
  runs used*. The displacement is bounded — 450 ms pre-#3351, 761 ms merged, both deterministic to the
  packet across replicates — and a cushion past it recovers the programme: at 1,500 ms the merged build
  places 105,959 of 106,382 packets with 0 continuity errors and exact CBR, and the #2967 control
  reaches 98.8 % there too. Neither number was wrong; both were quoted as a lane property when they are
  a lane-and-buffer property. **Method rule:** a shedding figure means nothing without the buffer it was
  measured at, and a bounded displacement is a *sizing* input, not a verdict — measure the sweep and
  report the recovery point beside the loss.
- **Believed:** a hard bound on accumulated PCR release drift at 250 ms was a conservative default, so
  the instrument was ready to grade a fix. **True:** the bound belongs to the sender, not the analyst.
  `export ts --latency-max` entitles the exporter to hold 500 ms of buffer, so a correct pipeline
  building a legitimate standing lag failed three runs out of three while its per-interval error sat at
  a p95 of 1.7 ms. Two shapes were also being conflated: a lag that settles and a pipe running slow both
  present as accumulated drift, and only the second is a defect. Corrected at `bbe2ec5` (bound set to
  the sender's budget, tail drift rate reported beside the total) and reported as a correction on #3335.
  **Method rule:** an accumulating quantity almost always has an owner with a declared allowance, and
  that allowance is the bound; and separating a transient from a steady state needs a window longer than
  the transient, which a 20 s window here is not (290 ms still climbing at 8.7 ms/s, against 480 ms
  holding at −0.017 ms/s over 120 s).
- **Believed:** the 480 ms plateau is the exporter's mux buffer filling once and then holding, as the
  fix intends. **True:** that is *one* of two mechanisms which predict the same curve, and this
  measurement does not separate them. CodeRabbit's review of `pace.rs` on #3351 observes that `absorb`
  routes reordered frames through the same path as delivery lag, so a frame deliberately placed before
  the anchor contributes its *reorder depth* as though it were lag, sliding the anchor until slack
  reaches `lead`. The clip used here has B-frames (108 of 150 frames sampled), so the mechanism applies,
  and "monotone growth to roughly `lead`, then flat" is exactly what both predict — a 480 ms plateau
  against a 500 ms budget fits either. **Method rule:** a quantity converging on a configured limit is
  evidence that *something* is bounded by that limit, never of which thing; when two mechanisms share a
  curve, name the arm that separates them before attributing it. That arm has since been run
  (measurement 10): `bframes=0` still carries 428.6 ms of the lag against `bframes=3`'s 481.2 ms, and
  moving `--latency-max` across 500 ms, 1 s and 2 s moves it by under 40 ms. **Neither mechanism owns
  it** — it is a fixed filling offset, and the limit it converges near is a coincidence of scale rather
  than a cause. The attribution in the comment posted on #3351 was stated more confidently than the
  evidence then supported, and is superseded by this.
- **Believed:** the merged build introduced an unbounded, monotonically growing delivery lag — the first
  end-to-end arms measured 3,582 ms rising +2,153 ms across 90 s, reproduced at +2,193 ms, where every
  control was flat. **True:** the growth is the same standing lag ramping toward a budget it had not
  reached inside the window. [`t18-arm.sh`](scripts/t18-arm.sh) runs the exporter at `--latency-max 3s`
  by default; hold it at 500 ms and the arm settles at 2,126 ms with a −24.6 ms trend. Nothing is
  unbounded and the groomer's cushion was never breached. **Method rule:** before reporting a trend as
  growth, check the window against every buffer in the path that the trend could be filling — a rig
  default two rungs above the setting under test will manufacture one.
- **Believed:** the analyser was ready to grade the boundary conditions, having been fixed six times
  over. **True:** it had two further defects, both of it failing conforming input, and both found only
  once legal fixtures existed rather than broken ones. A *signalled* discontinuity failed twice over —
  as a continuity error and as an 820 ms repetition-limit breach — though ISO 13818-1 2.4.3.3 permits
  the counter jump and 2.4.3.4 permits the clock jump with it, and the jump was additionally at risk of
  being unwrapped as a 33-bit rollover. Separately, `--live` returned a *hard pass* labelled "not
  measured" when it held too few PCRs to grade, so a producer dying after two packets reported success;
  on this rig the exporter exits early on nearly every run, so that was a live route to a false pass on
  the very verification it exists for. **Method rule:** most defects in a conformance instrument are it
  rejecting legal input, and a suite built only from broken streams cannot find them; and "not measured"
  must never share an exit code with "passed".
- **Believed:** the residue above the gate might be the two-vCPU host rather than the exporter, and the
  bursts were a group-boundary flush. **True:** the gate metric is 7.45 % on two vCPU and 7.45 % on
  eight, at zero CPU pressure, and the cause is that the PCR grid is advanced by frame arrival rather
  than by media time — measurement 7. **Method rule:** when an instrument's floor is offered as a
  caveat, the cheapest way to retire it is usually to move the instrument to a bigger host and change
  nothing else; and a residue with structure has a mechanism, so look for it in the code before naming
  it after the nearest event.
- **Believed:** [#2978](https://github.com/moq-dev/moq/issues/2978) was explicitly left open by #3006.
  **True:** it is closed as completed, on 2026-08-21, a day *before* #3006 merged — and #3006 went on to
  rewrite the same file (`rs/moq-srt/src/server.rs`, −161 lines). Our note inverted both the state and
  the order. **Method rule:** an issue's state is a fact with a timestamp, not an inference from the PR
  that seemed to address it; read it from the tracker at the moment of writing.
- **Believed:** `moq-srt` was an in-tree caller that honoured #2967's pacing contract, which is how
  [#2984](https://github.com/moq-dev/moq/issues/2984) was framed — one caller implements the contract,
  the other discards it. **True:** `moq-srt` had the *shape* of the contract and not the behaviour. Its
  `pace` used the scale-strict `Timestamp::checked_sub`, whose error arm assumed a reordered frame; the
  exporter stamps PCR frames in microseconds and media frames at the source's timescale (90 kHz for a TS
  import), so a cross-scale pair fell through both subtractions and collapsed onto the anchor. **Media
  frames on the SRT lane were not paced at all.** #3006 had to fix that to fix ours — computing offsets
  in nanoseconds in the extracted `Pacer` — and says so: without it, pacing `run_ts` "would not have
  fixed #2984 at all". The report's substance survives, because `run_ts` genuinely never read
  `frame.timestamp` and that is the root cause #3006 names; what was wrong was the exemplar cited beside
  it. **Method rule:** reading an implementation establishes its intent, not its behaviour. Citing
  another component as the working reference for a contract is a claim about how that component behaves,
  and it needs the same evidence as any other behavioural claim — here the code said
  `send_at = anchor + (ts - base)` and was right about everything except which clock the two operands
  were on.
- **Believed:** measurement 3's 45.9 % shed was a property of the lane, so the groomer was a correct
  instrument reporting a bad input. **True:** it was both. The exporter places PCR badly *and* the
  groomer had source PCR value cadence and byte-position cadence as interchangeable, which is an
  assumption about the source that no source is obliged to satisfy. On the fixture the groomer exited
  **zero** having discarded 67.2 % of the programme and added 106 discontinuities of its own
  (measurement 8). **Method rule:** when a stage reports a bad input, check whether the stage's own
  contract was ever written down — an assumption that has always held is indistinguishable from an
  invariant until the day it does not, and the failure it produces then is a *success* exit code.
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
  [#2984](https://github.com/moq-dev/moq/issues/2984) (the stdout boundary, filed from measurement 2),
  [#3006](https://github.com/moq-dev/moq/pull/3006) (the pacing fix, merged `489e3647`, graded in
  measurements 5 and 6 — and it repaired `moq-srt`'s own pacer on the way, see Corrections),
  [#2978](https://github.com/moq-dev/moq/issues/2978) (the same class of defect on the SRT egress,
  Luke's own, and **closed** — see Corrections),
  [#3334](https://github.com/moq-dev/moq/issues/3334) (the residual output-position/release defect,
  filed from measurement 7, **closed by the fix and discharged by measurement 10**),
  [#3351](https://github.com/moq-dev/moq/pull/3351) (the positional fix, **merged `4cf216149`**, graded
  in measurements 9 and 10) and [#3335](https://github.com/moq-dev/moq/pull/3335)
  (`test/ts/pcr-timing.py`, test tooling only — **closed as absorbed**: #3351 landed the file
  byte-identical to that branch's head, so nothing was left to merge). Hedged code-reading comments were left on
  [#2829](https://github.com/moq-dev/moq/issues/2829) and
  [#2779](https://github.com/moq-dev/moq/issues/2779) — offered as possibly the same underlying property,
  not as established fact.
- Diagnosed in [test-18-delivery-latency.md](test-18-delivery-latency.md) measurement 6; the gate is
  [test-13-downstream-grooming.md](test-13-downstream-grooming.md) criterion 3.
- The byte-locking model the fix breaks is [test-12-dual-path-handoff.md](test-12-dual-path-handoff.md).
- Findings destination: [`docs/evidence.md`](../docs/evidence.md) §3.2.

# Test 44 — The transmux lane against a calibrated T-STD model

**State: complete, conclusive on the questions asked.**

- **The media-aware lane's TS-out, as built, is not a conformant transport stream.** Neither of the
  groomer's clock modes makes it one, and neither does `main`'s own padding to the mux rate. On the configuration that passes TR 101 290 P1/P2 on the wire
  ([T19](test-19-pcr-grid-verification.md) measurement 11), on the soak's ([T21](test-21-permanence-soak.md)),
  on `ffa5b81b` and on current upstream `main` (`9157692f6`), the transport buffers of the video, both
  audio PIDs and the PSI overflow throughout, and **no constant PCR offset makes the audio decoder
  buffers legal in any 2 s window**.
- **A stage that re-multiplexes can make it one.** An offline T-STD scheduler that keeps each PID's
  packets in order rebuilds a multiplex that passes every buffer over the whole capture. It needs only
  the time each packet became available, and at no point the source's layout. It did so from the lane's
  own groomed egress on three builds, and from frame-granular source data at 25 ms of added decoder
  delay.
- **Byte-faithful carriage keeps the T-STD through the groomer's stream clock**, over SRT and over
  UDP: every buffer passes over the whole capture, at exactly the source's legal offsets, with the
  source's nulls stripped and re-spread. It does not keep it through the default arrival clock, which
  lets the PCR-to-PTS offset drift and fails the decoder buffers over a whole capture.

Measured at P1, wire domain, loopback, one clip, three exporter builds, two groomer builds, both
groomer clock modes. The exporter's own padded output and the re-multiplexer's outputs are file
domain. Hardware: not run.

TR 101 290 P1/P2 grades the PCR, continuity and tables. It does not model the decoder's buffers, and
the campaign's conformance results — T19's 0 of 20,193 intervals above 40 ms, T21's day — are P1/P2
results. ISO/IEC 13818-1 defines a conformant transport stream as one a T-STD can decode without
overflow or underflow, so a stream can pass every P1/P2 check and still not be one. The MSFTS
co-author's review put the point directly: a transmux subscriber becomes the multiplexer and has to
schedule every packet against the T-STD, a job the source multiplexer already did and the lane
discards. This test grades it.

## Objective

1. **Is the media-aware lane's groomed TS-out T-STD-conformant** on the configurations whose P1/P2
   results the paper quotes?
2. **Whose is any failure** — the lane's packet order, or the groomer's PCR regeneration?
3. **Could the existing groomer repair it?** It paces and re-stamps PCR but never reorders packets, so
   the only correction open to it is a constant PCR-to-PTS offset.
4. **Could a stage that reorders repair it, and at what decoder delay?**
5. **Does byte-faithful carriage keep the T-STD through the groomer over a whole capture**, with the
   source's nulls removed?

Questions 4 and 5 were added after the first grading. Question 4 came from the MSFTS review's second
point, and question 5 from the whole-capture scan failing the SRT control.

## Instrument

[`ts-tstd.py`](scripts/ts-tstd.py), written for this test. It interpolates every byte's arrival time
from the PCR (13818-1 2.4.2.2) and runs each PID's buffers on that clock:

| Buffer | Size | Leak | Source |
|---|---|---|---|
| TB, H.264 video | 512 B | 1.2 × NAL HRD `BitRate[0]` = 10,557,082 b/s | 13818-1 2.4.2.4, Cor. 2-2009; HRD read from the SPS |
| EB, H.264 video | `CpbSize[0]` + MB = 1,115,696 B | at DTS | 13818-1 2.14 |
| TB, MPEG-1 L2 and AC-3 audio | 512 B | 2 Mb/s | 13818-1 2.4.2.4 |
| B, MPEG-1 L2 audio | 3,584 B | at PTS | 13818-1 |
| B, AC-3 audio | 5,696 B | at PTS | A/52 Annex A 5.4 |
| TB, DVB teletext | 480 B | 6.75 Mb/s | EN 300 472 |
| TBsys, PAT/PMT/CAT | 512 B | 1 Mb/s | 13818-1 |
| SCTE-35 and SI PIDs | 512 B | 1 Mb/s | **assumed** — no normative T-STD; reported separately, not graded |

Residence is bounded at 1 s, and 10 s for AVC (2.4.2.6/2.4.2.7). The source's video HRD rate sits
between its mux rate (9,945,951 b/s) and the groomer's 11 Mb/s carrier, which matters below.

Three tests of whether an offset could repair the decoder buffers:

- **Nominal**: the stream's own PCR.
- **Whole-capture offset scan** (`--offset-scan`): the constant offsets at which each buffer, and all
  at once, are legal. One PCR serves every PID, so only the joint set is a repair.
- **Windowed** (`--window 2`): the exact legal interval per 2 s window. A groomer that regenerates PCR
  lets the PCR-to-PTS offset drift slowly, and then no single offset serves a whole capture even when
  the lane delivered every unit in time; over 2 s that drift is negligible, so **a window with no legal
  offset is a failure of the packet timing itself**. The *deficit* is how far apart the constraints are.

Transport-buffer overflow does not depend on the offset at all: it is set by how many packets of one
PID arrive back to back at the carrier rate.

**Validation.** Sixteen analytical self-tests pass (`--selftest`), among them the fluid-bucket overflow
point at a carrier above Rx (67 packets hold 507 B; the 68th overflows) and the exact legal interval
against a brute-force scan. **On the source multiplex every buffer passes, and the whole-capture scan
puts the joint legal offset at exactly +0 ms** (EB [−250, +0], MP2 [+0, +100], AC-3 [+0, +150]): the
model is calibrated to the multiplexer that produced the clip, with no slack in either direction.

It supersedes the harness's `tstd` check for this purpose ([T2](test-2-media-aware-transparency.md)),
which counted payload bytes against a single default leak rate.

### The re-multiplexing oracle

[`ts-remux-oracle.py`](scripts/ts-remux-oracle.py), written for question 4. It keeps every PID's
packets in order, byte for byte, and discards the input's nulls and its PID interleave. Each slot of a
constant-rate output goes to the available packet with the earliest decode deadline, among those whose
transport buffer and decoder buffer have room; otherwise the slot is a null. The buffer parameters are
`ts-tstd.py`'s. PCR is rewritten on the output byte clock, with an adaptation-only PCR packet whenever
none has gone for 25 ms. `--delay` lowers the output PCR against the input's, so every unit decodes
that much later. The smallest delay at which the scheduler sends nothing late is the rebuild's cost.

Availability is the only thing a rebuild at the subscriber is allowed to know about timing:

| Mode | A packet may be sent once | Stands for |
|---|---|---|
| `packet` | it has arrived in the input | a byte-faithful input; or, on a lane capture, a regroomer behind the lane |
| `frame` | every audio frame it carries a byte of has arrived; video and teletext as `pes` | a lane that publishes each access unit as one object |
| `pes` | its whole PES has arrived: `PES_packet_length` met, else the next PES start on its PID | a lane that publishes each PES as one object |

The oracle is greedy, not optimal: a feasible result proves a schedule exists, and an infeasible one
proves nothing. **Its own counts are not the verdict.** `ts-tstd.py` grading the output file is,
together with TSDuck `continuity` and `pcrverify --absolute --jitter-max 13`. **Validation:** fed the
source in `packet` mode at +0 ms, the output passes every buffer, with the joint legal offset exactly
+0 ms, 0 continuity errors and 0 PCRs outside ±481 ns.

## Environment

Loopback on one laptop, the [T18](test-18-delivery-latency.md) rig [`t18-arm.sh`](scripts/t18-arm.sh):
source `CNNiEMEA2.ts` (H.264, MPEG-1 L2, AC-3, DVB teletext, three SCTE-35 PIDs; 9,945,951 b/s), the
lane's `moq export ts` feeding `mpegts-pacer` at an 11 Mb/s carrier, 2,500 ms cap, 1,000 ms cushion,
subscriber `--max-latency 500ms`. Each arm is 300 s; the first 20 s are simulated but not graded
(`--skip 20`), because the SRT arm starts with a 6.7 s arrival backlog.

Neither original capture exists — T21 stored nothing by design and T19's egress was not retained — so
both configurations were re-captured:

| Arm | Exporter build | Groomer | Stands for |
|---|---|---|---|
| **m11** | `f8236680b` (carries #3351) | `64595f6` | T19 measurement 11 exactly |
| **t21** | `f8236680b` | `5ab84cd` | T21's chain. T21 ran `222cc72`, also carrying #3351, cross-host on a continuous source for a day; this is the same lane and groomer on loopback for 300 s |
| **ffa** | `ffa5b81b` — build under test | `5ab84cd` | the current build |
| **srt** | none: `tsp` SRT caller → listener, 1,000 ms latency | `64595f6` | attribution — the same groomer fed a byte-faithful transport |
| **main** | `9157692f6` — current upstream `main` | `5ab84cd` | whether the result still holds on today's code |
| **main-sc** | `9157692f6` | `5ab84cd --stream-clock` | whether the groomer's other clock mode repairs the lane |
| **main-raw** | `9157692f6`, its default null padding to the catalog's mux rate | none: the exporter's own bytes, saved before the groomer (`RECEIVE_SAVE`), 180 s | whether the exporter's padding carries a T-STD schedule by itself. **File domain**: the bytes as written, timed by their own PCR, as a sender that replays them against it would place them |
| **udp** | none: `tsp` UDP, the file's own bytes | `5ab84cd` | the byte-faithful control with no reliable transport |
| **udp-sc** | none: `tsp` UDP | `5ab84cd --stream-clock` | question 5: byte-faithful, nulls stripped and re-placed on the source's PCR |
| **srt-sc** | none: `tsp` SRT, 1,000 ms latency | `5ab84cd --stream-clock` | question 5 over a reliable transport |

`--stream-clock` places each packet on the output slot its source PCR implies at the locked rate,
spreading each PCR interval's packets evenly between its PCR slots. It is the mode the 1+1 design
uses. The default arrival clock releases content at a media rate recovered against its own emit clock,
closed-loop on buffer occupancy, and byte-locks PCR from the first PCR it sees. Both strip the input's
nulls and stuff their own.

The m11, t21 and ffa arms each reproduced its P1/P2 result on the wire: 0 continuity errors, 0 PCR
intervals above 40 ms (0/20,193, 0/20,297, 0/20,203; worst 30.1 ms), 0 PCRs outside ±481 ns; median
delivery latency 2,443, 2,469 and 3,092 ms. The m11 arm's groomer recorded 3 underruns where T19's recorded 0. The SRT
arm recorded 4 continuity errors and 0 of 11,803 intervals above 40 ms.

The main arm had 0 continuity errors and one PCR interval above 40 ms in 20,318: 210.9 ms, 0.93 s after
the first PCR, inside the ungraded start-up and beside the capture's one PCR discontinuity. One PCR in 20,317 was outside
±481 ns. The main-sc arm had 0, 0 of 19,098 and 0. **`main` rebases the PTS onto its own clock**, so the
rig's PTS-keyed latency report finds no matching frame and exits 1, and neither main arm has a delivery
latency. The byte-faithful arms had 3 (udp, loopback input drops), 0 and 0 continuity errors, and none
had a PCR interval above 40 ms.

## Pass criteria, fixed before the runs

- **Conformant**: zero overflows in every normative transport buffer, and zero underflows, overflows
  and residence violations in every decoder buffer, over the graded window (the grader's exit status).
- **Attributable to the lane**: a buffer that fails on a MoQ arm and passes on the SRT arm through the
  same groomer.
- **Repairable by the existing groomer**: a constant offset exists at which every decoder buffer is
  legal at once, and no transport buffer overflows.

The windowed test was added after the first grading, when the whole-capture scan found no legal offset
on the SRT arm either (below). It is a diagnostic that separates PCR drift from packet timing; it was
not a criterion fixed in advance.

For questions 4 and 5, fixed before those runs: an output **passes** when the grader exits 0 over the
graded window and TSDuck finds 0 continuity errors and 0 PCRs outside ±481 ns. **Repair** also
requires the joint whole-capture legal offset to contain +0 ms, so that the output decodes on its own
PCR.

## Results

### Transport buffers — overflowing packets of those graded, and peak occupancy

| PID | Source (600 s) | m11 | t21 | ffa | main | main-sc | srt |
|---|---|---|---|---|---|---|---|
| PAT/PMT/CAT | 0 · 169 B | 15 of 1,608 · 615 B | 14 of 1,616 · 615 B | 17 of 1,610 · 615 B | 3 of 1,622 · 581 B | 1 of 1,594 · 581 B | 0 · 171 B |
| H.264 video | 0 · 0 B | **76,419 of 1,672,352 (4.6 %)** · 9,939 B | **75,863 of 1,680,350 (4.5 %)** · 9,808 B | **70,145 of 1,672,543 (4.2 %)** · 9,808 B | **72,686 of 1,686,741 (4.3 %)** · 9,447 B | **1,615,840 of 1,684,733 (95.9 %)** · 56,996 B | 0 · 386 B |
| MPEG-1 L2 | 0 · 150 B | **39,623 of 45,952 (86.2 %)** · 6,802 B | **39,685 of 46,020 (86.2 %)** · 6,802 B | **39,672 of 45,949 (86.3 %)** · 6,802 B | **39,860 of 46,220 (86.2 %)** · 6,836 B | **34,340 of 46,124 (74.5 %)** · 6,836 B | 0 · 154 B |
| AC-3 | 0 · 150 B | **33,486 of 36,366 (92.1 %)** · 8,990 B | **33,530 of 36,404 (92.1 %)** · 9,263 B | **33,475 of 36,366 (92.1 %)** · 9,024 B | **33,674 of 36,570 (92.1 %)** · 9,332 B | **31,827 of 36,491 (87.2 %)** · 9,400 B | 0 · 154 B |
| Teletext | 0 · 60 B | 0 · 73 B | 0 · 145 B | 0 · 73 B | 0 · 73 B | 0 · 73 B | 0 · 73 B |

The assumed SCTE-35 and SI buffers peak at 171 B on every arm.

**Stream clocking makes the lane's video worse, not better.** It places each packet on the slot the
*exporter's* PCR implies, and the exporter's PCR positions do not track their values. The groomer
reported 1,726 overrun PCR intervals and a displacement of 3,655 packets (499 ms at rate), and it
spills each overrun into the following slots at the full carrier rate.

### Decoder buffers — nominal PCR, and the whole-capture offset scan

| | m11 | t21 | ffa | main | main-sc | srt |
|---|---|---|---|---|---|---|
| EB video: underflows · median margin | 10,005 of 10,005 · −548.6 ms | 10,028 of 10,036 · −284.0 ms | 10,021 of 10,021 · −544.5 ms | 10,094 of 10,094 · −1,031.6 ms | 10,074 of 10,074 · −398.4 ms | 0 · +2,604.3 ms, overflowing |
| B MP2: underflows · overflow arrivals | 9,358 of 11,488 · 555 | 261 of 11,505 · 27,452 | 9,139 of 11,487 · 820 | 11,555 of 11,555 · 0 | 2,980 of 11,531 · 9,057 | 0 · 35,846, residence over 1 s in every unit |
| B AC-3: underflows · overflow arrivals | 3,403 of 8,613 · 2,425 | 29 of 8,622 · 24,974 | 3,257 of 8,613 · 2,839 | 8,661 of 8,661 · 0 | 557 of 8,642 · 12,970 | 0 · 35,228, residence over 1 s in every unit |
| Legal offsets, −3 s to +3 s in 50 ms steps | EB [+900, +1,050]; audio none; **joint none** | EB [+600, +750]; audio none; **joint none** | EB [+900, +1,050]; audio none; **joint none** | EB [+1,350, +1,550]; audio none; **joint none** | EB [+800, +1,050]; audio none; **joint none** | **none for any buffer** |

On the nominal PCR every arm fails, SRT included. The arrival-clocked groomer's byte-locked PCR
regeneration sets the PCR-to-PTS offset from its own buffer occupancy, so the offset is wrong on every
arm and drifts on the SRT one (margins spread over 0.9 s). The whole-capture scan therefore cannot
attribute the decoder buffers. The windowed test can, and so can a stream-clocked control (below).

### Decoder buffers — 2 s windows with a legal constant offset

| | Source | m11 | t21 | ffa | main | main-sc | srt |
|---|---|---|---|---|---|---|---|
| EB video | 299 of 299 | 137 of 137 | 138 of 138 | 137 of 137 | 139 of 139 | 138 of 138 | 133 of 133 |
| B MP2 | 299 of 299 | **0 of 137** · deficit median 193.9 ms, max 429.9 | **0 of 138** · 199.1, 409.9 | **0 of 137** · 195.4, 411.9 | **0 of 139** · 199.4, 410.1 | **0 of 138** · 127.5, 372.6 | 133 of 133 |
| B AC-3 | 299 of 299 | **0 of 137** · 195.1, 578.8 | **0 of 138** · 215.2, 579.9 | **0 of 137** · 190.5, 488.6 | **0 of 139** · 210.3, 580.3 | **0 of 138** · 193.5, 485.8 | 133 of 133 |
| All at once | 299 of 299 | **0 of 137** · 707.8, 990.1 | **0 of 138** · 710.0, 990.6 | **0 of 137** · 706.3, 951.6 | **0 of 139** · 703.6, 989.0 | **0 of 138** · 686.1, 954.4 | 133 of 133 |

### `main`'s own padded export, before the groomer

File domain, 157 s graded. The export holds the mux rate on average (9,957,934 b/s, against the
source's 9,945,951 b/s), but not inside a PCR interval. The median interval carries 0.04 times the
packets its PCR values imply at that rate, and 12 % of intervals carry more than the video's
10.56 Mb/s leak, up to 17.5 times the rate. So the padding does not place the lane's packets on the
schedule their PCR describes.

| | main-raw |
|---|---|
| Transport buffers overflowing · peak | video **945,320 of 952,090 (99.3 %)** · 626,755 B; MP2 **1,471 of 26,082 (5.6 %)** · 1,082 B; AC-3 **11,003 of 20,621 (53.4 %)** · 7,054 B; PSI and teletext 0 |
| Decoder buffers, nominal PCR | EB 2,215 of 5,472 units underflow, median margin 3.3 ms; MP2 and AC-3 no underflow, every arrival overflowing |
| Whole-capture legal offsets | EB [+50, +350]; MP2 [−350, −300]; AC-3 none; **joint none** |
| 2 s windows legal | EB 78 of 78; MP2 78 of 78; AC-3 **0 of 78** · deficit median 27.2 ms, max 55.2; all at once **0 of 78** · 447.2, 473.8 |
| P1/P2 of the same bytes | 0 continuity errors; 0 of 7,109 PCR intervals above 40 ms, max 25.0 ms; **7,109 of 7,110 PCRs outside ±481 ns**, worst 17.5 ms |

### Byte-faithful carriage through the groomer's two clock modes

| | udp, arrival clock | srt, arrival clock (above) | udp-sc, stream clock | srt-sc, stream clock |
|---|---|---|---|---|
| Transport buffers overflowing · video peak | 0 · 448 B | 0 · 386 B | 0 · 91 B | 0 · 91 B |
| EB video median margin (source, 600 s: 734.7 ms) | 2,610.1 ms, peak 3,184,410 of 1,115,696 B | 2,604.3 ms, overflowing | **743.3 ms**, peak 1,100,393 B | **742.1 ms**, peak 1,100,393 B |
| Audio residence over 1 s | every unit | every unit | none | none |
| Whole-capture legal offsets | **none for any buffer** | **none for any buffer** | EB [−250, +0], MP2 [+0, +100], AC-3 [+0, +150], **joint [+0, +0]** | the same, **joint [+0, +0]** |
| 2 s windows legal, all at once | 137 of 137 | 133 of 133 | 137 of 137 | 133 of 133 |
| Grader | fails | fails | **passes** | **passes** |

The stream-clocked arms land on the source's own legal intervals to the 50 ms step (source: EB
[−250, +0], MP2 [+0, +100], AC-3 [+0, +150]). Their inputs lost every null, and with it every null's
position, and both are graded over the whole capture.

### Re-multiplexed by the oracle

At 11 Mb/s. The delay is against the input's own PCR. Every output below passes the grader, with 0
continuity errors, 0 PCRs outside ±481 ns and a largest PCR interval of 25.2 ms.

| Input | Availability | Late packets by delay (scheduler's count) | Written at | Joint legal offset · windows | EB video median margin | Hold before sending, median (max) |
|---|---|---|---|---|---|---|
| Source, 320 s | `packet` | 1 at 0 ms, 0.8 ms inside the scheduler's 1 ms guard | 0 ms | [+0, +0] · 159 of 159 | 744.5 ms | 0.2 ms (0.4 ms) |
| Source, 320 s | `frame` | 20,756 at 0 ms; **0 at 25 ms** | 25 ms | [+0, +0] · 160 of 160 | 703.5 ms | video 53.7 ms (240 ms); audio 0.4 ms (24 ms) |
| Source, 320 s | `pes` | 9,990 at 200 ms; **0 at 250 ms** | 250 ms | [+0, +0] · 160 of 160 | 905.7 ms | video 77.8 ms (242 ms); MP2 26.7 ms (148 ms) |
| ffa egress | `packet` | 1,065 at 800 ms; **0 at 900 ms** | 900 ms | [−25, +0] · 137 of 137 | 354.8 ms | video 0.1 ms (118 ms); audio 0.69–0.73 s (1.37 s) |
| m11 egress | `packet` | 3,291 at 750 ms; **0 at 900 ms** | 900 ms | [−25, +0] · 138 of 138 | 350.7 ms | video 0.3 ms (729 ms); audio 0.69–0.72 s (1.82 s) |
| main egress, from its PCR discontinuity at 0.71 s | `packet` | 682 at 1,300 ms; **0 at 1,400 ms** | 1,400 ms | [−50, +0] · 138 of 138 | 366.9 ms | video 0.1 ms (155 ms); audio 0.70–0.74 s (1.51 s) |

**On the source, the binding stream is the audio, not the video.** The source sends its audio just in
time, with a minimum MP2 margin of 0.3 ms over 600 s, and packs several frames per PES. Waiting for a whole frame
costs about one frame, and waiting for a whole PES costs about one PES. The video, pre-loaded at least
278 ms ahead, absorbs either wait.

**On the lane's egress, the delay the rebuild needs is the delay the lane's video already owed.** It is
900 ms on the builds whose video was legal at [+900, +1,050], and 1,400 ms on `main`, whose video was
legal at [+1,350, +1,550]. What the rebuild removes is the audio constraint that emptied the joint
set. It spreads the audio's runs, holding them a median 0.69–0.74 s, and sends the video within a
median 0.3 ms of its arrival. Its video decoder margin, a median 351–367 ms, is under half the
source's 735 ms. That is consistent with the lane having turned the source's pre-loading into
delivery delay, which is how [T19](test-19-pcr-grid-verification.md) reads the lane's latency. It is an
inference: the decode-referenced latency that would show it was not measured.

The FFmpeg-muxed `testloop_clean` was rejected as a second source: it overflows its own AAC transport
buffer on 80 % of packets (8,804 of 10,958 in its first 60 s), so it cannot serve as a control.

## Conclusions

**Established** (P1, wire, loopback, one clip, the builds named; the rebuild offline, file domain):

- **The media-aware lane's groomed TS-out fails the T-STD on every build tested.** That is three
  exporter builds in four configurations, up to current upstream `main`, and it includes the
  configuration that passes P1/P2 and the soak's. It fails in the transport buffers of video, both
  audio PIDs and the PSI, and in both audio decoder buffers.
- **The failure is the lane's, not the groomer's.** Byte-faithful carriage through the same groomer
  passes every transport buffer, and every decoder buffer in every window, in either clock mode.
  Through the stream clock it passes everything over the whole capture. The groomer does not reorder
  packets, so the transport-buffer overflows are the order in which the exporter wrote the packets.
- **Neither of the groomer's clock modes can repair it.** No offset touches a transport buffer. In the
  decoder buffers the video is repairable: legal in every window, and over the whole capture at +600
  to +1,550 ms of added delay depending on the build. **The audio is not repairable at any offset, in
  any window.** The audio's own timing spreads a median 0.13–0.22 s wider than its buffer holds, and the offsets
  legal for video and for audio lie a median 0.69–0.71 s apart. One PCR serves both. Stream clocking
  places packets by an exporter PCR that does not track its own positions, and it raises video
  transport-buffer overflow to 95.9 % of packets.
- **`main`'s padding to the mux rate does not repair it either** (file domain). The exporter's own
  padded bytes, before any groomer, overflow 99.3 % of video transport-buffer packets. They have no
  joint legal offset in any window, and 7,109 of 7,110 PCRs fall outside ±481 ns: the padding holds
  the rate on average but not per PCR interval.
- **A stage that re-multiplexes does repair it.** Kept in each PID's order and rescheduled against the
  T-STD, the lane's own groomed egress becomes a multiplex that passes every buffer over the whole
  capture and decodes on its own PCR. This holds on all three builds rebuilt. The delay needed
  against the egress's PCR, 0.9 s and on `main` 1.4 s, is the offset the lane's video needed anyway.
  Fed frame-granular source data, which a lane publishing each access unit as one object could
  deliver, the rebuild needs 25 ms; fed PES-granular data, 250 ms.
- **Byte-faithful carriage keeps the T-STD through the stream clock, without the source's nulls.** The
  test ran over UDP and over SRT. Every null was stripped and each PCR interval's packets re-spread
  evenly, and every buffer passes over the whole capture at exactly the source's legal offsets.
  Through the arrival clock the same bytes fail every decoder buffer over the whole capture, because
  the start-up lead sets the PCR-to-PTS offset and the offset then drifts.

**Likely** (inferred from the peaks; the exporter's code was not read for this test). The exporter
writes each track's pending units contiguously rather than interleaving the PIDs. An MP2 peak of
6,802 B is about 36 packets back to back, about twelve 576 B frames or 290 ms of audio released at
once, where the source spaces every audio packet on its own. At a 2 Mb/s leak, **more than three
back-to-back packets of an audio PID overflow at any carrier rate**. The video transport buffer is the
rate-dependent case: its 10.56 Mb/s leak is below the 11 Mb/s carrier, so a contiguous frame overflows
after 67 packets. At a carrier below the HRD rate the video transport buffer could not overflow,
however the packets were ordered. [T45](test-45-live-tstd-remux.md) read the exporter's code at
`ffa5b81b`: it writes one whole frame at a time, from whichever track's pending frame has the
smallest PTS, which is this mechanism on that build.

**Likely, and inferred from the mechanism.** A frame-granular rebuild costs about one audio frame on
this source because the source sends its audio just in time and pre-loads its video by at least
278 ms. A source that sends its video just in time would make the video the binding stream, at about
one frame's transfer time. A low-delay contribution encoder is that kind of source. Not measured: the
one broadcast-muxed clip here is not that source.

**What is structural and what is not.** The lane discards the source multiplexer's packet schedule.
The interleave of PIDs and the pre-loading of the decoder buffers live in the byte positions, and
neither is in the decode timestamps the lane carries. Rebuilding a conformant stream is therefore a
multiplexing job: schedule every PID's packets against the T-STD from the timestamps and sizes the
lane does carry. **That job is feasible, and the oracle does it on the lane's own output.** Two things
are structural. The job has to be done somewhere that reorders, at the subscriber or at an edge
stage. And it yields *a* conformant multiplex, not the source's. None of the builds does it, and the
pacing groomer cannot by design. What the oracle does not establish:

- **A real-time implementation.**
- **Clock recovery.** The oracle took its input's PCR as its clock. A subscriber on the lane has no
  source PCR, and `main` also rebases the PTS, so it must lock its output clock to the source's from
  the timestamps alone.
- **1+1 determinism.** The oracle's schedule depends on when each packet became available, which
  differs between legs. Two rebuilt legs would be byte-identical only under a schedule computed from
  the stream alone, which is the property stream clocking gives the pacer.
- **Glass-to-glass latency at T-STD conformance.**

[T45](test-45-live-tstd-remux.md) built the real-time implementation and measured presentation
latency at T-STD conformance on `ffa5b81b`; clock recovery and 1+1 determinism remain open.

**Uncertain.** How a hardware IRD responds. Receivers commonly provision audio and transport buffers
beyond the T-STD minimum, so this wire may decode on some equipment. The T-STD is the contract a
receiver is entitled to assume, not a prediction of any one decoder. **The arm that settles it is a
hardware IRD and analyser fed this wire and the rebuilt one side by side.** The pair would show both
how far receivers tolerate the lane's wire and whether they accept its rebuild.

## Limits

- **One clip, one carrier rate, loopback.** The audio result does not depend on the carrier; the video
  transport-buffer result does (above). No WAN path, so no network jitter is added to the lane's own.
- **300 s, not T21's day.** The t21 arm is T21's lane, #3351-bearing exporter and groomer, not its
  exact build, host or continuous source. The three MoQ arms agree to within 0.5 percentage points on
  every transport buffer, so a longer run is not expected to move the result; that is inferred, not
  measured.
- **The SCTE-35 and SI buffers are assumed**, and pass on every arm.
- **The decoder stage takes arrival at the packet's arrival**, ignoring the TB-to-EB transfer delay, so
  underflow margins are optimistic by at most a few milliseconds. That favours the lane.
- **The segmented-HTTP lane was not graded.** It carries the source's own packet order, so it should
  behave as the SRT arm does. That is reasoned, not measured.
- **The rebuild is offline and its output is a file.** Availability is the input's PCR-interpolated
  time, which on the egress captures is the groomer's regenerated clock. A constant transport latency
  therefore cancels, and path jitter beyond what the capture holds is not modelled. `frame` mode
  approximates per-frame objects on the source's own packetization, where a lane would repacketize.
  The scheduler is greedy, so an optimal one may need less delay.
- **`main`'s egress was cut at its one PCR discontinuity**, 0.71 s in, for the rebuild, because the
  oracle refuses a second timeline.
- **The main arms have no delivery latency.** `main` rebases the PTS, and the rig's latency report
  keys on it. Latency on `main` needs a tap that keys on content.

## Reproduction

```bash
python3 lab/scripts/ts-tstd.py --selftest
python3 lab/scripts/ts-tstd.py <source>.ts --offset-scan -500,500,50 --window 2
# one MoQ arm; RELAY_TOML is needed where the build predates the tree's demo relay config
RELAY_TOML=<relay.toml for the build> MOQ=<build>/moq RELAY=<build>/moq-relay MOQLAT=500ms \
  RATE=11000000 CAP=2500 PACER=<pacer>/mpegts-pacer \
  bash lab/scripts/t18-arm.sh <source>.ts <out> 300 moq 1000
RATE=11000000 CAP=2500 PACER=<pacer>/mpegts-pacer bash lab/scripts/t18-arm.sh <source>.ts <out> 300 srt 1000
# the stream-clocked arms: the same commands with the groomer's other clock mode
PACER_EXTRA=--stream-clock RATE=11000000 CAP=2500 PACER=<pacer>/mpegts-pacer \
  bash lab/scripts/t18-arm.sh <source>.ts <out> 300 udp 1000
# main-raw: any MoQ arm, keeping the exporter's own bytes before the groomer
RECEIVE_SAVE=<out>/export-raw.ts <the MoQ arm's environment> bash lab/scripts/t18-arm.sh <source>.ts <out> 180 moq 1000
python3 lab/scripts/ts-tstd.py <out>/<moq|srt|udp>-c1000-egress.ts --skip 20 --window 2 \
  --offset-scan -3000,3000,50 --json <out>/tstd.json

# the re-multiplexing oracle: sweep the delay, write the smallest with no late packets, grade it
python3 lab/scripts/ts-remux-oracle.py <out>/moq-c1000-egress.ts <rebuilt>.ts --rate 11000000 \
  --avail packet --delay 0.8,0.9,1.0,1.2,1.4 --duration 320 --json <rebuilt>.json
python3 lab/scripts/ts-remux-oracle.py <source>.ts <rebuilt-frame>.ts --rate 11000000 \
  --avail frame --delay 0,0.025,0.05 --duration 320
python3 lab/scripts/ts-tstd.py <rebuilt>.ts --skip 20 --window 2 --offset-scan -500,500,25
tsp -I file <rebuilt>.ts -P continuity -P pcrverify -O drop
```

A capture with a PCR discontinuity is cut after it first, for example with
`tail -c +$((188*<packet>+1))`.

## Corrections

- **The approximate `tstd` flag on the media-aware lane was attributed to the source content.**
  [T2](test-2-media-aware-transparency.md) read the harness's fixed-leak flag as "a property of the
  input content". Calibrated, the source passes every buffer at an offset of exactly +0 ms. The
  overflows belong to the lane's packet order. Rule ([method notes](method-notes.md#a-p1p2-pass-is-not-a-conformant-transport-stream)):
  a buffer-model flag is attributed only with a calibrated model, the source graded as the control,
  and a transparent transport through the same groomer.
- **The SRT control was reported as passing every buffer.** It passes every transport buffer and
  every decoder buffer in every 2 s window. Over the whole capture, the arrival-clocked groomer's PCR
  fails its decoder buffers at every offset, as it fails the lane's. The overstatement had reached
  the paper, where it has been corrected. Rule ([method notes](method-notes.md#a-transparent-control-through-an-arrival-clocked-groomer-attributes-the-transport-buffers-not-the-decoder-buffers)):
  an arrival-clocked control attributes the transport buffers only. A whole-capture decoder grade
  needs a stream-clocked control.

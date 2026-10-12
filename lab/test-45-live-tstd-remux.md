# Test 45 — A live T-STD re-multiplexer behind the media-aware lane

**State: questions 1–3 answered on two clips, loopback, for a Python re-multiplexer. Questions 4
and 5, put to upstream's merged export: across hosts two exports are byte-identical for 120 s, and
over 2,100 s the export stays conformant across three source joins while its clock follows a source
25 ppm fast at its slew limit, reaching +4.6 ppm; behind a source 4 ppm fast it settles after about
100 min. PCR_FO passes; PCR_DR fails, on the output's own 1 ms departure steps. On the live feed,
a conformant source that fills its 25 Mb/s multiplex, current `main` stops within 10 s on audio
whose PES begin mid-frame; with that and its video admission fixed in a scratch build it passes at
26 Mb/s, but not at the source's own rate** (§ *Questions 4 and 5, put to the merged export*).

- **A live re-multiplexer makes the media-aware lane's wire T-STD-conformant.** Fed nothing but what
  a subscriber has — each PID's packets in order, when each arrived, and the timestamps they carry —
  a real-time scheduler produced a multiplex that passes every buffer of the calibrated grader over
  the whole capture, and TR 101 290 P1/P2 on the same bytes, with no packet sent late. This is
  [T44](test-44-tstd-grading.md)'s offline oracle made causal and run in real time.
- **It costs 2.20 s of presentation latency on this build, and the lane decides most of it.** About
  1.2 s is the lane's own transit, measured on the audio, which the exporter does not hold. About
  0.4 s comes from the exporter's ordering: it writes each video frame once the audio has passed the
  frame's PTS, and authors that frame's DTS 400 ms earlier. The remaining 0.6 s is the lead the
  re-multiplexer adds to rebuild the decoder pre-load that this ordering removes. Searching the lead
  downward, 0.6 s is the lowest measured to pass — 550, 500 and 400 ms all fail the T-STD, and the
  video's margin crosses zero between about 545 and 560 ms, which is where a rate-limited bound
  derived independently from the frames puts it.
- **Byte-faithful carriage on the same rig conforms at a twentieth of that.** Through the
  stream-clocked groomer at a 100 ms cushion, UDP passes the grader and P1/P2 at 113.7 ms
  presentation latency, but only after the groomer's first 5 s, which a cap below its start-up
  backlog damages. Over SRT at a 120 ms latency it presents at 234.0 ms, but lost one burst in 288 s
  that SRT did not recover.
- **The lane's delay takes about 50 s to settle after a subscriber joins.** It grows by about 630 ms
  on every PID together. A stage that fixes a clock in the first seconds, as the re-multiplexer did
  with a 5 s warm-up, is overtaken by the lane.

Measured at P1, captured from the wire, wire domain, loopback, one clip, exporter `ffa5b81b`, the
re-multiplexer in Python. Two conformant runs, 270 s and 210 s on a clip each, and three shorter
leads on the primary clip that fail. Hardware: not run. The T-STD figures are from
[`ts-tstd.py`](scripts/ts-tstd.py) as corrected in [T46](test-46-tstd-check-cross-validation.md); that
correction moved no verdict on any capture graded here, only the counts and margins below.

## Objective

[T44](test-44-tstd-grading.md) showed that the lane's TS-out fails the T-STD, and that an offline
scheduler which reorders each PID's packets against the T-STD repairs it. The oracle had advantages a
live subscriber does not: the whole capture in hand, and the input's own PCR as a clock. This test
asks the P0-l questions of a live implementation:

1. **Can a real-time re-multiplexer, using only what a subscriber has, make the lane's wire
   T-STD-conformant?**
2. **At what latency, referenced to when a decoder presents each picture, and whose latency is it?**
3. **How does that compare with byte-faithful carriage at equal conformance, on the same rig?**
4. **Clock recovery** — locking the output clock to a remote source's rate from the timestamps alone.
5. **1+1 determinism** — two legs rebuilt byte-identically from a schedule computed from the stream.

Questions 4 and 5 were not put to the Python re-multiplexer. They were put to upstream's merged
export, with criteria fixed below.

## Pass criteria

Set when the tool was built, before the conformant run and the comparators. A configuration passes
only if all three hold:

1. **[`ts-tstd.py`](scripts/ts-tstd.py) passes the egress capture after a 5 s skip**: 0
   transport-buffer overflows, no decoder-buffer underflow or overflow on the stream's own PCR (the
   joint legal offset contains +0 ms), and every 2 s window legal.
2. **TR 101 290 P1/P2 on the same bytes, over the whole capture**: 0 continuity errors, 0 PCRs outside
   ±481 ns (`pcrverify --absolute --jitter-max 13`, given the carrier rate), 0 PCR intervals over
   40 ms.
3. **For the re-multiplexer, its own count**: 0 packets sent after their deadline, 0 left unsent. Its
   count is not the verdict; criterion 1 is.

Latency is quoted as presentation latency, with delivery latency beside it, and only for a
configuration that passes.

Two things were settled after the runs. `pcrverify` is given the carrier rate, which an existing
method rule requires ([method notes](method-notes.md) §2, *Pass `pcrverify --bitrate` explicitly*)
and the rig had not applied. And the comparators, which fail
criterion 2 only in the groomer's start-up or on one transport loss, are also reported for the part
of each capture that passes, with that part stated.

**Questions 4 and 5, and another profile, asked of the merged export.** Upstream's `moq export ts`
now schedules against the T-STD itself and steers its clock to the source's
([T47](test-47-fixed-delay-export.md)), so it is the live re-multiplexer these are put to, on
`f8215bc47`. Fixed before the runs, with T47's criteria 1–4 (both T-STD checks, P1/P2, the whole
capture, every unit of every track):

- **Clock recovery across hosts.** Relay and importer on one host, the clip looped four times by
  [`ts-seamless-loop.py`](scripts/ts-seamless-loop.py), whose joins pass the T-STD, paced 25 ppm fast (`tsp -P regulate --bitrate` at the CBR rate plus 25 ppm, inside the
  30 ppm a source is allowed), the export at 1 s on a second host, 2,100 s. It passes on criteria
  1–4, its output PCR within 30 ppm of its host's clock on the whole-run fit (PCR_FO), and a change
  of at most 0.075 Hz/s between consecutive 600 s windows (PCR_DR). The source's rate, from a tap on
  the origin against that host's clock, and the output's in each window are reported, as how far the
  export followed the source.
- **Drift rate on PCR arrivals, and settling**, fixed after the 2,100 s run put the picture tap's
  floor at a third of the limit. As that run, but the loop eight times (4,631 s), paced 4 ppm fast,
  for 4,500 s, with each PCR's arrival stamped on both hosts (`t18-latency.py tap --pcr`, graded by
  [`ts-pcr-rate.py`](scripts/ts-pcr-rate.py)). It passes on criteria 1–4; PCR_FO within 30 ppm on
  the whole-run fit; PCR_DR at most 0.075 Hz/s between consecutive 600 s windows, the arm void
  rather than passed unless the tap's floor on such a difference is under a third of that; and
  settled, the last 600 s window's output rate within 0.5 ppm of the source's. Predicted by
  simulating the steering law before the run: the output slews at its cap past the source's rate,
  to about 6.7 ppm near 40 min, to win back the delay it lost catching up, and is within 0.5 ppm
  by about 55 min.
- **Why the clock had not settled**, fixed after that run. As that run for 7,200 s (the loop 13
  times), the export logging each steering step: its estimate of the source's rate, the phase it
  steers on, the gap it is closing, its target rate and its rate (one log line on `f8215bc47`, on
  the export's host only). If over the last 30 min the estimate is within 0.5 ppm of the source's
  rate on the taps while the output is more than 0.5 ppm past it, the steering does not converge on
  a correct estimate. If the estimate is itself more than 0.5 ppm past the source's, the export
  follows what it measures, and the steered phase against the source's tapped rate says whether
  arrivals came earlier through the run, the lane's delay falling. Settled as before.
- **1+1 across hosts.** Two exports at 1 s of one broadcast, one on each of two hosts, started at
  the same wall-clock instant, 120 s. It passes if the captures are byte-identical from the first
  packet both carry; otherwise the identical fraction after one counter offset per PID
  ([`ts-cc-merge.py`](scripts/ts-cc-merge.py)) and the first difference are reported.
- **Another profile and rate.** `testloop.ts`, H.264 High 4:2:2 at 25 Mb/s in a 27.5 Mb/s CBR
  multiplex with MP2 audio, on loopback at 1 s and 500 ms, 120 s each. Each passes on criteria 1–4.
- **Real playout that fails the T-STD itself.** Two off-air recordings, each failing `ts-tstd.py` as
  a source: a playout chain's 1080i29.97 H.264 Main with eleven AC-3 services, SCTE-35 and SMPTE
  2038 in a 36.6 Mb/s multiplex, whose video packets overrun TB at the leak its HRD sets; and a
  1080i25 H.264 service with MPEG and AC-3 audio, teletext and SCTE-35 at 25 Mb/s, whose audio
  arrives up to 352 ms after it decodes. On loopback at 1 s, 110 s each. Not graded as the export's
  pass or fail, since a source can make a conformant output impossible: reported is whether the
  export runs the capture and, if it does, criteria 1–4 on its output, to show what a real feed
  does to it.
- **The live feed (P0-l, P1-u).** A 300 s capture of the live contribution feed at its hand-off
  (1080i25 H.264, 25 Mb/s CBR with no nulls, MP2 and AC-3 in PES not aligned to frames, teletext,
  SCTE-35), first graded as a source by `ts-tstd.py` over the whole capture and T33's gate; a source
  that fails is reported as the recordings above are. Through current `main`'s export on loopback
  at 1 s, 280 s. It passes on criteria 1–4, with `compliance.py`, which refuses the source's
  unaligned audio, applied to the output only. For each audio PID (P1-u), also: every PES flagged
  `data_alignment_indicator` starts on a frame sync; the output's frames are the source's, byte for
  byte and in order, none missing or repeated between its first and last frame except in the last
  second; and each PES's PTS advances on the last by the duration of the frames between them, no
  two equal. A failure is reported per PID with its first instance.

## Instruments

### The live re-multiplexer

[`ts-remux-live.py`](scripts/ts-remux-live.py), written for this test. It takes `moq export ts` on
stdin and sends RTP, seven packets a datagram, at a constant rate. It accepts the groomer's command
line, so [`t18-arm.sh`](scripts/t18-arm.sh) runs it with `PACER=` in the groomer's place.

- **The scheduler is the oracle's**: each slot goes to the available packet with the earliest decode
  deadline among those whose transport buffer and, where the T-STD sizes one, decoder buffer have
  room. Otherwise the slot is a null, and an adaptation-only PCR packet goes out whenever none has for
  25 ms. Transport-buffer sizes and audio B match [`ts-tstd.py`](scripts/ts-tstd.py); video is
  scheduled against the single cpb + BSmux + BSoh buffer the first instrument used (1,115,696 B on
  this clip). That bound is smaller than MB alone, so it cannot overflow 2.14.3.1's MB + EB leak
  model ([T46](test-46-tstd-check-cross-validation.md)). It does not model the leak's 24 Mb/s
  transfer into EB, so underflow is left to the grader. HRD parameters are read from the source's SPS before
  the loop starts.
- **Deadlines come from the stream as it arrives.** Video and teletext take the unit's DTS or PTS.
  Audio is split into frames as its bytes arrive, each frame known from its header, so a packet's
  deadline is the decode time of the frame holding its first byte. Every deadline is causal: nothing
  is scheduled against a packet that has not yet arrived.
- **The output clock is the decode timeline.** A slot's PCR is the system time clock at that slot,
  and the PTS and DTS pass through untouched, so the PCR-to-PTS offset is fixed by construction.
  What the tool chooses is where that timeline sits against the wall clock. During a warm-up it only
  observes: the latest any packet arrives against its own decode time fixes the offset, and the lead,
  `--latency-ms`, is added to it. Output then starts at once with nulls and PCR, the video from its
  next random-access indicator, and each other PES stream from its next unit boundary.
- **The clock never moves to absorb a late packet.** A packet that arrives later against its decode
  time than any in the warm-up spends the lead, and past it is sent late and counted. The output runs
  at the host clock's rate; rate recovery is not implemented.
- It drops input nulls and adaptation-only packets, rewrites continuity counters, and clears
  discontinuity indicators. `--trace` logs every PES start's arrival and decode time.

**Validation.** It was fed the source clip itself, played out in real time by `tsp -P regulate`, at a
50 ms lead and a 3 s warm-up, for 40 s. The output passes every buffer, with the joint legal offset
at [−25, +0] ms and 15 of 15 windows legal. It has 0 continuity errors and 0 PCRs outside ±481 ns,
a largest PCR interval of 25.2 ms, and presentation latency constant at 75.9 ms, with a 9.1 ms
spread and a −1.2 ms trend.

### Presentation latency

[`ts-decode-latency.py`](scripts/ts-decode-latency.py), written for this test. Delivery latency, as
[`t18-latency.py`](scripts/t18-latency.py) reports it, times a PES header from the source tap to the
egress tap. A re-multiplexer that delivers a picture early and shows it late, or the reverse, makes
that figure misleading. A T-STD decoder presents a picture when its clock reaches the PTS, so each
end's presentation time is the tap's arrival time for the header plus the PTS minus the capture's own
PCR-interpolated STC at that packet. The headline is the difference between the two ends.

Two choices matter:

- **Each end's clock is smoothed.** The per-header offset between wall clock and STC is replaced by
  its median over 5 s around the picture, as a receiver's clock recovery averages many packets. The
  source tap's per-header offsets scatter by about ±37 ms on the source's own timeline, because
  `tsp -P regulate` releases the playout in bursts. Unsmoothed, the smoke test read 75.5 ms with a
  74.3 ms spread; smoothed, 75.9 ms with 9.1 ms.
- **It is referenced to presentation, not decode.** The two agree when the egress keeps the source's
  DTS, as the smoke test and both comparators do. They differ on the lane, whose exporter authors its
  own DTS: on the conformant run the decode-referenced difference spreads over 521 ms where the
  presentation one is flat. That spread is the exporter's DTS moving against the source's, not
  latency.

**Validation.** On T44's stream-clocked SRT capture, which keeps the source's bytes and a fixed
PCR-to-PTS offset, it reads 2,033.1 ms with a 4.1 ms spread, against a delivery median of 2,033.0 ms.
A figure assumes the egress decodes on its own PCR, so it is quoted only where the capture passes the
grader.

## Environment

Loopback on one laptop. The [T18](test-18-delivery-latency.md) rig, with `ts-remux-live.py` in the
groomer's place at an 11 Mb/s carrier. Source `CNNiEMEA2.ts`, as in T44. Exporter `ffa5b81b`,
subscriber `--max-latency 500ms`, and the exporter's default null padding, which the re-multiplexer
drops. Taps on one host share one clock. The comparators feed the source's own bytes over UDP or SRT
to `mpegts-pacer` `5ab84cd --stream-clock`, with the cap one step above the cushion, because a
groomer that runs ahead settles at its cap ([T18](test-18-delivery-latency.md) § Corrections).

## Results

### The runs

| Run | Warm-up | Lead | Late packets (the tool's count) | Grader | P1/P2 | Presentation latency |
|---|---|---|---|---|---|---|
| smoke: source clip | 3 s | 50 ms | 0 of 230,895 | passes | passes | 75.9 ms |
| 1 | 5 s | 100 ms | **1,735,115 of 1,829,973**, of them 1,723,693 of 1,733,720 video | **fails**: every one of 10,481 video units underflows, median margin −504.7 ms; 1,663 MP2 and 1,131 AC-3 units; **19** video TB stretches not emptied within 1 s; 0 of 142 windows | passes | — |
| 2 | 60 s | 100 ms | **28,661–33,243 per 10 s**, throughout | **fails**: 6,901 of 8,687 video units, 32 MP2, 26 AC-3; **15** video TB stretches not emptied within 1 s; 0 of 116 windows | passes | — |
| **3** | **60 s** | **600 ms** | **0 of 1,676,219**, 0 unsent | **passes** | **passes** | **2,196.7 ms** |
| 4 | 60 s | 550 ms | 2,094 of 1,676,189, 0 unsent | **fails**: 37 of 9,532 video units underflow, margin min −79.5 ms; no joint legal offset; 127 of 130 windows. Both audio buffers and every transport buffer clean | passes | 2,226.0 ms † |
| 5 | 60 s | 500 ms | 595 of 1,683,713, 0 unsent | **fails**: 5 of 9,550 video units underflow, margin min −41.1 ms; no joint legal offset; 127 of 130 windows. Both audio buffers and every transport buffer clean | passes | 2,362.1 ms † |
| 6 | 60 s | 400 ms | 7,957 of 1,684,260, 0 unsent | **fails**: 65 of 9,549 video units underflow, margin min −134.2 ms; no joint legal offset; 120 of 130 windows. Both audio buffers and every transport buffer clean | passes | 1,246.6 ms † |
| **7: second clip** | **60 s** | **600 ms** | **0 of 1,300,115**, 0 unsent | **passes** | **passes** | **2,536.5 ms** † |

† Runs 4–7 do not share a join with each other or with run 3, and the lane's transit differs by about
a second between them, so their presentation latencies measure their own runs and not the lead or the
clip. Only run 3's figure is quoted elsewhere.

Run 3, the conformant configuration, in full. Every transport buffer passes, the video's peaking at
511 B of 512. The video decoder buffer has 0 underflows over 9,532 units, a minimum margin of 30.0 ms
and a median of 430.1 ms, and EB peaks at 784,021 B of 1,099,696.
Both audio buffers pass, with minimum margins of 111.2 ms (MP2, peaking at 3,345 B of 3,584) and
175.0 ms (AC-3, 5,459 B of 5,696). The joint legal offset is [−25, +0] ms, and 130 of 130 windows
are legal. P1/P2: 0 continuity errors,
0 PCRs outside ±481 ns, 0 of 10,644 PCR intervals over 40 ms, largest 25.2 ms. Output 13.5 % nulls.

Its presentation latency is flat: median 2,196.7 ms, p95 2,197.9 ms, maximum 2,199.3 ms, and a
+0.2 ms trend over 254.8 s. The minimum, 1,956.5 ms, is one host stall about 245 s into the output
that disturbed both taps, the source tap's clock offset by up to 660.5 ms. The 192 pictures below
2,190 ms all fall between 244.0 s and 249.3 s. Its delivery latency is a median 2,353.9 ms, spread
over 1,155.8 ms, because the scheduler sends video as early as the buffers allow and audio as late
as its small buffer requires. The egress pre-loads each picture by a median 447.3 ms, against the
source's 769.0 ms. The tool's scheduling loop fell behind by up to 167.7 ms, and no video packet
arrived with less than 374.9 ms of its 600 ms lead. Nothing was late.

**The conformant lead holds on a second clip, with more room.** Run 7 repeats run 3's
configuration on `CNNiEMEA.ts` — a different five-minute capture of the same service, the same
9,945,951 bps CBR mux and the same PID layout, so the rig and the 11 Mb/s carrier are unchanged. It
passes all three criteria over 206.3 s: nothing late of 1,300,115 packets and nothing unsent; 0
continuity errors, 8,255 PCRs all inside ±481 ns and 0 discontinuities; every transport buffer clean;
0 decoder underflows on all three streams; the joint legal PCR offset [−100, +0] ms, which contains
+0 ms; and 100 of 100 two-second windows legal. Its lane held the steady-state band (a 31 ms spread
against the warm-up anchor), so this is a clean cell.

Its margins are wider than run 3's throughout. The video decoder's minimum margin is 144.7 ms
against run 3's 30.0 ms, its first percentile 247.4 ms against 141.1 ms, and the video transport
buffer's longest non-empty stretch 0.023 s against 0.192 s. So of the two clips the primary one is
the harder, and the 600 ms lead is not tuned to it. Applying the margin slope measured on the primary
clip, that slack *implies* a floor some 160–210 ms below the primary clip's, which is not measured —
the run was made at 600 ms only, to ask whether the published lead generalises rather than to find
this clip's floor. The run is shorter than run 3 (210 s of graded output after the warm-up,
not 270 s) because the publisher loops the source with `--infinite` and this clip is 300 s long, so a
longer run would have crossed the loop point.

### What the lane delivers

The trace of every PES arrival at the re-multiplexer's input, taken on runs 2 and 3, explains both
failures and the conformant lead.

- **The lane settles over about 50 s.** Against each unit's decode time, arrivals get later by about
  630 ms over the first 40–60 s after the subscriber joins, on the video, both audio PIDs and the
  teletext together, and are then flat for the rest of the run. Over run 3 the source tap's clock
  offset moves by 5.8 ms and the egress tap's by 3.7 ms, both about 20 ppm, consistent with the
  host's wall clock slewing against its monotonic clock, so the settle is not the playout. Run 1's
  5 s warm-up anchored inside this transient, and was overtaken by it.
- **In steady state every video frame arrives at the same point of its decode timeline, and the
  audio 420 ms earlier.** Each video frame arrived whole, and its header's arrival against its DTS
  stayed within a 26 ms band. Both audio PIDs arrived 404–427 ms earlier against their decode times
  than the video did against its own.
- **That is the exporter's ordering** (read from its code at `ffa5b81b`, and consistent with the
  measured offset). The exporter holds one pending frame per track and muxes the one with the
  smallest PTS. The source sends audio just in time, so a video frame goes out once the audio has
  passed that frame's PTS. The exporter also authors every video DTS itself, as the PTS less the
  catalog's reorder depth, 400 ms on this clip, which is also the clip's largest reorder. Measured on
  9,650 pictures, the egress DTS runs 0–280 ms earlier than the source's, and PTS − DTS is 100–400 ms
  on every picture. The source's is 0–400 ms, and 0–120 ms on 72.5 % of pictures. So each video
  frame arrives about 400 ms after its own DTS relative to the audio's timeline. That makes the video
  the binding stream, where on the source it is the audio ([T44](test-44-tstd-grading.md)).
- **The lane's own transit is 1.2 s.** From the source tap to the exporter's output, after the
  settle, MP2 takes a median 1,203 ms (1,191–1,429 ms over 1,224 PES) and AC-3 1,224 ms
  (1,215–1,438 ms over 918 PES). The exporter does not hold the audio, so this is the lane: publisher,
  relay, subscriber and exporter together.

**Why a 100 ms lead fails once the lane has settled.** In run 2 no video packet arrived with less
than 97 ms of lead, and still some 30,000 went out late every 10 s. A frame that arrives whole, just
before its deadline, has to drain through the video transport buffer's 10.56 Mb/s leak. The 11 Mb/s
carrier also carries audio. The encoder's HRD schedule spread each frame ahead of its DTS, and the
exporter's ordering has gathered it back to the DTS, so the re-multiplexer has to recreate that
spread as delay. The grader agrees: run 2's video is legal only with 425–500 ms more pre-load than it
had, 525–600 ms of lead in all.

Computed from run 2's 7,597 matched frames, their sizes (median 96 packets, largest 1,579, 297 KB)
and their arrival offsets, a server that drains them in order at a constant rate needs this lead to
finish every frame by its DTS:

| Drain rate | Lead needed |
|---|---|
| 10.56 Mb/s, the video TB leak | 515 ms |
| 10.40 Mb/s, about what the carrier leaves the video | 545 ms |
| 10.00 Mb/s | 627 ms |

Run 3's 600 ms sits just above the middle figure, and sent nothing late.

**Searching downward, 600 ms is the lowest lead measured to pass.** Runs 4–6 repeated run 3's configuration at 550, 500 and 400 ms, and all three fail — on the
same three counts each time: packets sent after their deadline, video decoder underflows, and no
constant PCR offset legal for all three buffers at once. All three still pass P1/P2 on their own
bytes (0 continuity errors, 0 PCRs outside ±481 ns, 0 intervals over 40 ms), so what a smaller lead
costs is the T-STD and nothing else.

The video decoder's margin tracks the lead almost one for one. Across the runs whose lane held its
steady-state arrival band — 600, 500 and 400 ms — the minimum margin over about 9,500 units falls
from +30.0 ms to −41.1 ms to −134.2 ms, a slope of 0.7–0.9 ms per ms of lead removed, crossing zero
between about 545 and 560 ms. That agrees with the rate-limited bound derived above from frame sizes
and arrival offsets, which put the floor at 545 ms for the drain rate the carrier leaves the video.
Two independent routes to the same figure.

**Run 4, at 550 ms, is worse than run 5 at 500 ms, and the lane is why.** Its multiplex is not a
counter-example to that slope: in run 4 one per cent of video PES arrived at least 199.5 ms later
against their own decode times than the warm-up anchor, the worst 260.9 ms later, where runs 5 and 6
held the 25 ms band that run 3 established as the steady state. A lead set at the rate-limited floor
has nothing left for an excursion of that size, so the floor is a bound and not a safe set-point —
the deployable lead has to cover the lane's worst excursion as well as the drain.

**The instrument's own stalls are not what fails the sub-600 runs.** The scheduling loop's worst lag
was 6.8 ms in run 5, 26.4 ms in run 4 and 95.9 ms in run 6, against 167.7 ms in the conformant run 3:
the lag does not order the failures, and the one run that stalled worst is the one that passed. The
600 ms lead absorbed a 167.7 ms stall; the sub-600 failures are the drain, not the laptop.

**Presentation latency is not comparable across these runs**, because the lane's transit is set by
the join rather than by the configuration. Source tap to re-multiplexer input on the video, after
each run's settle, the median is 1,708.6 ms in run 6, 2,542.8 ms in run 4 and 2,728.1 ms in run 5 —
about a second of spread across three leads spanning 150 ms. Within a run it is as flat as ever (spreads of
4.1–4.4 ms), so the figures in the table measure their own runs and the 2.20 s of run 3 remains the
conformant figure. A latency comparison needs the runs it is drawn from to share a join.

### Where the 2.2 s goes

| Component | ms | Evidence |
|---|---|---|
| The lane's transit, source tap to exporter output | about 1,200 | measured, on the audio |
| The exporter's PTS ordering against its own DTS reserve | about 400 | measured as the video's arrival offset against the audio's (420 ms); mechanism from the code |
| The re-multiplexer's lead | 600 | measured as the lowest lead that passes; its floor derived from measured frames at about 545 ms, and measured to lie between 550 and 600 ms |
| **Sum** | **about 2,200** | measured presentation latency 2,196.7 ms |

The re-multiplexer's own share is the 600 ms, and only a lane that delivers frames ahead of their
decode time could shrink it. The 400 ms belongs to the exporter's ordering. A downstream stage could
re-derive each picture's DTS from the stream's reorder structure, returning 0–280 ms to most
pictures and nothing to those at the full 400 ms reorder. Whether that lowers the rate-limited lead
was not computed. The 1.2 s is the lane at this build and setting, and this test did not locate where
it is spent. [T18](test-18-delivery-latency.md) measured the lane's video delivery, groomer
included, at 126–146 ms on loopback on the `main` of the time, `eab96019`.

### Comparators

The source's own bytes over UDP, and over SRT at a 120 ms latency, into the stream-clocked groomer
at a 100 ms cushion and a 150 ms cap. Graded the same way.

| | UDP | SRT, 120 ms |
|---|---|---|
| Grader, after 5 s | **passes**: 0 overflows, 0 underflows, joint [+0, +100] ms, 144 of 144 windows | **fails**: 4 MP2 and 7 AC-3 underflows, joint [+100, +100] ms only; 141 of 141 windows legal |
| P1/P2, whole capture | **fails**: 90 continuity errors, 68 PCR intervals over 40 ms (largest 98.6 ms), 68 PCRs outside ±481 ns | **fails**: 83, 53 (98.6 ms), 53 |
| P1/P2 after the groomer's first 5.3 s | **passes**: 0, 0, 0 | 5 continuity errors, all at 139.7 s; 0, 0 |
| Presentation latency · delivery, median | **113.7 ms**, spread 4.4 ms · 113.6 ms | 234.0 ms, spread 4.4 ms · 233.9 ms |

- **Every whole-capture P1/P2 failure on the UDP arm is in the groomer's first 5.3 s.** The first
  picture it sent had reached the source tap 4.6 s earlier, and within the next 0.17 s it skipped
  through 4.5 s of pictures, down to its 150 ms cap. Its first 864 packets span 5.3 s of PCR, the PCR
  advancing 58–99 ms every few packets. After that the capture is clean. T44's stream-clocked arms,
  at a 2,500 ms cap, show none of it; on its SRT arm the first picture went out 2.03 s after the
  source sent it, inside the cap.
- **The SRT arm lost one burst it did not recover.** At 139.7 s it lost 22 packets across five PIDs
  before the groomer, which kept its own schedule, so no PCR failed. The 11 underflows are that loss:
  graded from 20 s to 139 s the capture passes with a joint offset of [+0, +25] ms, and from 145 s to
  its end at [+0, +0] ms.
- **Presentation and decode latency agree on both arms**, as they must where the DTS is the source's.

**At equal conformance, in steady state, byte-faithful carriage over UDP presents each picture at
113.7 ms against the re-multiplexed lane's 2,196.7 ms**, on the same rig and clip. Neither starts
cleanly and at once: the re-multiplexer sends nothing for its 60 s warm-up, and the groomer at this
cap damages its first 5 s. SRT at 120 ms is not conformant over this capture, on a single loss.

### Questions 4 and 5, put to the merged export (`f8215bc47`)

P1, wire domain, `moq-lite-06`, the origin on one EC2 host and the export on another in the same
region, BBRv3 (`delay`), [`t47-xhost.sh`](scripts/t47-xhost.sh).

- **Clock recovery across hosts: the output follows the source at its slew limit; PCR_FO passes,
  and PCR_DR is beyond this instrument.** 2,100 s, the source at +25.02 ppm against the origin's
  clock (+24.8 to +25.2 ppm in every 600 s window). Across all three joins it passes criteria 1–3:
  1,046 of 1,046 windows with every buffer legal (least margin 362.7 ms video, 68.1 ms MP2,
  143.6 ms AC-3; EB peak 99.8 %), `compliance.py`, 83,939 PCRs within ±481 ns, 0 continuity
  errors and 0 late drops. Every video, audio and teletext unit and every SCTE-35 cue is carried.
  Three SCTE-35 heartbeat sections on PID 141 are missing, one 0.4 s after the span starts and two
  in its last 1.03 s: one over the grader's edge allowance, so criterion 4 fails by its rule at
  the edges, with nothing missing inside the run. **The output's rate against its own host's clock
  rose from −0.04 ppm in the first 600 s window to +4.60 ppm in the last**, a trend of 2.94 ppb/s
  (0.0795 Hz/s) against the export's cap of 2.78 ppb/s (0.075 Hz/s), and +2.80 ppm on the whole-run
  fit, so PCR_FO passes. PCR_DR as fixed fails, at 0.106 Hz/s between consecutive 600 s windows,
  and that is the egress tap's floor rather than the clock's: the export writes on 25 ms slots,
  so each picture's arrival is quantized by ±12.5 ms, about 0.34 ppm of slope in a 600 s window
  (0.40 ppm measured about the trend), or 0.025 Hz/s on the difference of two windows. The source
  tap, written continuously, has 0.014 Hz/s. A clock slewing exactly at the limit cannot pass this
  test on this tap. Presentation latency was 2,277.5–2,327.1 ms and rose 31.8 ms from the first
  third to the last, the rate gap integrated over the run (about 22.5 ppm over 1,400 s). Following
  25 ppm fully at the cap takes about 2.5 h (derived).
- **Drift rate on PCR arrivals: criteria 1–4 and PCR_FO pass, PCR_DR fails as fixed, and at 75 min
  the output had not settled on the source's rate.** 4,500 s, the source at +4.02 ppm against the origin's clock (+3.85
  to +4.16 ppm in every 300 s window). The hosts' clocks agree within 0.05 ppm (each one's chrony
  skew), and the loop's media clock follows its PCR within 0.02 ppm. PCR_FO is +5.74 ppm on the
  whole-run fit. PCR_DR is 0.114 Hz/s between the first two 600 s windows and 0.085 between the third
  and fourth (the other four pairs 0.032–0.067). The output's rate in successive 600 s windows was
  +0.11, +2.65, +3.93, +5.82, +7.31, +8.02 and +9.03 ppm, the last 5.06 ppm above the source's.
  - **Criteria 1–4 pass over the whole run, at the 35 min runs' margins.** All 2,246 windows
    (least margin 362.7 / 68.1 / 143.6 ms on video, MPEG audio and AC-3); compliance PASS in each
    of four consecutive segments covering every packet after the 5 s cut, since the checker holds
    a whole capture in memory and the 5.6 GB one exhausted the host; all 179,932 PCRs within
    ±481 ns; every PES unit of the four PES PIDs present, each SCTE-35 PID one section short,
    inside the grader's edge allowance; no late drops.
  - **On the wire the clock moves in 1 ms steps.** The export writes each slot when tokio's
    millisecond timer fires, so a slot leaves at the clock's instant rounded up to the next tick,
    and the output's phase against the host stays flat for minutes and then steps 1 ms. A 600 s
    window resolves a rate only to about ±1.67 ppm of that, ±0.075 Hz/s on a difference: the limit
    itself. The tap's floor (0.001 Hz/s) assumes white noise and does not see it, so the void clause
    did not trigger. The steps are the output's, and an analyser on the wire would see them too.
  - **Read from when the steps fall, the clock slewed at its cap (0.075 Hz/s) to 6.7 ppm at 2,550 s,
    as predicted, then kept rising, more slowly, to 8.3–9.1 ppm over the last 800 s**, where the
    prediction had it back at the source's rate by 55 min. It gained 24.1 ms on the host against the
    source's 18.1 ms, so it ended about 6 ms shallower than it began while still steering as if it
    had slack to spend: slack the logged run below traces to the export's first 20 s.
  - The out-of-tolerance counter reads 19, all within the first 40 s, while the rate window held
    under a minute of floors and the estimates ran from −471 to +211 ppm.
- **Settling, with the steering logged: the clock settles after about 100 min on a correct
  estimate, once it has spent at its slew limit 10–12 ms the lane gave back in its first 20 s.
  PCR_FO passes; PCR_DR fails as fixed, on the same 1 ms steps.** 7,200 s (the loop 13 times), one
  log line per steering step (4,572 steps), the source at +4.02 ppm against the origin's clock
  (+3.92 to +4.07 ppm in every 600 s window); no late drops. The output's rate in successive 600 s
  windows was +0.28, +2.04, +3.98, +5.70, +7.49, +8.59, +9.35, +8.45, +6.98, +5.47 and +3.91 ppm.
  - **The estimate follows the source, and the lane held.** Over the last 30 min the export put
    the source at +4.22 ppm, against +4.02 ppm on the source's tap; the hosts' clocks were not
    compared on this run. The earliest arrival phase it steers on rose 26.3 ms between the first
    and last 600 s windows, 6,600 s apart: 3.99 ppm, the source's rate alone.
  - **The slack it spent was there within 20 s.** At its first step, 5 s in, frames were arriving
    6.0 ms ahead of the delay, and 12.1 ms ahead by 23 s, while its estimate of the source swung
    from −147 to +547 ppm on a nearly empty window: the lane settling after the export had anchored
    on its first frame. Catching the source's rate from zero at the cap added about 3 ms, the gap
    peaking at 12.7 ms in the fourth window. The steering then closed it no faster than the cap can
    stop on it, taking the output 5.3 ppm past the source in the seventh window and the gap through
    zero near 5,000 s. It overshot by 0.96 ms and was still 0.75 ms short of the delay in the last
    window, its pull holding the target 1.6–1.8 ppm below the source's rate to restore it. The prediction counted only the delay lost
    catching up, hence its 55 min; the 75 min run ended on the way up.
  - **Settled as fixed.** In the grader's last full window (6,010–6,610 s) the output is within
    0.01 ppm of the source, and over the last 30 min it is +4.22 against +4.02 ppm. The final
    588 s, not a full window, read −0.57 ppm, within the error that 1 ms steps every 250 s leave in
    a 600 s fit.
  - **PCR_FO is +6.54 ppm on the whole-run fit. PCR_DR is 0.077–0.088 Hz/s on each of the first
    four pairs of 600 s windows (0.034–0.070 on the other six), while the logged rate changed by at
    most 1.666 ppm a window, 0.0750 Hz/s.** The difference is the steps: the output's phase against
    the host held at −1.15 ms from 620 s to 1,070 s, then at −2.1 ms, and each window's fit lies
    within 0.46 ppm of the logged rate.
- **1+1 across hosts: byte-identical.** Two exports at 1 s, one on each host, began 5 ms apart and
  are identical from the first packet through all 782,483 packets both captured, the longer capture
  ending 165 packets later. This is 120 s, before either export's clock has steered, so whether two
  hosts' steering keeps the PCR values equal over hours is not measured.
- **Another profile: not answered, because `testloop.ts` is not a conformant source.** Its own
  audio transport buffers overflow (94–622 packets per PID in 120 s), and each video PES carries
  several access units, which `ts-tstd.py` refuses to grade and `ts-pid-complete.py` miscounts. On
  loopback the export exits after 67 pictures at both 1 s and 500 ms, on *missed a decode deadline
  on PID 48* (the video). The export's video leak is 1,200 × MaxBR, 24 Mb/s at this level 4.0,
  which is the Rbx `ts-tstd.py` uses too. A scratch build with High 4:2:2's cpbBrNalFactor instead
  (96 Mb/s) runs the whole capture with every audio unit, but its video fails both T-STD checks,
  so the factor is not the cause. Another profile needs a source that passes the T-STD itself.
- **Real playout: a PMT longer than one packet stops the export before its first packet; a damaged
  25 Mb/s service runs.** On loopback at 1 s, `f8215bc47`. The 36.6 Mb/s playout recording, whose PMT
  is one 391-byte section over three packets (eleven AC-3 services with their descriptors, SCTE-35,
  captions), is imported whole. The export subscribes to its fifteen tracks and exits 2 s later with
  nothing written, on *failed to write whole buffer* in `mpeg2ts`'s PSI writer, which writes a
  section into a single packet. The PMT-split fix (`d7dc586e7`, unmerged) writes the section whole,
  with no continuity error, but the export then stops after 6 pictures on *missed a decode deadline on
  PID 201*, the first AC-3, at both 1 s and 2 s. That PID's audio is on time in the source (no
  underflow, margin ≥ 38.7 ms over the first 13 s) while the source's video overruns TB, so this
  recording fails the T-STD too and is no clip for P0-l. The 1080i25 service's PMT is 153 bytes, and
  the export runs its 110 s in 25 Mb/s CBR, with all 4,146 PCRs within ±481 ns and no interval over 25 ms. Of the source's own
  faults, the late audio is repaired: no audio unit decodes before it has arrived, against 103–301 a
  PID in the source, as much as 394 ms late. The output adds faults the source does not have. Video
  overruns TB on 36 % of its packets (peak 1,311 B), though the export reads the SPS's HRD and holds
  video to its 21.6 Mb/s Rx, 358 packets a 25 ms slot (logged by a scratch build; reproduced). The
  slot's layout spaces each PID by its own count, so PIDs with equal counts land together: in a full
  slot the three MPEG audio PIDs, five packets each, arrive as one cluster, and between clusters video
  runs 12–13 packets back to back between nulls at the 25 Mb/s multiplex rate, each adding 26 B to a
  TB that drains at Rx. A unit test laying out that slot overruns TB on 932 of 1,436 video packets
  over four slots (peak 1,067 B); the same packets in smooth weighted round-robin peak at 459 B, so
  the slot is feasible and the layout is the cause. No clip here before ran its multiplex faster than
  its video's Rx, which is when this shows. With the slot interleaved (`main`, `9f1dd1afd` and
  `90500867d`, same rig, identical) video overruns TB on 88 of 943,296 packets in 32 events (peak
  646 B), one video frame is dropped late, and the PCR stays within ±481 ns. **The residue is the
  same limit at the slot's edges.** Every overflow falls in three slots, one at 14.3 s and two
  adjacent at 35.8 s. The first slot at each time opens after a slot the paused video left empty (this
  recording's video stops for over a second at a time), with the video at its admission cap of 358
  packets and its TB empty; the overflow carries into the next slot. The interleave spreads the
  video over the positions it counts, and the program tables go ahead of it outside that count. Two
  table packets leave room: the 36 such slots peak at 232–459 B.
  The two overflowing slots carry PAT and PMT twice, written for a keyframe and for the 500 ms
  repeat in the same slot, and peak at 552 and 646 B; the duplicate is also what overflows the
  system TB by four packets. A scratch build dropping the duplicate as upstream's draft does,
  padding the slot back at its end, clears the system TB and leaves the video overrun (65 packets,
  same peak), since the padding sits outside the count too; charging the tables to the null lane's
  share instead made it worse (479 packets, peak 746 B). A fix has to keep a capped video lane
  spread over every position it can drain in. Eight AC-3 units stay in B up to 1.05 s. The
  recording has 1,398 continuity gaps of its own across every PID, so its completeness grade (a
  third of the video and a tenth of each audio missing) measures the recording, not the export.
- **The live feed (P0-l, P1-u): current `main` stops on it; fixed, it passes only above the
  source's rate.** The capture passes as a source: T33's gate, and `ts-tstd.py` with every 2 s
  window legal (video EB peak 2.99 of 3.75 MB, margin ≥ 510 ms; audio margins ≥ 5.8 ms). Its SPS
  has no HRD, so the video's buffers are level 4.0's: Rx 36 Mb/s, and Rbx 24 Mb/s on payload. On
  loopback, `90500867d` exits 8–10 s in on *missed a decode deadline on PID 123*, the AC-3, at 1 s,
  at 2 s and with the multiplex raised to 26 Mb/s. Its AC-3 split parses sync frames from each
  PES's first byte; this feed's PES (6,978–7,162 B, about 9.3 frames of 192 kb/s) begin mid-frame,
  the parse fails, and the whole PES goes out as one unit larger than the receiver's 5,696-byte
  buffer, which admission never completes. Two scratch changes, in turn:
  - *The partial frame carried into the next PES*, the PES's PTS timing the first frame beginning
    in it: every AC-3 frame goes out, a frame a PES. The export then stops after 38 s on the video,
    2.4 % of its output nulls. It admits video at Rbx counted in whole packets, less a packet a slot
    of slack and the clock packet: 396 packets a 25 ms slot, about 2.9 % below the leak in payload,
    while this encoder fills the leak (407.6 packets a slot on average).
  - *Video admitted at Rbx in payload bytes*, without the slack: it stops after 148 s at 1 s and
    193 s at 2 s, on the video, whose bytes are the source's. At 26 Mb/s and 1 s it runs the capture
    and passes criteria 1–4 (136 of 136 windows; video margin ≥ 617 ms, EB peak 3.14 MB; every PCR
    within ±481 ns, largest interval 25.0 ms; every unit of every track) and P1-u: all 11,474 MP2
    and 8,601 AC-3 frames are the source's, in order, a frame a PES, flagged aligned, each PTS one
    frame on from the last.

  That output's non-null packets average 25.017 Mb/s. Against the source it spends about 35
  packets a second more on MP2 and 24 on AC-3 (a frame a PES, against about twelve and nine), 40
  on clock packets (the source carries PCR in video packets), and 25 fewer on tables. A source that
  fills its multiplex cannot be re-multiplexed at its own rate this way; a longer delay only
  postpones the stop (derived from the average).

## Conclusions

**Established** (P1, wire, loopback, one clip, `ffa5b81b`, one conformant run):

- **The media-aware lane's TS-out can be made T-STD-conformant live, by a subscriber-side
  re-multiplexer that sees only the lane.** Nothing it used is unavailable to a real subscriber: the
  packets in order, their arrival times, their timestamps, and buffer parameters from the source's
  own SPS. That last is calibration a deployment would take from the stream or the catalog.
- **The output clock does not need the source's PCR.** A PCR stamped from the decode timeline keeps
  the PCR-to-PTS offset fixed by construction; the scheduler's own byte clock gives a largest PCR
  interval of 25.2 ms and every PCR within ±481 ns.
- **On this build the latency is set by the lane's delivery schedule, not by the re-multiplexing.**
  Of the 2.2 s, about 1.2 s is the lane's transit and about 0.4 s the exporter's ordering. The
  re-multiplexer's 0.6 s lead rebuilds the pre-load that ordering removed.
- **Byte-faithful carriage keeps the T-STD at about 114 ms in steady state on the same rig**, through
  the stream-clocked groomer over UDP; about a twentieth of the re-multiplexed lane.
- **A live stage on this lane must anchor after the lane settles.** The lane's delay grows by about
  630 ms over the first 50 s, and a fixed clock cannot follow it. At the ±30 ppm system-clock
  tolerance, absorbing 630 ms would take almost six hours (derived).

**Not established.**

- **Clock recovery.** One host, one clock. A remote source's rate differs from the subscriber's by
  up to the encoder's tolerance, and the output clock would have to track it from arrivals alone,
  within the frequency-offset and drift-rate limits. The merged export, across hosts, follows a
  source at its slew cap. Over 75 min behind a source 4 ppm fast it passed the source's rate and
  did not settle, ending 5 ppm above it, and why is not established. Its wire phase moves in 1 ms
  steps, so on arrivals its drift rate fails at 600 s windows.
- **1+1 determinism.** This schedule depends on when each packet arrived, which differs between
  legs, and the exporter's PSI and SI are placed by its own arrivals. The merged export's schedule
  does not: two legs on two hosts were byte-identical for 120 s.
- **Any other clip, a cross-host lane, a long run, or `main`**, which rebases the PTS and so defeats
  the latency instruments' PTS keys.
- **The decoded-picture buffer.** The grader does not model it. The exporter decodes each picture
  0–280 ms earlier than the source does, so each is held that much longer before presentation, and
  whether that exceeds the level's decoded-picture buffer on a real decoder is unmeasured.
- **A clean start for byte-faithful carriage at this latency.** A groomer that went live without
  trimming, or a cap above its start-up backlog with the backlog drained, was not tested.

**Uncertain.** How a hardware IRD responds; as in T44.

## Limits

- **One conformant run per clip**, 270 s and 210 s after a 60 s warm-up, and the two clips are
  captures of the same service at the same rate, so they vary the content and not the profile, the
  rate or the PID layout. The warm-up length was chosen after seeing the settle, so the settle's
  length on other hosts and builds is not known.
- **The tool is Python on a shared laptop.** Its loop fell behind by up to 167.7 ms once. The 600 ms
  lead absorbed it. The lead search found that the loop's lag does not order the sub-600 failures, so
  the stalls are not what makes a smaller lead fail, but a tighter instrument might still lower the
  floor by the lag.
- **The floor between 550 and 600 ms was not bisected**, and the run at 550 ms met a lane excursion,
  so the lowest lead this lane can hold without one is bracketed rather than measured.
- **One comparator run per transport**, one cushion. SRT's single loss in 288 s is one event, not a
  loss rate.

## Reproduction

```bash
# smoke test on the source clip
python3 lab/scripts/t18-latency.py tap 111 eg.csv --udp 18999 --rtp --seconds 45 --save eg.ts &
tsp --realtime -I file <source>.ts -P regulate --pcr-synchronous -P until --seconds 40 -O file |
  python3 lab/scripts/t18-latency.py tap 111 src.csv --pipe --seconds 42 |
  python3 lab/scripts/ts-remux-live.py 127.0.0.1:18999 11000000 --calib-from <source>.ts --rtp \
    --latency-ms 50 --warmup-ms 3000 --json remux.json
# the lane, re-multiplexed live: run 3
RELAY_TOML=<relay.toml for the build> MOQ=<build>/moq RELAY=<build>/moq-relay MOQLAT=500ms \
  RATE=11000000 PACER=lab/scripts/ts-remux-live.py \
  PACER_EXTRA="--calib-from <source>.ts --warmup-ms 60000 --json <out>/remux.json --trace <out>/trace.csv" \
  bash lab/scripts/t18-arm.sh <source>.ts <out> 330 moq 600   # the last argument is the lead, in ms
# the comparators
CAP=150 PACER_EXTRA=--stream-clock RATE=11000000 PACER=<pacer>/mpegts-pacer \
  bash lab/scripts/t18-arm.sh <source>.ts <out> 300 udp 100
BUFMS=120 CAP=150 PACER_EXTRA=--stream-clock RATE=11000000 PACER=<pacer>/mpegts-pacer \
  bash lab/scripts/t18-arm.sh <source>.ts <out> 300 srt 100
# grade any of them
python3 lab/scripts/ts-tstd.py <out>/<arm>-c<cushion>-egress.ts --skip 5 --window 2 --offset-scan -500,500,25
tsp -I file <out>/<arm>-c<cushion>-egress.ts -P continuity -P pcrverify --absolute --jitter-max 13 \
  --bitrate 11000000 -O drop
python3 lab/scripts/ts-decode-latency.py <source>.ts <out>/<arm>-c<cushion>-source.csv \
  <out>/<arm>-c<cushion>-egress.ts <out>/<arm>-c<cushion>-egress.csv
```

`t18-arm.sh` reports P1/P2 itself; the explicit commands are for a capture taken otherwise.

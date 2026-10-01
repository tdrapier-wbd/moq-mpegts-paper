# Test 45 — A live T-STD re-multiplexer behind the media-aware lane

**State: questions 1–3 answered on one clip, loopback; clock recovery and 1+1 determinism not
attempted.**

- **A live re-multiplexer makes the media-aware lane's wire T-STD-conformant.** Fed nothing but what
  a subscriber has — each PID's packets in order, when each arrived, and the timestamps they carry —
  a real-time scheduler produced a multiplex that passes every buffer of the calibrated grader over
  the whole capture, and TR 101 290 P1/P2 on the same bytes, with no packet sent late. This is
  [T44](test-44-tstd-grading.md)'s offline oracle made causal and run in real time.
- **It costs 2.20 s of presentation latency on this build, and the lane decides most of it.** About
  1.2 s is the lane's own transit, measured on the audio, which the exporter does not hold. About
  0.4 s comes from the exporter's ordering: it writes each video frame once the audio has passed the
  frame's PTS, and authors that frame's DTS 400 ms earlier. The remaining 0.6 s is the lead the
  re-multiplexer adds to rebuild the decoder pre-load that this ordering removes, against a
  rate-limited lower bound of about 0.55 s on these frames.
- **Byte-faithful carriage on the same rig conforms at a twentieth of that.** Through the
  stream-clocked groomer at a 100 ms cushion, UDP passes the grader and P1/P2 at 113.7 ms
  presentation latency, but only after the groomer's first 5 s, which a cap below its start-up
  backlog damages. Over SRT at a 120 ms latency it presents at 234.0 ms, but lost one burst in 288 s
  that SRT did not recover.
- **The lane's delay takes about 50 s to settle after a subscriber joins.** It grows by about 630 ms
  on every PID together. A stage that fixes a clock in the first seconds, as the re-multiplexer did
  with a 5 s warm-up, is overtaken by the lane.

Measured at P1, captured from the wire, wire domain, loopback, one clip, exporter `ffa5b81b`, the
re-multiplexer in Python. One conformant run of 270 s. Hardware: not run. The T-STD figures are from
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

Questions 4 and 5 were not attempted; see [Limits](#limits).

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

Run 3's 600 ms sits just above the middle figure, and sent nothing late. The lowest lead that passes
live was not searched, so 600 ms is a sufficient lead, not the minimum.

### Where the 2.2 s goes

| Component | ms | Evidence |
|---|---|---|
| The lane's transit, source tap to exporter output | about 1,200 | measured, on the audio |
| The exporter's PTS ordering against its own DTS reserve | about 400 | measured as the video's arrival offset against the audio's (420 ms); mechanism from the code |
| The re-multiplexer's lead | 600 | set; its rate-limited floor derived from measured frames at about 545 ms |
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
  within the frequency-offset and drift-rate limits.
- **1+1 determinism.** This schedule depends on when each packet arrived, which differs between
  legs, and the exporter's PSI and SI are placed by its own arrivals.
- **Any other clip, a cross-host lane, a long run, or `main`**, which rebases the PTS and so defeats
  the latency instruments' PTS keys.
- **The decoded-picture buffer.** The grader does not model it. The exporter decodes each picture
  0–280 ms earlier than the source does, so each is held that much longer before presentation, and
  whether that exceeds the level's decoded-picture buffer on a real decoder is unmeasured.
- **A clean start for byte-faithful carriage at this latency.** A groomer that went live without
  trimming, or a cap above its start-up backlog with the backlog drained, was not tested.

**Uncertain.** How a hardware IRD responds; as in T44.

## Limits

- **One conformant run**, 270 s after a 60 s warm-up, on one clip. The warm-up length was chosen after
  seeing the settle, so the settle's length on other clips, hosts and builds is not known.
- **The tool is Python on a shared laptop.** Its loop fell behind by up to 167.7 ms once. The 600 ms
  lead absorbed it, and a smaller lead might not have.
- **The lead was not searched downward from 600 ms.** The rate-limited bound puts the floor near
  0.55 s; a run below 600 ms would say how much of the difference the host's stalls need.
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
  bash lab/scripts/t18-arm.sh <source>.ts <out> 330 moq 600
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

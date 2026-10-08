# Test 47 — The upstream fixed-delay TS export on a broadcast clip

**State: [#4645](https://github.com/moq-dev/moq/pull/4645) has merged, and the export as merged
(upstream `main`, October 2026: `82c3f2fe4`, reporting moq 0.14.2 / moq-relay 0.17.2, versions whose
releases do not carry it) reproduces its
last draft, `fe7cec106`, on every cell that passed there.** It carries every PID of the source with 0 late
drops on loopback at 500 ms, 750 ms and 1 s, over 540 s at 1 s, across hosts at 500 ms and 1 s, and
under 0 % and 1 % loss at both delays, each passing the buffer model in every window, P2 and
`compliance.py`. Presentation latency is twice the delay plus about 275 ms at 750 ms and 1 s; at
500 ms the join moves it. At 500 ms the 540 s run still stops on the video's schedule, at the same
point as the draft. A co-started 1+1 pair now exports byte-identical streams before any groomer. At
10 % loss the export fails loud, sooner than the draft. What it does not survive is being handed
another route's in-progress group after a re-request (§ *As merged*).

**As merged, on `82c3f2fe4`:**

- **Every passing cell matches the draft.** Presentation is 2,272–2,274 ms at 1 s (also over 540 s,
  with the output PCR following the source's to about 1.2 ppm), 1,776 ms at 750 ms, and 992 and
  1,024 ms on two 60 s joins at 500 ms. The 540 s run at 500 ms stops 156.5 s in with a minimum video
  margin of 56.4 ms, the draft's stop. MP2 and AC-3 units equal those of the scratch build the draft
  adopted in every matching loopback cell, and TSDuck counts every elementary-stream PID present
  (video, MP2, AC-3, teletext and three SCTE-35 PIDs).
- **At 10 % loss, 1 s,** every track is present with gaps for about 20 s, the video included, and
  the export then exits on *missed a decode deadline on PID 131* (teletext); the draft lost the
  video about 7 s in and ran to 75 s.
- **1+1 behind the export:** a co-started pair's two exports are byte-identical as captured, where
  the draft's differed by one TDT burst. A pair 8 s apart is 97.64 % identical after one counter
  offset per PID, against the draft's 98.52 %.
- **Under `--linger`** six clean-restart runs resume three times each with one flag per resume.
- **A re-request onto another route usually ends it.** After a crash replaced on the same path on
  the default `moq-lite-06`, or a 1+1 failover on one relay that the relay does not resume, the
  exporter re-requests its tracks and fetches the new route's in-progress group. The first late
  video or teletext unit in that backlog ends the export on *missed a decode deadline*. Every
  `moq-lite-06` crash-replace run ended this way, while on `moq-lite-07` the replacement's newer epoch
  ends the old broadcast and the export resumes in 8 of 8 ([T13](test-13-downstream-grooming.md)
  § *Liveness*). 7 of 9 single-relay failover re-requests ended this way or on a timestamp rewind
  ([T6](test-6-relay-resilience.md) § *Single-relay standby*). One mid-GOP join on the T6 rig also
  failed this way, before any signal.

**The last draft before merge, `fe7cec106`:** it anchors and steers on the track sent latest, as
our scratch build did.

- **The clock holds.** Over 540 s at 1 s on loopback the output's PCR follows the source's to
  0.3 ppm.
- **At 500 ms the join picks the latency.** Of nine joins, four presented at 1,273–1,277 ms, four
  at 993–1,026 ms and one at 1,383 ms, every one passing with every track and identical buffer
  margins. The source's start offset does not decide it, the cause is not located, and the faster
  mode has been run only on loopback.
- **Under 10 % loss the video goes and the export fails loud at 75 s,** on a missed MP2 deadline.
  Every head run there has lost the video; the teletext stop of the scratch build is not reproduced.
- **Under `--linger` every clean restart resumes,** with one flag per resume and the first session
  carried to its end. Across a `SIGKILL` the replacement publisher exits as the relay resumes the
  route onto it, which is `main`'s behaviour rather than the PR's (§ *Anchored on the track sent
  latest*).
- **The release-clock statistics count neither a skipped group nor an absent track,** and
  `out_of_tolerance` climbs through every start.
- **1+1:** behind this export a co-started pair is byte-identical through the groomer, and the
  difference left between two exporters is where each places a TDT
  ([T13](test-13-downstream-grooming.md) § *On #4645's PCR grid*).

**The head before it, `559a35244`:**

- **The anchor took the track with the most slack.** On this clip that is the video, sent up to
  0.97 s ahead, which left the audio the delay less that: on most joins every audio and teletext
  frame was dropped as late, and at 500 ms the export stopped within 30 s. Located in the code and
  reproduced in mocked time. Our scratch build, anchoring on the least slack after hearing from
  every track, carried every track and is the change `fe7cec106` took.
- **Under 10 % loss it ran on with almost nothing,** 32 video units and no audio.
- **Under `--linger`** joining as the broadcast started ended the export within 7 s in every run, and
  across a `SIGKILL` it did not resume.

**The head before it, `2dc542b4a`:**

- **The clock is fixed.** The output's PCR clock fits within about 8 ppm of the receiving host on
  every long run, and within about 1 ppm of the source over 540 s at 1 s. On `49efbc9a1` it ran
  about 500 ppm off.
- **At 1 s it conforms wherever it carried every track:** 540 s on loopback, 120 s across hosts and
  120 s at 1 % loss. Every buffer was legal in every window, `compliance.py` passed, and every PCR
  was within ±500 ns. One 1 s run, the loss rig at 0 %, lost every AC-3 unit.
- **At 500 ms it loses audio on most joins.** Across hosts it dropped every MP2, AC-3 and teletext
  unit for the whole run. On loopback, seven of nine joins lost from a tenth of the AC-3 up to all
  of the MP2 and AC-3. Shifting the join alone moved the presentation latency from 480 ms with no
  audio to 1,089 ms with all of it. Both 540 s runs stopped on a schedule overrun, at 157 s and
  202 s. Under 1 % loss at 500 ms, and at 10 % at 1 s, the export stops within seconds.
- **The graders pass a programme without its audio.** Both T-STD checks and `pcrverify` grade
  only what is present, so completeness is now counted per PID against the source.
- **In mocked time every case passes,** including the system-clock and 1+1-after-a-skip cases
  that failed on `49efbc9a1`. The harness does not reproduce the wire's audio loss.

**The rework before it, `49efbc9a1`, on loopback:**

- **The broadcast clip conforms at every delay tried, including the 500 ms default.** At 1 s,
  750 ms and 500 ms the export runs the whole capture. `ts-tstd.py` passes every buffer in 26 of
  26 windows, with EB peaking at 99.8 %, 82 % and 57 %. `compliance.py` passes at 1 s; at 750 ms
  and 500 ms it flags only the capture's last AC-3 PES, a partial sync frame the rig cut. There are
  0 continuity errors, and 0 of about 2,300 PCRs per run are outside ±500 ns. The previous head
  stopped within seconds at every delay up to 3 s on this clip.
- **Presentation latency is 2,125 ms at 1 s, 2,201 ms at 750 ms and 1,409 ms at 500 ms**, one run
  each, on loopback, on those conformant bytes. The 750 ms run is slower than the 1 s one; the
  spread between runs is not located.
- **The clock steering takes the system clock out of tolerance.** The output's PCR runs on the
  jitter buffer's clock, which steers by up to 500 ppm to hold the least slack at the delay. A
  receiver joined mid-group anchors on a frame already old, and the steering wears the lead away at
  the full rate. In mocked time that is 497.8 ppm over 12 minutes, against 1.4 ppm for a receiver
  there from the start. On the wire the output's PCR clock fits about 500 ppm off the source in
  each of the three runs. ISO 13818-1 2.4.2.1 allows 30 ppm, slewing at most 0.075 Hz/s.
  `pcrverify` and both T-STD checks pass it, because each holds the PCR to the stream's own bytes.
- **Two legs diverged after a skip, and their continuity counters always differ.** In mocked
  time, two exports of one broadcast lay the same bytes once both are out of the join, apart from
  the counter. After a skip the new generation anchored on each leg's own read, and the pair
  diverged; on `2dc542b4a` a skip opens no generation and the pair stays identical.

**The first head: first pass (P0-m), on loopback and then under loss and across hosts, on
`4b7158d6c00d`. Every bullet below this paragraph, and every results section after
[the rework's](#the-rework-49efbc9a1), is on that head or on scratch builds of it. The cause of the
broadcast-clip failure is located by an offline replay, which predicted two further runs of the
real export correctly. A scratch patch that schedules each PID's packets earliest deadline first,
admitted against that PID's own transport and decoder buffers, carries the full multiplex at 1 s
and at 750 ms with every buffer conformant; PCR accuracy still fails, from the unchanged stamping.
At 500 ms it stops, as the replay predicts for the DTS the export authors. Those passes hold
only for the join the runs made. At all eleven joins traced on #4645's release stage, on one host
and across hosts, the video track skipped a group, and the release stage then gave it a clock of
its own. The offset
from the other tracks' clock is set at the join and fixed for the run: 200 ms behind, about a
whole delay behind, or 1.2 s ahead. Only the 200 ms state passes, and the 1 s loopback pass is
that state. Under the loss rig at 1 s, 1 % stays conformant except at one grid restart, and 10 %
collapses the lane. In the one run on that head's unpatched schedule with the video a delay
behind, the export stopped. A scratch change that keeps every track on one clock makes all eleven joins
conform, with one set of margins, but it breaks four of upstream's discontinuity tests, so the fix
proper is a design choice upstream.**

- **On a real broadcast capture the export stops within seconds, at every delay up to 3 s.** On
  CNNiEMEA2 (AVC High@4.0 1080i, MP2, AC-3, teletext, three SCTE-35 PIDs, DVB SI) the export exits
  with a schedule overrun ("needs N packets in a 25 ms slot, more than R b/s allows within the
  delay") at `--delay` 500 ms, 1 s, 2 s and 3 s, at the catalog's recorded rate. At 1 s it does so
  also at 11 Mb/s and with the export subscribed before the publisher starts, and at 500 ms and 2 s
  with the video alone. Upstream's own harness (`just test ts --source`) reproduces it at the
  defaults.
- **The failure is not the extra tracks.** At the 500 ms default, the full multiplex also drops
  audio and verbatim frames as late from about 1 s in. Stripped to video and MP2, it still overruns;
  stripped to video alone, it overruns at 500 ms and at 2 s.
- **A generated clip with the same send-ahead fails only at the default, and passes both T-STD
  checks at 2 s.** It is FFmpeg-generated: 1080p25 video, x264 NAL HRD CBR at 9 Mb/s with a 9 Mbit
  CPB, muxed at 10 Mb/s, about 0.7 s of video send-ahead. The source passes upstream's strict check.
  Round-tripped at `--delay 500ms`, the export stops after 2.2 s of output. At `--delay 2s` it runs
  the whole capture, and upstream `compliance.py` and [`ts-tstd.py`](scripts/ts-tstd.py) both pass
  the output, every 2 s window included. So the default is too short for a CPB this size.
- **The broadcast clip fails on the schedule's send policy, not on its load.** On the source's
  own wire the video never exceeds 150.1 packets per 25 ms slot over any 3 s, against the 156 the
  export allows itself. The source carries it by sending up to 0.97 s ahead, with EB peaking at
  97 %. The export sends each unit as late as the rate allows, and it knows units only one window
  ahead. Slots it pads before a heavy stretch cannot be recovered, so a stretch where the decode
  timeline outruns the rate for about a window cannot be met. CNN's field-coded passages are such
  stretches. An offline replay of the export's rule fails the clip at every delay up to 3 s on the
  source's own DTS, and up to 5 s on the DTS the export authors. It fits at 8 s. The real export
  then did both: at 5 s it stopped with 17.60 s of decode time out, where the replay said 17.57 s,
  and at 8 s it ran the capture and passed the T-STD (video only).
- **The export's authored DTS makes this worse.** Its decode clock holds back a fixed *number* of
  pictures (10), not a fixed time. Each time CNN switches between frame and field coding, the
  authored DTS moves 0.2 s against the source's, and the leading pictures of the first GOP all
  get DTS one tick apart. With the rest of the multiplex taking its share of the rate, that alone
  puts the 500 ms default out of reach on this clip.
- **Sending the video earliest deadline first, as soon as its decoder buffer has room, carries
  the video at 1 s.** A first scratch patch of the PR head did only that. At `--delay 1s` it ran
  the whole capture with the video passing every buffer (EB full at its peak, minimum margin
  510 ms, 26 of 26 windows) and AC-3 still failing.
- **The export's audio fails the T-STD for two reasons, and neither is the video's.** Unpatched at
  8 s, MP2's B peaks at 11,170 of 3,584 B and AC-3's at 16,899 of 5,696 B, and AC-3's transport
  buffer overflows on 2,495 packets. First, the schedule fills each slot's minimum in push order,
  which carries audio out in bulk ahead of heavy video: up to 38 AC-3 packets in one 25 ms slot,
  about 2.3 Mb/s into a transport buffer that drains at 2 Mb/s. The layout spreads each PID's
  packets evenly through the slot, so it is the count per slot that overflows, not their spacing.
  Second, AC-3 passes through as the source's PES, nine 768-byte frames in 38 packets, about
  6.9 KB against a 5,696 B buffer. Delivering a PES whole before its first frame decodes overflows
  B however the slots are filled. A decoder removes each frame at its own PTS, so a schedule has to
  hold each frame's deadline, not the PES's.
- **Admitting each PID's packets against its own buffers carries the full multiplex at 1 s and
  750 ms.** The second scratch patch picks each slot's packets earliest deadline first across PIDs.
  It caps each PID per slot at what its transport buffer drains, and holds a buffered PID to its
  decoder buffer's room. A multi-frame unit's deadlines and buffer removals are taken frame by
  frame. At both delays the output passes every transport and decoder buffer of `ts-tstd.py` in
  every 2 s window, and `compliance.py`, with 0 continuity errors. At 500 ms it stops at 9.3 s of
  output: an offline replay of the same buffer-limited rule misses the DTS the export authors at
  that delay, while it nearly meets the source's. The 1 s pass is one join state of several (next
  bullets but one); the 750 ms run's state is not known. Presentation latency on those conformant
  bytes is 4.29 s at 1 s and 2.77 s at 750 ms, one run each, with a spread between runs that is not
  located.
- **Under 1 % loss at 1 s the per-PID build stays conformant except where the export restarts its
  grid.** Under the [T8b](test-8b-congestion-control.md) netem rig (25 ms each way, BBRv3), 0 %
  passes every buffer in all 56 windows. At 1 % the export lost 0.12 s of video and one 0.288 s
  AC-3 hole, and restarted its grid once, with a flagged PCR discontinuity. Every window either
  side of the restart passes, apart from 2 table packets over the system transport buffer. At 10 %
  the lane delivers almost nothing but nulls, so its buffer grade is moot.
- **A join where the video skips a group puts the video on its own clock, on one host as across
  hosts.** The consumer counts the skipped group as a discontinuity. #4645's jitter buffer then
  opens a new generation for the video alone, anchored no earlier than the deadlines it has
  already given the other tracks. Every one of eleven traced joins skipped a video group. The
  video's clock then ran 200 ms behind the others' (three joins), 959–979 ms behind (five), or
  1,200 ms ahead (two loopback joins), fixed for the whole run. In the eleventh an evicted MP2 group
  opened further generations. At 200 ms every buffer passes, with the 1 s loopback pass's
  margins to within 0.3 ms. A whole delay behind, the video reached the schedule one slot ahead of its
  deadline instead of 32, and 916 to 2,257 video units and 1,068 to 2,273 MP2 units underflowed.
  Ahead by 1.2 s, every MP2 unit reached the schedule 8 slots late and underflowed.
  In the one run with the PR head's own schedule, a delay behind, the export stopped on its fatal
  overrun within seconds.
- **With every track kept on one clock, all eleven joins conform.** A scratch release stage that
  lets a landing frame keep its clock, and moves lagging tracks to the newest clock, passed every
  buffer in every window at six joins on one host and five across hosts. The margins were the same
  in each. As written it breaks four of upstream's discontinuity tests, because the release stage
  cannot tell a skip at the join from a publisher's timeline restart.
- **Nearly every PCR the export writes misses TR 101 290's ±500 ns accuracy, by up to ±75 µs.** The
  export stamps each PCR with its 25 ms slot time, but a slot carries a whole number of packets
  (166 or 167 at 10 Mb/s), so the byte position wanders up to half a packet from where the value
  says it is. On the 2 s run, 1,868 of 1,880 PCRs after start-up are outside ±0.5 µs. Upstream's
  own schedule check tolerates one packet, so it passes. This is a P2 failure by design, and
  (reasoned) cheap to remove by stamping each PCR from its own byte position.
- **Delivery latency at `--delay 2s` is 6.83 s median on loopback**, on the generated clip,
  stable over 55 s (+17 ms trend). The design allows up to twice the delay plus the send-ahead,
  about 4.7 s; the remaining ~2 s is not located.

Measured at P1 and P2 on captured wire bytes, loopback, one host, the export forwarded without
re-clocking. T-STD graded on the stream's own PCR, with `ts-tstd.py` as corrected in
[T46](test-46-tstd-check-cross-validation.md); re-grading every kept capture with it moved no
verdict. One run per cell. The loss and cross-host arms are graded on the export's output file,
T-STD only. Hardware: not run.

## Objective

Upstream took up T-STD conformance of `moq export ts` as a questline after
[T44](test-44-tstd-grading.md) and [T45](test-45-live-tstd-remux.md). Its first implementation,
#4645, replaces the stall-and-hold interleave with a fixed-delay release stage and lays packets on
a PCR grid at the mux rate. Its CI passes on a generated 720p clip. This test asks the P0-m
questions of it on a real broadcast multiplex:

1. **Does the export run, and pass the T-STD, on a broadcast clip at its default delay?**
2. **If not, at what delay, and what is the failure?**
3. **What do P1/P2 say of the same bytes, and what is the latency against `--delay`?**
4. **Does the result hold under the [T8b](test-8b-congestion-control.md) loss rig, and across
   hosts?** Asked of the per-PID scratch build at 1 s, the one that passes on loopback.
5. **Does the rework carry the clip, at what delays, and what does its clock do to the output?**
   Asked of `49efbc9a1`, which took up the per-PID admission and the one-clock release stage.
6. **Does holding the clock to 30 ppm, with a live-edge join, keep the output conformant, at what
   latency, under loss and across hosts?** Asked of `2dc542b4a`.

## Pass criteria

Fixed before the runs, the same as T45's for the T-STD:

1. **Both T-STD checks pass the output** after a 5 s skip: upstream `compliance.py`
   (`run.sh --analyze-only`) and [`ts-tstd.py`](scripts/ts-tstd.py), every 2 s window legal.
2. **TR 101 290 P1/P2 on the same bytes**: 0 continuity errors, 0 PCR intervals over 40 ms, 0 PCRs
   outside ±500 ns against the rate the stream was padded to.
3. **The export runs the whole capture.**

A cell that fails criterion 3 has its latency and buffers quoted only for the part it delivered.
From `2dc542b4a` on, each cell is also checked for completeness: every PID the source carries is in
the output, with its unit count against the source's. This was added after a cell passed criteria 1
and 2 with its audio missing, so it was not fixed in advance.

## Instruments

**The forwarder.** #4645 paces its own output: it slices the multiplex on the PCR grid and writes
each slice at its slot boundary. A groomer in [T18](test-18-delivery-latency.md)'s rig would replace
that schedule with its own, so [`ts-rtp-forward.py`](scripts/ts-rtp-forward.py) takes the groomer's
slot. It sends each whole packet the moment it is read, seven to a datagram, and never holds a
remainder back for the next read. It rewrites nothing. Through the rig's plain-UDP arm it adds
0.3 ms median.

**The flags.** #4645 replaces `--max-age` with `--delay` and refuses the old flag;
[`moq-cli-flags.sh`](scripts/moq-cli-flags.sh) detects it. Its value is a release delay, not a
staleness bound, so latency at equal flag value does not compare across the two surfaces.

**The upstream harness.** `test/ts/run.sh` on the PR's own tree feeds a capture through
`tsp -P regulate --pcr-synchronous --wait-min 5 | moq import ts`, as T18's rig does, and grades
with `compliance.py`. Running it is what makes the failure reproducible by the maintainer.

**The generated fixture.** It is built to the broadcast clip's shape on the parameter that matters
to a scheduler, the video CPB, and nothing else. FFmpeg's TS muxer at this video rate fails the
audio buffer of its own output whatever the audio codec (MP2 and AAC both overflowed B), so the
fixture is video only. Its source passes `compliance.py`: EB peak 76 %, worst delay 0.7 s.

## Environment

- Export, import and relay: #4645 at `2dc542b4a` and at `49efbc9a1` for their sections, with no
  `MOQ_TS_*` or `MOQ_JITTER_*` variable (both read every buffer parameter from the stream).
  Everything else is on the first head, `4b7158d6c00d`. Release builds, relay on its own tree's config. The
  two scratch schedules are patches to `4b7158d6c00d`'s `schedule.rs` only.
- Mocked time: the export's own crate on the paused Tokio clock, a live H.264 + AAC broadcast
  written frame by frame at the instant a source sends it, receivers reading on their own cadence
  (`export_timing_test.rs`, [below](#in-mocked-time)).
- Comparator control: upstream harness on its default generated clip with the same build, which
  passes every check including strict T-STD.
- One host, loopback. All stages at `nice 10`.
- Loss arms: one host, the T8b network-namespace rig, 25 ms each way, BBRv3 on noq, uniform netem
  loss on the media direction, 120 s. Cross-host: relay and importer on one host, with the clip paced by
  `tsp -P regulate`, and the export on a second host in the same region, 120 s. On the per-PID
  build, with lateness logged rather than fatal (`MOQ_TS_LATE=send`) so that a run is graded whole;
  on `2dc542b4a`, as pushed: a frame that arrives late is dropped, and a schedule overrun stops
  the export.

## Results

### Anchored on the track sent latest, `fe7cec106`

Four commits on top of `559a35244`, one of them a merge of `main`. The anchor and the steering
floor take the track sent latest against its decode time, after hearing from every audio, video
and PES track, waiting two delays at most; section tracks are not waited for. This is the
scratch build's change below, taken into the PR. The jitter buffer releases equal decode times by
`(generation, decode time, PID)` rather than by nanosecond deadline. From `main` it carries the
skip of a stalled group at half the delay, the full-buffer T-STD grader of `test/ts`, and the
route-resume change of [#4741](https://github.com/moq-dev/moq/pull/4741). The export now reports
`dropped`, the estimated source drift and `out_of_tolerance` as *TS export release clock*. The
rigs are those of `559a35244`, unchanged, and every run joins a running source. Units are counted
per PID over the whole capture.

**Loopback**, 60 s unless stated. Every cell carried every PID of the source with 0 late drops and
passed `ts-tstd.py` in every window, `compliance.py` and `pcrverify` (no PCR outside ±500 ns),
except where the outcome says otherwise.

| `--delay` | Source started later by | Runs | Presentation, median | Outcome |
|---|---|---:|---|---|
| 1 s | 0, 0.3 s | 1 each | 2,272.2 / 2,272.5 ms | pass |
| 1 s, 540 s | 0 | 1 | 2,272.5 ms, +0.1 ms over the run | pass, 266 of 266 windows; output PCR −14.52 ppm against the tap, source −14.24 ppm |
| 750 ms | 0, 0.3 s | 1 each | 1,775.3 / 1,774.6 ms | pass |
| 500 ms | 0, 0.5 s, 0.7 s | 2, 1, 1 | 1,273.0–1,276.5 ms | pass |
| 500 ms | 0.3 s | 3 | 993.3, 1,002.6, 994.7 ms | pass |
| 500 ms | 0.1 s | 1 | 1,026.3 ms | pass |
| 500 ms, 540 s | 0 | 1 | 1,276.0 ms | every PID until *missed a decode deadline on PID 111* at 156.6 s; minimum video margin 56.4 ms |
| 500 ms, 540 s | 0.3 s | 1 | 1,382.7 ms | the same stop, at the same point in the source, with the same margins |

**Across hosts**, 120 s: at 1 s and at 500 ms, every PID, 0 late drops, 0 groups skipped, every
buffer in every window, `compliance.py` PASS and every PCR inside ±500 ns.

**Under loss**, the [T8b](test-8b-congestion-control.md) namespace rig, 25 ms each way, 120 s.

| Arm | `--delay` | Outcome |
|---|---|---|
| 0 % | 1 s, 500 ms | every PID, 0 late drops, pass |
| 1 % | 500 ms | every PID, 0 late drops, pass |
| 1 % | 1 s | pass, 0 late drops; one video group, 26 frames, skipped about 7 s in, with `dropped` at 0 |
| 10 % | 1 s | video stops about 7 s in and does not return, its groups evicted about once a second; MP2, AC-3 and teletext run on; at 75 s *missed a decode deadline on PID 121*; `dropped` stays 0 throughout |

**Under `--linger`**, the restart rig of [T13](test-13-downstream-grooming.md) § *Liveness*, at 1 s.

| Arm | Runs | Resumes | Flags on the PCR PID | CC jumps | Late drops | Exit |
|---|---:|---:|---:|---:|---:|---|
| Clean end, back after 5 s, clip replayed, `--linger 20s` | 3 | 3 each | 3 each | 0 | 0 | 0, after *broadcast did not return* |
| Clean end, back after 5 s, clip continued | 3 | 3 each | 3 each | 0 | 0 | 0, the same |
| `SIGKILL` 5 s before the clip ends, back after 3 s, `--linger 60s` | 3 | 1 each | 1 each | 0 | 0 | 0, the same |

- **Every track survives every join tried, at every delay, on every rig except 10 % loss.** The
  audio loss of `559a35244` and of every head before it is gone. The 540 s run at 500 ms still stops
  at the same point with the same minimum video margin, so that limit is the schedule's, as the
  scratch build suggested.
- **At 500 ms the join moves the latency, and every value passes.** Of nine joins, four presented
  at 1,273–1,277 ms, matching twice the delay plus about 275 ms; four at 993–1,026 ms, about 280 ms
  sooner; and one at 1,383 ms. Every output carries the same units on every PID with the same
  decoder-buffer margins and every PCR in range; only the release instant moves. The source's start
  offset does not decide it: a 0.3 s offset gave about 1,000 ms on three 60 s runs and 1,383 ms on
  the 540 s run, which stopped at the same point in the source as the unshifted one, so the faster
  release does not lift the 500 ms limit either. At 750 ms and 1 s the same shifted join changes
  nothing. Where the spread comes from is not located, and the faster mode is untested across hosts
  and under loss, where the hold it gives up may be needed.
- **The session-start exits are gone.** On `559a35244` and the scratch build, joining as the
  broadcast starts ended the export within 7 s in 5 of 5 runs. Here the first session runs to its end
  in 6 of 6, and each replay carries the same 394,324 packets.
- **Across a `SIGKILL` the export resumes, but the replacement publisher does not survive the
  relay.** The relay learns of the kill 12.8 s after it. By then the replacement had connected and
  exited: 0.23 s after connecting, the relay resumed the route onto it and fetched the killed
  publisher's video group 7, its subscriptions failed, and `moq import ts` exited with *rendition is
  not published*. The export resumed onto the next publisher in 3 of 3 runs. On `main` at
  `83ce47fe`, on the same rig, the relay detected the kill after 10.0 s and the export resumed onto
  the live replacement within a millisecond. `main` at `edd671fff` alone, which carries #4741's route
  resume, reproduces it in two of three runs and stalls without resuming in the third, so it sits in
  `main`'s relay and publisher, not in the PR; filed as
  [#4945](https://github.com/moq-dev/moq/issues/4945) ([T13](test-13-downstream-grooming.md)
  § *Liveness*).
- **The release-clock statistics miss lost programme and count a healthy start.** `dropped` counts
  deadline misses, so a group skipped by the consumer, or a video track absent for 68 s, leaves it at
  0; the once-only INFO line *elementary stream stopped delivering access units* is the only signal.
  `out_of_tolerance` counts the steering steps whose estimated source rate is beyond 30 ppm. It
  climbs through the first minute of every run (14 to 67 by the end of the runs read), with early
  estimates in the thousands of ppm, and then stops, on sources whose PCR the output follows to 0.3 ppm.
- **The 10 % arm is the transport losing the video.** Every head run there lost it: `559a35244`
  carried almost nothing after 10 s while padding to the mux rate, and the scratch build stopped at
  25 s on teletext. This head carries the rest of the programme for another minute and then fails
  loud, as upstream intends. The teletext stop is not reproduced.

**1+1 behind this export** is in [T13](test-13-downstream-grooming.md) § *On #4645's PCR grid*: a
co-started pair is byte-identical through the groomer, and once continuity counters are rewritten
the remaining difference between two exporters is where each places a TDT.

*Domain: P1 and P2; the export's output as it was paced, tapped on loopback and across hosts, and as
written to file on the loss and linger rigs.
`[unmerged]`, #4645 at `fe7cec106`, no parameter set by hand, noq; `CNNiEMEA2.ts`; one run per cell
except as stated. Reported on #4645.*

### Acquiring before release, and the anchor on the most slack, `559a35244`

Three commits on top of `2dc542b4a`. The jitter buffer releases nothing until a track starts its
next group, or until a held frame falls due, and then anchors the clock on the freshest frame
held. Clock recovery takes a floor every 2 s of decode time, the most slack a frame arrived with,
and fits the upper envelope of those floors over 10 minutes, within ±30 ppm and 0.075 Hz/s.
Cut AC-3 sync frames are dropped. A missed deadline after every source has ended sends the tail
late instead of failing. `compliance.py`, run from the head's own tree, models teletext's
EN 300 472 buffer. The rigs are those of [`2dc542b4a`](#the-live-edge-join-and-the-30-ppm-clock-2dc542b4a),
and each run joins a running source, about 4 s in. Units are counted per PID over the graded
window, 5 s onward. A complete MP2 track is about 2,140 units in a 60 s cell and about 4,750 in a
120 s one; a complete AC-3 track is about 1,600 and 3,560.

**Loopback.**

| Cell | Runs | MP2 units | AC-3 units | Late drops | Presentation, median | Output |
|---|---|---|---|---|---|---|
| 1 s, 540 s | the whole run | 0 | 0 | 37,550: every MP2, AC-3 and teletext frame | 969.9 ms | `ts-tstd.py` 266 of 266, `compliance.py` PASS, 0 of 21,498 PCRs outside ±500 ns; PCR clock −9.8 ppm against the host, source −9.4 ppm |
| 1 s, 60 s, and source 0.3 s later | the whole run, both | 0 | 0 | 3,884 each, the same | 969.9 / 971.7 ms | video only, conformant |
| 750 ms, 60 s | the whole run | 0 | 0 | 3,884, the same | 472.6 ms | video only, conformant |
| 500 ms, 60 s, repeated, and 540 s | exits at about 28 s: "missed a decode deadline on PID 111" | 0 | 0 | about 2,035 each | about −27 ms | — |
| 500 ms, source 0.3 s later | the whole run | 2,143, complete | 0 | 196 AC-3 PES | 749.9 ms | — |
| 500 ms, source 0.6 s later | exits within seconds, the same | 0 | 0 | 311 | — | — |
| 500 ms, source 0.9 s later | the whole run | 3 | 0 | 3,957 | 514.3 ms | — |

The 1 s and 750 ms outputs pass both T-STD checks, `compliance.py` and `pcrverify`, because each
grades the units present: they are video, SCTE-35 and SI.

**Across hosts**, as for `2dc542b4a`, 120 s.

| `--delay` | MP2 units | AC-3 units | Late drops | `compliance.py` | PCRs outside ±500 ns |
|---|---|---|---|---|---|
| 1 s | 4,739, complete | 3,556, complete | 0 | PASS | 0 of 4,785 |
| 500 ms | 1,012 | 0 | 4,372 | not graded | 0 of 4,794 |

**Under loss**, the [T8b](test-8b-congestion-control.md) namespace rig, 25 ms each way, BBRv3, 120 s.

| Arm | Runs | MP2 units | AC-3 units | Late drops | `compliance.py` |
|---|---|---|---|---|---|
| 0 %, 1 s | the whole run | 4,771, complete | 3,579, complete | 0 | PASS |
| 1 %, 1 s | the whole run | 4,764 | 3,574 | 19 | PASS |
| 10 %, 1 s | the whole run | 0 | 0 | 7,311; 32 video units carried in all | — |
| 1 %, 500 ms | exits at 5 s: "missed a decode deadline on PID 111" | 0 | 0 | 64 | — |

At 10 % the export now runs to the end of the window, where `2dc542b4a` stopped at 10 s, but its
output is PCR and tables with almost no media. Four of its 4,719 PCRs carry jitter of up to 325 ms.

**Why the audio goes.** Both selections that set the clock take the most slack across all tracks.
The acquisition anchors on the frame read least behind its decode time over every frame held, and
each steering step's floor is the most slack any frame in the step arrived with. CNN's mux sends
video up to 0.97 s ahead of its decode time and audio about just in time, so both choose the
video. The audio is then left the delay less 0.97 s, which at 1 s or below is no time at all, and
the steering holds it there. A third condition makes the join matter. The acquisition ends when any
track starts its next group, which can be before the track sent latest has delivered anything; the
anchor then cannot see it. The one 1 s cross-host run that kept its audio has video buffer margins
equal, to 0.1 ms, to the scratch build's below, so that join anchored on the audio. That is
inferred from the margins, not traced. The presentation latency fits the same reading: twice the
delay less about 1,030 ms at every delay, which is the video's send-ahead taken out of the delay.

**In mocked time.** The tests, carried onto this head, pass, with the 1+1 identity case still
ignored for the ST 2022-7 follow-up. A case joined at the live edge, with one track sent 700 ms
after the other at a 500 ms delay, at a group boundary and mid-group, fails. With the audio sent
later it drops 556 and 543 frames, and with the video sent later, 285 and 293. The same case passed
on `2dc542b4a`, for a reason not located. The head's tests were taken from an earlier commit that
does not carry it.

**A scratch build that anchors and steers on the least slack.** Three changes to the jitter buffer.
The acquisition anchors on each track's freshest frame, and of those, the one with the least
slack. Each steering step's floor is the least of the per-track floors. The acquisition waits until
every track in the catalog has delivered a frame, for at most two delays. The mocked case passes,
with every other `moq-mux` test. The relay and importer are the head's; only the export differs.

| Run | `--delay` | MP2 units | AC-3 units | Late drops | `ts-tstd.py` | `compliance.py` | Presentation, median |
|---|---|---|---|---|---|---|---|
| Loopback, 60 s | 500 ms | 2,131 | 1,597 | 0 | 26 of 26 | PASS | 1,276.6 ms |
| Loopback, source 0.3 s later | 500 ms | 2,181 | 1,634 | 0 | 26 of 26 | PASS | 1,272.9 ms |
| Loopback, 60 s | 750 ms | 2,142 | 1,605 | 0 | 26 of 26 | PASS | 1,775.8 ms |
| Loopback, 60 s | 1 s | 2,152 | 1,612 | 0 | 26 of 26 | PASS | 2,274.3 ms |
| Loopback, source 0.3 s later | 1 s | 2,151 | 1,612 | 0 | 26 of 26 | PASS | 2,272.5 ms |
| Across hosts, 120 s | 500 ms | 4,751 | 3,564 | 0 | 57 of 57 | PASS | — |
| Across hosts, 120 s | 1 s | 4,737 | 3,554 | 0 | 56 of 56 | PASS | — |
| Loopback, 540 s | 1 s | 22,060 | 16,546 | 0 | 264 of 264 | PASS | 2,273.4 ms, +0.2 ms over the run |
| Loopback, 540 s | 500 ms | 6,312 | 4,733 | 0 | 75 of 75 before the exit | PASS | 1,274.1 ms; exits at about 157 s: "missed a decode deadline on PID 111" |

Under loss, on the [T8b](test-8b-congestion-control.md) rig as above, 120 s, loss as configured:

| Arm | Runs | MP2 units | AC-3 units | Late drops | `ts-tstd.py` | `compliance.py` |
|---|---|---|---|---|---|---|
| 0 %, 1 s | the whole run | 4,731 | 3,549 | 0 | every window | PASS |
| 1 %, 1 s | the whole run | 4,730 | 3,548 | 0 | every window | PASS |
| 0 %, 500 ms | the whole run | 4,742 | 3,558 | 0 | every window | PASS |
| 1 %, 500 ms | the whole run | 4,742 | 3,558 | 0 | every window | PASS |
| 10 %, 1 s | exits at 25 s: "missed a decode deadline on PID 131" | 461 | 198 | 6 | every window before the exit | — |

Every PCR is within ±500 ns in every run. Over 540 s at 1 s the output's PCR clock follows the
source tap's to 0.6 ppm. The 500 ms runs of 60 s and 120 s no longer stop, but the 540 s one stops
at about 157 s, as the first 540 s run on `2dc542b4a` did, with the same minimum video EB margin of
56.4 ms. So that overrun belongs to the schedule at 500 ms on this passage of the clip, not to the
anchor. The 1 % arm at 500 ms carried exactly the 0 % arm's units; the rig sets the loss but does
not count what netem dropped. At 10 % the export now stops on teletext (PID 131), where the head
ran on with almost no media. Presentation latency is
twice the delay plus about 275 ms at each delay, with a spread of under 10 ms per run. With the
anchor on the audio, the video's 0.97 s send-ahead is no longer taken out of the delay, so it
becomes latency. [#4681](https://github.com/moq-dev/moq/pull/4681)'s planned cap on send-ahead is
what would bring it down (reasoned). Two costs of the change are reasoned, not measured. A sparse
PID that sends nothing at the join, such as SCTE-35, holds the acquisition the full two delays. A
track that queues for a whole steering step pulls the clock with it.


#### A broadcast that restarts under `--linger`, on `559a35244`

The linger rig of [T13](test-13-downstream-grooming.md) § *Liveness* (`lin.sh`), unchanged, with the
head's own `moq` and relay: `export ts --linger` starts first, then a same-name `import ts` publisher
of `CNNiEMEA2.ts` (15 s sessions) ends cleanly or is `SIGKILL`ed and restarts. Default `--delay 1s`,
loopback, P1, file domain; the scratch build `5e2425f` alongside.

| Arm | Build | Runs | First session | Resumes | Flags on the PCR PID | CC jumps | Exit |
|---|---|---:|---|---:|---:|---:|---|
| Clean end, back after 5 s, clip replayed, `--linger 20s` | head | 1 | export ends at 4.5 s | 3 | **3** | 0 | 0 |
| same | `5e2425f` | 1 | export ends at 6.6 s | 3 | **3** | 0 | 0 |
| `SIGKILL` 5 s before the clip ends, back after 3 s, `--linger 60s` | head | 2 | export ends at ~4.4 s | 0 | 0 | 0 | 1 (`dropped`) |
| same | `5e2425f` | 1 | export ends at 6.6 s | 1 | 1 | 0 | 1 (`internal error`) |

- **One flag per resume: the multi-flag resume of [#4767](https://github.com/moq-dev/moq/issues/4767)
  is gone on this head.** On `main` at `83ce47fe` the same replay arm set 6–8 flags for three resumes.
  Upstream closed #4767 against this PR's plan (`quest/m1/tstd/delay.md`), not against merged code.
- **Joining as the broadcast starts ends the export, in 5 of 5 runs on both builds**, with *missed a
  decode deadline on PID 111*, after 138–139 frames dropped as late on the head and 291 on
  `5e2425f`. Earlier cells joined about 4 s into the source and did not hit this at 1 s. Sessions
  reached by a later resume ran to their end, the head's with 2,913 more drops, its audio loss
  above.
- **Under `--linger` a local export error reads as the broadcast ending.** The exporter logs
  *broadcast ended, waiting for it to return* and waits for a replacement while the broadcast it was
  reading is still live, so the rest of that session (about 10 s here) is lost.
- **Across a publisher `SIGKILL` neither build carries through the restarts**, where `main` at
  `83ce47fe` resumes 10–13 s after each kill on the same rig. The PR's base predates `main`'s by
  about 230 commits, so this is not attributed to the PR; the arm is owed on the rebased head.

Reported on #4645 (issuecomment-6013366214).

### The live-edge join and the 30 ppm clock, `2dc542b4a`

Three commits on top of `49efbc9a1`. The jitter buffer's clock follows the source no more than
30 ppm off the receiver's clock, slewing at most 0.075 Hz/s (13818-1 2.4.2.1), and the export fails
when a source runs further off than that. Video and audio subscribe at the newest group, the live
edge, rather than at the delay's reach; verbatim tracks (here AC-3 and teletext) keep the reach. A
skipped group no longer opens a generation; only a declared restart does. No `MOQ_TS_*` variable is
set. The rigs are the rework's, plus the loss rig and cross-host on the head as pushed, with every
egress tapped so that its PCR clock can be fitted.

**Measuring the clock.** [`ts-decode-latency.py`](scripts/ts-decode-latency.py) fits each tap's
wall-minus-STC offset against the tap's own clock. The slope is the PCR clock's rate against the
tap's, which is the quantity 2.4.2.1's frequency tolerance bounds. It reports the rate over the
whole run and per 30 s window. On the loopback taps a 30 s window reads ±45–60 ppm from noise alone,
and in one run both taps read −160 and −176 ppm together, which is the host's clock, not the stream.
So the figures that grade against 30 ppm are the whole-run fit and the egress against the source
tap of the same run. The slew limit, 2.8 ppb per second, is far below what 30 s windows resolve, and
it is not graded.

**Loopback**, one host, the T18 rig as for the rework, catalog rate, mid-stream join. Cells of 60 s
have their T-STD graded after a 5 s skip; `compliance.py` flags each one's last AC-3 PES, the
capture's truncated frame ([below](#the-rework-49efbc9a1)), and nothing else.

| Cell | Runs | `ts-tstd.py`, 2 s windows | `compliance.py` | PCRs outside ±500 ns | Late drops | AC-3 units | Presentation, median | PCR clock: egress / source tap |
|---|---|---|---|---|---|---|---|---|
| 1 s, 540 s | the whole run; exits at the end on the capture's tail | 265 of 265 | PASS | 0 of 21,462 | 0 | 16,611, complete | 1,766.1 ms, +0.5 ms over the run | −7.6 / −6.4 ppm |
| 1 s, 60 s | the whole run | 26 of 26 | last PES only | 0 of 2,310 | 0 | 1,612 | 1,791.3 ms | −2.1 / −6.0 ppm |
| 750 ms, 60 s | the whole run | 26 of 26 | last PES only | 0 of 2,300 | 0 | 1,605 | 1,292.6 ms | +20.6 / −2.5 ppm |
| 500 ms, 60 s, four runs | the whole run | 26 of 26 each | last PES only | 0 of 2,290 each | 20–55 AC-3 PES each; up to 3 MP2, 1 teletext | 1,147–1,426 | 783.7–787.9 ms | within 25 ppm of the source tap in each |
| 500 ms, 540 s | exits at 157 s: "missed a decode deadline on PID 111" | 75 of 75 before the exit | PASS | 0 of 6,262 | 0 | 4,733, complete | 798.5 ms | −4.1 / −6.1 ppm |
| 500 ms, 540 s, repeated | exits at 202 s, the same | 98 of 98 before the exit | PASS | 0 of 8,042 | 427 AC-3 PES, 14 MP2, 1 teletext | 2,376, about 39 % of the track | 776.5 ms | −9.9 / −12.4 ppm |

**The join phase, on loopback**: three more 60 s runs at 500 ms, with the source started 0.3, 0.6
and 0.9 s later than in the cells above, so that the export joins at a different point in the
source's GOP. Every buffer passes in 26 of 26 windows and every PCR is within ±500 ns in each.

| Source started later by | Presentation, median | MP2 units | AC-3 units | Late drops |
|---|---|---|---|---|
| 0.3 s | 480.1 ms | 0 | 0 | 193 AC-3 PES, 2,306 MP2, 1,385 teletext |
| 0.6 s | 576.7 ms | 542 | 0 | 196 AC-3 PES, 1,754 MP2, 7 teletext |
| 0 (the four runs above) | 783.7–787.9 ms | about 2,130, complete | 1,147–1,426 | 20–55 AC-3 PES |
| 0.9 s | 1,089.0 ms | 2,181, complete | 1,634, complete | 0 |

**The presentation latency and the audio loss are one quantity.** At one delay, the join alone moves
the presentation latency over 609 ms, and the less of it a join gets, the more audio it loses. That
is what an anchor set by the join's first frame predicts. It gives the slower-sent tracks less
than the delay by as much as it shortens the latency.

**Across hosts**, relay and importer on one host, export on another in the same region, 120 s (the
origin stops at 119 s). No shared clock, so no latency.

| `--delay` | Runs | `ts-tstd.py` | `compliance.py` | PCRs outside ±500 ns | Late drops | Carried | PCR clock against the receiving host |
|---|---|---|---|---|---|---|---|
| 1 s | the whole run | 56 of 56 | PASS | 0 of 4,732 | 0 | every PID; AC-3 3,541 units | −3.4 ppm over 108 s; 30 s windows +1.8, −7.9, +9.7 |
| 500 ms | the whole run | 57 of 57 | PASS | 0 of 4,769 | 8,410: every MP2, AC-3 and teletext unit, about 70 a second from the first second | video, SCTE-35 and SI only: 0 packets of MP2, AC-3 or teletext | −1.2 ppm; +47.4, −5.2, +37.2 |

**Under loss**, the [T8b](test-8b-congestion-control.md) namespace rig, 25 ms each way, BBRv3, 120 s.

| Arm | Runs | `ts-tstd.py` | `compliance.py` | PCRs outside ±500 ns | Late drops | Carried |
|---|---|---|---|---|---|---|
| 0 %, 1 s | the whole run | 56 of 56 | PASS | 0 of 4,742 | 415 AC-3 PES, 205 MP2, 1 video, about 5 a second throughout | no AC-3 at all; MP2 4,568 units, against 4,757 in the 1 % arm |
| 1 %, 1 s | the whole run | 57 of 57 | PASS | 0 of 4,768 | 0 | every PID; AC-3 3,568 units |
| 10 %, 1 s | exits at 10 s: "missed a decode deadline on PID 111" | — | — | — | — | — |
| 1 %, 500 ms | exits at 5 s, the same | — | — | — | — | — |

**The clock is inside 2.4.2.1's frequency tolerance.** Over 540 s at 1 s the output's PCR clock fits
−7.6 ppm against the host, with the source's at −6.4 ppm: the output follows the source to about
1 ppm. Across hosts it fits −3.4 and −1.2 ppm against the receiving host. On `49efbc9a1` the same fit
reads about 500 ppm ([below](#the-rework-49efbc9a1)).

**Where a run loses a track, it loses it whole and for the whole run.** The drops are whole units at
the track's own rate: each AC-3 PES is nine sync frames, 288 ms, and across hosts at 500 ms the
export dropped every MP2, AC-3 and teletext unit from the first second to the last. The same
cell passes on one join and loses a track on the next: at 500 ms on loopback, all four 60 s runs
and one of the two 540 s runs lost AC-3, and the other 540 s run did not; at 1 s, the 0 % loss
arm lost AC-3 and the 1 % arm did not. The join-phase runs tie the loss to the presentation latency
the join gives. The mechanism behind both is reasoned from the code, not traced. The clock is anchored on the first frame pushed,
and every track's newest group arrives within milliseconds of subscribing. A TS source sends video
up to 0.97 s ahead of its decode time and audio just in time. When the first frame is a fresh
keyframe, audio of the same decode time therefore arrives that much later, and where the difference
exceeds the delay every audio frame misses its deadline. The steering would close the gap, but at
0.075 Hz/s a 100 ms deficit takes over three hours. A frame that would be late before anything has
been released is dropped rather than moving the anchor, though nothing yet constrains the anchor
there. A join that anchors on a stale keyframe errs the other way: every track gets extra slack,
which shows as latency.

**The graders pass a programme with its audio missing.** The 500 ms cross-host egress passes
`ts-tstd.py` in every window, `compliance.py` and `pcrverify` with no MP2, AC-3 or teletext in it.
The T-STD grades the units present, and `compliance.py` checks the PIDs that carry packets. The unit
counts per PID against the source are what catch it, and every cell above is checked that way
([method notes](method-notes.md)).

**The export stops on a schedule overrun at 500 ms, and under loss.** Both 540 s runs at 500 ms
stopped on the video, 157 s and 202 s after subscribing, so at different points in the clip. Their
minimum video EB margins had fallen to 56.4 and 27.0 ms, against 213.9 ms over the first 60 s. The
overrun recurs at this delay on this clip, and is not one passage of it; what sets the time is not
located. At 1 s the same 540 s ran through. Under loss the stop comes within seconds at 10 % and at 1 % with a
500 ms delay. On the first head both loss arms stopped within 5 s unless lateness was made non-fatal;
this head runs 1 % at 1 s through with nothing dropped.

**Presentation latency fell, but at 500 ms the join sets it.** It is 1,766–1,791 ms at 1 s and
1,293 ms at 750 ms, against 2,125 and 2,201 ms on `49efbc9a1`, one join phase each. At 500 ms it
ranges from 480.1 to 1,089.0 ms over four join phases, against 1,409 ms on `49efbc9a1`. The only
500 ms runs with every track complete are at 798.5 ms, in the first 540 s run (which stopped at
157 s), and at 1,089.0 ms; every faster run lost audio. So the sub-second figures are not yet a
latency the lane delivers with its programme intact.

#### In mocked time, on `2dc542b4a`

The tests branch rebased onto this head. The drift cases now run the source 25 ppm off, inside
what the clock may follow, instead of 400 ppm, which the head now refuses by design. A new case
sends one track 700 ms after the other at a 500 ms delay, which is the wire's audio-loss
condition.

| Test | Result |
|---|---|
| A skip at the join, and one while running, keep every track on one clock | pass (both) |
| A source 25 ppm slow, and one 25 ppm fast, keep the delay over five minutes of media | pass (both) |
| Two legs render the same packets: clean, at a fractional rate, and on a source 25 ppm off | pass (all three) |
| The same with a group skipped as slow by both | **pass**; failed on `49efbc9a1` |
| A mid-group joiner's system clock stays within 30 ppm and 0.075 Hz/s, over 30 s windows | **pass**; failed at +433.5 ppm on `49efbc9a1` |
| A track sent 700 ms after the other, at a 500 ms delay, joined at a group boundary and mid-group, loses nothing | pass: the harness does not reproduce the wire's loss |

The jitter buffer's own 12 tests pass as well. The same late-track case fails on `559a35244`
([above](#acquiring-before-release-and-the-anchor-on-the-most-slack-559a35244)), so the harness can
reproduce a join that starves the later track; why it passes on this head is not located. It is not
evidence against the loss above.

### The rework, `49efbc9a1`

The head as pushed, with no environment variable, through the same T18 rig: the source paced on its
own PCR into `moq import ts`, relay and `moq export ts` on one host over loopback, the export
forwarded without re-clocking. Each run is 60 s, joined mid-stream and padded to the catalog's
9,945,951 b/s. The T-STD grades skip 5 s; `compliance.py` runs on the same file cut at the first
PCR 5 s in; `pcrverify` runs on the whole capture against the catalog rate.

| `--delay` | Runs the capture | `ts-tstd.py`, 2 s windows | Video EB peak, margin min | MP2 / AC-3 B margin min | `compliance.py` | PCRs outside ±500 ns | Delivery / presentation latency, median |
|---|---|---|---|---|---|---|---|
| 1 s | yes; exits at the end (below) | every buffer, 26 of 26 | 99.8 %, 641.8 ms | 68.1 / 144.6 ms | PASS | 0 of 2,295 | 1,978 / 2,125 ms |
| 750 ms | yes | every buffer, 26 of 26 | 82 %, 464.6 ms | 68.3 / 144.5 ms | one AC-3 B underflow, the last PES (below) | 0 of 2,330 | 2,250 / 2,201 ms |
| 500 ms | yes | every buffer, 26 of 26 | 57 %, 213.9 ms | 69.3 / 144.6 ms | one AC-3 B underflow, the last PES | 0 of 2,322 | 1,706 / 1,409 ms |

Every transport buffer has 0 overflows: AC-3's and MP2's peak at 150 B, teletext's at 60 of 480 B
(EN 300 472's TB, drained at 6.75 Mb/s), and every SCTE-35 and SI one at 169 B. MP2's B peaks at
2,910 of 3,584 B in every run, and AC-3's at 5,242 of 5,696 B at 1 s and 4,692 B at the other two.
Continuity errors are 0, and no PCR interval is
over 25.1 ms. At 500 ms the export dropped one video frame as late 16 ms after subscribing, the
join's first frame, before any output. Presentation latency is timed with
[`ts-decode-latency.py`](scripts/ts-decode-latency.py), 10 s settle, about 1,625 pictures per run;
the PTS and content keys agree. One run per delay. The 750 ms run reads slower than the 1 s one,
so these figures do not say what a delay costs. A plausible cause is the join's staleness below,
which differs per run; that is reasoned, not measured.

**The AC-3 underflow is the end of the capture.** The flagged unit is the last AC-3 PES, carrying
the first 354 B of a 768 B sync frame; every PES before it is a whole 776 B one. The rig stops the
source at 60 s, partway through a frame, and the export passes the partial frame on as a PES of its
own. At 1 s the same tail made the export exit, after the publisher's tracks had closed, with
"MPEG-TS output missed a decode deadline on PID 123". Dropping a sync frame shorter than its
header declares would remove both (reasoned).

**The steered clock is the output's system clock.** The jitter buffer steers its clock's rate,
within 500 ppm, so that the least slack a frame arrives with stays at the delay, and the export
lays each slot and stamps each PCR on that clock. A receiver locks its decoder's clock to the PCR,
so the steering is passed to it. 2.4.2.1 allows 27 MHz ±810 Hz (30 ppm), changing by at most
0.075 Hz/s, about 2.8 ppb a second. A receiver that joins mid-group anchors its clock on the first
frame of its first group, already up to a delay old, and the steering then wears that lead away
at the full 500 ppm. On the wire, the output's PCR clock fits −503.7, +520.9 and +515.1 ppm against
the receiving tap at 1 s, 750 ms and 500 ms over the 46 s graded, with the source tap at −10.4,
+44.8 and −6.1 ppm: about 500 ppm off the source in every run, as in mocked time below.
`pcrverify` and both T-STD checks pass these bytes, because they hold each PCR to its own byte
position and the buffers to the stream's own clock; TR 101 290's PCR_FO and PCR_DR are the measures
that would see it, and were not run.

Steering does two jobs, and the tolerance leaves room for one (reasoned). Following a source within
±30 ppm fits, if the loop is slow and slew-limited. A join's lead does not: 300 ms at 30 ppm takes
nearly three hours. So the lead has to go before the first output, either by subscribing at the
live edge or by measuring the least slack over the first group or two and anchoring there before
releasing anything, as an IRD acquires its STC before it locks. `2dc542b4a` took the first
([above](#the-live-edge-join-and-the-30-ppm-clock-2dc542b4a)). It cut the presentation latency, but
the anchor then depends on how old the join's first frame is, in both directions; the second option
is the one that would remove that.

#### In mocked time

Nine tests in `rs/moq-mux/src/container/ts/export_timing_test.rs` on the export's own crate,
paused clock: a live H.264 + AAC broadcast written frame by frame at the instant a source sends it,
with video written group by group so that a group can be left open and skipped as slow, as at the
field join. Receivers are `Export`s with a delay and a multiplex rate, each reading on its own
cadence. The branch is published for the maintainer
([upstream contributions](upstream-contributions.md)). On `49efbc9a1`:

| Test | Result |
|---|---|
| A skip at the join, and one while running, keep every track on one clock | pass (both) |
| A source 400 ppm slow, and one 400 ppm fast, keep the delay over five minutes of media, which walks an unsteered clock 120 ms | pass (both) |
| Two legs, one joined mid-group and reading every 100 ms, render the same packets, counters aside | pass |
| The same at a fractional packets-per-slot rate | pass |
| The same with the source 400 ppm off, three minutes | pass |
| The same with a group skipped as slow by both | **fails**: with the video late, the legs differ by 3 slots after the skip, and are identical when both read after every frame; with the audio late, they differ in a PES header byte at the skip even at equal cadence (not located) |
| A mid-group joiner's system clock stays within 30 ppm and 0.075 Hz/s, over 30 s windows | **fails**: +433.5 ppm in the first window |

Measured separately on the same rig, a mid-group joiner's slots ran 497.8 ppm fast over 12
minutes simulated, against 1.4 ppm for a receiver there from the start. Its slots went out 877 ms
after the other's at 30 s and 533 ms after at 12 minutes, closing about 15 ms every 30 s: about
half an hour at 17 times the tolerance, entered in one step rather than a slew. Read as a 1+1
pair, those two receivers start 877 ms apart in wall time, which a selector's skew budget would
have to absorb.

The counters are excluded because the export numbers them from what each leg has sent. ST 2022-7
selection wants identical packets from both legs, so a pair with different counters makes a
continuity error at each switch. The maintainer's suggested remedy is a counter derived from the
media; it is not built.

### The broadcast clip

| Clip | `--delay` | Rate | Join | Output before exit | Late drops | Overrun ("needs N packets") |
|---|---|---|---|---|---|---|
| CNNiEMEA2, full | 500 ms | catalog 9.946 Mb/s | mid-stream | ~2 s, no video PES | first video frame | 644 |
| CNNiEMEA2, full | 1 s | catalog | mid-stream | ~1.4 s | 0 | 5,671 |
| CNNiEMEA2, full | 1 s | catalog | subscriber first | ~4.3 s | 0 | 264 |
| CNNiEMEA2, full | 2 s | catalog | mid-stream | ~7 s | 0 | 288 |
| CNNiEMEA2, full | 3 s | catalog | mid-stream | ~11 s | 0 | 472 |
| CNNiEMEA2, full | 1 s | 11 Mb/s | mid-stream | ~11 s | 0 | 238 |
| CNNiEMEA2, full, upstream harness | 500 ms (default) | catalog | — | 2.7 s | 120 (MP2 72, verbatim 48) | 352 |
| CNN video + MP2, upstream harness | 500 ms | catalog 9.70 Mb/s | — | — | 72 (MP2) | 352 |
| CNN video only, upstream harness | 500 ms | catalog 9.50 Mb/s | — | — | 0 | 165 |
| CNN video only | 2 s | catalog | mid-stream | ~10 s | 0 | 657 |
| CNN video only | 5 s | catalog | mid-stream | 17.60 s of DTS | 0 | 366 |
| CNN video only | 8 s | catalog | mid-stream | runs the capture (43 s graded) | 0 | none |

On a mid-stream join, the export writes the first group's keyframe and then nothing until the next
group's, 1.2 s of PTS later. That hole, and the window of units still queued when the export
stops, account for the PTS of a short capture covering less than its PCR. It is not a slow release.

### Where the broadcast clip fails

The clip is a hierarchical-B pyramid with open GOPs: each I-frame decodes 0.40 s before it is
presented and is followed in decode order by seven leading pictures. It switches between frame
and field coding (PAFF) every few seconds. In field-coded passages each field is its own PES, 20 ms
apart, and for a few hundred milliseconds the fields run 260–500 packets each: about 3,600
packets in 0.26 s.

**The load fits; the policy does not.** On the source wire the video PID never exceeds 18,008
packets in any 3 s (150.1 per slot; the stripped clip's rate is 9.50 Mb/s). In the export,
`schedule.rs` gives each later slot `rate / (188 × 8 × 40) − 1` = 156 packets of room, and sends in
each slot only what keeps the queued units on time. A unit enters the queue a window ahead of its
decode slot. The source meets the field burst by having sent the stretch before it early:
`ts-tstd.py` on the source gives a residence maximum of 0.97 s and EB peak 1,066,788 of 1,099,696 B
(CpbSize 8,797,568 bits). The export has padded those slots with nulls, so when the burst enters
its window, the window's queue exceeds the window's room.

**Replayed offline.** [`ts-schedule-replay.py`](scripts/ts-schedule-replay.py) replays the rule on
the stripped video-only clip at 9,501,512 b/s, the rate the export padded to. It runs on the
source's DTS, and on the DTS the export authors from PTS: a port of its decode clock, which
reproduces the PTS − DTS of 229 of 229 frames of the 2 s capture, with the SPS's 40 ms period and
the catalog's 36,000-tick reserve.

| `--delay` | As late as possible (the export), source DTS | As late as possible, authored DTS | Earliest deadline first, limited by EB, authored DTS |
|---|---|---|---|
| 0.5 s | stops | stops at start | late at start |
| 1 s | stops, 3.28 s out | stops, 3.78 s out | fits, EB peak 100 % |
| 2 s | stops, 2.33 s out | stops, 8.88 s out | fits |
| 3 s | stops, 1.35 s out | stops, 7.88 s out | fits |
| 5 s | fits | stops, 17.57 s out | fits |
| 8 s | fits | fits | fits |

"Out" is how much of the decode timeline has been sent when the rule fails. Two runs of the real
export on the same clip then tested the replay's two predictions. At `--delay 5s` it stopped with
17.60 s of decode time out ("needs 366 packets"). At `--delay 8s` it ran the whole publish (43 s
graded), with no overrun and no late drop. `ts-tstd.py` passes that output with 0 TB overflow, 0 EB
underflow, EB peak 532,069 of 1,099,696 B and a minimum EB margin of 1.3 ms. On the source's DTS the
earliest-deadline policy also fits at 0.5 s.

**The authored DTS.** The export carries no source DTS; it re-authors one from the PTS, handing the
PTS out in display order `reserve / period` = 10 pictures late. Ten pictures span 400 ms when they
are frames and 200 ms when they are fields, so against the source's DTS the authored DTS runs
0.28 s early in frame-coded passages and 0.08 s early in field-coded ones. Across each switch the
authored clock runs at half or double speed, compressing the decode timeline relative to the
bytes it carries. At start-up the first GOP's leading pictures precede its I-frame in display
order, and all seven get DTS one tick apart. With the source's DTS the as-late-as-possible rule
fits at 5 s; with the authored DTS it needs 8 s.

### A buffer-limited schedule, built

Two scratch patches to the PR head's `schedule.rs`, each taking its buffer parameters from
environment variables rather than the stream. Both count 184 bytes of decoder buffer per packet
sent. Both free a unit's bytes once the slot after its due slot is past: a slot's bytes are timed
up to its end boundary, so a unit due in slot k decodes during slot k + 1, and an occupancy count
that frees it any earlier overfills EB by up to a slot.

- **EB-limited video** (77 lines). It keeps the export's floor, the fewest packets that keep every
  unit on time, and fills the rest of each slot from queued video while EB has room. Audio and
  tables stay on the floor.
- **Per-PID admission** (about 200 lines). It replaces the floor. Each slot's packets go earliest
  deadline first across PIDs, each PID in its own order, each unit as soon as it is a window from
  its deadline. A PID takes at most `Rx × 25 ms / 1,504 − 1` packets per slot, which its transport
  buffer drains within the slot since the layout spreads them evenly. A PID given a decoder buffer
  takes no more than the buffer has room for. A PID without one (teletext, SCTE-35) goes in its due
  slot or the one before. A unit declared to carry *n* access units has frame k due at the
  unit's due slot plus k/*n* of the gap to that PID's next unit, and frees each frame's bytes
  separately. Because units keep only their own PID's order, the export's pulling of earlier units'
  deadlines down to a later unit's is switched off. A unit not complete by its deadline fails the
  export, as an overrun does in the unpatched build. The exceptions are a unit pushed after its
  deadline, the export's existing grace window after a rate change, and the first two windows of
  output, where the leading pictures' authored DTS is known to be unmeetable.

The parameters are taken from the clip. The video's decoder budget is one buffer of cpb + BSmux + BSoh,
which is how `ts-tstd.py` sized AVC before [T46](test-46-tstd-check-cross-validation.md) corrected it
to 2.14.3.1's leak model (MB 2,666,304 B and EB 1,099,696 B here). The budget is larger than EB alone,
so in the outputs that use it EB fills and up to about 12.5 KB waits in MB, which the leak model
allows. It is far inside MB + EB, so the patch is conservative against overflow, not wrong. It does
not model the leak's transfer into EB; underflow is what the grader checks, and every verdict here
comes from the grader.

| PID | Transport buffer drain | Decoder buffer given | Access units per unit |
|---|---|---|---|
| video | 10,557,082 b/s | 1,115,696 B | 1 |
| MP2 | 2 Mb/s | 3,584 B | 1 (the export repacketizes MP2 one frame per PES) |
| AC-3 | 2 Mb/s | 4,928 B: the 5,696 B buffer less one frame | 9 (the source's PES, passed through) |
| teletext | 6.75 Mb/s | none | 1 |
| others | 1 Mb/s | none | 1 |

AC-3 is given one frame less than its buffer because the patch places frame deadlines in whole
slots, and a 32 ms frame does not divide a 25 ms slot. Given the full 5,696 B on a 20 s run, B
peaked at 6,088 B; that run was not kept, so this figure is the uncorrected grader's. Graded with `ts-tstd.py` skipping 5 s, and `compliance.py` on the same file cut
5 s in:

| Build, clip, `--delay` | Runs | Video EB | MP2 B | AC-3 TB / B | P1 on the same bytes |
|---|---|---|---|---|---|
| #4645, video only, 8 s | yes, 43 s | pass, peak 48 %, margin min 1.3 ms | — | — | 0 CC errors |
| #4645, full, 8 s | yes, 42.8 s of DTS | pass, peak 48 % | **peak 11,170 of 3,584 B**, 4 of 19 windows | **2,495 pkts over** / **16,899 of 5,696 B**, 0 of 19 | 0 CC errors, PCR ≤ 25 ms |
| EB-limited, video only, 1 s | yes, 57.4 s of DTS | pass, EB full at peak with 12,538 B in MB, margin min 510 ms, 26 of 26 | — | — | one 975 ms PCR gap at the join |
| EB-limited, full, 1 s | yes, 57.3 s of DTS | pass, EB full at peak with 12,538 B in MB, margin min 512 ms, 26 of 26 | pass, 26 of 26 | **4,196 pkts over** / **6,926 of 5,696 B**, 0 of 26 | 0 CC errors, PCR ≤ 25 ms |
| Per-PID, full, 1 s | yes, 56.6 s of PCR | pass, peak 986,624 B (90 %), margin min 413 ms, 25 of 25 | pass, peak 2,910 B, margin min 63 ms, 25 of 25 | 0 over / peak 5,366 B, 25 of 25 | 0 CC errors, PCR ≤ 25 ms, `compliance.py` PASS |
| Per-PID, full, 750 ms | yes, 57.9 s of PCR | pass, peak 901,489 B (82 %), margin min 339 ms, 26 of 26 | pass, peak 2,910 B, margin min 68 ms, 26 of 26 | 0 over / peak 5,366 B, 26 of 26 | 0 CC errors, PCR ≤ 25 ms, `compliance.py` PASS |
| Per-PID, full, 500 ms | no: stops at 9.3 s of PCR, a 356-packet video unit late | — | — | — | — |

Every transport buffer in the per-PID outputs, teletext and SCTE-35 included, has 0 overflows;
AC-3's peaks at 150 B. Every slot carries 165 or 166 packets. `compliance.py`'s one warning in both
is its bitrate-consistency shape check (coefficient of variation 0.17 and 0.19 against 0.10). PCR
accuracy fails on every PCR (2,317 and 2,336) against ±500 ns, at 49 µs. The patches do not touch
the stamping, so this is the export's PCR stamping, already described below. The 975 ms gap is
the join's first-group hole, which the export lays as skipped slots, inside the graded skip.

**Why 500 ms stops.** Replayed with the video at 9.48 Mb/s, the multiplex rate less what the other
PIDs take on the source (MP2 202 kb/s, AC-3 198 kb/s, teletext 38 kb/s, tables 24 kb/s), the
buffer-limited rule at 0.5 s is late in 73 episodes on the authored DTS, the first at 0.03 s and
3.9 s, against 1 episode (at 203 s) on the source's DTS. At 0.75 s it fits on both, which the live
750 ms run confirms. At 500 ms this clip fails on the export's authored DTS, not on the per-PID
scheduler.

**Delivery latency** of the runs that complete is 4,181 ms median (p95 4,250) at 1 s and 2,716 ms
(p95 2,777) at 750 ms. At a fixed delay it moves by more than a second between builds. The two
EB-limited runs at 1 s gave 1,846 ms (video only) and 3,171 ms (full clip). The spread is not
located, so these figures do not rank the builds.

**Presentation latency** of the two conformant runs, timed where a decoder shows each picture
([`ts-decode-latency.py`](scripts/ts-decode-latency.py), 10 s settle, about 1,650 pictures each), is
a median 4,290.9 ms (spread 17.3 ms) at 1 s and 2,771.0 ms (spread 5.0 ms) at 750 ms, flat over each
run. The PTS key and [T46](test-46-tstd-check-cross-validation.md)'s content key agree to 0.3 ms at
1 s, since the export carries the source's PTS. These are latencies of conformant bytes, but one run
each, on loopback. The 1.5 s between them is six times the 250 ms between the delays, the same
unlocated spread as the delivery figures, so they say what one run cost and not what a delay costs.

### Under loss, and across hosts (per-PID build, 1 s)

Graded with `ts-tstd.py` skipping 5 s, 2 s windows, on the export's output file. "Lost" is decode
time the source carries and the output does not.

| Arm | Runs the window | Buffers (windows legal) | What the export did |
|---|---|---|---|
| Loss rig, 0 % | yes | every buffer, 56 of 56; EB margin min 274.8 ms | lost nothing |
| Loss rig, 1 % | yes | 54 of 55; MP2 B 11 overflowing arrivals (peak 5,776 B), AC-3 B 21 (peak 13,957 B), system TB 2 packets | lost 0.12 s of video and one 0.288 s AC-3 hole; 3 groups evicted; one grid restart at 73.9 s, the PCR stepping back 1.35 s with `discontinuity_indicator` set |
| Loss rig, 10 % | yes | moot | 744,318 of 759,806 packets are nulls, 11,415 video; 54 PCR discontinuities; 122 groups evicted |

**The 1 % failures sit at the restart.** Split at the restart, the first part passes in all 34
windows and the second in all 19, apart from the 2 table packets over the system transport buffer.
The scratch patch empties its occupancy model when the export clears its schedule on a restart, and
a receiver's buffers are not emptied by a PCR discontinuity, so the restart window overfills what
the patch believed was empty. Without `MOQ_TS_LATE=send`, the 1 % arm stopped at 5 s and the 10 %
arm at 30 s on a deadline miss (at 1 %, a 919-packet video unit 12 slots late). Those arms were
not traced, so whether that miss was the join skew below is not known.

**Across hosts, the outcome is set at the join.** In every traced cross-host run the video moved
to a second generation within its first frames and stayed there, while every other track stayed on
generation 0. The two runs with the consumer's log on show the cause: a video group skipped at the
join ("skipping slow groups"), which the consumer counts as a discontinuity. #4645's jitter buffer
moves a track that crosses a discontinuity to a new generation. It joins one another track has
already opened if its frame lands on that clock, and otherwise opens its own. Video is the only
track that crosses one, so it opens its own. The new anchor is the frame's arrival, or the latest
deadline already given out less the delay, whichever is later. Both cases occurred: in runs B and
the PR-head run the video's first frame had exactly the delay as slack (anchored at its arrival),
and in A and C it had 1,986 and 2,565 ms (pinned to the earlier deadlines). From then on the video
is released on one clock and everything else on another. The offset is fixed for the run. It is
measured from the release stage's own log: each frame's arrival plus its slack, less its decode
time, is constant within a generation (spread under 75 ms), and the offset is the difference between
the two generations' values. What sets its size is (reasoned) when each generation's first frame
arrived relative to its decode time, which a join decides. The export subscribed with tracing on:

| Run | Video clock behind the rest | Video lead into the schedule | Result |
|---|---|---|---|
| A, traced | 200 ms | 32 slots | every buffer passes, 56 of 56; EB margin min 413 ms, MP2 63 ms, AC-3 138 ms |
| B, traced | 979 ms | 1 slot | video 2,257 of 4,098 units underflow, MP2 2,286 of 4,691, AC-3 761 of 2,271; 1 of 56 windows legal |
| C, traced | 960 ms | 1 slot | video 1,803 of 4,071 units underflow, MP2 2,071 of 4,697, AC-3 943 of 3,526; 5 of 56 windows legal |
| C, repeated untraced | — | — | the same underflow counts, and minimum margins within 0.1 ms |
| D, untraced | — | — | video passes, EB full at peak with 12,681 B in MB, margin min 507 ms; every MP2 unit underflows (margin −189 ms), AC-3 2,403 of 3,591; 0 of 57 windows legal |
| PR head behaviour, traced | 959 ms | not logged | the export stops within seconds: "needs 1,855 packets in a 25 ms slot" |

"Lead" is the minimum number of slots before its deadline a video unit reached the schedule, from
runs that logged the schedule. Every other PID reached it at least 40 slots ahead, a whole delay, in
each of them. In run D the video ran *ahead* of the audio: audio units underflow by a nearly
constant amount while the video sends early, the converse of B and C. It was not traced, so its
offset is not measured, but two traced loopback joins below reproduce its margins to 0.1 ms with
the video 1,200 ms ahead. The last row ran the same build with no
`MOQ_TS_*` variable set, which leaves the PR head's schedule unchanged. It shows the skew is the
release stage's, not the scratch patch's. A sixth traced run is void, a rig fault: its origin
started while the previous run's relay still held the port. Its first 8 s show the same skip and a
960 ms offset.

**On one host the same split occurs, with the same states.** Both roles of the cross-host rig on
one host over loopback, and the T8b namespace rig at 0 %, each run for 60 s on the traced build:

| Rig | Video clock behind the rest | Video / MP2 lead | Result |
|---|---|---|---|
| Loopback, two joins | 200 ms | 32 / 40 slots | every buffer passes, 26 of 26; EB margin min 413.4 ms, MP2 63.0–63.3 ms, AC-3 138.4 ms |
| Loopback, two joins | −1,200 ms (ahead) | 40 / −8 slots | every MP2 unit underflows, margin min −188.5 ms; AC-3 1,144 of about 1,720; video passes, EB full at peak with 12,538 B in MB; 0 of 27 |
| Namespace rig, 0 % | 960 ms | 1 / 40 slots | video 916 of 1,862 units underflow, MP2 1,075 of 2,165; 2 of 25 |
| Namespace rig, 0 % | — (five generations) | 1 / −25 slots | an MP2 group evicted at the join opened a generation for the audio as well; every MP2 unit underflows (margin −596 ms), video 687 of 1,838; 0 of 25 |

Each pair of loopback joins reproduces the other's margins within 0.3 ms. Every join skipped one
video group.
The earlier loopback pass at 1 s ([above](#a-buffer-limited-schedule-built)) has the 200 ms state's
minimum margins to within 0.3 ms (413.4, 63.0 and 138.4 ms), so it is that state (reasoned from the
identity; that run was not traced). The 750 ms pass's margins (338.8, 67.8, 150.0 ms) have no
traced counterpart. So the per-PID build carries the full multiplex at 1 s on a join that leaves
the video 200 ms behind, which three of eleven traced joins did. The release stage, not the
schedule or the topology, decides which.

Timestamps are not affected. Matched by payload against the source in the 0 % loss arm and in run
D, a passing and a failing run, the video and MP2 PES carry the source's PTS: median shift 0 over
about 4,100 video and 540 MP2 matches in each. The skew is in when the bytes are sent, not in what
they say.

### Keeping the tracks on one clock (scratch)

Two changes to the release stage (`jitter.rs`, about 30 lines), each behind an environment
variable, on top of the per-PID build:

- **Rejoin** (`MOQ_JITTER_REJOIN`). A frame after a discontinuity that lands on the latest clock
  stays on it, even when no other track has opened that generation. This removes the split at
  joins where the video's first frame after the skip lands on the existing clock.
- **Follow** (`MOQ_JITTER_FOLLOW`). A track on an older generation moves to the newest one at its
  first frame that is not late there. The test is only "not late", because the SCTE-35 tracks'
  sparse frames decode far enough ahead of their arrival to fail the upper bound of "lands", and
  with that bound they stayed behind.

Graded as above, 60 s per join, traced:

| Release stage | Joins | Every buffer, every window | Lead into the schedule |
|---|---|---|---|
| Rejoin only | 6 on one host | 3 pass, 3 fail | where a second generation still opened, as before |
| Rejoin and follow, follow requiring "lands" | 6 on one host, 3 across hosts | 6 of 6 on one host; 1 of 3 across hosts | in the two failures, every PID down to 1 slot, with only the three SCTE-35 tracks (181 frames) left on the old generation |
| Rejoin and follow, follow requiring "not late" | 6 on one host, 5 across hosts | **11 of 11** | video and MP2 40 slots in every join; EB margin min 509.0–509.1 ms in every join |

Two further cross-host joins are void, a rig fault: the guard refused their origins while a relay
was still holding the port, and the export captured nothing.

**With one clock, every join conforms and the states collapse to one.** The runs that pass do so
with the same margins whether the video stayed on generation 0 or every track moved to generation
1. On this rig, then, the split accounts for all of the join dependence.

**The change is not a fix as written.** Upstream's `moq-mux` tests pass without the variables
(941 of 941). With each change, two fail:

- *Follow* breaks `a_discontinuity_re_anchors` and `a_backlog_releases_generations_in_turn`. A
  track still carrying its old timeline after the publisher restarts is not late on the new clock,
  so it follows it and is held seconds too long.
- *Rejoin* breaks `discontinuity_flags_the_break_once_across_tracks` and
  `discontinuity_re_emits_tables_and_resumes_the_clock`. A source discontinuity whose timestamps
  land on the old clock no longer produces the flagged break and table re-emission they expect.

The release stage cannot tell a group the consumer skipped at the join from a timeline restart,
because both arrive as the same counter. The distinction belongs where the skip happens (reasoned).
One option is a consumer that does not count a skip the caller never saw. Another is a
discontinuity that says whether the timeline continued.

### The generated clip

| `--delay` | Runs the capture | `compliance.py` | `ts-tstd.py` (skip 5 s, 2 s windows) | Latency (delivery, median) |
|---|---|---|---|---|
| 500 ms (upstream harness) | no: 2.2 s of 60 s, overrun "needs 279 packets" | FAIL: EB underflow ×58, TB overflow ×17,104 | — | — |
| 2 s | yes, 55 s | PASS, EB peak 39 % | PASS, 25 of 25 windows; EB margin min 5.0 ms, residence max 0.363 s | 6,832 ms (p95 6,910; trend +17 ms over 55 s) |

The export sends each picture as late as the rate allows. Against the source's EB margin of 282 ms
minimum and residence of 0.7 s maximum, the output's minimum margin is 5.0 ms and its maximum
residence 0.363 s. That is legal, and it is why a mid-stream start needs the whole send-ahead in
hand before the first unit is due.

### P1/P2 of the same bytes (2 s, generated clip)

- Continuity errors 0; PCR repetition 25 ms on every interval (0 over 40 ms).
- **PCR accuracy fails on nearly every PCR.** `pcrverify --absolute --jitter-max 13` fails all 2,279,
  whether given 9,999,999 b/s (the catalog rate the export padded to) or 10 Mb/s. Without
  `--absolute` (13 µs), it still fails all of them. A fit of PCR value against packet index after
  the first 10 s gives exactly 9,999,999 b/s with residuals of median 37.6 µs and maximum 75.3 µs:
  1,868 of 1,880 PCRs outside ±0.5 µs. The PCRs are 166 or 167 packets apart (1,770 and 509
  intervals). The value is the slot's time, and the byte position is that time rounded to a whole
  packet. Over the whole capture the residuals reach 22 ms, from the unpadded first ~2 s before the
  catalog rate arrives.

## Conclusions

Conclusions 1–9 are on `4b7158d6c00d` and its scratch builds; 10–12 are on `49efbc9a1`, 13–16
on `2dc542b4a`, and 17–19 on `559a35244` and its scratch build.

1. **On `4b7158d6c00d`, #4645 did not carry a real broadcast multiplex.** At every delay tried up
   to 3 s, and in each variation tried at one delay (a higher rate, subscribing first, the video
   alone), the export stops within seconds. The maintainer's harness reproduces it at the defaults, so the report does
   not depend on this rig. At 8 s it runs, on the video alone and on the full clip.
2. **The cause is the send policy, with the authored DTS compounding it.** Sending as late as
   possible with one window of lookahead cannot absorb a stretch that outruns the rate for about
   a window. A broadcast encoder spends its CPB on exactly such stretches. The replay locates
   this and predicted both further runs. Sending the video earliest deadline first within its EB
   removes the overrun in a built export, at 1 s on the full clip.
3. **A schedule inside the export can carry the full broadcast multiplex with every buffer
   conformant, at 1 s and 750 ms, in a scratch build, on a favourable join.** PCR accuracy still
   fails, for the reason in conclusion 6. The 1 s pass is the join state that leaves the video
   200 ms behind the other tracks; on the other states the same build fails (conclusion 8). It needs three things #4645 lacks: each PID's packets admitted
   against its own transport and decoder buffers rather than a shared rate floor; deadlines and
   buffer removal per access unit where a passed-through PES carries several; and no coupling of
   one PID's deadlines to another's push order. Unpatched, the audio fails at 8 s. With the video
   fix alone, MP2 passes and AC-3 fails. This is the per-packet admission
   [T45](test-45-live-tstd-remux.md)'s re-multiplexer does, built into the subscriber. The parameters
   came from the clip by hand; a shipped schedule would read them from the stream or the catalog.
4. **The 500 ms default is out of reach on this clip because of the authored DTS, not the
   schedule.** At 500 ms the buffer-limited rule meets the source's DTS in all but one episode over
   the clip and misses the authored DTS 73 times, and the live build stops.
5. **Its default is short for a broadcast CPB, independent of that failure.** A generated stream
   with 0.7 s of send-ahead, which passes the T-STD as a source, cannot start at 500 ms and
   conforms at 2 s.
6. **On the generated clip, its output passes both T-STD checks and fails PCR accuracy almost throughout.** The
   buffer model and P2 disagree on the same bytes, which is
   [T44](test-44-tstd-grading.md)'s point in the other direction: a T-STD pass is not a TR 101 290
   pass either.
7. **The latency at 2 s is about twice what the design accounts for.** This is on loopback. The
   ~2 s unexplained has the same order as the transit T45 left unlocated on `ffa5b81b`, and may be
   the same thing. Nothing here says so yet.
8. **#4645's release stage puts the video on a clock of its own at the join, and the offset
   decides conformance.** A discontinuity crossed by one track alone, here a video group skipped
   at the join, opens a generation only that track uses. All eleven traced joins did this, on one
   host and across hosts. The offset fell into three states, fixed per run: 200 ms behind (three
   joins), 959–979 ms behind (five) and 1,200 ms ahead (two). In the eleventh an MP2 group was
   also evicted at the join, and the audio got generations of its own. Only the first state leaves
   both sides with room. A whole delay behind, the schedule receives video units almost at their deadlines.
   Well ahead, it receives audio after theirs. In the one PR-head run the export stopped on it; the
   per-PID build runs and fails the buffer model. The defect is in the release stage, not in
   either schedule, and (reasoned) no schedule fix makes the output's conformance independent of
   the join. Keeping the tracks on one clock does: in a scratch release stage, eleven of eleven
   joins passed with one set of margins. As written it breaks upstream's handling of a genuine
   timeline restart, which the release stage cannot tell from a skip at the join.
9. **Under loss, the per-PID build's only failure at 1 % is its own model at a grid restart.** A
   shipped schedule has to carry the receiver's buffer occupancy across a restart, since a PCR
   discontinuity does not empty a decoder. At 10 % the lane delivers almost nothing; that is the
   transport, not the schedule.
10. **The rework carries the broadcast clip conformantly at 500 ms, 750 ms and 1 s, on one host.**
    Every buffer passes in every window and every PCR is within ±500 ns on the same bytes, at
    presentation latencies of 1.4–2.2 s, one run each. Conclusions 2, 3, 4, 6 and 8 are the
    mechanisms it removed: per-PID admission replaced the send policy, DTS authored in time made
    500 ms reachable, PCR stamping from the slot's first byte cleared P2, and one clock removed the
    join dependence. Against the laboratory re-multiplexer's 2,196.7 ms on this clip
    ([T45](test-45-live-tstd-remux.md)) the figures are comparable, but the builds and stages
    differ and single runs do not rank them.
11. **Its output's system clock is out of 13818-1's tolerance for tens of minutes after a
    mid-group join.** The clock steering that keeps the delay is also the PCR's clock, and it runs
    at its 500 ppm limit to remove the join's lead. This is a conformance failure that neither
    T-STD check nor `pcrverify` detects. Holding the steering inside ±30 ppm, slew-limited, with
    the lead removed at the join, was the proposed fix; `2dc542b4a` built it (conclusion 13).
12. **On `49efbc9a1`, 1+1 identity held in mocked time except after a skip and in the continuity
    counter.** On `2dc542b4a` the skip case passes too, which leaves the counter. Until it is
    derived from the media, two legs are not an ST 2022-7 pair, which needs identical packets.
13. **`2dc542b4a` holds the output's system clock inside 2.4.2.1's frequency tolerance.** Over
    540 s the output follows the source to about 1 ppm, and across hosts it is within 3.4 ppm of
    the receiving host. Its slew limit is not graded: the instrument resolves tens of ppm per 30 s
    window, not 2.8 ppb a second.
14. **At 1 s it carries the broadcast clip conformantly, on loopback, across hosts and under 1 %
    loss, where it carries every track.** One 1 s run of five lost every AC-3 unit
    (conclusion 15). On the first head the 1 % arm stopped within 5 s unless lateness was made
    non-fatal.
15. **The clock's anchor now depends on the join, and a 30 ppm clock cannot undo it.** Which
    frame anchors the clock, and how far ahead of its decode time the source sent it, decides
    whether the slower-sent tracks have their delay. Where they do not, they are dropped whole for
    the whole run: every MP2, AC-3 and teletext unit across hosts at 500 ms. At 500 ms this was the
    usual outcome (eight of ten runs) and at 1 s it happened once in five. At one delay the join
    alone moved the presentation latency over 609 ms, and the faster the join, the more audio it
    lost. The cause is reasoned from the code and consistent with that, not traced. The remedy is the other half of the proposal in conclusion 11:
    measure the least slack across the tracks before releasing anything, and anchor there.
16. **500 ms is not yet a working delay on this clip.** Its presentation latency is under a
    second on most joins, but those joins lose audio, both long runs stopped on a schedule overrun,
    at 157 s and 202 s, and under 1 % loss it stops within seconds. At 1 s the same 540 s ran through. A working 500 ms on this
    clip has not been shown.
17. **`559a35244` acquires before releasing, as conclusion 15 proposed, but anchors on the most
    slack, not the least.** Its acquisition and its steering floor both choose across all tracks the
    frame that arrived with the most slack. On a TS source that is the video. The audio is then left
    the delay less the video's send-ahead, and at 1 s or below it loses every frame on most joins.
    That is located in the code and reproduced in mocked time, and it is a regression on
    `2dc542b4a` at 1 s. The clock stays inside 2.4.2.1's tolerance, as on `2dc542b4a`.
18. **Anchoring and steering on the track with the least slack, after hearing from every track,
    carries the clip conformantly at 500 ms, 750 ms and 1 s, on loopback, across hosts and under
    1 % loss.** That is a scratch build, single runs, on one join phase each plus one shifted phase
    at 500 ms and 1 s. Over 540 s at 1 s it carries every track with every buffer passing. At 500 ms
    it carries every track until the schedule overrun at about 157 s that `2dc542b4a` also hit, so
    500 ms is still not a working delay over a whole capture.
19. **Carried whole, the clip's presentation latency is twice the delay plus about 275 ms.** The
    video's send-ahead now shows up as latency rather than being taken out of the audio's delay. At
    1 s that is about 2.27 s, beside the re-multiplexer's 2,196.7 ms on this clip
    ([T45](test-45-live-tstd-remux.md)), so no latency advantage is shown here for the in-export
    schedule. Different builds and single runs do not rank them. #4681's send-ahead cap, which
    would also redefine what the delay covers, is the change that would move it (reasoned).

## Limits

- **On `559a35244` and its scratch build:** nine loopback cells on the head and seven on the scratch
  build, 60 s except one 540 s cell on the head and two on the scratch build; two cross-host runs on
  each; four loss arms on the head and five on the scratch build. One clip, untraced. The loss rig
  does not count netem's drops, so the 1 % arms rest on the configured rate. Which frame anchored each join is inferred from the drops and the
  margins, not logged. The arm that would settle it is a run with the anchoring track and each
  track's first slack logged, at joins spread across a GOP. Not run on the scratch build: a
  publisher restart, a sparse track's effect on the hold, the cross-host loss path, and the
  generated clip.

- **On `2dc542b4a`:** twelve loopback runs (two of 540 s, three at shifted join phases), two
  cross-host and four loss arms, one clip, untraced. Four join phases were sampled at 500 ms and
  one at the other delays, so the audio-loss count per delay is a count of runs, not a frequency.
  The anchor mechanism is reasoned from the code, and the join-phase runs are consistent with it.
  The arm that would settle it is a run with the anchoring frame and each track's first slack
  logged, at joins spread across a GOP. The clock is fitted
  against each host's own clock, not a reference: across hosts, the figure is the output against
  the receiving host, which includes that host's own offset. The slew limit is not graded, and
  TR 101 290 PCR_FO and PCR_DR were not run. Not run on it: a publisher restart, a source more
  than 30 ppm off, and the generated clip.
- **On `49efbc9a1`:** three runs, one per delay, 60 s each, one host over loopback, one join each,
  untraced. Not run on it: the loss rig, cross-host, a publisher restart, the generated clip, and
  anything over a minute on the wire. Its clock was fitted on 46 s per run. The mocked-time tests
  model one H.264 + AAC broadcast, not this clip.
- One host, loopback, one run per cell, one broadcast channel (two captures of the same channel are
  on hand, not two channels). The loss rig and cross-host ran on the per-PID build at 1 s only.
  The loss arms ran once each, untraced, so which join state each landed in is not known. Cross-host
  is one pair of hosts in one region, seven runs, of which five were traced; the co-resident joins
  are six traced runs of 60 s on one of those hosts.
- Eleven traced joins show three offset states, plus one multi-generation join, and their
  outcomes. They do not give the states' frequencies, nor what in the join selects one; the arm
  that would settle it is a run of joins at controlled offsets into the source's group, traced.
  With the tracks on one clock the question no longer decides conformance on this rig.
- The one-clock release stage ran at 1 s, 60 s per join, without loss, on one clip. Its latency
  was not measured, and nor were a publisher restart or a mid-run eviction on it, which are the
  cases its test failures concern.
- The replay models the video PID alone; the 500 ms explanation takes the other PIDs as a fixed
  rate share.
- The patches are scratch builds, run once per cell. The per-PID patch's occupancy model resets
  on a grid restart, which the 1 % arm shows a receiver's buffers do not.
  The per-PID patch takes every buffer size, drain rate and AC-3's frame count from environment
  variables set by hand from this clip. It gives AC-3 one frame less than its buffer to cover
  whole-slot frame timing. It models no decoder buffer for teletext or SCTE-35. It does not hold
  the program tables ahead of other PIDs across slots, only within one. Lateness in the first two
  windows of output is not fatal and not graded (the grade skips 5 s), so the start is not shown
  conformant. Settling those needs the parameters read from the stream and a start that does not
  bunch the leading pictures' DTS.
- Delivery latency at a fixed delay moved by more than a second between builds; the cause is not
  located.
- The generated clip matches the broadcast one on CPB size and send-ahead only. It has no
  field-coded passages, and x264 cannot make them (it encodes MBAFF, not PAFF), so a shareable
  fixture for this failure would need a load profile that outruns the rate for about a window
  rather than an interlaced encode.
- The join hole (one keyframe, then the next group) is observed, not diagnosed.
- The forwarder writes datagrams as the export's slices arrive, so wire arrival timing is the
  export's plus one loopback hop. Arrival-timing PCR jitter was not graded; the PCR accuracy above
  is the values against byte position, the domain `pcrverify` grades.

## Reproduction

```bash
# Build the PR head in a worktree (never in the shared checkout)
git -C <moq-dev> fetch origin pull/4645/head
git -C <moq-dev> worktree add <wt> --detach 4b7158d6c00d
cd <wt> && CARGO_TARGET_DIR=<wt>/target nice -n 15 cargo build --release -j 4 --bin moq --bin moq-relay

# The rework, 49efbc9a1: no MOQ_TS_* variable; one cell per delay, then the three grades
VPID=111 RELAY_TOML=<wt>/demo/relay/localhost.toml MOQ=<bin>/moq RELAY=<bin>/moq-relay MOQLAT=500ms CAP=150 \
  PACER=lab/scripts/ts-rtp-forward.py bash lab/scripts/t18-arm.sh <broadcast>.ts <out> 60 moq 0
python3 lab/scripts/ts-tstd.py <out>/moq-c0-egress.ts --skip 5 --window 2
# The rig's summary grades PCR against its own RATE (10 Mb/s) and so fails every PCR; grade at the catalog rate
tsp -I file <out>/moq-c0-egress.ts -P pcrverify --absolute --jitter-max 13 --bitrate <catalog-rate> -O drop
python3 lab/scripts/ts-decode-latency.py <broadcast>.ts <out>/moq-c0-source.csv <out>/moq-c0-egress.ts \
  <out>/moq-c0-egress.csv --pid 111 --settle 10 --key content
# The mocked-time tests, on the tests branch (none is #[ignore]d on 2dc542b4a)
cd <wt> && cargo nextest run -p moq-mux --run-ignored all -E 'test(/export_timing/)'

# 2dc542b4a: the same cells, 540 s as well; then the PCR clock rate and the per-PID completeness
VPID=111 RELAY_TOML=<wt>/demo/relay/localhost.toml MOQ=<bin>/moq RELAY=<bin>/moq-relay MOQLAT=1s CAP=150 \
  PACER=lab/scripts/ts-rtp-forward.py bash lab/scripts/t18-arm.sh <broadcast>.ts <out> 540 moq 0
python3 lab/scripts/ts-decode-latency.py <broadcast>.ts <out>/moq-c0-source.csv <out>/moq-c0-egress.ts \
  <out>/moq-c0-egress.csv --pid 111 --settle 10 --rate-window 30     # "PCR clock vs tap" lines
python3 lab/scripts/ts-tstd.py <out>/moq-c0-egress.ts --skip 5 --window 2   # "units" per buffer: run on the source too, compare per PID
# The loss rig and cross-host as pushed: no MOQ_TS_* variable; TAP=1 stamps the egress for the clock fit
sudo LOSS_PCT=0 CC=delay LAT=1s KEEP_EGRESS=1 OUT=<out> bash lab/scripts/t8b-loss-point.sh l0 <bin> 120
bash lab/scripts/t47-xhost.sh origin c1 <bin> <EC2_IP> 120                 # on the origin host
TAP=1 LAT=500ms bash lab/scripts/t47-xhost.sh sub c1 <bin> <EC2_IP> 120     # on the subscriber host

# 559a35244: the same cells; PUBLISH_DELAY starts the source later to shift the join
PUBLISH_DELAY=0.3 VPID=111 RELAY_TOML=<wt>/demo/relay/localhost.toml MOQ=<bin>/moq RELAY=<bin>/moq-relay \
  MOQLAT=500ms CAP=150 PACER=lab/scripts/ts-rtp-forward.py bash lab/scripts/t18-arm.sh <broadcast>.ts <out> 60 moq 0
rg "missed its deadline" <out>/moq-c0-receive.log | rg -o "track=[^ ]+" | sort | uniq -c   # drops per track
# compliance.py from the head's tree; run.sh resolves a relative path against test/ts, so pass an absolute one
(cd <wt>/test/ts && ./run.sh --analyze-only "$(cd <out> && pwd)/egress-skip5.ts")
# The scratch build: the tests branch on the t0ms fork, its last commit the fix (see upstream-contributions)
git -C <moq-dev> fetch https://github.com/t0ms/moq-dev tests/4645-on-559a352
cd <wt> && cargo test -p moq-mux --lib -- a_track_sent_later_than_the_delay_loses_nothing   # fails on the head

# Upstream harness, as the maintainer would run it
cd <wt>/test/ts && TSC_PROFILE=release ./run.sh --source <broadcast>.ts --duration 60

# The generated reproducer (passes compliance.py as a source)
ffmpeg -f lavfi -i "testsrc2=size=1920x1080:rate=25,noise=alls=12:allf=t" -t 65 -an \
  -c:v libx264 -profile:v high -level 4.0 -preset veryfast -pix_fmt yuv420p \
  -x264-params "keyint=25:min-keyint=25:scenecut=0:nal-hrd=cbr" -b:v 9M -maxrate 9M -bufsize 9M \
  -f mpegts -muxrate 10000000 -pcr_period 20 -pes_payload_size 0 <fixture>.ts
./run.sh --analyze-only <fixture>.ts && TSC_PROFILE=release ./run.sh --source <fixture>.ts --duration 60

# A cell through the T18 rig, the export forwarded without re-clocking
VPID=256 RELAY_TOML=<wt>/demo/relay/localhost.toml MOQ=<bin>/moq RELAY=<bin>/moq-relay MOQLAT=2s CAP=150 \
  PACER=lab/scripts/ts-rtp-forward.py bash lab/scripts/t18-arm.sh <fixture>.ts <out> 60 moq 0
python3 lab/scripts/ts-tstd.py <out>/moq-c0-egress.ts --skip 5 --window 2
tsp -I file <out>/moq-c0-egress.ts -P pcrverify --absolute --jitter-max 13 --bitrate <catalog-rate> -O drop

# The per-PID scratch schedule (environment-driven; the patch is not published), full clip at 1 s
MOQ_TS_EB=111=1115696,121=3584,123=4928 MOQ_TS_RX=111=10557082,121=2000000,123=2000000,131=6750000 \
  MOQ_TS_FRAMES=123=9 VPID=111 RELAY_TOML=<wt>/demo/relay/localhost.toml MOQ=<bin>/moq \
  RELAY=<bin>/moq-relay MOQLAT=1s CAP=150 PACER=lab/scripts/ts-rtp-forward.py \
  bash lab/scripts/t18-arm.sh <broadcast>.ts <out> 60 moq 0
python3 <wt>/test/ts/compliance.py --ts <out>/egress-from-5s.ts

# The same build under the T8b loss rig, lateness logged rather than fatal, egress kept for grading
export MOQ_TS_LATE=send MOQ_TS_EB=111=1115696,121=3584,123=4928 \
  MOQ_TS_RX=111=10557082,121=2000000,123=2000000,131=6750000 MOQ_TS_FRAMES=123=9
sudo --preserve-env=MOQ_TS_LATE,MOQ_TS_EB,MOQ_TS_RX,MOQ_TS_FRAMES LOSS_PCT=1 CC=delay LAT=1s \
  KEEP_EGRESS=1 OUT=<out> bash lab/scripts/t8b-loss-point.sh l1 <bin> 120
python3 lab/scripts/ts-tstd.py <out>/l1/egress.ts --skip 5 --window 2

# Across hosts: the origin first, then the export on the other host (same MOQ_TS_* exported there).
# The slack and lead lines are two debug events the scratch patch adds; the consumer's is upstream's.
# MOQ_JITTER_REJOIN=1 MOQ_JITTER_FOLLOW=1 on the sub turns on the scratch one-clock release stage.
# A new origin refuses to start while an earlier one still holds the port.
bash lab/scripts/t47-xhost.sh origin x1 <bin> <EC2_IP> 120                 # on the origin host
RUST_LOG=info,moq_mux::jitter=debug,moq_mux::container::ts::schedule=debug,moq_mux::container::consumer=debug \
  bash lab/scripts/t47-xhost.sh sub x1 <bin> <EC2_IP> 120                  # on the subscriber host

# The schedule replay: the export's rule and a buffer-limited one, on source and authored DTS.
# --reserve is the "raising the video DTS reserve ... to=" value the export logs; --eb is the
# video's cpb + BSmux + BSoh, the budget the scratch patches use (smaller than MB + EB).
python3 lab/scripts/ts-schedule-replay.py <source-video-only>.ts --rate <catalog-rate> \
  --window 0.5,1,2,3,5,8 --reserve 36000 --period 3600 --eb 1115696 --check <out>/moq-c0-egress.ts
```

A clip cut for the harness must be cut by packets (`tsp -P until --packets N`): `--seconds` is wall
time and passes the whole file. A different export rate goes in through a wrapper that appends
`--mux-rate` to `export ts`, since the rig passes only the delay.

## Corrections

- **Believed:** the release stage starved the schedule. In the short captures the PTS covered
  13–29 % less than the PCR, and the PTS-to-PCR lead shrank before the overrun. That was reported
  upstream as "starved of frames rather than overfull". **True:** the schedule is overfull. The
  PTS shortfall is the join hole plus the window still queued at the exit, and the lead changes
  with the authored DTS's offset between frame- and field-coded passages. **Rule:** a capture
  that ends in a failure covers less PTS than PCR by construction, so a span ratio from it is not
  a rate. Compare the decode timeline against the source unit by unit
  ([method notes](method-notes.md)).
- **Believed:** AC-3's transport buffer overflowed because the export writes each frame's packets
  back to back. This was read from the code and reported upstream. **True:** the slot layout
  spreads each PID's packets evenly through the slot. The overflow is the count per slot: the
  floor carries a backlog of audio out in bulk, up to 38 AC-3 packets in one slot, more than a
  2 Mb/s drain clears in 25 ms. Separately, AC-3's passed-through PES is larger than its decoder
  buffer. **Rule:** before attributing a transport-buffer overflow to packet adjacency, count the
  PID's packets per scheduling interval on the captured bytes, and compare its PES size with its
  decoder buffer.
- **Believed:** on `49efbc9a1` the output's clock ran 290–370 ppm off, from the change in
  presentation latency between the first and last thirds of each run. This was reported upstream.
  **True:** a fit of the PCR clock against the receiving tap reads −503.7, +520.9 and +515.1 ppm,
  about 500 ppm off the source in each run, as in mocked time. Comparing the thirds' medians
  dilutes a steady rate over the span between them. **Rule:** grade a clock's rate by fitting the
  PCR against the receiver's clock, not from a latency trend.

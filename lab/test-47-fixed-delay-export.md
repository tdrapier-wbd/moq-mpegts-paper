# Test 47 — The upstream fixed-delay TS export on a broadcast clip

**State: first pass (P0-m), on loopback and then under loss and across hosts, on the head of
[#4645](https://github.com/moq-dev/moq/pull/4645) (`4b7158d6c00d`, unmerged). The cause of the
broadcast-clip failure is located by an offline replay, which predicted two further runs of the
real export correctly. A scratch patch that schedules each PID's packets earliest deadline first,
admitted against that PID's own transport and decoder buffers, carries the full multiplex at 1 s
and at 750 ms with every buffer conformant; PCR accuracy still fails, from the unchanged stamping.
At 500 ms it stops, as the replay predicts for the DTS the export authors. At 1 s under the
loss rig the patch carries 1 % loss conformant except at one grid restart, and the lane collapses
at 10 %. Across hosts the result is decided at the join. When the video track skips a group on
joining, #4645's release stage gives it a clock of its own, up to a whole delay behind the other
tracks'. The output then fails the buffer model for whichever side runs late, and in the one run
on the PR head's schedule the export stopped.**

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
  96 %. The export sends each unit as late as the rate allows, and it knows units only one window
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
  the whole capture with the video passing every buffer (EB peak 99.7 %, minimum margin 510 ms,
  26 of 26 windows) and AC-3 still failing.
- **The export's audio fails the T-STD for two reasons, and neither is the video's.** Unpatched at
  8 s, MP2's B peaks at 10,904 of 3,584 B and AC-3's at 16,896 of 5,696 B, and AC-3's transport
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
  that delay, while it nearly meets the source's.
- **Under 1 % loss at 1 s the per-PID build stays conformant except where the export restarts its
  grid.** Under the [T8b](test-8b-congestion-control.md) netem rig (25 ms each way, BBRv3), 0 %
  passes every buffer in all 56 windows. At 1 % the export lost 0.12 s of video and one 0.288 s
  AC-3 hole, and restarted its grid once, with a flagged PCR discontinuity. Every window either
  side of the restart passes, apart from 2 table packets over the system transport buffer. At 10 %
  the lane delivers almost nothing but nulls, so its buffer grade is moot.
- **Across hosts, a join where the video skips a group puts the video on its own clock.** The
  consumer counts the skipped group as a discontinuity. #4645's jitter buffer then opens a new
  generation for the video alone, anchored no earlier than the deadlines it has already given the
  other tracks. Over five traced joins, the video's clock ran from 200 ms to 979 ms behind theirs,
  fixed for the whole run. At 200 ms the output passed every buffer in all 56 windows. Near a
  whole delay, the video reached the schedule one slot ahead of its deadline instead of 32.
  Between 1,800 and 2,300 units each of video and MP2 then underflowed, and in the one run with
  the PR head's own schedule the export stopped on its fatal overrun within seconds.
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
re-clocking. T-STD graded on the stream's own PCR. One run per cell. The loss and cross-host arms
are graded on the export's output file, T-STD only. Hardware: not run.

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

## Pass criteria

Fixed before the runs, the same as T45's for the T-STD:

1. **Both T-STD checks pass the output** after a 5 s skip: upstream `compliance.py`
   (`run.sh --analyze-only`) and [`ts-tstd.py`](scripts/ts-tstd.py), every 2 s window legal.
2. **TR 101 290 P1/P2 on the same bytes**: 0 continuity errors, 0 PCR intervals over 40 ms, 0 PCRs
   outside ±500 ns against the rate the stream was padded to.
3. **The export runs the whole capture.**

A cell that fails criterion 3 has its latency and buffers quoted only for the part it delivered.

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

- Export, import and relay: #4645 head `4b7158d6c00d`, release build, relay on its own tree's
  config. The two scratch schedules are patches to that head's `schedule.rs` only.
- Comparator control: upstream harness on its default generated clip with the same build, which
  passes every check including strict T-STD.
- One host, loopback. All stages at `nice 10`.
- Loss arms: one host, the T8b network-namespace rig, 25 ms each way, BBRv3 on noq, uniform netem
  loss on the media direction, 120 s. Cross-host: relay and importer on one host, with the clip paced by
  `tsp -P regulate`, and the export on a second host in the same region, 120 s. Both on the
  per-PID build, with lateness logged rather than fatal (`MOQ_TS_LATE=send`) so that a run is
  graded whole.

## Results

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
`ts-tstd.py` on the source gives a residence maximum of 0.97 s and EB peak 1,066,777 of 1,115,696 B
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
underflow, EB peak 531,962 of 1,115,696 B and a minimum EB margin of 1.3 ms. On the source's DTS the
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

Parameters are the ones `ts-tstd.py` calibrates for the clip:

| PID | Transport buffer drain | Decoder buffer given | Access units per unit |
|---|---|---|---|
| video | 10,557,082 b/s | 1,115,696 B | 1 |
| MP2 | 2 Mb/s | 3,584 B | 1 (the export repacketizes MP2 one frame per PES) |
| AC-3 | 2 Mb/s | 4,928 B: the 5,696 B buffer less one frame | 9 (the source's PES, passed through) |
| teletext | 6.75 Mb/s | none | 1 |
| others | 1 Mb/s | none | 1 |

AC-3 is given one frame less than its buffer because the patch places frame deadlines in whole
slots, and a 32 ms frame does not divide a 25 ms slot. Given the full 5,696 B on a 20 s run, B
peaked at 6,088 B. Graded with `ts-tstd.py` skipping 5 s, and `compliance.py` on the same file cut
5 s in:

| Build, clip, `--delay` | Runs | Video EB | MP2 B | AC-3 TB / B | P1 on the same bytes |
|---|---|---|---|---|---|
| #4645, video only, 8 s | yes, 43 s | pass, peak 48 %, margin min 1.3 ms | — | — | 0 CC errors |
| #4645, full, 8 s | yes, 42.8 s of DTS | pass, peak 47 % | **peak 10,904 of 3,584 B**, 4 of 19 windows | **2,495 pkts over** / **16,896 of 5,696 B**, 0 of 19 | 0 CC errors, PCR ≤ 25 ms |
| EB-limited, video only, 1 s | yes, 57.4 s of DTS | pass, peak 99.7 %, margin min 510 ms, 26 of 26 | — | — | one 975 ms PCR gap at the join |
| EB-limited, full, 1 s | yes, 57.3 s of DTS | pass, peak 99.7 %, margin min 512 ms, 26 of 26 | pass, 26 of 26 | **4,196 pkts over** / **6,912 of 5,696 B**, 0 of 26 | 0 CC errors, PCR ≤ 25 ms |
| Per-PID, full, 1 s | yes, 56.6 s of PCR | pass, peak 986,564 B (88 %), margin min 413 ms, 25 of 25 | pass, peak 2,840 B, margin min 64 ms, 25 of 25 | 0 over / peak 5,352 B, 25 of 25 | 0 CC errors, PCR ≤ 25 ms, `compliance.py` PASS |
| Per-PID, full, 750 ms | yes, 57.9 s of PCR | pass, peak 901,333 B (81 %), margin min 339 ms, 26 of 26 | pass, peak 2,840 B, margin min 68 ms, 26 of 26 | 0 over / peak 5,352 B, 26 of 26 | 0 CC errors, PCR ≤ 25 ms, `compliance.py` PASS |
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

### Under loss, and across hosts (per-PID build, 1 s)

Graded with `ts-tstd.py` skipping 5 s, 2 s windows, on the export's output file. "Lost" is decode
time the source carries and the output does not.

| Arm | Runs the window | Buffers (windows legal) | What the export did |
|---|---|---|---|
| Loss rig, 0 % | yes | every buffer, 56 of 56; EB margin min 274.8 ms | lost nothing |
| Loss rig, 1 % | yes | 54 of 55; MP2 B 11 overflowing arrivals (peak 5,144 B), AC-3 B 20 (peak 9,376 B), system TB 2 packets | lost 0.12 s of video and one 0.288 s AC-3 hole; 3 groups evicted; one grid restart at 73.9 s, the PCR stepping back 1.35 s with `discontinuity_indicator` set |
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
| A, traced | 200 ms | 32 slots | every buffer passes, 56 of 56; EB margin min 413 ms, MP2 64 ms, AC-3 138 ms |
| B, traced | 979 ms | 1 slot | video 2,257 of 4,098 units underflow, MP2 2,273 of 4,691, AC-3 761 of 2,271; 1 of 56 windows legal |
| C, traced | 960 ms | 1 slot | video 1,803 of 4,071 units underflow, MP2 2,061 of 4,697, AC-3 942 of 3,526; 4 of 56 windows legal |
| C, repeated untraced | — | — | the same counts and margins to the unit |
| D, untraced | — | — | video passes, EB peak 99.7 %, margin min 507 ms; every MP2 unit underflows (margin −188 ms), AC-3 2,403 of 3,591; 0 of 57 windows legal |
| PR head behaviour, traced | 959 ms | not logged | the export stops within seconds: "needs 1,855 packets in a 25 ms slot" |

"Lead" is the minimum number of slots before its deadline a video unit reached the schedule, from
runs that logged the schedule. Every other PID reached it at least 40 slots ahead, a whole delay, in
each of them. In run D the video ran *ahead* of the audio: audio units underflow by a nearly
constant amount while the video sends early, the converse of B and C. It was not traced, so its
offset is not measured. The last row ran the same build with no
`MOQ_TS_*` variable set, which leaves the PR head's schedule unchanged. It shows the skew is the
release stage's, not the scratch patch's. A sixth traced run is void, a rig fault: its origin
started while the previous run's relay still held the port. Its first 8 s show the same skip and a
960 ms offset.

Timestamps are not affected. Matched by payload against the source in the 0 % loss arm and in run
D, a passing and a failing run, the video and MP2 PES carry the source's PTS: median shift 0 over
about 4,100 video and 540 MP2 matches in each. The skew is in when the bytes are sent, not in what
they say.

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

1. **#4645 does not yet carry a real broadcast multiplex.** At every delay tried up to 3 s, and in
   each variation tried at one delay (a higher rate, subscribing first, the video alone), the export
   stops within seconds. The maintainer's harness reproduces it at the defaults, so the report does
   not depend on this rig. At 8 s it runs, on the video alone and on the full clip.
2. **The cause is the send policy, with the authored DTS compounding it.** Sending as late as
   possible with one window of lookahead cannot absorb a stretch that outruns the rate for about
   a window. A broadcast encoder spends its CPB on exactly such stretches. The replay locates
   this and predicted both further runs. Sending the video earliest deadline first within its EB
   removes the overrun in a built export, at 1 s on the full clip.
3. **A schedule inside the export can carry the full broadcast multiplex with every buffer
   conformant, at 1 s and 750 ms, in a scratch build.** PCR accuracy still fails, for the reason
   in conclusion 6. It needs three things #4645 lacks: each PID's packets admitted
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
8. **#4645's release stage can put one track on a clock up to a whole delay behind the others'.**
   A discontinuity crossed by one track alone, here a video group skipped at the join, opens a
   generation only that track uses. Every traced cross-host join did this, and four of five put
   the video between 959 and 979 ms behind. From then on no schedule downstream can hold the
   decoder buffers for both sides, because it receives one side's units almost at their
   deadlines. In the one PR-head run the export stopped on it; the per-PID build runs and fails
   the buffer model. The defect is in the release stage, not in either schedule. Whether it also
   happens co-resident is untested: the loopback and loss-rig runs were not traced, and they
   passed.
9. **Under loss, the per-PID build's only failure at 1 % is its own model at a grid restart.** A
   shipped schedule has to carry the receiver's buffer occupancy across a restart, since a PCR
   discontinuity does not empty a decoder. At 10 % the lane delivers almost nothing; that is the
   transport, not the schedule.

## Limits

- One host, loopback, one run per cell, one broadcast channel (two captures of the same channel are
  on hand, not two channels). The loss rig and cross-host ran on the per-PID build at 1 s only.
  The loss arms ran once each, untraced. Cross-host is one pair of hosts in one region, seven runs,
  of which five were traced.
- How often a join skews the clocks, and by how much, is a property of the join; five traced joins
  do not give a distribution. The arm that would settle it is a run of joins at varied offsets into
  the source's group, traced.
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
# A new origin refuses to start while an earlier one still holds the port.
bash lab/scripts/t47-xhost.sh origin x1 <bin> <EC2_IP> 120                 # on the origin host
RUST_LOG=info,moq_mux::jitter=debug,moq_mux::container::ts::schedule=debug,moq_mux::container::consumer=debug \
  bash lab/scripts/t47-xhost.sh sub x1 <bin> <EC2_IP> 120                  # on the subscriber host

# The schedule replay: the export's rule and a buffer-limited one, on source and authored DTS.
# --reserve is the "raising the video DTS reserve ... to=" value the export logs; --eb is the
# decoder size ts-tstd.py calibrates for the video PID.
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

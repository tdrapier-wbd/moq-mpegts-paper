# Test 47 — The upstream fixed-delay TS export on a broadcast clip

**State: first pass (P0-m), loopback, on the head of
[#4645](https://github.com/moq-dev/moq/pull/4645) (`4b7158d6c00d`, unmerged). The cause of the
broadcast-clip failure is located by an offline replay, which predicted two further runs of the
real export correctly. A scratch patch that sends the video earliest deadline first, limited by its
decoder buffer, carries the full clip at 1 s with the video conformant. In both that build and
the unpatched export run at 8 s, the audio buffers fail. The loss rig and cross-host runs are
open.**

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
- **Sending the video earliest deadline first, as soon as its decoder buffer has room, carries
  the full clip at 1 s.** The patch is a scratch build of the PR head, with the EB size given by
  environment variable. At `--delay 1s` it runs the whole capture with no overrun and no late
  drop. The video passes every buffer: EB peak 99.7 %, minimum margin 510 ms, 26 of 26 windows.
- **Where the export runs the full clip, its audio fails the T-STD, patched or not.** Unpatched at
  8 s, MP2's B peaks at 10,904 of 3,584 B and AC-3's at 16,896 of 5,696 B, and AC-3's transport
  buffer overflows on 2,495 packets. Patched at 1 s, MP2 passes, and AC-3 still overflows TB
  (4,196 packets) and B (6,912 of 5,696 B). Read from the code, and consistent with audio
  residences of up to 0.68 s: the schedule writes a frame's packets back to back, and fills each
  slot's minimum in push order, which carries audio out early ahead of heavy video.
- **The export's authored DTS makes this worse.** Its decode clock holds back a fixed *number* of
  pictures (10), not a fixed time. Each time CNN switches between frame and field coding, the
  authored DTS moves 0.2 s against the source's, and the leading pictures of the first GOP all
  get DTS one tick apart.
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
re-clocking. T-STD graded on the stream's own PCR. One run per cell. Hardware: not run.

## Objective

Upstream took up T-STD conformance of `moq export ts` as a questline after
[T44](test-44-tstd-grading.md) and [T45](test-45-live-tstd-remux.md). Its first implementation,
#4645, replaces the stall-and-hold interleave with a fixed-delay release stage and lays packets on
a PCR grid at the mux rate. Its CI passes on a generated 720p clip. This test asks the P0-m
questions of it on a real broadcast multiplex:

1. **Does the export run, and pass the T-STD, on a broadcast clip at its default delay?**
2. **If not, at what delay, and what is the failure?**
3. **What do P1/P2 say of the same bytes, and what is the latency against `--delay`?**
4. Under the [T8b](test-8b-congestion-control.md) loss rig, and cross-host. *Not run.*

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
  config.
- Comparator control: upstream harness on its default generated clip with the same build, which
  passes every check including strict T-STD.
- One host, loopback. All stages at `nice 10`.

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

A scratch patch to the PR head's `schedule.rs`, 77 lines. It keeps the export's floor, the
fewest packets that keep every unit on time. It then fills the rest of each slot's allowance
from queued units of the PIDs given an EB size (`MOQ_TS_EB=pid=bytes`), in order per PID, while
that PID's buffer has room. Occupancy counts 184 bytes per packet sent, and a unit's bytes leave
the buffer once the slot after its due slot is past. Audio and tables stay on the floor. The video
EB is the 1,115,696 B that `ts-tstd.py` calibrates from the clip's SPS. Graded with
`ts-tstd.py`, skipping 5 s.

| Build, clip, `--delay` | Runs | Video EB | MP2 B | AC-3 TB / B | P1 on the same bytes |
|---|---|---|---|---|---|
| #4645, video only, 8 s | yes, 43 s | pass, peak 48 %, margin min 1.3 ms | — | — | 0 CC errors |
| #4645, full, 8 s | yes, 42.8 s of DTS | pass, peak 47 % | **peak 10,904 of 3,584 B**, 4 of 19 windows | **2,495 pkts over** / **16,896 of 5,696 B**, 0 of 19 | 0 CC errors, PCR ≤ 25 ms |
| Patched, video only, 1 s | yes, 57.4 s of DTS | pass, peak 99.7 %, margin min 510 ms, 26 of 26 | — | — | one 975 ms PCR gap at the join |
| Patched, full, 1 s | yes, 57.3 s of DTS | pass, peak 99.7 %, margin min 512 ms, 26 of 26 | pass, 26 of 26 | **4,196 pkts over** / **6,912 of 5,696 B**, 0 of 26 | 0 CC errors, PCR ≤ 25 ms |

PCR accuracy was not re-graded on these runs; the stamping is unchanged. The 975 ms gap is the
join's first-group hole, which the export lays as skipped slots, inside the graded skip. A slot's
bytes are timed up to its end boundary, so a unit due in slot k decodes during slot k + 1; an
occupancy count that frees it any earlier overfills EB by up to a slot.

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
   fixes it in a built export, at 1 s on the full clip.
3. **The export's audio does not conform on the broadcast clip in either cell where it runs it**
   (unpatched at 8 s, patched at 1 s). This is independent of the video fix, which improves MP2 to a pass and leaves AC-3 failing. A
   conformant schedule needs each PID's packets admitted against its own TB and B, not just a
   rate floor. That is what [T45](test-45-live-tstd-remux.md)'s re-multiplexer does, per packet,
   and it passed every buffer of this clip live, on the lane output of `ffa5b81b`.
4. **Its default is short for a broadcast CPB, independent of that failure.** A generated stream
   with 0.7 s of send-ahead, which passes the T-STD as a source, cannot start at 500 ms and
   conforms at 2 s.
5. **On the generated clip, its output passes both T-STD checks and fails PCR accuracy almost throughout.** The
   buffer model and P2 disagree on the same bytes, which is
   [T44](test-44-tstd-grading.md)'s point in the other direction: a T-STD pass is not a TR 101 290
   pass either.
6. **The latency at 2 s is about twice what the design accounts for.** This is on loopback. The
   ~2 s unexplained has the same order as the transit T45 left unlocated on `ffa5b81b`, and may be
   the same thing. Nothing here says so yet.

## Limits

- One host, loopback, one run per cell, one broadcast channel (two captures of the same channel are
  on hand, not two channels). Cross-host and the loss rig not run.
- The replay models the video PID alone. The patch is a scratch build: it takes the EB size from
  an environment variable rather than the SPS, buffers only the video, and was run once per cell
  at 1 s. It was not run at the 500 ms default, under loss or cross-host, and `compliance.py` was
  not run on its output. The arm that settles the audio is a per-PID, per-packet admission
  against TB and B in the export, graded on the full clip.
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

# Test 47 — The upstream fixed-delay TS export on a broadcast clip

**State: first pass (P0-m), loopback, on the head of
[#4645](https://github.com/moq-dev/moq/pull/4645) (`4b7158d6c00d`, unmerged). The loss rig,
cross-host runs and the cause of the broadcast-clip failure are open.**

- **On a real broadcast capture the export stops within seconds, at every delay tried.** On
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
  the output, every 2 s window included. So the default is too short for a CPB this size, and
  something further in the broadcast clip, not yet identified, defeats every delay.
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

In the runs that lasted long enough to measure, the export's media fell behind its own clock. The
PCR advanced at the wall clock's rate in clean 25 ms steps, while the PTS carried advanced more
slowly: 8.44 s of PTS against 9.75 s of PCR at 11 Mb/s, and 7.70 s against 10.85 s at 3 s. The
lead of PTS over PCR shrank from 0.44–0.57 s towards 0.27–0.30 s before the overrun. So the release
stage handed the schedule less than real time's worth of frames, although the source tap shows the
import fed at real time (60.24 s of PTS in 59.93 s). Where the frames were held is not located: the
import and relay logs show nothing beyond quiet SCTE-35 PIDs.

The broadcast clip differs from the passing generated one in being interlaced (`field_order=tt`),
in carrying B-frames with a reorder depth of 3 on a broadcast encoder's GOP, and in the size of
its I-frames. None of these has been isolated as the cause.

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
   not depend on this rig.
2. **Its default is short for a broadcast CPB, independent of that failure.** A generated stream
   with 0.7 s of send-ahead, which passes the T-STD as a source, cannot start at 500 ms and
   conforms at 2 s.
3. **Where it runs, its output passes both T-STD checks and fails PCR accuracy almost throughout.** The
   buffer model and P2 disagree on the same bytes, which is
   [T44](test-44-tstd-grading.md)'s point in the other direction: a T-STD pass is not a TR 101 290
   pass either.
4. **The latency at 2 s is about twice what the design accounts for.** This is on loopback. The
   ~2 s unexplained has the same order as the transit T45 left unlocated on `ffa5b81b`, and may be
   the same thing. Nothing here says so yet.

## Limits

- One host, loopback, one run per cell, one broadcast channel (two captures of the same channel are
  on hand, not two channels). Cross-host and the loss rig not run.
- The broadcast-clip failure is characterised, not diagnosed. The arm that would locate it is the
  export with its release stage's frame arrivals and releases traced against the wall clock, which
  needs instrumentation in the PR's code or the maintainer's.
- The generated clip matches the broadcast one on CPB size and send-ahead only. A generated
  interlaced (PAFF or MBAFF) twin with B-frames is the arm that would test the leading
  candidate.
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
```

A clip cut for the harness must be cut by packets (`tsp -P until --packets N`): `--seconds` is wall
time and passes the whole file. A different export rate goes in through a wrapper that appends
`--mux-rate` to `export ts`, since the rig passes only the delay.

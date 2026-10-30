# Test 70 — The segmented chain's latency against the 5–10 s budget, over the internet path

**State: run; every criterion holds.** At each configuration's floor the chain delivers in
2.6–4.5 s, and every clean cell passes P1/P2 and the buffer model. Rig: [`t70-wan-cell.sh`](scripts/t70-wan-cell.sh) on the receiver,
[`t70-wan-origin.sh`](scripts/t70-wan-origin.sh) on the origin, driven by
[`t70-drive.py`](scripts/t70-drive.py).

## Objective

P1-ah. The segmented lane's only conformant latency is [T18](test-18-delivery-latency.md)'s
9,324 ms. That is the first chain (`tsp -O hls`, `tsp -I hls`, a groomer) at an 8 s cushion over a
12.8 ms internet path, P1/P2-graded with 2 PCR intervals over 40 ms and never graded at the 13818-1
buffer model. [T68](test-68-segmented-chain-cushion-faults.md) found the current chain's cushion
floor on loopback at 2 s epochs: 3 s with the receiver's hold and the groomer's alignment, 1.5 s
with neither. Over the internet path, at each configuration's smallest clean cushion, this test
asks what the current chain's delivery latency is, and whether the same bytes pass P1/P2 and the
buffer model.

Four configurations: 2 s and 1 s epochs, each in the design variant (hold 1.5 s, alignment 30 s, as
T62, T63 and T68) and the default one (neither, as the standing receiver units start).

## Environment

| | |
|---|---|
| Origin | the EC2 secondary (eu-west-1), beside its standing units, which it does not touch: `contrib-10m.ts` from its start each cell, `tsp -P regulate` to its own multicast group on loopback, with the video PTS tapped by a mirrored fork; `t61-epochseg.py --duration D --window 6 --extra 3 --pdt` (target duration 4 s at D = 2, 2 s at D = 1); nginx 1.28, its own instance, playlist `max-age=1` |
| Path | the open internet to a laptop behind the office exit; round trip measured by the clock probe |
| Receiver | `b8-hls-recv.py`, 250 ms poll, one persistent connection, its defaults otherwise; `--release-ms 1500` in the design variant |
| Groomer | `mpegts-pacer` `97f3a38`, `--stream-clock` at 11.438 Mb/s, `--stall-ms 1000 --on-stall mute`, cap 14 s; `--align-ms 30000` in the design variant; raw TS to stdout, tapped inline by `t18-latency.py` and saved |
| Clock | `t18-latency.py clock-server` on the origin, probed 30 times before and after each cell, as T18: the mean offset corrects the latency and the drift bounds it |
| Graders | `t18-latency.py report` (8 s settle); TSDuck `continuity`, `pcrverify --absolute --jitter-max 13` and PCR repetition from `pcrextract`, as T18; [`ts-tstd.py`](scripts/ts-tstd.py) from 8 s, as T44 |

On this clip's random-access points, mostly every 1.2 s, 2 s epochs cut mostly 2.4 s and 1.2 s
segments, longest 3.04 s in these runs. 1 s epochs cut 1.2 s segments except nine of about 124, at
0.6–1.84 s, and one epoch in five carries none.

## Procedure

A cell is 120 s from the groomer's first output. A 40 s smoke cell checks the rig first, ungraded. Per configuration, the search starts at the
predicted floor, with one cell per 0.5 s step: down from a clean cell, to a 0.5 s minimum, or up
from a failing one. The floor is the smallest clean cushion with the step below failing. Two more
cells run there, so it has three; if one fails, the search steps up 0.5 s and runs three there.

## Pass criteria, fixed before running

1. **Clock.** A cell's latency is quoted only if its probes drift ≤ 10 ms across the cell and their
   uncertainty is ≤ 10 ms; otherwise it is reported and re-run.
2. **Clean.** From its first output to the stop, the groomer counts no cap or late drop, underrun,
   stall, muted or withheld packet, or cut run, and the receiver gives no segment up. One chain has
   no twin to compare against, so this is weaker than the byte-identity that set T68's floors.
3. **Floor**, per configuration: the smallest cushion, in 0.5 s steps, clean in three runs of three,
   with the step below failing.
4. **Conformance**, every cell: P1/P2 holds with 0 continuity errors, 0 PCRs outside ±481 ns and
   0 PCR intervals over 40 ms; the buffer model holds when `ts-tstd.py` exits 0 from 8 s. The
   source clip is graded by `ts-tstd.py` once, as the control: if it fails, the buffer-model column
   says nothing about the chain.
5. **Verdict:** each configuration's median latency at its floor, with its conformance, against the
   5–10 s budget and beside T18's 9,324 ms and the MoQ lane's conformant 2,447 ms.

*Predicted.* Latency is the hold plus the cushion in the design variant. In the default variant it
is the cushion plus the first segment's span plus its fetch. At 2 s epochs: design about 4.5 s
(3 s floor), default about 4 s (1.5 s floor). At 1 s epochs: design about 3 s (1.5 s floor),
default about 2 s (0.5 s floor). Fetch jitter on the path may add a step to a floor. The
stream-clocked groomer places every packet on the source's PCR grid, so P1/P2 and the buffer model
should hold wherever the cell is clean, as the source's own timing does.

## Results

Seventeen graded cells after the smoke cell. The source control passes the buffer model: no
transport-buffer overflow and no decoder-buffer underflow on any PID. The probe read a 12.2–12.6 ms
round trip and the origin 9.0–26.4 ms ahead, with drift ≤ 1.6 ms within a cell and uncertainty
5.9–6.9 ms. One cell drifted 14.9 ms and was re-run. The receiver's fetches took 183–270 ms at the
median and 345–586 ms at the 99th percentile, with no retry, give-up or failed playlist read.

| Configuration | Floor | The step below | Latency at the floor, three cells (median) |
|---|---|---|---|
| 2 s epochs, design | **3 s** | 2.5 s: 6 stalls, 10,584 late drops | 4,473.6, 4,475.0, 4,476.6 ms (**4,475**) |
| 2 s epochs, default | **1.5 s** | 1 s: 24 stalls, 36,888 late drops | 3,916.2, 3,962.3, 4,100.7 ms (**3,962**) |
| 1 s epochs, design | **2 s** | 1.5 s: 5 stalls, 7,513 late drops | 3,464.8, 3,464.9, 3,465.3 ms (**3,465**) |
| 1 s epochs, default | **1 s** | 0.5 s: 10 stalls, 15,315 late drops | 2,561.4, 2,603.7, 2,605.4 ms (**2,604**) |

Every cell at a floor shows 0 continuity errors, 0 PCRs outside ±481 ns and 0 of about 4,925 PCR
intervals over 40 ms (largest 25.0 ms), and passes the buffer model. Every cell below a floor fails
both: 29–162 continuity errors, 5–25 PCR intervals over 40 ms (largest 421–824 ms), and the buffer
model. Within a clean cell the 95th percentile sits 49–52 ms above the median, the spread is
146–323 ms, and the trend is under 3 ms.

## Grading

1. **Clock:** holds on 16 of 17 cells; the 17th was re-run.
2. and 3. **Floors:** 3 s, 1.5 s, 2 s and 1 s, each clean in three runs of three with the step
   below failing.
4. **Conformance:** every clean cell passes P1/P2 and the buffer model. The control passes.
5. **Verdict:** all four configurations deliver below the budget's 5 s lower end. Against T18's
   9,324 ms they are 2.1–3.6 times faster. At 1 s epochs without the hold, the chain is 157 ms (6 %)
   slower than the MoQ lane's P1/P2-conformant 2,447 ms, and these bytes pass the buffer model too,
   which that MoQ configuration fails ([T19](test-19-pcr-grid-verification.md)).

The prediction holds at 2 s epochs: both floors equal T68's loopback floors, so the path's fetch
time adds no step, and the latencies are as predicted. At 1 s epochs it fails by one step in both
variants. It assumed every segment would be 1.2 s, but the clip's irregular random-access points cut
a few as long as 1.84 s. T68's rule then gives the measured floors: aligned, the cushion covers the
longest span; unaligned, the longest span less the anchor segment's.

## Conclusions

1. **Over a 12 ms internet path the current segmented chain delivers this clip in 2.6–4.5 s at its
   floors, P1/P2- and buffer-model-conformant on every clean cell.** That is 4,475 ms at 2 s epochs
   with the hold and alignment, 3,962 ms without them, 3,465 ms at 1 s epochs with them and
   2,604 ms without.
2. **The floors are the clip's segment spans, not the path.** At 2 s epochs they match loopback.
   1 s epochs lower them by the difference in longest span.
3. **T18's 8 s cushion belonged to the first chain, not to segmented delivery.** The design's hold
   and alignment cost 0.5–0.9 s over the default variant at equal epochs.

## Limits

One clip, whose random-access points fall mostly every 1.2 s; a source on a 2 s GOP would cut
longer segments and need deeper floors. One unimpaired path; path faults are T68 part A's.
Three 120 s cells per floor, in 0.5 s steps. Every cell starts from the clip's start, so the
default variant anchors on one segment, as in T68. "Clean" is one chain's counters, not two
chains' identity.

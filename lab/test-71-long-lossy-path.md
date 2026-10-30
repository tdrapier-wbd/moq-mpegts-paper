# Test 71 — The latency ordering on a long, lossy path

**State: run, 27 cells and four diagnostics; every cell holds criteria 1–4, and the clean ordering
survives 0.1 % loss but not 1 %, where each MoQ lane loses programme in one replicate of three and
SRT in none.** Rig: [`t71-origin.sh`](scripts/t71-origin.sh) on the origin,
[`t71-far.sh`](scripts/t71-far.sh) on the receiver, one cell by [`t71-cell.sh`](scripts/t71-cell.sh),
graded by [`t71-grade.py`](scripts/t71-grade.py).

## Objective

P1-ad. Every latency ordering the campaign holds is loopback or one 12.8 ms internet path
([T18](test-18-delivery-latency.md), [T70](test-70-segmented-latency-budget.md); [Evidence](evidence.md)
§3.11), where the path costs its round trip and nothing else. A long, lossy path is the case that
should favour the tunnels: SRT retransmits inside a fixed buffer and sends at the source's rate
whatever it loses, while both MoQ lanes ride a congestion-controlled QUIC connection whose recovery
costs round trips. This test runs SRT and both MoQ lanes, each in its conformant configuration at the
same 1 s budget, from the primary to a host about 120 ms away, clean and at two random-loss rates,
and asks whether the ordering holds, and at what latency and delivered programme.

## Environment

| | |
|---|---|
| Origin | the EC2 primary (eu-west-1), beside its standing units, which it does not touch: `contrib-10m.ts` from its start each cell, `tsp -P regulate --pcr-synchronous --wait-min 5`, the video PTS tapped by a mirrored fork in the same process as the transmitter; its own `moq-relay` on UDP 4711, open, `--quic-congestion-control delay` (BBRv3) |
| Receiver | an on-demand c6in.2xlarge in us-west-2 (Ubuntu 26.04), running nothing else; the receive stage's stdout tapped inline by `t18-latency.py` and saved |
| Path | the open internet between the two regions; round trip from the clock probe's lowest-delay sample |
| Impairment | `netem` random loss on the receiver, on the lanes' flows only (UDP to and from the origin's relay and SRT ports, not the clock probe or the shell's session): ingress through an `ifb`, egress through a `prio` band, the same rate each way; GRO off on the receiver, `--quic-gso=false` on the subscriber; clean cells pass the same qdiscs at 0 %; applied loss read from netem's counters per cell |
| SRT | TSDuck `srt`, the origin listening and the receiver calling, `--latency 1000` both ends |
| MoQ, opaque lane | `moq import ts --passthrough`, relay, `moq export ts --passthrough --delay 1s` |
| MoQ, media-aware lane | `moq import ts`, relay, `moq export ts --delay 1s` (the fixed-delay export, padded to the catalog's rate) |
| MoQ build | `main` `66af72315` (`moq-lite-06`) on both hosts; WebSocket fallback off |
| TSDuck | 3.44 |
| Clock | both hosts' chrony on Amazon Time Sync, read before and after each cell: the latency is uncorrected, and its bound is the sum of the two hosts' offset and root distance. `t18-latency.py clock-server` on the origin (UDP 9710), probed 30 times before and after each cell, as a cross-check and for the round trip |
| Graders | `t18-latency.py report` (30 s settle); TSDuck `continuity`, `pcrverify --absolute --jitter-max 13` and PCR repetition from `pcrextract`, as T18; [`t28-content-lost.py`](scripts/t28-content-lost.py) on video and the busiest audio from 8 s; [`ts-passthrough-identity.py`](scripts/ts-passthrough-identity.py) on SRT and the opaque lane; [`ts-tstd.py`](scripts/ts-tstd.py) `--skip 8` on clean cells |

## Procedure

A cell is 120 s of the receive stage's output: the impairment set, both clocks read, the origin's
source started, the receiver run, the clocks read again, the source stopped, the counters read and
the impairment cleared. Broadcast names are unique per cell. Captures are graded on the receiver
after the matrix, never beside a running cell.

The matrix: three lanes × {clean, 0.1 %, 1 %} × three replicates, 27 cells, in three rounds. Each
round runs the conditions in order and, within each, the lanes in an order rotated per round, so
that drift on the path falls on every lane alike. A 40 s smoke cell per lane checks the rig first,
ungraded. Diagnostic, labelled and not ranked: both MoQ lanes at 0.1 % and 1 % with the relay on
CUBIC (`loss`), one cell each, because the controller decides how a QUIC sender meets random loss.

```bash
# origin, once: the relay and the clock reference
bash ~/t71/scripts/t71-origin.sh relay-up ~/t71/fix
bash ~/t71/scripts/t71-origin.sh clock-up ~/t71/fix
# laptop: one cell (lane srt|opaque|aware, loss in %)
ORIGIN_IP=<EC2_IP> ORIGIN=<origin-host> FAR=<far-host> \
	bash lab/scripts/t71-cell.sh <round>-<lane>-<loss> <lane> <loss> 120
# receiver, after the matrix
python3 ~/t71/scripts/t71-grade.py ~/t71/runs/<cell> --lane <lane> [--tstd]
```

## Pass criteria, fixed before running

1. **The path is the one asked for.** The probe's lowest-delay round trip is 80–150 ms on every
   cell. netem's counters on the lanes' flows read zero drops on clean cells, and on loss cells the
   applied rate each way is within ±30 % of the commanded one, or the cell is labelled with what was
   applied.
2. **The clock is bounded.** Before and after every cell both hosts' chrony is synchronised to
   Amazon Time Sync, and the sum of the two hosts' |offset| + root distance is at most 5 ms; that
   sum is the cell's latency bound. The probe's offset agrees with zero within its own uncertainty.
   A cell failing either is re-run once, then reported.
3. **The same picture, proved.** The recovered PTS shift is constant within each lane, and on clean
   cells at least 99 % of egress pictures match a source picture.
4. **Equal conformance on the clean path.** On every clean cell each lane's egress has 0 continuity
   errors and 0 PCR intervals over 40 ms, and `ts-tstd.py` passes it from 8 s. PCR accuracy
   (±481 ns) is reported, not gated: the media-aware export misses it by design
   ([T47](test-47-fixed-delay-export.md)). A lane failing on its clean cells is reported and not
   ranked.
5. **Delivered programme.** Per cell: video and audio content lost from 8 s (100 ms tolerance) and,
   on SRT and the opaque lane, identity gaps and foreign packets. A cell whose receive stage exits
   early is graded on what it delivered, with the time it stopped.
6. **The ordering, graded either way.** The clean cells' order of median latency is the reference.
   It survives a loss rate if every lane delivers its whole programme there (no content lost beyond
   tolerance, no continuity error) in all three replicates and the order of medians is unchanged. A
   lane that loses programme or conformance is ranked failing at that rate, whatever its latency.
   Quoted per lane and condition: the median of the three cells' medians, their range, the p95 and
   the clock bound.

*Predicted.* Clean: SRT about 1.1 s, its buffer plus about a round trip; both MoQ lanes about
1.1–1.2 s, the delay plus the one-way transit and the export's ordering. At an equal budget no lane
should lead by much. At 0.1 % all three should deliver everything at their clean latency. At 1 %,
SRT's buffer covers about eight round trips of retransmission and it should deliver everything;
BBRv3 does not back off at 1 % random loss, so both MoQ lanes should keep the rate, but a picture
whose retransmission is lost again costs further round trips, the export drops what misses its
delay, and T47 had the media-aware export stop between 2 % and 3 % at 1 s on a 50 ms path. On CUBIC
the MoQ lanes should not sustain 10 Mb/s at 1 % on this round trip: a Reno-like sender's loss bound
there is about 1 Mb/s.

## Results

**Criteria 1–4 hold on every cell.**

1. **Path.** Round trip 115–121 ms. Clean cells drop nothing. On every loss cell the media direction
   is within ±30 % of the commanded rate: 0.083–0.105 % at 0.1 %, 0.93–1.03 % at 1 %. The return
   direction carries 5,000–19,000 packets a cell and is within ±30 % except on three 0.1 % cells,
   labelled with what was applied: `r1-srt-l0.1` 0.052 %, `r3-srt-l0.1` 0.139 % and `r3-aware-l0.1`
   0.135 %.
2. **Clock.** Both hosts synchronised before and after every cell, the bound 0.80–1.07 ms; the probe
   agrees with zero within its ±58 ms. One media-aware 0.1 % cell lost its closing reads and
   counters when the workstation driving it slept, and was re-run (`r2-aware-l0.1b`); the original
   is not graded.
3. **Same picture.** The PTS shift is 0 on SRT and the opaque lane and +1 tick on the media-aware
   lane, in every cell; every egress picture matches a source picture, 4,210–4,279 a cell.
4. **Clean conformance.** Every clean cell of every lane: 0 continuity errors, PCR intervals at most
   25.1 ms, `ts-tstd.py` passing from 8 s. Reported: every clean cell, the media-aware lane's
   included, has 0 PCRs beyond ±481 ns, as T47's merged export had; the reason the criterion gave
   for not gating accuracy was the earlier build's.

**Latency and delivered programme** (ms; median of the three cells' medians, their range, the
median p95; clock bound ≤ 1.07 ms throughout):

| Lane | Loss | Median (range) | p95 | Whole programme |
|---|---|---|---|---|
| SRT | clean | 1,030.0 (1,026.1–1,031.2) | 1,061.5 | 3 of 3 |
| SRT | 0.1 % | 1,029.2 (1,028.8–1,030.5) | 1,060.8 | 3 of 3 |
| SRT | 1 % | 1,029.1 (1,026.1–1,031.2) | 1,060.6 | 3 of 3 |
| Opaque | clean | 1,046.9 (1,021.0–1,056.9) | 1,094.4 | 3 of 3 |
| Opaque | 0.1 % | 1,045.4 (1,021.0–1,046.0) | 1,092.3 | 3 of 3 |
| Opaque | 1 % | 1,040.7 (1,021.5–1,050.2) | 1,087.2 | 2 of 3 |
| Media-aware | clean | 1,281.1 (1,277.8–1,338.1) | 1,353.3 | 3 of 3 |
| Media-aware | 0.1 % | 1,286.6 (1,277.6–1,348.7) | 1,358.9 | 3 of 3 |
| Media-aware | 1 % | 1,440.8 (1,374.7–1,786.5) | 1,513.4 | 2 of 3 |

Every whole SRT and opaque cell is the source's packets with 0 identity gaps and 0 foreign packets.
The two failing cells lost programme in short holes during the run, not at the join:

- **Opaque, `r3-opaque-l1`:** 0.52 s of video and 0.36 s of audio in three holes of up to 200 ms,
  at 49, 76 and 118 s, its 4,075 missing packets in 11 identity gaps; where they were missing the
  wire broke, with 48 continuity errors and 10 PCR intervals over 40 ms (largest 147.9 ms).
- **Media-aware, `r2-aware-l1`:** 0.92 s of video in four holes of up to 280 ms, at 76–117 s, and no
  audio; its wire stayed conformant (0 continuity errors, 0 PCR intervals over 40 ms).

Within a cell each lane's latency is flat: between the first and last thirds SRT rises 24 ms, the
opaque lane moves −23 to +2 ms and the media-aware lane falls 27–64 ms.

**Diagnostic, the relay on CUBIC** (one cell each, not ranked; a clean cell delivers about 4,250
pictures):

| Lane | Loss | Pictures delivered | Bytes in 120 s | Other |
|---|---|---|---|---|
| Opaque | 0.1 % | 1,004 | 42 MB (2.8 Mb/s) | 998 continuity errors, 184 identity gaps |
| Media-aware | 0.1 % | 755 | 146 MB, 72 % of it null padding | median 1,704 ms, rising 152 ms over the cell |
| Opaque | 1 % | 137 | 9.8 MB (0.65 Mb/s) | 548 continuity errors |
| Media-aware | 1 % | 0 | nothing written | — |

The opaque lane's rates sit near a Reno-like sender's loss bound at 1,200-byte packets and 116 ms,
about 3.2 and 1.0 Mb/s. On streams this starved the picture count is the measure: the content
grader infers its nominal step from the stream, and scores the 0.1 % media-aware cell 12.6 s lost.

## Conclusions

1. **At a 1 s budget on a 116 ms path, SRT and the opaque MoQ lane deliver at the same latency, and
   the media-aware lane about a quarter of a second later.** SRT's and the opaque lane's ranges
   overlap, 17 ms apart at the median; clean, the media-aware lane's median is 234 ms behind the
   opaque lane's and 251 ms behind SRT's, and it is behind both in every replicate. SRT delivers at
   its configured 1,000 ms plus 26–31 ms, below the predicted buffer plus a round trip. The
   media-aware lane's latency is fixed at the join and holds for the run, varying between cells by
   60 ms clean and 412 ms at 1 %: its export acquires its clock once, on the track sent latest,
   which is the documented behaviour of the build's jitter buffer. What sets its surplus over the
   opaque lane at the same delay was not isolated.
2. **At 0.1 % random loss each way the ordering and every lane's programme survive at clean
   latency.**
3. **At 1 % only SRT stays whole.** Each MoQ lane lost under a second of programme in one replicate
   of three, in three or four holes of at most 280 ms, so under criterion 6 both rank failing at
   this budget. Neither lost rate, and the media-aware lane's median rose 160 ms. T47's export held
   at 2 % at 1 s on a 50 ms path, so the margin shrinks with the round trip, though two paths do not
   fit a curve.
4. **The relay's controller decides whether the MoQ lanes work at all on this path.** On CUBIC
   neither carries the programme at 0.1 %, and at 1 % the media-aware lane writes nothing; BBRv3
   kept every cell at the source's rate.

## Limits

- One path between two regions, one 10 Mb/s clip, 120 s cells and three replicates: one failure in
  three is an existence result at 1 %, not a rate.
- Independent random loss only, the same each way; no burst loss, reordering or rate limit.
- One budget: whether a longer MoQ delay restores whole delivery at 1 % is not measured. SRT is
  ungroomed TSDuck at `--latency 1000`.
- Software receivers only; no IRD.

# Test 73 — The long path at a 2 s budget, under random and burst loss, with the segmented lane

**State: run, 45 cells and five diagnostics; criteria 1–4 hold on every cell. At 2 s every lane is
whole at 1 % random loss; under burst loss SRT and both MoQ lanes stay whole and the segmented lane
loses programme in all three replicates, through the burst model's interaction with an on-off flow.**
Rig: T71's
([`t71-origin.sh`](scripts/t71-origin.sh), [`t71-far.sh`](scripts/t71-far.sh),
[`t71-cell.sh`](scripts/t71-cell.sh), [`t71-grade.py`](scripts/t71-grade.py)), extended with a
segmented lane and a burst-loss model; the model is checked by
[`t73-burst-probe.py`](scripts/t73-burst-probe.py) and the matrix run by
[`t73-drive.sh`](scripts/t73-drive.sh).

## Objective

[Evidence](evidence.md) §5 row 4. At a 1 s budget 116 ms away, SRT stays whole at 1 % random loss
and each MoQ lane loses programme in one replicate of three ([T71](test-71-long-lossy-path.md)).
This test asks three things on the same path: whether a 2 s budget makes the MoQ lanes whole at 1 %;
whether burst loss at the same mean rate, the case that should favour a tunnel without congestion
control, reorders the lanes; and where the segmented lane, never run on a long lossy path, falls
under both, and under T71's own conditions.

## Environment

As [T71](test-71-long-lossy-path.md#environment), with these differences:

| | |
|---|---|
| Budget | 2 s on every lane: SRT `--latency 2000` both ends; `moq export ts --delay 2s` on both MoQ lanes; the segmented lane's groomer cushion `--latency-ms 2000`. The segmented lane also runs T71's 1 s budget |
| Segmented lane | [T70](test-70-segmented-latency-budget.md)'s chain at its floor: on the origin, the paced clip to a loopback multicast group, `t61-epochseg.py --duration 1 --window 6 --extra 3 --target 2 --pdt`, and its own `nginx` on TCP 18731; on the receiver, `b8-hls-recv.py --poll 250` (no release hold) into `mpegts-pacer` (`97f3a38`) `stdout 11438000 --stream-clock --latency-ms <budget> --max-latency-ms 14000 --stall-ms 1000 --on-stall mute`. It carries a groomer and the other lanes do not, because its receiver has no playout clock of its own; its latency includes the epoch and the fetch |
| Segmented transport | HTTP/1.1 over TCP, kept alive. The origin's sender runs Linux `tcp_bbr` for the receiver's address only (a host route with `congctl bbr`, removed after), to match the MoQ relay's BBR; slow start after idle stays at the host default. Diagnostic: the host default, CUBIC |
| Impairment | T71's qdiscs, also on TCP 18731. Random: Bernoulli at 1 % (and 0.1 % for the segmented lane's 1 s cells). Burst: `netem loss gemodel 0.05% 5% 100% 0%`, a Gilbert model of mean loss 0.99 % in bursts of mean 20 datagrams, each way. In datagrams, so a burst lasts about 20 ms on the media direction and longer on the sparse return direction |

## Procedure

A cell is T71's: 120 s of the receive stage's output, the impairment set and cleared around it,
both clocks read before and after, captures graded on the receiver after the matrix. Broadcast names
and cells are unique.

**Before the matrix:** the burst model is measured on the receiver's qdisc by
`t73-burst-probe.py`, 60 s at 1,000 datagrams a second from the receiver to the origin's SRT port
through the egress band, with the lanes idle. A 40 s smoke cell per lane, ungraded, checks the rig.

**The matrix,** in three rounds, each running the conditions in order and the lanes in an order
rotated per round:

- 2 s budget: SRT, opaque, media-aware, segmented × {clean, 1 % random, burst}, 36 cells;
- 1 s budget, segmented only × {clean, 0.1 %, 1 %}, 9 cells, against T71's other lanes.

Diagnostic, labelled and not ranked: the segmented lane at 2 s on CUBIC at 1 % and burst, one cell
each; and, added once the matrix had shown the segmented lane failing under burst loss, the same
lane on BBR with the burst model on one direction only (`in:` or `out:` in `t71-far.sh`): the media
direction twice, the return direction once.

```bash
# laptop: one cell; LOSS is a percentage, or ge:<p>,<r> for the Gilbert model
BUFMS=2000 DELAY=2s ORIGIN_IP=<EC2_IP> ORIGIN=<origin-host> FAR=<far-host> \
	bash lab/scripts/t71-cell.sh <round>-<lane>-<cond>-b2 <lane> <loss> 120
# laptop: the matrix
ORIGIN_IP=<EC2_IP> ORIGIN=<origin-host> FAR=<far-host> bash lab/scripts/t73-drive.sh 120
# receiver, after the matrix
python3 ~/t71/scripts/t71-grade.py ~/t71/runs/<cell> --lane <lane> [--tstd]
```

## Pass criteria, fixed before running

1. **The path and the loss are the ones asked for.** T71's criterion 1 on every cell (round trip
   80–150 ms; zero drops clean; the applied rate each way within ±30 % of the commanded mean, or the
   cell labelled). The burst probe reads a mean loss of 0.7–1.3 % and a mean burst of 14–26
   datagrams, or the model is re-parameterised before any cell runs.
2. **The clock is bounded**, as T71's criterion 2.
3. **The same picture, proved**, as T71's criterion 3.
4. **Equal conformance on the clean path**, as T71's criterion 4; the segmented lane is graded on
   its groomer's output.
5. **Delivered programme**, as T71's criterion 5, adding the segmented lane's groomer stalls and
   the receiver's abandoned fetches.
6. **The ordering, graded either way**, as T71's criterion 6, separately for 1 % random and for
   burst.
7. **The budget answer.** A lane is whole at 1 % at 2 s if all three replicates are. Against T71's
   1 s result, only a change between "whole in all three" and "programme lost in at least one"
   counts; anything else is reported as not separated.

*Predicted.* Clean: SRT and the opaque lane about 2.03–2.05 s and the media-aware lane about
2.28 s, T71's figures plus a second; the segmented lane about 3.5–4 s, its cushion plus the 1 s
epoch, the fetch and slow start after each idle second. At 1 % random every lane whole: 2 s holds
about sixteen round trips of retransmission, and BBR does not back off at that rate. Under burst
loss SRT whole, since a burst costs it one round of retransmission and it never slows; BBRv3 reads a
round with 20 of about 120 datagrams lost as congestion and cuts its window, so the MoQ lanes may
fall behind the source for a second or two each burst, which the 2 s budget should absorb; the
segmented lane's BBR ignores loss and is whole. On CUBIC the segmented lane cannot carry the
programme at 1 %: a Reno-like sender's bound at this round trip is about 1 Mb/s. At 1 s the
segmented lane fails, since its cushion barely covers T70's floor on a 12 ms path.

## Results

**Criteria 1–4 hold on every cell.**

1. **Path and loss.** Round trip 115–121 ms. The burst probe read 0.91 % lost in 27 bursts over
   60 s, of mean 20.2 datagrams (median 14, longest 80), inside the fixed ranges. Every random-loss
   cell's applied rate each way is within ±30 % of the commanded one but one return direction at
   0.138 % (r1, segmented, 0.1 %). A burst cell holds about fifty bursts, so its applied rate varies
   more; outside ±30 %, and labelled: the media direction of r1-srt (0.58 %), r3-srt (1.47 %) and
   r3-seg (1.44 %), and the return direction of r2- and r3-aware (0.31, 0.36 %), r2- and r3-srt
   (0.54, 0.33 %) and r2- and r3-seg (0.59, 1.97 %).
2. **Clock.** Both hosts synchronised before and after every cell; bound 0.96–1.08 ms; the probe
   agrees.
3. **The same picture.** PTS shift 0 on SRT, the opaque and the segmented lanes and +1 tick on the
   media-aware one; every egress picture in every cell matches a source picture.
4. **Clean conformance.** On every clean cell of every lane, at both budgets: 0 continuity errors,
   0 PCR intervals over 40 ms, `ts-tstd.py` passes, and no PCR beyond ±481 ns.

**Latency and delivered programme.** Median of the three cells' medians, ms, with their range; every
cell's p95 is within 75 ms of its own median. *Whole* is criterion 6's: no content lost beyond
tolerance and no continuity error.

| Lane, budget | Clean | 1 % random | Burst |
|---|---|---|---|
| SRT, 2 s | 2,029.7 (2,028.8–2,033.3) | 2,032.7, whole | 2,031.3, whole |
| Opaque, 2 s | 2,022.2 (2,020.4–2,061.4) | 2,063.1 (2,056.6–2,120.6), whole | 2,022.2, whole |
| Media-aware, 2 s | 2,299.4 (2,252.2–2,343.9) | 2,397.4 (2,330.6–2,431.6), whole | 2,356.5, whole |
| Segmented, 2 s | 3,219.3 (3,171.4–3,284.0) | 2,746.0 (2,586.2–3,366.4), whole | 3,302.9; **0 of 3 whole**: 53.5, 1.2 and 44.4 s of video lost |
| Segmented, 1 s | 2,417.9 (2,401.0–2,458.7) | 2,788.5, 2 of 3 whole | not run; at 0.1 % random 2,517.1, 2 of 3 whole |

SRT and the opaque lane are byte-identical to the clip on every 2 s cell, burst included (0 gaps,
0 foreign packets). Within a cell SRT drifts +24 to +26 ms, the opaque lane −11 to −21 ms, the
media-aware lane −27 ms and the segmented lane under 2 ms. The segmented lane's latency is set in its
opening seconds: its groomer discards as late the opening backlog older than its cushion, 9,883
packets in every clean 2 s cell and 17,488, a further second of stream, in the two 1 % cells that
read 2,586 and 2,746 ms; the third, at 3,366 ms, discarded 9,883. At 1 s the discard is 8,429–8,894
in every cell while latency spans 2,366–2,899 ms, so it accounts for part of the spread only. Its 1 s
figure is 186 ms below [T70](test-70-segmented-latency-budget.md)'s 2,604 ms for the same chain on a
12.8 ms path; this test does not attribute the difference. The two 1 s segmented cells that are not whole each carry 7 continuity errors from one or two groomer
stalls and lose under 0.2 s of content.

**The segmented lane under burst loss.** In r1 a segment fetch timed out 12 s in, the receiver's
playlist requests then timed out every 3.2 s, and when one succeeded 12.3 s later 12 segments had
left the playlist; two more outages, of 4.9 and 14.6 s, skipped 5 and 17. nginx logged every request
that reached it as written within 0.71 s, so the time went on the path. The diagnostics, one cell
each unless stated:

| Segmented, 2 s | Video lost |
|---|---|
| Burst on the media direction only, two cells | 0 and 7.5 s |
| Burst on the return direction only | 15.8 s |
| Burst both ways, origin on CUBIC | 53.8 s |
| 1 % random, origin on CUBIC | collapsed: 11 segments fetched in 120 s, 9 abandoned, 1.6 MB written |

Either direction alone costs programme. The Gilbert chain advances per datagram, and the segmented
flow is on and off in both directions (each second, a 1.4 MB segment in a median 161 ms, then
requests only), so by the model's definition a burst entered at the end of a fetch persists across
the gap and takes the next request or response and its retransmissions; on the continuous lanes the
same 20 datagrams pass in about 20 ms. The receiver abandons a request after 3 s and a segment after
4 s. That the persistence, rather than the burst itself, costs the programme is inferred from the
model and the diagnostics, not measured on the wire.

## Conclusions

1. **A 2 s budget makes both MoQ lanes whole at 1 % random loss on this path**, in all three
   replicates against two of three at 1 s ([T71](test-71-long-lossy-path.md)): the change criterion
   7 counts, bought with a second of latency. SRT and the opaque lane stay level, at 2,030 and
   2,022 ms clean, which the replicates do not separate (they swap at 1 %); the media-aware lane is
   277 ms behind the opaque one and the segmented lane 1.2 s behind SRT.
2. **Under burst loss at the same mean rate, SRT and both MoQ lanes are whole and keep their clean
   order.** The predicted cost of BBRv3's loss response did not appear at this budget.
3. **The segmented lane is the one that loses programme under burst loss**, in every replicate and
   on either controller. The diagnostics place the cause in a datagram-counted burst model meeting an
   on-off flow and a 3 s fetch timeout, so this shows the lane fragile to that model, not to burst
   loss in general.
4. **At T71's 1 s budget the segmented lane delivers at 2.42 s**, 1.4 s behind SRT, and is the only
   lane to lose conformance at 0.1 %, in one replicate of three. On CUBIC, at 2 s, it collapses at
   1 % random, as the MoQ lanes did at 0.1 % in T71.

## Limits

- One path, one clip, 120 s cells, three replicates.
- Burst loss is netem's per-datagram Gilbert model only, which stretches a burst over an idle flow's
  gaps; loss correlated in time, as a congested queue or a fading link produces, is not run.
- The segmented receiver is the campaign's `b8-hls-recv.py`, with a 3 s request timeout and a 4 s
  give-up; a receiver that waits longer or opens a second connection is not tested.
- The budgets are equal as receive buffers: the segmented lane's latency also carries its epoch and
  fetch, and it alone runs a groomer.
- Software receivers only.

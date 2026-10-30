# Test 73 — The long path at a 2 s budget, under random and burst loss, with the segmented lane

**State: designed; criteria fixed, not yet run.** Rig: T71's
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
each.

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

Not yet run.

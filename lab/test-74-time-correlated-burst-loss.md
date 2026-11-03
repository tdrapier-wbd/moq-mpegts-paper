# Test 74 — Time-correlated burst loss on the long path

**State: specified, not run.** Rig: [T73](test-73-long-path-budget-burst.md)'s at its 2 s budget,
with a loss scheduler that defines bursts in time rather than in datagrams
(`t74-time-burst.py`, to build, started by `t71-far.sh`).

## Objective

[Evidence](evidence.md) §5 row 4. Under netem's Gilbert model at a 1 % mean, T73's segmented lane
lost programme in every replicate at a 2 s budget while SRT and both MoQ lanes stayed whole. Its
diagnostics place the cause in the model: the Gilbert chain advances per datagram, so a burst
entered at the end of a fetch persists across the flow's idle second and takes the next request.
Loss on real paths is correlated in time (a congested queue, a fading link), not in one flow's
packets. This test runs every lane under bursts defined in time, each lane in a round meeting the
same loss timeline, and asks one question: is the segmented lane's burst failure the lane's or the
model's?

**Falsifies:** [Comparison](../docs/comparison.md) §5.1's "a result of the burst model as much as
of the lane", in either direction.

## Environment

As [T73](test-73-long-path-budget-burst.md#environment) at the 2 s budget, with these differences:

| | |
|---|---|
| Loss model | Two states in time: bursts of 100 % loss whose durations are exponential with mean 20 ms, the duration T73's 20-datagram bursts had on the media direction, separated by gaps exponential with mean 1,980 ms, so 1.0 % of time is lost. Each direction has its own schedule, drawn from a seed fixed per round, so every lane in a round meets the same loss in time |
| Scheduler | `t74-time-burst.py` on the far host computes both directions' schedules from the seed, holds one `tc -batch -` process, and switches each direction's netem (T71's qdiscs, unchanged) between `loss 0%` and `loss 100%` at the scheduled times, logging each switch with its realtime timestamp. `t71-far.sh impair tb:<mean-ms>,<percent>,<seed>` starts it and `clear` stops it |
| Far host | Relaunched from its image by T71's procedure, terminated after |

## Procedure

**Before the matrix:** T73's `t73-burst-probe.py` through the scheduler, lanes idle, 60 s at 1,000
datagrams a second and 60 s at 100, on one seed. A time-based model loses the same share and the
same burst durations in milliseconds at both rates, where a datagram-counted one stretches each burst
tenfold at the lower rate. Then one segmented cell under T73's `ge:0.05,5`, to confirm the relaunched
rig reproduces T73's failure. A 40 s smoke cell per lane, ungraded.

**The matrix,** in three rounds, each with its own seed, the lanes in an order rotated per round:
SRT, opaque, media-aware and segmented × {clean, time bursts}, 24 cells of 120 s, about 75 minutes.

Diagnostic, labelled and not ranked: if the segmented lane loses programme, one cell each with the
bursts on the media direction only and on the return direction only, on round 1's seed.

```bash
# laptop: one cell under time bursts of mean 20 ms at 1 % of time, seed 1
BUFMS=2000 DELAY=2s ORIGIN_IP=<EC2_IP> ORIGIN=<origin-host> FAR=<far-host> \
	bash lab/scripts/t71-cell.sh <round>-<lane>-tb-b2 <lane> tb:20,1,<seed> 120
# receiver, after the matrix
python3 ~/t71/scripts/t71-grade.py ~/t71/runs/<cell> --lane <lane> [--tstd]
```

## Pass criteria, fixed before running

1. **The model is time-based, at the rate asked for.** At both probe rates the probe reads 0.7–1.3 %
   lost and a mean burst of 14–26 ms, the two rates' means within 25 % of each other; otherwise the
   scheduler is fixed before any cell runs. In each cell the scheduler's log shows every switch within
   2 ms of its schedule and 0.7–1.3 % of the window lost each way, or the cell is labelled.
2. **Path, clock, picture and clean conformance**, as T73's criteria 1–4.
3. **Delivered programme**, as T73's criterion 5.
4. **The attribution.** The segmented lane whole (T73's criterion 6) under time bursts in all three
   replicates: T73's burst failure is the model's. Programme lost in at least one: it is the lane's
   at time-correlated loss too. A result resting only on labelled cells is reported as not separated.
5. **The continuous lanes.** Against T73's burst column, only a change between "whole in all three"
   and "programme lost in at least one" counts.

*Predicted.* The segmented lane whole: a 20 ms burst overlaps one of its 161 ms fetches about one
time in five and costs a round of SACK recovery, or at worst a retransmission timeout of a few
hundred milliseconds, inside its 3 s request timeout and 2 s cushion; a lost request costs one
retransmission timeout. SRT and both MoQ lanes whole, as under T73's bursts, which lasted about as
long on their continuous flows.

## Limits, stated in advance

- One burst duration (20 ms mean) and one mean rate; longer outages are T28's and T31's.
- The loss is exogenous: a congested queue drops what the flows themselves send, which a fixed
  schedule does not model.
- The two directions' schedules are independent; a fade that takes both at once is not run.
- One path, one clip, 120 s cells, three replicates; T73's receivers, including the segmented
  receiver's 3 s request timeout.

# Test 74 — Time-correlated burst loss on the long path

**State: run; criteria 2–5 hold, criterion 1 but for one probe reading 0.2 ms out of band. The segmented lane's burst failure is the lane's: under bursts in time it fails two replicates of three, where every continuous lane stays whole. P1-ap: a failing fetch waits on a retransmission timeout, and a 1 s fetch deadline with a retry on a fresh connection does not bound it. A re-request at 500 ms on a second, kept-warm connection does: whole in three replicates of three, for 1.8–9.1 % more bytes.** Rig: [T73](test-73-long-path-budget-burst.md)'s at its 2 s budget, with a loss scheduler that defines bursts in time rather than in datagrams ([`t74-time-burst.py`](scripts/t74-time-burst.py), started by `t71-far.sh`; the matrix by [`t74-drive.sh`](scripts/t74-drive.sh)).

## Objective

[Evidence](evidence.md) §5 row 4. Under netem's Gilbert model at a 1 % mean, T73's segmented lane lost programme in every replicate at a 2 s budget while SRT and both MoQ lanes stayed whole. Its diagnostics place the cause in the model: the Gilbert chain advances per datagram, so a burst entered at the end of a fetch persists across the flow's idle second and takes the next request. Loss on real paths is correlated in time (a congested queue, a fading link), not in one flow's packets. This test runs every lane under bursts defined in time, each lane in a round meeting the same loss timeline, and asks one question: is the segmented lane's burst failure the lane's or the model's?

**Falsifies:** [Comparison](../docs/comparison.md) §5.1's "a result of the burst model as much as of the lane", in either direction.

## Environment

As [T73](test-73-long-path-budget-burst.md#environment) at the 2 s budget, with these differences:

|  |  |
| --- | --- |
| Loss model | Two states in time: bursts of 100 % loss whose durations are exponential with mean 20 ms, the duration T73's 20-datagram bursts had on the media direction, separated by gaps exponential with mean 1,980 ms, so 1.0 % of time is lost. Each direction has its own schedule, drawn from a seed fixed per round, so every lane in a round meets the same loss in time |
| Scheduler | `t74-time-burst.py` on the far host computes both directions' schedules from the seed, holds one `tc -batch -` process, and switches each direction's netem (T71's qdiscs, unchanged) between `loss 0%` and `loss 100%` at the scheduled times, logging each switch with its realtime timestamp. `t71-far.sh impair tb:<mean-ms>,<percent>,<seed>` starts it and `clear` stops it |
| Far host | Relaunched from its image by T71's procedure, terminated after |

## Procedure

**Before the matrix:** T73's `t73-burst-probe.py` through the scheduler, lanes idle, 60 s at 1,000 datagrams a second and 60 s at 250, on one seed. A time-based model loses the same share and the same burst durations in milliseconds at both rates, where a datagram-counted one stretches each burst fourfold at the lower rate. (At 250 a second the 4 ms spacing alone lengthens a measured 20 ms mean by about 8 %; at 100 it would by about 25 %, the width of criterion 1.) Then one segmented cell under T73's `ge:0.05,5`, to confirm the relaunched rig reproduces T73's failure. A 40 s smoke cell per lane, ungraded.

**The matrix,** in three rounds, each with its own seed, the lanes in an order rotated per round: SRT, opaque, media-aware and segmented × {clean, time bursts}, 24 cells of 120 s, about 75 minutes.

Diagnostic, labelled and not ranked: if the segmented lane loses programme, one cell each with the bursts on the media direction only and on the return direction only, on round 1's seed.

```bash
# laptop: one cell under time bursts of mean 20 ms at 1 % of time, seed 1
BUFMS=2000 DELAY=2s ORIGIN_IP=<EC2_IP> ORIGIN=<origin-host> FAR=<far-host> \
	bash lab/scripts/t71-cell.sh <round>-<lane>-tb-b2 <lane> tb:20,1,<seed> 120
# laptop: the matrix (round r's seed is 7400 + r)
ORIGIN_IP=<EC2_IP> ORIGIN=<origin-host> FAR=<far-host> bash lab/scripts/t74-drive.sh t74 120
# receiver, after the matrix; then, on the laptop, every cell's grade.json in one directory
python3 ~/t71/scripts/t71-grade.py ~/t71/runs/<cell> --lane <lane> [--tstd]
python3 lab/scripts/t73-summary.py <grades-dir>
# diagnostic: one direction only (in:tb:… or out:tb:…), with a header capture at the origin
sudo timeout -s INT 200 tcpdump -i <origin-nic> -s 128 -w <cell>.pcap 'tcp port 18731'
python3 lab/scripts/t74-tcp-recovery.py <cell>.pcap --slow-ms 600
```

## Pass criteria, fixed before running

1. **The model is time-based, at the rate asked for.** At both probe rates the probe reads 0.7–1.3 % lost and a mean burst of 14–26 ms, the two rates' means within 25 % of each other; otherwise the scheduler is fixed before any cell runs. In each cell the scheduler's log shows every switch within 2 ms of its schedule and 0.7–1.3 % of the window lost each way, or the cell is labelled.
2. **Path, clock, picture and clean conformance**, as T73's criteria 1–4.
3. **Delivered programme**, as T73's criterion 5.
4. **The attribution.** The segmented lane whole (T73's criterion 6) under time bursts in all three replicates: T73's burst failure is the model's. Programme lost in at least one: it is the lane's at time-correlated loss too. A result resting only on labelled cells is reported as not separated.
5. **The continuous lanes.** Against T73's burst column, only a change between "whole in all three" and "programme lost in at least one" counts.

_Predicted._ The segmented lane whole: a 20 ms burst overlaps one of its 161 ms fetches about one time in five and costs a round of SACK recovery, or at worst a retransmission timeout of a few hundred milliseconds, inside its 3 s request timeout and 2 s cushion; a lost request costs one retransmission timeout. SRT and both MoQ lanes whole, as under T73's bursts, which lasted about as long on their continuous flows.

## Limits, stated in advance

- One burst duration (20 ms mean) and one mean rate; longer outages are T28's and T31's.
- The loss is exogenous: a congested queue drops what the flows themselves send, which a fixed schedule does not model.
- The two directions' schedules are independent; a fade that takes both at once is not run.
- One path, one clip, 120 s cells, three replicates; T73's receivers, including the segmented receiver's 3 s request timeout.

## Results

T71's build, late October 2026 `main`, on both hosts, the far host from its image; 24 cells, none failed, plus the probe, one reproduction cell and three diagnostics.

1. **The model is time-based; one probe reading misses its band by 0.2 ms.** At 1,000 datagrams a second the probe lost 0.95 % in 24 bursts of mean 23.8 ms (median 21, max 63); at 250 a second, 0.96 % in 22 bursts of mean 6.55 datagrams, 26.2 ms. The two means are within 10 %, where a datagram-counted model would differ fourfold. The 26.2 ms is 0.2 ms over the 14–26 ms band: one schedule read at a 4 ms spacing, which misses bursts shorter than the spacing (22 against 24) and lengthens the rest, as the procedure foresaw (8 % expected, 10 % read). The scheduler was not changed. In every cell every switch landed within 0.14 ms of its schedule and 0.90–1.21 % of the window was lost each way, in bursts of mean 18.1–21.3 ms; no cell is labelled.
2. **Path, clock, picture and clean conformance hold on every cell.** Round trip 114.8–117.3 ms, clock bound at most 1.16 ms, every egress picture matched, the clean cells free of continuity errors and 40 ms PCR intervals and passing the buffer model. SRT and the opaque lane matched the clip packet for packet in every cell, impaired ones included. Under T73's `ge:0.05,5` the relaunched rig's segmented lane lost 21.4 s, reproducing T73's failure.
3. **Delivered programme:**

| Lane | Clean, median (range) | Time bursts: whole | Time bursts, median | What the others lost |
| --- | --- | --- | --- | --- |
| SRT | 2,029 ms (2,029–2,029) | 3 of 3 | 2,030 ms | — |
| Opaque | 2,055 ms (2,051–2,060) | 3 of 3 | 2,060 ms | — |
| Media-aware | 2,276 ms (2,275–2,276) | 3 of 3 | 2,276 ms | — |
| Segmented | 3,595 ms (3,584–3,649) | 1 of 3 | — | round 1: a 7.8 s stall, 22 continuity errors, nothing lost; round 2: 11.3 s of video and audio, 12 errors |

The segmented lane's clean median is 0.37 s above T73's 3.22 s on the same rig and budget; not investigated. Medians of cells that lost programme are not compared. 4. **The attribution: the lane's.** The segmented lane is whole in one replicate of three, and round 2 lost 11.3 s in an unlabelled cell. T73's burst failure is not only the datagram-counted model's: at time-correlated loss the lane fails too, less often and less deeply (T73: 1–54 s in every replicate). 5. **The continuous lanes:** whole in all three replicates, as under T73's bursts; no change.

_Prediction falsified_ for the segmented lane, which was to be whole; SRT and both MoQ lanes whole, as predicted.

**Diagnostics, labelled and not ranked**, each with a header capture of the lane's TCP at the origin read by [`t74-tcp-recovery.py`](scripts/t74-tcp-recovery.py):

| Cell | Bursts | Programme | Slowest fetch |
| --- | --- | --- | --- |
| media direction only | round 1's seed | whole | 1.16 s |
| return direction only | round 1's seed | whole | 0.98 s |
| both directions, again | round 2's seed | 0.36 s lost, 7 errors, one 536 ms stall | 1.56 s |

**What a burst costs a fetch, captured.** A response leaves the origin at line rate in about 40 ms each second. A loss with later segments behind it is resent within 6–96 ms; one at the tail is probed about 240 ms after the origin's last send. A burst that takes most of a response leaves nothing to probe from: both slow recoveries began with a 333–338 ms silence, a retransmission timeout, and continued in rounds of one round trip as the window regrew, 1.16 s and 1.56 s for a 1.5 MB segment, 555 segments resent in the slower. The 2 s cushion absorbed the 1.16 s fetch; the 1.56 s one stalled the groomer for 536 ms. The matrix's failing fetches, 3.9 s and 6.2 s in round 1 and 8.2 s in round 2, each with its first byte in one round trip, were not captured, and the re-run on round 2's seed did not repeat the 8.2 s: where a burst meets a fetch depends on the cell's phase against the schedule. None tripped the receiver's 3 s timeout, which bounds each read, not the fetch.

## Conclusions

- **Under bursts defined in time, segmented HTTP alone fails to stay whole on the 116 ms path at a 2 s budget**: in two replicates of three (11.3 s lost; a 7.8 s stall) and in the both-direction diagnostic. The continuous lanes, whose steady flow lets each loss be detected from the packets behind it, stay whole.
- **The datagram-counted model made the failure worse but did not create it.** Bursts on one direction alone did not fail the lane in either diagnostic.
- **A 20 ms burst turns a fetch into seconds through a retransmission timeout**, after which the response is resent one round trip at a time (2.2–5.6 s, captured).
- **Re-requesting on a fresh connection does not bound it at this budget.** On the 116 ms path a new connection needs about the second of slack a 2 s cushion leaves, so a 1 s deadline cuts healthy retries and each cut costs 1.5 s.
- **Re-requesting on a connection already open bounds it.** At 500 ms on a second connection kept warm by the playlist polls, the lane stayed whole in three replicates of three. Without the re-request, the same timelines cost programme in one and continuity in another. No segment waited over 0.75 s after the join, and the duplicates cost 1.8–9.1 % more bytes. One path, one budget, HTTP/1.1 over TCP.

## The failing fetch, and a deadline on it (P1-ap)

**Procedure.** The rig relaunched as above. Per round r of three, on seed 7400 + r: the segmented lane under time bursts, then again with each segment fetch bounded at 1,000 ms by [`t74-fetch-deadline.py`](scripts/t74-fetch-deadline.py), which runs the receiver unchanged and shuts the socket at the deadline, so that its retry asks again on a new connection. Round 1 adds a clean cell with the deadline. Every cell has a header capture of the lane's TCP at the origin.

```bash
DEADLINE_MS=1000 CAPTURE=<origin-nic> ORIGIN_IP=<EC2_IP> ORIGIN=<origin-host> FAR=<far-host> \
	bash lab/scripts/t74-drive.sh p1ap 120
python3 lab/scripts/t74-tcp-recovery.py <cell>/origin.pcap --slow-ms 600
```

**The deadline, set before running.** In the diagnostics a 1.16 s fetch was absorbed and a 1.56 s one stalled the groomer for 536 ms, so a fetch has about 1 s of slack at this budget; past 1,000 ms it has already cost programme. A new connection then pays a poll, a handshake and slow start on the 116 ms path, about 1.5 s for a 1.5 MB segment.

**Pass criteria, fixed before running:**

1. Path and scheduler as criteria 1–2; each cell's capture spans its receive window with no packet dropped by the kernel.
2. **A failing fetch captured:** at least one fetch of 2 s or more in a cell without the deadline, its recovery read from the capture. None in three rounds is reported as not captured.
3. **The deadline:** the lane whole (T73's criterion 6) in all three cells with it, and it bounds the failure; programme lost in at least one, and it does not at this budget. Reported beside it, per cell: the deadline's firings, the longest stall and the segments lost, against the same round without it.
4. **The clean control:** whole, the deadline never firing; otherwise 1,000 ms is too tight for this path and criterion 3 is labelled.

_Predicted._ A failing fetch begins with a retransmission timeout on a response's tail and goes on in one-round-trip rounds, as the two captured slow recoveries did. With the deadline the lane is still not whole where a burst meets a fetch, the new connection's 1.5 s exceeding the slack, but no stall exceeds 2 s and no segment is lost.

**Results**, seven cells:

1. **Path, scheduler and captures hold.** Every switch landed within 0.11 ms of its schedule and 0.88–1.17 % of the window was lost each way, in bursts of mean 18.3–20.9 ms; round trip 115–117 ms, clock bound at most 1.10 ms. Every capture spans its window with no packet dropped by the kernel.
2. **Failing fetches captured.** Without the deadline: 2.17 s in round 1, and 5.62, 5.00 and 3.66 s in round 2, each with its first byte in one round trip; none of 2 s in round 3. In the three the capture reads whole, the origin fell silent for 335–447 ms, a retransmission timeout, then resent through the rest of the fetch one round trip apart: 511, 394 and 74 segments.
3. **The deadline does not bound the failure.** Every cell fetched all 108 segments; what was lost arrived too late.

| Round | Without the deadline | With it: firings | With it: longest wait for a segment | With it: programme |
| --- | --- | --- | --- | --- |
| 1 | whole, 2 groomer stalls, 12 continuity errors | 0 | 1.72 s | whole, no stall |
| 2 | 11.44 s lost; waits up to 6.73 s | 4 | 5.73 s | 5.84 s lost |
| 3 | 0.20 s lost; waits up to 3.01 s | 4 | 5.04 s | 4.98 s lost |

A new connection fetches a segment in 976–983 ms on this path when it loses nothing, which leaves the deadline 17–24 ms. Two retries that had lost nothing were cut as their last bytes arrived, and two segments were cut twice. Each cut cost about 1.5 s before the next attempt finished, so where it fired the deadline replaced one long recovery with a chain of short ones, 3.2–5.7 s end to end. In both rounds where it fired it also cut the joining fetch, and those two cells ran about 1 s below the others' latency (2,387 and 2,517 ms, against 3,144–3,495 ms), with less cushion when their bursts came; not investigated. 4. **The clean control:** whole, the deadline never firing; its slowest fetch, the joining one on a new connection, took 974 ms. Met, by 26 ms, so criterion 3 is not labelled.

_Prediction_: the failing fetch's shape confirmed. With the deadline, no segment was lost, but waits reached 5.7 s and the programme lost 5.8 s: falsified.

## A re-request on a connection already open ([Evidence](evidence.md) §5 row 4)

**Procedure.** P1-ap's rig, relaunched. The origin is on a host of its own in the same region, with no standing units, rather than beside the soak. Per round r of three, on seed 7400 + r: the segmented lane under time bursts, then again with [`t74-hedge.py`](scripts/t74-hedge.py), which runs the receiver unchanged over two kept-alive connections. Segment fetches alternate between them, and each playlist poll also goes out on the idle one, so neither idles past a retransmission timeout, after which Linux cuts a sender's window. That makes both as warm as the receiver's one connection. A segment fetch still running at 500 ms is requested again on the other connection, and the first complete response is used; the slower one finishes unused. Round 1 adds a clean cell with the hedge. Every cell has a header capture of the lane's TCP at the origin.

**The hedge, set before running.** A healthy fetch on a kept-alive connection takes about 160 ms on this path, and one that recovers a burst by SACK about 6–96 ms more. A failing fetch falls silent for 335–447 ms, a retransmission timeout, before it resends. At 500 ms only the last has not finished, and a request on a warm connection should then complete within about 200 ms, inside the second of slack the 2 s cushion leaves.

**Pass criteria, fixed before running:**

1. Path, scheduler and captures as P1-ap's criterion 1.
2. **A failing fetch captured without the hedge:** at least one fetch of 2 s or more across the three rounds. None in three rounds is reported as not captured, and criterion 3 then says nothing about the failure.
3. **The hedge:** the lane whole (T73's criterion 6) in all three cells with it, and it bounds the failure; programme lost in at least one, and it does not. Reported per cell: the hedges fired and which connection answered, the longest wait for a segment, the segments lost, and the bytes the hedges added, against the same round without it.
4. **The clean control:** whole, the hedge firing on no fetch but the joining one; otherwise 500 ms is too tight for this path and criterion 3 is labelled.

_Predicted._ The hedge bounds the failure: a fetch stalled by a retransmission timeout is overtaken at 500 ms by one on the other connection that completes about 200 ms later, so no segment waits more than about 0.8 s and the lane is whole in all three. A burst that also takes the hedge's request costs one more round trip.

```bash
HEDGE_MS=500 CAPTURE=<origin-nic> ORIGIN_IP=<EC2_IP> ORIGIN=<origin-host> FAR=<far-host> \
	bash lab/scripts/t74-drive.sh hedge 120
python3 lab/scripts/t74-tcp-recovery.py <cell>/origin.pcap --slow-ms 600
```

**Results**, seven cells:

1. **Path, scheduler and captures hold.** Every switch landed within 0.10 ms of its schedule, and 0.88–1.18 % of the window was lost each way, in bursts of mean 18.3–21.0 ms. Both cells of a round met the same timeline. Round trip 115.0–116.6 ms, clock bound at most 1.23 ms. Every capture spans its window with no packet dropped by the kernel.
2. **A failing fetch captured,** in round 1 without the hedge: 3.86 s. It began without a silence (its longest send gap was 23 ms). The fetch before it on the same connection had waited out a 353 ms retransmission timeout, and this one went out on the window that left, regrowing one round trip at a time. Round 3's longest fetch took 1.81 s, a retransmission timeout and 831 segments resent; round 2's took 0.62 s.
3. **The hedge bounds the failure.** Every cell fetched all its segments. Each cell with the hedge also hedged its joining fetch, whose original answered first; the table counts the hedges after it.

| Round | Without the hedge | With it: hedges, re-request first | With it: longest wait after the join | With it: bytes added | With it: programme |
| --- | --- | --- | --- | --- | --- |
| 1 | 3.48 s lost, 16 continuity errors, 2 groomer stalls; waits up to 3.86 s | 9, 5 | 0.75 s | 14.6 MB (9.1 %) | whole |
| 2 | whole; waits up to 0.62 s | 2, 0 | 0.67 s | 5.1 MB (3.2 %) | whole |
| 3 | 5 continuity errors, one groomer stall, no content lost; waits up to 1.81 s | 1, 1 | 0.75 s | 2.9 MB (1.8 %) | whole |

The bytes added are the unused responses, the join's included; every one completed. The slowest original a re-request overtook took 5.47 s. 4. **The clean control:** whole. The hedge fired once, on the joining fetch (968 ms), whose re-request, the second connection's first, took 967 ms. Met.

_Prediction_: confirmed after the join, with no wait over 0.75 s and the lane whole in all three cells. The joining fetch, on new connections, took 0.97–1.31 s with or without the hedge.

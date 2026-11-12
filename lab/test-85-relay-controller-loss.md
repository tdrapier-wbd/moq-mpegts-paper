# T85 — `moq-relay`'s controller under last-mile loss and under congestion

**State: criteria fixed; running.**

## Objective

Through a CDN-hosted relay of another implementation, 5–10 % last-mile loss cost the media-aware lane nothing, where `moq-relay` at its default lost 23–39 s of a 40 s shape ([T84](test-84-moq-cdn-relay-impairment.md)). `moq-relay` offers `--quic-congestion-control loss` (CUBIC), `delay` (its own BBRv3, the default) or `none` (no control and no pacing). Its BBRv3 answers loss twice: a round losing more than 2 % (`LOSS_THRESH`) cuts its long-term inflight bound, and every round with a loss shrinks its short-term bounds by `BETA` (0.7), down to the latest delivery rate.

1. Does `none`, or BBRv3 with either loss response removed, hold the lane through T84's loss?
2. What does each cost when the loss is congestion: capacity below the feed's rate, and a shallow-buffered bottleneck that drops an unpaced burst?
3. Does any change what 20 % reorder costs?

## Environment

|  |  |
| --- | --- |
| Host | one EC2 instance (8 vCPU), T84's local arm: `tsp regulate` replays the synthetic fixture to `moq import ts` and `moq-relay` on the host, GSO off; the publisher and an uncounted anchor on loopback; the impaired and control legs in T72's namespaces (100 ms RTT, a 20 Mb/s `cake` on the impaired leg). |
| Build | `moq-dev` `main`, one commit for client and relay, recorded with the results. |
| Arms | **`default`** (no flag: BBRv3); **`none`** (`--quic-congestion-control none`); **`thr20`** (the same tree, `LOSS_THRESH` 0.2); **`noloss`** (`LOSS_THRESH` 0.2 and `BETA` 1.0: BBRv3's model with no loss response). The two patched relays are lab builds, not upstream options. |
| Lane | demultiplexed, its delay matched to T84's 5.91 s column. |
| Shapes | each 40 s from 20 s in a 95 s window, three replicates, replicate-major: **loss5**, **loss10** (Bernoulli), **reorder20** (50 ms, T84's); **step8** (the `cake` falls from 20 to 8 Mb/s, below the feed's 10 Mb/s); **shallow15** (the `cake` replaced by a 15 Mb/s token bucket with a 3 kB burst and a 15 kB queue: room for a paced sender, not for an unpaced burst). |

## Procedure

Each arm runs under [`t84-moq-drive.py`](scripts/t84-moq-drive.py) as T84's did: controls until one matches within 100 ms of 5,910 ms, a void cell re-run once, each cell conserved against the control. [`t85-batch.sh`](scripts/t85-batch.sh) runs the four arms in turn; `t84-moq-drive.py compare-arms` sets each arm's median beside the default's, per shape.

## Pass criteria, fixed before running

1. T84's criteria 1–4 hold in every arm: a matched, clean control; clean control legs; single-packet loss; every lossless cell conserved.
2. **H-base:** `default` loses at least 20 s at 5 % loss, so T84's local figure holds on this build.
3. **H-arm:** `none`, `thr20` and `noloss` each lose at most 0.5 s at 5 % and at 10 % loss, judged arm by arm.
4. **H-cost:** on step8 and shallow15, an arm that passes criterion 3 loses no more than `default` by T84's criterion 5 (a difference counts past 2 s and a quarter of the larger). Predicted: `none` loses more on shallow15.
5. **Reported:** reorder20 per arm, against `default` by the same rule; on step8 and shallow15, the packets the bottleneck dropped. The drops were added after a pilot cell and before the graded run: through shallow15, `none` lost no content while the bucket dropped two of every three packets it was offered.

## Limits, stated in advance

- One host and one synthetic last mile: Bernoulli loss and `netem` reorder.
- One flow per bottleneck, and `cake` isolates flows: what a sender that ignores loss costs other traffic is not measured.
- One lane at one column.

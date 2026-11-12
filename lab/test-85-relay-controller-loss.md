# T85 — `moq-relay`'s controller under last-mile loss and under congestion

**State: run. Criteria 1 and 2 hold; `noloss` passes 3 and 4, `none` passes 3 and fails 4, `thr20` misses 3 at 10 % by 0.02 s. What `moq-relay` loses to random loss is its BBRv3's loss response, and removing it cost no content the rig could measure; with no controller the relay collapses under reorder and below the feed's rate.**

## Objective

Through a CDN-hosted relay of another implementation, 5–10 % last-mile loss cost the media-aware lane nothing, where `moq-relay` at its default lost 23–39 s of a 40 s shape ([T84](test-84-moq-cdn-relay-impairment.md)). `moq-relay` offers `--quic-congestion-control loss` (CUBIC), `delay` (its own BBRv3, the default) or `none` (no control and no pacing). Its BBRv3 answers loss twice: a round losing more than 2 % (`LOSS_THRESH`) cuts its long-term inflight bound, and every round with a loss shrinks its short-term bounds by `BETA` (0.7), down to the latest delivery rate.

1. Does `none`, or BBRv3 with either loss response removed, hold the lane through T84's loss?
2. What does each cost when the loss is congestion: capacity below the feed's rate, and a shallow-buffered bottleneck that drops an unpaced burst?
3. Does any change what 20 % reorder costs?

## Environment

|  |  |
| --- | --- |
| Host | one EC2 instance (8 vCPU), T84's local arm: `tsp regulate` replays the synthetic fixture to `moq import ts` and `moq-relay` on the host, GSO off; the publisher and an uncounted anchor on loopback; the impaired and control legs in T72's namespaces (100 ms RTT, a 20 Mb/s `cake` on the impaired leg). |
| Build | `moq-dev` `main` `ced5a45c5f` for client and relay (release, Rust 1.98.1); `thr20` and `noloss` the same tree with one and two constants changed in `moq-congestion`'s BBRv3. |
| Arms | **`default`** (no flag: BBRv3); **`none`** (`--quic-congestion-control none`); **`thr20`** (the same tree, `LOSS_THRESH` 0.2); **`noloss`** (`LOSS_THRESH` 0.2 and `BETA` 1.0: BBRv3's model with no loss response). The two patched relays are lab builds, not upstream options. |
| Lane | demultiplexed, its delay matched to T84's 5.91 s column. |
| Shapes | each 40 s from 20 s in a 95 s window, three replicates, replicate-major: **loss5**, **loss10** (Bernoulli), **reorder20** (50 ms, T84's); **step8** (the `cake` falls from 20 to 8 Mb/s, below the feed's 10 Mb/s); **shallow15** (the `cake` replaced by a 15 Mb/s token bucket with a 3 kB burst and a 15 kB queue: room for a paced sender, not for an unpaced burst). |

## Procedure

Each arm runs under [`t84-moq-drive.py`](scripts/t84-moq-drive.py) as T84's did: controls until one matches within 100 ms of 5,910 ms, a void cell re-run once, each cell conserved against the control. [`t85-batch.sh`](scripts/t85-batch.sh) runs the four arms in turn; `t84-moq-drive.py compare-arms` sets each arm's median beside the default's, per shape. A pilot ran each new shape once on `default` and shallow15 on `none`, and checked that each shape applied and was restored and that the flag reached the relay.

## Pass criteria, fixed before running

1. T84's criteria 1–4 hold in every arm: a matched, clean control; clean control legs; single-packet loss; every lossless cell conserved.
2. **H-base:** `default` loses at least 20 s at 5 % loss, so T84's local figure holds on this build.
3. **H-arm:** `none`, `thr20` and `noloss` each lose at most 0.5 s at 5 % and at 10 % loss, judged arm by arm.
4. **H-cost:** on step8 and shallow15, an arm that passes criterion 3 loses no more than `default` by T84's criterion 5 (a difference counts past 2 s and a quarter of the larger). Predicted: `none` loses more on shallow15.
5. **Reported:** reorder20 per arm, against `default` by the same rule; on step8 and shallow15, the packets the bottleneck dropped. The drops were added after a pilot cell and before the graded run: through shallow15, `none` lost no content while the bucket dropped two of every three packets it was offered.

## Results

Every arm's first control matched (5,891–5,956 ms at a 5,750 ms delay) and lost nothing. Programme missing from the impaired leg, seconds, median of three (range):

| Shape | `default` | `none` | `thr20` | `noloss` |
| --- | --- | --- | --- | --- |
| loss5 | 32.52 (26.16–34.20) | 0.08 (0.08) | 0.05 (0.04–0.16) | 0.04 (0.04) |
| loss10 | 38.80 (37.72–40.72) | 0.08 (0.00–0.08) | 0.52 (0.28–0.80) | 0.04 (−0.04–0.04) |
| reorder20 | 33.69 (32.56–34.64) | 69.36 (69.20–69.44), session ended | 34.48 (34.12–35.96) | 32.04 (31.64–35.00) |
| step8 | 8.96 (8.92–9.08) | 59.80 (59.56–60.04), session ended | 9.00 (8.32–9.52) | 8.32 (8.12–8.40) |
| shallow15 | 0.08 (0.00–0.08) | 0.24 (0.16–0.28) | 0.04 (0.04) | 0.04 (0.04) |

Packets the bottleneck dropped in each cell, against those it delivered (step8 and shallow15 to the shape's end; reorder20, the 20 Mb/s `cake`, over the cell):

| Shape | `default` | `none` | `thr20` | `noloss` |
| --- | --- | --- | --- | --- |
| step8 | 0 of 56,089–56,262 | 5,543–31,664 of 48,171–52,654 | 0 | 0 |
| shallow15 | 106–136 of 38,875–38,999 | 90,301–98,021 of 40,801–40,853 | 2,042–2,384 of 39,331–39,412 | 1,926–2,218 of 39,324–39,405 |
| reorder20 | 0 | 432,481–524,354 of 56,838–58,854 | 0 | 0 |

Each `none` session that ended was its subscriber's export failing on its own clock guard (`the source's clock runs -140440.4 ppm off ours, past the 30 ppm the output's may follow`, in one): it fails once arrivals have fallen half the delay behind at a rate it cannot follow, as [T84](test-84-moq-cdn-relay-impairment.md) conclusion 5 found at 11.87 s.

| Criterion | Result | Verdict |
| --- | --- | --- |
| 1 T84's 1–4 | controls matched and clean; no control leg failed, so no cell was void; mean packet 1,170–1,227 B, no UDP receive error; every hole-free cell that kept its session conserved within 0.16 s (the three hole-free `none` reorder cells ended, and conservation counts their loss) | holds |
| 2 H-base | `default` 26.16–34.20 s at 5 % | holds |
| 3 H-arm | `none` 0.08 and 0.08 s; `noloss` 0.04 and 0.04 s; `thr20` 0.05 and 0.52 s | holds for `none` and `noloss`; `thr20` fails at 10 % by 0.02 s |
| 4 H-cost | `noloss` as `default` on both shapes; `none` more on step8 (59.80 s against 8.96), as `default` on shallow15 | holds for `noloss`, fails for `none`; the prediction named the wrong shape |
| 5 Reported | reorder20: `thr20` and `noloss` as `default`, `none` more | — |

## Conclusions

1. **What `moq-relay` loses to random loss is its BBRv3's loss response.** With both responses removed, 5–10 % loss costs 0.04 s, as through the CDN's relay, against 32.5–38.8 s at the default. The 2 % threshold carries nearly all of it: raised to 20 % alone, 0.05 s at 5 % and 0.52 s at 10 %.
2. **Removing it cost no content this rig could measure.** Below the feed's rate every BBRv3 arm lost 8.3–9.0 s, against the 7.8 s the missing capacity forces, and the `cake` dropped nothing: BBRv3's rate model, not its loss response, held the queue. Through the shallow bucket the patched arms lost no content while the bucket dropped 5–6 % as many packets as it delivered, against 0.3 % at the default. What a sender that ignores loss costs other flows on a shared bottleneck is untested, and is the case left against it.
3. **No controller is no remedy.** `none` rides the loss, but nothing bounds its retransmission: under 20 % reorder the 20 Mb/s `cake` dropped 7.6–8.9 packets for each it delivered, and below the feed's rate the backlog grew; in both, the export ended the session and lost 60–69 s.
4. **Reorder's cost is not the loss response:** 32–34 s in every BBRv3 arm, as T84's 31–36 s locally. [T28](test-28-failure-injection-matrix.md)'s relaxed loss-detection thresholds remain the one change measured to cut it (2.12–3.0 s, on noq); `moq-quic`'s packet threshold is fixed at 3.

## Limits, stated in advance

- One host and one synthetic last mile: Bernoulli loss and `netem` reorder.
- One flow per bottleneck, and `cake` isolates flows: what a sender that ignores loss costs other traffic is not measured.
- One lane at one column.

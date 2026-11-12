# T84 — The MoQ lanes through a CDN relay under T28's path faults

**State: run; every criterion holds.** Through the CDN's relay both MoQ lanes lose nothing to 5–10 % last-mile loss at either column, one cell in twenty-four aside, where `moq-relay` on the same client and paths loses 23–39 s of 40, and in eight cells the session: the relay decides the lane's loss, as the edge decides the segmented lane's. 20 % reorder still costs 13–15 s through the CDN's relay, against 31–36 s locally, and a 5 s outage 4–5 s at either column. Rigs: [`t84-moq-cell.sh`](scripts/t84-moq-cell.sh), [`t84-moq-grade.py`](scripts/t84-moq-grade.py), [`t84-moq-drive.py`](scripts/t84-moq-drive.py), [`t84-batch.sh`](scripts/t84-batch.sh), on [T72](test-72-segmented-cdn-edge-impairment.md)'s paths ([`t72-net.sh`](scripts/t72-net.sh)).

## Objective

Through a CloudFront edge the segmented lane's loss under last-mile faults is the edge's TCP's ([T72](test-72-segmented-cdn-edge-impairment.md)). A deployed MoQ lane's subscriber is served by a CDN's relay, whose QUIC the publisher neither sets nor sees. This experiment puts both MoQ lanes through a CDN-hosted moqx relay, impairs only the relay-to-subscriber path with T72's shapes at T72's columns, and asks whether the relay decides what the lane loses: each cell is run again through `moq-relay` on the subscriber's host, on the same client, fixture and paths ([Evidence](evidence.md) §3.3).

## Environment

|  |  |
| --- | --- |
| Source | A synthetic fixture, the only content the CDN's relay may carry: a test pattern and a tone, H.264 1080p25 at 8.3 Mb/s CBR with a 1.2 s GOP and B-frames, MP2 and AC-3, multiplexed at `contrib-10m.ts`'s 9.95 Mb/s on its PIDs, 240 s, PCR every 20 ms. It passes the T-STD on video and PSI; its audio is multiplexed 0.6–0.7 s ahead and overflows the audio buffer model, which nothing here grades. Replayed by `tsp regulate`, video PTS tapped by a fork (T28's tap). |
| Lanes | **demux**: `import ts` / `export ts --delay D`; **passthrough**: `import ts --passthrough` / `export ts --passthrough --delay D`. Client `d66c892833` at every end, raw QUIC, `moq-transport-18`, a broadcast new to each cell. One uncounted subscriber opens each broadcast first ([openmoq/moqx#795](https://github.com/openmoq/moqx/issues/795)). |
| Relays | **node**: the operator's three-thread moqx v0.3.7 node, in another region across the internet; publisher and anchor reach it unshaped from the subscriber host. **local**: `moq-relay` `d66c892833` on the subscriber host, its default controller (BBRv3), GSO off. |
| Path | T72's: two namespaces on the subscriber host. **Impaired**: 50 ms of netem in front of `cake` at 20 Mb/s on the downlink, 50 ms on the return, the shape applied at the netem. **Control**: unimpaired. Both legs run in every cell. |
| Columns | T72's: 5.91 s and 11.87 s, each matched by the export's delay on its control cell's median latency. The export runs at its delay plus an offset set at each session's join: 162 ms on the local relay and 212–415 ms through the node in the pilots. |
| Shapes | T72's: a 5 s outage from 20 s in a 60 s window; 5 % and 10 % loss, and 5 % and 20 % reorder (50 ms), from 20 s to 60 s of a 95 s window. Three replicates, replicate-major. |
| Graders | T68's content and latency instruments through [`t84-moq-grade.py`](scripts/t84-moq-grade.py) on each leg, [`t2831-conservation.py`](scripts/t2831-conservation.py) against the arm's control from 8 s; each namespace's UDP receive errors; the node's own counters over each cell's window. |

Cells, per relay and lane: **5.91 s**, control and all five shapes; **11.87 s**, control, outage and both losses. One more 5 % loss cell through the node, on the demultiplexed lane at 5.91 s, carries the impaired subscriber's qlog. The node's four arms run first, then the local relay's.

## Pass criteria, fixed before running

1. **Control.** Each arm's control loses no content, keeps its session to the stop, and matches its column within 100 ms. The export's delay moves by the control's miss, up to six controls; an arm still unmatched runs on the last delay and is reported with its latency.
2. **Control leg.** In every cell the unimpaired leg has no hole and keeps its session. A cell where it does not is void for the impaired leg, since the relay and not the path lost it, and is run once more.
3. **The path's loss.** The impaired netem's mean packet over each cell is at most 1,514 bytes, and neither namespace counts a UDP receive error.
4. **Conservation.** As T72: a cell with no hole conserves to its control's offset.
5. **Verdict**, per lane, shape and column on the median of three: **the relay's** if the node's missing programme differs from the local relay's by more than 2 s and by more than a quarter of the larger; **as local** otherwise. Each is set beside T28's MoQ row and T72's edge row at the same column.

**Prediction.** The local relay as T28's noq row, about 30 s lost to 5 % loss at 5.91 s; the node as the pilot's 5 % loss cell, which lost nothing. The outage costs both relays about what it cost T28's lane at 5.91 s, and nothing at 11.87 s.

## Results

The impaired leg's missing video, in seconds: the median of three, the range beside it where the replicates differ by more than 0.1 s. The verdict is criterion 5's (`t84-moq-drive.py compare`), demultiplexed lane first; T28's MoQ row and T72's edge row are at the same column.

| Column | Shape | Demux, node | Demux, local | Passthrough, node | Passthrough, local | Verdict | T28 MoQ | T72 edge |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 5.91 s | 5 s outage | 4.48 (4.04–4.52) | 7.56 (5.04–7.60) | 5.00 (4.88–5.04) | 7.12 (7.04–8.16) | the relay's, both | 7.04 | 8.84 |
| 5.91 s | 5 % loss | 0 | 28.08 (23.16–32.40) | 0.08 | 31.76 (27.56–31.80) | the relay's, both | 31.28 | 0 |
| 5.91 s | 10 % loss | 0 | 38.88 (36.36–39.00) | 0.04 (0.04–33.16 ²) | 37.24 (35.52–65.52 ¹) | the relay's, both | 37.76 | 0 |
| 5.91 s | 5 % reorder | 0 | 0.08 | 0.04 | −0.08 | as local, both | 0 | 0 |
| 5.91 s | 20 % reorder | 13.12 (11.16–15.16) | 35.76 (33.60–36.32) | 14.96 (14.16–15.16) | 31.48 (30.72–32.40) | the relay's, both | 36.76 | 0 |
| 11.87 s | 5 s outage | 4.08 (3.56–4.28) | 6.44 (3.00–6.44) | 4.28 (3.96–4.40) | 5.88 (5.72–6.04) | the relay's; as local | 6.12 | 0 |
| 11.87 s | 5 % loss | 0 | 26.88 (22.60–52.08 ¹) | 0.08 | 53.76 (52.52–54.56 ¹) | the relay's, both | 29.52 | 0 |
| 11.87 s | 10 % loss | 0 | 37.48 (36.16–37.52) | 0.08 | 59.04 (58.96–59.40 ¹) | the relay's, both | 37.24 | 0 |

¹ The impaired export ended before the stop, so the rest of the window counts as missing; its holes alone were 9.0–27.9 s. The demultiplexed export ended once, on "MPEG-TS output missed a decode deadline", and the passthrough export in seven cells, every loss cell at 11.87 s among them, on its source clock measured 79,000–326,000 ppm slow against the 30 ppm it follows. No session ended through the node. ² Over that replicate's loss the node's egress fell from 33 to 22.8 Mb/s and its sender was window-limited 1,820 times, against 346–455 in the other two; the subscriber skipped 109 groups.

Controls matched at 5,823.6–5,994.0 ms and 11,787.2–11,967.6 ms, seven arms on their first control and the node's demultiplexed 5.91 s arm on its third, and lost nothing. No control leg had a hole or lost its session in any of the 97 shaped cells, so none was void; the impaired netem's mean packet was 1,186–1,264 bytes, and neither namespace counted a UDP receive error. Each of the 36 shaped cells without a hole conserved to its control's offset within 0.1 s.

The node's counters, over each 40 s shape against the 20 s before it, node-wide (publisher, anchor and both legs): under 5–10 % loss it declared 1,357–4,062 packets lost and resent them, window-limited 184–455 times against a baseline of 333–528, so loss did not hold its sending back. Under 20 % reorder it declared 7,353–10,239 lost, 84–90 % of them later found spurious, and was window-limited 13,226–15,065 times, about 25 times its baseline. The impaired subscriber's qlog in the 5 % loss cell agrees: about 1,000 packets a second inside the loss as outside it, 5.0–5.3 % of the node's packet numbers missing in each full 10 s of the loss, smoothed RTT 111–117 ms. A sender that took loss for congestion could not hold 9.8 Mb/s there (about 0.5 Mb/s by the Mathis bound).

## Conclusions

1. **Criteria 1–4 hold**: every control matched and clean, every control leg clean, single-packet loss throughout, every lossless cell conserved.
2. **Under random loss the relay decides, on both lanes at both columns.** Through the CDN's relay 5–10 % last-mile loss costs nothing, as the segmented lane through CloudFront ([T72](test-72-segmented-cdn-edge-impairment.md)); through `moq-relay` on the same client, fixture and paths it costs 23–39 s at 5.91 s, T28's noq row: its default BBRv3 bounds what it has in flight once a round loses more than 2 % (`LOSS_THRESH`, read in the code, unchanged on `main` to mid-November; not traced). T28's MoQ loss under sustained loss is its relay's controller's, not the lane's, and on a deployed path that controller is the CDN operator's, which the publisher neither sets nor sees. The node's is not immune: it gave way in one passthrough cell at 10 %.
3. **Reorder costs both QUIC relays, less through the node.** 20 % reorder costs it 13–15 s against 31–36 s locally: it takes most reordered packets for lost and becomes window-limited. The edge's TCP lost nothing to it (T72). 5 % reorder costs neither.
4. **The outage is the lane's at both columns.** 4.1–5.0 s through the node and 5.9–7.6 s locally, beside T28's 6.12–7.04 s: the longer delay buys almost nothing, where the segmented lane and SRT lose nothing at 11.87 s. The prediction's "nothing at 11.87 s" was their figure; T28's MoQ row had lost 6.12 s there. The node's 1.6–3.1 s advantage clears the verdict's margin in three cells of four, narrowly.
5. **At 11.87 s the local exporters end the session under loss**: every passthrough loss cell and one demultiplexed. A recoverable under-delivery becomes the session's end through the exporters' clock-following and decode-deadline guards, so the local figures at 11.87 s are partly the exporters'. Through the node no session ended.

## Limits

- **One CDN relay.** The operator's three-thread moqx v0.3.7 node in one region; its controller is not exposed and its counters are node-wide. Another operator, or another configuration of this one, may decide otherwise.
- **One last mile, synthetic.** As T72: 20 Mb/s and 100 ms RTT, Bernoulli loss from a netem on the subscriber host. The node's legs carry about 11 ms more RTT than the local relay's.
- **One client build**, raw QUIC, `moq-transport-18`, on the synthetic fixture, not the live feed.

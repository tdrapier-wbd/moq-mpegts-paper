# T84 — The MoQ lanes through a CDN relay under T28's path faults

**State: running.** Rigs: [`t84-moq-cell.sh`](scripts/t84-moq-cell.sh), [`t84-moq-grade.py`](scripts/t84-moq-grade.py), [`t84-moq-drive.py`](scripts/t84-moq-drive.py), [`t84-batch.sh`](scripts/t84-batch.sh), on [T72](test-72-segmented-cdn-edge-impairment.md)'s paths ([`t72-net.sh`](scripts/t72-net.sh)).

## Objective

Through a CloudFront edge the segmented lane's loss under last-mile faults is the edge's TCP's ([T72](test-72-segmented-cdn-edge-impairment.md)). A deployed MoQ lane's subscriber is served by a CDN's relay, whose QUIC the operator neither sets nor sees. This experiment puts both MoQ lanes through a CDN-hosted moqx relay, impairs only the relay-to-subscriber path with T72's shapes at T72's columns, and asks whether the relay decides what the lane loses: each cell is run again through `moq-relay` on the subscriber's host, on the same client, fixture and paths ([Evidence](evidence.md) §3.3).

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

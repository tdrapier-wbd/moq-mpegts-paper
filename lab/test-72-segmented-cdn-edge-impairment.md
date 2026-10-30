# T72 — The segmented lane through a CDN edge under T28's path faults

**State: designed; criteria fixed before the first run.** Rigs:
[`t72-net.sh`](scripts/t72-net.sh), [`t72-cdn-cell.sh`](scripts/t72-cdn-cell.sh),
[`t72-cdn-drive.py`](scripts/t72-cdn-drive.py).

## Objective

[T68](test-68-segmented-chain-cushion-faults.md) part A found that at 100 ms RTT, matched on
latency, the segmented lane's loss is its origin's TCP controller's: nothing under 5–10 % loss on
BBR, 47–71 s of 95 on CUBIC. A deployed lane's receiver fetches from a CDN edge, so the controller
facing the last mile is the edge's, which the operator neither sets nor sees. This experiment puts a
CloudFront edge between origin and receiver, impairs only the edge-to-receiver path with T68's
shapes, and asks which of T68's rows the edge reproduces ([Evidence](evidence.md) §5 row 12).

## Environment

| | |
|---|---|
| Chain | T68's: `tsp regulate` replays `contrib-10m.ts` to multicast on `lo`; `t61-epochseg.py` (2 s epochs, program date-time); an nginx origin on the receiver host; CloudFront (one distribution, both pathways on that origin, playlist `max-age=0`, segments `max-age=60`, header-gated at the edge and at the origin); `b8-hls-recv.py` over HTTPS/1.1, holding each segment to its date-time plus 2.5 s; `mpegts-pacer` `97f3a38` `--stream-clock --on-stall mute`. |
| Path | Two namespaces on the receiver host, each behind NAT on its interface, the distribution's name pinned to one edge address in each. **Impaired**: T28's placement, 50 ms of netem in front of `cake` at 20 Mb/s on the downlink and 50 ms on the acknowledgements, the shape applied at the netem. **Control**: unimpaired. Both legs run in every cell. The host's receive offload is off, so the netem drops single packets rather than coalesced ones. |
| Arms | **cf**: both legs through the edge. **direct**: both legs from the origin over the same paths, the host's TCP on CUBIC, the rig's check against T68's CUBIC row. |
| Columns | T68's: 5.91 s (cushion from 3,460 ms) and 11.87 s (from 9,420 ms), each matched on its control cell's median latency to within 100 ms. |
| Shapes | T28's: a 5 s outage from 20 s in a 60 s window; 5 % and 10 % loss, and 5 % and 20 % reorder (50 ms), from 20 s to 60 s of a 95 s window. Three replicates, replicate-major. |
| Graders | T68's: [`t68-netns-grade.py`](scripts/t68-netns-grade.py) on each leg, [`t2831-conservation.py`](scripts/t2831-conservation.py) against the arm's control from 8 s, `t18-latency.py` over source and egress taps on one clock. |

Cells: **cf at 5.91 s**, control and all five shapes; **cf at 11.87 s**, control, outage and both
losses; **direct at 5.91 s**, control, outage and 5 % loss.

## Pass criteria, fixed before running

1. **Rig.** The direct arm reproduces T68's CUBIC row at 5.91 s: 5 % loss costs 50–75 s
   (T68: 62.88 s) and the outage 8–13 s (T68: 10.58 s). Otherwise the cf arm is not compared with T68.
2. **Control.** Each arm's control loses no content at the groomer, gives up no segment, and
   matches its column within 100 ms (T68's criteria 7, first half, and 9).
3. **Control leg.** In every cell the unimpaired leg has no hole and gives up no segment. A cell
   where it does is void for the impaired leg, since the edge and not the path lost it, and is run
   once more.
4. **Single-packet loss.** The impaired netem's mean packet over each cell is at most 1,514 bytes.
5. **Conservation.** As T68: a cell with no hole conserves to its control's offset.
6. **Verdict**, per shape and column on the median of three: **as BBR** if the edge's missing
   programme is within 2 s of T68's BBR row (0 s under loss and reorder); **as CUBIC** if within 25 %
   of T68's CUBIC row; **between** otherwise. The outage, which T68 ran on CUBIC alone, is set beside
   T68's CUBIC row and T28's MoQ and SRT rows.

The edge's point of presence and the viewer protocol are recorded with each arm.

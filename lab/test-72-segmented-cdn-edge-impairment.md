# T72 — The segmented lane through a CDN edge under T28's path faults

**State: run; every criterion holds.** Through a CloudFront edge the segmented lane loses nothing
under 5–10 % last-mile loss or 5–20 % reorder at 100 ms RTT, at either column: T68's BBR row, not
its CUBIC one. A 5 s outage still costs about 9 s at the 5.91 s column, which a 3.46 s cushion
cannot cover, and nothing at 11.87 s. Rigs: [`t72-net.sh`](scripts/t72-net.sh),
[`t72-cdn-cell.sh`](scripts/t72-cdn-cell.sh), [`t72-cdn-drive.py`](scripts/t72-cdn-drive.py).

## Objective

[T68](test-68-segmented-chain-cushion-faults.md) part A found that at 100 ms RTT, matched on
latency, the segmented lane's loss is its origin's TCP controller's: nothing under 5–10 % loss on
BBR, 47–71 s of 95 on CUBIC. A deployed lane's receiver fetches from a CDN edge, so the controller
facing the last mile is the edge's, which the operator neither sets nor sees. This experiment puts a
CloudFront edge between origin and receiver, impairs only the edge-to-receiver path with T68's
shapes, and asks which of T68's rows the edge reproduces ([Evidence](evidence.md) §3.3).

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

## Results

Every request in both edge arms was served by one Dublin point of presence, in the origin's region,
over HTTPS/1.1. Median video lost at the groomer's output over three replicates, conserved against
the arm's control (range in brackets), beside T68's and T28's rows at the same columns:

| Shape | 5.91 s, edge | 5.91 s, direct (CUBIC) | T68 5.91 s, CUBIC / BBR | 11.87 s, edge | T68 11.87 s, CUBIC / BBR | T28 MoQ / SRT, 5.91 s; 11.87 s |
|---|---|---|---|---|---|---|
| 5 s outage | 8.84 s (8.72–9.28) | 10.90 s (10.64–14.04) | 10.58 s / — | 0 | 0 / — | 7.04 / 0.18 s; 6.12 / 0 s |
| 5 % loss | 0 | 62.88 s (60.56–71.22) | 62.88 s / 0 | 0 | 47.58 s / 0 | 31.28 / 0 s; 29.52 / 0 s |
| 10 % loss | 0 (0–0.08) | — | 71.18 s / 0 | 0 | 54.08 s / 0 | 37.76 / 0 s; 37.24 / 0 s |
| 5 % reorder | 0 | — | 0 / 0 | — | 0 / 0 | 0 / 0 s |
| 20 % reorder | 0 | — | 0 / 0 | — | 0 / 0 | 36.76 / 0 s; 37.24 / 0 s |

Controls sat at 5,909.7–5,911.1 ms and 11,870.0 ms and lost nothing. The control leg had no hole and
gave up no segment in any of the 33 cells, so none was void, and the impaired netem's mean packet
was 1,489–1,511 bytes. A 0 conserves to the control's offset, within 0.1 s.

Under loss, the 99th-percentile fetch through the edge took 2.0–2.4 s and the slowest segment still
came at 5–14 Mb/s; from the origin on CUBIC the same cells took 25–32 s at 0.7–1.0 Mb/s, T68's
collapse. Before any shape, 7–15 % of segments reached the receiver after the 2.5 s hold through
the edge, against 33–43 % from the origin: T68's criterion 7 second half fails at this placement
either way, less often through the edge. After the outage the first segment arrived 5.2–5.7 s late
through the edge and 5.2–5.8 s from the origin (T68: 5.7 s): past a 3.46 s cushion, inside 9.42 s.
The impaired leg's segments were almost all edge cache hits, the control leg's requests the misses
that filled them, so the measured path is the edge's delivery; the fetch from origin to edge, a
millisecond away, is outside it.

## Conclusions

1. **Criterion 1 passes.** The direct arm reproduces T68's CUBIC row: 62.88 s at 5 % loss, as T68,
   and 10.90 s in the outage against 10.58 s. The rig measures what T68's did.
2. **Criteria 2–5 hold**: every control matched and clean, every control leg clean, single-packet
   loss throughout, every lossless cell conserved.
3. **Criterion 6: as BBR under loss, at both columns.** CloudFront's delivery to an impaired last
   mile behaves as T68's BBR origin did, not its CUBIC one: under 5–10 % loss the segmented lane
   loses nothing, as SRT, where T28's MoQ lane loses 29–38 s. Reorder does not discriminate: both of
   T68's rows lose nothing. The receiver cannot see the edge's controller; AWS states that its edges
   run BBR, which this matches.
4. **The outage is the cushion's, not the controller's.** Through the edge it costs 8.84 s at
   5.91 s, beside the origin's 10.58–10.90 s on CUBIC, T28's 7.04 s on MoQ and 0.18 s on SRT; at
   11.87 s, nothing, as on CUBIC and SRT.

## Limits

- **One CDN, one point of presence.** The result is CloudFront's: another CDN's edge may run a
  different controller, or choose one per client network.
- **One last mile, synthetic.** 20 Mb/s and 100 ms RTT, Bernoulli loss from a netem on the receiver
  host; a real access network's loss is burstier, and the edge's path to it longer than a
  millisecond.
- **HTTPS/1.1 over TCP.** HTTP/3 from the edge is not measured.

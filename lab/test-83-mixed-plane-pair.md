# Test 83: an SRT leg beside a MoQ or segmented-HTTP leg, merged or switched

**State: Parts A and B run on the MoQ legs; criteria 1–3, 5, 6 and 8 hold, and 7 is reported.** An SRT leg and an opaque leg merge without loss through every fault, inside an ST 2022-7 class only with SRT's latency matched; matched, a switch between SRT and the media-aware leg costs the background's hole, and unmatched skips 2.3–2.5 s toward the leading leg. The segmented arms of A and B are next, Part C after them, Part D on the author's approval, Part E with the IRDs of B-6.

## Objective

[Architecture](../docs/architecture.md) §5 measures redundant pairs within one data plane, and §11 offers a "transport-swappable hedge", a managed transport kept beside the new plane for the most critical routes, by reasoning only. An interim deployment would run the proven point-to-point leg (SRT, or AWS MediaConnect's) beside a MoQ or segmented-HTTP leg of the same source, and protect each with the other. No pair has mixed planes. This test asks:

- **Part A, merge:** do an SRT leg and an opaque MoQ leg of one source, each through its own stream-clocked groomer, emit the same RTP datagrams, and does an ST 2022-7 receiver merge them hitlessly through each leg's faults? The same for an SRT leg and a segmented leg, as packaged and with the packager's added tables removed.
- **Part B, switch:** across an SRT leg and a media-aware MoQ leg, and an SRT leg and a segmented leg, what does [T80](test-80-video-aware-receiver-switch.md)'s switch cost at a fault and at a commanded cut, with SRT's latency matched to the other leg's and not, and what changes in the tables at the cut?
- **Part C, shadow:** over 72 h of the live feed, does each new-plane leg deliver what the SRT leg delivers?
- **Part D:** Part B's matched cells and 24 h of Part C with a MediaConnect flow as the SRT leg.
- **Part E:** an IRD's own input switch between the SRT and a new-plane send of [`srt-send.sh`](scripts/srt-send.sh), and a hardware ST 2022-7 merge of Part A's pair.

## Predictions, stated before running

- **A, opaque:** identical datagrams. Both legs carry the source's packets verbatim, continuity counters included ([T4](test-4-remote-e2e-srt.md), [T48](test-48-passthrough-export.md)), and the stream-clocked groomer takes each packet's slot from the stream, not from its arrival (Architecture §5.1), so the pair merges wherever the legs' delay difference fits the receiver's window.
- **A, segmented:** not mergeable as packaged, since `tsp -O hls` adds a PAT/PMT pair to each segment under its own counters ([Evidence](evidence.md) §3.1); identical once that pair is removed, if nothing else differs.
- **B:** with the legs arriving within 0.3 s, T80's result: no decoder hole beyond the stream's own and at most two frames repeated. Unmatched, a repeat or a hole of the lag, since T80's switch pairs by arrival. At each cut the decoder sees the source's tables give way to the export's, or the reverse, which a software decoder ignores.

## Environment

| Component | Build |
| --- | --- |
| `moq`, `moq-relay` | upstream `main` under test at the run, recorded with each run |
| Groomer | `mpegts-pacer` `v0.1.0` `--rtp --stream-clock` at the clip's rate, one per leg, SSRC and sequence seed set per pair |
| SRT leg | `tsp --realtime -I file -O srt --caller` to `tsp -I srt --listener`, latency per cell: 1,000 ms, or matched to the other leg's measured latency as [T28](test-28-failure-injection-matrix.md) matched it |
| Opaque leg | `import ts --passthrough`, its own relay, `export ts --passthrough`, as [`t12-opaque-late.sh`](scripts/t12-opaque-late.sh)'s legs |
| Media-aware leg | `import ts`, its own relay, `export ts --stitch --follow` under a supervisor, as [T81](test-81-gateway-failover.md)'s legs |
| Segmented leg | `tsp -O hls` into an origin, `b8-hls-recv.py` held to each segment's program date-time, as `srt-send.sh`'s `seg` lane |
| Merge | [`t12-merge-oracle.py`](scripts/t12-merge-oracle.py), the ST 2022-7 selection rules, its window per cell |
| Switch | [`t80-vswitch.py`](scripts/t80-vswitch.py) in `lookback` mode, 202 ms of video silence, 2,000 ms hold, before one groomer; a commanded cut added before the first run, with its own control |
| Source | `contrib-10m.ts` for Parts A, B and D; the live feed for C and E, graded as it runs and not recorded unattended |
| Hosts | A and B on one host, loopback, then the primary and secondary; C on the secondary's lanes; D in the AWS region of the hosts |

## Procedure

**Part A.** A rig derived from `t12-opaque-late.sh`: leg A is the SRT leg fed from the reference tee, leg B the opaque leg, each into its own groomer, one packet capture of both. Cells, three runs each, at both SRT latencies: control; each leg dark 15 s and back; each leg's receiver or export killed; each leg joining 8 s late; the SRT sender restarted; the opaque leg's relay restarted. Graded as that rig grades: `t12-merge-oracle.py` on the capture, then `ts-passthrough-identity.py` of the merged output against the reference; the legs' datagram identity and delay difference are read from the same capture. Then the same cells with leg B the segmented leg, as packaged and through a stage that drops the packager's added PAT/PMT pair, the stage built and given its own controls first.

Fixed before the first graded run: the rig is [`t83-mixed-merge.sh`](scripts/t83-mixed-merge.sh), driven by [`t83a-batch.sh`](scripts/t83a-batch.sh). The clip is paced once onto a loopback multicast group that the reference tap, the SRT sender and the importer each read; the SRT sender, its receiver and the importer restart 1 s after they exit, the export does not. Runs last 90 s, faults strike at 40 s. The matched SRT latency is 2,022 ms: 1,000 ms plus the 1,022 ms by which the opaque leg trailed the SRT leg in a 60 s control at 1,000 ms.

**Part B.** The SRT leg and the media-aware leg into the switch, then one groomer, then a recorder, faulted at 30 s and restored at 45 s as T81's cells: each leg's outage, kill and return, and a commanded cut in each direction with both legs healthy. Three runs a cell, at both SRT latencies. Graded as T80 ([`t56-grade.py`](scripts/t56-grade.py)), and across each cut a table diff: PAT, PMT and its version, SDT, NIT, EIT, the PIDs carried, and the SCTE-35 PID's sections. Then the SRT and segmented legs.

Fixed before the first graded run: the rig is [`t83-mixed-switch.sh`](scripts/t83-mixed-switch.sh), driven by [`t83b-batch.sh`](scripts/t83b-batch.sh). The clip is paced once to a loopback port and tapped, and the SRT sender and the importer read the tap as it grows. The switch is T80's `lookback` (τ = 202 ms, 2 s hold), then one arrival-clocked groomer and the recorder. A fault strikes the leg the switch is serving, so each cell starts the switch on the leg it faults. The commanded cut is a signal to the switch, planned as a fault's cut is, with the serving leg's last video packet as the silence instant. Its controls run first, three runs each: T80's `lookback` kill cell on T58's rig, and the commanded cut between two media-aware legs. The matched SRT latency is 2,215 ms: 1,000 ms plus the 1,215 ms by which the media-aware leg trailed the SRT leg in a 75 s control at 1,000 ms ([`t83-leg-lag.py`](scripts/t83-leg-lag.py); 1,163–1,265 ms in each 5 s after the first). Each event is graded by `t56-grade.py` on the recording, with detection read from `events.txt`, and each cut by [`t83-tables.py`](scripts/t83-tables.py) on the switch's output.

**Part C.** On one receiving host, `srt-send.sh`'s `rx` lane as the reference beside `ma`, `pt` and `seg`, for 72 h. A grader built for it reports per leg and per hour the TR 101 290 P1/P2 errors and the content each leg lacks against `rx`, matched by PTS on every video and audio unit. Its controls: `rx` against itself, and a copy of one lane with units removed at known places.

**Part D.** The source sent once into a MediaConnect flow, whose SRT output replaces leg A; Part B's matched cells, then 24 h of Part C. Its cost is priced and approved before anything is created.

**Part E.** The IRD's two inputs on `srt-send.sh`'s `rx` and `ma` lanes: a cut it is commanded to make, and a lane stopped with `srt-send.sh stop ma`. If a hardware ST 2022-7 receiver is available, Part A's opaque pair into it.

## Pass criteria, fixed before running

1. **Valid (A).** Each control loses nothing. The oracle merges T12's same-plane opaque pair with no loss (positive control) and grades an arrival-clocked groomer pair unmergeable (negative control).
2. **Identity (A).** On the control, at least 99.99 % of the datagrams that share a sequence number are byte-identical, RTP header and payload, between the SRT and the opaque leg.
3. **Hitless (A).** In every fault cell the merged output has no lost datagram and no continuity error, with the legs' delay difference inside the oracle's window. The difference is reported with the ST 2022-7 class it fits.
4. **Segmented (A).** Identity reported as packaged and with the added pair removed; criterion 3 graded on the second.
5. **Valid (B).** Each control's decoder hole is the background's, and T80's same-plane `lookback` cell reproduces on the build under test.
6. **Matched (B).** At each fault and each commanded cut: no decoder hole beyond the background's, no corrupt picture, at most two frames repeated.
7. **Unmatched (B).** Reported, not graded: the hole or the repeat against the legs' lag.
8. **Tables (B).** Every table, version and PID that differs across each cut listed; no SCTE-35 section lost across a cut.
9. **Valid (C).** The grader names every unit removed from the negative control and none from the positive.
10. **Shadow (C).** Every content difference between a new-plane leg and `rx` attributed to one leg and a cause; none left unexplained.
11. **MediaConnect (D).** Criteria 6, 8 and 10 with the flow as the SRT leg.
12. **Hardware (E).** Reported: the IRD's picture, sound, alarms and re-lock time at each cut, with the analyser's P1/P2 across it; the hardware merge against criterion 3.

## Limits, fixed in advance

- A software decoder and a reference merge until Part E; whether an IRD rides a cut whose tables change is Part E's alone.
- One clip, one host first; the cross-host repeat is one path.
- Until Part D the SRT leg is TSDuck's sender, and MediaConnect's may handle latency and loss differently.
- Within its plane the opaque pair leaves its importer single ([Architecture](../docs/architecture.md) §5.2); here the SRT leg, with its own ingest, covers that importer, so Part A cannot show what the importer's loss costs a same-plane pair.

## Results

### Part A: the two legs are one set of datagrams, merged without loss through every fault, and inside an ST 2022-7 class only when matched

`main` `cd560bde5e`, one host, loopback, `contrib-10m.ts`; 60 runs, all valid. Datagrams from leg B span both latencies' six runs. Skew is leg B's delay less leg A's at the matched 2,022 ms, in milliseconds; the class is each run's largest excursion against Class A's 10 ms, B's 50 ms and C's 450 ms.

| Cell | Datagrams from leg B | Run medians | Largest | Class, per run |
| --- | --- | --- | --- | --- |
| control | 0–21 | −21.8 to 2.8 | 25.3 | A, B, B |
| leg A dark 15 s | 13,512–13,581 | −21.9 to −21.7 | 53.0 | B, B, C |
| leg B dark 15 s | 0 | −21.9 to 3.5 | 48.4 | A, A, B |
| leg A's receiver killed, the leg ending | 44,809–45,789 | −21.9 to 2.2 | 24.0 | A, B, B |
| leg B's export killed, the leg ending | 0 | −22.0 to 2.7 | 24.0 | A, B, B |
| leg A 8 s late | 0 | 1.8 to 2.1 | 29.9 | A, A, B |
| leg B 8 s late | 0–20 | −20.8 to 3.4 | 22.7 | A, B, B |
| SRT sender restarted | 5,032–5,195 | −21.9 to −21.8 | 48.6 | B, B, B |
| opaque relay restarted | 0 | −21.7 to 2.4 | 23.8 | A, B, B |

- **Criterion 1 holds.** T12's opaque pair merged in all three runs, 74,986 datagrams matched and none mismatched or lost; the arrival-clocked pair was unmergeable in all three, 1.5–1.7 % of the datagrams sharing a sequence number identical. No mixed control lost a datagram.
- **Criterion 2 holds.** In the six mixed controls every datagram sharing a sequence number was byte-identical, RTP header and payload, and the merged output was the reference's packets in order.
- **Criterion 3 holds at both latencies; the difference fits a class only when matched.** In all 48 fault runs the merge lost no datagram, with no continuity error, no conflict and nothing missing or foreign against the reference; each leg covered the other's fault. At 1,000 ms every run's skew lay between 973 and 1,048 ms, beyond Class C: the oracle's sequence merge has no time limit, and a 2022-7 receiver would follow one leg. At 2,022 ms the fault runs fit Class A in 8 of 24, B in 15 and C in one.
- **The skew sits on two levels 24.5 ms apart**, 1,000 or 1,025 ms unmatched and −22 or +3 ms matched; each run's median takes one, a few runs visit both, and the level decides Class A or B. Not traced.
- **Criterion 4 not run.** The segmented arm needs its PAT/PMT-dropping stage and that stage's controls first.
- **The opaque prediction holds:** the legs are identical datagrams, merged wherever their difference fits the receiver.

### Part B: matched, the switch cuts between SRT and the media-aware leg at the background's cost; unmatched, it repeats a little one way and skips 2.3–2.5 s the other

`main` `cd560bde5e`, one host, loopback, `contrib-10m.ts`; 42 runs, all valid. Leg A is SRT, leg B media-aware. Times in seconds; a fault's background is the hole before it on the leg the switch served, 0.57 on leg A and 0.21 on leg B; programme lost is negative when repeated.

| Event, three runs each | Detection | Hole (background) | Programme lost | Bad pictures |
| --- | --- | --- | --- | --- |
| Matched, 2,215 ms (legs within 54 ms) |  |  |  |  |
| SRT leg's outage or kill | 2.43 | 0.21 (0.57) | 0 | 0 |
| media-aware leg's outage or kill | 2.08 | 0.22 (0.21) | 0 | 0 |
| commanded cut, SRT → media-aware | — | 0.21 (0.57) | 0 | 0 |
| commanded cut, media-aware → SRT | — | 0.21 | 0 | 0 |
| Unmatched, 1,000 ms (leg B 1.18–1.22 s behind) |  |  |  |  |
| SRT leg's outage or kill | 1.12–1.22 | 0.93 (0.57) | −0.12 | 0 |
| media-aware leg's outage or kill | 2.08 | 1.53 (0.21) | **2.48** | 0 |
| commanded cut, SRT → media-aware | — | 1.10 (0.57) | −0.08 | 0 |
| commanded cut, media-aware → SRT | — | 1.31 (0.21) | **2.32** | 0 |

- **Criterion 5 holds.** T80's kill cell reproduced in all three runs: detection 2.14–2.15 s against T80's 2.11, hole 0.22–0.23 s against 0.20 before, no programme lost, no bad picture. The commanded cut between two media-aware legs cost 0.22–0.23 s against 0.20–0.21 before, nothing lost, no table change, in all six cuts. The six runs with no event made no cut.
- **Criterion 6 holds.** In all 18 matched events the hole was within its background plus 0.1 s, no picture was bad, and no programme was lost or repeated. The grader read no background before a cut back to SRT; the 0.21 s hole there is under leg B's own.
- **Criterion 7, reported:** toward the lagging leg the 2 s hold absorbs most of the 1.2 s lag, repeating 0.08–0.12 s, while toward the leading leg the switch skips 2.3–2.5 s, about twice the lag, and at its faults one SCTE-35 PID's cadence misses a slot.
- **Criterion 8 holds.** Every cut between the planes changes two tables, both ways and at both latencies: the export's PAT lists programme 0 (the network PID, 16) where the source's does not, and PMT 100's version is 0 against the source's 6, its PCR PID, streams and stream types unchanged. No PID is added or dropped. The clip's one distinct SCTE-35 section, repeated about every 975 ms on three PIDs, was lost at no cut.
- **The B prediction holds matched and fails unmatched.** Matched, the switch costs T80's result with nothing repeated. Unmatched, it is not the lag as predicted: the hold absorbs it one way and doubles it the other. The table change is the one predicted, and FFmpeg decodes through it.
- **Output latency drifts, untraced.** In the four runs read whole that start on the SRT leg, of 18, the recording's latency falls by about 0.047 s per second from the first cut to the media-aware leg, about 2 s by the run's end, and in the one with a cut back it keeps falling; one run starting on the media-aware leg, T80's control and the same-plane cut stay within 0.5 s. No criterion grades it.
- **Two grader limits.** Where a cut's hole is no larger than the background's gaps, `t56-grade.py` resumes at the largest gap in the next 15–20 s, so its latency step there reads the drift and the next event gets no background. Its single bad pictures, at returns where the switch did not cut and once in the same-plane control, are not stable: the control's did not recur when its run was graded again, and seven runs read whole showed isolated bad pictures 9–31 s from any event, consistent with FFmpeg concealing the recordings' 8–10 continuity errors outside any switch differently between decodes.

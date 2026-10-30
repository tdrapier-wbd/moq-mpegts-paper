# Test 71 — The latency ordering on a long, lossy path

**State: protocol fixed; not yet run.** Rig: [`t71-origin.sh`](scripts/t71-origin.sh) on the origin,
[`t71-far.sh`](scripts/t71-far.sh) on the receiver, one cell by [`t71-cell.sh`](scripts/t71-cell.sh),
graded by [`t71-grade.py`](scripts/t71-grade.py).

## Objective

P1-ad. Every latency ordering the campaign holds is loopback or one 12.8 ms internet path
([T18](test-18-delivery-latency.md), [T70](test-70-segmented-latency-budget.md); [Evidence](evidence.md)
§3.11), where the path costs its round trip and nothing else. A long, lossy path is the case that
should favour the tunnels: SRT retransmits inside a fixed buffer and sends at the source's rate
whatever it loses, while both MoQ lanes ride a congestion-controlled QUIC connection whose recovery
costs round trips. This test runs SRT and both MoQ lanes, each in its conformant configuration at the
same 1 s budget, from the primary to a host about 120 ms away, clean and at two random-loss rates,
and asks whether the ordering holds, and at what latency and delivered programme.

## Environment

| | |
|---|---|
| Origin | the EC2 primary (eu-west-1), beside its standing units, which it does not touch: `contrib-10m.ts` from its start each cell, `tsp -P regulate --pcr-synchronous --wait-min 5`, the video PTS tapped by a mirrored fork in the same process as the transmitter; its own `moq-relay` on UDP 4711, open, `--quic-congestion-control delay` (BBRv3) |
| Receiver | an on-demand c6in.2xlarge in us-west-2 (Ubuntu 26.04), running nothing else; the receive stage's stdout tapped inline by `t18-latency.py` and saved |
| Path | the open internet between the two regions; round trip from the clock probe's lowest-delay sample |
| Impairment | `netem` random loss on the receiver, on the lanes' flows only (UDP to and from the origin's relay and SRT ports, not the clock probe or the shell's session): ingress through an `ifb`, egress through a `prio` band, the same rate each way; GRO off on the receiver, `--quic-gso=false` on the subscriber; clean cells pass the same qdiscs at 0 %; applied loss read from netem's counters per cell |
| SRT | TSDuck `srt`, the origin listening and the receiver calling, `--latency 1000` both ends |
| MoQ, opaque lane | `moq import ts --passthrough`, relay, `moq export ts --passthrough --delay 1s` |
| MoQ, media-aware lane | `moq import ts`, relay, `moq export ts --delay 1s` (the fixed-delay export, padded to the catalog's rate) |
| MoQ build | `main` `66af72315` (`moq-lite-06`) on both hosts; WebSocket fallback off |
| TSDuck | 3.44 |
| Clock | both hosts' chrony on Amazon Time Sync, read before and after each cell: the latency is uncorrected, and its bound is the sum of the two hosts' offset and root distance. `t18-latency.py clock-server` on the origin (UDP 9710), probed 30 times before and after each cell, as a cross-check and for the round trip |
| Graders | `t18-latency.py report` (30 s settle); TSDuck `continuity`, `pcrverify --absolute --jitter-max 13` and PCR repetition from `pcrextract`, as T18; [`t28-content-lost.py`](scripts/t28-content-lost.py) on video and the busiest audio from 8 s; [`ts-passthrough-identity.py`](scripts/ts-passthrough-identity.py) on SRT and the opaque lane; [`ts-tstd.py`](scripts/ts-tstd.py) `--skip 8` on clean cells |

## Procedure

A cell is 120 s of the receive stage's output: the impairment set, both clocks read, the origin's
source started, the receiver run, the clocks read again, the source stopped, the counters read and
the impairment cleared. Broadcast names are unique per cell. Captures are graded on the receiver
after the matrix, never beside a running cell.

The matrix: three lanes × {clean, 0.1 %, 1 %} × three replicates, 27 cells, in three rounds. Each
round runs the conditions in order and, within each, the lanes in an order rotated per round, so
that drift on the path falls on every lane alike. A 40 s smoke cell per lane checks the rig first,
ungraded. Diagnostic, labelled and not ranked: both MoQ lanes at 0.1 % and 1 % with the relay on
CUBIC (`loss`), one cell each, because the controller decides how a QUIC sender meets random loss.

```bash
# origin, once: the relay and the clock reference
bash ~/t71/scripts/t71-origin.sh relay-up ~/t71/fix
bash ~/t71/scripts/t71-origin.sh clock-up ~/t71/fix
# laptop: one cell (lane srt|opaque|aware, loss in %)
ORIGIN_IP=<EC2_IP> ORIGIN=<origin-host> FAR=<far-host> \
	bash lab/scripts/t71-cell.sh <round>-<lane>-<loss> <lane> <loss> 120
# receiver, after the matrix
python3 ~/t71/scripts/t71-grade.py ~/t71/runs/<cell> --lane <lane> [--tstd]
```

## Pass criteria, fixed before running

1. **The path is the one asked for.** The probe's lowest-delay round trip is 80–150 ms on every
   cell. netem's counters on the lanes' flows read zero drops on clean cells, and on loss cells the
   applied rate each way is within ±30 % of the commanded one, or the cell is labelled with what was
   applied.
2. **The clock is bounded.** Before and after every cell both hosts' chrony is synchronised to
   Amazon Time Sync, and the sum of the two hosts' |offset| + root distance is at most 5 ms; that
   sum is the cell's latency bound. The probe's offset agrees with zero within its own uncertainty.
   A cell failing either is re-run once, then reported.
3. **The same picture, proved.** The recovered PTS shift is constant within each lane, and on clean
   cells at least 99 % of egress pictures match a source picture.
4. **Equal conformance on the clean path.** On every clean cell each lane's egress has 0 continuity
   errors and 0 PCR intervals over 40 ms, and `ts-tstd.py` passes it from 8 s. PCR accuracy
   (±481 ns) is reported, not gated: the media-aware export misses it by design
   ([T47](test-47-fixed-delay-export.md)). A lane failing on its clean cells is reported and not
   ranked.
5. **Delivered programme.** Per cell: video and audio content lost from 8 s (100 ms tolerance) and,
   on SRT and the opaque lane, identity gaps and foreign packets. A cell whose receive stage exits
   early is graded on what it delivered, with the time it stopped.
6. **The ordering, graded either way.** The clean cells' order of median latency is the reference.
   It survives a loss rate if every lane delivers its whole programme there (no content lost beyond
   tolerance, no continuity error) in all three replicates and the order of medians is unchanged. A
   lane that loses programme or conformance is ranked failing at that rate, whatever its latency.
   Quoted per lane and condition: the median of the three cells' medians, their range, the p95 and
   the clock bound.

*Predicted.* Clean: SRT about 1.1 s, its buffer plus about a round trip; both MoQ lanes about
1.1–1.2 s, the delay plus the one-way transit and the export's ordering. At an equal budget no lane
should lead by much. At 0.1 % all three should deliver everything at their clean latency. At 1 %,
SRT's buffer covers about eight round trips of retransmission and it should deliver everything;
BBRv3 does not back off at 1 % random loss, so both MoQ lanes should keep the rate, but a picture
whose retransmission is lost again costs further round trips, the export drops what misses its
delay, and T47 had the media-aware export stop between 2 % and 3 % at 1 s on a 50 ms path. On CUBIC
the MoQ lanes should not sustain 10 Mb/s at 1 % on this round trip: a Reno-like sender's loss bound
there is about 1 Mb/s.

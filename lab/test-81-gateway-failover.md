# Test 81: a gateway's failure behind an IRD's input switch, on the media-aware lane

**State: run and graded; every criterion with a mark holds.** A gateway's death cost a decoder behind the IRD model's input switch 1.1–1.2 s of picture with either switch model, and stepped the PCR back 0.12–0.25 s against arrival with no discontinuity indicator. Its return cost nothing, and a leg's fault behind the groomer cost what no fault costs.

## Objective

[Architecture](../docs/architecture.md) §5.2 doubles the receive chain: two edge gateways each switch both legs of the media-aware lane and feed both IRDs. The two gateways' outputs are not the same transport, so an IRD chooses between them by its own input switch, not by a merge, and a gateway's failure costs that switch. [T80](test-80-video-aware-receiver-switch.md) measured the gateway's switch alone, writing to a recorder; no groomer stood behind it and no second gateway beside it. This test asks, on T80's legs and switch:

- **Part A:** what does a whole gateway's failure cost a decoder behind an IRD-model input switch between two gateways, and is the gateway's return free?
- **Part B:** does T80's result for a leg's fault, behind the 2 s hold, survive a groomer between the switch and the IRD?

## Environment

| Component | Build |
| --- | --- |
| `moq`, `moq-relay` | upstream `main` at `2460728a2` (`~/bin-2460728a-thin`), recorded with each run |
| Gateway switch | [`t80-vswitch.py`](scripts/t80-vswitch.py) in T80's `lookback` mode: 202 ms of video silence, 2,000 ms hold |
| Groomer | `mpegts-pacer` `v0.1.0` (`97f3a38`), 11,000,000 b/s, RTP, `--latency-ms 1000 --max-latency-ms 8000 --stall-ms 1000 --on-stall mute`, PCR regenerated |
| IRD model | `tsswitch` (TSDuck 3.45) `--fast-switch --receive-timeout 500` on the two groomers' RTP, cutting on absence anywhere; or `t80-vswitch.py` in `rap` mode (200 ms, no hold) on the same inputs through `tsp -I ip`, a switch that detects video silence and cuts at a keyframe |
| Host | the laptop, loopback; no other timing work and no build during a run |
| Source | T58's one source: `contrib-10m.ts` (1080i H.264, 9.95 Mb/s CBR, an I-frame every 1.2 s, open GOP) played live to a file each importer follows from its own start |
| Legs | T58's: leg A and leg B, each an importer, its own relay and its own broadcast, with a 6 s QUIC idle timeout |
| Gateways | gateway 1 and gateway 2, each with its own `export ts --stitch --follow 10s --delay 2s` of each leg under a supervisor, its own switch and its own groomer; gateway 2's exports start 1 s after gateway 1's |

## Procedure

[`t81-gateway-failover.sh`](scripts/t81-gateway-failover.sh). Importer A starts at 0 s, the gateways' exports of leg A at 2 and 3 s, of leg B at 7 and 8 s, importer B at 8 s. The IRD model starts at 14 s on gateway 1, once both groomers send. At 30 s the rig fails one thing and restores it 15 s later; 75 s a run. Recorded with arrival times: the IRD model's output (`sub1`) and each gateway's switch output before its groomer (`gw1`, `gw2`). One shakedown run per cell precedes the matrix and is not graded.

| Cell | The fault at 30 s | Restored at 45 s | IRD model | Runs |
| --- | --- | --- | --- | --: |
| `gw` | gateway 1 killed whole: its exports, supervisors, switch and groomer | gateway 1 restarted | `tsswitch` | 3 |
| `gw-rap` | as `gw` | as `gw` | `vswitch` `rap` | 3 |
| `leg` | importer A, the leg both gateways serve, SIGKILLed | importer A restarted | `tsswitch` | 3 |
| `none` | nothing (the negative control) | — | `tsswitch` | 1 |
| positive control | T58's `kill` with `tsswitch` at 500 ms on the legs, no gateway ([`t58-receiver-select.sh`](scripts/t58-receiver-select.sh)) | as T58 | — | 1 |

Each run is graded by [`t56-grade.py`](scripts/t56-grade.py) `--caps sub1,gw2 --arrive` against the source: per event the stall, the decoder hole beside the same before it, the programme lost or repeated, the latency step and the bad pictures. At the IRD model's cut, the step in PCR against the packet count is read from `sub1` by [`t81-pcr-step.py`](scripts/t81-pcr-step.py), which reported no step on the first 15 s of a groomer's output and exactly +10 ms then −10 ms at each PCR `pcr-perturb.py --every 500 --ticks 270000` moved.

## Pass criteria, fixed before running

1. **Void** unless every event time is in `events.txt`, `sub1` and `gw2` cover the run to within 3 s of its end, the source tap shows no continuity error, each gateway's switch log names a video PID on both inputs, and the IRD model starts on gateway 1.
2. **Controls.** _Negative:_ in `none` the IRD model makes no switch, neither gateway cuts after leg B's arrival, and `sub1`'s decoder hole after the IRD model's start stays within its hole before plus 0.1 s. _Positive:_ T58's `kill` costs a decoder hole over 1 s, as in T58 and T80.
3. **A1, the cost of a gateway's failure,** measured, no pass mark: per IRD model, the median and worst of three of the detection (the kill to the IRD model's switch), the decoder hole, the programme lost or repeated, the bad pictures and the PCR step at the cut.
4. **A2, a gateway's return is free:** in `gw` and `gw-rap`, gateway 1's restart causes no IRD switch and no decoder hole on `sub1` beyond its hole before plus 0.1 s, in all three runs.
5. **B1, a leg's fault behind the groomer:** in `leg`, the IRD model makes no switch, and on `sub1` the fault costs a decoder hole within its hole before plus 0.1 s, a programme lost or repeated of at most two frames (0.08 s) and no bad picture, in all three runs: T80's `lookback` result through a groomer.

_Predicted:_ A1 with `tsswitch`: about T58's cost, 1–3 s of hole and broken pictures to the next keyframe, since it cuts mid-picture into a groomer whose PCR has its own origin; with `rap`, under T80's `rap` bound of 2.3 s and no hole longer than a GOP plus the detection. A2 holds (non-revertive). B1 holds.

## Limits, fixed in advance

- `tsswitch` and `t80-vswitch.py` model an IRD's input redundancy; neither is a product. How a given IRD switches inputs, and what its clock does when the other input's PCR has another origin, are its own and unmeasured here; FFmpeg, the decoder, recovers no clock from the PCR, so the PCR step is reported rather than seen.
- A gateway killed as processes on one host stands in for a gateway host lost; both gateways share the host, the source file and loopback.
- One clip, one GOP structure, as T80.

## Results

`moq` 0.14.2 and `moq-relay` 0.17.2 from the environment's build, on the laptop, eleven runs in sequence with nothing else timed.

**A gateway's death.** Median, with the worst of three in brackets; seconds unless marked. _Outage_ is the decoder hole that a blip of pictures inside it does not split; _bad_ is the range of corrupt pictures after the cut. The PCR step is against the packet count, as fixed, and, beyond the criteria, against `sub1`'s arrival times, whose index resolves about 25 ms (the `none` run's largest reading, 22 ms).

| IRD model | Detection | Stall | Outage | Programme lost | Bad | Latency step | PCR step, packets | PCR step, arrival |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `tsswitch`, 500 ms | 0.53 (0.53) | 0.51 (0.51) | 1.17 (1.23) | 0.36 (0.36) | 16–21 | 0.12 (0.18) | +319 ms (+342) | −173 ms (−249) |
| `vswitch` `rap` | 0.17 (0.17) | 0.97 (1.00) | 1.20 (1.20) | 0.88 (0.88) | 4–8 | 0.15 (0.16) | +817 ms (+879) | −154 ms (−167) |

Each run shows one PCR step, at the cut, and none carries the discontinuity indicator. Gateway 2's own output (`gw2`) lost nothing at gateway 1's death in any run, a 0.22–0.23 s hole against 0.19–0.21 s before it. The IRD model's cut leaves 3–4 continuity errors on `sub1` with `tsswitch` and 6–7 with `rap`.

**The return, a leg's fault and no fault.** Decoder hole, with the same before the event in brackets; no event here made an IRD switch.

| Cell, event | Runs | Decoder hole | Programme | Bad |
| --- | --: | --- | --- | --- |
| `gw`, `gw-rap`: gateway 1 restarted | 6 | 0.223–0.224 (0.229–0.231) | 0 | 0 |
| `leg`: importer A killed | 3 | 0.229–0.230 (0.205–0.206) | 0 | 0 |
| `leg`: importer A restarted | 3 | 0.224 (0.203–0.204) | 0 | 0 |
| `none`: nothing, graded at the same times | 1 | 0.229 (0.205) | 0 | 0 |

At importer A's kill both gateways cut to leg B, 2.05–2.12 s and 2.17–2.28 s after it, and each cut left 10 continuity errors, which the groomer passed on: 10 on `sub1` and 10 on `gw2` in every `leg` run. The `none` run has none.

## Grading

1. **No run is void.** Every event time is in `events.txt`, the grader's void checks pass on all eleven, each gateway's switch log names video PID 111 on both inputs, and the IRD model starts on gateway 1 in all ten T81 runs.
2. **Both controls hold.** _Negative:_ in `none` the IRD model made no switch, neither gateway decided a cut, and graded at the fault cells' times `sub1`'s hole was 0.229 s against 0.205 s before, with no continuity error and no PCR step over 1 ms. _Positive:_ T58's `kill` cost a 2.24 s hole and 2.12 s of programme after a 3.39 s detection, against T58's 2.24 (2.85), 1.80 (2.12) and 3.34 (3.50).
3. **A1 is measured** (the first table). Against the prediction, `tsswitch` cost the bottom of the predicted 1–3 s, and `rap` stayed inside its bounds.
4. **A2 holds** in all six runs.
5. **B1 holds** in all three runs: no IRD switch, a hole 0.024 s over the one before it against a 0.1 s bar, no programme lost and no bad picture.

## Conclusions

- **A gateway's death costs about 1.2 s of picture whichever way the IRD switches; how it switches decides the rest.** A dead gateway's groomer falls silent at once, so `tsswitch` cut at its receive timeout, not after the 3.3 s T58's switch waited while a killed leg's export drained. Cutting mid-picture, it broke 16–21 pictures and lost 0.36 s. Cutting at the other gateway's next keyframe, `rap` decided in 0.17 s, then waited for it: 0.88 s lost and 4–8 broken pictures, the open GOP's leading pictures T80 found.
- **The cut steps the PCR, unflagged, by the offset between the two groomers' clocks.** Each groomer locks its PCR to its own byte count from its own origin, so the stream an IRD follows jumps back 0.12–0.25 s against arrival at every cut, whichever model cut. A decoder that recovers its clock from the PCR must absorb that step; FFmpeg recovers none, so what an IRD does with it is unmeasured. Groomers locked to a common clock would remove it; none here is.
- **A gateway's return costs nothing, and T80's `lookback` result survives a groomer.** A leg's fault behind both gateways' 2 s hold cost the IRD what no fault costs. The gateway's cut does leave 10 continuity errors per leg fault, unflagged, which an analyser following TR 101 290 counts at its first priority.
- **Limit:** each cell's three runs hit nearly one keyframe phase, the fault falling at a fixed time on a looped clip, as in T80; the `rap` figures are one phase's.

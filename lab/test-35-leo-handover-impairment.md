# Test 35 — LEO / Starlink handover impairment

**State: candidate — specified, not run, not yet committed to the programme.** [T5](test-5-network-impairment.md)
used *steady* impairment; [T8](test-8-srt-vs-moq.md) matched controllers on loopback. On Starlink (LEO)
the perceived damage is periodic **satellite-to-satellite handover** — not uniform loss — and QUIC treats
a loss burst differently from Bernoulli loss. This candidate would extend T5/T8 with a pulsed profile;
it has not run, is not calibrated against a real capture, and remains **optional** until the campaign
commits apparatus time.

Source: [P2-f](planned-experiments.md#p2--completeness).

## Objective

Characterise MoQ and SRT behaviour under a **periodic handover impairment** plausible for LEO
satellite backhaul: near-clean baseline with short pulses of elevated delay and bursty loss, repeated
every ~15 s.

The metric is **per-pulse recovery** — whether each ~1 s burst causes a bounded, self-clearing dip or
accumulates into starvation over successive handovers — not average throughput. Extends
[T5](test-5-network-impairment.md) (impairment family) and [T8](test-8-srt-vs-moq.md) (comparative
matrix, condition 5 bursty/correlated loss if committed).

## What is already known, and precisely what it leaves open

**Steady loss and reordering are characterised.** [T5](test-5-network-impairment.md) and
[T8](test-8-srt-vs-moq.md) established that matched congestion controllers erase much of the MoQ/SRT
loss separation on loopback, and that **reordering** is the impairment that still separates lanes on a
shared substrate. Neither exercised **periodic** burst loss synchronized to a handover cadence.

**Collaborator reports point at handover-shaped damage.** Periodic degradation on satellite-backhauled
contribution is a plausible operational motivator; no rig result in this repository validates that
shape yet.

**The netem sketch is a candidate model, not a measurement.** Parameters (~15 s period, ~1 s pulse,
~10 % loss during pulse) are **assumed** pending calibration against a real Starlink capture. The
profile labelled S3 is described as roughly **25 % worse** than [APNIC / MMSys'24](https://dl.acm.org/doi/10.1145/3626287) Starlink measurements — conservative degradation, not a replay of those traces.

**Open before trusting numbers:** (a) calibrate period, hold and loss against capture; (b) correlate with
[T5](test-5-network-impairment.md) reordering finding — handover plus reorder is the genuine worst
case; (c) apply via SSH-safe media-only filter, not blanket `ifb0`, on shared hosts.

## Environment

| | |
|---|---|
| Topology | Same as [T5](test-5-network-impairment.md) / [T8](test-8-srt-vs-moq.md): publisher → impairment → relay/subscriber; MoQ media-aware and SRT reference legs. |
| Impairment | Periodic pulse on baseline (script below); adapt from collaborator sketch to **media-only** `prio`+`u32` egress shaping per [T8b](test-8b-congestion-control.md) SSH-safe discipline — **do not** run raw `ifb0` redirect on shared `<EC2_IP>`. |
| Baseline (S3) | `delay 50ms 8ms 25% loss 0.3%` — "Starlink medium-degraded", ~25 % worse than APNIC/MMSys'24. |
| Pulse | ~11 s clean, ~1 s `delay 150ms 20ms loss 10%`, repeat. |
| Source | ~10 Mb/s paced clip; record build and controller pins as T8/T8b. |
| Duration | Long enough for ≥ 20 handover cycles (≥ 5 min) plus soak if collapse is cumulative. |

## Procedure

1. **Adapt script** to SSH-safe media-only filter (replace `ifb0` ingress redirect from sketch).
2. **Calibrate (optional but preferred):** compare RTT/loss statistics to a real Starlink pcap if one is
   available; document deltas if sketch parameters change.
3. **Run MoQ and SRT** through the same pulse under matched buffers ([T8](test-8-srt-vs-moq.md) latency
   matching).
4. **Optional worst case:** add reordering during pulse arm per [T5](test-5-network-impairment.md)
   reordering cell — labelled separately.
5. **Grade per pulse:** delivery rate, holes, continuity; mark whether recovery completes before next
   pulse.

Collaborator `netem` sketch — **parameters preserved verbatim**; host interface name must be adapted:

```bash
#!/bin/bash
# S3: "Starlink medium-degraded", ~25% worse than APNIC/MMSys'24 measurements.
BASELINE="delay 50ms 8ms 25% loss 0.3%"
tc qdisc change dev ifb0 root netem limit 20000 $BASELINE
while true; do
    sleep 11
    tc qdisc change dev ifb0 root netem limit 20000 delay 150ms 20ms loss 10%   # handover pulse
    sleep 1
    tc qdisc change dev ifb0 root netem limit 20000 $BASELINE
done
```

If committed, place alongside [T8](test-8-srt-vs-moq.md) impairment matrix condition 5 (bursty/correlated
loss) so both transports meet the same pulse.

## Metrics

- **Per-pulse delivery dip** — minimum Mb/s and programme holes during each 1 s pulse.
- **Inter-pulse recovery** — time to return to ≥ 95 % of pre-pulse rate before next cycle.
- **Cumulative degradation** — trend over 20+ cycles: stable, drifting, or collapse.
- **Continuity errors** — TSDuck on egress; MoQ expected thinning not damage if prior lanes hold.
- **Standing RTT** — baseline versus pulse phase ([method-notes](method-notes.md): state condition).

## Pass criteria, fixed before running

Characterisation, not a gate — records behaviour for [Gate 3](README.md) / resilience claims:

1. **Bounded per-pulse recovery.** Each handover pulse followed by recovery to ≥ 95 % of pre-pulse
   delivery within 5 s **or** a finding recorded with pulse index and severity.
2. **No cumulative collapse over 20 cycles** unless measured — monotonic decline across cycles is a
   finding for both lanes separately.
3. **MoQ continuity** — 0 continuity errors at groomed egress unless paired with deliberate shedding
   configuration; thinning documented separately from damage.
4. **Comparative statement requires matched conditions.** MoQ versus SRT only with same pulse script,
   same baseline, matched receiver buffers.
5. **Script safety.** Run aborted if impairment applied outside media-only class on a shared host (SSH
   must remain usable).

## Limits, stated in advance

- **Candidate, not programme commitment.** May be dropped without changing acceptance gates; listed in
  [lab README](README.md) roadmap as T5+.
- **`netem` is an emulator** ([lab README](README.md)); complements but does not replace public-internet
  EC2 path from [T4](test-4-remote-e2e-srt.md).
- **Uncalibrated period/loss** until Starlink capture comparison — headline numbers carry *assumed
  profile* qualification.
- **Single route, single clip** — same cross-cutting limits as T5/T8.
- **Does not prove collaborator root cause** — only that this pulse shape produces stated transport
  behaviour.

## Why this has not run

Marked **candidate** in the planning record: apparatus exists (`tc`/`netem`), but calibration, SSH-safe
adaptation, and programme slot were not allocated. Steady impairment and controller matching answered
higher-priority questions first ([T5](test-5-network-impairment.md), [T8](test-8-srt-vs-moq.md),
[T8b](test-8b-congestion-control.md)). Committing this test requires explicit decision to extend the
impairment matrix — not default backlog.

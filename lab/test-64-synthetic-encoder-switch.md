# Test 64 — A synthetic unflagged encoder switch

**State: the reproducer built and replayed on `66af7231`; [P1-an](planned-experiments.md)'s runs on
upstream's tolerance remain.** Rig: [`t64-switch.py`](scripts/t64-switch.py), replayed through
[T41](test-41-import-reanchor-coverage.md)'s [`t41-rewind-supervisor.sh`](scripts/t41-rewind-supervisor.sh).

## Objective

Build a public stimulus with the features of the real switch [T34](test-34-real-encoder-severity.md)
graded, where a contribution changed between two encodes whose clocks were not locked, and check that
it costs what the real switch cost on the build T34 replayed it through. Upstream can then test its
tolerance of the switch without the capture, which cannot be shared, and P1-an can run it both ways.

**Falsifies:** that T34's cost of a switch, 2.8 s on `main` `66af7231` with the import restarted at
once, is the restart's and transfers to any unflagged whole-multiplex switch, rather than belonging
to that capture.

## The stimulus

Two FFmpeg encodes of one synthetic programme, H.264 at 25 Hz with MP2 and AC-3, muxed alike at
6 Mb/s with PAT, PMT, SDT and NIT, on clocks 16,844.5 s apart, the second starting 0.28 s later in
the programme with GOPs of 30 frames against 24. Each encode's PES are spread over the packets until
their PID's next PES, as a broadcast multiplexer interleaves them, and each PCR re-stamped for its
place. The two are cut together at one packet, chosen so that:

| Feature | Real switch (T34) | Synthetic |
|---|---|---|
| PIDs changing source at one packet | 12, each breaking its continuity counter once | 7, each breaking it once (forced where the counters happen to run on) |
| Cut mid-PES on both sides | video and MP2 | video, MP2 and AC-3 |
| New video's first PES | no `random_access_indicator`, non-IDR slices; keyframe 80 ms later in decode order | the same |
| Tables either side | PAT, PMT, NIT, SDT byte-identical | the same |
| Step, every clock together | back 16,844.35–16,844.65 s | back 16,844.70–16,845.00 s; forward 16,844.00–16,844.30 s |
| `discontinuity_indicator` | none | none |
| Not reproduced | — | teletext, the TDT, the second encode's 11 s path offset |

The lower clock sits at 33,155.5 s, so a fresh import does not read a step back as a wrap forward.

## Procedure

`t64-switch.py <out.ts> back|forward`, then [`p0j-splice.py`](scripts/p0j-splice.py) on the output,
the tool that classified the real switch. Each stimulus played through `t41-rewind-supervisor.sh`
`pipe` for 55 s, the switch at 30 s: a supervisor restarting the import at once, two exports at
`--delay 1s --follow 30s --stitch`, `moq-lite-07-wip`, `VPID=257`; graded by
[`t41-rewind-grade.py`](scripts/t41-rewind-grade.py). Three runs back and one forward on `main`
`66af7231`, the build of T34's replay.

## Pass criteria, fixed before running

1. **Class.** `p0j-splice.py` finds every PID's counter broken once, the video and MP2 cut mid-PES
   on both sides, the tables identical, every clock stepping by 16,844–16,845 s together and no
   `discontinuity_indicator`.
2. **Back.** A run counts as T34's did: the source plays in real time across the switch, the import
   exits there once with the live error and its successor publishes to the end, and both exports
   exit 0. The stimulus reproduces the real switch if the programme lost is within 200 ms of its
   2,800 ms; otherwise the result is reported as found.
3. **Forward.** The import carries on, and each export ends on its clock check, as both did live
   (T34). Otherwise the result is reported as found.

## Results

**The class is the real switch's.** On each stimulus `p0j-splice.py` finds every PID's counter
broken once, the tables at their next packet; the video, MP2 and AC-3 cut mid-PES on both sides; the
four tables' versions and CRCs identical; PCR and every PES stepping together, back by
16,844.70–16,845.00 s and forward by 16,844.00–16,844.30 s; and no `discontinuity_indicator`. The
new video's first PES has no `random_access_indicator` and holds non-IDR slices, and its first
keyframe is 80 ms later in decode order.

**Back: the real switch's behaviour, 0.3 s cheaper.** All three runs count. Each import exits once
at the switch, with *frame timestamp … is below the previous group's start*, on the AC-3's first PES
after it, and its successor starts 22–27 ms later. Every export exits 0, and the two legs are
byte-identical in every run. Each figure holds on both legs:

| Switch | Runs | Programme lost (ms) | Longest arrival gap (ms) | First post-switch picture beyond the latency (ms) | Latency before the switch (ms) |
|---|---:|---|---|---|---|
| Synthetic | 3 | 2,480–2,520 | 2,375–2,397 | 1,305–1,321 | 1,122–1,137 |
| Real (T34) | 3 | 2,800 | 2,778–2,785 | 1,564–1,572 | 1,203–1,212 |

On criterion 2 the result is reported as found: 280–320 ms below the real switch, on the grader T34
used. Both of the parts T34 split the loss into are smaller: the old encode's tail, about the
export's latency, because that latency is 70–90 ms shorter, and the new encode's head, because its
first picture comes 240–270 ms sooner. What shortens the head is not resolved: the successor's log at
this level does not record its catalog hold.

**Forward: as live.** The import carries on across the step, and both exports end 2.3 s after it left the
source, on their clock check, *the source's clock runs +40847.1 ppm off ours, past the 30 ppm the output's
may follow*. The figure is not a clock reading: an unmarked step leaves the export's startup offset
in place.

**The grader's holes are authored decode times.** On DTS the grader also counts 54 pictures missing
before the break and 40 after, two at every group start. The export carries them: it writes each
group's IDR and the picture after it with decode times 2 and 1 ticks below the IDR's presentation
time, where the source has them 80 and 40 ms earlier, as
[method-notes](method-notes.md) § *Time a picture where a decoder presents it* has the export
authoring DTS. On presentation times (`t41-rewind-grade.py --pts`) one picture is missing in two runs
and none in the third, and the loss is 2,400–2,480 ms. T34's real feed grades with no such holes, so
the table compares the two on DTS.

**What it settles.** A public stimulus reproduces the real switch's class and behaviour both ways on
the build T34 replayed it through: the step back ends the import with the live error, and the step
forward ends every export. Its cost has the real switch's two parts and is 0.3 s lower on this
content, so T34's 2.8 s belongs to the restart and that feed, not to every switch.

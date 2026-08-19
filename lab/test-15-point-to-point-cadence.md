# T15 — RIST and SRT on the cadence instrument

## Objective

[Comparison](../docs/comparison.md) §10.1 argues that RIST should hand a groomer the *cleanest*
egress of the transports this paper weighs, on the reasoning that a packet-level tunnel with a jitter
buffer "reconstructs the original packet cadence, delayed, rather than reassembling a stream from
objects or segments." That was reasoned and explicitly flagged as unmeasured, and it was the largest
unmeasured structural claim in the paper.

This runs RIST and SRT through the instrument [T14](test-14-data-plane-comparison.md) used, so the
point-to-point class can be quoted in the same units as MoQ and segmented HTTP.

Measurement 4 extends the same legs from cadence to carriage, asking what each transport does to the
DVB time tables it carries, and adds the media-aware lane to the comparison. It settles an upstream
design question — whether a clock should be relayed from the source or synthesised at the edge — and it
separates the two classes of machine more sharply than the cadence measurements do.

### Pass criteria (fixed before the runs)

1. **The instrument resolves what it is asked to.** A transport leg is only reportable if a
   no-transport control run through the same chain is measurably *finer* than it. Without that, a
   "clean" result cannot be distinguished from the rig's own floor.
2. **RIST's median burst and worst-case silence are stated against MoQ's 12.4 kB / 149 ms and
   segmented HTTP's 2.95 MB / 4.01 s**, from the same source clip and the same 1 ms burst threshold.
3. **§10.1's claim is graded either way.** "RIST is cleanest" is falsifiable, and a result that
   contradicts it is the more valuable outcome, since it is currently load-bearing in a section that
   recommends RIST for routes that do not need internet-scale fan-out.

## Environment

Single macOS host, loopback path, same clip and same instrument as T14.

| | |
|---|---|
| Source | `~/CNNiEMEA2.ts` — 1080i25 H.264, 9,945,951 bps CBR, 4.57 % null stuffing |
| Publisher | `tsp -I file --infinite -P regulate --pcr-synchronous`, identical to every T14 arm |
| RIST | TSDuck 3.44-4676 `rist` input/output plugins, and libRIST 0.2.20 `ristsender`/`ristreceiver` |
| SRT | TSDuck `srt` plugins, matched 1000 ms latency both ends |
| Jitter buffer | 1000 ms on every RIST leg (`buffer=1000`) |
| Instrument | [`t13-cadence.py`](scripts/t13-cadence.py), 64 kB reads (`pipe`) or per-datagram (`capture`) |
| Burst grouping | [`t15-bursts.py`](scripts/t15-bursts.py), 1 ms separation — T14's threshold |
| Window | 60 s per leg |
| Clock legs (measurement 4) | [`tdt-transports.sh`](scripts/tdt-transports.sh) for the pipes, 75 s per leg, and [`tdt-moq.sh`](scripts/tdt-moq.sh) for the media-aware lane, 300 s per arm — both reading [`tdt-staleness.py`](scripts/tdt-staleness.py) |
| MoQ build (measurement 4) | `dev` at `016fc09ae`, which carries the TDT/TOT proxy (#2929) and the SI snapshot tracks (#2909) |

The burst tool is new here and was validated before use: run against T14's retained arm A and B1
captures it reproduces the published figures exactly — 12.4 kB / 90.6 kB / 285.8 kB and
148.82 ms for MoQ, 2.95 MB / 3.49 MB / 3.59 MB, 24 gaps over a second and 4012 ms for segmented HTTP.

### The rig has a floor, and finding it changed the experiment

The first RIST run looked like a clean result — 92.1 kB bursts every 73 ms, tight distribution, no
silence over 78 ms. **It was the rig.** A plain-UDP control through the same chain, with no jitter
buffer, no retransmission and no pacing of its own, returns the *same numbers to within a
millisecond*: 92.1 kB median, 92.3 kB p95, 10 ms peak/mean 7.47 on both.

The cause is the publisher, not the receiver: `regulate --pcr-synchronous` accumulates for at least
`--wait-min` before releasing, and TSDuck's default is **50 ms**. So the source itself arrives in
~92 kB bursts, and no transport that merely carries them can be shown to be finer.

Every leg was therefore re-run at `--wait-min 5`, which drops the control to 30.6 kB / 24.5 ms and
restores headroom below MoQ's 12.4 kB. **Both source conditions are reported**, because the 50 ms one
is what T14 published on and the 5 ms one is what resolves the transport.

### What this environment cannot show

- **Loopback has no loss, no reordering and no RTT**, so nothing here exercises the retransmission or
  jitter-buffer *recovery* these protocols exist for. This measures the shape of a healthy stream's
  delivery, which is the hand-off question, not the reliability question.
- **A real CBR contribution source is smoother than this publisher.** `tsp regulate` is a software
  pacer with a millisecond-scale release granularity; a hardware encoder emits continuously. Since
  the tunnels are transparent (below), their egress on a real feed would be finer than measured here
  — the numbers below are an upper bound on their burstiness, not a fixed property.
- **libRIST's `cbr-output` is a libRIST-tools feature**, not something TSDuck's `rist` plugin exposes.

## Procedure

```bash
# Instrument floor: no transport at all, both source granularities
lab/scripts/t15-cadence.sh          ~/CNNiEMEA2.ts ~/t15 60 udp
WAITMIN=5 lab/scripts/t15-cadence.sh ~/CNNiEMEA2.ts ~/t15 60 udp

# The transports, at the resolving source granularity
for leg in rist-main rist-simple srt librist librist-cbr; do
	WAITMIN=5 lab/scripts/t15-cadence.sh ~/CNNiEMEA2.ts ~/t15 60 "$leg"
done

# MoQ re-run on the same fine source, to separate object model from input
WAITMIN=5 lab/scripts/t14-a.sh ~/CNNiEMEA2.ts ~/t15/moq-w5 60

python3 lab/scripts/t15-bursts.py ~/t15/*-egress.csv
python3 lab/scripts/t15-bursts.py --sweep ~/t15/librist-cbr-w5-egress.csv

# Measurement 4: the clock, on the same three transports plus the UDP control
lab/scripts/tdt-transports.sh ~/CNNiEMEA2.ts ~/tdt_transports 75

# and on the media-aware lane, whose arms vary the source cadence against the
# exporter's 30 s re-emission timer
lab/scripts/tdt-moq.sh "$TGT/moq" "$TGT/moq-relay" \
	~/moq-dev/demo/relay/localhost.toml ~/CNNiEMEA2.ts ~/tdt_moq 300
```

## Results

### Measurement 1 — the point-to-point transports are transparent

At the T14-matched source (50 ms release, ~92 kB bursts):

| | UDP control | RIST main | MoQ (T14 arm A) | Segmented HTTP (T14 arm B1) |
|---|---|---|---|---|
| Median burst | 92.1 kB | **92.1 kB** | 12.4 kB | 2.95 MB |
| p95 burst | 92.3 kB | **92.3 kB** | 90.6 kB | 3.49 MB |
| Median gap | 72.1 ms | **73.3 ms** | 3.5 ms | 2008 ms |
| Max gap | 76.3 ms | **77.8 ms** | 148.8 ms | 4012 ms |
| 10 ms peak/mean | 7.47 | **7.47** | 23.95 | 231.07 |

At the resolving source (5 ms release, ~30.6 kB bursts):

| | UDP control | RIST main | RIST simple | SRT | MoQ | libRIST + `cbr-output` |
|---|---|---|---|---|---|---|
| Median burst | 30.6 kB | **30.6 kB** | **30.6 kB** | **30.6 kB** | **12.2 kB** | **1.3 kB** |
| p95 burst | 30.8 kB | 30.8 kB | 30.8 kB | 30.8 kB | 90.2 kB | 21.4 kB |
| Median gap | 24.5 ms | 24.5 ms | 24.5 ms | 24.6 ms | 22.3 ms | 1.1 ms |
| Max gap | 34.0 ms | 36.7 ms | 36.6 ms | 35.5 ms | **149.4 ms** | 34.9 ms |
| 10 ms peak/mean | 7.40 | 3.43 | 4.31 | 3.43 | 23.93 | **3.28** |

**RIST and SRT reproduce their input and add nothing to it.** Median and p95 burst are identical to
the no-transport control at both source granularities, to three significant figures, across RIST Main,
RIST Simple and SRT. The mechanism §10.1 proposed is exactly right: these are packet tunnels, and what
comes out is what went in, delayed by the jitter buffer.

**They do smooth within the burst, though not its size.** The 10 ms peak/mean halves against the raw
UDP control — 3.43 against 7.40 — because the jitter buffer drains a 30.6 kB group over a longer
sub-interval than the kernel does. Burst *size* is the source's; burst *concentration* is improved.

### Measurement 2 — MoQ's granularity is a property of MoQ, not of its input

Fed a source four times finer (92.1 kB → 30.6 kB bursts), MoQ's egress does not move: **12.2 kB
median against 12.4 kB**, p95 90.2 kB against 90.6 kB, max gap 149.4 ms against 148.8 ms, 10 ms
peak/mean 23.93 against 23.95. The object model sets the granularity and the source does not reach it.

That is the structural difference the comparison was missing, and it sorts the three classes cleanly:

| Class | Egress granularity is set by | Measured |
|---|---|---|
| **MoQ** | the object model — *re-paces*, finer than its input | 12.2–12.4 kB whatever the source |
| **RIST / SRT** | the source — *transparent*, neither finer nor coarser | 30.6 kB or 92.1 kB, tracking exactly |
| **Segmented HTTP** | segment duration — *aggregates*, far coarser than its input | 2.95 MB at 2 s segments |

### Measurement 3 — RIST can be told to pace itself, and then it beats everything

libRIST's UDP output carries `cbr-output=1`, which "space[s] receiver output at the stream's measured
rate". Off, the receiver is transparent like every other leg (30.6 kB). On, it emits at **1.3 kB
median — a single datagram — with a 1.1 ms median gap and the lowest 10 ms peak/mean measured
anywhere in this campaign, 3.28.** That is ten times finer than MoQ and roughly 2,300 times finer
than segmented HTTP.

**It smooths within the source's release window and does not remove it**, which the threshold sweep
makes plain: the median is 1.3 kB at a 1 ms grouping threshold but 30.6 kB at 2 ms, i.e. the datagrams
are spaced ~1.1 ms apart *inside* a group that still arrives every 24 ms. Compare the other legs,
which are flat at 30.6 kB from 0.2 ms to 5 ms.

It is also not grooming. `cbr-output` spaces packets at a *measured* rate; it does not re-stamp PCR,
does not pad to a nominal constant rate, and offers no accuracy guarantee. It reduces what a groomer
must absorb; it does not replace one ([T13](test-13-downstream-grooming.md)).

### Measurement 4 — what the transports do to the clock they carry

About carriage rather than cadence, and it separates the two classes of machine more sharply than any
cadence measurement does. The question is not whether a time table arrives but **which time it asserts
when it does**, so the source is re-stamped by `tsp -P timeref --start system`: every TDT transmitted
asserts the true UTC of its own transmission, and any lateness a receiver reads is the path's.

#### The point-to-point transports are transparent

| Leg | TDT sections delivered | inter-section arrival gaps | staleness spread *(instrument)* |
|---|---|---|---|
| plain UDP *(control)* | 5 × 0x70 | 15.23, 15.08, 15.19, 15.10 s | 601 ms |
| SRT, 1000 ms latency | 5 × 0x70 | 15.23, 15.08, 15.19, 15.10 s | 604 ms |
| RIST Main, 1000 ms buffer | 5 × 0x70 | 15.24, 15.07, 15.20, 15.10 s | 601 ms |

**They are indistinguishable from the no-transport control, to two decimal places on every gap.** They
reproduce the source's section cadence packet-for-packet and add no variance to when the clock arrives.

Two columns here are instrument and not transport, and saying so is the point of quoting the control:

- The ~600 ms of *growing* staleness is `timeref --start`, which advances its reference over
  packets ÷ bitrate. The replay ran 1.00–1.02 % slow against that assumed rate, so the asserted clock
  slides at ~10 ms/s — identically on all three legs. It is a fair illustration of what
  media-timeline-derived time does, and it is not any transport's doing.
- **The absolute offset is not the configured buffer.** A publisher whose output blocks until its peer
  connects has already anchored `timeref`, so the stall becomes a constant lateness for the rest of the
  run. These legs are comparable by spread and by gaps, not by median.

The specifications agree with the measurement: VSF TR-06-2:2022 (RIST Main Profile) and the SRT
protocol draft contain **no occurrence of TDT, TOT, SI, PSI, SDT or EIT** between them, and the only
reference to TS syntax anywhere in TSDuck's `srt` or `rist` I/O plugins is reading PCR to estimate
input bitrate. RIST's null-packet deletion is the sole case of either touching TS content, and it is
explicitly reversible — the sender strips nulls and sends a bitmask of their positions, the receiver
restores them in place.

#### The media-aware lane carries the clock, and delivers it late

`export ts` now proxies TDT/TOT from the source on a latest-value SI slot (upstream #2929), closing the
zero-packet gap [T17](test-17-si-snapshot-tracks.md) measured. Because the lane is a remultiplexer
rather than a pipe, it cannot forward a section — it stores the newest one and re-emits it on its own
timer, which for table 0x70/0x73 is the DVB *maximum* repetition interval of 30 s. The consequence is
measurable, and it is not the sub-second lateness a pipe adds.

Arms differ only in how the source's cadence sits against that 30 s timer. 300 s per arm,
[`tdt-moq.sh`](scripts/tdt-moq.sh).

| Arm | source TDT cadence | sections delivered | median late | max late | repeated a section already sent |
|---|---|---|---|---|---|
| **control** — same publisher, no MoQ | 15.1 s | 20 × 0x70 | **470 ms** | 916 ms | no |
| **base** — clip's own clock | 15.1 s | 11 × 0x70 | **14,385 ms** | 15,546 ms | no |
| **slow** — clock slower than the timer | 45 s | 11 × 0x70 | **23,894 ms** | 38,861 ms | **4 of 11** |
| **tot** — TDT and TOT together | 20 s each | 11 × 0x70, 11 × 0x73 | **4,332 ms** | 5,009 ms | no |

**The source's clock is true to under a second and arrives ~14 s late.** In the base arm the exporter
emits every 30.0–30.3 s while the source ticks every 15.1 s, so half the ticks are overwritten in the
slot before they are ever sent, and what a boundary finds in the store is whatever arrived since the
last one — here, systematically, a section about one source period old. Steady-state lateness sits at
13.4–15.5 s across eight consecutive emissions.

Drift is not the explanation, which is why the control runs the same length: over the same 300 s the
instrument's own slide is ≤ 917 ms, and lateness here is flat rather than growing.

**The magnitude is not a constant of the build.** Same mechanism, same binary: 4.3 s in the `tot` arm,
14.4 s in `base`, 23.9 s in `slow`. It is set by how the emission grid falls against the source's ticks,
which varies with both the source's cadence and its phase — so it is not an offset anything downstream
could be told about and correct for. A single arm would have supported almost any figure.

**Below the timer's rate, the exporter repeats a time it has already asserted.** With the source at
45 s the exporter still emitted 11 times against 7 distinct source values, re-sending 4 of them:

```text
  0.01 s  asserts 09:54:50      19.21 s  asserts 09:54:50   <- again, 19 s later
 49.48 s  asserts 09:55:35      79.23 s  asserts 09:55:35   <- again
```

A receiver that trusts each TDT — which is what a TDT is for — sets its clock, advances it locally for
19 s, then receives the same time again and **steps backwards by 19 s**. A receiver of the original
multiplex never sees this: every TDT on that wire carries a new time, so its corrections are always
forward. This is the one result that is a defect rather than a cost, and it is the difference between
"late by a bounded amount" and "asserting a time known to be wrong".

**TOT survives intact, which validates the argument for proxying at all.** A `local_time_offset`
descriptor is operator policy — DST transition dates and per-country offsets an exporter cannot invent
— and both regions' bytes come through identical to the source's, with the section's own CRC
recomputed around a re-stamped UTC field:

```text
injected f0 1c 58 1a 47 42 52 02 01 00 ef 9a 02 00 00 00 00 44 45 55 …
egress   f0 1c 58 1a 47 42 52 02 01 00 ef 9a 02 00 00 00 00 44 45 55 …   identical
```

#### What the two classes mean for the clock

**Proxying a clock is correct for a pipe and insufficient for a remultiplexer.** A constant-delay pipe
that never repeats a section is late by its path and cannot be later; the measurement above puts that
at ~600 ms of instrument and nothing of transport. A stage that rebuilds the multiplex and re-emits SI
on its own cadence is a different machine: it is late by however long it holds a section, and below
its own emission rate it repeats one.

The fix that follows is narrow. For a latest-value table the interval should be a *floor on repetition*
and not the emission schedule — emit when the value changes, fall back to the interval only to satisfy
the DVB maximum. The reasoning that a source's observed cadence "means nothing downstream" holds for a
static table, where a repetition carries the same information whenever it is sent; for a clock the
cadence *is* the information.

### Against the pass criteria

| | Outcome |
|---|---|
| 1. Instrument resolves what it is asked to | **Met, on the second attempt.** The first run was the rig's floor; the UDP control caught it and the source was tightened until the control sat below MoQ. |
| 2. RIST stated in T14's units | **Met.** Both source conditions, same clip, same 1 ms threshold, tool validated against T14's retained captures. |
| 3. §10.1 graded either way | **Met, and it graded against the claim** on burst size while confirming its mechanism and its worst-case silence. |

## Observations

- **The worst-case silence inverts the burst-size ranking.** MoQ's 149 ms maximum gap is more than
  four times RIST's and SRT's ~35 ms, and it is stable across both source conditions, so it is the
  object model's too. A groomer's start gate and underrun threshold are sized by the *longest*
  silence, not the median burst — so on that axis, which is the one that decides whether a groomer
  falsely declares underrun, the point-to-point tunnels genuinely are the cleanest of the four.
- **MoQ's median burst is threshold-sensitive where the tunnels' is not.** Swept from 0.2 ms to 5 ms,
  MoQ's median runs 7.1 → 25.8 kB while every point-to-point leg stays at 30.6 kB and segmented HTTP
  at megabytes. T14's 12.4 kB is therefore a 1 ms-threshold figure rather than a natural constant.
  The comparison is unaffected — the threshold was fixed in advance and applied identically to every
  leg, and MoQ is finer than the tunnels at every threshold up to 2 ms — but the single number should
  not be quoted as though the grouping were incidental to it.
- **RIST Simple profile only works receiver-listens / sender-calls.** Asking a Simple-profile sender
  to listen fails with `Address already in use` on a demonstrably free port, which cost a hung run
  before the direction was tested directly. Main profile supports both. The rig now gives each leg its
  own port block and aborts if the publisher dies rather than letting the receiver block forever.
- **The transparency result makes the source the thing to specify.** Since a tunnel's egress is its
  ingress, "RIST hands over a clean stream" is a statement about the encoder, not about RIST. On a
  true CBR hardware feed the tunnels should be smoother than anything measured here; behind a bursty
  software packager they are exactly as bursty as it is. Neither is a protocol property.
- **Transparency extends to carriage, and that is what makes the incumbents' clock handling safe.**
  The same property measured on cadence holds on the time tables: the transports neither parse nor
  repeat a section, so a forwarded TDT is late by the path and by nothing else. It follows that
  "proxy the source's clock" is advice about constant-delay pipes rather than about time tables, and
  it does not transfer to a stage that re-emits SI on a cadence of its own.
- **A test whose control drifts identically to its arms has measured its own instrument.** All three
  clock legs returned a spread within 3 ms of each other; the shared component was the replay-rate
  error in `timeref --start`, and only the presence of a no-transport control made it separable from
  a transport property. This is the same lesson the cadence half of T15 learned, arrived at from the
  other direction.

## Conclusion

**§10.1's mechanism is confirmed and its ranking is not.** RIST is a transparent packet tunnel, as
argued — measured identical to a no-transport control on burst size at two source granularities, and
so is SRT. But transparency is not the same as cleanliness: fed this campaign's publisher, RIST hands
a groomer 30.6 kB bursts where MoQ hands it 12.2 kB from the same source, because MoQ's granularity is
set by its object model and does not track its input.

**On the axis that sizes a groomer's start gate, the tunnels win.** Worst-case silence is ~35 ms on
RIST and SRT against MoQ's 149 ms and segmented HTTP's 4.01 s. Median burst and maximum silence rank
the four differently, and a hand-off argument has to say which it means.

**Grooming burden does not rank inversely to scalability**, which was one of the two outcomes T15 was
specified to look for. The ordering by median burst is MoQ (12.2 kB), then RIST/SRT (30.6 kB), then
segmented HTTP (2.95 MB) — so the most scalable Internet-native candidate is also the finest-grained,
and the incumbent point-to-point class sits in the middle rather than at the top. The perceived
hand-off advantage of the incumbents is real only in worst-case silence, and it is not large.

**Nothing here changes what the distributor owns.** The finest egress measured, libRIST's paced
`cbr-output` at 1.3 kB, still carries no PCR re-stamp, no padding to a nominal rate and no accuracy
guarantee, so an edge grooming stage is required on all four transports. That is the same conclusion
T13 and T14 reached, now with the point-to-point class measured rather than assumed.

### Still open

| Cell | Why it is not run |
|---|---|
| RIST and SRT under loss and RTT | Loopback has neither. This measures delivery shape on a healthy path, not recovery. |
| A true CBR hardware source | Would establish the tunnels' floor rather than this publisher's. The transparency result makes this the interesting remaining variable. |
| RIST Advanced profile | libRIST 0.2.20 exposes it; nothing in the comparison currently turns on it. |
| A proxied clock through MoQ under loss | Measured on a clean loopback path only. Whether a lost snapshot group extends the staleness above is untested, and it is the arm that would matter on a real route. |
| The clock legs' true end-to-end latency | The rig's publisher blocks until its peer connects, which anchors `timeref` before the stream flows and turns the stall into a constant offset. Fixing it means anchoring after the connection is up. |
| Whether `cbr-output`'s spacing survives a groomer's input stage | It reduces burst absorption, and whether that lets a smaller buffer pass TR 101 290 is a groomer question ([architecture](../docs/architecture.md) §4.5). |

## Corrections

> The general method rules extracted from this section, together with those from every other
> experiment, are collected in [method-notes.md](method-notes.md). What stays here is the
> specific record of what this experiment got wrong.

- **"RIST should hand the groomer the cleanest egress of the four" — withdrawn as stated.** The
  reasoning behind it (a packet tunnel reproduces source pacing rather than reassembling from objects
  or segments) is confirmed exactly. The conclusion drawn from it was not, because it compared a
  transparent transport against a re-pacing one without asking what either was being fed: MoQ's egress
  is finer than its own input, so "reproduces the source" is a weaker property than "sets its own
  granularity". The method rule: **when a comparison ranks transports by an output property, measure
  the input too, or a transport that merely passes its input through will be credited with its
  source's virtues.**
- **A clean-looking first result was the measuring rig.** RIST Main initially read 92.1 kB / 73 ms
  with a tight distribution, which is a plausible jitter-buffer drain figure and is entirely the
  publisher's release granularity. It was caught only because a no-transport control was run through
  the same chain. The method rule, which T9 also yielded: **a control with the mechanism removed is
  worth more than a second run of the same arm** — the second run reproduces the artefact.

## References

- [T13 — downstream grooming](test-13-downstream-grooming.md): what no off-the-shelf stage does.
- [T14 — MoQ against segmented HTTP](test-14-data-plane-comparison.md): the instrument, the burst
  threshold, and the MoQ and segmented-HTTP columns quoted here.
- [T17 — SI on snapshot tracks](test-17-si-snapshot-tracks.md): the EIT carriage this clock now
  accompanies, and the zero-packet gap measurement 4 exists to put in context.
- [comparison](../docs/comparison.md) §10.1: the claim under test.
- [`t15-cadence.sh`](scripts/t15-cadence.sh), [`t15-bursts.py`](scripts/t15-bursts.py),
  [`tdt-transports.sh`](scripts/tdt-transports.sh), [`tdt-moq.sh`](scripts/tdt-moq.sh),
  [`tdt-staleness.py`](scripts/tdt-staleness.py).
- VSF TR-06-2:2022 (RIST Main Profile) and `draft-sharabayko-srt`: neither mentions any TS table.

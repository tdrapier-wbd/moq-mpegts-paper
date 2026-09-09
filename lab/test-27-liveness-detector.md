# Test 27 — The per-PID liveness detector: built, and made to work in a real lane

**State: the detector is complete and validated. Five synthetic arms, three cross-host in-lane arms,
a fault-injection arm against the detector itself — and one fixed-N soak in which the detector found
a client-side defect, now bisected to a single upstream commit:
[#3375](https://github.com/moq-dev/moq/pull/3375), the rewind fix this campaign's own T23
measurements motivated, stalls video and primary audio permanently on a source that does *not*
rewind. Reported as [#3533](https://github.com/moq-dev/moq/issues/3533).**

[T24](test-24-partial-media-plane-stall.md) concluded that per-PID access-unit liveness was the only
detector that caught every partial media-plane failure, and reached that conclusion with an offline
grader over a finished capture on one host. **This turns the recommendation into a running process
and finds out whether it survives contact with the distribution path.** It does, and the strongest
single result is a coincidence of two independent instruments:

| Same 60 s video suppression | Instrument | Delivered outage |
|---|---|---|
| [T24](test-24-partial-media-plane-stall.md) | offline grader, capture, loopback | 57.22 s |
| this test | live detector, cross-host lane, after the CBR groomer | **57.212 s** |

Different topology, different code, different measurement method, three decimal places apart. The
fine structure a liveness detector depends on **crosses a relay on another machine, the exporter's
PCR regeneration and a CBR groomer intact.**

The other results that matter:

- **The audio case is caught in 0.7–1.4 s.** T24's best wire-observable detector, the stuffing
  ratio, could not see a dead audio stream *at all* — 27.0 % against a control that peaks at 27.1 %.
  In the lane, all three non-video streams alarm within 1.4 s of the injection and the video PID
  stays silent. The detector's sensitivity is not proportional to the stream's share of the mux,
  which was the whole reason for building it.
- **Nothing fires on a healthy lane.** 180 s cross-host and 300 s of real broadcast material
  locally: zero alarms, and the 90 min N = 60 soak below adds to that.
- **Three of the failures found during this work were in the detector, not the lane.** A detector
  that blocks on `read()` cannot notice silence — it missed a *total* stall outright. A detector that
  takes media time as an absolute distance from the first PCR can be made to invent a 23,861 s outage
  by corrupting one byte. And learning across the lane's start-up transient set every threshold ~7×
  too wide. All three are fixed and each has an arm that fails without the fix, because a monitoring
  tool's own failure modes are the ones that produce a confident wrong answer.
- **The detector then earned its keep by finding something the campaign was not looking for.** A
  fixed-N soak meant as a false-positive test instead found **#3375's complement regression** — bisected
  to `0e61e35`, reported as [#3533](https://github.com/moq-dev/moq/issues/3533); mechanism and upstream
  report history in [upstream-contributions.md](upstream-contributions.md) § #3375.

Rig: [`ts-liveness.py`](scripts/ts-liveness.py) is the detector,
[`t27-liveness-inlane.sh`](scripts/t27-liveness-inlane.sh) the in-lane harness,
[`ts-partial-stall.py`](scripts/ts-partial-stall.py) the stimulus (unchanged from T24), and
[`f5-soak-side.sh`](scripts/f5-soak-side.sh) the fixed-N soak.

## Objective

T24 left the recommendation one step short of usable. Three things were unproven, and each of them
could have invalidated it:

1. **That the signal survives the lane.** T24 graded the delivered stream, so it knew the outage
   arrived. It did not ask whether the *evidence a detector needs* — access-unit spacing, which is
   exactly the fine structure a store-and-forward hop is entitled to rearrange — is still legible at
   the monitoring point, on the far side of a relay, an exporter that regenerates PCR, and a groomer
   that rebuilds the wire.
2. **That a threshold can be set at all in a real lane.** Delivered access-unit spacing is far more
   variable than a file's. A detector whose threshold is set by lane jitter rather than by media
   cadence is either insensitive or false-positive prone.
3. **That it is a detector rather than a grader.** Constant memory, no disk, no foreknowledge of the
   PID layout, and useful while the stream is still running.

## The detector

Five design decisions are load-bearing. Each is a correctness matter, and three of them were forced
by a failure recorded below rather than anticipated.

**An access unit is a PES start, and all three conditions are required** —
`payload_unit_start_indicator` set, a payload present, and the payload beginning `00 00 01`. T24's
stimulus, and a real encoder whose video path has died behind a running mux, emits
adaptation-field-only packets carrying PCR on the video PID. A packet with no payload must not be
read as a picture (ISO 13818-1 2.4.3.3), and a detector that counted packets rather than units would
report that dead stream as live.

**The expected stream set comes from the PMT.** A detector that watches the PIDs it has observed
cannot alarm on a PID it has never observed, so an encoder that comes up with its video path already
dead looks like a service that simply has no video. This is the `never started` arm, and it is a
case T24's method could not have produced.

**Thresholds are learned per PID, and streams without a cadence are declared unmonitorable rather
than watched.** Access-unit spacing across one mux spans orders of magnitude — 40 ms for 25 fps
video, 32 ms for AC-3, about a second for this clip's teletext, and unbounded for SCTE-35, which is
silent between breaks. T24 measured the analogous problem for the stuffing ratio; the same
proportionality defeats any single threshold. SCTE-35 and DVB subtitling are excluded by kind, and
saying so is more useful than watching them against an invented number. DVB signals AC-3 and
teletext both as private PES, so the kind comes from the descriptors, not from `stream_type` alone.

**Learning skips the lane's own start-up.** Measured against the raw exporter output with no warm-up,
every threshold in the mux was learned at **8,550 ms** — all four identical, because a single
media-time discontinuity during start-up was absorbed into all of them and set them ~7× too wide.
Discarding the first 5 s of media time brings the same measurement to 1,000–1,950 ms.

**It runs on two clocks, and they are not redundant.** Gaps are *measured* in media time from the
stream's own PCR, so a reading is a property of the stream rather than of how fast the pipe drained —
which is what makes 57.212 s comparable with T24's 57.22 s. But media time cannot measure its own
absence: if PCR stops, media time stops and a per-PID gap never grows again. Wall clock therefore
runs alongside as a dead man's handle on the clock itself.

## Environment

- **Relay host:** EC2 primary, `c6in.large`, 2 vCPU, `eu-west-1`. Relay only.
- **Publisher and subscriber host:** EC2 secondary, `c6in.2xlarge`, 8 vCPU / 15.7 GB, `eu-west-1b`.
- **Cross-host,** 0.72 ms RTT (mean TCP handshake; ICMP is blocked), GSO enabled both ends.
- **Build:** `moq` / `moq-relay` at the merge that closed
  [#3491](https://github.com/moq-dev/moq/issues/3491) via
  [#3515](https://github.com/moq-dev/moq/pull/3515); `mpegts-pacer` `5ab84cd`.
- **Chain, in-lane arms:** `ts-partial-stall.py` → `tsp -P regulate --pcr-synchronous` →
  `moq import ts` → relay (other host) → `moq export ts --latency-max 500ms` → `mpegts-pacer -
  11000000 --latency-ms 1000 --max-latency-ms 2500 --stall-ms 1000 --on-stall mute` →
  `ts-liveness.py`. `--latency-max 500ms` matches T24 so the two are comparable.
- **Local synthetic arms:** `CNNiEMEA.ts`, 1,983,892 packets, 299.976 s of media, graded from file.
- **Measurement point: after the groomer.** That is where an operator monitors, and it is not the
  same as the exporter's output — see the placement result below.

## Arms and results

### Synthetic, from file — does it fire when it should, and stay quiet when it should

Injection at t = 30 s of media time for 60 s. Detector defaults: 5 s warm-up, 20 s learning, so
armed at t = 25 s.

| Arm | Alarms | Which PID, and when | Delivered outage vs 60 s injected |
|---|---|---|---|
| `control` | **0** | — | — |
| `video` | 1 | 111 at t = 31.19, gap 1.195 s | **60.074 s** |
| `audio` | 3 | 131 at 31.02, 121 at 31.14, 123 at 31.73 | 60.049 / 60.272 / 60.197 s |
| `never started` | 1 | 111 at arming, reason `never started` | 19.997 s from arming to first unit |

Thresholds learned on the control and identical across the first three arms — 111 : 1,482 ms,
121 : 1,374 ms, 123 : 1,818 ms, 131 : 1,000 ms (the floor) — so the arms differ only in the
stimulus. **Zero alarms across 300 s of real broadcast material** is the reading that makes the rest
worth having.

The `never started` arm exposed a defect worth recording because it is the kind that leaves a
detector quietly useless: on recovery the stream was cleared but never given a threshold, so it ran
unwatched for the remaining four minutes. A recovered stream now re-learns — the outage it has just
emerged from is not evidence of its cadence — and the `WATCHING` event at t = 65.129 is that
re-arming being stated rather than assumed.

### The clock-stop arm — the case a media-time detector cannot see

A live pipe, 20 s of stream, 12 s of complete silence, 15 s more. This is [T22](test-22-silent-media-plane-failure.md)'s
total stall, and it is here because it is the failure a per-PID media-time detector is *structurally*
blind to.

| | Reading |
|---|---|
| clock stopped, declared at | **3.069 s** of wall silence (`--pcr-timeout 3`) |
| outage measured on resume | **12.096 s** against 12 s injected |
| per-PID outages reported | **0 — correctly** |

The last row is the point. In media time nothing happened: the clock stopped, so every stream's gap
froze where it was. Both clocks are needed and neither covers the other.

**The first version of this arm detected nothing at all**, because the detector was sitting in a
blocking `read()` waiting for a packet that was never going to arrive, so its loop never ran. A pipe
is now waited on with a timeout and the timeout expiring is itself an observation. *A detector that
blocks on input cannot detect silence* — and the failure it misses is the easiest one in the set.

### The corrupt-PCR arm — fault injection against the detector

One byte of one PCR base altered, 1,500 PCRs into an otherwise healthy stream.

| | Without the guard | With the guard (default) |
|---|---|---|
| alarms | **4 — every watched PID at once** | **0** |
| phantom outage | 23,861 s | — |
| media span reported | 23,906 s | **45.303 s, correct** |
| discontinuities | — | 2 (the jump, and the return) |

Taking media time as the absolute distance from the first PCR lets a single bad value move the whole
timeline, after which every stream appears to have been silent for as long as the error was large.
This is not hypothetical: it is what produced a **94,847 s** "outage" in a real run, when a broken
pipe fed the detector garbage. Media time is now accumulated step by step, and a step that is
backwards or further forward than `--pcr-jump` (5 s) is reported as a discontinuity rather than
absorbed as elapsed time.

### In-lane, cross-host — the arms that decide the question

Injection at t = 60 s of media time for 60 s, 180 s per arm, detector after the groomer.

| Arm | Alarms | Detected, relative to injection | Delivered outage vs 60 s |
|---|---|---|---|
| `control` | **0** | — | — |
| `video` | 1 — pid 111 | **+1.24 s** | **57.212 s** |
| `audio` | 3 — pids 131, 121, 123 | **+0.74 / +0.81 / +1.41 s** | 59.802 / 59.953 / 60.434 s |

Thresholds learned in the lane, stable across all three arms to within 4 ms — 111 : 1,083 ms,
121 : ~2,052 ms, 123 : ~3,110 ms, 131 : 1,985 ms.

Three things follow.

**The signal survives the path.** 57.212 s here against T24's 57.22 s, by an unrelated instrument on
a different topology. T24 recorded a 2.8 s discrepancy between the 60.02 s it injected and the
57.22 s it delivered, and flagged it as unexplained; this reproduces the discrepancy rather than
resolving it, which at least establishes it is a property of the lane and not of T24's grader.

**The audio case works, and that is the whole point.** T24's verdict on the stuffing ratio was that
it "works for video, **fails for audio**" — a dead audio stream moved the peak stuffing ratio to
27.0 % against a control peaking at 27.1 %, which is not a detection. Here the two audio streams and
the teletext each alarm inside 1.4 s, and the video PID does not alarm, so the detector also
*localises* the fault. Nothing in the delivered stream's whole-stream statistics does either.

**Detection latency is the threshold, and the lane sets it.** For the same content, the achievable
thresholds are 1.0–1.8 s from a file and 1.0–3.1 s at the groomed monitoring point: the lane widens
the small streams' thresholds by up to 1.7×. That is a real cost in sensitivity on exactly the
streams that need a per-PID detector, and it is stated rather than averaged away.

### Where the detector is placed changes what it can see

The exporter's output is not a groomed wire, and the same content measured at the two points learns
different thresholds:

| PID | From file | Raw `moq export ts` | After the CBR groomer |
|---|---|---:|---:|
| 111 video | 1,482 ms | 1,950 ms | **1,000 ms** |
| 121 mp1a | 1,374 ms | 1,000 ms | 2,084 ms |
| 123 ac3 | 1,818 ms | 1,800 ms | 2,936 ms |
| 131 teletext | 1,000 ms | 1,000 ms | 2,031 ms |

Neither point is uniformly better and the honest summary is that they trade: grooming tightens the
video threshold to the floor and loosens the small streams'. Measured directly on the exporter's
output, 102 media-time gaps over 0.3 s appeared in 39 s, simultaneously on every PID — PCR-only
stretches between bursts of PES, which is the exporter delivering by group rather than by packet.
**The monitoring point must be stated with any threshold figure**, and the operational point is the
groomed wire, because that is what leaves the building.

### The soak that was meant to be a false-positive test, and found a regression instead

A fixed-N soak (N = 60, cross-host) with the detector on one subscriber found a **client-side stuck
state at the source's first content-loop join** (590 s media): delivered clock **−596.9 s**, video and
MPEG-1 audio alarms that never cleared, 60 exporters at **0.31 Mb/s** each while the relay still
transmitted **642 Mb/s** — and a **fresh subscriber served perfectly** (8.9 Mb/s, 143,872 video packets
in 25 s). Join controls at N = 4 ruled out fan-out and `--latency-max` (500 ms and 3 s stall identically
to **0.31 Mb/s**).

[`t27-bisect-step.sh`](scripts/t27-bisect-step.sh) over 53 commits: **first bad
[#3375](https://github.com/moq-dev/moq/pull/3375) `0e61e35`**, file
`rs/moq-mux/src/container/ts/export.rs`. Parent `025613d`: **9.0–9.8 Mb/s** across joins; #3375:
**0.31 Mb/s** from the first join. Detector on the same join:

| | parent `025613d` | `#3375` `0e61e35` |
|---|---|---|
| delivered-clock discontinuities | **0** | **−119.35 s** |
| video PID 111 / MPEG-1 audio 121 | live | **DEAD**, never clear |
| AC-3 / teletext / PSI | brief outage then `CLEAR` | live — the **0.31 Mb/s** residue |

| source timeline | parent `025613d` | `#3375` `0e61e35` |
|---|---|---|
| true rewind (`tsp --infinite`) | **0.00 Mb/s** stall (#2833) | **8.66 Mb/s**, recovers |
| continuous, content join every 30 s | **9.0–9.8 Mb/s** | **0.31 Mb/s**, video + MPEG-1 dead |

Video-only control (five joins): **1.88–2.02 Mb/s** on both builds — multi-track is required. The fence
is `Track::admit` / `rewind()` generation gating in `export.rs` (snippet and full report history:
[upstream-contributions.md](upstream-contributions.md) § #3375 → [#3533](https://github.com/moq-dev/moq/issues/3533);
raw captures: [`results/t27-3375/`](results/t27-3375/README.md)). **Blast radius:** per-exporter state
(restart clears it); no self-heal across 80 further joins (**0.31 Mb/s** max, parent **9.52 Mb/s** mean).
Whether a never-repeating encoder feed triggers the fence is **open** ([P0-3](planned-experiments.md)).
This is a **different stimulus** from [T23](test-23-pcr-discontinuity-classes.md)'s six discontinuity
classes; T23's verdict on those arms is unchanged.

## What this establishes

1. **T24's recommendation is implementable and works in the distribution path.** Per-PID
   access-unit liveness, running live at the groomed monitoring point behind a cross-host relay,
   caught every arm at its true length and fired nothing on either control. The outage length agrees
   with T24's independent offline measurement to three decimal places.
2. **The media-aware lane preserves the evidence that per-PID monitoring needs.** This is the
   architectural result. A demuxing carriage layer could have destroyed access-unit spacing while
   still delivering conformant bytes, which would have made the only sufficient detector unusable in
   the very architecture that needs it. It does not.
3. **A dead audio stream is detectable in about a second.** The failure mode with no wire-observable
   signature at all in T24 — 4 % of the mux, invisible to the stuffing ratio, invisible to every P1
   check — is caught and localised to the PID.
4. **Detection latency is bounded and knowable in advance.** It equals the learned threshold, the
   detector reports its thresholds when it arms, and an operator can therefore be told what their
   detection time will be per stream before a fault occurs.
5. **The detector's own failure modes are characterised.** Blocking input defeats silence detection;
   absolute media time lets one corrupt PCR fabricate an outage across every PID; learning across a
   lane's start-up transient desensitises every threshold by ~7×. All three are fixed, and each has
   an arm that fails without the fix.
6. **The detector paid for itself on its first real run, which is the practical case for it.** It was
   attached as a false-positive control and instead localised a fault to two PIDs and named the
   delivered-clock step that precedes them — a fault whose *wire* remained conformant and whose byte
   counters at the relay showed 642 Mb/s of healthy transmission. Neither the relay's resource series,
   nor P1/P2 conformance, nor a rate check at the relay would have shown it. That is exactly T24's
   argument, now demonstrated on an unplanned failure rather than an injected one.
7. **A regression in a merged upstream fix was attributed to one commit in about an hour**, by
   shrinking the reproducer's period and bisecting with a known-good binary as an in-run control. The
   method is reusable and is written down in [method notes](method-notes.md).

## What this does not establish

- **Nothing about a frozen picture** — see [T24](test-24-partial-media-plane-stall.md) Limits (first
  stated there): valid advancing access units carrying an unchanging picture defeat every
  transport-layer detector including this one.
- **One clip, one PID layout, one mux.** The thresholds are this programme's; the *method* of
  learning them is what transfers. A mux with PCR on its own PID, or with a sparse subtitling stream
  that a broadcaster does expect to be live, would need the classification revisited.
- **The learned threshold is only as good as its learning window.** 20 s of observation sets a
  threshold from the worst spacing seen in 20 s. A lane whose jitter has a longer tail than that
  would false-positive later, and this run is too short to bound that tail. `--gap` exists so a
  threshold can be derived from the format instead — which is more defensible, since a broadcaster
  knows its frame rate — and that path is tested but not soaked.
- **Nothing about a multi-programme mux.** One service throughout. The PMT walk handles several
  programmes by construction and that construction is untested.
- **Nothing about detection-to-response.** As in T24, this measures when the signal becomes
  available, not what an operations system does with it.
- **The detector is a reference implementation, not a product.** Pure Python at 11 Mb/s costs
  roughly a core; it demonstrates that the measurement is available and cheap in principle, and says
  nothing about the cost of doing it at scale across many services.

## Open

**A per-track liveness signal in `moq import ts`.** The publisher logs audio frame-sync loss
([#3372](https://github.com/moq-dev/moq/pull/3372)) but has no equivalent for video. The importer
already parses each elementary stream to demux it — a symmetric per-track gap warning is drafted for
upstream. Everything measured here is done by a downstream observer reconstructing what the publisher
already knew.

**Whether the 2.8 s compression of the outage is the exporter's PCR regeneration.** [T24](test-24-partial-media-plane-stall.md)
measured 60.02 s injected against 57.22 s delivered; this reproduces **57.212 s** on a cross-host
lane. One focused run.

**Whether the lane's spacing jitter has a tail longer than the learning window.** The 90 min soak is
a start; 90 minutes is not a permanence claim.

**Whether per-PID liveness monitoring is available in practice.** The recommendation is only useful if
broadcast monitoring products expose per-PID access-unit liveness rather than only per-PID bitrate —
bitrate alone inherits the proportional-sensitivity problem [T24](test-24-partial-media-plane-stall.md)
measured.

## Corrections

**The exporter's per-process memory is not fixed, and T26's reading of it is superseded.**
[T26](test-26-cross-host-fanout.md) recorded the client's cost as "~96 MB, fixed per process rather
than buffer-driven, and no attempt was made to attribute it". Holding N constant and letting time be
the only variable shows it is a **cache filling to a plateau**, and the three signatures of that are
all present at two fan-out levels:

| Fixed-N run | Mean RSS per exporter | Largest single process | Log fit | Linear fit | Second-half slope | Largest drawdown |
|---|---|---:|---:|---:|---:|---:|
| N = 10, 703 s | 49.0 → **119.1 MB** peak | 124.4 MB | **r² = 0.904** | r² = 0.602 | **−0.21 MB/min** | 9.4 MB |
| N = 60, 547 s | 66.4 → **116.7 MB** | 134.2 MB | **r² = 0.973** | r² = 0.793 | +2.54 MB/min | 3.7 MB |

A logarithm beats a line on both, growth decelerates to nothing at N = 10, and **memory is given
back** — 9.4 MB of drawdown from a running peak, which a leak does not do. Past 300 s the mean sits
in the **106–119 MB** band, which is where [T21](test-21-permanence-soak.md) independently found the
exporter from 0.5 h to 4.5 h (119–122 MB). T26's figure was this fill measured at 45 s, not the
steady state; **~120 MB per session is the figure to plan against.**

The method rule this yields: *a per-N ramp cannot measure anything that develops over time, because
N and elapsed time move together in every reading.*

**A "high fan-out permanence soak at N = 100" is not runnable on a 15.7 GB host, and the first
attempt at one misattributed its own failure.** 100 subscribers × ~120 MB is 12 GB before the
publisher, the graders and the kernel, so the host OOM-killed a subscriber at about nine minutes
after 38 M direct-reclaim scans. The run was configured to stop on a *delivery* threshold and duly
reported "per-subscriber delivery fell to 78.5 % at n=100" — but `rx_bytes` was constant at
~12.86 GB per cell across every cell including that one, and relay egress held 990 Mb/s throughout.
**The bytes never stopped arriving; the harness stopped being able to account for them.** A delivery
threshold measures the harness's own thrashing. The soak rig now stops on `MemAvailable` instead,
which fires while the readings still mean something and names the harness as the cause.

**Two harness collisions, both mine, both now prevented in the scripts.** An unscoped
`pkill -f ts-liveness.py` in the in-lane rig's cleanup killed a detector belonging to a *different*
experiment on the same host, breaking that experiment's subscriber pipe and ending its run — and it
was the resulting garbage that produced the 94,847 s phantom outage. Separately, reusing one
broadcast name across back-to-back arms cost a run: [T25](test-25-isolation-under-abuse.md)'s
retention means the relay holds an abandoned session until the QUIC idle timeout, so the next arm's
subscriber attached to the previous arm's broadcast and died with `json: dropped` when the new
publisher replaced it. Each arm now gets its own broadcast name, and every kill pattern is scoped to
the run rather than to the tool.

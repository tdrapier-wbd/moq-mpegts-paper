# T8b — congestion control for a permanent fixed-rate trunk

> **State:** C1–C5 are executed on the namespace rig (68 cells) and C6, the soak, is running.
> **The experiment does not name a congestion controller, and that is its result** — C1, C2 and C4
> rank them in three different orders, and C5 shows why the question was the wrong one: what governs
> this feed is the **provisioning margin** and the **bottleneck queue discipline**, both of which move
> the outcome further than any controller choice. Below ~1.2× headroom delay climbs steeply; at or
> above it every controller is comfortable and indistinguishable. An AQM removes bufferbloat outright
> for every controller and transport at once (554–584 ms → 101–119 ms). What is stable across all five
> conditions is the failure *mode*: the MoQ lane loses content and never integrity — **0 continuity
> errors in every one of its ~40 cells** — while SRT inverts that and gets worse the better-behaved the
> network is, reaching 17,652–22,365 errors under an AQM while taking the most bytes of any lane.
> **The one place the media-aware lane loses badly is C3:** three feeds sharing a congested bottleneck
> collectively used 25 % of it against SRT's 84 %, on one replicate that needs repeating. Two known
> gaps: the four segmented C2 cells are withheld (outcome matches the expected mechanism, but their own
> RTT says the specified queue never formed), and most of C3's aggregate was lost to a disk janitor
> mid-run. The upstream discussion this test came from is
> [moq #2432](https://github.com/moq-dev/moq/pull/2432).

## Objective

Characterise **congestion-control behaviour for primary distribution**, which the
[T8](test-8-srt-vs-moq.md) matrix does not: T8 ran on an over-provisioned path (~292 Mb/s raw TCP
against a ~10 Mb/s stream), so a "100 %" cell there means "the source fitted in spare capacity," not
"the controller behaved well." It measures resilience to *non-congestive* impairment.

The use case is specific, and it sets the metric:

- The feed is a **fixed, non-congestion-responsive VBR** stream. On the media-aware lane MoQ carries
  the elementary essence (stuffing is stripped; CBR is rebuilt downstream by the pacer), so the
  transport sees VBR regardless of the source mux. The feed does **not** adapt its rate to the
  network — so this is *not* the adaptive-encoder / ABR case the CC knob
  ([#2432](https://github.com/moq-dev/moq/pull/2432)) was opened for.
- It must run **24/7/365, permanently**. That makes *stability over indefinite runtime* a first-class
  requirement: an intermittent or rare failure mode is disqualifying, because over continuous
  operation it will recur and eventually coincide with a transient.
- The value proposition versus SRT/Zixi is **relay-scaled distribution**, not glass-to-glass latency,
  and a downstream pacer rebuilds CBR/PCR at egress.

So the headline metric is **completeness and reconstructability** — delivered fraction, **0 continuity
errors after the pacer**, and session survival — **not** standing latency. Queuing delay matters only
where it (a) exceeds the receive buffer (`--latency-max`) and forces group drops, or (b) erodes the
buffer headroom that absorbs the next transient. This is why the "bufferbloat = latency" framing of
the upstream test does not map directly: that test optimises latency for a flow that can *fill* the
pipe; ours is fixed-rate with a re-groomer, so **completeness under contention** is the axis.

The **segmented-HTTP arm asks the same question of the third data plane**, and it is the condition
that plane has not yet been put through. [T5](test-5-network-impairment.md) and
[T8](test-8-srt-vs-moq.md) impair it non-congestively, where it never corrupts anything and simply
sheds time; nothing so far has asked what it does when the pipe is *smaller than the feed* and there
is no more time to shed. Because the answer turns out to depend entirely on the receiver, the arm is
run under two clients — the off-the-shelf `tsp -I hls` and T6's minimal re-anchoring client — which is
the only way to tell a property of the lane from a property of one implementation.

This is a characterisation, not a gate: the thesis is decided by T7 (Gate 2).

### Pass criteria (agreed in advance)

For a permanent fixed-rate trunk, "pass" is about staying reconstructable, not about latency:

1. **Complete and reconstructable.** On a provisioned path (C2–C5) the feed arrives with **0 continuity
   errors after the pacer** and no session drop, and recovers from a transient without a gap that
   breaks reconstruction.
2. **Stable indefinitely (C6).** No drift, leak, or rare abort over a hours→days soak — an intermittent
   fault is a fail even if the median run looks fine.
3. **Fails gracefully when under-provisioned (C1).** Degradation is *thinning* (missing content, clean
   TS), not *damage* (continuity errors) or a session/relay abort.
4. **Queuing delay judged only against the receive buffer.** Acceptable if it stays clear of
   `--latency-max` with headroom for a transient; a fail if it periodically approaches or exceeds it.

Scored in *Verdict against the pass criteria* below.

## Environment

> Placeholders `<EC2_IP>` / `<subscriber-home-ip>` carry the machine-specific values from
> `INSTRUCTIONS.local.md`.

### Rig — prefer the namespace rig

Contention is a **queue**, not a geography: the base RTT is supplied by `netem` either way. Running
both endpoints in local network namespaces removes access-link variability and makes the result
reproducible on any Linux host, so it is the primary rig. The real-path rig is the corroborating
variant, not the reference.

The harnesses below are **kept local** (not published) — the invocation details live in
`INSTRUCTIONS.local.md` §7.

| Rig | Harness | Use |
|---|---|---|
| **Namespace (primary)** | `t8b-netns.sh` | Two netns joined by veth on one Linux host; bottleneck + queue downstream, base delay both ways. Fully controlled, no shared-host risk. |
| Real path (corroborating) | `t8b-shaper.sh` | EC2 `<EC2_IP>` → `<subscriber-home-ip>`, shaping `ens5` egress. Media-only `prio`+`u32` lane so SSH stays clean. The real-path RTT adds to the emulated base delay — record both. |
| RTT probe (both rigs) | `t8b-rtt-probe.sh` | Standing RTT sampled over the same window as the capture — used only as a buffer-headroom check, not as a QoE metric. |

### Controllers

Pin `--server-quic-congestion-control` / `--client-quic-congestion-control` on **every** run — the
resolved default is backend-specific and changed at #2468, and an unpinned run silently confounds the
comparison. The relay is the sender on the downstream hop, so the relay's flag is the one that
governs. The goal is **not** to pick a default but to identify the controller we can *pin and rely on*
for a permanent fixed-rate trunk.

| Controller | Backend | Build |
|---|---|---|
| CUBIC | quinn / quiche | `--server-quic-congestion-control loss` |
| BBRv1 | quinn | quinn relay, `--server-quic-congestion-control delay` |
| BBRv2 | quiche | single-backend relay (`--no-default-features --features quiche,websocket,uds`) |
| BBRv3 | noq | single-backend relay (`--features noq,…`) — see caveat |
| SRT | — | `tsp -O srt` / `tsp -I srt`, matched buffer, as the incumbent reference |
| Segmented HTTP | TCP/CUBIC | `t8b-segmented.sh` — `tsp -O hls` + a Python origin in the publisher namespace, 2 s segments, 6-segment window. `RECV=tsp` (off-the-shelf) or `RECV=pull` (T6's re-anchoring client). |

**BBRv3 caveat.** noq/BBRv3 carries a subtract-overflow panic under high loss
([noq #768](https://github.com/n0-computer/noq/issues/768)). A relay abort is an outage by definition
for a permanent feed, so record an abort or a collapse as a *result*, not a reason to omit the row.

### Source and buffers

- Source: a real broadcast feed (`CNNiEMEA2.ts`) carried media-aware, paced with
  `tsp -I file … --infinite -P regulate --pcr-synchronous` (**not** `ffmpeg -re`, which mis-paces this
  TS). Media-aware carriage strips stuffing, so the wire profile is VBR — the representative input.
- Matched buffers as in T8: MoQ `--latency-max 2s`, SRT `--latency 2000` on listener and caller.

## Procedure

### 0. Calibrate the shaper before trusting any number

A `tc` chain that looks right can still queue in the wrong place. Confirm the rig reproduces the
intended profile first.

```bash
sudo ./scripts/t8b-netns.sh up
sudo ./scripts/t8b-netns.sh bloat

# idle RTT should sit at the base (2 x the one-way netem delay), not above it
sudo ./scripts/t8b-netns.sh sub ./scripts/t8b-rtt-probe.sh sample 10.99.0.1 20 idle.csv
```

Calibration passes when idle ≈ base RTT. `iperf3` is not required (and was absent on the EC2 host): a
loss-based CUBIC run doubles as the greedy reference — it fills the FIFO, so if the CUBIC run drives
the queue to ~base + queue-depth the bottleneck is where it should be.

### 1. Conditions

The upstream shaped-bottleneck profile (10 Mb/s source → 5 Mb/s cap, base RTT, deep queue) is used,
but re-scoped: an *under-provisioned* cap is a failure-mode probe, while the operating point of
interest is a *provisioned* path under contention.

| # | Condition | Setup | What it isolates | State |
|---|---|---|---|---|
| C1 | Under-provisioned (failure mode) | `bloat`, cap < feed (~2:1) | how each CC/transport fails when the link cannot carry the feed | **run** |
| C2 | Transient congestion / competing flow **(priority)** | provisioned cap + a competing flow or brief dip below feed rate | does the feed stay complete, and how fast it recovers; post-transient bloat | not run |
| C3 | Coexistence / fairness | provisioned, N ∈ {2,3} flows share the class | does the feed hold its share (starvation → dropped content) | not run |
| C4 | AQM counterfactual | `codel` / `cake` at the same bottleneck | does AQM change the completeness/latency picture | not run |
| C5 | Provisioning margin | cap ≈ 1.5× / 1.1× feed | where content loss *begins* per controller (an economics input) | not run |
| C6 | Long-duration soak (permanence) | provisioned, hours→days | drift / leak / rare abort a short run misses | not run |

### 2. Run each cell

Per controller per condition: start a **fresh** MoQ import on a unique broadcast name (`moq import`
crashes at the ~600 s source loop wrap when replaying a looped *file* — a live permanent feed does not
wrap, but the test harness must keep windows short; reusing a name also leaves a stale announce that
stalls the export at 0 bytes), then capture completeness + probe over the same window.

```bash
# relay with the controller pinned (namespace rig; per-backend binary for BBRv1/BBRv2/BBRv3)
sudo ./scripts/t8b-netns.sh pub <relay-binary> --server-bind 10.99.0.1:4443 \
  --tls-generate localhost --auth-public "" --server-quic-congestion-control delay

# publisher (media-aware; stuffing stripped -> VBR on the wire)
sudo ./scripts/t8b-netns.sh pub bash -c \
  'tsp -I file ~/CNNiEMEA2.ts --infinite -P regulate --pcr-synchronous -O file - \
   | <moq> --client-tls-disable-verify --client-connect https://10.99.0.1:4443/anon \
       --broadcast t8b.c1.bbr1 import ts'

# subscriber capture + RTT over the same window
sudo ./scripts/t8b-netns.sh sub bash -c \
  'timeout 60 <moq> --client-tls-disable-verify --client-connect https://10.99.0.1:4443/anon \
     --broadcast t8b.c1.bbr1 export ts --latency-max 2s > t8b_bbr1.ts' &
sudo ./scripts/t8b-netns.sh sub ./scripts/t8b-rtt-probe.sh sample 10.99.0.1 60 rtt_bbr1.csv
```

### 3. Measure (completeness first)

```bash
# delivered content: bytes over the window, then continuity AFTER the pacer
tsp -I file t8b_bbr1.ts -P continuity -O drop          # no output = 0 CC errors = reconstructable
tsp -I file t8b_bbr1.ts -P analyze -O drop | grep -E 'bitrate|packets'
# queuing delay only as a buffer-headroom check
./scripts/t8b-rtt-probe.sh summary idle.csv rtt_cubic.csv rtt_bbr1.csv rtt_bbr2.csv
```

## Results

Rig: two network namespaces on the EC2 host, 5 Mb/s `htb` bottleneck, 100 ms base RTT (2 × 50 ms
`netem`), 500 ms `bfifo` (312 500 B). Source `CNNiEMEA2.ts` carried media-aware (VBR on the wire),
paced at ~9.93 Mb/s — i.e. ~2:1 over-subscription of the cap (condition **C1**, the failure mode).
MoQ `--latency-max 2s`, SRT `--latency 2000`. Each backend used its matching relay build (quinn /
quiche / noq); `loss` = CUBIC, `delay` = BBRv1 (quinn) / BBRv2 (quiche) / BBRv3 (noq).

**Calibration.** Idle RTT through the shaped path measured min 100.0 / avg 106.7 ms — at the base.
Under load CUBIC drives the queue to ~520–600 ms (base + ~500 ms queue), confirming the bottleneck
queue is where it should be.

### C1 — Under-provisioned (failure mode), 5 Mb/s cap, 100 ms base, 500 ms queue

Completeness first (delivered fraction of the cap, continuity after the pacer); queuing delay p50 per
replicate is a secondary buffer-headroom read. 2–3 replicates per controller, 45–60 s windows.

| Controller (backend) | Delivered (% of cap) | CC errors | Queuing delay p50 | Character |
|---|---|---|---|---|
| CUBIC (quinn) | 65–81 % | 0 | 516 / 519 / 520 ms | stable full bloat |
| CUBIC (quiche) | 62–63 % | 0 | 562 / 566 ms | stable full bloat |
| BBRv1 (quinn) | 45–76 % | 0 | 226 / **591** / 234 ms | **bimodal** — occasional full bloat |
| BBRv2 (quiche) | 67–69 % | 0 | 225 / 291 (/ 265) ms | **stable, ~½ CUBIC** |
| BBRv3 (noq) | **11–13 %** | 0 | 595 / 597 ms | **broken** — bloats *and* starves ([noq #768](https://github.com/n0-computer/noq/issues/768)) |
| SRT (reference) | 90 % | **4279** | 583 ms | most bytes, but a damaged (unreconstructable) stream |
| **Segmented HTTP** (`tsp` client) | **64 %** | **0** | **489 ms** | **clean until it stops — the session dies at 43 s** |
| **Segmented HTTP** (re-anchoring client) | **99 %** | **0** | **486 ms** | **thins in whole segments; survives** |

The segmented rows were measured in the same session as an SRT re-run that reproduced the published
reference row to within noise (90 % of cap, 4,288 CC errors against 4,279, p50 582 ms against 583), so
they sit on the same scale as the rows above them rather than merely alongside them.

**Read the "Character" column as a description of this condition and not as a verdict on a controller.**
C2 inverts this ordering and C4 flattens it; the reasons are in those sections. What C1 establishes that
survives is the rig, the segmented lane's client dependence below, and the thinning-versus-damage split.

### C1, segmented lane — the client decides whether this lane degrades or dies

Two clients, one lane, one condition, opposite outcomes. This is the whole result, and it is a result
about receiver policy rather than about segment fetching.

| | `tsp -I hls` | `t6-hls-pull.py` (re-anchors on failure) |
|---|---|---|
| Delivered | 3.18 Mb/s — **64 % of cap**, 32 % of source | 4.93 Mb/s — **99 % of cap**, 50 % of source |
| Segments served | 8 consecutive, no gaps | 12 of an 18-segment span — **6 skipped** |
| Continuity errors | 0 | 0 |
| PCR intervals > 40 ms | 0 | 2, max 12.0 s — *the holes* |
| Session at 60 s | **dead: 404 at 43 s** | alive, ~12 s behind the edge |

Both replicates of each are identical to three significant figures.

**`tsp` does not fall off the edge so much as walk backwards off it.** It fetches strictly in order
and never skips, so a sustained shortfall means it slides steadily further back through the live
window until the segment it asks for has already been deleted — then a 404, at 43 s. What it does with
that 404 is worse than stopping: it does not check the status before handing the body to the demuxer,
so the origin's HTML error page enters the transport stream
(`MIME type is text/html, maybe not a valid transport stream`, then
`synchronization lost after 126,800 packets`).

**Given a client that re-anchors, the same lane thins exactly as MoQ does** — and delivers more. It
skips 6 segments to stay near the edge, producing a clean TS with holes rather than damage: 0
continuity errors, and two PCR discontinuities of 12 s that *are* the skips. It also fills the
bottleneck almost perfectly at 99 % of cap, where MoQ manages 45–81 %, because a fetcher that never
requests a stale object keeps the pipe busy.

**Read the delivery advantage with its price attached.** The re-anchoring client is running roughly
12 s behind the live edge and takes its content loss in 12 s holes; the MoQ rows are at
`--latency-max 2s` and shed in group-sized pieces. Segmented HTTP is buying that completeness with
about six times the latency and much coarser loss granularity, which for a broadcast hand-off is the
wrong side of both trades even though the delivered fraction is higher.

Sweeping the bottleneck against the source's 9.95 Mb/s, with the `tsp` client, locates where its
particular failure begins:

| Cap | Over-subscription | Delivered | % of cap | % of source | Segments served | Lag at 60 s | Session |
|---|---|---|---|---|---|---|---|
| 5 Mb/s | 2.0 : 1 | 3.18 Mb/s | 64 % | 32 % | 8, no gaps | 10 s behind | **404 at 43 s** |
| 8 Mb/s | 1.24 : 1 | 6.64 Mb/s | 83 % | 67 % | 17, no gaps | 6 s behind | survives, still falling |
| 12 Mb/s | 0.83 : 1 | 8.93 Mb/s | 74 % | 90 % | 22, no gaps | at the edge | survives, keeps up |

**The 8 Mb/s row is the one to read carefully.** Surviving the window is not the same as being
healthy: it lost about four segments of ground over 60 s against a nine-segment retention, so it is on
the same trajectory as the 5 Mb/s cell with a longer fuse. A 60 s window is too short to call it a
pass.

Two properties in that ladder belong to the lane rather than to the client. **A strictly-ordered
fetcher cannot use the bottleneck it is given** — 64 %, 83 % and 74 % of cap, including the
over-provisioned cell; the re-anchoring client's 99 % shows the capacity was there to be taken. And
**the lane bloats the queue even when over-provisioned**: p50 RTT is 337 ms at a 12 Mb/s cap against a
100 ms base, because each segment fetch is a line-rate burst into the bottleneck buffer. A segmented
trunk sharing a bottleneck with anything else will hurt it whether or not the trunk is short of
capacity.

### C2 — Transient congestion on a provisioned path, and it reverses the C1 ranking

15 Mb/s cap (1.5× the feed), 100 ms base, 500 ms `bfifo`. A greedy TCP bulk flow arrives 40 s into a
120 s window and leaves at 80 s, through the same bottleneck in the same direction. Two replicates each.
The instrument is the receiver's output sampled once a second, so the transient is scored as three
phases rather than averaged away; **recovery** is the first second past the transient with three
consecutive seconds back at ≥ 95 % of the pre-transient rate.

| Controller | Before | During | After | Recovery | CC | PCR > 40 ms | max |
|---|---:|---:|---:|---:|---:|---:|---:|
| CUBIC (quinn) | 9.63 / 9.63 | 9.01 / 8.16 | 9.77 / 9.43 | 3 s / 7 s | 0 | 412 / 394 | 1.20 s |
| **BBRv1 (quinn)** | 9.56 / 9.54 | **9.36 / 9.50** | 9.79 / 9.64 | **4 s / 1 s** | **0** | 414 / 414 | 0.54 s |
| BBRv2 (quiche) | 9.28 / 9.33 | **6.69 / 6.10** | 9.06 / 8.97 | **11 s / 13 s** | 0 | 375 / 363 | 2.72 s |
| SRT (reference) | 9.43 / 9.43 | **9.91 / 9.97** | 10.04 / 10.04 | 1 s / 1 s | **53 / 5** | 4 / 0 | 74 ms |

**BBRv2 was C1's winner and is C2's worst by a wide margin.** Under a shaped bottleneck too small for
the feed it was the one controller that was *stable* — full delivery at half CUBIC's queuing delay on
every replicate — and that is the row this experiment previously recommended. Provision the path
properly and put one competing flow on it, and it gives up **28–35 % of its rate** and takes **11–13
seconds** to come back. CUBIC gives up 6–15 % and recovers in 3–7 s. BBRv1, the controller C1
disqualified for bimodality, barely registers the transient at all: −2 % and −0.4 %, back inside 4 s and
1 s.

**So a failure-mode condition cannot rank controllers for a deployment, and C1 is now evidence for that
rather than a ranking.** The two conditions do not disagree about any measurement; they disagree about
which behaviour is being rewarded. A delay-based controller reading a full bottleneck buffer as a signal
to yield is doing the right thing when the buffer is full because the link is too small, and the wrong
thing when it is full because something else is briefly using it — the feed is not congestion-responsive,
so yielding is content lost rather than rate deferred. BBRv2 yields hardest and therefore loses most.
CUBIC, which needs actual loss before it backs off, holds more of the feed for the same reason it bloats.

**Nothing on the MoQ lane corrupted anything, at any controller: 0 continuity errors in all six cells.**
The transient costs *content* — a hole where groups were skipped, visible as a PCR interval up to 2.72 s —
and never integrity. SRT again does the opposite and does it twice as clearly as in C1: it **gains** rate
during the transient (9.91 and 9.97 against 9.43 before), because it is not congestion-responsive and
simply declines to yield, and it pays for that with 53 and 5 continuity errors. Taking the most bytes and
delivering a damaged stream is the same trade C1 recorded at 90 % and 4,279 errors, now visible at a
provisioning level where every other lane is comfortable.

**The PCR column is the exporter defect, not the transient.** 363–414 intervals above 40 ms on every MoQ
cell is the clustering characterised in [T18](test-18-delivery-latency.md) and filed as
[#2937](https://github.com/moq-dev/moq/issues/2937); what the transient adds is the *maximum*, which
tracks the hole rather than the cadence. SRT's 0–4 is the same contrast T18 measured and for the same
reason: it carries the source mux with its own PCR spacing.

#### The segmented rows of C2 are withheld pending a re-run

Four segmented cells ran and none is reportable, for a reason worth stating precisely rather than
dismissing. The *outcome* looks exactly like the mechanism C1 identified: delivery falls from ~9–10 Mb/s
to 2.4–3.0 Mb/s, the receiver's output file stops growing between t=41 s and t=49 s — within seconds of
the competing flow's scheduled 40 s onset — and in three of the four it never restarts. Half of 15 Mb/s
is less than the 10 Mb/s feed, so a client that fetches in order falls behind, leaves the origin's
availability window, and dies on the 404. That is C1's finding arriving on a provisioned path.

**What cannot be shown is that the queue those cells experienced was the queue the condition specifies.**
Their standing RTT reads **p95 178–183 ms against 554–584 ms on every other cell in the same condition**,
so on the only independent evidence the rig collected, the bottleneck buffer never filled — yet the same
greedy flow demonstrably filled it for the six MoQ and SRT cells run minutes apart under identical
shaping. Something about these cells is not what the label says, and until it is known which, a
collapse that *looks* like the expected mechanism is the most dangerous kind of result to publish: it
would confirm a prior on evidence that does not support it. The re-run records the competing flow's own
throughput per cell, which is the measurement whose absence makes this undecidable. C1's segmented
conclusion — that behaviour under contention on this lane is a property of the *client*, not the
transport — is unaffected, since it was measured with the shortfall applied by the cap itself and needed
no competing flow at all.

### C4 — AQM, which deletes the queue, the controller ranking and most of the argument

`codel` and `cake` in place of the 500 ms FIFO, 100 ms base, 5 Mb/s cap, no competing flow, two
replicates each plus one BBRv3 cell per qdisc. **Read this as C1 with an AQM rather than as a provisioned
path:** 5 Mb/s against a ~10 Mb/s feed is a 2× shortfall, so the condition isolates the queue discipline
and holds the shortfall constant, and none of it speaks to a properly sized link. Delivered fraction is
quoted against the cap, since against the source it is fixed at roughly half by construction.

| lane | codel: of cap | CC | PCR > 40 ms | max | cake: of cap | CC | PCR > 40 ms | max |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| CUBIC | 45 / 49 % | 0 | 51 / 56 | 4.68 s | 50 / 50 % | 0 | 60 / 58 | 3.04 s |
| BBRv1 | 43 / 47 % | 0 | 55 / 55 | 4.68 s | 47 / 58 % | 0 | 57 / 69 | 4.68 s |
| BBRv2 | 59 / 59 % | 0 | 69 / 72 | 3.32 s | 57 / 54 % | 0 | 67 / 65 | 3.32 s |
| BBRv3 | 44 % | 0 | 51 | 7.10 s | 36 % | 0 | 46 | 3.50 s |
| SRT | 88 / 88 % | **22,365 / 22,343** | 538 / 550 | 296 ms | 75 / 79 % | **17,815 / 17,652** | 547 / 552 | 494 ms |
| segmented, `tsp` | 79 / 79 % | 0 | **0 / 0** | **25.0 ms** | 56 / 56 % | 0 | **0 / 0** | **25.0 ms** |
| segmented, re-anchoring | 79 / 79 % | 11 / 11 | 1 / 1 | 10.18 s | 55 / 55 % | 21 / 21 | 2 / 2 | 9.97 s |

**An AQM removes the bufferbloat completely, for every controller and every transport, and that is the
single most consequential number here.** Standing RTT is **p50 100–108 ms against a 100 ms base, p95
101–119 ms** — against 554–584 ms p95 on the FIFO under the same base in C1 and C2. The 520–570 ms
queuing delay that this experiment spent C1 characterising, and that decided C1's controller ranking, is
a property of the *queue discipline at the bottleneck*, not of the controller and not of the transport.
Put `codel` or `cake` at the bottleneck and it is simply gone.

**With the delay gone, the controller spread very nearly goes with it.** C1 separated the controllers by
a factor of two-and-a-half in standing delay and ~20 points of delivery; here they sit inside 43–59 %
with zero continuity errors everywhere, and the ordering that survives is weak — BBRv2 marginally ahead
on both AQMs, BBRv3 last on both, CUBIC and BBRv1 indistinguishable. **Between C1, C2 and C4 the
controller ranking has now come out in three different orders under three conditions, which retires the
question rather than answering it:** for a fixed-rate feed the controller is a second-order term, and the
first-order terms are how the link is provisioned and what the bottleneck queue does.

**AQM is where SRT's failure mode stops being a trade and becomes a disqualification.** C1 recorded 4,279
continuity errors under a FIFO; the same protocol under `codel` at the same shortfall takes **22,365**,
and under `cake` **17,815**, reproducing to within 0.1 % and 1 % on the replicates. An AQM drops early
and deliberately rather than tail-dropping a full buffer, and SRT's ARQ cannot keep up with it — so it
still takes the most bytes of any lane (88 % of cap) and still delivers the least usable stream of any
lane. Its PCR train degrades in the manner already noted: 538–552 intervals over 40 ms with the *median*
interval unmoved, which is loss punching holes in an even grid rather than clustering.

**MoQ's 0 continuity errors survive the AQM, and its cost moves entirely into the hole size.** Every MoQ
cell, both AQMs, both replicates, all four controllers: zero. What the shortfall buys instead is a
maximum PCR gap of **3.0–7.1 seconds**, i.e. multi-second holes where groups were dropped. Thinning
rather than damage, at every queue discipline tried — that is now the most robust single result in this
experiment.

**The segmented lane's 0 PCR violations here are a symptom of lag, not a conformance win, and the
distinction matters.** `tsp -I hls` posts 0 intervals over 40 ms and a 25.0 ms maximum — perfect, and it
would be tempting to read as the lane keeping its timing under pressure. It is not: the client delivers a
*contiguous* prefix of the stream and simply falls behind, which is [T5](test-5-network-impairment.md)'s
"sheds time, not bytes" and the reason no gap appears in its PCR train. Its 79 % (codel) and 56 % (cake)
are how far behind it got before the window closed, not how much it lost. The re-anchoring client is the
control that proves it: given the same conditions it *does* skip, and its PCR maximum immediately becomes
**9.97–10.18 s** with 11–21 continuity errors.

**Two `cake` cells lost the RTT instrument** (`rtt_p50=NA`) with the delivery measurement intact. Nothing
depends on those two readings, since the other twenty-four agree on the AQM result, but they are the
reason the RTT claim above is stated as a range over the condition rather than per cell.

### C5 — the provisioning margin, which is the number an operator actually sets

The condition C2 and C4 make interesting: if the controller is second-order and an AQM deletes the queue,
what remains is *how much headroom over content rate a fixed feed needs*. Caps of 15, 12, 11 and 10 Mb/s
against a ~9.9 Mb/s source — 1.51×, 1.21×, 1.11× and 1.01× headroom — on the 500 ms FIFO, no competing
flow, one replicate per cell. Delivered is against the source; delay is p50 against a 100 ms base.

| headroom | CUBIC | BBRv1 | BBRv2 | SRT | segmented `tsp` | segmented re-anchor |
|---|---|---|---|---|---|---|
| **1.51×** | 95 % / 114 ms | 95 % / 114 ms | 93 % / 113 ms | 97 % / 114 ms | 99 % / **129 ms** | 92 % / 128 ms |
| **1.21×** | 94 % / 138 ms | 95 % / 138 ms | 93 % / 135 ms | 97 % / 126 ms | 89 % / **336 ms** | 84 % / 333 ms |
| **1.11×** | 94 % / 173 ms | 95 % / 171 ms | 90 % / 154 ms | 97 % / 130 ms | 84 % / **369 ms** | 80 % / 367 ms |
| **1.01×** | 92 % / **517 ms** | 92 % / 315 ms | 93 % / **229 ms** | 90 % / 570 ms **(1,035 CC)** | 79 % / 407 ms | 76 % / 405 ms |

**There is no content cliff on the MoQ lane anywhere in this ladder, which was not the expected answer.**
The condition was designed to find where content loss begins, and delivery declines gently from 95 % to
92 % as headroom falls from 1.51× to 1.01× — with **0 continuity errors in all twelve MoQ cells**. Running
a fixed 9.9 Mb/s feed through a 10 Mb/s pipe costs three points of content and no integrity. What responds
to the margin instead is **standing delay**, and it responds sharply: flat at 113–114 ms through 1.51×,
138 ms at 1.21×, 154–173 ms at 1.11×, and then 229–517 ms at 1.01×.

**So the deployable output of this whole experiment is a provisioning rule, not a controller.** Below
about 1.2× headroom the FIFO begins to fill and the delay starts eating the receive buffer that absorbs
the next transient; above it, every controller and both MoQ backends are indistinguishable and
comfortable. That is a number an operator can act on, it is stable across the three conditions that
measured it, and it makes the controller choice a tie-break rather than a decision.

**The controllers separate only at 1.01×, and there they reproduce C1's ordering** — BBRv2 229 ms, BBRv1
315 ms, CUBIC 517 ms — which is consistent rather than contradictory: C1 was also a thin-margin FIFO
condition. The three-way disagreement across conditions is between *regimes*, not between replicates.

**SRT's failure is a cliff where MoQ's is a slope.** It is the best lane in the ladder down to 1.11× —
97 % delivered at 126–130 ms, better than any MoQ cell — and at 1.01× it breaks: 570 ms and **1,035
continuity errors**. Graceful degradation against a sharp edge just above unity is the same
thinning-versus-damage split, now located on the provisioning axis.

**The segmented lane needs roughly 1.5× where MoQ needs 1.2×, and the reason is burst shape rather than
average rate.** Its delay is already 129 ms at 1.51× and triples to 336 ms at 1.21×, where every MoQ cell
is still at 138 ms — because each segment fetch is a line-rate burst into the bottleneck buffer
irrespective of how much average headroom exists. It also delivers the least at every margin below 1.5×
(89 %, 84 %, 79 %). This reproduces C1's independent reading of 337 ms at a 12 Mb/s cap to within 1 ms in
a different session, which is the strongest cross-session agreement in the experiment. **A segmented trunk
sharing a bottleneck hurts whatever shares it with, and needs provisioning against its bursts.**

### C3 — coexistence, where the media-aware lane's one serious scaling result is

N concurrent feeds through one 15 Mb/s bottleneck and one relay, 500 ms FIFO, 90 s, one replicate. The
per-flow figure below is flow 1; the aggregate is the sum over all N receivers, and **it survives for
only the two `n=3` cells** — the others were deleted by a disk janitor mid-run, which is a self-inflicted
gap and the reason `n=2` is reported per-flow only.

| cells | flow 1, of source | aggregate | of the 15 Mb/s cap | CC (flow 1) | RTT p50 |
|---|---:|---:|---:|---:|---:|
| MoQ BBRv1, n=2 | 46 % | not captured | — | 0 | 594 ms |
| MoQ CUBIC, n=2 | 29 % | not captured | — | 0 | 522 ms |
| MoQ BBRv1, n=3 | 12 % | **3.76 Mb/s** | **25 %** | 0 | 596 ms |
| SRT, n=3 | 31 % | **12.67 Mb/s** | **84 %** | 7,833 | 592 ms |
| MoQ CUBIC, n=3 | 20 % | not captured | — | 0 | 558 ms |
| SRT, n=2 | 90 % | not captured | — | 1,562 | 582 ms |

**Three MoQ feeds sharing a congested path collectively use a quarter of it; three SRT feeds use
84 %.** That is the one result in this experiment where the media-aware lane loses on something other
than a filed upstream defect, and it is not a fairness problem — it is a *utilisation* problem. Each
flow's individual share being below the fair 1/N is expected under contention; the aggregate falling to
3.76 Mb/s on a 15 Mb/s link is not. The mechanism is coherent: a delay-sensing controller behind a
permanently saturated 500 ms FIFO (p50 596 ms) reads a very large delay, all three flows read it at once,
and they back off together — so the more feeds share the path, the worse the total. SRT does not sense
delay, does not yield, and fills the link at the cost of 7,833 continuity errors.

**Read this as one replicate of one controller at one queue discipline, and as the strongest argument in
the campaign for running C3 properly.** It is the first condition to suggest that trunking several
media-aware feeds over one shared bottleneck is qualitatively worse than trunking one — which matters
directly, because a distribution trunk carrying many services is the intended deployment. The re-run
needs: aggregate captured for every cell, `cake` alongside the FIFO (C4 predicts most of this effect
disappears with an AQM, and that prediction is cheap and load-bearing), CUBIC's aggregate to separate
"delay-based collapse" from "MoQ collapse", and replicates.

### C6 — specified, not yet reported

The permanence soak is BBRv1/quinn at a 15 Mb/s cap for 14 hours, chosen because C1's unexplained
bimodality is exactly what a 120 s window cannot rule on. It grades in flight rather than storing, since
a 15 Mb/s feed is 162 GB a day, and it samples per-role RSS, a running packet total, continuity events
and respawns once a minute. Because relay memory rises under load by a mechanism
[T9](test-9-performance.md) has already root-caused, the RSS arm is graded against that mechanism's
predicted knee rather than against a flat line — see the pass criterion under *What to do next*.
**No result is reported here yet**, so nothing in this file rests on it.

## Observations

- **CUBIC bloats, reliably — and the bloat belongs to the FIFO, not to CUBIC.** Both backends fill the
  500 ms FIFO to ~520–570 ms on every replicate, and C4 then shows every controller sitting at 100–108 ms
  against a 100 ms base once the bottleneck runs `codel` or `cake`. So "CUBIC bloats" is really "a
  tail-drop buffer bloats, and CUBIC is the controller that fills it fastest"; the deployment lever is
  the queue discipline, which is usually someone else's to set.
- **The controller is a second-order term for this feed, and it took three conditions to see it.** C1,
  C2 and C4 rank the controllers in three different orders. Under an under-provisioned cap (C1) BBRv2 on
  quiche is the stable, complete performer and BBRv1 on quinn is bimodal; on a provisioned path with a
  transient (C2) BBRv2 is the worst row on the page — shedding 28–35 % of the feed and needing 11–13 s to
  recover — while BBRv1 loses 0.4–2 % and recovers inside 4 s; under an AQM (C4) the spread closes to
  43–59 % of cap with 0 CC everywhere and no ordering worth quoting. **What each condition actually
  measures is how readily the controller yields, and for a feed that cannot slow down, yielding is content
  lost.** Whether that is the right thing to do depends on whether the bottleneck is permanently too small,
  briefly shared, or never allowed to fill — so it is a provisioning and queue-discipline question, and
  the open question to the maintainer on #2432 (whether BBRv2 on quiche is supported for continuous
  operation) matters less than it did.
- **BBRv3 (noq) is out** — it both bloats and collapses delivery to ~12 %, the #768 overflow biting
  under sustained pressure. A controller that can abort the relay is an outage by definition here.
- **BBRv1's C1 bimodality is still unexplained and still matters.** C2 shows it is the best-behaved
  controller under a transient, which is an argument for running it, and C1 shows one replicate in
  three bloating to 591 ms, which is an argument against — consistent with the maintainer's own "quinn
  BBR is kind of bugged" note. The two are not in conflict: an intermittent fault that appears on a
  third of short runs is exactly what a soak resolves and a 120 s window cannot, which is why C6 runs
  BBRv1 rather than the C2 winner-on-paper.
- **MoQ and SRT fail in opposite directions, and this is the result that holds in every condition.**
  MoQ sheds *whole groups* and emits a syntactically clean TS — **0 continuity errors in every MoQ cell
  of C1, C2 and C4**, across four controllers, three queue disciplines and two provisioning levels —
  paying instead in content, visible as PCR gaps up to 7.1 s. SRT keeps the most bytes of any lane and
  damages them: 4,279 continuity errors under a FIFO, and **17,652–22,365 under an AQM**, because early
  deliberate drops defeat its ARQ where a full tail-drop buffer merely delayed it. **SRT's failure mode
  gets four to five times worse on exactly the queue discipline a well-run network is most likely to
  deploy**, which is the sharpest form of this finding the campaign has.
- **On the segmented lane, congestion behaviour is a receiver property, not a transport property.**
  The same lane under the same shortfall either dies at 43 s or thins cleanly at 99 % of the cap
  depending only on what the client does with a 404. This is the sharpest instance in the campaign of
  something the whole segmented arm keeps running into: **on a lane whose transport holds no session
  state, almost every behaviour worth measuring has been pushed up into the client**, so a figure
  attributed to "segmented HTTP" is very often a figure about one client's error handling. T6 found
  the same thing for failover; here it is worth a factor of three in delivered rate and the difference
  between a live feed and a dead one.
- **Where MoQ and SRT trade content for liveness and integrity for content, in-order fetching refuses
  both trades — and that refusal is what kills it.** An idempotent `GET` for an immutable object has
  no thinning behaviour of its own, so a client that will not skip has nowhere to go under sustained
  shortfall but backwards through the window. This is [T5](test-5-network-impairment.md)'s "sheds
  time, not bytes" followed far enough to find what happens when there is no more time to shed. The
  thinning has to be *implemented* by the receiver; on the media-aware lane it comes with the
  transport.
- **The re-anchoring client's higher delivered fraction is bought with latency and granularity, and
  should not be quoted without them.** 99 % of the cap against MoQ's 45–81 % is real, but it is
  measured ~12 s behind the live edge with content lost in 12 s holes, against MoQ's 2 s buffer and
  group-sized losses. For a distribution hand-off that is the wrong side of both trades.
- **Delivered fraction is noisy; the qualitative ordering is not.** With 2–3 replicates the goodput
  numbers swing ~20 points, so treat them as indicative; the completeness/stability *ranking* is the
  firm result.

## Verdict against the pass criteria

| # | Criterion | Scored |
|---|---|---|
| 1 | Complete and reconstructable (C2–C5) | **On C2: MoQ passes on integrity at every controller (0 CC) and recovers on every controller, but only BBRv1 passes on completeness** — CUBIC loses 6–15 % of the feed through the transient and BBRv2 28–35 %, which is a hole, not deferred rate. SRT fails on damage again (53 and 5 CC) while over-delivering |
| 2 | Stable indefinitely (C6) | **Not yet reported** — the soak is specified above and has produced no result this file relies on |
| 3 | Fails gracefully when under-provisioned (C1) | **MoQ passes on every controller except BBRv3**; SRT fails on damage (4,279 continuity errors); segmented HTTP passes or fails on the client — it thins cleanly under a receiver that re-anchors, and loses the session at 43 s under the one that does not |
| 4 | Queuing delay against the receive buffer | **A property of the bottleneck queue, not of the lane.** Against a 500 ms FIFO every controller runs 520–584 ms and eats the whole 2 s buffer's headroom; against `codel` or `cake` every controller runs at 100–108 ms on a 100 ms base and the criterion is met with two orders of magnitude of margin |

## Conclusion

**The controller that looks best depends on which condition you run, three conditions have produced
three orders, and so this experiment does not yield a controller recommendation — it yields a reason not
to trust one.** Under a cap permanently too small for the feed behind a tail-drop buffer (C1), BBRv2 on
quiche is stable and complete where CUBIC bloats and BBRv1 is bimodal. On a properly provisioned path
with a competing flow passing through (C2), BBRv2 sheds 28–35 % of the feed and takes 11–13 s to recover,
CUBIC sheds 6–15 %, and BBRv1 — C1's bimodal reject — barely registers it. Put an AQM at the bottleneck
(C4) and the spread closes to 43–59 % of cap with zero continuity errors everywhere and no ordering worth
quoting. All three readings are sound, and the reason they disagree is the same each time: **a controller
that yields to a full queue is right when the queue is full because the link is too small, wrong when it
is full because a neighbour is briefly busy, and irrelevant when the queue is never allowed to fill.**
For a feed that cannot slow down, the middle case turns politeness into missing content. BBRv3 (noq) is
excluded in every condition by [#768](https://github.com/moq-dev/moq/issues/768).

**The two things that did move the outcome are the provisioning margin and the bottleneck's queue
discipline.** An AQM takes standing delay from 554–584 ms to 101–119 ms for every controller and every
transport at once — a larger effect than any controller choice in any condition here — which reframes the
"bufferbloat" framing this test inherited from upstream: the delay was the buffer's, and the controller
only determined how fast it was filled. And C5 turns the margin into the one number this experiment can
hand an operator: **provision at ≥ 1.2× content rate for the MoQ lane and ≥ 1.5× for a segmented one**,
above which every controller is comfortable and below which delay climbs steeply toward the receive
buffer that has to absorb the next transient. The segmented figure is higher for a structural reason —
each segment fetch is a line-rate burst, so its queueing is set by burst shape rather than average
headroom, which C5 and C1 independently measured at 336 and 337 ms.

**The MoQ lane's one serious loss in this experiment is concurrency, and it is one replicate.** Three
feeds through a single congested bottleneck collectively delivered 3.76 Mb/s of a 15 Mb/s link — 25 % —
where three SRT feeds delivered 84 %. Individual shares below 1/N are expected; a *total* that collapses
as feeds are added is not, and a delay-sensing controller behind a permanently full FIFO is a coherent
mechanism for it. Since C4 shows an AQM removes the standing delay that would drive such a collapse,
the obvious prediction is that this largely disappears under `codel` or `cake` — which is both cheap to
test and the difference between an artefact of a deep tail-drop buffer and a real limit on trunking
multiple services over one path. Until it is run, this is the experiment's most important open item.

**What does not vary is the failure mode, and that is the transferable result.** Across three
conditions, four controllers, three queue disciplines and two provisioning levels, the MoQ lane loses
*content* and never *integrity* — **0 continuity errors in every MoQ cell run** — with the cost appearing
as PCR gaps of up to 7.1 s where groups were skipped. SRT does the opposite everywhere, and for the same
reason each time: not being congestion-responsive, it takes its share rather than yielding — it actually
**gained** rate through the C2 transient — and pays in continuity errors. **Its damage scales with how
well-behaved the network is**: 53 and 5 errors on a provisioned FIFO, 4,279 on an under-provisioned FIFO,
and 17,652–22,365 under an AQM, because early deliberate drops defeat ARQ where a full tail-drop buffer
only delayed it. Thinned-but-clean against complete-but-damaged is the real choice, and it is stable
across every condition in a way that no controller ranking is.

**Under congestion the three data planes fail three different ways — but only two of those failures
belong to a transport.** MoQ thins and SRT damages, and each does so because of what its protocol
does with a shortfall. Segmented HTTP does whatever its receiver does: `tsp -I hls` slides backwards
through the live window and loses the session at 43 s, while a client that re-anchors on a 404 thins
in whole segments at 99 % of the cap with a clean TS. **The lane is not fragile under congestion; the
shipped client is.** That is the finding, and it is a different claim from the one the `tsp` row on
its own would support.

Two things still separate the lanes once the client is matched. The re-anchoring client's
completeness is bought at ~12 s behind the live edge with content lost in 12 s holes, against MoQ's
2 s buffer and group-sized losses — better numbers, worse properties for a hand-off. And the thinning
that MoQ gets from its transport has to be built into the receiver here, which is precisely the work
that the two available clients have not done.

The controller wording in [`docs/architecture.md`](../docs/architecture.md) §8.4 / §8.5 is **not**
changed to name a controller, because the finding promoted from here is that no single condition can
name one. What is promotable is the provisioning rule, the AQM result, and the failure-mode split.

## Next steps

- **Re-run C3 properly.** The highest-value item, because it is the only measurement suggesting the
  media-aware lane has a real scaling limit: aggregate captured for *every* cell, `cake` beside the
  FIFO to test whether the collapse is the buffer's, CUBIC's aggregate to separate a delay-based
  collapse from a MoQ one, and replicates.
- **Re-run the segmented C2 cells with the competing flow's own throughput recorded**, so a delivery
  collapse can be attributed to the impairment rather than inferred from it.
- **Read the C6 soak out** when it completes: per-role RSS trend, respawn count, and continuity events
  with timestamps. It is the only condition addressing permanence, and the one that decides whether
  BBRv1's C1 bimodality is a transient artefact or a standing fault. **Grade the relay's RSS slope
  against [T9](test-9-performance.md)'s knee rather than against zero**, because a rising slope is the
  expected behaviour here and not by itself a finding: the `quinn-proto` per-stream slot mechanism
  predicts linear growth to a plateau at baseline + ~99 MB once ~10,000 uni slots are filled, then
  ~+8 MB/h. What decides it is whether the slope *breaks* where the slot count predicts and where the
  ceiling lands; a slope that holds straight through the predicted knee is a different mechanism and is
  the reportable outcome.
- Add **replicates** (≥ 5) for delivered-fraction confidence; the qualitative ranking is already clear
  at 2, and C2's separation between controllers (0.4 % against 35 %) is far wider than the replicate
  spread.
- **Never let a cleanup job run against a live results tree again.** A janitor deleting captures to
  protect the disk destroyed four of six C3 aggregates, which was the most valuable data in the matrix.
  It should have excluded any cell still running *and* whatever the condition needs summed.
- **Run the segmented lane long enough at 8 Mb/s to see the `tsp` client die**, since 60 s only shows
  the trajectory. The prediction is a 404 at roughly the point four segments per minute of lost ground
  consumes a nine-segment window, and it is worth having the number rather than the extrapolation.
- **Hold the latency budget equal before quoting the 99 %.** The re-anchoring client sits ~12 s behind
  the edge; capping it near MoQ's 2 s would say whether the delivery advantage survives a matched
  liveness target or was only ever the extra buffer.

## References

- Upstream discussion this test came from, and where the C1 numbers were reported:
  [#2432](https://github.com/moq-dev/moq/pull/2432) (CC knob + methodology).
- Extends [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md) (over-provisioned matrix, CC knob, backends).
- Impairment method and SSH-safe lane: [test-5-network-impairment.md](test-5-network-impairment.md).
- Upstream: [#2468](https://github.com/moq-dev/moq/pull/2468) (backend-specific CC defaults),
  [noq #768](https://github.com/n0-computer/noq/issues/768) (BBRv3 panic).
- Findings destination (once settled): [`docs/evidence.md`](../docs/evidence.md) §3.3.

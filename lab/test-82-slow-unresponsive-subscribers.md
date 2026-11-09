# Test 82: slow and unresponsive subscribers on the current relay

**State: run and graded: 24 matrix cells and 12 supplementary cells, on current main and the previous QUIC stack.**

## Objective

A primary distribution serves every head-end of a region from one relay, so a head-end whose process or output path stalls must cost the other head-ends nothing, must cost the relay an amount a planner can provision, and must come back on its own. [T25](test-25-isolation-under-abuse.md) found the victims isolated and the relay's memory set by abandoned-session retention, about media rate × idle timeout per killed session, on a build that predates the relay's present delivery path: upstream's own QUIC stack with a 4 MiB send window per connection, ingest paced by a group's fastest reader, and whole frames shed from a group's front. T25 measured only the victims, and its unresponsive reader was a full pipe, never a peer that stops acknowledging.

Three questions, on current `main`:

- **Isolation:** do slowed, stopped or frozen subscribers cost a healthy subscriber of the same track anything?
- **Cost:** what does each unresponsive subscriber cost the relay, and does it grow with how long the subscriber stays stuck?
- **The stuck subscriber's own fate:** does a slowed subscriber accumulate latency or lose groups, and does a stopped or frozen one return to the live edge, exit, or hang?

## Environment

| Component | Build |
| --- | --- |
| `moq`, `moq-relay` | upstream `main` at `bad28cefd5` (`~/bin-bad28cef-thin`); the stack control is `3c0daa21b` (`~/bin-3c0daa21-thin`), the last build on the previous QUIC stack. Each cell records its build. |
| Host | the laptop (M3 Pro, 18 GB), loopback, no other timing work and no build during a run |
| Source | `contrib-10m.ts` (1080i25 H.264 on PID 111, which also carries the PCR, MP2 on 121, AC-3 on 123, 9.95 Mb/s, an I-frame every 1.2 s, open GOP), played live with `tsp -P regulate --pcr-synchronous` into `moq import ts` |
| Relay | `--auth-public '**' --quic-gso=false --quic-congestion-control delay --quic-idle-timeout <cell>`, `/metrics` on the internal listener; defaults otherwise: no cache capacity, a 30 s cache window, a 4 MiB send window |
| Subscribers | every one an `export ts --delay 2s` drained by [`t82-reader.py`](scripts/t82-reader.py), victims and abusers alike; every client dials with the cell's idle timeout. The session negotiates `moq-lite-06`. |

## Procedure

[`t82-slow-consumer.sh`](scripts/t82-slow-consumer.sh) runs one cell. The publisher starts 3 s before `t0`, and every subscriber starts at `t0`: two victims and N abusers. The baseline window is 20–45 s, the event starts at 45 s, and the cell ends at 170 s. Each reader logs, every 0.1 s, its bytes and, per PID, its PES count and last PTS. The rig samples the relay's and every export's RSS and process state every 0.5 s, and scrapes the relay's counters every second. Lag is the difference of two subscribers' last video decode timestamp on one wall clock (the DTS, or the PTS where a PES has no DTS). The export re-stamps PCR, so PCR would time the export, not the programme.

| Arm | Abusers | Event at 45 s | Idle timeout | Probes |
| --- | --: | --- | --- | --- |
| `control` | 0 | none | 10 s | the instrument's noise; the RSS baseline |
| `healthy32` | 32 | none | 10 s | the cost arms' null at equal concurrency |
| `r1` | 32 | SIGSTOP every abuser's export for 40 s | 10 s | cost per frozen session |
| `r2` | 32 | as `r1` | 30 s | whether that cost grows with time stuck |
| `r3` | 32 | as `r1` | 30 s, send window 16 MiB | whether the send window is the bound |
| `slow` | 1 | the reader drains at half the clip rate for 60 s | 10 s | latency or loss |
| `stop` | 1 | the reader reads nothing for 60 s; the export runs and acknowledges | 10 s | T25's full pipe, with the abuser measured |
| `freeze5`, `freeze30` | 1 | SIGSTOP the export for 5 s or 30 s | 10 s | recovery inside and beyond the idle timeout |
| `pt-control`, `pt-slow`, `pt-stop` | 0, 1, 1 | as named, on the passthrough lane | 10 s | the lane's share of the subscriber's fate |

SIGSTOP freezes the whole export: it neither reads its socket nor acknowledges, which is what a hung head-end process looks like to the relay. The `stop` and `slow` abusers acknowledge throughout, and only their output backs up. The matrix runs every media-aware arm except `r3` twice, and the others once, in interleaved order. It runs `control`, `healthy32`, `r1` and `r2` once on the stack control.

```bash
i=0
for c in control r1 slow stop freeze5 freeze30 healthy32 r2 r3 pt-control pt-slow pt-stop \
	control r1 slow stop freeze5 freeze30 healthy32 r2; do
	i=$((i + 1)); MOQ=~/bin-bad28cef-thin lab/scripts/t82-slow-consumer.sh "$c" "/tmp/t82/$i-$c"
done
for c in control healthy32 r1 r2; do
	i=$((i + 1)); MOQ=~/bin-3c0daa21-thin lab/scripts/t82-slow-consumer.sh "$c" "/tmp/t82/$i-noq-$c"
done
python3 lab/scripts/t82-grade.py /tmp/t82 --csv lab/results/t82-summary.csv
```

**Calibration on the first control, before any abuse cell.** The first `control` cell failed two of the original instruments.

- The original instrument read the last PTS. In decode order that steps back by up to 0.24 s and forward by up to 0.36 s on this clip's B-frames, so the two identical victims differed by up to 0.6 s against a 0.5 s criterion. The reader now logs the decode timestamp.
- The idle relay's RSS is a sawtooth. It climbs at the ingest rate as the cache fills, then drops 15–45 MB when the cache's 30 s window reclaims. Peak minus baseline over a 40 s window read 21 MB with no event, against a 5 MB null criterion. Every estimator of a level change spread 10–15 MB (sd) on that control, and ranged up to ±40 MB.

So criterion 2 now uses medians over short windows, 32 abusers instead of 16 (halving the null per session), and a null range of ±40 MB in place of 5 MB. The four-abuser slope cells were dropped. The partial `r1` cell running at the time was deleted unseen. No threshold of criteria 1, 3 or 4 changed.

**Supplementary cells, added after the matrix and graded by the same criteria.** The matrix left four questions open, so twelve cells were added, numbered 25–36.

- By the replicates the laptop had 4.6 GB in swap, and one relay's RSS fell to 9.8 MB, below its own cache. macOS RSS leaves out swapped and compressed pages. From cell 25 on, [`t82-footprint.py`](scripts/t82-footprint.py) samples the relay's physical footprint (`proc_pid_rusage`), which counts them, and the grader takes criterion 2's windows on it too.
- Suffix `-rs` gives the relay a stateless-reset secret (`--listen-reset-secret`), which lowers moq-quic's reset interval from 20 ms to 1 ms.
- Suffix `-np` exports with `--mux-rate 0`, which leaves the output unpadded.
- Suffix `-f` exports with `--follow 10s`, and `-fs` with `--follow 10s --stitch`.
- `slow150` is `slow` held for 150 s, in a cell that ends at 260 s.
- `KEEP=1` keeps the captures, which [`t82-burst.py`](scripts/t82-burst.py) slices by the reader's clock.

```bash
i=24
for c in healthy32 r2 r2-rs r2-rs stop-np slow150 freeze30-f r1-f; do
	i=$((i + 1)); MOQ=~/bin-bad28cef-thin lab/scripts/t82-slow-consumer.sh "$c" "/tmp/t82/$i-$c"
done
i=$((i + 1)); MOQ=~/bin-bad28cef-thin KEEP=1 lab/scripts/t82-slow-consumer.sh stop "/tmp/t82/$i-stop-keep"
for c in healthy32 r2; do
	i=$((i + 1)); MOQ=~/bin-3c0daa21-thin lab/scripts/t82-slow-consumer.sh "$c" "/tmp/t82/$i-noq-$c"
done
MOQ=~/bin-bad28cef-thin KEEP=1 lab/scripts/t82-slow-consumer.sh freeze30-fs /tmp/t82/36-freeze30-fs
python3 lab/scripts/t82-burst.py /tmp/t82/33-stop-keep a1 40 41 105.0 105.5 105.5 106
```

Three grader faults were fixed before grading, and no threshold changed:

- The export's clock line differs on the passthrough lane and on the previous build, and the first parser missed both forms.
- Criterion 2.3 applies only where the freeze outlasts the idle timeout, so `freeze5` is not graded on it.
- The `slow` and `stop` windows end at the event's own end, not at 105 s.

## Hypotheses and pass criteria, fixed before running

**Criterion zero: the stimulus happened.** A cell failing it is void, not graded.

- Before the event, every abuser read within 5 % of victim 1's bytes over 20–45 s.
- A frozen abuser's export is in state `T` at every sample from 1 s after the SIGSTOP to 1 s before the SIGCONT.
- The `slow` reader's rate over 50–100 s is within ±10 % of half the clip rate.
- The `stop` reader gains at most 64 KiB over 46–105 s, and its lag behind victim 1 rises by at least 50 s over the window. That rise is the lag instrument's positive control.
- For the cost arms, `healthy32`'s level change L and growth G (both defined in criterion 2, taken at the same times with no event) each lie within ±40 MB.

**Criterion 1: isolation (H1).** In every arm, each victim, over 45–170 s:

1. delivers video and both audio PIDs' PES counts within 0.5 % of the other victim's and of the mean of its lane's `control` victims;
2. stays within 0.5 s of victim 1's video PTS at every row from 20 s;
3. has 0 continuity errors in its capture;
4. never raises its export's `dropped` or `gaps` counter after 20 s;
5. runs to the end.

**Criterion 2: cost per frozen session (H2).** All times are after the SIGSTOP, and M[a, b) is the relay's median RSS over that window.

- The level per session is L/N, where L = M[4, 9) − M[−6, 0). The send window fills in about 3.4 s at the media rate, so this is taken after it is full.
- The growth per session is G/N, where G = M[24, 29) − M[4, 9). It is taken in `r2` and `r3`, whose sessions live 30 s.

Two models predict these:

- The send-window model predicts L/N ≤ 4 MiB + 1 MiB (5.24 MB) and G/N ≈ 0.
- T25's retention model predicts the cost grows at the media rate for as long as the session lives: L/N ≈ 8 MB, and G/N ≈ 25 MB over the 20 s.

The ±40 MB null range is 1.25 MB per session at N = 32. The criteria:

1. H2 holds if L/N ≤ 6.5 MB in every `r1` and `r2` cell, and G/N ≤ 2.5 MB in every `r2` cell. T25's model holds instead if G/N ≥ 12 MB. If neither holds, the measured law is reported and H2 fails.
2. `r3` shows which quantity binds. If its L/N exceeds `r2`'s by more than 2.5 MB, the send window binds; otherwise the client's flow-control credit or something else does. The result is reported either way.
3. The relay closes every frozen session at its idle timeout: N connections close between idle − 1 s and idle + 5 s after the SIGSTOP, and three remain at idle + 5 s. This was to be read from `sessions_failed_total{kind="idle_timeout"}`, but a relay configured by flags, with no stats node, exports that series and `stale_groups_total` with no samples. So it is read from the relay's log, one `session accepted` and one `connection closed` line per connection, with the same thresholds. The relay's stale-group count is not available.
4. What the relay returns after the sessions close is reported, not graded, because macOS's allocator decides it.

**Criterion 3: the slowed subscriber (H3: the design trades loss for bounded latency).** Over 55–105 s, the `slow` abuser:

1. keeps its lag behind victim 1 at or below 4 s (the 2 s delay, a 1.2 s GOP and margin);
2. delivers at least 25 % of victim 1's video PES;
3. grows its export's RSS by at most 32 MB.

A lag that grows through the window fails H3, and its slope is reported.

**Criterion 4: recovery (H4: recovery is deterministic).** From the end of each condition (the `slow` and `stop` windows, the SIGCONT in `freeze5`, `freeze30` and the cost arms), each abuser:

1. within 10 s (15 s after `freeze30` and the cost arms), either returns to within 0.5 s of victim 1's video PTS and stays there to the end, or exits;
2. never hangs. A hang is an abuser that is alive, with its reader reading, but has no new video PTS for more than 10 s.

An abuser still more than 0.5 s behind at the deadline fails. Exits, with their logged cause, are counted; an exit passes this criterion and is reported as a finding.

## Limits, fixed in advance

- Loopback has no round-trip time and no loss, so this tests a stuck subscriber process, not a congested path; [T8b](test-8b-congestion-control.md) and [T31](test-31-congestion-capacity-ladders.md) cover the path.
- One relay, no tiers. A frozen downstream relay is a session of the same kind but holds the larger peer budget, and is not run.
- The negotiated draft is `moq-lite-06`. `moq-lite-07-wip`'s stale drops are opt-in and not exercised.
- RSS is macOS's, and its cache sawtooth is the null's floor; L/N includes any group payload the frozen sessions pin in common, so it bounds the per-session cost from above. N stops at 32, so hundreds of stuck head-ends are a linear extrapolation.
- Every abuser is the shipped CLI misbehaving. A hostile client is out of scope.

## Results

Per-cell figures are in [`t82-summary.csv`](results/t82-summary.csv). "Main" is `bad28cefd5`; "previous stack" is `3c0daa21b`.

### Isolation

In all 36 cells, both stacks:

- every victim's video PES count matched the other victim's to within 0.1 %;
- every victim capture had 0 continuity errors;
- no export's `dropped` or `gaps` counter rose after 20 s;
- every victim ran to the end.

Victim lag stayed within 0.32 s, with one exception. In the supplementary previous-stack `healthy32` cell, a single 0.1 s row read 0.56 s, at 39.7 s, before any event. No slowed, stopped or frozen subscriber, up to 32 at once, reached a healthy one.

### Cost per frozen session

Per session, in MB. G is taken only where the sessions live 30 s.

| Build | Cells | RSS L/N | RSS G/N | Footprint L/N | Footprint G/N |
| --- | --- | --: | --: | --: | --: |
| main | `healthy32` ×3, the null | −0.01, 0.18, 0.09 | 0.20, 0.00, −0.29 | 0.46 | 0.46 |
| main | `r1` ×2, `r1-f` | 0.51, 0.31, 0.86 |  | 0.91 (`r1-f`) |  |
| main | `r2` ×3 | 0.47, −0.23, −0.91 | 0.07, −0.56, 0.92 | 0.87 | 0.37 |
| main | `r2-rs` ×2 | 0.90, 0.21 | 0.93, 0.56 | 0.95, 0.96 | 0.44, 0.43 |
| main | `r3`, 16 MiB send window | 0.74 | 0.23 |  |  |
| previous stack | `healthy32` ×2, the null | −0.06, 0.34 | −0.48, −0.79 | 0.11 | 0.39 |
| previous stack | `r1` | 7.29 |  |  |  |
| previous stack | `r2` ×2 | 5.49, 0.63 | −1.18, 2.18 | 8.78 | 26.32 |

On main, the footprint's null grows 0.46 MB per session-equivalent in each window with no event. Net of the null, a frozen session costs 0.4–0.5 MB, and nothing more while it stays frozen. RSS agrees on main, within its ±1.25 MB-per-session null. The footprint was back at its pre-freeze 104 MB 35 s after the idle close.

On the previous stack, the footprint shows T25's retention:

- The relay grew from 121 MB before the freeze to 1,194 MB 25 s into it, the media rate per frozen session (9.95 Mb/s for 20 s is 25 MB).
- At the end it was still at 305 MB, 180 MB above its level before the freeze.
- RSS read the same cell as 0.6 and 2.2 MB per session, because the retained pages had been swapped or compressed. It caught the growth only in cell 24: an L/N of 5.5 MB, and 693 MB above baseline after the close.

### Idle close

Every frozen session closed at its idle timeout, 10.00–10.09 s or 30.01–30.09 s after the SIGSTOP, leaving three sessions, on both stacks.

- On main, 6–15 of each 32 closed as `transport idle timeout`, which drops the connection silently. The rest closed as `cancelled`, and those clients ended the instant they resumed.
- On the previous stack, all 32 closed as `connection error: closed`.

### The slowed subscriber

| Arm | Lag, max | Lag slope | Video PES vs victim | Export RSS growth | End |
| --- | --: | --: | --: | --: | --- |
| `slow` ×2, half rate for 60 s | 31.3 s | 0.48 s/s | 20 % | 23 MB | live 0.5 s after the throttle lifts, behind a 31× burst |
| `slow150`, half rate for 150 s | 111.7 s | 0.76 s/s | 12 % | 40 MB | the export exits at 123.6 s |
| `pt-slow`, passthrough | 14.6 s | 0.22 s/s | 53 % | 39 MB | live 0.2 s after |

The export writes a constant-rate, padded output and blocks when its reader does, so its output runs at the reader's pace. Meanwhile the relay's 30 s cache evicts the groups the export has not read (`current group evicted … Old`), and the export's `dropped` count goes from 0 to 474. A lag past 30 s therefore means video absent for long stretches, not media buffered for that long.

`slow150`'s export quit with "the source's clock runs -1046665.1 ppm off ours, past the 30 ppm the output's may follow". The cause was its own output's pace, not the source's clock.

### Recovery

| Condition | Main | Previous stack |
| --- | --- | --- |
| `freeze5` ×2 | live 0.2 s and 1.5 s after the SIGCONT |  |
| `freeze30` ×2 | exits 0.4–0.5 s after |  |
| `freeze30-f` | exits 1.0 s after, the returning broadcast taken for "another publisher instance" |  |
| `freeze30-fs` | live 2.8 s after, capture at 0 continuity errors |  |
| `r1` ×2, `r1-f`; 32 each | all 96 exit within 2.5 s | all 32 exit within 0.5 s |
| `r2` ×3; 32 each | 78 exit within 10.4 s; **18 hang**, until 18–60 s after | all 64 exit within 13.5 s |
| `r2-rs` ×2 | all 64 exit within 9.5 s |  |
| `r3` | all 32 exit within 0.9 s |  |
| `stop` ×3 | live 0.5–0.6 s after, behind a 61× burst |  |
| `stop-np` | live 0.5 s after; peak 2.5× the line rate |  |
| `pt-stop` | live 0.1 s after; peak 3.7× |  |

Every exit is the export's own, after it reconnects:

- On main, 246 of the freeze cells' exits end with "broadcast did not return … follow=0ns", 9 with "moq: no error", and 1 with the replacement error `freeze30-f` shows.
- On the previous stack, 82 end on a transport error reading the catalog, and 12 as on main.

A hung abuser kept reading and logging (`media skipped upstream; resuming at the next group`) and received nothing.

**Why resumed sessions hang on main.** A client whose connection the relay dropped silently learns of it only from a stateless reset. The relay sends one in answer to a packet for a connection it no longer has. moq-quic sends at most one per `min_reset_interval` per endpoint (20 ms by default, 1 ms with a reset secret) and drops any other inciting packet unanswered.

All 32 clients resume in the same millisecond, and their keep-alives (0.3 × the idle timeout, 9 s here) stay in phase. Each round therefore answers one to three of them: the hung sessions of the third `r2` cell end at 94.0, 103.1, 112.1, 121.1, 130.1 and 139.1 s. Their own idle timers did not end them within 30 s either. The likely reason, inferred rather than measured, is the RTT sample from acknowledgements buffered across the freeze, which stretches three probe timeouts past the idle timeout.

With a secret, both `r2-rs` cells ended every session within one keep-alive round. At a 10 s idle timeout, `r1` hung none in 96, and the previous stack hung none.

**The burst after an output stall.** A `stop` subscriber's export keeps its PCR grid while its reader reads nothing, and writes every missed slot when the reader resumes. In the first 0.5 s it wrote 75.1 MB (1.2 Gb/s): 96.8 % null packets and 42 video PES, carrying PCRs that span 60.4 s. After that it ran at 10.1 Mb/s with the PCR in step with the wall clock. Unpadded (`stop-np`), the peak is 2.5× the line rate. The export's RSS rose 74–78 MB at the resume.

The reader here drains as fast as it can, so it is live 0.6 s later. A receiver that plays out by PCR would sit 60 s behind live instead, the length of the stall.

## Grading

- **Criterion zero** held in all 36 cells; none is void.
- **Criterion 1 (H1): holds on both stacks.** 35 of 36 cells pass. The exception is the one 0.56 s sample above, in a cell with no event.
- **Criterion 2 (H2): holds on main, fails on the previous stack.**
  - On RSS, as fixed: on main, L/N is at most 0.91 MB in every `r1` and `r2` cell, and G/N at most 0.93 MB in every `r2` cell. On the previous stack, `r1`'s L/N of 7.29 MB exceeds 6.5, and its RSS growth fits neither model.
  - On the supplementary footprint: main reads 0.87–0.96 MB (L/N) and 0.37–0.44 MB (G/N). The previous stack's G/N of 26.3 MB meets T25's retention model (12 MB or more).
  - 2.2: `r3` exceeds `r2` by less than 2.5 MB, so on main the send window does not bind.
  - 2.3 passes in every cell whose freeze outlasts the idle timeout.
- **Criterion 3 (H3): fails.** Both `slow` cells exceed 4 s of lag and fall below 25 % of the video; their export RSS (23 MB, within 32) passes. `pt-slow` fails on lag and on export RSS (39 MB). A slowed subscriber pays both latency and loss.
- **Criterion 4 (H4): fails on main, holds on the previous stack.** On main, 18 of 96 `r2` sessions hang. Every other abuser returns or exits in time, and with a reset secret none of 64 hung.

## Conclusions

**Architectural, and favourable.** One relay keeps its healthy subscribers' media whole whatever its slowed, stopped or frozen subscribers do, on both stacks and with 32 frozen at once.

On current main, a frozen session costs the relay about 0.5 MB, which does not grow while the session stays stuck, and the relay frees it at the idle timeout. 1,000 frozen head-ends would extrapolate linearly to about 0.5 GB.

T25 measured the relay's price as retention at the media rate until the idle timeout. That is a property of the previous QUIC stack, and it reproduces here on that stack: 32 frozen sessions took that relay to 1.2 GB within 25 s. At that rate one frozen head-end costs about 37 MB at a 30 s idle timeout.

**Architectural, and a limit.** A subscriber stuck longer than the idle timeout loses its session. With default flags the export then exits, so recovery is the head-end's supervisor's job unless it runs `--follow --stitch`.

A subscriber slower than the stream cannot be served at the live edge with all its media: the relay holds 30 s and evicts the rest, so loss is inherent. The added latency is the export's.

**Implementation defects, each with a measured trigger:**

1. **Resumed sessions hang (main).** They hang for 18–60 s when many resume after a freeze longer than a 30 s idle timeout: 18 of 96 sessions. The cause is the 20 ms endpoint-wide stateless-reset interval against in-phase keep-alives. The previous stack does not do this. Remedy tested: `--listen-reset-secret`, with which none of 64 hung.
2. **Padding back-fill.** The export writes a stalled output's missed padding all at once: 60 s of PCR in 0.5 s. Remedy tested: `--mux-rate 0` (a 2.5× peak). A PCR-paced receiver behind it is not tested.
3. **Follow misreads the reconnect.** After the subscriber's own reconnect, `--follow` takes the unchanged publisher for a replacement and the export exits. `--stitch` works around it (live 2.8 s after a 30 s freeze) at the price of a flagged program switch.
4. **The export does not shed on a slow output.** It blocks instead of shedding to the live edge, and after about 80 s at half rate exits with a clock-drift error that blames the source.

**Not established:**

- hundreds of stuck head-ends (N stops at 32, and the reset drain with more clients or real-network jitter is untested);
- a frozen downstream relay;
- T25's kill-and-relaunch churn on main;
- a slowed subscriber without padding.

## Follow-up: Parts B–E, criteria fixed before running

The first report left four questions open. Each part below fixes its hypothesis and criteria before its first cell. The rig, builds, clip and instruments are those above, except where a part says otherwise. Parts C and D use _light_ abusers: their export writes straight to `/dev/null` with no reader, so 64 of them fit the laptop. A light abuser's fate is read from its own log, from the first `session terminated` or `session error` line, which is the instrument the hang analysis above used.

### Part B: a PCR-paced receiver behind a stalled export

Defect 2's consequence was inferred, not measured: that a receiver playing out by PCR, behind an export that back-filled a 60 s stall, sits about 60 s behind live.

In each cell, abuser `a1`'s export feeds a _valve_ (`t82-reader.py` with the `stop` throttle, forwarding what it reads), then a receiver, then a reader that logs the receiver's output. A chain control `k1` runs the same chain with no throttle, in the same cell. The cell ends at 230 s.

The two receivers:

- `tsp -P regulate --pcr-synchronous` (TSDuck 3.45), which forwards every packet, nulls included, at the pace of its PCR;
- the campaign's groomer, `mpegts-pacer` at `97f3a38`, the build in T76's soak: `stdout 9950000 --latency-ms 1000 --max-latency-ms 8000 --stall-ms 1000 --on-stall mute`.

The arms are `stop-tsp`, `stop-np-tsp`, `stop-pacer` and `stop-np-pacer`, one cell each, on main. L_a and L_k are the lags of `a1`'s and `k1`'s receiver output behind victim 1's video DTS. B is k1's median L_k over 20–45 s, and te is 105 s, when the valve resumes.

**HB:** behind a stalled, padded export, a PCR-paced receiver plays the back-filled padding in real time, so its output stays about the stall's length behind live.

1. Valid: `k1` runs to the end with L_k within B ± 0.5 s at every row from 20 s, and the valve gains at most 64 KiB over 46–105 s.
2. HB holds for a receiver if, in its padded cell, L_a − B ≥ 50 s at every row from te + 10 s to te + 40 s.
3. The remedy holds for a receiver if, in its unpadded cell, L_a is back within B + 0.5 s by te + 10 s and stays there to the end.
4. If the padded cell's L_a is back within B + 0.5 s by te + 10 s, HB fails for that receiver. Otherwise L_a at te + 10, te + 40 and te + 100 s is reported.

Also reported: the receiver's output rate after te, its output's video PES after te against victim 1's, and continuity errors in its output.

### Part C: the reset drain with 64 clients

The arms are `r2` with light abusers: `r2x32l` (32) once, `r2x64` (64) twice, and `r2x64-rs` (64, with a reset secret) once. Each freezes for 40 s at a 30 s idle timeout, and each cell ends at 300 s. A session is _late_ if it ends more than 15 s after the SIGCONT (criterion 4's deadline for the cost arms), and the _drain_ is its last end minus the SIGCONT.

**HC:** without a secret, the drain grows with the number of clients, since each keep-alive round answers one to three of them.

1. Valid: `r2x32l` has at least one late session, so light abusers reproduce the hang.
2. HC holds if both `r2x64` cells drain for longer than 60 s, the longest at 32 clients. Their late counts are reported against 2–11 of 32.
3. The remedy holds at 64 if every session of `r2x64-rs` ends within 15 s of the SIGCONT.
4. Victims are graded by criterion 1.

### Part D: T25's killed-peer storm on main

The arms are `storm` (idle timeout 10 s) twice and `storm30` (30 s) once on main, and `storm30` once on the previous stack. From 45 s, every 5 s, the rig SIGKILLs every abuser export and starts 40 new light ones. Twelve generations run, 480 sessions, and the last is killed at 105 s. The cell ends at 170 s.

F is the relay's footprint, F0 its median over 39–45 s, and S the sessions it holds, read from its log (accepted minus closed). P is the largest F − F0 over 50–110 s, H the largest S − 3 over the same window, and P/H the cost per held session.

**HD:** on main, a killed peer costs the relay about what a frozen one does.

1. HD holds if P/H ≤ 1 MB in both main `storm` cells and the main `storm30` cell. T25's retention holds instead if P/H ≥ 5 MB. Otherwise the measured law is reported.
2. Reported: whether F is back within 40 MB of F0 by 105 s + idle + 30 s.
3. Victims are graded by criterion 1.

### Part E: the slowed subscriber unpadded

The arm is `slow-np` twice, on main, graded by criterion 3's thresholds unchanged.

**HE:** the latency comes from the export's blocked writer, not from its padding. HE holds if both cells' lag exceeds 4 s (criterion 3.1 still fails) and their video share exceeds 25 % (criterion 3.2 passes), against 20 % padded.

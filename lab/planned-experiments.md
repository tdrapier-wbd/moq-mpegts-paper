# Specified but not yet executed

These protocols were designed as part of the campaign and are recorded here so an external engineer
can execute them reproducibly.

**This file holds only what is outstanding.** Everything measured lives in the per-test file it
belongs to; where an experiment is partly executed, the entry here is reduced to the *remaining*
conditions plus a pointer to the results. An entry is deleted once nothing of it is outstanding — a
to-do list that accumulates its own history stops being readable as a to-do list. Results,
corrections and the reasoning behind them belong in `test-*.md` and
[method-notes.md](method-notes.md).

**Prioritised by what a result could change, not by how interesting it is.** The ranking is stated once,
immediately, as P0/P1/P2; the reliability families it introduces are specified in full under [The
production-reliability programme](#the-production-reliability-programme); and the older per-experiment
protocols follow, each reduced to what is outstanding.

Placeholders `<EC2_IP>` / `<subscriber-home-ip>` carry the machine-specific values from
`INSTRUCTIONS.local.md`.

---

## The programme

Every experiment names its own open items and most of them are worth doing eventually. This is the list
that decides what runs next.

**The campaign has changed shape, and the ranking has to change with it.** Until now it asked whether
MoQ can carry a broadcast mux at all, and the entries that led this list were the ones that would
answer that. That question is largely answered, and a second architecture — segmented HTTP carrying
MPEG-TS, over HTTP/3 rather than the TCP everything here was measured on — has become a serious
candidate rather than a comparison point. **The question the programme now serves is which of the two
can be run permanently, at scale, by an operations team, for years.** That is a different question from
the one the existing entries were designed for, and it is dominated by sustained reliability,
deterministic recovery, continuous media integrity and operational predictability rather than by
latency.

**Three tiers, and the tier is decided by what a result could change, not by how interesting it is.**

- **P0 — could change a viability conclusion for either architecture.** If the result comes out one
  way, a `docs/` conclusion changes side or a lane stops being recommendable. Nothing else competes
  for a run window while a P0 is runnable.
- **P1 — establishes where one architecture is superior.** The comparative body of the paper. These
  sharpen or reverse a verdict *row*; they do not decide viability.
- **P2 — completeness.** Worth having, unlikely to change a conclusion. A P2 that starts looking like
  it could change one has been mis-tiered; move it.

Two standing rules keep this from becoming a wishlist. **An experiment earns a place only if a named
document says something it could falsify** — the falsifiable claim is quoted in the entry. And **an
entry is deleted once nothing of it is outstanding**, results going to the `test-*.md` file that owns
them.

The families introduced for the reliability programme are specified in full under
[The production-reliability programme](#the-production-reliability-programme); the tiers below carry
the ranking and the one-paragraph reason, and point at the specification.

---

### P0 — could change a viability conclusion

**P0-1. ~~The end-to-end re-run against a grid-sliced export.~~ Done —
[T19](test-19-pcr-grid-verification.md) measurement 10.** [#3351](https://github.com/moq-dev/moq/pull/3351)
merged as `4cf216149` and the re-run answers open question 1 in [Evidence](../docs/evidence.md): **an
evenly spaced exporter cadence does not clear the P1 repetition gate.** At the pipe the fix is complete
— adjacency 0 %, release error p95 1.70 ms, upstream's own gate green on the merged build. On the wire,
against #3351's own merge-base, it drops 36 % fewer packets and halves stuffing but leaves **12.2 % of
intervals above 40 ms, 811 continuity errors and 2,126 ms of latency** against a 118 ms pre-fix control.

**What P0-1 left behind was ours, and measurement 11 discharges it.** The residue is that a coded frame's
bytes belong to its own 40 ms, so a 417 kB I-frame is 357 ms of carrier — a mux schedule the source's
CBR muxer supplied against a T-STD buffer and that decode timestamps do not carry. Building a new one is
the groomer's job and the groomer had three defects stopping it, the load-bearing one being that PCR
re-insertion could only take a slot the content scheduler declined and a burst declines none. Fixed,
**the lane passes: 0 of 20,193 intervals above 40 ms over 300 s, 0 continuity errors, 0 drops, 0
underruns, exact CBR.** The cost is a buffer sized by the peak coded frame — 3.6× its carriage duration
sufficed across three sources spanning an 18× peak-to-mean range, 2.5× did not.

**What remains on this line is one coefficient and one platform.** The 3.6× rests on three sources on
one rig, and the claim that it is derivable from a contribution encoder's published VBV is reasoning,
not measurement. Widening it is **P2**: it changes a sizing rule, not a viability conclusion. The
delivery latency this lane now carries (~2.4 s median) is #2967's regression, tracked separately.

**P0-2. ~~The segmented lane over HTTP/3 — the reordering cell, re-run substrate-matched.~~ Done —
[T20](test-20-segmented-http3.md).** It falsified the row it was aimed at, and for a reason nobody
had ranked: the 0.98-against-0.19 separation was a **packet-size artefact**, not a substrate one.
Equalised, the cell reads 0.44 segmented/TCP, 0.18 segmented/HTTP/3 and 0.13 media-aware, with the
last two overlapping. The substrate change also *won* the segmented lane the loss cell and the 30 s
outage cell. [Comparison](../docs/comparison.md) §14's reliability row and
[Evidence](../docs/evidence.md) §3.3 are updated.

**What P0-2 leaves behind, and it is not small.** The H3 receiver is `ffmpeg -c copy -f mpegts`, which
re-muxes and therefore regenerates continuity counters and PCR: on the H3 and H1 arms those columns
grade the receiver, not the wire. **A byte-faithful HTTP/3 HLS receiver is now the outstanding
instrument** — `tsp -I hls` is byte-faithful but cannot negotiate H3, and FFmpeg can negotiate H3 but
cannot pass bytes through. Until one exists, no *carriage-fidelity* claim can be made about the
segmented lane over HTTP/3, only delivered-rate and programme-loss claims. Building it is a fetcher
that reads the playlist over H3 and concatenates segments verbatim; it is a small job and it upgrades
every cell T20 measured.

**P0-3. The exporter's PCR does not survive a source discontinuity — upstream fix, then re-soak.**
*The groomer half is closed; the upstream half is now the single item between this architecture and a
viability claim.*
**Falsifies:** the headline conformance result's applicability to a permanent service.

[T21](test-21-permanence-soak.md) put the groomer inside a long run for the first time and found the
recovered media rate departing at ~9 minutes while the wire stayed perfectly conformant. Our groomer
had divided real packets by a media time that had stopped advancing — that half is **fixed,
regression-tested and pushed** (`mpegts-pacer` `5ab84cd`).

[T23](test-23-pcr-discontinuity-classes.md) has since **characterised the upstream half as a class**,
which is what step 2 below asked for, and the answer changes the shape of what remains:

- **The 33-bit rollover is carried correctly end to end** — a 30.080 ms step in modulo arithmetic,
  6,259 PCRs within ±500 ns, 0 continuity errors. This was the item that made the defect unavoidable
  for a permanent feed, and it is **discharged**.
- **Forward jumps recover** in 238 ms.
- **A rewind costs its own duration in programme**, one-for-one from 1 s to 600 s, because the
  exporter's scheduler is monotonic in media time. The recovery burst — 97,225 packets, 18.3 MB —
  is itself large enough to overrun the groomer.

**What remains is upstream's, and it is narrower than it looked.** The exposure is the splice, the
source failover and the encoder restart, not a clock that stops of its own accord. Sequence:

1. **Report upstream.** *(Done — measurements posted to
   [#2833](https://github.com/moq-dev/moq/issues/2833), which already owned the mechanism for SI
   tables; T23 adds that the stall stops the whole programme, that the cost is linear, and that the
   rollover is unaffected. See [upstream contributions](upstream-contributions.md).)*
2. ~~**Characterise the trigger precisely.**~~ **Done — T23.**
3. **Then** re-soak per [F2](#f2-permanence-soak), 24 h and 7 days, with the groomer in path.
   **Running.** The source problem that made this impossible is solved rather than waited out: the
   lab has no live feed and every clip in it is minutes long, so `lab/scripts/ts-continuous-source.py`
   replays one with the timeline advanced across the join. It is graded before use — 0 backward PCR
   steps, 0 discontinuity indicators, 0 continuity errors, join interval indistinguishable from the
   median — and the lane confirms it, crossing the first pass boundary at `gap_ms=0` where the
   equivalent loop rewind costs 62,760 ms (T23 arm B). Conditions are in
   [T21 § the re-soak](test-21-permanence-soak.md#the-re-soak-on-a-continuous-timeline). The 7-day
   arm remains outstanding after the 24 h arm reports.

**The residue of the rewind finding is closed and it was ours.** T23's encoder-restart arm lost 44 s
of programme *and* 54,168 packets to a groomer overrun, and only the first is upstream's. Sweeping the
groomer's hard cap against the same stimulus puts the threshold between 20 s and 50 s against a 44.69 s
rewind: at a cap above the rewind the arm loses **0 packets and produces 0 continuity errors**, and the
headroom costs two packets of steady-state occupancy when it is not being used. **No pacer change is
warranted** — the right cap is the deployment's worst expected rewind times its bitrate, the drops are
already counted when it is set too low, and a large default would spend memory on every feed.

**P0-3b. The servo saturates, and the buffer walks to a rail.** *Ours, unaddressed, and separate from
the above.* On the 8-vCPU secondary the rate estimate stayed healthy for a full run while the buffer
drifted monotonically from 9,008 to 18,105 packets against a 6,300 set point. The release servo's
authority is ±`RATE_SERVO_GAIN` = ±5 %, so any standing rate-estimate error beyond 5 % saturates it and
occupancy runs to the cap (drops) or to zero (underruns) regardless. **Question:** is the ±5 % clamp
adequate for the estimator's real accuracy, and what is that accuracy over hours? **Minimum
experiment:** the existing diagnostic lane on both hosts with the fixed estimator, reading
`buffer_packets` against `latency_target_ms` — the fix improved estimator accuracy (9.42 Mb/s against a
true ~9.5, where the old build read 8.67), so this may already be smaller than it was, and that is
worth measuring before changing a control constant. **Changes the conclusion if:** the buffer cannot be
held at its set point over hours on either host, which would mean the cushion is not a designed
quantity but an accident of host speed.
**Now instrumented rather than separately scheduled:** the running re-soak is on the same 8-vCPU
secondary and reads exactly these quantities for 24 h, so it answers this or it does not, without a
second run. The early reading is that the estimate **oscillates** about the true rate rather than
standing off it — 8.79–10.08 Mb/s about ~9.5 — with the buffer in a 5,992–8,001 band and no monotone
walk. That amplitude exceeds the ±5 % authority at its extremes, so the question is live: an
oscillation the servo can ride is not the same as the standing error that walked the buffer before.

**P0-4. ~~Silent media-plane failure — detection.~~ Done for the MoQ lane —
[T22](test-22-silent-media-plane-failure.md).** It confirmed the property it was aimed at and bounded
it: **the transport never detects a stalled source** (120 s frozen, zero non-benign log lines across
publisher, relay and exporter — not a timeout race, since the 30 s and 120 s arms agree), while the
media plane detects it in **1.69–1.88 s** from two independent signals, with no false positive on the
control. A frozen *relay* is the one case QUIC catches, at **34.3 s**. `--on-stall continue` holds a
byte-perfect programme-free carrier indefinitely and makes the failure undetectable downstream.
[Architecture](../docs/architecture.md) §9.1 is updated and its monitoring design survives, with PCR
progression promoted to the primary detector because it needs nothing from MoQ, nothing from the groomer
and no cooperation from the sender.

**What P0-4 leaves behind, and it is a real gap.** `SIGSTOP` freezes a process *cleanly*. A real
encoder that stalls may half-work — some tracks advancing and not others, or timestamps repeating while
bytes still flow — and neither detector above is obviously sufficient for that. **A partial-stall arm is
new P1** and is specified in [F3](#f3-silent-media-plane-failure). The segmented lane's half of F3 is
unrun and stays unrun while that lane lacks a byte-faithful receiver (P0-2's residue).

**P0-5. A hardware IRD and a TR 101 290 analyser, soaked ≥ 72 h (Gate 2).** *Blocked on apparatus; P0
on leverage.* Every conformance number in this campaign is graded by software written or configured by
the same people who built the thing under test: enough to falsify a design, not enough to accept one.
A soak settles PLL lock, the buffer model, slow clock drift and discontinuity handling at once, and it
closes the one question [T12](test-12-dual-path-handoff.md) cannot answer in software — whether a real
merge engine agrees with our reference receiver on an ST 2022-7 pair. **≥ 72 h for an arithmetic
reason:** the PCR base wraps every 26.51 h. Pair it with P0-3 so one borrowed week yields both verdicts.
Every boundary it tests now has a substitute runnable here first, which is what turns a borrowed week
into measurement rather than debugging. Protocol below under *Hardware TR 101 290 P1/P2 soak*.

---

### P1 — establishes where one architecture is superior

**P1-1. The failure-injection and recovery matrix, both lanes, scored in media rather than in
sessions.** The single largest comparative gap. Infrastructure failures have been probed one at a time
and reported as recovery *times*; what a distributor buys is programme continuity, and the two are not
the same number. Specified as [F4](#f4-failure-injection-and-recovery).

**P1-2. The scaling model, both lanes.** Not a maximum observed once. For MoQ the fan-out knee on
record is the *host's*, because every relay cost figure was measured with subscribers co-resident with
the relay and they cost more CPU than the relay serving them; drive them from the 8-vCPU box and the
knee becomes the relay's. For segmented HTTP the question is the split between origin and cache as
client count rises, which one nginx with `proxy_cache` in front of it indicates and does not establish.
Removes a caveat from a load-bearing number in [`economics.md`](../docs/economics.md). Specified as
[F5](#f5-the-scaling-model).

**P1-3. A capped-stream relay-memory arm.** *Only time on the rig that exists.* C6 converged
asymptotically on **2.03×** the ceiling [T9](test-9-performance.md) predicted, decaying +24.60 →
+1.82 MB/h and still not flat at 14 h. Connection scaling is ruled out — flat across 0–4 subscribers,
a five-connection leg in the same range as two — so a second term is adding ~100 MB over the ten hours
past the knee. One run bounds it: `--server-quic-max-streams 1024` isolates the slot-dependent part
(T9: 91.4 MB against 189.5 MB), a logged group count says whether the excess tracks groups, and
`/proc/pressure/memory` beside RSS tells a decaying slope from kernel reclaim. It is the difference
between budgeting 100 MB and 200 MB per ingested channel. **Its upstream standing is weaker than it
looks, and that is the reason to cap the streams rather than argue.**
[#2745](https://github.com/moq-dev/moq/issues/2745) is **closed as not-planned**: the maintainer
root-caused the retention to `quinn-proto` recycling one receive-stream state per stream ever accepted,
which is not moq state and is bounded by `max_streams`. Our 14 h leg — posted there after the close,
and unanswered — measured 2.03× that bound, so either the ceiling model is incomplete or a second term
exists that is moq's. Only if the excess survives a 1024-slot cap is there anything to re-file. Note
this is a *sizing* question now, not a stability one: the audience term was measured and is zero.

**P1-4. MoQ's distributed redundancy model.** The paper has a 1+1 result at the *egress* and no model
above it. Multiple relays, publisher redundancy, receiver-side relay selection, and what a relay or
path failure costs in programme rather than in reconnect time. Specified as
[F6](#f6-moq-distributed-resilience).

**P1-5. Segmented HTTP's distributed redundancy model.** The mirror of P1-4, and the lane's strongest
theoretical claim: that independent addressable objects and multiple paths give near-seamless failover
without a session to re-establish. It is asserted from the specification and demonstrated on one
filesystem. Includes the two-host segment store — both packagers writing identical names into a
*consistent* store is free on one filesystem and is the actual engineering across two hosts — and the
CloudFront edge. Specified as [F7](#f7-segmented-distributed-resilience).

**P1-6. Sustained capacity degradation.** *Nothing new needed for the MoQ half; ~20 minutes.* C3's
mechanism is settled — the shed is per-subscriber deadline shedding, tracking `--latency-max` from
4.29 Mb/s at 500 ms to 10.35 at 30 s at `n=2`, past the uncontended single-flow rate — but the sweep
does not say where the knee is, and it is already at 62 % of cap by 8 s. The comparative half is new:
the same bandwidth ladders against the segmented lane, scored on what an operator actually needs, which
is the worst impairment absorbable without losing programme. Specified as [F8](#f8-congestion-and-capacity).

**P1-7. Interoperability, separated from standardisation.** Three legs, all previously ranked and all
still wanted: Cloudflare with a provisioned scope (T11a) as the strongest available test of relay
neutrality, since the anonymous attempt negotiated draft 18 cleanly and returned no data, which is the
expected outcome without publish and subscribe tokens; a `moq2ts` broadcast through a `moq-dev` relay
(T11b), publisher-only, so the question is only whether the relay forwards objects whose catalog it
cannot parse and whether an early `PUBLISH` poisons namespace registration; and a broadcast profile for
`moq-interop-runner`, which extends shared infrastructure rather than building a private rig. The
segmented half is the harder one to design honestly and is specified as
[F9](#f9-interoperability-in-practice).

---

### P2 — completeness

**P2-1. Operational observability and supportability, assessed comparably.** Largely a structured
review rather than a measurement, and it should say so. Specified as [F10](#f10-observability).

**P2-2. Resource-exhaustion and isolation.** Whether one bad receiver can degrade others. Reviewed
rather than exploited. Specified as [F11](#f11-isolation-under-abuse).

**P2-3. A standby packager joining an already-running feed.** The production shape, and the cell a
co-started pair cannot measure. Cheap on the two hosts; sits behind P1-5, which establishes the steady
state it is a perturbation of.

**P2-4. Differential delay on a real pair.** `netem` on the cross-AZ path models geographically
separated origins — which is why one region was the right choice, since impairment can be added to a
low-delay pair and cannot be subtracted from a cross-region one. It models rather than measures.

**P2-5. C3 replicates.** One per cell today. The per-flow split is known not to reproduce and the
aggregate is, so two more replicates would put an error bar on the only number being quoted — but the
qualitative result is already clear at one and P1-6 is the better use of the same rig time.

---

### Blocked on apparatus

**B-1. T12's churn arms.** The recovered-leg and late-join cells wait on
[#2779](https://github.com/moq-dev/moq/issues/2779), because an exporter numbering continuity counters
from process state cannot produce a byte-identical pair after a restart however many hosts it runs on.
They also need a grader `t12-merge-oracle.py` is not yet. The comment on #2779 is the only thing we can
do to move this.

**B-2. The full interop suite against a `moq2ts` subscriber (T11c).** Blocked until they publish one.
Worth planning the matrix now so the run is ready when it lands: it is the comparison that would settle
which lane preserves what, particularly whether their null-stripping and SPTS-from-MPTS behaviour costs
conformance where ours does.

**B-3. A true CBR hardware source (T15's residual).** The transparency result makes a real CBR source
the interesting variable rather than a nicety, and nothing in the lab produces one.

**B-4. The segmented plane's low-latency arm at equal conformance.** No client we have realises it; the
only receiver that could is a commercial ABR-to-TS gateway, which is the same apparatus block as P0-5
in a different guise.

**B-5. Multi-programme carriage through a media-aware edge (MPTS).** Only interesting where the edge is
media-aware — a byte cache serves an unusual TS payload exactly as nginx does, so asking it of a plain
cache re-measures nginx. If the question is whether a commercial packaging edge rejects a
multi-programme segment, it has to be that product. T17's 40-service figures remain scaled from one
service rather than measured on an MPTS.

---

### No longer worth doing

- **T19's arrival oracle on a bigger host** — run; 7.45 % on two vCPU and 7.45 % on eight, at zero CPU
  pressure. The caveat it existed to retire is retired.
- **The clean two-host 1+1 arm** — run twice, byte-identical both times, 0 residue.
- **The full 1+1 with two publishers, two relays and two paths** — run. A publisher, relay, exporter and
  groomer per host across two availability zones, sharing nothing but a verified-identical source file:
  **single-track content is 46,778 of 46,778 shared datagrams identical, counters included**, so the
  strongest positive result in the paper stands with no shared component at all. A seven-stream mux over
  the same topology reaches 75.56 %, the residue being the same packets in a different order because the
  exporter interleaves by arrival. Located and posted to
  [#2829](https://github.com/moq-dev/moq/issues/2829); multi-track identity is now an upstream fix rather
  than another cell here. See [T12](test-12-dual-path-handoff.md).
- **Recovering C3's aggregates** — all six recovered, and the cell now prints them, so the failure mode
  cannot recur.
- **C3 under an AQM** — run. `cake` cut RTT from ~550 ms to 100 ms and the collapse survived at 48 %/40 %
  of cap, so C4's prediction is falsified rather than untested. Do not re-run it as a rescue.
- **Hunting a lower-layer mechanism for C3** — the `latency-max` sweep discriminated: the shed tracks the
  budget over a 2.4× range at 0 continuity errors, so there is nothing left for a shared-lane mechanism
  to explain. P1-6 is the sizing residue, and it is a different question.
- **Filing the PCR output-position finding, and the conformance test** — filed as
  [#3334](https://github.com/moq-dev/moq/issues/3334) and [#3335](https://github.com/moq-dev/moq/pull/3335),
  with hedged comments on #2829/#2779. The maintainer then **wrote the fix**,
  [#3351](https://github.com/moq-dev/moq/pull/3351), which merged as `4cf216149` and verifies both
  against its own merge-base and on a merged build (adjacency 50.31 % → 0 %, release p95 70.3 → 1.7 ms).
  The end-to-end re-run it unblocked is **done** (P0-1 above) and answers open question 1: no.
- **The `mpegts-pacer` positional guard** — in, with five tests and the T19 capture as the regression
  fixture. The groomer now measures the assumption it used to make.
- **More transparency clips through lanes already characterised** across a 2.75× bitrate spread.
- **The arm B1 wire-cost leg on the EC2 path**, whose HTTP-layer term is path-independent and whose
  framing multiplier is measured elsewhere; and per-track wire-byte attribution.
- **The segmented HTTP/3 arm.** Run — [T20](test-20-segmented-http3.md). Both the original motivation
  (explaining the lanes' loss difference, killed earlier by [T8](test-8-srt-vs-moq.md) matching the
  controller) and its successor (whether the lanes still differ under *reordering* once both sit on
  QUIC) are now answered: they do not. What survives is the byte-faithful H3 receiver noted under
  P0-2, which is an instrument gap rather than an open question.

---

### What to bundle, because prompt count is the scarce resource

Grouped so nothing in a group contaminates anything else in it. Each group is one run.

**Group A — the two-host group.** P1-2's fan-out knee and P1-5's two-host segment store. Both need both
boxes and neither can share a host with a timing measurement. Run the fan-out knee **last**, because it
deliberately saturates a box.

**Group B — the cheap ladder, and it can share a run with almost anything.** P1-6's MoQ half. It runs in
network namespaces on the primary against a stopped loop publisher, needs no new apparatus, and its
grading is a per-cell aggregate rather than a timing comparison — so it is the right filler for a window
whose main item is posting, reviewing or building.

**Group C — the long runs, and there are now two of them.** P1-3's capped-stream memory arm, and P0-3's
soak. A soak measures the machine it runs on, so neither can share a window with anything, and both want
days rather than minutes. Start at the end of a session and read at the start of the next. P0-3's two
lanes must run on *separate* hosts or in separate windows; a segmented origin and a MoQ relay sharing a
box measure each other.

**Group D — the injection matrix.** P1-1 and P0-4 share a harness: both interrupt a component and grade
the media that came out. Build the grader once. P0-4 is the subset where the component does not die, so
it costs one more arm rather than one more rig.

**Do not bundle:** anything from the blocked list, whose windows are set by apparatus rather than by
us. *(P0-2 was on this list as an open-ended build task; it is done, and the build took about an hour
of the window — the open-ended part turned out to be the FFmpeg option-propagation defect, not the
QUIC stack.)*

---

## The production-reliability programme

The families the tiers above point at. Each is specified the same way — **question, hypothesis where
one is worth stating, setup, metric, decision criterion, why it matters to primary distribution, and
what existing evidence already answers** — because the last of those is what stops the programme
re-measuring what it has.

**One measurement convention governs the whole family and is worth stating once.** Every metric here is
expressed in *programme*, not in *sessions*. "Recovered in 4 s" is not a result; "lost 3.2 s of media
and 41 continuity errors, then ran clean" is. A lane that reconnects instantly and resumes at the live
edge, discarding what it missed, has failed a test that a lane reconnecting slowly and refetching has
passed, and only a media-domain metric can tell them apart. This is the same distinction
[T6](test-6-relay-resilience.md) already found the hard way between the media-aware exporter, which
skips to the live edge, and the segmented client, which refetches from the store.

**And one scoping rule.** Both lanes must be impaired at the same point in the topology and graded by
the same instrument, or the comparison measures the rig. Where a lane has no equivalent of a component
— there is no MoQ "origin" and no segmented "relay" — the equivalence is stated in the entry rather
than assumed.

### F1. Substrate-matched impairment — run, see [T20](test-20-segmented-http3.md)

- **Question, as asked.** Does segmented HTTP keep its reordering advantage when it runs over HTTP/3
  rather than TCP?
- **Hypothesis, as written.** "It keeps most of it… the advantage should narrow rather than vanish."
- **Outcome.** Wrong twice over. It does not narrow, it goes: 0.18 over HTTP/3 against the
  media-aware lane's 0.13, overlapping across replicates, which is below the "row changes side"
  threshold this entry set at ~0.5. And the premise was wrong too — the advantage was never a
  substrate property. Equalising packet sizes drops the segmented lane to **0.44 on TCP as well**,
  because the original cell gave it 34 kB packets against the media-aware lane's 931 B ones while
  `netem` reorders per packet.
- **What the decision criterion could not have caught.** This entry specified the arm to add and not
  the property to control. Had the H3 arm been run without normalising MTU and offloads, it would have
  returned 0.995 — "the advantage survives, strengthened" — and the artefact would have been confirmed
  rather than found. **The residual rule is in [method-notes](method-notes.md)**: report the measured
  packet-size distribution beside any per-packet impairment result.
- **What replaces it.** Not a re-run. The instrument gap under P0-2: a byte-faithful HTTP/3 HLS
  receiver, without which the H3 arm cannot carry a carriage-fidelity claim, only a delivered-rate one.

### F2. Permanence soak

- **Question.** Does either lane remain in a *stable operating state* as uptime grows, or does it merely
  survive?
- **Hypothesis.** Survival is not in doubt on either. What the soak is looking for is monotonic drift in
  something that is supposed to be stationary — resident memory, thread count, file descriptors,
  end-to-end latency, buffer occupancy — and the MoQ lane already has two candidates: a relay ceiling
  still creeping at 14 h and a publisher thread count that grew 22 → 86 over 26 h, decelerating but not
  stopping.
- **Setup.** 24 h first, then 7 days, one lane per host. MoQ: publisher → relay → exporter → groomer.
  Segmented: packager → origin → client → groomer. Same clip, same rate, same groomer, both on the WAN
  path rather than loopback, because a loopback soak measures the host. Sample every 60 s.
- **Metric.** Continuously: TS continuity errors, PCR interval distribution and accuracy, PTS/DTS
  relationships, PSI/SI cadence, TDT/TOT presence and age, media-sequence or object progression,
  delivery latency, jitter, groomer buffer occupancy, per-role CPU and RSS, thread and fd counts,
  session or connection churn, reconnects, and restarts. Every one of them as a *time series*; the
  endpoint value alone would have hidden all three drifts already found.
- **Decision criterion.** Pass is: zero continuity errors, no PCR regression against the 1 h baseline,
  and every resource series either flat or converging with the asymptote stated. Any series still rising
  at a rate that would exhaust the host inside a year is a fail whether or not the run completed.
- **Why it matters.** This is the use case. A permanent feed is not a long demo, and the failure modes
  that matter are the ones with a time constant longer than a test.
- **Existing evidence.** [T8b](test-8b-congestion-control.md) C6 is 14.006 h on one MoQ topology: 0
  continuity errors, 0 respawns, 9.512 Mb/s mean, relay RSS converging asymptotically on baseline +
  200.5 MB and still +1.82 MB/h in the final hour. [T9](test-9-performance.md) has 26.5 h phased soaks
  on an older build. **The segmented lane has never been soaked**, which makes its half of this the
  larger gap of the two.

### F3. Silent media-plane failure

> **Done for the MoQ lane, as [T22](test-22-silent-media-plane-failure.md).** It passes: the transport
> detects a stalled source never — 120 s frozen, zero non-benign log lines — and the media plane detects
> it in 1.69–1.88 s from two independent signals, with no false positive on the control. A frozen relay
> is caught by QUIC's idle timeout at 34.3 s, 18× slower. `--on-stall continue` makes the failure
> undetectable downstream. Recovery is clean and the programme clock skips exactly the outage.
>
> **Two parts remain.** (1) A **partial stall** — an encoder that half-works, advancing some tracks and
> not others, or repeating timestamps while bytes still flow. `SIGSTOP` freezes a process cleanly and
> cannot produce this, and neither detector above is obviously sufficient for it; a PCR that keeps
> advancing over a frozen picture defeats the primary detector outright. **P1**, and the highest-value
> remaining item in this family. (2) The **segmented lane's** half, which stays blocked on that lane
> lacking a byte-faithful HTTP/3 receiver.

- **Question.** How does each lane detect that the connection is healthy and the programme is no longer
  advancing, and how long does it take?
- **Hypothesis.** Neither detects it at the transport layer, because at the transport layer nothing is
  wrong. Detection has to come from the media plane, and the two lanes have different natural signals:
  MoQ has object arrival and subscription state, segmented HTTP has playlist freshness and media-sequence
  progression. The segmented lane is expected to be the worse case, because a cache can serve the last
  good segment indefinitely and there is no connection to drop.
- **Setup.** Induce, per lane, without killing the process: a publisher whose input stalls while its
  session stays up; a packager that stops writing new segments while the origin keeps serving the old
  playlist; a relay that holds the subscription open and forwards nothing; a cache pinned on a stale
  playlist while the origin has moved on. `SIGSTOP` on the encoder and a frozen input file give the
  first two without code.
- **Metric.** Time from the last advancing media until each candidate detector fires, for each detector
  separately: PCR progression at the groomer, media-sequence or object progression, wall-clock age of
  the newest media against the wall clock, and expected-versus-actual media time. Plus what the
  *transport* said throughout, which is the point.
- **Decision criterion.** A lane passes if at least one detector fires within one groomer cushion of
  the stall and does so without a false positive across the F2 soak. A detector that cannot distinguish
  a stall from normal segment-duration silence has failed, which is the specific trap on the segmented
  lane.
- **Why it matters.** It is the failure a primary-distribution operator is least protected against: an
  alarm set on process liveness or connection state reports green while the programme is off air.
- **Existing evidence.** Both lanes have an observed instance and neither has a designed test.
  [T5](test-5-network-impairment.md): past ~20 % loss the segmented client lost 82 s of programme while
  the origin returned nothing but 200s, so origin error rate cannot detect it.
  [T9](test-9-performance.md)/[T6](test-6-relay-resilience.md): a relay takeover livelock left the
  process alive at 100 % CPU with no accepts for hours. [Architecture](../docs/architecture.md) §9.1
  designs against both; the design is untested.

### F4. Failure-injection and recovery

- **Question.** How much programme is lost or corrupted before continuous delivery is restored, for each
  failure, on each lane?
- **Setup.** Two axes. *Transport*: loss, reordering, jitter, bandwidth reduction, and outages of
  500 ms, 5 s, 30 s and 5 min, applied with `netem`/`tc` at the same point on both lanes. *Infrastructure*:
  kill and restart the publisher, the relay, the origin, the packager, the edge cache, and the network
  path; then two at once. Equivalences to declare: the MoQ relay and the segmented cache are the
  mid-path node; the MoQ publisher and the segmented packager are the source node; MoQ has no origin
  and segmented HTTP has no subscription state, and those asymmetries are results rather than gaps in
  the matrix.
- **Metric.** Per injection: seconds of media lost, continuity errors, PCR discontinuities and PTS
  regressions, wall-clock recovery time, time to *stable* operation as distinct from first byte, and
  whether an operator had to intervene. Recovery time alone is explicitly not the headline.
- **Decision criterion.** Ranked by media lost, not by recovery time. A 30 s outage that costs 30 s of
  programme is a worse result than a 60 s outage that costs none, and the ladder exists to find where
  each lane crosses from the second behaviour to the first.
- **Why it matters.** Contracted content has no allowance for a hole. The distinction between shedding
  time and losing bytes is the one a downstream buffer can or cannot absorb.
- **Existing evidence.** Substantial, and this family should reuse rather than repeat it.
  [T6](test-6-relay-resilience.md) has origin restart and relay return: the MoQ exporter resumes in ~4 s
  and *loses the media produced during the outage* by skipping to the live edge, where a retrying
  segmented client refetches it and loses nothing — though neither TSDuck's HLS input nor FFmpeg's
  demuxer survives an origin restart at all. Relay-failure detection is 30–33 s by default and ~10 s
  tuned. [T5](test-5-network-impairment.md) has the loss and reordering ladders and the availability
  window at 7.7–12.2 % applied loss. What is missing is the outage ladder, the simultaneous failures,
  and a single grader applying one media-domain metric across all of it.

### F5. The scaling model

- **Question.** What is the shape of the cost curve as receivers increase, and where does each lane
  place the load?
- **Hypothesis.** MoQ places it on the relay and grows with channels rather than with audience;
  segmented HTTP places it on the cache and leaves origin load roughly flat. Both are indicated and
  neither is established as a *model*.
- **Setup.** MoQ: subscribers driven from the 8-vCPU secondary against a relay on the primary — the
  point being that every existing figure has them co-resident, so the knee on record is the host's. Ramp
  to saturation, attributing CPU, RSS, fds and threads per role. Segmented: the same client ramp against
  origin-only, then origin behind nginx `proxy_cache`, then behind a CloudFront distribution, recording
  origin requests separately from edge requests at each step.
- **Metric.** Per-role CPU, RSS and network against receiver count; per-subscriber delivered rate; for
  the segmented lane, the origin-request count as a fraction of client requests — the cache offload
  ratio, which is the whole scaling argument in one number.
- **Decision criterion.** A fitted curve with its breakpoint identified and the binding resource named,
  for each lane. "It reached N" is not the deliverable; the deliverable is what an operator multiplies.
- **Why it matters.** Fan-out at near-zero marginal cost is R2, the requirement the incumbent IP
  architectures fail, and the reason the problem is open at all.
- **Existing evidence.** [T9](test-9-performance.md) has per-subscriber egress holding 9.49–9.65 Mbps to
  N = 55 and 527 Mbps aggregate before collapsing at N = 70 — **host-limited, on loopback**; relay RSS
  35.9 → 130.3 MB over the same ramp, and ~3.22 MB of fixed baseline per subscriber. Both origins serve
  100 concurrent clients at ~992 Mb/s with no knee. Memory *growth* is settled and is not an audience
  term: flat at ~28 MB/h from 0 to 8 subscribers, driven by ingested groups at ~9 KiB each.
  [T11](test-11-interop.md) has the cache offload indicated at one node — two clients cost the origin
  nine fetches rather than eighteen.

### F6. MoQ distributed resilience

- **Question.** Can MoQ be given a redundancy model that keeps the *programme* continuous, rather than
  one that reconnects the session quickly?
- **Hypothesis.** Not with relay reselection alone. The measured floor is one detection interval, and
  the exporter resumes at the live edge, so a reselect costs whatever the detection took. Continuity has
  to come from a receiver holding two subscriptions at once, which is the 1+1 result generalised above
  the egress.
- **Setup.** Two relays fed by one publisher; then two publishers of the same source feeding two relays;
  a receiver subscribed to both, selecting per ST 2022-7. Fail each element in turn — one relay, one
  path, one publisher — and then the receiver's preferred leg.
- **Metric.** Programme continuity across the failure, graded by the merge oracle in the byte domain:
  media lost, continuity errors, PCR discontinuity. Reconnect time recorded but subordinate.
- **Decision criterion.** Hitless means no media lost and no continuity error at the merged output. Any
  other outcome is reported as the number of seconds of programme it cost, and compared against F7's
  equivalent.
- **Why it matters.** R6 asks for "no visible failure during contracted content", and the installed base
  implements that as 1+1 with receiver-side selection. A lane whose only answer is fast reconnection
  does not meet it.
- **Existing evidence.** The egress half is strong and should not be re-run: single-track legs are
  byte-identical across two hosts in two availability zones with no shared component, 46,778/46,778 with
  zero residue ([T12](test-12-dual-path-handoff.md)); multi-track reaches 75.56 % for a located upstream
  reason. Relay-reselect failover is 30–33 s default, ~10 s tuned, and hitless is unreachable by it
  ([T6](test-6-relay-resilience.md)). What is untested is everything between the publisher and the
  egress: multiple relays, multiple paths, publisher redundancy, and receiver-side selection *between
  relays* rather than between groomed legs.

### F7. Segmented distributed resilience

- **Question.** Can segmented HTTP exploit independent addressable objects and multiple delivery paths
  to achieve seamless or near-seamless primary-distribution failover?
- **Hypothesis.** Yes for a *serving-node* failure, because the object is addressable from anywhere and
  the client has a window in which to ask again. Probably not for a *packaging* failure, and the
  interesting cases are the partial ones — playlist available and segment not, segment available and
  playlist stale, replicas inconsistent — where the lane's statelessness stops helping.
- **Setup.** Two packagers writing identical names into a store shared across two hosts, which is the
  step never taken: on one filesystem consistency is free and across two it is the engineering. Then
  induce, one at a time: edge failure with the origin up; origin failure with the edge warm; a playlist
  that references a segment the store does not have; a segment present with a stale playlist; premature
  deletion inside the availability window; and two replicas that disagree. Content Steering last, since
  it needs a client that implements it.
- **Metric.** Media lost and continuity errors at the groomed output; origin-versus-edge request
  attribution during each failure; whether the client detected the inconsistency or served it.
- **Decision criterion.** Seamless means zero media lost with no operator action. The specific failure
  to look for is not a stall but a *silent* one: the misconfigured pair in T6 delivered ±20 s of
  time-travel that passed every continuity and PCR check, and this family must be able to catch that
  class or it is not grading the right thing.
- **Why it matters.** It is the lane's strongest theoretical claim and the basis on which the paper
  currently gives it the redundancy and recovery rows. Those rows rest on the specification plus one
  filesystem.
- **Existing evidence.** [T6](test-6-relay-resilience.md): a shared-feed active/active pair with shared
  names fails over with no measurable interruption, 3/3 runs, no receiver merge needed — **on one
  filesystem, with the standby always co-started**; a *misconfigured* pair is accepted silently and
  delivers time-travel. [T11](test-11-interop.md): objects are cacheable, measured at a single nginx
  node. [T5](test-5-network-impairment.md): the availability window is real and has a measured edge.
  Multi-CDN, Content Steering and edge/Pathway selection remain specification-only.

### F8. Congestion and capacity

- **Question.** What is the maximum impairment duration and severity each lane absorbs without losing
  programme?
- **Setup.** A shaped bottleneck stepped 20 → 8 Mb/s for 5 s, 20 → 12 Mb/s for 60 s, and 20 → 8 Mb/s
  permanently, applied identically to both lanes, under `cake` so bufferbloat is not the variable. For
  MoQ, add the `--latency-max` ladder at 1, 3, 4 and 6 s at n = 2 and n = 3, which is the knee C3's
  mechanism implies and did not locate.
- **Metric.** Backlog growth, buffer occupancy, latency growth and its recovery, media lost, continuity
  errors, and resource growth *during* the impairment — the last because a lane that absorbs a shortfall
  by buffering is spending memory to do it.
- **Decision criterion.** The headline is one number per lane: the longest impairment absorbed with zero
  media lost. Secondary is whether recovery returns to the pre-impairment operating point or to a new
  one, since a permanently deeper buffer is a latency regression that survives the fault.
- **Why it matters.** R4 asks for a bounded *and stable* budget, and R5 for degradation that does not
  turn one lost packet into a multi-second gap. A trunk is provisioned against this curve.
- **Existing evidence.** [T8b](test-8b-congestion-control.md) has the under-provisioned case on both
  lanes: `tsp -I hls` delivers 64 % and 404s at 43 s where a re-anchoring client delivers 99 %, so the
  segmented outcome is receiver policy rather than lane behaviour; provision ≥ 1.5× segmented against
  ≥ 1.2× MoQ. C3's aggregate collapse is attributed to per-subscriber deadline shedding, tracking
  `--latency-max` 4.29 → 10.35 Mb/s from 500 ms to 30 s at 0 continuity errors throughout. The step
  ladders and the segmented comparison are new.

### F9. Interoperability in practice

- **Question.** Distinguishing specification maturity from demonstrated multi-vendor interoperability,
  where does each lane actually stand?
- **Setup.** Segmented: the same TS-carrying HLS origin against independent client implementations, and
  the same client against independent packagers, scored on whether the transport stream survives
  round-trip rather than on whether playback starts. MoQ: the T11 legs — Cloudflare with a provisioned
  scope, `moq2ts` through a `moq-dev` relay, and a broadcast profile contributed to
  `moq-interop-runner`.
- **Metric.** Round-trip media fidelity against the T1 criteria: PIDs, `stream_type`, PMT descriptors,
  SCTE-35, DVB service identity, continuity. Plus, separately, whether the pairing connects at all.
- **Decision criterion.** Report the two axes separately and never collapse them. Connecting is not
  interoperating; the paper's existing result is precisely that eight MoQ relays negotiated cleanly and
  forwarded no media.
- **Why it matters.** R1. And because the comparison here is genuinely inverted — the mature,
  universally-interoperable lane is specified informationally, and the standards-track one has no
  demonstrated cross-implementation media interop — which is a result about what standardisation
  predicts, and is worth stating carefully rather than as a slogan.
- **Existing evidence.** [T11](test-11-interop.md): 6/6 third-party segmented clients pass; the MoQ
  relay matrix does not. The segmented result is scoped to a single programme; multi-programme through
  a real CDN is B-5.

### F10. Observability

- **Question.** Can an operations team run hundreds of permanent feeds and determine quickly why one has
  stopped delivering correctly?
- **Setup.** Structured comparison rather than a measurement, and it must be labelled as such. For each
  lane: what telemetry exists natively, what has to be built, what a failure looks like in each domain,
  how far a fault can be localised from telemetry alone, what tooling a broadcast engineer already owns
  that applies, and what the deployment and upgrade surface is. Grounded wherever possible in a fault
  actually induced in F3 and F4, answering "what would the operator have seen?".
- **Metric.** Per induced fault: which telemetry moved, how long before it moved, and whether it
  localised the fault to a component.
- **Decision criterion.** Judgement, stated as judgement. The reportable output is the list of faults
  for which *no* telemetry on a lane distinguishes the failing component — that list is a finding.
- **Why it matters.** R8, and it is a reliability property rather than a convenience: a fault that
  cannot be localised is a fault that stays.
- **Existing evidence.** [Architecture](../docs/architecture.md) §9 has the design and the two-domain
  correlation problem. `--stats-enabled` is off by default on the relay. The segmented lane's diagnostic
  surface is HTTP logs and manifest probes, which is mature and indirect.

### F11. Isolation under abuse

- **Question.** Can one receiver degrade the service other receivers get, on either lane?
- **Setup.** Against a running feed with well-behaved subscribers: a subscription storm; subscriptions
  to many nonexistent tracks; a client opening and abandoning sessions rapidly; a client requesting
  segments that do not exist; a slow reader that never drains. Measure the *other* subscribers
  throughout.
- **Metric.** Delivered rate and continuity at the well-behaved receivers, and relay or origin resource
  growth attributable to the abusive one.
- **Decision criterion.** Any measurable degradation of an unrelated feed is a finding and belongs in
  the paper regardless of severity. The purpose is not a security assessment; it is to establish whether
  either lane has an obvious operational weakness at scale.
- **Why it matters.** Multi-tenancy is assumed by both economic models. A relay holding per-subscription
  state is structurally more exposed than a cache serving idempotent GETs, and the paper should either
  show that or stop implying it.
- **Existing evidence.** Relay state is per-subscriber and per-track by construction
  ([Comparison](../docs/comparison.md) §2); relay memory growth is *not* an audience term, which bounds
  one obvious attack. [Control plane](../docs/control-plane.md) is design-only and carries no
  measurement. Nothing has been tested adversarially.

---
## Delivery latency at equal conformance — measured, see T18

**Both the cushion sweep and the latency cell this file used to own are now measured in
[T18](test-18-delivery-latency.md), and the framing they shared was wrong.** They asked where the MoQ
lane's PCR-repetition curve crosses zero as the groomer's cushion deepens, on the premise that
conformance is bought with depth and depth is latency. The two axes are indeed independent — repetition
sat at ~490 intervals above 40 ms with a 228 ms maximum across a ladder spanning eight times the depth,
and stayed there when groomer starvation was removed entirely — but the reason T18 gave for that was
wrong. It read the flat ladder as proof that the exporter's clustering put the gaps out of the groomer's
reach. In fact **no cushion shortens a coded frame**, and the groomer would only place a PCR in a slot
the content scheduler had declined, of which a burst offers none.
[T19](test-19-pcr-grid-verification.md) measurement 11 closes it: reserve the slot instead and the gate
clears at every depth.

**T18's prediction is scored, and it does not hold.** T18 predicted that an exporter emitting
PCR-bearing packets on an **even** ~25 ms grid would pass the gate at a 250 ms cushion.
[#2967](https://github.com/moq-dev/moq/pull/2967) delivered the even values,
[#3006](https://github.com/moq-dev/moq/pull/3006) delivered the even releases and
[#3351](https://github.com/moq-dev/moq/pull/3351) delivered the even positions; the wire failed after all
three. The gate is met, at the 250 ms cushion T18 named, by the downstream change instead. What T18 got
right is that this line was the campaign's highest-leverage run; what it got wrong is which stage owned
it.

The history #2937 had to answer is worth keeping, because it explains why the fix took the shape it did:
upstream built this fix once and abandoned it after a real IRD would not lock, so the report argued that
the failure belonged to the delivery model rather than to PCR placement, and that a bounded CBR stage
downstream absorbs what the exporter was being asked to. The placement framing avoided the earlier
attempt's trap — it adds no PCRs the source did not already justify, so it creates none of the empty
PCR-only windows that sank it — and #2967 kept that property.

**RIST against SRT on a real path.** The WAN legs have run: the path costs its round trip and nothing
more, and MoQ delivers a picture across the internet in **109 ms**. One cell did not settle — RIST reads
262–333 ms below its own loopback figure with a *rising* trend where every other arm falls, so its
apparent advantage over SRT is an unsettled window rather than a protocol property. This is the one place
a real path may separate two protocols the campaign has otherwise been unable to tell apart, and it needs
a single long run rather than new apparatus.

**A lossy WAN path.** Both T18 environments were healthy, so nothing exercised the retransmission and
jitter-buffer recovery the tunnels exist for — the case that should favour them against the media-aware
lane. Impairment on the WAN legs is the arm that could change the ordering rather than confirm it, and
[T8](test-8-srt-vs-moq.md)'s controller matrix has sharpened what it should look for: on loopback,
loss turns out not to separate the two lanes at all once both are given the same congestion
controller, and **reordering is the only impairment that does**. So the arm worth running on a real
path is the reordering one, and the loss ladder there is now a check on the controller choice rather
than on the architecture. A path carrying both at once remains the case neither rig has produced.

**Segmented HTTP over HTTP/3.** Long carried as the caveat that a shared QUIC substrate would erase
the loss difference between the two planes. That hypothesis has now been confirmed by a cheaper route
— matching the controller erases it on TCP — so this drops from load-bearing to confirmatory. It is
also still blocked on the receive side rather than the origin: `tsp -I hls` speaks HTTP/1.1 and the
box's `curl` is built without HTTP/3, so an h3 arm needs a client that both negotiates h3 and hands a
transport stream onward.

**Still blocked, and unchanged.** The segmented arm cannot reach the low end of its own envelope on free
software — no free client fetches partial segments ([T14](test-14-data-plane-comparison.md) measurement
2b) — so a like-for-like *low-latency* segmented comparison still needs the commercial ABR-to-TS
hardware the entry below requires. T18's segmented figures are therefore the classic-segment case:
3497 ms at best, 9185 ms where it comes closest to the gate.

---

## Rigs to build before the thing they measure arrives

**Two things this campaign is waiting for are not purchases but *windows*:** a TR 101 290 analyser and
IRD arrive on loan for days, and a real encoder feed is somebody else's schedule. A window spent finding
out that the rig is wrong is a window spent twice, and the campaign has just paid a small version of that
bill. [T19](test-19-pcr-grid-verification.md) found the groomer carrying an untested precondition — that
a PCR's value and its position in the byte stream advance together — which nothing exposed until an
upstream change violated it. Preconditions of that class do not announce themselves; the only way to
find the next one is to violate it deliberately. Doing that here costs an afternoon, and doing it with a
borrowed analyser on the bench costs a day of the loan.

Hence the principle: **anything that can fail for a reason other than the subject should be made to fail
before the window opens.** All three pieces below need nothing this lab does not already have, and each
converts a question that would have to be asked on the day into one that is already answered.

### A. Boundary-condition fixtures, and the groomer dry-run against them

Gate 2's value is in the boundaries rather than the steady state, because the steady state is already
measured on this rig at length. Each condition below is synthesisable with TSDuck today and gradeable
with instruments that already exist, so each can be turned from a hardware-day *question* into a
hardware-day *confirmation*. In leverage order:

**The stimuli and the instrument are now built; what remains is the pipeline.** `ts-pcr-fixtures.py`
generates every condition in this section, and `ts-pcr-selftest.py` asserts the verdict each must
produce, so the analyser's own accept-and-reject behaviour is a tested quantity rather than an
assumption — which it was not, and building it found two more defects in the analyser, both of it
failing conforming input. The wrap in item 1 is **placed 400 ms into a fixture**, which is the whole
mechanism this section asked for. Read the items below as *what has still never been run through the
groomer and a MoQ round trip*, because that is now the only part missing: a fixture passing the
analyser says nothing about what the pipeline does with the same condition, and items 1 to 4 all rest
on the pipeline rather than on the instrument.

1. **The PCR 33-bit wrap, placed rather than waited for.** The base clock wraps every **26.51 h** (see
   [method-notes](method-notes.md) §3), so it need not be soaked for: start the PCR just below the
   boundary and it arrives in minutes. `mpegts-pacer` is *designed* for it — `Slot::slots_per_wrap`
   keeps the slot index monotonic across the boundary and `forward_delta_handles_wrap` unit-tests the
   modular arithmetic — but **what is proven is the arithmetic, not the pipeline**: no stream has been
   run across a wrap end to end, through the scheduler's run-closing and the discontinuity threshold,
   let alone through a MoQ round trip whose importer has its own timeline. This is the single cheapest
   test on the list with a real chance of failing. The stimulus exists: `ts-pcr-fixtures.py wrap`
   starts 20 slots below the boundary and crosses it 400 ms in, and the analyser is asserted to unwrap
   it rather than read it as a backwards clock. Feeding it to the groomer is the outstanding step.
2. **Source-clock drift, by deliberately mis-rating the replay.** The pacer locks its output rate
   **once**, from a two-PCR warmup window plus a headroom fraction (`pacer.rs`), and derives its cushion
   once as well; neither is re-estimated. Every long run in the campaign replayed a file on the same host
   that paced it, so the source clock *was* the sink clock and the groomer has never met a source whose
   rate is not its own. ISO 13818-1 permits ±810 Hz on 27 MHz — **±30 ppm**, or 2.6 s of accumulated
   offset per day — against a headroom margin that is one-sided, so source-faster-than-estimate is the
   dangerous direction and buffer occupancy is the thing to watch rather than throughput.
   Arithmetically the margin is orders of magnitude larger than the drift and should hold; that is a
   prediction, not a measurement, and registering it before the run is the point. Substitute: replay at
   nominal × (1 ± 30 ppm) with `-P regulate`, and sample occupancy and derived latency, not just PCR.
3. **A *signalled* discontinuity.** The pacer sets and honours the discontinuity indicator and has a
   resume test, but only across its own resume — the one discontinuity the campaign has actually carried
   is the loop wrap's *unsignalled* splice. A source that flags its discontinuities is the normal case
   and the untested one. `ts-pcr-fixtures.py discontinuity` supplies it, and it is worth noting what
   that fixture already caught: the analyser was failing a legal signalled splice twice over, so had
   this been run against hardware first, the instrument would have called a conforming stream broken.
4. **Mid-stream PID change, PCR-PID change and PMT version increment.** Named in the Gate 2 protocol
   below and never synthesised through the pipeline. `ts-pcr-fixtures.py pid-change` moves the PCR to a
   second PID mid-stream, which the analyser catches on that check alone; the PMT version increment is
   still unbuilt, since it is a PSI condition rather than a PCR one. These exercise the importer's track
   model as much as the groomer, and the exporter has been seen doing it for real, reporting
   "TS track layout changed after PAT/PMT was emitted" mid-run.

**A failure in any of these is our defect, and is cheaper now than later.** Where a MoQ round trip is in
the path, a failure may also be upstream's — which is a further argument for running them now, since a
filed issue takes weeks and the hardware window does not wait.

### B. The acceptance harness, dry-run against the software reference receiver

The measurement set, the running order and the capture format should be fixed and rehearsed before the
analyser arrives, against the reference receiver the campaign already uses. What that rehearsal is for
is the rig, not the result:

- **A control ahead of every subject, pre-scripted.** Feed the analyser the source clip straight from
  disk through `rawsendmpeg2ts` before any MoQ lane touches it. That clip is measured conformant here,
  so if the analyser flags it the rig is wrong and nothing downstream of that is interpretable. This is
  the campaign's standing discipline; the reason it has to be *scripted* is that on the day there is no
  time to design it.
- **Machine-readable capture, decided in advance.** Whatever the analyser offers — CSV, syslog, SNMP
  traps — one of them has to be logged to a file, because a 72 h soak read off a GUI is not a
  measurement and cannot be re-graded later. Confirm the export path exists on the specific model
  before it ships, since this is the one detail that cannot be worked around on site.
- **A time budget, written down, soak first.** The soak is the long pole and must start on day one and
  run unattended; the boundary drills from A are short and attended. If the analyser has two inputs
  they interleave, and if it has one the drills follow the soak — which changes the order in which
  questions get answered, so decide it before rather than during.
- **Named in advance: what a *pass* looks like.** P1 and P2 sub-error by sub-error, plus PLL lock state
  and the buffer-model verdict, which is analyser-specific and not part of TR 101 290 proper. A gate
  fixed after seeing the output is not a gate.

### C. The real-source rig, and what can honestly be substituted

Every figure in the campaign comes from a looped file. Separating what a real encoder changes from what
merely *looks* different is worth doing now, because it decides which questions need the source at all:

- **Substitutable now, and listed in A:** the free-running clock (mis-rated replay), signalled
  discontinuities, the wrap.
- **Substitutable, and worth doing because it removes an artefact rather than adding one:** the loop
  wrap splice. The looped file's wrap is a real continuity event that a real source does not have, so
  some measured continuity behaviour is the rig's. A long single-pass replay of a long clip separates
  the two without an encoder.
- **Not substitutable.** Whether a *particular* encoder's PCR is itself conformant, which sets the floor
  for everything downstream and which this campaign has never had to consider because its clip is
  comfortably inside the gate; genuine scene-driven rate variation within CBR; and SI that changes
  because something happened rather than because a fixture generator was run.

The rig to have ready is therefore small: a capture point at the source, the same instruments pointed at
it, and the source's own conformance graded *before* it is used as an input — so that the first real-feed
result is not a lane verdict resting on an ungraded source.

---

## Hardware TR 101 290 P1/P2 soak (T7, P2 — Gate 2)

The load-bearing open test. Feed the live groomed egress to a hardware IRD + TR 101 290 analyser and
confirm PLL lock and a clean P1/P2 result over a **sustained soak of ≥ 72 h** — short runs can pass by
luck, and only hours→days surface slow clock drift, buffer-model violations and rare discontinuity
handling. **72 h is arithmetic rather than ambition:** the PCR base wraps every 26.51 h, so a 24 h run
spans 0.91 of a wrap period and can contain none of the events it is soaking for
([method-notes](method-notes.md) §3). Run jointly with the resource soak below so one long run yields
both verdicts. Exercise the boundaries a groomer must handle beyond steady state:

- source-clock drift; PCR discontinuities / 33-bit wrap; mid-stream PID / PCR-PID change;
- ST 2022-7 determinism under loss (the on-hardware hitless-switch drill), verifying the two egress
  legs stay byte-identical under *divergent* object-loss recovery, not only in the clean case.

**Every one of those boundaries has a synthesisable substitute that should be run against the groomer
before the hardware arrives**, so that a failure on the day is attributable to the receiver rather than
to our own untested precondition — the fixtures, and the case for them, are in
[Rigs to build before the thing they measure arrives](#rigs-to-build-before-the-thing-they-measure-arrives).

Where access exists, corroborate with a second analyser (Elecard / R&S MTS4EA / Tektronix MTS / Ateme
Titan). The precondition — which groomer topologies can produce a byte-identical pair — is already
characterised in [test-6-relay-resilience.md](test-6-relay-resilience.md), and the hand-off it enables
is graded in software in [T12](test-12-dual-path-handoff.md). This drill therefore starts from a
known-good sender pattern, and its open question is narrow: **does a real IRD's merge engine agree with
T12's reference receiver?**

---

## T14 — remaining measurements (Gate 1 + Gate 2, both data planes)

**Partly run.** Burst granularity, carriage fidelity and wire cost are measured and recorded in
[test-14-data-plane-comparison.md](test-14-data-plane-comparison.md), which also holds the rigs, the
environment and what the results do to
[comparison](../docs/comparison.md). Three cells remain, each blocked on something the lab does not
currently have.

1. **Whether a commercial ABR-to-TS gateway, run as the distributor's own edge stage, passes
   TR 101 290 P1/P2 on hardware.** Feed a MEG- or TITAN-Edge-class gateway an HLS-with-TS feed and
   grade its TS output on the Gate 2 rig — PLL lock, P1/P2 clean, PCR accuracy inside 481 ns, no
   interval above 40 ms, duration fidelity 1.000. The question is not whether a client's receiver
   relieves the distributor of the hand-off, since the distributor does not supply that receiver; it
   is whether such a box discharges the distributor's *own* grooming obligation. §4.4 of
   [comparison](../docs/comparison.md) rests on datasheet claims and this converts them into a
   finding either way. **Blocked on:** hardware. *Moves:* whether part of the broadcast-grade edge
   layer is purchasable for segmented HTTP and not for MoQ, or whether the hand-off axis closes
   entirely.
2. **The segmented plane's *low-latency* arm at equal conformance.** The general cell is measured —
   [T18](test-18-delivery-latency.md) grades every plane's delivery latency against the conformance of
   the same bytes — but its segmented arm is the classic-segment case, 3497 ms at its shallowest
   runnable cushion. What remains is whether partial segments move that, and only hardware can answer
   it: arm B2 established that parts can be *published* with MPEG-TS free of charge and that no free
   client fetches them, so the only receiver that could realise the low-latency arm is a commercial
   ABR-to-TS box. The sub-question this cell used to carry — how far 200–330 ms parts close the 240×
   burst gap — is **answered**: not at all, because nothing free gets at the parts. **Blocked on:** the
   same hardware as measurement 1, which is why the two have merged. *Moves:* §5's structural floor,
   and only for the segmented plane.
3. **Multi-programme carriage in practice.** HLS normatively excludes it ("Transport Stream Segments
   MUST contain a single MPEG-2 Program"), and a cache does not parse the payload. Publish TS
   segments containing an MPTS through a real CDN and record: does it deliver them, does a conformant
   analyser accept the result, and does an ABR-to-TS gateway. **Blocked on:** a CDN account.
   *Moves:* this now carries the *whole* of MoQ's carriage-fidelity advantage **on mux content**,
   because T14 showed single-programme carriage in TS segments is verbatim and
   [T3](test-3-opaque-transparency.md) confirmed it across three clips and the full service layer — so
   it is the one cell where a negative result for HLS is the interesting one. The clock half of the
   axis is settled separately and is not waiting on this: the segment-head PAT/PMT injection costs
   file-domain PCR accuracy, and grooming closes it.

**Deliberately not queued.** Wire cost's per-packet framing is derived from
[T9](test-9-performance.md)'s real-path measurement rather than measured on the segmented-HTTP leg,
because loopback's 16384 B MTU cannot price a packet and the HTTP-layer term that *is* measured is
path-independent. Re-running arm B1 on the EC2 path under
[`t9-overhead-wan.sh`](scripts/t9-overhead-wan.sh)'s accounting would confirm a multiplier, not move a
result, so it ranks below all three cells above.

**What none of this can settle.** One route, one source, one host. Nothing about whether a commodity
MoQ relay market appears, nothing about operating either chain at scale, and — like every Gate 1
result here — nothing about hardware acceptance except in measurement 1.

---

## T15 — RIST and SRT on the cadence instrument — **run**

Results in [test-15-point-to-point-cadence.md](test-15-point-to-point-cadence.md). Neither of the two
outcomes this was specified against is what happened, so the specification is kept here in summary
rather than deleted.

It asked whether RIST's egress is near-source-paced, expecting either that **grooming burden ranks
inversely to scalability** or that the incumbents' hand-off advantage is folklore. The answer is
neither: RIST and SRT are *transparent* — measured identical to a no-transport control on burst size —
so their egress is whatever their publisher produced, while MoQ's is set by its object model and does
not move when the source changes. Grooming burden therefore does **not** rank inversely to
scalability; MoQ hands over the finest bursts (12.2 kB against 30.6 kB from the same source), and the
tunnels lead only on worst-case silence (~35 ms against 149 ms), which is the figure that sizes a
groomer's start gate.

What remains open from this line is in T15's own "still open" table: the tunnels under loss and RTT,
and a true CBR hardware source, which the transparency result makes the interesting variable.

---

## T16 — grooming a segmented-HTTP egress — **run**

Results in [test-16-grooming-segmented-http.md](test-16-grooming-segmented-http.md), rig in
[`scripts/t16-groom-segmented.sh`](scripts/t16-groom-segmented.sh). Specified to close the cell
[evidence](../docs/evidence.md) §3.2 admitted was open — "the equivalent grooming pass on
a segmented-HTTP egress is unmeasured" — by inserting the groomer into T14 arm B1's chain and changing
nothing else, then grading with T13's criteria and gates verbatim.

It also tested T14's disposal of the gap as "a configuration finding, not a defect", by running the
groomer at three points in the parameter space beside the adaptive arm. That is the half of the
specification worth keeping: the adaptive arm passed, and so did an arm with every depth pinned by flag
to what the adaptive arm derived — but T14's proposal taken literally, raising only the stall timeout,
produced a stream with 231 continuity errors behind a flawless PCR record and a perfectly flat wire. **A
cadence instrument and a PCR grader between them cannot detect a groomer that is deleting programme**,
which is a method finding for any future pacing measurement: score packet conservation as its own
column.

What remains open is in T16's own "still open" table. In rough order of value:

- **6 s segments**, which T14 measurement 5 already publishes, against the groomer's 8 s default cushion
  ceiling. This is the one arm expected to fail as shipped, and therefore the one worth running.
- **1 s segments**, where 2.5 × the observed lead lands under that ceiling, so the adaptive factor is
  tested rather than clamped. T16 measured only that 8 s was adequate. [T7](test-7-timing-integrity.md)
  has since run this at 27.5 Mbps as a diagnostic rather than as this cell: halving the segment
  duration halved the source gap (3798 → 1878 ms) and did not change the conformance outcome, but that
  clip was rate-limited by the test host, so the cell still wants running at a bitrate the rig can pace.
- **A host that can pace ~30 Mbps without underrunning**, which is a rig upgrade and the precondition
  for measuring the segmented lane above ~11.5 Mbps at all. T7's four-clip sweep is clean on the three
  ~10 Mbps clips and inconclusive on the 27.5 Mbps one, and a local-file control at the same rate
  fails worse than the lane does, so every high-bitrate segmented figure is currently bounded by the
  instrument rather than by the subject.
- **A lossy segmented path, downstream of the groomer.** [T5](test-5-network-impairment.md) has since
  put the segmented lane through a loss ladder and found the *ungroomed* egress byte-verbatim and
  P1-clean at every level, so what is left for T16 is narrower than it was: not whether segments
  survive, but whether the groomer's cushion absorbs a lane running at 0.17 of source rate without
  muting. Every T16 arm is loopback, so no segment has yet failed to arrive.
- **A feed that is not rate-matched, or a join mid-segment,** which is what would distinguish the
  content-based start gate from a plain timer at the same depth. On a rate-matched delivery the two
  coincide, so T16 leaves the gate unfalsified rather than demonstrated.

---

## T17 — standalone SI on snapshot tracks — **run**

Results in [test-17-si-snapshot-tracks.md](test-17-si-snapshot-tracks.md); rigs in
[`scripts/eit-roundtrip.sh`](scripts/eit-roundtrip.sh) and
[`scripts/si-join-cost.sh`](scripts/si-join-cost.sh), fixture generator in
[`scripts/make-eit-epg.py`](scripts/make-eit-epg.py). Specified to settle the one part of upstream's
SI-on-tracks design that code review cannot: an EIT schedule sub-table is sparse, so its completeness
cannot be decided by counting sections, and the importer commits on observing the transmission cycle
wrap instead. Whether that reconstructs the table is empirical.

It does. EIT round-trips section-for-section across four sub-tables of an 8-day EPG against zero on the
merge base, and the two costs theory predicted are immaterial: carriage is bitrate-neutral (0.985×) and
the export gate — which holds all output until every SI entry has a snapshot — costs 1 ms, because the
subscriptions are issued together. The experiment also produced the 8-day price
[#2882](https://github.com/moq-dev/moq/issues/2882) asked for: 29,912 B across four snapshot tracks per
service, so ~1.1 MiB across 160 tracks at 40 services.

The method finding is worth more than either number. The census that opened the run used
`tsp -P tables` without `--all-sections` and read a sparse sub-table's *non-completion* as its
*absence*, producing a confident and wrong conclusion about the existing fixture. **An instrument that
reports completed tables cannot establish the absence of a table designed never to complete.**

What remains open:

- **A lossy path.** In a sparse table a lost section and a skipped section number are
  indistinguishable, so a section lost before the cycle wraps should yield a snapshot quietly missing a
  segment. That is reasoned, not measured; it wants a drop injected on the SI PID. Upstream has since
  fixed a related defect by merging same-version sections rather than replacing them, so this arm is now
  confirmation of a fix rather than the adjudication of an open question. The segmented lane is the
  control that makes it legible: it carries the same 69 sections without parsing them (§5), so it has
  no commit rule to get wrong, and a loss ladder run against both at once separates a carriage failure
  from a reconstruction failure. [`scripts/eit-section-diff.py`](scripts/eit-section-diff.py) grades
  either lane unchanged.
- **Multi-service.** The 40-service figures are scaled from one service, not measured on an MPTS.
- **The clock's emission timing.** Carriage is settled — TDT/TOT is proxied from the source and TOT's
  descriptors survive byte-for-byte — but the exporter re-emits a stored section on its own 30 s timer,
  so the delivered clock is ~14 s late and repeats a time it has already asserted when the source ticks
  slower than the timer ([T15](test-15-point-to-point-cadence.md) measurement 4). Measured on a clean
  loopback path only; what a lost snapshot group does to it is untested.

---

## T13 extended — an off-the-shelf datagram sender — **run**

Results in [test-13-downstream-grooming.md](test-13-downstream-grooming.md) under "The egress stage on
its own"; rig in [`scripts/t13-rawsend.sh`](scripts/t13-rawsend.sh). T13 concluded that a constant-rate
stream is not a paced wire and that the missing piece is a stage owning a clock.
[`rawsendmpeg2ts`](https://github.com/EDIS-mx/rawsendmpeg2ts) is exactly that stage and nothing else,
so it tests the conclusion directly rather than adding another candidate groomer.

The conclusion holds and the gap it named is now closed. Holding the muxer fixed and swapping only the
egress takes the same FFmpeg output from 10 ms CoV 6.553 and a 265.8 ms silence to 0.048 and 3.5 ms,
at the declared rate rather than 15 % above it. Replaying a CBR file the sender is byte-identical
across 165,326 packets and reaches the instrument's resolution floor. A fully off-the-shelf chain now
passes three of T13's four criteria and fails only carriage, which sharpens what has to be said in
someone else's documentation: not "you need a groomer" but "you need a stage that inflates a mux and
re-places PCR without rewriting it, and nothing off the shelf does that".

Legs ran on the EC2 box because the sender does not build on macOS — `clock_nanosleep` with
`TIMER_ABSTIME` is the pacing mechanism and does not exist there — so every control was re-measured
on that host at a matched rate.

What remains open:

- **Hardware.** This is loopback on a general-purpose kernel, and the tool's own documentation insists
  a switch between sender and IRD invalidates the test. It is a candidate for [T7](test-7-timing-integrity.md)'s Gate 2 rather than a substitute.
- **Behaviour at a join backlog.** The sender has no buffer policy, so a backlog becomes standing
  latency or is discarded upstream by the exporter's `--latency-max`. Neither was measured; a
  deliberately delayed start would show which.
- **A rate that drifts.** The rate is derived once from ~1 s of PCR on a CBR assumption. What happens
  when the groomer in front does not hold it exactly is untested.

---

## Dual-path 1+1: remaining conditions (T12)

All four arms are run; results and limitations are in
[test-12-dual-path-handoff.md](test-12-dual-path-handoff.md), rigs in [`scripts/t12-*`](scripts/).
What those results left open:

**Restart one leg of a live pair — blocked upstream.** A stream-clocked leg that mutes and returns
already rejoins its partner's numbering and phase correctly; the one thing stopping the pair being
byte-identical afterwards is the exporter's continuity counters, filed as
[moq-dev/moq#2779](https://github.com/moq-dev/moq/issues/2779). Once that lands, re-run the recovered-leg
and late-join cells expecting 100 % agreement.

That re-run also needs a grader the current one is not. `t12-merge-oracle.py` recovers the legs'
sequence offset by voting on payload identity and derives skew from it, so it cannot grade a pair that
differs in any field — it graded the join cell on 15 datagrams out of 23,175 and returned a spurious
offset and a 12 s skew that did not exist. Either give the oracle a masked-compare mode or wait for the
exporter fix; meanwhile use [`t12-seqskew.py`](scripts/t12-seqskew.py), which measures phase without
correlating.

**Meshed variants — what the independent-upstream arm left open.** Both the clock question and the
path-diversity question are settled. Arm D run with a publisher, relay, exporter and groomer per host
across eu-west-1a and eu-west-1b, sharing nothing but a verified-identical source file, is
byte-identical across 46,778 of 46,778 shared datagrams with zero residue on single-track content, and
reaches 75.56 % on a seven-stream mux for a located upstream reason
([#2829](https://github.com/moq-dev/moq/issues/2829)). So the legs agree about *stream position*, not
merely about wall time, with no shared component above the egress.

What that leaves is the *mesh*, which is a different topology rather than a deeper version of the same
one: relay B dialling relay A as a cluster peer
(`~/t6-redundancy/relayA.toml`/`relayB.toml`) to check that relay reselect neither helps nor interferes
once the receiver is doing the switching, and the receiver holding two relay subscriptions rather than
two groomed legs. That is [F6](#f6-moq-distributed-resilience), and it is also the arm that would
exercise [#3312](https://github.com/moq-dev/moq/pull/3312)'s subscription resumption across routes
sharing a first hop.

**Segmented 1+1: the two cells the T6 arm could not run.** A pair sharing one feed and one naming
scheme is hitless, and two packagers of one feed are byte-identical, but both were measured with the
standby **co-started** and with one filesystem standing in for the segment store. Two cells follow
from that, in order of leverage:

1. **A standby that joins an already-running feed** — the production shape, and the case the
   media-aware lane drills as E2. Content-chosen segment boundaries predict a mid-stream joiner cuts
   at the same intra-coded pictures as the incumbent and so drops straight into the same naming
   sequence, but that is a prediction. It needs a live fan-out the loopback rig did not provide;
   multicast failed on the laptop, so run it on EC2 where T5's segmented arm already works.
2. **Two hosts writing one store.** The whole result rests on both packagers writing identical names
   into a consistent store; on one filesystem that is free, and across two hosts it is the actual
   engineering. Worth pairing with the two-host T12 cells above, since both are blocked on the same
   second instance.

A third, cheaper cell: `tsp -O hls` writes segments in place rather than writing and renaming, so a
client fetching mid-write is a live hazard that three clean runs did not provoke. Drive the fetch
rate up against a shared-name pair and see whether it bites.

A fourth, cheapest of all: **where between 1 s and 8 s the segmented pair becomes byte-identical.** At
a 1 s groomer cushion two segmented legs agree on 99.95 % of datagrams and at 8 s on 100 %, so the
determinism precondition is met — but eight times the MoQ lane's cushion is a latency cost stated
without knowing how much of it is necessary. A bisection on `PACER_LAT` in
[`scripts/t12-segmented-local.sh`](scripts/t12-segmented-local.sh) is one afternoon and turns a bound
into a number.

**Also unaddressed by T12:** SMPTE 2022-1 FEC; a full 10 Mbps mux rather than 2 Mbps on a 2-vCPU box;
a carrier rate matched to the content rate, to resolve whether the 1.4 % PCR-interval floor measured
there is an artefact of 55–60 % stuffing; and any hardware IRD merge, which is Gate 2.

---

## Congestion control for a permanent fixed-rate trunk (extends T8)

Promoted to its own protocol with a runnable rig — see
[test-8b-congestion-control.md](test-8b-congestion-control.md). All conditions C1–C6 are run,
including C3's six aggregates, the `cake` arm — under which the collapse survived, falsifying the
bufferbloat explanation — and the `--latency-max` probe that attributed it to per-subscriber deadline
shedding. **Nothing of the original protocol is outstanding.** What extends it now is the capacity
ladder in [F8](#f8-congestion-and-capacity), which asks a different question: not which controller,
but how much impairment either lane absorbs without losing programme.

---

## LEO / Starlink satellite-handover impairment (candidate — extends T5/T8)

The [T5](test-5-network-impairment.md) runs used *steady* impairment. On Starlink (LEO) the perceived
damage is not steady-state loss but the **satellite-to-satellite handover** — a periodic pulse
(~every 15 s) of elevated delay and **bursty** loss lasting ~1 s, against an otherwise near-clean
baseline. Because QUIC treats a loss burst very differently from uniform Bernoulli loss, this is a
plausible cause of the periodic degradation reported by collaborators on satellite-backhauled
contribution.

A collaborator's `netem` sketch (a **candidate**, not yet run or calibrated) models it as a
clean-ish baseline with a periodic 1 s handover pulse. As written it drives an `ifb0` ingress-redirect
qdisc rather than the SSH-safe egress `prio` band, so it needs adapting to the media-only filter
before running on a shared host:

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

If run it belongs alongside the T8 impairment matrix (condition 5, bursty/correlated loss) so both
transports meet the same pulse; the metric to watch is not average throughput but **per-pulse
recovery** (does each 1 s burst cause a bounded, self-clearing dip, or accumulate into
starvation/collapse over successive handovers?). Open items before trusting the numbers: (a) calibrate
period/hold/loss against a real Starlink capture rather than the assumed 15 s / 1 s / 10 %; (b) run it
correlated with the T5 reordering finding (a handover that also reorders is the genuine worst case);
(c) apply via the SSH-safe media-only filter, not a blanket `ifb0` qdisc, on any shared host.

---

## System performance & resource utilisation (T9)

Soaks, the fan-out envelope, the bitrate sweep, protocol overhead, the relay memory characterisation
and the audio-resync work are all executed and written up in
[test-9-performance.md](test-9-performance.md). What is left:

1. **Bound the half of the ceiling the slot arithmetic does not explain.** The knee reproduced where
   predicted, but [T8b](test-8b-congestion-control.md) C6 ran 14.006 h and converged asymptotically on
   **2.03×** the predicted ceiling, its slope decaying from +24.60 to +1.82 MB/h without ever breaking and
   without going flat. Audience is not the variable — growth is flat across 0–4 subscribers and a
   five-connection leg reaches the same range as a two-connection one — so this is a second term on the
   ingest side, and it is the difference between budgeting 100 MB and 200 MB per channel. **Run it
   capped** — `--server-quic-max-streams 1024`, the group count logged, `/proc/pressure/memory` beside RSS
   — which separates the slot-dependent part from kernel reclaim from a genuine second term in one leg.
   Related and still open: the ~20–30 MB slot-independent term is unattributed, and a third slot count
   (say 4,096) would test whether the two-point fit holds as a line.
2. **Re-test the memory behaviour after any upstream fix**, using `gop14` as the sensitive case — at
   6,445 groups/h it shows a regression in half the time. The fix has to come from `quinn-proto` and no
   released version past 0.11.16 changes the recycling behaviour, so this may wait a long time.
3. **What a real decoder does with an unflagged 24 ms audio hole, and with a substituted frame**, if
   [#2798](https://github.com/moq-dev/moq/issues/2798) needs it. A resync is signalled nowhere, but
   "unsignalled" only matters if something downstream would have acted on the signal. The splice case is
   the sharper half: a frame of spliced bytes decodes to *something*, and whether that is an inaudible
   glitch or a full-scale click decides how much the missing signal costs. An AC-3 decoder that honours
   `crc1` should conceal it; an MP2 decoder on this content has no CRC to check.
4. **Two residuals from the splice fix ([#2823](https://github.com/moq-dev/moq/pull/2823), merged and
   verified: the mixed frame is gone from the looped feed).** First, **the counter-contiguous wrap**,
   where the fix is blind and the mixed frame returns — reproduced on `main` with a 130,705-packet cut
   of the broadcast clip, chosen so the audio PID's counter runs straight through the wrap, and worth
   reporting as its own issue once the AC-3 question below is answered, since a CRC or a PES-length
   check would cover it. Second, **why AC-3 loses the 8 whole
   frames inside its truncated PES while MP2 keeps its 7**, when `salvages_partial_pes` is true for both
   and they take the same branch: either the salvage flush is not reaching the parser for AC-3 or the
   parser is discarding a confirmed frame, and ~256 ms of good audio per wrap turns on which. Also worth
   constructing the opposite case — a mux that *does* split audio frames across PES boundaries — to
   exercise the first commit's confirmation path, which no content we have reaches.
5. **The publisher thread count**, which grows and decelerates without settling.
6. **A cross-machine fan-out** to find the relay's own knee, overhead under loss versus SRT, and the
   groomer/pacer envelope. Now the MoQ half of [F5](#f5-the-scaling-model).
7. **The segmented lane's own resource envelope, which has no equivalent of any of the above.** Its
   carriage overhead is measured (1.036× source TS, [T9](test-9-performance.md)) and nothing else is:
   no per-role CPU or RSS figure for packager, origin or client, no fan-out knee, and no soak. The
   comparison is currently one lane characterised for cost and one lane characterised for bytes. It
   wants an nginx origin rather than `python3 -m http.server`, because the origin is the role whose
   scaling the whole commercial argument for this lane depends on, and the one measured is a
   single-threaded reference implementation. Now the segmented half of [F5](#f5-the-scaling-model) and
   of [F2](#f2-permanence-soak).
8. **A full-feed publisher soak — both blockers now cleared, so this is ready to run.** Every long run
   to date used a video-only source, because looping a normal broadcast TS killed the publisher at the
   wrap. The origin host now runs a `main` build carrying the whole audio-resync and continuity series
   (#2751, #2823, #2891), and its standing loop publisher was rebuilt to replay the file's own bytes
   (`tsp -I file --infinite -P regulate --pcr-synchronous`) instead of re-muxing through `ffmpeg -c
   copy`. Verified at the subscriber: all seven elementary streams arrive on the source's own PIDs with
   AC-3 typed AC-3, the teletext descriptor intact and all three SCTE-35 PIDs typed 0x86 — where the
   ffmpeg loop had delivered two tracks on renumbered PIDs. The soak therefore now exercises what it was
   commissioned to exercise, and the publisher's `NRestarts` doubles as a wrap regression test, since
   the byte-faithful wrap is the #2802 splice rather than a remuxer's approximation of it.

**Standing method** (used for the executed conditions, and for the remaining ones). Per role
(publisher, relay, subscriber + groomer/pacer), establish the steady-state resource envelope and its
scaling, and prove stability over long runs. The priority dimension is a **hours→days soak** to detect
memory leaks / unbounded growth — a resource leak is a production blocker, not a characterisation
note. Run on the Linux EC2 host so `pidstat`/`/proc` are available; pin builds and record them.

```bash
# steady-state per role (fixed 10 Mbps CNNiEMEA2 loop), ≥ 300 s after warm-up
pidstat -h -r -u -d -t -p <PID> 1 300 > perf_<role>.log
while :; do printf '%s fds=%s thr=%s\n' "$(date +%s)" \
  "$(ls /proc/<PID>/fd | wc -l)" "$(ls /proc/<PID>/task | wc -l)"; sleep 1; done > fds_<role>.log

# soak (≥ 24 h, ideally 72 h): coarse sampler + RSS-vs-time slope (slope ~0 = no leak)
while :; do printf '%s ' "$(date +%s)"; ps -o rss=,%cpu=,nlwp= -p <PID>; sleep 60; done > soak_<role>.log
awk '{n++;x=$1;y=$2;sx+=x;sy+=y;sxy+=x*y;sxx+=x*x}
  END{b=(n*sxy-sx*sy)/(n*sxx-sx*sx); printf "RSS slope = %.4f MB/hour\n", b*3600/1024}' soak_<role>.log
```

Pass criteria for any role: RSS growth slope statistically ≈ 0 over the soak, or a plateau with a
stated ceiling; fd, socket and thread counts stable and returning to baseline after join/leave and
relay-reconnect churn; bounded CPU with headroom. Pair the soak with the T7 ≥ 72 h PLL-lock soak so one
long run yields both verdicts. Re-running the fan-out sweep across two machines needs
N ∈ {1,5,10,25,50} subscribers on hosts separate from the relay, since a co-resident subscriber costs
more CPU than the relay serving it and the knee then belongs to the box.

**This method block now serves both lanes.** [F2](#f2-permanence-soak) and [F5](#f5-the-scaling-model)
apply it unchanged to the segmented roles — packager, origin, client — which is the point: a comparison
of resource behaviour is only worth having if the same sampler and the same slope test produced both
sides of it. The media-domain series F2 adds on top (continuity, PCR, PSI cadence, media-sequence
progression) are graded by the existing `compliance.py` and `ts-pcr-timing.py` instruments rather than
by anything new.

**Carriage overhead: the opaque lane and loss above 1 % remain.** The media-aware lane and SRT are
measured on a real path ([T9](test-9-performance.md)). Two rules for whoever runs the rest, on top of
the three enforced by the rigs themselves ([`scripts/README.md`](scripts/README.md)) — the first pass
here produced a wrong number that survived two rounds of hypothesis:

- **State the budget in advance.** QUIC's per-packet cost is ~64 B (IP + UDP + short header + AEAD tag
  + `STREAM` header), so 5.5 % at a 1200 B datagram and 4.5 % at 1500 B, against SRT's 3.3 %. Without
  a prediction, a wrong measurement has nothing to fail against.
- **State the denominator.** Elementary-stream bytes, delivered TS and source TS differ by the stuffing
  and TS-header volumes; only the last is the like-for-like comparison against a byte pipe.

---

## Cross-implementation interop (T11)

Three other MoQ implementations now matter to this project
([comparison](../docs/comparison.md) §12), and "a MoQ relay is a neutral transport fabric"
is a load-bearing assumption that has only ever been tested against `moq-dev` peers.

**T11a — `moq-dev` against third-party relays.** *Partly run;* harness, relay matrix and the isolated
root cause are in [test-11-interop.md](test-11-interop.md), which carries its own list of remaining
legs. The one worth prioritising is **Cloudflare with a provisioned scope**: the anonymous attempt
negotiated draft 18 cleanly and returned no data, which is the expected outcome without publish and
subscribe tokens, so it has not yet tested anything. Done properly it is **the strongest available test
of relay neutrality**, because it uses third-party production infrastructure rather than a lab peer.
Record the negotiated draft, whether the `hang` catalog survives a relay with no catalog concept,
round-trip fidelity against the T1 baseline, and added latency. Their relay treats publisher disconnect
as terminal, so expect no source-failover behaviour — confirming that is itself a result worth
recording against [architecture](../docs/architecture.md) §5.

**T11b — a `moq2ts` broadcast through a `moq-dev` relay.** *Runnable now, weaker result.* `moq2ts` is
publisher-only, so there is no MSFTS subscriber to close the loop; the question is only whether the
relay forwards objects whose catalog it cannot parse. Observe the relay's forwarding and announce
behaviour rather than decoding output. `moq-dev` is demand-driven (T11a), so the open part of the
preannounce split documented in `moqxr` PR #21 is the other direction: run with their default
(preannounce off) and then with it on, to establish whether an early `PUBLISH` poisons namespace
registration.

**T11c — the full suite against a `moq2ts` subscriber.** *Blocked until they publish one.* When it
exists, run T1–T3 transparency, T7 timing integrity and TR 101 290 conformance against their
implementation and contrast with ours. This is the comparison that would actually settle which lane
preserves what — particularly whether their null-stripping and SPTS-from-MPTS behaviour costs
conformance in the same places ours does, and whether the `mediatimeline` side track is a better
answer to wall-clock correlation than downstream PCR regeneration. Plan the matrix now so the run is
ready when the subscriber lands.

**Ecosystem contribution to consider alongside these:** a **broadcast profile** for the community
[`moq-interop-runner`](https://github.com/englishm/moq-interop-runner) — TS carriage fidelity, PSI/SI
survival, PCR integrity across a relay. The harness already exists and deliberately stops at the
protocol handshake, so this extends shared infrastructure rather than building a private rig, and
gives the transparent-TS profile a neutral conformance target.

---

## T3 — the segmented-HTTP transparency arm and the duration sweep — **run**

Results in [test-3-opaque-transparency.md](test-3-opaque-transparency.md); rigs in
[`scripts/t3-segmented-transparency.sh`](scripts/t3-segmented-transparency.sh) and
[`scripts/t3-transparency.py`](scripts/t3-transparency.py). Specified because the paper now treats
segmented HTTP as a candidate for primary distribution rather than as a foil, while the transparency
question had only ever been asked of the two MoQ lanes — and because
[T14](test-14-data-plane-comparison.md) measurement 4 established what the lane *forwards* on one clip
without being able to see what it *adds*.

Scored against T3's inventory on all three of its clips, the lane preserves mux content as completely
as the opaque lane — service identity, non-default PMT PIDs, CAT, TDT/TOT, every splice PID, stuffing,
0 continuity errors, 0 PCR intervals above 40 ms — and adds exactly one PAT/PMT pair per segment and
no PID the source lacked. The addition costs file-domain PCR accuracy: 37–74 ns to 109–302 µs,
predicted from 376 bytes at each clip's rate before it was measured and confirmed across a 2.75×
bitrate spread. Grooming closes it ([T16](test-16-grooming-segmented-http.md)).

**Both cells this file listed as cheap have since been run, and only one of them existed.**

- **6 s and 1 s segments through the same inventory — run, and it confirmed the mechanism.** Sweeping
  duration moved the injection count 5.7× and the maximum PCR error 1 % (299.6 / 301.9 / 302.4 µs),
  which is what a per-segment displacement predicts and an accumulating error does not. The violation
  *count* fell 2,456 → 2,453 → 8, so P2 exposure is partly a segment-duration choice while the error an
  IRD would see is not. P1 table margin fell monotonically the other way, as predicted.
- **The two MoQ lanes at `pcrverify --absolute` — not closable, and the reason is the gate.** The gate
  presupposes a mux rate. The media-aware lane's ungroomed egress has none — 0 stuffing packets, and
  `analyze` reports 22–32 Gb/s on 10–27 Mb/s content — and graded anyway it returns *exactly* the
  maximum PCR interval, matching to 0.003 % on three clips whose maxima differ 8×. So it measures MoQ
  object burst structure, not carriage. The opaque lane cannot be graded at all: its private checkout is
  gone from the machine and no capture survived, which makes that cell blocked on an artefact rather
  than on instrument time.

What remains in T3's "still open" table is now uniformly expensive: the opaque lane's build,
multi-programme carriage, a lossy segmented path, and the opaque lane on a current draft.

---

## T4 — the three-lane arm over the public internet — **run**

Results in [test-4-remote-e2e-srt.md](test-4-remote-e2e-srt.md); rig in
[`scripts/t4-three-lane.sh`](scripts/t4-three-lane.sh), scored by T3's
[`scripts/t3-transparency.py`](scripts/t3-transparency.py). Specified to ask T3's transparency question
on a real path instead of loopback, and to do it as a genuine side-by-side: one clip, one origin, one
pacing, one packet bound, one instrument, differing only in the transport.

**Byte-faithful SRT is transparent on every criterion** — 13 PIDs of 13 at source numbers, SDT, NIT,
TDT/TOT, three splice PIDs, stuffing, the exact source mux rate, identical PSI cadence and PCR grid, 0
CC, and **0 PCR-accuracy violations at 481 ns**, the campaign's first over-the-wire P2 grade of any lane.
**The media-aware lane is faithful to the mux as bytes and not as a timed object:** identity, PIDs, SI
and splice all survive; stuffing, mux rate, PSI density (8.04 → 2.51 PAT/s) and PCR spacing do not.

**Segmented HTTP reproduced its loopback result on a prediction registered before the run** — content
intact, criterion 6 failed by exactly **1.00 injected PAT/PMT pair per segment head**, **302.148 µs** of
PCR accuracy against **302.4 µs** predicted, 0.043 % of added rate. So the injection accounting is a
property of the segmenter, not of the path, and T3's loopback carriage breadth can be read as
generalising.

**Two standing claims fell out of this and have been corrected everywhere they appeared.** T4 credited the
media-aware lane's 320 ms PCR gaps to the encoder; the source is flat at a 24.95 ms maximum with no
interval above 40 ms in 600 s, and [T2](test-2-media-aware-transparency.md) had already tabulated those
figures as lane impairments. And an "all inbound TCP is filtered" claim rested on `nc -z` probes against
ports with nothing listening, which cannot distinguish a filter from an absent server.

Remaining here, in cost order:

- **Why the lane clusters PCRs** — 86 % of intervals under 1 ms, monotonic, mean conserved. Group-wise
  reassembly is the obvious candidate but is inferred from the distribution, not confirmed against the
  exporter. Worth settling before it is raised upstream, because PSI density may have the same cause.
- **The maximum PAT interval on the media-aware lane**, which no instrument can currently supply: with
  no mux rate only an average over the PCR span is available (399 ms against P1's 500 ms limit).
- **Leg C** (opaque over the wire), blocked on that lane's egress delivering zero bytes; the cheap
  discriminator is EC2's own Linux binaries.

---

## MPTS / multiple concurrent services (T10)

Carry a multi-program TS (or several SPTS broadcasts concurrently) through the opaque lane and verify
per-service PSI/SI, PCR and CC integrity at egress, plus relay fan-out behaviour under N services.
Primary distribution is frequently MPTS; the campaign to date is SPTS-only. Gate 1 (fidelity) at
multi-service scale.

---

## Office-network reproduction of T3/T4

Re-run the opaque lane (T3) and the remote end-to-end SRT chain (T4) from the office network. The
office has ample upload capacity (removing the ~2 Mbps home-uplink ceiling that capped T4's SRT leg)
but may impose UDP/QUIC throttling or DPI a home link does not. This tests two things at once: (a) the
opaque lane and full-rate SRT contribution without the access-link bottleneck, and (b) whether
MoQ/QUIC survives an enterprise network posture that polices or rate-limits UDP — a real deployment
risk. Record connect success, negotiated draft, throughput, and any QUIC fallback/blocking.

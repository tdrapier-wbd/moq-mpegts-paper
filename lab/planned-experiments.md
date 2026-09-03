# Specified but not yet executed

These protocols were designed as part of the campaign and are recorded here so an external engineer
can execute them reproducibly.

**This file holds only what is outstanding.** Everything measured lives in the per-test file it
belongs to; where an experiment is partly executed, the entry here is reduced to the *remaining*
conditions plus a pointer to the results. An entry is deleted once nothing of it is outstanding — a
to-do list that accumulates its own history stops being readable as a to-do list. Results,
corrections and the reasoning behind them belong in `test-*.md` and
[method-notes.md](method-notes.md).

**Ordered by leverage, not by convenience.** The entries below hold the protocols; the ranking that
decides which to run is stated once, immediately.

Placeholders `<EC2_IP>` / `<subscriber-home-ip>` carry the machine-specific values from
`INSTRUCTIONS.local.md`.

---

## The ranking

Every experiment names its own open items and most of them are worth doing eventually. This is the list
that decides what runs next, re-derived rather than carried forward, because three of the entries it
used to lead with are now done and one of them changed what the rest are worth.

**What today's run removed from this list, and it is the top four entries.** The PCR output-position
issue is filed ([#3334](https://github.com/moq-dev/moq/issues/3334)) with the conformance test offered
as a PR ([#3335](https://github.com/moq-dev/moq/pull/3335)) and hedged comments on #2829/#2779. C3 ran
under `cake` and the collapse survived it, so the AQM counterfactual is closed as a **falsification**
rather than a caveat. The `latency-max` probe then attributed the collapse: it is per-subscriber deadline
shedding, and at a 30 s budget there is no collapse at all. And the `mpegts-pacer` positional guard is
in, with five tests and the fixture as its regression case.

**What that does to the rest of the list is more than remove four rows.** The campaign's largest
unexplained result is gone, and the honest consequence is that **the largest remaining soft spot is not
a measurement at all — it is a claim resting on a shared upstream.** Byte-identical 1+1 is the strongest
positive result in the paper and the arm that produced it shares its publisher and relay, so it rises
to the top. C3's residue is now a sizing ladder, which is cheap and no longer urgent.

**Ranked on four things**, in this order: whether the result could change a conclusion in
[`docs/`](../docs/); whether it removes a material caveat; what it costs to set up; and whether it
produces an upstream contribution.

---

### MUST DO NOW

**1. ~~The full 1+1 — two publishers, two relays, two paths.~~ Done.** A publisher, relay, exporter and
groomer per host across two availability zones, sharing nothing but a verified-identical source file:
**single-track content is 46,778 of 46,778 shared datagrams identical, counters included**, so the
strongest positive result the campaign has now stands with no shared component at all. **A seven-stream
mux over the same topology reaches 75.56 %**, and the residue is reordering rather than damage — the
same packets, 99.95 % common as a multiset, in a different order, because the exporter interleaves by
arrival. Measured, located and posted to [#2829](https://github.com/moq-dev/moq/issues/2829); see
[T12](test-12-dual-path-handoff.md).

**What this leaves is not a measurement.** Multi-track byte identity now depends on an upstream fix to
`pick_next_track`, not on another cell here. The open question worth apparatus is therefore the one
below it: whether a *hardware* IRD merges the pair the software oracle accepts.

**1b. The end-to-end re-run against a grid-sliced export, the moment
[#3351](https://github.com/moq-dev/moq/pull/3351) merges.** *Newly unblocked, and the cheapest
high-leverage measurement on the list.* The positional fix is written and verified **at the pipe**
(T19 measurement 9: adjacency 50.31 % → 0 %, release p95 70.3 → 1.7 ms against its own merge-base). What
it does not tell us is the thing the whole PCR line of work was filed under: **whether a byte-locking
groomer downstream of it produces a conformant wire.** T19 measurements 3, 4 and 6 re-run unaltered and
answer it — the lane was 120 → 772 ms and 0 → 1,166 continuity errors on the merged build, and this is
the change that should move both. It also decides open question 1 in
[Evidence](../docs/evidence.md), the P1 repetition gate. Do not run it against the PR branch as the
deployable answer: a build that has not landed cannot retire a caveat about the deployable
configuration.

---

### HIGH VALUE

**2. A capped-stream relay-memory arm.** *Only time on the rig that exists.* C6 converged
asymptotically on **2.03×** the ceiling [T9](test-9-performance.md) predicted, decaying +24.60 →
+1.82 MB/h and still not flat at 14 h. Connection scaling is ruled out — flat across 0–4 subscribers,
a five-connection leg in the same range as two — so a second term is adding ~100 MB over the ten hours
past the knee. One run bounds it: `--server-quic-max-streams 1024` isolates the slot-dependent part
(T9: 91.4 MB against 189.5 MB), a logged group count says whether the excess tracks groups, and
`/proc/pressure/memory` beside RSS tells a decaying slope from kernel reclaim. It is the difference
between budgeting 100 MB and 200 MB per ingested channel.

**Its upstream standing is weaker than it looks, and that is the reason to cap the streams rather than
argue.** [#2745](https://github.com/moq-dev/moq/issues/2745) is **closed as not-planned**: the maintainer
root-caused the retention to `quinn-proto` recycling one receive-stream state per stream ever accepted,
which is not moq state and is bounded by `max_streams`. Our 14 h leg — posted there after the close, and
unanswered — measured 2.03× that bound, so either the ceiling model is incomplete or a second term
exists that is moq's. The capped arm is what distinguishes those, and only if it shows the excess
surviving a 1024-slot cap is there anything to re-file.

**3. T9's cross-machine fan-out knee.** *The secondary exists and is provisioned for exactly this.*
Every relay cost figure in the campaign is measured with the subscribers co-resident with the relay,
and they cost more CPU than the relay serving them — so the knee currently on record is the host's, not
the relay's. Drive the subscribers from the 8-vCPU box against the relay on the primary and it becomes
the relay's. This removes a caveat from the relay-versus-origin cost comparison, which is a load-bearing
number in [`economics.md`](../docs/economics.md).

**4. The segmented lane's two-host segment store.** *Both hosts exist.* The segmented lane's equivalent
of the 1+1 result, and the half that has never been tested: both packagers writing identical names into
a *consistent* store is free on one filesystem and is the actual engineering across two hosts.

**5. C3's latency knee, as a ladder rather than a mechanism hunt.** *Nothing new needed; ~20 minutes.*
The mechanism is settled — the shed is per-subscriber deadline shedding, and it tracks `--latency-max`
from 4.29 Mb/s at 500 ms to 10.35 at 30 s at `n=2`, past the uncontended single-flow rate. What the sweep
does not say is where the knee is: it is already at 62 % of cap by 8 s, so four points span the whole
transition. Add 1, 3, 4 and 6 s at `n=2` and `n=3` under `cake` and the answer is a curve an operator can
size a trunk from, plus the discriminator for *what* sets it — the RTT, the group duration, or the relay's
own buffering, which predict knees in different places. Lower than the arms above only because it
sharpens a result rather than removing a caveat from a published claim.

**6. An HTTP/3 client for the segmented lane.** *Needs a library build, not an account.* The segmented
lane is graded against MoQ over QUIC while itself running over TCP, and the reason is a client library
rather than a protocol: macOS's system libcurl and the EC2 box's curl 8.18.0 are both built without
HTTP/3, so `tsp -I hls` cannot negotiate it whatever an origin offers. **That box's nginx 1.28.3 already
carries `--with-http_v3_module`**, so the server half exists and only the client half is missing; on
Linux it is buildable (curl against ngtcp2 or quiche via `LD_LIBRARY_PATH`, or an HTTP/3 fetch engine
behind a pull-style client rather than `tsp -I hls`). Until it exists every segmented figure carries an
unstated "over TCP", and the head-to-head compares a transport to a transport-plus-a-generation.

---

### USEFUL BUT DEFER

**7. A CloudFront edge in front of the existing origin.** Cheaper than this list long assumed — same AWS
account, minutes to point at the EC2 origin as a custom origin, free tier covers a single-client
experiment, no CDN relationship needed. It buys real anycast, real PoPs and real multi-tenancy. Deferred
because [T9](test-9-performance.md) removed most of what it was standing in for: both origins serve 100
concurrent clients at ~992 Mb/s with no knee, so "the weakest possible origin" was never the constraint.
Budget for two things it will not do by default — it needs explicit `Cache-Control` from the origin to
behave on a live playlist, and it bills per request, which 2 s segments generate briskly.

**8. A standby packager joining an already-running feed.** The production shape, and the cell a
co-started pair cannot measure. Cheap on the two hosts; deferred behind items 5 and 6, which establish
the steady state it is a perturbation of.

**9. Differential delay on a real pair.** `netem` on the cross-AZ path models geographically separated
origins — which is why one region was the right choice, since impairment can be added to a low-delay
pair and cannot be subtracted from a cross-region one. It models rather than measures, so it ranks below
the arms that measure something new.

**10. Cloudflare with a provisioned scope (T11a).** The strongest available test of relay neutrality,
because it is third-party production infrastructure rather than a lab peer. The anonymous attempt
negotiated draft 18 cleanly and returned no data, which is the expected outcome without publish and
subscribe tokens, so it has not yet tested anything. Needs an account and a scope; that is the only
reason it is not higher.

**11. A `moq2ts` broadcast through a `moq-dev` relay (T11b).** Runnable now, weaker result. `moq2ts` is
publisher-only, so the question is only whether the relay forwards objects whose catalog it cannot
parse, plus whether an early `PUBLISH` poisons namespace registration (the open direction of the
preannounce split in `moqxr` PR #21).

**12. A broadcast profile for `moq-interop-runner`.** Extends shared infrastructure rather than building
a private rig, and gives the transparent-TS profile a neutral conformance target. Deferred rather than
dropped: [#3335](https://github.com/moq-dev/moq/pull/3335) is the same instinct aimed at a repository
that will act on it sooner.

**13. C3 replicates.** One per cell today. The per-flow split is known not to reproduce and the
aggregate is, so two more replicates would put an error bar on the only number being quoted — but the
qualitative result is already clear at one and item 5 is the better use of the same rig time.

---

### BLOCKED

**14. A hardware IRD and a TR 101 290 analyser, soaked ≥ 72 h (Gate 2).** *The one genuinely
unavoidable purchase or loan, and still the highest-value blocked item.* Every conformance number in
this campaign is graded by software written or configured by the same people who built the thing under
test: enough to falsify a design, not enough to accept one. A soak settles PLL lock, the buffer model,
slow clock drift and discontinuity handling at once, and it is the only way to test the boundaries a
groomer meets outside steady state. It also closes the one question
[T12](test-12-dual-path-handoff.md) cannot answer in software — whether a real merge engine agrees with
our reference receiver on an ST 2022-7 pair. **≥ 72 h for an arithmetic reason:** the PCR base wraps
every 26.51 h. Pair it with the T9 resource soak so one borrowed week yields both verdicts, and note
that every boundary above has a substitute runnable here first — which is what turns a borrowed week
into measurement rather than debugging.

**15. T12's churn arms.** The recovered-leg and late-join cells wait on
[#2779](https://github.com/moq-dev/moq/issues/2779), because an exporter numbering continuity counters
from process state cannot produce a byte-identical pair after a restart however many hosts it runs on.
They also need a grader `t12-merge-oracle.py` is not yet. Item 1's comment on #2779 is the only thing we
can do to move this.

**16. The full interop suite against a `moq2ts` subscriber (T11c).** Blocked until they publish one.
Worth planning the matrix now so the run is ready when it lands: it is the comparison that would settle
which lane preserves what, particularly whether their null-stripping and SPTS-from-MPTS behaviour costs
conformance where ours does.

**17. A true CBR hardware source (T15's residual).** The transparency result makes a real CBR source the
interesting variable rather than a nicety, and nothing in the lab produces one.

**18. The segmented plane's low-latency arm at equal conformance.** No client we have realises it; the
only receiver that could is a commercial ABR-to-TS gateway, which is the same apparatus block as item 14
in a different guise.

**19. Multi-programme carriage through a media-aware edge (MPTS).** Only interesting where the edge is
media-aware — a byte cache serves an unusual TS payload exactly as nginx does, so asking it of a plain
cache re-measures nginx. If the question is whether a commercial packaging edge rejects a
multi-programme segment, it has to be that product. T17's 40-service figures remain scaled from one
service rather than measured on an MPTS.

---

### NO LONGER WORTH DOING

- **T19's arrival oracle on a bigger host** — run; 7.45 % on two vCPU and 7.45 % on eight, at zero CPU
  pressure. The caveat it existed to retire is retired.
- **The clean two-host 1+1 arm** — run twice, byte-identical both times, 0 residue. What remains is item
  1, which is a different arm.
- **Recovering C3's aggregates** — all six recovered, and the cell now prints them, so the failure mode
  cannot recur.
- **C3 under an AQM** — run. `cake` cut RTT from ~550 ms to 100 ms and the collapse survived at 48 %/40 %
  of cap, so C4's prediction is falsified rather than untested. Do not re-run it as a rescue.
- **Hunting a lower-layer mechanism for C3** — the `latency-max` sweep discriminated: the shed tracks the
  budget over a 2.4× range at 0 continuity errors, so there is nothing left for a shared-lane mechanism
  to explain. Item 5 is the sizing residue, and it is a different question.
- **Filing the PCR output-position finding, and the conformance test** — filed as
  [#3334](https://github.com/moq-dev/moq/issues/3334) and [#3335](https://github.com/moq-dev/moq/pull/3335),
  with hedged comments on #2829/#2779. The maintainer then **wrote the fix**,
  [#3351](https://github.com/moq-dev/moq/pull/3351), which verifies against its own merge-base
  (adjacency 50.31 % → 0 %, release p95 70.3 → 1.7 ms) and is reported on the PR. What this *adds* to
  the list is the end-to-end re-run it unblocks, below.
- **The `mpegts-pacer` positional guard** — in, with five tests and the T19 capture as the regression
  fixture. The groomer now measures the assumption it used to make.
- **More transparency clips through lanes already characterised** across a 2.75× bitrate spread.
- **The arm B1 wire-cost leg on the EC2 path**, whose HTTP-layer term is path-independent and whose
  framing multiplier is measured elsewhere; and per-track wire-byte attribution.
- **The segmented HTTP/3 arm *as an explanation for the lanes' loss difference*.** That motivation is
  dead: [T8](test-8-srt-vs-moq.md) erased the difference by matching the controller on TCP, which was
  the cheaper route to the same answer. Item 8 is a different question — like-for-like transport
  generation in the head-to-head — and is still wanted.

---

### What to bundle, because prompt count is the scarce resource

Grouped so nothing in a group contaminates anything else in it. Each group is one run.

**Group A — the two-host group, with its lead item now done.** Items 3 and 4 — the fan-out knee and the
two-host segment store. Both need both boxes and neither can share a host with a timing measurement. The
full 1+1 that led this group is complete, which frees the window: run the fan-out knee **last**, because
it deliberately saturates a box.

**Group B — the cheap ladder, and it can share a run with almost anything.** Item 5 (C3's latency knee).
It runs in network namespaces on the primary against a stopped loop publisher, needs no new apparatus,
and its grading is a per-cell aggregate rather than a timing comparison — so it is the right filler for a
window whose main item is posting, reviewing or building.

**Group C — the long run.** Item 2 alone. A memory soak measures the machine it runs on, so it cannot
share a window with anything, and it wants hours rather than minutes. Start it at the end of a session
and read it at the start of the next.

**Do not bundle:** item 6 (an HTTP/3 client is a build task with an open-ended failure mode, and it will
eat a window on its own), or anything from the BLOCKED list, whose windows are set by apparatus rather
than by us.

---
## Delivery latency at equal conformance — measured, see T18

**Both the cushion sweep and the latency cell this file used to own are now measured in
[T18](test-18-delivery-latency.md), and the framing they shared was wrong.** They asked where the MoQ
lane's PCR-repetition curve crosses zero as the groomer's cushion deepens, on the premise that
conformance is bought with depth and depth is latency. On the media-aware lane the two axes turn out to
be independent: repetition sits at ~490 intervals above 40 ms with a 228 ms maximum across a ladder
spanning eight times the depth, and stays there when groomer starvation is removed entirely. The groomer
inserted 137, 103, 28 and 0 PCRs of its own across that ladder for violation counts of 491, 489, 503 and
502 — **the exporter clusters its PCRs, so the gaps a groomer would have to fill are not where its own
insertion slots fall**, and no cushion fixes that.

What T18 leaves open is listed in its own *Still open* table. Two entries belong here because they need
setup rather than analysis:

**The prediction, still untested — and the reason is now a measured one.** T18 predicts that an exporter
emitting PCR-bearing packets on an **even** ~25 ms grid would pass the gate at a 250 ms cushion, that is
at the 127 ms delivery latency already measured. [#2937](https://github.com/moq-dev/moq/issues/2937) was
filed against that, [#2967](https://github.com/moq-dev/moq/pull/2967) delivered exactly the placement
rule asked for, and [T19](test-19-pcr-grid-verification.md) confirms it at the exporter to the tick. The
prediction still cannot be scored, because the grid does not reach the wire: it is expressed as per-frame
timestamps and the exporter's output is a byte stream, so the PCR *packets* leave bunched and grooming
either drops content or regenerates the original distribution. **What this run now needs is one more
upstream change on the exporter's output path**, after which T18's rig re-runs unaltered. Still the
campaign's highest-leverage outstanding run.

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

**Meshed variants — what the two-host arm left open.** The clock question is settled: arm D run with
one groomer per host, eu-west-1a and eu-west-1b, on independent oscillators, is byte-identical across
every shared slot, twice. So the legs agree about *stream position* and not merely about wall time.

What that arm still shares is everything above the groomers — one publisher, one relay, one physical
path — so it grades clock-independent determinism of two egress legs and **not** path diversity. The
arm that grades path diversity needs two publishers of the same feed and two relays, optionally with
relay B dialling relay A as a cluster peer (`~/t6-redundancy/relayA.toml`/`relayB.toml`) to check that
relay reselect neither helps nor interferes once the receiver is doing the switching. That is the
arm to run next, and it is also the one that would exercise
[#3312](https://github.com/moq-dev/moq/pull/3312)'s subscription resumption across routes sharing a
first hop.

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
including C3's six aggregates. What remains of T8b is the `cake` arm and the mechanism probe behind
C3's aggregate collapse, now attributed to the subscriber's latency budget; the controller ranking is no longer scoped to
non-congestive impairment.

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
   groomer/pacer envelope.
7. **The segmented lane's own resource envelope, which has no equivalent of any of the above.** Its
   carriage overhead is measured (1.036× source TS, [T9](test-9-performance.md)) and nothing else is:
   no per-role CPU or RSS figure for packager, origin or client, no fan-out knee, and no soak. The
   comparison is currently one lane characterised for cost and one lane characterised for bytes. It
   wants an nginx origin rather than `python3 -m http.server`, because the origin is the role whose
   scaling the whole commercial argument for this lane depends on, and the one measured is a
   single-threaded reference implementation.
7. **A full-feed publisher soak — both blockers now cleared, so this is ready to run.** Every long run
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

# Method notes

The campaign's methodological rulebook: consult it before designing, running, grading or interpreting
an experiment. Each rule is a bold instruction followed by the experiments it came from; the incident
behind a rule is recorded in that experiment's lab note, not here.

A rule belongs here only if it would change how a future experiment is designed, measured or read.
Before adding one, look for an existing rule of the same principle and extend its provenance instead
of writing a sibling.

---

## 1. Controls

**A looped clip is not a long clip, and the difference is a rewind per lap.** *(T21, T23.)*

`tsp -I file --infinite` restarts the programme clock each lap; T23 priced a backward jump at its duration in programme time, so T21's source injected a ~600 s rewind roughly every 665 s and measured recovery from a manufactured event, not permanence. **The property under test must survive how the stimulus was extended.** Use a timeline that advances for the full soak (`ts-continuous-source.py` advances PCR, PTS, DTS and continuity counters across the join). Before the run, check 0 backward steps, 0 discontinuity indicators, 0 continuity errors, and a join interval indistinguishable from the median.

**A comparison tool that cannot fail is not evidence.** *(#2825 anchor-point port, [upstream](upstream-contributions.md) §3.)*

`table-anchor.py` returns a plausible percentage whether or not it reads the right field. **Give a comparison instrument a positive and a negative control before quoting it.** Positive: a capture against itself must return 100 %. Negative: a deliberate perturbation on one leg must fail by the amount implied and leave untouched rows at 100 % — here, nulling every second PAT/PMT on one leg moved those rows to ~50–52 % and left SDT and NIT at 100 %. The negative control separates measuring from agreeing.

**A gap in a delivery trace is not evidence of damage until a run with the intervention removed has
been shown not to have one.** *(T38.)*

Withdrawal of one affiliate channel left five pauses over 0.5 s (longest 3.195 s) on the kept channel; an undisturbed session on the same channel showed four pauses (longest 3.013 s) — ordinary burstiness. **Zero continuity errors** on both: a pause without a continuity error is late delivery, not lost media. A de-provisioning, failover or impairment arm needs a do-nothing twin on the same channel in the same session, because the burstiness floor is a property of the rig and the day.

**A negative control and a broken rig give the same reading, so an adversarial arm has to prove it
ran before its result means anything.** *(T25.)*

F11's abusers died on a CLI parse error (`CONN` passed as one argument) before opening a connection; stderr went to `/dev/null`, so victims reported `keep_up` 1.001 with zero continuity errors — indistinguishable from perfect isolation under abuse. **The stimulus needs its own liveness assertion as a pass criterion** (F11 samples abuser process-group count and fails if peak concurrent count during abuse is below two). **Keep one adversary's stderr** so silent parse failures are falsifiable. Whenever the expected result is "nothing happened", require independent evidence that the arm ran.

**A before/after across two builds must hold the *instrument* constant, not just the subject — and
the newest release is usually the wrong "after".** *(T8b, C3's #3271 re-check.)*

Comparing `0.9.11-eab96019` to `0.9.15` is void: #3006 between them paces TS export on frame timestamps instead of drain-on-arrival, changing what a fixed 90 s byte window counts (6.09 vs 4.48 Mb/s meant nothing). For each commit between arms, ask whether it could affect the *measurement*, not only the subject; if yes, use the merge-base pair (`bec7c4b59^` vs `bec7c4b59`, one file, #3006 identical on both sides).

**Fitting the two shapes you expect cannot see a third, and a step masquerades as the leak you were
looking for.** *(T21, the 6 h per-PID run.)*

`t21-role-fit.py` called `moq export ts` LINEAR (+2.73 MB/h) on a series that was flat 119–122 MB then **+14.5 MB in one half-hour** — a step fits a line better than a log, so a two-shape test calls the wrong thing. **Report a shape-independent statistic beside the fitted one** (here, largest single-interval increment as a share of total growth: 68 % vs 17 % for publisher). **Where a verdict is a choice between models, print the evidence that no model was right.**

**A per-cell verdict must be derived from every instance of the thing it is about, or the rig will
quietly report the state of instance one as the state of the cell.** *(T8b, C3's #3271 re-check.)*

C3's death detector read only `sub.log`; that yielded 0 vs 6 deaths (p ≈ 0.016) and a drafted regression, but all pre-arm deaths sat in `sub.2.log`. Re-reading all subscriber files gave 3/15 vs 9/15 (p ≈ 0.060). Partial reads return plausible numbers, not errors. Glob `sub*.log`, count instances found, and record that count next to the verdict; every derived quantity must scale with fan-out.

**Pinning a component for reproducibility scopes the conclusion to that pin — and if the mechanism
runs through the pinned component, the A/B can attribute the effect to the wrong one entirely.**
*(T8b, C3's #3271 re-check.)*

A merge-base client pair with relay pinned at 0.13.7 showed post-#3271 subscriber exits in 6/14 contended cells vs 0/14 pre (p ≈ 0.016). The mechanism runs through **relay group eviction**; on current 0.14.14 relay, deaths appear in all four relay × client combinations and eviction counts fall from ~1000 per cell to single digits. Ask of each pin: **could the proposed mechanism run through this?** If yes, cross the pin before writing the report, not after. (Crossing the pin also prompted re-reading all subscriber logs — see above.)

**On the media-aware lane, a PCR-derived measure of "how much programme arrived" measures the
exporter's clock, not the programme.** *(T24, applied in T8b's C3 re-check.)*

Delivered-programme from first-to-last PCR over wall clock ranked the arm with **40 % fewer bytes** as better continuity until read correctly: `moq export ts` regenerates PCR on a uniform grid (#2967), so PCR advances on exporter liveness, not media arrival (as T24 showed for 57 s missing video with 0 continuity errors). **On this lane, PCR is an exporter liveness signal and nothing more**; programme arrival needs per-PID access-unit counting (T24's grader).

**Do not grade a capture while its writer is still running.** *(T8b, C3's #3271 re-check.)*

Grading while the last cell was still capturing reported 65.17 s programme in 90 s (`keep_up` 0.724); after the writer exited the same cell read 90.20 s. A partial capture is short, not corrupt, and looks like a stall. Grade after the cell writer exits, or confirm the run is complete before grading; the replicate rig grades in-script.

**A control that removes the suspect stage tests the stimulus, not the system, and exonerates
nothing downstream of what it removed.** *(T21.)*

Ruling out loop wrap by feeding the same looped clip **straight into the groomer with MoQ removed** held across wraps and was read as eliminating the wrap; the exporter — which fails on wrap — was gone, so the control could only return null. Name stages the control removes; if the hypothesis was that one of *them* misbehaves, the control cannot test it. Write "the wrap alone, without the exporter, does not do it", not "not the wrap".

**A control with the mechanism removed is worth more than a second run of the same arm.** A second
run reproduces the artefact. *(T15, and independently T9.)*

RIST Main measured 92.1 kB bursts every 73 ms; plain-UDP through the same chain matched to within a millisecond — publisher release granularity, not transport. Without that control the rig floor would have been published as a transport property.

**Where a stage's own throughput could be the limit, the control that removes the subject entirely is
not optional — a saturated instrument fails in the direction that looks like a finding.** *(T7,
segmented arm.)*

One clip failed PCR repetition on the segmented lane; raising groomer cushion and halving segment duration each ruled one mechanism without removing the lane. Local file at the same output rate (no packager, origin, or HTTP; largest content gap 51 ms) did *worse* than any lane run — the clip measured pacing saturation. Only a control that deletes the subject distinguishes subject from instrument.

**Pinning a setting on one arm is half a control. The variable you know to be decisive is the one
most likely to be left defaulted on the arm where its knob has a different name.** *(T5 / T8.)*

T5 pinned media-aware BBR after T8 showed controller decides loss, but left segmented on system CUBIC (nowhere on the command line) and attributed disjoint lane weaknesses. Matched controller: both lanes hold full rate; under CUBIC both collapse — only reordering was lane-specific. Pin both arms when the knob exists under different names/layers (`--*-quic-congestion-control` vs `net.ipv4.tcp_congestion_control`) and record both on the result line.

**A setting is a default for what happens next, not a fact about what is being measured — read it
back off the thing under test.** *(T8, segmented arm.)*

`sysctl` affects sockets opened after it; confirm by reading the controller from connections carrying the run. On segment-fetch, sample repeatedly — each fetch is a short-lived connection, so one snapshot lands between them and reports nothing.

**Run the control before believing a striking result, not after.** *(T17.)*

A round-trip captured zero bytes, matching a predicted export-gate failure — until merge-base control behaved identically: a renamed flag whose deprecated alias warns and does not take effect.

**Grade beyond one full failure-detection interval, or the drill measures the timeout rather than the
mechanism.** *(T6.)*

Failover drill killed publisher at t+22 s and graded at t+43 s — 21 s into a 30 s QUIC idle timeout. No build could pass; the conclusion was withdrawn.

**A positive control that cannot be subjected to the same injections as the arms is a gate on the
rig, not a comparison.** *(T12.)*

Arm C grooms once and duplicates (single publisher, relay, exporter): killing its publisher takes the whole arm down — honest architecture, but arm C validates receiver and instrument, not the topology.

**A parameter fixed once in the method section and never varied is an uncontrolled variable, and it is
the first place to look when a result refuses to explain itself.** *(T8b C3.)*

C3's headline — second feed *reduced* throughput — survived controller and bufferbloat elimination until `--latency-max` at 2 s was swept: `n=2` aggregate 4.29 → 10.35 Mb/s (above single-flow). Before hunting a network mechanism, list every value the rig was told and vary ones never in the matrix.

**A stage that sizes itself adaptively is a free variable, not a constant. Pin it before you attribute
a downstream count to a build.** *(T23, re-grading against #3529.)*

Forward-jump groomer underruns fell 3,300 → 0 across builds while adaptive cushion settled ~347 ms vs 200 ms (control included). Re-running arm **and control** on both builds with cushion pinned at 200 ms separated build from cushion; control moved too (189 → 6), so claim only excess *over control within one build* (17× old, below new). Pin adaptation for comparability; carry control through the pinned run for what you may claim.

**Stop the subject, not the instrument: a control killed before it can report is not a control.**
*(T37 D7.)*

The control subscriber was still being served when the harness killed the whole recorder pipeline; the recorder wrote no record and two runs reported failure when the control had held. Give end-of-input to recorders that write on end-of-input; teardown paths matter most for the arm still running.

**Re-running the control arm re-measures the session, and that is exactly why it earns its place.**
*(T23, re-grading against #3529.)*

Re-grade showed content gaps rising on every arm (26–27 ms → 70–127 ms), but the byte-identical control rose further (27 ms → 141 ms), forbidding build attribution — session baseline moved. Carry the null arm into every re-run, not just the first campaign.

---

## 2. Instruments, and reading what they tell you

**A harness must assert the fault is present in its own source before asking anything downstream
about it.** *(T39 Part A.)*

Three runs reported a client-edge detector had not caught suppressed audio; the source slice had failed silently and the clip still had audio throughout. A null from a detector and a null from apparatus that never built the fault are indistinguishable. Count the thing you removed in the file you will publish and abort if it is still there.

**Time-slicing a transport stream needs `--pcr-based`; wall-clock and media time differ by the ratio
of disk speed to bitrate.** *(T39 Part A.)*

`tsp -P until --milli-seconds 20000` on a file stops twenty seconds after reading starts, by which point a 372 MB clip may be entirely consumed; `-P until --seconds` does not exist. Never suppress a fixture builder's stderr, and state which clock a duration uses.

**A check that has only ever returned "clean" has not been shown to work. Feed it something broken
before you publish the zeros.** *(T5, T6, T7, T8b, T18, T3, T36.)*

Six rigs counted continuity errors by grepping `tsp -P continuity` for "discontinuity"; the plugin prints
`* continuity: packet index: 13,264, PID: 0x0079 (121), missing 14 packets` and uses that word only in
`--help`, so the count was structurally zero on every input. Nothing looked wrong because zeros on a healthy
rig are expected — the defect was invisible where it was load-bearing. It survived into a T7 pass criterion,
a T5 headline, a T6 observation built on the counter not firing, and a T18 "zero on all nineteen cells"
sentence. Re-grading retained captures with a working matcher left T7 and MoQ arms genuinely at zero and
moved T18's segmented cell to 583 events and T6's dual-source cells to ~95. The cost of the check is one
deliberately corrupted file per instrument, once; the cost of skipping it is that every published zero is
worth exactly as much as the grep behind it. Prefer matching tool data (`missing N packets`) over prose
words; where two instruments measure the same property, report both and treat disagreement as a finding.
T36 repeated the trap with a word matcher and with `tsp -P pcrverify --max-interval`, which is not an
option that plugin has — the plugin errored and the counter reported zero violations, caught only by
excising forty packets from a passing capture. Use `t13-grade.py`'s gates and regex rather than writing a
third matcher.

**A per-interval CPU figure has to come from a CPU-time delta over that interval, not from a
platform utilisation field whose averaging window is longer than the interval.** *(T38.)*

`ps -o %cpu` on Darwin averages up to a minute while ladder steps were twelve seconds, so the zero-subscriber point read higher than five subscribers in two of three arms. Read cumulative CPU time either side of the dwell and divide by wall interval.

**A resource whose baseline is contaminated by run history needs the process restarted
between arms, not a longer settle.** *(T38.)*

The same ladder's RSS rose monotonically with arm order (14.5, 17.5, 57.5, 71.1 MB) and one arm fitted a negative slope because the relay held the previous arm's peak after teardown; withhold or restart rather than quote contaminated baselines.

**A counter that wraps detects an event and cannot size it. Never report its magnitude as the damage.**
*(T5, T19.)* Incidents, aliasing table and remedy: § *A continuity count detects loss and cannot measure it* (§5).

**Errors logged by a server are not an instrument for a client falling behind.** *(T5.)*

Origin 404 rate works only while the client is slow enough to be overtaken but still requests the segment just deleted; deeper loss reloads the playlist and skips silently — one ladder cell lost 82 s of programme with origin logs of nothing but 200s.

**An instrument that reports its own confidence has to be read.** *(T12.)*

A merge oracle voting on payload identity had 15 votes out of 23,175 — confidence 0.19 — and picked an offset that read as twelve seconds of skew; two hypotheses, two tool changes and three runs followed while the figure was on screen throughout.

**A derived quantity must be re-measured independently before it is explained.** *(T12.)*

Measuring arrival at equal sequence numbers — which needs no correlator — gave a median of 10.4 ms for the same twelve-second artefact.

**An instrument that reports *completed* objects cannot be used to establish the absence of an object
designed never to complete.** *(T17.)*

EIT schedule sub-tables that never complete look absent to section-completing analysers; census sparse tables with `--all-sections`.

**A negative reachability result is evidence about the network only if the far end would have answered a
positive one. Read the failure mode, not the failure.** *(T4.)*

`nc -z` on ports with no listener measures absence of a server, not a firewall: filtered ports time out (~8 s here), admitted ports with no listener refuse immediately (~17 ms once a listener is bound). Test with something listening or characterise the silence.

**An option whose units depend on a sibling flag will be misread eventually. Read the tool's echo of
the threshold, not the flag.** *(T16.)*

`pcrverify --jitter-max` is microseconds by default and PCR ticks only under `--absolute`; a whole analysis was re-run against both readings before the tool's printed conversion settled it.

**A harness that omits a row when its instrument returns nothing cannot distinguish zero from
unmeasured. Make it fail on an empty series.** *(T3 — same TSDuck trap as the `--jitter-max` rule:
behaviour depends on a sibling flag, not on the value passed.)*

`pcrextract --csv` writes its series to TSDuck's report stream — stderr — unless given `-o`. An analyser
reading stdout received nothing, interval computation returned nothing, and a truthiness test skipped rows:
three complete-looking transparency tables lacked PCR interval and >40 ms rows. Detect omission by checking
output against the columns it was supposed to have, and fail the harness on an empty series.

**Report long intervals and discontinuities separately; a metric that conflates two faults hides
both.** *(T12.)*

Counting PCR intervals above 100 ms together with negative intervals reported sixteen "jumps" in a clean control; split apart, that arm has zero backward steps.

**Grade a pacing stage with a packet-conservation column beside the timing ones.** *(T16, and T13
independently.)*

One configuration posted the best PCR record and flattest wire while carrying 231 continuity errors; every *when* measure passed and only *which* bytes left failed.

**Score what a stage *added*, not only what survived.** *(T3.)*

Transparency census shape cannot see packets never in the source; on segmented HTTP, 46 such packets moved PCR accuracy four orders of magnitude while survival rows read clean. Stages that re-head, re-index or re-stamp need an addition column.

**Two gates that both claim to measure "PCR conformance" can disagree by four orders of magnitude, so
name which one a result is quoted against.** *(T3.)*

Inserting packets does not change PCR values (P1 repetition 0 % above 40 ms) but changes byte positions (P2 accuracy 37 ns → 302 µs).

**A gate that presupposes a property of the stream cannot compare streams that differ in whether they
have it — and it will return a plausible number rather than refuse.** *(T3.)*

`pcrverify --absolute` assumes a byte clock; ungroomed media-aware egress with no stuffing grades as exactly the maximum interval (159.995 vs 160.000 ms across clips 8× apart in maxima). Before booking an unfilled cell, check the instrument is defined on the thing being compared.

**"Pacing" names two independent quantities, and a lane can be perfect on one and absent on the
other, so measure them separately.** *(T13, the exporter residual; figures below from the
`53f8aa99d` reference capture, which is the one [T13](test-13-downstream-grooming.md) carries.)*

They are where PCR values fall in time and how many bytes the stream carries between them. On media-aware
egress the answers can be opposite: PCR intervals exactly 25.00 ms at minimum, median and maximum — better
than the 24.65 ms source because the exporter regenerates values onto a synthetic grid — while byte counts
between the same pairs run 188 B to 870,628 B against the 31,081 B the declared rate requires. A report
that says pacing is fixed on the first is true and useless.

**Read the interval from the carried PCR values and the rate from the packet count over the same
pair** (`pcr-residual.py`).

Both statistics come from one capture, they cannot disagree about which stream they describe, and the second
is what a groomer exists to supply. It also explains a result that looks like a precision problem: a P2
gate predicts arrival from byte position, so a stream whose instantaneous rate spans four orders of
magnitude fails every PCR by construction.

**A third quantity hides between them, and it is the one that decides whether a groomer can help:
the correct *aggregate* rate is not a schedule.** *(T13.)*

Padding can land within 0.21 % of declared rate while 96.7 % of individual slots carry the wrong byte count; grade the distribution, never the total.

### Read PCR from one PID, and say which

*(T13 P1-n, hardening `pcr-residual.py`.)* The first script version pooled PCRs from every PID that
carried one; two PIDs each on a correct 25 ms grid, offset from one another, read as a 12.5 ms grid with
half the bytes between samples — a clean stream graded as badly clustered, with no symptom anything is
wrong because every number is plausible. Name every PCR-bearing PID in the output and grade one of them;
the script prints the PID census before the verdict and grades the PID carrying the most PCRs unless told
otherwise. The same pass added interval minimum, which had been omitted: clustering is a short-interval
defect and median, p95 and maximum hide it — a grid with a third of PCRs bunched into sub-millisecond
pairs still reports correct median and maximum. The reference clip carries 21 sub-millisecond intervals
(0.09 %), so compare groomed output against that baseline rather than against perfection.

### A determinism comparison must align on the source's own bytes, never on a value either process minted

*(T13 P1-n, `ts-pair-diff.py`.)* The question is whether two egress processes of one broadcast are
octet-identical for the same media, as an ST 2022-7 receiver needs. Aligning on PCR, packet index or
continuity counter assumes the answer, because those are the values under test. Align on a payload run
that occurs once in the other capture — source media neither process regenerated — then classify each
difference by field so the result names a mechanism. Take the needle from after the later process joined:
an 8 s stagger put first candidates before B's first byte and the tool reported "no common media", which
reads like a failed comparison; it now retries with B's needles in A. A comparison of two streams that are
93 % null packets is void, not a pass. A fixed alignment turns one displaced packet into a wall of
differing payload: on #4645's scratch build, 713 adjacent transpositions made packet *i* versus packet *i*
report four clusters of 10,902 video packets as payload damage; re-aligned with slip allowed, 943,271 of
944,023 packets agree. Grade the whole overlap, allow the alignment to slip, and compare the elementary
stream before calling a difference content loss.

**A slot-by-slot comparison measures the first inserted packet, not the property after it.**
*([T12](test-12-dual-path-handoff.md) § After the media-time interleave.)* Keyed by PID and PTS the groomed RTP pair was 100 % identical in order while slot comparison read 24.7 %; one or two PCR-only packets per 40 s shifted every later slot. Before quoting slot-identity, check what is being matched; grade the claimed property on a key processes cannot mint.

**On a saturated constant-rate multiplex, one inserted packet reads as a burst of transpositions.**
*([T13](test-13-downstream-grooming.md) § On #4645's PCR grid, `ts-cc-merge.py`.)* Count packets per PID per PCR interval before naming a burst; one TDT 0.7–0.9 s early leaves video one packet behind with no stuffing to absorb it. When rewriting continuity counters, take each PID's offset as the modal one across the overlap, not the first seen.

**Pass `pcrverify --bitrate` explicitly whenever the arm might not be carrying full programme. Grading
PCRs against a rate TSDuck derived from those PCRs turns a conservation failure into a PCR failure.**
*(T19 measurement 11, T47.)*

Shallow cushion rungs shed 80 % of content so TSDuck's rate estimate missed nominal 11 Mb/s and every PCR failed accuracy against it. Pass the padded rate, not always the rig's `RATE`: catalog 9,999,999 b/s vs groomer 10,000,000 b/s exceeds 500 ns after ~5 s. Separate rate from error by fitting PCR value against packet index.

**Vary the parameter the mechanism says is irrelevant; that is the test the mechanism can fail.**
*(T3.)*

PAT/PMT per segment should scale injection frequency with 1/duration but not error size; sweeping 1 s / 2 s / 6 s moved injection count 5.7× and maximum error by 1 % (299.6, 301.9, 302.4 µs).

**A commanded buffer depth is not the depth in force. A pacer whose output rate exceeds the content rate
arriving at it burns its cushion off, and its own status line will not say so.** *(T18.)*

`mpegts-pacer` logged `holding 2000 ms` through 18,070 underruns with measured standing depth 90 ms. Quote cushion with surplus; match null-stripping carrier to content rate, not mux rate.

**A fix acts in one domain. Test it in that domain, or the instrument will confidently answer a
different question.** *(T19.)*

File capture measures byte position, not release timing #3006 creates; live pipe timestamps showed the fix plainly. Before measuring a fix, name which domain (value, byte position, arrival time) it acts on.

**Grade a stream against the values it asserts about itself, not against a nominal you supply.**
*(T19.)*

Compare each PCR interval to the difference between the two PCR values ([`ts-pcr-timing.py`](scripts/ts-pcr-timing.py)) rather than an external 25 ms nominal; the self-referential test yields error sign and needs no reference clock.

**The sign of a timing error tells you whether you are measuring the writer or the reader.** *(T19.)*

A preempted reader produces late and early errors in balance; a writer flushing backlog produces early ones only — measured 626 early to 136 late ruled out reader scheduling as the whole story.

**Two invariants failing at once are one defect until you have checked they fail on different
things.** *(T19.)*

Cross-tabulating release-timing and byte-position checks showed 615 of 626 early releases were byte-adjacent packets and none of 136 late ones were — one mechanism, not two.

**Half the defects in a conformance instrument are it failing conforming input, and only a legal
fixture finds those. Build the stimulus for every condition the standard permits, not just the ones
it forbids.** *(T19, `ts-pcr-timing.py` — eight defects, five of them this shape.)*

Five PCR analyser defects rejected ISO 13818-1–legal streams (duplicate packet, discontinuity jump, clock jump, duplicate PCR value, 33-bit rollover). Write pass expectations first — false positives cost credibility.

**An instrument's "not measured" and its "passed" must never be the same exit code. A producer that
died is the case the gate exists for.** *(T19, `check_release` — found by a reviewer, not by us.)*

`check_release` hard-passed "not measured (no arrival stamps)" below three timestamped PCRs, greening early-exiting producers on a live rig. Absence of evidence needs its own verdict with floors on sample count and window share.

**A fixture must break exactly one thing, and a generator emitting legal streams gets its own
bookkeeping wrong silently. Verify the stimulus arrived before trusting the verdict.**
*(T19, `ts-pcr-fixtures.py`.)*

Fixtures that computed continuity per fixture polluted interval tests; loss of an exact multiple of 16 packets on a PID is invisible to continuity counter — size holes from the clock. Each fixture asserts a detail field proving its condition, not merely that some check moved.

**Where an instrument's behaviour is a choice rather than a requirement, the test has to say which.
"It passes its tests" and "it implements the standard" are different claims.** *(T12, the ST 2022-7
selection oracle.)*

Label adversarial conditions: eight standard-required, one precondition violation, three unreachable by a sequence selector, one blind spot (intra-leg duplicate with differing payload resolved first-wins). Self-authored tests prove stability, not conformance.

**A monotone series measured inside a start-up transient is not a monotone series.** *(T21, P0-3b.)*

Nine minutes of groomer buffer drift looked monotonic; over 24 h the series was bounded oscillation with the clip's 600 s bitrate period. A trend claim needs a window longer than the longest stimulus period — enumerate periods before choosing the window.

**Distinguish a leak from a cache by whether the slope survives, and fit the competing shapes rather
than eyeballing the curve.** *(T21's 24 h soak, T45.)*

Two roles grew by comparable totals — relay 243 MB and publisher 137 MB — and end-point growth said the
relay was worse; fitting settles it. The relay fits a logarithm at R²=0.9895 against 0.9097 for a line,
with quarterly slopes halving (9.85 / 4.56 / 2.42 / 1.75 MB/h). The publisher fits a line at R²=0.9898
against 0.8960 for a logarithm, with quarterly slopes holding (2.36 / 2.87 / 2.81 / 2.57 MB/h). Quote
slopes per quarter, not per run; fit at least a line, a logarithm and a square root; report the largest
drawdown from a running peak — 9.2 MB drawdown against 137 MB growth is itself evidence of a cache.
Exclude warm-up by measuring it, not by default: a 2 h run with a 20 min settle read the importer at
+4.99 MB/h while the 24 h run showed flat after ~1.5 h at +0.23 MB/h from 2 h. [T45](test-45-live-tstd-remux.md)
met the same rule live: a re-multiplexer fixed after 5 s warm-up was overtaken by a lane whose delay grows
~630 ms over its first 50 s and sent 95 % of packets late.

**Sample resource series per process, not per command-line signature.** *(T21's 24 h soak, and the
follow-up run it forced, T43.)*

`pgrep -f` on a wrapper matched shell plus binary; `[m]oq-relay.*PORT` once matched the ssh shell and cleanup killed a healthy relay. Resolve each role to the PID from `$!` at launch.

**An instrument that blocks on its input cannot observe the absence of input.** *(T27.)*

A per-PID liveness detector in `read()` during total stall never ran its timeout check. Drive stall detection from wall clock the subject does not control — a dead man's handle, not redundancy with media-time measurement.

**Derive elapsed media time by accumulating steps, never as a distance from an origin — and bound the
step.** *(T27.)*

Current PCR minus first PCR moved the whole timeline on one bad byte and alarmed all four PIDs with a fabricated 23,861 s outage. Reject backwards or implausibly large steps; fault-inject the instrument, not only the system.

### A trace's labels are code

*(T28, the reorder qlog.)* noq labelled every declared loss `reordering_threshold` because send-time minus present saturates to zero. Before quoting a cause field, read the code that writes it; prefer acknowledgement frames over trigger labels; disable a candidate cause to test the label.

### A looped source is continuous only if every PID's timestamps are

*From re-running [T40](test-40-continuous-join-through-srt.md) on upstream `dev` after
[#4543](https://github.com/moq-dev/moq/pull/4543).* Importers that end on rewind make `tsp --infinite` a one-pass soak. [`ts-continuous-source.py`](scripts/ts-continuous-source.py) must rebase every stream ID with a PES header, not only `0xC0`–`0xEF` — AC-3 and teletext on private stream 1 stepped back ~30 s while PCR moved forward, invisible until importers stopped re-anchoring. Before a looped soak, scan joins per PID with [`ts-join-scan.py`](scripts/ts-join-scan.py) and confirm every timestamp-bearing PID moves forward; never loop through `tsp --infinite` on builds that end import on rewind without a generator that passed that scan.

### `srt-live-transmit` fed from a pipe pads every short read with zeros

*From the SRT arms of the #4543 measurements ([upstream contributions](upstream-contributions.md)).*
`srt-live-transmit` 1.5.6 sends full chunks padded with zeros on short stdin reads; default 1456-byte chunks splice headers onto foreign bytes and parse errors tracked host load, not build ([Haivision/srt#3388](https://github.com/Haivision/srt/issues/3388); fixed on master for v1.5.8, padding through v1.5.7). Feed SRT from a sender that emits whole packets (`tsp -O srt`); if piping in is unavoidable, check receiver bytes for zero-filled slots before attributing parse failures to the system under test.

### Time a picture where a decoder presents it, on a clock averaged over many packets

*From [T45](test-45-live-tstd-remux.md), [T46](test-46-tstd-check-cross-validation.md).* Delivery latency
times a PES header from tap to tap; across re-scheduling stages that moves with the schedule, not what a
viewer sees. Time at presentation: each tap's arrival for the header, plus PTS, less the capture's STC at
that packet. The first version used DTS; on the media-aware lane it spread over 521 ms where presentation
is flat, because the exporter authors DTS up to 280 ms earlier than the source. `tsp -P regulate` releases
playout in bursts, so per-header clock offsets scatter ±37 ms and differencing single headers reported
74 ms spread on a stage that added none. Reference latency to the PTS wherever a stage between taps may
author the DTS, and take each end's clock from a median over seconds of headers as decoder clock recovery
would. Check the instrument on a byte-faithful capture first, where presentation, decode and delivery
latency must agree. A lane that rebases PTS defeats a PTS key, so `ts-decode-latency.py --key content`
matches pictures on slice NAL units. Quote presentation latency only on bytes that pass the T-STD and name
which key matched the pictures; on T44's `main` capture presentation reads 1,775.6 ms while every access
unit fails T-STD by about a second, so no decoder achieves the quoted figure.

### A grader written once is one reading of the standard; cross-validate it before its figures decide anything

*From [T46](test-46-tstd-check-cross-validation.md).* `ts-tstd.py` was written for T44 from the clauses;
self-tests passed what its author believed the clauses said. Graded against upstream's independent check on
35 files it had six defects — two as disagreements (AVC buffer sized as one buffer rather than MB + EB; no
grade of 2.4.2.6 transport buffer emptying once per second) and four that decided no condition on the
corpus so agreement could not reveal them, found by reading each clause against the code. Upstream's check
had three defects of its own; neither instrument was the reference and each disagreement was decided by
clause. One defect was silent pass on a stream the grader could not grade. Before a home-built instrument's
figures decide anything, grade the same bytes with an independent implementation, fix the agreement
criterion in advance, settle each disagreement from the clause, read every clause against the code, and
refuse with exit status any stream the grader cannot grade — never pass it clean.

---

## 3. Ratios, windows and intervals

**A ratio between two captures is only valid when both windows cover the same media. The durable fix
is not to measure the interval more carefully but to construct the ratio so that no interval appears
in it.** *(T9, then T14, then T16 — the same error, three rigs, three times.)*

Dividing one stage's bytes by another stage's wall-clock span put a delivered rate 4.7 % above a CBR source and made overhead *negative* when a receiver drained a live window faster than real time. Form ratios from byte totals over the same media — everything sent over payload sent — with no wall clock.

**When the thing under test polls on a fixed cadence, randomise where in its cycle you intervene —
and take the phase from the pollee's own log, not from how long you slept.** *(T37.)*

Integer-second settles aligned every revocation to one point in the relay's re-check cycle (six runs within 3 ms, one phase). Randomise within a sub-cadence interval; derive phase from the authorization endpoint's log, not slept time (−0.722 s residual versus 0.109–0.110 s, σ under 2 ms). **The zero of the measurement has to come from the instrument that observed the event, not from the script that intended it.**

**A client's reconnect budget will masquerade as a server's response time, and it is usually the
rounder number.** *(T37.)*

10.032 s on a pilot was nearly written down; the relay log showed teardown ~25 ms after decision, the rest `--backoff-timeout` re-dialling a refusing relay. **A suspiciously round figure at the scale of a default is a default.** Set retry budget negligible and state it.

**A delivered-media span measured as last-PCR-minus-first saturates at one lap of a looping source, so
a cell longer than the clip reports a shortfall that is arithmetic rather than loss.** *(T25.)*

`keep_up` 1.001 in 165 s cells versus 0.779 in 765 s on a ~600 s `tsp --infinite` clip (596.27 s span in 765 s) with zero holes and clean continuity reads like 22 % loss but is arithmetic. Keep the cell inside one lap, use [`ts-continuous-source.py`](scripts/ts-continuous-source.py), or score bytes and holes and void the span figure.

**Estimate a rate as one ratio of two sums, never as the average of per-interval ratios. The two agree
only when the intervals carry comparable amounts, and on a media-aware lane they never do.** *(T19,
`mpegts-pacer`.)*

Intervals on a 25.0 ms grid carried **1 to 4,631 packets each, median 8**; averaged \(x_i/t_i\) reported 7.14 Mb/s for 9.31 Mb/s (23 % low). Sum packets, sum media seconds, divide once; the same run reads 9.14 Mb/s.

**A rate estimate driving an open loop integrates its own error against uptime. Close the loop on an
observable.** *(T19, `mpegts-pacer`.)*

`rate × elapsed` release with a 2.5 % under-read yielded **+1,792.9 ms across 90 s** and 10,279 packets shed. Trim release by buffer distance from target. **A latency figure that grows linearly with window length is the signature** — report trend beside median.

**The span a capture measures for itself is only the flow's duration if the flow is continuous. On a
bursty lane, first-to-last-packet is short and every rate divided by it is high.** *(T9 segmented —
the same family as the rule above, arrived at from the opposite direction.)*

Segment fetchers pause inside the capture window; span 4 % short made carriage 1.081x versus 1.036x despite byte totals agreeing to five figures. Span-free wire-over-payload ratio matched across runs.

**Equal window length is not equal media. When two captures are compared packet for packet, assert
the reference's homogeneity in the instrument rather than assuming it.** *(T3 — the content form of
the artefact above, and the fourth rig to hit that artefact in some form.)*

398,936 packets in both windows still differed: `testloop_clean` stuffing 18.43 % in the first 60 s versus 13.1–13.8 % later produced a head-cut comparison that looked like padding stripped (18.43 → 14.95 % stuffing). Offset the reference to join media (14.83 → 14.95 %); report stuffing by quarter and flag non-homogeneous windows.

**An extremum carries its window. A "max error" over more media can only grow, so two such figures are
comparable only over equal windows.** *(T3.)*

PCR accuracy 37 ns over 60 s versus 74 ns over 5 minutes — both valid. Applies to every max, peak, and tightest bound here.

**A mismatched-window extremum does not only mislead — it can manufacture a false *agreement*, which
survives review because agreement invites no scrutiny. Prefer a distribution to a maximum, and confirm
"preserved" against the source in the same window.** *(T4, sharpening the rule above.)*

Matching 319.98 ms maxima on egress and "source" credited cadence transport; source max PCR interval is 24.95 ms everywhere. Distribution showed 1,123 of 1,307 intervals under 1 ms — **the 0.01 ms minimum was the tell, not the 320 ms tail**. Mean PCR can match within 0.7 ms while 86 % of PCRs cluster sub-millisecond and the rest sit in 320 ms gaps; for spacing, PSI cadence, and packet interval, mean is not preservation evidence.

**Fix a numeric budget before taking the measurement, or there is nothing to read the result
against.** *(T9.)*

Per-hop overhead with no pre-agreed budget let a rig error pass; deriving budget post hoc cannot falsify the run.

**A measurement window shorter than the phenomenon's own timescale reads as a different phenomenon.**
*(T9.)*

Relay memory knees near ~three hours; shorter legs extrapolated hourly slope to "unbounded" daily growth though the series plateaus.

**A per-something cost has to name the something, and the rig has to hold it at one.** *(T8b C6,
refining the rule above.)*

"~99 MB per publisher" pre-registration hit 2.03× at 14 h while fan-out legs measured the ramp, not the ceiling. **Varying a quantity over a window shorter than the phenomenon measures the derivative, not the asymptote.**

**Before adopting the tidy explanation a new number suggests, test it against the measurements already
in hand.** *(T8b C6.)*

2.03× on two connections looked per-connection, but prior fan-out already showed flat growth across 0–4 subscribers. **A coincidence of ratios is not a mechanism.**

**Set a soak's duration from the longest period in the system, not from a round number.** *(Gate 2 rig
design, applying the rule above before the run rather than after it.)*

PCR wraps every **26.51 h** (2³³/90,000 s); 24 h is 0.91 periods, 72 h guarantees two. Place PCR just below the boundary for a minutes-long fixture instead of waiting.

**Register the shape as well as the number, or a converging curve and a leak grade the same.** *(T8b
C6.)*

Slope decayed 13× by 14 h without a knee or convergence; ceiling-only criteria misclassify smooth approach to 2× prediction. Pair long RSS with reclaim/pressure counters.

**A bound on an accumulating quantity has to come from the thing that is allowed to accumulate it.
Pick the number and the check grades the number — and before reporting a trend as growth, check the
window against every buffer in the path that the trend could be filling.**
*(T19 measurements 9 and 10, grading #3351.)*

+2,153 ms latency trend over 90 s with flat controls was exporter lag toward default `moq export ts --latency-max 3s`, not a leak (500 ms setting: 2,126 ms, −24.6 ms trend). Grade drift against the owner's allowance (500 ms latency budget), not instrument defaults (250 ms PCR drift check failed at p95 1.7 ms). Separate settling lag from slow pipe via tail *rate* on samples longer than lag build-up.

**A shedding figure is a property of the stream *and* the buffer it met. Sweep the buffer and report
the recovery point beside the loss.** *(T19 measurement 10.)*

45.9 % / 67.2 % content loss quotes are at one cushion; bounded displacement (450 ms / 761 ms) recovers 105,959 of 106,382 packets at exact CBR — sizing input, not verdict.

---

## 4. Attribution: naming a mechanism from the evidence

**Before reporting a resource cost, vary the knob the documentation says bounds it.** *(T25.)*

A subscription storm took relay RSS from 87 MB to 1.9 GB in 60 s while `moq-relay` documents the group cache as unbounded unless `cache.capacity` or `cache.headroom` is set. An explicit 256 MiB cap left the peak unchanged at 1,930 MB; abandoned sessions until the QUIC idle timeout held the memory, and cutting that timeout 30 s → 10 s cut growth 4.5×. The documented bound is the cheapest hypothesis to eliminate first.

**Where a cost could be concurrency or churn, hold peak concurrency fixed and vary only the
lifetime.** *(T25.)*

The same 42 concurrent subscribers cost 1,833 MB when killed and relaunched every 5 s and 65 MB when held for the whole phase — 28× at the same headline concurrency. With a 30 s idle timeout and 5 s churn the relay holds roughly seven generations while the arm still reads "42 concurrent abusers".

**A comparison at fixed positions cannot tell reordering from corruption. Compare the two as
multisets before concluding the content differs.** *(T12 arm D, independent upstream.)*

Full-mux residue was 24.28 % slot-by-slot but 99.9528 % of packets were common as a multiset, with alignment at 98.414 % once displacement was allowed. One displaced packet de-phases every later slot comparison. Compare multiset, then alignment, then positional figures.

**On a lane whose transport holds no session state, most of what you are about to measure lives in
the client — so measure two of them before naming the lane.** *(T8b, T6.)*

Under a 2:1 shortfall, segmented HTTP either lost the session at 43 s or thinned at 99 % of the bottleneck depending only on 404 re-anchoring; same origin, shaper, clip, and window. A figure attributed to "segmented HTTP" is often one client's error handling. T6 reached the same conclusion for failover.

**When two runs differ in more than one variable, do not credit the one you have been tuning.**
*(T13, T18.)*

T16 reached 0 PCR intervals above 40 ms while carrying seconds of cushion where T13's MoQ legs posted 131–159 at about 1 s, so cushion got the credit until T18's eightfold sweep moved nothing and T13's segmented pass-through posted 0 at almost no buffer. Data-plane attribution miscredited the same way and survived three more experiments. The variable you are holding in mind is the one most likely to be miscredited, including the replacement attribution.

**A quantity that does not move under the variable you control has not thereby been shown to belong to
someone else.** *(T13, T18, T19.)*

MoQ PCR-repetition failure was invariant across an eightfold cushion sweep, groomer starvation removal, paths, and rigs, which was read in T13, T18, and twice in T19 as proof the cause lay upstream; three upstream fixes merged on that reading and none cleared the wire. No cushion shortens a coded frame, and the groomer only placed PCR in slots the scheduler had declined inside bursts; reserving the slot cleared the gate at every depth. Before concluding "not ours", enumerate what else in your own stage the knob cannot reach — here, burst length is input property, not buffer depth.

**Name a divergence mechanism from the bytes that differ, not from the most plausible cause.**
*(T12.)*

Of 400 sampled conflicting datagrams, none differed only in PCR; 39.5 % disagreed on PID order and 28.2 % on null count. Ignoring PCR at the receiver would not have worked.

**A mechanism read from the source is a hypothesis; and before reporting a null, work out whether the
arm could have shown the effect.** *(T12, T10.)*

Exporter SI snapshots advance per leg in the code you read, but state tracks media position. A 15 s clock with 870 ms lag predicts ~0.6 differing emissions in ten, so zero confirms nothing until the clock is driven at resolution limit (seven in ten). T10: when state is shared, model what advances it before crediting a lane.

**Compare with the suspect field masked before attributing a conflict.** *(T12.)*

97–98 % of conflicting datagrams differed in one field minted upstream of both groomers. Payload difference is measurement; groomer divergence is conclusion.

**Before recording that a stage preserves a property, check whether another experiment already found
that it does not. A contradiction between two files is worth more than a re-measurement, because one of
them is already wrong and is being cited.** *(T4.)*

T4 credited PCR cadence transport while T2 had tabulated lane impairments with source at 20–28 ms against egress 319.9 ms and T8 showed the same split from SRT. Treat cross-file contradiction as a first-class defect.

**When a processing stage and its source could each explain a placement defect, the stage's own
insertion counter decides it — not the arithmetic that fits.** *(T18.)*

Starvation was persuasive: `underruns` equalled nulls inserted and the commanded carrier exceeded content rate by 3.2 %. Matching carrier to content cut underruns from 18,070 to 5 while repetition stayed at 502 violations. A defect that survives removal of its supposed cause belongs to the other stage.

**A counter reading zero in the one configuration where the thing it counts is impossible is evidence
about that configuration and nothing else. Vary the condition that enables the mechanism, and check the
counter moves, before quoting it.** *(T18.)*

`pcr_inserted=0` at **0.0 % stuffing** was quoted across five documents, but that groomer inserts PCR only into slots it was already going to stuff, so the counter cannot read anything else there. Across the ladder it reads 137, 103, 28, 0 insertions at 4.1 %, 3.2 %, 0.8 %, 0.0 % stuffing while violations hold 491, 489, 503, 502 — four insertion rates, one result.

**A threshold-crossing count summarises a distribution and can point at the opposite of its cause. Before
asking anyone to change a rate, plot the interval distribution and check the mean is actually deficient.**
*(T18.)*

375–414 "intervals above 40 ms" per window read as too few PCRs, but the distribution showed 31–36 PCR/s against the source's 41, median interval **11 µs**, 85 % under 1 ms, and every violation in a hole between bursts. Loss and clustering are also indistinguishable in the count and obvious in the distribution — a lossy SRT lane posted 538 crossings with median 24.8 ms and 0.0 % under 1 ms.

**Keep a byte-transparent control in any rig that measures a conversion, carrying the same source in the
same session.** *(T18, via T8b.)*

The defect went eighteen months mis-summarised because the exporter was only measured through a groomer and the source was profiled in a different session. One congestion rig wrote `moq export ts` straight to file and carried the identical clip on the same PID over SRT and two segmented clients, so "source conformant, count survives, spacing does not" was readable three ways off one session.

**A precise upstream report can be undone by an imprecise in-house paraphrase, and the paraphrase is what
gets cited.** *(T18.)*

The filed issue said "not sparsity" with mean conserved to 0.7 ms; in-house summaries said "emits PCRs too rarely" and propagated into `docs/` and README. Restate the mechanism, not the symptom that made it visible.

**Pin upstream-report links to a commit on `main`, not to a working branch.** *(T10, moq-dev/moq#4353.)*

Branch links 404 after merge. Use `https://github.com/<repo>/blob/<full-sha>/<path>` from the commit that holds the cited tree and recheck after merge.

**A cleanup job must never run against a live results tree.** *(T8b.)*

A 68-cell matrix wrote ~140 MB per cell onto a host with 3.3 GB free, so a janitor deleted captures older than three minutes. C3 sums all N receivers; four of six cells lost second and third captures before summing, leaving shares that cannot distinguish unfair sharing from collective under-use. The two survivors showed 25 % aggregate utilisation against SRT's 84 %. Tell the janitor what analysis needs, not just what is being written now; derive sums before deleting inputs.

**An unattributed residue is not a finding.** *(T12.)*

2.90 % of datagrams still differed after masking the continuity counter; breaking residue down by PID named the second defect.

**Distinguish a stage that *normalises* a difference from one that merely gives two streams a common
frame of reference.** *(T12.)*

Only normalisation bounds what downstream measurement can see. Position grooming makes legs comparable and carries displaced tables faithfully rather than absorbing them.

**When a comparison ranks transports by a property of their output, measure the input as well.**
*(T15.)*

Otherwise pass-through transport is credited with the source's virtues and encoder properties get filed as protocol claims.

**When an argument says two measurements should converge, check whether the mechanism it proposes
would cost something elsewhere in the same comparison.** *(T14.)*

A TS packager retains stuffing; one that stripped it would forfeit byte-verbatim segments and the fidelity advantage in the same comparison.

**A hypothesis that predicts a *gradient* is cheap to falsify: run the extreme first.** *(T12.)*

Doubling mux rate changed the convergence cell by nothing measurable.

**Predict the deviation's magnitude from the mechanism before measuring it, and confirm it by spreading
the variable the mechanism scales with.** *(T3.)*

PAT and PMT are 376 bytes, so injecting them at a segment head should displace every later PCR by transmit time for 376 bytes — predicted 300.8, 109.4, and 302.4 µs on three clips spanning 2.75× in bitrate; measured 297.7, 109.4, and 301.9. Prediction makes the number attributable; bitrate spread makes agreement evidence because a wrong mechanism would not track 1/bitrate.

**Run the falsification test even once you have stopped believing the prediction — a caveat retired by
measurement eliminates a class of cause, and a caveat retired by argument eliminates nothing.**
*(T8b C3/C4.)*

`cake` cut RTT from ~550 ms to 100 ms while C3 collapse survived at 48 % of cap, excluding bufferbloat by measurement rather than argument.

**When a stage reports a bad input, ask whether the stage's own contract was ever written down.**
*(T19, `mpegts-pacer`.)*

The groomer shed 45.9 % of exporter content and this was filed as lane property, but it read one PCR interval as both duration and length — an assumption no source must satisfy. On a fixture with a perfect value grid and clustered positions it exited zero having discarded 67.2 % and added 106 discontinuities. Make implicit assumptions measured quantities compared against configuration, not silent thresholds; a success exit code is not proof the input was bad.

**Before a throughput ceiling is attributed to software, get the platform's own statement about the
interface.** *(T26.)*

On Nitro, `ethtool -S ens5` publishes `bw_out_allowance_exceeded`, `pps_allowance_exceeded`, `conntrack_allowance_exceeded`, and `linklocal_allowance_exceeded`. All four stayed at **zero** through three arms up to 1.47 Gb/s and 154 kpps beside relay CPU, so collapse had to be explained elsewhere. The harness fell to subscriber idle time and process count; the relay host to per-process accounting — instrument each candidate, not only the one under test.

**When the only remaining difference is the build, bisect it — and shrink the reproducer's period
first so a step costs minutes.** *(T27, the #3375 regression.)*

Fan-out video loss at the first content join made a 600 s clip cost ~20 minutes per bisect step; truncating to 30 s put a join every half minute and six steps in about an hour. Cut period to what the failure actually depends on, not the full pass length.

**Carry a known-good binary as a second subscriber in every bisect step.** *(T27.)*

Run candidate and last-known-good builds against the same publisher, relay, and join; void the step if the control stalls. That turns flaky relay, load, or wrong binaries into `skip` instead of false verdicts.

**`git bisect run` inherits a non-login shell, and a build that cannot start looks exactly like a
commit that cannot be tested.** *(T27.)*

Missing `cargo` on PATH made every step exit 125 (`skip`) in 25 seconds. Set `PATH` in the step script; a bisect that finishes faster than one build takes has not tested anything.

**A fix verified against the stimulus it was written for is not verified against that stimulus's
complement.** *(T27, on this campaign's own contribution.)*

#3375 passed all six T23 arms, each a single timeline event in a single pass, but stalls video and primary audio permanently on a continuous timeline whose content restarts — the stimulus a real encoder produces. Pre-fix, a true rewind costs everything; post-fix, a non-rewinding content join does. Verify fixes by adding the case the fix's logic newly decides about; where a fix introduces a detector, add the arm where that detector should stay silent.

### A mechanism read from a diff names the component, not the loop

*(T8b C7.)* Bisect put random-loss collapse on #4001's interleave hold: each hold spends skip budget, so holds become skipped content. A hold alone costs a quiet track one wait; collapse needed `rewind()` renewing the hold at every source skip, making the loop self-sustaining. `UnknownSession` and group evictions in logs did not track delivery. Settle suspected mechanisms with a same-build switch on one variable (here an environment override of the hold budget) and log the decision (hold start, tracks waited, end). The switch proves causation; the log shows the loop, which neither bisect nor diff can show.

### Locate a whole-capture error count in time before naming its cause

*From [T45](test-45-live-tstd-remux.md)'s comparators.* Twenty-six continuity errors at default cap looked like host load; at 150 ms cap on a quiet host there were ninety, all in the groomer's first 5.3 s while trimming a 4.6 s startup backlog. SRT audio decoder failures clustered around one 22-packet loss at 139.7 s and passed graded halves. Before attributing a count, place events in time: spread causes predict spread events; startup transients and single incidents predict clusters.

### Repeat a cell that disagrees with its neighbour before naming what differs between them

*From [T47](test-47-fixed-delay-export.md)'s cross-host arm.* The per-PID build's first cross-host run failed every MP2 unit by a nearly constant 188 ms where the namespace rig's 0 % arm passed every buffer; topology suggested arrival skew or release anchoring. The second run at the same settings failed on video, not audio; a third passed. A video group skipped at join put video on its own release clock at an offset the join set; traced joins on one host fell into the same states, and the 1 s loopback pass being compared against was one of them. **When one run of a new configuration differs from the old one, run it again before explaining the difference.** Configuration effects repeat; shape-changing failures belong to entry state — here answered by release-stage per-frame slack, which also made the offset measurable. **A result that repeats to the tenth of a millisecond is one state repeating, not robustness:** minimum margins 413.4, 63.6, 138.4 ms recurred exactly across cross-host and loopback runs sharing a 200 ms state.

---

## 5. Rig hygiene

**A server role that cannot bind its port has to stop the run, or the run rides the previous
run's server and dies with it.** *(T47.)*

The cross-host origin starts relay and importer on a fixed port; if the new relay exits on "address
already in use" unchecked, clients attach to the old relay and fail later with errors that do not
name the cause. **Check that a server you started is still running before starting its clients.**
An exit status from `&` says only that the process was forked.

**A `pkill -f` or `pgrep -f` pattern sent over SSH matches the command line that carries it.** The
incidents and the remedy are in § *A `pgrep` or `pkill` pattern matches every command line that
carries it* below.

**When arms run back to back against a service that caches an admission decision, the cache carries
the previous arm's answer into the next one.** *(T37, T38.)*

The relay caches the authorization endpoint's reply for its `max-age`, so a grant withdrawn to end
one arm can still read as *withdrawn* when the next arm dials in — correct behaviour that silently
voids arms. Either wait out the cache between arms or clear it, and never read "no media" as a
publisher fault until the admission cache has been ruled out. With no subscriber between arms the
relay cancels upstream as idle and the resumed broadcast may not deliver; **hold one keepalive
subscriber on every channel for the life of the matrix**, with an unlimited reconnect budget.

**A stimulus built to defeat a detector must be graded as *healthy* by that detector before it is
used.** *(T24.)*

Naive packet suppression breaks continuity counters and any TR 101 290 P1 check catches that — the
experiment would "detect" failure as an artefact of the tool. **When the hypothesis is "X cannot see
this", the stimulus has to be proved invisible to X before the run, not after it.** T24 measured the
unmodified clip first: matching packet and PCR counts, zero continuity errors, `pcrverify --absolute`
passing.

**A detector that watches an aggregate has a sensitivity floor set by the share of the aggregate it is
watching, and that floor has to be reported with it.** *(T24.)*

The stuffing ratio detects dead video unmissably (13.7 % to 95.2 % in one second) but dead audio peaks
at 27.0 % where control peaks at 27.1 %, because audio is 4 % of the mux and video is 82 %. **Any
detector reading a ratio, total or rate over a composite has this property**; report the smallest
contributor whose loss exceeds the aggregate's variance, or use per-component instrumentation.

**Before grading two pipelines for determinism, hash every artefact they are supposed to share.**
*(T12 arm D, independent upstream.)*

Each host's own source copy, binary, relay and groomer can diverge by a byte or a stale copy and
produce a false negative. Four checksums up front convert arguable divergence into conclusive agreement;
the secondary groomer is a copy nothing on that host marks stale.

**An instrument that reads zero has not measured zero until it has been shown reading non-zero.**
*(T12 arm D.)*

`t12-dual-host.sh` reported 0.0 % leg CPU for a whole run because `ps -o %cpu -p` reads the wrapper;
`-g`/`--pgid` on procps-ng 4.0.4 also returned 0.0 %. Run the rig once against a known load before
believing nulls.

**Every statistic the experiment intends to report must be an output the cell prints. A number
recovered afterwards from files that happened to survive is not a measurement, it is a salvage.**
*(T8b C3.)*

C3 needed the aggregate over N concurrent flows; the cell graded only flow one and stat-ed surviving
captures until a mid-matrix janitor deleted four of six. Sum at grade time and print `agg_bytes`/`agg_mbps`
so captures need not survive the cell. *Ask of each intended finding: which printed field is it? If the
answer is "we can work it out from the artefacts", it is not yet measured.*

**Retire a caveat about the instrument by moving the instrument, not by arguing about it.** *(T19.)*

A Python reader on two vCPU was labelled an upper bound until the same clip on eight cores read 7.45 %
against 7.45 % at zero CPU pressure — one host, one file copy, four minutes. *A host-bound caveat is
usually cheaper to remove than to keep restating.*

**Derive a rate target from a capture of the stage's own input, never from another stage's output —
and treat an unexpectedly smooth result as a suspect one.** *(T13.)*

A pass-through pacing target taken from the wrong place throttles below the true rate or drains a join
backlog above it and looks *flatter* than a correct run; both produced plausible tables.

**Grade a downstream stage against captures taken from the pipeline it will sit in, never against a
synthesised approximation of that pipeline's output.** *(T13.)*

A CBR input built by stripping nulls from the source retains the source byte schedule, arrives ahead
of groomer slots, and produced thousands of drops and continuity errors that a real capture of the same
shape did not.

**A daemon started in a subshell outlives its own teardown, and answering on the port does not make it
yours.** *(T12.)*

`( cd dir && relay config ) &` records the subshell in `$!`, so teardown leaves the relay bound; the
next run's fingerprint poll can succeed against a stranger. `exec` the daemon inside the subshell and
after a successful fingerprint poll verify the daemon is still alive. T6's HTTP origin showed liveness
is not enough: use an identity token unique to the cell in the served tree and refuse until fetch
returns **that** value. T7 had overlapping sweeps on one port grading whichever publisher served.
**So the identity token belongs in every rig that binds a fixed port, and it needs a companion: refuse
to start on a port already in use, and hold a lock for the length of a sweep.**

**On a lane that two sources can serve at once, the failure is repeated time, not lost time — and
neither a continuity check nor a PCR-interval check can see it.** *(T6.)*

T6's segmented arm reported zero CC discontinuities while the stream jumped ±20 s; both gates ask only
whether the clock moved. The tell is rate ratio above 1× or an explicit PCR decrease count — add one
where two publishers, packagers or origins can be live simultaneously.

**A metric that only fires on an anomaly is only ever exercised by one, so prove its arithmetic on a
case where it fires.** *(T6.)*

The rewind counter first used `pcrextract`'s unsigned offset column and wrapped on the event it
existed to detect. A baseline where the metric reads zero is not evidence that it works.

**Cancel a safety watchdog at teardown, or it fires into somebody else's cell.** *(T5.)*

Uncancelled `sleep 1800; tc qdisc del` jobs deleted shapers mid-run in later cells; loss cells looked
immune when the impairment was gone. Cancel at teardown; fail a cell that finds no shaper where one
was armed.

**Segmentation offload decouples commanded loss from applied loss, and by a different factor for each
transport — so it breaks comparisons, not just constants.** *(T5.)*

`netem` drops on TSO/GSO super-packets; one `loss 10%` delivered **7.8 % to the segmented lane and 2.5 %
to the media-aware lane**. Disable kernel offloads and application GSO (`--server-quic-gso=false`) on
QUIC. **Label the row with the loss the shaper measured, not the loss it was asked for** when a gap
survives.

**Loopback is not a small version of a network path: its MTU makes a percentage loss model
meaningless.** *(T5.)*

`lo` at 65536-byte MTU makes each drop event far larger and burstier than a real path. Pin MTU to 1500;
the tell is packet count far below expectation for the window.

**`netem slot MIN MAX` with no allowances is a rate cap, not a jitter model.** *(T5.)*

Bare `slot` releases one packet per slot (~200 kb/s ceiling). Set `packets` and `bytes` allowances so
timing varies without metering throughput.

**In a timing rig, assert the process census between legs rather than trusting a kill, and check that
a file's size and its packet count agree.** *(T13.)*

Killing a backgrounded pipeline by its last PID reaps only the groomer; orphaned subscribers inflated
CPU. A 17 MB file that censused as 2.4 M packets was the tell.

**The carrier rate must exceed the arriving content rate, or the groomer drops content.** *(T12.)*

A 2.0 Mb/s egress target for a 1.9 Mb/s feed produced 4,011 drops and 11 continuity errors.

**A two-host latency figure must bracket its clock, and a cell whose clocks moved by more than the
probe's uncertainty is spurious no matter how clean it looks.** *(T18.)*

One cell straddled a clock step (13.94 ms drift against 6.47 ms probe uncertainty) and returned an
attractive median of 1000.3 ms with zero PCR violations; re-run read 2072 ms with 36 violations. Probe
offset before and after each WAN cell.

**Launch a long-lived remote fixture once, from a locally backgrounded SSH, and have the measurement
probe it rather than start it.** *(T18.)*

`setsid nohup … &` over SSH blocks until the remote process exits, so a cell starting its own hour-long
clock server hangs for the hour. Background SSH locally; a cell that finds no reference should fail loudly.

**Bind the port before opening the output file, and refuse the run when a previous cell's listener is
still up. And do not trust a process census taken from a sandboxed shell.** *(T18.)*

Opening CSV before binding truncated the file on port collision so failure looked like "transport
delivered nothing". Sandbox `ps` missed a sweep still holding taps and CPU; pre-flight with `pgrep`
from an unsandboxed shell.

**Sort on the key, not the record.** *(T12.)*

Sorting whole `(time, leg, payload)` tuples ordered microsecond-tied datagrams by payload and scrambled
one leg into 207 phantom continuity errors.

**Any redundancy test whose sources are started independently measures its own clock skew.** *(T6.)*

Independent replays from clip start lag by the join delay; *"same file" is not "same stream"* when two
packagers open the clip apart in time. Fan one regulated source into both legs and forward leaps vanish.

**The merge window is the union of the legs' activity.** *(T12.)*

Grading only where both legs are live truncates at the blackout being measured and scores covered
outage as none; the survivor defines the end of the window.

**Verify where the capture tap sits relative to the impairment.** *(T9.)*

A tap downstream of the shaper measures what reached the path, not what the sender pushed — without
that check, "unchanged under loss" can be tap placement.

**A workaround flag must record which platform it works around, and be re-tested when the platform
changes.** *(T26.)*

`--server-quic-gso=false` was for macOS loopback GSO stalls but ran unexamined on Linux EC2, costing
29 % relay CPU and half the fan-out ceiling before a scaling arm measured a handicapped relay. Re-test
inherited flags when the environment changes.

**Fit the model over the régime that holds, then move a resource to test its prediction.** *(T26.)*

Fitting every fan-out point averages linear region with collapse. Fitting only delivering points gave
0.806 % core per subscriber and predicted ~124 on one core; `taskset` halved that and the cliff arrived
between 125 and 150. **Constraining a resource to move a predicted knee is cheaper than scaling until
the knee appears.**

**A ramp cannot measure anything that develops. Hold the variable you are not asking about still.**
*(T26, T27.)*

At N=1 versus N=150, export memory looked flat because every point was 45 s old in a ramp where N and
time move together. Holding N=10 and varying time showed cache fill with drawdowns. A capacity rig and
a permanence rig differ in which variable they pin.

**A stop condition must fire on the cause, not on a symptom the failure also produces.** *(T27.)*

Delivery below 85 % of N=1 reported failure while `rx_bytes` and relay egress stayed flat — OOM had
killed a subscriber. **Where a resource can be measured directly, do not infer it from throughput**;
watch `MemAvailable` when memory can stop the run.

**A cleanup pattern must name the run, not the tool.** *(T27.)*

§5 already carries *A `pgrep` or `pkill` pattern matches every command line that carries it*. `pkill -f
ts-liveness.py` killed another experiment's detector on the same host. Scope every pattern to the run's
label, broadcast name or output path.

**A broadcast name may not be reused by back-to-back arms.** *(T27.)*

The relay retains an abandoned session until QUIC idle timeout; a reused name lets the second subscriber
attach to the first broadcast and die on publisher replace. One name per arm, or wait longer than idle
timeout.

**"Blocked" needs three words, not one: name the apparatus, and name the host you checked.**
*(T28 and T31.)*

T28 and T31 were marked runnable on macOS where `netem` and network namespaces do not exist, and
"blocked on a Linux host" was written widely — yet Linux EC2 hosts already had the apparatus. Distinguish
unverified absence from estate-wide block:

| What is true | What may be written |
|---|---|
| No host in the estate has the apparatus | **blocked** — and say what would supply it |
| A host has it, reachable over SSH, not yet checked | **not blocked; unverified** — go and check, it is one command |
| A host has it and the rig needs porting | **not blocked; not yet run**, with the porting cost |

**Record the substrate requirement in the register entry beside the third-party dependency**, and before
writing "blocked" on a substrate, enumerate hosts and check one.

**A grader is validated in the domain it was exercised in, and "file" and "wire" are different
domains.** *(T28.)*

`t28-media-lost.py` matched injected holes on file captures but reported **1,254 s of duplication in a
55 s** live exporter capture because clustered PCR emission broke the constant byte-rate assumption.
**Run the known-answer self-test in the domain you are about to use**; grade raw exporter output on PCR
cadence with byte positions ignored, or restore CBR through the groomer first.

**Delete an output file before the capture that is supposed to write it, or an outage measures the
run before it.** *(T4, live ingest.)*

`stat` on an undeleted path read the previous sample during outage and read healthy. **`rm -f` the target
inside the measurement function, never once at the top of the script**, and treat unchanged byte count
across a state change as a rig fault until proven otherwise.

**A file source feeding a live transport must be paced, and the reader must be attached first.**
*(T4, live ingest.)*

Unpaced `tsp -I file` floods UDP before the reader starts and false-fails transports. With `-P regulate
--pcr-synchronous` and reader first, loopback multicast worked. **A negative result about a transport
is only about the transport if the sender ran at the stream's own rate and someone was listening.**

**Never put `ffmpeg` in front of MoQ in a carriage path.** *(T3, T4.)*

`ffmpeg -c copy -f mpegts` is not passthrough: a 13-PID slice becomes **5 PIDs** with renumbered
video/audio; `tsp` is byte-identical. **Use `tsp -I srt` / `tsp -O srt` for SRT and `tsp` for replay;
if ffmpeg must appear, it is a transcode and must be declared as one.**

**Separate the contribution session from the thing under test.** *(T4, live ingest.)*

A fused `srt-listener | moq import` restarts the third-party feed on every experiment restart. Split at
local multicast so contribution survives MoQ kills and gives the rig a tap on the publisher input.
**Where a feed comes from outside the lab, the boundary between it and the rig is part of the rig's
design, not an implementation detail.**

**The reference arm for a carriage measurement is the input to the carriage, not a second copy of the
source.** *(T4, live ingest.)*

Three readers on the publisher's local group captured **byte-identical** windows alongside the publisher;
a separate encoder output is a different encode. **Take the reference from the last point the two paths
shared, and the difference is attributable.**

**Do not re-base a ladder on a different emulator to make it runnable.** *(T31.)*

macOS `dnctl`/`pfctl` would not be comparable to T5, T8b and T20 on `netem`; T31 extends T8b. Wait for
the Linux host.

### A rehearsal that starts from a directory somebody already set up has rehearsed the measurement, not the day

*From [T33](test-33-gate2-preparation.md).* Gate 2's harness assumed relay, fingerprint path and fixtures
that nothing in the repository created — built by hand in `/tmp` that no longer existed. **Rehearse from
nothing, on a host that has never run it.** Anything the rig needs and does not build is an untested
precondition; the same pass found undeclared script imports and a relay with no fingerprint endpoint.

### A regression with a sharp signature is a better build-identity test than a version string

*From [T40](test-40-continuous-join-through-srt.md).* Same commit on two hosts self-reported different
version numbers while the git suffix went stale independently. **Ask the binary what it is:** where a
defect has a sharp signature (pre-#3375 healthy under continuous-join, #3375 onward stalls), measurement
settles what strings cannot. [#3912](https://github.com/moq-dev/moq/pull/3912) dropped git-describe so
binaries report crate version alone with **no `-<sha>` suffix**; print the `bin-<sha>.sha` sidecar from
`ec2-build-main.sh` rather than `--version`.

### Hash both sides of a patched-against-stock pair before running either

*From [T11b](test-11-interop.md#t11b--openmoqs-msfts-publisher-through-a-moq-dev-relay).* An uncommitted
patch survived `git switch` and both binaries hashed identically. **A variant pair is two different hashes
or it is not a pair.** Commit the variant, rebuild each side from clean `git status`, compare SHA-256
before the first run.

### A closed issue is a claim about a tracker, not about a binary

*From the [#3987](https://github.com/moq-dev/moq/pull/3987) round.* Issues closed *as completed* by a PR
that added Markdown under `quest/` and changed no code, while defects re-measured live. **Re-test on the
closure; never read it as the fix.** Read the closing diff and the code path; `git log` plus diffstat —
a PR touching no source cannot fix a runtime defect.

### A watcher that polls for absence must wait for presence first

*From [T41](test-41-import-reanchor-coverage.md).* All arms reported death at t=1.0 s because the watcher
polled before the process existed. **Absence is what "not started yet" looks like as well as what "died"
looks like.** Wait for appearance, record that as t=0, then watch for exit; equal lifetime to start-up
delay is the signature.

### A watcher that polls for presence must not find the previous run's file

*From [T13](test-13-downstream-grooming.md) § Liveness.* A reused status file ended the run 37 ms after
the last publisher. **Presence is what "left over" looks like as well as what "finished" looks like.**
Delete status files before the run; run directories are fresh or cleared, never inherited.

### A control made of two production deployments is a coincidence, not an experiment

*From [T34](test-34-real-encoder-severity.md) and [T40](test-40-continuous-join-through-srt.md).* Two
hosts on builds either side of a regression varied host, kernel and path alongside the binary. **If the
same comparison can be made from pinned artefacts on one host, make it there and let the deployments
move.** Pinned binaries survive rebuilds; a control that forbids upgrades is eventually destroyed.

### An inline instrument damaged one lane and was invisible on the other

*(From [T28](test-28-failure-injection-matrix.md) P1-m.)* A PES-timestamp tap inline on both lanes was meant to cost both equally; on SRT it graded **4.2–5.4 s** lost and **5,704–8,930** continuity errors with no impairment, and **0.000 s / 0 errors** with the tap removed. `moq export ts` re-synthesises at egress and launders upstream damage.

**"The instrument is on both arms" is not the same as "the instrument cancels."** *(T28.)* It cancels only if both arms would report its effect. Where one lane passes bytes through and the other regenerates them, a damaging instrument is visible on the first and erased on the second, and the comparison measures the instrument.

**Prefer a mirroring tap to a pass-through one.** *(T28.)* `tsp -P fork --nowait --ignore-abort` feeds the instrument a copy while the graded stream continues. Keep an unimpaired control for every lane at every setting.

**"The tap" was two taps, and only one of them did it — so attribute the position, not the technique.** *(T28.)* The egress tap graded **0.000 s / 0 errors** inline; the source arm alone reproduced **4.563–4.693 s** and **6,001–6,493** errors. A pass-through instrument is dangerous where it feeds something real-time, not everywhere.

**The second attribution was confounded too, in exactly the way the sentence above warns about — the cause is a process boundary, not an instrument.** *(T28.)* Splitting the publisher to put Python in the path also moved `regulate --pcr-synchronous` out of the SRT sender's process; mirroring without Python still graded **4.601–4.602 s** lost, **6,104–6,133** errors, and **65.0 s** programme in a 60 s run. A single `tsp` holding both stages returned **0.000 s, 0 errors, 57.6 s**. Keep pacing and the transmitter it feeds in one process; treat "delivers more programme time than the run lasted" as a lost clock.

### A capture that stops early grades as a flawless cell

*(From [T28](test-28-failure-injection-matrix.md) P1-m and the idle-timeout bracket.)* When the session dies mid-cell the capture ends and a media-lost grader reports **0.000 s lost, 0 holes, 0 continuity errors** — best score, worst outcome (e.g. **19.8 s** captured vs siblings' **57.6 s**, or ~⅓ bytes after QUIC idle `dropped`).

**Grade the span and the byte count before reading any quality metric**, and treat a cell whose span falls materially short of its siblings as void rather than as clean. *(T28.)* Controls can be clean while impaired cells lie in the summary table.

### Matching on a measured quantity can collapse the sweep you thought you were running

*(From [T28](test-28-failure-injection-matrix.md) P1-m, the sustained-loss ladder.)* Matching SRT to MoQ's *measured* latency is correct, but MoQ's measured latency was ~2 s at every nominal budget, so budgets **0.5 s, 2 s and 6 s** became SRT settings **2,165, 2,016 and 2,012 ms** — one buffer run three times.

**After matching, print the matched values and check they still differ before reading the arm as a sweep.** *(T28.)* A flat measurement maps the whole range onto one point; the arm establishes one condition, not a ladder.

### An impairment rung has to be expressed in the units the result depends on

*(From [T31](test-31-congestion-capacity-ladders.md).)* Absolute shaped rates (**12 Mb/s** "moderate shortfall" vs ~**9.95 Mb/s** fixture) made a mild cell unimpaired and zero; re-based on multiples of stream rate (**0.9×**) hit the intended shortfall.

**Write a rung in the quantity the outcome is a function of, and derive the absolute value from the fixture at run time.** *(T31.)* Programme loss depends on rate *relative to* the stream; a quiet failure runs, grades clean, and never says the impairment was absent.

### A median across a window containing a step measures where the step fell

*(From [T28](test-28-failure-injection-matrix.md) P1-m.)* Two MoQ outage replicates reported medians **7,936 ms** and **2,184 ms** while p95 agreed (~**9,868 ms**); latency *steps* at outage, so median encodes outage position, not effect.

**Choose the statistic to match the shape of the change.** *(T28.)* For a step, report late-window value and trend; keep median only for stationary quantities. Where a metric is still moving at window end, call the figure a lower bound.

### A declared CSV column that is never written shifts every field after it

*(From [T28](test-28-failure-injection-matrix.md) P1-m.)* Header declared sixteen columns, writer emitted fifteen (`sys.argv[2:8]` dropped `capture_bytes`); name-based reads from `media_lost_s` onward returned neighbours' values.

**Assert the field count when parsing a self-generated CSV**, and reconcile at least one row against the human-readable log before building a table from it. *(T28.)* Shifted columns yield wrong numbers of the right magnitude.

### Never edit a shell script while it is running

*(From [T8b](test-8b-congestion-control.md) P0-i.)* A 20-minute pass finished ten cells then hit nonsense errors on lines that did not contain the reported text; `bash -n` passed on both copies afterward.

**`bash` reads a script incrementally, by byte offset, not into memory.** *(T8b.)* Rewriting mid-run resumes at the old offset in new bytes. Edit a copy for the next run; never overwrite a script with a live pass in it.

### A `pgrep` or `pkill` pattern matches every command line that carries it, including the one sending it

*(From [T26](test-26-cross-host-fanout.md), [T8b](test-8b-congestion-control.md) P0-i, [T25](test-25-isolation-under-abuse.md), [T43](test-43-fanout-current-build.md), [T47](test-47-fixed-delay-export.md).)* `pgrep -f` / `pkill -f` match the whole command line, including the SSH shell running the pattern. T26's `pkill -f "broadcast f5.fanout.hang"` killed the remote shell and left a stale publisher competing on the relay; T26 tap validation returned SSH **255** with the pattern present twice; T25 lost a session when `t25seg` appeared in the cleanup command line itself. T8b's `while pgrep -f "t8b-export-death.sh p0i "` matched the monitoring shell; T47's wait on **0.0.0.0:4443** never ended for the same reason.

**Bracket one character of any `pgrep`/`pkill` pattern** — `pkill -9 -f "[t]18-tap-perturb"`, `t8b[-]export-death` — so the pattern cannot match a command line that quotes it. *(T26, T8b, T25, T43, T47.)* Bracketing does not stop a parent argv that still carries the literal (T26, T25). **The reliable fix is to put the patterns in a script file on the host and invoke the file** ([`f5-reset.sh`](scripts/f5-reset.sh)), so the pattern never enters the caller's command line.

**The file protects only a session that does nothing else.** *(T43.)* An unbracketed pattern inside `f5-reset.sh` killed the caller; combining reset and launch in one ssh put the launch name in argv and the reset killed the session. Run the reset in its own ssh call.

**A reset that does not verify is not a reset.** *(T26, T43, T47.)* End with `pgrep -f "[p]attern" && echo STILL RUNNING || echo clean`, or refuse to start when survivors remain; wait on end markers, not only on process absence.

**A bracketed pattern still matches the next waiter in the queue.** *(T28 attribution runs.)* Three queued waits chained on script names deadlocked: the first waiter matched the third's command line. **Queue a chain as one sequential command**, `a; b; c`, or wait on PIDs and end markers only.

**Check that a multi-cell runner is still alive after its first cell.** *(T47.)* A `(nohup bash runner.sh &)` from a short-lived shell ran one **540 s** cell then stopped; the same runner as a job of a persistent shell ran all cells. Look for the second cell's header in the log.

### A replicate loop inside one script invocation re-uses the fixed port the last replicate held

*(From [T31](test-31-congestion-capacity-ladders.md), QUIC-backend arms.)* Three replicates in one invocation: two VOID, `Address already in use`, subscriber got `goaway` — old relay answered the new subscriber.

**This is the identity-not-liveness trap of *A process that is still there is not the process you started* (§ above), reappearing in our own replicate harness rather than in the system under test.** *(T31.)* With fixed ports, one replicate is one invocation with full teardown between; fail loudly if the port is bound before start.

**The same trap returned between cells, and by a build rather than a harness.** *(T31, build `5d0991b9`.)* `kill` plus one-second sleep was insufficient when the relay drained longer on SIGTERM; void cells until the ladder waits for relay exit (force after **10 s**) and logs if the started relay is not running **3 s** later. **A teardown timed against one build is an assumption about that build**; wait for the process, not for a clock.

### A subscriber that ran for the whole window and did not die may still have measured nothing

*(From [T8b](test-8b-congestion-control.md) P0-i.)* Outcome was process survival, so zero bytes still scored as full-window survivors; with `--auth-public` silently inverted (§5), a whole arm could look clean.

**Where the measurement is an absence, add an independent liveness column.** *(T8b.)* Classify capture below a floor as *void*; "nothing crashed" is not positive evidence the rig worked.

### An unattended workstation sleeps through a paced run, and every process survives it

*(From the #4733 re-run.)* Maintenance sleep stretched **60 s** arms to **780–1,060 s** wall clock; egress **12 MB–74 MB** vs **74 MB** full; only one arm valid. Under `caffeinate`, all ran **~61.7 s** with identical egress.

**Wrap every unattended local run in `caffeinate -dims`, and check each cell's wall-clock duration against its nominal window before reading its result.** *(#4733 re-run.)* Duration overshoot voids the cell however clean the exit.

### A grader whose pattern does not match its tool's wording scores every input as clean

*(From [T42](test-42-h3-receiver-fidelity.md) P0-e.)* `tsp -P continuity` emits `* continuity: packet index: …, missing N packets`, not `discontinuity`; the grader returned zero on a ten-packet excision until a built-in positive control aborted at zero.

**A grader must demonstrate, in the same run that uses it, that it detects known damage.** *(T42, T19, T20.)* Damage the input by a known amount, require the grader to report it, and abort if it does not — one arm buys protection against a mis-typed pattern and an inverted conclusion. **When a class of bug is found once, grep the whole rig directory for it before assuming it was one rig's mistake.** Four rigs shared the defect (three counted `TS:`, one `discontinuity` alone); two fed published tables; [`check-rigs.sh`](scripts/check-rigs.sh) now rejects patterns `tsp` does not emit.

### A metric that spans the rig's startup transient puts a floor under the control

*(From [T22](test-22-silent-media-plane-failure.md) P0-f.)* "Longest interval with no playlist advance" gave **8.1 s** on control vs **30.5 s** on a **30 s** stall; excluding pre-first-advance put control at **3.1 s** and stall at **31.5 s**.

**Define a metric over the regime the experiment is about, and discard the transient explicitly.** *(T22.)* A startup plateau in the null weakens discrimination without triggering re-examination.

### A bare `wait` returns only when the rig's infinite producers do, which is never

*(From [T25](test-25-isolation-under-abuse.md) P2-b.)* The rig backgrounds an `--infinite` packager, victim receivers, and abuse `while :` loops, then called `wait` with no arguments. That waits for every background job, hung **16 minutes** with pipe-buffered silence, and when restarted competed with the first pass for the same output directory — three arms lost to apparent packager flakiness.

**Wait on the specific PIDs the measurement depends on, never on all of them.** *(T25.)* **A backgrounded run that has not returned is still a running experiment.** Confirm the previous attempt is dead before re-running.

### The exporter manufactures bytes and clock, so neither measures what the media-aware lane delivered

*(From [T20](test-20-segmented-http3.md) 4a, T28/T31 re-grade.)* From moq-dev #3831 onward `--mux-rate` defaults to catalog `mpegts.muxRate`, padding to constant rate so `delivered_ratio` can exceed **1.0** with **47.7–94.1 %** null packets (`--mux-rate 0` turns padding off). `t28-media-lost.py` reads PCR; the exporter keeps **25 ms** adaptation-only PCR on the video PID across evicted groups (**0.775 s** lost vs **36.4 s** picture holes and **22** evictions on unpadded chronic congestion; **2.375 s** on transient **0.8×** with no picture missing). What survives is content-PID packet rate and presentation timestamps ([`t28-content-lost.py`](scripts/t28-content-lost.py)), graded per elementary stream.

**Before trusting a delivery metric, ask what the sender is allowed to manufacture.** *(T20, T28, T31.)* On re-synthesising egress, bytes, clock and continuity are egress work; access units are not. Report null-packet share; grade picture and sound separately.

**Validate a grader against the lane's failure, not against an excision.** *(T20, T28.)* Byte excision removes clock and content together; MoQ failures need agreement with pictures, content-PID packets, or eviction logs on impaired egress captures.

### A hole count sees only gaps between what arrived, so conserve against the window

*(From T28 matched ladder, content-graded.)* At **0.5 s** budget under **5 %** loss, content grader **2.76 s** lost while video stopped at **29.6 s** in a **60 s** window; hole sum has no gap after the last picture.

**Grade programme lost as expected content minus content present, not as the sum of the holes.** *(T28.)* Expected from window and clean cell ([`t2831-conservation.py`](scripts/t2831-conservation.py)); hole count is a lower bound. Report both where latency budget may mean late vs lost.

### A continuity count detects loss and cannot measure it: the counter is four bits

*(From [T19](test-19-pcr-grid-verification.md) cushion re-grade, [T5](test-5-network-impairment.md), [T31](test-31-congestion-capacity-ladders.md).)* **82,104** of **106,382** offered packets shed; working pattern found **15** events and **110** missing — three orders of magnitude under. The field is four bits, so gaps above **15** packets alias ([`cc-aliasing-probe.py`](scripts/cc-aliasing-probe.py)). On segmented HTTP, live-edge re-anchor after the availability window fires correctly but reports **33** missing for **200,000+** packet holes ([T5](test-5-network-impairment.md)).

**On the media-aware lane's egress the count cannot even detect loss.** *(T31.)* `moq export ts` re-muxes and writes its own continuity counters; group evictions upstream leave no gap. **0** errors on **75.64 s** picture lost is by construction and evidence of nothing about delivery; only byte-faithful paths carry counters the loss could disturb.

| excised | 1 | 5 | 10 | 15 | **16** | 17 | **32** | **160** |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| reported missing | 1 | 5 | 10 | 15 | **0** | 1 | **0** | **0** |

**Read continuity for whether a wire is clean, and conservation for how much survived.** *(T19, T5, T31.)* Pair zero continuity with delivered ratio; a small count on a shedding arm says nothing.

**Never quote a continuity count as a loss magnitude**, and where a table carries both, put the conservation or delivered-ratio column next to it so the pairing is visible in one row. *(T19, T5.)* When the counter range is smaller than the fault, it is an alarm, not a measure.

### An idle-memory baseline drifts by more than a null result's whole excursion

*(From [T25](test-25-isolation-under-abuse.md) P2-b.)* Abuse moved origin RSS **103.6→104.2 MB** (**0.6 MB** peak); idle baseline **102.8 MB** twenty minutes earlier — **0.8 MB** spread, larger than the excursion.

**Where a resource result is a null, report the bound, not the number.** *(T25.)* Quote per-pass baseline spread or an upper bound. **A discarded run's control arm is still data about the instrument**, even when treatment arms are void.

### Delay in front of the shaper costs an ack-clocked sender, and not a paced one

*(From [T42](test-42-h3-receiver-fidelity.md), [`rig-capacity.sh`](scripts/rig-capacity.sh).)* TCP through **20 Mb/s** `cake` with **100 ms** delay ahead of the shaper ran **4–6 Mb/s** while paced UDP passed **19.32 Mb/s** payload. CUBIC on a **3 MB** transfer left slow start early at ~**45 %** of BDP with threshold **39** segments; with `cake` as data-path root the same transfer reached **15.3 Mb/s** and threshold **245**. UDP was unchanged; `cake` under **0 ms** `netem` (as ladders use) gave the same TCP bias. Ack-clocked senders can be slowed in a way paced SRT is not; the topology re-run moved neither media lane outside scatter ([T28](test-28-failure-injection-matrix.md)).

**Calibrate a new or changed rig with bulk and paced traffic before the first lane runs**, and say where the delay sits relative to the bottleneck. *(T42, T28.)* Use [`t2831-topology.sh`](scripts/t2831-topology.sh) to separate rig bias from lane behaviour.

### A bisect across a long-lived branch meets CLI states that neither endpoint has

*(From [T28](test-28-failure-injection-matrix.md) idle bisection.)* First-parent bisection landed on upstream `dev` merge; inside `dev`, new dial flags still paired with old `--latency-max`, so `moq export ts` rejected arguments and every cell captured **0 bytes**. Steps logged "no teardown" because nothing ran; cargo targets filled the disk. After the export flag was fixed, relay already took `--listen` while `--auth-public` remained a prefix, so the rig's `**` glob matched nothing and the lane delivered nothing with no error (see §5 `--auth-public` inversion).

**Detect each flag from the subcommand that takes it**, not from a sibling flag's spelling, and make a bisection step report a void cell as void, with the error it printed. *(T28.)* Check build-host disk before a long bisection.

**When a first-parent bisection lands on a merge, test a `main` commit the branch absorbed, and the branch's merge of it, before bisecting the branch.** *(T28.)* Branch commits need not contain the good end.

### A diagnostic flag can exist in `--help` and not in the build

*(From [T28](test-28-failure-injection-matrix.md) reorder attribution.)* `--quic-qlog` in help but compiled out in release → NA in every qlog cell.

**Run a diagnostic arm's flag once against the exact binary before queueing it**, and make the arm check for the capability rather than discover its absence in the results. *(T28.)*

### A sandboxed shell can bind loopback and not connect to it

*(From [T6](test-6-relay-resilience.md) single-relay standby drill.)* Sandbox: relay listened, publishers connected, subscribers timed out (**0 bytes**); same script over ssh on Linux was clean.

**Treat a loopback rig that connects some clients and not others as the environment until shown otherwise**, and run loopback drills on a host reached over ssh, or from an unsandboxed shell, rather than from a sandboxed one. *(T6.)*

### What a signal means to `moq` depends on the build

*(From the same drill, [T6](test-6-relay-resilience.md).)* `moq` **0.12.1** (`ffa5b81b`): SIGTERM hard-killed; **0.12.8+**: SIGINT and SIGTERM both clean-close; relay reselect behaviour differs by build and signal.

**Record which signal drove a graceful arm and which CLI version received it, and prefer ending the importer's input as the build-independent clean exit.** *(T6.)*

### With a shared hop the newest publisher serves, so a standby drill must know which one it killed

*(From the same drill, [T6](test-6-relay-resilience.md).)* Recency ranking and hash ties mean subscribers may not be on the publisher you signalled; idle-publisher kill is the control and should show no stall.

**Start subscribers after both publishers are producing, log each publisher separately, and read which one received the media subscriptions before and after the signal.** *(T6.)*

### The client's idle timeout sets the relay's detection

*(From the same drill, [T6](test-6-relay-resilience.md), [T13](test-13-downstream-grooming.md).)* QUIC uses the smaller idle timeout; client **6 s** → relay `timed out` **7–9 s** after kill. [T13](test-13-downstream-grooming.md) kill arms stopped **~31 s** (default **30 s** idle); **95 s** window showed exit vs `--linger` resume.

**Record the idle timeout on both sides of every session a failover figure crosses**, not only the relay's. *(T6, T13.)*

**After a hard kill, observe for at least the idle timeout plus the behaviour's own window**, or "not yet detected" is recorded as "hung". *(T6, T13.)*

---

## 6. Claims, and their scope

**A scratch change that fixes the measured case is a fix only once the upstream tests pass with it
switched on.** *(T47.)*

A release-stage change made eleven traced joins conform with one margin set, but with its environment variables set four of `moq-mux`'s 941 tests failed — each part broke genuine timeline restart handling the rig never exercised. Gating behind a variable keeps default tests green and says nothing about the change. **Run the suite with the change on**; a failure there defines the mechanism and the cases a fix must preserve.

**Before calling an upstream close accidental, read the body of the pull request that closed it, not
only the commit diff.** *(T13 / P1-n, the #2779 draft.)*

Continuity-counter defect was fully present while [#2779](https://github.com/moq-dev/moq/issues/2779) showed closed-completed the same day as [#3868](https://github.com/moq-dev/moq/pull/3868), with no commit touching numbering — every timeline signal said *swept up by accident*. #3868's body says "`2779` is abandoned (close #2779 as won't-fix on merge and remove its `quest` label)". **A grooming pull request states its dispositions in prose, and the disposition is not in the diff.** When the inference is about *intent*, the evidence is what somebody wrote, not what the code does. Posting a reopen would have asked a maintainer to reverse a considered call; framing the sibling as rightly closed carries the same measurement as an argument the maintainer has reason to want.

**Reading a specification from inside finds what it says; asking a deployment question from outside
finds what it omits. Do both.** *(MSFTS review, 2026-09.)*

Three passes over MSFTS §5.5 found four defects in what the text said; none found the CAT omission — §5.5.2's retain list follows the PAT/PMT graph, the Conditional Access Table sits outside it, and the EMM PID is unreachable from the list, so a conforming publisher can scramble a track nothing can descramble, silently. A commercial question about BISS-CA over MoQ forced an end-to-end entitlement trace. *A reading pass checks the document against itself; a deployment question checks it against a use it has to support.*

**Cite the clause that carries the obligation, not the clause with the famous name.** *(MSFTS
contribution round, caught in review before filing.)*

A draft cited ISO/IEC 13818-1 §2.4.2 for PCR-driven system-clock recovery; the T-STD is idealised — PCR defines a delivery schedule and §2.4.2 constrains buffer occupancy against it. Real delivery within tolerance is 13818-9 and, for DVB, TR 101 290 PCR limits. *The stronger argument is schedule, then tolerance.*

**When a measured quantity depends on contention for a shared resource, one user of that resource
measures the uncontended case — and must be labelled as such.** *(T37 D2 against D7.)*

T37's revocation sweep at one subscriber per arm reported worst case "one re-check cadence plus 0.110 s" as the mechanism's bound; that figure is the *floor*, because re-checks come from a cache shared across sessions and widening only appears with a second session. Six staggered sessions put worst case at 1.54 cadences (the implementation names two). *Before quoting a per-session figure as a bound, ask what the sessions share.*

**A verified hypothesis is not a working mechanism.** *(T39 Parts B and C.)*

One credential can carry both media `--subscribe` and telemetry `--publish` scopes, routed independently — six cells with a readback oracle. That does not make the telemetry return path available: shipped tooling cannot publish non-media data at all. *Name what the hypothesis tested and what it did not, especially when it passes.*

**A defect found through an incidental stimulus is described at the level of that stimulus, not of the
class it belongs to. Characterise the class before reporting it.** *(T23.)*

T21's exporter PCR degenerating into a counter after a loop was drafted as "PCR does not survive source discontinuity". Grading direction, magnitude and class separately showed 33-bit rollover carried **correctly**, forward jumps recover, and rewind yields withhold-and-burst without the counter — any of which would have overstated scope upstream. *One stimulus establishes that a defect exists; it does not establish what it is.*

**Verify that a fixture asserts what it claims before spending a run on it.** *(T23.)*

Arm B was meant to be a 600 s backward jump by subtracting 600 s from zero; that is legal rollover arithmetic, not a backward jump, so the discontinuity arm would have measured the wrap arm and agreement would read as corroboration. Reading stimuli back through the analyser caught it in minutes. *Generating a fixture and grading a fixture are two claims.*

**A stage that integrates must be graded over a window longer than its own integration time, or the
run has qualified the transient.** *(T21.)*

A closed-loop pacer replacement was qualified on a 300 s live arm (stable latency, conformant wire), but its failure mode takes about **nine minutes**, and the first soak found media-rate estimate ramping to 2.58 Gb/s with cushion at zero. Where a change introduces an accumulator, the qualifying run must outlast its time constants — here **source looping** at 600 s, which a short test never hits.

**Where a stage derives a quantity from its input, the input's own version of that quantity is a
control, and capturing both ends of one run is cheaper than arguing about which end is wrong.**
*(T21.)*

The groomer was accused of a broken rate estimator for two runs; publisher input and exporter output in the same run showed a clean 25 ms grid and one signalled discontinuity on input, no discontinuity and a stopped clock on export — the estimator was faithful to input that had stopped telling the truth. One `tee` on each side settles deriver-versus-source disputes.

**An estimator must not integrate a sample it has no reason to believe, and a physical ceiling is the
cheapest reason available.** *(T21.)*

The pacer computed 431 Mb/s inside an 11 Mb/s carrier, drained its cushion, and both numbers sat in one counter line for twenty minutes. Over seconds, content cannot arrive faster than the carrier; single-interval spikes are what the buffer is for — check recovered quantities against conservation laws and raise a counter rather than clamp silently.

**A quantity that is supposed to be stationary needs a time series, and a high-water mark is not one.**
*(T21.)*

`buffer_high_water` without standing depth left only a peak that never falls; collapse from ~1.4 s to zero was invisible until instantaneous occupancy was sampled on a timer. Cumulative counters answer "what went wrong"; standing levels answer "is it still going wrong".

**Conformance of the output is not health of the stage producing it.** *(T21, T22.)*

A groomer defect that destroyed the de-jitter cushion left **every** wire check passing: 0 continuity errors, 0 PCR intervals above 40 ms, exact CBR, programme conserved. T22's frozen source left every *transport* check passing. Conformance is evidence about bytes in the measured window, not that the pipeline will keep producing them; lasting health needs stage counters and stated scope (minutes, not hours).

**Citing another component as the working reference for a contract is a behavioural claim about that
component, and reading its source is not evidence for it.** *(T19.)*

#2984 rested on `moq-srt` implementing #2967's pacing contract; reading `send_at = anchor + (ts - base)` looked exact but cross-scale PCR versus 90 kHz media fell through to an unpaced error arm. **Reading source is sound evidence that something is absent and weak evidence that something present works.** Measure the exemplar or state that its correctness is assumed.

**Split a capability claim by pipeline stage before publishing it.** *(T14.)*

"No maintained toolchain does Low-Latency HLS with MPEG-TS" split on execution: **publishing** is one free command; **receiving** has no free implementation. *"No tool does X" is usually "no tool does one particular stage of X".*

**A claim that a class of tool cannot do something is a claim about the input as much as the tools —
name the input property that defeats them, then find an input without it.** *(T13.)*

"No off-the-shelf stage grooms a broadcast mux" held for nine chains until the binding property was egress: `moq export ts` carries no stuffing, so groomers must inflate. Identical chains against segmented egress pass nulls through and `tsp -P pcradjust` alone passes all four criteria byte-for-byte. *Name the property someone upstream can change.*

**A claim about what a tool cannot be configured to do is a claim about its whole parameter space.**
*(T16.)*

"No configuration of the documented flags passes" came from two facts about three parameters; two more arms found one pass — narrower and more useful.

**A "structurally impossible" claim derived from a specification is a hypothesis about an
implementation, and costs one afternoon to test.** *(T14.)*

"TS segments imply re-mux, so byte-verbatim carriage is unavailable" — measured, a segment differs from source in byte 3 on one PAT and one PMT only. *When the claim falls, check whether the named mechanism survives:* here packets are *inserted*, verbatim in payload but not as a mux, and those two packets still cost file-domain PCR accuracy.

**When recording what a blocked measurement needs, name the constraint that actually binds.**
*(T14.)*

A cell blocked on "caching HTTP/3 origin, not installed" stayed blocked after two origins were installed, for unrelated reasons. *A guess about the blocker sends the next session shopping instead of measuring.*

**Liveness must key on programme content, not carrier presence — and the enforcement point is the
sender.** *(T12.)*

A rate-holding groomer mints conformant CBR with zero programme; both selection policies read that as health. *A receiver cannot recover information the sender declined to omit.* Exclude the groomer's adaptation-only PCR from the content check.

**Every stream-position quantity must be a function of position in the stream, not of what this
instance happened to emit.** *(T12.)*

A resumed leg returned 8,756 datagrams behind its partner because RTP sequence counted datagrams *sent*; sequence, timestamp and PCR must be stream-derived for redundancy.

**Pin every parameter the property depends on, then measure; a prediction of divergence is not a
substitute for one run.** *(T12.)*

Ungroomed legs were predicted to fail alignment on phase; with RTP framing pinned and co-start they align in all twelve cells and fail on *conformance* instead — found only by running.

**When comparing two designs, draw the demarcation before comparing, and count only work that falls on
the same side of it.** *(T14, found in editorial review.)*

"Segmented HTTP's receive-side hand-off already ships" counted client equipment as discharging the distributor's obligation. Advantage in a third party's capex is optionality, not architecture.

**When a defect is attributed to a component, name the boundary the measurement was taken at — a fix
verified inside that boundary can be invisible outside it.** *(T19.)*

PCR clustering was fixed at the exporter (exact 25 ms grid versus 85 % sub-millisecond intervals), but spacing lives in per-frame timestamps while stdout carries bytes — the defect survived as clustered packet *positions* on the wire. "The exporter" and "the exporter's output interface" are separate stages.

**Grade an upstream fix on the deployed chain, not only on the claim it makes.** *(T19.)*

#2967 was true at the exporter; adopting it alone would have shipped continuity from 0 to 824 errors and delivery latency from 118 to 769 ms — visible only end-to-end in one 90 s run.

**A measurement that is undefined as a verdict can still be sound as a diagnostic, if what is read is
the distribution rather than the pass/fail.** *(T19.)*

`pcrverify --absolute` on rate-less media-aware egress cannot yield a conformance verdict (stated since T13). It still separated builds: pre-fix missed by *varying* amounts, post-fix by constant 24,842 µs — arithmetically repairable versus not.

**A head-to-head is only a lane result if the lanes were on the same substrate; otherwise it is a
substrate result wearing a lane's name.** *(Editorial audit of T5/T8 against the §14 verdict, settled
by [T20](test-20-segmented-http3.md).)*

Reordering 0.98 versus 0.19 was measured with TCP under segmented HTTP and QUIC under MoQ while the recommended configuration is HTTP/3 on both. Re-run on shared substrate found packet size differed too — **1,209 packets averaging 34,380 B on the segmented lane against 29,062 averaging 931 B on the media-aware one** for the same media, so `reorder 25 %` met ~24× fewer events on the winner. **Before a comparative row is generalised, list what differed besides the thing under test** — the audit found one asymmetry where there were two.

**An impairment specified per packet is only comparable across lanes that carry the same media in
comparable packets. Normalise MTU and offloads on every arm, and report the measured packet-size
distribution beside any per-packet result.** *(T20, re-running T5's reordering cell.)*

T5's reordering cell disabled segmentation offload on the MoQ arm only (correct for `netem`, but asymmetric). Equalise MTU and offloads and segmented falls to 0.44 on TCP and 0.18 on HTTP/3 against 0.13 — separation was largely the rig's. Even normalised, QUIC arms send ~1.5× the packets for the same media, so "same shaper setting" is still not "same impairment"; say which.

**A client option naming a transport is a request, not a measurement; prove the substrate from the
server and the wire.** *(T20, HLS over HTTP/3.)*

FFmpeg does not propagate `http_version` to demuxer child connections — `-http_version 3only` fetches the playlist over HTTP/3 and segments over HTTP/1.1 with no warning. **The transport is established by the origin, not requested by the client** (H3 vhost with no TCP listener, ALPN log, capture counting UDP versus TCP).

**After #3793, dial-side and relay flags were renamed — detect, do not assume.** *(Post-#3793 rebuild,
T21/T27/T40.)*

[#3793](https://github.com/moq-dev/moq/pull/3793) rejects old names: `--client-connect` → `--connect`, `--client-tls-disable-verify` → `--connect-tls-insecure`, `--latency-max` → `--max-age`; relay `--server-bind` / `--tls-generate` → `--listen` / `--listen-tls-generate`; `--server-quic-gso` → `--quic-gso`. Compare builds with **each binary detected separately** — pre-#3793 subscriber against post-#3793 relay needs `--client-*` on one side and `--connect-*` on the other. Use [`moq-cli-flags.sh`](scripts/moq-cli-flags.sh); `ec2-swap-build.sh` migrates unit files when the binary exposes `--connect`.

**`--auth-public` inverted its meaning at the CLI migration, and the wrong value delivers nothing
without erroring anywhere.** *(T13 `3831-a`, P0-i, and both standing relays.)*

It takes a path glob, not a boolean; which glob grants the connection root changed. Measured loopback dialling `https://…/anon`:

| relay build | `--auth-public ""` | `--auth-public "**"` | `--auth-public "anon/**"` |
|---|---|---|---|
| `moq 0.9.15` (pre-migration surface) | **15.4 MB** | 0 | 0 |
| `moq 0.11.2-5d0991b9` | 0 | **13.3 MB** | 0 |
| `moq 0.11.2-615d166d` | 0 | **14.5 MB** | 0 |

Pre-migration `""` means everything public; post-migration `""` means nothing. `anon/**` serves nothing on any build because `/anon` is the connection root and the relay matches paths relative to it. **Failure is silent:** sessions accept, no bytes deliver, no error logged. Repointing standing relays with `""` carried across would serve nothing; hard-coded literals break build comparisons across the migration — `moq-cli-flags.sh` reads `RELAY_AUTH` from relay help. **Check the capture is non-empty before grading it.** Enforced via `moq_relay_public`, `moq_require_bytes`, and `check-rigs.sh` before a session.

### The default congestion controller changed to the one known to abort, and a rig that does not pin it cannot attribute anything

*(From the `84b34f54` build survey; [T8](test-8-srt-vs-moq.md), T13 `3831-a`, [T20](test-20-segmented-http3.md), [T28](test-28-failure-injection-matrix.md), [T31](test-31-congestion-capacity-ladders.md).)*

**Pin the controller on every relay, through `RELAY_CC_FLAG` rather than a literal**, and state it with the result. `--quic-congestion-control` takes `loss` (CUBIC) or `delay` (BBRv3) and **defaults to `delay`**, which [T8](test-8-srt-vs-moq.md) records aborting under high loss — the condition outage ladders create. The flag was `--server-quic-congestion-control` before the #3793 CLI migration; a rig that pinned the old name on a newer build stops pinning silently and reverts to the default, so a build comparison across the migration carries a **controller change as well as a code change**, attributed to neither.

From `fd4f5d82e` to `ffa5b81b` every backend resolves an unset controller through one `unwrap_or(Delay)`; unpinned cells ran **BBR** (v1 on quinn builds, v3 on noq). **Read the backend from the binary, not from the CLI generation** — post-migration flag names on `5d0991b9` still appear on a quinn build, so infer backend from `--*-backend` or the linked QUIC crate. #3811 deleted quinn: every figure from `615d166d` onward is noq regardless of the rig, and `--no-default-features --features quinn` now fails; say which backend a figure is on whenever it crosses #3811, and prefer file-domain evidence across that boundary. The iroh backend cannot turn GSO off and rejects explicit `false`, so `--quic-gso=false` only works when the build dropped iroh (as `ec2-build-main.sh` does).

**a MoQ impairment figure quoted without its controller is not a lane result**, and a figure taken before the rig pinned the controller cannot be assumed to have used the one its file implies. Re-check rather than infer. On loopback with a `netem` token bucket the controller can decide the headline (under reorder BBRv3 delivers **zero bytes in 60 s** where CUBIC delivers 55.2 s of media span; under a 5 s total outage BBRv3 reads 0.227 where CUBIC reads **0.961**). In the `netns`/`cake` rig, graded on content, it moves neither capacity rungs nor the 5 s outage beyond single-sample scatter.

### A receiver's per-fetch timeout is a measurement parameter, and on an impaired lane it can be the whole result

*(T28/T31 segmented lane; [T42](test-42-h3-receiver-fidelity.md).)*

`hls-verbatim-recv.py` refuses any segment that is not a whole number of 188-byte packets, which is right — a truncated fetch would grade as a wire fault. The refusal is triggered by the per-fetch timeout (`curl --max-time`, **per transfer**), which binds only where one segment's goodput falls below `segment bytes / timeout` (~2 Mb/s for ~3–3.7 MB segments at 15 s).

**Quote the timeout beside any impaired segmented cell, and use it as a test rather than a setting**: re-run the cell at a longer budget, and if the byte count moves the cell was measuring the instrument. At 25 % reorder the same cell read **4.0 % of control at 15 s and 25.4 % at 60 s**; the T20 loss-20 arm read nothing at 15 s and 0.131 at 60 s. Where goodput stays above the threshold the timeout is inert (0.8× shortfall and 10 % loss read identically at 15 and 60 s). The reorder cell also needed nginx's default 64k stream buffer (next rule): with buffer at 16m the 15 s budget matched the 60 s reading.

### An origin or a receiver can be the bottleneck at the rig's RTT, and loopback will never show it

*(T31 segmented ladder in the namespace rig; [T42](test-42-h3-receiver-fidelity.md).)*

At 100 ms RTT the unimpaired control fell behind the live window and 404'd — unrelated to the lane. nginx's `http3_stream_buffer_size` defaults to 64k (~4.6 Mb/s per stream at 100 ms), and the receiver spawned `curl` per cycle (new connection from slow start each batch). Raising the buffer fixed the first but not the second; one connection for the run fixed both.

**Before a lane's first impaired cell on a new rig, run its unimpaired control and check that the delivery machinery keeps up with margin**: fetch time against segment period, and bulk transfer through the path at each origin setting that could bind. A rig that changes RTT must re-establish that instrument and origin are not what is being measured. [`t31-origin-window.sh`](scripts/t31-origin-window.sh) checks the origin.

### A cleanup pattern keyed on a flag name stops matching when the flag is renamed

*(From the repo-wide rig audit.)*

Twenty `pkill -f "[m]oq-relay --server-bind $PORT"` patterns matched nothing once the relay used `--listen`; `pkill` exits non-zero when it matches nothing, and each pattern was `|| true`, so a stale relay held the port and the next cell failed to bind elsewhere with no link to the cause.

**Match a process on what will not be renamed** — the binary name and the address it was given — e.g. `[m]oq-relay.*127.0.0.1:$PORT`. A pattern that silently stops matching is worse than one that errors.

### One measured defect is not a diagnosis of a different symptom

*(Standing live-ingest chain.)*

A measured auth inversion was written up as why the chain served 0 bytes; applying the fix changed nothing. Three independent faults remained (auth value, publisher dialling localhost against the relay's Elastic IP certificate, empty multicast source). Only after all three were repaired did a subscriber recover 14.4 MB.

**A confirmed defect on the path is a candidate, not a cause, until the stages between it and the symptom are each observed.** Walk the chain stage by stage and count bytes at each boundary — source, ingest, group, publisher session, relay grant, subscriber.

**`systemctl is-active` is not evidence that a pipeline is running.** Units reported `active` while the SRT listener was idle and the publisher's connection loop had exited inside a surviving shell. Health checks on this chain must count bytes (`live-feed-status.sh`).

**A `#3493` re-soak that crosses a timestamp reset needs a build carrying the [#3798](https://github.com/moq-dev/moq/issues/3798) fix: `main` from `9d2a4f6e`, where the 24 h re-soak ran, and not homogeneous `5d0991b9` or `ffa5b81b`.** *(T21 `3493-check-2h`, `3493-loop-2h`.)*

Import aborts with *frame timestamp is below the live edge* at content join on `ts-continuous-source.py` (~600 s) and loop wrap on `tsp --infinite` (~665 s) — the same `TimestampRewind` without `reanchor()`. A #3493 slope confirmation needs [#3798](https://github.com/moq-dev/moq/issues/3798) or a single-pass window under one clip length; closure of #3798 by a plan-only PR did not clear `ffa5b81b` ([T21 § *The #3493 re-soak*](test-21-permanence-soak.md#the-3493-re-soak)).

### A P1/P2 pass is not a conformant transport stream

*([T44](test-44-tstd-grading.md).)*

Every "conformant wire" before T44 was TR 101 290 P1/P2. ISO/IEC 13818-1 defines conformant as T-STD decodable without overflow or underflow. The media-aware groomed wire passed P1/P2 for 300 s and a day while transport and decoder buffers overflowed throughout.

**Say "P1/P2-conformant" when that is what was graded, and grade the T-STD before saying "conformant".** Calibrate the model per PID; grade the source as control through a transparent transport on the same groomer. Where the groomer regenerates PCR, ask per short window (`ts-tstd.py --window`) rather than a whole-capture offset scan.

### A buffer-model pass says nothing about what is missing: count each PID's units against the source

*([T47](test-47-fixed-delay-export.md), `2dc542b4a`.)*

An export at 500 ms dropped every MP2, AC-3 and teletext unit yet passed `ts-tstd.py`, `compliance.py` and `pcrverify`; absent PIDs have no buffer to overflow. Pass criteria never read the export's drop log.

**Grade completeness alongside conformance: every PID the source carries is in the output, with its unit count against the source's over the same span.** Read the export's drop log. A conformance verdict without a completeness check is a verdict on the part that arrived.

### Grade a clock's rate by fitting PCR against the receiver's clock, not from a latency trend

*([T47](test-47-fixed-delay-export.md), `49efbc9a1`.)*

Presentation-latency trends between run thirds reported 290–370 ppm off; fitting wall-minus-STC against tap clock gave ~500 ppm (the steering limit). Medians of thirds dilute a steady rate; a 30 s window alone reads ±45–60 ppm on one host.

**Fit the PCR against the receiving clock (`ts-decode-latency.py`'s "PCR clock vs tap") over the longest span available, and compare egress with the source tap of the same run.** Grade 30 ppm on the whole-run fit. The slew limit (2.8 ppb/s) is below this instrument's reach; say so rather than quoting per-window change.

### A transparent control through an arrival-clocked groomer attributes the transport buffers, not the decoder buffers

*([T44](test-44-tstd-grading.md).)*

SRT and plain UDP through an arrival-clocked groomer pass transport buffers and fail every decoder buffer at every offset; stream-clocked grooming passes with the source's joint legal offset. The campaign FFmpeg-muxed test loop overflows its own AAC transport buffer on 80 % of packets.

**A whole-capture decoder-buffer result belongs to the groomer's clock mode as much as to the transport.** Use stream-clocked grooming or none for a whole-capture transparent control; quote arrival-clocked arms for transport buffers and short windows only. Grade a clip before using it as control.

### A rig that copies its config from a live checkout runs the checkout's schema against a pinned binary

*(T44.)*

[`t18-arm.sh`](scripts/t18-arm.sh) copies relay config from `~/moq-dev`'s demo tree unless `RELAY_TOML` is set — whichever branch was checked out, not the build under test. Loud failures included `[iroh]` on a build without iroh and `[listen] bind` vs checkout's `[server] listen`; ignored renamed keys would not be loud.

**A pinned binary takes its config from its own tree** (`git show <build>:demo/relay/localhost.toml`), passed explicitly. Strip sections for features the build lacks (`ffa5b81b`'s demo still carries `[iroh]`).

### An exporter that paces itself is graded with nothing re-clocking it, and on more than its CI's clip

*([T47](test-47-fixed-delay-export.md).)*

Fixed-delay export timing is part of what it claims; a groomer after the receiver would grade the groomer. CI's generated 720p clip peaks buffers at 1–2 %; the broadcast clip failed within seconds at every delay; broadcast CPB on generated video reproduced half the failure.

**Grade a self-pacing exporter through a forwarder that never re-clocks** ([`ts-rtp-forward.py`](scripts/ts-rtp-forward.py)). **Give it a fixture with a broadcast-sized CPB, and grade that fixture as a source before blaming the export.** Report T-STD and P2 separately where both are graded (export passed every T-STD buffer and failed PCR accuracy on nearly every PCR — converse of [*A P1/P2 pass is not a conformant transport stream*](#a-p1p2-pass-is-not-a-conformant-transport-stream)).

### `tsp -P until --seconds` counts wall time, not stream time

*(T47.)*

`until --seconds 75` without `--realtime` read a 700 MB file in seconds and never stopped.

**Cut by packets** (`-P until --packets N`, with N = seconds × rate / 1,504), and check the output's size before using it.

### A failing capture's PTS span is not a rate; replay the scheduler before theorising about it

*(T47.)*

Schedule-overrun captures showed 13–29 % less PTS than PCR; the cause was a join hole plus queued exit units, not a starving release stage. Frame-by-frame DTS compare and offline replay of the slot rule predicted the next two binary runs to 0.03 s.

**Measure a timeline against the source unit by unit, never by the spans of a truncated capture.** Port the scheduler to [`ts-schedule-replay.py`](scripts/ts-schedule-replay.py), validate against a capture, and predict an unrun before reporting a cause. Replay source timing as control: if source DTS fails too, the fault is policy, not timestamps.

### Count a PID's packets per interval, and size its PES against its buffer, before naming a cause

*(T47.)*

AC-3 overflow was attributed to back-to-back packets; captured bytes showed up to 38 AC-3 packets per 25 ms slot and PES carrying nine frames exceeding the decoder buffer.

**Before attributing a buffer overflow to packet spacing, count the PID's packets per scheduling interval on the captured bytes.** Before modelling decoder buffer per PES, compare PES size with the buffer: several access units mean deadlines and removal are per access unit.

### A parameter sweep whose runs do not share a join measures the join as well as the parameter

*([T45](test-45-live-tstd-remux.md).)*

At 550 ms failed worse than 500 ms because 1 % of video arrived ≥199.5 ms late vs a 25 ms band on neighbours — not a non-monotone parameter response. End-to-end latency across the sweep spread ~1 s that the parameter did not cause.

**In a sweep over a live lane, measure the lane in each run and report it beside the result.** Where a figure depends on absolute transit, runs without a shared join are not comparable. T-STD on the stream's own PCR compares across runs, but a lane excursion in one run still moves it.

### A corrected instrument owes a re-grade of every figure it produced, and a re-read of every argument built on one

*([T46](test-46-tstd-check-cross-validation.md), applied to T44, T45, T47.)*

Correcting `ts-tstd.py`: T46 verified no T44/T45 verdict moved, yet re-grading moved counts, margins, legal offset intervals ("exactly +0 ms" became [+0, +100]), and derived spreads. Saved JSON differed from reproduction lines in write-ups.

**When an instrument changes, re-grade every kept capture with the flags it was first graded with (read them from the saved output, not from the write-up), then re-read each sentence that uses a moved figure, including derived ranges and "exactly" claims.** "No verdict moved" is the start of the check, not the end of it. Label uncaptured figures as the old instrument's.

# Method notes

Every rule below was learned by getting something wrong in this campaign. They are collected here,
organised by theme rather than by experiment, because several of them bit more than once in different
rigs and that is the most useful thing about them — the per-experiment files record what happened,
this file records what to do about it.

Each rule names the experiment(s) where it was learned. Where a rule was violated more than once
after being written down, that is stated, because it is the strongest evidence that the rule is worth
having.

---

## 1. Controls

**A control with the mechanism removed is worth more than a second run of the same arm.** A second
run reproduces the artefact. *(T15, and independently T9.)*

> RIST Main initially measured 92.1 kB bursts every 73 ms with a tight distribution — a plausible
> jitter-buffer drain figure, and entirely the publisher's own release granularity. A plain-UDP
> control through the same chain returned the same numbers to within a millisecond. Without that
> control the rig's floor would have been published as a transport property.

**Where a stage's own throughput could be the limit, the control that removes the subject entirely is
not optional — a saturated instrument fails in the direction that looks like a finding.** *(T7,
segmented arm.)*

> One of four clips failed PCR repetition on the segmented lane, reproducibly, and the lane offered
> two plausible mechanisms for it: the groomer's adaptive cushion ceiling, and the segment arrival
> gap. Raising the ceiling and halving the segment duration each ruled one out without dislodging the
> conclusion, because both left the lane in place. Feeding the groomer a local file at the same output
> rate — no packager, no origin, no HTTP client, largest content gap 51 ms — produced a *worse* result
> than any run through the lane. The clip was measuring where the pacing stage saturates. Two controls
> that vary the subject cannot distinguish the subject from the instrument; only the one that deletes
> it can.

**Pinning a setting on one arm is half a control. The variable you know to be decisive is the one
most likely to be left defaulted on the arm where its knob has a different name.** *(T5 / T8.)*

> T5 pinned its media-aware arm's congestion controller to BBR precisely because T8 had shown the
> controller decides a loss result, and left its segmented arm on the system default — which is CUBIC,
> a fact that appears nowhere in a command line. The experiment then attributed the resulting
> difference to the data plane and published "the two lanes' weaknesses are disjoint". Completing the
> lane × controller matrix on the same rig showed the loss axis does not separate the lanes at all: at
> a matched controller both hold full rate, and under CUBIC both collapse. Only the reordering half of
> the original conclusion was a lane property. Where a knob exists in both arms under different names
> and different layers — `--*-quic-congestion-control` against `net.ipv4.tcp_congestion_control` —
> pin both and record both on the result line.

**A setting is a default for what happens next, not a fact about what is being measured — read it
back off the thing under test.** *(T8, segmented arm.)*

> A `sysctl` changes the controller for sockets opened after it. Confirming it needs the controller
> read back from the connections actually carrying the run, which on a segment-fetching lane means
> sampling repeatedly: each fetch is a short-lived connection, so a single snapshot lands between them
> and reports nothing — indistinguishable from the setting never having applied.

**Run the control before believing a striking result, not after.** *(T17.)*

> A round-trip against a proposed upstream fix captured zero bytes, which matched a predicted failure
> of the export gate closely enough to be believed. It was a renamed command-line flag whose
> deprecated alias warns and then does not take effect. The merge-base control behaved identically,
> which is what exposed the rig rather than the change under test.

**Grade beyond one full failure-detection interval, or the drill measures the timeout rather than the
mechanism.** *(T6.)*

> A failover drill killed the publisher at t+22 s and graded at t+43 s — 21 s into a 30 s QUIC idle
> timeout. No build could have passed it. The conclusion it produced was withdrawn.

**A positive control that cannot be subjected to the same injections as the arms is a gate on the
rig, not a comparison.** *(T12.)*

> Arm C grooms once and duplicates, so it has a single publisher, relay and exporter behind it:
> killing its publisher takes the whole arm down. That is the honest result rather than a rig
> failure, and it is the architectural finding in miniature — but it means arm C validates the
> receiver and the instrument, not the topology.

**A parameter fixed once in the method section and never varied is an uncontrolled variable, and it is
the first place to look when a result refuses to explain itself.** *(T8b C3.)*

> C3's headline was that adding a second media-aware feed *reduced* total delivered throughput — a
> utilisation defect with no mechanism, which survived the elimination of the congestion controller and
> then of bufferbloat. It was the subscriber's `--latency-max`, pinned at 2 s across every cell of the
> matrix because 2 s was the campaign's chosen operating point. Sweeping it 500 ms → 30 s moved the
> `n=2` aggregate 4.29 → 10.35 Mb/s, above the single-flow rate. The number was a fact about a
> configuration, and the configuration had been held constant so consistently that it had stopped being
> visible as a choice. *Before hunting a mechanism in the network, list every value the rig was told
> and vary the ones that were never in the matrix.*

---

## 2. Instruments, and reading what they tell you

**A check that has only ever returned "clean" has not been shown to work. Feed it something broken
before you publish the zeros.** *(T5, T6, T7, T8b, T18, T3 — one defect, six rigs.)*

> Six rigs counted continuity errors by grepping `tsp -P continuity` output for the word
> "discontinuity". The plugin prints
> `* continuity: packet index: 13,264, PID: 0x0079 (121), missing 14 packets`, and uses that word
> only in its `--help`. The count was therefore structurally zero on every input, and had been for
> the life of the campaign. Nothing looked wrong, because a conformance column of zeros on a healthy
> rig is exactly what a healthy rig should produce — the defect was invisible precisely where it was
> most load-bearing. It survived into a T7 pass criterion, a T5 headline ("loses time, never bytes"),
> a T6 observation built on the counter *not* firing, and a T18 sentence reading "zero on all
> nineteen cells". Re-grading the retained captures with a working matcher left T7 and the MoQ arms
> genuinely at zero and moved T18's segmented cell to 583 events and T6's dual-source cells to ~95.
> *The cost of the check is one deliberately corrupted file per instrument, once. The cost of skipping
> it is that every "0" the campaign published is worth exactly as much as the grep behind it —
> including the ones that happen to be right, because a correct answer from a broken instrument is
> still not a measurement.* Two corollaries worth keeping: prefer matching on the tool's **data**
> (`missing N packets`) over matching on a **word from its prose**, since the prose is not an
> interface; and where two instruments can be pointed at the same property, report both and treat
> disagreement as a finding.

**A counter that wraps detects an event and cannot size it. Never report its magnitude as the damage.**
*(T5.)*

> Past its availability window a segmented-HTTP client re-anchors to the live edge, skipping whole
> minutes of programme. The continuity counter fires — correctly, once per PID carrying the splice, so
> a single skip reads as 6–11 "events" — and then reports 33 missing packets for a hole of 34 segments,
> which is over 200,000. A continuity counter is four bits; it reports the remainder modulo 16 and has
> no way to say how many times it wrapped. The event count is the detector, the PCR interval is the
> measure, and the packet total is neither. The general form: whenever a counter's range is smaller than
> the fault it is watching for, it degrades from a measurement to an alarm, and the write-up has to
> demote it in the same breath as it reports it.

**Errors logged by a server are not an instrument for a client falling behind.** *(T5.)*

> The obvious signal for "the client fell out of the availability window" is the origin's 404 rate, and
> it works only in the narrow band where the client is slow enough to be overtaken but fast enough to
> still be asking for the segment that was just deleted. Deeper into loss it reloads the playlist first,
> finds the segment already gone from the list, and skips silently: the worst cell on the ladder lost
> 82 s of programme with an origin log of nothing but 200s. A failure detected at one end of a path
> because the other end complains is only detectable while the other end still knows to complain.

**An instrument that reports its own confidence has to be read.** *(T12.)*

> A merge oracle recovers the sequence offset between two legs by voting on payload identity. With
> one field differing on every datagram it had 15 votes out of 23,175 — confidence 0.19 — and picked
> an offset that, restated in time, read as twelve seconds of skew. Two hypotheses, two tool changes
> and three runs were spent on that artefact. The confidence figure was on the screen throughout.

**A derived quantity must be re-measured independently before it is explained.** *(T12.)*

> The same twelve seconds. Measuring arrival at equal sequence numbers — which needs no correlator —
> gave a median of 10.4 ms.

**An instrument that reports *completed* objects cannot be used to establish the absence of an object
designed never to complete.** *(T17.)*

> An EIT schedule sub-table declares a `last_section_number` spanning its whole range and transmits
> only the sections holding events, so it never completes and a section-completing analyser prints
> nothing. Reading that as absence produced a false finding about the fixture. Census sparse tables
> with `--all-sections`.

**A negative reachability result is evidence about the network only if the far end would have answered a
positive one. Read the failure mode, not the failure.** *(T4.)*

> `nc -z` reported nine TCP ports on the origin closed, which was written up as "the security group
> admits no inbound TCP but SSH" and made a whole data plane look blocked on a firewall change. Nothing
> was listening on any of those ports, so refusal was the expected answer either way: the probe measured
> the absence of a server, not the presence of a filter. The two cases are trivially separable and the
> probe threw the distinction away — **a filtered port drops the packet and times out (8 s here), an
> admitted port with no listener refuses immediately (17 ms once a listener was bound)**. Test with
> something listening, or characterise the silence before drawing a conclusion from it.

**An option whose units depend on a sibling flag will be misread eventually. Read the tool's echo of
the threshold, not the flag.** *(T16.)*

> `pcrverify --jitter-max` is microseconds by default and PCR ticks only under `--absolute`. A whole
> analysis was re-run against both readings before the tool's own printed conversion settled it.

**Report long intervals and discontinuities separately; a metric that conflates two faults hides
both.** *(T12.)*

> Counting PCR intervals above 100 ms together with *negative* intervals reported sixteen "jumps" in
> a clean control, implying switch damage where there was none. Split apart, that arm has zero
> backward steps anywhere and a different arm has seven.

**Grade a pacing stage with a packet-conservation column beside the timing ones.** *(T16, and T13
independently.)*

> A configuration reachable by flag posts the best PCR record and the flattest wire of any arm
> measured, over a stream carrying 231 continuity errors. Every measure of *when* bytes leave was
> satisfied; the failure is visible only in measures of *which* bytes left.

**A harness that omits a row when its instrument returns nothing cannot distinguish zero from
unmeasured. Make it fail on an empty series.** *(T3, and it is the same TSDuck trap as the
`--jitter-max` rule above: the behaviour depends on a sibling flag, not on the value passed.)*

> `pcrextract --csv` writes its series to TSDuck's *report* stream — stderr — unless given `-o`. An
> analyser reading stdout received nothing, the interval computation returned nothing, and a
> truthiness test skipped the rows: three complete-looking transparency tables were produced with the
> PCR interval and >40 ms rows simply absent. The omission was detectable only by checking the output
> against the columns it was supposed to have.

**Score what a stage *added*, not only what survived.** *(T3.)*

> A transparency census is shaped as a loss detector: it lists what the source carried and looks for
> it at egress. Nothing in that shape can see 46 packets that were never in the source — and on the
> segmented-HTTP lane those 46 packets are the entire deviation, moving PCR accuracy by four orders of
> magnitude while every survival row reads clean. Any stage that re-heads, re-indexes or re-stamps a
> mux needs an addition column.

**Two gates that both claim to measure "PCR conformance" can disagree by four orders of magnitude, so
name which one a result is quoted against.** *(T3.)*

> Inserting packets into a mux does not change PCR *values*, so the P1 repetition interval is
> untouched — 0 % above 40 ms. It does change the byte positions those values arrive at, which is
> what P2 accuracy compares them against: 37 ns → 302 µs. A rig running one gate would have reported
> the same lane as perfect or as broken depending on which.

**A gate that presupposes a property of the stream cannot compare streams that differ in whether they
have it — and it will return a plausible number rather than refuse.** *(T3.)*

> `pcrverify --absolute` compares PCR values against the byte positions they arrive at, which assumes
> a byte clock. A media-aware MoQ egress, ungroomed, carries no stuffing and so has no mux rate —
> `analyze` puts its "bitrate" at 22–32 **Gb/s** on 10–27 Mb/s content. Graded anyway, the gate
> returned **exactly the maximum PCR interval**: 159.995 against 160.000 ms, 39.9886 against
> 39.9889 ms, 319.931 against 319.933 ms — three clips, maxima 8× apart, agreeing to 0.003 %. Quoting
> that beside a lane where the gate *is* defined would have compared a PCR interval with a PCR error,
> three orders of magnitude apart, under one column heading. Before booking an unfilled cell as a cheap
> gap, check the instrument is defined on the thing being compared.

**Vary the parameter the mechanism says is irrelevant; that is the test the mechanism can fail.**
*(T3.)*

> One PAT/PMT pair per segment displaces later PCRs by the pair's own transmit time, so the error's
> *size* should not depend on segment duration while its *frequency* should scale as 1/duration.
> Sweeping 1 s / 2 s / 6 s moved the injection count 5.7× and the maximum error by 1 % (299.6, 301.9,
> 302.4 µs). A cumulative error would have grown with segment count. Confirming a mechanism by
> re-measuring what it predicts *changes* is weaker than confirming what it predicts stays still.

**A commanded buffer depth is not the depth in force. A pacer whose output rate exceeds the content rate
arriving at it burns its cushion off, and its own status line will not say so.** *(T18.)*

> `mpegts-pacer` logs `holding 2000 ms` while underrunning 18,070 times, and the measured standing depth
> was 90 ms. The surplus is the whole mechanism: a carrier commanded at 10 Mb/s against a null-stripping
> lane delivering ~9.68 Mb/s of content is a 3.2 % surplus, and the same lane reads 87 ms or 824 ms of
> latency at the same commanded cushion depending only on the carrier rate. Byte-transparent arms carry
> their mux's own stuffing and so ran at a 0.55 % surplus, six times less — an asymmetry that looked like
> a transport difference. Quote a cushion with its surplus, and match a null-stripping lane's carrier to
> content rate rather than to the original mux rate.

**A fix acts in one domain. Test it in that domain, or the instrument will confidently answer a
different question.** *(T19.)*

> #2967 changed PCR *values* and #3006 changed the *time* the bytes are released. The campaign's rig
> captured the export to a file and measured where the PCR packets sat among the bytes — the right
> instrument for #2967's successor question and the wrong one for #3006, because writing to a file
> flattens precisely the timing the fix creates. Run against #3006 it showed the positional bunching
> unchanged, which reads as "the fix did nothing" and is in fact "this measurement cannot see the fix".
> Grading it needed a different instrument altogether: read the export live off a pipe and timestamp
> each PCR packet as it arrives, at which point the fix is plainly there — the on-grid share doubles and
> gate failures halve. Three domains were in play at once here (value, byte position, arrival time), all
> three called "PCR spacing", and a result in one is not a result in another. *Before measuring a fix,
> say which of those the change acts on and check the rig observes it; a rig inherited from the previous
> question is the likeliest way to get a confident null.*

**Grade a stream against the values it asserts about itself, not against a nominal you supply.**
*(T19.)*

> The arrival oracle compared PCR inter-arrival against a nominal 25 ms, which works only because #2967
> happens to emit a 25 ms grid: it needs the grid's period supplied from outside, it is silent about a
> clock running at the wrong rate, and it cannot say whether a given PCR arrived when *it* said it would.
> Rewritten to compare each interval against the difference between the two PCR *values*
> ([`ts-pcr-timing.py`](scripts/ts-pcr-timing.py)), the same reader needs no reference clock, no source
> file and no declared mux rate, and it becomes valid for any exporter at any cadence. It also yields a
> statistic the nominal version could not: the *sign* of the error. *A self-referential test is both
> more portable and more sensitive than one that needs a reference, whenever the stream carries a
> statement about its own timing.*

**The sign of a timing error tells you whether you are measuring the writer or the reader.** *(T19.)*

> A Python reader on a shared box cannot distinguish its own scheduling delay from a late write, and
> that was offered as the ceiling on a 7.45 % figure for a whole session. It need not have been: a
> preempted reader lengthens one interval and shortens the next, so it produces late and early errors in
> balance, while a writer flushing a backlog produces early ones only. The measured ratio was 626 early
> to 136 late. *Before attributing jitter to the instrument, check whether the instrument's failure mode
> is even the right shape; an asymmetry rules it out without needing a better host.*

**Two invariants failing at once are one defect until you have checked they fail on different
things.** *(T19.)*

> Post-#3006 the exporter failed a release-timing check on 42 % of intervals and a byte-position check on
> 56 % of packets, and these were carried as two findings with two possible causes. Cross-tabulating the
> two per interval — one extra counter over data already in hand — showed 615 of the 626 early releases
> were exactly the byte-adjacent packets and that none of the 136 late ones were, which collapses two
> symptoms into one mechanism and pointed straight at the line of code responsible. *When a run reports
> two failures over the same population, join them before you report them; the cross-tab is usually
> free and it is the difference between two hypotheses and one cause.*

**Half the defects in a conformance instrument are it failing conforming input, and only a legal
fixture finds those. Build the stimulus for every condition the standard permits, not just the ones
it forbids.** *(T19, `ts-pcr-timing.py` — eight defects, five of them this shape.)*

> Of the defects review and fixture-building found in the PCR analyser, five were the tool rejecting
> streams ISO 13818-1 explicitly allows: a legal duplicate packet (2.4.3.3), a signalled
> `discontinuity_indicator` counter jump, the clock jump the same flag licenses (2.4.3.4), a PCR
> repeating its value in a duplicate, and a capture crossing the 33-bit rollover. Every one would have
> been reported as a defect *in the stream*, on a hard check, by an instrument whose own tests were all
> of the form "does it catch a break". The asymmetry is structural: a suite built from defects only ever
> exercises the reject path, so the accept path is whatever the implementation happens to do. **The
> pass expectations are the ones worth writing first**, because a false positive costs a soak its
> credibility while a false negative merely costs it a finding.

**An instrument's "not measured" and its "passed" must never be the same exit code. A producer that
died is the case the gate exists for.** *(T19, `check_release` — found by a reviewer, not by us.)*

> `check_release` returned a *hard pass* labelled "not measured (no arrival stamps)" whenever it had
> fewer than three timestamped PCRs. For a file that is correct: a file carries no arrival times and
> there is nothing to grade. For a live capture it inverted the instrument, because a producer that
> emitted two packets and exited produced a green run — and the exporter under test exits early on
> nearly every run of this rig, so the route was live rather than theoretical. The fix is a floor on
> both the sample count and the share of the requested window it spans. The general rule is that
> *absence of evidence has to be its own verdict*, distinct from pass and from fail, and reachable only
> in the domain where it is true.

**A fixture must break exactly one thing, and a generator emitting legal streams gets its own
bookkeeping wrong silently. Verify the stimulus arrived before trusting the verdict.**
*(T19, `ts-pcr-fixtures.py`.)*

> The first draft of the PCR spacing and position fixtures both reported continuity errors, because
> counters were computed per fixture instead of maintained across the packets each emitted. Those
> fixtures were about intervals and byte positions; the counter noise was the generator's. A self-test
> asserting on a polluted signal proves nothing, so counters are now maintained by construction and a
> counter failure means the fixture intended one. Worse, the loss fixture *hid its own stimulus*:
> excising exactly 15 packets left the counter landing on the value it would have had anyway, so the
> loss was invisible to the check meant to catch it. **A loss of an exact multiple of 16 packets on a
> PID is undetectable by continuity counter** — a property of MPEG-TS worth knowing rather than a bug,
> and the reason holes are sized from the clock instead. Each fixture now asserts a detail field
> proving its condition was reached, not merely that some check moved.

**Where an instrument's behaviour is a choice rather than a requirement, the test has to say which.
"It passes its tests" and "it implements the standard" are different claims.** *(T12, the ST 2022-7
selection oracle.)*

> Every 1+1 result rests on `t12-merge-oracle.py`, which had no unit test, so its documented behaviour
> and the standard's requirements were indistinguishable in the record. Labelling fourteen adversarial
> conditions separated them: eight where it does what ST 2022-7 requires, one where the input already
> violates a precondition of the standard so *nothing* is required and always taking leg A is a
> reproducibility choice, three where the rule cannot reach a sequence-number selector at all (PCR
> wrap, source-clock offset, and offset voting which is this implementation's own invention), and one
> outright blind spot. The blind spot is the return on the exercise: an intra-leg duplicate whose
> payload *differs* is silently resolved first-wins and moves no figure the oracle reports, so a leg
> renumbering onto a live sequence number would have looked clean in every published column. **Self-
> authored tests establish that an implementation is stable and self-consistent, never that it
> conforms**; conformance is decided by the thing the standard is written for, which here is a
> receiver, and that gate stays open.

---

## 3. Ratios, windows and intervals

**A ratio between two captures is only valid when both windows cover the same media. The durable fix
is not to measure the interval more carefully but to construct the ratio so that no interval appears
in it.** *(T9, then T14, then T16 — the same error, three rigs, three times.)*

> A receiver that drains a live window faster than real time before settling carries more media in
> 58 s of wall clock than a steady arm does in 60 s. Dividing one stage's bytes by another stage's
> span put a delivered rate 4.7 % above a CBR source and made an overhead figure come out
> *negative*. The fix that held was to form the ratio from two byte totals over the same media —
> everything sent, over the payload sent — with no wall clock in it at all.

**The span a capture measures for itself is only the flow's duration if the flow is continuous. On a
bursty lane, first-to-last-packet is short and every rate divided by it is high.** *(T9 segmented —
the same family as the rule above, arrived at from the opposite direction.)*

> First-to-last-packet was adopted precisely *because* nominal windows were untrustworthy, and it is
> right for a lane that sends without pause. A segment fetcher pauses: its first and last packets sit
> inside the capture window rather than at its edges, so the span came out 4 % under the real flow
> duration and the carriage figure read 1.081x instead of 1.036x — the difference between "materially
> worse than SRT" and "tied with it". Two runs whose byte totals agreed to five significant figures
> disagreed by 2 % on rate, which is the tell: when the numerator repeats and the quotient does not,
> the denominator is the defect. The span-free ratio, wire bytes over payload bytes, was identical
> across both runs.

**Equal window length is not equal media. When two captures are compared packet for packet, assert
the reference's homogeneity in the instrument rather than assuming it.** *(T3 — the content form of
the artefact above, and the fourth rig to hit that artefact in some form.)*

> Both windows held exactly 398,936 packets and were still not comparable: `testloop_clean` carries
> 18.43 % stuffing over its first 60 s against 13.1–13.8 % later on, so a head cut against a
> live-edge egress reported stuffing falling 18.43 → 14.95 % and video rising by 13,858 packets. That
> reads precisely like a lane stripping padding. Offsetting the reference to the media the receiver
> joined brought the same comparison to 14.83 → 14.95 %. The assertion belongs in the instrument
> because the failure produces a plausible number rather than an error — the analyser now reports the
> reference's stuffing by quarter and declares a non-homogeneous window.

**An extremum carries its window. A "max error" over more media can only grow, so two such figures are
comparable only over equal windows.** *(T3.)*

> `CNNiEMEA`'s source PCR accuracy is 37 ns over the 60 s reference cut and 74 ns over the whole
> 5-minute clip. Both are right. The equal-window rule is usually invoked for rates and ratios, but it
> binds at least as tightly on every "tightest clean bound", "max jitter" and "peak" in this
> repository, because those statistics have no averaging to dilute a single outlier.

**A mismatched-window extremum does not only mislead — it can manufacture a false *agreement*, which
survives review because agreement invites no scrutiny. Prefer a distribution to a maximum, and confirm
"preserved" against the source in the same window.** *(T4, sharpening the rule above.)*

> A media-aware egress was reported at "max 319.98 ms" beside "the source's own 319.98 ms" and the lane
> was credited with transporting the encoder's cadence. The source's maximum PCR interval is 24.95 ms in
> every span of the clip and across all 600 s of it; the egress figure came from the lane. Two extrema
> taken over different windows had produced a matching pair, and a matching pair reads as proof. The
> distribution refuted it immediately and unambiguously: 1,123 of 1,307 intervals under 1 ms is not
> something any conformant mux can produce, so **the 0.01 ms minimum was the tell, not the 320 ms tail**.

**A metric can be preserved in the mean and destroyed in the distribution. For anything whose value is
its regularity — PCR spacing, PSI cadence, packet interval — a mean is not evidence of preservation.**
*(T4.)*

> The same egress conserved its mean PCR interval to within 0.7 ms of the source (23.81 against
> 24.47 ms) while clustering 86 % of its PCRs sub-millisecond and collecting the residual into 320 ms
> gaps. Mean, monotonicity and total span were all preserved; the only property that mattered — even
> spacing — was gone.

**Fix a numeric budget before taking the measurement, or there is nothing to read the result
against.** *(T9.)*

> Per-hop wire overhead was measured with no budget agreed in advance. A rig error inside it went
> unnoticed for exactly that reason: there was nothing the number could contradict. The budget was
> derived from the protocol afterwards, which is the wrong way round.

**A measurement window shorter than the phenomenon's own timescale reads as a different phenomenon.**
*(T9.)*

> Relay memory grows per ingested group until every stream slot is occupied, which takes about three
> hours at the rate tested. Every leg was shorter than that, so an hourly slope extrapolated to a
> daily figure read as unbounded growth and was reported as failing a stability criterion. It
> plateaus.

**A per-something cost has to name the something, and the rig has to hold it at one.** *(T8b C6,
refining the rule above.)*

> The plateau was registered in advance as "baseline + ~99 MB per publisher connection". A 14 h soak
> converged on 2.03× that. The fan-out legs could not have caught it: they varied the subscriber count
> but ran far shorter than the knee, so they measured the ramp and not the ceiling, and nothing had ever
> run long enough to show that the ceiling was double the derivation. **Varying a quantity over a window
> shorter than the phenomenon measures the derivative, not the asymptote** — and a pre-registered
> prediction that omits which quantity it scales in cannot be falsified cleanly by either.

**Before adopting the tidy explanation a new number suggests, test it against the measurements already
in hand.** *(T8b C6.)*

> The soak carried one publisher and one subscriber, and 2.03× a *per-publisher* ceiling on *two
> connections* is exactly what a per-connection cost would produce. That reading was written up as the
> leading hypothesis and it was wrong: the campaign's own earlier fan-out work had already measured the
> growth rate flat across 0, 1, 2 and 4 subscribers, and a four-subscriber leg — five connections —
> reaching the same range as two. Nothing new had to be run to rule it out, only re-read. **A coincidence
> of ratios is not a mechanism**, and the cost of the error would have been an upstream report claiming
> audience scaling against evidence we had published ourselves.

**Set a soak's duration from the longest period in the system, not from a round number.** *(Gate 2 rig
design, applying the rule above before the run rather than after it.)*

> The PCR field's 33-bit base runs at 90 kHz, so it wraps every 2³³/90,000 s = 95,443.7 s = **26.51 h**.
> The hardware soak has been specified throughout as "≥ 24 h, ideally 72 h" — and 24 h spans 0.91 of a
> wrap period, so a conforming run of the stated minimum can contain no wrap at all and still be
> reported as having soaked. The wrap is precisely the slow-clock event the soak exists to find. 72 h is
> therefore not a preference but the shortest duration that guarantees two. The same reasoning says the
> wrap should not be waited for at all where it can be *placed*: start the PCR just below the boundary
> and the event arrives in minutes, which is a fixture rather than a soak.

**Register the shape as well as the number, or a converging curve and a leak grade the same.** *(T8b
C6.)*

> The criterion asked whether the slope *broke* at a predicted knee. What happened was neither: the
> slope decayed monotonically by 13× and had not converged at 14 h. Stating only a ceiling made a smooth
> approach to twice that ceiling unclassifiable, when "asymptotic, still rising, at 2× the prediction"
> is the informative answer. Add a reclaim or pressure counter beside any long RSS series, too, or a
> decaying slope cannot be told from the kernel taking pages back.

**A bound on an accumulating quantity has to come from the thing that is allowed to accumulate it.
Pick the number and the check grades the number.** *(T19 measurement 9, grading #3351.)*

> A hard bound on accumulated PCR release drift was added with a 250 ms default, chosen because it
> looked small. A sender that buffers is *entitled* to build a standing lag up to its own latency
> budget, which defaults to 500 ms, so the check failed a correct pipeline three runs out of three
> while its per-interval error sat at a p95 of 1.7 ms. *An accumulating quantity almost always has an
> owner with a declared allowance — a buffer, a budget, a window — and that allowance is the bound;
> anything else measures the instrument's taste.*
>
> Two shapes were also being conflated under one name. A lag that settles and a pipe running slow both
> present as accumulated drift, and only the second is a defect. Separating them needs the *rate* over
> the tail of the sample rather than the total, and a sample longer than the lag takes to build: the
> same pipeline reads 290 ms of drift still climbing at 8.7 ms/s over a 20 s window, and 480 ms holding
> at −0.017 ms/s over 120 s. *A window shorter than the transient cannot distinguish the transient from
> the steady state, and will report the transient as the steady state with no indication that it has.*

---

## 4. Attribution: naming a mechanism from the evidence

**A comparison at fixed positions cannot tell reordering from corruption. Compare the two as
multisets before concluding the content differs.** *(T12 arm D, independent upstream.)*

> The full-mux cell read 24.28 % residue against a slot-by-slot oracle, which invites the conclusion
> that a quarter of the stream was wrong. It was not: 99.9528 % of packets were common to both legs as
> a multiset, every media PID carried an identical packet count, and an edit-script alignment matched
> 98.414 % once displacement was allowed. One displaced packet de-phases every comparison after it, so
> a positional metric reports the *consequence* at full size and says nothing about the cause. The
> three views answer different questions and the cheap ones come first: the multiset says whether the
> same bytes are present, the alignment says how far they moved, and only then does the positional
> figure mean anything. Without them the finding would have been filed as damage rather than as
> ordering, and the upstream report would have been wrong.

**On a lane whose transport holds no session state, most of what you are about to measure lives in
the client — so measure two of them before naming the lane.** *(T8b, T6.)*

> Under a 2:1 shortfall, segmented HTTP either lost the session at 43 s or thinned cleanly at 99 % of
> the bottleneck, depending only on whether the receiver re-anchored after a 404. Same origin, same
> shaper, same clip, same window; a factor of three in delivered rate and the difference between a
> live feed and a dead one. The first client's number, written up alone, would have read as
> "segment fetching cannot survive congestion" — a claim about HTTP that the second client falsifies
> in one run. Where MoQ's transport supplies the thinning, this lane requires the receiver to
> implement it, so a figure attributed to "segmented HTTP" is very often a figure about one client's
> error handling. T6 reached the same conclusion for failover.

**When two runs differ in more than one variable, do not credit the one you have been tuning.**
*(T13, T18.)*

> T16 reached 0 PCR intervals above 40 ms on the wire while carrying seconds of cushion, where T13's
> MoQ legs posted 131–159 at about 1 s. Cushion was the variable under active investigation, so it got
> the credit, and T13 recorded the failure as "a buffer-depth choice rather than a limit". It was not:
> T18 swept the MoQ cushion eightfold with no movement at all, and T13's segmented pass-through leg
> posts 0 while holding almost no buffer. The two runs had differed in the *data plane* as well, and
> that was the whole effect — one egress delivers PCRs on a grid and the other clusters them. *The
> variable you are holding in mind is the one most likely to be miscredited.*

**Name a divergence mechanism from the bytes that differ, not from the most plausible cause.**
*(T12.)*

> "Two groomers will agree on content and differ only in the PCR bytes each stamped" was plausible,
> standing, and wrong: of 400 sampled conflicting datagrams, **none** differed only in PCR, 39.5 %
> disagreed on PID order and 28.2 % carried a different number of nulls. The fix implied by the wrong
> mechanism — ignore PCR at the receiver — would not have worked.

**A mechanism read from the source is a hypothesis; and before reporting a null, work out whether the
arm could have shown the effect.** *(T12.)*

> Reading the exporter, each SI table's snapshot advances as that leg's own subscription delivers
> groups — so two legs looked able to assert different clocks at the same slot, and that was put to
> upstream as a likely 1+1 divergence source. It is wrong: the code says which *state* the emission
> consults, not what advances it, and the state turns out to track the media position. The first arm
> that "confirmed" agreement was worth almost nothing either — a 15 s clock and 870 ms of lag predicts
> 0.6 differing emissions in ten, so observing zero is consistent with both answers. Only after the
> clock was driven at its resolution limit, where the same lag predicts seven in ten, did zero mean
> anything. Compute the effect the arm should see before running it, or a null is just a quiet arm.

**Compare with the suspect field masked before attributing a conflict.** *(T12.)*

> "The payloads differ" is a measurement. "The groomer diverged" is a conclusion. Here they came
> apart: 97–98 % of conflicting datagrams differed in one field minted upstream of both groomers.

**Before recording that a stage preserves a property, check whether another experiment already found
that it does not. A contradiction between two files is worth more than a re-measurement, because one of
them is already wrong and is being cited.** *(T4.)*

> T4 credited the media-aware lane with transporting the encoder's PCR cadence. T2 had already tabulated
> the same clip's same figures under the heading "impairments introduced by the lane", with a source
> column at 20–28 ms against the egress's 319.9 ms, and T8's table showed the same split from the SRT
> side. The evidence was never missing; it was contradicted, and the wrong file was the one the paper
> drew on. A campaign accumulating results across many files needs cross-file contradiction treated as a
> first-class defect, because nothing else in the process will surface it.

**When a processing stage and its source could each explain a placement defect, the stage's own
insertion counter decides it — not the arithmetic that fits.** *(T18.)*

> The groomer's PCR repetition failures on the media-aware lane were attributed to starvation, and the
> arithmetic was persuasive: `underruns` equalled the nulls inserted exactly, and the commanded carrier
> exceeded the lane's content rate by the same 3.2 %. Matching the carrier to content rate cut underruns
> from 18,070 to 5 and left repetition at 502 violations, unchanged. A defect that survives the removal of
> its supposed cause belongs to the other stage.

**A counter reading zero in the one configuration where the thing it counts is impossible is evidence
about that configuration and nothing else. Vary the condition that enables the mechanism, and check the
counter moves, before quoting it.** *(T18.)*

> The attribution above was then published on the strength of `pcr_inserted=0` — read from the cell at
> **0.0 % stuffing**. That groomer places a PCR only into a slot it was already going to stuff, so at zero
> stuffing it has no slots and the counter cannot read anything else. A structural zero was quoted as a
> measured one, in five documents and an upstream issue. Read across the whole ladder the counter varies
> as designed — 137, 103, 28, 0 insertions at 4.1 %, 3.2 %, 0.8 %, 0.0 % stuffing — while the violation
> count holds at 491, 489, 503, 502. The conclusion was right and its evidence was the wrong shape: four
> insertion rates producing one result is a far stronger argument than no insertions at all, and it was
> already sitting in the run logs.

**A threshold-crossing count summarises a distribution and can point at the opposite of its cause. Before
asking anyone to change a rate, plot the interval distribution and check the mean is actually deficient.**
*(T18.)*

> "Intervals above 40 ms" was the campaign's only PCR conformance instrument for a long time, and 375–414
> of them per window read naturally as *too few PCRs*. It became the shorthand "the exporter emits PCRs
> too rarely" in five documents. The distribution says the opposite: 31–36 PCRs a second against the
> source's 41 and against the ~25/s the gate needs, with a median interval of **11 µs**, 85 % of intervals
> under 1 ms, and every violation inside a 100 ms–1.8 s hole between bursts. Density was never the
> deficiency and a denser cadence would have changed nothing. Loss and clustering are also
> indistinguishable in the count and obvious in the distribution — a lossy SRT lane posts 538 crossings
> with its median still at 24.8 ms and 0.0 % under 1 ms.

**Keep a byte-transparent control in any rig that measures a conversion, carrying the same source in the
same session.** *(T18, via T8b.)*

> The defect above went eighteen months mis-summarised because the exporter was only ever measured through
> a groomer and against a source profiled in a different session. What settled it was an unrelated
> congestion rig that happened to write `moq export ts` straight to a file *and* carry the identical clip
> on the same PID over SRT and two segmented clients — so "the source is conformant, the count survives,
> the spacing does not" was readable three ways off one session. The control cost nothing; it was already
> in the matrix for another reason.

**A precise upstream report can be undone by an imprecise in-house paraphrase, and the paraphrase is what
gets cited.** *(T18.)*

> The filed issue said "it is not sparsity", gave the mean conserved to 0.7 ms, and asked for a bounded
> *interval*. Every one of those is correct. The summaries written from it said "emits PCRs too rarely"
> and "a denser cadence would clear the gate", and those propagated into four `docs/` files, the top-level
> README and two other experiments — the versions a reader would actually act on. When restating a
> finding in shorter form, restate the *mechanism*, not the symptom that made it visible.

**A cleanup job must never run against a live results tree.** *(T8b.)*

> A 68-cell matrix was writing a ~140 MB capture per cell onto a host with 3.3 GB free, so a janitor was
> armed to delete captures older than three minutes. It protected the disk and destroyed the matrix's
> most valuable data: C3 sums the outputs of *all* N receivers, and four of its six cells had their
> second and third captures deleted before anyone summed them, leaving per-flow shares that cannot
> distinguish "the flows shared unfairly" from "the flows collectively under-used the link". The two
> cells that survived showed 25 % aggregate utilisation against SRT's 84 % — the single most consequential
> number in the matrix, saved only by finishing last. **A janitor must be told what the analysis needs,
> not just what is being written now; and a condition whose result is a sum over several files is the
> case it will silently ruin.** Deriving the summary before deleting the input would also have caught it.

**An unattributed residue is not a finding.** *(T12.)*

> "What remains is a continuity counter" was written over a measurement that already said otherwise —
> 2.90 % of datagrams still differed after masking the counter. The comparison reported only a
> percentage. Breaking the residue down by PID named the second defect in one line.

**Distinguish a stage that *normalises* a difference from one that merely gives two streams a common
frame of reference.** *(T12.)*

> Only the first bounds what a downstream measurement can see. Grooming by stream position is what
> makes two legs comparable at all, and it carries a displaced table faithfully rather than absorbing
> it.

**When a comparison ranks transports by a property of their output, measure the input as well.**
*(T15.)*

> Otherwise a transport that merely passes its input through is credited with its source's virtues,
> and a claim about an encoder is filed as a claim about a protocol.

**When an argument says two measurements should converge, check whether the mechanism it proposes
would cost something elsewhere in the same comparison.** *(T14.)*

> "A TS packager has no reason to retain stuffing either, so the wire figures will converge." The
> packager does retain it — and one that stripped it would stop producing byte-verbatim segments and
> forfeit the fidelity advantage that was the other half of the same comparison. A saving reasoned
> about in isolation is usually a trade seen from one side.

**A hypothesis that predicts a *gradient* is cheap to falsify: run the extreme first.** *(T12.)*

> "The carrier has too little slack for a backlog to drain, so a higher mux rate will let a returning
> leg converge." Doubling the rate changed the cell by nothing measurable. Two runs cost less than
> the reasoning that preferred them.

**Predict the deviation's magnitude from the mechanism before measuring it, and confirm it by spreading
the variable the mechanism scales with.** *(T3.)*

> A PAT and a PMT are 376 bytes, so injecting them at a segment head should displace every later PCR
> by the time 376 bytes take to transmit — 300.8, 109.4 and 302.4 µs on three clips spanning 2.75× in
> bitrate. Measured: 297.7, 109.4 and 301.9. The prediction is what made the number attributable; the
> bitrate spread is what made the agreement evidence, because a wrong mechanism would not track
> 1/bitrate. The same maxima arriving unpredicted would have been filed as "sub-millisecond PCR error
> at segment boundaries" and left there.

**Run the falsification test even once you have stopped believing the prediction — a caveat retired by
measurement eliminates a class of cause, and a caveat retired by argument eliminates nothing.**
*(T8b C3/C4.)*

> C4 predicted an AQM would remove C3's collapse. By the time the cells were run the prediction was
> already doubted on other grounds, so the six-cell run looked like confirming what was known. It was
> worth 12 minutes: `cake` cut RTT from ~550 ms to 100 ms, which proves the AQM did its job, and the
> collapse survived at 48 % of cap. Bufferbloat is now *excluded* rather than *thought unlikely*, and
> that is what left the latency budget as the only candidate standing. An unrun counterfactual stays in
> the limits section forever and keeps every downstream conclusion provisional.

**When a stage reports a bad input, ask whether the stage's own contract was ever written down.**
*(T19, `mpegts-pacer`.)*

> The groomer shed 45.9 % of the exporter's content and this was filed as a property of the lane. It was
> also a defect in the groomer: it read one PCR interval as both a duration and a length, which is an
> assumption about the source that no source is obliged to satisfy. On a fixture with a *perfect* value
> grid and clustered positions it exited **zero** having discarded 67.2 % of the programme and added 106
> discontinuities of its own. *An assumption that has always held is indistinguishable from an invariant
> until the day it does not — and the failure it produces then is a success exit code.* The fix is to
> make the assumption a measured quantity compared against something the configuration already
> specifies, not to add a threshold.

---

## 5. Rig hygiene

**Before grading two pipelines for determinism, hash every artefact they are supposed to share.**
*(T12 arm D, independent upstream.)*

> The independent-upstream arm gives each host its own copy of the source, its own `moq`, its own
> relay and its own groomer. Every one of those is a way for the arm to grade the artefacts instead of
> the pipeline: a source file that differs by a byte, or a groomer copied before the last rebuild,
> produces a divergence indistinguishable from the one the experiment exists to look for. Four
> checksums taken up front cost seconds and convert a negative result from arguable to conclusive.
> The secondary's groomer is a *copy* and nothing on that host reports it stale, which is exactly the
> case the check catches.

**An instrument that reads zero has not measured zero until it has been shown reading non-zero.**
*(T12 arm D.)*

> `t12-dual-host.sh` reported 0.0 % leg CPU through a whole live run, because `ps -o %cpu -p` reads
> the wrapper shell. The repair, reading the process group with `-g`, was written, reviewed and
> deployed, and it *also* returned 0.0 %: neither `-g` nor `--pgid` selects by process group id on
> procps-ng 4.0.4. Two sampler generations reported the same plausible-looking figure and neither had
> measured anything. A rig that reports a resource figure should be run once against a known load
> before its nulls are believed.

**Every statistic the experiment intends to report must be an output the cell prints. A number
recovered afterwards from files that happened to survive is not a measurement, it is a salvage.**
*(T8b C3.)*

> C3's whole point was the *aggregate* over N concurrent flows — the per-flow share falling below the
> fair 1/N is expected under contention, and only the sum says whether the link was used. The cell
> subscribed the extra flows correctly and wrote each to `out.$i.ts`, but graded and printed only flow
> one; the aggregate was obtained afterwards by stat-ing whatever captures were still on disk. When a
> janitor armed mid-matrix deleted captures to protect the disk, it destroyed four of the six
> aggregates, and the most valuable data in a 68-cell run was lost to a cleanup job. The repair is two
> lines — sum the sizes at grade time and print `agg_bytes`/`agg_mbps` — after which no capture needs to
> survive the cell at all and the cell can delete them itself. *Ask of each intended finding: which
> printed field is it? If the answer is "we can work it out from the artefacts", it is not yet measured.*

**Retire a caveat about the instrument by moving the instrument, not by arguing about it.** *(T19.)*

> "This is a Python reader on two vCPU, so the absolute figure is an upper bound" was written into an
> experiment's limits and quoted for a session. Settling it cost one host, one file copy and four
> minutes: same binaries, same clip, same window, four times the cores — 7.45 % against 7.45 %, at zero
> CPU pressure. *A host-bound caveat is usually cheaper to remove than to keep restating, and keeping it
> quietly weakens every number it is attached to.*

**Derive a rate target from a capture of the stage's own input, never from another stage's output —
and treat an unexpectedly smooth result as a suspect one.** *(T13.)*

> A pass-through pacing target was taken twice from the wrong place. Below the true rate the leg
> throttles and wanders; above it, the leg spends the whole window draining a join backlog at the cap
> and looks *flatter* than a correct run. Both produced a plausible table.

**Grade a downstream stage against captures taken from the pipeline it will sit in, never against a
synthesised approximation of that pipeline's output.** *(T13.)*

> A CBR input built by stripping nulls from the source clip retains the source's own byte schedule,
> so content arrives ahead of the slots the groomer has for it. On that input the groomer dropped
> 6,360 packets and produced 100 continuity errors — a result that would have been reported as a
> defect. On a real capture of the same shape it drops nothing.

**A daemon started in a subshell outlives its own teardown, and answering on the port does not make it
yours.** *(T12.)*

> `( cd dir && relay config ) &` records the *subshell* in `$!`, so teardown kills the wrapper and
> leaves the relay bound. The next run's relay then failed with `Address already in use`, its
> fingerprint poll succeeded against the survivor, and the run silently graded a relay of unknown build
> and unknown remaining lifetime — reading as a clean mid-run collapse at the moment the stranger
> exited, complete with a plausible step change in the pair's agreement. Two lines fix it: `exec` the
> daemon inside the subshell so the recorded pid is the daemon, and after the fingerprint poll succeeds
> check the daemon is still alive, refusing the run if something else holds the port.
>
> T6's segmented arm hit the same defect with an HTTP origin, and showed that a liveness check is not
> enough even so. That cell's origin died on `Address already in use`; its client spent the drill
> talking to the previous cell's server over the previous cell's document root — where nothing was
> being killed — and the cell reported a clean *hitless failover* it had not earned, with every
> delivered number plausible. The general fix is an identity check, not a liveness check: write a
> token unique to the cell into the served tree and refuse to proceed until a fetch returns **that**
> value, so "a server is up" can never be read as "my server is up".
>
> T7's segmented arm then re-encountered it on a rig written after that fix, from the other direction:
> not a leftover server but two sweeps of the same script overlapping on its one port, each cell
> grading whichever publisher happened to be serving. It produced a complete set of conformant,
> plausible, wrong results — a clip's numbers can only be caught by noticing they carry another clip's
> bitrate. **So the identity token belongs in every rig that binds a fixed port, and it needs a
> companion: refuse to start on a port already in use, and hold a lock for the length of a sweep.**
> A rule recorded as one experiment's correction gets read as that experiment's problem.

**On a lane that two sources can serve at once, the failure is repeated time, not lost time — and
neither a continuity check nor a PCR-interval check can see it.** *(T6.)*

> Every corrupt cell in T6's segmented arm reported **zero** continuity-counter discontinuities while
> the delivered stream jumped backwards and forwards by twenty seconds. Both standard gates ask only
> whether the clock *moved*: CC is a property of each segment's own mux and every segment was
> internally valid, and a PCR-interval test measures spacing, which is correct on both sides of a
> rewind. The tell is in the rate ratio — a receiver taking 1.17× or 1.39× of source rate is being
> handed the same media twice — and the direct metric is an explicit count of PCR decreases. Add one
> to any rig where two publishers, packagers or origins can be live simultaneously.

**A metric that only fires on an anomaly is only ever exercised by one, so prove its arithmetic on a
case where it fires.** *(T6.)*

> The rewind counter above was first written against `pcrextract`'s "Value offset in PID" column,
> which is unsigned, and it wrapped on precisely the event it existed to detect — reporting a
> 6.8 × 10¹¹ second rewind. It read a perfectly sensible zero on every clean run, and the interval
> statistics that share the parser were genuinely unaffected, because for a monotonic clock that
> column differences identically to the PCR value column. A baseline in which the metric reads zero
> is not evidence that the metric works.

**Cancel a safety watchdog at teardown, or it fires into somebody else's cell.** *(T5.)*

> Each impairment cell armed a `sleep 1800; tc qdisc del` so a killed run could not leave the box
> shaped. Nothing cancelled them, so they accumulated and began firing half an hour later — *during
> later cells* — deleting the shaper partway through a run that then reported a clean, plausible
> result for a condition it never experienced. Every media-aware loss cell in that pass looked immune
> to loss, and it was the watchdogs. Nothing in the delivered numbers shows this; only the shaper's own
> counters do, as a missing qdisc where the impairment should be. So the watchdog is cancelled at
> teardown, and a cell that finds no shaper at the end is **failed rather than reported**.

**Segmentation offload decouples commanded loss from applied loss, and by a different factor for each
transport — so it breaks comparisons, not just constants.** *(T5.)*

> `netem` makes its drop decision on the buffer it is handed, which under TSO/GSO is a super-packet the
> stack splits into many wire packets afterwards. The commanded percentage then lands on
> super-packets while the wire carries many times more. Because TCP and QUIC offload differently, one
> `loss 10%` command delivered **7.8 % to the segmented lane and 2.5 % to the media-aware lane** — the
> two arms were never given the same impairment, and the media-aware lane's apparent robustness was
> partly a smaller dose. Turning off the kernel offloads is only half of it: quinn coalesces datagrams
> in its own `sendmsg`, so the application's GSO has to go too (`--server-quic-gso=false`), after which
> the media-aware arm measured 5.08 % against a commanded 5 %.
>
> Where a residual gap survives, **label the row with the loss the shaper measured, not the loss it was
> asked for.** The segmented arm still under-loses by about a third, and reporting actual against
> commanded is what keeps the row honest — here it also strengthens the finding, since that lane
> degrades further while receiving less.

**Loopback is not a small version of a network path: its MTU makes a percentage loss model
meaningless.** *(T5.)*

> `lo` defaults to a 65536-byte MTU, so `loss 1%` discards 1 % of ~37 kB super-packets rather than of
> wire-sized ones — each drop event tens of times larger and far burstier than any real path produces.
> Pin the MTU to 1500 for the run. The tell is the packet count: 1,366 packets for a window that should
> carry 36,000.

**`netem slot MIN MAX` with no allowances is a rate cap, not a jitter model.** *(T5.)*

> Bare `slot` releases **one packet per slot**, which at 30–90 ms intervals is a ~200 kb/s ceiling. The
> segmented lane read 0.77 Mb/s and the cell was written down as a collapse under jitter; the collapse
> was entirely the instrument. Set `packets` and `bytes` allowances so the slot varies timing without
> also metering throughput.

**In a timing rig, assert the process census between legs rather than trusting a kill, and check that
a file's size and its packet count agree.** *(T13.)*

> Killing a backgrounded `subscriber | groomer` pipeline by its last PID reaps only the groomer.
> Three orphaned subscribers competed for two cores by the last leg, inflating exactly what was being
> measured. The tell was arithmetic, not suspicion: a 17 MB capture that censused as 2.4 M packets.

**The carrier rate must exceed the arriving content rate, or the groomer drops content.** *(T12.)*

> A 2.0 Mb/s egress target for a 1.9 Mb/s feed leaves no stuffing headroom: 4,011 packets dropped, 11
> continuity errors.

**A two-host latency figure must bracket its clock, and a cell whose clocks moved by more than the
probe's uncertainty is spurious no matter how clean it looks.** *(T18.)*

> The origin's clock drifted ~1 ms per minute against this one, so every WAN cell probes the offset
> before and after and reports the difference. One cell straddled a clock step — 13.94 ms of drift
> against a 6.47 ms probe uncertainty — and returned the most attractive result in the experiment: a
> median of exactly 1000.3 ms, a 37 ms spread, and the only zero PCR-violation count on any arm. Re-run,
> it reads 2072 ms with 36 violations. The check is what stopped it being published, and the tell was the
> drift, not the implausibility — the figure was entirely plausible.

**Launch a long-lived remote fixture once, from a locally backgrounded SSH, and have the measurement
probe it rather than start it.** *(T18.)*

> `setsid nohup … &` over SSH does not detach the way it appears to: the SSH invocation blocks until the
> remote process exits, so a cell that starts its own hour-long clock server hangs for the hour. Earlier
> short-lived variants had masked this by "working" — they returned in exactly the server's lifetime.
> Backgrounding the SSH locally makes the wait harmless; making the fixture a separate step means a cell
> that finds no reference fails loudly instead of reporting no latency.

**Bind the port before opening the output file, and refuse the run when a previous cell's listener is
still up. And do not trust a process census taken from a sandboxed shell.** *(T18.)*

> A tap that opened its CSV first and bound its socket second truncated the file it was about to fail to
> write, so a port collision presented as *the transport delivered nothing* — the one symptom that looks
> like a real finding. Meanwhile a sweep believed dead was still running: the `ps` used to check it was
> sandboxed and could not see it, its taps held the egress ports, and the cells that did run were
> competing with it for the CPU whose scheduling was being measured. Two sweeps' worth of MoQ and
> segmented figures had to be discarded. The pre-flight check that would have caught it is one `pgrep`,
> and the census that finally showed the truth had to be run from an unsandboxed shell.

**Sort on the key, not the record.** *(T12.)*

> An arrival-ordered selector sorted whole `(time, leg, payload)` tuples, so microsecond-tied
> datagrams were ordered by payload bytes and one leg's own packets were scrambled into 207 phantom
> continuity errors.

**Any redundancy test whose sources are started independently measures its own clock skew.** *(T6.)*

> Two publishers replaying independent copies of the same clip from its start leave the standby's
> media timeline lagging by exactly the join delay, so on splice the exporter is handed timestamps in
> the past and emits nothing until the new source overtakes. The reported "8–9 s stall at standby
> join" tracked the join delay with slope 1.
>
> The segmented arm of the same experiment repeated the mistake in a new costume, which is why the
> rule is worth stating as *"same file" is not "same stream"*: two packagers each opening the clip
> for themselves, twelve seconds apart, produced a receiver stream oscillating ±20 s, and none of
> that was a property of the lane. Fan one regulated source into both legs — `gtee` into two FIFOs,
> or a live multicast for a mid-stream joiner — and the forward leaps vanish entirely.

**The merge window is the union of the legs' activity.** *(T12.)*

> Grading only the window where both legs are live truncates the analysis at the blackout it is meant
> to measure, and scores a covered outage as no outage. The survivor defines the end of the window,
> which is the entire point of 1+1.

**Verify where the capture tap sits relative to the impairment.** *(T9.)*

> A tap downstream of the shaper measures what reached the path, not what the sender pushed. Over one
> window the capture recorded 22,381 datagrams against the shaper's 22,396 passed and 2,441 dropped.
> Without that check, "unchanged under loss" reads as a finding when it is an artefact of tap
> placement.

---

## 6. Claims, and their scope

**Citing another component as the working reference for a contract is a behavioural claim about that
component, and reading its source is not evidence for it.** *(T19.)*

> The report that became #2984 rested on an asymmetry: #2967 documents a caller-side pacing contract,
> `moq-srt` implements it, `moq-cli`'s `run_ts` discards it. The `moq-srt` half came from reading
> `send_at = anchor + (ts - base)` and seeing it wait, which is the contract exactly. It was wrong.
> Its subtraction was scale-strict, the exporter stamps PCR in microseconds and media at the source's
> 90 kHz, and a cross-scale pair fell through to an error arm that assumed reordering and collapsed onto
> the anchor — so media frames on that lane were never paced. The fix to *our* issue had to repair the
> exemplar first. The report survived because its load-bearing half was a negative claim about
> `run_ts`, which reading does establish: *code that never mentions `frame.timestamp` cannot be pacing
> on it.* **Reading source is sound evidence that something is absent and weak evidence that something
> present works.** When the argument leans on a second implementation being correct, either measure it
> or say plainly that its correctness is assumed.

**Split a capability claim by pipeline stage before publishing it.** *(T14.)*

> "No maintained toolchain does Low-Latency HLS with MPEG-TS" was assembled from documentation and
> was true as far as it went. Run rather than read, it splits: **publishing** is a single free command
> that works first time, and **receiving** has no free implementation at all. Stating it as one
> undifferentiated gap made it look like an ecosystem that had not got round to TS, when it is really
> a market — the missing half is the half that is sold as hardware. *"No tool does X" is usually "no
> tool does one particular stage of X", and which stage decides who pays.*

**A claim that a class of tool cannot do something is a claim about the input as much as the tools —
name the input property that defeats them, then find an input without it.** *(T13.)*

> "No off-the-shelf stage grooms a broadcast mux" stood for most of T13's life, backed by nine chains
> against four criteria fixed in advance. Every measurement was sound and the generalisation was not.
> The property doing the work was in the *egress*: `moq export ts` carries no stuffing, so a groomer
> must inflate a stream and no tool that preserves a mux can. Run the identical nine chains against a
> segmented egress, which passes the source's nulls through, and `tsp -P pcradjust` alone passes all
> four criteria with the mux byte-for-byte intact. *If no input without the property exists, the
> conclusion is about the tools; if one does, the conclusion was about the input all along — and the
> useful version names the property, because that is the thing someone upstream can change.*

**A claim about what a tool cannot be configured to do is a claim about its whole parameter space.**
*(T16.)*

> "No configuration of the documented flags passes" was drafted from two correct facts about three
> parameters. Two more arms were run instead of asserting it, and one passed. The corrected finding
> was narrower and more useful than the one it replaced.

**A "structurally impossible" claim derived from a specification is a hypothesis about an
implementation, and costs one afternoon to test.** *(T14.)*

> "A sequence of TS segments is a re-muxed stream, so byte-verbatim carriage is structurally
> unavailable." Measured, a segment differs from the source in byte 3 on one PAT and one PMT and in
> nothing else. Inserting two packets is not re-muxing. *And when such a claim falls, check whether the
> mechanism it named survives without the impossibility attached to it:* here it did — the pair is
> *inserted*, so the mux is verbatim in payload but not as a mux, and those two packets still cost
> file-domain PCR accuracy.

**When recording what a blocked measurement needs, name the constraint that actually binds.**
*(T14.)*

> A cell was recorded as blocked on "a caching HTTP/3 origin, not installed". Two were then installed
> and the cell was still blocked, for two unrelated reasons. *A guess about the blocker sends the
> next session shopping instead of measuring.*

**A claim that decides a comparison must cite the measurement that established it.** *(This
campaign's own largest error, found in editorial review rather than in a rig.)*

> "MoQ carries the same feed sub-second, measured" appeared in two published documents for several
> revisions at a time when **no latency measurement existed anywhere in this campaign** — the property was
> a structural consequence of the protocol plus an inference from delivery granularity, and it decided the
> paper's central comparison. It has since been measured and the claim turned out to be true and
> conservative ([T18](test-18-delivery-latency.md): 109 ms across the internet). That does not retire the
> rule, it sharpens it: the claim was unfalsifiable when made, and *the absence of a citation on a
> load-bearing claim is a finding about the argument, not a gap in its prose* — being right by luck is not
> a defence.

**Name the measurement domain when file and wire can differ, because here they did.** *(T7/T13/T16,
found in editorial review.)*

> Grooming takes PCR intervals above 40 ms to 0 % **on file** and to 131–159 in 25 s **on the wire**
> at the same configuration. Five documents carried the file figure without its domain. Any
> conformance number that a hardware receiver would grade differently from an offline analyser has to
> say which one produced it — and where both exist, the delivered figure leads and the file figure is
> reported as the precondition it is, because a reader who stops after one paragraph must stop on the
> right number.

**Liveness must key on programme content, not carrier presence — and the enforcement point is the
sender.** *(T12.)*

> A groomer asked only to hold a rate holds it against a dead source: a byte-perfect CBR carrier with
> zero programme in it, minting the PCR that makes it look conformant. Both selection policies read
> that as health. *A receiver cannot recover information the sender declined to omit.* The content
> check must also exclude the groomer's own adaptation-only PCR packets, which the first version of
> that metric got wrong.

**Every stream-position quantity must be a function of position in the stream, not of what this
instance happened to emit.** *(T12.)*

> A resumed leg came back 8,756 datagrams behind its partner because its RTP sequence counted
> datagrams *sent*, so a silence cost it numbers rather than consuming them. Sequence number,
> timestamp and PCR all have to be derived from the stream for a redundant pair to work.

**Pin every parameter the property depends on, then measure; a prediction of divergence is not a
substitute for one run.** *(T12.)*

> Two independently packetised ungroomed legs were predicted to fail alignment on phase, making that
> arm a negative control. With RTP framing pinned and both legs co-started it aligns exactly in all
> twelve cells. It fails on *conformance* instead — which is a more useful result and was found only
> by running it.

**When comparing two designs, draw the demarcation before comparing, and count only work that falls on
the same side of it.** *(T14, found in editorial review.)*

> "Segmented HTTP's receive-side hand-off already ships, so that layer is solved for it" counted the
> client's own equipment as if it discharged the distributor's obligation. An advantage that lives in a
> third party's capex is optionality, not architecture — and the same slip flatters whichever side of a
> comparison happens to have the larger installed base.

**When a defect is attributed to a component, name the boundary the measurement was taken at — a fix
verified inside that boundary can be invisible outside it.** *(T19.)*

> The PCR clustering was attributed to the exporter, and the exporter's fix is exact: an exact 25 ms
> grid where 85 % of intervals had been sub-millisecond. But the spacing lives in per-frame timestamps
> and the exporter's only public interface is stdout, which carries bytes. So the defect survived at
> full strength one boundary further out, as clustered packet *positions* instead of clustered *values*,
> and the lane's wire conformance regressed. "The exporter" and "the exporter's output interface" are
> separate stages and a report should say which one it measured.

**Grade an upstream fix on the deployed chain, not only on the claim it makes.** *(T19.)*

> #2967's claim was true and independently confirmed at the exporter. Adopting it on that basis would
> have shipped a build that takes continuity from 0 to 824 errors and delivery latency from 118 to
> 769 ms. Only the end-to-end arm showed it, and it cost one 90 s run.

**A measurement that is undefined as a verdict can still be sound as a diagnostic, if what is read is
the distribution rather than the pass/fail.** *(T19.)*

> `pcrverify --absolute` on a rate-less media-aware egress cannot yield a conformance verdict, and this
> campaign has said so since T13. It still distinguished the two builds usefully: the pre-fix stream
> missed by *varying* amounts, the post-fix stream by a *constant* 24,842 µs. Constant error is
> arithmetically repairable downstream and varying error is not, which is a real difference that the
> verdict column discards.

**A head-to-head is only a lane result if the lanes were on the same substrate; otherwise it is a
substrate result wearing a lane's name.** *(Editorial audit of T5/T8 against the §14 verdict, settled
by [T20](test-20-segmented-http3.md).)*

> Reordering was the one impairment on which the two data planes separated, 0.98 against 0.19, and the
> paper carried it as a property of the lane. It was measured with TCP under the segmented arm and QUIC
> under the media-aware one, while the configuration the verdict recommends is segmented HTTP *over
> HTTP/3* — which puts QUIC under both and removes half the stated explanation. The audit's ask was
> only to re-run the cell on a shared substrate. Doing so found the other half of the explanation was
> also unsound: the arms differed in packet size as well as in transport, and that, not the transport,
> was carrying the result. **Before a comparative row is generalised, list what differed between the
> arms besides the thing under test, and check that the recommendation does not change one of them** —
> and note that the audit found one such difference where there were two.

**"Later evidence supersedes earlier conclusions" is only half a rule; the other half is that it
supersedes them only as far as it actually reaches.** *(Editorial audit, relay memory.)*

> The early reading was "linear, 650 MB/day, unbounded". The later evidence retired it properly:
> growth is flat in subscriber count, tracks ingested groups, and plateaus. But the plateau itself was
> observed once, at 14 h, still creeping at +1.82 MB/h when the run ended — so "bounded" is the
> direction the evidence points and not a thing the evidence establishes. The correction had to replace
> the stale claim in several places while *keeping* the qualification in all of them, and the temptation
> at each one was to write the cleaner sentence. **A supersession that drops the new result's own limits
> has traded one overstatement for another.**

**A file that records what is outstanding decays faster than one that records what happened, because
it is only correct until the next run.** *(Editorial audit, `planned-experiments.md`.)*

> Four entries described the arm to run next when that arm had already run, one of them contradicted
> twenty lines above by the file's own ranking. Nothing was wrong when written. The rule that keeps a
> to-do list honest is not "update it when things change" but **"an entry must name the document it
> could falsify"** — an entry that cannot name one has either been answered already or was never
> load-bearing, and both are reasons to delete it.

**An impairment specified per packet is only comparable across lanes that carry the same media in
comparable packets. Normalise MTU and offloads on every arm, and report the measured packet-size
distribution beside any per-packet result.** *(T20, re-running T5's reordering cell.)*

> T5's reordering cell was the paper's single strongest lane result: segmented HTTP 0.98 against MoQ's
> 0.19. It ran on loopback at the default 65536-byte MTU, with segmentation offload disabled on the MoQ
> arm — correctly, because `netem` mishandles super-packets, and *on that arm only, because that was
> the arm that needed it*. The captures show what the shaper then saw: **1,209 packets averaging
> 34,380 B on the segmented lane against 29,062 averaging 931 B on the media-aware one, for the same
> media**. `reorder 25 %` is a per-packet probability, so the lane that won met ~24× fewer events.
> Equalise MTU and offloads and the segmented lane falls to 0.44 on TCP and 0.18 on HTTP/3, against
> 0.13 — the separation was the rig's. **A correction applied to one arm because only that arm needed
> it is itself an asymmetry**, and the way to catch it is to measure the packet-size distribution on
> every arm rather than to reason about which arm the fix was for. The residual matters too and does not
> go away: even normalised, the QUIC arms send ~1.5× the packets for the same media, so "same shaper
> setting" is still not "same impairment" and the figure has to say which it is.

**A client option naming a transport is a request, not a measurement; prove the substrate from the
server and the wire.** *(T20, HLS over HTTP/3.)*

> FFmpeg propagates only a fixed whitelist of I/O options to a demuxer's child connections, and
> `http_version` is not on it. `-http_version 3only` therefore fetches the *playlist* over HTTP/3 and
> every *media segment* over HTTP/1.1, with no warning anywhere: the client believes it asked, and
> 100 % of the media bytes go over TCP. It was visible only because the origin logs ALPN per request.
> **The rule the rig now follows is that the transport is established by the origin, not requested by
> the client** — the H3 arm's vhost has no TCP listener at all, so a fallback fails loudly instead of
> succeeding quietly — and is corroborated by two further instruments that cannot collude with the
> client's configuration: the origin's per-request ALPN log and a packet capture counting UDP against
> TCP.

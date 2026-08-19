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

---

## 2. Instruments, and reading what they tell you

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

---

## 4. Attribution: naming a mechanism from the evidence

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
> from 18,070 to 5 and left repetition at 502 violations, unchanged. The counter that settled it was
> `pcr_inserted=0` — every PCR on the egress had come from upstream, so no amount of buffering could
> change what was never sent. A defect that survives the removal of its supposed cause belongs to the
> other stage.

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

---

## 5. Rig hygiene

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

**Split a capability claim by pipeline stage before publishing it.** *(T14.)*

> "No maintained toolchain does Low-Latency HLS with MPEG-TS" was assembled from documentation and
> was true as far as it went. Run rather than read, it splits: **publishing** is a single free command
> that works first time, and **receiving** has no free implementation at all. Stating it as one
> undifferentiated gap made it look like an ecosystem that had not got round to TS, when it is really
> a market — the missing half is the half that is sold as hardware. *"No tool does X" is usually "no
> tool does one particular stage of X", and which stage decides who pays.*

**A claim about what a tool cannot be configured to do is a claim about its whole parameter space.**
*(T16.)*

> "No configuration of the documented flags passes" was drafted from two correct facts about three
> parameters. Two more arms were run instead of asserting it, and one passed. The corrected finding
> was narrower and more useful than the one it replaced.

**A "structurally impossible" claim derived from a specification is a hypothesis about an
implementation, and costs one afternoon to test.** *(T14.)*

> "A sequence of TS segments is a re-muxed stream, so byte-verbatim carriage is structurally
> unavailable." Measured, a segment differs from the source in byte 3 on one PAT and one PMT and in
> nothing else. Inserting two packets is not re-muxing.

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

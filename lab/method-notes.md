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
> revisions. No latency measurement exists anywhere in this campaign; the property is a structural
> consequence of the protocol plus an inference from measured delivery granularity, and it decides
> the paper's central comparison. *The absence of a citation on a load-bearing claim is a finding
> about the argument, not a gap in its prose.*

**Name the measurement domain when file and wire can differ, because here they did.** *(T13/T16,
found in editorial review.)*

> Grooming takes PCR intervals above 40 ms to 0 % **on file** and to 131–159 in 25 s **on the wire**
> at the same configuration. Five documents carried the file figure without its domain. Any
> conformance number that a hardware receiver would grade differently from an offline analyser has to
> say which one produced it.

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

# Method notes

The campaign's methodological rulebook: consult it before designing, running, grading or interpreting
an experiment. Each rule is a bold instruction, the experiments it came from, and the check it implies;
the incident behind a rule is recorded in that experiment's file, not here.

A rule belongs here only if it would change how a future experiment is designed, measured or read.
Before adding one, look for an existing rule of the same principle and extend its provenance instead
of writing a sibling.

---

## 1. Controls

**A looped clip is not a long clip, and the difference is a rewind per lap.** *(T21, T23, T40, T47.)*
`tsp -I file --infinite` restarts the programme clock each lap, so a soak on it measures recovery from a
manufactured rewind, and on builds that end the import at a rewind it is a one-pass soak. Use a timeline
that advances for the whole run ([`ts-continuous-source.py`](scripts/ts-continuous-source.py), which must
rebase every PES-bearing stream, private stream 1 included). Before the run, scan each join per PID with
[`ts-join-scan.py`](scripts/ts-join-scan.py) (no backward step, discontinuity flag or continuity error; a
join interval like the median); grade a cut across a join with [`ts-tstd.py`](scripts/ts-tstd.py), since a
forward-moving join can still overlap one audio track and gap another
([`ts-seamless-loop.py`](scripts/ts-seamless-loop.py) builds one that passes); and count units with
13818-1 duplicate packets discarded, because a join can forge one.

**A gap in a delivery trace is not damage until the same session's do-nothing twin is shown not to have
one.** *(T38.)* A withdrawal arm's five pauses over 0.5 s matched an undisturbed session's four. Give every
de-provisioning, failover or impairment arm a twin on the same channel in the same session, and read a
pause with zero continuity errors as late delivery, not loss.

**A negative control and a broken rig give the same reading, so an arm whose expected result is
"nothing happened" must prove it ran.** *(T25, T8b P0-i.)* Abusers that died on a CLI parse error with
stderr discarded looked like perfect isolation; subscribers scored on survival scored zero bytes as
survivors. Give the stimulus its own liveness criterion (T25 fails a cell whose peak concurrent abusers
fall below two), keep one adversary's stderr, and classify any capture below a byte floor as void.

**A before/after across two builds must hold the instrument constant, and the newest release is usually
the wrong "after".** *(T8b, C3's #3271 re-check.)* #3006 between the arms changed what a fixed byte window
counted. For each commit between the arms, ask whether it could change the measurement as well as the
subject; if so, use the merge-base pair.

**A per-cell verdict must read every instance of what it is about.** *(T8b, C3's #3271 re-check.)* A death
detector reading only `sub.log` gave 0 against 6; all subscriber logs gave 3/15 against 9/15. Glob every
instance, print the count found beside the verdict, and make every derived quantity scale with fan-out.

**Pinning a component scopes the conclusion to the pin, and if the mechanism runs through the pinned
component the A/B can credit the wrong one.** *(T8b, C3's #3271 re-check.)* The mechanism ran through relay
group eviction while the relay was pinned. Ask of each pin whether the proposed mechanism could run
through it, and cross the pin before writing the report.

**A control that removes the suspect stage tests the stimulus, not the system, and exonerates nothing
downstream of what it removed.** *(T21.)* Feeding the looped clip straight into the groomer removed the
exporter that failed on the wrap. Name the stages a control removes, and write "the wrap alone, without
the exporter, does not do it", not "not the wrap".

**A control with the mechanism removed is worth more than a second run of the same arm, and where a
stage's own throughput could be the limit, the control that deletes the subject is mandatory.** *(T15,
T9, T7.)* Plain UDP through the same chain matched RIST's 73 ms bursts to the millisecond, so they were
the publisher's; a local file at the lane's rate did worse than any lane, so the clip measured the pacer.
A saturated instrument fails in the direction that looks like a finding.

**Pin a decisive setting on every arm, under each arm's own name for it, and read it back off the thing
under test.** *(T5, T8.)* T5 pinned the media-aware lane's BBR and left the segmented lane on the system's
CUBIC; matched, both lanes held full rate. Record both settings on the result line (for example
`--quic-congestion-control` and `net.ipv4.tcp_congestion_control`), and confirm from connections carrying
the run, sampling repeatedly where connections are short-lived.

**Run the control before believing a striking result, not after.** *(T17; the #2913 merge-base control;
T11c.)* A round trip that captured nothing matched a predicted failure until the merge-base build did the
same: a renamed flag whose alias warned and did nothing. A failure through another implementation is
theirs only once the same arm, subscriber included, passes through the reference one: T11c's
passthrough arm ran a subscriber that delivers nothing through `moq-dev`'s own relay.

**Grade beyond one full failure-detection interval, and record the idle timeout on both ends of the
session.** *(T6, T13.)* A failover graded 21 s into a 30 s QUIC idle timeout could not pass on any build.
QUIC uses the smaller of the two timeouts (a 6 s client put the relay's detection at 7–9 s), so observe a
hard kill for at least the idle timeout plus the behaviour's own window, or "not yet detected" is recorded
as "hung".

**A positive control that cannot take the arms' injections is a gate on the rig, not a comparison.**
*(T12.)* Arm C grooms once and duplicates, so killing its publisher takes the whole arm down: it validates
receiver and instrument, not the topology.

**A parameter fixed once and never varied is an uncontrolled variable.** *(T8b C3.)* C3's "a second feed
reduces throughput" survived controller and bufferbloat elimination until the 2 s `--latency-max` was
swept. Before hunting a network mechanism, list every value the rig was told and vary the ones never in
the matrix.

**A stage that sizes itself adaptively is a free variable: pin it before attributing a downstream count
to a build, and carry the control through the pinned run.** *(T23, re-grading against #3529.)* Underruns
fell 3,300 to 0 across builds while the adaptive cushion settled at 347 ms against 200; pinned, the
control moved too (189 to 6), so only the excess over control within one build could be claimed.

**Re-running the control re-measures the session, which is why it earns its place.** *(T23.)* On a
re-grade every arm's content gap rose, the byte-identical control's furthest, which forbade attributing
the rise to the build. Carry the null arm into every re-run.

**Stop the subject, not the instrument.** *(T37 D7.)* Killing the whole recorder pipeline left a control
that had held with no record. Give end-of-input to recorders that write on it.

**A control made of two production deployments is a coincidence, not an experiment.** *(T34, T40.)* Two
hosts on builds either side of a regression varied host, kernel and path too. Make the comparison from
pinned artefacts on one host when it can be made there.

**A transparent control through an arrival-clocked groomer attributes the transport buffers, not the
decoder buffers.** *(T44.)* SRT and UDP through such a groomer pass the transport buffers and fail every
decoder buffer; stream-clocked grooming passes with the source's own offset. Use stream-clocked grooming
or none for a whole-capture transparent control, and grade a clip as a source before using it as one:
the campaign's FFmpeg-muxed loop overflows its own AAC transport buffer.

**A self-pacing exporter is graded with nothing re-clocking it, and on more than its CI's clip.**
*(T47.)* A groomer after it grades the groomer. Use a forwarder that never re-clocks
([`ts-rtp-forward.py`](scripts/ts-rtp-forward.py)), give it a fixture with a broadcast-sized CPB graded as
a source first, and report T-STD and P2 separately: the export passed every buffer and failed PCR accuracy
on nearly every PCR.

---

## 2. Instruments, and reading what they tell you

**A check that has only ever returned "clean" has not been shown to work: give every grader a positive
and a negative control, in the run that uses it.** *(#2825's anchor port; T3, T5, T6, T7, T8b, T12,
T18, T19, T20, T36, T42.)* Six rigs counted continuity errors by grepping `tsp -P continuity` for
"discontinuity", a word it prints only in `--help`; T36 passed `pcrverify` an option it does not have;
`ps -o %cpu -p` read a wrapper at 0.0 %. Each read zero on every input, and the zeros reached pass
criteria and headlines. A capture against itself must read 100 %, and a known perturbation must move
exactly the rows it should (nulling every second PAT/PMT on one leg took those rows to about 50 % and left
SDT and NIT at 100 %). Damage the input by a known amount and abort if the grader misses it; prove a
rare-event metric's arithmetic on a case where it fires (a rewind counter on an unsigned column wrapped
on its own event); match the tool's data (`missing N packets`), not its prose; and when a class of bug is
found once, grep the whole rig directory ([`check-rigs.sh`](scripts/check-rigs.sh) rejects patterns `tsp`
does not emit). Use `t13-grade.py`'s gates rather than writing a third matcher.

**Validate a grader in the domain and against the failure it will grade.** *(T20, T28.)*
`t28-media-lost.py` passed injected holes on files and reported 1,254 s of duplication in a 55 s live
export, whose clustered PCRs broke its constant-rate assumption. Byte excision removes clock and content
together, and the media-aware lane loses one without the other; check agreement with pictures,
content-PID packets or eviction logs on impaired captures.

**Read a 33-bit timestamp step the shorter way round its clock, and replay a backward step from well
above zero.** *(T34.)* A classifier subtracting modulo 2³³ one way read a 16,845 s step back as
78,599 s forward. The wrap hides the step from a replay too: a fresh import starts at the capture's
own clock, a few thousand seconds in, so the step falls below zero and publishes as a jump forward.
Lift every PCR, PTS and DTS by more than the step, private streams included, and cut either side of
the event as controls: a cut before it must read clean.

**Verify the stimulus before the run: the fault is present in the bytes you will publish, it is the only
fault, and a stimulus meant to be invisible to a detector passes that detector first.** *(T19, T23, T24,
T39, T51.)* A source slice failed silently and the clip kept its audio; a "600 s backward jump" built by
subtracting from zero was legal rollover; naive packet suppression breaks continuity counters any P1 check
catches; a `tsp -P fork` copy meant to feed a second publisher "the same stream" arrived behind live and
lossy. Count what you removed in the published file and abort if it is still there; have each fixture
assert a field proving its condition; size holes from the clock, since loss of a multiple of 16 packets is
invisible to the counter; tap the inputs of consumers fed one stream and compare them.

**A conformance grader written once is one reading of the standard.** *(T19, T46.)* Five of eight PCR
analyser defects rejected legal streams, and `ts-tstd.py` had six defects against an independent check
that had three of its own. Build legal fixtures for every condition the standard permits, write pass
expectations first, cross-validate on the same bytes with an independent implementation, settle each
disagreement from the clause, and give "not measured" its own exit status: never pass a stream the
grader cannot grade.

**A corrected instrument owes a re-grade of every figure it produced, and a re-read of every argument
built on one.** *(T46, applied to T44, T45, T47.)* No verdict moved, yet counts, margins and "exactly
+0 ms" (now [+0, +100]) did. Re-grade every kept capture with the flags read from its saved output, re-read
each sentence using a moved figure, and label uncaptured figures as the old instrument's.

**Cut a file by stream position, not by wall time.** *(T39, T47.)* `tsp -P until --milli-seconds` and
`--seconds` count wall time, so a fast read consumes a whole clip; cut with `--pcr-based` or
`--packets N` (N = seconds × rate / 1,504), check the output's size, and never suppress a fixture
builder's stderr.

**A per-interval CPU figure comes from a CPU-time delta over that interval, and a resource baseline that
run history contaminates needs the process restarted between arms.** *(T38, T12.)* Darwin's `%cpu`
averages over up to a minute against twelve-second steps; relay RSS rose with arm order (14.5 to
71.1 MB) because it kept the previous arm's peak. Read cumulative CPU time either side of the dwell,
resolve the process rather than its wrapper, and restart or withhold contaminated baselines.

**Errors a server logs are not an instrument for a client falling behind.** *(T5.)* A segmented client
that lost 82 s of programme reloaded the playlist and skipped silently, and the origin logged only 200s.

**A receiver that restores a constant rate cannot report delivery by what it writes.** *(T52.)*
`moq export ts --delay` lays out its constant-rate mux in stuffing whatever arrives: its output held
100 % at a step where each subscriber received 83 % and the exports skipped groups in common. Count
the bytes the host received on each receiver's socket (a firewall counter on its port: `rchar` misses
`recvmsg` and reads zero for QUIC), and grade content by the groups its log says it skipped, since
the padded wire stays conformant.

**Read the confidence an instrument reports, and re-measure a derived quantity independently before
explaining it.** *(T12.)* A merge oracle with 15 votes in 23,175 reported twelve seconds of skew; arrival
at equal sequence numbers, which needs no correlator, read 10.4 ms.

**An instrument that reports completed objects cannot establish the absence of one designed never to
complete.** *(T17.)* Census EIT schedule sub-tables with `--all-sections`.

**A negative reachability result is evidence about the network only if the far end would have answered a
positive one.** *(T4.)* A filtered port times out (about 8 s); an admitted port with no listener refuses
in milliseconds. Test against a listener, or characterise the silence.

**Read a TSDuck threshold from the tool's echo, and fail a harness on an empty series.** *(T3, T16.)*
`pcrverify --jitter-max` is microseconds unless `--absolute` makes it ticks, and `pcrextract --csv` writes
to stderr unless given `-o`, so an analyser reading stdout silently dropped three tables' PCR rows. Check
the output against the columns it should have.

**Report long intervals and backward steps separately.** *(T12.)* Pooled, they reported sixteen "jumps"
in a clean control that has no backward step.

**Grade a pacing stage on which bytes left as well as when, and on what it added as well as what
survived.** *(T3, T13, T16.)* The best PCR record and flattest wire carried 231 continuity errors; 46
packets the segmented lane added moved PCR accuracy four orders of magnitude while the survival census
read clean. Give re-heading, re-indexing or re-stamping stages a conservation and an addition column.

**Two gates that both measure "PCR conformance" can disagree by four orders of magnitude, and a gate that
presupposes a property returns a plausible number on a stream without it.** *(T3.)* Inserted packets
leave P1 repetition unchanged and move P2 accuracy from 37 ns to 302 µs; `pcrverify --absolute` grades an
unstuffed egress as exactly its maximum interval. Name the gate a result is quoted against, and check the
instrument is defined on the thing compared before booking the cell.

**"Pacing" names three quantities, and a lane can pass one and fail the others.** *(T13.)* PCR values on
an exact 25 ms grid can carry 188 B to 870,628 B between pairs against the 31,081 B the rate requires,
and padding within 0.21 % of the rate can leave 96.7 % of slots wrong. Read the interval from the carried
PCR values and the rate from the packet count over the same pair (`pcr-residual.py`), and grade the
distribution of per-slot bytes, never the total.

**Read PCR from one PID, and say which.** *(T13 P1-n.)* Two PIDs on offset 25 ms grids pooled into a
12.5 ms grid with half the bytes. Print the PID census before the verdict, grade one PID, report the
interval minimum (clustering hides under median, p95 and maximum), and compare groomed output against
the source's own sub-millisecond share (0.09 % on the reference clip).

**A determinism comparison aligns on the source's own bytes, never on a value either process minted, and
compares as multisets before positions.** *(T12, T13 P1-n; `ts-pair-diff.py`, `ts-cc-merge.py`.)* PCR,
packet index and continuity counter are the values under test. Align on a payload run that occurs once in
the other capture, taken after the later process joined; allow the alignment to slip, since one displaced
packet de-phases every later slot (24.28 % slot-by-slot was 99.95 % common as a multiset and 98.414 %
aligned; a groomed pair was 24.7 % by slot and 100 % keyed by PID and PTS); classify each difference by
field; on a saturated constant-rate mux count packets per PID per PCR interval before naming a burst; take
each PID's continuity offset as the modal one; and void a comparison of streams that are mostly nulls.

**Pass `pcrverify --bitrate` explicitly whenever the arm might not carry the full programme.** *(T19
measurement 11, T47.)* Without it TSDuck derives the rate from the PCRs it then grades, so shed content
fails every PCR. Pass the padded rate, not always the rig's: 9,999,999 against 10,000,000 b/s exceeds
500 ns after about 5 s. Fit PCR value against packet index to separate rate from error.

**Grade a stream against the values it asserts about itself.** *(T19.)* Compare each PCR interval with the
difference of its two PCR values ([`ts-pcr-timing.py`](scripts/ts-pcr-timing.py)); that yields the error's
sign and needs no reference clock. A preempted reader errs early and late in balance and a writer
flushing backlog errs early only (626 early to 136 late); cross-tabulate two failing invariants before
calling them two defects (615 of 626 early releases were byte-adjacent).

**A fix acts in one domain; test it there.** *(T19, T7.)* A file capture measures byte position and cannot see
the release timing #3006 changed. Name the domain (value, byte position, arrival time) before measuring,
and the point after it. TR 101 290's accuracy is value against byte position, the same from a file or a
capture; overall jitter and the delay factor need arrival timestamps where the receiver sits. A PCR grid
a stage regenerated grades that stage, not the delivery before it; source-to-egress timing is read on
matched PTS.

**Where an instrument's behaviour is a choice rather than a requirement, its tests must say which.**
*(T12, the ST 2022-7 selection oracle.)* Label each case as standard-required, precondition violation,
unreachable or blind spot; self-authored tests prove stability, not conformance.

**A detector reading an aggregate has a sensitivity floor set by the share it watches; report it.**
*(T24.)* The stuffing ratio catches dead video (13.7 % to 95.2 %) and misses dead audio (27.0 % against
the control's 27.1 %), because audio is 4 % of the mux.

**An instrument that blocks on its input cannot observe the absence of input, and elapsed media time is
accumulated from bounded steps, never measured from an origin.** *(T27.)* A liveness check in `read()`
never ran during a total stall; current-minus-first PCR turned one bad byte into a 23,861 s outage on four
PIDs. Drive stall detection from a clock the subject does not control, reject backward or implausible
steps, and fault-inject the instrument.

**A quantity meant to be stationary needs a time series; a high-water mark is not one.** *(T21.)* A
cushion's collapse from 1.4 s to zero was invisible in `buffer_high_water` until occupancy was sampled on
a timer.

**A continuity count detects loss and cannot measure it: the counter is four bits.** *(T5, T19, T31;
[`cc-aliasing-probe.py`](scripts/cc-aliasing-probe.py).)* 82,104 shed packets read as 110 missing, and a
segmented re-anchor over 200,000 packets as 33. Excising 16, 32 or 160 packets reports 0. On the
media-aware lane's egress it cannot even detect loss, because the exporter writes its own counters (0
errors on 75.64 s of pictures lost). Read continuity for whether a wire is clean and conservation for how
much survived, and put a delivered-ratio column beside any continuity count.

**A trace's labels are code.** *(T28, the reorder qlog.)* noq labelled every declared loss
`reordering_threshold` because a time difference saturates to zero. Read the code that writes a cause
field before quoting it, prefer acknowledgement frames to trigger labels, and disable a candidate cause to
test the label.

**`srt-live-transmit` fed from a pipe pads every short read with zeros.** *(The #4543 SRT arms;
[Haivision/srt#3388](https://github.com/Haivision/srt/issues/3388), padding through v1.5.7.)* Feed SRT
from a sender that emits whole packets (`tsp -O srt`), or check the receiver's bytes for zero-filled slots
before attributing parse errors.

**An SRT latency longer than libsrt's buffers hold fails without an error.** *(T28's 11.87 s column.)*
The default 8,192-packet buffers hold about 8.7 s at 10 Mb/s; at 11.87 s even the unimpaired control lost
picture and ran 3.3 s late, and impaired cells logged `RCV-DROPPED` and ended 10–16 s behind. With both
ends' `--rcvbuf`/`--sndbuf` at (latency + RTT) × link rate every cell was clean. Size them so before
running any SRT arm above about 8 s, and count `RCV-DROPPED` in the receiver's log.

**Time a picture where a decoder presents it, on a clock averaged over many packets.** *(T45, T46,
T57.)* DTS spread 521 ms where presentation was flat, because the exporter authors DTS up to 280 ms
early, and single-header offsets scattered ±37 ms through `tsp -P regulate`. Reference latency to the
PTS, take each end's clock from a median over seconds of headers, check the instrument on a
byte-faithful capture first, match pictures on slice data where a lane rebases PTS
(`ts-decode-latency.py --key content`), and quote presentation latency only on bytes that pass the
T-STD. Grade a delay's constancy across a re-multiplexer on the two PCR clocks, each picture's
latency less its lead over its own stream's PCR plus the far end's (`p1aa-grade.py`): on arrivals,
each multiplexer's scheduling moved a 72 h delay by tens of milliseconds a minute where on the PCR
clocks it held a 43 ms range.

**Grade a clock's rate by fitting PCR against the receiver's clock, not from a latency trend.** *(T45,
T47.)* Trends between run thirds read 290–370 ppm where the fit read about 500 ppm. Fit over the longest
span (`ts-decode-latency.py`, "PCR clock vs tap") against the same run's source tap, and grade 30 ppm on
the whole-run fit, breaking it wherever the PCR's advance departs from the arrivals' (a splice, a
restarted export's fresh clock) and pooling the stretches: one unbroken fit across T57's splices read
36 % (`p1aa-grade.py`). The slew limit is below a picture tap's reach: drift rate needs PCR-arrival timing
(`t18-latency.py tap --pcr`, `ts-pcr-rate.py`), and where departures are quantized (25 ms slots, a 1 ms
timer) a white-noise floor misleads, so read the clock from when the steps fall.

---

## 3. Ratios, windows and intervals

**A ratio between two captures is valid only over the same media; construct it so that no interval
appears in it.** *(T3, T9, T14, T16, T25.)* Dividing bytes by another stage's wall-clock span put delivery
4.7 % above a CBR source; a bursty flow's first-to-last span runs short and inflates every rate divided by
it; last-PCR-minus-first saturates at one lap of a looping source; equal windows of one clip differed in
stuffing (18.43 % against 13.1–13.8 %). Form ratios from byte totals over the same media, offset the
reference to the same media, keep cells inside one lap, and report a reference's homogeneity by quarter.

**Estimate a rate as one ratio of two sums, never as the mean of per-interval ratios, and close any loop
a rate estimate drives.** *(T19, `mpegts-pacer`.)* Intervals carrying 1 to 4,631 packets averaged to
7.14 Mb/s for 9.31; an open-loop release with a 2.5 % under-read drifted 1,792.9 ms in 90 s. Sum, then
divide once; trim release by buffer distance from target; a latency that grows linearly with the window
is the signature.

**When the subject polls on a fixed cadence, randomise where in its cycle you intervene, and take the
phase from the instrument that observed the event.** *(T37.)* Integer-second settles put six revocations
within 3 ms of one phase. The zero of a measurement comes from the observer's log, not from the script's
intention.

**A suspiciously round figure at the scale of a default is a default.** *(T37.)* A 10.032 s "response
time" was a client's `--backoff-timeout`. Set retry budgets negligible and state them.

**An extremum carries its window, and a mismatched-window extremum can manufacture a false agreement.**
*(T3, T4.)* A maximum over more media can only grow. Matching 320 ms maxima at egress and "source"
credited cadence transport, though the source's maximum was 24.95 ms and 1,123 of 1,307 egress intervals
were under 1 ms. Prefer a distribution to a maximum, confirm "preserved" against the source in the same
window, and never read a matching mean as preservation.

**Fix a numeric budget before the measurement.** *(T9.)* A budget derived afterwards cannot falsify the
run.

**A window shorter than the phenomenon's own timescale reads as a different phenomenon.** *(T8b C6, T9,
T21, T26, T27, Gate 2's rig design.)* Relay memory knees near three hours, so hourly slopes read as
unbounded growth; a groomer's nine-minute "monotone drift" was a bounded 600 s oscillation; a pacer
qualified on 300 s failed after about nine; a ramp moves N and time together, so it measures neither. Set
a soak from the longest period in the system (the PCR wraps every 26.51 h, so 24 h may hold none and 72 h
holds two; place a fixture near the boundary instead of waiting), outlast every integrator a change adds,
name the denominator of a per-something cost and hold it at one, and pin the variable you are not asking
about.

**Distinguish a leak from a cache: register the shape as well as the number, and fit the competing
shapes.** *(T8b C6, T21, T45.)* A step
fits a line better than a logarithm, and a converging curve and a leak can share a ceiling. Fit at least a
line, a logarithm and a square root, quote slopes per quarter (the relay's halved, 9.85 to 1.75 MB/h; the
publisher's held at about 2.6), report a shape-independent statistic beside the fit (largest single
increment as a share of growth, largest drawdown from a running peak), measure warm-up instead of assuming
it, and pair long RSS series with reclaim counters.

**A bound on an accumulating quantity comes from the thing allowed to accumulate it, and a trend is
growth only once every buffer it could be filling is ruled out.** *(T19 measurements 9 and 10.)* A
+2,153 ms trend was the exporter lagging to its default 3 s `--latency-max`. Grade drift against the
owner's allowance, not an instrument's default, and separate settling lag from a slow pipe by the tail
rate.

**A shedding figure belongs to the stream and the buffer it met.** *(T19 measurement 10.)* Sweep the
buffer and report the recovery point beside the loss: bounded displacement recovered 105,959 of 106,382
packets at exact CBR.

**A median across a window containing a step measures where the step fell.** *(T28 P1-m, P1-q.)* Two
outage replicates read 7,936 and 2,184 ms with matching p95. For a step, report the late-window value and
the trend, and call a still-moving figure a lower bound. Look at replicates before fixing a judge across
builds: the 5 s outage is bimodal on every build bisected, so judge the share in the high mode and size
the replicates for the shift that matters.

**Matching on a measured quantity can collapse the sweep you thought you were running.** *(T28 P1-m.)*
MoQ's measured latency was about 2 s at every budget, so SRT's matched settings were one buffer three
times. Print the matched values and check they still differ.

**An impairment rung has to be expressed in the units the result depends on.** *(T31.)* An absolute
12 Mb/s "shortfall" left a 9.95 Mb/s fixture unimpaired. Write rungs as multiples of the stream's rate and
derive the absolute value from the fixture at run time.

**A hole count sees only gaps between what arrived, so conserve against the window.** *(T28.)* Video
that stopped at 29.6 s of 60 graded 2.76 s lost. Grade programme lost as expected minus present
([`t2831-conservation.py`](scripts/t2831-conservation.py)) and report the hole sum as a lower bound.

**Define a metric over the regime the experiment is about.** *(T22.)* Including the pre-first-advance
start-up put an 8.1 s floor under the control (3.1 s without it).

**A reference leg is a reference only for what it holds.** *(T50.)* Legs started together subscribe
milliseconds apart; where each unit is its own group, the reference lacked up to 76 packets of the
first second's teletext and AC-3 that the others held, and a merge graded against it differed there.
Grade a merge from the first slot every leg holds on each PID, and count what the reference lacks
apart from what the merge lost.

**Where a resource result is a null, report the bound, not the number.** *(T25.)* Idle baseline spread
(0.8 MB) exceeded the abuse excursion (0.6 MB). A discarded run's control arm is still data about the
instrument.

**A parameter sweep whose runs do not share a join measures the join as well as the parameter.**
*(T45.)* 550 ms failed worse than 500 ms because 1 % of its video arrived 199.5 ms late. Measure the lane
in each run and report it beside the result.

**Grade an outage to sustained recovery, not by its longest gap.** *(T56.)* After a hard kill an
export resumed in a blip of pictures and paused again for about its delay: the longest gap between
good pictures read 6.2 s where the outage was 8.7 s, and the window after it held no picture to
measure the programme lost. End an outage at the first second of good pictures with no gap over
0.5 s, and measure what was lost from there.

---

## 4. Attribution: naming a mechanism from the evidence

**Before reporting a resource cost, vary the knob the documentation says bounds it; where it could be
concurrency or churn, hold concurrency fixed and vary lifetime.** *(T25.)* A 256 MiB cache cap left a
1,930 MB peak unchanged, and cutting the idle timeout from 30 s to 10 s cut growth 4.5×; the same 42
subscribers cost 1,833 MB churned every 5 s and 65 MB held.

**On a lane whose transport holds no session state, measure two clients before naming the lane.** *(T6,
T8b.)* Under one shortfall a segmented client either lost the session at 43 s or held 99 %, depending only
on its 404 re-anchoring.

**Before reporting that a client cannot reach a relay, run it in each of its publishing modes and read
its interop notes.** *(T53.)* `openmoq-publisher` with `--publish-catalog` publishes by PUBLISH, which
`moq-relay` refuses; without it, the same release is served on draft 18. The arm's mode was reported as
the client's defect.

**When two runs differ in more than one variable, do not credit the one you have been tuning; and a
quantity that does not move under your variable is not thereby someone else's.** *(T13, T18, T19.)*
Cushion took the credit for a PCR result until an eightfold sweep moved nothing; the same invariance was
read three times as proof the cause lay upstream, and three upstream fixes merged on that reading before
reserving the slot in our own groomer cleared the gate. Enumerate what your own stage's knob cannot reach.

**Name a divergence from the bytes that differ, with the suspect field masked, and attribute the
residue.** *(T12.)* None of 400 conflicting datagrams differed only in PCR; 97–98 % differed in one field
minted upstream of both groomers; breaking the remaining 2.90 % down by PID named the second defect.

**A mechanism read from the source is a hypothesis; before reporting a null, work out whether the arm
could have shown the effect.** *(T10, T12.)* A 15 s SI clock with 870 ms lag predicts 0.6 differing
emissions in ten, so zero confirmed nothing until the clock was driven at its limit.

**Before recording that a stage preserves a property, check whether another experiment found that it
does not.** *(T4.)* A contradiction between two files means one is already wrong and being cited; treat it
as a defect.

**A stage's own counters decide a placement defect, and a counter reading zero where its event is
impossible is evidence about that configuration only.** *(T18.)* Matching the carrier to the content cut
underruns from 18,070 to 5 while violations held at 502; `pcr_inserted=0` at 0.0 % stuffing was quoted in
five documents, though that groomer inserts only into slots it would stuff. Vary the condition that enables
the mechanism and check the counter moves.

**A threshold-crossing count can point at the opposite of its cause; plot the interval distribution
first.** *(T18.)* 375–414 intervals above 40 ms read as too few PCRs; the distribution showed a median of
11 µs and every violation in a hole between bursts. Loss and clustering look alike in the count and
opposite in the distribution.

**Keep a byte-transparent control carrying the same source in the same session in any rig that measures
a conversion.** *(T18, T8b.)* The exporter's defect went eighteen months mis-summarised because it was
only ever seen through a groomer, with the source profiled in another session.

**Distinguish a stage that normalises a difference from one that gives two streams a common frame of
reference.** *(T12.)* Only normalisation bounds what downstream measurement can see.

**When a comparison ranks transports by their output, measure the input as well, and check what the
convergence a mechanism predicts would cost elsewhere.** *(T14, T15.)* Otherwise the source's virtues are
credited to the transport; a packager that stripped stuffing would forfeit its byte-verbatim segments.

**Predict a deviation's magnitude from the mechanism, spread the variable it scales with, and vary the
one it says is irrelevant.** *(T3, T12.)* PAT and PMT at a segment head predicted 300.8, 109.4 and
302.4 µs on clips 2.75× apart in bitrate, measured 297.7, 109.4 and 301.9; segment duration moved
injection count 5.7× and maximum error 1 %. A gradient hypothesis is cheapest falsified at its extreme.

**Run the falsification test even after you stopped believing the prediction.** *(T8b C3/C4.)* A caveat
retired by measurement eliminates a class of cause; one retired by argument eliminates nothing.

**Before adopting the tidy explanation a new number suggests, test it against measurements already in
hand.** *(T8b C6.)* A coincidence of ratios is not a mechanism.

**When a stage reports bad input, write down the stage's own contract, and refuse to integrate a sample
there is no reason to believe.** *(T19, T21, T34.)* A groomer that read one PCR interval as both duration and
length exited zero after discarding 67.2 % of a legal fixture; a pacer computed 431 Mb/s inside an
11 Mb/s carrier and drained its cushion; an importer's *below the live edge*, read as the feed stepping
back, was its own stamp on a SCTE-35 section. Make assumptions measured quantities, check recovered values
against conservation, and raise a counter rather than clamp silently. Before blaming the source for a
refusal, reproduce it on the captured bytes through the same build, cut either side of the suspect packet.

**Where a stage derives a quantity from its input, capture both ends of one run.** *(T21.)* The input
showed a clean grid and a signalled break, the output a stopped clock: the estimator was faithful to input
that had stopped telling the truth.

**Before attributing a throughput ceiling to software, read the platform's statement about the
interface, and instrument every candidate.** *(T26.)* Nitro's `ethtool -S` allowance counters stayed at
zero to 1.47 Gb/s and 154 kpps.

**Fit a model over the régime that holds, then move a resource to test its prediction.** *(T26.)* Fitting
only delivering points predicted about 124 subscribers per core; `taskset` halved the core and the cliff
arrived between 125 and 150.

**Bisect when only the build differs, with the reproducer's period shrunk, a known-good second
subscriber, and every void step reported as void.** *(T27, T28.)* A 30 s cut put a join every half minute
and six steps in an hour. Set `PATH` in the step script (a bisect faster than one build tested nothing),
detect each flag from the subcommand that takes it, check the disk first, and when first-parent bisection
lands on a merge, test a `main` commit the branch absorbed before bisecting the branch.

**A fix verified against the stimulus it was written for is not verified against its complement.**
*(T27.)* #3375 passed six single-event arms and stalled a continuous timeline whose content restarts. Add
the case the fix newly decides about, and where it adds a detector, the arm where it must stay silent.

**A mechanism read from a diff names the component, not the loop.** *(T8b C7.)* Bisect named #4001's
interleave hold; collapse needed `rewind()` renewing the hold at every skip. Settle a mechanism with a
same-build switch on one variable and a log of the decisions: the switch proves cause, the log shows the
loop.

**Locate a whole-capture error count in time before naming its cause.** *(T45.)* Ninety continuity
errors fell in a groomer's first 5.3 s of backlog trimming. Spread causes predict spread events;
transients and single incidents predict clusters.

**Repeat a cell that disagrees with its neighbour before naming what differs.** *(T47.)* A cross-host
failure moved from audio to video on a re-run and passed on the third: entry state, not configuration.
Configuration effects repeat; a margin that repeats to a tenth of a millisecond is one state repeating.

**A failing capture's span is not a rate; measure a timeline unit by unit and replay the scheduler before
theorising.** *(T47.)* 13–29 % less PTS than PCR was a join hole plus queued exit units.
[`ts-schedule-replay.py`](scripts/ts-schedule-replay.py) predicted the next two runs to 0.03 s; replay the
source's timing as a control.

**Count a PID's packets per interval, and size its PES against its buffer, before naming a cause.**
*(T47.)* AC-3 overflow ran to 38 packets per 25 ms slot, with PES carrying nine frames larger than the
buffer.

**A confirmed defect on the path is a candidate, not a cause, until each stage between it and the
symptom is observed.** *(The standing live-ingest chain.)* Fixing a measured auth inversion changed
nothing; three more faults remained. Count bytes at each boundary, and treat `systemctl is-active` as no
evidence that a pipeline moves bytes.

---

## 5. Rig hygiene

**A replicate loop inside one script invocation re-uses the fixed port the last replicate held, and any
fixed port can be answered by a previous run's server.** *(T6, T7, T12, T18, T31, T47.)* Old relays
answered new subscribers; `( cd dir && relay ) &` recorded the subshell in `$!`; one build drained longer
on SIGTERM than the teardown waited. Run one replicate per invocation with full teardown, `exec` daemons
inside subshells, refuse to start on a bound port and hold a lock for a sweep, serve an identity token
unique to the cell and refuse until it answers, check a started server is still running before starting
its clients, wait for the process to exit (force after 10 s) rather than a sleep, and bind the port before
opening the output file.

**A capture that stops early grades as a flawless cell.** *(T4, T8b, T28, the #4733 re-run.)* A session
that died mid-cell graded 0.000 s lost; a cell graded while its writer ran read 65 s of 90; an output not
deleted before an outage read the previous run; workstation sleep stretched 60 s arms to 780–1,060 s.
Check span, byte count and wall-clock duration against siblings and the nominal window before any quality
metric, grade after the writer exits, `rm -f` each target inside the measurement function, wrap
unattended local runs in `caffeinate -dims`, and void a short cell rather than score it clean.

**A run measures the machine it runs on, so what else the machine does is part of the cell.**
*(T9, T21, T26.)* Give soaks, memory arms and timing rigs a host window of their own, never beside a
build; run a deliberate saturation (the segmented fan-out) last in a session, and keep a segmented
origin off any box carrying a MoQ relay. Cheap namespace cells fill a window whose main item is
posting, reviewing or building.

**Every statistic the experiment reports is an output the cell prints, and no cleanup job runs against a
live results tree.** *(T8b C3.)* A mid-matrix janitor deleted four of six captures C3 needed summed. Sum
at grade time and print the aggregate; a number recovered later from surviving files is a salvage.

**When arms run back to back against a service that caches an admission decision, the cache carries the
last arm's answer.** *(T37, T38.)* Wait out or clear the relay's `max-age` cache between arms, rule it out
before reading "no media" as a publisher fault, and hold one keepalive subscriber on every channel for the
matrix.

**Know which bytes ran: hash every artefact the arms share, both sides of a patched-against-stock pair,
and the binary itself.** *(T11b, T12, T40, T45.)* An uncommitted patch survived `git switch` and both binaries
hashed alike; binaries report no `-<sha>` since #3912. Worktrees sharing a cargo target reuse each
other's crates, so a `main` build linked the branch's export. Commit the variant, rebuild from clean status
with the build log showing the changed crate compiled from that worktree, compare SHA-256 before the
first run, print the `bin-<sha>.sha` sidecar, and where a defect or change has a sharp signature (a
message only one side has), use it as the identity test.

**A pinned binary takes its config from its own tree.** *(T44.)* [`t18-arm.sh`](scripts/t18-arm.sh) once
copied the live checkout's schema. Pass `git show <build>:demo/relay/localhost.toml` explicitly and strip
sections for features the build lacks.

**Detect a binary's flags and capabilities from that binary.** *(T28; the #3793 rebuild, T21, T27,
T40.)* #3793 renamed the dial and relay flags, a bisection met CLI states neither endpoint had, and
`--quic-qlog` appeared in `--help` but was compiled out. Use [`moq-cli-flags.sh`](scripts/moq-cli-flags.sh)
per binary, and run a diagnostic arm's flag once against the exact binary before queueing it.

**`--auth-public` inverted its meaning at the CLI migration, and the wrong value delivers nothing
without an error.** *(T13 `3831-a`, P0-i, both standing relays.)* It takes a path glob relative to the
connection root: before the migration `""` meant everything public, after it `"**"` does, and `anon/**`
serves nothing on any build. Read `RELAY_AUTH` from relay help (`moq-cli-flags.sh`), and check a capture
is non-empty before grading it (`moq_require_bytes`, `check-rigs.sh`).

**The default congestion controller changed to the one known to abort, and a rig that does not pin it
cannot attribute anything.** *(The `84b34f54` survey; T8, T13, T20, T28, T31.)*
`--quic-congestion-control` defaults to `delay` (BBRv3), which T8 records aborting under high loss. Pin it
on every relay through `RELAY_CC_FLAG`, state it with the result, read the QUIC backend from the binary,
and say which backend a figure is on when it crosses #3811 (quinn removed). Under `netem` reorder BBRv3
delivered nothing where CUBIC delivered 55 s; in the `netns`/`cake` rig the controller moved nothing
beyond scatter.

**A receiver's per-fetch timeout is a measurement parameter, and on an impaired lane it can be the whole
result.** *(T28, T31, T68.)* `curl --max-time` binds where one segment's goodput falls below its size over the
timeout; at 25 % reorder one cell read 4.0 % of control at 15 s and 25.4 % at 60 s. Quote the timeout and
re-run impaired cells at a longer one, grading both: a longer one is not kinder to an outage, where 10 s
instead of 3 s left a stalled fetch waiting past the link's return and lost 14.6–26.0 s against 9.5–10.6 s.

**An origin or a receiver can be the bottleneck at the rig's RTT.** *(T31, T42.)* nginx's 64k
`http3_stream_buffer_size` caps a stream near 4.6 Mb/s at 100 ms, and a `curl` per cycle restarts slow
start. Before a lane's first impaired cell, check its unimpaired control keeps up with margin
([`t31-origin-window.sh`](scripts/t31-origin-window.sh)).

**Delay in front of the shaper costs an ack-clocked sender, and not a paced one.** *(T28, T42;
[`rig-capacity.sh`](scripts/rig-capacity.sh).)* TCP through 20 Mb/s `cake` with 100 ms ahead of it ran
4–6 Mb/s while paced UDP passed 19.3. Calibrate a new or changed rig with bulk and paced traffic, say where
the delay sits, and separate rig bias from lane behaviour with
[`t2831-topology.sh`](scripts/t2831-topology.sh).

**Segmentation offload decouples commanded loss from applied loss, by a different factor per
transport.** *(T5.)* One `loss 10%` delivered 7.8 % to the segmented lane and 2.5 % to the media-aware
one. Disable kernel offloads and application GSO, and label a row with the loss the shaper measured.

**Loopback is not a small network path, and `netem slot` without allowances is a rate cap.** *(T5.)* A
65,536-byte MTU makes each drop far larger; pin it to 1,500. Bare `slot` releases one packet per slot;
set `packets` and `bytes` allowances.

**Cancel a safety watchdog at teardown, or it fires into somebody else's cell.** *(T5.)* A stray
`sleep 1800; tc qdisc del` removed later cells' shapers. Fail a cell that finds no shaper where one was
armed.

**A workaround flag records the platform it works around and is re-tested when the platform changes.**
*(T26.)* `--quic-gso=false`, for macOS loopback, cost Linux relays 29 % CPU and half the fan-out ceiling.

**Verify where the capture tap sits relative to the impairment.** *(T9.)* Downstream of the shaper it
measures what reached the path, not what the sender pushed.

**State which directions an outage drops.** *(T28 P1-z.)* The ladder's outage dropped only what the
relay sent, so the subscriber's packets reached it throughout. A recovery rule keyed on hearing the
peer then fires during the outage, not after it; dropping both directions adds an RTT sample that
spans the outage. Record the direction with the cell, and run both when the mechanism listens to the
peer.

**An inline instrument damaged one lane and was invisible on the other.** *(T28 P1-m.)* An inline tap
cost SRT 4.2–5.4 s and thousands of continuity errors with no impairment, and nothing on the media-aware
lane, whose exporter re-synthesises. "On both arms" is not "cancels" when one lane passes bytes and the
other regenerates them. Prefer a mirroring tap (`tsp -P fork --nowait --ignore-abort`), attribute the
position rather than the technique (only the source-side tap did it), and keep pacing and the transmitter
it feeds in one process: splitting `regulate --pcr-synchronous` from the SRT sender was the cause, and a
run that delivers more programme than it lasted has lost its clock.

**The exporter manufactures bytes and clock, so neither measures what the media-aware lane delivered.**
*(T8b, T20 4a, T24, T28, T31.)* From #3831 `--mux-rate` pads to the catalog's rate, so a delivered ratio
can exceed 1.0 on 47.7–94.1 % nulls; the exporter keeps 25 ms PCR across evicted groups (0.775 s "lost"
against 36.4 s of missing pictures), so PCR is a liveness signal on this lane. Ask what the sender is
allowed to manufacture, report the null share, and grade picture and sound per elementary stream
([`t28-content-lost.py`](scripts/t28-content-lost.py)).

**A pacer's carrier must match the content arriving at it, and its commanded depth is not the depth in
force.** *(T12, T18.)* A 2.0 Mb/s carrier for a 1.9 Mb/s feed dropped 4,011 packets; a carrier above the
content rate burned the cushion while the status line said "holding 2000 ms" through 18,070 underruns.
Quote the cushion with the surplus.

**Derive a rate target from a capture of the stage's own input, and grade a stage against captures from
the pipeline it will sit in.** *(T13.)* A target from the wrong stage, or an input synthesised by stripping
nulls, produced plausible, flatter, wrong tables. Treat an unexpectedly smooth result as a suspect one.

**In a timing rig, assert the process census between legs, and check a file's size against its packet
count.** *(T13.)* Killing a pipeline by its last PID reaped only the groomer; a 17 MB file that censused as
2.4 M packets was the tell.

**A two-host latency figure must bracket its clock, and its correction must be tested.** *(T18, T70.)* A
cell that straddled a 13.94 ms clock step returned a clean 1,018 ms; the re-run read 2,108. Probe offset
before and after each WAN cell. The offset's sign was once applied inverted, reading every WAN cell low
by twice its offset: run the probe against a server shifted by a known amount, through to the report.

**Launch a long-lived remote fixture once, from a locally backgrounded SSH, and have cells probe it.**
*(T18.)* `setsid nohup … &` over SSH blocks until the remote process exits, unless all three of its
standard streams are redirected.

**A sandboxed shell is not the environment.** *(T6, T18.)* A sandbox bound loopback and connected some
clients and not others, and its `ps` missed a running sweep. Run loopback drills and process census from a
host reached over SSH or an unsandboxed shell.

**Sort on the key, not the record.** *(T12.)* Sorting whole tuples ordered tied datagrams by payload and
made 207 phantom continuity errors.

**Any redundancy test whose sources are started independently measures its own clock skew, and its merge
window is the union of the legs' activity.** *(T6, T12.)* Independent replays lag by the join delay, so
"same file" is not "same stream": fan one regulated source into both legs, and let the surviving leg
define the end of the window.

**On a lane that two sources can serve at once, the failure is repeated time, and neither a continuity
nor a PCR-interval check sees it.** *(T6.)* Add a rate-ratio or PCR-decrease count wherever two
publishers, packagers or origins can be live.

**With a shared identity the rig does not choose which publisher serves, so a standby drill must know
which one it killed.** *(T6.)* Start subscribers after both publishers produce, log each publisher
separately, and read which one held the media subscriptions before and after the signal. Record which
signal and which build drove a graceful arm (SIGTERM hard-killed `moq` 0.12.1 and closes cleanly from
0.12.8), and prefer ending the importer's input as the build-independent clean exit.

**A stop condition must fire on the cause, not on a symptom the failure also produces.** *(T27.)* Delivery
below 85 % flagged an OOM-killed subscriber; watch `MemAvailable` directly.

**A broadcast name may not be reused by back-to-back arms.** *(T27.)* The relay keeps an abandoned session
until the idle timeout, and a reused name attaches the next subscriber to it.

**A file source feeding a live transport must be paced, with the reader attached first.** *(T4.)*
Unpaced `tsp -I file` floods UDP and false-fails transports; use `-P regulate --pcr-synchronous`.

**Never put `ffmpeg` in front of MoQ in a carriage path.** *(T3, T4.)* `ffmpeg -c copy -f mpegts` turned a
13-PID slice into 5 renumbered PIDs; `tsp` is byte-identical. If ffmpeg must appear, declare it as a
transcode.

**Separate the contribution session from the thing under test, and take the reference from the last point
the two paths shared.** *(T4.)* Split at local multicast so the outside feed survives rig restarts and gives
a tap on the publisher's input; three readers there captured byte-identical windows, where a second encode
would differ.

**"Blocked" names the apparatus and the host checked, and the constraint that actually binds.** *(T14,
T28, T31.)* Ladders were marked blocked on Linux while Linux hosts had the apparatus. Write *blocked* only
when no host in the estate has it, *not blocked; unverified* when a reachable host has not been checked,
and *not yet run* with the porting cost when it has; do not re-base a ladder on another emulator to make
it runnable.

**A rehearsal from a directory somebody already set up has rehearsed the measurement, not the day.**
*(T33.)* Rehearse from nothing, on a host that has never run the rig; anything it needs and does not build
is an untested precondition.

**A watcher must see a start before it reads an absence, and must not find the previous run's file.**
*(T13, T41.)* Every arm "died" at 1.0 s because the watcher polled before the process existed; a reused
status file ended a run 37 ms after it began. Record appearance as t = 0, and start each run in a fresh
directory.

**A declared CSV column that is never written shifts every field after it.** *(T28.)* Assert the field
count when parsing a self-generated CSV and reconcile one row against the log.

**Never edit a shell script while it is running.** *(T8b P0-i.)* `bash` reads by byte offset, so a rewrite
resumes at the old offset in new bytes. Edit a copy.

**A bare `wait` returns only when the rig's infinite producers do, which is never.** *(T25.)* Wait on the
PIDs the measurement needs, and confirm a previous attempt is dead before re-running.

**A `pgrep` or `pkill` pattern matches every command line that carries it, including the one sending
it.** *(T21, T25, T26, T27, T28, T43, T47, T8b P0-i, the repo-wide rig audit.)* `-f` matches the whole
command line, so a pattern kills the SSH shell or waiter that quotes it while the stale process
survives; twenty patterns keyed on a flag matched nothing after its rename, behind `|| true`, and one
keyed on a tool killed another experiment's detector. Bracket one character (`[t]18-tap-perturb`), and
since a parent argv carrying the literal defeats the bracket, keep reset patterns in a script on the
host run in its own ssh call ([`f5-reset.sh`](scripts/f5-reset.sh)); match the binary and the address it
was given (`[m]oq-relay.*127.0.0.1:$PORT`), scoped to the run's label or output path; verify the reset
(`pgrep -f "[p]attern" && echo STILL RUNNING`); queue a chain as one sequential command or wait on PIDs
and end markers; sample a role by the PID `$!` gave at launch; and check a multi-cell runner after its
first cell.

---

## 6. Claims, and their scope

**A scratch change that fixes the measured case is a fix only once the upstream tests pass with it
switched on.** *(T47.)* Gated behind an environment variable it kept the suite green; switched on, four of
941 tests failed on timeline restarts the rig never exercised.

**A closed issue is a claim about a tracker, not about a binary, and its disposition is in the closing
PR's prose.** *(T13 P1-n, the #3987 round.)* Issues closed by a quest-only PR still reproduced; #2779's
close looked accidental until #3868's body declared it won't-fix. Re-test on closure, read the closing
diff (a PR touching no source fixes no runtime defect), and read its body before inferring intent.

**Read a specification from inside and question it from a deployment outside.** *(The MSFTS review.)*
Three reading passes missed that the retain list never reaches the CAT; a BISS-CA question found it.

**Cite the clause that carries the obligation, not the clause with the famous name.** *(The MSFTS
contribution round.)* PCR clock recovery within tolerance is 13818-9 and TR 101 290, not the idealised
T-STD of 13818-1 §2.4.2.

**Where the artefact is text in a repository, send the text.** *(The MSFTS review.)* Eleven issues in
one day became eleven patches the editor wrote himself; an ask sent as a pull request moves that work to
the reviewer, and a patch that builds is evidence of review. Give several asks a priority order, and
check the tracker for an open issue that already covers half of one before filing it.

**A precise upstream report can be undone by an imprecise in-house paraphrase, and the paraphrase is
what gets cited.** *(T18.)* The issue said "not sparsity", with the mean conserved to 0.7 ms; summaries
said "emits PCRs too rarely" and reached `docs/` and README. Restate the mechanism, not the symptom that
made it visible.

**Pin upstream-report links to a commit on `main`, not to a working branch.** *(T10.)* Branch links 404
after merge: use `blob/<full-sha>/<path>` from the commit holding the cited tree, and recheck after
merge.

**One user of a shared resource measures the uncontended case, and must be labelled so.** *(T37 D2, D7.)*
One subscriber per arm gave a revocation "bound" of one cadence plus 0.110 s; six staggered sessions put
the worst case at 1.54 cadences. Ask what sessions share before quoting a per-session bound.

**Random loss above about 1 % and reorder deeper than three packets are stress cells, not path
models.** *(T28; #5953, declined on this ground.)* Real paths do not lose packets independently of
their load, and QUIC declares a packet overtaken by three lost. T28's 5–10 % loss and 20 % reorder
cells separated SRT from the MoQ lane, and the settings proposed from them were declined. Label such
cells as stress where a claim cites them; rank lanes or settings, and propose upstream, on outage,
congestion and burst-loss cells or a captured path, as upstream's own grading does (#5918).

**A verified hypothesis is not a working mechanism.** *(T39.)* One credential carried both scopes, yet the
shipped tooling could not publish telemetry at all. Name what the test did and did not exercise.

**A defect found through an incidental stimulus is described at that stimulus's level until its class is
characterised.** *(T21, T23.)* "PCR does not survive a source discontinuity" split, graded by class, into
a rollover carried correctly, forward jumps that recover, and rewinds that withhold and burst.

**Conformance of the output is not health of the stage producing it.** *(T21, T22.)* A groomer that had
destroyed its cushion passed every wire check, and a frozen source passed every transport check. Lasting
health needs stage counters and a stated scope.

**Reading source is sound evidence that something is absent and weak evidence that something present
works.** *(T19.)* #2984 rested on `moq-srt` pacing correctly; measured, it fell through to an unpaced arm.
Measure an exemplar, or state that its correctness is assumed.

**A capability claim names the pipeline stage, the input property and the parameter space it covers.**
*(T13, T14, T16.)* "No tool does LL-HLS with TS" was true of receiving and false of publishing; "no stage
grooms a broadcast mux" held only for an egress carrying no stuffing; "no configuration passes" rested on
three parameters, and two more arms found one. A "structurally impossible" claim from a specification is a
hypothesis worth an afternoon: TS segments differed from the source in two PSI packets only.

**Liveness keys on programme content, and the enforcement point is the sender.** *(T12.)* A rate-holding
groomer mints conformant CBR with no programme; exclude its adaptation-only PCR from the content check.

**Every stream-position quantity must be a function of position in the stream, not of what this instance
emitted or saw.** *(T12, T30.)* An RTP sequence that counted datagrams sent left a resumed leg 8,756 behind; sequence,
timestamp and PCR must be stream-derived for redundancy. Two `tsp -O hls` packagers of one source on
two hosts cut 1.2 s apart until their input bitrate was fixed, and one that missed the first tables
numbered its PAT and PMT apart: hash a pair's segments, written apart, before it shares a namespace.

**Pin every parameter the property depends on, then measure; a predicted divergence is no substitute for
one run.** *(T12.)* Ungroomed legs predicted to fail on phase aligned in all twelve cells and failed on
conformance instead.

**Draw the demarcation before comparing two designs, and count only work on the same side of it.**
*(T14.)* A receive-side hand-off in clients' equipment does not discharge the distributor's obligation.

**Name the boundary a defect was measured at, and grade an upstream fix on the deployed chain.** *(T19.)*
PCR clustering fixed inside the exporter survived as clustered positions on its output; #2967 alone would
have taken continuity from 0 to 824 errors and latency from 118 to 769 ms.

**A measurement undefined as a verdict can still be a sound diagnostic if the distribution is what is
read.** *(T19.)* `pcrverify --absolute` on rate-less egress gives no verdict, yet separated varying misses
before a fix from a constant 24,842 µs after.

**Retire a caveat about the instrument by moving the instrument.** *(T19.)* Eight cores read 7.45 %
against two cores' 7.45 % in four minutes; a host-bound caveat is usually cheaper to remove than to
restate.

**A head-to-head is a lane result only on a shared substrate, with packet sizes reported.** *(T5, T20.)*
Reordering 0.98 against 0.19 compared TCP with QUIC and 34,380 B packets with 931 B ones, so `reorder 25 %`
met about 24× fewer events on the winner; normalised, the gap was largely the rig's. List what differed
besides the thing under test, equalise MTU and offloads on every arm, and prove the transport from the
server and the wire: FFmpeg's `-http_version 3only` fetched segments over HTTP/1.1.

**A P1/P2 pass is not a conformant transport stream, and a buffer-model pass is not a complete one.**
*(T44, T47.)* The groomed wire passed P1/P2 for a day while its buffers overflowed throughout; an export
that dropped every MP2, AC-3 and teletext unit passed `ts-tstd.py`, since absent PIDs have no buffer.
Say "P1/P2-conformant" for what was graded, grade the T-STD per PID with the source as control
(`ts-tstd.py --window` where the groomer regenerates PCR), and count every PID's units against the source
over the same span, reading the export's drop log.

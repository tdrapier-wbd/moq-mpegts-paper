# Test 34 — A real encoder against the continuous-source fence

**State: graded on one real step, the feed's contribution switching between two encodes upstream,
unflagged.** None of the nine exits P0-j first captured was a step: each was the standing build of
the time stamping a SCTE-35 section below the one before it, which `main` no longer does, and the
seven-day re-run saw no exit in 169 h. A later ring caught one, on standing units past moq
0.14.0, where a backward step ends the import by design ([Evidence](../docs/evidence.md) §3.13): a
hard switch, at one packet, to a second encode of the service with identical tables and a clock
16,844.6 s behind, with no `discontinuity_indicator`. The import ended on both legs at once and a
subscriber lost 9.8 s of output; a switch the other way, forward, ends the subscriber's export
instead (§ *A switch between two encodes*). The `OLD`/`NEW` fence comparison below is moot by the
same design.

Specified as [P0-j](planned-experiments.md#p0--could-change-a-viability-conclusion). Rig sketch:
[`t27-realfeed-severity.sh`](scripts/t27-realfeed-severity.sh).

## Objective

Determine whether a **real, never-repeating** transport-stream source triggers the per-track
backwards-step fence that [#3533](https://github.com/moq-dev/moq/issues/3533) describes, and **how
severe** the stall is in practice when it does.

**Falsifies:** either the claim that the #3375 regression is a **lab artefact** reachable only from
looped sources, or the claim that current upstream `main` can carry a real multi-track feed at all
([P0-j](planned-experiments.md#p0--could-change-a-viability-conclusion)).

## What is already known, and precisely what it leaves open

**The fence is measured on a manufactured join.** [T27](test-27-liveness-detector.md) bisected to
`0e61e35` (#3375): on `ts-continuous-source.py` — timeline continuous, content restarts every ~30 s —
post-#3375 delivery falls to **0.31 Mb/s** from the first join onward while pre-#3375 parent holds
**9.0–9.8 Mb/s**. A per-PID liveness detector shows a **119.35 s backwards delivered-clock step** on
video and MPEG-1 audio PIDs; parent on the same bytes records **0 discontinuities**. Only PSI, AC-3 and
teletext survive. Mechanism and code path:
[upstream-contributions.md](upstream-contributions.md) § #3375 → [#3533](https://github.com/moq-dev/moq/issues/3533).

**True rewind versus continuous join are opposite cases on the same merge.** Parent pre-#3375 stalls on
`tsp --infinite`; #3375 recovers. Continuous timeline: parent clean, #3375 fenced — the regression
**traded** failures ([upstream-contributions.md](upstream-contributions.md)).

**Single-track immunity is measured.** Video-only source clean on both builds across joins — fence needs
a bystander track ([upstream-contributions.md](upstream-contributions.md)).

**What is not established:** whether a live encoder's audio resync at a **hard cut** (never repeating
content) produces the same backwards step. [T27](test-27-liveness-detector.md) supplies the step at a
*repeat point*; ordinary in broadcast but **manufactured** for the test.

**Upstream has asserted severity without this lab measuring it.** The quest
`quest/m0/3533-ts-export-restart-stall.md` names the trigger as the legacy audio importer re-locking a
frame slightly below its extrapolated high-water after resync, and frames the scenario as *"what a real
encoder produces at a hard cut"*. That is the maintainer agreeing with the severity reading — **strong
support, and still specification-and-code reasoning rather than a measurement on a never-repeating
source** ([P0-j](planned-experiments.md#p0--could-change-a-viability-conclusion)). **The distinction is the whole point of this experiment.**

Until answered: treat pre-#3375 build as the only one **demonstrated** to carry a continuous
multi-track source; no build carries both that and a true rewind — re-confirmed on current `main`
against the continuous reproducer ([T23 § #3533](test-23-pcr-discontinuity-classes.md),
[upstream-contributions.md](upstream-contributions.md)).

## Environment

| | |
|---|---|
| Ingress | Live SRT (or equivalent) contribution into `moq import ts` on `<EC2_IP>`; broadcast name
  `<LIVE_BROADCAST>`. |
| Builds | Side-by-side subscribers: `OLD` = pre-#3375 binary (`025613d` parent), `NEW` = post-#3375 /
  current `main` — same relay, same wall time, build is the only variable
  ([`t27-realfeed-severity.sh`](scripts/t27-realfeed-severity.sh)). |
| Detector | [`ts-liveness.py`](scripts/ts-liveness.py) per subscriber: `--warmup 10 --learn 40` (longer
  learn than clip runs — real feed jitter must not set thresholds that false-alarm). |
| Metrics | Exporter `/proc/<pid>/io` `wchar` rate — low rate means receiving but not muxing, not merely
  a dead process. |
| Duration | Default 3,300 s (~55 min) or until first fence signature; extend if feed is stable. |
| Substitute (weaker) | Genuine **programme junction** between two different sources on one continuous
  timeline — not the same test as never-repeating single encoder, but cheaper than restored SRT if
  available ([P0-j](planned-experiments.md#p0--could-change-a-viability-conclusion)). |

## Procedure

1. **Confirm ingress.** Verify bytes arriving at publisher before MoQ subscribe; attempted run failed
   because catalog announced with **no media** ([P0-j](planned-experiments.md#p0--could-change-a-viability-conclusion)).
2. **Start paired subscribers** via `t27-realfeed-severity.sh <label> <relay-ip> <broadcast> <duration>`.
3. **Sample** every 10 s: Mb/s old vs new, process alive; log liveness JSONL per build.
4. **Watch for fence signature on NEW:** sustained NEW ≪ OLD (order of 0.31 Mb/s vs ~9 Mb/s in T27),
   liveness `-119 s` class delivered-clock step on video/audio PIDs, OLD healthy throughout.
5. **If no fence over duration:** record as *live feed did not arm fence* — severity downgraded to
   loop-only reproducer (still a real defect, narrower deployment claim).
6. **Optional substitute arm:** two-source junction with documented timeline continuity; label results
   separately from single-encoder never-repeat.

Do **not** loop the source; do not use `ts-continuous-source.py` for the primary arm (that is T27's
reproducer, already run).

## Metrics

- **Delivered rate** — Mb/s per build from exporter `wchar` deltas.
- **Per-PID liveness** — outage duration, delivered-clock steps, alarm latency per PID.
- **Continuity and structural** — periodic TSDuck capture if rate collapses; 0 CC on healthy build
  confirms lane not generally broken.
- **Ingress health** — SRT/publisher metrics; stall versus fence discrimination.
- **Time to fence** — if armed, wall time from session start or from identified programme event (cut,
  ad break, source switch).

## Pass criteria, fixed before running

This experiment **does not pass/fail upstream**; it classifies severity:

1. **Both subscribers receive media** for the first 60 s at ≥ 80 % of expected contribution bitrate —
   else ingress failure, cell discarded (not "fence absent").
2. **If NEW delivery drops below 1 Mb/s sustained for ≥ 60 s while OLD stays ≥ 80 % of nominal:** record
   **fence armed on live feed** — supports maintainer severity; current `main` unsuitable for
   multi-track live primary distribution until [#3533](https://github.com/moq-dev/moq/issues/3533) fixed.
3. **If OLD and NEW track within 10 % for full duration:** record **fence not observed on this feed** —
   defect real on continuous reproducer but **not demonstrated on never-repeating encoder**; paper must
   state reachability plainly ([P0-j](planned-experiments.md#p0--could-change-a-viability-conclusion)).
4. **Liveness on NEW must show backwards-step signature** (not merely low rate) to attribute collapse to
   #3533 mechanism rather than unrelated stall.
5. **Substitute junction arm**, if run: same criteria with arm label `junction` — cannot substitute for
   criterion 3 on single-encoder never-repeat.

## Limits, stated in advance

- **One feed, one path.** Does not prove all encoders; documents this encoder / this junction class.
- **P1 observability only.** Does not replace Gate 2 hardware; grades exporter output and liveness, not
  IRD PLL.
- **Build pair must include pre-#3375 parent** — comparing two post-fix builds cannot show regression.
- **Upstream quest is not evidence here.** Maintainer specification supports hypothesis; only this run
  supports *measured severity on live feed*.
- **Contribution schedule is external.** No claim about encoder vendor until a specific sender is recorded
  (model field TBM when known, placeholder `<ENCODER>` in public notebook).

## The live feed

The primary's standing chain (`srt-ingest`, the loopback multicast group, `moq import ts` on
`84b34f54`, restarted by systemd 5 s after an exit) was watched for 14.6 h by
[`live-feed-monitor.sh`](scripts/live-feed-monitor.sh), which records no media: TSDuck's continuity
check on the multicast group, the SRT statistics every 5 min, the units' restart counters every
minute, and every 15 min the bytes a 10 s export of the standing build delivers.

| | |
|---|---|
| Hand-off | SRT: 0 restarts, 2 packets lost in one 5 min interval, 0 dropped; 0 continuity errors on the multicast group |
| Import exits | **3**, each *frame timestamp is below the live edge*, after 2 h 12 min, 4 h 49 min and 3 min on the feed; none in the 12 h since. None falls in an interval with SRT loss or a continuity error |
| Publisher absent per exit | about 6 s, exit to reconnect, then an MP2 resync |
| Egress probe | 55 samples, median 22.4 Mb/s; 4 empty, none at an exit (the probe's own; its stderr is not kept) |
| Import CPU | median 74.9 % of a core; host load median 1.77 of 2 vCPU |

*Measured, P1, the import's log and the hand-off's counters, standing build `84b34f54`, one feed,
14.6 h monitored within about 19 h on the feed.*

**The exits are not the hop's**, and they are not rare: three in 19 h, two of them 3 min apart.
Whether they are the feed's is not shown: this build logs nothing before the error, the monitor
grades continuity, not PCR, and none of the nine exits since captured with the hand-off around them
was a step at all (below). On any build from moq 0.14.0 a real step ends the import alike; its class
decides whether an upstream fix could keep the import across one.

**The export's half (P0-j), fixed before running.** [`p0j-step-watch.sh`](scripts/p0j-step-watch.sh)
runs two roles for 48 h. On the primary, a 60 s ring of the hand-off in RAM, copied to disk 20 s
after each exit of the standing import with the journal around it. On the secondary, a standing
`84b34f54` export of the standing broadcast (`--max-age 2s`), restarted whenever it ends, piped into
[`ts-liveness.py`](scripts/ts-liveness.py) (`--warmup 10 --learn 40`) with its output dropped. A step
is graded when both roles were up across it, on two readings:

1. **The step's class**, from the ring: the PCR and each PID's PTS across the exit, whether a
   `discontinuity_indicator` marks the step (flagged) or nothing does (unflagged), and which PIDs
   step back and by how much.
2. **What the subscriber lost**, per PID: the media gap the liveness detector reports, or, where the
   export ended, the wall time from its last byte to the next export's first. The reference is §3.13
   of the evidence: about 3 s of programme per republish, here on top of the publisher's absence of
   about 6 s.

Neither reading has a pass mark; one graded step answers P0-j, and each further step is a replicate.
A flagged step goes to [#4582](https://github.com/moq-dev/moq/issues/4582), an unflagged one to the
contribution's engineer, and one confined to a single PID to a new issue.

### None of P0-j's nine exits is a step in the feed

*Measured, P1, nine hand-off rings of about 80–95 s and the import's journal, standing build
`84b34f54`, every import exit in the 44.4 h the ring ran on the live feed; the rings replayed
offline through `84b34f54` and through `main` at `0d9e9ff78` (the first four) and `a7b421617` (the
other five).*

The ring stopped after 44.4 h of its 48: an unattended package upgrade restarted the publisher and
`srt-ingest` cleanly, which reset the restart counter the ring stops on. The watch ran all 48 h; one
exit after the ring stopped is not graded. The rig now keys the ring on the unit's invocation, which
every start changes, and restarts an export silent for 10 s as well as one that ends; the re-run
shares [T21](test-21-permanence-soak.md)'s seven-day live arm.

**Reading 1, the class: none of the nine.** No ring has a `discontinuity_indicator`, a continuity
error, a PCR step backward or an interval above 25.1 ms, or a PID whose timestamps step back; in the first, every
packet is synced and audio PTS advances by 0.288–0.320 s a PES, teletext by 0.04 s, video DTS by
0.02–0.04 s, and the host's UDP receive-buffer errors did not move. Each ring holds SCTE-35 traffic
on PIDs 141–143: a `splice_null` every second and cues (`splice_insert`, `time_signal`) each sent
three times about 2.3 s apart. This build stamps each section with the PTS of the latest video PES
header and writes each as its own group. The video is field-coded, a PES every 20 ms with PTS ahead
of DTS by 40–360 ms, so that stamp steps back whenever a reordered picture's header precedes a
section. Replayed through that rule
([`p0j-exit-classify.py`](scripts/p0j-exit-classify.py)), each ring has one send stamped below the
section before it on its PID (in exits 7–9 a second, on PID 143, 2 ms after the first on 141), at
the exit within the second or so that the ring's file names resolve:

| Exit | The send stamped below | Below its predecessor by | Sent after it by | PIDs |
|---|---|---|---|---|
| 1 | a return `splice_insert`'s second send, after a `splice_null` | 0.12 s | 327 ms | 141, 143 |
| 2 | a `splice_null`, after a `time_signal` | 0.10 s | 327 ms | 141, 142 |
| 3 | a `splice_null`, after a `splice_insert` | 0.02 s | 326 ms | 143 |
| 4 | a `splice_insert`, after a `splice_null` | 0.08 s | 329 ms | 141 |
| 5 | a `time_signal`, after a `splice_null` | 0.04 s | 327 ms | 141 |
| 6 | a `time_signal`, after a `splice_null` | 0.08 s | 329 ms | 141 |
| 7 | a `splice_null` after a `splice_insert`, and on 143 the reverse | 0.04 s | 326 ms | 141, 143 |
| 8 | a `splice_insert` after a `splice_null`, and on 143 the reverse | 0.08 s | 329 ms | 141, 143 |
| 9 | a `splice_null`, after a `splice_insert` | 0.10 s | 329 ms | 141, 143 |

Every other section in the nine rings stamps forward. **The replay reproduces each exit at the first
such section**: fed to `84b34f54`'s own import, each ring ends it with the same error; cut 7 packets
before that section the ring reads to the end, cut 3 packets after it the import exits, and that
section is the only packet between the cuts that starts anything. `main`, which has clamped a
section to the live edge since [#3997](https://github.com/moq-dev/moq/pull/3997), reads all nine
rings to the end. Whether the three exits before P0-j were cues is not recorded.

**Reading 2, what the subscriber lost.** At each exit the export ended with the publisher, with no
liveness alarm, and its successor started within 1 s and waited for the publisher, which systemd
restarted 5.1–5.3 s after the exit. At the first the export resubscribed 5.8 s after the exit; its
first byte is not logged, so each exit cost at least 5 s plus the export's start. This build's
export carries none of the SCTE-35 PIDs; the detector reports all three silent.

**The export's own failures, on a build `main` has moved past.** The watch started 46 exports in
48 h. Nine ended with the publisher at an exit. 26 ended on their own after 6 min to 4.5 h (median
54 min), each on *no route can serve the rest of this group* (`old`) then `json: old`: the catalog
defect [#3897](https://github.com/moq-dev/moq/issues/3897), fixed after this build. Ten restarts
failed at once on the same error. Between ends the export skipped 77 evicted groups and failed 268
group resumes; the detector reported 21 gaps of 1.0–2.2 s, 16 of them beside such a warning, and
the export's own PCR stepped back 223 times, by 25 ms to 3 s, where the hand-off's never did. The last export never ended: the upgrade's restart did not close the
publisher's session, the relay moved the export's subscriptions to the replacement when the old
session timed out 31 s later, and the export then received nothing for 3.6 h and logged no error.
That is this build re-splicing onto whatever instance serves the path; on `main` an epochless track
ends at a replacement instead ([upstream ledger](upstream-contributions.md) § *A re-request onto a
live route*). None of this is graded here, and none of it is a new defect.

### The seven-day re-run: no step in 169 h

*Measured, P1, standing build `3c0daa21`, the ring and watch shared with
[T21](test-21-permanence-soak.md)'s seven-day live arm.* The ring, keyed on the import's invocation,
recorded **no event**: the import ran its one invocation for all 169 h. From moq 0.14.0 a backward
step on any track ends the import, so the feed stepped back on none. What it did instead was arrive
damaged eight times, upstream of SRT; once, at 99 h, the import counted a PCR discontinuity without
the indicator and the AC-3 timeline jumped about 16,848 s forward, and the export failed on its
clock check and was restarted. That step is forward and was not captured, since the ring keys on
import exits; by its size and its single unflagged PCR discontinuity it is the switch below.

### A switch between two encodes: the first graded step

*Measured, P1, the ring's five 20 s files around the exit and the journal, standing build
`3c0daa21` on both legs; classified by [`p0j-exit-classify.py`](scripts/p0j-exit-classify.py) and
[`p0j-splice.py`](scripts/p0j-splice.py), replayed through `3c0daa21`; the subscriber's loss from
[T57](test-57-cross-host-timing.md)'s export of the same broadcast on the second host.*

**Reading 1, the class: an unflagged splice of the whole multiplex.** At one packet every PID
changes source. Each of the twelve breaks its continuity counter once, the PSI and SI at their next
packet; the video and the MP2 are cut mid-PES on both sides; the new video's first PES has no
`random_access_indicator` and holds non-IDR slices, so it joins mid-GOP. PAT, PMT, NIT and SDT are
byte-identical either side, versions and CRCs alike. PCR and every PES PID step back together, by
16,844.35–16,844.65 s, and no packet in the ring sets `discontinuity_indicator`; the import counted
it as a PCR discontinuity-indicator error. The TDT, stamped upstream, runs 34.3 s behind the
hand-off before the splice and 23.4 s after, so the two encodes reach us by paths about 11 s apart.
SRT lost nothing, and both legs' imports saw the splice in the same millisecond: it is upstream of
the hand-off.

**The source's bytes alone end the import.** Replayed through `3c0daa21`'s import, cut 7 packets
before the splice or 4 after it, the ring reads to the end; cut 100 after it, the import exits with
the live error, on the teletext's first PES after the splice. The replay lifts every timestamp by
30,000 s first: a fresh import starts at the ring's own clock, from which this step would fall
below zero, and reads it as a jump forward.

**Reading 2, what the subscriber lost: 9.8 s of output.** The export on the second host stopped
writing at the exit, wrote again 9.78 s later, then paused 0.3 s and 0.6 s. The publisher was away
5.3 s, 5 s of it systemd's restart hold-off; the export's supervisor restarted it after 2 s; it
wrote 2.4 s after its tracks were subscribed. A supervisor restarting at the step costs 3–4 s
([Evidence](../docs/evidence.md) §3.13); the difference is the hold-off and the export's restart.

**The switch runs both ways, every day or two.** Both legs' import counters record three such
events in 90 h, each one PCR discontinuity-indicator error on both legs in the same second: back
16,841.17 s, ending both imports and every session a CDN soak held on the feed
([T52](test-52-cdn-relay-fanout.md)); forward 55 h later by 16,844.97 s; back 35 h after that by
16,844.61 s, the one graded here. The import accepts the forward step. The export does not: 7.5 s
after it, it failed on *the source's clock runs +172.5 ppm off ours, past the 30 ppm the output's
may follow*, losing 8.0 s of output with shorter gaps either side, as export 1 did at the forward
jump of about 16,848 s in [T21](test-21-permanence-soak.md). An earlier exit on one leg alone,
19,336 s below, is not of this class and is not classified.

**What it settles.** A real feed does step back, not at a programme junction but where its
contribution switches between two encodes whose clocks are not locked. The switch breaks ISO
13818-1's rule that a timebase change be flagged, so it goes to the contribution's engineer;
upstream's handling of it is by design both ways. Both legs of a 1+1 pair fed by that contribution
fail together, and on this design each backward switch costs every subscriber about 10 s of
programme and each forward one ends every export.

## What actually has to happen for the fence to close, and what therefore will not trigger it

This matters for operating the live feed as much as for running the experiment, and the answer is
counter-intuitive in one place.

**The trigger is a discontinuity in the *content*, not in the *transport*.** The fence needs the
transport timeline to be continuous — PCR, PTS and DTS monotone, continuity counters unbroken, no
`discontinuity_indicator` — while the content restarts. That is the defining difference between
[#3533](https://github.com/moq-dev/moq/issues/3533) and the case #3375 was written to fix, and it has a
consequence worth stating plainly: **a clean contribution feed is the worst case, not the safe one.** A
transport-level break, which sets the discontinuity indicator, gives the fence one of its two exits; a
flawless SRT hop carrying a hard cut gives it neither. So "the SRT hand-off is constant with no issues"
does not protect the feed — it is the precondition under which the defect bites.

**What does and does not qualify:**

| Event | Closes the fence? |
|---|---|
| Steady feed, one uninterrupted encode, no junctions | **No.** Nothing resyncs, nothing steps backwards |
| A hard cut at a programme junction or ad insertion, encoded continuously | **Expected yes** — this is the case the quest calls *"what a real encoder produces at a hard cut"*, and the one this experiment exists to confirm |
| A contribution failover between two sources on one timeline | **Likely yes**, and for the same reason: a content join on a continuous timeline |
| SRT loss beyond the recovery window, or our own `srt-ingest` restart | **Probably not by this mechanism** — a transport gap tends to set the indicator, which is an exit. It may of course break the feed some other way |
| A single-track (video-only) source | **No.** Measured immune on both builds: the fence needs a bystander track |

The qualification on the second row is the honest one: whether a given junction resyncs the *audio*
importer depends on the upstream encoder and splicer, and nothing here has measured a real one. Our own
clip carries three SCTE-35 PIDs, so the service is ad-supported and junctions are certain; whether they
are encoded as hard cuts is not known.

**Two properties make one event sufficient.** The fence is permanent — 0.31 Mb/s with no recovery over
40 minutes — and it is *partial*: PSI, AC-3 and teletext keep flowing while video and primary audio
stop. A receiver locks and shows nothing, and any monitor that asks "is the multiplex present" reports
health. So the operational risk is not an occasional glitch; it is that the feed dies at the first
junction and continues to look alive. **Watch delivered video bitrate at a subscriber, not mux
presence** — which is the [T22](test-22-silent-media-plane-failure.md)/[T24](test-24-partial-media-plane-stall.md)
lesson arriving in production form.

### The two hosts are on opposite sides of the regression, which is a free control

Measured by ancestry rather than assumed: `eab960192`, the build the **primary** runs, does **not**
contain #3375 (merged `0e61e3520`, 2026-09-05); `fd4f5d82e`, the build under test on the **secondary**,
does. Against a real encoder — a non-rewinding source — that puts the pair either side of the defect:

| | Primary (`eab960192`) | Secondary (`fd4f5d82e`) |
|---|---|---|
| #3533 continuous-join fence | **absent** — predates the regression | **present** |
| True-rewind stall that #3375 fixed | present, but a live encoder does not rewind | fixed |
| Also missing on the older build | #3351's PCR-grid slicing, and TDT/TOT carriage | — |

So the primary's older build would be expected to survive a junction the secondary's does not. That
looked like a free `OLD`/`NEW` pair, and it is **no longer needed as one**: the better control has
been run. The older build was never simply better either — it lacks #3351, so its raw egress carries
the worse PCR grid, and a conformance figure from it is not comparable with one from the secondary.

**The one-host version of the control is the instrument, and [T40](test-40-continuous-join-through-srt.md)
has executed it.** The two-host arrangement shares a *source* but not a *machine*, so host, kernel,
core count and contribution path all vary alongside the build. Running both arms on the secondary
from the pinned T27 bisect binaries (`~/t27/bisect/0e61e35` and `025613d`) varies only the build, and
T40 did exactly that through a faithful copy of the SRT ingest chain: the post-#3375 arm stalls
permanently at the first content join (0.31 Mb/s residue), the parent is healthy across four joins,
and the two traces are identical to the hundredth of a Mb/s until the join.

**The builds are therefore free to move.** The control lives in pinned artefacts that no rebuild
touches, so unifying the hosts costs nothing this experiment needed. What T40 leaves for T34 is the
question T40 cannot answer: **whether a real encoder produces this junction at all.** T40's generator
cuts hard at an IDR, which is legitimate but synthetic; only the live feed settles whether the fence
is one production actually meets.

## Corrections

- **The import's exits were read as the feed stepping back.** This file read three exits on *frame
  timestamp is below the live edge* over a clean hand-off as the feed's timeline stepping back. The
  nine exits since captured with the hand-off around them had no step on any PID: each was the
  import stamping a SCTE-35 section below its predecessor (§ *None of P0-j's nine exits is a step in
  the feed*). Method rule: an importer's refusal names what it wrote, not what the source sent;
  classify from the source's bytes, and replay them through the same build cut either side of the
  suspect packet, before attributing a refusal to the source.

# Test 34 — A real encoder against the continuous-source fence

**State: specified, not run.** [#3533](https://github.com/moq-dev/moq/issues/3533) stalls video and
primary audio permanently when one track reports a backwards step on a **continuous timeline** — bisected
to [#3375](https://github.com/moq-dev/moq/pull/3375) in [T27](test-27-liveness-detector.md). The
reproducer manufactures that step at a **content repeat**; whether a **never-repeating live encoder**
ever produces the same step sets how severe the defect is for real primary distribution. This experiment
has not run because the rig's live ingress had no sender attached on the one attempt, and restoring a
contribution feed or a genuine two-source junction is blocked on someone else's schedule.

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

## Why this has not run

**Blocked on access to a live TS source.** The obvious rig was attempted; live ingress had no sender
([P0-j](planned-experiments.md#p0--could-change-a-viability-conclusion)). Restored SRT contribution or a booked programme junction is
required. Cheaper substitutes were listed but deliberately **not** equated to the primary question. Until
this runs, severity for real primary distribution rests on code reasoning ([upstream-contributions.md](upstream-contributions.md))
and the continuous reproducer ([T27](test-27-liveness-detector.md)) — and the planning record requires
keeping that distinction explicit.

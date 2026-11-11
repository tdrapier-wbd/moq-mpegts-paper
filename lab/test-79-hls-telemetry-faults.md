# Test 79 — What a NOC's sources say about the segmented lane's faults

**State: run, each fault twice and a control, then with the counters in CMCD and through CloudFront.** On `t61-epochseg.py` a dead video stops the segmented lane outright: no segment for 61 s, so every source sees only an absence. With a time-bound cut the lane hands the audio on through it, and liveness names the dead video in 3.4 s. CMCD v2's own keys carry an origin outage within 0.2 s and nothing inside the stream; with the receiver's TR 101 290 counters as custom keys they name dead audio in 8 s. CloudFront's real-time logs parse only CMCD version 1, so B-8's v2 keys reach them raw. TR 101 290 catches dead audio in 7–8 s, and per-PID liveness catches every fault.

## Objective

[T32](test-32-observability-survey.md) mapped the segmented lane's faults to what the origin, the playlist, a byte-faithful receiver and the media show, and found the most likely one, a stalled source, invisible to every HTTP-layer signal. Since then the receiver ([B-8](test-30-segmented-distributed-resilience.md), `b8-hls-recv.py`) reports its own telemetry and CMCD v2 (CTA-5004-B), and TSDuck's `influx` plugin reports TR 101 290's error counters live. The question is P1-ak's: for each fault, which of the sources a NOC could watch signals it, how soon, and what CMCD v2 cannot express.

## Environment

The laptop, every process on loopback: `contrib-10m.ts` played in real time (`tsp -P regulate --pcr-synchronous`) into [`t61-epochseg.py`](scripts/t61-epochseg.py) `--pdt`, the segmenter then deployed (2 s epochs, six listed), served by `python3 -m http.server`. [`b8-hls-recv.py`](scripts/b8-hls-recv.py) fetches it with CMCD v2 in request mode (headers) and event mode (interval reports every 5 s) to [`p1ak-collector.py`](scripts/p1ak-collector.py). Its output goes to TSDuck 3.45's `influx --tr-101-290 --interval 1`, posting to the same collector, and to [`ts-liveness.py`](scripts/ts-liveness.py), [T27](test-27-liveness-detector.md)'s per-PID detector, its clock timeout at 6 s, three segment durations: at its 3 s default it alarmed on a shakedown control, because the receiver hands on whole segments, up to 3.1 s apart. Rig: [`p1ak-telemetry.sh`](scripts/p1ak-telemetry.sh), 170 s an arm, the receiver joining 10 s after the source and the fault 50 s after it.

| Arm | Fault | From |
| --- | --- | --- |
| control | none | the null |
| video | the video PES suppressed for 60 s, its PCR kept ([`ts-partial-stall.py`](scripts/ts-partial-stall.py)) | T24 |
| audio | both audio PES suppressed for 60 s | T24 |
| stall | `SIGSTOP` on the segmenter for 30 s | T22's segmented arm |
| origin | the origin stopped for 30 s | T32's second row |

## Sources and signals

- **Receiver log** (B-8's JSON lines): an _explicit_ signal is a `pl-fail`, `seg-retry`, `seg-lost`, `msn-skip`, `msn-regress` or `discontinuity` record.
- **CMCD v2 event mode**: explicit is an `e` (error) record, a play state of rebuffering or fatal, or a response record whose status is not 200.
- **TR 101 290** (TSDuck): explicit is any error counter (severities 1–3) rising between two reports.
- **Per-PID liveness**: explicit is an `alarm`.
- A _derived_ signal is an absence a monitor would have to time itself: no new segment in the receiver's log, no response record for a segment in CMCD, no TR 101 290 report, each for more than three segment durations (6 s).

Detection time is from the fault's onset at the source (the wall time of the source's first byte plus 50 s) to the signal's own timestamp: the record's time for the log and CMCD, the collector's arrival time for TR 101 290, the line's arrival for liveness.

## Pass criteria, fixed before running

1. **Validity.** The control raises no explicit signal in any source from 25 s after the receiver joins to the end (startup, before any detector has learned the stream, excluded), and no derived one. A source that does is reported with its false positives, and its detections on the faults are not credited.
2. **Per fault and source:** detected or not, explicit or derived, the time, and the signal. Not detected means nothing by the fault's end plus 10 s.
3. **CMCD's reach:** the faults with no explicit CMCD record, and for each detected fault the keys that carried it.
4. **Repeats:** each fault arm runs twice; a detection time that differs by more than one segment duration (2 s) between the two is reported as unstable, not averaged.

_Predicted_, from T22, T24 and T32: the stall gives no explicit signal anywhere until the segmenter resumes, only the derived absences; the origin outage is explicit in the receiver and in CMCD within a second, and in TR 101 290 as continuity errors at the hole; video and audio suppression is seen by per-PID liveness alone, so CMCD cannot express either.

## Results

All nine graded runs completed ([`p1ak-grade.py`](scripts/p1ak-grade.py)). Seconds from the fault's onset, the two runs of each arm; _d_ marks a derived signal, an absence timed at 6 s:

| Fault | Receiver log | CMCD v2 | TR 101 290 | Per-PID liveness |
| --- | --- | --- | --- | --- |
| Video PES dead 60 s | _d_ 5.96, 5.92 | _d_ 5.95, 5.90 | _d_ 5.95, 5.91; `PTS_error` 63.19, 63.24 | clock stopped 6.05, 6.01 |
| Audio PES dead 60 s | none | none | `PID_error` (both PIDs) 7.01, 6.97 | no access unit 3.39, 3.61 |
| Segmenter stopped 30 s | _d_ 5.77, 5.87; `msn-skip` 30.21, 30.30 | _d_ 5.76, 5.85; `e` `msn-skip` 30.21, 30.30 | _d_ 5.76, 5.86; continuity 33.38, 33.45 | clock stopped 5.85, 5.95 |
| Origin stopped 30 s | `pl-fail` 0.20, 0.02 | `rr` `rc=0`, `e` `pl-fail`, `ps` `sta=r`: 0.20, 0.02 | _d_ 5.93, 5.75; continuity 33.39, 33.38 | clock stopped 6.02, 5.84 |

**The video arm stopped the segmenter.** It cuts only at a random-access picture, and with the video suppressed none came: no segment closed for 61 s, then one of 76 MB carried the whole minute of audio, teletext and SCTE-35 at once. Every source therefore saw the absence, and liveness named the dead video (`no access unit`) only when that segment arrived. The stall and the outage each ended in a jump in the media sequence (`msn-skip`) and 11–12 continuity errors where the receiver resumed at the live edge.

1. **Validity holds.** The control raised nothing in any source, explicit or derived, so every source's detections are credited. A shakedown control, not graded, had found two defaults wrong: `tsp` batching its input reported every 6–8 s, and liveness at 3 s.
2. **Per fault and source:** the table.
3. **CMCD's reach:** an explicit record for the origin outage at 0.02–0.20 s (`rc`, `ec`, `sta`) and for the stall only on resumption (`ec`); none for video or audio. B-8 declares rebuffering only on a failed fetch and sends no buffer level, so a frozen playlist reaches CMCD only as missing records.
4. **Repeats are stable:** no pair differs by more than 0.4 s.

_Prediction:_ held for the stall and the outage. It failed for both partial stalls: dead video became a total stall that every source saw, and TR 101 290 caught dead audio, which T24 had recorded as moving no counter (corrected there).

### A segmenter that also cuts at a time bound (criteria fixed before the first run)

[`t79-epochseg.py`](scripts/t79-epochseg.py) is `t61-epochseg.py` plus one rule: a segment that no random-access point has closed closes at the first PCR packet 1.9 s into the next epoch, in content time read as the PCR plus the last video PES's PTS lead, so two packagers reading one feed cut the same packet. The bound must exceed the clip's longest wait for a random-access point (1.2 s) plus the lead's swing between adjacent frames, and stay under the 2 s epoch so that the numbers stay consecutive. On files first, any failure stopping the rig:

1. **Silent on healthy video:** on the clip, the copy writes the segments `t61-epochseg.py` writes, by name and digest, and cuts nothing at the bound.
2. **Cuts through dead video:** on the clip with its video suppressed for 60 s from 50 s (the video arm's stimulus), `t61-epochseg.py` closes no segment across the suppression and the copy closes one every epoch, and the copy's segments concatenate to its input from its first segment on.
3. **Deterministic:** a second instance reading the same file from a later point, once before the suppression and once inside it, writes the same digest for every K both write.
4. **The rig:** the control and the video arm twice, the copy in place of `t61-epochseg.py`, nothing else changed. **Valid** if the control raises nothing (criterion 1 of the first run) and cuts nothing at the bound. **Pass,** P1-ak's done-when (the audio delivered through the suppression): in both video runs, from the onset to the end plus 10 s, the receiver logs a new segment at least every 6 s, and per-PID liveness raises no clock alarm and none on either audio PID, and raises one on the video PID. Each source's first signal and the repeats are graded as in the first run.

_Predicted:_ dead video reads by cause, in liveness (`no access unit`) and TR 101 290 (`PTS_error`), within a few seconds, and is absent from the receiver log and CMCD.

**Results.** All four criteria hold.

1. **Silent:** on the whole clip the copy wrote the same 298 segments as `t61-epochseg.py`, by name, duration, size and digest, and cut nothing at the bound. The bound first cut healthy video at 1.0 s (8 of 298 segments) and never from 1.2 s, so 1.9 s has at least 0.7 s in hand on this clip.
2. **Cuts through dead video:** `t61-epochseg.py` wrote one 61.1 s segment of 76 MB and then skipped 30 numbers. The copy cut 29 segments at the bound, each about 2 s, its numbers consecutive, and its segments concatenate byte for byte to its input.
3. **Deterministic:** the copies started at 30 s and inside the suppression at 70 s shared 83 and 44 numbers with the first (29 of the first set cut at the bound), every digest identical. The later one cut nothing until the video returned.
4. **The rig:** the control raised nothing in any source and cut nothing at the bound. In both video runs, the receiver logged 38 segments from 5 s before the onset to 10 s after the end, the longest wait 3.6 s. Liveness alarmed only on the video PID (`no access unit`, 3.37 and 3.35 s) and on neither audio PID, with no clock alarm.

**On the live feed, criteria 1 and 3 before it replaced `t61-epochseg.py` on both HLS edges.** For 12 min on each origin host, beside the packager it would replace on the same multicast group, the copy wrote 359 segments, each identical to that packager's by number, duration, size and digest, and cut nothing at the bound. The longest wait for a random-access point was 1.19 s (median 0.51 s), 0.71 s inside the bound; the 358 numbers both hosts wrote are identical. [`seg-units.sh`](scripts/seg-units.sh) now installs it.

| Dead video, 60 s | Receiver log | CMCD v2 | TR 101 290 | Per-PID liveness |
| --- | --- | --- | --- | --- |
| `t61-epochseg.py` (above) | _d_ 5.96, 5.92 | _d_ 5.95, 5.90 | _d_ 5.95, 5.91; `PTS_error` 63.19, 63.24 | clock stopped 6.05, 6.01 |
| With the time-bound cut | none | none | `PTS_error` 62.18, 62.07 | `no access unit` 3.37, 3.35 |

_Prediction:_ held for liveness, the receiver log and CMCD. It failed for TR 101 290, which counts `PTS_error` only when the video returns, not while none arrives.

### TR 101 290 counters in CMCD (criteria fixed before the first run)

The receiver now carries TSDuck's counters as CMCD custom keys (`--ts-counters`): each priority's running total on every request and interval report (`tr101290-p1`, `-p2`, `-p3`), and an error record naming each counter that rises between two of TSDuck's reports (`ec` `tr101290-<counter>`). TSDuck posts to the receiver, which forwards each post unchanged to the collector, so the TR 101 290 column is graded as before. Offline, [`b8-cmcd-test.py`](scripts/b8-cmcd-test.py) passes and fails three broken copies: one counting a per-PID line, one raising an error for a counter already raised in the first report, one whose listener fails a report. The rig as above with `TS_PORT` set and `CMCD=query`, so request mode reaches the origin's log, on `t61-epochseg.py`: the control once, the audio and origin arms twice each.

1. **Validity.** The control raises no `tr101290-` error record from 25 s after the join, and every request after TSDuck's first report carries the three keys.
2. **Carriage.** Each rise the TR 101 290 column records in a fault's window has its CMCD error record naming the counter within 1.5 s of the forwarded report (the receiver batches records up to a second), and CMCD names no counter the column lacks.
3. **Reach.** CMCD's column re-graded: which faults it now carries explicitly, and when.

_Predicted:_ dead audio as `tr101290-pid_error` at about 7 s; the origin outage as `tr101290-continuity_count_error` on resumption, about 33 s, after the `pl-fail` CMCD already had; the control nothing.

**Results.** All three criteria hold.

1. **Valid:** the control raised no `tr101290-` record, nor anything in any source. Every request after TSDuck's first report, 541–678 a run, and every interval report carried the three totals.
2. **Carriage:** every rise the TR 101 290 column recorded has its CMCD error record, stamped within 2 ms of the forwarded report and reaching the collector 1.0 s later, the receiver's batching; CMCD named no other counter. TSDuck's reports reached the collector within 17 ms of their own timestamps.
3. **Reach:** dead audio, which CMCD's own keys never named, now reaches it by cause.

| Fault | CMCD v2, first explicit | Counters CMCD names | TR 101 290 | Per-PID liveness |
| --- | --- | --- | --- | --- |
| Audio PES dead 60 s | `tr101290-pid_error` 8.10, 8.18 | `pid_error`, `pts_error` | `PID_error` 8.10, 8.18 | `no access unit` 2.20, 2.05 |
| Origin stopped 30 s | `pl-fail` or `rr` `rc=0`: 0.19, 0.08 | `continuity_count_error`, `pcr_error`, `pcr_discontinuity_indicator_error` on resumption | continuity 32.26, 32.30 | clock stopped 6.02, 6.00 |

Against the first runs, TR 101 290 reported dead audio 1.1 s later and liveness 1.3 s sooner, alike in both repeats; routing the reports through the receiver accounts for at most 17 ms of it.

_Prediction:_ held, dead audio a second later than predicted.

### Through CloudFront: which keys reach the real-time logs (criteria fixed before the first run)

A second distribution beside the soak's, whose one behaviour a viewer-request function answers (200, no body, no origin reached), logs every request to Kinesis with CloudFront's dedicated CMCD fields, the query string and the request headers. The keys are B-8's own: every request of the offline test's counters run (a lost segment, a retried one, both TSDuck reports), captured at its local origin in each form and replayed in order from the laptop, each request's index in its path.

1. **Validity.** A CMCD v1 request with keys CloudFront documents (`br`, `bl`, `cid`, `d`, `ot`, `sid`, `v=1`) fills those dedicated fields, and a request with no CMCD fills none; otherwise void.
2. **Reported,** per key B-8 sends and per form: whether a dedicated field carries it and with what value, and whether it reaches the log raw, in `cs-uri-query` or `cs-headers`, byte for byte.
3. **Complete:** every replayed request appears in the log once.

_Predicted:_ the dedicated fields are CMCD v1's, so the keys v2 shares with v1 fill them and v2's own (`sn`, `ltc`, `msd`) and the custom keys reach the log only raw.

**Results.** Valid and complete; B-8's v2 keys reach the log only raw. [`p1ak-cf-cmcd.py`](scripts/p1ak-cf-cmcd.py) captured 83 requests a form and replayed them through one London edge, into a distribution, log configuration and stream created for the run and deleted after it. A diagnostic arm, added after the first look and not a criterion, replayed each request again with its `v=2` removed, which CMCD reads as version 1.

1. **Valid:** the v1 control filled its seven fields with the values sent, in both forms, and the request without CMCD filled none. Every record's edge and status matched its response's. A first replay was void: its reader took the fields in the configuration's order, which CloudFront does not keep.
2. **Reported:**

| B-8's requests, either form | Dedicated fields filled | Raw, byte for byte |
| --- | --- | --- |
| As sent, `v=2` | none, for any key | every request, in `cs-headers` or `cs-uri-query` |
| `v=2` removed (diagnostic) | every key v1 defines, with the value sent (`bs`, `cid`, `d`, `mtp`, `ot`, `sf`, `sid`, `st`, `su`), and `cmcd-version` 1; not `nor`, which v2 writes as a list | every request |

`sn`, `ltc`, `msd` and the three `tr101290-` totals have no field and reach the log only raw; their presence does not stop the v1 keys parsing.

3. **Complete:** 335 of 335 requests logged once.

_Prediction:_ failed. The keys v2 shares with v1 fill no field when the payload says `v=2`: CloudFront parses only version 1, so a v2 sender's keys reach a NOC through these logs only by parsing the raw field.

## Conclusions

1. **A segmenter that cuts only at random-access points amplifies a dead video into a dead service**, where [T24](test-24-partial-media-plane-stall.md) found the media-aware lane contains it. One that also cuts at a content-time bound contains it too: the audio goes on, and every packager cuts the same segments.
2. **CMCD v2's own keys express a transport fault at once and nothing inside the stream; the receiver's TR 101 290 counters, as custom keys, add what TSDuck sees.** Dead audio then reaches CMCD by cause, and a continuity hole on resumption. A stalled source still appears only as records that stop; a buffer level, which B-8 does not send, would carry it. **Through CloudFront none of it reaches a dedicated field**: the real-time logs parse only CMCD version 1 and keep a v2 payload raw.
3. **TR 101 290 at the receiver gives the cause for dead audio** (`PID_error`) and marks a hole on resumption, but reports nothing while its input is stopped.
4. **Per-PID liveness detects every fault**, dead audio in 2.1–3.6 s, dead video in 3.4 s once the segmenter cuts at a bound, and the rest at its 6 s clock timeout. Its timeout must exceed the gap between segment deliveries, since an ungroomed receiver hands on whole segments.
5. **For a NOC**, three faults are named by cause: the origin outage within 0.2 s, dead audio within 2.1–8.2 s (liveness, then TR 101 290 and CMCD with its counters), and, with the time-bound cut, dead video within 3.4 s (liveness alone). Without the cut, dead video reads only as an absence, as does a stalled source, timed at three segment durations or more; the stalled source has no explicit signal in any source until it resumes, as [T32](test-32-observability-survey.md) found at the origin.

## Limits, stated in advance

- One clip and a local origin; CloudFront saw one run's requests replayed through one edge, not a session through it.
- TSDuck reports TR 101 290 counters, not a vendor probe's alarms; P2-a's survey asks the vendors.
- The counters ride in custom keys no specification defines, so a collector must know their names.
- The campaign's own segmenter alone, in its two variants, and no groomer after the receiver: the deployed lane grooms before the IRD, which smooths what TR 101 290 and liveness see.

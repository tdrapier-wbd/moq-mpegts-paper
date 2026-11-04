# Test 79 — What a NOC's sources say about the segmented lane's faults

**State: run, each fault twice and a control; P1-ak's telemetry half.** Its CloudFront half waits on B-7. On this segmenter a dead video stops the segmented lane outright: no segment for 61 s, so every source sees only an absence. CMCD v2 carries an origin outage within 0.2 s and nothing inside the stream; TR 101 290 catches dead audio in 7 s, and per-PID liveness catches every fault.

## Objective

[T32](test-32-observability-survey.md) mapped the segmented lane's faults to what the origin, the playlist, a byte-faithful receiver and the media show, and found the most likely one, a stalled source, invisible to every HTTP-layer signal. Since then the receiver ([B-8](planned-experiments.md), `b8-hls-recv.py`) reports its own telemetry and CMCD v2 (CTA-5004-B), and TSDuck's `influx` plugin reports TR 101 290's error counters live. The question is P1-ak's: for each fault, which of the sources a NOC could watch signals it, how soon, and what CMCD v2 cannot express.

## Environment

The laptop, every process on loopback: `contrib-10m.ts` played in real time (`tsp -P regulate --pcr-synchronous`) into [`t61-epochseg.py`](scripts/t61-epochseg.py) `--pdt`, the deployed segmenter (2 s epochs, six listed), served by `python3 -m http.server`. [`b8-hls-recv.py`](scripts/b8-hls-recv.py) fetches it with CMCD v2 in request mode (headers) and event mode (interval reports every 5 s) to [`p1ak-collector.py`](scripts/p1ak-collector.py). Its output goes to TSDuck 3.45's `influx --tr-101-290 --interval 1`, posting to the same collector, and to [`ts-liveness.py`](scripts/ts-liveness.py), [T27](test-27-liveness-detector.md)'s per-PID detector, its clock timeout at 6 s, three segment durations: at its 3 s default it alarmed on a shakedown control, because the receiver hands on whole segments, up to 3.1 s apart. Rig: [`p1ak-telemetry.sh`](scripts/p1ak-telemetry.sh), 170 s an arm, the receiver joining 10 s after the source and the fault 50 s after it.

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

## Conclusions

1. **On this segmenter the segmented lane amplifies a dead video into a dead service**, where [T24](test-24-partial-media-plane-stall.md) found the media-aware lane contains it. A segmenter that also closes a segment at a time bound would hand the audio on; to build and re-run once T76's soak, which runs this segmenter, ends.
2. **CMCD v2, as B-8 sends it, expresses a transport fault at once and nothing inside the stream.** A dead elementary stream, a continuity hole and a stalled source are not CMCD's to say: the last two appear only as records that stop. A buffer level, or TS counters in custom keys, would carry them; neither is sent.
3. **TR 101 290 at the receiver gives the cause for dead audio** (`PID_error`) and marks a hole on resumption, but reports nothing while its input is stopped.
4. **Per-PID liveness detects every fault**, dead audio in 3.4–3.6 s and the rest at its 6 s clock timeout. Its timeout must exceed the gap between segment deliveries, since an ungroomed receiver hands on whole segments.
5. **For a NOC**, two faults are named by cause: the origin outage within 0.2 s, dead audio within 3.4–7 s (liveness, TR 101 290). Dead video and a stalled source read only as an absence, timed at three segment durations or more; the stalled source has no explicit signal in any source until it resumes, as [T32](test-32-observability-survey.md) found at the origin.

## Limits, stated in advance

- One clip, a local origin and no CDN: the CloudFront half (which CMCD keys reach the real-time logs) waits on B-7.
- TSDuck reports TR 101 290 counters, not a vendor probe's alarms; P2-a's survey asks the vendors.
- The receiver reports no TS-level counters in CMCD (B-8's custom keys are not built), so CMCD's reach is that of the keys CTA-5004-B defines.
- One segmenter, the campaign's own, and no groomer after the receiver: the deployed lane grooms before the IRD, which smooths what TR 101 290 and liveness see.

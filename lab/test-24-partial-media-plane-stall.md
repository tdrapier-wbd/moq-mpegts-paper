# T24 — a partial media-plane stall: half the programme stops, every check stays green

> **State: complete. Four arms, one of them a control.**
>
> **The lane contains a partial failure rather than amplifying it, and that is the load-bearing
> result.** With the video elementary stream dead for a minute, audio, subtitles, SCTE-35 and the
> PSI tables all ran without a single interruption, the carrier held **11,001,354 b/s** against the
> control's 11,001,940, and continuity stayed at **zero errors**. One dead stream stayed one dead
> stream. A demuxing carriage layer had the opportunity to turn a dead track into a dead service —
> by waiting on a track that would never arrive — and it did not take it.
>
> **[T22](test-22-silent-media-plane-failure.md)'s recommended detector fails outright.** Across a
> **57.22 s** hole in the video, PCR progression, continuity, PCR repetition and PCR accuracy are all
> green: **0 continuity errors, 0 intervals over 40 ms, worst interval 30.080 ms**, identical to the
> control. The entire TR 101 290 P1 set passes over a service with no pictures in it. T22 concluded
> that "PCR progression is the detector to build on"; against the failure mode most likely to occur —
> an encoder whose video path dies behind a running mux — **that conclusion is wrong**, and T22's
> recommendation is corrected here.
>
> **What does detect it is the stuffing ratio, and its sensitivity is proportional to the dead
> stream's share of the mux.** Losing the video took stuffing from **13.7 % to 95.2 %**, which fired
> within a second and cannot be mistaken for anything else. Losing both audio streams and the
> subtitles took it to a peak of **27.0 %** — against a **control that peaks at 27.1 %**. The same
> detector that is unmissable for video cannot see audio at all.
>
> **Only per-stream liveness catches every arm.** Counting access units per PID found every outage in
> every arm, at its true length, and fired nothing on the control. It is not a P1 check and it is not
> what the campaign has been recommending.
>
> **One upstream asymmetry.** `moq import ts` logs a warning when the *audio* parser loses frame sync,
> so the audio arms are visible in the publisher's own log. There is **no equivalent for video**: a
> 57 s absence of video access units produced nothing. Because the importer already parses the
> elementary streams in order to demux them, this is a signal a media-aware publisher is uniquely
> placed to emit and currently does not.

## Objective

[T22](test-22-silent-media-plane-failure.md) removed a whole feed and timed how long each candidate
detector took to notice. It closed with a limit it could not address:

> `SIGSTOP` freezes a process cleanly. A real encoder that stalls may half-work — emitting some tracks
> and not others, or emitting stale timestamps — and this experiment does not cover partial stalls.
> That is a materially different failure and the detectors above are not obviously sufficient for it.

They are not obviously sufficient for a structural reason. **PCR rides on the video PID** in this clip
as in most — PID 111 here, carrying both the video and the programme clock. An encoder whose video
path has died while its mux and clock keep running therefore emits a perfectly healthy PCR over no
pictures at all, and every timing check in TR 101 290 P1 is a check on that PCR. The detector the
architecture's observability case rests on is defeated by the failure mode a broadcaster is most
likely to meet.

Two questions, and the second matters more than the first:

1. **Is a partial failure observable anywhere in the delivered stream?**
2. **Does the lane contain it or amplify it?** This is the one that could count against the
   architecture. Opaque carriage cannot amplify a partial stall, because it does not know what a
   track is; a demuxing lane reassembles a mux from tracks, and a mux that waits for a track that
   will never arrive converts one dead elementary stream into a dead service. That would be
   *worse* than not detecting it.

## Method

**The stimulus is built, not injected, and it is graded before it is used.** `SIGSTOP` cannot produce
a partial stall — it stops everything. `lab/scripts/ts-partial-stall.py` suppresses chosen elementary
streams for a window timed on the stream's **own PCR**, so a run is deterministic however fast the
pipe is drained, and substitutes null packets so the mux rate is unchanged to the byte.

Two properties are preserved deliberately, and the experiment would be worthless without them:

- **The continuity counters stay legal across the suppression.** A counter that jumped would be caught
  by any P1 check, which would make the failure trivially detectable and the result an artefact of the
  tool. Each suppressed payload packet decrements a per-PID adjustment applied to everything
  subsequently emitted on that PID; the adjustment is applied *after* the decrement, which is what
  makes the adaptation-field-only PCR packets repeat the last payload counter instead of advancing it.
  A packet with no payload must not increment (ISO 13818-1 2.4.3.3), and one that did would itself be
  the alarm.
- **The stream resumes on a PES boundary**, so a decoder resumes at the start of an access unit rather
  than inside one, as a real encoder coming back would.

**The stimulus grades as healthy.** Two-pass check of the full clip against the unmodified original:

| | control | `video` mode |
|---|---|---|
| packets | 3,967,645 | **3,967,645** — identical, rate preserved to the byte |
| PCRs | 24,574 | **24,574** — every one preserved |
| worst PCR interval | 24.951 ms | **24.951 ms** |
| continuity errors (own grader **and** TSDuck) | 0 | **0** |
| `pcrverify --absolute --jitter-max 500` | pass | **pass** |
| video access units | 19,629 | 17,609 |
| hole in PID 111 | none | **60.02 s at t=30.0** |

So before MoQ is involved at all, the stimulus is a stream that no P1 check can distinguish from a
healthy one and that is missing a minute of pictures. That is the premise the experiment needs, and
it is measured rather than assumed.

### Arms

| Arm | Suppressed | Represents |
|---|---|---|
| `control` | nothing | the null — a detector that fires here is useless |
| `video` | PID 111 payload, **its PCR kept** | encoder's video path dead, mux and clock alive |
| `audio` | PIDs 121, 123, 131 | audio and subtitle paths dead, video and clock alive |
| `es` | 111, 121, 123, 131 | the extreme: a clock and a programme description, no programme |

`audio` suppresses the subtitle stream along with the two audio streams because it targets every
non-video elementary stream; it is "everything but the video", not "the audio" strictly.

### Environment

- **Host:** EC2 secondary, `c6in.2xlarge`, 8 vCPU / 15 GB, `eu-west-1b`. Loopback; the question is
  what the delivered stream contains, not what a path does to it.
- **Build:** merged upstream `main` — `moq` 0.10.0 / `moq-relay` 0.14.15, the same build as
  [T21](test-21-permanence-soak.md)'s 24 h soak, so the two are comparable — with `mpegts-pacer` from
  `5ab84cd`.
- **Chain:** `ts-partial-stall.py` → `tsp -P regulate --pcr-synchronous` → `moq import ts` → relay →
  `moq export ts --latency-max 500ms` → `mpegts-pacer - 11000000 --latency-ms 1000 --max-latency-ms
  2500 --stall-ms 1000 --on-stall mute` → captured to disk.
- **Rig:** `lab/scripts/t24-partial-stall.sh`, graded by `lab/scripts/t24-grade.py`.
- 150 s per arm: ~27 s healthy, 60 s suppressed, ~60 s recovered.

**The output is captured and graded offline, unlike T22.** T22 was timing a detector and needed a
live observer. Here the question is what the delivered stream *contains*, per elementary stream and in
media time, and a capture answers that exactly — 195 MB an arm, graded then discarded.

**A note on concurrency.** These arms ran on the same host as T21's 6 h per-role memory run, on a
separate port and broadcast. The window is recorded there so the memory fit can exclude it; at 11 Mb/s
on an 8-vCPU host at load 0.79 the interaction is negligible, but it is stated rather than assumed.

## Results

### The whole-stream checks — every one an operator already has

| | `control` | `video` | `audio` | `es` |
|---|---|---|---|---|
| packets delivered | 1,088,619 | **1,088,570** | **1,088,626** | 668,010 |
| mux rate | 11,001,940 b/s | **11,001,354 b/s** | **11,000,344 b/s** | 6,804,652 b/s |
| continuity errors | 0 | **0** | **0** | **0** |
| PCRs | 10,234 | 8,523 | 9,680 | 6,218 |
| PCR intervals > 40 ms | 0 | **0** | **0** | 1 |
| worst PCR interval | 30.080 ms | **30.080 ms** | **30.080 ms** | 57,521 ms |
| backward PCR steps | 0 | **0** | **0** | 1 |
| session / transport | silent | **silent** | one publisher WARN | one publisher WARN |

The `video` and `audio` columns are the result. **Every check is green and one of them is measuring a
service with no pictures in it.** The carrier is within 600 b/s of the control's, continuity is
perfect, PCR repetition is comfortably inside the 40 ms limit and the worst interval is identical to
the control's to three decimal places.

The `es` arm behaves completely differently and for a configured reason: with no content at all the
groomer's stall timer expired and `--on-stall mute` stopped the carrier, which is the policy T22
measured. That took the PSI tables down with it — PID 100 has a 59.42 s hole — so the total-loss case
*is* detectable, by the absence of bytes, and is not the interesting one.

The session-state readings were compared with the arm name and connection ids normalised away, so that
two runs differing only in their broadcast name compare equal. On that basis `control` and `video`
produce **identical** sets of log lines. The transport has nothing to say about a dead video stream —
consistent with T22's central finding, now extended from a total stall to a partial one.

### Per-stream liveness — the question those checks cannot answer

Access units per PID, in media time, with holes longer than 2 s reported:

| PID | stream | `control` | `video` | `audio` | `es` |
|---|---|---|---|---|---|
| 111 | AVC video (+PCR) | live | **57.22 s hole** | live | 58.61 s hole |
| 121 | MPEG-1 audio | live | **live** | 59.79 s hole | 59.30 s hole |
| 123 | AC-3 audio | live | **live** | 60.53 s hole | 59.88 s hole |
| 131 | teletext | live | **live** | 59.63 s hole | 60.31 s hole |
| 100 | PMT | live | live | live | 59.42 s hole |
| 141–143 | SCTE-35 | live | live | live | 59.2 s hole |

This is the containment result stated exactly. In the `video` arm, **every stream other than the
video ran without an interruption longer than two seconds** — including the SCTE-35 splice tables,
which matter for a downstream ad system, and the PSI, which matters for tuning. In the `audio` arm the
video ran clean throughout. The lane degrades to precisely the streams that failed.

The delivered outage is **57.22 s against 60.02 s injected**: the lane's own buffering returned 2.8 s
of it. That is the same order as the **1.81–1.92 s** T22 measured for the groomer's cushion plus the
exporter's `--latency-max`, and the residue is noted below rather than explained away.

### Which detectors actually fire

Stuffing ratio is measured per second of media time at the graded output; the steady state is taken
after the cushion has filled and before the injection.

| Detector | `control` | `video` | `audio` | Verdict |
|---|---|---|---|---|
| session / transport | silent | **silent** | WARN, on recovery | fails for video |
| carrier present | yes | **yes** | **yes** | fails |
| continuity | 0 | **0** | **0** | fails |
| PCR repetition / accuracy (P1) | pass | **pass** | **pass** | **fails** |
| **stuffing ratio** | 13.8 %, peak 27.1 % | **13.7 % → 95.2 %, fires t=27** | peak **27.0 %** | works for video, **fails for audio** |
| **groomer underruns** | 0 | **406,850** | **0** | works for video, fails for audio |
| groomer `content_gap_max_ms` | 201 ms | 200 ms | 199 ms | fails |
| groomer stall / mute | 0 / 0 | **0 / 0** | **0 / 0** | fails |
| **per-stream access units** | none | **57.22 s** | **60.53 s** | **works everywhere** |

Three things follow, and the middle one is the one that would be missed by reading the video column
alone.

**The stuffing ratio is an excellent detector for a large stream.** 13.7 % to 95.2 %, inside one
second of the outage reaching the output, with a control that never moves more than 13 points. It
needs nothing from MoQ, nothing from the groomer and no cooperation from the sender — it is a property
of the bytes, which is the quality T22 valued in PCR progression and which PCR progression turns out
not to have. Its floor is one second only because that is the measurement bucket.

**The same detector is blind to a small stream.** The two audio streams and the subtitles together are
about 440 kb/s of a 9.5 Mb/s programme. Removing them moved the peak stuffing ratio to 27.0 % against
a control whose own peak is 27.1 % — the two are not separable, and the "fires at t=41" reading is an
artefact of a noisy series crossing a threshold 13 s late rather than a detection. **A stuffing-ratio
alarm sensitive enough to catch a dead audio stream would false-positive on healthy variable-bitrate
video.** The detector's sensitivity is proportional to the dead stream's share of the mux, and that is
a property of the measurement, not of this lane.

**The groomer's underrun counter is a strong second detector for the same case and no help for the
other.** 406,850 underruns against zero on the control, because with the video gone the groomer had
nothing to release and emitted stuffing instead. It says nothing about the audio arm, for the same
proportional reason.

### Recovery

Every arm recovered without operator action and without damage:

| Arm | Streams back | Continuity errors on resume | Dropped | Groomer resyncs | PCR rebases |
|---|---|---|---|---|---|
| `video` | all | **0** | 0 | 0 | 0 |
| `audio` | all | **0** | 0 | 0 | 0 |
| `es` | all | **0** | 0 | 0 | 1 |

The `es` arm is worth separating: recovering from a total 60 s outage the groomer took **one PCR
rebase**, produced **one** over-limit PCR interval and one backward step at the seam, and still
delivered **zero continuity errors and zero dropped packets**. That is the correct shape for a
recovery — the discontinuity is declared once, at the seam, and nothing downstream of it is corrupted.

## What this establishes

1. **The media-aware lane contains a partial media-plane failure.** One dead elementary stream leaves
   every other stream, the PSI and the exact CBR carrier untouched. The plausible architectural
   objection — that reassembling a mux from independently delivered tracks lets one dead track block
   the others — **is measured and does not occur.** This is the result that matters for the
   architecture, and it is a positive one.
2. **A partial stall is invisible to the whole of TR 101 290 P1.** Zero continuity errors, zero PCR
   intervals over 40 ms, a worst interval identical to the control's, and 57 s with no pictures. Any
   monitoring design that stops at P1 will report a dead service as healthy, indefinitely.
3. **[T22](test-22-silent-media-plane-failure.md)'s recommendation is corrected.** "PCR progression is
   the detector to build on" holds for a total stall and fails for a partial one, because PCR shares a
   PID with the video whose absence it is being asked to report. The detector to build on is
   **per-PID access-unit liveness**, which caught every arm at its true length with no false positive
   on the control.
4. **Content-rate detection works in proportion to the dead stream's share of the mux.** Unmissable
   for video at 82 % of the mux; useless for audio and subtitles at 4 %. An operator can be told what
   a stuffing-ratio alarm will and will not catch, which is more useful than being told it works.
5. **The groomer's stall policy remains a monitoring decision.** `--on-stall mute` is what made the
   total-loss arm detectable at all, and it converted that arm into an absence of bytes. It does
   nothing for either partial arm, in which the groomer never entered a stall state.

## What this does not establish

- **Nothing about a frozen picture.** Every arm here removes access units. An encoder that keeps
  emitting *valid* access units carrying an unchanging or looping picture would advance PCR, PTS, DTS
  and the continuity counters, hold its bitrate and defeat **every** detector in the table, including
  per-stream liveness. That failure is undetectable without decoding and comparing pictures, it is
  equally undetectable under opaque carriage or over SDI, and so it is a limit of transport monitoring
  in general rather than of this architecture. It is not tested here and should not be claimed either
  way.
- **Nothing about stale timestamps**, the other half of T22's limit. A source emitting PCR that
  advances at the wrong rate is [T23](test-23-pcr-discontinuity-classes.md)'s territory and partly
  measured there.
- **One clip, one PID layout.** PCR shares a PID with the video here. A mux carrying PCR on its own
  PID would behave the same way for the detectors — that is the point, PCR is independent of the video
  either way — but the proportional-sensitivity figures are specific to this programme's bitrate split.
- **Detection is measured; response is not.** Nothing here says how long an operations system takes to
  act, only when the signal becomes available.

## Open

**A per-track liveness signal in `moq import ts`.** The publisher logs
`audio stream lost frame sync and resynced pid=… track=".mp2" discarded=466 resyncs=1` — added
upstream in [#3372](https://github.com/moq-dev/moq/pull/3372) — so both audio arms are visible in the
publisher's own log without any downstream analysis. **Video has no equivalent**: 57 s with no access
units produced no log line at all. The importer already parses each elementary stream in order to
demux it, so it is the one component in the chain that knows a track has gone quiet without doing any
extra work. A symmetric per-track gap warning is a small change with a large monitoring payoff, and it
is something a media-aware publisher can offer that an opaque relay structurally cannot. Drafted for
upstream.

**The 2.8 s discrepancy between injected and delivered outage.** 60.02 s in, 57.22 s out. The
magnitude matches the cushion plus `--latency-max` that T22 measured at 1.81–1.92 s, but the sign
needs care — buffering should shift both edges of a hole equally and leave its length alone, so
something is compressing it, most likely the exporter's PCR regeneration during the gap (it inserted
2,575 PCRs in this arm against 4,286 in the control). Not load-bearing for any conclusion above, and
worth one focused run.

**Whether per-PID liveness monitoring is available in practice.** The recommendation this experiment
arrives at is only useful if broadcast monitoring products expose per-PID access-unit liveness rather
than only per-PID bitrate. Bitrate alone would inherit exactly the proportional-sensitivity problem
measured here, since a dead stream's PID bitrate goes to zero but the *service* bitrate does not.

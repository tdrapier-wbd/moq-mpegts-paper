# Test 80: a receiver switch that detects on the video PID and cuts at a random-access point

**State: run and graded. C0, C4 and C5 hold; C2 and C6 fail.** Holding both legs 2 s and cutting at a random-access point cost every one-source fault the background's decoder hole and no bad picture, in all twelve runs, at most two frames repeated where the legs ran apart. Without the hold the egress cell lost 2.5 s in two runs of three. A relay's skip never breaks the clock, and on upstream's fix, which flags only a clock that jumps, it reaches the wire unflagged.

## Objective

[T58](test-58-receiver-select.md) switched two legs of the media-aware lane at the receiver with TSDuck's `tsswitch`, which detects only absent packets and cuts anywhere. A fault cost the switched output 0.8–2.9 s of decoder hole: the switch waited out the media the failed leg's export still held and the PCR and null packets after it, then cut into the other leg mid-picture. T58 named the two things a receiver switch could do instead, and measured neither. [Evidence](evidence.md) §5 row 7 asks whether a media-aware failover can be brought under a second as a decoder sees it, and names those two, with an export that flags the skip a relay loss leaves.

This test asks, on T58's topology and today's `main`:

- **Part A:** does a switch that detects on the video PID's silence and starts the other leg at a random-access point bring every fault under a second at the decoder, and does holding both legs for a fixed delay make it hitless?
- **Part B:** does the export now flag the skip a relay loss leaves on moq-lite 07 ([T56](test-56-media-aware-failover.md) R5), so that a receiver can see it?

## Environment

| Component | Build |
| --- | --- |
| `moq`, `moq-relay` | `main` at `419b799c7`, recorded with each run; it flags the first PCR after a delivery skip |
| Switch | [`t80-vswitch.py`](scripts/t80-vswitch.py) (Python 3), recorded with each run; the positive control's `tsswitch`, TSDuck 3.45, `--fast-switch` |
| Host | the laptop, loopback; no other timing work and no build on the host during a run |
| One source | T58's: the contribution clip (1080i H.264, 9.95 Mb/s CBR, an I-frame every 1.2 s in an open GOP) played live to a file that each importer follows from its own start |
| Two sources | T58's separate encode (720p H.264, 2 s closed GOP, 9 Mb/s CBR, other PIDs), played from the same instant |
| Legs | T58's: leg A and leg B, each an importer, its own relay and its own broadcast, and an `export ts --stitch --follow 10s --delay 2s` under a supervisor that restarts it when it exits |
| QUIC idle timeout | 6 s on every client and relay, keep-alive a third of it |

## Procedure

**Part A.** [`t58-receiver-select.sh`](scripts/t58-receiver-select.sh) as T58 runs it, with `SWITCHER=vswitch` putting `t80-vswitch.py` where `tsswitch` was. The switch reads both exports' pipes and starts on leg A. When the serving leg's video PID has carried nothing for τ = 200 ms while the other's has, it cuts to the other, never back (non-revertive), and logs the decision to `events.txt` as T58's switch events are. At the cut it writes the other leg's latest PAT and PMT, then that leg from a video packet that sets `random_access_indicator` (which the export sets on the first packet of each keyframe). It repairs no continuity counter.

| Mode | Output | The cut |
| --- | --- | --- |
| `rap` | each packet as it arrives | the other leg from its next random-access point after the decision |
| `lookback` | each packet 2 s after it arrives, so the switched output is 2 s later than either leg | the other leg from its latest random-access point at least 0.1 s before the failed leg's last video packet, still held; the failed leg ends at its own random-access point within 0.3 s of that one by arrival (the same picture, on one source), else at that instant. With none held that late, the next one |

At 30 s the rig fails one component of the leg the switch serves and restarts it 15 s later. Three runs per cell, 75 s each:

| Cells | Mode | Source |
| --- | --- | --- |
| `kill`, `term`, `relay`, `egress` (T58's) | `rap`, `lookback` | one |
| `kill`, `term` | `lookback` | two (leg B on the separate encode) |
| `kill`, `tsswitch` at a 500 ms receive timeout (the positive control) | — | one |
| `none`: no fault, one run per mode (the negative control) | `rap`, `lookback` | one |

The `relay` cell runs with the importers retrying without limit (`RETRY=0s`), as T58's did. Measures, from [`t56-grade.py`](scripts/t56-grade.py) on each recording, are T58's: detection (from the fault to the switch's decision), the stall, the decoder hole beside the same before the event, the programme lost or repeated, the latency step, and bad pictures. Every 10 s the switch logs each input's longest gap between video packets.

**Part B.** T56's R5 on this build: [`t6-relay-kill.sh`](scripts/t6-relay-kill.sh) `MODE=diamond`, one importer through two middle relays to the exporters' relay, the serving middle relay SIGKILLed at 20 s and restarted at 30 s, with `--stitch --follow 10s` at `--delay` 2 s and 10 s, on moq-lite 07 (`MOQ_CONNECT_VERSION` and `MOQ_LISTEN_VERSION`), three runs each; one run on the default version at 2 s as the control. Each export is graded by [`t6-switch-grade.py`](scripts/t6-switch-grade.py), the PCR PID read from its PMT.

## Pass criteria, fixed before running

1. **Void** unless every event time is in `events.txt`, every recording covers its run to within 3 s of its end, the source file shows no continuity error, and the switch's log names a video PID on both inputs.
2. **Controls.** _Negative:_ in each mode's no-fault run the switch makes no cut after leg B's arrival, and no input's longest video gap while it is live exceeds τ/2 = 100 ms; otherwise τ is fixed at twice that gap before the graded runs, and the change reported. _Positive:_ `tsswitch` at 500 ms costs each `kill` fault a decoder hole over 1 s, as in T58, in all three runs.
3. **C0, a leg's arrival is free,** T58's criterion, in every run of both modes: the standby's start and each restart cause no cut, and no decoder hole beyond the hole before the event plus 0.1 s.
4. **C1, the costs,** measured, no pass mark: per mode, cell and source, the median and worst of three of the detection, the stall, the decoder hole, the programme lost and the bad pictures.
5. **C2, sub-second without a delay:** in `rap`, every cell's fault costs a decoder hole and a programme lost under 1 s, in all three runs. T58's C2, with this switch.
6. **C6, hitless with a 2 s hold:** in `lookback` on one source, every cell's fault costs a decoder hole within its hole before the event plus 0.1 s, a programme lost or repeated of at most one frame (0.04 s), and no bad picture, in all three runs.
7. **C4, two sources,** T58's criterion, in `lookback`: every cut decodes on, with a decoder hole under 1 s, and the programme step reported, in all three runs of both cells.
8. **C5, the skip flagged:** on moq-lite 07, at each delay and in all three runs, every export that skips programme marks the skip with `discontinuity_indicator` on its PCR PID and on no other, within a second of the step in video decode time, with the PMT version unchanged and no continuity error outside it; the programme lost is reported beside R5's. The default-version control must show its switch with every PID flagged, or the grader's reading of the indicator is unproven and C5 is void.

_Predicted:_ C0 holds. C2 fails on this clip: the hole is τ plus the wait for the other leg's next random-access point, up to 1.2 s, so some runs exceed a second. C6 holds. C4 holds within the encodes' offset. C5 holds.

## Limits, fixed in advance

- `t80-vswitch.py` models what a receiver's input switch could do; it is no product. It reads both legs' exports over pipes on the one host, finds random-access points by the export's own `random_access_indicator`, and repairs no continuity counter or table version.
- Whatever `lookback` saves is bought with its hold: 2 s of latency on top of each export's delay.
- FFmpeg is the decoder, not an IRD. Loopback has no loss or jitter, and the laptop's scheduler is in every timing. Both legs read one file on one host, so the source is common to them, which no 1+1 covers. One clip, one GOP structure.

## Results

**As run.** 35 Part A runs and 7 Part B runs, none void: every switch log names a video PID on both inputs. Two departures, both fixed before the graded runs or forced by the grader:

- **τ is 202 ms, not 200.** In both no-fault runs leg A's longest video gap in its first 10 s was 100–101 ms, against at most 76 ms after; criterion 2 fixed τ at twice it. Neither control cut.
- **`lookback`'s arrivals have no hole before them.** The standby's start (7.1 s) and its importer's (8.1 s) fall within the switched output's first 2 s, which the hold leaves without a window before them, so the grader reports none. Their holes, 0.22–0.32 s, match leg A's own recording over the same windows (0.324 s against 0.318 s, 0.288 s against 0.283 s at the two highest).

**Part A, the faults.** Median (worst) of three, in seconds; a negative programme lost is a repeat. The hole before each fault was 0.18–0.21 s in every run, 0.23 s in the positive control's.

| Mode, cell | Detection | Stall | Decoder hole | Programme lost | Bad pictures |
| --- | --- | --- | --- | --- | --- |
| `rap`, kill | 2.09 (2.12) | 0.69 (0.72) | 0.79 (0.82) | 0.72 (0.76) | 7, 7, 7 |
| `rap`, term | 2.35 (2.35) | 0.32 (0.39) | 0.47 (0.69) | 0.44 (0.60) | 7, 7, 7 |
| `rap`, relay | 2.15 (2.16) | 0.72 (0.72) | 0.81 (0.82) | 0.76 (0.76) | 7, 7, 7 |
| `rap`, egress | 0.16 (0.17) | 1.34 (1.37) | 2.29 (2.32) | 2.52 (2.52) | 1, 0, 6 |
| `lookback`, kill | 2.11 (2.11) | 0.06 (0.06) | 0.22 (0.23) | 0 (−0.08) | 0, 0, 0 |
| `lookback`, term | 2.49 (2.50) | 0.06 (0.06) | 0.23 (0.23) | 0 (0) | 0, 0, 0 |
| `lookback`, relay | 2.11 (2.13) | 0.05 (0.05) | 0.22 (0.22) | 0 (0) | 0, 0, 0 |
| `lookback`, egress | 0.17 (0.18) | 0.03 (0.07) | 0.20 (0.21) | 0 (−0.08) | 0, 0, 0 |
| `lookback`, two sources, kill | 2.14 (2.15) | 0.13 (0.13) | 0.32 (0.33) | −0.84 (−0.84) | 0, 0, 0 |
| `lookback`, two sources, term | 2.28 (2.34) | 0.12 (0.13) | 0.33 (0.33) | −0.84 (−0.84) | 0, 0, 0 |
| `tsswitch` at 500 ms, kill (positive control) | 3.40 (3.40) | 1.49 (1.50) | 2.24 (2.25) | 2.12 (2.12) | 0, 0, 0 |

- **Detection waits only for the export's held video.** After a kill or a relay loss the failed leg's video ran on 1.75–1.96 s, about its export's delay; the switch decided τ later, 1.3 s sooner than `tsswitch`, which waits out the PCR and null packets after it as well. After a SIGTERM the video ran on 2.0–2.3 s. An egress stall decides at τ.
- **`rap` costs the wait for the other leg's next keyframe and its open GOP.** Each kill, term and relay cut broke the seven leading pictures that reference the GOP before it. Each cell's three runs hit nearly one keyframe phase, the fault falling at a fixed time on a looped clip, so each figure is one phase's, not the cell's worst. In two egress runs the cut stepped decode time by 1.48 and 1.52 s, more than half the clip's picture-order period (`log2_max_pic_order_cnt_lsb` 7, no IDR: 1.28 s); FFmpeg, carrying its picture-order count across the unmarked cut, put the GOP after it out of order and dropped a further second. The third run stepped 0.32 s and lost 0.28 s.
- **`lookback` cuts on the same picture when the legs arrive within 0.3 s.** Both legs carry equal PTS on each keyframe (41–55 shared per run). In look-kill-2 and look-egress-2 leg B ran up to 0.7 s behind A, beyond the arrival match: A ended at a packet boundary, B restarted 0.4–0.5 s of programme A had shown, FFmpeg dropped what it had already ordered, two frames repeated, and the latency stepped up by the lag. Pairing the keyframes by PTS instead would trade that repeat for a hole of the lag, since the output is paced by arrival; hiding the lag needs a stage that re-times by content.
- **Two sources cost their offset as a repeat**: 0.84 s of programme shown twice and a 0.66 s latency step in all six runs, at a hole of 0.32–0.33 s. T58's `tsswitch` cost up to 3.6 s of hole and 2.7 s of programme there.

**Part A, the arrivals.** 110 arrivals across the 30 faulted `vswitch` runs and both no-fault runs caused no cut. In `rap` each cost a hole of 0.15–0.25 s, within its before plus 0.1 s.

**Part B.** On moq-lite 07 every export skipped programme at the relay loss and flagged it once, with `discontinuity_indicator` on the PCR PID (111) and on no other, the PMT version unchanged and no continuity error: at a 2 s delay video decode time stepped 5.24–6.44 s (R5: 6.9–8.1 s), at 10 s 1.5 s (R5: 2.7 s), in every run, both exports. The flag leads each stream's step in output byte order: video by 0.20–0.98 s, audio and teletext by up to 1.57 s. **The PCR does not jump, and no stream's timestamps leave it:** the export fills the outage with null packets on a PCR running at its 25 ms spacing, and each PID resumes with its DTS advanced as far as the PCR, within 0.05 s, so its offset to the PCR is unchanged (video +1.00 s before, +1.04 s after). No frame from before the skip follows the flag, which falls in the padding. A fourth run at 2 s, read packet by packet with a PCR-jump detector that found T64's 7 s synthetic step and nothing in the source, gave the same, its video stepping 7.62 s as it resumed a group later; on `204c97f4f`, the build [#7741](https://github.com/moq-dev/moq/issues/7741) reported, one run gave the same hole unflagged. The default-version control switched with every PID flagged, a new PMT, its step 7.3–7.6 s.

**Grading.**

| Criterion | Result |
| --- | --- |
| 1, void | none void |
| 2, controls | negative held with τ re-fixed at 202 ms; positive held, a 2.24–2.25 s hole in all three |
| 3, C0 | **holds**: no cut on 110 arrivals, every `rap` hole within its bar |
| 4, C1 | the table above |
| 5, C2 | **fails**: the egress cell's hole was 2.29 and 2.32 s in two runs; the other cells were under a second in all three, each at one phase |
| 6, C6 | **fails, narrowly**: every hole within its bar and no bad picture in all twelve; the programme within a frame in ten, two frames repeated in two |
| 7, C4 | **holds**: every cut decodes on, a hole of 0.32–0.33 s, 0.84 s repeated |
| 8, C5 | **holds**, the control valid |

## Conclusions

- **A receiver switch can bring a media-aware failover under a second as a decoder sees it, if it holds both legs.** Detecting silence on the video PID and cutting, 2 s behind both legs, from the other leg's last keyframe before the failure, every one-source fault cost the background's decoder hole and no corrupt picture, against `tsswitch`'s 2.24 s on the same build. The price is 2 s of latency on top of each export's delay, and any lag between the legs as a repeat and a latency step.
- **Without a hold a keyframe cut is not bounded under a second on an open-GOP clip.** It waits for the other leg's next keyframe, up to a GOP, and breaks the open GOP's leading pictures; a cut that skips more than half the stream's picture-order period also costs the decoder its ordering. Sub-second `rap` results here are one keyframe phase each.
- **The legs' arrival skew, not the switch, sets what `lookback` repeats.** It varied 0.2–0.7 s between runs of one topology on one host.
- **The demultiplexed export's skip is a programme gap on an unbroken clock, and on upstream's fix it is unflagged.** The clock runs on through the skip and every stream keeps its offset to it. The flag #7785 set there announced a new time base equal to the old one; #7981 keeps the flag for a clock that jumps, so a receiver sees the skip only as the gap in each stream's decode time. The skip itself still costs the detection interval less what a resumed copy keeps.

## Part B on the flag fix

Upstream's [#7981](https://github.com/moq-dev/moq/pull/7981) (`main` at `2460728a2`) flags a PCR only where its clock jumps, so the skip above, on an unbroken clock, should go out unflagged. Part B's command unchanged on that build, three runs at each delay and the control; each export read by `t6-switch-grade.py` and the PCR-jump detector above.

_Criteria, fixed before running._ Void as criterion 1, or unless the detector again finds T64's 7 s step and nothing in the source. **Passes** if every moq-lite 07 export that skips programme keeps its PCR within 100 ms of its packet count and sets `discontinuity_indicator` on no PID in its skip; the control keeps its switch with every PID flagged and a new PMT; and the programme lost stays within Part B's range at each delay. A PCR jump is reported, and passes only if its first PCR is flagged.

_Results._ None void; the detector found T64's step (+6.5 s) and nothing in the source. **No moq-lite 07 export set `discontinuity_indicator` on any PID, and no PCR left its packet count by 100 ms**: 18 exports in nine runs, the video skipping 6.4–7.6 s at a 2 s delay and 1.5–3.6 s at 10 s. The control's two switches kept every PID flagged with a new PMT, the flag on the first PCR after a +6.3 s jump. **The loss clause fails as written** at 10 s, 3.0 and 3.6 s in two of six runs against Part B's 1.5 s, but three runs of the old build interleaved with the last three lost 1.5–3.0 s, each flagged once: Part B's three runs had shared one group phase, and the builds lose alike. **The fix holds**: a skip on an unbroken clock goes out unflagged, and a declared switch's jump keeps its flags.

## Corrections

**Believed:** the flag leads each stream's timestamp step, so a receiver acting on it acts early; and, in #7741, the skip was a forward jump of PCR and PTS. **True:** the PCR never jumps; each stream's timestamps advance with it across padding, and only padding follows the flag. **Rule:** [method notes](method-notes.md) §2, on reading a timestamp step against the PCR.

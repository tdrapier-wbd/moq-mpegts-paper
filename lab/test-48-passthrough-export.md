# Test 48 — The passthrough TS export on real captures

**State: complete**, on the implementation branch and again as merged. On a dedicated host criteria 1–4
pass on both clips, and on the live feed across hosts: each leg is the source's bytes, a leg joining 8 s late is the same stream, a leg over the
internet is too, and every PCR goes out within 2 ms of its value's schedule. Criterion 5 fails on its accounting clause, and under 10 % loss this lane delivers as
little video as every other MoQ export graded on content in the same rig.

## Objective

`moq export ts --passthrough --delay <d>` (our implementation of upstream's `ts-passthrough-export`
quest, since merged) writes back out the `m2ts` track an `import ts --passthrough` published, paced on
the source's own PCR. The quest's claim is that from the first group it releases the output is the
source's bytes, less any object dropped late, so it is exactly as T-STD-conformant as the source,
and that two exporters of one broadcast write identical bytes. If that holds on real captures, the
media-aware lane has a TS-out mode whose conformance is the source's
([Evidence](evidence.md) §3.16, §5 row 2) and whose 1+1 legs are byte-identical without
being co-started ([Architecture](../docs/architecture.md) §5.1, P1-o). The demultiplexed export can
claim neither.

## Environment

- **Build:** the implementation branch at `0da3a7736` (on upstream `main` `90500867d`), release,
  default features; every EC2 arm again on upstream `main` at `b581c27ed`, with the export merged.
- **Loopback arms**, on the EC2 secondary (Linux, dedicated) and on this workstation (macOS, shared):
  relay, publisher and two subscribers on one host. Clips:
  `contrib-10m.ts` (1080i25 H.264, MP2 and AC-3, 11 Mb/s; passes the T-STD in
  [T44](test-44-tstd-grading.md)) and the 125 s sports cut (H.264 and AC-3, 21.6 Mb/s; fails
  it, [T45](test-45-live-tstd-remux.md)). `--delay 1s`, 120 s.
- **Loss arm (EC2 secondary):** the #4613 rig ([`t8b-loss-point.sh`](scripts/t8b-loss-point.sh),
  `IMPORT_ARGS=--passthrough EXPORT_ARGS=--passthrough`): two network namespaces, 10 % uniform loss
  on the relay-to-subscriber direction, 25 ms each way, `contrib-10m.ts`, `--delay 2s` and 6 s, 120 s.
  Controls: the same build's demultiplexed export, and the standing `84b34f54` (`--max-age 2s`) at
  0 % and 10 %, every egress graded on content.
- **Live arm (P1-t):** the live hand-off (25 Mb/s CBR, no nulls; [T45](test-45-live-tstd-remux.md))
  read from the primary's loopback multicast beside the standing ingest, which it does not touch. On
  the primary: a relay of this build, `import ts --passthrough`, and the hand-off capture, the
  reference. Legs A and B (8 s late) on the secondary, cross-AZ; leg W at the workstation, over the
  internet. `--delay 2s` on every leg, 150 s
  ([`p1t-live-passthrough.sh`](scripts/p1t-live-passthrough.sh)).

## Procedure

[`t48-passthrough.sh`](scripts/t48-passthrough.sh) starts a relay, publishes the clip through
`tsp regulate --pcr-synchronous | moq import ts --passthrough`, and runs leg A from the start, its
stdout teed into upstream's live PCR grader (`test/ts/pcr-timing.py --live`), and leg B 8 s later.
[`ts-passthrough-identity.py`](scripts/ts-passthrough-identity.py) walks each capture against the
clip: a packet that continues the current run of source bytes is matched, a jump forward in the
source is a gap, and a packet found nowhere ahead is foreign. B is compared with A byte for byte over
the source span both cover. Upstream's `test/ts/compliance.py` grades A and the source span A covers,
whose `tstd` check is the strict buffer model ([T46](test-46-tstd-check-cross-validation.md)
cross-validates it). The loss arm keeps its egress and runs the identity check on it.

## Pass criteria, fixed before running

1. **Identity, unimpaired.** On both clips, both legs: 0 foreign packets, 0 gaps, and the exporter
   reports 0 dropped.
2. **A late leg is the same stream.** B, joining 8 s after A, is byte-identical to A over the source
   span both cover, continuity counters included.
3. **The source's conformance.** `compliance.py`'s `tstd` check gives the same verdict on A as on the
   source span A covers, on both clips (expected: the news cut passes, the sports cut fails).
4. **Paced on the source's PCR.** On leg A, `pcr-timing.py`'s `pcr-release-timing` check passes (no
   PCR released more than 10 ms off the interval its value asserts) and its `pcr-rate` check passes
   (the PCR clock within 30 ppm of the release clock).
5. **Under 10 % loss.** The relay and both clients stay up for the 120 s; the egress has 0 foreign
   packets; it has no gap unless the exporter reports drops, and no more gaps than reported drops.

The live arm is graded on criteria 1–4 against the hand-off capture, with W held to criteria 1 and 2
as a third leg, and reports, without a threshold, the bytes the relay sent each leg against the
source bytes it delivered. A run of packets that the hand-off capture and the publisher's socket
disagree on, both reading one multicast group, is the rig's, not the lane's; the capture's own
continuity check tells them apart.

Criterion 3 is implied by criterion 1, since `compliance.py` grades a file on its own PCR; it is kept
because it is the quest's own test. Criterion 4 is the one the file-domain checks cannot see.

## Results

### Loopback

| Clip, host | Packets, A / B | Gaps, foreign, dropped | B against A | `tstd`, A / source span | Release timing, A | PCR rate, A |
|---|---:|---|---|---|---|---:|
| News, EC2 | 707,717 / 739,858 | 0, 0, 0 on both | identical, 125.5 MB | pass / pass | 0 of 4,380 outside ± 10 ms; worst 1.8 ms | −0.13 ppm |
| Sports, EC2 | 1,710,040 / 1,788,056 | 0, 0, 0 on both | identical, 302.3 MB | fail / fail, identical | 0 of 4,179; worst 1.9 ms | +0.16 ppm |
| News, workstation | 707,433 / 739,368 | 0, 0, 0 on both | identical, 125.4 MB | pass / pass | **1** of 4,378; 10.045 ms, p99 3.1 ms | −2.12 ppm |
| Sports, workstation | 1,708,526 / 1,788,056 | 0, 0, 0 on both | identical, 302.0 MB | fail / fail, identical | **9** of 4,174; worst 62.3 ms, p99 3.6 ms | +0.53 ppm |
| News, EC2, `b581c27ed` | 707,717 / 739,858 | 0, 0, 0 on both | identical, 125.5 MB | pass / pass | 0 of 4,380; worst 1.8 ms | +0.54 ppm |
| Sports, EC2, `b581c27ed` | 1,710,040 / 1,787,639 | 0, 0, 0 on both | identical, 302.3 MB | fail / fail, identical | 0 of 4,179; worst 1.9 ms | +0.69 ppm |

*Measured, P1, wire domain (each leg's stdout), build `0da3a7736` unless named, `--delay 1s`, 120 s,
one run per clip, host and build. Leg A's capture ends when the grader's 110 s window does.*

The sports cut's verdict is the source's own: the span A covers carries 1,425 continuity errors, six PCR
intervals over 100 ms (worst 200 ms) and four audio PIDs the strict model refuses, having no sync at
the offset where the span starts; its video PID stays inside its buffers. A carries all of it byte for
byte, and so does B over the overlap. The merged export repeats the dedicated host's verdicts on
both clips; its release clock logged nothing on the news cut, and on the sports cut 14 and 10 steps out of tolerance in
the first 65 s, dropping nothing.

The workstation's release-timing outliers belong to the host (*inferred*: the same build, clips and
grader on the dedicated host put every PCR within 1.9 ms). Graded the same way there, the input pacer
(`tsp regulate --pcr-synchronous`) puts 4,279 of 4,326 sports-cut intervals outside ± 10 ms (p95 46 ms), so
the export re-paces a bursty input to within a few milliseconds of the source's PCR.

### The live feed across hosts (P1-t)

| Leg | Packets | Gaps, foreign, dropped | Against A | `tstd`, A / source span | Release timing, A | PCR rate, A |
|---|---:|---|---|---|---|---:|
| A, secondary | 2,294,914 | 0, 0, 0 | — | fail / fail, identical | 0 of 7,358 outside ± 10 ms; worst 2.0 ms | −0.10 ppm |
| B, secondary, 8 s late | 2,337,508 | 0, 0, 0 | identical, 408.4 MB | | | |
| W, workstation, internet | 2,464,773 | 0, 0, 0 | identical, 423.3 MB | | | |

*Measured, P1, wire domain (each leg's stdout), build `0da3a7736`, `--delay 2s`, one 150 s run; the
hand-off capture is the reference, and the relay, publisher and capture shared the primary with the
standing ingest.*

All four criteria pass, and the internet leg holds criteria 1 and 2 as well. The `tstd` verdict is the
source's, as with the sports cut: the span A covers opens mid-frame on both audio PIDs, which the strict model
refuses, and the video stays inside its buffers (EB peak 79.9 %). On the primary the passthrough
import took 6.4 % of a core and the relay 8.4 % serving three legs, against 74.8 % for the standing
media-aware import of the same feed. Counted per datagram, the relay sends each leg 1.054× the
source's rate ([T14](test-14-data-plane-comparison.md) § *On the live feed's profile*).

**The merged export gives the same verdicts.** On `b581c27ed`, the same rig without W (one 150 s
run): A 2,308,198 packets and B 2,337,756, each 0 gaps, 0 foreign, 0 dropped; B identical to A over
408.3 MB; `tstd` fail on A and on its source span, identically; 0 of 7,851 releases outside ± 10 ms,
worst 1.9 ms; PCR rate +0.14 ppm. The import took 6.1 % of a core and the relay 6.3 %.

Each exporter's release clock counted steps out of tolerance for the first 25–70 s (A 9, B 4, W 23)
and none after, with nothing dropped. The count is of the source rate
the steering estimates, which starts at hundreds of ppm on a live join; the output's PCR rate over
the leg is −0.10 ppm. On a live join that counter is a startup alarm, not an output fault.

### Under 10 % loss

| Arm: export, build, `--delay` | Egress | Nulls | Video delivered | Audio lost | Identity |
|---|---:|---:|---:|---:|---|
| passthrough, `0da3a7736`, 2 s, **0 % loss** | 9.75 Mb/s | 4.6 % | 100 % (4,270 units) | 0 s | 0 gaps, 0 foreign |
| passthrough, `0da3a7736`, 2 s | 0.58 Mb/s | 4.6 % | **6.0 %** (185) | 32.1 s | 90 gaps, 0 foreign |
| passthrough, `0da3a7736`, 6 s | 0.59 Mb/s | 4.7 % | **6.0 %** (145) | 48.5 s | 79 gaps, 0 foreign |
| passthrough, `b581c27ed`, 2 s, **0 % loss** | 9.75 Mb/s | 4.6 % | 100 % (4,270) | 0 s | 0 gaps, 0 foreign |
| passthrough, `b581c27ed`, 2 s | 0.70 Mb/s | 4.7 % | **7.1 %** (186) | 25.9 s | 99 gaps, 0 foreign |
| demultiplexed, `0da3a7736`, 2 s | 9.65 Mb/s | 90.6 % | **8.2 %** (327) | 0.7 s | — |
| demultiplexed, `0da3a7736`, 6 s | 9.20 Mb/s | 95.0 % | **3.5 %** (91) | 0 s | — |
| demultiplexed, `84b34f54` (`--max-age`), 2 s, **0 % loss** | 9.89 Mb/s | 5.5 % | 100 % (4,232) | 0 s | — |
| demultiplexed, `84b34f54` (`--max-age`), 2 s | 7.21 Mb/s | 95.9 % | **2.7 %** (74) | 1.0 s | — |
| demultiplexed, `83ce47fe`, 2 s, **0 % loss**, two runs | 9.85 Mb/s | 3.9, 4.2 % | 100 % (4,262) | 0.4, 0.2 s | — |
| demultiplexed, `83ce47fe`, 2 s, two runs | 9.92, 10.49 Mb/s | 88.5, 94.2 % | **8.0, 2.6 %** (339, 109) | 20.3, 11.0 s | — |

*Measured, P1, EC2 secondary, BBRv3 on noq, 25 ms each way, 120 s, one run per cell. Egress is wire
domain; video and audio are content domain ([`t28-content-lost.py`](scripts/t28-content-lost.py)).
Video delivered is the video PID's packets against the 0 % arm of the same build (`0da3a7736`'s
passthrough arm for both of its exports, the clip being the same), with access units in brackets:
the grader's lost-seconds figure misreads a capture this sparse, taking the 1.2 s between surviving
fragments for the frame period.*

Neither process died and no packet of the passthrough egress is foreign: what arrives is the
source's bytes, and each gap is whole groups. The exporter's log names each one, 187 groups the relay
ended as `Old` merging into the 90 gaps (190 into 99 on `b581c27ed`), but its drop count stays at 0. That count is of objects that
arrive past their deadline, and these never arrive: the relay ends a group's stream once the track's
newest content is a budget past the start of the group after it, while the stream waits on the
transport. **So criterion 5 fails on its accounting clause.**

**The collapse is not the passthrough lane's.** Graded on content, the demultiplexed export of the
same build delivers 3.5–8.2 % of the video, the standing older build 2.7 %, and `main` with the
interleave-hold fix ([T8b](test-8b-congestion-control.md) § *C7*) 2.6–8.0 %. Tripling the delay,
and with it the relay's budget, helps neither export, so what arrives is set upstream of both
(*inferred*). The demultiplexed export keeps the audio because audio rides tracks of its own; in the
passthrough lane it shares the video's groups. The older build's row also corrects
[T8b](test-8b-congestion-control.md) § *C7*, whose rates are egress bytes (§ *Corrections* there).

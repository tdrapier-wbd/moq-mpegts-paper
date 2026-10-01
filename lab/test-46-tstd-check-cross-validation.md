# Test 46 — Two T-STD checks cross-validated, and a content key for presentation latency

**State: complete on one clip, its derived captures and upstream's own controls; offline, on saved
captures, with no live run.**

- **With `ts-tstd.py` corrected, the two checks agree on 24 of 35 files, and each of the other 11
  disagreements traces to upstream's check.** In the 24, every condition both checks grade has the same
  pass or fail on every PID. Where both find a violation, their first violations fall within 0.3 ms of
  each other. One of the 24 is a synthetic file that both refuse to grade. The 11 come from four causes
  in upstream's check: three defects against Rec. ITU-T H.222.0 (10/2014), and one convention about the
  last access unit of a capture.
- **As first written, `ts-tstd.py` was wrong in six ways.** Two produced disagreements:
  - It sized the AVC decoder buffer as a single EB of cpb + BSmux + BSoh, where 2.14.3.1 specifies the
    leak model's MB and EB: 1,115,696 B against 3,766,000 B on this clip.
  - It did not grade 2.4.2.6's rule that every transport buffer empties at least once a second.

  Reading the clauses against the code found the other four:
  - It delivered bytes at packet arrival rather than at TB exit.
  - It left audio PES headers out of B.
  - It delivered duplicate packets.
  - It passed silently any stream it could not grade.

  All six are fixed, each with a control. No T44 or T45 verdict moves, but several published figures do.
- **Presentation latency can now be timed without PTS keys.** The AVC slice NAL units cross the
  media-aware lane byte-identical even where its parameter sets are reordered or dropped.
  [`ts-decode-latency.py --key content`](scripts/ts-decode-latency.py) matches pictures on those slices.
  - **Validation:** on T45's four reference runs it reproduces the PTS key's median to within
    0.0005 ms. It times between 99.908 % and 100 % of the same pictures, each against the same source
    picture.
  - **T44's `main` capture:** the PTS key cannot time it at all, and the content key reads 1,775.6 ms.
    Those bytes fail the T-STD on every video and audio access unit, though, so the figure is the
    schedule the egress declares, not a latency any decoder achieves.

## Objective

1. **Do `ts-tstd.py` and upstream's T-STD check agree?** Upstream moq-dev/moq merged a full
   ISO/IEC 13818-1 T-STD check into `test/ts/compliance.py` (PR #4643, merged into the
   `quest/m1/tstd/README` branch rather than `main`; see [Environment](#environment)). This campaign's
   [`ts-tstd.py`](scripts/ts-tstd.py) was written independently for [T44](test-44-tstd-grading.md).
   Two instruments built from the same clauses by different hands should give the same verdict on
   the same bytes. Where they do not, one of them is wrong or they model different things, and
   which it is must be decided from the standard, not from which result is more convenient.
2. **Can presentation latency be timed without PTS keys?** [`ts-decode-latency.py`](scripts/ts-decode-latency.py)
   matches each egress picture to its source picture by PTS. Upstream `main` and the fixed-delay
   export rebase the PTS, so that key cannot time them. A key on the pictures' elementary-stream
   bytes would.

## Pass criteria, fixed before the runs

### Part A — when the two checks agree

Both checks grade the same bytes, from the same first packet to the last, at offset 0: each
stream's own PCR, with no added decoder delay.

**Equalising the start.** Upstream's check has no start-up skip; `ts-tstd.py` simulates from the
first PCR and counts from `--skip S`. Each capture is therefore cut at the first packet that carries
a PCR on the program's PCR PID at or after S seconds of that PCR, measured from the capture's first
PCR. S is the skip the capture's own experiment graded with: 20 s for the T44 arms and T44's
re-multiplexed outputs, 5 s for the T45 arms, and 0 for the source clip, the Kyrion capture and its
restamps. Those are cut at their first PCR packet, so that neither check sees packets ahead of the
first PCR, which upstream times by extrapolation and `ts-tstd.py` ignores. Both checks then grade
the cut file whole, `ts-tstd.py` with `--skip 0`. To show that the cut does not move `ts-tstd.py`'s
own verdict, it also grades each uncut file with `--skip S`, as T44 and T45 did.

**Conditions compared, per PID graded by both checks:**

| Condition | `ts-tstd.py` | upstream |
|---|---|---|
| TB overflow | `TB … overflow_packets` | `TB overflow` |
| TB not emptied within 1 s (2.4.2.6) | not graded, so a pass | `TB not emptied within 1 s` |
| Video MB/EB overflow | `EB … overflow_arrivals` (one buffer stands for MB and EB) | `MB overflow` or `EB overflow` |
| Audio B overflow | `B … overflow_arrivals` | `B overflow` |
| EB or B underflow | `underflows` | `EB underflow` / `B underflow` |
| STD delay | `residence_over_limit` | `held over N s` |

The `ts-tstd.py` column describes the instrument as it stood when the criteria were fixed. After the
fixes below it grades the 1 s rule itself (`not_emptied_within_1s`), and its video row is the
MB + EB leak model's MB overflow, EB overflow or EB underflow. The criterion is unchanged.

A condition a check does not grade counts as that check's pass, because its verdict passes the
stream. **The checks agree on a file when every compared condition has the same pass or fail on
every PID graded by both.** A PID graded by only one check (the systems buffer, teletext, SCTE-35 or
SI in `ts-tstd.py`; anything upstream refuses) is a coverage difference, reported but not counted.

**Every disagreement** is located: the first violating access unit and the time of the violation in
both checks, on the cut file's PCR clock. Which check is right is decided from Rec. ITU-T H.222.0
(10/2014), the edition upstream cites, by clause, and the disagreement is classed as a model
difference or a defect. Neither check is changed to force agreement. If `ts-tstd.py` is wrong, it is
fixed with a control that shows the fix, and the whole corpus is re-graded.

**Corpus.** The source clip; every T44 arm with a saved egress (and `main-raw`'s exporter bytes);
the six T45 arms; upstream's Kyrion control as captured, and restamped by its own `tstd-controls.py`
at 1×, 0.7×, 4× and 15×. Graded the same way as extras: upstream's three synthetic layouts and T44's
six re-multiplexed outputs.

### Part B — the content key

Fixed in advance: on T45's `smoke`, `ffa-L600-w60`, `udp-sc-c100` and `srt-sc-b120-c100`, the content
key must reproduce the PTS key's presentation-latency median to within 0.1 ms (T45: 75.9, 2,196.7,
113.7 and 234.0 ms) and match at least 99.9 % of the pictures the PTS key matches. Only then is it
run on a capture the PTS key cannot time. Before that, a T45 capture is checked for whether the
elementary-stream bytes survive the lane unchanged.

## Instruments

**[`tstd-xval.py`](scripts/tstd-xval.py)**, written for this test, drives both checks on one file:
- **Cutting:** it makes the cut described above, and puts the capture's first PAT and PMT packets in
  front of it, because `ts-tstd.py` collects PCRs only once it has a PMT. Without them,
  `ts-tstd.py` began about 1,100 video packets later than upstream on the Kyrion capture, whose PSI
  repeats every 0.8 s.
- **Reading violations:** it reads `ts-tstd.py`'s own first violations. It wraps upstream's
  `Grade.flag` to read the simulator's state when each violation is first flagged. Neither check's
  logic is altered.
- **Tabulating:** `--table` builds the agreement table from the per-file JSON.
- **The synthetics:** they are graded with `--no-cut`. Their only SPS precedes their first PCR, so a
  cut file has none.

**[`ts-tstd.py`](scripts/ts-tstd.py)** after the fixes:
- **Delivery at TB exit:** each byte leaves TB for B, or for MB, at its own exit time. Byte q of a
  packet leaves at `t0 + max((occ0 + q)/Rx, q·a)`, where a is the packet's per-byte arrival interval
  and occ0 is the fill it found (2.4.2.3).
- **Duplicates:** a packet repeating the previous one's continuity counter and payload costs TB but is
  not delivered (2.4.2.3).
- **Audio PES headers:** they sit in B until the access unit after them is removed (2.4.2.3).
- **The 1 s rule:** every TB is graded on emptying at least once a second, with a stretch's drain
  projected forward so a buffer still holding bytes at the end of the capture is caught (2.4.2.6).
- **AVC buffers:** AVC is the leak model of 2.14.3.1:
  - EBS = cpb_size, and MBS = BSmux + BSoh + 1200 × MaxCPB[level] − cpb_size.
  - Rx = 1.2 × BitRate, and Rbx = 1200 × MaxBR[level], with H.264 Table A-1's limits.
  - Without a NAL HRD, its default is cpb_size = 1200 × MaxCPB, and BitRate = cpbBrNalFactor × MaxBR
    (Table A-2).
  - MB's output is evaluated in closed form, as the min-plus closure of arrivals, EB room and Rbx.
    MB overflow and EB underflow are graded separately. EB cannot overflow, because the leak stops
    while EB is full. The STD delay limit is 10 s.
- **Refusals:** a stream it cannot grade is refused and named, and the exit status is 2, never 0. The
  refused cases:
  - HEVC.
  - The decoder buffers of MPEG-2 video and AAC (their TB is still graded).
  - AVC with no SPS in its first 3 s, or of an untabulated level.
  - A video PES without a timestamp, or one carrying several access units.

Exit 0 is graded and clean, 1 is violated, and 2 is refused with nothing violated. The self-test is
29 checks, 13 of them new controls for these fixes:
- the byte-exact exit of a unit ending on byte 42 of a packet;
- a TB fed at 1.001 × and 0.999 × Rx for 1.5 s;
- bytes left in a TB at the end;
- a PES header tipping B over;
- the level 4.0 sizes;
- MB overflow in the leak;
- EB underflow behind Rbx.

The offset tools (`--scan`, `--window`) re-run the exact models, except that `--window` treats
MB + EB as one buffer.

**[`ts-decode-latency.py`](scripts/ts-decode-latency.py)** gains `--key content`; `--key pts` is
unchanged and remains the default:
- **The key:** each PES on the video PID is digested over its AVC slice NAL units, types 1–5, as
  carried, with emulation prevention and without start codes or trailing zeros. The access unit
  delimiter, SEI and parameter sets are left out.
- **Alignment:** it is monotone, because the egress carries a subsequence of the source in stream
  order. Where a digest recurs, the copy taken is the one after the previous match whose PTS step
  from that match is nearest the egress picture's own step, which a PTS rebase leaves unchanged.
- **What it times:** the tap CSVs and everything downstream are as before.
- **Self-test, 6 checks:**
  - the digest ignores a dropped PPS and the start-code length;
  - it changes with one slice byte, or with emulation prevention removed;
  - repeating content with five pictures dropped, and the PTS rebased across the 33-bit wrap, is
    matched exactly;
  - the same input defeats a naive first-copy match.
- **Regression:** run on T45's four reference runs, the default mode's output and key–value file are
  byte-identical to the committed version.

## Environment

**Grading is offline,** on the saved captures, on one workstation: Python 3.14 and TSDuck 3.44
(upstream's check calls `tsanalyze`). No relay, lane or live run took part.

**Upstream's check is graded at the head of `quest/m1/tstd/README`, `8df1e438`.** That is the #4643
merge, `70e73835`, plus a merge of `dev`, with no change to `test/ts` between them. #4643 merged into
that branch, not into `main`; upstream `main` (`eb3e971c`) still carries an approximate TB-only check
with fixed leak rates. Upstream's own `tstd-controls.py` passes 9 of 9 on this machine.

**The Kyrion fixture** is `rs/moq-mux/src/container/ts/test_data/scte35/kyrion_dirtystart.ts` at the
same commit. It is 1,434,816 B, sha256 `8a04c93b21fa9101f95715714275f5ad88ebf11f36ea8ff929651206a406b039`:
a 4 s contribution feed carrying AVC High@4.0 and two MPEG-1 Layer II tracks.

**The standard is Rec. ITU-T H.222.0 (10/2014),** equivalent to ISO/IEC 13818-1:2015: clauses 2.4.2.3
(T-STD notation and transfer), 2.4.2.6 (buffer management) and 2.14.3.1 (AVC T-STD extension). The
AVC level limits are from Rec. ITU-T H.264 Tables A-1 and A-2.

**The corpus is 35 files:**

| Group | Files | Cut at |
|---|---|---|
| Source clip | `<source>.ts`: H.264 High@4.0 with NAL HRD 8.798 Mb/s, MPEG-1 L2, AC-3, DVB teletext, three SCTE-35 PIDs | first PCR |
| T44 arms | `ffa`, `m11` (300 s and 90 s), `main`, `main-sc`, `t21a`, `srt` (300 s and 90 s), `srt-sc`, `udp`, `udp-sc`; `main-raw` as exported and as groomed | 20 s |
| T44 oracle outputs | source at packet, frame and PES availability; `ffa`, `m11`, `main` at packet availability | 20 s |
| T45 arms | `smoke`, `ffa-L100`, `ffa-L100-w60`, `ffa-L600-w60`, `udp-sc-c100`, `srt-sc-b120-c100` | 5 s |
| Upstream controls | Kyrion as captured; restamped at 1×, 0.7×, 4× and 15× by `tstd-controls.py`'s own builder (TSDuck `pcradjust`) | first PCR |
| Upstream synthetics | `synthetic`, `two AUs, one PES`, `adaptation burst`, `duplicate packet` | uncut |

Every run is P1: a captured file, graded on its own PCR. Every capture is from one clip, on loopback.

## Results

### Defects found in `ts-tstd.py`

**Run as first written, `ts-tstd.py` agreed with upstream on 19 of 35 files.** Of the 16 others:
- **Five** disagreed only through `ts-tstd.py` defects.
- **Four** disagreed through a `ts-tstd.py` defect alongside one of upstream's causes, set out below.
- **Seven** disagreed only through upstream's causes.

One of the 19 agreed only nominally. On `two AUs, one PES`, `ts-tstd.py` passed a stream whose video
it had silently skipped, while upstream refused it.

| Defect in `ts-tstd.py` | Clause | Files where it decided a condition | Example, `ts-tstd.py` against upstream |
|---|---|---|---|
| AVC decoder buffer sized as one EB of cpb + BSmux + BSoh (1,115,696 B) instead of MB + EB (2,666,304 + 1,099,696 = 3,766,000 B) | 2.14.3.1 | `srt-300s`, `srt-90s`, `udp-300s`, Kyrion 4× and 15× | `srt-300s` video: 1,596,408 overflowing arrivals against 0 |
| TB not emptied within 1 s not graded | 2.4.2.6 | `main-sc-300s`, `main-raw` export, `ffa-L100`, `ffa-L100-w60`, Kyrion 4× and 15× | `ffa-L100` video: 0 against 19 stretches |
| Bytes delivered to EB or B on packet arrival, not on TB exit | 2.4.2.3 | none on this corpus; it moves margins and counts | the source clip's MP2 unit at 259.3497 s: +0.333 ms margin at arrival, +0.317 ms at TB exit |
| Audio PES header bytes not held in B | 2.4.2.3 | none; it moves B counts | Kyrion 4× MP2 B overflow: 568 → 576 per PID |
| Duplicate packets delivered to EB or B | 2.4.2.3 | none | `duplicate packet`: one duplicate, now detected and not delivered |
| A stream it cannot grade passed silently | — (method) | `two AUs, one PES`; the synthetic cut at its first PCR, which loses its only SPS | exit 0 → 2 on both |

**The controls, original against fixed `ts-tstd.py`,** on files graded as stored with the default
skip:

| Control | Original | Fixed |
|---|---|---|
| Kyrion 4×, video MB/EB overflow | 4,138 (one EB of 1,115,696 B) | 0 (MB + EB of 3,766,000 B) |
| Kyrion 4×, video TB not emptied within 1 s | not graded | 1 |
| Kyrion 4×, MP2 B overflow, per PID | 568 | 576 (8 more just before a removal, the PES headers now held) |
| Synthetic, cut at its first PCR (no SPS) | exit 0, video skipped | exit 2, refused: no SPS in the first 3 s |
| `two AUs, one PES` | exit 0 | exit 2, refused: several access units in one PES |
| `duplicate packet` | passes, duplicate delivered | passes, 1 duplicate detected and not delivered |
| Source clip | passes | passes |

### The agreement table, `ts-tstd.py` corrected

`ts-tstd.py` fixed, the whole corpus re-graded. The counts are given as `ts-tstd.py` against upstream.
For upstream, "fails" means its `tstd` check returned `WARN` with violations; it reports refusals as
`WARN` too.

| Capture | Cut at | `ts-tstd.py` | upstream | Conditions agreeing | Disagreements |
|---|---|---|---|---|---|
| source | 0 s | passes | fails | 14 of 15 | PID 121 underflow (0 vs 1) |
| T44 `ffa-300s` | 20.0191 s | fails | fails | 15 of 15 | — |
| T44 `m11-300s` | 20.0228 s | fails | fails | 15 of 15 | — |
| T44 `m11-90s` | 20.0199 s | fails | fails | 15 of 15 | — |
| T44 `main-300s` | 20.0047 s | fails | fails | 15 of 15 | — |
| T44 `main-sc-300s` | 20.0005 s | fails | fails | 15 of 15 | — |
| T44 `t21a-300s` | 20.0013 s | fails | fails | 15 of 15 | — |
| T44 `main-raw` export | 20 s | fails | fails | 14 of 15 | PID 123 underflow (0 vs 1) |
| T44 `main-raw` egress | 20.0253 s | fails | fails | 15 of 15 | — |
| T44 `srt-300s` | 20.0143 s | fails | fails | 15 of 15 | — |
| T44 `srt-90s` | 20.0144 s | fails | fails | 15 of 15 | — |
| T44 `srt-sc-300s` | 20.0024 s | passes | fails | 14 of 15 | PID 121 underflow (0 vs 1) |
| T44 `udp-300s` | 20.007 s | fails | fails | 13 of 15 | PID 121 underflow (0 vs 1); PID 123 underflow (0 vs 1) |
| T44 `udp-sc-300s` | 20.0024 s | passes | fails | 13 of 15 | PID 121 underflow (0 vs 2); PID 123 underflow (0 vs 1) |
| T45 `smoke` | 5.0102 s | passes | passes | 15 of 15 | — |
| T45 `ffa-L100` | 5.0045 s | fails | fails | 15 of 15 | — |
| T45 `ffa-L100-w60` | 5.0053 s | fails | fails | 15 of 15 | — |
| T45 `ffa-L600-w60` | 5.0046 s | passes | fails | 14 of 15 | PID 111 underflow (0 vs 1) |
| T45 `udp-sc-c100` | 5.0346 s | passes | fails | 13 of 15 | PID 121 underflow (0 vs 2); PID 123 underflow (0 vs 1) |
| T45 `srt-sc-b120-c100` | 5.0109 s | fails | refuses both audio PIDs | 5 of 5 (video) | — |
| Kyrion as captured | 0 s | passes | passes | 15 of 15 | — |
| Kyrion restamped 1× | 0 s | passes | passes | 15 of 15 | — |
| Kyrion 0.7× | 0 s | fails | fails | 15 of 15 | — |
| Kyrion 4× | 0 s | fails | fails | 13 of 15 | PID 257 STD delay (132 vs 0); PID 258 STD delay (132 vs 0) |
| Kyrion 15× | 0 s | fails | fails | 13 of 15 | PID 257 STD delay (142 vs 0); PID 258 STD delay (142 vs 0) |
| `synthetic` | uncut | passes | passes | 5 of 5 | — |
| `two AUs, one PES` | uncut | refuses | refuses | none compared | — |
| `adaptation burst` | uncut | fails | fails | 5 of 5 | — |
| `duplicate packet` | uncut | passes | passes | 5 of 5 | — |
| oracle source, packet | 20.0158 s | passes | fails | 14 of 15 | PID 121 underflow (0 vs 1) |
| oracle source, frame | 20.0087 s | passes | fails | 14 of 15 | PID 123 underflow (0 vs 1) |
| oracle source, PES | 20.0028 s | passes | passes | 15 of 15 | — |
| oracle `ffa`, packet | 20.014 s | passes | passes | 15 of 15 | — |
| oracle `m11`, packet | 20.021 s | passes | passes | 15 of 15 | — |
| oracle `main`, packet | 20.0214 s | passes | passes | 15 of 15 | — |

**The cut moves no `ts-tstd.py` verdict:** each file's uncut grade at `--skip S` gives the same verdict
as its cut grade.

**Where both checks find a violation, they find the same first one.** There are 94 such rows (PID by
condition). In all 94 the two first violations are within 0.3 ms of each other on the cut file's
clock. For underflow and STD delay, that means the same access unit. The counts are identical on 36
of the 94. On the rest they differ by convention, not by verdict: when fill is checked, upstream's
0.5 B TB tolerance, and the truncated last unit.

### The eleven disagreements

| Cause | Files, PID and first violation (upstream; seconds on the cut file's clock) | `ts-tstd.py` on the same unit | Clause | Verdict |
|---|---|---|---|---|
| **Delivery from TB to B by whole packet** | source 121 at 259.3497; `srt-sc-300s` 121 and `udp-sc-300s` 121 at 232.6163; `udp-sc-c100` 121 at 252.6951; oracle source, packet 121 at 239.161 | complete at its decode time. Margin at byte-exact TB exit: source +0.317, `srt-sc-300s` +0.267, `udp-sc-c100` +0.267, oracle +0.135 ms; upstream finds −0.267, −0.317, −0.317 and −0.449 ms. `udp-sc-300s`'s unit is `srt-sc-300s`'s and was not probed separately | 2.4.2.3: bytes leave TB at Rx and enter B as they leave | **upstream defect** — a false underflow on a clean stream |
| **Floating-point drift in the leak** | `ffa-L600-w60` 111 at 260.8116 | complete | 2.14.3.1: EB underflows when bytes of the unit are absent at its decode time | **upstream defect** — a false underflow |
| **Simulation stops at the last packet** | Kyrion 4× 257 and 258: none flagged | 132 units per PID held over 1 s; the first enters at 0.3152 s and is decoded at 1.3222 s (1.007 s). 15×: 142 per PID, 1.014 s | 2.4.2.6: delay through the STD at most 1 s for audio | **upstream defect** — a missed violation |
| **Last access unit of a truncated capture** | `main-raw` export 123 at 156.9445; `udp-300s` 121 at 275.2025 and 123 at 275.2262; `udp-sc-300s` 121 (second) and 123 at 273.336; `udp-sc-c100` 121 (second) and 123 at 293.4148; oracle source, frame 123 at 300.0408 | not graded: the unit is incomplete in the file | — | **convention** — whether to grade bytes the capture does not hold |

**Delivery by whole packet.** The source clip's unit at 259.3497 s is a 576 B MP2 frame. Its last
byte is byte 42 of a packet that arrives at an empty 2 Mb/s TB. Byte-exact, that byte leaves TB
0.317 ms before the frame's decode time. Upstream delivers a packet's payload only when its last byte
has left, 146 bytes and 0.584 ms later, and so flags the frame as absent. The other four files have
the same structure, and each pair of margins differs by the same 0.584 ms.

**Floating-point drift.** At the unit's decode time, upstream's accumulated leak output is
286,429,515.9999984 B against a unit end of 286,429,516 B. Its tolerance of 10⁻⁹ B is below a double's
resolution at that magnitude, about 6 × 10⁻⁸ B. `ts-tstd.py` evaluates the same leak in closed form
and finds the unit complete.

**Simulation stops at the last packet.** At 4×, the capture's 4 s of content arrives in about 1 s of
PCR time, and its MP2 units then wait over a second for their decode times. Upstream stops removing
units at the time of the last packet, so units decoded after it are never assessed. It still fails
both files, on TB and B overflow, so its verdict is right; the missed condition is the defect.

**Last access unit of a truncated capture.** In each case the PID's last bytes arrive 0.5–2 s before
the capture ends, mid-frame. On `udp-300s`, for example, the last audio delivery is at 273.29 s, the
frame is due at 275.20 s, and the capture ends at 275.24 s. Upstream sizes the frame from its header
and grades the missing bytes as an underflow. On the `main-raw` export it is 206 B short; on the
oracle's frame output, 110 B. `ts-tstd.py` drops a trailing incomplete unit. Neither is wrong under the
standard, which does not speak to bytes a capture never received. For a capture, though, upstream's
convention reports an underflow the stream may not have.

### Coverage differences

- **`srt-sc-b120-c100` audio.** A 22-packet loss at 139.7 s breaks audio sync. Upstream refuses both
  audio PIDs from that point. `ts-tstd.py` grades them and fails them, on 4 MP2 and 7 AC-3 underflows.
  Both grade the video, and agree.
- **Graded by `ts-tstd.py` only.** These are TBsys, the teletext TB, and the TBs of SCTE-35 and SI,
  whose rates are assumed and marked as such. On T44 `main-300s`, for example, TBsys overflows on 3
  packets.
- **Refused by `ts-tstd.py`, absent from the corpus.** These are HEVC, and the decoder buffers of
  MPEG-2 video and AAC. Upstream models HEVC and AAC; neither check was exercised on them here.

### What the fixes move in T44 and T45

No verdict moves: every T44 and T45 capture, graded uncut at its own skip as those tests did, keeps
its pass or fail. [T44](test-44-tstd-grading.md), [T45](test-45-live-tstd-remux.md) and
[T47](test-47-fixed-delay-export.md) now quote the corrected figures; T47's captures, re-graded the
same way, also keep every verdict. The largest moves:

| Capture | Figure | Before | After |
|---|---|---|---|
| T44 `srt-300s` | video decoder overflow arrivals | 1,601,980 | 0 — MB + EB peak 3,180,342 of 3,766,000 B, MB 2,081,690 of 2,666,304 B |
| T44 `srt-90s` | video decoder overflow arrivals | 341,578 | 0 — peak 2,943,962; MB 1,845,091 |
| T44 `udp-300s` | video decoder overflow arrivals | 1,644,181 | 0 — peak 3,184,324; MB 2,086,001 |
| T44 `main-sc-300s` | video TB not emptied within 1 s | not graded | 5 |
| T44 `main-raw` export | video TB not emptied within 1 s | not graded | 10 |
| T44 `main-raw` export | video EB underflows | 2,215 | 5,471 |
| T45 `ffa-L100` | video TB not emptied within 1 s | not graded | 19 |
| T45 `ffa-L100` | MP2 / AC-3 underflows | 1,639 / 1,116 | 1,663 / 1,131 |
| T45 `ffa-L100-w60` | video TB not emptied within 1 s | not graded | 15 |
| T45 `ffa-L100-w60` | video / AC-3 underflows | 6,891 / 25 | 6,901 / 26 |
| T44 `ffa-300s` | MP2 / AC-3 underflows | 9,139 / 3,257 | 9,603 / 3,553 |
| T44 `udp-300s` | MP2 / AC-3 B overflow arrivals | 36,791 / 36,158 | 48,173 / 44,694 |

**The arrival-clocked arms' video does not overflow.** T44's `srt` and `udp` arms through the arrival
clock fit inside 2.14.3.1's MB + EB, with at least 15 % to spare at the peak. They still fail, on audio B
overflow and STD delay: `srt-300s` has 11,123 MP2 and 8,342 AC-3 units held over 1 s.

**The `main-raw` export's video underflows more than doubled.** That export overflows its video TB on
945,320 packets. With delivery at TB exit, the bytes queued behind each burst reach EB later than
they did on arrival. Counts after a TB overflow depend on how a model treats the overflowing bytes.
Both checks keep them and drain them at Rx, and they agree on this file's video.

**Audio counts move, in both directions.** Across the failing captures, audio underflow counts rise by
2–13 %, and B overflow arrivals move by between −5 % and +31 %. The PES headers now occupy B, and
bytes arrive at TB exit. The table gives the largest moves; the per-file JSON holds all of them.

T44's oracle
and T45's live re-multiplexer schedule video against the old, smaller buffer of cpb + BSmux + BSoh.
That is stricter than the standard requires. Their outputs pass the corrected grader, as the table
shows, with headroom they do not use.

### Part B — what survives the lane

Source and egress access units matched by PTS, compared byte for byte and NAL unit by NAL unit:

| T45 capture | Path | Access units | ES byte-identical | Differ | What differs |
|---|---|---|---|---|---|
| `ffa-L600-w60` | media-aware lane `ffa5b81b`, live re-multiplexer | 9,650 | 9,070 | 580 | parameter sets only: 332 lose a repeated PPS ([AUD, PPS, SEI, slice] → [AUD, SEI, slice]); 248 carry SPS/PPS moved ahead of the AUD. AUD, SEI and every slice are byte-identical in all 9,650 |
| `smoke` | re-multiplexer on the source clip | 1,456 | 1,455 | 1 | the capture's last access unit, truncated |
| `udp-sc-c100` | UDP, stream-clocked groomer | 10,781 | 10,773 | 8 | bytes missing: the capture's first seven access units (start-up) and its last |
| `srt-sc-b120-c100` | SRT, stream-clocked groomer | 10,637 | 10,634 | 3 | the capture's first and last, and the one hit by the 22-packet loss at 139.7 s |

**The ES bytes do not survive the media-aware lane unchanged; the slices do.** The key is therefore on
the slice NAL units. The source clip's 19,629 pictures have 19,629 distinct slice digests, so its
alignment for repeated content is exercised only by the self-test.

### Part B — validation

Each arm was run with both keys, over the same egress and the same 10 s settle:

| T45 arm | T45 figure | PTS key on the stored artefacts | Content key | Difference | PTS-key pictures matched, same source picture |
|---|---|---|---|---|---|
| `smoke` | 75.9 ms | 76.0372 ms, 1,092 pictures | 76.0376 ms, 1,091 | +0.0005 ms | 1,091 of 1,092 (99.908 %) |
| `ffa-L600-w60` | 2,196.7 ms | 2,196.7067 ms, 9,270 | 2,196.7067 ms, 9,270 | 0 | 9,270 of 9,270 (100 %) |
| `udp-sc-c100` | 113.7 ms | 113.7142 ms, 10,327 | 113.7142 ms, 10,326 | 0 | 10,326 of 10,327 (99.990 %) |
| `srt-sc-b120-c100` | 234.0 ms | 234.0460 ms, 10,187 | 234.0460 ms, 10,186 | 0 | 10,186 of 10,187 (99.990 %) |

**Against the PTS key on the same bytes, the content key meets both criteria on all four arms.** No
picture it matches is paired with a different source picture than the PTS key chose. The one picture
it drops on each byte-faithful arm is a damaged one:
- **`smoke` and `udp-sc-c100`:** the capture's truncated last picture.
- **`srt-sc-b120-c100`:** the picture at 139.58 s that the loss hit.

The PTS key times all three, because their headers arrived.

**On `smoke` the PTS key itself does not reproduce T45's 75.9 ms.** On T45's saved artefacts, the
committed script reads 76.0 ms with a 6.9 ms spread; T45 quotes 75.9 ms with 9.1 ms from an earlier
computation. Against the quoted figure, both keys are 0.14 ms off. The criterion is met against the
PTS key on the same bytes, which is the comparison it describes; it is not met against the quoted
number.

The content key reports the egress-to-source PTS offset it finds:
- **`ffa-L600-w60`:** −1 tick on 100 % of matches, agreeing with the PTS key's shift.
- **The other three arms:** 0.

### Part B — T44's `main` capture, which the PTS key cannot time

| | |
|---|---|
| Capture | T44 `main-300s`: upstream `main` `9157692f6`, `moq export ts` into the arrival-clocked groomer `5ab84cd` at a 1,000 ms cushion, 2,500 ms cap, 11 Mb/s carrier, subscriber `--max-latency 500ms` |
| Measurement | P1, loopback, one clip, 300 s capture, 10 s settle |
| PTS key | exits 1: no egress PTS within ±4 ticks of a source PTS (egress PTS = source PTS − 2,305,461,943 ticks, a rebase) |
| Content key | 10,864 of 10,865 egress pictures matched, all at that one offset; 10,538 timed over 287.1 s |
| Presentation latency | median **1,775.6 ms**, spread 4.4 ms, trend 0.0 ms |
| Delivery latency | median 3,384.2 ms |
| Egress pre-load | median **−1,007.4 ms**: each picture arrives about a second after its own presentation time on the egress clock |
| T-STD on the same bytes (`ts-tstd.py`, fixed, `--skip 20`) | **fails**: every video unit underflows (10,094 of 10,094, median margin −1,031.7 ms); every MP2 (11,555) and AC-3 (8,661) unit underflows; TB overflows on video (72,686 packets), MP2 (39,860), AC-3 (33,674) and TBsys (3). Upstream's check agrees on all 15 conditions |

**1,775.6 ms is not a latency a decoder delivers.** It is when the egress's own PCR and PTS say each
picture should be shown, and the pictures arrive a second too late for that. A receiver must either
delay its clock or discard them. Whichever it does sets the latency, and this instrument cannot see
which, because it assumes a T-STD-conformant egress.

## Conclusions

### Established

- **`ts-tstd.py` and upstream's check agree on the T-STD verdict of every file where neither has a
  defect.** That holds on this corpus, at offset 0, from an equalised start. Where both find a
  violation, their first violations are within 0.3 ms of each other.
- **`ts-tstd.py` as used in T44 and T45 had six defects, now fixed with controls.** They are the AVC
  buffer size, the ungraded 1 s rule, delivery on arrival, audio PES headers, duplicates, and silent
  passes. None changed a T44 or T45 verdict. They do change the figures listed above, the largest
  being that the arrival-clocked arms' video fits its buffer.
- **Upstream's check, at the commit graded, has three defects against H.222.0 (10/2014).**
  - It delivers TB to B by whole packet (2.4.2.3), which fails five clean files by 0.27–0.45 ms.
  - Floating-point drift in its leak exceeds its tolerance (2.14.3.1): one false underflow.
  - It does not assess units decoded after the last packet (2.4.2.6), and misses STD-delay violations.

  It also grades a capture's truncated last access unit as an underflow, which is a convention.
- **The media-aware lane on `ffa5b81b` passes AVC slices, AUD and SEI byte-identical.** It drops
  repeated PPS and moves SPS/PPS ahead of the AUD.
- **`ts-decode-latency.py --key content` reproduces the PTS key on T45's four reference runs,** and
  times a PTS-rebased capture the PTS key cannot.

### Not established

- **Agreement on HEVC, MPEG-2 video or AAC.** None is in the corpus, and `ts-tstd.py` refuses their
  decoder buffers. A broadcast HEVC or AAC clip graded by both checks would settle it.
- **Agreement on other programs and encoders.** The corpus is one clip and its derivatives, plus one
  4 s Kyrion capture. Agreement on a second encoder's long capture would generalise it.
- **A presentation latency for upstream `main`.** The one figure obtained is on bytes that fail the
  T-STD, so it is not a viewer's latency. That needs a `main` or fixed-delay capture whose egress
  passes both checks, which is planned experiment P0-m.
- **Whether the content key survives other lanes.** It is validated on the media-aware lane at
  `ffa5b81b` and on byte-faithful carriage. A lane that re-encodes, or rewrites slice headers, would
  defeat it. Its pictures would go unmatched, which shows as a low match rate rather than a wrong
  figure.

## Limits

- **Margins are quoted at byte-exact TB exit.** Where the two checks' first violations are compared,
  times are rounded to 0.1 ms.
- **`--window` in `ts-tstd.py` treats MB + EB as one buffer.** The whole-capture grade models them
  separately. A window verdict on an AVC stream near MB's limit is therefore approximate.
- **Counts after a TB overflow are model conventions.** Both checks queue the overflowing bytes; a
  model that discarded them would count differently. Verdicts do not depend on it.
- **The truncated-unit convention decides an audio underflow condition on five files:** the
  `main-raw` export, `udp-300s`, `udp-sc-300s`, `udp-sc-c100` and the oracle's frame output. The
  stream beyond a capture's end is unknown, so neither check's verdict on that unit is evidence about
  the stream.
- **T44's oracle and T45's re-multiplexer still schedule against the old video buffer.** It is
  smaller than 2.14.3.1's, so they are conservative, not wrong.
- **Part B's alignment for repeated content is shown only on a synthetic sequence.** No capture here
  repeats a slice digest. The first match in a capture takes the first copy of its digest.

## Reproduction

```bash
# upstream's check, its controls and the Kyrion fixture, at the commit graded
Q=8df1e438bc8f1ba4d28dc22050825d807be6e956
for f in compliance.py pcr-timing.py tstd-controls.py README.md; do
	gh api "repos/moq-dev/moq/contents/test/ts/$f?ref=$Q" --jq .content | base64 -d > <upstream>/test/ts/$f
done
D=rs/moq-mux/src/container/ts/test_data/scte35
B=$(gh api "repos/moq-dev/moq/contents/$D?ref=$Q" --jq '.[] | select(.name=="kyrion_dirtystart.ts") | .sha')
gh api "repos/moq-dev/moq/git/blobs/$B" --jq .content | base64 -d > <upstream>/$D/kyrion_dirtystart.ts
python3 <upstream>/test/ts/tstd-controls.py            # 9 of 9 ok

# the restamps and synthetics, built by tstd-controls.py's own builders
(cd <upstream>/test/ts && python3 -c '
import importlib.util as u
s = u.spec_from_file_location("c", "tstd-controls.py"); c = u.module_from_spec(s); s.loader.exec_module(c)
for name, build, _ in c.CASES[1:]:
	build("<scratch>/kyrion/" + name.replace(",", "").replace(" ", "-") + ".ts")')

# the instruments' own controls
python3 lab/scripts/ts-tstd.py --selftest               # 29 of 29 ok
python3 lab/scripts/ts-decode-latency.py --selftest     # 6 of 6 ok

# one file through both checks: S = 20 (T44 arms and oracle outputs), 5 (T45), 0 (source, Kyrion);
# --no-cut instead of --skip for the synthetics
python3 lab/scripts/tstd-xval.py <capture>.ts --upstream <upstream>/test/ts --skip <S> \
	--label <label> --json <scratch>/xval/<label>.json --scratch <scratch>/cut
python3 lab/scripts/tstd-xval.py --table <scratch>/xval/*.json

# presentation latency by content, on a T45 arm or T44's main capture
python3 lab/scripts/ts-decode-latency.py <source>.ts <out>/<arm>-c<cushion>-source.csv \
	<out>/<arm>-c<cushion>-egress.ts <out>/<arm>-c<cushion>-egress.csv --key content --kv <out>/pres-content.kv
```

Run one grader at a time: each holds a whole capture in memory, about 400 MB for a 300 s capture.

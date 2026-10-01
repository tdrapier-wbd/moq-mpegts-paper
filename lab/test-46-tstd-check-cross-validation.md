# Test 46 — Two T-STD checks cross-validated, and a content key for presentation latency

**State: criteria fixed; not yet run.**

## Objective

1. **Do `ts-tstd.py` and upstream's T-STD check agree?** Upstream moq-dev/moq merged a full
   ISO/IEC 13818-1 T-STD check into `test/ts/compliance.py` (PR #4643). This campaign's
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

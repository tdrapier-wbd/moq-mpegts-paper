# T86 — OpenMOQ's `moq2ts` through the campaign's tests

**State: P2-r and P2-s run; `moq2ts` passes both, and neither found an issue to file.** Roadmap rows P2-r to P2-w put the campaign's tests to `moq2ts`'s headless publisher (`moq2ts-cli`) and console receiver (`moq2ts-receiver`), beside `moq-dev`'s own pair on the same clips and graders. Each row is a section here. A gap found becomes one issue on `moq2ts`, saying when it is a difference between `moq-dev` and the MoQT draft rather than a defect (OpenMOQ's request).

## Environment

- Laptop loopback. `moq2ts` `main` `044c190372` built headless: `moq2ts-cli` on the `moqxr` v0.4.21 SDK (QtCore and QtGui, no Widgets), `moq2ts-receiver` on moq5 `main` `392a8a2` (service, MSF and MPEG-2 TS, picoquic), no Qt.
- `moq-dev` `f1eecd3a7` (relay and CLI, thin LTO). It carries the media-aware regression [#9081](https://github.com/moq-dev/moq/issues/9081), which touches neither passthrough nor the relay ([T67](test-67-import-step-restart.md) passes byte for byte on it).
- Rig: [`t11d-arm.sh`](scripts/t11d-arm.sh). Arm A is `moq2ts-cli --unmodified --paced` → `moq-relay` → `moq2ts-receiver` on MoQT draft 22 or 18, objects of 250 ms (`--fragment-ms 250`, `--segment-bytes` a quarter of a second of the clip). Arm M is `moq-dev`'s pair, `import ts --passthrough` → `moq-relay` → `export ts --passthrough`, on `moq-lite-07`, the only protocol on which `moq-dev` lists its passthrough track.

## P2-r — output conformance

The three reference clips the laptop holds that are T-STD-conformant as sources: `fixture-10m` (synthetic, 240 s, 9.95 Mb/s), `contrib-5m` (news contribution, 300 s, 9.95 Mb/s) and `live300` (the live feed at hand-off, 300 s, 25 Mb/s, no nulls). `testloop`, T7's fourth clip, is not T-STD-conformant and is not here. Arm A on both drafts and arm M, one run per clip.

_Criteria, fixed before running:_

1. **Validity.** The source, graded by [`t12-analyse.sh`](scripts/t12-analyse.sh), gives zero continuity errors and zero `pcrverify` violations at ±500 ns.
2. **The clip passes whole.** Every run reaches the clip's end with no session or group abort, and its output is the source's own bytes from the join to the end ([`ts-passthrough-identity.py`](scripts/ts-passthrough-identity.py): no gap, nothing foreign, nothing repeated).
3. **The file domain is the source's.** On the output `t12-analyse.sh` gives the source's verdict over the same span: continuity errors, PCR intervals above 40 ms, PCR steps back, `pcrverify` violations.
4. **Reported, not graded: the release domain.** The share of PCRs each output releases more than 10 ms from the interval its PCR asserts ([`ts-pcr-timing.py`](scripts/ts-pcr-timing.py) `--live`), and its p95. `moq2ts-receiver` is a capture tool that writes each object as it lands; `moq export ts --passthrough` paces on the PCR.

_Results._ Every source is valid (criterion 1), and every run of the nine meets criteria 2 and 3. Each output is its source's bytes, in order, from the join to the end, and gives the source's verdict: no continuity error, no PCR interval above 40 ms, no step back, no `pcrverify` violation. Drafts 22 and 18 deliver the same bytes.

| Clip | Arm | Joins at source packet | PCRs released outside ±10 ms | p95 | Worst |
| --- | --- | --: | --: | --: | --: |
| `fixture-10m` | A, draft 22 | 0 | 100 % | 221 ms | 261 ms |
|  | A, draft 18 | 0 | 100 % | 221 ms | 261 ms |
|  | M | 15,872 | 0.1 % | 2.5 ms | 42 ms |
| `contrib-5m` | A, draft 22 | 0 | 99.1 % | 219 ms | 264 ms |
|  | A, draft 18 | 0 | 99.1 % | 219 ms | 304 ms |
|  | M | 13,777 | 0.5 % | 1.9 ms | 75 ms |
| `live300` | A, draft 22 | 0 | 85.3 % | 210 ms | 329 ms |
|  | A, draft 18 | 0 | 84.9 % | 208 ms | 312 ms |
|  | M | 37,987 | 1.6 % | 3.0 ms | 160 ms |

_Conclusions._

1. **`moq2ts` carries a conformant transport stream through `moq-relay` unchanged, on both drafts.** Its file-domain conformance is the source's on all three clips. P2-r found nothing to report as an issue.
2. **The release domain is the receiver's design, not a defect.** `moq2ts-receiver` writes each 250 ms object as it lands, so a PCR leaves up to an object's duration early or late, against `moq-dev`'s export, which paces on the PCR to within 3 ms at p95. A receiver feeding a decoder in real time would need a pacing stage after it. That is a capability `moq2ts` does not claim, so it is noted here, not filed.
3. **The two receivers join differently.** `moq2ts-receiver`, started 3 s after its publisher, receives from the clip's first packet. `moq export`, also started 3 s after its publisher, joins at the group then current, about 2.3 s of programme in. P2-u grades the late join itself.

## P2-s — PCR discontinuities

T23's six stimuli on a 110 s cut of `contrib-5m`, one event 45 s in: A back 1 s, B back 600 s, C forward 30 s (all three flagged), D the 33-bit rollover (unflagged, by definition), E an encoder restart to zero (flagged, counters reset), F the control. Then T64's two unflagged encoder switches, back and forward, 30 s into a 60 s synthetic stream at 6 Mb/s. Arm A on draft 22 and arm M, one run per stimulus, with [`t86-arrival-tap.py`](scripts/t86-arrival-tap.py) in place of release timing: release graded against the stream's own PCR means nothing across a discontinuity. Both publishers pace on the PCR (`moq2ts-cli --paced`; `tsp -P regulate --pcr-synchronous` ahead of `moq import`), so the event is put to the pacing as well as to the path.

_Criteria, fixed before running:_

1. **The control is clean.** Arm F passes whole, as P2-r's criterion 2, and sets the run's baseline: its longest read gap after the join.
2. **Nothing is lost.** Each arm's output is the stimulus's bytes from the join to the end, as P2-r's criterion 2.
3. **Nothing stalls.** The longest read gap within 10 s of the event is within 0.5 s of the control's longest, and the output ends within 1 s of where the control's does, counted from each run's first byte.

_Results._ `moq2ts` meets every criterion on every stimulus. Graded by [`t86-arrival-grade.py`](scripts/t86-arrival-grade.py); T64's pair has no control of its own, so its span is read against its 60 s stimulus.

| Stimulus | `moq2ts` (arm A): whole | Longest gap near the event | Span | `moq-dev` (arm M) |
| --- | --- | --: | --: | --- |
| F, control | yes | 278 ms (longest 283 ms) | 108.8 s | whole; 107.0 s |
| A, back 1 s | yes | 279 ms | 108.8 s | the import exits at the event |
| B, back 600 s | yes | 274 ms | 108.8 s | the import exits at the event |
| C, forward 30 s | yes | 279 ms | 108.8 s | whole; 35 ms; 107.0 s |
| D, rollover | yes | 301 ms | 109.0 s | whole; 33 ms; 107.0 s |
| E, restart to zero | yes | 299 ms | 108.8 s | the import exits at the event |
| T64 back | yes | 314 ms | 59.3 s | the import exits at the switch |
| T64 forward | yes | 349 ms | 59.3 s | 98 packets lost at the switch |

_Conclusions._

1. **`moq2ts` carries every PCR discontinuity class unchanged and without a stall.** Its pacing neither sleeps through the 30 s forward jump nor waits out the 600 s rewind; the longest read gap near any event is within 70 ms of the control's, which is one 250 ms object. P2-s found nothing to report as an issue.
2. **`moq-dev`'s arm is T67's parent and repeats it**: on `f1eecd3a7` the passthrough import ends at every step back and loses packets at the unflagged step forward, both of which [#9069](https://github.com/moq-dev/moq/pull/9069) fixes ([T67](test-67-import-step-restart.md)). Here the gap is 98 packets, against T67's 197 on its supervisor's lane.

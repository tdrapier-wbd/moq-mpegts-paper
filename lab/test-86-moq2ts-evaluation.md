# T86 — OpenMOQ's `moq2ts` through the campaign's tests

**State: P2-r to P2-w run. `moq2ts` passes P2-r and P2-s; P2-t found three issues, filed; two are fixed and verified, and the third still costs it 42.7 s on a publisher restart against `moq-dev`'s 14 s. P2-u: both pairs carry 9.95 Mb/s whole to 1 % random loss and neither from 3 %, where `moq2ts` loses 2.6–12.5 s more than `moq-dev`'s `main`; a late join is prompt on both. P2-v: it carries a multiplex whole and each programme as its own track with nothing lost, but joins a programme 4.3–4.6 s after start-up, past the 3 s allowed. P2-w: it carries the live feed unchanged, byte for byte through its captured splice, as `moq-dev`'s passthrough does.** Roadmap rows P2-r to P2-w put the campaign's tests to `moq2ts`'s headless publisher (`moq2ts-cli`) and console receiver (`moq2ts-receiver`), beside `moq-dev`'s own pair on the same clips and graders. Each row is a section here. A gap found becomes one issue on `moq2ts`, saying when it is a difference between `moq-dev` and the MoQT draft rather than a defect (OpenMOQ's request). [`kits/t86/`](kits/t86/README.md) reruns every cell from synthetic inputs, for builds we have not tested. On `moq2ts` `044c190` and `moq-dev` `b45179d39b` it gives each verdict here, except that `moq-dev` now carries every PCR step and loop wrap whole and `moq2ts`'s programme 3 joins late too (91–92 % of its video).

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

## P2-t — restarts and loop wraps

T28's infrastructure axis on loopback, [`t86-restart.sh`](scripts/t86-restart.sh): `tsp` plays a 150 s cut of `contrib-5m` once at its PCR rate to a local UDP port, which each publisher instance reads through its own `tsp`, so a killed publisher takes nothing upstream with it. The publisher, `moq-relay` and the receiver each run under a supervisor that restarts them 0.5 s after they exit, and 60 s in one of them gets SIGKILL. Arm A is `moq2ts-cli` (live, from stdin; it reconnects by itself) and `moq2ts-receiver` on draft 22; arm M is `moq-dev`'s passthrough pair. A fifth cell, in place of T41's loop wraps, plays a 30 s cut five times over, four unflagged wraps, with nothing killed. One run per cell and arm.

_Criteria, fixed before running:_

1. **The control is clean.** With nothing killed, each arm's output is the source's bytes from its join to the end, and each component starts once.
2. **Each kill is recovered.** After the cell's kill, the output resumes without intervention beyond the supervisor's restarts, and from there to the end is the source's bytes.
3. **`moq2ts` loses no more than `moq-dev`.** Per cell, arm A's programme lost (the source packets missing from its output, in seconds of the clip) is within 1 s of arm M's.
4. **The wraps pass.** In the wrap cell the output is the source's bytes from the join to the end, and no component exits.
5. **Reported:** per cell, the outage (the longest read gap) and every component's exits.

_Results._ Graded by [`t86-restart-grade.py`](scripts/t86-restart-grade.py); the receiver cell's two instances are graded apart, because the restarted one rejoins at the start of a group the first had begun, and the identity grader matches forwards only. Programme lost is in seconds of the clip.

| Cell | `moq2ts` lost | Its outage | `moq-dev` lost | Its outage |
| --- | --: | --: | --: | --: |
| Control | 0 | 0.41 s | 0 | 0.14 s |
| Publisher killed (three runs) | 42.74, 42.74, 15.47 s | 41.9, 41.8, 11.8 s | 14.08, 14.08, 11.34 s | 14.1, 14.1, 11.4 s |
| Relay killed | 12.91 s | 10.0 s | 13.81 s | 13.8 s |
| Receiver killed | 0 (1,385 packets repeated) | 0.63 s | 1.58 s | 1.61 s |
| Four loop wraps | 0 | 0.14 s | 9.67 s | 2.91 s |

Criterion 1 holds, read against two things every run shares, the control included: the receiver's retries before the publisher's first catalog exists, and the last partial object each publisher holds once its input stops (287 packets on `moq2ts`, 35 on `moq-dev`). Criterion 2 holds in every cell: `moq2ts-cli` reconnects to a restarted relay without exiting. Criterion 3 fails on the publisher cell and holds on the other two. Criterion 4 holds for `moq2ts`; `moq-dev`'s import exits at each wrap, as at every step back on this build ([P2-s](#p2-s--pcr-discontinuities)).

_What the publisher cell's loss is made of._ With the relay at `debug`, three more runs all took the slow course:

- **The restarted publisher is refused until the relay drops its dead predecessor.** Each time `moq2ts-cli` connects, `moq-relay` advertises the namespace it still holds, and `moqxr` answers the PUBLISH_NAMESPACE with an error and then closes its own session. It gets in only after the relay's 10 s idle timeout drops the dead session, at its next back-off step: 75.0 s for a kill at 61.1 s. The same refusal stops two publishers sharing a relay: each ends the other's session within 30 ms of the second connecting, on drafts 18 and 22.
- **The receiver stays on its ended subscription for 30 s.** When the dead session drops, the relay withdraws the namespace and ends the receiver's two subscriptions with PUBLISH_DONE (status 0, "internal error"), counting 2 and 51 data streams; at the same instant it resets a fill stream and opens a stream for group 0. `moq2ts-receiver`'s library, moq5, keeps a subscription until it has processed as many streams as PUBLISH_DONE counts, or for its default 30 s (`MOQ_DONE_WAIT_DEFAULT_US`, floored by any negotiated delivery timeout, of which there are none here). In one run of six the counts met and the receiver left at once; in the other five it left 30 s later, 102.9 s, while the new publisher had been in since 75.0 s. That wait is the difference between 42.7 s and `moq-dev`'s 14 s.
- **The receiver never answers a PUBLISH_NAMESPACE.** The relay advertises the new publisher's namespace to it and logs "no answer to the advertisement" every 5 s.

_Conclusions._

1. **`moq2ts` matches or beats `moq-dev` on a relay or receiver restart and across loop wraps**; on a publisher restart it loses 42.7 s in five runs of six against 11–14 s.
2. **Three findings for OpenMOQ.** The first is a `moqxr` defect, not a difference between `moq-dev` and the draft: drafts 18 and 22 let a publisher send PUBLISH_NAMESPACE to any subscriber, and require exactly one OK or error in answer. The third is a receiver defect for the same reason. The second is neither side's defect against the draft, which has the stream count include fill streams and the subscriber wait at least the delivery timeouts after PUBLISH_DONE: it is moq5's 30 s default meeting streams the relay counts and the receiver never processes, and is reported to `moq2ts` ([#73](https://github.com/openmoq/moq2ts/issues/73)) as a default worth changing in a live receiver.

### Re-check of the first and third findings' fixes

`moqxr` v0.4.25 carries [moqxr#157](https://github.com/openmoq/moqxr/pull/157); moq5 `main` carries [moq5#71](https://github.com/openmoq/moq5/pull/71), which refuses a PUBLISH_NAMESPACE the receiver does not serve. The [kit](kits/t86/README.md)'s cell `t`, arm A, with the relay at `debug`, and two publishers on one relay, each with its own namespace and receiver, for 60 s on drafts 22 and 18.

_Criteria, fixed before running:_

1. **The restarted publisher stays in.** In the publisher cell, the relay logs an answer to each PUBLISH_NAMESPACE it sends `moq2ts-cli`, and the restarted CLI's first session lasts to the end of the run.
2. **Two publishers share a relay.** On both drafts each publisher keeps one session for the whole run, and each receiver's output is its source's bytes from the join to the end.
3. **The receiver answers.** In every cell the relay logs no "no answer to the advertisement", and logs an answer to each PUBLISH_NAMESPACE it sends a receiver.
4. **Reported:** cell `t`'s programme lost per kill, beside P2-t's.

_Results._ `moq2ts` `main` `be3a18d` on the `moqxr` v0.4.25 SDK and moq5 `main` `3f1e2fc`, relay `b45179d39b`; one run each.

- **Criterion 1 holds.** The restarted CLI connects 0.5 s after the kill. The relay advertises the namespace its dead predecessor still holds; the CLI refuses it (code 3, "publisher does not accept PUBLISH_NAMESPACE") and keeps that session to the end of the run.
- **Criterion 2 holds on both drafts.** Each publisher, on `--no-reconnect`, runs its 60 s and exits at the clip's end, and each output is its source's bytes from the join to the end with no gap.
- **Criterion 3 holds for every live session.** Each receiver session refuses each advertisement with code 3, the draft's `NOT_SUPPORTED`. The one "no answer" in any log is the killed publisher's session, 6.6 s after its SIGKILL and before the idle timeout drops it; the criterion should have excepted a dead peer.
- **Cell `t`** loses 43.26 s on the publisher kill, 13.32 s on the relay's and 0.06 s on the receiver's, with none across the loop, as on `044c190` with v0.4.21. The publisher cell's cost is now [#73](https://github.com/openmoq/moq2ts/issues/73)'s 30 s wait alone: [moq5#74](https://github.com/openmoq/moq5/pull/74) makes it settable, and `moq2ts-receiver` does not yet set it.

## P2-v — multi-programme streams

[T10](test-10-mpts-multiservice.md)'s fixtures, rebuilt by [`make-real-mpts.sh`](scripts/make-real-mpts.sh): `mpts3.ts`, three programmes on independent clocks (programme 1 the news contribution with seven elementary streams, 2 video only, 3 video and audio), and `mpts3-cc.ts`, the same on one clock. 60 s at 19.9 Mb/s. [`t86-mpts.sh`](scripts/t86-mpts.sh) releases the fixture once through `tsp -P regulate --pcr-synchronous` into the publisher's stdin, every receiver started first. Two cells, each on both implementations:

- **Unmodified multiplex (U).** Arm A: `moq2ts-cli --unmodified`, one `unmodified-multiplex` track, read by `moq2ts-receiver`. Arm M: `import ts --passthrough` → `export ts --passthrough`. T10 never ran passthrough carriage of a multiplex.
- **Per programme (P).** Arm A: `moq2ts-cli --config` with programmes 1, 2 and 3 keeping all DVB SI, one `moq2ts-receiver --track program-<n>` per programme. Arm M: `import ts --program all` → one `export ts` per programme broadcast, T10's split, on `moq-lite-07` so that #9081 does not touch programme 1's field-coded video.

`moq2ts` on draft 22; one run per fixture, cell and arm. Graded by [`t10-grade.py`](scripts/t10-grade.py), per programme, and in cell U also by `ts-passthrough-identity.py`.

_Criteria, fixed before running:_

1. **Validity.** Each fixture gives 0 continuity events and every PCR within 13 ticks on `pcrverify`, as T10's did.
2. **Cell U carries the multiplex whole.** The output is the fixture's bytes from the join to the end, and every programme is CARRIED, its PMT bit-identical.
3. **Cell P carries each programme.** Each programme's capture grades it CARRIED: its own PAT entry and PMT, its PCR on its own PID with no interval above 40 ms, every elementary stream present with its stream type and descriptors, 0 continuity events. Its video delivers at least 95 % of the source's packets, which allows a 3 s join.
4. **Reported, not graded:** PMT bit identity and SI (SDT, EIT present/following) per programme in cell P, audio and SCTE-35 packet counts, the join, and either arm's difference between the two fixtures.

_Results._ Both fixtures are valid: 0 continuity events, every checked PCR within 13 ticks (criterion 1). Every one of the 16 captures grades its programme CARRIED, with 0 continuity events, no PCR interval above 40 ms, every elementary stream present with its stream type and descriptors, and the SDT entry and EIT present/following sections identical to the source's. The table gives each programme's video packets delivered as a share of the source's, `mpts3` / `mpts3-cc`:

| Programme | U, `moq2ts` | U, `moq-dev` | P, `moq2ts` (its join) | P, `moq-dev` |
| --- | --: | --: | --: | --: |
| 1, seven ES, field-coded | 96.3 / 96.3 % | 99.6 / 99.6 % | 92.4 / 92.4 % (4.6 s) | 97.9 / 97.9 % |
| 2, video only | 98.4 / 97.3 % | 100 / 100 % | 92.9 / 92.9 % (4.3 s) | 100.3 / 97.1 % |
| 3, video and audio | 99.3 / 98.3 % | 100 / 99.9 % | 97.4 / 97.5 % (2.4, 2.1 s) | 98.7 / 95.3 % |

- **Cell U (criterion 2 holds on both arms).** Each output is the fixture's bytes from the join to the end, and every PMT is bit-identical. `moq2ts` joins 2.2 s in, `moq-dev` 0.24 s.
- **Cell P, `moq-dev` (criterion 3 holds).** Programme 1's PMT is rebuilt (structure identical, bytes not), as in T10's split; programmes 2 and 3 are bit-identical. Each programme's export is padded to the multiplex's 19.9 Mb/s: programme 2's capture is 91 % null packets.
- **Cell P, `moq2ts` (criterion 3 fails on programmes 1 and 2, on the join alone).** Filtered to its programme's elementary streams, each capture is the source's packets in order from its join to the fixture's end, with no gap; every PMT is bit-identical and no nulls are added. The join, 4.3–4.6 s on programmes 1 and 2, exceeds the 3 s the criterion allows. At start-up `moq2ts-cli --config` reads about 1 s of PCR time for each programme's PAT and PMT before it publishes the catalog, then starts each programme at its next random access point. On `mpts3.ts` programme 2's first PMT comes between 1 and 2 s in, so it opens late and joins the catalog then, as documented; its join is the same on `mpts3-cc.ts`, where it opens at once.
- **The receiver exits at once while no catalog exists** (`no MSF catalog received`), so the rig restarts each `moq2ts-receiver` until its first byte, as [P2-t](#p2-t--restarts-and-loop-wraps)'s supervisor did.

_Conclusions._

1. **Both implementations carry a multiplex whole on MoQ**: `moq2ts --unmodified` and `moq-dev`'s passthrough deliver the fixture's own bytes from the join, every programme with its PAT entry, PMT, PCR and SI, on independent and common clocks. This is the passthrough carriage of a multiplex that T10 left unrun.
2. **Both carry each programme as its own track.** `moq2ts` forwards a programme's packets unchanged, PMT included, and adds nothing; `moq-dev` rebuilds programme 1's PMT and pads every programme to the multiplex's rate. Neither loses anything after its join. `moq2ts`'s start-up join is the longer: 4.3–4.6 s on programmes 1 and 2, where `moq-dev`'s video shares imply under 3 s. A late join to a running broadcast is P2-u's.
3. **Nothing to file.** The late PMT is handled as `moq2ts` documents it, and the start-up join is a property of reading the PSI before publishing, not a defect.

## P2-u — loss on the path, and a late join

T5's loss ladder and the late join P2-v deferred, on the laptop. The shaper is [`t86-lossy-udp.py`](scripts/t86-lossy-udp.py), a userspace UDP proxy between `moq-relay` and the receiver: on the payload direction it adds 15 ms, T5's base delay, and drops each datagram with the rung's probability (Bernoulli, as T5's `netem`), counting what it passes and drops; the other direction passes untouched. It replaces T5's `tc` on a Linux host, so its figures compare the two implementations in one rig, not with T5's. No datagram is segmented (`moq` runs with GSO off; macOS has no UDP GSO). The relay pins `--quic-congestion-control bbr`, its default. Rig [`t86-loss.sh`](scripts/t86-loss.sh): `tsp -P regulate` plays the source once into the publisher's stdin, live; the receiver's output is tapped every 100 ms ([`t67p-tap.py`](scripts/t67p-tap.py)). Arm A is `moq2ts-cli --unmodified` → `moq2ts-receiver`, draft 22; arm M is `moq-dev`'s passthrough pair, `moq-lite-07`.

- **Loss ladder (L).** A 60 s cut of `contrib-10m` (9.95 Mb/s), the receiver started first; loss 0, 0.1, 1, 3, 5 and 10 %.
- **Late join (J).** No loss; the receiver starts 20 s after the source. J1: the 60 s cut, as L. J2: `mpts3.ts` per programme, as P2-v's cell P ([`t86-mpts.sh`](scripts/t86-mpts.sh) with `JOIN_AT=20`).

One run per cell and arm.

_Criteria, fixed before running:_

1. **The shaper is valid.** Rung 0 drops nothing; every other cell's measured drop share is within half to one and a half times the rung's. Each row is labelled with the measured share.
2. **The control is clean.** At rung 0 each arm's output is the source's bytes from the join to the end.
3. **A rung is passed whole** when the output is the source's bytes from the join with no gap and no continuity error, and ends within 1 s of the source's end. Reported per rung: programme lost, continuity errors, the longest read gap.
4. **`moq2ts` loses no more than `moq-dev`.** At each rung arm A's programme lost is within 1 s of arm M's.
5. **A late receiver starts promptly.** In J1 and J2 every receiver writes its first byte within 3 s of starting, and from there to the end loses nothing (J1: the source's bytes; J2: as P2-v's criterion 3, less its join allowance).
6. **Reported:** in J1, where the first byte sits in the source and how far behind the live edge it is when it lands; in J2, each programme's first-byte delay.

_Discriminator, fixed after the ladder and before running it._ From 3 % both arms lose most of the clip. The relay's BBRv3 treats loss above about 2 % in a round as congestion, so the ladder's 3 % and 5 % rungs are re-run with the relay on `cubic` (`RELAY_CC=cubic`), both arms. If both pass whole there, the cliff is the relay's congestion controller, not either receiver; if not, it is not the controller alone.

_Results._ Graded by [`t86-loss-grade.py`](scripts/t86-loss-grade.py) and, in J2, as P2-v. The shaper is valid (criterion 1): rung 0 drops nothing, and every other cell measures within 0.07 points of its rung below 3 % and within 0.62 above. Programme lost, in seconds of the 60 s source, with continuity errors; an export that exits is placed in the source:

| Rung (measured) | Arm A, `moq2ts` | Arm M, `moq-dev` `f1eecd3a` | Arm M, `moq-dev` `main` `b45179d39b` |
| --- | --: | --: | --: |
| 0, 0.13, 1.07 % | 0, whole | 0, whole | 0, whole (rung 0) |
| 3.1 % | 27.7 (226) | 19.8 (337) | 15.2 (340) |
| 5.2–5.4 % | 45.7 (154) | 51.7 (62), export exits at 14 s | 35.4 (470) |
| 10.3–10.4 % | 50.7 (88) | 56.2 (86), export exits at 41 s | 48.1 (420) |
| 3.2–3.6 %, `cubic` | 48.0 (144) | 56.6 (54), export exits at 8 s | 37.2 (463) |
| 5.1–5.6 %, `cubic` | 49.2 (111) | 57.3 (40), export exits at 7 s | 42.6 (477) |

- **To 1 % both arms pass whole (criteria 2 and 3 hold there); from 3 % neither does.** Arm A's 1.07 s longest read gap at rung 0, against arm M's 32 ms, is its final read, which waits for the publisher's held last object; before it, reads are at most 73 ms apart ([Corrections](#corrections)). Each starts 3.1–3.5 s after the receiver starts, as both wait for the source's first group.
- **Criterion 4 fails at every lossy rung against `moq-dev`'s `main`**, where `moq2ts` loses 2.6–12.5 s more. On `f1eecd3a` it failed at 3 % alone: at 5 % and 10 % `moq-dev`'s export ended, reading the starved source's clock as running 18,000–276,000 ppm slow and exiting once the shortfall had used half its delay. On `main` (re-run with the relay's anonymous grant written as the prefix `""`, which it requires) the export plays on with gaps, as `moq2ts-receiver` does; it still logs the shortfall as drift, up to 8,700 ppm, but no longer fails on it.
- **The discriminator fails: `cubic` does worse.** At 3 % arm A loses 48.0 s against 27.7 s on BBRv3, arm M on `main` 37.2 s against 15.2 s. The cliff is therefore not BBRv3's loss threshold alone. Both arms fall together and the relay's controller moves it, so the rig puts it in the relay's sending through random loss, not in either receiver. A loss-based controller on this 15 ms path at 3 % random loss sustains about 4.5 Mb/s by the Mathis bound, under half the clip's 9.95 Mb/s; that is a reading, not a measurement.
- **Late join (criterion 5 holds on both arms).** In J1 each output is the source's bytes from its first byte to the end. `moq2ts` writes 0.41 s after starting, 20.24 s into the source and 0.22 s behind the live edge; `moq-dev` writes after 1.08 s, at 20.09 s and 1.05 s behind. In J2 every capture grades its programme CARRIED, every PMT as in P2-v, and `moq2ts`'s are, filtered to their elementary streams, the source's packets from the join to the end with no gap. First-byte delays are 0.63, 1.65 and 0.81 s on `moq2ts`, 0.73, 0.46 and 1.71 s on `moq-dev`, for programmes 1, 2 and 3.
- **A late `moq2ts-receiver` does not see the track end.** In J1 it holds its last object until its `--duration` expires, 20 s after the publisher exits, where at rung 0 it ends within 1.2 s. This is consistent with [#73](https://github.com/openmoq/moq2ts/issues/73)'s mechanism: the PUBLISH_DONE stream count includes streams a late joiner never received.

_Conclusions._

1. **On a lossy path the two implementations stand or fall together.** Both carry 9.95 Mb/s whole to 1 % random loss on a 15 ms path, and neither carries it from 3 %. The relay's congestion controller shifts the cliff and the receivers do not, so it is a property of the transport under random loss. These figures compare the two implementations in one userspace rig; they do not replace T5's.
2. **Through the same loss `moq-dev` delivers more.** On its current `main` both receivers write through the gaps, and `moq2ts` loses 2.6–12.5 s more of the 60 s at every lossy rung.
3. **A late join is prompt on both, and per programme too.** `moq2ts` joins a running broadcast or programme within 0.4–1.7 s, closer to the live edge than `moq-dev`. P2-v's 4.3–4.6 s join is therefore a start-up cost only.
4. **Nothing new to file.** The late receiver's hold is #73's mechanism, and `moq-dev`'s exit on starvation does not reproduce on its `main`.

## P2-w — the live feed

Two captures of the live feed (hardware encoder, 25.000 Mb/s CBR, 1080i25 H.264, MP2, AC-3, teletext and three SCTE-35 PIDs), each released once at 25 Mb/s by [`t86-loss.sh`](scripts/t86-loss.sh) with the shaper passing everything (no loss, no delay) and the receiver started first. The release is `tsp -P regulate --bitrate 25000000`, since pacing on PCR would follow a step.

- **The step (S).** [T34](test-34-real-encoder-severity.md#a-switch-between-two-encodes-the-first-graded-step)'s ring around the feed's one captured step, an unflagged splice to a second encode 16,844.6 s behind, lifted 30,000 s as T34 and T67 replayed it: 97.1 s, the splice 71.9 s in.
- **The long capture (L).** 300 s of the feed at its hand-off, without a step.

Arm A is `moq2ts-cli --unmodified` (objects of 250 ms, `--segment-bytes 781140`) → `moq2ts-receiver`, draft 22, as in P2-u. Arm M is `moq-dev` `main` `b45179d39b`'s passthrough pair, `moq-lite-07`, on which a passthrough import splices a clock step instead of ending. One run per cell and arm. Graded by [`t86-units-grade.py`](scripts/t86-units-grade.py), which matches each output's units against the capture's on T83 Part C's parser ([`t83c-shadow.py`](scripts/t83c-shadow.py) `units`: an audio frame, a PES or a SCTE-35 section, keyed by PID and PTS and compared by digest), and by `t86-loss-grade.py` for byte identity, the join and read gaps.

_Criteria, fixed before running:_

1. **The grader's controls hold.** The step capture against itself: every unit present. With 2 s of packets cut 1 s after the splice: 1.96 s of video missing, starting 1.85 s after the splice, every loss within 5 s of it. With 1 s cut at 20 s: 0.92 s of video missing, every loss more than 5 s from the splice. _Run before the first capture: all three hold._
2. **Cell L conserves the feed.** From each arm's join to the capture's end, every unit is present with its digest, none altered, missing or added.
3. **Cell S conserves the feed away from the step.** As criterion 2 for every unit more than 5 s from the splice; neither receiver ends before the capture does.
4. **The step costs `moq2ts` no more than `moq-dev`.** Arm A's video missing or altered within 5 s of the splice is within 0.5 s of arm M's.
5. **Reported:** the step's cost on each arm in seconds of video, against SRT's nothing and the 2.8 s of T34's best case on the design that ended the import; byte identity; the join; the longest read gap.

_Results._ Every criterion holds.

| Cell, arm | Units graded | Missing, altered, added | Byte identity from the first byte | First byte, behind live | Longest read gap |
| --- | --: | --: | --- | --- | --: |
| S, `moq2ts` | 11,993 | 0 | whole; the source's 12 continuity breaks and one PCR step | 2.44 s in, 0.28 s | 1,069 ms |
| S, `moq-dev` | 12,285 | 0 | whole, as above | 0.09 s in, 1.06 s | 30 ms |
| L, `moq2ts` | 37,560 | 0 | whole | 2.27 s in, 0.19 s | 1,046 ms |
| L, `moq-dev` | 37,711 | 0 | whole | 1.08 s in, 1.06 s | 209 ms |

- **The step costs nothing on either arm (criteria 3 and 4 hold).** Each output is the capture's bytes from its first byte to the end, through the splice. Every unit within 5 s of it is present with its digest. Neither receiver ends early.
- **The long capture is conserved (criterion 2 holds).** On both arms, every unit from the join to the end is present with its digest, and the output is the capture's bytes.
- **The join is graded per PID.** The first run found every loss within the first 0.6 s after the join: audio frames of PES begun before the output's first byte, which the feed's long, unaligned audio PES make undeliverable. Byte identity showed nothing lost after that byte. The grader now takes the join from the first unit other than a SCTE-35 section (a section is keyed by its CRC, which repeats), and grades each PID from its own first unit delivered. Its three controls give the same results after the change.
- **`moq2ts`'s longest read gaps are most likely its final read**, as at P2-u's rung 0, not a cadence ([Corrections](#corrections)); these runs were not kept to regrade.

_Conclusions._

1. **`moq2ts` carries the live feed unchanged, its unflagged splice included.** The 300 s of a hardware encode, and T34's switch to a second encode 16,844.6 s behind with no `discontinuity_indicator`, cross `moq-relay` byte for byte on draft 22. `moq-dev`'s passthrough on `main` does the same, as [T67](test-67-import-step-restart.md) found on the same capture. Where T34's design lost 9.8 s at this step (2.8 s at best), neither passthrough lane now loses anything.
2. **Nothing to file.**

## Corrections

**The longest read gap counted the final read.** Believed (P2-u, P2-w): `moq2ts-receiver` writes about once a second. True: its reads come at most 73–145 ms apart, and its final read waits about 1 s for the publisher's held last object; [`t86-loss-grade.py`](scripts/t86-loss-grade.py) counted that read whenever it landed within 1 s of the publisher's exit. P2-u's rung 0, re-run on `044c190`, gives 1,081 ms with it and 73 ms without; OpenMOQ found it on the kit's cell `s`. The grader now leaves the final read out and reports it apart. Rule: a gap statistic stops before the stream's end, and a figure read as a cadence is checked against the reads around it.

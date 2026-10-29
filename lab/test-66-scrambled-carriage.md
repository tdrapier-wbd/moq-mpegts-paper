# Test 66 — A scrambled multiplex through the opaque lane, the groomer and a descrambling receiver

**State: run twice; the second run holds every criterion, the first failed C on the rig's own
start-up buffering.**

Part of [P1-al](planned-experiments.md#p1--establishes-where-one-architecture-is-superior). Rig:
[`t66-scrambled-carriage.sh`](scripts/t66-scrambled-carriage.sh).

## Objective

Does a DVB-CISSA-scrambled multiplex, with an ECM PID referenced from the PMT and an EMM PID from
the CAT as BISS-CA carries them, cross `moq-dev`'s opaque lane and our groomer byte for byte, and can
the receiver descramble it before an IRD that has no BISS-CA?

**Falsifies:** [Control](../docs/control-plane.md) §7.3's premise that a route which must deliver a
feed still scrambled is served by byte-faithful carriage and needs nothing else, if that carriage
alters a scrambled byte or drops a conditional-access PID; and the prediction, from the source, that
the media-aware lane cannot carry one. The answer decides whether BISS-CA asks anything of the lane,
and whether the soft receiver can terminate it for an affiliate whose IRD lacks it.

## Stimulus

- **Clip:** `contrib-10m.ts`, its first 120 s: one service (H.264 on 111 with the PCR, MP2 121, AC-3
  123, teletext 131, SCTE-35 141–143), PMT on 100, no CAT, 9.95 Mb/s CBR with stuffing.
- **Conditional-access structure:** a CA_descriptor for `CA_system_id` `0x2610` (BISS-CA's) at
  program level in the PMT, naming ECM PID `0x200`; a CAT whose CA_descriptor names EMM PID `0x201`;
  one private section on each (table_id `0x80` and `0x82`, fixed random payload), repeated at
  16 kb/s from the stuffing. Their payloads are not BISS-CA's syntax, which a byte-faithful lane
  cannot see.
- **Scrambling:** TSDuck's `scrambler` on the service, DVB-CISSA, 13 control words from a file,
  10 s crypto-periods. Video, audio and teletext (the last only with `--subtitles`) are scrambled;
  SCTE-35 stays clear, as is common. The scrambler nulls the packets before it has read the PAT and
  PMT, the first 401 here.
- **Builds:** `moq` and `moq-relay` at `66af72315`; `mpegts-pacer` `97f3a38`; TSDuck 3.45.

## Arms

One relay on loopback. A–C share one publish of the scrambled stream, in real time on its own PCR;
D and E read the same file in parallel.

| Arm | Chain | Stands for |
|---|---|---|
| A | `import ts --passthrough` → relay → `export ts --passthrough --delay 1s` → file | the opaque lane |
| B | A second export → `mpegts-pacer` 11 Mb/s → UDP → `tsp -I ip` | a receiver feeding a BISS-CA IRD |
| C | A third export → `tsp -P descrambler` (the same control words) → pacer → UDP → `tsp -I ip` | a receiver feeding an IRD without BISS-CA |
| D | the same stream into `import ts` (no passthrough), a second broadcast → `export ts --delay 2s` | the media-aware lane |
| E | the same stream into our segmenter, `t65-epochseg-stdin.py` | the segmented lane's origin |
| Control | TSDuck's `descrambler` on the scrambled file, offline | the instruments |

## Pass criteria, fixed before the first run

1. **Control.** Every payload-bearing packet on 111, 121, 123 and 131 is scrambled, both parities
   occur, and the parity changes at least 11 times; descrambled offline, every such packet the
   scrambler kept equals the clear fixture's. Otherwise the stimulus is void and nothing below is graded.
2. **A.** `ts-passthrough-identity.py` against the scrambled fixture finds **0 foreign packets**, and
   the CAT, ECM and EMM PIDs occur in the capture as often as in the source span it covers. Gaps
   (objects dropped late) are reported, not failed: they are the lane's timing, not its transparency.
3. **B.** `--groomed` identity (nulls dropped, PCR fields masked) against the scrambled fixture finds
   0 foreign packets; the capture has 0 continuity errors and no PCR interval over 40 ms.
4. **C.** `--groomed` identity against the offline-descrambled control finds 0 foreign packets, and
   FFmpeg logs no error on the capture that it does not log on the same span of the clear fixture
   (the clip's GOPs are open, so a capture's first pictures may lack their references either way).
5. **D**, classified, not passed: what the importer publishes and what the export writes. Predicted:
   no video FFmpeg can decode, and no conditional-access PID.
6. **E**, classified: predicted to name no segment, since it takes each segment's name from a PES
   header that scrambling hides.

## Limits, stated in advance

- **The control words stand in for the key ladder.** The receiver steps through the same list from
  the first crypto-period, which a receiver joining late cannot do; BISS-CA's EMM (the session key
  under the receiver's RSA key) and ECM (the session word under the session key) are not exercised.
- One clip, one graded run, loopback; the ECM and EMM do not change between crypto-periods.

## Results

| # | Arm | Measured | Grade |
|---|---|---|---|
| 1 | Control | 753,959 payload packets on the four PIDs, none clear; 11 parity changes; 0 differ from the clear fixture once descrambled | pass |
| 2 | A | 786,591 packets in order from source packet 6,369 (the first random-access indicator on 111) to the end; 0 gaps, 0 foreign; CAT 238, ECM 1,264, EMM 1,264, as in the span; 0 continuity errors, PCR intervals ≤ 25.0 ms | pass |
| 3 | B | 753,491 content packets, A's span without its nulls; 0 gaps, 0 foreign; 0 continuity errors, PCR ≤ 28.8 ms; every scrambled packet and CA PID count as in A | pass |
| 4 | C | 753,491 packets equal to the descrambled control, 0 gaps, 0 foreign, 0 continuity errors, PCR ≤ 27.5 ms; FFmpeg logs one AC-3 "incomplete frame" on the capture and the same on the clear span | pass |
| 5 | D | the importer types 111 and 121 as decoded tracks and refuses every unit on the scrambled PIDs as damaged ("missing PES start code prefix": 4,299 on 111, 553, 415 and 2,995 on 121, 123 and 131), delivers 0 access units, never announces the broadcast, and at end of input fails to publish its catalog ("TS sections reached end of input without a media timestamp"); the export writes 0 bytes | as predicted, and further: no broadcast at all |
| 6 | E | the segmenter anchors its date-time and names no segment | as predicted |

The table is the second run. The first differed only in C, which failed criterion 4 on one foreign
packet: `tsp` loads half its buffer (8 MB, 6.7 s of this source) before it processes, so the pacer
met a 6.7 s lead against its 2.5 s cap and trimmed 30,641 packets before its first output and 145
after its eighteenth, leaving 3 continuity errors and one PCR packet it inserted across the splice.
The second run sets `--initial-input-packets 7`; the pacer's lead is 36 ms and it drops nothing.

## Conclusions

1. **BISS-CA asks nothing of the opaque lane or of the groomer.** Scrambling leaves the adaptation
   field clear, and neither reads past it: the lane groups on the random-access indicator and
   carries every scrambled packet and conditional-access PID unaltered, and the groomer re-times on
   the PCR alone. Control §7.3's premise survives.
2. **The soft receiver can descramble for an IRD that lacks BISS-CA**, at the scrambling layer: a
   `tsp` descrambler before the pacer hands the IRD the clear source packet for packet. A `tsp`
   stage in a live chain needs a small `--initial-input-packets`, or the pacer trims and splices
   its start. The key ladder that would give the receiver its control words is not exercised.
3. **The media-aware lane carries no part of a scrambled multiplex.** A subscriber finds no
   broadcast; the publisher logs damage each second, and its only error comes at end of input,
   which a live feed never reaches.
4. **Our segmenter cannot cut a scrambled source**: it names each segment from a PES timestamp.
   Naming from the PCR, which stays clear, would remove that dependency, untested; `tsp -O hls` is
   untried.

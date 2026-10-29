# Test 66 — A scrambled multiplex through the opaque lane, the groomer and a descrambling receiver

**State: criteria fixed; not yet run.**

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
  10 s crypto-periods. Video, audio and teletext are scrambled; SCTE-35 stays clear, as is common.
- **Builds:** `moq` and `moq-relay` at `66af72315`; `mpegts-pacer` `97f3a38`; TSDuck 3.45.

## Arms

One relay on loopback; the scrambled stream published once, in real time on its own PCR.

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
   occur, and the parity changes at least 11 times; descrambled offline, every such packet equals the
   clear fixture's. Otherwise the stimulus is void and nothing below is graded.
2. **A.** `ts-passthrough-identity.py` against the scrambled fixture finds **0 foreign packets**, and
   the CAT, ECM and EMM PIDs occur in the capture as often as in the source span it covers. Gaps
   (objects dropped late) are reported, not failed: they are the lane's timing, not its transparency.
3. **B.** `--groomed` identity (nulls dropped, PCR fields masked) against the scrambled fixture finds
   0 foreign packets; the capture has 0 continuity errors and no PCR interval over 40 ms.
4. **C.** `--groomed` identity against the offline-descrambled control finds 0 foreign packets, and
   FFmpeg decodes the capture with no error logged.
5. **D**, classified, not passed: what the importer publishes and what the export writes. Predicted:
   no video FFmpeg can decode, and no conditional-access PID.
6. **E**, classified: predicted to name no segment, since it takes each segment's name from a PES
   header that scrambling hides.

## Limits, stated in advance

- **The control words stand in for the key ladder.** The receiver steps through the same list from
  the first crypto-period, which a receiver joining late cannot do; BISS-CA's EMM (the session key
  under the receiver's RSA key) and ECM (the session word under the session key) are not exercised.
- One clip, one run, loopback; the ECM and EMM do not change between crypto-periods.

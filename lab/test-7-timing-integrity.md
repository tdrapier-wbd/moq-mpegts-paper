# T7 — Timing integrity (TR 101 290)

## Objective

Prove that the groomed egress is timing-conformant: PCR accuracy and interval, PTS/DTS continuity,
and mux-rate stability all within TR 101 290 limits — first on file (P1, cheap), then on the live
wire (P2) on a real hardware IRD. P2 is the make-or-break gate (Gate 2).

## Environment

- Full media-aware lane + `mpegts-pacer`: `~/CNNiEMEA2.ts` (and the three other T1 clips) →
  `tsp regulate` → `moq import ts` → `moq-relay` → `moq export ts` → `mpegts-pacer` (`cbr_file`,
  `auto regenerate`) → TSDuck.
- Build under test: `moq-dev` `feat/mux-ts-dvb-service-layer` (`moq` 0.8.7, `moq-relay` 0.13.7,
  `moq-native` 0.18.3 — carrying #2072/#2066 and the #2440 service layer), so the exporter
  round-trips the CNN open-GOP + triple-SCTE-35 feed deterministically and **keeps the PMT PID at
  0x0064** (no longer renumbered). `mpegts-pacer` 0.1.0; TSDuck 3.44.

## Procedure

1. **File (P1).** Capture groomed egress; run TSDuck `pcrverify` (interval/accuracy), `pcrextract`
   (jitter distribution) and `analyze` (structure, mux rate). Confirms the re-stamp arithmetic. Per
   clip: raw media-aware egress → paced (see `lab/README.md` for the analysis commands).
2. **Hardware (P2) — not yet run.** Feed the live egress to a hardware IRD and TR 101 290 analyser;
   confirm PLL lock and a clean P1/P2 result over a sustained soak (target ≥ 24 h, ideally 72 h);
   run jointly with the T9 resource soak. Exercise the correctness boundaries a groomer must handle
   beyond steady state: source-clock drift, PCR discontinuities / 33-bit wrap, mid-stream PID/PCR-PID
   change. Corroborate with a second analyser (Elecard/R&S/Tektronix/Ateme) where access exists. See
   [planned-experiments.md](planned-experiments.md).

## Results

P1 (file) figures are the range across four groomed clips; P2 remains the load-bearing open item.

| Metric | Unit | Limit | P1 (file) | P2 (hardware) |
|---|---|---|---|---|
| PCR accuracy | ns | ±500 (P2) | **0 viol. @ ±500 ns; ≤ 74 ns floor¹** | **TBM (load-bearing)** |
| PCR interval — max | ms | ≤ 40 | **30.6–32.2** | TBM |
| PCR interval — % > 40 ms | % | 0 | **0.0000 %** (all 4 clips) | TBM |
| PTS/DTS continuity | pass/fail | no gaps | **pass** (no gaps; DTS authored) | TBM |
| Mux-rate stability | Mbps/jitter | CBR | **exact CBR** (bitrate = pcrbitrate) | TBM |
| TR 101 290 P1 | pass/fail | pass | **pass** (file-level) | **TBM** |
| TR 101 290 P2 | pass/fail | pass | n/a (file) | **TBM** |
| IRD PLL lock (sustained) | hh:mm | stable | n/a | TBM (≥ 24 h target) |
| Drift / discontinuity / wrap | pass/fail | pass | **0 disc. (steady state)²** | TBM |

¹ File arithmetic, not wire timing: `pcrverify` records 0 violations at ±500 ns on all four clips;
tightest floor ≤ 74 ns (≤ 2 units) on `testloop_clean`, ≤ 37 ns (≤ 1 unit) on the other three.
Because the pacer byte-locks PCR to output position, file jitter is near-zero by construction — the
wire (P2) test is the one that decides PCR_accuracy. ² 0 CC errors and 0 PCR discontinuities in
steady state; boundary cases (drift, 33-bit wrap, mid-stream PID change) are not exercised by these
clips and remain TBM.

### File-based (P1) per clip — media-aware lane + `mpegts-pacer`

| Clip (paced CBR) | Raw egress > 40 ms | Paced > 40 ms | Paced PCR max (ms) | Mux rate (exact CBR) | `pcrverify` > 500 µs | CC err |
|---|---|---|---|---|---|---|
| `testloop_clean` (synthetic) | 25.15 % | **0 %** | 32.15 | **9.731 Mbps** | **0** | 0 |
| `testloop` (27.5 Mbps 4:2:2) | 0 %³ | **0 %** | 30.64 | **30.085 Mbps** | **0** | 0 |
| `CNNiEMEA` (CNN, 5 min) | 13.92 % | **0 %** | 31.84 | **11.006 Mbps** | **0** | 0 |
| `CNNiEMEA2` (CNN, 10 min) | 9.08 % | **0 %** | 31.84 | **11.006 Mbps** | **0** | 0 |

³ `testloop`'s native 27 ms PCR cadence is already < 40 ms before grooming; pacing still converts it
to exact CBR (`bitrate = pcrbitrate = userbitrate`) with byte-locked PCR. For every clip the pacer
inserts byte-locked PCR-only packets where source spacing exceeds 40 ms (117–737 per clip) and stuffs
12.7–13.0 % nulls, dropping 0 content packets.

Known baseline (pre-groom, file, P1): ~24 % of PCR intervals exceeded 40 ms, up to 133 ms — the
problem grooming exists to solve.

## Observations

- P1 is a pass across a synthetic CBR reference, a 27.5 Mbps 4:2:2 mux, and two real CNN contribution
  captures.
- **P1 file analysis is optimistic by construction:** it cannot see the software CBR pacer's
  scheduling jitter on a general-purpose OS/NIC, which is exactly what PCR_accuracy (±500 ns) tests on
  the wire. Only P2 decides it.
- A single IRD model is not the installed base; a credible pass needs a defined IRD test matrix
  (models, analyser settings).

## Conclusion

The media-aware lane + `mpegts-pacer` is CBR/PCR-conformant at P1 across four clips (0 % > 40 ms,
exact CBR, 0 `pcrverify` violations @ ±500 ns, 0 CC), and the opaque-lane P1 is shown in
[T3](test-3-opaque-transparency.md). This is *necessary but not sufficient*: the grooming design is
"structurally sound and file-validated," not "proven broadcast-acceptable." **The hardware (P2) pass
remains the open, load-bearing test.** Recorded as a permanent finding in
[`docs/evidence.md`](../docs/evidence.md) §3.

## References

- P1 vs wire (P2) caveat, boundary cases: [`docs/architecture.md`](../docs/architecture.md) §7.2.
- Hardware-soak protocol (not yet run): [planned-experiments.md](planned-experiments.md).
- Finding: [`docs/evidence.md`](../docs/evidence.md) §3.

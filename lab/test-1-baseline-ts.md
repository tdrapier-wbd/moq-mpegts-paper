# T1 — Baseline TS characterisation (P0 reference)

## Objective

Characterise the input MPEG-TS sources at P0 so that every downstream metric (T2, T3, T7) can be
stated as a *delta* against a known-good reference. Run before MoQ touches the stream. There is no
pass/fail: T1 *defines* the reference. The only failure mode is choosing a non-representative or
already-broken source.

## Environment

- TSDuck 3.44-4676, macOS (Darwin 25.5.0). All commands run from the directory holding the clips.
- Four source clips, chosen to span synthetic-CBR, a real high-bitrate 4:2:2 broadcast mux, and
  two real CNN International contribution captures:

| File | Role | Service | Video | Duration | TS bitrate |
|---|---|---|---|---|---|
| `testloop_clean.ts` | Synthetic clean CBR reference (FFmpeg) | Service01 | H.264 High@L4.0 4:2:0 1080i/p | 7:57 | 10.00 Mbps (exact CBR) |
| `testloop.ts` | Real broadcast mux reference | Cartoonito UK HD 422 | H.264 High **4:2:2**@L4.0 1080 | 7:56 | 27.51 Mbps |
| `CNNiEMEA.ts` | Real contribution capture | CNNI EMEA HD (WBD) | H.264 High@L4.0 4:2:0 1080 | 4:59 | 9.95 Mbps |
| `CNNiEMEA2.ts` | Real contribution capture (longer) | CNNI EMEA HD (WBD) | H.264 High@L4.0 4:2:0 1080 | 9:59 | 9.95 Mbps |

## Procedure

Each command is `-O drop` (T1 only reads and analyses). `<clip>` is each of the four files.

```bash
# 1. structural + service + PID + table report (bitrate, PIDs, repetition, CC)
tsp -I file <clip> -P analyze -O drop
# 2. PCR accuracy sweep (µs, then absolute PCR units; 13 units ≈ 481 ns ≈ the P2 ±500 ns limit)
tsp -I file <clip> -P pcrverify -O drop
tsp -I file <clip> -P pcrverify --jitter-max 500 -O drop     # then 50, 5
tsp -I file <clip> -P pcrverify --absolute --jitter-max 13 -O drop   # then 5, 2, 1
# 3. PCR interval / repetition (TR 101 290 P1, ≤ 40 ms) — see lab/README.md awk one-liner
tsp -I file <clip> -P pcrextract --pcr --csv -o <clip>_pcr.csv -O drop
# 4. continuity-counter integrity (no output = 0 errors)
tsp -I file <clip> -P continuity -O drop
```

## Results

Measured reference (P0):

| Metric (unit) | `testloop_clean` | `testloop` | `CNNiEMEA` | `CNNiEMEA2` |
|---|---|---|---|---|
| File size (bytes) | 596,847,172 | 1,638,619,656 | 372,971,696 | 745,917,260 |
| TS packets | 3,174,719 | 8,716,062 | 1,983,892 | 3,967,645 |
| Duration | 7:57 (477 s) | 7:56 (476 s) | 4:59 (299 s) | 9:59 (599 s) |
| TS bitrate, PCR-based (Mbps) | 10.000 | 27.508 | 9.946 | 9.946 |
| Service bitrate (Mbps) | 8.547 | 26.054 | 9.474 | 9.476 |
| Video PID bitrate (Mbps) | 8.254 | 25.062 | 9.019 | 9.021 |
| PCR PID / PMT PID | 0x0100 / 0x1000 | 0x0030 / 0x0020 | 0x006F / 0x0064 | 0x006F / 0x0064 |
| PCR interval min/mean/max (ms) | 0.60 / 19.80 / 20.45 | 27.34 / 27.74 / 28.16 | 0.15 / 24.42 / 24.95 | 0.15 / 24.42 / 24.95 |
| PCR intervals > 40 ms | **0 (0.0000%)** | **0 (0.0000%)** | **0 (0.0000%)** | **0 (0.0000%)** |
| PCR accuracy, file (jitter) | < 37 ns¹ | < 74 ns¹ | < 74 ns¹ | < 37 ns¹ |
| Continuity-counter errors | **0** | **0** | **0** | **0** |
| Transport errors / invalid sync | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| PCR discontinuities (leaps) | 0 | 0 | 0 | 0 |
| PAT repetition mean/max (ms) | 97 / 100 | 475 / 476 | 125 / 291 | 125 / 291 |
| PMT repetition mean/max (ms) | 97 / 100 | 475 / 475 | 125 / 291 | 125 / 291 |
| SDT repetition mean/max (ms) | 500 / 500 | 1974 / 1986 | 1044 / 1105 | 1044 / 1103 |
| Other SI | — | CAT | NIT 5048 ms, TDT 15144 ms | NIT 5048 ms, TDT 15145 ms |
| Audio | MPEG-2 AAC | MPEG-1 L2 256k + AC-3 + MPEG-1 L2 (VI) | MPEG-1 L2 192k + AC-3 | MPEG-1 L2 192k + AC-3 |
| Teletext | — | 0x0050 | 0x0083 | 0x0083 |
| SCTE-35 PIDs | — | 0x0060 | 0x008D/8E/8F | 0x008D/8E/8F |
| Stuffing (null) bitrate (Mbps) | 1.435 | 1.447 | 0.458 | 0.456 |

¹ File-based PCR accuracy expressed as the tightest `pcrverify` jitter bound with **zero**
violations: `testloop_clean`/`CNNiEMEA2` pass at ≤ 37 ns (1 PCR unit); `testloop`/`CNNiEMEA` pass
at ≤ 74 ns (2 units) with 0 violations, and show a handful only at the 37 ns bound (447 and 1
respectively). All four are far inside the TR 101 290 P2 ±500 ns limit — as a *file arithmetic*
result (see Observations).

### Component / track inventory (P0)

The reference against which T2/T3 check track carriage; PCR is carried on the video PID in all four.

`testloop_clean.ts` — Service01 (synthetic, minimal): Video 0x0100 (H.264 High@L4.0 4:2:0, **PCR
PID**); Audio (eng) 0x0101 (MPEG-2 AAC); PSI 0x0000/0x1000/0x0011 (PAT/PMT/SDT-BAT). No teletext,
SCTE-35, CAT, NIT, TDT/TOT.

`testloop.ts` — Cartoonito UK HD 422: Video 0x0030 (H.264 **4:2:2**@L4.0, **PCR PID**); Audio 1
0x0040 (MPEG-1 L2 256k); Audio 2 0x0041 (AC-3); Audio 3 0x0042 (MPEG-1 L2, **visual-impaired**);
Subtitles 0x0050 (teletext); SCTE-35 0x0060; PSI 0x0000/0x0020/0x0001/0x0011 (PAT/PMT/CAT/SDT-BAT).

`CNNiEMEA.ts` / `CNNiEMEA2.ts` — CNNI EMEA HD (WBD): Video 0x006F (H.264 High@L4.0 4:2:0, **PCR
PID**); Audio 1 0x0079 (MPEG-1 L2 192k); Audio 2 0x007B (AC-3); Subtitles 0x0083 (teletext);
SCTE-35 0x008D/0x008E/0x008F (**three** Splice Info streams); PSI/SI 0x0000/0x0064/0x0010/0x0011/
0x0014 (PAT/PMT/NIT (WBD)/SDT-BAT/TDT-TOT).

## Observations

- All four clips are valid, conformant P0 references: 0 CC/transport/discontinuity errors, 0 % of
  PCR intervals > 40 ms, file PCR accuracy < 74 ns.
- **File-based PCR accuracy is arithmetic, not wire timing.** The < 74 ns figures confirm the source
  PCR values are internally consistent against the estimated CBR; they do *not* characterise a live
  source's true clock, which is only visible on the wire (P2 — same caveat as P1).
- Two sub-millisecond minimum PCR intervals (`testloop_clean` 0.60 ms, CNN 0.15 ms) appear against
  otherwise regular ~20–25 ms spacing. With 0 reported discontinuities these are most likely
  capture-boundary artefacts; they do not affect P1 (which bounds the *maximum* interval).
- `testloop` PAT/PMT repetition (~475 ms) is within TR 101 290 P1 (≤ 500 ms) but close to the limit
  — a transport that *adds* table jitter could push this clip over, whereas the other three
  (≤ 100–291 ms) have ample margin.
- GOP structure was not separately measured. The CNN captures are treated as the open-GOP
  contribution class (recovery-point SEI, roughly one IDR / 15 s); IDR cadence was not quantified
  in this run.

## Conclusion

The four-clip set is clean and representative (synthetic CBR + real 4:2:2 broadcast mux + two real
CNN contribution captures), so downstream T2/T3/T7 comparisons are honest deltas against a known-good
baseline. Reference established.

## References

- Contribution-feed class (CNN International, open-GOP): [`docs/evidence.md`](../docs/evidence.md) §4.
- P1 (file) vs wire (P2) accuracy caveat: [`docs/architecture.md`](../docs/architecture.md) §7.2.
- Pre-groom baseline used downstream: [`docs/evidence.md`](../docs/evidence.md) §3.

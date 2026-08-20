# T3 — Transport transparency: the opaque `m2ts` lane and segmented HTTP (local)

## Objective

Ask of each candidate carriage lane the same question: **is the multiplex that arrives the same
object as the multiplex that left?** Verify, component by component against the
[T1](test-1-baseline-ts.md) §5.6 inventory, that video, every audio track, teletext, every SCTE-35
PID and the full PSI/SI survive at their original PIDs; that TSID/ONID/service identity and PMT/PCR
PIDs are unchanged; and that the mux structure, integrity and P1 timing arrive intact. A lane that
demuxes and rebuilds ([T2](test-2-media-aware-transparency.md)) cannot be asked this question, because
it constructs a new multiplex by design; these two lanes forward one, so for them it is decidable.

Two lanes are scored here against the same inventory and the same three clips:

- **The platform's opaque `m2ts` lane** — the fallback lane ([architecture](../docs/architecture.md)
  §4.2), and the one the prototype chain implements end to end.
- **Segmented HTTP carrying MPEG-TS** — classic HLS with TS segments, the alternative data plane
  [comparison](../docs/comparison.md) grades MoQ against. Added because the paper now treats
  segmented HTTP as a candidate for primary distribution rather than as a foil, and the
  transparency question had only ever been asked of the two MoQ lanes.

**Why this is not a re-run of [T14](test-14-data-plane-comparison.md) measurement 4.** T14 censused
PIDs on one clip and compared one published segment against the source packet by packet, concluding
segmented HTTP is verbatim. That establishes what survives; it does not establish that the mux is
*unchanged*, because a lane can be faithful to every byte it forwards and still add bytes of its
own. This arm scores service identity and PSI/SI contents rather than packet counts, across the
three clips T3 already uses — which is what brings `testloop`'s CAT and visual-impaired audio, and
`testloop_clean`'s non-default PMT PID, into the frame — and it adds a **packet-conservation**
criterion so an addition is scored rather than described.

### Pass criteria (fixed before the segmented-HTTP runs)

The first five are T3's existing inventory, applied unchanged so the columns are comparable. The
sixth is new, and it is the one this arm was expected to fail.

1. **Components.** Every elementary stream from the T1 inventory present at its original PID on all
   three clips: video, every audio track including `testloop`'s visual-impaired commentary,
   teletext, and every SCTE-35 PID.
2. **Service identity.** TSID, ONID, service name, provider, service type, PMT PID and PCR PID
   unchanged. `testloop_clean` (PMT 0x1000) and `testloop` (PMT 0x0020) are the clips that catch a
   lane which renumbers to a default.
3. **PSI/SI completeness.** Every table the source carries survives — including TDT/TOT and CAT,
   which the media-aware lane drops, the latter being a table no HLS document mentions — and none is
   re-versioned.
4. **Mux structure.** Null stuffing preserved and the PCR-derived bitrate equal to source.
5. **Integrity and P1 timing.** 0 continuity errors, 0 transport errors, 0 invalid sync; 0 PCR
   repetition intervals above 40 ms; PAT/PMT/SDT repetition inside the TR 101 290 P1 limits.
   `testloop` is the sensitive clip, at 475 ms against a 500 ms PAT/PMT limit ([T1](test-1-baseline-ts.md)).
6. **Nothing added.** The egress contains no PID and no table the source did not have, and no
   packet the source did not send. The opaque lane passes this by construction; a segmenter writes
   a PAT and PMT at the head of every segment, so the criterion exists to price that rather than
   note it.

---

## Environment

### The opaque `m2ts` lane

- Binaries: private `moq_relay` / `moq_publisher` / `moq_subscriber` built from the repo's pinned
  `Cargo.lock` — `moq-transport` 0.14.2, `moq-native` 0.17.0, `moq-relay` 0.12.9. Default local relay
  mode. Negotiated **draft-14**. No GSO workaround needed (unlike the moq-dev relay in T2).
- Relay config `relay.toml` (QUIC + HTTP on `[::]:4443`, self-signed `localhost`, anonymous auth).
- Publisher: TCP ingest `127.0.0.1:5001`, broadcast `mpegts`, track `ts`. Each MoQ Object is a
  concatenation of whole 188-byte TS packets (default 7 → 1316 bytes), batched into ordered groups
  — **byte-preserving by construction**.
- Subscriber: reassembles Objects → MPEG-TS with a decoder-safe start gate, an adaptive CBR/PCR
  pacer, and **read-only TR 101 290 monitoring** on the egress; output UDP / RTP / TCP.

### The segmented-HTTP lane

| Component | Detail |
|---|---|
| Publisher | TSDuck 3.44-4676 `tsp -O hls`, 2 s target, `--intra-close --align-first-segment --live 6 --live-extra-segments 3` |
| Origin | `python3 -m http.server` over the segment directory, HTTP/1.1 loopback |
| Receiver | TSDuck 3.44-4676 `tsp -I hls --live`, captured **ungroomed** |
| Rig | [`t3-segmented-transparency.sh`](scripts/t3-segmented-transparency.sh) |
| Analyser | [`t3-transparency.py`](scripts/t3-transparency.py) |
| Window | 60 s of media per clip, bounded by packet count, one run each |
| Segment durations | 2 s on all three clips; 1 s and 6 s on `CNNiEMEA` for the duration sweep |

The measurement point is the **ungroomed** egress, matching the opaque arm, which ran its
subscriber with `--no-pacing`. [T16](test-16-grooming-segmented-http.md) measures the groomed
version of this same chain, and the two answer different questions: T16 asks whether the cadence can
be repaired, this asks whether the mux arrived.

### The media-aware lane, for the PCR-accuracy cell only

Captured to settle whether the P2 gate can compare the three lanes; the lane's *carriage* results are
[T2](test-2-media-aware-transparency.md)'s, not re-measured here. `moq 0.9.10-eab960192` and
`moq-relay` from `~/bin-main` (stock `main`), local relay on `[::]:4443` with
`--server-quic-gso=false`, fed `tsp -I file … -P regulate --pcr-synchronous`, captured **ungroomed**
from `moq export ts` by [`t14-a.sh`](scripts/t14-a.sh) — 45 s per clip, all three clips.

### Common to both

TSDuck 3.44-4676 (Darwin 25.5.0). All localhost. Three clips: `testloop_clean`, `testloop` (4:2:2),
`CNNiEMEA`.

**Load-bearing methodological finding — feed the lane the raw TS, not an ffmpeg remux.** The repo's
convenience ingest (`ffmpeg -re -i clip.ts -c copy -f mpegts tcp://…`) regenerates the TS container
before it reaches the publisher: it strips null padding (`testloop_clean` 10.00 → 8.31 Mbps) and
rewrites the PCR cadence to ~80 ms (**99 % of intervals > 40 ms**). That is an FFmpeg muxer artefact,
**not** the lane. Every result below uses raw, PCR-paced bytes (`tsp … -P regulate` piped straight
into the publisher's TCP ingest, or fed to `tsp -O hls`), which reproduces the source exactly.

### What this environment cannot show

- Loopback only, file-fed. A live SRT/RTP contribution source is [T4](test-4-remote-e2e-srt.md).
- Single programme throughout. HLS normatively excludes multi-programme TS segments, and that cell
  now carries the whole of MoQ's remaining carriage advantage; it is unrun
  ([planned-experiments](planned-experiments.md)).
- One run per clip per lane. The opaque lane's draft-14 pin is a tracked dependency.
- The duration sweep ran on `CNNiEMEA` only, so its invariance claim leans on the bitrate spread from
  the three-clip runs for generality rather than on a second sweep.
- The media-aware captures are bounded by wall clock, not packet count. That is sound for grading a
  stream's internal PCR consistency, which needs no second window to compare against, and it would
  **not** be sound for any census row — which is why none is taken from them here.
- Nothing was ever lost in transit on either lane, so this measures what a lane *does* to a mux, not
  what it does when the path damages one.
- **PCR accuracy figures below are file arithmetic, not wire timing** — T1's caveat, which applies
  with equal force here. They establish whether PCR values remain consistent with the byte positions
  the lane delivered them at; they say nothing about a real clock.

---

## Procedure

### The opaque lane

```bash
# 1. relay
cd ~/moq-publisher-subscriber && ./target/release/moq_relay

# 2. subscriber (groomer) + capture; reader connected BEFORE the feed starts.
#    TCP playout is always 188-aligned (TSDuck's UDP ip input drops non-aligned datagrams).
./target/release/moq_subscriber --output-protocol tcp --playout-bind 127.0.0.1:5002 --no-pacing
nc 127.0.0.1 5002 > <clip>_out.ts
#    (single-program clips also capture via UDP: --output-protocol udp --output-port 5000
#     + tsp -I ip 5000 -O file <clip>_out.ts)

# 3. publisher (opaque m2ts, TCP ingest)
./target/release/moq_publisher     # relay https://localhost:4443/anon, broadcast mpegts, track ts

# 4. feed the RAW source TS, PCR-paced, into the publisher's TCP ingest (no remux)
tsp -I file <clip> -P regulate -P until --seconds 30 -O file - | nc 127.0.0.1 5001

# 5. analyse egress (analyze / continuity / pcrextract per lab/README.md)
```

`--no-pacing` is used because `tsp regulate` already delivers the source in real time (the
subscriber's own pacer would double-pace); in-band PCR figures are identical with or without it.

### The segmented-HTTP lane

```bash
# publisher, origin and receiver all start and stop inside one invocation
for c in testloop_clean testloop CNNiEMEA; do
	PORT=18091 lab/scripts/t3-segmented-transparency.sh ~/$c.ts ~/t3seg/$c 60 2
done

# the duration sweep: same clip, same media window, segment duration varied
for s in 1 6; do
	PORT=$((18100 + s)) lab/scripts/t3-segmented-transparency.sh \
		~/CNNiEMEA.ts ~/t3seg-dur/$s 60 $s
done
```

The rig derives the window from the clip's own PCR bitrate and bounds the capture by **packet
count**, then cuts an equal-packet source reference offset to the media the receiver joined, and runs
the analyser over the pair. Two rules it enforces, both of which cost this run a wrong number first
(Corrections):

- **The window is packets, never wall clock.** `tsp -I hls --live` drains the live window faster than
  real time before settling, so a wall-clock window carries an unknown quantity of media and no count
  taken in it can be compared with anything.
- **The reference is offset, and its homogeneity is asserted rather than assumed.** The analyser
  reports the source reference's stuffing fraction per quarter, because a census across two equal
  windows only measures the lane if both cover equivalent mux.

### The media-aware lane, for the PCR-accuracy grade

```bash
for c in testloop_clean testloop CNNiEMEA; do
	NAME=$c lab/scripts/t14-a.sh ~/$c.ts ~/t3ma/$c 45      # ungroomed egress
done
# then, per capture: the tightest clean --absolute bound, both gates, and the max PCR interval
tsp -I file ~/t3ma/<clip>/a-egress.ts -P pcrverify --absolute --jitter-max 13 -O drop
tsp -I file ~/t3ma/<clip>/a-egress.ts -P pcrverify --jitter-max 500 -O drop
```

The bound is bisected with `t3-transparency.py`'s `tightest_clean_bound`, and the max PCR interval it
is compared against comes from the same file's `pcr_intervals` — the two must be computed on the same
capture for the identity below to mean anything.

---

## Results

### The opaque `m2ts` lane

Source identity vs opaque egress — every field **preserved**:

| Field (source → egress) | `testloop_clean` | `testloop` | `CNNiEMEA` |
|---|---|---|---|
| Transport Stream Id | 0x0001 → **0x0001** | 0x0001 → **0x0001** | 0x0000 → **0x0000** |
| Original Network Id | 0xFF01 → **kept** | 0x0001 → **kept** | 0x0000 → **kept** |
| Service name / type | Service01 / 0x01 → **kept** | Cartoonito UK HD 422 / 0x01 → **kept** | CNNI EMEA HD / 0x19 → **kept** |
| PMT PID | 0x1000 → **kept** | 0x0020 → **kept** | 0x0064 → **kept** |
| PCR PID | 0x0100 → **kept** | 0x0030 → **kept** | 0x006F → **kept** |
| Egress PID count | 6 | 11 | 13 |
| Reference bitrate (Mbps) | **10.000** (= src) | **27.5** (= src) | **9.95** (= src) |
| CBR / null padding | **preserved** | **preserved** | **preserved** |
| Continuity-counter errors | **0** | **0** | **0** |
| Transport errors / invalid sync | 0 / 0 | 0 / 0 | 0 / 0 |
| PCR interval min/mean/max (ms) | 1.20 / 19.80 / 20.00 | 27.34 / 27.74 / 28.16 | 0.30 / 24.42 / 24.95 |
| PCR intervals > 40 ms | **0 %** | **0 %** | **0 %** |

Every component from the T1 inventory survived verbatim at its original PID. For `CNNiEMEA` the
egress carried, unchanged: AVC video 0x006F, MPEG-1 audio 0x0079, **AC-3** 0x007B, teletext 0x0083,
**all three SCTE-35 splice PIDs** (0x008D/8E/8F, table_id 0xFC), and the full PSI/SI — PAT, **NIT**
(0x0010), **SDT** (0x0011), **TDT/TOT** (0x0014), PMT (0x0064). For `testloop` the egress
additionally preserved the visual-impaired commentary audio 0x0042 and the CAT.

#### Built-in egress monitor (read-only TR 101 290)

- **Transient P1** (`pat_missing` / `pmt_missing` / `pid_missing`, `raised` → `recovered`) only
  during the live-join window while the first PAT/PMT/PID cycle arrives; self-clears within the first
  group. Expected.
- **P2 `pcr_jitter` on `CNNiEMEA`** (~4–5 ms on PCR PID 0x006F): carried from the source
  contribution feed — the lane surfaces it, does not create it (raw-fed egress still 0 % > 40 ms).
- **0 discontinuities** in steady state; egress bitrate tracks the source.

### The segmented-HTTP lane

**Criteria 1, 2, 3 and 5 are met on all three clips; 4 is met only in part and 6 fails, both for the
same single reason.** Service identity, the component inventory, PSI/SI, integrity and P1 timing all
arrive unchanged:

| Field (source → egress) | `testloop_clean` | `testloop` | `CNNiEMEA` |
|---|---|---|---|
| Transport Stream Id | 0x0001 → **0x0001** | 0x0001 → **0x0001** | 0x0000 → **0x0000** |
| Original Network Id | 0xFF01 → **kept** | 0x0001 → **kept** | 0x0000 → **kept** |
| Service name / provider | Service01 / FFmpeg → **kept** | Cartoonito UK HD 422 → **kept** | CNNI EMEA HD / Warner Bros. Discovery → **kept** |
| Service type | 0x01 → **kept** | 0x01 → **kept** | 0x19 → **kept** |
| PMT PID | 0x1000 → **kept** | 0x0020 → **kept** | 0x0064 → **kept** |
| PCR PID | 0x0100 → **kept** | 0x0030 → **kept** | 0x006F → **kept** |
| Egress PID count | 6 → **6** | 11 → **11** | 13 → **13** |
| Null stuffing (% of mux) | 14.83 → **14.95** | 5.26 → **5.25** | 4.66 → **4.66** |
| Continuity-counter errors | **0** | **0** | **0** |
| — on the second instrument | **0, agrees** | **0, agrees** | **0, agrees** |
| Transport errors / invalid sync | 0 / 0 | 0 / 0 | 0 / 0 |
| PCR interval min/mean/max (ms) | 1.20 / 19.80 / 20.00 → **1.20 / 19.81 / 20.00** | 27.34 / 27.74 / 28.16 → **unchanged** | 0.30 / 24.40 / 24.95 → **0.60 / 24.42 / 24.95** |
| PCR intervals > 40 ms | **0 %** | **0 %** | **0 %** |
| PCR-derived bitrate (b/s) | 10,000,000 → 10,016,717 | 27,507,824 → 27,508,926 | 9,945,951 → 9,950,170 |
| **PCR accuracy, tightest clean bound** | 37 ns → **297,704 ns** | 74 ns → **109,370 ns** | 37 ns → **301,889 ns** |
| **PCR violations at 481 ns (P2 limit)** | 0 → **3,028** | 0 → **22** | 0 → **2,453** |
| PCR violations at 500 µs | 0 → **0** | 0 → **0** | 0 → **0** |

Every component survived at its original PID, including the two the media-aware lane does not
relay and the one no HLS document mentions: **`CNNiEMEA`'s TDT/TOT** (0x0014, repetition
15,134 → 15,130 ms) and **`testloop`'s CAT** (0x0001, 475 → 475 ms, version unchanged). All three
SCTE-35 PIDs on `CNNiEMEA`, the single splice PID on `testloop`, `testloop`'s visual-impaired
commentary audio 0x0042, AC-3 with its typing, teletext and NIT/SDT are all present at source
counts. No table was re-versioned: PMT version churn reads 0 → 0, 2 → 2 and 6 → 6 across the three
clips.

Continuity is counted on two instruments — `analyze`'s per-PID `discontinuities` and `tsp -P
continuity` — because [T16](test-16-grooming-segmented-http.md) measured those two disagreeing on one
stream, 220 against 231. Here they agree at zero on every clip, so the zero is a property of the
captures rather than of one counter.

#### Criterion 6 — what the lane added, exactly

| | `testloop_clean` | `testloop` | `CNNiEMEA` |
|---|---|---|---|
| Mean segment achieved (2 s target) | 2.666 s | 2.751 s | 2.405 s |
| Segment heads *added* in the window | 25 | 23 | 26 |
| PAT packets, excess over equal media | **+25** | +22 | +27 |
| PMT packets, excess over equal media | **+25** | **+23** | **+26** |
| Per segment head | **1.00 / 1.00** | 0.96 / **1.00** | 1.04 / **1.00** |
| PIDs at egress absent from source | **none** | **none** | **none** |

**The lane adds exactly one PAT/PMT pair per segment and nothing else.** The detector counts
back-to-back PAT→PMT pairs, which the source never produces — 0 in the `testloop` and `CNNiEMEA`
references — so it fires only on an injected Media Initialization Section. The ±1 on the PAT row is
the window boundary, where a capture opens or closes mid-segment.

`testloop_clean` is the exception that makes the measure worth stating carefully: its FFmpeg muxer
already writes PAT and PMT adjacently, so the detector reads **614 heads in the source and 639 at
egress** rather than 0 and 25. Both the head row and the packet rows are therefore read as *excess*,
which is the same +25 either way — and is why the accounting is built on excess over equal media
rather than on an absolute count.

#### The clock is where transparency stops, and the error is one injected pair

**PCR *repetition* is preserved and PCR *accuracy* is not.** The P1 mean and maximum intervals are
unchanged from source on all three clips, and 0 % exceed 40 ms — the same result the opaque lane
posts. (The *minimum* interval moves on `CNNiEMEA`, 0.30 → 0.60 ms; T1 attributes sub-millisecond
minima on these clips to capture boundaries and P1 bounds the maximum, so nothing turns on it.) But
the tightest `pcrverify --absolute` bound the egress passes cleanly degrades from tens of nanoseconds
to hundreds of microseconds — and the magnitude is precisely the injected pair:

| | 376 B at the clip's rate | measured max PCR error | agreement |
|---|---:|---:|---|
| `testloop_clean` (10.000 Mbps) | 300.8 µs | 297.7 µs | 99.0 % |
| `testloop` (27.508 Mbps) | 109.4 µs | 109.4 µs | 99.97 % |
| `CNNiEMEA` (9.946 Mbps) | 302.4 µs | 301.9 µs | 99.8 % |

A PAT and a PMT are two packets, 376 bytes. Inserting them at a segment head displaces every later
PCR in that segment relative to a constant-rate byte clock by the time those 376 bytes take to
transmit — which is a property of the clip's bitrate, not of HLS. The prediction therefore has to
scale as 1/bitrate across a 2.75× range, and it does, to within 1 % on every clip. **The mechanism
is not inferred from the numbers; the numbers were predicted from the mechanism and then measured.**

How *many* PCRs breach the 481 ns gate is a separate quantity and a much less stable one: 3,028 of
~3,030 on `testloop_clean`, 2,453 of ~2,457 on `CNNiEMEA`, but only 22 of ~2,163 on `testloop`. It
tracks the direction of the whole-capture rate perturbation (+0.17 %, +0.04 %, +0.004 %) rather than
the segment count, and `testloop` is the only clip where that perturbation is small enough to
attribute to the injection alone — the other two include a window term. Treat the *max* as the
result and the *count* as an indication.

**All three clips pass the campaign's looser 500 µs gate.** So the error sits between the 481 ns P2
gate and the pre-check the campaign uses, which is exactly the band a groomer exists to
close — and [T16](test-16-grooming-segmented-http.md) measured the groomed version of this chain at
**0 violations at 481 ns**. The deviation is real, bounded, attributed, and discharged by the stage
both data planes already require.

#### A 6× duration sweep separates the error's size from its frequency

The mechanism above predicts something the 2 s runs cannot test: because the displacement is *one
pair's* transmit time, the **size** of the error should not depend on segment duration, while the
**number** of injections should scale as 1/duration. Segment duration was swept 1 s / 2 s / 6 s on
`CNNiEMEA`, same 60 s media window, same instrument:

| | 1 s | 2 s | 6 s |
|---|---:|---:|---:|
| Mean segment achieved | 1.195 s | 2.405 s | 6.668 s |
| Segment heads added | 51 | 26 | 9 |
| PAT / PMT packets added | +50 / +51 | +27 / +26 | +9 / +10 |
| **Max PCR error (tightest clean bound)** | **299.6 µs** | **301.9 µs** | **302.4 µs** |
| PCR violations at 481 ns | 2,456 | 2,453 | **8** |
| PCR violations at 500 µs | 0 | 0 | 0 |
| PCR-derived bitrate, excess over source | +0.156 % | +0.042 % | +0.011 % |
| PAT repetition mean (source 125 ms) | 113 ms | 118 ms | 122 ms |

**The error's size is invariant across a 6× change in segment duration — 299.6, 301.9, 302.4 µs, a
1 % spread around the predicted 302.4 µs — while the number of injections changes by 5.7×.** That is
the sharpest confirmation of the mechanism in this experiment: a cumulative error would have grown with
segment count and a per-segment displacement does not. The head count independently tracks the achieved
duration at all three densities (51 × 1.195 s, 26 × 2.405 s and 9 × 6.668 s each span the 60 s window),
which checks the detector as well as the lane.

Both predictions T3 wrote down hold, and one is louder than expected. **The P1 table margin falls
monotonically as segments lengthen** — PAT repetition 113 → 118 → 122 ms against the source's
125 ms — because fewer injected PATs mean less shortening. And **the P2 violation count falls with
duration**, but not proportionally: 2,456 → 2,453 → **8**. Nine injections in 60 s perturb the
whole-capture rate by only +0.011 %, and below some threshold the model no longer drifts past 481 ns
between PCRs at all; 1 s → 2 s changes nothing, 2 s → 6 s changes almost everything. This is a second,
independent demonstration that the *count* is a threshold effect on the capture's mean rate rather than
a per-event tally — established once from three clips at one duration, and again from one clip at three
durations. **The max is the result; the count is an indication.**

The practical reading: **P2 exposure at this measurement point is partly a segment-duration choice** —
a 6 s segmenter posts 307× fewer violations than a 1 s one. It does not remove the need for the
groomer, because the max error is unmoved and the max is what an IRD sees.

#### The same injection buys P1 table margin

Adding a PAT/PMT pair can only shorten a repetition interval, never lengthen one, so the mechanism
that costs P2 accuracy improves P1 table repetition. It shows up most on the clip
[T1](test-1-baseline-ts.md) flagged as having the least margin:

| Table repetition, mean / max (ms) | source | egress | P1 limit |
|---|---|---|---|
| `testloop` PAT | 475 / 475 | **402** / 475 | 500 |
| `testloop` PMT | 475 / 475 | **404** / 475 | 500 |
| `CNNiEMEA` PAT | 125 / 291 | **118** / 291 | 500 |
| `testloop_clean` PAT | 98 / 100 | **94** / 100 | 500 |

T1 warned that `testloop`'s ~475 ms PAT/PMT repetition was close enough to the 500 ms limit that a
transport *adding* table jitter could push it over. This lane adds tables rather than jitter: the
mean falls and the maximum does not move.

#### Against the pass criteria — the segmented-HTTP lane

| Criterion | Result |
|---|---|
| 1. Components | **Met** on all three clips. Video, every audio track including `testloop`'s visual-impaired commentary, teletext and every SCTE-35 PID, each at its original PID and at source counts. |
| 2. Service identity | **Met.** TSID, ONID, service name, provider, service type, PMT PID and PCR PID unchanged. The two non-default PMT PIDs (0x1000, 0x0020) were held rather than renumbered. |
| 3. PSI/SI completeness | **Met.** PAT, PMT, SDT, NIT, TDT/TOT and CAT all survive; no table re-versioned. None of these clips carries EIT, so that table is measured separately on a synthetic fixture through this same rig: all 69 sections of an 8-day EPG arrive byte-identical, sparse schedule sub-tables included, at 1.003× the source's PID rate ([T17](test-17-si-snapshot-tracks.md) §5). |
| 4. Mux structure | **Half met.** Null stuffing is preserved (14.83 → 14.95 %, 5.26 → 5.25 %, 4.66 → 4.66 %). The PCR-derived bitrate is **not** equal to source — it rises by +0.004 % to +0.17 %, upward on every clip, which is the injected packets showing up in a whole-capture rate estimate. Same cause as criterion 6. |
| 5. Integrity and P1 timing | **Met.** 0 continuity errors on two independent instruments, 0 transport errors, 0 invalid sync, 0 PCR intervals above 40 ms, and every table inside its P1 repetition limit — with more margin than the source had. |
| 6. Nothing added | **Failed, as expected, and by exactly one thing.** No PID and no table the source lacked, but one PAT/PMT pair per segment: +25/+25, +22/+23 and +27/+26 against 25, 23 and 26 segment heads. The cost is 109–302 µs of file-domain PCR accuracy, closed by grooming ([T16](test-16-grooming-segmented-http.md)). |

Criteria 4 and 6 fail together and for one reason, which is the useful form of the result: **the lane's
only departure from transparency is that it inserts two packets per segment**, and both the rate row
and the conservation row are that fact measured two ways.

### The three lanes, side by side

Media-aware column shows as-shipped and, where PR #2440 changes it, the state after "→".

| Property | T2 media-aware (`moq-dev`) | T3 opaque (platform) | T3 segmented HTTP |
|---|---|---|---|
| Wire model | demux → typed + opaque tracks (hang catalog) | whole-TS Objects (MSFTS `m2ts` catalog) | TS sliced at packet boundaries, PAT/PMT per segment |
| Elementary streams | preserved (all audio, teletext, SCTE-35) | **preserved, verbatim, same PIDs** | **preserved, verbatim, same PIDs** |
| PAT / PMT | PMT renumbered → 0x1000 → **kept (#2440)** | **PMT PID kept** | **PMT PID kept** (0x1000, 0x0020, 0x0064 all held) |
| SDT / NIT | dropped → **preserved (#2440)** | **preserved verbatim** | **preserved verbatim** |
| TDT/TOT | **dropped** | **preserved verbatim** | **preserved verbatim** |
| CAT | **dropped** | **preserved verbatim** | **preserved verbatim** |
| Service name / type | lost → **preserved (#2440)** | **preserved** | **preserved** |
| TSID / ONID | regenerated → **preserved (#2440)** | **preserved** | **preserved** |
| SCTE-35 splice PIDs | carried (opaque per-PID tracks) | **preserved in-mux, verbatim** | **preserved in-mux, verbatim** |
| Mux structure | VBR; nulls stripped (CBR restored by pacer) | **CBR preserved; nulls preserved** | **nulls preserved**; PCR-derived rate +0.004–0.17 % |
| Continuity errors | **0** | **0** | **0** |
| PCR intervals > 40 ms (P1), file domain | 0–26 % by clip → **0 % (paced)** | **0 %** | **0 %** |
| PCR accuracy, file domain | **gate is degenerate ungroomed** — no mux rate to grade against, and meaningful only once a groomer restores one (below) | not measurable on this machine (below) | **37–74 ns → 109–302 µs**; 0 violations at 500 µs; **0 at 481 ns once groomed** ([T16](test-16-grooming-segmented-http.md)) |
| Packets added to the mux | rebuilt, so not comparable | **none** | **one PAT/PMT pair per segment, and nothing else** |
| Egress monitoring | none | **built-in TR 101 290** | none |
| Transparency verdict | media-faithful; with #2440 + pacer, transparent **except TDT/TOT** (by design) **and EIT** (until [#2824](https://github.com/moq-dev/moq/pull/2824) merges) | **broadcast-transparent** | **transparent to the mux's content; not to its clock** |

#### Why the PCR-accuracy row cannot be filled across lanes

That row was expected to be a cheap gap to close: run `pcrverify --absolute` on the two MoQ lanes and
make it a three-way comparison. **It is not closable, and the reason is a property of the gate rather
than of the lanes.**

The media-aware lane was captured ungroomed on all three clips on a named current build
(`moq 0.9.10-eab960192`, stock `main`, via [`t14-a.sh`](scripts/t14-a.sh) — the same rig and the same
ungroomed measurement point T14 leg A uses) and graded:

| Media-aware ungroomed egress | `testloop_clean` | `testloop` | `CNNiEMEA` |
|---|---:|---:|---:|
| Null stuffing | **0 packets** | **0 packets** | **0 packets** |
| `analyze`'s declared bitrate | 22.0 Gb/s | 25.4 Gb/s | 32.2 Gb/s |
| Max PCR interval | 160.000 ms | 39.9889 ms | 319.933 ms |
| **Tightest clean `--absolute` bound** | **159.995 ms** | **39.9886 ms** | **319.931 ms** |
| Bound ÷ max interval | **0.99997** | **0.99999** | **0.99999** |
| Violations at 481 ns | 1,113 of 1,130 | 2,244 of 2,255 | 1,097 of 1,125 |
| Violations at 500 µs | 332 | 1,127 | 155 |

**The "PCR accuracy" the gate reports on this lane is numerically the maximum PCR interval** — to
within 0.003 % on three clips whose maxima differ by 8×, which is not a coincidence that needs a
second explanation. The lane demuxes and rebuilds, so its ungroomed egress carries no stuffing and
therefore no mux rate: `analyze` puts the "bitrate" at 22–32 **Gb/s** on ~10–27 Mb/s content. Asked to
compare PCR values against byte positions in a stream that has no byte clock, `pcrverify --absolute`
returns the gap between PCRs. It is measuring the burst structure of MoQ object delivery, not carriage
fidelity, and quoting 160 ms beside segmented HTTP's 302 µs would be comparing a PCR interval with a
PCR error.

So the gate is meaningful exactly where a mux rate survives. It is meaningful on the source clips
(37–74 ns), and on segmented HTTP (109–302 µs) because that lane preserves stuffing and CBR — which is
why the injection shows up there at all. On the media-aware lane at this measurement point it is
undefined, and what it actually establishes is the thing T13 and T16 already concluded from the other
direction: **on that lane the groomer is not an optimisation, it is what creates the quantity the gate
names.**

**The opaque lane still cannot be graded, but the reason has moved.** Its source tree turned out to
survive on the EC2 host ([T4](test-4-remote-e2e-srt.md)), with a `Cargo.lock` pinning
`moq-transport` 0.14.2 / `moq-native` 0.17.0 / `moq-relay` 0.12.9 — the versions this experiment
recorded — and it builds on macOS from that lock. So the lane is recoverable and
[`t3-opaque-lane.sh`](scripts/t3-opaque-lane.sh) now scripts what was previously a hand-run sequence.

What blocks the grade is the egress, not the transport. Publisher, relay and subscriber connect, the
subscriber accepts a playout reader and reports `bytes_out` climbing at ~10 Mb/s with 0
discontinuities, and **no bytes reach the reader** — reproduced four ways (TCP passthrough with and
without `--no-pacing`, UDP passthrough, and TCP `--egress-profile broadcast --mux-rate`), with `lsof`
confirming a single established connection and no write error logged. Whether that is a defect in this
build or an artefact of building it on macOS is unresolved; the discriminator is to run the same chain
with the Linux binaries already present on EC2.

So **"the opaque lane preserves PCR arithmetic" remains reasoned from byte-preservation rather than
measured**. Being byte-preserving by construction it would return its source's own figure, but that is
an argument, and the row says so rather than showing a number.

---

## Observations

- **The opaque lane is byte-transparent at P1**: TSID/ONID, service name/type, all PSI/SI
  (PAT/PMT/SDT/NIT/TDT/CAT), PMT PID, PCR PID, every elementary stream and every SCTE-35 PID
  preserved verbatim; 0 CC / transport errors; CBR and PCR conformance preserved when fed raw.
- **Segmented HTTP is transparent to what a mux contains and not to when it was sent, and that is a
  sharper claim than "verbatim".** [T14](test-14-data-plane-comparison.md) established the content
  half by comparing a segment against the source; the missing half is that the lane is *additive*.
  It preserves everything, including two tables the media-aware lane drops, and it inserts a
  PAT/PMT pair every segment that no MoQ lane inserts. Fidelity to the payload and fidelity to the
  multiplex are different properties, and a lane can hold the first while breaking the second.
- **A transparency claim needs a "what was added" column, not only a "what survived" one.** The
  census that a lane is scored on is naturally a loss detector: it counts what the source had and
  looks for it at egress. Nothing in that shape can see 46 extra packets, and on this lane those 46
  packets are the entire deviation — they move the P2 PCR-accuracy figure by four orders of
  magnitude while every survival row reads clean. This generalises past segmented HTTP to any stage
  that re-heads, re-indexes or re-stamps a mux.
- **Predicting the deviation before measuring it is what made it attributable.** 376 bytes at the
  clip's own rate is 300.8, 109.4 and 302.4 µs on the three clips; the measured maxima are 297.7,
  109.4 and 301.9. Had the same numbers arrived without the prediction they would have been
  reported as "sub-millisecond PCR error at segment boundaries" and left there. The 2.75× bitrate
  spread is what turns agreement into evidence, because a wrong mechanism would not track 1/bitrate.
- **The error is per-segment, which a duration sweep can prove and a single duration cannot.** Holding
  the clip and the window fixed and moving segment duration 1 s → 6 s changes the injection count by
  5.7× and the maximum PCR error by 1 %. That is the difference between a per-event displacement and an
  accumulating one, and it is only visible by varying the thing the mechanism says should not matter.
  The same sweep shows the *count* of P2 violations collapsing 2,456 → 8, which is why the count is
  reported as an indication and the max as the result.
- **A gate can be undefined on a lane rather than merely unmeasured, and the difference is not
  cosmetic.** The P2 PCR-accuracy row looked like a missing measurement; it is a category error on the
  media-aware lane, whose ungroomed egress has no mux rate for an absolute gate to reference. The
  instrument does not refuse — it returns the maximum PCR interval, a plausible-looking number three
  orders of magnitude from the truth. An unfilled cell is worth interrogating before it is filled.
- **The two timing gates disagree about this lane, and both are right.** PCR *repetition* — the P1
  interval — is untouched, because inserting packets does not change PCR *values*. PCR *accuracy* —
  the P2 arithmetic — moves a long way, because it compares those values against the byte positions
  they arrived at, and the lane changed the byte positions. A rig quoting one gate as "PCR
  conformance" would report this lane as perfect or as broken depending on which it happened to run.
- **The deviation is discharged by a stage both planes already need.** T16 measured the groomed
  version of this chain at 0 violations at 481 ns, so nothing here argues against segmented HTTP on
  fidelity grounds. What it does establish is that the segmented lane's egress **cannot be handed to
  an IRD ungroomed** on the strength of being verbatim, which is how a reading of T14 alone might
  have it.
- Transparency is only as good as what touches the TS on either side: an FFmpeg `-c copy` remux in
  the contribution path, or a demux/remux lane (T2), rewrites the stream regardless of MoQ or HTTP.
- Capture-tooling detail: TSDuck's UDP `ip` input dropped some subscribers' non-188-aligned egress
  datagrams (0 bytes captured while the subscriber's own counters showed full egress); the aligned
  TCP playout capture was used for `CNNiEMEA` / `testloop`. Not a lane defect.

---

## Conclusion

**Gate 1 media fidelity is met at P1 on both lanes, and only one of them is transparent in both
directions.** The opaque lane adds nothing and preserves everything, which is what a fallback lane is
for. Segmented HTTP preserves everything too — including `testloop`'s CAT and `CNNiEMEA`'s TDT/TOT,
which the media-aware MoQ lane drops — and adds one PAT/PMT pair per segment, which costs ~300 µs of
file-domain PCR accuracy at 10 Mbps and ~110 µs at 27.5 Mbps. That is its whole departure from
transparency, measured on three clips: two packets per segment, and nothing else.

**So the carriage-fidelity axis does not separate the opaque lane from segmented HTTP for a single
programme, and the remaining separation is the clock and the multi-programme case.** The clock
deviation is bounded, attributed to a named mechanism, and closed by the grooming stage the
distributor owns on both planes ([T16](test-16-grooming-segmented-http.md)) — so it is a
demarcation finding rather than a fidelity one. The multi-programme case is where HLS's normative
"Transport Stream Segments MUST contain a single MPEG-2 Program" bites, it is unrun, and it now
carries the whole of MoQ's residual carriage advantage.

**The P2 PCR-accuracy axis does not rank the lanes, and that is a finding rather than a gap.** It is
defined only where a mux rate survives the transport, which is true of segmented HTTP and of the opaque
lane and false of the media-aware lane's ungroomed egress. Where it is defined it is informative — it
is what caught the injected pair. Where it is not, it returns the maximum PCR interval and looks like
an answer.

The load-bearing gaps that remain are **P2 hardware conformance** ([T7](test-7-timing-integrity.md),
Gate 2) and a **real-time / remote contribution path** ([T4](test-4-remote-e2e-srt.md)) —
file-based localhost transparency is necessary, not sufficient. Recorded as a permanent finding in
[`docs/evidence.md`](../docs/evidence.md).

### Still open

| Cell | Needs |
|---|---|
| The opaque lane at the P2 PCR-accuracy gate | **a working egress on that lane.** The build is recovered (source survives on EC2, compiles on macOS at its own lock) and rigged in [`t3-opaque-lane.sh`](scripts/t3-opaque-lane.sh), but no output protocol delivers bytes to a reader while the subscriber reports them sent — four configurations tried. Next step is the same chain on EC2's Linux binaries, to separate a build defect from a macOS one. The media-aware half of this cell is closed, with the finding that the gate is degenerate there |
| Multi-programme carriage through both lanes | the MPTS fixture and, for HLS, a real CDN ([planned-experiments](planned-experiments.md)). This now carries the whole of MoQ's residual carriage advantage |
| A lossy segmented path | a path that drops segments. Nothing was ever missing here, only late — so this experiment says what a lane *does* to a mux, never what it does when the path damages one |
| The opaque lane on a current draft | it remains pinned to draft-14 against a private implementation, and has never been repeated |
| The duration sweep on the 27.5 Mbps clip | one rig invocation. The sweep ran on `CNNiEMEA` only; the invariance claim rests on the bitrate spread from the three-clip runs rather than on a second sweep |

---

## Corrections

> The general method rules extracted from this section, together with those from every other
> experiment, are collected in [method-notes.md](method-notes.md). What stays here is the
> specific record of what this experiment got wrong.

**Two P1 timing rows were silently absent from the first set of reports, and nothing failed.**
`pcrextract --csv` writes its series to TSDuck's *report* stream — stderr — unless given `-o`, so an
analyser reading stdout receives an empty series. The interval computation then returned nothing, the
rows were skipped by a truthiness test, and three complete-looking tables were produced with the PCR
interval and the >40 ms rows simply not there. The mistake was visible only by comparing the output
against the columns it was supposed to have. *Lesson: a harness that skips a row when its instrument
returns nothing cannot distinguish "no violations" from "no measurement". Make the analyser fail on
an empty series rather than omit the row — and note that this is the same class of error as
[T16](test-16-grooming-segmented-http.md)'s `--jitter-max` unit confusion: both are TSDuck options
whose behaviour depends on a sibling flag rather than on the value passed.*

**"Closing the PCR-accuracy row is cheap" was wrong, and wrong in a way that mattered.** This file
listed the row as needing "nothing — the captures and the analyser exist", on the assumption that an
unfilled cell is unfilled for want of instrument time. Two things were false. The opaque lane's build
was gone from the machine, so half the cell was blocked on an artefact rather than on a run; and on the
half that *could* be run, the gate turned out not to measure the quantity its name implies — on a
stuffing-free egress `pcrverify --absolute` returns the maximum PCR interval, matching it to 0.003 % on
three clips. *Lesson: before booking a gap as cheap, check that the instrument is defined on the thing
being compared. A conformance gate that presupposes a property of the stream — here a constant mux
rate — cannot rank lanes that differ in whether they have that property, and will silently return a
plausible number instead of refusing. This is the same failure family as the two below: an instrument
that answers a question adjacent to the one asked.*

**A PCR-accuracy figure is window-dependent, so it carries its window like any other count.** The
`CNNiEMEA` source reads **37 ns** over the 60 s reference cut used throughout this experiment and
**74 ns** over the whole 5-minute clip, because a maximum over more media can only grow. Both numbers
are correct and they are not interchangeable; the tables here are the reference-cut figures, matching
the egress windows they are compared against. *Lesson: the campaign's equal-window rule is not only
about rates and ratios — it applies to any statistic that is an extremum, which includes every
"tightest clean bound" in this repository.*

**The source reference was cut from the head of the file, and one clip is not homogeneous there.**
The census compares two equal-packet windows, which measures the lane only if both cover equivalent
mux. `testloop_clean` carries **18.43 % stuffing over its first 60 s against 13.1–13.8 % later on**,
so a head cut against a live-edge egress reported stuffing falling 18.43 → 14.95 % and video rising
by 13,858 packets — which reads exactly like a lane stripping padding, and is a property of the clip.
The rig now offsets the reference by the publisher's elapsed run time at the join, which brings the
same comparison to 14.83 → 14.95 %, and the analyser reports the reference's stuffing by quarter so a
non-homogeneous window is declared rather than discovered. *Lesson: this is [T9](test-9-performance.md)'s
loopback span artefact in its content form — the windows were the same length and still not
comparable. Equal duration is not equal media, and the assertion belongs in the instrument, because
the failure produces a plausible number rather than an error.*

---

## References

- Lane choice and the fallback rationale: [`docs/architecture.md`](../docs/architecture.md) §6;
  [`docs/architecture.md`](../docs/architecture.md) §4.2.
- Media-aware counterpart: [test-2-media-aware-transparency.md](test-2-media-aware-transparency.md).
- P0 inventory every column is scored against: [T1](test-1-baseline-ts.md) §5.6.
- [T14](test-14-data-plane-comparison.md) measurement 4 — the packet-level verbatim result this
  extends from one clip to three and adds the additive direction to.
- [T16](test-16-grooming-segmented-http.md) — the groomed version of this same chain, which closes
  the PCR-accuracy deviation measured here.
- Finding: [`docs/evidence.md`](../docs/evidence.md) §3.1.
- Rigs: [`t3-segmented-transparency.sh`](scripts/t3-segmented-transparency.sh),
  [`t3-transparency.py`](scripts/t3-transparency.py), and [`t14-a.sh`](scripts/t14-a.sh) for the
  media-aware capture graded in the PCR-accuracy section.

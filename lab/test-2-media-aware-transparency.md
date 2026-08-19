# T2 — Transport transparency, media-aware lane (local)

## Objective

Exercise the upstream `moq-dev` **media-aware** lane (`moq import ts` → `moq-relay` → `moq export ts`)
end-to-end on localhost: prove the non-opaque transport works against the public reference
implementation, enumerate exactly which components (per the T1 §5.6 inventory) are carried, and
measure the impairments the lane introduces. The opaque lane (T3) is the byte-for-byte counterpart;
the direct contrast is in T3.

## Environment

- Binaries: `moq` / `moq-relay` built from `github.com/moq-dev/moq` (`moq-native` 0.18.3), carrying
  the #1979 catalog-reservation fix (#2072) and open-GOP recovery-point detection (#2066). Protocol
  negotiated **moq-lite-04** (moq-lite, the forwards-compatible subset — not the draft-14 transport
  the opaque platform pins). Binary supports moq-lite-01…04, moq-transport-14…17.
- Relay config `demo/relay/localhost.toml` (QUIC + HTTP on `[::]:4443`, self-signed `localhost`,
  anonymous auth).
- Feed pacing: TSDuck `regulate` (real-time, PCR-based). TSDuck 3.44-4676.
- Downstream groomer: [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) 0.1.0 via its
  offline `cbr_file` example — byte-locks PCR to output byte position (`PcrMode::Regenerate`),
  re-inserts byte-locked PCR-only packets on the PCR PID, strips input nulls, stuffs to the target
  mux rate. Not a muxer: PID structure, continuity counters and PSI/PES payloads pass through
  untouched.
- All localhost. macOS loopback gotchas apply (see `lab/README.md`).

Two upstream changes separate the as-shipped behaviour recorded below from the current one: the #1979
catalog-reservation fix (#2072, with open-GOP recovery-point detection #2066), and the DVB
service-layer preservation in PR [#2440](https://github.com/moq-dev/moq/pull/2440). Results are
labelled by which side of those they sit on.

## Procedure

```bash
# 1. relay
cd ~/moq-dev
./target/release/moq-relay demo/relay/localhost.toml --server-quic-gso=false

# 2. publish (media-aware import), real-time paced; <name>.hang selects the hang catalog
tsp -I file <clip> -P regulate -P until --seconds 35 \
  | ./target/release/moq --client-connect http://localhost:4443 \
      --client-quic-gso=false --broadcast <name>.hang import ts

# 3. subscribe (export back to TS), started ~4 s after the publisher
./target/release/moq --client-connect http://localhost:4443 \
    --client-quic-gso=false --broadcast <name>.hang export ts > <name>_out.ts

# 4. carried tracks, from the subscriber log
grep -oE 'track=[^ ]+' <name>_sub.log | tr -d '"' | sort -u

# 5. analyse egress (analyze / continuity / pcrextract per lab/README.md)

# 6. groom the VBR egress to CBR, then re-analyse (<rate> ≈ 1.2× source: 12/33/12 Mbps)
cargo run -q -p mpegts-pacer --example cbr_file -- <name>_out.ts <name>_paced.ts <rate> regenerate
tsp -I file <name>_paced.ts -P pcrverify --jitter-max 500 -O drop
tsp -I file <name>_paced.ts -P analyze -O drop     # now exact CBR
python3 mpegts-pacer/test/compliance.py --ts <name>_paced.ts --reference <name>_out.ts
```

For the #1979 / #2440 metadata run, `CNNiEMEA2.ts` was fed two ways to separate the lane from the
ingest — (A) an `ffmpeg -stream_loop -re -c copy` loop (which re-muxes the container) and (B) a raw
`tsp regulate --pcr-synchronous` control (source PSI/SI/PIDs reach the lane intact). The subscriber
is started first so the reservation gate publishes one complete catalog snapshot.

## Results

### Track carriage (catalog + egress)

`moq import ts` builds a **hybrid catalog**: recognised codecs become typed tracks (`0.avc3` =
H.264, `0.aac`/`0.mp2` = audio); every other elementary PID is carried as an opaque per-PID `N.ts`
track. PSI/SI service tables are **not** represented as tracks.

| Source | Tracks advertised & subscribed | Elementary components preserved in egress (P1) |
|---|---|---|
| `testloop_clean` | `catalog.json`, `0.avc3`, `0.aac` | video 0x0100, audio 0x0101 |
| `testloop` | `catalog.json`, `0.avc3`, `0.mp2`, `1.mp2`, `0.ts`, `1.ts`, `2.ts` | video 0x0030, audio 0x0040/0x0041(AC-3)/0x0042(VI), teletext 0x0050, SCTE-35 0x0060 |
| `CNNiEMEA` | `catalog.json`, `0.avc3`, `0.mp2`, `0.ts`…`4.ts` | video 0x006F, audio 0x0079/0x007B(AC-3), teletext 0x0083, SCTE-35 0x008D/8E/8F |

All video, all audio (incl. AC-3 and the visual-impaired commentary), teletext, and **every**
SCTE-35 splice PID were carried at their **original PID numbers** with **0 CC errors** and 0
transport errors. The real CNN open-GOP feed produced video successfully.

### Impairments introduced by the lane (as-shipped, pre-#2440)

| Metric | `testloop_clean` | `testloop` | `CNNiEMEA` | Source (P0) |
|---|---|---|---|---|
| Egress size captured | 21.0 MB | 65.2 MB | 24.3 MB | — |
| Continuity-counter errors | 0 | 0 | 0 | 0 |
| Service name / type | lost (unknown / Undefined) | lost | lost | present |
| SDT / NIT / TDT / CAT | dropped | dropped (CAT, SDT) | dropped (NIT, SDT, TDT) | present |
| PMT PID | 0x1000 (was 0x1000) | 0x1000 (was 0x0020) | 0x1000 (was 0x0064) | source PID |
| PCR PID | 0x0100 (kept) | 0x0030 (kept) | 0x006F (kept) | kept |
| CBR pacing / null packets | none | none | none | CBR |
| PCR interval max (ms) | 1680¹ | 1120¹ | 319.9 | 20–28 |
| PCR intervals > 40 ms | **25.5 %** | 0.10 %¹ | **13.7 %** | 0 % |

¹ Multi-hundred-ms / 1-second maxima include a live-join / capture-stop artefact (subscriber joins
and is killed mid-group). The robust figure is the **percentage** over 40 ms. `testloop_clean`'s
25.5 % closely matches the ~24 % pre-groom figure independently measured in evidence §3.

### `mpegts-pacer` grooming closes the P1 timing gap

Raw egress → paced egress, same three clips (`regenerate` mode):

| Metric (raw → paced) | `testloop_clean` | `testloop` (4:2:2) | `CNNiEMEA` |
|---|---|---|---|
| Target CBR mux rate | 12 Mbps | 33 Mbps | 12 Mbps |
| Reference bitrate | bursty → **12.000 exact** | bursty → **33.000 exact** | bursty → **12.000 exact** |
| PCR intervals > 40 ms | 25.4 % → **0 %** | 0.07 %¹ → **0 %** | 13.6 % → **0 %** |
| PCR interval max (ms) | 240 → **30.7** | 1000¹ → **30.3** | 320 → **30.8** |
| PCR interval mean (ms) | 40.3 → **20.9** | 20.6 → **19.2** | 39.6 → **21.3** |
| `pcrverify` > 500 µs (over/total) | 229/792 → **0/1525** | 753/1507 → **0/1623** | 104/764 → **0/1422** |
| Bitrate CoV (1 ms / 10 ms) | 9.59 → **0.11 / 0.02** | 4.40 → **0.03** | 16.4 → **0.10** |
| Burstiness (peak/mean) | 378× → **1.27×** | 172× → **1.13×** | 388× → **1.25×** |
| Null stuffing (ratio; packets) | 0 → **30.9 % (78,645)** | 0 → **23.3 % (159,059)** | 0 → **20.0 % (48,274)** |
| PCR-only packets re-inserted | **733** | **116** | **658** |
| Content packets dropped | **0** | **0** | **0** |
| Continuity-counter errors | 0 → **0** | 0 → **0** | 0 → **0** |
| Compliance harness verdict | fail → **PASS²** | fail → **PASS²** | fail → **PASS²** |

² PASS on every hard structural check (packet size, sync, PAT/PMT, PSI CRC, continuity, PCR
presence/monotonicity, duration-fidelity vs the raw egress) and all shape checks except two that
are **not** the pacer's to fix: `service-descriptors` (the SI the lane already dropped upstream — a
pacer is not a muxer) and `tstd` (the harness's fixed 512-byte transport-buffer / default leak-rate
model flags the clustered elementary streams — a property of the input content).

### What #1979 resolves, and the service-layer gap closed by PR #2440

The old aborts (`TS track layout changed after PAT/PMT was emitted` / `requires a video track for
the program clock`) are gone. #1979 is fixed by two changes the round-trip both needs, on the same
tree: **#2072** (catalog reservation gating — the exporter withholds PSI until every PMT-reserved
track resolves) and **#2066** (open-GOP recovery-point-SEI keyframe detection, without which an
IDR-less feed's video never resolves and the gate stays shut). The raw-fed control carried every
component at its original PID, `stream_type` and descriptors verbatim:

| Component (raw-fed) | Source PID / type | Egress PID / type | Descriptors carried |
|---|---|---|---|
| Video (AVC) | 0x006F / 0x1B | **0x006F / 0x1B** | AVC video (0x28), Maximum-bitrate (0x0E) |
| Audio (MP2) | 0x0079 / 0x03 | **0x0079 / 0x03** | ISO-639 language, Audio-stream, Max-bitrate |
| Audio (AC-3) | 0x007B / 0x06 | **0x007B / 0x06** | ISO-639 language, AC-3 (0x6A), Max-bitrate |
| Teletext | 0x0083 / 0x06 | **0x0083 / 0x06** | ISO-639 language, Teletext (0x56) |
| SCTE-35 ×3 | 0x008D/8E/8F / 0x86 | **0x008D/8E/8F / 0x86** | program-level CUEI registration ×3; splice sections present |
| PCR PID | 0x006F | **0x006F (kept)** | — |

The DVB **service layer** was a separate gap: the `mpegts` catalog
(`rs/moq-mux/src/container/ts/catalog.rs`) modelled per-PID PMT info + verbatim ES only, with no
field for service identity or standalone SI, so `export ts` rebuilt just PAT + PMT. PR #2440 threads
a service record through the catalog and rebuilds the SI on export:

| Metadata field | Source (P0) | As-shipped egress | With PR #2440 |
|---|---|---|---|
| SDT (service name / provider) | "CNNI EMEA HD" / "Warner Bros. Discovery" | dropped → (unknown) | **preserved** |
| SDT service type | 0x19 (Advanced-codec HD TV) | dropped → 0x00 | **preserved** |
| NIT (network) | present (0x0010) | dropped | **preserved** |
| Transport-stream ID | 0x0000 | regenerated → 0x0001 | **preserved** |
| Original Network Id | present | not preserved | **preserved** |
| PMT PID | 0x0064 | renumbered → 0x1000 | **preserved (0x0064)** |
| TDT / TOT (time) | present (0x0014) | dropped | **still dropped**, deliberately |
| EIT (event / EPG) | absent from every clip held; synthesised (below) | n/a | dropped by #2440; **p/f actual carried by [#2824](https://github.com/moq-dev/moq/pull/2824)**, an open PR |

### EIT: measured on a synthetic fixture, and what carrying it would cost

No capture held here carries EIT, so the claim that the lane drops it rested on reading the import
gate rather than on a measurement. [`make-eit-fixture.sh`](scripts/make-eit-fixture.sh) closes that
by injecting a twelve-event EPG onto PID 0x0012 of `CNNiEMEA2.ts` with `tsp -P eitinject`, anchored
to the clip's own TDT epoch so the present event is genuinely current. The EIT packets are taken
from the clip's null stuffing, so the fixture is the same 9,945,951 bps CBR stream as the source
with 0 CC errors, and the two variants (`pf`, `full`) differ only in whether EIT schedule is
generated alongside p/f.

Round-tripped by [`eit-roundtrip.sh`](scripts/eit-roundtrip.sh) through a local relay on `main`
@ `9698cd93` (post-#2440), 45 s capture:

| Table | PID | Source packets | Egress packets |
|---|---|---:|---:|
| NIT | 0x0010 | 119 | 5 |
| SDT | 0x0011 | 574 | 21 |
| EIT | 0x0012 | 1,153 | **0** |
| TDT/TOT | 0x0014 | 40 | **0** |

The egress carries PAT, NIT, SDT/BAT, PMT, video, both audio tracks, teletext and all three SCTE-35
PIDs — and nothing on 0x0012 or 0x0014. NIT and SDT survive at the catalog's repetition cadence
rather than the source's, which is #2440 working as designed.

The same fixture prices the fix, because #2440 dedupes SI sections by identity and only takes the
catalog write lock when the bytes change. What matters is therefore the *revision* rate, not the
repetition rate:

| Table | Sections transmitted | Distinct | Mean distinct section |
|---|---:|---:|---:|
| NIT | 119 | 1 | — |
| SDT | 574 | 1 | — |
| EIT p/f actual | 592 | **4** | 77 B |
| EIT schedule actual | 420 | **8** | 129 B |
| TDT/TOT | 40 | **40** | — |

EIT would cost 12 catalog updates and ~1.3 kB of catalog state over ten minutes — the same order as
SDT and NIT, because it repeats byte-identically between event transitions. TDT/TOT is the opposite
and is why the two tables need different answers: every section is new content, so each one is a
republish, for a table that says nothing but "now" and that an exporter can mint more accurately
than it can relay. The scaling caveat is that distinct-section count grows with events × services:
p/f is bounded at two sections per service, schedule is not.

### EIT p/f survives the round-trip on #2824's branch, verified on the same fixture

The PR is **open**, so nothing below is in a released build; it is the measurement of a proposed fix,
not of shipped behaviour. [#2824](https://github.com/moq-dev/moq/pull/2824) acts on that split:
`SI_PIDS` gains a `table_id`
filter and 0x0012 enters carrying p/f actual (0x4E) only, at a 2 s interval. Re-running
`eit-roundtrip.sh` against the PR head, EIT goes **0 → 37 packets** at egress over a 43 s export,
all of them 0x4E, with every one of the 411 schedule sections dropped. That is 19 emissions of a
two-section table, ~2.4 s apart against the 2 s interval; SDT and NIT are undisturbed at ~2.2 s and
~10.8 s, and TDT/TOT stays at zero.

The carried sections are **byte-identical to the source**. Cutting a 60 s window across the point
where the EPG's version rolls from 0 to 1 and reassembling both sides, all four p/f sections match
exactly (90, 65, 65 and 88 bytes), every schedule section is absent, and the egress makes the version
switch once and cleanly — v0 ×27 then v1 ×28, with no flapping and no stale version left behind.

**The `current_next_indicator` guard needed a fixture built for it.** The PR also drops sections
carrying a version that is not yet in force, which nothing here transmitted.
[`ts-eit-pending-version.py`](scripts/ts-eit-pending-version.py) marks the first occurrences of the
new version as pending and recomputes the section CRC, so the result is a legal stream and a
rejection means the guard fired rather than the section being malformed. On that clip the egress
carries **v0 ×47 then v1 ×8** against ×27/×28 unpatched, and no pending section appears at all: the
exporter holds the version that applies and adopts the new one only when it becomes current. Without
the guard each pending section would have replaced the current one under the same identity and
republished the catalog every repetition.

Not covered here: EIT p/f *other* (0x4F), which the PR also excludes because `section_key` cannot
tell two foreign services with the same `service_id` apart. No source held here carries it.

### What carried SI costs the catalog, and why it is a scaling question

The catalog is whole-state: one changed SI section rewrites the entire document on the plaintext
and DEFLATE tracks, and appends a group to the MSF one. Whether that matters cannot be read off a
single-service capture, so it was measured against service count.
[`si-catalog-cost.rs`](scripts/si-catalog-cost.rs) records every catalog publish on all three
tracks; [`make-mpts-fixture.sh`](scripts/make-mpts-fixture.sh) supplies the multiplexes, grafting
SDT and NIT for N services and a rolling EPG onto this clip's media. That graft is not a
contrivance: a real SPTS carved out of a distribution multiplex carries its whole multiplex's SDT,
NIT and EIT p/f in full.

**SDT and NIT cost nothing after acquisition.** Ten minutes of `CNNiEMEA2.ts`: 7 catalog publishes,
none caused by SI, 184 B of a 1,587 B catalog. Synthesised to 40 services the standing size grows
but the churn is still exactly zero, because neither table turns over.

**EIT is what makes it expensive, and the cost is the product of two growing terms** — the number of
republishes at a programme junction and the size of each document:

| services | standing catalog | SI share | junction | plain | deflate | active set as binary |
|---|---:|---:|---|---:|---:|---:|
| 1 | 2,180 B | 34.8 % | 2 republishes in 0.11 s | 4,360 B | 1,625 B | 525 B |
| 12 | 6,746 B | 79.2 % | 20 republishes in 0.11 s | 134,920 B | 26,935 B | 3,900 B |
| 40 | 18,428 B | 92.7 % | 61 republishes in 1.27 s | 1,124,108 B | 157,958 B | 12,531 B |

Between 12 and 40 services, 3.3× the services costs 8.3× the junction. The bandwidth is not the
problem — 1.12 MB against a multiplex of tens of Mb/s is noise, and a consumer reads one track
rather than their sum. What the numbers actually indict is the *join* (18,428 B read before media
discovery, 92.7 % of it SI, against 1,342 B without) and the *parsing* (every consumer re-parsing
an 18 kB document 61 times in 1.27 s for a table it will never use).

Two further findings are not about scale at all:

- **A multi-section table is assembled in the catalog in public.** At 40 services the SDT is held at
  1 of its 2 sections for 5.2 s across 53 publishes. Section 0 declares `last_section_number = 1`,
  so an exporter re-emitting that state puts a table on the wire that announces two sections and
  transmits one — incomplete rather than merely stale. No tuning of the catalog fixes this; the
  fault is that a whole-state document is revised one section at a time.
- **The MSF catalog churns identically.** It is derived from the media sections alone, so an
  SI-only change appends a byte-identical group: 120 groups with 4 distinct payloads by SHA-256
  over the 40-service run. That holds on the real single-service feed too.

These are the measurements behind [#2882](https://github.com/moq-dev/moq/issues/2882), which asks
whether carried SI belongs in the catalog or on its own snapshot track. They support the move — on
the coherence argument more than the cost one — but they also show that the tables #2440 actually
shipped would gain nothing from it.

Paced `CNNiEMEA2` egress (raw-fed → `auto` regenerate): **10.999 Mbps exact CBR**; PCR > 40 ms
9.08 % → **0 %** (max 320 → 31.9 ms); `pcrverify` > 500 µs → **0/2286**, max |jitter| 6 µs; null
stuffing 0 → **12.8 % (40,910 pkts)**, 645 PCR-only re-inserted, **0 dropped**; **0 CC**; all 7
elementary streams + SCTE-35 type 0x86 + descriptors intact; compliance `ts: PASS` (only WARNs:
`service-descriptors`, `tstd`).

The `ffmpeg`-loop feed (A) additionally showed two ingest-side artefacts that are ffmpeg's, not the
lane's: `ffmpeg -c copy` re-muxes the container, renumbering PIDs (PCR → 0x0100) and re-labelling
SCTE-35 as private `stream_type` 0x06 before the bytes reach `moq import`. The raw-fed control (B)
is the faithful measure.

## Observations

- As shipped, the media-aware lane is *media-faithful* (elementary streams, continuity, PCR PID
  intact) but **not broadcast-transparent**: it dropped the DVB service layer, renumbered the PMT,
  and emitted non-CBR bursty egress violating TR 101 290 P1 on 13.7 % and 25.5 % of intervals
  for the two clips whose native PCR cadence is coarser than the exporter's group boundaries, and on
  0.10 % for the 27.5 Mbps mux whose own 27 ms cadence is already inside the limit. **Quote the range
  as 0–26 % across the four clips T7 measured, not as 13–26 %.**
- The timing/CBR half is closed downstream of *any* VBR source by `mpegts-pacer`; the service-layer
  half is closed upstream by #2440. Those left **TDT/TOT and EIT** unpreserved, and the two were
  never one gap: EIT revises rarely enough to fit #2440's catalog carriage at ~12 updates per ten
  minutes, and #2824 now carries its present/following half on exactly that argument, while TDT/TOT
  is new content in every section and belongs at the exporter's clock rather than in the catalog. So
  what an exporter must **regenerate** rather than relay is now just the clock — which matters more
  than it did, since a receiver with no TDT has no wall clock to place the surviving EPG against.
- The open-GOP round-trip requires **both** #2072 and #2066 on the same tree: with #2072 alone an
  IDR-less feed's video never resolves, so the reservation gate stays shut and the catalog never
  publishes.
- `mpegts-pacer` fixes PCR/stuffing/CBR but restores neither SI nor PMT identity (the opaque lane's
  job), and its P1 result is arithmetic, not a wire (P2) pass.
- This is loopback only (isolates the lane, not network effects — those are T4/T5), moq-lite-04 not
  draft-14, and uses live-join captures (so PCR-interval *maxima* include boundary artefacts; the
  `% > 40 ms` metric is the reliable one).

## Conclusion

The media-aware lane carries all elementary streams and PMT descriptors with 0 CC and rides out the
CNN open-GOP + triple-SCTE-35 feed deterministically. With `mpegts-pacer` (timing/CBR) and PR #2440
(service layer) it is broadcast-transparent **except** the time-varying tables and the P2 hardware
pass (T7). Those tables are no longer one gap: EIT p/f actual round-trips byte-identically on
[#2824](https://github.com/moq-dev/moq/pull/2824) — measured here, but still an open PR, so no
released build carries it — while TDT/TOT stays dropped deliberately, leaving the wall clock as the
one thing an exporter must regenerate rather than relay. The permanent finding is recorded in
[`docs/evidence.md`](../docs/evidence.md) §3.2 (PCR cadence + pacer) and §4 (open-GOP + service layer).

## References

- Media-aware lane as the preferred path: [`docs/architecture.md`](../docs/architecture.md) §4.2.
- Byte-for-byte counterpart and the decisive contrast: [test-3-opaque-transparency.md](test-3-opaque-transparency.md).
- Upstream: [#1979](https://github.com/moq-dev/moq/issues/1979), #2072, #2066,
  [#2440](https://github.com/moq-dev/moq/pull/2440).
- Findings: [`docs/evidence.md`](../docs/evidence.md) §3.2, §4.

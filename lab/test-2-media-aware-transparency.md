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
| TDT / TOT (time) | present (0x0014) | dropped | **still dropped** |
| EIT (event / EPG) | (none in these clips) | n/a | **still dropped** |

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
  and emitted non-CBR bursty egress violating TR 101 290 P1 on 13–26 % of intervals.
- The timing/CBR half is closed downstream of *any* VBR source by `mpegts-pacer`; the service-layer
  half is closed upstream by #2440. Together they leave only the **dynamic TDT/TOT and EIT** tables
  unpreserved.
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
(service layer) it is broadcast-transparent **except** the dynamic TDT/TOT/EIT tables and the P2
hardware pass (T7). The permanent finding is recorded in
[`docs/evidence.md`](../docs/evidence.md) §3 (PCR cadence + pacer) and §4 (open-GOP + service layer).

## References

- Media-aware lane as the preferred path: [`docs/architecture.md`](../docs/architecture.md) §4.2.
- Byte-for-byte counterpart and the decisive contrast: [test-3-opaque-transparency.md](test-3-opaque-transparency.md).
- Upstream: [#1979](https://github.com/moq-dev/moq/issues/1979), #2072, #2066,
  [#2440](https://github.com/moq-dev/moq/pull/2440).
- Findings: [`docs/evidence.md`](../docs/evidence.md) §3, §4.

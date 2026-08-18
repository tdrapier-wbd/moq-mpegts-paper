# T3 — Transport transparency, opaque `m2ts` lane (local)

## Objective

Demonstrate that the platform's **opaque `m2ts` lane** — the fallback lane
([architecture](../docs/architecture.md) §4.2), and the one the prototype chain implements end to
end — carries a complete
MPEG-TS end-to-end over a local MoQ relay **without altering it**: verify, component by component
against the T1 §5.6 inventory, that video, every audio track, teletext, every SCTE-35 PID and the
full PSI/SI survive at their original PIDs; that TSID/ONID/service identity and PMT/PCR PIDs are
unchanged; and that the groomed egress stays CBR and TR 101 290 P1-conformant. This is the Gate 1
fidelity question the media-aware lane (T2) cannot answer.

## Environment

- Binaries: private `moq_relay` / `moq_publisher` / `moq_subscriber` built from the repo's pinned
  `Cargo.lock` — `moq-transport` 0.14.2, `moq-native` 0.17.0, `moq-relay` 0.12.9. Default local relay
  mode. Negotiated **draft-14**. No GSO workaround needed (unlike the moq-dev relay in T2).
- Relay config `relay.toml` (QUIC + HTTP on `[::]:4443`, self-signed `localhost`, anonymous auth).
- Publisher: TCP ingest `127.0.0.1:5001`, broadcast `mpegts`, track `ts`. Each MoQ Object is a
  concatenation of whole 188-byte TS packets (default 7 → 1316 bytes), batched into ordered groups
  — **byte-preserving by construction**.
- Subscriber: reassembles Objects → MPEG-TS with a decoder-safe start gate, an adaptive CBR/PCR
  pacer, and **read-only TR 101 290 monitoring** on the egress; output UDP / RTP / TCP.
- TSDuck 3.44-4676 (Darwin 25.5.0). All localhost. Three clips: `testloop_clean`, `testloop` (4:2:2),
  `CNNiEMEA`.

**Load-bearing methodological finding — feed the lane the raw TS, not an ffmpeg remux.** The repo's
convenience ingest (`ffmpeg -re -i clip.ts -c copy -f mpegts tcp://…`) regenerates the TS container
before it reaches the publisher: it strips null padding (`testloop_clean` 10.00 → 8.31 Mbps) and
rewrites the PCR cadence to ~80 ms (**99 % of intervals > 40 ms**). That is an FFmpeg muxer artefact,
**not** the lane. Every result below uses raw, PCR-paced bytes (`tsp … -P regulate` piped straight
into the publisher's TCP ingest), which reproduces the source exactly.

## Procedure

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

## Results

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

### Built-in egress monitor (read-only TR 101 290)

- **Transient P1** (`pat_missing` / `pmt_missing` / `pid_missing`, `raised` → `recovered`) only
  during the live-join window while the first PAT/PMT/PID cycle arrives; self-clears within the first
  group. Expected.
- **P2 `pcr_jitter` on `CNNiEMEA`** (~4–5 ms on PCR PID 0x006F): carried from the source
  contribution feed — the lane surfaces it, does not create it (raw-fed egress still 0 % > 40 ms).
- **0 discontinuities** in steady state; egress bitrate tracks the source.

### T2 (media-aware) vs T3 (opaque) — the decisive contrast

Media-aware column shows as-shipped and, where PR #2440 changes it, the state after "→":

| Property | T2 media-aware (`moq-dev`) | T3 opaque (platform) |
|---|---|---|
| Wire model | demux → typed + opaque tracks (hang catalog) | whole-TS Objects (MSFTS `m2ts` catalog) |
| Draft negotiated | moq-lite-04 | **draft-14** (`moq-transport` 0.14.2) |
| Elementary streams | preserved (all audio, teletext, SCTE-35) | **preserved, verbatim, same PIDs** |
| PAT / PMT | PMT renumbered → 0x1000 → **kept (#2440)** | **PMT PID kept** |
| SDT / NIT | dropped → **preserved (#2440)** | **preserved verbatim** |
| TDT/TOT / CAT | **dropped** (TDT/TOT still dropped) | **preserved verbatim** |
| Service name / type | lost → **preserved (#2440)** | **preserved** |
| TSID / ONID | regenerated → **preserved (#2440)** | **preserved** |
| SCTE-35 splice PIDs | carried (opaque per-PID tracks) | **preserved in-mux, verbatim** |
| Mux structure | VBR; nulls stripped (CBR restored by pacer) | **CBR preserved; nulls preserved** |
| PCR intervals > 40 ms (P1), file domain | 0–26 % by clip → **0 % (paced)** | **0 %** |
| Egress monitoring | none | **built-in TR 101 290** |
| Transparency verdict | media-faithful; with #2440 + pacer, transparent **except TDT/TOT** (by design) **and EIT** (until [#2824](https://github.com/moq-dev/moq/pull/2824) merges) | **broadcast-transparent** |

## Observations

- The opaque lane is byte-transparent at P1: TSID/ONID, service name/type, all PSI/SI
  (PAT/PMT/SDT/NIT/TDT/CAT), PMT PID, PCR PID, every elementary stream and every SCTE-35 PID
  preserved verbatim; 0 CC / transport errors; CBR and PCR conformance preserved when fed raw.
- Transparency is only as good as what touches the TS on either side: an FFmpeg `-c copy` remux in
  the contribution path, or a demux/remux lane (T2), rewrites the stream regardless of MoQ. The
  opaque lane's job is to add nothing; on this evidence, at P1, it doesn't.
- Capture-tooling detail: TSDuck's UDP `ip` input dropped some subscribers' non-188-aligned egress
  datagrams (0 bytes captured while the subscriber's own counters showed full egress); the aligned
  TCP playout capture was used for `CNNiEMEA` / `testloop`. Not a lane defect.
- Loopback only, file-fed (raw `regulate`). A live SRT/RTP contribution source is T4. Draft-14 pin
  is a tracked dependency.

## Conclusion

Gate 1 media fidelity is met at P1 for the opaque lane. The load-bearing gaps that remain are **P2
hardware conformance** (T7, Gate 2) and a **real-time / remote contribution path** (T4) —
file-based localhost transparency is necessary, not sufficient. Recorded as a permanent finding in
[`docs/evidence.md`](../docs/evidence.md) (opaque prototype = the byte-for-byte reference that bounds
the media-aware lane's residual gaps).

## References

- Lane choice and the fallback rationale: [`docs/architecture.md`](../docs/architecture.md) §6;
  [`docs/architecture.md`](../docs/architecture.md) §4.2.
- Media-aware counterpart: [test-2-media-aware-transparency.md](test-2-media-aware-transparency.md).
- Finding: [`docs/evidence.md`](../docs/evidence.md) §3.1–§3.

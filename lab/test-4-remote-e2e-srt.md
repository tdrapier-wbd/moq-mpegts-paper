# T4 — Three data planes over the public internet (MoQ media-aware, segmented HTTP, SRT)

## Objective

Put the path over the **public internet** with a cloud relay on AWS EC2, and answer two questions
there.

1. **What does each data plane do to a broadcast mux over a real path?** Carry the *same* clip from
   the *same* EC2 origin to the *same* local receiver over three transports — MoQ's media-aware lane,
   segmented HTTP (TS-in-HLS) and byte-faithful SRT — and score all three with one instrument.
   [T3](test-3-opaque-transparency.md) asked this on loopback; asking it on the wire is what separates
   "the lane alters the mux" from "the path altered the mux".
2. **Can a live contribution feed traverse the whole chain?** local TS → FFmpeg SRT → EC2
   SRT-receiver → MoQ publisher (EC2) → MoQ relay (EC2) → MoQ subscriber (local) → TSDuck/ffplay —
   the bridge between "works on localhost" (T2/T3) and "works on the wire" (T7).

**The comparison is by construction, not by assembly.** A side-by-side stitched together from three
separately-designed measurements is not a comparison, so the three lanes are driven by one script
([`t4-three-lane.sh`](scripts/t4-three-lane.sh)) and differ in exactly one thing: the transport
between the two ends. Same clip, same `tsp regulate --pcr-synchronous` pacing at the origin, same
packet-count bound, same ungroomed measurement point, same analysis
([`t3-transparency.py`](scripts/t3-transparency.py)). Where a lane cannot be measured on the same
terms as the others, that is reported as a property of the lane rather than filled in with a number
taken differently.

**State: all three lanes are measured**, each over the public internet on the current build, with the
segmented lane's outcome scored against a prediction registered before it ran.

> The EC2 host IP is `<EC2_IP>` throughout (real value in `INSTRUCTIONS.local.md`).

## Pass criteria

Fixed in [T3](test-3-opaque-transparency.md) before that experiment's lanes were run, and applied here
unchanged so that the loopback and over-the-wire results are scored identically:
(1) every source PID present at egress at its original number; (2) PSI/SI tables carried, within
TR 101 290 P1 repetition limits; (3) TSID, ONID and service identity unchanged; (4) no continuity
errors and no invalid sync; (5) PCR cadence preserved; (6) **nothing added** — no packets or PIDs at
egress that the source did not have.

A lane is not required to pass. The purpose is to record *which* criteria each one fails and by how
much, because that is what the paper's carriage-fidelity verdict is scored on.

## Environment

- **Deployed cloud path = the `moq-dev` media-aware lane, not the opaque lane.** SSH inspection
  established this as a material fact: the relay is `moq-relay` on UDP 443 and both publishers use
  `moq import ts` (a loop and the SRT-fed live broadcast). The opaque lane's service lines are present
  but commented out.
- **Build under test: `moq-relay 0.14.11-eab96019` / `moq 0.9.11-eab96019`**, a source build at `main`
  `eab960192`. All three units point at it and none has restarted.
- EC2 services (already running; relay never restarted during this test):
  - `moq-relay.service` → `moq-relay --server-bind 0.0.0.0:443 --tls-generate … --auth-public`
  - `moq-publisher-cnn-loop.service` → `tsp -I file ~/CNNiEMEA2.ts --infinite -P regulate
    --pcr-synchronous -O file - | moq … import ts --broadcast cnn.international.emea.loop.hang`
  - `moq-publisher.service` → `ffmpeg -i "srt://0.0.0.0:9000?mode=listener&latency=6000…" -c copy -f
    mpegts - | moq … import ts --broadcast cnn.international.emea.live.hang`
- Local: `moq` client from `~/bin-main`; SRT-capable FFmpeg is the local `~/FFmpeg` build (not OS
  FFmpeg), and `tsp` carries the SRT plugins; TSDuck 3.44.
- TLS verification disabled (`--client-tls-disable-verify`) for the relay's self-signed cert — a lab
  convenience, not a production posture.

**The loop leg's publisher is `tsp`, not `ffmpeg`, and that changes what the leg measures.** It was
formerly `ffmpeg -re -stream_loop -1 -c copy`, whose default stream selection dropped the AC-3, teletext
and all three SCTE-35 PIDs before MoQ ever saw them. Any carriage row taken through that publisher
measured ffmpeg's remuxer as much as the lane. `tsp … -P regulate --pcr-synchronous`
replays the file's own packets, so the broadcast now presents the source mux to the importer.

### The three-lane arm

- **Rig:** [`t4-three-lane.sh`](scripts/t4-three-lane.sh), one lane per invocation. It starts its own
  origin-side sender (so the sender's file position at the join is known and the local reference can be
  cut to match), captures generously, then trims to the packet bound. The standing relay and both
  standing publishers are left exactly as found; the rig tears its own sender down **by process group**,
  never by process name, because on that box the standing units are `tsp`/`moq`/`ffmpeg` processes too.
- **Source:** `/home/ubuntu/CNNiEMEA2.ts` (745,917,260 B, 1080i25 H.264, ~9.95 Mbps PCR-derived, 13
  PIDs, 600 s). The local copy is byte-identical in length and supplies the reference cut, so no
  745 MB transfer is needed to compare against the source.
- **One instrument, one version, both ends:** TSDuck **3.44-4676** on EC2 *and* locally — the same
  build, so nothing in these tables is an instrument difference between origin and receiver.
- **MoQ binaries differ by a patch version across the lane** — `moq 0.9.11-eab96019` importing on EC2,
  `moq 0.9.10-eab960192` exporting locally — but both are built from the same `main` commit
  `eab960192`, so the difference is a version string rather than a code difference.
- **Lane transports:** MoQ media-aware over QUIC **UDP 443** *through the relay*; byte-faithful SRT
  **UDP 9010** point-to-point (T8's port; the standing SRT receiver on 9000 is untouched); segmented
  HTTP over **TCP** from a static origin with no relay.
- **Window:** 30 s of media = **198,389 packets** at the clip's PCR-derived 9,945,951 b/s. Every lane
  is trimmed to that count.
- A **fresh broadcast name per MoQ run** (`t4.3lane.<pid>.hang`): reusing a name the relay has already
  announced can leave a stale announce, after which the subscriber receives only `catalog.json` and
  stalls at zero bytes.

**Perimeter, as it stands: inbound `22`, `80`, `443` and `8080` on TCP, and all UDP.** An inbound rule
for TCP 8080 was added during this session for the segmented lane; the two UDP ports the other lanes
need (443 QUIC, 9010 SRT) fall under the blanket UDP rule. All three lanes therefore run from home.

**A closed-port probe cannot tell a filtered port from an open one with nothing listening, and reading
it as "filtered" is how this file briefly acquired a wrong environment claim.** `nc -z` against `80`,
`443`, `8080` and six other TCP ports reported every one closed, and that was recorded as the security
group admitting no TCP but SSH. It supported no such conclusion: nothing was listening on any of those
ports, so a refusal was the expected answer whether the rule existed or not. The discriminator is the
response, not its absence — **a filtered port drops the packet and the probe times out, while an
admitted port with no listener refuses immediately.** Measured here: with `python3 -m http.server` bound
on 8080, a request from home completed in **17 ms** with HTTP 200; TCP **81**, which is in no rule, took
the full **8 s** timeout. Because that distinction was not drawn at the time, this file cannot say
retroactively whether 8080 was admitted before the rule was added — only that the probe used could not
have told the difference.

## Procedure

```bash
# THREE-LANE ARM — one invocation per lane, 30 s of media each. ORIGIN/PEM per
# INSTRUCTIONS.local.md §7; the script refuses to run without them rather than
# carrying a host address in a public file.
export ORIGIN=ubuntu@<EC2_IP> PEM=<ssh-key>
bash lab/scripts/t4-three-lane.sh moq ~/t4-3lane/moq-run 30
bash lab/scripts/t4-three-lane.sh srt ~/t4-3lane/srt-run 30
bash lab/scripts/t4-three-lane.sh hls ~/t4-3lane/hls-run 30   # needs inbound TCP 8080

# What each lane runs, in one line each (the script assembles these):
#  moq  origin: tsp -I file $CLIP --infinite -P regulate --pcr-synchronous -O file -
#               | moq --client-connect https://localhost:443/anon --broadcast $B import ts
#       home:   moq --client-connect https://<EC2_IP>:443/anon --broadcast $B export ts --latency-max 3s
#  srt  origin: tsp … -O srt --listener 0.0.0.0:9010 --transtype live --latency 2000
#       home:   tsp -I srt --caller <EC2_IP>:9010 --transtype live --latency 2000
#  hls  origin: tsp … -O hls seg.ts --playlist index.m3u8 --duration 2 --live 6
#               --live-extra-segments 3 --intra-close --align-first-segment
#               + python3 -m http.server 8080
#       home:   tsp -I hls http://<EC2_IP>:8080/index.m3u8 --live

# A. remote subscribe — media-aware loop (T2 over the wire), captured for TSDuck
timeout 60 ~/bin-main/moq --client-tls-disable-verify \
  --client-connect https://<EC2_IP>:443/anon \
  --broadcast cnn.international.emea.loop.hang export ts --latency-max 3s > loop_out.ts
tsp -I file loop_out.ts -P analyze -O drop   # + continuity, pcrextract per lab/README.md

# B. full SRT contribution chain. Local ~/FFmpeg transcodes to a rate that fits the home uplink
#    (2 Mbps stable; 3.5 Mbps saturated it), pushes SRT to the EC2 receiver → EC2 media-aware
#    publisher → cnn.…live.hang. Match SRT latency to the listener (6000 ms).
~/FFmpeg/ffmpeg -re -i ~/testloop_clean.ts -map 0:v:0 -map 0:a:0 \
  -c:v h264_videotoolbox -b:v 2000k -maxrate 2000k -bufsize 2000k -profile:v high -g 50 -bf 0 -realtime 1 \
  -c:a copy -f mpegts "srt://<EC2_IP>:9000?mode=caller&latency=6000&peerlatency=6000&sndbuf=8388608"

# subscribe back locally to the live SRT-fed broadcast, capture for TSDuck
./moq --client-tls-disable-verify --client-connect https://<EC2_IP>:443/anon \
  --broadcast cnn.international.emea.live.hang export ts --latency-max 5s > t4_live_out.ts
tsp -I file t4_live_out.ts -P analyze -O drop     # + continuity, pcrextract per lab/README.md

# C. opaque remote (T3 over the wire) — NOT YET RUN. The lane is installed on EC2
#    (~/moq-publisher-subscriber, binaries + source, Cargo.lock pinning T3's exact versions) but
#    its units are commented out and the binaries are Linux, so an over-the-wire run needs a
#    macOS-side subscriber built from that source:
# moq_subscriber --output-protocol tcp --playout-bind 127.0.0.1:5002 --no-pacing \
#   --broadcast mpegts --track ts https://<EC2_IP>:443/anon
```

## Results

### The three lanes, side by side

Same clip, same origin, same path, same 198,389-packet window, same instrument. Reference cuts offset
to the media each receiver joined (MoQ 5 s, SRT 6 s, segmented HTTP 3 s into the clip); all three
references are homogeneous across the window to 0.09–0.10 points of stuffing, so the census rows measure
the lane and not the cut.

| Criterion (T3's, applied over the wire) | MoQ media-aware — QUIC 443, via relay | Segmented HTTP — TCP 8080, no relay | SRT byte-faithful — UDP 9010, point-to-point |
|---|---|---|---|
| **(1)** Every source PID at its original number | **11 of 13** | **13 of 13** | **13 of 13** |
| TDT/TOT (0x0014) | **dropped** | preserved | preserved |
| Null stuffing (0x1FFF) | **stripped** — 4.51 % → 0 | preserved — 4.50 % | preserved — 4.53 % |
| AC-3 0x007B, teletext 0x0083, SCTE-35 ×3 | all present | all present | all present |
| **(3)** TSID, ONID, service name/provider/type | all unchanged | all unchanged | all unchanged |
| PMT PID / PCR PID | 0x0064 / 0x006F — source values kept | 0x0064 / 0x006F kept | 0x0064 / 0x006F kept |
| **(4)** CC errors / invalid sync | **0 / 0** | **0 / 0** | **0 / 0** |
| **(2)** PSI cadence | **regenerated, thinner** — 8.04 → **2.51 PAT/s**, mean gap 124 → **399 ms** | **denser by the injections** — 8.04 → 8.47 PAT/s, mean gap 124 → 118 ms | identical — 8.04 PAT/s, 124.4 ms |
| **(5)** PCR grid | **not reproduced** — 1,123 of 1,307 intervals < 1 ms, max **319.94 ms**, 8.19 % > 40 ms | **reproduced** — max 24.95 ms, 0 % > 40 ms | **reproduced exactly** — max 24.95 ms, 0 % > 40 ms |
| PCR accuracy at the 481 ns P2 gate | **gate degenerate** — 1,248 "violations", and the bound it reports (319.93 ms) is just the largest PCR gap | **302.1 µs**, 1,223 violations — the injected pair, priced; 0 violations at 500 µs | **0 violations**; tightest clean bound 1 tick (37 ns) |
| Mux rate | **none** — `analyze` reads 15.66 Gb/s on ~10 Mb/s content | 9,950,239 b/s — source **+0.043 %**, the injected bytes | 9,945,951 b/s — the source value exactly |
| **(6)** Nothing added | no new PIDs; PSI *reduced* rather than added | **fails** — no new PIDs, but **+13 PAT and +13 PMT: exactly 1.00 pair per segment head** | no new PIDs, no added packets |
| Media carried in the 198,389-packet window | **31.12 s** | 29.98 s | 29.99 s |

**SRT over the public internet is byte-faithful on every criterion, and the measurement is now on the
record rather than inferred.** Thirteen PIDs of thirteen at their source numbers, both SI tables,
TDT/TOT, all three splice PIDs, stuffing, the exact source mux rate, an identical PSI cadence, a PCR
grid indistinguishable from the file's, 0 continuity errors, and 0 PCR-accuracy violations at the
481 ns P2 gate over a ~125 ms internet path. This is the first time the campaign has graded PCR
*accuracy* on a lane over the wire at all: [T3](test-3-opaque-transparency.md) could not, because the
opaque lane's egress delivers nothing and the media-aware lane has no mux rate for the gate to work
against.

**The media-aware lane's carriage result over the wire is much better than T4 first reported and its
timing result is worse.** Service identity, TSID, ONID, both source PIDs and every elementary stream
including the splice PIDs survive — the half that [#2440](https://github.com/moq-dev/moq/pull/2440)
fixed. What does not survive is everything to do with the *mux as a timed object*: stuffing, the mux
rate, PSI cadence and the PCR grid. Those are not path damage — the same 0 continuity errors say the
bytes arrived intact — they are what demuxing to tracks and reassembling without a rate does to a
broadcast mux.

#### Three of this lane's rows are not numbers, and saying so is the result

The media-aware column above contains four entries that a reader could mistake for measurements of
timing quality. They are not, and the reason is the same in each case: **the ungroomed egress carries
no stuffing, so it has no mux rate, and every instrument that needs one degenerates.**

- **`analyze`'s bitrate (15.66 Gb/s)** is header arithmetic on a stream with no rate. Any rate for
  this lane has to come from bytes over a known window.
- **`pcrverify --absolute`'s 1,248 violations** is the degeneracy [T3](test-3-opaque-transparency.md)
  characterised, now confirmed over a real path: with no mux rate the tool has no expected PCR to
  compare against, so the "worst error" it reports (319.93 ms) is simply the largest gap in the PCR
  series. It is not a 320 ms clock error.
- **The PSI repetition columns** `analyze` prints for this lane (PAT 0/0 ms, SDT 1/1 ms) are derived
  from that same absent rate and are meaningless. The 2.51 PAT/s and 399 ms figures in the table are
  computed instead from the capture's own PCR span (31.12 s of media), which is a defensible *average*
  — but it is an average only. **The maximum PAT interval on this lane cannot be measured**, so
  whether it ever breaches P1's 500 ms limit is unknown, and 399 ms mean leaves little margin.
- **Equal packets are not equal media on this lane.** The 198,389-packet window carries **31.12 s** of
  media at egress against **29.98 s** at the source, because 4.5 % of the source's packets were
  stuffing and none of the egress's are. The packet bound equalises the *window*, not the *content*,
  wherever a lane strips padding — so this lane's absolute counts carry a ~3.8 % content offset, and
  only the per-100k-packet and per-second-of-media figures are directly comparable with the others.

#### The 320 ms PCR gaps are the lane's, not the encoder's

T4 previously reported the media-aware egress at "mean/max 33.52 / 319.98 ms, 12.59 % of intervals
> 40 ms" and attributed the maximum to the source, concluding that the lane "transports the cadence
the encoder produced". **That attribution was wrong.** Profiling the source clip's own PCR spacing
across every span of it shows no such gap anywhere:

| Span of `CNNiEMEA2.ts` | n | min (ms) | mean (ms) | max (ms) | > 40 ms |
|---|---:|---:|---:|---:|---:|
| 0–30 s | 1,225 | 1.51 | 24.48 | **24.95** | **0** |
| 5–35 s (this run's window) | 1,225 | 1.51 | 24.47 | **24.95** | **0** |
| 0–60 s (the window leg A used) | 2,456 | 0.15 | 24.42 | **24.95** | **0** |
| 60–120 s | 2,455 | 0.45 | 24.44 | **24.95** | **0** |
| 120–300 s | 7,378 | 0.15 | 24.39 | **24.95** | **0** |
| 300–600 s | 12,281 | 0.15 | 24.42 | **24.95** | **0** |
| **whole clip, 0–600 s** | **24,573** | 0.15 | 24.42 | **24.95** | **0** |

The source is a flat ~24.4 ms PCR grid with a 24.95 ms maximum and **not one interval above 40 ms in
600 s**. So the 320 ms maximum and the 8–13 % of intervals over 40 ms are introduced between the
importer and the exporter.

**This was already the campaign's finding, and T4 was the file that contradicted it.**
[T2](test-2-media-aware-transparency.md) records exactly these figures in a table headed *"impairments
introduced by the lane"*, with a source column at 20–28 ms and 0 % above 40 ms against the same clip's
319.9 ms egress maximum and 13.7 %. [T8](test-8-srt-vs-moq.md) shows the same split from the other
side — native SRT-carried cadence "mean 24.5 ms, 0 % > 40 ms" beside a raw MoQ egress at 10.78 % with a
1,200 ms maximum. What this arm adds is confirmation over a real path on the current build, the source
profile that kills the 319.98 ms coincidence outright, and the shape of the distribution below.

What the lane does is not reordering, and it is not loss. The egress PCR series is **monotonic** (0
intervals going backwards) and carries *more* PCRs than the source window (1,307 against 1,225), yet
**1,123 of its 1,307 intervals are under 1 millisecond**, with the residual time collected into 107
gaps of up to 319.94 ms. PCR values are timestamps, so this is independent of the missing stuffing:
the lane emits PCR-bearing packets in near-simultaneous clusters separated by long gaps, conserving
the mean (23.81 ms against the source's 24.47 ms) while destroying the spacing. The clustering is
consistent with group-wise reassembly — the exporter writing out a group's packets back-to-back — but
that mechanism is inferred from the shape of the distribution, **not** confirmed against the code, and
is recorded below as an open question.

The practical consequence is unchanged by any of this and is already the campaign's position: raw
media-aware egress needs a groomer before it is a broadcast mux, and with one it measures IRD-grade
(T7/T13/T16, and T8's paced column at 0 % > 40 ms and 0 `pcrverify` violations at ±500 ns). What
changes is the *reason*: the groomer is not tidying up an awkward encoder, it is rebuilding a timeline
the lane discarded.

#### Segmented HTTP over the real path matches its loopback prediction to 0.1 %

The prediction was registered before the lane ran, taken from T3's loopback arm: content intact, and
criterion 6 failed by one injected PAT/PMT pair per segment head, costing ~302 µs of PCR accuracy —
scaling with segment *count* rather than segment *size*. All of it held.

| Pre-registered prediction | Measured over the internet |
|---|---|
| Content survives intact | **13 of 13 PIDs**, SDT, NIT, TDT/TOT, splice ×3, stuffing preserved, 0 CC |
| One PAT/PMT pair injected per segment | **+13 PAT, +13 PMT over equal media; 13 back-to-back pairs — 1.00 per segment head** |
| PCR accuracy degrades to ~302 µs | **302.148 µs** against 302.4 µs predicted from 376 bytes at the source rate |
| PCR *repetition* untouched | max 24.95 ms, **0 % above 40 ms** — the source grid |

Mean achieved segment duration was **2.396 s** against a 2 s target, `--intra-close` overshooting to
land on an I-frame, so "13 segments" is 13 heads across 29.98 s of media rather than 15.

**The real path changes nothing about the injection accounting, which was the open question this leg
existed to answer.** Injection is a property of the segmenter, not of the delivery: the count per
segment, the 302 µs displacement and the P1-clean repetition are all indistinguishable from loopback
across a ~125 ms path with per-segment TCP connections. What the path adds is visible only in rate —
the egress declares 9,950,239 b/s against the source's 9,945,951, **+0.043 %**, which is the injected
bytes and nothing else.

The one number worth reading carefully is the P2 row. **1,223 violations at 481 ns and 0 at 500 µs**
bounds the error rather than merely counting it: the injection displaces PCRs by a fixed ~302 µs, so it
breaches a 481 ns gate constantly and a 500 µs gate never. Unlike the media-aware lane's 1,248
"violations", this figure is a real measurement — the mux rate survives, so the gate has a byte clock to
grade against.

### Leg A — what changed on the media-aware lane, and what changed it

This leg's value now is the *delta*, not the absolute figures: the three-lane table above is the
authoritative carriage record for this lane, taken with matched windows and one instrument. Leg A is a
60 s capture of the standing loop broadcast (72.2 MB / 383,930 packets) on the current deployed build,
and **the whole non-transparency half of its original result has been reversed by
[#2440](https://github.com/moq-dev/moq/pull/2440) and by the publisher change**:

| Metric | As first measured (pre-#2440, ffmpeg publisher) | **Now** (`0.9.11-eab96019`, `tsp` publisher) |
|---|---|---|
| Relay reachable over internet | yes (~125 ms RTT) | yes |
| Elementary streams delivered | 2 — `0.avc3` + `0.mp2` | **7, all at source PIDs**, plus verbatim `N.ts` tracks |
| AC-3 / teletext / SCTE-35 ×3 | **dropped** (by ffmpeg, before MoQ) | **all present** — 0x007B typed AC-3, 0x0083, 0x008D/8E/8F |
| Transport Stream Id | 0x0001 (regenerated) | **0x0000 — source value** |
| Original Network Id | — | **0x0000 — source value** |
| Service name / provider | **lost** (unknown / Undefined) | **CNNI EMEA HD / Warner Bros. Discovery** |
| Service type | **lost** | **0x19 — preserved** |
| SDT / NIT | **dropped** | **both present** |
| TDT/TOT | dropped | **still dropped** — [#2914](https://github.com/moq-dev/moq/issues/2914), fixed by #2929 on `dev`, which this build predates |
| PMT PID | **renumbered → 0x1000** | **0x0064 — source PID kept** |
| PCR PID | 0x0100 | **0x006F — source PID kept** |
| Continuity-counter errors (P1) | **0** | **0** |
| PCR interval mean / max | 34.98 / 319.98 ms | 33.52 / 319.98 ms — **both lane-introduced**, see above |
| PCR intervals > 40 ms | 13.21 % | 12.59 % — **lane-introduced**, source has none in 600 s |

**Over the public internet, the deployed media-aware lane now carries the DVB service layer it used to
strip, with 0 continuity errors.** Only TDT/TOT is still missing, and that has a known cause and a
merged fix the deployed build predates. The two PCR rows barely moved across the change — but that
stability is not the reassurance this leg originally read into it, because the gaps those rows count
are produced by the lane and not by the encoder.

**The egress has no mux rate, so its "bitrate" is not a figure** — `analyze` reports 24.8 Gb/s here on
~10 Mb/s content. That property and its consequences for the P1 and P2 gates are set out in full in the
three-lane section above.

### Leg B — the live SRT contribution chain

Three SRT runs were taken. Run 1 (3.5 Mbps) delivered ~3.3 MB then the home uplink dropped the SRT
link (`code=24`) — the access-link constraint, not the transport. Run 3 (2 Mbps, matched SRT latency)
was stable; figures below are from run 3, and were taken on the **pre-#2440** build.

| Metric | Live SRT chain → media-aware |
|---|---|
| SRT contribution leg (local → EC2:9000) | **works** — caller connected, feed delivered end-to-end |
| Captured egress | **10.3 MB / ~48 s** |
| Continuity-counter errors (P1) | **0** |
| Service name / SI | lost (unknown/Undefined) — pre-#2440 |
| PMT PID | renumbered → 0x1000 — pre-#2440 |
| Encoded PCR interval min/mean/max | **40.00 / 40.00 / 40.00 ms** |
| PCR intervals > 40 ms | **0 %** (n=1235) |

A live SRT contribution feed traversed the whole chain with **0 CC errors**. QUIC carried the media
losslessly; the non-transparency was the *lane*, not the network, exactly as local T2 predicted.

Two limits on this leg, both of which make it weaker than the three-lane arm rather than wrong. Its
carriage rows are pre-#2440 and have not been re-measured, so read the three-lane table for what the
lane does today. And the feed was **transcoded** (`h264_videotoolbox`, 2 Mbps) to fit the home uplink,
so this leg never tested byte-faithful carriage in the first place — the campaign's later rule is to
keep ffmpeg out of an SRT carriage path entirely and use `tsp -O srt` / `tsp -I srt`
([T8](test-8-srt-vs-moq.md), [method-notes](method-notes.md)).

**That second gap is now closed, in the other direction.** The three-lane arm runs SRT byte-faithfully
with `tsp` at both ends and grades it against the source, so "what SRT does to a mux over this path" is
measured. It is measured **downstream** (EC2 → home), because the home uplink cannot carry a full-rate
mux; this leg remains the only *contribution*-direction evidence, and it is transcoded. Byte-faithful
contribution from this workstation is not measurable on this access link at all.

Full-rate confirmation is in [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md) (clean path): the same
media-aware lane pulled the full ~9.93 Mbps `CNNiEMEA2.ts` loop home over QUIC at **9.48 Mbps
sustained for 4 min, 0 CC** — the low Mbps here was the source (SRT-latency/uplink-limited), not the
transport.

## Observations

- **On PCR cadence: the media-aware lane does not transport the spacing the encoder produced.** It
  conserves the *mean* while destroying the *distribution* — clustering PCRs sub-millisecond and
  collecting the residual into gaps up to 320 ms, from a source that has no interval above 40 ms
  anywhere in 600 s. The leg's earlier reading, that 13.2 % of intervals > 40 ms "reflects the source",
  was an artefact of comparing a 60 s egress maximum against a whole-clip source maximum. Timing
  conformance remains a groomer/egress responsibility (T7) — but the groomer is *reconstructing* a
  cadence, not tidying one.
- **The three lanes separate "the mux as bytes" from "the mux as a timed object", and only the second
  is where they differ.** SRT preserves both. The media-aware lane now preserves the first completely
  (identity, PIDs, SI, splice) and none of the second (stuffing, mux rate, PSI cadence, PCR grid). That
  split is sharper over the wire than on loopback, because 0 continuity errors on the same capture rule
  out the path as the cause.
- **Injection is a property of the segmenter, not of the path.** Segmented HTTP's per-segment PAT/PMT
  pair, its ~302 µs PCR displacement and its clean P1 repetition are indistinguishable from T3's
  loopback figures across a ~125 ms internet path with per-segment TCP connections. The only thing the
  path adds is 0.043 % of declared rate, which is the injected bytes. So T3's loopback carriage result
  for this lane generalises, which is not something that could be assumed of a lane whose delivery model
  is a sequence of separate HTTP fetches.
- **The two lanes that preserve stuffing carry equal media in an equal packet count; the one that strips
  it does not.** Segmented HTTP and SRT both put 29.98–29.99 s of media in the 198,389-packet window
  against the source's 29.97 s. The media-aware lane puts **31.12 s** in the same count. A packet bound
  is therefore an equal-media bound only for a byte-faithful lane, and the choice of bound has to be
  justified per lane rather than per rig.
- **The opaque lane is not *running* on EC2, but it is installed there — and that changes leg C from
  blocked to runnable.** Its service unit lines are commented out, so nothing serves it; the
  `moq_relay` / `moq_publisher` / `moq_subscriber` binaries and the full source tree with its
  `Cargo.lock` are on the box. The lock pins **`moq-transport` 0.14.2, `moq-native` 0.17.0,
  `moq-relay` 0.12.9** — the exact versions [T3](test-3-opaque-transparency.md) recorded, so a run
  there is comparable with T3's published opaque results rather than being a different lane. That also
  matters to T3, whose P2 PCR-accuracy cell is blocked precisely because this checkout no longer exists
  on the workstation. The source **builds on macOS** from that lock, so the subscriber side of leg C exists now
  and [`t3-opaque-lane.sh`](scripts/t3-opaque-lane.sh) scripts the chain. Leg C is nonetheless still
  unrun, because the lane's **egress delivers nothing**: publisher, relay and subscriber connect and
  the subscriber reports `bytes_out` climbing at ~10 Mb/s while zero bytes reach a connected reader,
  on TCP paced and unpaced, on UDP, and under `--egress-profile broadcast`. `lsof` shows one
  established connection and the subscriber logs no write error. Whether this is a defect in the build
  or specific to compiling it on macOS is unresolved, and the cheap discriminator is to run the same
  chain against the Linux binaries already on the box.
- **Home uplink < 10 Mbps sustained**, so a full-rate mux cannot be *published* from the local end;
  the SRT leg was transcoded (`h264_videotoolbox`). 3.5 Mbps dropped after ~30 s; 2 Mbps was stable.
  Publish-side figures are bounded by the access link, and the SRT transcode is not byte-transparent
  (that is T3's claim, not T4's).
- **EC2 restored as found.** Relay service never stopped (same PID throughout); the SRT publisher
  auto-restarts on SRT EOF (normal) and was left active. No processes left running by this test.

## Conclusion

Over the public internet the data planes fail **different halves of the same question**, and the split
is not the one this file originally reported.

**SRT is byte-faithful, and that is now measured rather than assumed** — 13 PIDs of 13 at their source
numbers, both SI tables, TDT/TOT, three splice PIDs, stuffing, the exact source mux rate, an identical
PSI cadence and PCR grid, 0 continuity errors, and 0 PCR-accuracy violations at the 481 ns P2 gate,
across a ~125 ms path. With segmented HTTP's 302 µs beside it, these are the campaign's first
over-the-wire PCR-*accuracy* grades of any lane, and the two of them bracket the useful range: one lane
at the instrument's floor, one at a known and fully explained displacement.

**The MoQ media-aware lane is now faithful to the mux as a set of bytes and unfaithful to it as a timed
object.** Identity, PIDs, SI and splice signalling survive the internet path intact with 0 continuity
errors — everything the leg originally reported as stripped, less TDT/TOT, which has a merged upstream
fix this build predates. What does not survive is stuffing, the mux rate, PSI density (8.04 → 2.51
PAT/s) and the PCR grid (gaps to 320 ms from a source with none above 40 ms in 600 s). So "works on the
wire" is closed for delivery *and* for carriage, and is **not** closed for cadence — and the groomer's
role is larger than this file previously implied: it rebuilds a timeline rather than tidying one.

**Segmented HTTP is transparent to the mux's content over the real path and additive by exactly one
PAT/PMT pair per segment — the loopback result, reproduced to 0.1 % on a prediction made before the
run.** 13 PIDs of 13, TDT/TOT, stuffing, 0 CC, the source PCR grid; +13 PAT and +13 PMT over equal
media, 302.148 µs of PCR displacement against 302.4 µs predicted, and 0.043 % of added rate. **The path
does not touch the injection accounting**: per-segment TCP fetches across ~125 ms behave, on every
carriage measure, exactly as loopback did. So of the three lanes, the two byte-faithful ones differ from
each other only in whether the segmenter's two packets are there.

The contribution-chain result stands unchanged: live SRT contribution → EC2 → MoQ publish → relay →
local subscribe, 0 CC.

Opaque-remote (leg C) remains unrun, but it is a **build** step rather than a deployment one: the lane
is installed on EC2 at T3's exact pinned versions, and only a macOS-side subscriber is missing.
Recorded as a permanent finding in [`docs/evidence.md`](../docs/evidence.md) §1.

## Still open

1. **Why the media-aware lane clusters PCRs.** The distribution's shape (86 % of intervals sub-1 ms,
   monotonic, mean conserved) points at group-wise reassembly, but this is inferred from the output and
   not confirmed against the exporter's code. Worth confirming before it is reported upstream, because
   if PSI density and PCR spacing are both group-derived then a group-size change moves both.
2. **The maximum PAT interval on the media-aware lane**, which no instrument can currently give: with
   no mux rate, `analyze`'s repetition figures are meaningless and only an average over the PCR span is
   available (399 ms against P1's 500 ms limit). Whether individual gaps breach P1 is unknown.
3. **Byte-faithful SRT in the contribution direction** is not measurable on this access link.
4. **Leg C**, blocked on the opaque lane's egress delivering zero bytes; the cheap discriminator is the
   Linux binaries already on the box.
5. **Delivery cadence per lane over this path** is deliberately out of scope here — this arm scores
   carriage and integrity. T8 holds the delivered-rate comparison and T18 the latency work.

## Corrections

**This file's results table asserted a stripped service layer long after the deployment stopped
stripping it.** Every SI/PMT/TSID row was measured on a build predating #2440 and, for the loop leg,
through an `ffmpeg -c copy` publisher that dropped AC-3, teletext and the splice PIDs before MoQ saw
them — so those rows were partly measuring ffmpeg's stream selection and were labelled as the lane's
behaviour. Both have since changed and the rows now carry both states explicitly. *Lesson: a result
taken against a standing deployment has two provenances, the build and the feed, and either can move
without the experiment being re-run. A leg whose publisher is not part of the rig needs its publisher
recorded as an input — the same class of error as feeding a lane an ffmpeg remux and attributing the
remuxer's output to the transport ([T3](test-3-opaque-transparency.md)).*

**This file credited the lane's 320 ms PCR gaps to the encoder, and concluded the opposite of what the
data supports.** It reported the egress at "mean/max 33.52 / 319.98 ms" and called the maximum
"identical to the source's own 319.98 ms", concluding that the lane "transports the cadence the encoder
produced". The source's maximum PCR interval is **24.95 ms**, in every span of the clip and over all
600 s of it; the 320 ms gaps are introduced between importer and exporter. The error was comparing a
60 s egress extremum against a whole-clip source extremum and reading the coincidence as identity — and
it survived because a 320 ms figure existed on both sides of the comparison, so the numbers looked like
they matched.

The aggravating detail is that **the campaign already knew better**:
[T2](test-2-media-aware-transparency.md) lists this figure under "impairments introduced by the lane"
with the source at 20–28 ms and 0 % above 40 ms. So this was not a gap in the evidence but a
contradiction between two lab files, and the wrong one of the two was the one being cited.

*Lesson: two extrema are only comparable when taken over the same window, and a matching pair of extrema
is the easiest kind of agreement to fake accidentally. When a lane appears to preserve a property,
verify it against the source **in the same window**, and prefer a distribution to a maximum — here the
giveaway was not the 320 ms tail but the 0.01 ms minimum, which no conformant mux can produce. And
before recording that a lane preserves something, check whether another experiment already found that
it does not: a contradiction between two files is worth more than a re-measurement, because one of them
is already wrong.*

**This file briefly recorded the origin's security group as admitting no inbound TCP but SSH, on a probe
that could not have shown it.** `nc -z` reported nine TCP ports closed and that was written up as
"filtered", making segmented HTTP look blocked on a firewall change. Nothing was listening on any of
those ports, so refusal was the expected answer whether or not a rule existed — the probe measured the
absence of a server, not the presence of a filter. With a listener bound on 8080 the same path completed
in 17 ms; TCP 81, in no rule, took the full 8 s timeout. *Lesson: a negative reachability result is only
evidence about the network if the far end would have answered a positive one. Test a port with something
listening on it, or read the failure mode rather than the failure — a drop times out, a refusal returns
immediately — and never infer a policy from a silence you have not characterised. The same shape as the
campaign's rule about computing the effect an arm should see before trusting its null.*

## References

- Deployed cloud path and end-to-end result: [`docs/evidence.md`](../docs/evidence.md) §1.
- Three-lane rig: [`scripts/t4-three-lane.sh`](scripts/t4-three-lane.sh); shared instrument:
  [`scripts/t3-transparency.py`](scripts/t3-transparency.py).
- Same criteria on loopback, and the P2-gate degeneracy: [test-3-opaque-transparency.md](test-3-opaque-transparency.md).
- Full-rate confirmation and the SRT-vs-MoQ delivery comparison: [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md).
- Media-aware fingerprint origin, and the lane's PCR impairment as first measured locally:
  [test-2-media-aware-transparency.md](test-2-media-aware-transparency.md).
- What a groomer puts back: [test-13-downstream-grooming.md](test-13-downstream-grooming.md),
  [test-16-grooming-segmented-http.md](test-16-grooming-segmented-http.md).

# T8 — SRT vs MoQ comparative benchmark

## Objective

Characterise MoQ against the incumbent it would replace — **SRT**, the de-facto IP contribution
transport — carrying the *same* MPEG-TS from the *same* EC2 origin to the *same* local receiver, over
the *same* controlled impairment, measured head-to-head. Report delivered quality under impairment
(throughput, continuity, TR 101 290 P1), loss recovery, transparency, CPU, and — still owed —
glass-to-glass latency. This is a *comparison*, not a pass/fail gate: MoQ need not beat SRT on every
axis, only be within a defensible margin while offering the architectural properties (relay fan-out,
single-transport CDN) SRT lacks.

> The EC2 host IP is `<EC2_IP>`; the subscriber home IP is `<subscriber-home-ip>`; the third-party
> relay IP is `<EDIS_IP>` (real values in `INSTRUCTIONS.local.md`).

## Environment

- **EC2 origin (`<EC2_IP>`):** the `moq-dev` media-aware relay + publisher already deployed (see T4),
  plus a purpose-built T8 source on a **separate** broadcast (`t8.bench.hang`) and a **separate** SRT
  listener port (`:9010`) so the standing services are untouched. SRT-capable FFmpeg is the box's
  `~/FFmpeg` build. TSDuck 3.44 and FFmpeg 8.0.1 (SRT-enabled) on the box.
- **Local receiver:** `moq-dev` `moq` client + [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer)
  0.1.0 (`moq_egress` example) for the MoQ path; `~/FFmpeg` (SRT-enabled) for the SRT path; TSDuck
  3.44-4676.
- **Matched buffers.** Latency is only comparable at equal end-to-end buffering. Clean-path/impairment
  runs used **B = 2 s** (MoQ `--latency-max 2s`, SRT `--latency 2000`); a buffer ladder
  B ∈ {250 ms, 500 ms, 1 s, 2 s} is defined for the (still-owed) latency runs.
- **Clock discipline:** for absolute glass-to-glass latency, both ends NTP-synced (`chrony`); the
  relative MoQ − SRT delta does not need NTP (same burnt-in timecode, same local clock).
- Runs 2026-07-22 (clean path + start of matrix) and 2026-07-23 (four-way CC comparison; third-party
  long-haul). The EC2 build predates PR #2440, so the MoQ egress strips DVB SI throughout.

**Two deliberate asymmetries** (recorded, not hidden): the MoQ path traverses a relay hop (the point
of the architecture) whereas SRT is point-to-point; and the deployed EC2 publisher is the media-aware
lane, so the MoQ egress is not byte-transparent the way SRT-carried TS is. `mpegts-pacer` grooms the
MoQ egress back to CBR so the *timing* comparison is fair; the *transparency* comparison needs the
opaque lane on EC2 (opaque-remote follow-up).

## Procedure

```bash
# 1. EC2 — one encoder, timecode burnt in, tee'd byte-identical to both transports (latency runs)
CLIP=~/CNNiEMEA2.ts
~/FFmpeg/ffmpeg -stream_loop -1 -re -i "$CLIP" -map 0:v:0 -map 0:a:0 \
  -vf "drawtext=…:timecode='00\:00\:00\:00':rate=25:…, drawtext=…:text='%{localtime}':…" \
  -c:v libx264 -preset veryfast -tune zerolatency -b:v 8M -maxrate 8M -bufsize 1M -g 25 -bf 0 \
  -c:a copy -f tee "[f=mpegts]srt://0.0.0.0:9010?mode=listener&latency=1000|[f=mpegts]pipe:1" \
  | ~/moq-dev/target/release/moq --client-connect http://localhost:4443 \
      --broadcast t8.bench.hang import ts

# 2. Local — MoQ receive → groom → measure (analysis: 30 s window)
timeout 30 sh -c './moq --client-tls-disable-verify --client-connect https://<EC2_IP>:443/anon \
  --broadcast t8.bench.hang export ts --latency-max 1s \
  | cargo run --release -p mpegts-pacer --example moq_egress -- - 10000000 > t8_moq_paced.ts'
tsp -I file t8_moq_paced.ts -P analyze -O drop      # + continuity, pcrextract per lab/README.md

# 3. Local — SRT receive → measure (same clock, same window, matched buffer)
timeout 30 ~/FFmpeg/ffmpeg -i "srt://<EC2_IP>:9010?mode=caller&latency=1000" -c copy -f mpegts t8_srt_out.ts
tsp -I file t8_srt_out.ts -P analyze -O drop        # + continuity, pcrextract

# 5. Impairment sweep — steer BOTH UDP egress flows (QUIC sport 443, SRT sport 9010 → sub IP) into
#    the same SSH-safe netem band, run concurrently (bandwidth-cap condition is run one at a time):
IFACE=ens5; SUBIP=<subscriber-home-ip>
sudo tc qdisc add dev $IFACE root handle 1: prio bands 4 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
sudo tc qdisc add dev $IFACE parent 1:4 handle 40: netem delay 0ms
for SPORT in 443 9010; do
  sudo tc filter add dev $IFACE parent 1:0 protocol ip prio 1 u32 \
    match ip protocol 17 0xff match ip sport $SPORT 0xffff match ip dst $SUBIP/32 flowid 1:4
done
sudo tc qdisc change dev $IFACE parent 1:4 handle 40: netem loss 1%   # etc.
```

**Pacing caveats (learned in the clean-path run).** For delivered-quality runs that carry the
original TS `-c copy`, do **not** pace with `ffmpeg -re` — its reader stalls on sparse data PIDs
(SCTE-35/teletext), collapsing a 10 Mbps source to ~1/3 real-time and backpressuring the chain. Pace
the looped file with `tsp -I file <clip> --infinite -P regulate --pcr-synchronous -O file -`. Keep
FFmpeg out of the SRT *carriage* path (use `tsp -O srt` / `srt-live-transmit`) — an `ffmpeg -c copy
-f mpegts` hop re-muxes (synthetic "Service01"/"FFmpeg" SDT, ~80 ms PCR interval) and is not
byte-transparent. Impairment is forward (download) path only.

## Results

### Clean path (condition 0), real EC2 → home internet, `CNNiEMEA2.ts` loop

| Result (clean path) | MoQ over QUIC + pacer | SRT (byte-faithful) |
|---|---|---|
| Sustained delivery | **9.48 Mbps over 240 s** (1.51 M pkts) | **9.96 Mbps over 40 s** |
| CC errors | **0** | **0** |
| Egress PCR > 40 ms | raw 10.78 % (max 1200 ms) → **paced 0.06 %** (8 gaps, max 139 ms) | **0 %** (native, mean 24.5 ms) |
| PCR accuracy (paced) | **0 `pcrverify` viol. @ ±500 ns**; exact CBR 10.892 Mbps | n/a (native cadence) |
| Service / SI | **stripped** → "(unknown)", **PMT PID → 0x1000** | **preserved** — "CNNI EMEA HD" / WBD / type 0x19, **PMT PID 0x0064** |
| Origin CPU (2-vCPU EC2) | `moq import` **~34 %** of a core; relay **2.6 %**; load ~1.45 | `tsp regulate`+carriage **~1 %**, no relay |
| Reference: raw TCP same path | **292 Mbps** (SSH bulk) — link is not the limit | — |

Findings: (1) the QUIC download is not the bottleneck — full ~9.5 Mbps, 0 CC, 4 min; raw TCP runs at
292 Mbps. (2) `ffmpeg -re` mis-paces sparse-PID MPEG-TS (see caveats); `tsp regulate
--pcr-synchronous` restores full rate. (3) transparency is the real MoQ−SRT difference on this path,
not delivery. (4) a remux in the SRT path is not transparent. (5) media-aware `moq import` is
single-thread CPU-bound at ~1/3 of a core (≈32 Mbps ceiling per core on this instance).

### Impairment matrix (matched B = 2 s, one run per condition, indicative)

Delivered rate as % of each config's own clean baseline (CUBIC 9.67, BBRv1 9.59, quiche-BBR2 9.28,
noq-BBR3 9.63, SRT 9.96 Mbps); every capture had 0 CC errors. All four MoQ congestion controllers
side by side:

| Condition (`netem`) | CUBIC (quinn) | BBRv1 (quinn) | BBR2 (quiche) | BBR3 (noq) | SRT |
|---|---|---|---|---|---|
| Baseline | 100 % | 100 % | 100 % | 100 % | 100 % |
| loss 0.5 % | 97 % | 100 % | 99 % | ~74 %‡ | 100 % |
| loss 1 % | 95 % | 100 % | 98 % | 93 % | 100 % |
| **loss 2 %** | **53 %** | **100 %** | 95 % | **100 %** | 100 % |
| **loss 5 %** | **31 %** | **100 %** | 93 % | **100 %** | 100 % |
| **loss 10 %** | **13 %** | **100 %** | **47–70 %** | **97 %** | 100 % |
| bursty loss 3 % (25 % corr) | 99 % | 99 % | 100 % | 100 % | 100 % |
| **reorder 20 ms 25 %** | **20 %** | **99 %** | **25–31 %** | **100 %** | 100 % |
| jitter 60 ± 30 ms — **non-ordered** (reorders) | **2 %** | **7–13 %** | **2 %** | **8–71 %**§ | 100 % |
| jitter 60 ± 30 ms — **in-order** (`slot`, FIFO) | — | 97 % | 100 % | 100 % | 95 %¶ |
| duplicate 1 % | 99 % | ~100 % | 98 % | 100 % | 100 % |
| **combined WAN 120 ms + 1 % loss** | **14 %** | **97 %** | 96 % | 93 % | 100 % |

Ranges are the spread across two runs. ‡ BBR3's loss-0.5 % was low on both runs (72 %, 78 %) yet 1/2/5 %
were ≥ 93 % (non-monotonic) → most likely a join-window artefact. § non-ordered jitter under BBR3 was
unstable (one run 71 %, next 8 %). ¶ netem `slot` mildly rate-caps, so both transports sit ~5 % below
line rate — the point is they are comparable and near-full.

**Table 2 — MoQ buffer sensitivity @ 2 % uniform loss (CUBIC):** 2 s → 5.85 Mbps, 6 s → 5.19, 10 s →
5.20. Buffer-independent ceiling ≈ 5 Mbps → the collapse is **congestion-control-driven, not a
buffering knob**.

**Table 3 — transient loss burst (20 % × 3 s at t≈12 s within a 40 s window):** MoQ 9.08 Mbps (91 %),
~2–3 s stall to 0 then catch-up overshoot (11–16 Mbps) back to full; SRT 9.96 Mbps (100 %), no visible
dip — ARQ absorbs the burst inside the 2 s window.

**Table 4 — bandwidth constraint (`netem rate`, per-transport, no added loss):** 12 Mbit → MoQ 9.52
(98 %) / SRT 9.89 (99 %); 10 Mbit → 9.49 (98 %) / 9.85 (99 %); 9 Mbit (< line rate) → 7.58 (78 %) /
6.68 (67 %). Below ~9.9 Mbps line rate both degrade gracefully and comparably.

### Congestion control — the loss collapse is a CUBIC default, not a MoQ limit

The matrix findings above were measured with quinn's default CUBIC. The CC knob
([#2432](https://github.com/moq-dev/moq/pull/2432)) exposes `--server/client-quic-congestion-control
{loss|delay}`: `loss` = CUBIC, `delay` = BBR (generation fixed by backend — BBRv1 on quinn, BBRv2 on
quiche, BBRv3 on noq). With the **relay** switched to `delay` (it is the sender on the impaired
download hop):

- The **uniform-loss collapse disappears**: 2 % 53 % → 100 %, 5 % 31 % → 100 %, 10 % 13 % → 100 %.
- **Reordering is fixed:** 25 % reorder 20 % → 99 %. Combined WAN 14 % → 97 %. Bursty loss stays 99 %.
- **The one apparent residual — "jitter" — is really *reordering*, and true in-order jitter is a
  non-issue.** Non-ordered netem jitter still collapses under BBR (60 ± 30 ms → 7–13 %; correlation
  doesn't help — a 30 ms swing dwarfs the ~1.2 ms packet spacing so packets still overtake), but
  `netem slot 30–90 ms` (in-order jitter) delivers 97 %, matching SRT. So the collapse is QUIC's
  **in-order-stream head-of-line blocking under reordering**, not delay variation.

Congestion control is **sender-local and per-connection — not on the wire, not negotiated, invisible
to peers/relays** — so the switch is non-breaking, needs no protocol/version change, and preserves
interop. Because MoQ is hop-by-hop QUIC, `delay` can be enabled on just the lossy relay→subscriber
hop, with the short relay-edge RTT as the retransmit loop.

### All BBR generations vs the backends (CUBIC / BBRv1 / BBR2 / BBR3 side by side)

Compared using two extra single-backend `moq-relay` binaries (`--no-default-features --features noq`
= BBR3; `--features quiche` = BBR2) swapped in for the standing quinn relay
([#1706](https://github.com/moq-dev/moq/pull/1706) made BBR3 the noq default; `rs/moq-native/src/quic.rs`).
Cross-backend interop holds cleanly (quinn clients ↔ noq/quiche relay, all `moq-lite-05`); every
backend delivers full clean-path rate (noq 9.63, quiche 9.28, quinn 9.6 Mbps).

- **Every BBR generation kills the CUBIC uniform-loss collapse at 2–5 %** (all ≥ 93 %) —
  backend-independent.
- **At the stress edges the *implementation* matters more than the version number.** quinn-BBRv1 and
  noq-BBR3 are strongest (~100 % through 10 % loss and 25 % bounded reordering); **quiche-BBR2 is
  weakest** (fades at 10 % loss to 47–70 %, and handles bounded reordering about as badly as CUBIC,
  25–31 %).
- **The reordering residual is CC-version-independent** (CUBIC 2 %, BBRv1 7–13 %, BBR2 2 %, BBR3
  unstable), while in-order jitter is ~100 % for every controller — a QUIC HOL/loss-detection item,
  **not fixed by picking a CC**.
- **Maturity vs generation trade-off.** quinn (mature, BBRv1) is the best all-rounder and the
  default/production backend; noq-BBR3's instability here is explained by a BBRv3 panic
  ([noq #768](https://github.com/n0-computer/noq/issues/768)) — a subtract-overflow in
  `inflight_at_loss` that aborts the process under high loss and has driven noq/iroh back to CUBIC by
  default. For a broadcast deployment today, **quinn + `delay` (BBRv1)** is the pragmatic choice;
  upstream has since made **BBRv1 the default on quinn** ([#2468](https://github.com/moq-dev/moq/pull/2468)).

### Congestion-control defaults & methodology (bounding how these numbers read)

- **The default CC is now backend-specific** (#2468): quinn CUBIC → **BBRv1**; quiche CUBIC → **BBRv2
  (gcongestion)**; noq/iroh BBRv3 → **CUBIC** (because BBRv3 panics, #768). Pin
  `--*-quic-congestion-control` explicitly on every run, or the backend default confounds an A/B.
- **Upstream methodology guidance (#2432), adopted:** (1) the one meaningful CC test is **bufferbloat
  under a shaped bottleneck** (10 Mb/s source, rate-limited to 5 Mb/s, 100 ms base RTT, 500 ms queue
  — CUBIC p50 RTT ~558 ms vs BBRv1 ~90 ms; the evidence behind the #2468 quinn-BBRv1 default). (2)
  reordering *"doesn't happen on the internet, otherwise TCP and QUIC would break"* → a `netem`
  artefact, retained for the record but not a roadmap driver. (3) random loss "removes signal" —
  *"the best congestion control in the face of random loss is zero congestion control"* — so the
  CUBIC-collapse/BBR-robust result is **loss-signal interpretation**, not a CC-quality metric.

### Third-party BBR relay — dual long-haul (2026-07-23)

Neither leg is local: EC2 publisher (eu-west-1, EMEA, RTT ≈ 174 ms) → relay `mgw.edis.mx`
(`<EDIS_IP>`, Mexico, BBR) → home subscriber (London, RTT ≈ 190 ms). Relay `https://mgw.edis.mx/test`,
valid Let's Encrypt cert (no `--client-tls-disable-verify`), reported running BBR server-side and
appearing load-balanced (successive connects negotiated `moq-lite-05` *or* `moq-lite-04` — full interop
across versions/nodes). Media-aware lane; both clients default CC (only the relay is BBR, governing
the download hop). Single continuous **300 s** window (kept under the ~600 s source-loop-wrap that
crashes `moq import`).

| Metric | Value |
|---|---|
| Capture duration / size | 300 s → **354.97 MB** |
| Sustained goodput (0–300 s) | **9.47 Mbps** (15–300 s: 9.52 Mbps) |
| Per-15 s window spread | 9.41 – 9.66 Mbps (essentially flat) |
| Source rate (reference) | ~9.93 Mbps → **~96 % delivered, no throttle/collapse** |
| Continuity (CC) errors | **0** end-to-end |
| Reconnects / group skips / stalls | **0** (log = connect + 8 `subscribe started`, nothing else for 5 min) |
| Elementary streams reconstituted | **8/8** (AVC 0x006F PCR, MP2 0x0079, AC-3 0x007B, teletext 0x0083, 3× SCTE-35 0x008D/8E/8F) |

Structural (pre-#2440 EC2 build): PMT → 0x1000, service "(unknown)", SDT/NIT stripped — a known
property of the binary, not the path. Timing raw egress: PCR mean 27.5 ms, max 320 ms, 10.4 % > 40 ms.
After the CBR pacer: exact CBR **10.955 Mbps** (12.8 % stuffing), PCR mean 18.94 / max 31.85 ms,
**0 % > 40 ms, 0 `pcrverify` viol. @ ±500 ns, 0 CC, 0 dropped** — IRD-grade.

## Observations

- SRT is unconditionally robust across every loss/reorder/jitter/WAN condition tested (its 2 s ARQ
  window recovers everything the forward path drops).
- Under default CUBIC, MoQ over QUIC collapses under uniform loss ≥ 2 %, reordering, and WAN — but
  this is a **default-configuration artefact of loss-based CUBIC**, removed by BBR (`delay`): MoQ is
  full-rate/0-CC through 10 % loss, 25 % reordering and the WAN profile, on par with SRT.
- Integrity manifests differently: the MoQ exporter always emits a syntactically clean TS (CC = 0 even
  when it delivers 13 % of the program) — degradation is *missing content*, measured by
  delivered-rate-vs-source, not CC. SRT's degradation (only below line rate) shows as `RCV-DROPPED`.
- **Scope caveat:** the loss/reorder/jitter/dup matrix ran on an **over-provisioned path** (~292 Mbps
  raw TCP, ~30× the stream), so it measures resilience to *non-congestive* impairment, **not**
  congestion control. A "100 %" cell means "the source fit in the spare capacity," not "the
  controller behaved well." The only genuinely CC-dependent result is CUBIC misreading random loss —
  loss-signal interpretation, not a CC-quality verdict. Table 4 caps the pipe but only with a bare
  `netem rate` token bucket, CUBIC vs SRT only. The congestion-control test proper (shaped bottleneck,
  all controllers, scored on completeness) has a [first-pass failure-mode result in
  T8b](test-8b-congestion-control.md) but its provisioned-path conditions are not yet run.

## Conclusion

Delivered-quality and resilience are measured; the CUBIC→BBR delta is the headline: a one-flag,
non-breaking change moves QUIC from "loss-fragile" to "SRT-comparable" on degraded paths, while
keeping MoQ's architectural wins. Residual gaps: pathological *reordering* (a QUIC loss-detection/HOL
item, not CC) and media-aware SI transparency (opaque lane / #2440 closes it). Glass-to-glass latency
and protocol overhead remain **TBM** (lowering latency was explicitly not the objective here — robust
delivery under degradation was). Recorded as a permanent finding in
[`docs/evidence.md`](../docs/evidence.md) §6. This is a comparison, not a gate: the thesis is decided
by T7 (Gate 2), and the [T8b](test-8b-congestion-control.md) congestion-control run gates any
controller recommendation for a permanent fixed-rate trunk.

## References

- Impairment method reused from: [test-5-network-impairment.md](test-5-network-impairment.md).
- Congestion control for a permanent fixed-rate trunk (first-pass C1 run): [test-8b-congestion-control.md](test-8b-congestion-control.md).
- Upstream: [#2432](https://github.com/moq-dev/moq/pull/2432), [#2468](https://github.com/moq-dev/moq/pull/2468), [#1706](https://github.com/moq-dev/moq/pull/1706), [noq #768](https://github.com/n0-computer/noq/issues/768).
- Findings: [`docs/evidence.md`](../docs/evidence.md) §6; feeds [`docs/economics.md`](../docs/economics.md) §8.

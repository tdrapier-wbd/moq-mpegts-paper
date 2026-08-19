# T14 — MoQ against segmented HTTP on one route

## Objective

[Comparison](../docs/comparison.md) grades two candidate data planes for primary distribution —
MoQ, and segmented HTTP carrying MPEG-TS — across nine axes. Every MoQ row in that comparison is
measured in this campaign; every segmented-HTTP row was specification text or a vendor datasheet. Half
of the verdict table was therefore argument rather than evidence, and the argument was load-bearing:
the paper's framing as a *two-data-plane* evaluation rests on it.

This closes the gap on the axes reachable without new hardware, and it tests one prediction the
comparison made and could not support:

> A 1–2 s segment fetched over HTTP arrives as a burst of a megabyte or two, where a MoQ object is
> roughly frame-sized. Segmented HTTP's egress may therefore be *harder* to groom, not easier.

That prediction matters because the whole hand-off axis turned on it. The obligation to hand a client
a clean, paced transport stream sits on the distributor's side of the demarcation on **both** data
planes — a distributor does not supply its clients' receivers ([comparison](../docs/comparison.md)
§4.1) — so the question is not who owns the grooming stage but how much work it has to do.

### Pass criteria (fixed before the runs)

Stated as what would move the paper's conclusion, since a comparison has no pass/fail:

1. **Burst granularity.** If the segmented-HTTP egress is measurably burstier than the MoQ egress at
   the same measurement point, the hand-off axis stops favouring segmented HTTP.
2. **Carriage fidelity.** If segmented HTTP loses PSI/SI tables or splice PIDs that the media-aware
   MoQ lane preserves, the carriage-fidelity row in §12 stands. If it loses less, the row moves.
3. **Payload cost.** [economics](../docs/economics.md) §4.7 estimates segmented HTTP at ~1.05× source
   TS bytes against MoQ's measured 0.982×. The prediction under test is *near parity with MoQ if the
   packager strips stuffing*.

---

## Environment

| Component | Detail |
|---|---|
| Source | `CNNiEMEA2.ts` — CNN EMEA HD, 9,945,951 bps CBR, open-GOP, 3× SCTE-35, full DVB SI |
| Host | single macOS host, loopback path, both legs in the same session |
| MoQ | `moq` / `moq-relay` 0.9.10 @ `eab960192` (stock `main`), relay `--server-quic-gso=false` |
| Segmented HTTP, arm B1 | TSDuck 3.44-4676 `hls` output and input plugins |
| Segmented HTTP, arm B2 | Apple HLS Tools 1.26.143 (`mediastreamsegmenter --format=transport -w 300`, `mediastreamvalidator`); clients `tsp -I hls` and FFmpeg 9.0.1 |
| Origin | `python3 -m http.server` for measurement 2; nginx 1.31.3 for measurement 5, whose access log is the instrument |
| Segment duration | 2 s for measurements 2 and 4; 1 s / 2 s / 6 s for measurement 5. Always `--intra-close`, `--align-first-segment`, `--live 6 --live-extra-segments 3` |
| Instrument | [`t13-cadence.py pipe`](scripts/t13-cadence.py), 64 kB reads, identical on both legs; nginx `$bytes_sent` / `$body_bytes_sent` / `$request_length` for measurement 5 |
| Rigs | [`t14-a.sh`](scripts/t14-a.sh) (leg A), [`t14-b1.sh`](scripts/t14-b1.sh) (arm B1), [`t14-b2.sh`](scripts/t14-b2.sh) (arm B2), [`t14-wirecost.sh`](scripts/t14-wirecost.sh) + [`t14-wirecost.py`](scripts/t14-wirecost.py) (measurement 5) |
| Capture | 60 s from the live edge, one run per leg per segment duration |

**Leg B splits in two, and the reason is a finding in itself.** No *single* toolchain does Low-Latency
HLS with MPEG-TS partial segments end to end. The specification permits TS parts and the low-latency
ecosystem standardised on CMAF/fMP4 regardless: TSDuck implements no `EXT-X-PART` and no blocking
playlist reload, FFmpeg emits no partial-segment tags and its demuxer exposes no option to fetch them,
and Shaka Packager's low-latency path is CMAF, which discards the TS carriage that is the point of the
leg. What remains is Apple's own HLS Tools (closed-source, macOS-only, free) or `biim`, a small Python
implementation. Measurement 2b shows the gap is **not evenly distributed across the pipeline**: the
publish stage is solved and free, and the receive stage has nothing.

- **Arm B1 — classic HLS with TS, entirely off the shelf.** Symmetric TSDuck, so PSI, PID and cadence
  observations are directly comparable with T1/T2/T7/T13.
- **Arm B2 — Low-Latency HLS with TS parts.** Now run, with Apple's HLS Tools 1.26.143 as the
  publisher. The arm divides further than expected: the *publish* half exists and works, the *receive*
  half has no free implementation at all (measurement 2b).

Both arms feed the *same* groomer and egress as leg A, because a shared groomer is what makes this a
comparison rather than two demonstrations.

### What this environment cannot show

- **Loopback inflates burst *rate*.** A segment is fetched as fast as the machine allows. Burst
  *size* is set by segment size and the silence between bursts by the publish cadence, so those two
  are structural — but the peak-rate figures below are an upper bound, not a WAN prediction.
- **Read-size resolution.** The instrument resolves bursts at or above 64 kB, equally on both legs.
- **Loopback cannot price a packet, so measurement 5 does not try.** `lo0`'s MTU is 16384 and
  `tcpdump` needs unavailable privileges, so per-packet framing is taken from T9's real-path
  measurement and labelled derived. The HTTP-layer ratio that *is* measured here is byte-to-byte and
  so carries to any path.
- One clip, one run per leg, single host, no packet loss.

---

## Procedure

```bash
# Leg A — MoQ: tsp regulate -> import ts -> relay -> export ts -> instrument
lab/scripts/t14-a.sh ~/CNNiEMEA2.ts ~/t14/a 60

# Arm B1 — classic HLS: tsp -O hls -> HTTP origin -> tsp -I hls -> instrument
lab/scripts/t14-b1.sh ~/CNNiEMEA2.ts ~/t14/b1 60 2

# Cadence report and PID census
python3 lab/scripts/t13-cadence.py report ~/t14/a/a-egress.csv ~/t14/b1/b1-egress.csv
tsp -I file <capture>.ts -P analyze --normalized -O drop

# Measurement 5 — carriage cost through nginx, one run per segment duration
for s in 1 2 6; do
	PORT=$((18090 + s)) lab/scripts/t14-wirecost.sh ~/CNNiEMEA2.ts ~/t14wire-$s 60 $s
done

# Arm B2 — LL-HLS with TS parts, against both a static and a conformant origin
for o in nginx apple; do
	for c in tsp ffmpeg; do
		ORIGIN=$o lab/scripts/t14-b2.sh ~/CNNiEMEA2.ts ~/t14b2-$o-$c 45 $c 300
	done
done
# Control: does Apple's own client-side tool fetch the parts?
mediastreamvalidator -t 25 http://127.0.0.1:<port>/lowLatencyHLS.m3u8
```

The measurement point on both legs is the **ungroomed** egress — what the reassembly stage hands the
groomer — so no pacer is in either chain.

---

## Results

### Measurement 2 — burst granularity: the prediction holds, by two orders of magnitude

| | Leg A (MoQ) | Arm B1 (segmented HTTP) |
|---|---|---|
| Mean delivered rate | 9.550 Mb/s | 10.454 Mb/s |
| Bursts in the window | 3,078 | **28** |
| Median burst size | **12.4 kB** | **2.95 MB** |
| p95 / max burst | 90.6 kB / 286 kB | 3.49 MB / 3.59 MB |
| Gaps > 500 ms | **0** | 24 |
| Gaps > 1 s | **0** | **24** |
| Largest gap | 148.8 ms | **4,012 ms** |
| 10 ms peak/mean | 23.95× | **231.07×** |
| 10 ms CoV | 2.672 | **12.514** |

**Segmented HTTP's egress is ~240× coarser by median burst size, and it stops entirely for seconds
at a time where MoQ never stops for more than 149 ms.** The 1 s rate series shows the mechanism
plainly: MoQ delivers between 8.1 and 11.0 Mb/s in every single second of the window, while arm B1
alternates between zero and 20–30 Mb/s.

The gap sequence identifies the cause beyond doubt. Silences arrive at 1999.6, 2006.3, 2007.0,
2008.1, 2008.3 ms — the segment duration, repeated — with occasional 4,011 ms gaps of exactly two
segment periods where the client misses a publish cycle. The client fetches a completed segment at
line rate, then waits for the next one to exist. Median burst size of 2.95 MB against a 2.43 MB
segment confirms it frequently collects two at once.

### Measurement 2b — arm B2: the parts are real, and nothing free will fetch them

Apple's HLS Tools are installed, so the arm the comparison has been deferring is now runnable. The
result is not the one the open question anticipated.

**The publish side works, first time.** `mediastreamsegmenter -w 300 -t 2 --format=transport` emits a
playlist carrying `EXT-X-PART` entries pointing at MPEG-TS parts of 0.28–0.30 s and 240–430 kB, with
`EXT-X-PART-INF`, `INDEPENDENT=YES` on parts that carry an IDR, and an `EXT-X-PRELOAD-HINT` for the
part still being written. This is exactly what the specification describes and what nothing else
implements — it is free, and it took one command.

**The receive side has no free implementation.** Both freely available clients that can turn HLS back
into a transport stream fetched **zero** parts, over an origin that was advertising them. The run was
repeated against two origins — a static nginx serving the segmenter's output, and Apple's own
`ll-hls-origin-example.go`, which synthesises a fully conformant low-latency playlist
(`CAN-BLOCK-RELOAD=YES`, `PART-HOLD-BACK=0.900`) and blocks requests until the requested part exists.
**The choice of origin changed nothing:**

| Against the conformant Apple origin | `tsp -I hls` | FFmpeg |
|---|---|---|
| Partial segments fetched | **0** | **0** |
| Blocking playlist reloads (`_HLS_msn`) | **0** | **0** |
| Full segments fetched | 25 | 26 |
| Median burst | 2.23 MB | 2.13 MB |
| 10 ms peak/mean | 222.94× | 427.73× |

Neither client issued a *single* blocking reload, so neither even attempted the low-latency handshake
the origin was advertising in the standard way. The figures below are from the nginx origin; the Apple
origin reproduces them.

| 45 s window, 300 ms parts, 2 s segments | Leg A (MoQ) | Arm B1 (classic) | **B2 + `tsp -I hls`** | **B2 + `ffmpeg`** |
|---|---|---|---|---|
| Partial segments fetched | — | — | **0** | **0** |
| Full segments fetched | — | — | 25 | 26 |
| Bursts in the window | 3,078 | 28 | 25 | 23 |
| Median burst | **12.4 kB** | 2.95 MB | **2.27 MB** | **2.34 MB** |
| Largest gap | **148.8 ms** | 4,012 ms | 2,008 ms | 2,087 ms |
| 10 ms peak/mean | **23.95×** | 231.07× | 217.05× | **427.82×** |
| 10 ms CoV | **2.672** | 12.514 | 12.502 | **14.492** |

Burst sizes are grouped on the same 1 ms separation threshold as the leg A and arm B1 figures above,
so the columns are directly comparable.

**Arm B2 is arm B1 with extra files on disk.** Median burst falls from 2.95 MB to ~2.3 MB, and that
~20 % is explained entirely by segment duration — Apple's segmenter produces clean 2.00 s segments
where TSDuck's `--intra-close` overshoots to 2.38 s — not by parts. Against MoQ the gap closes from
~240× to ~185×, which is noise on a two-order-of-magnitude difference. ffmpeg is *worse* than classic
TSDuck on both dispersion measures.

**The control that makes this a finding about clients rather than about the rig.** Apple's own
`mediastreamvalidator`, pointed at the same origins, fetched **21 parts against 5 full segments** on
nginx and **17 parts against 7, using 12 blocking reloads,** on the conformant origin — which also
validates with **zero MUST-fix issues**. So the parts are real, correctly named, individually
fetchable, conformant, and actively advertised, and a client that wants them can have them. `tsp` and
`ffmpeg` fetching none is a property of those clients:

- **TSDuck does not parse `EXT-X-PART` at all.** Proven independently rather than inferred: pointed at
  the live edge before the first segment closed — when the playlist legitimately contains only parts
  and a preload hint — it exits with `Error: hls: empty HLS media playlist`. It is not choosing
  segments over parts; it cannot see parts.
- **FFmpeg's HLS demuxer exposes no partial-segment options** (`ffmpeg -h demuxer=hls` lists
  `live_start_index`, `m3u8_hold_counters`, `http_seekable` and no `EXT-X-PART` handling), and fetched
  only complete segments.

**Both results are now proof rather than inference.** An earlier run used only the static origin, whose
playlist omits `PART-HOLD-BACK` — a MUST-level defect — which left open the objection that FFmpeg
declined the parts because the origin never properly advertised them. Repeating against Apple's
conformant origin removes it: the directives were present, the validator exercised them, and FFmpeg
still issued zero blocking reloads and fetched zero parts. Neither client implements low-latency HLS,
and no property of the origin will change that.

### Measurement 4 — carriage fidelity: arm B1 is verbatim, and loses less than MoQ

PID census against the source, 60 s windows:

| PID | Content | Source | Arm B1 | Leg A (MoQ) |
|---|---|---|---|---|
| 0x0000 | PAT | 4,813 | 518 | 150 |
| 0x0010 | NIT | 119 | 12 | 7 |
| 0x0011 | SDT/BAT | 574 | 59 | 31 |
| 0x0014 | TDT/TOT | 40 | 4 | **absent** |
| 0x0064 | PMT (own PID preserved) | 4,814 | 518 | 150 |
| 0x006F | AVC video | 3,598,744 | 368,645 | 361,386 |
| 0x0079 | MPEG-1 audio | 80,553 | 8,250 | 9,828 |
| 0x007B | AC-3 audio (typing preserved) | 79,163 | 8,108 | 7,752 |
| 0x0083 | Teletext | 14,999 | 1,536 | 1,476 |
| 0x008D / 0x008E / 0x008F | SCTE-35 splice info, all three | 603 / 597 / 601 | 60 / 61 / 60 | 59 / 59 / 60 |
| 0x1FFF | Stuffing | 182,025 | 18,575 | **absent** |

**Arm B1 carries the mux verbatim.** Every PID, every PSI/SI table including the DVB service layer,
all three SCTE-35 PIDs with correct typing, the PMT on its own PID, AC-3 correctly labelled, and the
null stuffing. This is unsurprising once stated: an MPEG-TS segment *is* MPEG-TS, sliced at packet
boundaries with a PAT and PMT prepended, so nothing in the multiplex is interpreted and nothing is
lost.

**How verbatim, exactly.** A published segment was aligned against the source and compared packet by
packet. Segments are 188-byte aligned (`seg-000023.ts` = 15,984 packets exactly), and in a 1,200-packet
window **two packets differ, both PSI, each in byte 3 alone** — the byte carrying the continuity
counter:

```
  pkt + 226   PID 0x0000 (PAT)   differing byte offsets [3]
  pkt + 992   PID 0x0064 (PMT)   differing byte offsets [3]
```

So the only modification is a continuity re-stamp on PAT and PMT, which is *forced*: the segmenter
injects an extra PAT/PMT pair at each segment head, so the counters after it must be renumbered to stay
continuous. Every media, audio, teletext, splice and stuffing packet is byte-identical to source.
`tsp -P continuity` reports **zero errors** on arm B1, on leg A and on the source.

> **Extended by [T3](test-3-opaque-transparency.md).** "Verbatim" holds for everything the lane
> *forwards* and this measurement cannot see what it *adds*, because a census lists what the source
> carried and looks for it at egress. Scored against T3's transparency inventory on three clips, the
> lane preserves more than this census records — service identity, TSID/ONID, non-default PMT PIDs,
> and `testloop`'s CAT — and adds exactly one PAT/PMT pair per segment and nothing else. That
> addition is not free: it displaces every later PCR in its segment relative to a constant-rate byte
> clock, taking file-domain PCR accuracy from 37–74 ns to 109–302 µs, or 2,453 violations at the
> TR 101 290 P2 gate against the source's zero. P1 repetition is untouched. So the arm is transparent
> to the mux's *content* and not to its *clock*, and the clock half is closed by the groomer of
> [T16](test-16-grooming-segmented-http.md) rather than by the carriage.

**This is materially better than the MoQ media-aware lane, and equal to the opaque lane on mux
content for a single programme** — obtained without an opaque lane, and preserving the DVB service
layer the HLS specification never mentions. It is *not* equal to the opaque lane on the clock:
[T3](test-3-opaque-transparency.md) scores both against one inventory and finds the segment-head
injection costs file-domain PCR accuracy that the opaque lane's byte-preserving carriage does not.

Both absences on the MoQ leg are known and by design, and this run reproduces them rather than
discovering them. **Stuffing** is not carried, which is exactly where the media-aware lane's 0.982× wire
figure comes from. **TDT/TOT** is not relayed either, so the edge must mint wall time
([evidence](../docs/evidence.md) §3.1, [architecture](../docs/architecture.md) §4.2). Arm B1 carries both
without being asked to.

### Measurement 5 — wire cost: HTTP's own overhead is negligible, and MoQ's ~7 % lead is the price of not being verbatim

**HTTP is not what costs anything.** Measured at the HTTP layer across a 6.5× range of segment
duration, everything segmented HTTP adds to the transport stream it carries — response headers,
playlist re-fetching and the request bytes going back — stays under a tenth of one percent:

| | 1 s target | 2 s target | 6 s target |
|---|---:|---:|---:|
| Mean segment achieved | 1.261 s | 2.379 s | 6.568 s |
| Segments / playlists served | 49 / 81 | 26 / 58 | 10 / 31 |
| Response headers | +0.0170 % | +0.0092 % | +0.0033 % |
| Playlist re-fetching | +0.0687 % | +0.0488 % | +0.0237 % |
| Request bytes (return path) | 0.014 % | 0.009 % | 0.004 % |
| **HTTP layer vs source TS** | **1.0009×** | **1.0006×** | **1.0003×** |

Every term scales as 1/segment-duration, as it must when a fixed per-request cost is amortised over a
segment, and **playlist re-fetching is the larger of the two forward terms at every duration** — four
to seven times the response headers. Extrapolating the same 1/duration scaling to the 200–330 ms parts
arm B2 would use puts the HTTP tax at roughly 0.4–0.6 %, before allowing for LL-HLS returning a whole
playlist per blocking reload. **The chattiness of low-latency HLS is therefore not a bandwidth
argument against it**, which is worth knowing because it is often assumed to be one.

**The wire figure, with framing added from T9.** The HTTP-layer ratio above is a ratio of bytes to
bytes, so it is path-independent and loopback does not bias it. Per-packet framing is the part
loopback cannot give (below), so it comes from T9's real-path measurement:

| Data plane | Measured input | Framing | Wire vs source TS |
|---|---|---:|---:|
| **MoQ, media-aware, 1200 B** | measured end to end on a real path (T9) | — | **0.982×** |
| MoQ, media-aware, 1452 B | measured end to end on a real path (T9) | — | 0.973× |
| **Segmented HTTP over HTTP/3, 1200 B** | 1.0006× HTTP layer | ×1.0550 | **1.056×** derived |
| Segmented HTTP over HTTP/3, 1452 B | 1.0006× HTTP layer | ×1.0450 | 1.046× derived |
| Segmented HTTP over HTTP/2 on TCP+TLS, 1500 B | 1.0006× HTTP layer | ×1.0287 | 1.029× derived |
| SRT, byte-verbatim | measured on the same real path (T9) | — | 1.037× |

Three results follow.

**MoQ carries this service in ~7.0 % less bandwidth than segmented HTTP, and the figure is
MTU-invariant.** 0.982 against 1.056 at 1200 B and 0.973 against 1.046 at 1452 B are both a 7.0 %
saving, because both data planes ride QUIC and pay identical framing. Nothing about the comparison
turns on the datagram size chosen.

**The 7 % is the price of byte-verbatim carriage, not a property of HTTP.** Measurement 4 established
that arm B1 delivers the mux byte-for-byte; measurement 5 prices that. The mux this clip carries is
**4.57 % null stuffing** (`tsanalyze` on the delivered stream: 454,941 b/s of 9,945,951), and MoQ's
media-aware lane carries none of it, nor the 4-byte header on each surviving TS packet, nor TDT/TOT.
Read down the table and the pattern is not MoQ-against-HTTP at all: **every verbatim data plane lands
between 1.03× and 1.06×, and the only thing that gets below 1.0× is declining to be verbatim.** SRT,
at 1.037×, is a cheaper verbatim carriage than segmented HTTP over HTTP/3 — the two differ only in
framing. So measurements 4 and 5 are one finding read twice: arm B1's fidelity advantage and its
bandwidth disadvantage are the same fact.

The corollary is that MoQ's ~7 % is contingent on the source. On an unstuffed mux the stuffing term
vanishes and the gap narrows to roughly 2.5 points of TS packet headers and uncarried SI. Any cost
model quoting 7 % must quote the stuffing level with it.

**Putting segmented HTTP on HTTP/3 costs ~2.6 points of bandwidth against HTTP/2 on TCP** (1.056×
against 1.029×), because QUIC's minimum 1200 B datagram charges 5.5 % framing where a 1500 B TCP path
charges 2.7 %. The move to HTTP/3 buys loss resilience and no head-of-line blocking, and it is not
free on the wire. Raising the datagram to 1452 B recovers a point of it.

#### Why framing is derived rather than measured, and what was actually blocking it

The blocker recorded here previously was "a caching HTTP/3 origin, currently not installed". nginx
1.31.3 with `--with-http_v3_module` and Caddy 2.11.4 are now both installed, and **that was not the
constraint.** Two others are, and neither is fixed by installing a server:

- **No HLS client here speaks HTTP/3.** macOS's system libcurl is built without it, so TSDuck's `hls`
  input cannot negotiate H3 however the origin is configured. The origin was therefore run as
  HTTP/1.1, which is the *upper* bound on header cost — H3 would compress those headers with QPACK —
  so the 1.0006× is conservative against segmented HTTP by under 0.02 points.
- **Loopback cannot price a packet.** `lo0`'s MTU is 16384, so datagram and segment counts here bear
  no relation to a real path, and `tcpdump` needs privileges this environment does not have. A real
  H3 client would not have fixed this.

The honest division of labour is the one taken: measure exactly the part that was genuinely unknown
and is path-independent (HTTP's own overhead), and take the part that is a per-packet property of the
substrate from the leg that measured it on a real path. Closing it properly means running arm B1 on
the EC2 path under [`t9-overhead-wan.sh`](scripts/t9-overhead-wan.sh)'s accounting; on the evidence
above that would confirm a multiplier rather than move the result.

### Against the pass criteria

| Criterion | Result |
|---|---|
| 1. Burst granularity | **Met, decisively, and it survived the escape route.** ~240× coarser bursts on arm B1, 24 multi-second silences against none; and ~185× on arm B2, because no free client fetches the parts that would have closed the gap. The hand-off axis no longer favours segmented HTTP. |
| 2. Carriage fidelity | **Moved, against MoQ.** Arm B1 is verbatim for a single programme and loses less than the media-aware lane. |
| 3. Payload cost | **Met, and the estimate was right for the wrong reason.** [economics](../docs/economics.md) §4.7 guessed ~1.05× and the wire figure is 1.056× at 1200 B — but its premise was that the packager strips stuffing, and TSDuck keeps it. The estimate's *number* survives; its *mechanism* does not. MoQ's ~7 % lead is the price of not being verbatim, and it is contingent on this clip's 4.57 % stuffing. |

---

## Observations

**The burst granularity and the latency floor are the same knob, and partial segments do not turn
it.** Both of segmented HTTP's problems — coarse bursts and a seconds-scale latency floor — have one
cause, segment size, so shrinking segments to reduce the grooming burden is the same action as
shrinking them to reduce latency, and it terminates in partial segments. Measurement 2b tested the
escape and found it closed: the parts are published correctly and free of charge, and **no freely
available client will fetch them**, so the egress a groomer sees is arm B1's. This is a sharper
statement than the one this file previously carried. It is not that the low-latency tooling is
immature or awkward; it is that **the free toolchain is asymmetric — publish exists, receive does
not** — and the missing half is precisely the half a distributor needs to hand a client a transport
stream.

**Where the asymmetry sits is exactly where the commercial products sell.** Synamedia's MEG with
"ABR2TS conversion" and Ateme's TITAN Edge are receive-side boxes. Measurement 2b explains the market:
the publish half of low-latency TS-in-HLS is a free command, and the receive half is a product. That
also sets the terms for anyone wanting a free path — they get classic HLS, seconds of latency, and
megabyte bursts, on either arm.

**A groomer for arm B1 needs seconds of buffer, not milliseconds.** With 24 silences over 2 s in a
60 s window, a groomer holding the output byte clock across a silence must hold at least one segment
period, plus margin for the observed two-period stalls. `mpegts-pacer`'s `--stall-ms` /
`--on-stall mute` machinery was built for a MoQ egress whose worst gap is 149 ms; it is the right
mechanism, but the timeouts documented for leg A are an order of magnitude too tight for a
segment-fetching leg. That is a configuration finding, not a defect.

> **Narrowed by [T16](test-16-grooming-segmented-http.md).** The mechanism claim holds and the
> parameter claim does not. Run with only the timeout raised — this paragraph's literal proposal —
> the groomer stops muting and instead overflows its buffer and pads the shortfall with nulls,
> producing 231 continuity errors behind a flawless PCR record. The operative parameter is the
> cushion, 200 ms to 8 s, with the timeout following from it; and its value is a property of the
> egress rather than of the tool, which is why T16's passing arm derives it from arrival instead.

**The carriage result inverts a claim this paper leaned on.** MoQ's clearest carriage advantage was
verbatim fidelity via the opaque lane. For a *single programme* an MPEG-TS segment achieves the same
thing on the alternative, with no special lane, and it keeps the DVB service layer the HLS
specification never mentions. What survives of the advantage is confined to the multi-programme case,
where HLS's normative "Transport Stream Segments MUST contain a single MPEG-2 Program" bites — still
unrun, and now carrying the whole of that row.

**Interop status remains inverted from interop outcome.** Worth recording alongside the numbers: HLS
has no normative reference implementation — it is an Apple-authored informational document — yet it
interoperates everywhere, and its authoritative implementation is closed-source and macOS-only. MoQ is
standards-track with open implementations and no cross-implementation media interop
([evidence](../docs/evidence.md) §3.7). Open source and interoperability are not the same axis.

---

## Conclusion

**The hand-off axis moves off segmented HTTP.** On the evidence here the alternative's reassembly
stage is off the shelf, which was the real asymmetry, but what it hands the groomer is two orders of
magnitude further from a paced wire than what MoQ hands it, with multi-second silences MoQ does not
produce. Since the grooming obligation sits on the distributor's side of the demarcation on both data
planes, "easier to receive" and "easier to hand off cleanly" turn out to be different claims, and only
the first is true of segmented HTTP.

**The carriage-fidelity axis moves toward segmented HTTP** for a single programme, verbatim and
including the DVB service layer, which removes MoQ's advantage everywhere except a contribution mux.

**The cost axis stays with MoQ, at ~7 %, and the fidelity and cost results are one finding.** Arm B1
is 7.0 % more expensive on the wire *because* it is verbatim: it carries this clip's 4.57 % stuffing
and every TS packet header, and the media-aware lane carries neither. Every verbatim data plane
measured or derived on this campaign — SRT at 1.037×, segmented HTTP at 1.056× — sits above 1.0×
source, and only stripping the mux goes below it. An operator cannot have both halves, and which half
to want is a business question rather than a protocol one: the ~7 % is bandwidth, the fidelity is
whether the far end can re-emit the contribution mux.

**Glass-to-glass latency remains unmeasured, and measurement 2b changed why.** The *structural* floor
is now settled — segment duration sets it, parts would lower it, and nothing free fetches parts — so
what is missing is only the end-to-end number at equal conformance. The reason is no longer that the
low-latency toolchain is missing — half of it is present, free, and works on the first command. It is
that the half which turns parts back into a transport stream does not exist outside commercial
hardware. That is a sharper and more useful statement about maturity than "no toolchain does this",
and it locates the gap precisely: **on the receive side, which is the distributor's side of the
demarcation** (§4.1). An operator who wants sub-2-second TS-in-HLS must buy a receiver; an operator
who will not buy one gets classic HLS, whatever the publisher emits.

### Still open

Protocols for these are in [planned-experiments.md](planned-experiments.md).

| Cell | Needs |
|---|---|
| Commercial ABR-to-TS gateway on P1/P2 — moves the paper most, and measurement 2b raised its value | MEG- or TITAN-class hardware on the Gate 2 rig. It is now the *only* candidate receiver that could realise the low-latency arm at all |
| Glass-to-glass at equal conformance | a client that fetches parts. Measurement 2b shows no free one exists, so this cell is blocked on the same hardware as the row above rather than on Apple's tools |
| Wire cost with framing measured rather than derived | arm B1 on the EC2 path under [`t9-overhead-wan.sh`](scripts/t9-overhead-wan.sh)'s accounting. Low value: it would confirm a multiplier, not move a result |
| Multi-programme carriage through a real CDN | a CDN account and the MPTS fixture |

---

## Corrections

> The general method rules extracted from this section, together with those from every other
> experiment, are collected in [method-notes.md](method-notes.md). What stays here is the
> specific record of what this experiment got wrong.

**"No maintained toolchain does Low-Latency HLS with MPEG-TS" was too coarse, and the coarseness hid
the interesting half.** The claim was assembled from documentation — TSDuck implements no
`EXT-X-PART`, FFmpeg emits no partial-segment tags, Shaka's low-latency path is CMAF — and it was
true as far as it went. Run rather than read, the situation splits: **publishing** LL-HLS with TS
parts is a single free command with Apple's tools and works first time, while **receiving** it back
into a transport stream has no free implementation at all. Stating it as one undifferentiated gap
made it look like an ecosystem that had not got round to TS, when it is really a market: the missing
half is the half that is sold as hardware. *Lesson: "no tool does X" is usually "no tool does one
particular stage of X", and which stage decides who pays. Split a capability claim by pipeline stage
before publishing it.*

**A blocked cell was attributed to the wrong blocker.** Wire cost was recorded as needing "a caching
HTTP/3 origin, currently not installed". Both nginx and Caddy were then installed and the cell was
still blocked, for two reasons neither of which a server install addresses: no HLS client available
here negotiates HTTP/3, and loopback's 16384 B MTU makes any packet count meaningless regardless of
client. *Lesson: when recording what a measurement needs, name the constraint that actually binds.
"Tool X is not installed" is a guess about the blocker unless the measurement has been attempted far
enough to hit it, and a guess sends the next session shopping instead of measuring.*

**A rate ratio was computed across two different windows, and the sign came out wrong.** The first
version of [`t14-wirecost.py`](scripts/t14-wirecost.py) divided HTTP bytes by the access log's span and
delivered bytes by the receiver's span. The spans differed by 11 %, because `tsp -I hls --live` drains
the live window faster than real time before settling, which put the delivered rate 4.7 % *above* a CBR
source and made segmented HTTP's overhead come out **negative**. The fix was to remove wall clocks from
the ratio entirely: a segment response's `$body_bytes_sent` is verbatim TS by measurement 4, so the
ratio of everything sent to the segment bodies sent is the overhead over exactly the media carried,
whenever it was fetched. *Lesson: this is T9's loopback artefact recurring in a new rig — the same
error, in a different measurement, five experiments later. Comparing two byte totals is only valid
when they cover the same interval, and the durable fix is not to measure the interval more carefully
but to construct the ratio so that no interval appears in it.*

---

## References

- [comparison](../docs/comparison.md) §4 — the hand-off axis and the demarcation argument
- [T1](test-1-baseline-ts.md) — source mux baseline; [T13](test-13-downstream-grooming.md) — the
  grooming candidates, whose failures are tool properties and so apply to both legs
- [T7](test-7-timing-integrity.md) — the P1 oracle both legs would be graded against once groomed
- [T9](test-9-performance.md) — the per-packet framing costs measurement 5 builds on, measured on a
  real path, and the loopback span artefact its Corrections section first recorded
- Rigs: [`t14-a.sh`](scripts/t14-a.sh), [`t14-b1.sh`](scripts/t14-b1.sh),
  [`t14-wirecost.sh`](scripts/t14-wirecost.sh), [`t14-wirecost.py`](scripts/t14-wirecost.py),
  [`t13-cadence.py`](scripts/t13-cadence.py)

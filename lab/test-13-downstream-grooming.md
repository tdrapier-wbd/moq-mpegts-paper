# T13 — Off-the-shelf CBR/PCR grooming of an MPEG-TS egress

## Objective

> **The grooming requirement is a property of the lane, not of MPEG-TS.** This experiment began on the
> MoQ lane and concluded that no off-the-shelf stage does the whole job. That conclusion holds, and it
> is narrower than it first read: it is caused by two properties of `moq ... export ts` — it drops
> stuffing, and it clusters its PCRs instead of spacing them — and neither is true of a segmented HTTP
> egress. Graded on the segmented lane, the same TSDuck chain that is only *partial* on the MoQ lane
> passes all four criteria with the mux intact. Read every result below against the lane it was
> measured on; the two are tabulated side by side throughout.

**Can the grooming stage be built from tools an operator already has?** Every measurement in this
campaign has groomed with one tool ([`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer)),
which makes the stage look like a dependency on a single implementation. The candidates are the ones
an engineer would reach for first — TSDuck's `regulate` and `pcradjust`, FFmpeg's `-muxrate`, and
GStreamer's `mpegtsmux bitrate=` — graded against the same oracle as
[T2](test-2-media-aware-transparency.md) and [T7](test-7-timing-integrity.md), with the pacer present
only as a control.

Those three each try to do the whole job. A fourth,
[`rawsendmpeg2ts`](https://github.com/EDIS-mx/rawsendmpeg2ts), does only half of it deliberately — it
paces datagrams and rewrites nothing — and was added later, because the first pass concluded that
the half it does was the one nothing off the shelf did well. It is graded in its own group below,
against controls re-measured on its host.

The answer decides how the grooming requirement can honestly be written in someone else's
documentation, which is where this started: the upstream review of
[moq-dev/moq#2830](https://github.com/moq-dev/moq/pull/2830) rightly objected to a recipe that
invoked a tool with no supported installation path.

It also turns out to depend on what the data plane hands the groomer, which is why both lanes are
measured rather than one:

- **MoQ.** `moq ... export ts` emits content only. MPEG-TS null packets are not carried, so the stream
  has no stuffing and declares no mux rate, and it arrives in MoQ's object bursts. A groomer has to put
  the stuffing, the rate and the cadence back.
- **Segmented HTTP.** The packager slices the transport stream it was given, nulls included, so what
  `tsp -I hls` hands downstream still carries the source's stuffing and still declares the source's mux
  rate. Only the cadence is missing — and it is missing more coarsely, because whole segments arrive at
  once.

That difference is measured rather than assumed, in the census that opens the results, and it is what
splits the scoring.

### Pass criteria (fixed before the runs)

A grooming stage is a candidate for a documented recipe if it does all four:

1. **Preserves the mux.** Every PID, stream type and PSI table the egress delivered arrives
   unchanged. A broadcast mux is a contract: SCTE-35 on a known PID with stream type 0x86, not
   "something equivalent".
2. **PCR accurate.** 0 violations at the TR 101 290 P2 limit, measured as
   `pcrverify --absolute --jitter-max 13` (13 PCR units ≈ 481 ns). The plain `--jitter-max 500` that
   reads as 500 *micro*-seconds is a pre-check, not the gate.
3. **PCR spaced within the repetition limit.** No intervals above 40 ms. *(Reworded from "PCR present
   often enough" — the gate itself is unchanged and was always the interval, but the original phrasing
   implied a shortage of PCRs, and [T18](test-18-delivery-latency.md) measurement 6 showed the MoQ
   exporter's failure is where it places them rather than how many it sends.)*
4. **Honest about time.** Duration fidelity 1.000 against the source: the stream must carry the rate
   it claims. And on the wire, a delivered rate that is actually rate-controlled.

## Environment

- One laptop (macOS, Apple silicon), everything on loopback. `moq` 0.9.10 / `moq-relay` 0.14.10
  release binaries, `mpegts-pacer` 0.1.0, TSDuck 3.44-4676, FFmpeg 9.0.1, GStreamer 1.28.6. Those
  releases predate the TS importer's continuity work ([#2823](https://github.com/moq-dev/moq/pull/2823),
  [#2891](https://github.com/moq-dev/moq/pull/2891)), which changes nothing here: every chain graded
  below sits *downstream* of `export ts`, and the publisher feeds an unlooped source.
- Oracle: `compliance.py` from the upstream `test/ts` tree (HARD structural checks plus the broadcast
  shape checks — PCR repetition and jitter, null ratio, burstiness, instantaneous bitrate, T-STD
  buffer model), with `tsp -P pcrverify` at both gates and `tsp -P analyze` for the PID census.
- **File-domain input:** a real `export ts` capture of the broadcast mux clip (1080i25 H.264, MPEG-1
  audio, AC-3, teletext and three SCTE-35 PIDs), sliced to 300,000 packets — 47.4 s of PCR span,
  0 null packets, content rate 9,507,216 b/s against the source's 9,945,951 b/s mux rate. A second
  case, the simple feed, uses the video-only 2.000 Mbps CBR clip with its 11,522 nulls stripped,
  146,325 packets, content rate 1,853,986 b/s. That second input is **synthetic** and is retained only
  for the muxer arithmetic it exercises: as the correction below sets out, a stripped clip keeps the
  source's byte schedule, which is why the pacer alone posts continuity errors on it (100, against 0 on
  a real capture). No claim about a groomer's *carriage* is made from it.
- **Wire-domain rig:** one relay, and per variant a fresh publisher (`tsp regulate --pcr-synchronous`
  into `moq import ts`) and one subscriber chain, each groomer writing to its own loopback port where
  every datagram is timestamped as it is read off the socket. Legs run one at a time so that CPU
  contention is not recorded as jitter. The rate the pass-through chain is told to pace at is measured
  first, from an ungroomed 12 s capture of the same egress: 9,711,337 b/s against the 9,945,951 b/s
  nominal. That it differs from the file-domain capture's 9,507,216 b/s is expected — with the source's
  stuffing removed, what is left is variable, so the content rate is a property of the window measured,
  which is why each domain measures its own.
- **Segmented-lane rig (same laptop).** `tsp -O hls` packages the same broadcast clip to 2 s segments
  (`--intra-close --align-first-segment`, 6-segment live window) behind a loopback `python3 -m
  http.server`, and `tsp -I hls --live` is the client. The file-domain input is a 60 s capture of that
  client's output: 406,407 packets, 4.57 % stuffing, declared rate 9,957,489 b/s. The wire legs run
  25 s each against a standing origin, one at a time, with each groomer writing to its own loopback
  port. The pacer runs at two cushions here rather than one, because on this lane the cushion is the
  variable that matters: 8 s, the depth [T12](test-12-dual-path-handoff.md) and
  [T16](test-16-grooming-segmented-http.md) need, and 1 s, which is *below the segment period* and is
  included to show what that costs.
- **Egress-pacer rig (a second host).** The legs that test a datagram sender on its own run on the
  EC2 box (Ubuntu, 2 vCPU, kernel 7.0) rather than the laptop, because
  [`rawsendmpeg2ts`](https://github.com/EDIS-mx/rawsendmpeg2ts) does not build on macOS:
  `clock_nanosleep` with `TIMER_ABSTIME` does not exist there, and that call *is* its pacing
  mechanism, so a shimmed build would measure the shim. Every control in that group — TSDuck,
  FFmpeg, the pacer — is therefore re-measured on the same box at the same rate rather than compared
  against the laptop figures above. Source is the same clip; the MoQ legs subscribe to the box's
  standing relay and loop publisher, `moq` 0.9.11-eab96019.
- Rigs: [`t13-groom-matrix.sh`](scripts/t13-groom-matrix.sh) builds the file-domain variants for
  either lane, [`t13-segmented-egress.sh`](scripts/t13-segmented-egress.sh) captures and censuses the
  segmented egress that feeds it, [`t13-cadence.sh`](scripts/t13-cadence.sh) and
  [`t13-cadence-segmented.sh`](scripts/t13-cadence-segmented.sh) run the live legs on each lane,
  [`t13-rawsend.sh`](scripts/t13-rawsend.sh) runs the egress-pacer legs, and
  [`t13-grade.py`](scripts/t13-grade.py) and [`t13-cadence.py`](scripts/t13-cadence.py) grade them.

## Procedure

Nine chains in the file domain, each fed the identical ungroomed capture — run once per lane, so the
same table can be read for both:

| Chain | What it tests |
|---|---|
| `tsp -P regulate --bitrate <content>` | pacing alone, the most commonly suggested answer |
| `tsp -P pcradjust --bitrate <content>` | re-stamping PCR against the stream's own content rate, no stuffing |
| `tsp -P mux <nulls> -P pcradjust --bitrate <nominal>` | padding up to the source's mux rate, then re-stamping to it |
| `ffmpeg -muxrate <nominal>` | FFmpeg's constant-rate muxer, defaults |
| `ffmpeg -muxrate <nominal>` + `-streamid` + `-mpegts_pmt_start_pid` | the same with every PID pinned back to its original value |
| GStreamer `tsdemux ! mpegtsmux bitrate=<nominal>`, PIDs pinned | GStreamer's constant-rate muxer, both ends pinned |
| GStreamer again, `tsdemux send-scte35-events=true` and `mpegtsmux scte-35-pid=<first splice PID>` | whether GStreamer can carry splice information at all |
| `mpegts-pacer` at the nominal rate | control |
| `mpegts-pacer` at its own chosen rate | control |

Then the four that were worth running live on the MoQ lane — the pinned FFmpeg, GStreamer, the TSDuck
pass-through (`pcradjust` then `regulate` then `-O ip`), and the pacer — measured on the socket for
delivered rate, gap distribution, and the PCR conformance of the stream *as received*.

On the segmented lane the live legs are the two that the file domain leaves undecided, plus one
diagnostic: the TSDuck pass-through, the pacer at an 8 s cushion, and the pacer at 1 s. The two
regenerating muxers are not re-run live there — the file domain already disqualifies them on
carriage, and nothing about the arrival shape can repair a PID that was renumbered.

Then a third group, on the second host, isolating the egress stage. The pairs are the point: the same
FFmpeg output sent by FFmpeg's own socket and by `rawsendmpeg2ts`, so the only difference is which
stage decides when to send; and the same MoQ egress groomed by FFmpeg-plus-sender and by the pacer at
an identical 11 Mb/s, so the two architectures are compared at one rate. Two further legs establish
what the tools do at their best and what the instrument's floor is: the sender replaying the source
clip with no groomer in the chain at all, and TSDuck's own sender on that clip, at its default
`regulate` and at `--wait-min 5`.

## Results

### What each lane hands a groomer

Both egresses carry the same clip. This is the census that decides how much work is left to do, and
the last two rows are the two that turn out to matter:

| | source clip | MoQ `export ts` | segmented `tsp -I hls` |
|---|---|---|---|
| packets in the capture | 3,967,645 | 300,000 | 406,407 |
| **stuffing (PID 0x1FFF)** | 4.59 % | **0 %** | **4.57 %** |
| **declares a mux rate** | 9,945,951 b/s | **none** | **9,957,489 b/s** |
| PCR outside 481 ns | — | 1,527 of 1,567 | 2,506 of 2,516 |
| max PCR jitter | — | 307,767 µs | 302 µs |
| **PCR intervals > 40 ms** | 0 | **163** | **0** |

The stuffing row is the whole of T13's original problem: a groomer on the MoQ lane has to *inflate* a
stream, and the observations below establish that `tsp` cannot. On the segmented lane there is nothing
to inflate — the packager passed the source's nulls through, and 4.57 % against 4.59 % is the same
stuffing minus what fell outside the capture window.

The last row is the one that was not anticipated, and it removes T13's headline live failure from the
segmented lane before any tool runs. MoQ's exporter emits PCRs in clusters rather than on a grid, so any
stage that carries them rather than minting its own inherits 163 intervals over the 40 ms limit. The segmented egress
arrives with 0, because the source is a conformant broadcast mux and the packager preserved its PCR
spacing.

Both lanes fail the 481 ns gate on essentially every PCR before grooming, which is expected of either:
neither delivers on a constant-rate wire, so PCR read against a constant-rate model is wrong on both.
That is the part a groomer is *for*.

### File domain, MoQ lane

Broadcast mux, 300,000 packets. "Mb/s" is the rate the stream declares by its own PCR arithmetic;
duration fidelity is the ratio of the groomed stream's own duration to the source's.

| Chain | packets | stuffing | Mb/s | PCR > 481 ns | PCR > 500 µs | intervals > 40 ms | CC | max jitter | duration |
|---|---|---|---|---|---|---|---|---|---|
| ungroomed egress | 300,000 | 0 % | 9.519 | **1,527 of 1,567** | 230 | 163 | 0 | 307,767 µs | 1.000 |
| TSDuck `regulate` | 300,000 | 0 % | 9.519 | **1,527** | 230 | 163 | 0 | 307,767 µs | 1.000 |
| TSDuck `pcradjust` @ content | 300,000 | 0 % | 9.519 | 0 | 0 | **299** | 0 | 262 µs | 1.000 |
| TSDuck `mux` nulls + `pcradjust` @ nominal | 300,000 | 0 % | 9.958 *claimed* | 0 | 0 | 284 | 0 | 251 µs | **0.956** |
| FFmpeg `-muxrate` | 313,853 | 4.5 % | 9.950 | 0 | 0 | 0 | 0 | 8.8 µs | 1.001 |
| FFmpeg `-muxrate`, PIDs pinned | 313,853 | 4.5 % | 9.950 | 0 | 0 | 0 | 0 | 8.8 µs | 1.001 |
| GStreamer `mpegtsmux bitrate=`, PIDs pinned | 313,828 | 3.8 % | 9.952 | 0 | 0 | 0 | 0 | 25.0 µs | 1.001 |
| GStreamer, SCTE-35 forwarded | 313,828 | 3.8 % | 9.952 | 0 | 0 | 0 | 0 | 25.0 µs | 1.001 |
| pacer @ nominal *(control)* | 313,831 | 4.2 % | 9.952 | 0 | 0 | 0 | 0 | 19.3 µs | 1.001 |
| pacer @ auto *(control)* | 344,988 | 12.8 % | 10.940 | 0 | 0 | 0 | 0 | 19.6 µs | 1.001 |

Structural outcome, relative to what `export ts` emitted:

| Chain | Structure |
|---|---|
| TSDuck `regulate`, both `pcradjust` variants, pacer | preserved (the pacer adds PID 0x1FFF, which is the stuffing) |
| FFmpeg `-muxrate` | **all seven elementary PIDs renumbered** — 111/121/123/131/141/142/143 became 256–262 |
| FFmpeg `-muxrate`, PIDs pinned | PIDs kept, but AC-3 relabelled ATSC and **all three SCTE-35 PIDs retyped to generic MPEG-2 PES private data**; an SDT synthesised |
| GStreamer `mpegtsmux`, PIDs pinned | elementary PIDs and stream types kept, AC-3 kept as DVB AC-3, but **all three SCTE-35 PIDs absent**, the teletext descriptor lost, and the PMT moved from 4096 to 32 |
| GStreamer, SCTE-35 forwarded | the same, with splice information back on PID 141, correctly typed 0x86 — one of the three |

On the 2 Mbps single-programme CBR feed the same chains are uniformly better behaved, which is the
tell: `pcradjust` at the content rate reaches 4.3 µs (against 262 µs on the broadcast mux), FFmpeg
0.6 µs with nothing lost, and GStreamer 2.3 µs at exactly 2.000 Mb/s with duration fidelity 1.000,
losing only the SDT and the PMT's PID — because a video-only feed has no signalling to damage and a
genuinely constant content rate to re-stamp against. The nominal-rate `mux` variant fails the same way
as on the broadcast mux, harder: duration fidelity 0.927.

### File domain, segmented lane

The same nine chains, same clip, same oracle, fed the 60 s segmented capture (406,407 packets) in
place of the `export ts` one. Structure is relative to the segmented egress as delivered.

| Chain | packets | stuffing | Mb/s | PCR > 481 ns | intervals > 40 ms | CC | max jitter | Structure |
|---|---|---|---|---|---|---|---|---|
| ungroomed segmented egress | 406,407 | 4.6 % | 9.948 | 2,506 | **0** | 0 | 302.3 µs | — |
| TSDuck `regulate` | 406,407 | 4.6 % | 9.948 | **2,506** | 0 | 0 | 302.3 µs | preserved |
| **TSDuck `pcradjust` @ content** | 406,407 | 4.6 % | 9.948 | **0** | **0** | 0 | **2.9 µs** | **preserved** |
| TSDuck `mux` nulls + `pcradjust` @ nominal | 406,407 | 4.6 % | 9.959 *claimed* | 0 | 0 | 0 | 2.9 µs | preserved |
| FFmpeg `-muxrate` | 411,577 | 5.6 % | 9.958 | 0 | 0 | 0 | 2.0 µs | **10 PIDs renumbered** |
| FFmpeg `-muxrate`, PIDs pinned | 411,577 | 5.6 % | 9.958 | 0 | 0 | 0 | 2.0 µs | **NIT/CAT lost, 3 SCTE-35 retyped** |
| GStreamer `mpegtsmux`, PIDs pinned | 408,640 | 4.2 % | 9.963 | 0 | 0 | 0 | 22.7 µs | **PSI and all 3 splice PIDs lost** |
| GStreamer, SCTE-35 forwarded | 408,640 | 4.2 % | 9.963 | 0 | 0 | 0 | 22.7 µs | **the same, 1 of 3 splice PIDs back** |
| pacer @ nominal *(control)* | 407,358 | 4.8 % | 9.959 | 0 | **5** | 0 | 6.5 µs | preserved |
| pacer @ auto *(control)* | 446,285 | 13.1 % | 10.918 | 0 | **21** | 0 | 5.7 µs | preserved |

**`tsp -P pcradjust` alone clears every file-domain criterion on this lane**, and does it while
carrying the mux byte-for-byte: 0 violations at the P2 gate, 2.9 µs maximum jitter, no interval above
40 ms, stuffing and declared rate unchanged from the egress. On the MoQ lane the identical command
leaves 299 intervals above 40 ms, and the reason is entirely the census above — here there was nothing
to insert and nothing to re-place.

The two regenerating muxers damage the mux exactly as they do on the MoQ lane, which is the expected
result and worth stating: their failure is a property of the tool, so it does not move when the lane
does. The `mux` + `pcradjust` variant still inserts zero packets, but its dishonesty shrinks from 4.4 %
to 0.11 % — it claims 9.959 Mb/s and carries 9.948 — because on this lane almost all the stuffing it
was asked to add is already there.

The pacer is the interesting inversion. On this lane it is *worse* than doing less: it strips the
egress's nulls and re-stuffs to a nominal rate slightly above what the stream carries, and that
redistribution puts 5 intervals over 40 ms where the untouched byte schedule had none. Told to choose
its own rate it inflates to 13.1 % stuffing and posts 21. A stage that rebuilds a schedule which was
already correct can only make it worse.

### Wire domain, MoQ lane

25 s per leg. Delivered rate is UDP payload, so the pacer's figure includes RTP headers.

| Chain | delivered | per-second range | 10 ms CoV | 10 ms peak/mean | gap p50 / p95 / max | gaps > 20 ms | PCR > 481 ns as received | > 40 ms | max jitter |
|---|---|---|---|---|---|---|---|---|---|
| FFmpeg `-muxrate`, PIDs pinned | 11.382 Mb/s | **8.11 – 46.34** | **5.875** | **117.71** | 5 µs / 32 µs / **735 ms** | 130 | 0 | 0 | 1.2 µs |
| GStreamer `mpegtsmux` + `udpsink` | 9.954 Mb/s | 8.68 – 11.44 | 2.262 | 28.79 | 5 µs / 1.10 ms / **284 ms** | **376** | 0 | 0 | 21.8 µs |
| TSDuck `pcradjust` + `regulate` | 9.715 Mb/s | 9.70 – 9.73 | 0.353 | 2.06 | 5 µs / 9.95 ms / 14.6 ms | 0 | 0 | 136 | 76 µs |
| pacer *(control)* | 10.037 Mb/s | 10.03 – 10.05 | **0.079** | 1.59 | 1.17 ms / 2.09 ms / 10.4 ms | 0 | 0 | 131 | 171 µs |

One thing the file domain cannot show. The pacer posts no PCR interval above 40 ms on a file and 131 in
25 s on the wire; the pass-through chain posts them in both domains at a similar rate (299 across 47 s
on file, 136 across 25 s live). A stage that re-times a stream as it arrives cannot place PCRs as
freely as one reading a file, and for the pacer that is the whole difference between the two columns.
The two regenerating muxers post none in either domain, because they mint their own PCR schedule
rather than carry the exporter's.

Structure on the live legs behaves as the file domain predicts. This build's `export ts` emits its own
PSI — PMT on PID 100 plus a NIT on 16 and an SDT on 17 — and the pass-through chain and the pacer
delivered all of it untouched. FFmpeg rebuilt it: the NIT dropped, its own SDT in place of the
exporter's, and the same AC-3 and SCTE-35 retyping as on file. GStreamer discarded all of it — NIT,
SDT and the exporter's PMT PID — and emitted its own PAT and PMT, because `tsdemux` presents no PSI
to re-mux.

### Wire domain, segmented lane

25 s per leg, same instrument. The pacer legs are RTP, so their delivered rate includes RTP headers.

| Leg | delivered | per-second range | gap p50 / p95 / max | 10 ms CoV | peak/mean | PCR > 481 ns as received | > 40 ms | max interval | CC | Structure |
|---|---|---|---|---|---|---|---|---|---|---|
| TSDuck `pcradjust` + `regulate` | 9.951 Mb/s | 9.84 – 10.04 | 5.7 µs / 9.94 ms / **85.8 ms** | **0.618** | **8.78** | **0** | **0** | 24.9 ms | 0 | preserved |
| pacer @ **8 s** cushion *(control)* | 10.037 Mb/s | 10.02 – 10.06 | 1.16 ms / 2.12 ms / **9.8 ms** | **0.078** | **1.27** | **0** | **0** | 37.8 ms | 0 | preserved |
| pacer @ **1 s** cushion | **8.570 Mb/s** | **0.00 – 10.06** | 1.16 ms / 1.95 ms / **1,848.5 ms** | 0.425 | 1.86 | 2 | **5** | **1,846.5 ms** | **311** | **FAIL** |

Two results, and they are independent.

**The criterion that fails on the MoQ lane passes here, for both stages.** The pass-through chain and
the pacer each deliver 0 PCR intervals above 40 ms as received, where on the MoQ lane the same two
deliver 136 and 131. Nothing about the tools changed. What changed is the census: this egress arrives
with its PCR spacing intact, so a stage that carries it has something conformant to carry.

**Below the segment period, a groomer starves, and the failure is total.** The 1 s cushion is smaller
than the 2 s segments feeding it, so twice in 25 s the buffer ran dry and the socket went silent for
1.85 s. That figure appears identically in three instruments — a 1,848.5 ms gap between datagrams, a
1,846.5 ms PCR interval, and 1,845,984 µs of PCR jitter — which is what a genuine starvation looks
like as opposed to an instrument artefact. It cost 311 continuity errors and 14 % of the delivered
rate. The same stage at 8 s is clean on every column. **On a segmented lane the cushion is not a
tuning parameter, it is a correctness precondition, and its floor is the segment duration.** That is
the same threshold [T12](test-12-dual-path-handoff.md) needed for a byte-identical 1+1 pair and
[T16](test-16-grooming-segmented-http.md) needed to reach 0 intervals above 40 ms.

The pass-through chain's weakness on this lane is cadence, and only inside the second. Its per-second
series is flat and its PCR record is clean, but the 10 ms statistics are an order of magnitude worse
than the pacer's — CoV 0.618 against 0.078, an 8.78× peak-to-mean against 1.27×, and a worst silence
of 85.8 ms against 9.8 ms. `regulate` holds almost no buffer, so the coarse structure of segment
arrivals passes straight through it; on the MoQ lane, where arrivals are object-sized, the same chain
manages CoV 0.353 and a 14.6 ms worst silence. The tool did not get worse, the input did.

### The egress stage on its own

Every chain above bundles two jobs: rewrite the stream so it is constant-rate and PCR-conformant, and
put it on the wire on a clock. [`rawsendmpeg2ts`](https://github.com/EDIS-mx/rawsendmpeg2ts) does only
the second — 366 lines of C11 that take a CBR, null-stuffed stream, derive the mux rate from bytes per
PCR, and send seven packets per datagram against absolute `CLOCK_MONOTONIC` deadlines anchored at
start. It rewrites nothing, so it cannot be scored as a grooming stage; it is the stage T13 concluded
was missing after one.

Eight legs on the second host plus an ungroomed reference capture, 25 s each, one at a time. The
three at 11.000 Mb/s are rate-matched on
purpose: the instrument's 10 ms window resolves 1316-byte datagrams to about a tenth of a window, so
the quantisation floor moves with the rate and a cross-rate comparison would read that as a difference
between tools. For the same reason the pacer runs without `--rtp` here, unlike the laptop legs above,
so that every leg puts 1316 payload bytes in every datagram.

| Leg | delivered | gap p50 / p95 / p99 / max | 10 ms CoV | 10 ms peak/mean |
|---|---|---|---|---|
| **told to run at 11.000 Mb/s, MoQ egress, same groomer** | | | | |
| `ffmpeg -muxrate` + `rawsendmpeg2ts` | 11.000 | 957 µs / 990 µs / 1.05 ms / **3.65 ms** | **0.048** | 1.15 |
| `ffmpeg` PIDs pinned + `rawsendmpeg2ts` | 11.000 | 957 µs / 991 µs / 1.05 ms / **3.51 ms** | **0.048** | 1.15 |
| `mpegts-pacer` *(control)* | 11.000 | 1.08 ms / 1.14 ms / 1.27 ms / 3.87 ms | 0.077 | 1.15 |
| `ffmpeg -muxrate` + its own UDP output | **12.721** | 3 µs / 17 µs / 159 µs / **265.8 ms** | **6.553** | **171.13** |
| **at 9.946 Mb/s** | | | | |
| `rawsendmpeg2ts` replaying the source file | 9.946 | 1.06 ms / 1.08 ms / 1.10 ms / **1.65 ms** | 0.053 | **1.06** |
| `tsp regulate --pcr-synchronous -O ip` | 9.976 | 3 µs / 19 µs / 73.6 ms / 74.3 ms | 2.502 | 7.51 |
| the same, `--wait-min 5` | 9.958 | 3 µs / 91 µs / 24.7 ms / 33.7 ms | 1.206 | 3.39 |
| `mpegts-pacer` *(control)* | 9.946 | 1.08 ms / 2.08 ms / 2.11 ms / 9.96 ms | 0.087 | 1.59 |

Carriage and conformance of the same legs, as received. PID 0x1FFF is omitted from the PID sets and
reported in the stuffing column instead:

| Leg | PID set delivered | jitter > 481 ns | intervals > 40 ms | max interval | stuffing |
|---|---|---|---|---|---|
| ungroomed egress *(reference)* | 0, 16, 17, 100, 111, 121, 123, 131, 141–143 | 528 | 55 | 319.9 ms | 0 % |
| `rawsendmpeg2ts`, source file | **byte-identical to the file** | 0 | **0** | 25.0 ms | 4.5 % |
| `ffmpeg -muxrate` + sender | 0, 17, 256, 257, 4096 | 0 | **0** | 20.2 ms | 15.3 % |
| `ffmpeg` pinned + sender | 0, 17, 111, 121, **123 ATSC**, 131, **141–143 private**, 4096 | 0 | **0** | 20.4 ms | 13.8 % |
| `mpegts-pacer` *(control)* | 0, 16, 17, 100, 111, 121, 123, 131, 141–143 | 0 | **159** | 227.4 ms | 11.1 % |

The file leg is the strongest statement available about what the sender does to a stream: the
31,081,288 bytes received compare equal to the first 31,081,288 bytes of the source, all 165,326
packets of it, PID 0x1FFF stuffing and TDT included. Its rate derivation returned 9,945,951 bit/s,
the clip's nominal mux rate to the bit, and it reported no clock slip in 25 s on any of the three
legs it ran.

The pacer's leg at 9.946 Mb/s is not a steady state and is included only for completeness: it
delivered 0 % stuffing, which means it spent the window drawing down a backlog rather than padding a
surplus, because the egress content rate on this host is close enough to the nominal to leave nothing
to pad with. That is the same trap the first correction below records, and its bimodal gap
distribution — a p95 of 2.08 ms against a 1.06 ms mean, datagrams leaving in pairs — is what the trap
looks like on a socket. The 11.000 Mb/s legs are the comparison to read.

### Against the pass criteria

Each candidate chain, scored on the four criteria fixed above. **On the MoQ lane no off-the-shelf
chain passes all four**; the closest fails one criterion only, and it is carriage. The unpinned FFmpeg
and the plain GStreamer remux fail criterion 1 harder than the forms listed, so they are not scored
separately.

| Chain | 1 mux preserved | 2 PCR ≤ 481 ns | 3 no interval > 40 ms | 4 honest time, paced wire | Verdict |
|---|---|---|---|---|---|
| TSDuck `regulate` alone | pass | **fail** (1,527) | **fail** (163) | pass (its wire measured in the chain below) | **fail** — paces without grooming |
| TSDuck `pcradjust` @ content (+ `regulate` for the wire) | pass | pass | **fail** (299 file; 136 live) | pass | **partial** — the only pass-through option, and it cannot run at a nominal rate |
| TSDuck `mux` nulls + `pcradjust` @ nominal | pass | pass | **fail** (284) | **fail** (duration 0.956) | **fail** — claims a rate it does not carry |
| FFmpeg `-muxrate`, PIDs pinned, own socket | **fail** (SCTE-35 retyped, AC-3 relabelled, SDT injected) | pass | pass | **fail** on the wire (8.11–46.34 Mb/s) | **partial** — timing yes, fidelity and cadence no |
| FFmpeg `-muxrate`, PIDs pinned, **+ `rawsendmpeg2ts`** | **fail** (all three SCTE-35 PIDs retyped, AC-3 relabelled ATSC, NIT dropped, SDT synthesised) | pass | pass (0 live, max 20.4 ms) | pass (11.000 Mb/s, CoV 0.048, worst silence 3.5 ms) | **partial** — the only failure left is carriage |
| GStreamer `mpegtsmux`, PIDs pinned, SCTE-35 forwarded | **fail** (PSI beyond PAT/PMT, PMT's PID, teletext descriptor, 2 of 3 splice PIDs) | pass | pass | duration pass, wire **partial** (silences to 284 ms) | **partial** — loses signalling, and its wire still needs pacing |
| `mpegts-pacer` *(control)* | pass | pass | pass on file (0); **fail live** (131 laptop, 159 box) | pass | **pass** as scored; see criterion 3's live column |

Criterion 4's duration test is 1.000 within the arithmetic of adding stuffing, which is why the 1.001
readings above count as exact; what it is there to catch is the 0.956 of the nominal-rate `mux`
variant, a stream running 4.4 % fast.

**On the segmented lane the same scoring comes out differently, and the difference is criterion 3.**

| Chain | 1 mux preserved | 2 PCR ≤ 481 ns | 3 no interval > 40 ms | 4 honest time, paced wire | Verdict |
|---|---|---|---|---|---|
| TSDuck `regulate` alone | pass | **fail** (2,506) | pass (0) | pass | **fail** — paces without grooming |
| **TSDuck `pcradjust` (+ `regulate` for the wire)** | **pass** | **pass** | **pass** (0 file, 0 live, max 24.9 ms) | **pass** (9.951 Mb/s, per-second 9.84–10.04) | **pass**, with a cadence caveat below |
| TSDuck `mux` nulls + `pcradjust` @ nominal | pass | pass | pass (0) | **fail** (claims 9.959, carries 9.948) | **fail** — still claims a rate it does not carry |
| FFmpeg `-muxrate`, PIDs pinned | **fail** (NIT and CAT lost, 3 SCTE-35 PIDs retyped) | pass | pass | not re-run live | **fail** — carriage, as on the MoQ lane |
| GStreamer `mpegtsmux`, SCTE-35 forwarded | **fail** (PSI, PMT PID, 2 of 3 splice PIDs) | pass | pass | not re-run live | **fail** — carriage, as on the MoQ lane |
| `mpegts-pacer` @ 8 s cushion *(control)* | pass | pass | pass (5 file, **0 live**) | pass (CoV 0.078) | **pass** |
| `mpegts-pacer` @ 1 s cushion | pass | **fail** (2) | **fail** (5, max 1,846 ms) | **fail** (8.570 Mb/s, 1.85 s silences) | **fail** — cushion below the segment period |

The pass-through chain's criterion 4 is a pass on the terms fixed in advance — the delivered rate is
genuinely rate-controlled, flat to ±1 % every second, with no silence approaching a segment period.
The caveat that belongs with it is that its cadence inside the second is an order of magnitude coarser
than the pacer's, with 85.8 ms worst-case silence. Whether that matters is a receiver question the
campaign has not yet answered on hardware; it is well inside what the criterion asks and well outside
what the pacer achieves.

**What decides criterion 3 is the egress's PCR spacing, not buffer depth and not the file/wire
distinction.** An earlier reading of this experiment attributed the pacer's live failure to cushion,
because [T16](test-16-grooming-segmented-http.md) reached 0 on the wire while carrying seconds of it.
Two measurements rule that out. [T18](test-18-delivery-latency.md) swept the MoQ lane's cushion across
eight times the depth, removed starvation entirely, and did not move the figure. And on the segmented
lane the TSDuck chain holds almost no buffer at all and still posts 0 — because this egress arrives
with 0 intervals above 40 ms, where MoQ's arrives with 163. A pass-through stage inherits what it is
given, exactly; a regenerating stage mints its own schedule and inherits nothing, which is why FFmpeg
and GStreamer post 0 on both lanes while destroying the mux on both. Cushion enters only as a way to
make things *worse*: too shallow and the stage starves, which is the 1 s row above, and that is a
different defect with a different signature.

## Observations

**The grooming requirement is set by the data plane, and the two lanes ask for different jobs.** This
is the finding that reorganises the rest. On the MoQ lane a groomer must add stuffing, invent a
nominal rate, re-place PCR and own a clock; nothing off the shelf does the first while carrying a
broadcast mux, so the whole chain fails. On the segmented lane the packager already passed the
source's nulls, its declared rate and its PCR spacing through, so the only job left is the clock — and
`tsp -P pcradjust -P regulate -O ip` does it, mux intact, on every criterion. **The same command is a
partial answer on one lane and a complete one on the other.** Any statement about what a grooming
stage must do is incomplete without naming the egress it sits behind.

**TSDuck cannot restore stuffing, by construction.** `mux` inserted exactly zero packets, with
`--bitrate` and with `--inter-packet`, on both inputs and on both lanes. `tsp`'s pipeline can drop
packets or overwrite existing stuffing but cannot inflate a stream, which its own plugin documentation
states three ways over: `mux` "replaces all stuffing packets", `duplicate` reuses null packets, and
`pcradjust`'s `--min-ms-interval` inserts a PCR by replacing "the next null packet". A MoQ egress has
no nulls to replace, so there is nothing for these plugins to work with. This is why there is no
pad-to-bitrate plugin to find — and why the limitation is invisible on the segmented lane, where the
nulls are already there.

**Passing every PCR check is not the same as being right.** The `mux` + `pcradjust` @ nominal variant
posts a perfect PCR record — 0 violations at 481 ns — while delivering 47.4 s of content as 45.3 s.
It re-stamped PCR as though the stuffing it failed to insert were there, so the stream claims
9.958 Mb/s and carries 9.519. An IRD locked to that clock drains its buffer at 4.4 %. The pair of
checks that catches it is duration fidelity plus the packet count; PCR conformance alone does not.

**Fixing PCR repetition requires stuffing; not needing to fix it requires a lane that never broke it.**
On the MoQ lane `pcradjust` leaves 299 intervals above 40 ms — more than the ungroomed stream's 163,
because re-stamping redistributes time across a stream whose content is unevenly bunched once the
nulls are gone. Inserting an extra PCR needs a null packet to overwrite, which is the same wall as
above. On the segmented lane the identical command posts 0, and does so without inserting anything,
because the spacing it inherited was already conformant. The repetition criterion is not really a test
of the groomer at all: it is a test of what reached it.

**A stage that rebuilds a correct schedule can only damage it.** The pacer at a nominal rate is the
best-scoring stage on the MoQ lane and a mild regression on the segmented one, where it strips 4.6 %
stuffing and re-inserts 4.8 % at a slightly higher rate, putting 5 intervals over 40 ms where the
untouched byte schedule had none. At its own chosen rate it inflates to 13.1 % and posts 21. This is
not a defect in the tool — it is being asked to solve a problem the lane does not have. The general
form is worth keeping: on an egress that already carries a valid mux rate, the correct amount of
re-stuffing is none, and a groomer's value there is confined to the wire.

**A constant-rate stream is not a paced wire.** This is the finding that inverts the FFmpeg result.
`-muxrate` produces the best PCR arithmetic of anything measured, and on the socket it is unusable:
46.34 Mb/s in the first second as it drains the backlog MoQ handed it, then 8–13 Mb/s per second,
1.3 Gb/s peaks inside 10 ms windows, datagrams 5 µs apart punctuated by a 735 ms silence. It writes a
CBR stream as fast as its input arrives. Whatever wire behaviour is wanted must come from a stage
that owns a clock, which `-muxrate` does not.

**GStreamer paces per frame, not per packet.** `udpsink` synchronises to the clock by default, and
that is enough to stop the backlog dump that ruins the FFmpeg leg: the GStreamer leg opens at
10.53 Mb/s where FFmpeg opens at 46.34, and holds the nominal rate across the window. But the cadence
it produces is granular: datagrams leave 5 µs apart in a burst, then the socket is silent for up to
284 ms, 376 times in 25 s, and the delivered rate still swings 8.68–11.44 Mb/s second to second. The
count is the tell — 376 silences against the 625 frames a 1080i25 feed carries in 25 s — so what the
sink is synchronising to is the access unit the muxer timestamped, not the packet. Setting `alignment=7`
fixes the datagram at 1316 bytes but does not change when it is sent. A constant-rate mux plus a
clock-synchronised sink is closer to a paced wire than `-muxrate` and a socket, and it is still not one.

**GStreamer can carry SCTE-35, on one PID, on its own schedule.** `tsdemux` presents no pad for a
splice PID, so a plain remux drops all three and their signalling with them. With
`send-scte35-events=true` and `mpegtsmux scte-35-pid=141` the sections come back **correctly typed as
0x86** with the payload intact to the CRC, which is more than FFmpeg manages. Two limits come with it:
`mpegtsmux` has room for one splice PID, so a mux with three keeps the first; and the repetition is
regenerated, not passed through — 7 heartbeat packets in a 6 s window arrived as 1. What this window
contains is `splice_null` heartbeats, so it demonstrates carriage and typing, not the timing of a real
splice command.

**What `tsdemux` will not show you, `mpegtsmux` cannot put back.** Both ends can be pinned — `tsdemux`
names its pads after the source PID, `mpegtsmux` takes the PID from its request pad name — and within
that, fidelity is good: PIDs, stream types and the DVB AC-3 signalling FFmpeg relabels all survive.
The losses are what never reaches the muxer as a pad: every PSI table beyond PAT and PMT, the PMT's own
PID (4096 became 32, and `prog-map`'s `PMT_1` did not move it), and the teletext descriptor's language
and page assignment, leaving a bare teletext stream type. A remux is only as faithful as its demuxer.

**A pipeline that produces nothing is the default configuration.** With `queue` at its default sizes
the remux deadlocks: the muxer waits for a stream whose queue is full, and the file it is writing stays
at zero bytes indefinitely. Every GStreamer measurement here needs
`max-size-buffers=0 max-size-time=0 max-size-bytes=134217728` on each branch. Worth stating in any
recipe, because the failure is silent.

**`regulate` is a pacer, not a groomer, and it is a good one — but it is only as good as its input's
burst size.** It changed nothing about PCR conformance on either lane (1,527 violations before and
after on MoQ, 2,506 on segmented), and behind `pcradjust` it is the only pass-through chain here that
is both PCR-conformant and rate-controlled. Its cadence, though, degrades with the coarseness of what
arrives: on the MoQ lane it holds 9.70–9.73 Mb/s per second with a 2.06 peak-to-mean and no silence
longer than 15 ms; on the segmented lane, fed 2 s segments, the same settings give an 8.78
peak-to-mean and an 85.8 ms silence. It holds almost no buffer, so the arrival shape passes through
it. `--packet-burst` tunes its granularity but not its depth, and depth is what a bursty lane needs.

**A groomer with a cushion shallower than the burst period does not degrade, it stops.** The 1 s
cushion against 2 s segments is the clearest failure in this experiment: 1.85 s of complete socket
silence, twice in 25 s, 311 continuity errors, 14 % of the rate gone. There is no partial-credit
region — the buffer either spans the gap between arrivals or it empties. The threshold is the segment
duration and the campaign has now met it three times from different directions:
[T12](test-12-dual-path-handoff.md) needed 8 s for a byte-identical 1+1 pair,
[T16](test-16-grooming-segmented-http.md) needed it for PCR repetition, and this needs it for the wire
to exist at all.

**The wire half of grooming is a solved problem, and it is small.** The finding above — that a
constant-rate stream is not a paced wire, and that the missing thing is a stage owning a clock — has
an off-the-shelf answer in 366 lines of C11 with no dependencies beyond POSIX. Holding the groomer fixed
and swapping only the egress takes the same FFmpeg output from CoV 6.553, a 171× peak-to-mean and a
265.8 ms silence to CoV 0.048, 1.15× and 3.5 ms. Nothing about the stream changed; the only
difference is which stage decided when to call `send`.

**Delivering the declared rate and delivering the right average are different tests.** Told to run at
11 Mb/s, FFmpeg's own socket put 12.721 Mb/s on the wire across the window and 51.65 Mb/s in the
first second, because it writes as fast as its input arrives and MoQ hands it a join backlog. The
same groomer behind the sender delivered 11.000 Mb/s, every second of the window between 10.99 and
11.00. A per-second series is what separates these; a window average does not.

**Uniform pacing without a buffer policy moves the problem rather than removing it.** The sender's
deadlines are anchored at start and its socket is blocking with a 32 kB send buffer, so it will not
dump a backlog — but neither will it discard one. Whatever MoQ delivers at join above the derived
rate becomes standing latency in the pipe, or is dropped upstream when the exporter's own
`--latency-max` expires, and nothing in the chain reports which. This is the whole of the difference
in kind between it and the pacer, whose looser cadence buys `--latency-ms`, `--max-latency-ms`,
`--stall-ms` and `--on-stall`. It is also why the rate matters so much: the rate is derived once, from
about a second of PCR at start, on a CBR assumption, so the groomer in front must hold a fixed rate
for the life of the stream.

**Past a point the 10 ms peak-to-mean stops measuring the tool and starts measuring the window.**
Replaying the source file, no 10 ms window ever held more than one datagram above nominal: p95 and
maximum both land on 10.528 Mb/s, which is exactly ten 1316-byte datagrams where the mean calls for
9.45, and the peak-to-mean of 1.06 is that ratio and nothing else. At 11 Mb/s the floor is 12
datagrams against 10.45, or 1.15 — and all three paced legs there report exactly 1.15, sender and
pacer alike. The statistic separates a paced wire from an unpaced one by two orders of magnitude and
cannot separate two paced ones at all. What still discriminates is the coefficient of variation
(0.048 against 0.077) and the gap distribution: a p95 of 990 µs against 1.14 ms, and p99 1.05 ms
against 1.27 ms.

## Conclusion

**Whether the grooming stage can be built off the shelf depends on the data plane, and for segmented
HTTP the answer is yes.**

`tsp -P pcradjust --bitrate <rate> -P regulate --bitrate <rate> -O ip`, behind a segmented egress,
passes all four criteria: the mux survives byte-for-byte, PCR clears the P2 gate, no interval exceeds
40 ms as received, and the wire is flat to ±1 % per second. It costs one qualification — cadence
inside the second is coarse, an 8.78 peak-to-mean and 85.8 ms worst silence against the pacer's 1.27
and 9.8 ms — and one operational rule, that any stage on this lane must hold a cushion at least as
deep as the segment period or it will stop dead rather than degrade.

**On the MoQ lane there is still no off-the-shelf stage that does both halves, and the half missing is
carriage.** That is not a statement about MPEG-TS grooming; it is a statement about what `export ts`
delivers. Two of its properties cause the entire result: it carries no stuffing, so a groomer must
inflate a stream and no tool that preserves a broadcast mux can; and it emits PCRs in bursts rather than
on a grid, so any stage that carries them rather than minting its own inherits 163 intervals above the
40 ms limit. The
segmented lane is the control that isolates this — same clip, same tools, same oracle, both properties
absent, and the failure disappears. **The gap to state upstream is a MoQ exporter gap, not a grooming
gap.**

On the MoQ lane, each candidate fails a different criterion, and which failure is acceptable depends
on the receiver:

- **`tsp -P pcradjust --bitrate <content rate> -P regulate --bitrate <content rate> -O ip`** is the
  only pass-through option: the mux survives byte-for-byte, PCR passes the P2 gate, duration fidelity
  is exact, and the wire is rate-controlled with no silence beyond 15 ms. Its limits must be stated
  with it — PCR repetition above 40 ms is not fixed, PCR error against a constant-rate model is
  76–262 µs on a real mux rather than the pacer's 19–171 µs, `pcradjust` rewrites PTS and DTS by
  default, and the service runs at the content rate rather than a nominal one, so a downstream contract
  for "9.946 Mb/s" cannot be met.
- **`gst-launch-1.0 ... tsdemux ! mpegtsmux bitrate=<nominal> ! udpsink`** is the best of the
  regenerating options and the only off-the-shelf stage that both runs at a nominal rate and keeps
  SCTE-35 correctly typed. It costs the PSI beyond PAT and PMT, the PMT's PID, the teletext descriptor,
  and every splice PID after the first; its wire is rate-controlled per second but bursts with silences
  up to 284 ms, so anything expecting smooth delivery still needs a pacing stage. The pipeline must be
  written per stream and its queues resized, or it deadlocks.
- **`ffmpeg -muxrate ... | rawsendmpeg2ts`** is the strongest fully off-the-shelf chain, and its only
  remaining failure is carriage. PCR arithmetic is exact, PCR repetition is the best of anything
  measured as delivered (0 intervals above 40 ms, 20.4 ms maximum, because the muxer mints its own
  schedule), and the wire is the tightest of any chain at the same rate. What it costs is the mux:
  PIDs can be pinned back, SCTE-35 stream types cannot, AC-3 is relabelled ATSC, the NIT is dropped
  and an SDT is synthesised. For a single-programme feed with no signalling contract this is now a
  complete answer; for a broadcast mux it is not, and no configuration of it is.
- **`mpegts-pacer`** is the only stage measured here that satisfies all four criteria on the MoQ lane,
  and the only one that keeps the mux intact. Its weakness is the one criterion 3's live column
  exposes: it inherits the exporter's PCR spacing, 159 intervals above 40 ms in 25 s. That is not a
  cushion choice. [T18](test-18-delivery-latency.md) swept the cushion across eight times the depth,
  removed starvation entirely, and moved the figure not at all, and the segmented legs above post 0
  from a stage holding almost no buffer — so on both lanes the determinant is the egress, not the
  depth. The groomer does place PCRs of its own, but only into slots it was already going to stuff, and
  those do not fall in the gaps the exporter's clustering leaves ([T18](test-18-delivery-latency.md)
  measurements 4 and 6); the word "inherits" is exact, and it is the whole defect. That it satisfies
  the set at all is a statement about the state of the ecosystem, not a recommendation: as the
  upstream review of [#2830](https://github.com/moq-dev/moq/pull/2830) observed, it had no supported
  installation path at the time, and it is still one lab's unpublished tool.

The two halves of the job separate cleanly, and on the MoQ lane only one of them is unsolved off the
shelf. Any stage that owns a clock can produce a broadcast-grade wire, and one that does is 366 lines
of C. What no off-the-shelf stage does is add stuffing and re-place PCR *while carrying a broadcast mux
unchanged*: the tools that regenerate a mux can time it perfectly and cannot carry it, and the tools
that carry it cannot inflate it.

Stated that precisely, the gap is visibly conditional — and the segmented lane is the case where the
condition does not hold, because there is nothing to inflate and nothing to re-place. So the sentence
for someone else's documentation is not "you need a groomer" and not "no off-the-shelf groomer
exists", but: *an egress that drops stuffing and thins PCR requires a grooming stage that no
off-the-shelf tool can provide without damaging the mux; an egress that preserves both requires only
a paced sender, and TSDuck is one.* That framing survives on both lanes, and it points at the two
exporter behaviours worth changing upstream rather than at a missing tool.

For upstream documentation this supports stating the *requirement* precisely and naming the
off-the-shelf options with their measured limits, rather than naming any single tool as the answer.
That holds whether or not our own tool can be installed, which is why the installability fix noted
below does not reopen it.

**Scope.** These are file-arithmetic and loopback-cadence results on two general-purpose machines, a
laptop and a 2-vCPU cloud instance. They say nothing about what a hardware IRD accepts, which remains
[T7](test-7-timing-integrity.md)'s open Gate 2 — and the sender's own documentation is emphatic that a
switch between sender and IRD invalidates the test, because multicast storm control fakes the pacing
either way. That gate matters more for the segmented conclusion than for the MoQ one: the
pass-through chain passes every criterion fixed here while putting 85.8 ms silences on the wire, and
whether a receiver tolerates those is precisely what has not been tested. The wire figures carry a
general-purpose OS's scheduling jitter, and the three groups' figures are not interchangeable: compare
within a group, never across. The segmented legs also use one packager (`tsp -O hls`) at one segment
duration; [T11](test-11-interop.md) establishes that this packager re-muxes rather than slicing
verbatim, so another packager could hand a groomer a different census than the one above.

## Corrections

> The general method rules extracted from this section, together with those from every other
> experiment, are collected in [method-notes.md](method-notes.md). What stays here is the
> specific record of what this experiment got wrong.

- **A pacing target must be measured from the stream the stage will receive.** The pass-through chain
  needs the egress content rate, and it was twice taken from somewhere else: first from a file-domain
  capture of a different window (9,507,216 b/s), then from the FFmpeg leg's own output, which is padded
  to the nominal rate and therefore reads back 9,945,951. Both produced a plausible table. Below the
  true rate, `regulate` throttles under arrival and the delivered rate wanders (9.41–9.60 Mb/s); above
  it, the leg spends the entire window draining its join backlog at the cap and looks *flatter* than a
  correct run. Measured properly at 9,711,337 b/s the leg is flat at 9.70–9.73 Mb/s. **Method rule:**
  derive a rate target from a capture of the stage's own input, never from another stage's output, and
  treat an unexpectedly smooth result as a suspect one.
- **A null-stripped source clip is not a substitute for a real egress capture.** The first pass built
  the CBR input by stripping PID 0x1FFF from the source clip, on the reasoning that this is exactly
  what MoQ removes. On that input the pacer dropped 6,360 of 146,325 packets and produced 100
  continuity errors — a result that would have been reported as a defect. On a real `export ts`
  capture of the same shape it drops nothing. The stripped clip retains the source's own byte
  schedule, so content arrives ahead of the slots the groomer has for it. **Method rule:** grade a
  downstream stage against captures taken from the pipeline it will sit in, never against a
  synthesised approximation of that pipeline's output.
- **Killing a backgrounded pipeline by `$!` reaps only its last stage.** The egress-pacer rig started
  each leg as `subscriber | groomer &` and killed `$!`, which is the groomer. Every subscriber
  survived its own leg and kept pulling the broadcast for the rest of the run, so by the last leg
  three extra `moq export ts` processes were competing for two cores — load the late legs paid and the
  early ones did not, in a rig whose whole subject is scheduling jitter. It inflated exactly what was
  being measured: worst-case silences of 8.8 ms and 18 reported clock slips became 3.5 ms and zero
  once each subscriber was wrapped in `timeout` and swept by command line afterwards. The tell was
  arithmetic, not suspicion — a 17 MB reference capture that censused as 2.4 M packets, because the
  process writing it had never stopped. **Method rule:** in a timing rig, assert the process census
  between legs rather than trusting a kill, and check that a file's size and its packet count agree.
- **A negative result measured on one data plane was written as a property of MPEG-TS grooming.** For
  most of its life this experiment was titled "grooming of a MoQ egress" and concluded that no
  off-the-shelf stage does the job. Every measurement behind that was sound; the generalisation was
  not. Two properties of `export ts` — no stuffing, and PCR emitted in clusters — cause the entire
  result, and running the identical nine chains against a segmented egress makes the failure vanish,
  with `tsp -P pcradjust` passing all four criteria and carrying the mux. **Method rule:** when an
  experiment concludes that a class of tool cannot do something, name the input property that defeats
  them and then find an input without it; if none exists the conclusion is about the tools, and if one
  does the conclusion was about the input.
- **PCR repetition on the wire was attributed to buffer depth on the strength of a coincidence.** T16
  reached 0 intervals above 40 ms while carrying seconds of cushion, and this file read that as the
  cause, recording it here as "a buffer-depth choice rather than a limit". Two later measurements
  refute it: T18 swept the MoQ cushion eightfold with no effect, and the segmented pass-through leg
  above posts 0 while holding almost no buffer. The common factor was never the cushion, it was which
  egress the two runs were behind. **Method rule:** when two runs differ in more than one variable and
  one of them is the one you have been tuning, do not credit it — the other variable here was the data
  plane, and it was the whole effect.
- **"No supported installation path" was true when written, and has since been fixed.** The pacer was
  library-only: every documented command was `cargo run --example`, and `cargo install` refused the
  crate outright for having no binary target. The egress adapter is now the crate's `mpegts-pacer`
  binary, installable with `cargo install --git`, though still not on crates.io. This changes none of
  the measurements above and none of the conclusion: the recommendation for someone else's
  documentation was never contingent on our tool being installable, and remains the requirement plus
  the off-the-shelf options.

## References

- [T2](test-2-media-aware-transparency.md) — media-aware carriage and the first grooming results.
- [T7](test-7-timing-integrity.md) — TR 101 290 timing integrity, and the P1/P2 gates used here.
- [T11](test-11-interop.md) — what the HLS packager does to a transport stream, which is what sets the
  segmented lane's census here.
- [T12](test-12-dual-path-handoff.md) — the dual-path chain these stages sit in, and why a groomer's
  placement determinism matters for a 1+1 pair; the 8 s cushion this experiment also needs.
- [T16](test-16-grooming-segmented-http.md) — grooming the segmented lane end to end, at the cushion
  the wire legs here require.
- [T18](test-18-delivery-latency.md) — the cushion sweep that rules buffer depth out as the cause of
  the MoQ lane's PCR repetition.
- [moq-dev/moq#2830](https://github.com/moq-dev/moq/pull/2830) — the upstream documentation review
  that prompted this experiment.
- [EDIS-mx/rawsendmpeg2ts](https://github.com/EDIS-mx/rawsendmpeg2ts) — the datagram sender graded in
  the egress-pacer group.

# T13 — Off-the-shelf CBR/PCR grooming of a MoQ egress

## Objective

> **Read criterion 3 on the wire, not on the file.** The headline result of this experiment that
> travels furthest is a negative one: `mpegts-pacer` posts **0** PCR intervals above 40 ms on a
> captured file and **131 on the laptop rig and 159 on the EC2 box, with a 227.4 ms maximum, on the
> wire**, at the cushion the MoQ lane runs. [T16](test-16-grooming-segmented-http.md) later showed the
> constraint is buffer depth rather than live operation, reaching 0 on the wire at an 8 s cushion on
> the *other* data plane. **The depth at which the MoQ lane would reach 0, and whether it is
> compatible with sub-second delivery, is unmeasured** and is the campaign's highest-leverage
> outstanding run ([planned-experiments](planned-experiments.md)).


`moq ... export ts` emits a transport stream with no stuffing and no wire cadence: MPEG-TS null
packets are not carried, so what arrives is content only, delivered in MoQ's object bursts. Anything
downstream that expects a constant mux rate has to put both back. Every measurement in this campaign
so far has done that with one tool ([`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer)),
which makes the grooming stage look like a dependency on a single implementation.

This asks the question that matters to anyone adopting the chain: **can the grooming stage be built
from tools an operator already has?** The candidates are the ones an engineer would reach for first —
TSDuck's `regulate` and `pcradjust`, FFmpeg's `-muxrate`, and GStreamer's `mpegtsmux bitrate=` —
graded against the same oracle as
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

### Pass criteria (fixed before the runs)

A grooming stage is a candidate for a documented recipe if it does all four:

1. **Preserves the mux.** Every PID, stream type and PSI table that `export ts` emitted arrives
   unchanged. A broadcast mux is a contract: SCTE-35 on a known PID with stream type 0x86, not
   "something equivalent".
2. **PCR accurate.** 0 violations at the TR 101 290 P2 limit, measured as
   `pcrverify --absolute --jitter-max 13` (13 PCR units ≈ 481 ns). The plain `--jitter-max 500` that
   reads as 500 *micro*-seconds is a pre-check, not the gate.
3. **PCR present often enough.** No intervals above 40 ms.
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
- **Egress-pacer rig (a second host).** The legs that test a datagram sender on its own run on the
  EC2 box (Ubuntu, 2 vCPU, kernel 7.0) rather than the laptop, because
  [`rawsendmpeg2ts`](https://github.com/EDIS-mx/rawsendmpeg2ts) does not build on macOS:
  `clock_nanosleep` with `TIMER_ABSTIME` does not exist there, and that call *is* its pacing
  mechanism, so a shimmed build would measure the shim. Every control in that group — TSDuck,
  FFmpeg, the pacer — is therefore re-measured on the same box at the same rate rather than compared
  against the laptop figures above. Source is the same clip; the MoQ legs subscribe to the box's
  standing relay and loop publisher, `moq` 0.9.11-eab96019.
- Rigs: [`t13-groom-matrix.sh`](scripts/t13-groom-matrix.sh) builds the file-domain variants,
  [`t13-cadence.sh`](scripts/t13-cadence.sh) runs the live legs,
  [`t13-rawsend.sh`](scripts/t13-rawsend.sh) runs the egress-pacer legs, and
  [`t13-grade.py`](scripts/t13-grade.py) and [`t13-cadence.py`](scripts/t13-cadence.py) grade them.

## Procedure

Nine chains in the file domain, each fed the identical ungroomed capture:

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

Then the four that were worth running live — the pinned FFmpeg, GStreamer, the TSDuck pass-through
(`pcradjust` then `regulate` then `-O ip`), and the pacer — measured on the socket for delivered
rate, gap distribution, and the PCR conformance of the stream *as received*.

Then a third group, on the second host, isolating the egress stage. The pairs are the point: the same
FFmpeg output sent by FFmpeg's own socket and by `rawsendmpeg2ts`, so the only difference is which
stage decides when to send; and the same MoQ egress groomed by FFmpeg-plus-sender and by the pacer at
an identical 11 Mb/s, so the two architectures are compared at one rate. Two further legs establish
what the tools do at their best and what the instrument's floor is: the sender replaying the source
clip with no groomer in the chain at all, and TSDuck's own sender on that clip, at its default
`regulate` and at `--wait-min 5`.

## Results

### File domain

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

### Wire domain

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

Each candidate chain, scored on the four criteria fixed above. No off-the-shelf chain passes all four.
The closest now fails one criterion only, and it is carriage. The unpinned FFmpeg and the plain
GStreamer remux fail criterion 1 harder than the forms listed, so they are not scored separately.

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

Criterion 3 is scored on the file domain, where a stage places PCRs freely, and that scoring now
flatters one class of stage at the other's expense. On the wire the two candidate chains separate
completely: the regenerating chain delivers 0 intervals above 40 ms with a 20.4 ms maximum, and the
pacer delivers 159, up to 227 ms. Neither is a defect. A stage that mints its own PCR schedule places
PCRs wherever its `-pcr_period` says, and inherits nothing; a stage that carries the exporter's
inherits their spacing, and MoQ's egress arrives with 55 intervals already above 40 ms and a 319.9 ms
maximum. What decides it for a pass-through stage is buffer depth rather than live operation as such
— [T16](test-16-grooming-segmented-http.md) reaches 0 on the wire by carrying seconds of cushion —
so the choice is to regenerate PCR, or to hold enough buffer to always have a packet ready at the
deadline. At the ~1 s cushion used here, the pacer does neither. Read criterion 3 on the live column
when the question is what an IRD receives.

## Observations

**TSDuck cannot restore stuffing, by construction.** `mux` inserted exactly zero packets, with
`--bitrate` and with `--inter-packet`, on both inputs. `tsp`'s pipeline can drop packets or overwrite
existing stuffing but cannot inflate a stream, which its own plugin documentation states three ways
over: `mux` "replaces all stuffing packets", `duplicate` reuses null packets, and `pcradjust`'s
`--min-ms-interval` inserts a PCR by replacing "the next null packet". A MoQ egress has no nulls to
replace, so there is nothing for these plugins to work with. This is why there is no pad-to-bitrate
plugin to find.

**Passing every PCR check is not the same as being right.** The `mux` + `pcradjust` @ nominal variant
posts a perfect PCR record — 0 violations at 481 ns — while delivering 47.4 s of content as 45.3 s.
It re-stamped PCR as though the stuffing it failed to insert were there, so the stream claims
9.958 Mb/s and carries 9.519. An IRD locked to that clock drains its buffer at 4.4 %. The pair of
checks that catches it is duration fidelity plus the packet count; PCR conformance alone does not.

**Fixing PCR repetition requires stuffing.** `pcradjust` leaves 299 intervals above 40 ms — more than
the ungroomed stream's 163, because re-stamping redistributes time across a stream whose content is
unevenly bunched once the nulls are gone. Inserting an extra PCR needs a null packet to overwrite,
which is the same wall as above.

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

**`regulate` is a pacer, not a groomer, and it is a good one.** It changed nothing about PCR
conformance (1,527 violations before and after) but its live cadence holds 9.70–9.73 Mb/s per second
with a bounded 2.06 peak-to-mean and no silence longer than 15 ms, lumpy only inside 10 ms windows,
which is its regulation granularity and is tunable with `--packet-burst`. Paired with `pcradjust` it is
the only pass-through chain here that is both PCR-conformant and rate-controlled.

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

**There is no off-the-shelf stage that does both halves of the job, and the half still missing is
carriage.** Each candidate fails a different criterion, and which failure is acceptable depends on the
receiver:

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
- **`mpegts-pacer`** remains the only stage measured here that satisfies all four criteria as scored,
  and it is the only one that keeps the mux intact. Its weakness is the one criterion 3's live column
  exposes: at the ~1 s cushion run here it inherits the exporter's PCR spacing, 159 intervals above
  40 ms in 25 s. [T16](test-16-grooming-segmented-http.md) shows that is a buffer-depth choice rather
  than a limit — with seconds of cushion the same stage posts 0 — so the trade is PCR repetition
  against latency. That it satisfies the set at all is a statement about the state of the ecosystem, not a
  recommendation: as the upstream review of
  [#2830](https://github.com/moq-dev/moq/pull/2830) observed, it had no supported installation
  path at the time, and it is still one lab's unpublished tool.

The two halves of the job now separate cleanly, and only one of them is unsolved off the shelf. Any
stage that owns a clock can produce a broadcast-grade wire, and one that does is 366 lines of C. What no
off-the-shelf stage does is add stuffing and re-place PCR *while carrying a broadcast mux unchanged*:
the tools that regenerate a mux can time it perfectly and cannot carry it, and the tools that carry it
cannot inflate it. That is the gap to state in someone else's documentation, and it is narrower and
more specific than "you need a groomer".

For upstream documentation this supports stating the *requirement* precisely and naming the
off-the-shelf options with their measured limits, rather than naming any single tool as the answer.
That holds whether or not our own tool can be installed, which is why the installability fix noted
below does not reopen it.

**Scope.** These are file-arithmetic and loopback-cadence results on two general-purpose machines, a
laptop and a 2-vCPU cloud instance. They say nothing about what a hardware IRD accepts, which remains
[T7](test-7-timing-integrity.md)'s open Gate 2 — and the sender's own documentation is emphatic that a
switch between sender and IRD invalidates the test, because multicast storm control fakes the pacing
either way. The wire figures carry a general-purpose OS's scheduling jitter, and the two hosts'
figures are not interchangeable: compare within a group, never across.

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
- [T12](test-12-dual-path-handoff.md) — the dual-path chain these stages sit in, and why a groomer's
  placement determinism matters for a 1+1 pair.
- [moq-dev/moq#2830](https://github.com/moq-dev/moq/pull/2830) — the upstream documentation review
  that prompted this experiment.
- [EDIS-mx/rawsendmpeg2ts](https://github.com/EDIS-mx/rawsendmpeg2ts) — the datagram sender graded in
  the egress-pacer group.

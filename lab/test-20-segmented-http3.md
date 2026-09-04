# T20 — the segmented lane over HTTP/3, and what that does to the reordering result

> **State:** the HTTP/3 acquisition path is built, proven and reproducible, and the substrate-matched
> impairment cells are measured. This closes [P0-2](planned-experiments.md) and answers open question
> 18 in [`docs/evidence.md`](../docs/evidence.md) §5.
>
> **An HTTP/3 HLS client exists now.** FFmpeg master built `--enable-libcurl` against a libcurl with
> ngtcp2/nghttp3 and OpenSSL 3.5 native QUIC fetches an HLS presentation entirely over HTTP/3. The
> origin for the H3 arm has **no TCP listener at all**, so the arm cannot silently complete over
> HTTP/1.1 — it would fail instead — and every request in every H3 run is logged by the origin as
> `HTTP/3.0 alpn=h3`. The route the campaign had written off as blocked is open.
>
> **Getting there found a defect that is itself the point of this experiment.** FFmpeg propagates only
> a fixed whitelist of I/O options from a parent demuxer to its child connections, and `http_version`
> is not on it. Ask for `-http_version 3only` on an HLS URL and the *playlist* is fetched over HTTP/3
> while **every media segment silently opens at HTTP/1.1** — the ALPN on the segment connection reads
> `http/1.1`, and nothing warns. A one-line whitelist addition fixes it (measurement 1). Without that
> patch an "HLS over HTTP/3" experiment carries 100 % of its media bytes over TCP.
>
> **The headline: the segmented lane's reordering advantage does not survive the substrate change, and
> was never a lane property to begin with.** [T5](test-5-network-impairment.md) measured segmented HTTP
> at **0.98** delivered rate under 25 % reordering against MoQ's **0.19**, and that separation is the
> single impairment result on which the paper's reliability verdict turns. Re-run with the packet sizes
> equalised, segmented HTTP over TCP reads **0.44**, segmented HTTP over HTTP/3 reads **0.18**, and MoQ
> reads **0.13**. The lane that was said to be immune to reordering is, on QUIC, within noise of MoQ.
>
> **The mechanism is packet size, and it is measured, not inferred.** T5's rig left loopback at its
> default 65536-byte MTU while correctly disabling GSO on the MoQ arm only. The segmented lane
> therefore moved its media in **1,209 packets averaging 34,380 bytes** where MoQ moved the same media
> in **29,062 packets averaging 931 bytes**. `netem reorder 25 %` reorders a *fraction of packets*, so
> the segmented lane received roughly 24× fewer reordering events. Reproduce T5's conditions here and
> T5's numbers come back exactly — 0.995 segmented against 0.125 MoQ. Equalise the packet sizes and the
> separation collapses. **This was a rig asymmetry wearing a protocol result's name.**
>
> **The substrate change is not uniformly bad for the segmented lane — it is bad only for reordering.**
> Under loss the same change runs strongly the other way: at ~20 % *applied* loss the segmented lane
> reads **0.10 on TCP and 0.70 on HTTP/3**, and under a 30 s total outage **0.51 on TCP against 0.76 on
> HTTP/3**. Moving segmented HTTP onto QUIC costs it the reordering cell and buys it the loss and
> outage cells. No single-sentence verdict survives that, which is the finding.

## Environment

- **One host, all arms.** The EC2 secondary (`<EC2_SECONDARY>`), `c6in.2xlarge`, 8 vCPU / 15 GB,
  Ubuntu 26.04, `eu-west-1b`. Publisher, origin, impairment lane and receiver are all on loopback, so
  the arms share a clock and a shaper and differ only where the experiment intends.
- **Source:** `~/CNNiEMEA2.ts`, 9,945,951 bps CBR, 1080i25 H.264 + MP2 + AC-3 + teletext + 3× SCTE-35.
- **Packager (identical for both HLS arms):**
  `tsp --realtime -I file <src> --infinite -P regulate --pcr-synchronous -O hls --live 6
  --live-extra-segments 3 --duration 2 --intra-close --align-first-segment`.
- **TSDuck** 3.44-4676; **moq** 0.9.15 / **moq-relay** 0.14.14 (`~/bin-3006`).

### The HTTP/3 client, pinned

| Component | Version | Build |
|---|---|---|
| libcurl | 8.18.0 | `--with-openssl --with-ngtcp2 --with-nghttp3 --enable-alt-svc`, prefix `~/h3` |
| QUIC transport | ngtcp2 1.16.0 | Ubuntu 26.04 `libngtcp2-dev` |
| HTTP/3 framing | nghttp3 1.12.0 | Ubuntu 26.04 `libnghttp3-dev` |
| TLS | OpenSSL 3.5.5 | native QUIC interface (`libngtcp2-crypto-ossl`) |
| FFmpeg | master `git-2026-09-03-818e5d9` | `--enable-openssl --enable-libcurl --enable-protocol=libcurl`, `-Wl,-rpath,~/h3/lib`, **plus the patch in measurement 1** |
| Origin | nginx 1.28.3 (Ubuntu, `--with-http_v3_module`) | TLS 1.3, self-signed, two vhosts |

`curl --version` on this build reports
`Features: alt-svc AsynchDNS HSTS HTTP3 HTTPS-proxy IPv6 Largefile libz NTLM PSL SSL threadsafe
TLS-SRP UnixSockets`. **`nghttp2` is deliberately absent**, so the client cannot speak HTTP/2 at all
and "fell back to H2" is not among the ways this experiment can be wrong.

**Route (4) was not needed and is not available.** FFmpeg's native HTTP/3 protocol over
ngtcp2/nghttp3 is proposed in FFmpeg PR #23478 and is **not** in master: `configure` carries no
`--enable-libngtcp2` or `--enable-libnghttp3`, and there is no `libavformat/http3.c`. What master does
carry is `libavformat/libcurl.c` and `--enable-libcurl`, which is route (1), the preferred one.

### The two origins

One nginx, one config, one document root, one set of segment files, two `server` blocks:

- **`:8443`** — `listen 8443 ssl` only, `http2 off`. TCP and TLS 1.3. No QUIC listener.
- **`:8444`** — `listen 8444 quic` only. **No TCP listener of any kind.**

`ss -lntup` shows `tcp 0.0.0.0:8443` and `udp 0.0.0.0:8444` and nothing else, and a deliberate
HTTP/1.1 connection to `:8444` exits 7 (connection refused). The transport is therefore enforced by
the origin, not requested by the client.

## Procedure

`lab/scripts/t20-h3-arm.sh <label> <h1|h3|moq> [window_s]` runs one arm end to end — publisher,
origin, shaped lane, receiver, teardown and grading — inside a single invocation.

```bash
# clean baseline, with a capture
PCAP=1 OUTDIR=~/t20/base t20-h3-arm.sh base h1 60
PCAP=1 OUTDIR=~/t20/base t20-h3-arm.sh base h3 60
PCAP=1 OUTDIR=~/t20/base t20-h3-arm.sh base moq 60

# the P0 cell, and the control that explains T5
IMPAIR="delay 30ms reorder 25% 50%" OUTDIR=~/t20/reorder  t20-h3-arm.sh reorder  h3 60
NORM_LO=0 IMPAIR="delay 30ms reorder 25% 50%" OUTDIR=~/t20/nonorm t20-h3-arm.sh nonorm h3 60

# ladders
IMPAIR="loss 10%"  OUTDIR=~/t20/L10     t20-h3-arm.sh L10     h3 60
OUTAGE_S=30 OUTAGE_AT=15 OUTDIR=~/t20/outage30 t20-h3-arm.sh outage30 h3 75
IMPAIR="rate 20mbit" RATE_BASE=20mbit DIP_RATE=8mbit DIP_S=perm DIP_AT=20 \
  OUTDIR=~/t20/cap_8perm t20-h3-arm.sh cap_8perm h3 90
```

The receiver for both HLS arms is the same binary with one option changed:

```bash
ffmpeg -prefer_libcurl 1 -http_version {1.1|3only} -tls_verify 0 \
       -i https://127.0.0.1:{8443|8444}/index.m3u8 -c copy -f mpegts out.ts
```

**Metric.** `delivered_ratio` = output bytes × 8 ÷ (9,945,951 × window), i.e. T5's "delivered rate
against the fixture's rate, where 1.00 is *kept up*", so the numbers are directly comparable with
T5's table. Ratios slightly above 1.00 at baseline are the HLS client fetching the origin's live
window at join, which every HLS arm does equally.

**Loopback normalisation.** The rig sets `lo` to MTU 1500 and turns TSO/GSO/GRO off before every run,
and restores 65536 afterwards. `NORM_LO=0` reproduces the un-normalised shape T5 measured in, and is
retained only as a control. Why this is not optional is measurement 4.

## Measurements

### 1. FFmpeg asks for HTTP/3 on the playlist and takes HTTP/1.1 for the media

`libavformat/hls.c` populates its child-connection options with `ffio_copy_url_options()`, which
copies a fixed list of option names from the parent:

```text
"headers", "user_agent", "cookies", "http_proxy", "referer", "rw_timeout", "icy", "prefer_libcurl"
```

`prefer_libcurl` is on the list, so segments *are* fetched by libcurl. `http_version` is not, so they
are fetched at libcurl's default version. Observed directly: with `-http_version 3only` set, the
origin logs the playlist as

```text
proto=HTTP/3.0 http3=h3 alpn=h3 status=206 uri=/index.m3u8
```

while FFmpeg's own debug output for the very next segment reads

```text
[libcurl] * ALPN: curl offers http/1.1
[libcurl] * ALPN: server accepted http/1.1
```

`tls_verify` and `ca_file` are also absent from the list, which is what made the defect visible at
all: against a self-signed origin the segment connection fails certificate verification and the run
dies with `Error when loading first segment`. Against a *publicly trusted* origin it would not fail —
it would succeed, over TCP, silently, and be reported as an HTTP/3 measurement.

The fix used here is a three-name addition to that whitelist:

```c
"headers", "user_agent", "cookies", "http_proxy", "referer", "rw_timeout", "icy", "prefer_libcurl",
"http_version", "tls_verify", "ca_file", NULL };
```

**This is the paper's own thesis reproduced inside a tool:** a lane that reports one substrate and
carries another, with no diagnostic anywhere in the path saying so. It is offered upstream — see
[`upstream-contributions.md`](upstream-contributions.md).

### 2. Transport proof

Three independent instruments, none of them the client's own configuration:

| Instrument | H1 arm | H3 arm |
|---|---|---|
| Origin access log, every request | 54/54 `proto=HTTP/1.1 alpn=http/1.1 port=8443` | 54/54 `proto=HTTP/3.0 http3=h3 alpn=h3 port=8444` |
| Packet capture, whole run | **71,389 TCP / 0 UDP** | **109,657 UDP / 0 TCP** |
| Origin listener | `tcp 0.0.0.0:8443` | `udp 0.0.0.0:8444`, **no TCP listener** |

Across every H3 run in this experiment the origin logged **zero** non-HTTP/3 requests. The client
option used is `3only` = `CURL_HTTP_VERSION_3ONLY`, which does not fall back; the build cannot speak
HTTP/2; and the origin would refuse a TCP connection if it tried. Fallback is excluded by the client,
by the build and by the server independently.

### 3. Clean baseline — the two transports are indistinguishable

60 s window, no impairment, normalised loopback:

| Arm | Bytes | Delivered ratio | Requests | Media span | md5 |
|---|---|---|---|---|---|
| HLS / HTTP/1.1 / TCP | 77,026,984 | 1.033 | 54 | 66.5 s | `7f3402ea…` |
| HLS / HTTP/3 / QUIC | 77,026,984 | 1.033 | 54 | 66.5 s | `7f3402ea…` |
| MoQ / QUIC | 55,225,000 (45 s) | 0.987 | — | 46.2 s | — |

**The two HLS arms produce byte-identical output.** Same md5, same length, same request count. Under
no impairment the substrate change is invisible at the media plane, which is the precondition the rest
of the experiment needs.

MoQ's PCR reads max 25.00 ms and 0 % above the 40 ms gate; the HLS arms read max 80.00 ms and ~95 %
above it. **That is not a transport result** — see the limits below.

### 4. Reordering (P0) — and the control that reinterprets T5

`netem delay 30ms reorder 25% 50%`, 60 s windows, three replicates:

| Arm | Replicate a | b | c | Mean |
|---|---|---|---|---|
| HLS / HTTP/1.1 / TCP | 0.415 | 0.483 | 0.429 | **0.44** |
| HLS / HTTP/3 / QUIC | 0.172 | 0.177 | 0.178 | **0.18** |
| MoQ / QUIC | 0.121 | 0.079 | 0.180 | **0.13** |

The H3 arm is the tightest of the three (0.172–0.178). The MoQ arm is the noisiest and its spread
overlaps the H3 arm's, so **HLS/H3 and MoQ are not separated by this cell**; HLS/TCP is separated
from both.

**The control.** The same three cells with loopback left at its default 65536 MTU and offloads on —
the shape [T5](test-5-network-impairment.md) measured in:

| Arm | Normalised (MTU 1500) | Un-normalised (MTU 65536) | T5's published figure |
|---|---|---|---|
| HLS / HTTP/1.1 / TCP | 0.44 | **0.995** | 0.981 |
| HLS / HTTP/3 / QUIC | 0.18 | **0.995** | — |
| MoQ / QUIC | 0.13 | **0.125** | 0.192 |

T5 reproduces. The segmented lane reads 0.995 against MoQ's 0.125, which is T5's 0.981 against 0.192
within run-to-run spread. **The result is real; its interpretation was wrong.**

**Why.** Packet sizes on the wire, measured from captures of those same runs:

| Arm | MTU 65536 (T5's shape) | MTU 1500 (normalised) |
|---|---|---|
| HLS / TCP | 1,209 pkts, **avg 34,380 B**, max 65,483, 60.4 % over 1500 B | 71,389 pkts, avg 1,163 B, max 1,448 |
| HLS / QUIC | 2,682 pkts, avg 15,338 B, max 65,500, 26.9 % over 1500 B | 109,657 pkts, avg 803 B, max 2,400 |
| MoQ / QUIC | 29,062 pkts, **avg 931 B**, max 1,200, **0 %** over 1500 B | — |

`netem`'s `reorder` is a per-packet probability. In T5's rig the segmented lane carried its media in
**24× fewer packets** than MoQ, so the same "25 %" was a 24×-weaker impairment on the lane that won.
MoQ was the only arm with segmentation offload disabled — a correct fix, applied to one arm — and
that is precisely what created the asymmetry.

### 5. Loss ladder — compare at *applied* loss, not commanded

`netem loss X%`, 60 s. The commanded figure is not the delivered one, and the error is
transport-dependent, so the shaper's own counters are reported alongside (T5's rule):

| Commanded | Arm | Applied | Delivered ratio |
|---|---|---|---|
| 1 % | H1 / H3 / MoQ | 0.16 % / 1.02 % / 0.96 % | 0.995 / 0.995 / 0.984 |
| 3 % | H1 / H3 / MoQ | 0.46 % / 2.92 % / 3.12 % | 0.995 / 0.995 / 0.984 |
| 5 % | H1 / H3 / MoQ | 0.97 % / 4.94 % / 4.95 % | 0.995 / 0.995 / 0.984 |
| 10 % | H1 / H3 / MoQ | 2.75 % / 10.3 % / 10.0 % | 1.020 / 0.995 / 0.984 |
| 20 % | H1 / H3 / MoQ | 19.0 % / 20.0 % / 20.2 % | **0.096** / **0.703** / **0.984** |

**The TCP arm receives a fraction of the loss it is commanded** — 0.16 % against a commanded 1 %,
where both QUIC arms receive ~1.0 % from the identical qdisc. GSO is verifiably off on `lo` for every
run, so this is not the offload artefact of measurement 4; it is a second, independent way in which a
per-packet shaper does not treat the two transports alike. Every comparison below is read at matched
*applied* loss.

Up to ~10 % applied, nothing separates the arms: loopback has roughly a thousand times the headroom
the 9.95 Mb/s media needs, so retransmission absorbs the loss invisibly. **The cell only discriminates
at ~20 % applied**, and there the ranking is the reverse of the reordering cell: MoQ 0.98, segmented
over HTTP/3 0.70, segmented over TCP 0.10.

### 6. Total outage — 500 ms, 5 s, 30 s

The shaped band is taken to `loss 100%` 15 s into a 75 s window and then restored, so the arm must
re-establish delivery inside the measured window. Ideal recovery from a 30 s outage in a 75 s window
is 0.60 if nothing is made up, and above 0.60 if backlog is recovered.

| Outage | HLS / TCP | HLS / HTTP/3 | MoQ / QUIC |
|---|---|---|---|
| 500 ms | 1.006 | 1.006 | 0.980 |
| 5 s | 0.995 | 0.974 | 0.928 |
| 30 s | **0.507** | **0.764** | 0.596 |

A 500 ms outage is invisible to all three and a 5 s outage nearly so. At 30 s the arms separate and
the ordering is again not the reordering ordering: the segmented lane over HTTP/3 recovers **more than
the outage cost it** (0.764 against the 0.60 floor), because the origin's live window still holds the
segments it missed and it fetches them back. The same lane over TCP delivers **less** than the floor
(0.507). MoQ lands at 0.596 — the floor almost exactly — which is what a live-edge transport with no
back-catalogue should do, and its output carries a single 28,725 ms PCR gap that is the outage itself,
cleanly bounded.

**This is the segmented lane's structural advantage showing up where it should:** addressable, retained
objects let a client recover content after the fact. It is visible here only because the metric is
content delivered rather than session recovered.

### 7. Capacity degradation

Lane provisioned at 20 Mb/s, i.e. ~2× the 9.95 Mb/s media rate, then degraded 20 s into the window.

| Scenario | HLS / TCP | HLS / HTTP/3 | MoQ / QUIC |
|---|---|---|---|
| 20 Mb/s throughout (control) | 1.006 | 1.006 | 0.980 |
| 20 → 8 Mb/s for 5 s | 0.997 | 0.989 | 0.969 |
| 20 → 12 Mb/s for 60 s | 0.977 | 0.977 | 0.975 |
| 20 → 8 Mb/s **permanently** | **0.808** | **0.789** | **0.456** |

The two transient degradations are absorbed by every arm: a 5 s dip below the media rate is covered by
buffer, and 12 Mb/s for 60 s is still above the 9.95 Mb/s the stream needs, so it is not a shortfall at
all. **The substrate makes no difference in any capacity cell** — the two HLS arms are within 0.02 of
each other throughout.

The architectures separate only under *sustained* insufficiency. With the lane held at 8 Mb/s against a
9.95 Mb/s stream for the last 70 s of a 90 s window, the arithmetic ceiling is about **0.85** of source.
Both segmented arms land just under it (0.808 / 0.789), i.e. they deliver very nearly everything the
reduced pipe can carry and take the shortfall as growing lateness. MoQ delivers **0.456** — roughly half
of what the same pipe carried for the segmented arms — because it discards groups that miss the
subscriber's release deadline rather than falling behind, which is the deadline-shedding behaviour
characterised in [T8b](test-8b-congestion-control.md) C3.

**For permanent primary distribution this is the sharper of the two behaviours to know about.** Under a
lasting capacity shortfall the segmented lane loses nothing it can still fetch and degrades into
lateness; the media-aware lane holds its latency and throws programme away. Which is preferable is a
policy choice, but it is a choice, and it is not visible in any cell where capacity is adequate.

### 8. HTTP/3 connection and stream behaviour

From the baseline captures and origin logs:

- **One QUIC connection for the whole session.** All 54 requests of the 60 s H3 run — 26 playlist
  reloads and 28 segment fetches — are carried on a single client UDP 4-tuple. libcurl's connection
  pool holds it open; there is no per-segment connection setup. The H1 arm likewise uses one TCP
  connection via keep-alive.
- **Segment fetches are sequential, not concurrent.** The FFmpeg HLS demuxer holds at most one segment
  request in flight, so the origin sees ~2 requests per second (one playlist reload, one segment) with
  occasional 3–4 request seconds at the join.
- **The consequence for primary distribution is the important part.** QUIC's per-stream head-of-line
  independence can only help a client that has more than one stream outstanding. This client never
  does, so on the segment path HTTP/3 delivers no multiplexing benefit and inherits QUIC's
  loss/reordering recovery behaviour without the structural advantage that usually offsets it. That is
  consistent with the reordering result: a reordered packet stalls the one segment in flight, and the
  next request has not been issued yet.

## Conclusions

1. **HLS over HTTP/3 is now experimentally reachable**, with FFmpeg + libcurl + ngtcp2/nghttp3, and
   the configuration is pinned above. The campaign's previous "HTTP/3 is not reachable from a client
   here" limit is retired.
2. **The reordering advantage of segmented HTTP is not a lane property.** It reproduces only when the
   segmented lane is given packets ~24× larger than the lane it is compared against. Equalised, it
   falls from 0.98 to 0.44 on TCP and to 0.18 on HTTP/3, against MoQ's 0.13.
3. **On HTTP/3, segmented HTTP and MoQ are not separated by reordering at all.** Their spreads
   overlap. The one impairment axis that was said to separate the two data planes does not, once both
   are on QUIC.
4. **The substrate change is a trade, not an upgrade.** Segmented HTTP loses the reordering cell by
   moving to QUIC and wins the loss cell (0.10 → 0.70 at ~20 % applied) and the 30 s outage cell
   (0.51 → 0.76).
5. **Under no impairment the substrate is invisible** — byte-identical output — so nothing in carriage
   or timing fidelity turns on it.
6. **A single-connection, sequential-fetch HLS client gets no multiplexing benefit from HTTP/3.** Any
   argument for HTTP/3 on the segment path that rests on stream independence needs a client that keeps
   several segments outstanding, which this one does not.

## Limits

- **The HLS arms' CC and PCR columns grade the receiver, not the wire.** `ffmpeg -c copy -f mpegts`
  re-muxes: it regenerates continuity counters and re-times PCR. `cc_errors=0` on those arms is true
  by construction and is **not** evidence about transport integrity, and their PCR distribution
  (max 80 ms, ~95 % above the 40 ms gate) is a property of FFmpeg's mpegts muxer, identical on both
  arms. The byte-faithful `tsp -I hls` receiver used in [T14](test-14-data-plane-comparison.md) cannot
  negotiate HTTP/3, so this experiment trades carriage fidelity for substrate reach. **A byte-faithful
  H3 receiver is the obvious next instrument** and is not yet built. Only the MoQ arm's PCR figures
  here are wire-domain.
- **A per-packet impairment is not a per-byte impairment, even normalised.** At MTU 1500 the QUIC
  arm still sends ~1.5× the packets of the TCP arm for the same media (109,657 against 71,389), so at
  a fixed per-packet reorder probability it takes ~1.5× the events. That residual runs against the
  QUIC arms and is not removed by anything in this rig. It is far smaller than the 24× of T5's shape,
  but the reordering figures should be read as "same shaper setting", not "same impairment".
- **Loopback.** No RTT, and ~1000× headroom over the media rate, which is why the loss ladder is flat
  below 20 %. These are loopback constants, as T5's were.
- **Replicates.** Three on the reordering cell; one on each loss, outage and capacity cell.
- **The FFmpeg patch is local and unmerged.** Reproducing this needs it (measurement 1).

## Corrections

**Believed:** segmented HTTP's resistance to reordering was a property of the lane — bounded,
independently addressable objects retried over a fresh request — and would survive a change of
substrate, so the only open question was whether HTTP/3 would preserve the 0.98.

**True:** it was a property of the *packet size the rig gave it*. T5 disabled segmentation offload on
the MoQ arm, correctly, and left the segmented arm on 65536-byte loopback packets, so the two arms met
`reorder 25 %` with a 24× difference in the number of packets exposed to it. Equalise them and the
advantage largely disappears on TCP and entirely disappears on QUIC.

**Method rule:** *an impairment specified per packet is only comparable across two lanes if the lanes
carry the same media in comparable packets — normalise MTU and offloads on every arm, and report the
measured packet-size distribution alongside any per-packet impairment result.* A fix applied to one
arm because that arm needed it is itself an asymmetry.

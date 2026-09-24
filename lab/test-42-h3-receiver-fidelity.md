# Test 42 — A byte-faithful HTTP/3 HLS receiver, and what the previous one was grading

**State: built and validated for byte fidelity and for timing; P0-e is closed.** The campaign now has an HLS receiver that both
negotiates HTTP/3 and reproduces the packager's bytes exactly
([`hls-verbatim-recv.py`](scripts/hls-verbatim-recv.py)). Over both HTTP/1.1 and HTTP/3 its output is
**byte-identical** to the origin's own segment files — the same SHA-256 that `tsp -I hls`
independently produces, so the check is not self-fulfilling.

The receiver it replaces, `ffmpeg -c copy -f mpegts`, does not reproduce the wire and **reports a
clean carriage grade on a stream that is not clean**: given an origin with 10 deliberately excised
transport packets, it reported **0 continuity events and 0 missing packets** where the origin, this
receiver and `tsp` all reported **2 events and 10 missing packets**. Every continuity and PCR figure
previously taken through that receiver on the H3 and H1 arms was therefore measuring the receiver.
The `cc_errors=0` recorded there was not a weak result; it was a constant.

## Objective

[T20](test-20-segmented-http3.md) compares MoQ against HLS over HTTP/3 and HTTP/1.1, and its two HLS
arms were graded through `ffmpeg -c copy -f mpegts` because that is the only client in the lab that
could reach an H3 origin: `tsp -I hls` is byte-faithful but speaks HTTP/1.1 only. `ffmpeg -c copy`
copies *elementary streams*, not the transport layer — it demultiplexes and re-multiplexes — so the
continuity counters and PCR values it emits are its own. The lane could be graded on delivery but not
on carriage, which is the half that matters for the requirement set.

That gap is **P0-e** in [`planned-experiments.md`](planned-experiments.md): a build task rather than
an experiment, and the instrument that the segmented halves of P0-f, P2-b and T32 were waiting on.
The objective here is the instrument plus enough validation to trust it, and — because it is cheap
once the instrument exists — a measurement of how much of the previous carriage grade was the
receiver's work.

## Environment

| | |
|---|---|
| Host | Secondary, 8 vCPU / 15.7 GB, Ubuntu 26.04, `eu-west-1b` |
| Origin | nginx, existing T20 `h3lab` vhosts — `:8443` TLS/TCP with **no QUIC listener**, `:8444` QUIC with **no TCP listener** |
| Packager | `tsp -O hls`, VOD (no `--live`), `--duration 2 --intra-close --align-first-segment` |
| Source | `clip30.ts`, the leading ~30 s of `CNNiEMEA2.ts`; 13 segments, 193,057 packets |
| Transport | `curl` built against ngtcp2/nghttp3 (`~/h3/bin/curl`), `--http3-only` on the H3 arm |
| Comparators | `tsp` 3.44-4676; `ffmpeg` built `--enable-libcurl` (`~/h3/bin/ffmpeg`) |
| Rigs | [`p0e-validate-receiver.sh`](scripts/p0e-validate-receiver.sh), [`p0e-launder-test.sh`](scripts/p0e-launder-test.sh) |
| Domain | **file**, at **P2**; the fixture is VOD, so the segment set is deterministic |

The fixture is deliberately **VOD rather than live**. A finite playlist carrying `#EXT-X-ENDLIST`
fixes the segment set, so a hash mismatch is a receiver defect and never a race against a rolling
live window. Byte fidelity is a property of the receiver, not of the schedule, so nothing is lost by
removing the race from the measurement.

## What the instrument does, and why it is this small

For TS-in-HLS, byte-faithful reception needs no transport-stream code at all. A segment is a whole
number of 188-byte packets, so fetching each segment in playlist order and concatenating the bytes
**reconstructs exactly what the packager emitted**, continuity counters and PCR values included. The
receiver therefore does not demultiplex, re-stamp, re-time, reorder or synthesise a table, and the
absence of that machinery is the correctness argument rather than a limitation.

Transport is delegated to `curl` because the lab already had one built against ngtcp2/nghttp3, and
writing an HTTP/3 stack to move bytes would have been the wrong work. The H3 arm passes
`--http3-only`, so an arm that cannot negotiate QUIC **fails rather than silently falling back to
TCP** and measuring the wrong substrate.

What makes it an instrument rather than a downloader is that it is loud about everything it could not
carry, because in this application every failure mode otherwise looks like clean output. A segment
that 404s, times out, or rolls out of the live window before it is fetched leaves a **hole**;
concatenating across one produces counter jumps that grade as a wire defect when they are a receiver
defect. Holes are counted, reported, and set `byte_faithful: false` in the JSON summary with a
non-zero exit — **a run reporting any hole is void for carriage grading**. A playlist carrying
`#EXT-X-MAP` is refused outright, since it is fMP4 and verbatim concatenation is meaningless there;
so is a segment that is not a whole number of packets or lacks the `0x47` sync byte.

## Results

### The receiver reproduces the origin's bytes, over both substrates

Ground truth is the packager's own output: the segment files on disk, concatenated in playlist
order. No reference implementation is needed, because the origin *is* the reference.

| Receiver | Transport | Bytes | SHA-256 | Equals origin? |
|---|---|---|---|---|
| origin (`tsp -O hls` on disk) | — | 36,294,716 | `c53b8199…3e3969` | ground truth |
| `hls-verbatim-recv.py` | HTTP/1.1 | 36,294,716 | `c53b8199…3e3969` | **yes** |
| `hls-verbatim-recv.py` | HTTP/3 | 36,294,716 | `c53b8199…3e3969` | **yes** |
| `tsp -I hls` | HTTP/1.1 | 36,294,716 | `c53b8199…3e3969` | **yes** |
| `ffmpeg -c copy -f mpegts` | HTTP/3 | 34,670,396 | `1408c856…467456` | **no**, 1,624,320 bytes short |

The `tsp` row is the one that makes the rest trustworthy. An independent byte-faithful
implementation reaching the same hash shows the comparison can be passed by something other than the
code under test; the `ffmpeg` row shows it can be failed. Both are needed — a check that only ever
passes measures nothing.

Eight validation arms pass, the four negative controls among them: a single flipped byte in one
segment changes the output hash; `--http-version 3` against the TCP-only vhost fails instead of
falling back; an `#EXT-X-MAP` playlist is refused; and a segment removed from the origin is reported
as a hole with a non-zero exit rather than concatenated over.

### On a damaged origin, the previous receiver reports a clean stream

The fidelity table shows the receivers differ. It does not show that the difference changes a
*grade*, because that fixture is clean at the origin and so every arm scores zero — and zero is
uninformative. To decide it, 10 packets were excised from the middle of one segment on a 188-byte
boundary, which is the shape of a real carriage loss and leaves the file packet-aligned. The origin
then has a known, non-zero continuity error count, and the question becomes whether a receiver
*reports* the damage or *repairs* it before grading.

| Receiver | Transport | Bytes | Continuity events | Packets missing | |
|---|---|---|---|---|---|
| origin (packager) | — | 36,292,836 | 2 | 10 | ground truth |
| `hls-verbatim-recv.py` | HTTP/1.1 | 36,292,836 | 2 | 10 | byte-identical; grades the wire |
| `hls-verbatim-recv.py` | HTTP/3 | 36,292,836 | 2 | 10 | byte-identical; grades the wire |
| `tsp -I hls` | HTTP/1.1 | 36,292,836 | 2 | 10 | byte-identical; grades the wire |
| `ffmpeg -c copy -f mpegts` | HTTP/3 | 34,668,516 | **0** | **0** | **hides 10 of 10 lost packets** |

One excision produced two events because the excised run straddled two PIDs — 9 packets on PID 111
and 1 on PID 121 — which is why both the event count and the total packets missing are reported.

This is the result that closes the evaluation point. The `cc_errors=0` previously recorded on the H3
and H1 arms did not survive a test; it was unable to fail.

### What the re-mux actually changes

The 4.5 % byte difference is not a partial download, and the damage is not confined to continuity
counters. Comparing the PID tables of the same origin bytes received both ways:

| | Origin / verbatim receiver | Through `ffmpeg -c copy` |
|---|---|---|
| PIDs present | 0, 16, 17, 20, 100, 111, 121, 123, 131, 141, 142, 143, 8191 | 0, 17, 256, 257, 258, 259, 260, 261, 262, 4096 |
| Video PID | 111 (175,207 packets) | 256 (175,172 packets) |
| PMT PID | 100 (247 packets) | 4096 (285 packets) |
| NIT (PID 16) | 6 packets | **absent** |
| TDT/TOT (PID 20) | 2 packets | **absent** |
| Null packets (PID 8191) | 8,733 | **absent** |
| Total | 193,057 packets | 184,417 packets |

Every PID is renumbered, so any PID-referenced claim taken through this receiver is void. The NIT
and the TDT/TOT are dropped entirely, which removes two of the tables the carriage work grades.
Stuffing is discarded, which means the emitted bitrate is the muxer's choice rather than the
origin's — and discarding 8,733 nulls more than accounts for the 8,640-packet shortfall, so the
re-mux is a net **addition** of 93 packets once stuffing is set aside — the regenerated PAT (247 →
285), PMT (247 → 285) and PID 17 (28 → 60) add 108 between them, against 8 lost with the NIT and
TDT/TOT and 7 net across the elementary streams.

Per-stream counts move in **both** directions, one audio stream losing 45 packets while another
gains 73, which is the signature of re-multiplexing rather than of loss. Matching origin streams to
their renumbered counterparts by packet count — the counts are distinctive enough to make the
mapping unambiguous here, though it is an inference and not read from the PMT — also shows the
**stream order changes**: PID 131 sorts before 141–143 at the origin, while the 730-packet stream it
becomes sorts after theirs.

On the clean fixture `ffmpeg` also logged `corrupt input packet in stream 2` against bytes that two
independent byte-faithful receivers reproduce exactly. The complaint describes its own parsing, not
the origin.

### What the receiver costs in time, and where it — or its origin — becomes the bottleneck

Measured with [`t20-recv-timing.sh`](scripts/t20-recv-timing.sh) on T20's loopback H3 arm, and in
the T8b namespace rig for the last two rows; live `tsp -O hls`, 2 s target segments of ~3 MB, 60 s
windows, one sample per cell. Fetch and lag exclude the first reload, which takes the whole live
window at once and so measures the join, not the lane. Lag is the time from the segment file's last
write at the origin to its arrival at the receiver.

| Path | Origin buffer | Receiver | Segments | Holes | Fetch p50 / p95 | Lag p50 / p95 / max |
|---|---|---|---:|---:|---|---|
| loopback, no delay | 64k default | curl per cycle | 27 | 0 | 13 / 21 ms | 0.52 / 0.93 / 1.06 s |
| loopback, 100 ms RTT, no rate limit | 64k default | curl per cycle | 13 | 3, exit 1 | 4.5–5.3 s per segment | — |
| loopback, 100 ms RTT, no rate limit | 16m | curl per cycle | 27 | 0 | 1.34 / 2.41 s | 2.23 / 3.41 / 4.04 s |
| netns, `cake` 20 Mb/s, 100 ms RTT | 16m | curl per cycle | — | 404 on the control | ~2.1 s for one 3 MB object ¹ | — |
| netns, `cake` 20 Mb/s, 100 ms RTT | 16m | one connection | 29 | 0 | 1.56 / 2.38 s | 2.53 / 6.90 / 8.54 s |

¹ From [`t31-origin-window.sh`](scripts/t31-origin-window.sh): 0.21 s to first byte and 1.87 s in
total on a fresh connection, against a ~2.46 s segment period that also has to carry a two-round-trip
playlist fetch.

**Three findings, in the order a rig meets them.**

**1. With nginx's defaults the origin, not the lane, is the bottleneck at 100 ms RTT.**
`http3_stream_buffer_size` defaults to 64k, and a stream then carries about 64 KB per round trip:
4.57–4.89 Mb/s at 100 ms whether the bottleneck is 20 or 1,000 Mb/s, against 11.95–12.85 Mb/s through
the 20 Mb/s bottleneck at 256k, 1m and 16m (eight of nine fetches; one at 1m read 9.68), and 23.6 Mb/s
at 16m through 1,000 Mb/s — three fetches of one 3 MB object per setting, each from slow start. The stream is
~10 Mb/s, so every segmented cell at that RTT measured the origin's buffer. At loopback's near-zero
RTT the same window is never reached, which is why no earlier loopback cell showed it. The lab's
`h3lab` vhost and the namespace origin both now set 16m.

**2. A receiver that reconnects every cycle falls behind a live window that a player would hold.**
The receiver spawns `curl` twice a reload cycle, so each playlist and each batch opens a new QUIC
connection and restarts slow start. On loopback that costs 7.8 ms a playlist and 2.8 ms a handshake,
which is nothing against the reload period. Behind 20 Mb/s at 100 ms RTT it costs more than a segment's
period: the control cell fell behind until the origin evicted a segment it had not fetched. Held on
one connection (`--libcurl`, the same curl 8.18 / ngtcp2 library loaded in-process), the same control
fetched 70 requests over **one** connection with 0 holes. The per-cycle design is kept for loopback,
where it is measured to be harmless, and the namespace rig uses one connection.

**3. Lag through this receiver is dominated by its reload period, not by its fetch.** Reloads come
every half target duration, so a segment waits up to ~1 s after it appears even where the fetch takes
13 ms: the unimpaired loopback lag of 0.52 s median is almost entirely that quantisation. A latency
figure taken through the receiver carries up to one reload period of its own, and on the namespace rig
its tail (6.9 s p95) is also the fetch competing with the next segment. This is a floor on what the
instrument can resolve, not a property of the lane, and it applies to delivery-latency figures only:
loss and conservation grades close the window long after the lag has settled.

**The per-fetch timeout is per transfer, and binds only when one segment takes longer than it.**
`--timeout` is curl's `--max-time`, which curl applies to each transfer rather than to the invocation:
at 15 s, batches of six segments ran 19.4 s with curl exiting 0. With ~3–3.7 MB segments a 15 s timeout
binds only where one segment's goodput falls below ~2 Mb/s:

| Cell (loopback, one sample each) | 4 s | 15 s | 60 s | 15 s, truncation as hole |
|---|---|---|---|---|
| 0.8× permanent shortfall (7.96 Mb/s) | exit 1 at segment 19 (3.67 MB) | 32 segments, 0 holes, 0.873 | identical | identical |
| 10 % loss | 27 segments, 0 holes | identical | identical | identical |

At 0.8× a 3.67 MB segment needs 3.7 s at the bottleneck rate plus queueing, which a 4 s timeout
truncates; at 15 s nothing does, and the lane's lag grows to 21.2 s by window close with every segment
delivered. The cells that do depend on the timeout are those that push one segment's goodput below
`segment bytes / timeout`: 25 % reorder, and HTTP/1.1 at 20 % loss
([method-notes](method-notes.md) § *A receiver's per-fetch timeout is a measurement parameter*).

## What this does not show

- **Timing is characterised on one host, one sample per cell.** The reload-period floor and the
  two bottlenecks above are mechanisms and should transfer; the specific lags are loopback and
  namespace figures, not cross-host ones. The one-connection mode has been run on the namespace rig
  only, and its byte fidelity rests on the same concatenation code rather than on a repeat of the
  hash arms.
- **TCP through the namespace rig's `cake` is unexplained.** In the same diagnostic, HTTP/1.1 over TCP
  fetched the 3 MB object at 4.15 Mb/s through the 20 Mb/s bottleneck (three fetches, identical) and at
  21.5–23.7 Mb/s through 1,000 Mb/s, where HTTP/3 at 16m managed ~12.8 and ~23.6. No campaign lane runs
  TCP in that rig today; one that does has to resolve this first — a TCP bulk transfer through the rig
  with `ss -i` on the sender would show whether it is the congestion window, the pacing or the qdisc.
- **The measurements here are `file`-domain at P2**, taken against a VOD fixture on one host with the
  origin and receiver co-resident. They establish what each receiver does to bytes. They are not
  cross-host delivery measurements and carry none of T20's substrate comparison.
- **T20's delivery figures are unaffected.** The re-mux corrupts carriage grading, not arrival
  timing; nothing here revises a latency or throughput number. What it invalidates is the continuity
  and PCR half of the H3 and H1 arms, which the source already labelled as receiver-graded.
- **No live-window arm was run.** Hole detection is validated by removing a segment from a VOD
  origin, which exercises the same code path as a live roll-off but not the timing race that produces
  one in practice.
- **Only TS-in-HLS is in scope.** fMP4 is refused rather than handled, which is correct for this
  campaign and a real limit for any other use.
- **One sample per arm.** The quantities measured are deterministic functions of the bytes — hashes
  and counter arithmetic — so replication would test the host, not the receiver.

## Corrections

**A grader whose pattern does not match its tool's wording scores every input clean.** The first
version of the laundering rig counted `tsp -P continuity` lines matching `discontinuity`. The plugin
writes `* continuity: … missing 9 packets`, so the count was always zero and the rig reported a
known-damaged origin as having no continuity errors — then correctly aborted, because it checks that
the origin's damage is visible before trusting any arm. That guard is the only reason the error
surfaced as a `FATAL` rather than as a published finding that `ffmpeg` and the verbatim receiver
agree. The method rule is in [`method-notes.md`](method-notes.md): a grader must be shown to detect
known damage in the same run that uses it, not in a separate exercise.

**`tsp -I hls` rejects a self-signed origin and does not honour `CURL_CA_BUNDLE`.** It has no
`--insecure`, so the comparator arm failed on certificate verification alone and initially looked
like an inability to read the playlist. The lab certificate has to be in the system trust store. This
is an environment fact, recorded in `INSTRUCTIONS.local.md`.

**`ffmpeg` needs `-prefer_libcurl 1` and the `3only` spelling.** `-http_version 3` is rejected by the
native `https` handler with `Error setting option http_version to value 3`; HTTP/3 in this build
comes from the libcurl handler, which the T20 rig selects explicitly. An arm that omits it does not
fall back to TCP — it fails to open the input at all.

# Getting Started: One Transport Stream, End to End

Status: working draft. Layer: hands-on. Scope: three recipes on one machine, with released tools. Reads with: [Primer](primer.md), for how the transports work, and [Comparison](comparison.md), for how they compare.

**Contents**

- [In brief](#in-brief)
- [What you need](#what-you-need)
- [Recipe 1: MoQ](#recipe-1-moq)
- [Recipe 2: Segmented HTTP](#recipe-2-segmented-http)
- [Recipe 3: Multicast to an IRD](#recipe-3-multicast-to-an-ird)
- [What the recipes show](#what-the-recipes-show)
- [Limits](#limits)

## In brief

**Over MoQ and over segmented HTTP, released tools carry one transport stream from publisher to subscriber with its service intact** ([Recipe 1](#recipe-1-moq), [Recipe 2](#recipe-2-segmented-http)), **and a pacer turns either subscriber's output into a constant-rate multicast feed an IRD can read** ([Recipe 3](#recipe-3-multicast-to-an-ird)). The recipes show each path working; they measure nothing ([Limits](#limits)).

## What you need

**Tested on macOS with these versions, and Recipe 3's multicast commands on Linux with TSDuck 3.44:**

| Tool | Version | For |
| --- | --- | --- |
| `moq` (crate `moq-cli`) and `moq-relay` | 0.14.12 and 0.17.12 | the MoQ publisher, subscriber and relay |
| `mpegts-pacer` | 0.1.1 | pacing the subscriber's output for an IRD (Recipe 3) |
| TSDuck (`tsp`) | 3.45 | pacing the source, HLS packaging and receiving, the checks |
| FFmpeg | 9.0 | generating the fixture |
| Python 3 | any recent | a static HTTP origin |

With a Rust toolchain installed, the MoQ tools and the pacer build in a few minutes:

```bash
cargo install --locked moq-cli@0.14.12 moq-relay@0.17.12
cargo install --locked --git https://github.com/tdrapier-wbd/mpegts-pacer --tag v0.1.1 mpegts-pacer
```

Every command below runs in `/tmp/gs`. From the root of this repository:

```bash
export REPO=$PWD
mkdir -p /tmp/gs && cd /tmp/gs
"$REPO/lab/interop/make-fixture.sh" fixture.ts
```

The fixture is synthetic: 20 s of one service with one video and one audio stream at a constant 2 Mb/s. The checker, `lab/interop/validate-ts.sh`, reads only TSDuck's analysis of the two files: continuity counters, sync bytes, transport errors, PAT and PMT, and the service and elementary-stream inventory against the source ([`lab/interop`](../lab/interop/README.md) explains why that is enough to detect loss).

Open three terminals, each with `REPO` exported and in `/tmp/gs`.

## Recipe 1: MoQ

**Terminal 1, the relay.** It generates a self-signed certificate for `localhost` and lets any anonymous session publish and subscribe on any path, so keep it to a test machine:

```bash
moq-relay --listen '[::]:4443' --listen-tls-generate localhost --auth-public '**'
```

**Terminal 2, the subscriber.** It waits for the broadcast `demo`, writes it out as a transport stream, and exits when the broadcast ends:

```bash
moq --connect https://localhost:4443/anon --connect-tls-insecure \
  export --broadcast demo ts > received-moq.ts
```

**Terminal 3, the publisher.** `regulate --pcr-synchronous` releases the file at the pace of its own programme clock, as an encoder would; without it the whole file arrives in a burst:

```bash
tsp -I file fixture.ts -P regulate --pcr-synchronous -O file \
  | moq --connect https://localhost:4443/anon --connect-tls-insecure import --broadcast demo ts
```

After 20 s both clients exit. `--connect-tls-insecure` skips certificate verification, which suits a self-signed relay on this machine and nothing else.

**Check:**

```bash
"$REPO/lab/interop/validate-ts.sh" received-moq.ts --reference fixture.ts
```

Expect every `CHECK` line `pass` and a final `RESULT pass`. The `byte-identical` line is `info` and reports a smaller file: the released client carries the elementary streams, not the source's packets, and the subscriber builds a new multiplex without the source's null stuffing ([Primer](primer.md) §4).

Stop the relay with Ctrl-C.

## Recipe 2: Segmented HTTP

**Terminal 1, the origin.** Any static HTTP server will do:

```bash
mkdir -p hls && cd hls && python3 -m http.server 8080 --bind 127.0.0.1
```

**Terminal 2, the packager.** It paces the source as before and cuts it into 2 s segments behind a live playlist of the latest twelve, more than the fixture's ten, so no segment leaves the playlist before the receiver reads it; at the end of the input it marks the playlist ended:

```bash
tsp -I file fixture.ts -P regulate --pcr-synchronous \
  -O hls hls/seg.ts --playlist hls/index.m3u8 --duration 2 --live 12
```

**Terminal 3, the receiver.** Start it once `hls/index.m3u8` exists, a few seconds in; it follows the playlist from its first segment and exits at its end:

```bash
tsp -I hls http://127.0.0.1:8080/index.m3u8 -O file received-hls.ts
```

TSDuck 3.45 prints `Error: hls: no URL specified` after the last segment; its exit status is still 0, and every segment has been fetched.

**Check:**

```bash
"$REPO/lab/interop/validate-ts.sh" received-hls.ts --reference fixture.ts
```

Expect `RESULT pass` again. This time the `byte-identical` line reports a slightly larger file: the packager starts each segment with a PAT and a PMT so that it can be decoded on its own ([Comparison](comparison.md) §2). Joined back together, the segments carry the source's own packets.

Stop the origin with Ctrl-C.

## Recipe 3: Multicast to an IRD

**A live source usually arrives as UDP or RTP multicast, and an IRD expects the same: a constant mux rate, with every PCR on time.** Neither subscriber's output arrives like that, so it goes through `mpegts-pacer`, which holds a cushion, pads to a constant rate and restamps each PCR from its byte position.

The groups here are in 239.255.0.0/16 on this machine, and loopback carries multicast only with a route. On macOS (remove it afterwards with `delete` in place of `add`), or on Linux (with `del` and `multicast off`):

```bash
sudo route -n add -net 239.255.0.0/16 -interface lo0                         # macOS
sudo ip link set lo multicast on && sudo ip route add 239.255.0.0/16 dev lo  # Linux
```

With a real feed, use its group and port, the address of the interface that receives it in place of `127.0.0.1`, its mux rate in place of `2000000`, and a route for the output group through the interface that faces the IRD.

Take one path at a time, with Recipe 1's relay or Recipe 2's origin running again (after `rm -f hls/*`), and start each command below in its own terminal, in order. First the check, which waits for the output group, records 15 s of it and grades the recording:

```bash
tsp -I ip 239.255.1.2:5000 --local-address 127.0.0.1 -P until --seconds 15 \
  -P pcrverify --absolute --jitter-max 13 -O file out.ts
python3 "$REPO/lab/scripts/ts-pcr-timing.py" out.ts
"$REPO/lab/interop/validate-ts.sh" out.ts
```

**MoQ.** The publisher reads the feed in place of the file; the subscriber's output is paced behind a fixed 1 s cushion:

```bash
tsp -I ip 239.255.1.1:5000 --local-address 127.0.0.1 -O file \
  | moq --connect https://localhost:4443/anon --connect-tls-insecure import --broadcast demo ts
moq --connect https://localhost:4443/anon --connect-tls-insecure export --broadcast demo ts \
  | mpegts-pacer 239.255.1.2:5000 2000000 --latency-ms 1000
```

**Segmented HTTP.** The packager reads the feed. The receiver, started once the playlist exists, feeds the pacer, which sizes its cushion to the segments' arrival:

```bash
tsp -I ip 239.255.1.1:5000 --local-address 127.0.0.1 \
  -O hls hls/seg.ts --playlist hls/index.m3u8 --duration 2 --live 12
tsp -I hls http://127.0.0.1:8080/index.m3u8 -O file | mpegts-pacer 239.255.1.2:5000 2000000
```

**The feed**, which the fixture stands in for. Add `--rtp` to it for an RTP feed, and to the pacer for an RTP output; the readers detect RTP:

```bash
tsp -I file fixture.ts -P regulate --pcr-synchronous -O ip 239.255.1.1:5000 --local-address 127.0.0.1
```

When the check has run, expect `0 with jitter > 13` (every PCR within about 500 ns of where its byte position puts it, TR 101 290's accuracy limit), `all checks passed` (no PCR interval over 40 ms, no continuity break) and `RESULT pass`. These judge PCR values against bytes; arrival timing is checked where the IRD receives the feed, with `--input-synchronous` added to `pcrverify`.

Stop everything with Ctrl-C, remove the route, and clean up with `rm -rf /tmp/gs`.

## What the recipes show

**Both paths deliver the service intact**: the same services and elementary streams, no continuity error, no transport error, PAT and PMT present; after the pacer, every PCR is accurate and frequent enough at a constant mux rate.

## Limits

**The checks test interoperability, not conformance**: the rest of TR 101 290, and the grooming of a production output ([Architecture](architecture.md) §4), go unexamined. One machine, no loss, no congestion and one 20 s file exercise none of what the paper measures: latency, redundancy, behaviour under loss, or capacity. Those results, and the conditions under which they hold, are in [Evidence](../lab/evidence.md).

The commands were tested with the fixture alone. What each path does with a real feed's other components, such as SI tables, data streams and scrambled content, is examined lane by lane in the [Comparison](comparison.md) §2.

# Getting Started: One Transport Stream, End to End

Two recipes that carry the same MPEG-TS from a publisher to a subscriber on one machine, once over
MoQ and once over segmented HTTP, with released tools, and then check what came out against what
went in. They show each path working; they measure nothing. How the two transports work is in the
[Primer](primer.md); how they compare is in the [Comparison](comparison.md).

## What you need

Tested on macOS with these versions:

| Tool | Version | For |
|---|---|---|
| `moq` (crate `moq-cli`) and `moq-relay` | 0.14.12 and 0.17.12 | the MoQ publisher, subscriber and relay |
| TSDuck (`tsp`) | 3.45 | pacing the source, HLS packaging and receiving, the checks |
| FFmpeg | 9.0 | generating the fixture |
| Python 3 | any recent | a static HTTP origin |

With a Rust toolchain installed, the MoQ tools build in a few minutes:

```bash
cargo install --locked moq-cli@0.14.12 moq-relay@0.17.12
```

Every command below runs in `/tmp/gs`. From the root of this repository:

```bash
export REPO=$PWD
mkdir -p /tmp/gs && cd /tmp/gs
"$REPO/lab/interop/make-fixture.sh" fixture.ts
```

The fixture is synthetic: 20 s of one service with one video and one audio stream at a constant
2 Mb/s, generated rather than downloaded. The checker, `lab/interop/validate-ts.sh`, reads only
TSDuck's analysis of the two files: continuity counters, sync bytes, transport errors, PAT and PMT,
and the service and elementary-stream inventory against the source
([`lab/interop`](../lab/interop/README.md) explains why that is enough to detect loss).

Open three terminals, each with `REPO` exported and in `/tmp/gs`.

## Recipe 1: MoQ, publisher to relay to subscriber

**Terminal 1, the relay.** It generates a self-signed certificate for `localhost` and lets any
anonymous session publish and subscribe on any path, so keep it to a test machine:

```bash
moq-relay --listen '[::]:4443' --listen-tls-generate localhost --auth-public '**'
```

**Terminal 2, the subscriber.** It waits for the broadcast `demo`, writes it out as a transport
stream, and exits when the broadcast ends:

```bash
moq --connect https://localhost:4443/anon --connect-tls-insecure \
  export --broadcast demo ts > received-moq.ts
```

**Terminal 3, the publisher.** `regulate --pcr-synchronous` releases the file at the pace of its own
programme clock, as an encoder would; without it the whole file arrives in a burst:

```bash
tsp -I file fixture.ts -P regulate --pcr-synchronous -O file \
  | moq --connect https://localhost:4443/anon --connect-tls-insecure import --broadcast demo ts
```

After 20 s both clients exit. `--connect-tls-insecure` skips certificate verification, which suits
a self-signed relay on this machine and nothing else.

**Check:**

```bash
"$REPO/lab/interop/validate-ts.sh" received-moq.ts --reference fixture.ts
```

Expect every `CHECK` line `pass` and a final `RESULT pass`. The `byte-identical` line is `info` and
reports a smaller file: the released client carries the elementary streams, not the source's
packets, and the subscriber builds a new multiplex without the source's null stuffing ([Primer](primer.md) §4).
Byte-faithful carriage of the packets themselves exists on upstream's development branch, not in
these releases.

Stop the relay with Ctrl-C.

## Recipe 2: segmented HTTP, packager to origin to receiver

**Terminal 1, the origin.** Any static HTTP server will do:

```bash
mkdir -p hls && cd hls && python3 -m http.server 8080 --bind 127.0.0.1
```

**Terminal 2, the packager.** It paces the source as before and cuts it into 2 s segments behind a
live playlist of the latest twelve, more than the fixture's ten, so no segment leaves the playlist
before the receiver reads it; at the end of the input it marks the playlist ended:

```bash
tsp -I file fixture.ts -P regulate --pcr-synchronous \
  -O hls hls/seg.ts --playlist hls/index.m3u8 --duration 2 --live 12
```

**Terminal 3, the receiver.** Start it once `hls/index.m3u8` exists, a few seconds in. It starts at
the first segment in the playlist, follows the playlist as it grows, and exits at its end:

```bash
tsp -I hls http://127.0.0.1:8080/index.m3u8 -O file received-hls.ts
```

TSDuck 3.45 prints `Error: hls: no URL specified` after the last segment; its exit status is still
0, and every segment has been fetched.

**Check:**

```bash
"$REPO/lab/interop/validate-ts.sh" received-hls.ts --reference fixture.ts
```

Expect `RESULT pass` again. This time the `byte-identical` line reports a slightly larger file: the
packager starts each segment with a PAT and a PMT so that it can be decoded on its own
([Comparison](comparison.md) §8). Joined back together, the segments carry the source's own packets.

Stop the origin with Ctrl-C, and clean up with `rm -rf /tmp/gs`.

## What the recipes show, and what they do not

Both paths deliver the service intact: the same services and elementary streams, no continuity
error, no transport error, PAT and PMT present. That is all the check claims. It is an interoperability
check, not a conformance test: it does not look at TR 101 290, PCR accuracy or a constant mux rate,
which depend on pacing and on any grooming after the subscriber ([Architecture](architecture.md) §4).
One machine, no loss, no congestion and one 20 s file exercise none of what the paper measures:
latency, redundancy, behaviour under loss, or capacity. Those results, and the conditions under which
they hold, are in [Evidence](../lab/evidence.md).

The commands were tested with the fixture alone. What each path does with a real feed's other
components, such as SI tables, data streams and scrambled content, is examined lane by lane in the
[Comparison](comparison.md) §8.

#!/usr/bin/env python3
"""P0-e — a byte-faithful HLS receiver that can negotiate HTTP/3.

The campaign has two HLS receivers and neither can grade the segmented lane's carriage:

  * `tsp -I hls` is byte-faithful but speaks HTTP/1.1 only, so it cannot reach an H3 origin.
  * `ffmpeg -c copy -f mpegts` reaches H3 but **re-muxes**: it regenerates continuity counters
    and re-times PCR, so continuity and PCR grade the receiver rather than the wire and a
    `cc_errors=0` from it is true by construction.

This is the missing third option. It does exactly one thing: fetch the playlist, fetch each
media segment in playlist order, and write the segment bytes out **unmodified**. For TS-in-HLS
that is sufficient and complete — a segment is a whole number of 188-byte transport packets, so
ordered concatenation reconstructs the stream the packager emitted, continuity counters and PCR
values included. Nothing here demultiplexes, re-stamps, re-times or synthesises a table.

Transport is delegated to `curl`, because the lab already has one built against ngtcp2/nghttp3
(`~/h3/bin/curl`) and re-implementing an HTTP/3 stack to move bytes would be the wrong kind of
work. `--http-version 3` adds `--http3-only`, so an H3 arm that silently falls back to TCP fails
instead of quietly measuring the wrong substrate.

## What makes it an instrument rather than a downloader

A receiver used for carriage grading has to be **loud about everything it could not carry**,
because every failure mode here looks like clean output:

  * a segment that 404s, times out, or rolls off the live window before it is fetched, is a
    **hole**; concatenating across it produces a stream whose continuity counters jump, which
    grades as a wire defect when it is a receiver defect;
  * a media-sequence discontinuity between reloads is the same thing seen from the playlist side;
  * a segment that is not a whole number of 188-byte packets, or does not start with the 0x47
    sync byte, is not TS at all (most likely fMP4), and emitting it would corrupt everything
    downstream of it.

All three abort or are counted and reported on stderr and in the JSON summary. **A run that
reports any hole is void for carriage grading**, and the exit status says so.

Usage:
    hls-verbatim-recv.py <playlist-url> -o out.ts [--http-version 1|3] [--seconds N]
                         [--curl PATH] [--insecure] [--summary out.json]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urljoin

TS_PACKET = 188
SYNC_BYTE = 0x47


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class Fetcher:
    """Thin wrapper over curl. One invocation may carry several URLs so the connection is
    reused within a reload cycle; that matters for throughput, not for byte fidelity."""

    def __init__(self, curl, http_version, insecure, timeout):
        self.curl = curl
        self.http_version = http_version
        self.insecure = insecure
        self.timeout = timeout
        self.requests = 0

    def _base(self):
        argv = [self.curl, "--silent", "--show-error", "--fail", "--max-time", str(self.timeout)]
        if self.http_version == "3":
            # --http3-only, not --http3: a fallback to TCP would silently measure the
            # wrong substrate, which is the whole thing this arm exists to avoid.
            argv.append("--http3-only")
        else:
            argv.append("--http1.1")
        if self.insecure:
            argv.append("--insecure")
        return argv

    def text(self, url):
        self.requests += 1
        r = subprocess.run(self._base() + [url], capture_output=True)
        if r.returncode != 0:
            raise IOError(f"curl {r.returncode} for {url}: {r.stderr.decode(errors='replace').strip()}")
        return r.stdout.decode("utf-8", errors="replace")

    def files(self, urls, destdir):
        """Fetch several URLs into destdir, preserving order. Returns list of (url, path|None)."""
        argv = self._base()
        out = []
        for i, u in enumerate(urls):
            p = os.path.join(destdir, f"seg{i:06d}")
            argv += ["--output", p, u]
            out.append((u, p))
        self.requests += len(urls)
        r = subprocess.run(argv, capture_output=True)
        results = []
        for u, p in out:
            if os.path.exists(p) and os.path.getsize(p) > 0:
                results.append((u, p))
            else:
                log(f"  !! FETCH FAILED {u}: {r.stderr.decode(errors='replace').strip()[:160]}")
                results.append((u, None))
        return results


def parse_media_playlist(text, base_url):
    """Return (media_sequence, [(uri, discontinuity_before)], endlist, target_duration)."""
    media_seq = 0
    seg = []
    endlist = False
    target = None
    pending_disc = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
            media_seq = int(line.split(":", 1)[1])
        elif line.startswith("#EXT-X-TARGETDURATION:"):
            target = float(line.split(":", 1)[1])
        elif line.startswith("#EXT-X-DISCONTINUITY"):
            pending_disc = True
        elif line == "#EXT-X-ENDLIST":
            endlist = True
        elif line.startswith("#EXT-X-MAP:"):
            raise SystemExit(
                "refusing to run: playlist carries #EXT-X-MAP, so this is fMP4 and not TS. "
                "Verbatim concatenation is only meaningful for TS-in-HLS."
            )
        elif not line.startswith("#"):
            seg.append((urljoin(base_url, line), pending_disc))
            pending_disc = False
    return media_seq, seg, endlist, target


def is_master(text):
    return "#EXT-X-STREAM-INF" in text


def pick_variant(text, base_url):
    """Take the first variant. A byte-fidelity instrument should not be choosing renditions."""
    lines = [x.strip() for x in text.splitlines()]
    for i, line in enumerate(lines):
        if line.startswith("#EXT-X-STREAM-INF"):
            for nxt in lines[i + 1 :]:
                if nxt and not nxt.startswith("#"):
                    return urljoin(base_url, nxt)
    raise SystemExit("master playlist carried no variant URI")


def validate_ts(path):
    """A segment must be a whole number of 188-byte packets, each starting with 0x47."""
    size = os.path.getsize(path)
    if size % TS_PACKET != 0:
        return f"{size} bytes is not a multiple of {TS_PACKET}"
    with open(path, "rb") as fh:
        head = fh.read(TS_PACKET * 4)
    for off in range(0, len(head), TS_PACKET):
        if head[off] != SYNC_BYTE:
            return f"no 0x47 sync at offset {off}"
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("url", help="media or master playlist URL")
    ap.add_argument("-o", "--output", required=True, help="output .ts (verbatim concatenation)")
    ap.add_argument("--http-version", choices=["1", "3"], default="1")
    ap.add_argument("--seconds", type=float, default=60.0, help="wall-clock capture window")
    ap.add_argument("--curl", default=os.environ.get("CURL", "curl"))
    ap.add_argument("--insecure", action="store_true")
    ap.add_argument("--timeout", type=float, default=15.0, help="per-request timeout")
    ap.add_argument("--summary", help="write a JSON summary here")
    args = ap.parse_args()

    if not shutil.which(args.curl) and not os.path.isfile(args.curl):
        raise SystemExit(f"no curl at {args.curl}")

    fetch = Fetcher(args.curl, args.http_version, args.insecure, args.timeout)

    if args.http_version == "3":
        v = subprocess.run([args.curl, "--version"], capture_output=True).stdout.decode()
        if "HTTP3" not in v:
            raise SystemExit(
                f"{args.curl} is not built with HTTP/3 (no HTTP3 in --version features). "
                "An H3 arm needs a curl built against ngtcp2/nghttp3."
            )

    url = args.url
    first = fetch.text(url)
    if is_master(first):
        url = pick_variant(first, url)
        log(f"master playlist -> variant {url}")

    seen = set()  # absolute media sequence numbers already written
    holes = []  # (after_seq, detail)
    discontinuities = []  # absolute sequence numbers carrying EXT-X-DISCONTINUITY
    written_segments = 0
    written_bytes = 0
    reloads = 0
    next_expected = None  # absolute sequence we expect to write next

    started = time.time()
    tmp = tempfile.mkdtemp(prefix="hlsverbatim-")
    try:
        with open(args.output, "wb") as out:
            while time.time() - started < args.seconds:
                cycle = time.time()
                try:
                    body = fetch.text(url)
                except IOError as e:
                    log(f"  !! playlist fetch failed: {e}")
                    time.sleep(1.0)
                    continue
                reloads += 1
                media_seq, segs, endlist, target = parse_media_playlist(body, url)

                # Absolute sequence number of every segment now in the window.
                window = [(media_seq + i, uri, disc) for i, (uri, disc) in enumerate(segs)]
                fresh = [(s, u, d) for (s, u, d) in window if s not in seen]

                if next_expected is not None and fresh:
                    # The playlist rolled past something we never fetched.
                    if fresh[0][0] > next_expected:
                        missing = fresh[0][0] - next_expected
                        holes.append((next_expected, f"{missing} segment(s) rolled out of the window"))
                        log(
                            f"  !! HOLE: sequences {next_expected}..{fresh[0][0] - 1} "
                            f"left the playlist before they were fetched"
                        )

                if fresh:
                    got = fetch.files([u for (_, u, _) in fresh], tmp)
                    for (seq, uri, disc), (_, path) in zip(fresh, got):
                        if path is None:
                            holes.append((seq, "fetch failed"))
                            seen.add(seq)
                            next_expected = seq + 1
                            continue
                        bad = validate_ts(path)
                        if bad:
                            raise SystemExit(
                                f"segment {uri} is not a valid transport stream ({bad}). "
                                "Refusing to emit it: verbatim concatenation of non-TS produces "
                                "a corrupt stream that grades as a wire defect."
                            )
                        if disc:
                            discontinuities.append(seq)
                            log(f"  -- EXT-X-DISCONTINUITY before sequence {seq}")
                        with open(path, "rb") as fh:
                            data = fh.read()
                        out.write(data)
                        written_bytes += len(data)
                        written_segments += 1
                        seen.add(seq)
                        next_expected = seq + 1
                        os.unlink(path)

                if endlist:
                    log("playlist carried #EXT-X-ENDLIST — stopping")
                    break

                # Reload no faster than half the target duration, per RFC 8216 §6.3.4.
                nap = (target / 2.0) if target else 1.0
                slept = time.time() - cycle
                if nap > slept:
                    time.sleep(nap - slept)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    elapsed = time.time() - started
    summary = {
        "url": args.url,
        "http_version": args.http_version,
        "output": args.output,
        "elapsed_s": round(elapsed, 2),
        "playlist_reloads": reloads,
        "http_requests": fetch.requests,
        "segments_written": written_segments,
        "bytes_written": written_bytes,
        "ts_packets": written_bytes // TS_PACKET,
        "playlist_discontinuities": discontinuities,
        "holes": [{"after_sequence": s, "detail": d} for s, d in holes],
        "byte_faithful": len(holes) == 0,
    }

    log("")
    log(
        f"segments {written_segments}   bytes {written_bytes:,}   packets {summary['ts_packets']:,}   reloads {reloads}"
    )
    if discontinuities:
        log(f"playlist signalled {len(discontinuities)} discontinuity/ies at {discontinuities}")
    if holes:
        log(f"VOID for carriage grading: {len(holes)} hole(s) — the output is not the wire")
    else:
        log("no holes: the output is the concatenation of every segment the playlist offered")

    if args.summary:
        with open(args.summary, "w") as fh:
            json.dump(summary, fh, indent=2)

    return 0 if (written_segments > 0 and not holes) else 1


if __name__ == "__main__":
    sys.exit(main())

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

## What it costs, which a latency arm has to subtract

Each reload cycle is two `curl` processes -- the playlist, then every fresh segment in one
invocation -- so each cycle pays two connection setups, each from slow start: negligible on
loopback, more than a 2 s segment's period behind a 20 Mb/s bottleneck at 100 ms RTT. `--libcurl`
loads the same library in-process and keeps one connection for the run instead. `--timeout` is
curl's `--max-time`, which curl applies to each transfer, not to the invocation: a batch may run
far past it, and a segment is cut short only when it alone takes longer, i.e. when its size over
the path's rate exceeds the timeout. A segment cut short is not whole packets and by default ends
the run, without a summary (`--truncated hole` records it instead). Reloads come every half target
duration, so a segment waits up to that long after it appears; the first reload fetches the whole
live window, so the first few segments' lag is the join, not the lane. `--trace` writes each
segment's handshake, time to first byte, batch time and, with `--origin-dir` on a co-resident
origin, its lag behind the segment file's creation.

Usage:
    hls-verbatim-recv.py <playlist-url> -o out.ts [--http-version 1|3] [--seconds N]
                         [--curl PATH] [--insecure] [--summary out.json]
                         [--trace t.csv] [--origin-dir DIR] [--truncated abort|hole]
                         [--libcurl PATH]
"""

import argparse
import io
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

    # One line per transfer on stdout, which the segment fetch otherwise leaves empty. The
    # handshake is `appconnect`: every invocation is a fresh process and so a fresh connection.
    # The marker must not start with `@`, which curl reads as "take the format from this file".
    WRITE_OUT = "TRACE %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{http_code}\\n"

    def __init__(self, curl, http_version, insecure, timeout):
        self.curl = curl
        self.http_version = http_version
        self.insecure = insecure
        self.timeout = timeout
        self.requests = 0
        self.last_rc = 0
        self.last_timings = []

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
        # `--max-time` applies to each transfer, so a batch is not bounded as a whole.
        argv = self._base() + ["--write-out", self.WRITE_OUT]
        out = []
        for i, u in enumerate(urls):
            p = os.path.join(destdir, f"seg{i:06d}")
            argv += ["--output", p, u]
            out.append((u, p))
        self.requests += len(urls)
        r = subprocess.run(argv, capture_output=True)
        self.last_rc = r.returncode
        self.last_timings = [
            line.split()[1:] for line in r.stdout.decode(errors="replace").splitlines() if line.startswith("TRACE ")
        ]
        results = []
        for u, p in out:
            if os.path.exists(p) and os.path.getsize(p) > 0:
                results.append((u, p))
            else:
                log(f"  !! FETCH FAILED {u}: {r.stderr.decode(errors='replace').strip()[:160]}")
                results.append((u, None))
        return results


class PersistentFetcher:
    """The same transfers through one libcurl easy handle for the whole run, so every request
    after the first reuses one connection and its congestion window, as a player's does. The
    per-process `Fetcher` opens two connections a cycle, each from slow start; behind a 20 Mb/s
    bottleneck at 100 ms RTT that alone costs more than a 2 s segment's period. Same library as
    the `curl` binary it replaces, same `--max-time`-per-transfer and `--fail` semantics."""

    OPT_WRITEDATA, OPT_URL, OPT_WRITEFUNCTION = 10001, 10002, 20011
    OPT_FAILONERROR, OPT_SSL_VERIFYPEER, OPT_SSL_VERIFYHOST = 45, 64, 81
    OPT_HTTP_VERSION, OPT_NOSIGNAL, OPT_TIMEOUT_MS = 84, 99, 155
    HTTP_1_1, HTTP_3ONLY = 2, 31
    INFO_TOTAL, INFO_SIZE, INFO_STARTTRANSFER, INFO_APPCONNECT = 0x300003, 0x300008, 0x300011, 0x300021
    INFO_NUM_CONNECTS = 0x20001A

    def __init__(self, libpath, http_version, insecure, timeout):
        import ctypes

        self.c = ctypes
        self.lib = ctypes.CDLL(libpath)
        self.lib.curl_easy_init.restype = ctypes.c_void_p
        self.lib.curl_easy_strerror.restype = ctypes.c_char_p
        self.lib.curl_global_init(ctypes.c_long(3))
        self.h = ctypes.c_void_p(self.lib.curl_easy_init())
        self.sink = None
        write_fn = ctypes.CFUNCTYPE(ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_void_p)
        self._cb = write_fn(self._write)
        self._set(self.OPT_WRITEFUNCTION, self._cb)
        self._set(self.OPT_NOSIGNAL, ctypes.c_long(1))
        self._set(self.OPT_FAILONERROR, ctypes.c_long(1))
        self._set(self.OPT_TIMEOUT_MS, ctypes.c_long(int(timeout * 1000)))
        self._set(self.OPT_HTTP_VERSION, ctypes.c_long(self.HTTP_3ONLY if http_version == "3" else self.HTTP_1_1))
        if insecure:
            self._set(self.OPT_SSL_VERIFYPEER, ctypes.c_long(0))
            self._set(self.OPT_SSL_VERIFYHOST, ctypes.c_long(0))
        self.requests = 0
        self.connects = 0
        self.last_rc = 0
        self.last_timings = []

    def _set(self, opt, val):
        self.lib.curl_easy_setopt(self.h, self.c.c_int(opt), val)

    def _write(self, ptr, size, nmemb, _):
        self.sink.write(self.c.string_at(ptr, size * nmemb))
        return size * nmemb

    def _info(self, what, ctype):
        v = ctype()
        self.lib.curl_easy_getinfo(self.h, self.c.c_int(what), self.c.byref(v))
        return v.value

    def _perform(self, url, sink):
        self.requests += 1
        self.sink = sink
        self._set(self.OPT_URL, self.c.c_char_p(url.encode()))
        rc = self.lib.curl_easy_perform(self.h)
        self.connects += self._info(self.INFO_NUM_CONNECTS, self.c.c_long)
        return rc

    def text(self, url):
        buf = io.BytesIO()
        rc = self._perform(url, buf)
        if rc != 0:
            raise IOError(f"curl {rc} for {url}: {self.lib.curl_easy_strerror(rc).decode()}")
        return buf.getvalue().decode("utf-8", errors="replace")

    def files(self, urls, destdir):
        out, self.last_timings, self.last_rc = [], [], 0
        for i, u in enumerate(urls):
            p = os.path.join(destdir, f"seg{i:06d}")
            with open(p, "wb") as fh:
                rc = self._perform(u, fh)
            d = self.c.c_double
            self.last_timings.append(
                [
                    f"{self._info(self.INFO_APPCONNECT, d):.6f}",
                    f"{self._info(self.INFO_STARTTRANSFER, d):.6f}",
                    f"{self._info(self.INFO_TOTAL, d):.6f}",
                    f"{self._info(self.INFO_SIZE, d):.0f}",
                    "",
                ]
            )
            if rc != 0:
                self.last_rc = rc
                if os.path.getsize(p) == 0:
                    log(f"  !! FETCH FAILED {u}: curl {rc}: {self.lib.curl_easy_strerror(rc).decode()}")
                    out.append((u, None))
                    continue
            out.append((u, p))
        return out


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
    ap.add_argument("--trace", help="per-segment timing CSV: the receiver's own cost, for a latency arm")
    ap.add_argument(
        "--origin-dir",
        help="the origin's segment directory, when co-resident: adds each segment's lag behind its file's mtime",
    )
    ap.add_argument(
        "--truncated",
        choices=["abort", "hole"],
        default="abort",
        help="a segment that is not whole packets -- what a timeout leaves -- ends the run (default) or is a hole",
    )
    ap.add_argument(
        "--libcurl",
        help="libcurl.so to load instead of spawning curl: one connection for the whole run, as a player keeps",
    )
    args = ap.parse_args()

    if not shutil.which(args.curl) and not os.path.isfile(args.curl):
        raise SystemExit(f"no curl at {args.curl}")

    if args.libcurl:
        fetch = PersistentFetcher(args.libcurl, args.http_version, args.insecure, args.timeout)
    else:
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

    trace = None
    if args.trace:
        trace = open(args.trace, "w")
        trace.write(
            "cycle,seq,playlist_s,batch_n,batch_s,curl_rc,appconnect_s,ttfb_s,total_s,bytes,written_epoch,origin_mtime,lag_s\n"
        )
    timeouts = 0

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
                playlist_s = time.time() - cycle
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
                    batch_at = time.time()
                    got = fetch.files([u for (_, u, _) in fresh], tmp)
                    batch_s = time.time() - batch_at
                    if fetch.last_rc == 28:
                        timeouts += 1
                        log(f"  !! TIMEOUT: a segment took longer than {args.timeout:g} s")
                    for k, ((seq, uri, disc), (_, path)) in enumerate(zip(fresh, got)):
                        if path is None:
                            holes.append((seq, "fetch failed"))
                            seen.add(seq)
                            next_expected = seq + 1
                            continue
                        bad = validate_ts(path)
                        if bad and args.truncated == "hole":
                            log(f"  !! HOLE: segment {seq} truncated ({bad}), not emitted")
                            holes.append((seq, f"truncated: {bad}"))
                            seen.add(seq)
                            next_expected = seq + 1
                            os.unlink(path)
                            continue
                        if bad:
                            raise SystemExit(
                                f"segment {uri} is not a valid transport stream ({bad}). "
                                "Refusing to emit it: verbatim concatenation of non-TS produces "
                                "a corrupt stream that grades as a wire defect."
                            )
                        if trace:
                            t = fetch.last_timings[k] if k < len(fetch.last_timings) else ["", "", "", "", ""]
                            mtime = lag = ""
                            if args.origin_dir:
                                try:
                                    m = os.stat(os.path.join(args.origin_dir, os.path.basename(uri.split("?")[0])))
                                    mtime = f"{m.st_mtime:.3f}"
                                    lag = f"{time.time() - m.st_mtime:.3f}"
                                except OSError:
                                    pass
                            trace.write(
                                f"{reloads},{seq},{playlist_s:.4f},{len(fresh)},{batch_s:.4f},{fetch.last_rc},"
                                f"{t[0]},{t[1]},{t[2]},{os.path.getsize(path)},{time.time():.3f},{mtime},{lag}\n"
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
        if trace:
            trace.close()

    elapsed = time.time() - started
    summary = {
        "url": args.url,
        "http_version": args.http_version,
        "output": args.output,
        "elapsed_s": round(elapsed, 2),
        "playlist_reloads": reloads,
        "http_requests": fetch.requests,
        "connections": getattr(fetch, "connects", None),
        "segments_written": written_segments,
        "bytes_written": written_bytes,
        "ts_packets": written_bytes // TS_PACKET,
        "playlist_discontinuities": discontinuities,
        "holes": [{"after_sequence": s, "detail": d} for s, d in holes],
        "batch_timeouts": timeouts,
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

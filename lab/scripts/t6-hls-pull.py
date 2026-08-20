#!/usr/bin/env python3
"""A minimal HLS media-playlist client that does not give up.

T6's segmented arm needs to separate two things that a drill using an off-the-shelf
client cannot: what the *protocol* requires in order to recover from a serving-node
failure, and what a given *client* happens to implement. Both `tsp -I hls` and
ffmpeg's HLS demuxer abandon the stream on the first failed playlist reload, so a
drill run only under them measures their error handling and reports it as a property
of segmented HTTP.

This client exists to establish the other bound. It is deliberately the least
capable thing that can still be called a receiver — one media playlist, no master
playlist, no ABR, no discontinuity handling, no LL-HLS — and its only real feature is
that a failed fetch is a retry rather than an exit. HTTP holds no session state, so
recovery needs nothing re-established: the next successful GET is the recovery.

On recovery it re-anchors to the live edge rather than replaying whatever it missed,
which is the behaviour a broadcast receiver wants (a hole, not a lag) and matches how
the media-aware exporter resumes.

Usage:
  t6-hls-pull.py URL OUT.ts [--seconds N] [--retry MS] [--edge N] [--log FILE]
"""
import argparse
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def get(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": "t6-hls-pull/1"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def parse_media_playlist(text):
    """Return (media_sequence, [segment_uri, ...]) from a media playlist."""
    seq, uris = 0, []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
            try:
                seq = int(line.split(":", 1)[1])
            except ValueError:
                pass
        elif line and not line.startswith("#"):
            uris.append(line)
    return seq, uris


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("out")
    ap.add_argument("--seconds", type=float, default=60.0)
    ap.add_argument("--retry", type=float, default=500.0, help="retry/poll interval, ms")
    ap.add_argument("--edge", type=int, default=1,
                    help="join this many segments back from the live edge")
    ap.add_argument("--timeout", type=float, default=2.0)
    ap.add_argument("--log", default=None)
    args = ap.parse_args()

    logf = open(args.log, "w", buffering=1) if args.log else sys.stderr

    def log(msg):
        print(f"{time.time():.3f} {msg}", file=logf)

    out = open(args.out, "wb", buffering=0)
    deadline = time.time() + args.seconds
    poll = args.retry / 1000.0

    # Segment identity is the URI. Media sequence numbers are not reliable across a
    # source change (a standby packager restarts its own numbering), and this client
    # has to keep working across exactly that case.
    seen = set()
    joined = False
    fetched = failed = 0
    first_ok = None
    gaps = []          # (down_since, recovered_at) for every outage survived
    down_since = None

    while time.time() < deadline:
        try:
            body = get(args.url, args.timeout).decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001 - any failure is a retry, by design
            failed += 1
            if down_since is None:
                down_since = time.time()
                log(f"playlist fetch failed, retrying: {e}")
            time.sleep(poll)
            continue

        if down_since is not None:
            gaps.append((down_since, time.time()))
            log(f"playlist recovered after {time.time() - down_since:.2f}s")
            down_since = None

        _, uris = parse_media_playlist(body)
        if not uris:
            time.sleep(poll)
            continue

        if not joined:
            # Join at the live edge: everything already in the playlist is history.
            for u in uris[:-args.edge] if args.edge else uris:
                seen.add(u)
            joined = True

        for u in uris:
            if u in seen:
                continue
            seg_url = urllib.parse.urljoin(args.url, u)
            try:
                data = get(seg_url, args.timeout)
            except Exception as e:  # noqa: BLE001
                failed += 1
                # A segment that cannot be fetched now has usually aged out; do not
                # block the live edge waiting for it.
                log(f"segment fetch failed {u}: {e}")
                seen.add(u)
                continue
            out.write(data)
            seen.add(u)
            fetched += 1
            if first_ok is None:
                first_ok = time.time()

        time.sleep(poll)

    out.close()
    worst = max((b - a for a, b in gaps), default=0.0)
    log(f"done fetched={fetched} failed={failed} outages={len(gaps)} worst_outage_s={worst:.2f}")
    print(f"PULL fetched={fetched} failed={failed} outages={len(gaps)} "
          f"worst_outage_s={worst:.2f}")


if __name__ == "__main__":
    main()

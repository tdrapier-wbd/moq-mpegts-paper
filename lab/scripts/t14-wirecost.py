#!/usr/bin/env python3
"""T14 measurement 5: what segmented HTTP costs to carry a transport stream.

Reduces an nginx access log to a carriage ratio against the source TS.

The accounting is deliberately clock-free. A first version divided HTTP bytes by
the log's span and delivered bytes by the receiver's span, and the two spans
differed by 11 % because `tsp -I hls --live` drains the live window faster than
real time before settling; that put the delivered rate 4.7 % *above* a CBR source
and made the overhead come out negative. The fix is to stop dividing by wall
clocks. `$body_bytes_sent` on a segment response is the TS payload itself, and
T14 measurement 4 established that arm B1 carries the mux byte-verbatim, so those
bytes *are* source bytes: the ratio of everything nginx sent to the segment bodies
it sent is the carriage overhead over exactly the media carried, whenever it was
fetched. Rates are still printed, but only as a sanity check, never as a ratio.

Per-packet framing is not measured: loopback's 16384 B MTU makes datagram counts
meaningless and tcpdump needs privileges unavailable here. T9 measured framing on
a real path, per packet and MTU-parameterised, so it is added arithmetically at a
stated datagram size and labelled derived.
"""

from __future__ import annotations

import argparse
import csv

# T9 measured the carriage cost of a QUIC datagram on a real path: 28 B of IP+UDP
# outside the datagram and ~36 B of QUIC header, AEAD tag and STREAM framing
# inside it. As a multiplier on the bytes carried that is the framing floor for
# anything riding QUIC, MoQ and HTTP/3 alike.
QUIC_FRAMING = {1200: 1.0550, 1452: 1.0450, 8952: 1.0070}

# TCP/IPv4 at a 1500 B path MTU: 20 B IP + 20 B TCP over a 1460 B MSS, plus TLS
# 1.3 AES-GCM at a 5 B record header and 16 B tag per 16 KB record.
TCP_FRAMING = 1 + 40 / 1460 + 21 / 16384

FIELDS = ("msec", "method", "uri", "status", "sent", "body", "received")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--access-log", required=True)
    parser.add_argument("--skip-lines", type=int, default=0)
    parser.add_argument("--delivered-csv")
    parser.add_argument("--source-bps", type=float, required=True)
    args = parser.parse_args()

    with open(args.access_log) as fh:
        lines = fh.read().splitlines()[args.skip_lines :]
    rows = [dict(zip(FIELDS, line.split())) for line in lines if len(line.split()) == 7]
    if len(rows) < 2:
        raise SystemExit("access log has no complete requests in the window")

    segments = [row for row in rows if row["uri"].endswith(".ts")]
    playlists = [row for row in rows if row["uri"].endswith(".m3u8")]
    if not segments:
        raise SystemExit("no segment requests in the window")

    def total(rows_, field):
        return sum(int(row[field]) for row in rows_)

    media = total(segments, "body")
    media_seconds = media / (args.source_bps / 8)
    forward = total(rows, "sent")
    ret = total(rows, "received")
    seg_headers = total(segments, "sent") - media
    unique = len({row["uri"] for row in segments})
    errors = [row for row in rows if not row["status"].startswith("2")]

    print("--- measured, HTTP layer, clock-free -------------------------------")
    print(f"SEGMENTS_SERVED        {len(segments)} ({unique} distinct, "
          f"{len(segments) - unique} refetched)")
    print(f"PLAYLIST_FETCHES       {len(playlists)}")
    print(f"NON_2XX                {len(errors)}")
    print(f"MEDIA_CARRIED_S        {media_seconds:.2f}  ({media:,} B of TS)")
    print(f"MEAN_SEGMENT_S         {media_seconds / len(segments):.3f}")
    print()
    print(f"TS_PAYLOAD_B           {media:,}")
    print(f"SEGMENT_HEADERS_B      {seg_headers:,}  "
          f"({seg_headers / media * 100:+.4f} % of payload)")
    print(f"PLAYLIST_DOWN_B        {total(playlists, 'sent'):,}  "
          f"({total(playlists, 'sent') / media * 100:+.4f} % of payload)")
    print(f"FORWARD_HTTP_B         {forward:,}")
    print(f"RETURN_HTTP_B          {ret:,}  ({ret / forward * 100:.3f} % of forward)")
    print()
    print(f"HTTP_VS_SOURCE_TS      {forward / media:.4f}x")
    print(f"PLAYLIST_RATE_HZ       {len(playlists) / media_seconds:.2f} per media second")
    print(f"RETURN_KBPS            {ret * 8 / media_seconds / 1e3:.2f}  "
          f"(over the media time carried)")

    if args.delivered_csv:
        with open(args.delivered_csv) as fh:
            records = [(int(r["t_ns"]), int(r["bytes"])) for r in csv.DictReader(fh)]
        span = records[-1][0] / 1e9
        delivered = sum(length for _, length in records)
        print()
        print("--- sanity check, not a ratio --------------------------------------")
        print(f"RECEIVER_SPAN_S        {span:.3f}")
        print(f"DELIVERED_MBPS         {delivered * 8 / span / 1e6:.4f} "
              f"(source {args.source_bps / 1e6:.4f}; above it means the receiver "
              "was still draining the live window)")

    print()
    print("--- derived: + T9's measured per-packet framing --------------------")
    for mtu, factor in sorted(QUIC_FRAMING.items()):
        print(f"  HTTP/3 at {mtu:5d} B    {forward * factor / media:.4f}x source TS")
    print(f"  HTTP/1.1+TLS 1500 B  {forward * TCP_FRAMING / media:.4f}x source TS")
    print()
    print("  MoQ, measured on a real path (T9): 0.982x at 1200 B, 0.973x at 1452 B")


if __name__ == "__main__":
    main()

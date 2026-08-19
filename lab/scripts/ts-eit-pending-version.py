#!/usr/bin/env python3
"""Announce an EIT version ahead of the change, the way a real DVB mux does.

Takes a clip that already carries an EIT version transition and marks the first N
occurrences of the new version as `current_next_indicator = 0` — a *pending* version,
transmitted alongside the one that still applies. That is the case the `is_current` guard
in #2824 exists for, and no capture we hold contains it.

The CRC is recomputed, so the result is a legal stream and a rejection means the guard
fired rather than the section being malformed.

Every section that starts in a packet is examined, not only the one the `pointer_field`
names: TSDuck packs SI sections back-to-back, so a walk that stops at the first would leave
a packed successor current and produce a fixture that tests less than it claims.
"""

import sys

TS = 188


def section_starts(pkt):
    """Offsets of every section beginning in this packet, in order."""
    off = 5 + pkt[4] if pkt[3] & 0x20 else 4
    if off >= TS:
        return
    sec = off + 1 + pkt[off]  # past the pointer_field
    while sec + 3 <= TS and pkt[sec] != 0xFF:
        length = 3 + (((pkt[sec + 1] & 0x0F) << 8) | pkt[sec + 2])
        yield sec, length
        if sec + length > TS:
            return
        sec += length


def crc32_mpeg(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


def main():
    src, dst, version, n_pending = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    data = bytearray(open(src, "rb").read())
    patched = 0
    for i in range(0, len(data) - TS + 1, TS):
        if patched >= n_pending:
            break
        p = data[i : i + TS]
        if p[0] != 0x47 or (((p[1] & 0x1F) << 8) | p[2]) != 0x12 or not (p[3] & 0x10) or not (p[1] & 0x40):
            continue
        for off, length in section_starts(p):
            if patched >= n_pending:
                break
            s = i + off
            if off + 8 > TS or off + length > TS or data[s] != 0x4E:
                continue
            if (data[s + 5] >> 1 & 0x1F) != version or not data[s + 5] & 1:
                continue
            data[s + 5] &= ~0x01  # current_next_indicator = 0: this version is not in force yet
            crc = crc32_mpeg(data[s : s + length - 4])
            data[s + length - 4 : s + length] = crc.to_bytes(4, "big")
            patched += 1
    open(dst, "wb").write(data)
    print(f"marked {patched} EIT v{version} sections as pending -> {dst}")


if __name__ == "__main__":
    main()

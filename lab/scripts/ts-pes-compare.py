#!/usr/bin/env python3
"""Do two TS captures carry the same elementary-stream content? ts-pes-compare.py a.ts b.ts

Reassembles every PES in each capture, matches them by PID and the first 14 octets (start code,
length, flags, PTS), and compares the payloads. Where ts-pair-diff.py finds packets differing, this
separates different media from the same media packetized differently.
"""
import sys

P = 188


def pes(path):
    data = open(path, 'rb').read()
    open_pes, done = {}, {}
    for i in range(len(data) // P):
        p = data[i * P:(i + 1) * P]
        pid = ((p[1] & 0x1F) << 8) | p[2]
        afc = (p[3] >> 4) & 3
        if not afc & 1:
            continue
        off = 4 + (1 + p[4] if afc & 2 else 0)
        if p[1] & 0x40:
            if pid in open_pes:
                body = open_pes.pop(pid)
                done[(pid, bytes(body[:14]))] = bytes(body)
            open_pes[pid] = bytearray()
        if pid in open_pes:
            open_pes[pid] += p[off:]
    return done


a, b = pes(sys.argv[1]), pes(sys.argv[2])
common = set(a) & set(b)
differ = sum(1 for k in common if a[k] != b[k])
print(f'PES {len(a)} / {len(b)}, matched by PID and header {len(common)}, payload differs {differ}')
sys.exit(1 if differ else 0)

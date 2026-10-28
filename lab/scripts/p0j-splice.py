"""Describe a whole-multiplex splice in a P0-j hand-off ring.

usage: p0j-splice.py <event-dir> [packet-index]

The splice is the first continuity break in the concatenated ring unless a packet index is given.
For each PID: the last packet before and the first after (continuity counter, payload start). For
the PSI and SI PIDs: each table's version and CRC on each side, the SDT's names and the TDT's UTC
time. For PCR and every PES PID: the last timestamp before and the first after, and the step, the
shorter way round the 33-bit clock. For the video: whether its first packet after the splice starts
a PES, carries random_access_indicator, and which NAL unit types the first PES holds.
"""
import datetime as dt
import glob
import os
import sys

d = sys.argv[1]
files = sorted(glob.glob(os.path.join(d, 'ring-*.ts')))
data = b''.join(open(f, 'rb').read() for f in files)
n = len(data) // 188
WRAP_S = (1 << 33) / 90000
PKT_S = 188 * 8 / 25e6


def step(a, b):
    return (b - a + WRAP_S / 2) % WRAP_S - WRAP_S / 2


def ts33(b):
    return ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1


def pkt(i):
    p = data[i * 188:(i + 1) * 188]
    pid = (p[1] & 0x1F) << 8 | p[2]
    afc = (p[3] >> 4) & 3
    off, rai, pcr = 4, False, None
    if afc & 2:
        alen = p[4]
        if alen:
            fl = p[5]
            rai = bool(fl & 0x40)
            if fl & 0x10 and alen >= 7:
                b = p[6:12]
                base = b[0] << 25 | b[1] << 17 | b[2] << 9 | b[3] << 1 | b[4] >> 7
                pcr = (base * 300 + ((b[4] & 1) << 8 | b[5])) / 27e6
        off = 5 + alen
    payload = p[off:] if afc & 1 and off < 188 else b''
    return pid, bool(p[1] & 0x40), p[3] & 15, rai, pcr, payload


def find_splice():
    last = {}
    for i in range(n):
        pid, _, cc, _, _, payload = pkt(i)
        if pid == 0x1FFF or not payload:
            continue
        if pid in last and cc not in ((last[pid] + 1) & 15, last[pid]):
            return i
        last[pid] = cc
    sys.exit('no continuity break in the ring')


s = int(sys.argv[2]) if len(sys.argv) > 2 else find_splice()
print(f'{len(files)} rings, {n:,} packets; splice at packet {s:,} ({s * PKT_S:.3f} s into the ring)')


def mjd_utc(b):
    mjd = b[0] << 8 | b[1]
    bcd = [((x >> 4) * 10 + (x & 15)) for x in b[2:5]]
    t = dt.datetime(1858, 11, 17) + dt.timedelta(days=mjd, hours=bcd[0], minutes=bcd[1], seconds=bcd[2])
    return t.strftime('%Y-%m-%d %H:%M:%S')


def dvb_text(b):
    return (b[1:] if b and b[0] < 0x20 else b).decode('latin-1', 'replace')


def describe(pid, sec):
    tid = sec[0]
    if tid in (0x70, 0x73):
        return f'table 0x{tid:02x} UTC {mjd_utc(sec[3:8])}'
    ver = (sec[5] >> 1) & 31
    crc = sec[-4:].hex()
    extra = ''
    if tid == 0x42:
        k = 11
        names = []
        while k < len(sec) - 4:
            dl = ((sec[k + 3] & 15) << 8) | sec[k + 4]
            j, end = k + 5, k + 5 + dl
            while j < end:
                tag, ln = sec[j], sec[j + 1]
                if tag == 0x48:
                    pl = sec[j + 3]
                    prov = dvb_text(sec[j + 4:j + 4 + pl])
                    nl = sec[j + 4 + pl]
                    names.append(f'{prov}/{dvb_text(sec[j + 5 + pl:j + 5 + pl + nl])}')
                j += 2 + ln
            k = end
        extra = f' services {names}'
    if tid == 0x02:
        pcr_pid = ((sec[8] & 0x1F) << 8) | sec[9]
        pil = ((sec[10] & 15) << 8) | sec[11]
        k, es = 12 + pil, []
        while k < len(sec) - 4:
            es.append(f'{((sec[k + 1] & 0x1F) << 8) | sec[k + 2]}:0x{sec[k]:02x}')
            k += 5 + (((sec[k + 3] & 15) << 8) | sec[k + 4])
        extra = f' PCR {pcr_pid} streams {es}'
    return f'table 0x{tid:02x} version {ver} crc {crc}{extra}'


def first_section(i0, i1, pid, rev=False):
    """The first section to start on pid between packets i0 and i1 (the last, if rev)."""
    rng = range(i1 - 1, i0 - 1, -1) if rev else range(i0, i1)
    for i in rng:
        p, pusi, _, _, _, payload = pkt(i)
        if p != pid or not pusi or not payload:
            continue
        b = bytearray(payload[1 + payload[0]:])
        j = i + 1
        while len(b) < 3 + (((b[1] & 15) << 8) | b[2]) and j < n:
            q, _, _, _, _, pl = pkt(j)
            if q == pid:
                b += pl
            j += 1
        sl = 3 + (((b[1] & 15) << 8) | b[2])
        if len(b) >= sl and (not rev or j <= s):
            return i, bytes(b[:sl])
    return None, None


span = int(30 / PKT_S)
lo, hi = max(0, s - span), min(n, s + span)
pids = {}
for i in range(lo, hi):
    pid, pusi, cc, rai, pcr, payload = pkt(i)
    if pid == 0x1FFF:
        continue
    side = 'after' if i >= s else 'before'
    e = pids.setdefault(pid, {})
    if side == 'before' or 'after' not in e:
        e[side] = (i, cc, pusi)

_, pat = first_section(lo, s, 0, rev=True)
pmt = ((pat[10] & 0x1F) << 8) | pat[11] if pat else None
print('per PID (last before | first after: packet, cc, payload start):')
for pid in sorted(pids):
    b, a = pids[pid].get('before'), pids[pid].get('after')
    print(f'  {pid:5d}  {b}  |  {a}' + (f'  (+{(a[0] - s) * PKT_S:.3f} s)' if a else ''))

for pid in [0, pmt, 16, 17, 20]:
    if pid is None:
        continue
    _, before = first_section(lo, s, pid, rev=True)
    ia, after = first_section(s, hi, pid)
    print(f'PID {pid}: before {describe(pid, before) if before else None}')
    print(f'{"":{len(str(pid)) + 5}}after  {describe(pid, after) if after else None}'
          + (f' (+{(ia - s) * PKT_S:.3f} s)' if ia else ''))

last, first = {}, {}
for i in range(lo, hi):
    pid, pusi, _, rai, pcr, payload = pkt(i)
    if pcr is not None:
        if i < s:
            last[('pcr', pid)] = (i, pcr)
        elif ('pcr', pid) not in first:
            first[('pcr', pid)] = (i, pcr)
    if pusi and len(payload) >= 14 and payload[:3] == b'\x00\x00\x01' and payload[7] & 0x80:
        pts = ts33(payload[9:14]) / 90000
        dts = ts33(payload[14:19]) / 90000 if payload[7] & 0x40 else pts
        key = ('pes', pid)
        if i < s:
            last[key] = (i, pts, dts)
        elif key not in first:
            first[key] = (i, pts, dts)
print('timestamps (last before -> first after, step):')
for key in sorted(set(last) | set(first), key=lambda k: (k[0], k[1])):
    b, a = last.get(key), first.get(key)
    if b and a:
        print(f'  {key[0]} {key[1]}: {b[-1]:.4f} -> {a[-1]:.4f}, step {step(b[-1], a[-1]):+.4f} s'
              f' (first after at +{(a[0] - s) * PKT_S:.3f} s)')
vid = 111
v_before, v_after = last.get(('pes', vid)), first.get(('pes', vid))
p_before, p_after = last.get(('pcr', vid)), first.get(('pcr', vid))
if v_before and v_after and p_before and p_after:
    print(f'  video DTS minus PCR: before {step(p_before[1], v_before[2]):.3f} s, '
          f'after {step(p_after[1], v_after[2]):.3f} s')

for i in range(s, hi):
    pid, pusi, _, rai, _, payload = pkt(i)
    if pid != vid:
        continue
    print(f'video first packet after: +{(i - s) * PKT_S:.3f} s, payload start {pusi}, random_access_indicator {rai}')
    break
for i in range(s, hi):
    pid, pusi, _, rai, _, payload = pkt(i)
    if pid != vid or not pusi:
        continue
    es = bytearray(payload[9 + payload[8]:])
    j = i + 1
    while len(es) < 60000 and j < hi:
        q, qpusi, _, _, _, pl = pkt(j)
        if q == vid:
            if qpusi:
                break
            es += pl
        j += 1
    types, k = [], 0
    while True:
        k = es.find(b'\x00\x00\x01', k)
        if k < 0 or k + 3 >= len(es):
            break
        types.append(es[k + 3] & 0x1F)
        k += 3
    print(f'video first PES after: +{(i - s) * PKT_S:.3f} s, random_access_indicator {rai}, NAL types {types[:12]}'
          f'{" ..." if len(types) > 12 else ""}')
    break

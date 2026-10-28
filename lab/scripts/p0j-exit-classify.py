"""Classify a P0-j import exit from its hand-off ring.

usage: p0j-exit-classify.py <event-dir> <exit-hh:mm:ss.fff>   (VIDEO_AROUND=1 prints the video PES around the first)

Reports what the source did across the ring (discontinuity flags, CC errors, PCR steps, PES
timestamps stepping back), then replays 84b34f54's section stamping: every SCTE-35 section is
stamped with the PTS of the latest video PES header and written as its own group, and the
producer refuses a timestamp below the track's live edge. A section stamped below its PID's
previous one is where that build's import would end.
"""
import datetime as dt
import glob
import os
import sys

d, exit_hms = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(d, 'ring-*.ts')))
PKT_S = 188 * 8 / 25e6
WRAP_S = (1 << 33) / 90000


def step(a, b):
    """b - a in seconds, the shorter way round the 33-bit clock: a step back across the wrap is negative."""
    return (b - a + WRAP_S / 2) % WRAP_S - WRAP_S / 2


def t_of(name):
    s = os.path.basename(name)[5:20]
    return dt.datetime.strptime(s, '%Y%m%d-%H%M%S').replace(tzinfo=dt.timezone.utc).timestamp()


def hms(w):
    return dt.datetime.fromtimestamp(w, dt.timezone.utc).strftime('%H:%M:%S.%f')[:-3]


def ts33(b):
    return ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1


day = dt.datetime.fromtimestamp(t_of(files[0]), dt.timezone.utc).date()
h, m, s = exit_hms.split(':')
exit_w = dt.datetime(day.year, day.month, day.day, int(h), int(m), tzinfo=dt.timezone.utc).timestamp() + float(s)

pmt_pid = None
video_pid = None
scte = set()
pes_pids = {}
series = {}
pcr = {}
disc = []
cc_err = {}
last_cc = {}
total = synced = 0
sec_pkt = []         # packet index, in the concatenated ring, at which each section completes

last_pts = None      # 84b34f54's media clock: the latest video PES header's PTS
unwrap_base = 0
prev_raw = None
buf = {}
sections = []        # (wall, pid, stamp_s, command_type)


def unwrap(raw):
    global unwrap_base, prev_raw
    if prev_raw is not None and raw < prev_raw - (1 << 32):
        unwrap_base += 1 << 33
    prev_raw = raw
    return (raw + unwrap_base) / 90000


def emit(pid, sec, w):
    cmd = sec[13] if len(sec) > 13 else -1
    sections.append((w, pid, last_pts, cmd))
    sec_pkt.append(total - 1)


def section_bytes(pid, payload, pusi, w):
    if pusi:
        ptr = payload[0]
        rest = payload[1:]
        if pid in buf and buf[pid]:
            buf[pid] += rest[:ptr]
            drain(pid, w)
        buf[pid] = bytearray(rest[ptr:])
    elif pid in buf:
        buf[pid] += payload
    drain(pid, w)


def drain(pid, w):
    b = buf.get(pid)
    while b and len(b) >= 3:
        if b[0] == 0xFF:
            buf[pid] = bytearray()
            return
        n = 3 + (((b[1] & 0x0F) << 8) | b[2])
        if len(b) < n:
            return
        emit(pid, bytes(b[:n]), w)
        del b[:n]


for f in files:
    t0 = t_of(f)
    data = open(f, 'rb').read()
    for i in range(len(data) // 188):
        p = data[i * 188:(i + 1) * 188]
        total += 1
        if p[0] != 0x47:
            continue
        synced += 1
        pid = (p[1] & 0x1F) << 8 | p[2]
        if pid == 0x1FFF:
            continue
        pusi = bool(p[1] & 0x40)
        afc = (p[3] >> 4) & 3
        cc = p[3] & 15
        w = t0 + i * PKT_S
        off = 4
        di = False
        if afc & 2:
            alen = p[4]
            if alen:
                flags = p[5]
                di = bool(flags & 0x80)
                if flags & 0x10 and alen >= 7:
                    b = p[6:12]
                    base = b[0] << 25 | b[1] << 17 | b[2] << 9 | b[3] << 1 | b[4] >> 7
                    ext = (b[4] & 1) << 8 | b[5]
                    pcr.setdefault(pid, []).append((w, (base * 300 + ext) / 27e6))
            off = 5 + alen
            if di:
                disc.append((w, pid))
        if not afc & 1 or off >= 188:
            continue
        if pid in last_cc and not di and cc != (last_cc[pid] + 1) & 15 and cc != last_cc[pid]:
            cc_err.setdefault(pid, []).append((w, total - 1))
        last_cc[pid] = cc
        payload = p[off:]
        if pid == 0 and pusi and pmt_pid is None:
            sec = payload[1 + payload[0]:]
            pmt_pid = ((sec[10] & 0x1F) << 8) | sec[11]
            continue
        if pid == pmt_pid and pusi and video_pid is None:
            sec = payload[1 + payload[0]:]
            slen = ((sec[1] & 0x0F) << 8) | sec[2]
            pil = ((sec[10] & 0x0F) << 8) | sec[11]
            k = 12 + pil
            while k < 3 + slen - 4:
                st = sec[k]
                epid = ((sec[k + 1] & 0x1F) << 8) | sec[k + 2]
                eil = ((sec[k + 3] & 0x0F) << 8) | sec[k + 4]
                if st in (0x02, 0x1B, 0x24) and video_pid is None:
                    video_pid = epid
                elif st == 0x86:
                    scte.add(epid)
                pes_pids[epid] = st
                k += 5 + eil
            continue
        if pid in scte:
            section_bytes(pid, payload, pusi, w)
            continue
        if pusi and len(payload) >= 14 and payload[:3] == b'\x00\x00\x01':
            sid = payload[3]
            if sid in (0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xFF, 0xF2, 0xF8):
                continue
            fl = payload[7]
            if fl & 0x80:
                pts_raw = ts33(payload[9:14])
                v = pts_raw
                if fl & 0x40 and len(payload) >= 19:
                    v = ts33(payload[14:19])
                series.setdefault(pid, []).append((w, v / 90000))
                if pid == video_pid:
                    last_pts = unwrap(pts_raw)

print(f'== {os.path.basename(d.rstrip("/"))}: ring {hms(t_of(files[0]))} -> '
      f'{hms(t_of(files[-1]) + (os.path.getsize(files[-1]) // 188) * PKT_S)}, exit {exit_hms}')
print(f'packets {total:,}, synced {synced:,}; video PID {video_pid}, SCTE-35 PIDs {sorted(scte)}')
print('discontinuity_indicator:', len(disc), [(hms(w), p) for w, p in disc[:10]])
print('cc errors:', {k: len(v) for k, v in cc_err.items()} or 0)
if cc_err:
    at = sorted(x[1] for v in cc_err.values() for x in v)
    first = min(x[0] for v in cc_err.values() for x in v)
    print(f'   at packets {at[0]}–{at[-1]} of the concatenated ring ({hms(first)})')
for pid, s in sorted(pcr.items()):
    ds = [(hms(s[k][0]), round(step(s[k - 1][1], s[k][1]), 4)) for k in range(1, len(s))]
    steps = [x for x in ds if x[1] < -0.001 or x[1] > 0.025]
    worst = max(steps, key=lambda x: abs(x[1]), default=None)
    print(f'PCR pid {pid}: {len(s)} samples; {len(steps)} backward or > 25 ms, largest {worst}: {steps[:8]}')
for pid, s in sorted(series.items()):
    steps, mx, u = [], 0.0, 0.0
    for k in range(1, len(s)):
        u += step(s[k - 1][1], s[k][1])
        if u - mx < -0.5:
            steps.append((hms(s[k][0]), round(u - mx, 3)))
            mx = u
        else:
            mx = max(mx, u)
    gap = max((s[k][0] - s[k - 1][0], hms(s[k - 1][0])) for k in range(1, len(s)))
    print(f'PES pid {pid} (type 0x{pes_pids.get(pid, 0):02x}): {len(s)} PES; back > 0.5 s: {steps[:5]}; '
          f'largest wall gap {gap[0]:.3f} s after {gap[1]}')

names = {0x00: 'null', 0x05: 'insert', 0x06: 'time_signal'}
print(f'SCTE-35 sections: {len(sections)}; commands',
      {names.get(c, hex(c)): sum(1 for x in sections if x[3] == c) for c in {x[3] for x in sections}})
prev = {}
below = []
for w, pid, stamp, cmd in sections:
    if stamp is None:
        continue
    if pid in prev and stamp < prev[pid][1]:
        below.append((w, pid, stamp - prev[pid][1], w - prev[pid][0], names.get(cmd, hex(cmd)),
                      names.get(prev[pid][2], hex(prev[pid][2]))))
    prev[pid] = (w, stamp, cmd)
print(f'sections stamped below their predecessor: {len(below)}')
if below:
    k = next(j for j, x in enumerate(sections) if x[0] == below[0][0] and x[1] == below[0][1])
    print(f'   the first completes at packet {sec_pkt[k]} of the concatenated ring (cut with head -c N*188)')
for w, pid, ds, dw, cmd, pcmd in below:
    print(f'   {hms(w)} PID {pid} {cmd}: {ds * 1000:+.0f} ms below the {pcmd} {dw * 1000:.0f} ms before '
          f'(exit {w - exit_w:+.2f} s)')
for w, pid, stamp, cmd in sections:
    if cmd != 0x00:
        print(f'   cue {hms(w)} PID {pid} {names.get(cmd, hex(cmd))} stamp {stamp:.3f}')
if below and os.environ.get('VIDEO_AROUND'):
    w0 = below[0][0]
    vs = [x for x in series[video_pid] if w0 - 0.6 <= x[0] <= w0 + 0.1]
    secs = [x for x in sections if w0 - 0.6 <= x[0] <= w0 + 0.1]
    print('   video PES (wall, PTS-or-DTS key) and sections around the first:')
    for x in sorted([(a, 'V', b) for a, b in vs] + [(a, f'S{p}:{names.get(c, c)}', st) for a, p, st, c in secs]):
        print(f'      {hms(x[0])} {x[1]:>14} {x[2]:.3f}')

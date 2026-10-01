#!/usr/bin/env python3
"""Re-multiplex a transport stream under the T-STD, as an edge multiplexer could.

    ts-remux-oracle.py in.ts out.ts --rate BPS --delay S[,S...] [--avail packet|pes|frame]
                       [--duration S] [--pcr-ms MS] [--json PATH]

The question it answers is whether a receiver that has only each PID's packets,
in order, and the time each became available, can rebuild a multiplex that
meets the ISO/IEC 13818-1 T-STD, and at what added decoder delay. It keeps every
PID's packet order and bytes, discards the input's nulls and its interleave, and
fills each slot of a constant --rate output with the earliest-deadline packet
that is available and that its buffers have room for, otherwise a null. PCR is
rewritten on the output byte clock, with an adaptation-only PCR packet when none
has gone for --pcr-ms.

    --avail packet   a packet is available once it has arrived in the input: the
                     byte-faithful case, where only the nulls and their
                     positions are lost.
    --avail pes      a packet is available once its whole PES has arrived: when
                     PES_packet_length is met, else at the next PES start on its
                     PID. This is a lane that delivers each frame as one object.
                     PSI, SI and section PIDs stay at packet granularity.
    --avail frame    as pes, but an MPEG or AC-3 audio packet is available once
                     every audio frame it carries a byte of has arrived: a lane
                     that publishes each audio frame as its own object, as the
                     source packetization allows it to be approximated.
    --delay S        output PCR is lowered by S against the input's, so every
                     access unit decodes S later than it would in the input. The
                     smallest S at which nothing is late is the rebuild's cost in
                     decoder delay; with several, each is scheduled and the
                     smallest with no late packet is written.

Buffer parameters are ts-tstd.py's. Times are the input's own PCR-interpolated
times, so a constant transport latency cancels; availability is only as good as
the input's PCR. The scheduler is greedy earliest-deadline-first with buffer
gates, not an optimal one: a feasible result proves a schedule exists, an
infeasible one does not prove none does. ts-tstd.py grading the output is the
judge; the counts printed here are the scheduler's own.
"""

import argparse
import bisect
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("tstd", os.path.join(HERE, "ts-tstd.py"))
T = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(T)

PKT = T.PKT
NULL_PID = 0x1FFF
GUARD = 0.001  # seconds kept clear of every deadline and residence limit
EB_SLACK = 256  # bytes kept clear of every decoder buffer
SI_PIDS = (0x10, 0x11, 0x12, 0x14)


class Leaky:
    """ts-tstd.py's transport buffer, asked before a packet is sent rather than after."""

    def __init__(self, size, rx_bps):
        self.size, self.rx = float(size), rx_bps / 8.0
        self.occ, self.last = 0.0, 0.0

    def _at(self, t):
        return max(0.0, self.occ - self.rx * max(0.0, t - self.last))

    def room(self, t0, t1):
        drain = self.rx * (t1 - t0)
        peak = self._at(t0) if drain >= PKT else self._at(t0) + PKT - drain
        return peak <= self.size - 1.0

    def send(self, t0, t1):
        self.occ = max(0.0, self._at(t0) + PKT - self.rx * (t1 - t0))
        self.last = t1


class Stream:
    """One PID's packets, in order, with what the scheduler needs to know about each."""

    def __init__(self, pid, kind):
        self.pid, self.kind = pid, kind
        self.idx, self.arr, self.pusi, self.es_off, self.es_len = [], [], [], [], []
        self.pes_len = []  # declared PES_packet_length at a PES start, 0 if unbounded
        self.pts = []  # the PES timestamp at a start (seconds, input clock), else None
        self.units = []  # (t_decode, start, end) in the elementary byte stream
        self.avail = []
        self.in_pes = False  # a PES start has been seen, so payload is elementary data


def calibrate(path, kind, pid):
    """(TB bytes, Rx b/s, decoder bytes or None, residence limit s), as ts-tstd.py grades."""
    if kind in ("avc", "hevc"):
        br, cpb, level = T.video_hrd(path, pid)
        if br:
            ref = max(T.AVC_MAXBR.get(level, 20000) * 1200, 2_000_000)
            return 512, 1.2 * br, cpb / 8.0 + (0.004 * ref + ref / 750.0) / 8.0, 10.0
        if level in T.AVC_MAXBR:
            return 512, 1.2 * T.AVC_MAXBR[level] * 1200, None, 10.0
        return None
    if kind == "mpeg2v":
        return 512, 1.2 * 15_000_000, None, 1.0
    if kind in ("mpa", "ac3"):
        return 512, 2_000_000, 5696 if kind == "ac3" else 3584, 1.0
    if kind == "aac":
        return 512, 2_000_000, None, 1.0
    if kind == "teletext":
        return 480, 6_750_000, None, 1.0
    return 512, 1_000_000, None, 1.0  # systems data, SI and SCTE-35


def parse(path, duration):
    data, n = T.read_packets(path)
    mv = memoryview(data)
    pmt_pids, pcr_pid, streams = {}, None, {}
    pcr_raw, discont = [], 0
    for i in range(n):
        p = mv[i * PKT:(i + 1) * PKT]
        if p[0] != T.SYNC:
            continue
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if p[1] & 0x40 and pid == 0 and not pmt_pids:
            sec = T.section_body(bytes(T.payload_of(p)))
            if sec and sec[0] == 0x00:
                pmt_pids = T.parse_pat(sec)
        elif p[1] & 0x40 and pid in pmt_pids and not streams:
            sec = T.section_body(bytes(T.payload_of(p)))
            if sec and sec[0] == 0x02:
                pcr_pid, streams = T.parse_pmt(sec)
        if pcr_pid is not None and pid == pcr_pid:
            v = T.parse_pcr(p)
            if v is not None:
                if p[4] and p[5] & 0x80:
                    discont += 1
                pcr_raw.append((i * PKT + 11, v))
    if not streams or len(pcr_raw) < 2:
        sys.exit(f"{path}: no PMT or fewer than two PCRs")
    if discont:
        sys.exit(f"{path}: {discont} PCR discontinuities; cut the input to one timeline")
    samples, off, prev = [], 0, None
    for b, v in pcr_raw:
        if prev is not None and v + off < prev - T.PCR_MODULUS // 2:
            off += T.PCR_MODULUS
        samples.append((b, v + off))
        prev = v + off
    clock = T.TimeBase(samples)
    t_end = clock.t[0] + duration if duration else float("inf")

    kinds = {pid: T.classify(st, tags) for pid, (st, tags) in streams.items()}
    out = {}
    audio = {}
    first = samples[0][0] - 11
    for i in range(first // PKT, n):
        p = mv[i * PKT:(i + 1) * PKT]
        if p[0] != T.SYNC:
            continue
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if pid == NULL_PID:
            continue
        t1 = clock.at((i + 1) * PKT)
        if t1 > t_end:
            break
        s = out.get(pid)
        if s is None:
            kind = kinds.get(pid, "psi" if pid in (0, 1, *pmt_pids) else "si" if pid in SI_PIDS else "other")
            s = out[pid] = Stream(pid, kind)
            if kind in ("mpa", "ac3"):
                audio[pid] = T.AudioStream(kind)
        pl = bytes(T.payload_of(p))
        start = bool(p[1] & 0x40)
        pes_len, pts = 0, None
        es = b""
        pes_kind = s.kind not in ("psi", "si", "scte35")
        if pes_kind and start and len(pl) >= 9 and pl[:3] == b"\x00\x00\x01":
            pes_len = (pl[4] << 8) | pl[5]
            flags = pl[7]
            ts = None
            if flags & 0x80 and len(pl) >= 14:
                ts = T.pes_ts(pl[9:14])
            if flags & 0x40 and len(pl) >= 19:
                ts = T.pes_ts(pl[14:19])
            if ts is not None:
                pts = T.unwrap_to(ts * 300, t1 * T.TICKS) / T.TICKS
            es = pl[9 + pl[8]:]
            if pid in audio:
                audio[pid].pes_start(pts)
            elif s.kind in ("avc", "hevc", "mpeg2v"):
                total = s.es_off[-1] + s.es_len[-1] if s.es_off else 0
                if s.units and s.units[-1][2] is None:
                    s.units[-1] = (s.units[-1][0], s.units[-1][1], total)
                if pts is not None:
                    s.units.append((pts, total, None))
            s.in_pes = True
        elif not start and s.in_pes:
            es = pl
        if pid in audio and audio[pid].starts:
            audio[pid].feed(es)
        total = s.es_off[-1] + s.es_len[-1] if s.es_off else 0
        s.idx.append(i)
        s.arr.append(t1)
        s.pusi.append(start)
        s.es_off.append(total)
        s.es_len.append(len(es))
        s.pes_len.append(pes_len)
        s.pts.append(pts)
    for pid, a in audio.items():
        out[pid].units = a.units()
    for s in out.values():
        if s.units and s.units[-1][2] is None:
            s.units[-1] = (s.units[-1][0], s.units[-1][1], s.es_off[-1] + s.es_len[-1])
    return data, clock, pcr_pid, out


def availability(s, mode):
    """When each packet of `s` may be sent, under the chosen granularity."""
    if mode == "packet" or s.kind in ("psi", "si", "scte35", "other"):
        return list(s.arr)
    n = len(s.arr)
    if mode == "frame" and s.kind in ("mpa", "ac3") and s.units:
        # A packet can go once every audio frame it carries a byte of is complete.
        ends = [u[2] for u in s.units]
        done_at = []
        k = 0
        for end in ends:
            while k < n and s.es_off[k] + s.es_len[k] < end:
                k += 1
            done_at.append(s.arr[min(k, n - 1)])
        avail = [0.0] * n
        for k in range(n):
            last_byte = s.es_off[k] + max(s.es_len[k], 1) - 1
            j = bisect.bisect_right(ends, last_byte)
            avail[k] = done_at[j] if j < len(ends) else s.arr[-1]
        return avail
    avail = [0.0] * n
    starts = [k for k in range(n) if s.pusi[k]] + [n]
    if starts[0] != 0:
        for k in range(starts[0]):
            avail[k] = s.arr[k]
    for a, b in zip(starts, starts[1:]):
        # A bounded PES is complete with the last packet before the next start on its
        # PID; an unbounded one only when that next start shows it has ended.
        if s.pes_len[a]:
            done = s.arr[b - 1]
        else:
            done = s.arr[b] if b < n else s.arr[-1]
        for k in range(a, b):
            avail[k] = done
    return avail


def deadlines(s, delay, max_delay):
    """(deadline, earliest) per packet: decode by, and not before the residence limit."""
    n = len(s.arr)
    if s.units:
        starts = [u[1] for u in s.units]
        ends = [u[2] for u in s.units]
        dl, early = [0.0] * n, [float("-inf")] * n
        for k in range(n):
            j = bisect.bisect_right(ends, s.es_off[k])
            dl[k] = (s.units[j][0] + delay - GUARD) if j < len(ends) else float("inf")
            if s.es_len[k]:
                last = bisect.bisect_left(starts, s.es_off[k] + s.es_len[k]) - 1
                if last >= 0:
                    early[k] = s.units[last][0] + delay - max_delay + GUARD
        return dl, early
    if s.kind == "teletext":
        dl, cur = [0.0] * n, None
        for k in range(n):
            if s.pusi[k] and s.pts[k] is not None:
                cur = s.pts[k]
            dl[k] = (cur + delay - GUARD) if cur is not None else s.avail[k] + 0.2
        return dl, [float("-inf")] * n
    horizon = 0.3 if s.kind in ("scte35", "other") else 0.1
    return [a + horizon for a in s.avail], [float("-inf")] * n


def pcr_packet(pid, cc, ticks):
    base, ext = ticks // 300, ticks % 300
    p = bytearray(b"\xff" * PKT)
    p[0:4] = bytes([0x47, (pid >> 8) & 0x1F, pid & 0xFF, 0x20 | (cc & 0x0F)])
    p[4], p[5] = 183, 0x10
    p[6:12] = bytes([(base >> 25) & 0xFF, (base >> 17) & 0xFF, (base >> 9) & 0xFF, (base >> 1) & 0xFF,
                     ((base & 1) << 7) | 0x7E | ((ext >> 8) & 1), ext & 0xFF])
    return p


def write_pcr(p, ticks):
    base, ext = ticks // 300, ticks % 300
    p[6:12] = bytes([(base >> 25) & 0xFF, (base >> 17) & 0xFF, (base >> 9) & 0xFF, (base >> 1) & 0xFF,
                     ((base & 1) << 7) | 0x7E | ((ext >> 8) & 1), ext & 0xFF])


NULL = bytes([0x47, 0x1F, 0xFF, 0x10]) + b"\xff" * (PKT - 4)


def schedule(data, clock, pcr_pid, streams, calib, rate, delay, pcr_ms, write):
    slot = PKT * 8.0 / rate
    t0 = min(s.avail[0] for s in streams.values() if s.avail)
    t_last = max(s.avail[-1] for s in streams.values() if s.avail)
    base_ticks = round((t0 - delay) * T.TICKS)
    tbs, shared = {}, None
    for pid, s in streams.items():
        size, rx = calib[pid][0], calib[pid][1]
        if s.kind == "psi":
            shared = shared or Leaky(512, 1_000_000)
            tbs[pid] = shared
        else:
            tbs[pid] = Leaky(size, rx)
    ebs = {}
    for pid, s in streams.items():
        if calib[pid][2] and s.units:
            rm = sorted((u[0] + delay, u[2]) for u in s.units)
            ebs[pid] = {"size": calib[pid][2], "rm": rm, "ptr": 0, "removed": 0, "cum": 0}
    dls = {pid: deadlines(s, delay, calib[pid][3]) for pid, s in streams.items()}
    head = {pid: 0 for pid in streams}
    last_payload_cc = {}
    stats = {pid: {"late": 0, "late_max_ms": 0.0, "hold": [], "slack_min_ms": float("inf")} for pid in streams}
    out = bytearray() if write else None
    pcr_step = pcr_ms / 1000.0
    last_pcr = float("-inf")
    pcr_gap_max = 0.0
    nulls = pcr_only = 0
    remaining = sum(len(s.arr) for s in streams.values())
    n = 0
    pids = list(streams)
    while remaining:
        ta, tb = t0 + n * slot, t0 + (n + 1) * slot
        chosen = None
        # An adaptation-only packet repeats its PID's last counter, so none can go
        # before that PID has sent a payload packet to take the counter from.
        if (pcr_pid in last_payload_cc and ta - last_pcr >= pcr_step
                and tbs[pcr_pid].room(ta, tb)):
            chosen = "pcr"
        else:
            best = None
            for pid in pids:
                k = head[pid]
                s = streams[pid]
                if k >= len(s.arr) or s.avail[k] > ta:
                    continue
                dl, early = dls[pid]
                if early[k] > ta or not tbs[pid].room(ta, tb):
                    continue
                eb = ebs.get(pid)
                if eb is not None:
                    rm, p = eb["rm"], eb["ptr"]
                    while p < len(rm) and rm[p][0] <= tb:
                        eb["removed"] = max(eb["removed"], rm[p][1])
                        p += 1
                    eb["ptr"] = p
                    if eb["cum"] + s.es_len[k] - eb["removed"] > eb["size"] - EB_SLACK:
                        continue
                if best is None or dl[k] < best[0]:
                    best = (dl[k], pid)
            if best is not None:
                chosen = best[1]
        if chosen is None:
            nulls += 1
            if write:
                out += NULL
        elif chosen == "pcr":
            ticks = (base_ticks + (n * PKT + 11) * 8 * 27_000_000 // rate) % T.PCR_MODULUS
            tbs[pcr_pid].send(ta, tb)
            pcr_gap_max = max(pcr_gap_max, ta - last_pcr) if last_pcr > float("-inf") else 0.0
            last_pcr = ta
            pcr_only += 1
            if write:
                out += pcr_packet(pcr_pid, last_payload_cc[pcr_pid], ticks)
        else:
            s = streams[chosen]
            k = head[chosen]
            head[chosen] = k + 1
            remaining -= 1
            tbs[chosen].send(ta, tb)
            if chosen in ebs:
                ebs[chosen]["cum"] += s.es_len[k]
            st = stats[chosen]
            dl = dls[chosen][0][k]
            st["hold"].append(tb - s.avail[k])
            st["slack_min_ms"] = min(st["slack_min_ms"], (dl - tb) * 1000)
            if tb > dl:
                st["late"] += 1
                st["late_max_ms"] = max(st["late_max_ms"], (tb - dl) * 1000)
            i = s.idx[k]
            p = bytearray(data[i * PKT:(i + 1) * PKT])
            has_pcr = T.parse_pcr(p) is not None
            if chosen == pcr_pid and has_pcr:
                ticks = (base_ticks + (n * PKT + 11) * 8 * 27_000_000 // rate) % T.PCR_MODULUS
                write_pcr(p, ticks)
                pcr_gap_max = max(pcr_gap_max, ta - last_pcr) if last_pcr > float("-inf") else 0.0
                last_pcr = ta
            if (p[3] >> 4) & 0x1:
                last_payload_cc[chosen] = p[3] & 0x0F
            if write:
                out += p
        n += 1
        if ta > t_last + 30:
            break  # something can never be sent; report rather than spin
    report = {"delay_s": delay, "slots": n, "nulls": nulls, "pcr_only_packets": pcr_only,
              "pcr_gap_max_ms": round(pcr_gap_max * 1000, 2), "unsent": remaining, "pids": {}}
    late_total = remaining
    for pid, st in stats.items():
        h = sorted(st["hold"])
        late_total += st["late"]
        report["pids"][f"{pid:#06x}"] = {
            "kind": streams[pid].kind, "packets": len(streams[pid].arr), "late": st["late"],
            "late_max_ms": round(st["late_max_ms"], 1),
            "slack_min_ms": round(st["slack_min_ms"], 1) if h else None,
            "hold_median_ms": round(h[len(h) // 2] * 1000, 1) if h else None,
            "hold_max_ms": round(h[-1] * 1000, 1) if h else None,
        }
    report["late_total"] = late_total
    return report, out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--rate", type=int, required=True, help="output mux rate, b/s")
    ap.add_argument("--delay", required=True, help="added decoder delay in seconds, comma-separated")
    ap.add_argument("--avail", choices=("packet", "pes", "frame"), default="packet")
    ap.add_argument("--duration", type=float, default=0.0, help="use only the first S seconds of input")
    ap.add_argument("--pcr-ms", type=float, default=25.0)
    ap.add_argument("--json", metavar="PATH")
    a = ap.parse_args()

    data, clock, pcr_pid, streams = parse(a.input, a.duration)
    calib = {}
    for pid, s in streams.items():
        c = calibrate(a.input, s.kind, pid)
        if c is None:
            sys.exit(f"PID {pid:#x}: no buffer parameters for {s.kind}")
        calib[pid] = c
        s.avail = availability(s, a.avail)
    runs = []
    for d in [float(x) for x in a.delay.split(",")]:
        r, _ = schedule(data, clock, pcr_pid, streams, calib, a.rate, d, a.pcr_ms, write=False)
        runs.append(r)
        worst = max(r["pids"].items(), key=lambda kv: kv[1]["late"])
        print(f"delay {d * 1000:7.1f} ms: late packets {r['late_total']:>8}, unsent {r['unsent']}, "
              f"worst {worst[0]} ({worst[1]['kind']}) {worst[1]['late']} late, max {worst[1]['late_max_ms']} ms")
    ok = [r for r in runs if r["late_total"] == 0]
    pick = min(ok, key=lambda r: r["delay_s"]) if ok else runs[-1]
    r, out = schedule(data, clock, pcr_pid, streams, calib, a.rate, pick["delay_s"], a.pcr_ms, write=True)
    with open(a.output, "wb") as f:
        f.write(out)
    print(f"wrote {a.output} at delay {pick['delay_s'] * 1000:.1f} ms "
          f"({'no late packets' if r['late_total'] == 0 else 'LATE: ' + str(r['late_total'])}); "
          f"{r['nulls'] * 100.0 / r['slots']:.1f} % nulls, PCR gap max {r['pcr_gap_max_ms']} ms")
    for pid, v in r["pids"].items():
        print(f"  {pid} {v['kind']:9} packets {v['packets']:>8}  late {v['late']:>6}  "
              f"hold median {v['hold_median_ms']} ms max {v['hold_max_ms']} ms  slack min {v['slack_min_ms']} ms")
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"input": a.input, "rate": a.rate, "avail": a.avail, "duration": a.duration,
                       "calibration": {f"{p:#06x}": list(c) for p, c in calib.items()},
                       "sweep": runs, "written": r}, f, indent=1)
    return 0 if r["late_total"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

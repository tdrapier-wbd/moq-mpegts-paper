#!/usr/bin/env python3
"""Grade a transport stream against the ISO/IEC 13818-1 T-STD buffer model.

    ts-tstd.py capture.ts [--json out.json]
    ts-tstd.py --selftest

TR 101 290 P1/P2 grades the PCR, continuity and tables. It does not model the
decoder's buffers, so a stream can pass every check in it and still deliver a
PID's bytes faster than a receiver is required to drain them. This grades that
directly, on the stream's own clock: every byte's arrival time is interpolated
from the PCR (13818-1 2.4.2.2), and each buffer fills on arrival and leaks at the
rate the standard fixes for its stream type.

Two stages are modelled:

    TB      the transport buffer, complete 188-byte packets in, drained at Rx
            while non-empty (13818-1 2.4.2.4, Cor. 2-2009). 512 bytes for every
            elementary stream and for system data; 480 bytes for DVB teletext
            (EN 300 472). Overflow is a violation.

    EB / B  the decoder-side buffer: video MB+EB, audio B. Elementary-stream
            bytes in when their packet has arrived, an access unit out at its
            DTS (or PTS). An access unit whose last byte arrives after its
            decode time is an underflow; occupancy above the buffer size is an
            overflow. Arrival at this stage is taken at the packet's arrival,
            ignoring the TB/MB transfer delay, so underflow margins are
            optimistic by at most a few milliseconds.

Calibration, per stream type (Rx is the TB leak rate):

    AVC / HEVC video   Rx = 1.2 x BitRate[0] of the NAL HRD in the SPS, read with
                       ffmpeg's trace_headers; EBS = CpbSize[0]. Without HRD
                       parameters, the level's MaxBR (cpbBrNalFactor 1200).
    MPEG-2 video       Rx = 1.2 x Rmax(profile, level); pass --rx if not MP@ML/HL.
    MPEG-1/2 audio,    Rx = 2 Mb/s; BSn = 3,584 bytes (13818-1), 5,696 bytes for
    AC-3               AC-3 in DVB (A/52 Annex A 5.4).
    Teletext           TB 480 bytes, Rx = 6.75 Mb/s (EN 300 472 5).
    PAT/PMT/CAT        one TBsys, 512 bytes, Rxsys = 1 Mb/s.
    SI and SCTE-35     *assumed*: the standard defines no T-STD for them, so each
                       PID is graded against a systems-data TB (512 B, 1 Mb/s)
                       and reported separately from the normative buffers.

Attribution. The one repair a groomer that does not reorder packets can make to
the decoder buffers is a constant PCR-to-PTS offset. --offset-scan finds the
offsets at which each buffer, and all of them at once, would be legal. A groomer
that regenerates PCR can also let that offset drift, so --window S asks the same
question of every S-second window, where drift is negligible: a window with no
legal offset is a failure of the packet timing itself, not of the PCR. --skip S
simulates from the first PCR but counts nothing before S seconds, so a start-up
transient is not graded as steady state. Transport-buffer overflow does not
depend on the offset at all.

Exit status is 0 when no normative buffer overflows or underflows, 1 otherwise.
"""

import argparse
import bisect
import json
import re
import subprocess
import sys

PKT = 188
SYNC = 0x47
TICKS = 27_000_000.0
PCR_MODULUS = (1 << 33) * 300
EPS = 1e-6

# Level -> MaxBR in units of 1000 b/s (H.264 Table A-1), for streams without HRD.
AVC_MAXBR = {
    10: 64, 11: 192, 12: 384, 13: 768, 20: 2000, 21: 4000, 22: 4000, 30: 10000,
    31: 14000, 32: 20000, 40: 20000, 41: 50000, 42: 50000, 50: 135000, 51: 240000,
    52: 240000,
}
MP1_L2_KBPS = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
MP1_FS = [44100, 48000, 32000]
AC3_KBPS = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
AC3_FS = [48000, 44100, 32000]


# --- the models, independent of any file ---------------------------------------


class TransportBuffer:
    """A leaky bucket fed by whole packets at the transport rate, drained at Rx."""

    def __init__(self, name, size, rx_bps, normative=True, grade_from=float("-inf")):
        self.name, self.size, self.rx = name, float(size), rx_bps / 8.0
        self.normative = normative
        self.grade_from = grade_from  # simulate throughout, count only from here
        self.pids = set()
        self.occ = 0.0
        self.last = None
        self.packets = 0
        self.over_packets = 0
        self.over_events = 0
        self._in_over = False
        self.peak = 0.0
        self.since = None  # when the buffer last went from empty to occupied
        self.longest_nonempty = 0.0

    def packet(self, t0, t1):
        """One packet whose first byte arrives at t0 and last at t1 (seconds)."""
        if self.last is not None and t0 > self.last:
            gap = t0 - self.last
            if self.occ > EPS and self.rx * gap >= self.occ:
                emptied = self.last + self.occ / self.rx
                if self.since is not None and self.since >= self.grade_from:
                    self.longest_nonempty = max(self.longest_nonempty, emptied - self.since)
                self.since = None
            self.occ = max(0.0, self.occ - self.rx * gap)
        if self.occ <= EPS:
            self.since = t0
        drain = self.rx * max(0.0, t1 - t0)
        if drain >= PKT:
            peak = self.occ
            end = max(0.0, self.occ + PKT - drain)
        else:
            end = self.occ + PKT - drain
            peak = end
        self.occ = end
        self.last = t1
        graded = t0 >= self.grade_from
        if self.occ <= EPS:
            self.since = None
        elif self.since is not None and graded:
            self.longest_nonempty = max(self.longest_nonempty, t1 - self.since)
        if not graded:
            return
        self.packets += 1
        self.peak = max(self.peak, peak)
        if peak > self.size + EPS:
            self.over_packets += 1
            if not self._in_over:
                self.over_events += 1
            self._in_over = True
        else:
            self._in_over = False

    def report(self):
        return {
            "buffer": self.name,
            "pids": sorted(self.pids),
            "normative": self.normative,
            "size_bytes": self.size,
            "rx_bps": round(self.rx * 8),
            "packets": self.packets,
            "overflow_packets": self.over_packets,
            "overflow_events": self.over_events,
            "peak_bytes": round(self.peak, 1),
            "longest_nonempty_s": round(self.longest_nonempty, 3),
        }


class DecoderBuffer:
    """Elementary bytes in on arrival, access units out at their decode time."""

    def __init__(self, name, size, max_delay, grade_from=float("-inf")):
        self.name, self.size, self.max_delay = name, float(size), max_delay
        self.grade_from = grade_from  # simulate throughout, count only from here
        self.total = 0  # elementary bytes received so far
        self.arr_t = []
        self.cum = []
        self.units = []  # (t_decode, start, end) as offsets in the elementary byte stream

    def bytes_in(self, t, n):
        if n > 0:
            self.total += n
            self.arr_t.append(t)
            self.cum.append(self.total)

    def unit(self, t_decode, start, end):
        self.units.append((t_decode, start, end))

    def shifted(self, offset):
        """The same arrivals with every decode time moved `offset` seconds later.

        Equivalent to lowering every PCR by `offset`: it adds that much decoder delay
        without moving a byte, which is the one correction a groomer that does not
        reorder packets can apply.
        """
        d = DecoderBuffer(self.name, self.size, self.max_delay, self.grade_from)
        d.total, d.arr_t, d.cum = self.total, self.arr_t, self.cum
        d.units = [(t + offset, s, e) for t, s, e in self.units]
        return d

    def legal_interval(self, lo=float("-inf"), hi=float("inf")):
        """The exact set of constant decode-time offsets (s) that are legal in [lo, hi).

        Every constraint is monotone in the offset: an underflow bounds it below, and
        a residence limit or an overflow bounds it above. Decode order is stream order,
        so unit end offsets are non-decreasing. Returns (low, high); empty if low > high.
        """
        arr_t, cum = self.arr_t, self.cum
        low, high = float("-inf"), float("inf")
        ends = [e for _, _, e in self.units]
        for td, start, end in self.units:
            k = bisect.bisect_left(cum, end)
            if k >= len(cum):
                break
            first = arr_t[bisect.bisect_left(cum, start + 1)]
            if not lo <= first < hi:
                continue
            low = max(low, arr_t[k] - td)
            high = min(high, self.max_delay - (td - first))
        i0, i1 = bisect.bisect_left(arr_t, lo), bisect.bisect_left(arr_t, hi)
        for i in range(i0, i1):
            need = cum[i] - self.size  # this much must already have been removed
            if need <= EPS:
                continue
            j = bisect.bisect_left(ends, need)
            if j >= len(ends):
                break
            high = min(high, arr_t[i] - self.units[j][0])
        return low, high

    def report(self):
        # An access unit is complete when the cumulative arrivals reach its end offset,
        # and leaves the buffer, with every byte before it, at its decode time. Its
        # first byte's residence is bounded by 13818-1 2.4.2.6/2.4.2.7.
        arr_t, cum = self.arr_t, self.cum
        margins = []
        delays = []
        under = 0
        late = 0
        for td, start, end in self.units:
            k = bisect.bisect_left(cum, end)
            if k >= len(cum):
                break  # the capture ends before this unit is complete
            first = arr_t[bisect.bisect_left(cum, start + 1)]
            if first < self.grade_from:
                continue
            done = arr_t[k]
            margins.append(td - done)
            if done > td + EPS:
                under += 1
            delays.append(td - first)
            if td - first > self.max_delay + EPS:
                late += 1
        occ_peak = 0.0
        over = 0
        u = 0
        removed = 0
        units = sorted(self.units)
        for t, c in zip(arr_t, cum):
            while u < len(units) and units[u][0] <= t:
                removed = max(removed, units[u][2])
                u += 1
            occ = c - removed
            if t < self.grade_from:
                continue
            occ_peak = max(occ_peak, occ)
            if occ > self.size + EPS:
                over += 1
        ms = sorted(margins)
        return {
            "buffer": self.name,
            "size_bytes": self.size,
            "units": len(margins),
            "underflows": under,
            "margin_min_ms": round(ms[0] * 1000, 1) if ms else None,
            "margin_p01_ms": round(ms[len(ms) // 100] * 1000, 1) if ms else None,
            "margin_median_ms": round(ms[len(ms) // 2] * 1000, 1) if ms else None,
            "peak_bytes": round(occ_peak, 1),
            "overflow_arrivals": over,
            "max_delay_limit_s": self.max_delay,
            "residence_max_s": round(max(delays), 3) if delays else None,
            "residence_over_limit": late,
        }


# --- the stream ----------------------------------------------------------------


def parse_pcr(p):
    if (p[3] >> 4) & 0x3 not in (2, 3) or p[4] < 7 or not (p[5] & 0x10):
        return None
    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
    return base * 300 + (((p[10] & 0x01) << 8) | p[11])


def payload_of(p):
    afc = (p[3] >> 4) & 0x3
    if afc == 1:
        return p[4:]
    if afc == 3:
        return p[5 + p[4]:]
    return b""


def section_body(buf):
    """The PSI section in a PUSI payload, or None."""
    if not buf:
        return None
    ptr = buf[0]
    s = buf[1 + ptr:]
    if len(s) < 3:
        return None
    length = ((s[1] & 0x0F) << 8) | s[2]
    return s[: 3 + length] if len(s) >= 3 + length else None


def parse_pat(sec):
    pmts = {}
    body = sec[8:-4]
    for i in range(0, len(body) - 3, 4):
        prog = (body[i] << 8) | body[i + 1]
        pid = ((body[i + 2] & 0x1F) << 8) | body[i + 3]
        if prog != 0:
            pmts[pid] = prog
    return pmts


def parse_pmt(sec):
    pcr_pid = ((sec[8] & 0x1F) << 8) | sec[9]
    pil = ((sec[10] & 0x0F) << 8) | sec[11]
    i = 12 + pil
    end = len(sec) - 4
    streams = {}
    while i + 5 <= end:
        st = sec[i]
        pid = ((sec[i + 1] & 0x1F) << 8) | sec[i + 2]
        eil = ((sec[i + 3] & 0x0F) << 8) | sec[i + 4]
        desc = sec[i + 5: i + 5 + eil]
        tags = set()
        j = 0
        while j + 2 <= len(desc):
            tags.add(desc[j])
            j += 2 + desc[j + 1]
        streams[pid] = (st, tags)
        i += 5 + eil
    return pcr_pid, streams


def classify(st, tags):
    if st == 0x1B:
        return "avc"
    if st == 0x24:
        return "hevc"
    if st in (0x01, 0x02):
        return "mpeg2v"
    if st in (0x03, 0x04):
        return "mpa"
    if st == 0x81 or (st == 0x06 and 0x6A in tags):
        return "ac3"
    if st == 0x0F:
        return "aac"
    if st == 0x06 and 0x56 in tags:
        return "teletext"
    if st == 0x86:
        return "scte35"
    return "other"


def video_hrd(path, pid):
    """(BitRate, CpbSize bits, level) from the SPS via ffmpeg, or Nones."""
    try:
        out = subprocess.run(
            ["ffmpeg", "-hide_banner", "-t", "3", "-i", path, "-map", f"i:{pid:#x}",
             "-c", "copy", "-bsf:v", "trace_headers", "-f", "null", "-"],
            capture_output=True, text=True, timeout=120,
        ).stderr
    except (OSError, subprocess.TimeoutExpired):
        return None, None, None

    def field(name):
        m = re.search(rf"(?<!\w){name}(?!\w).*= (\d+)\s*$", out, re.M)
        return int(m.group(1)) if m else None

    level = field("level_idc") or field("general_level_idc")
    nal = field("nal_hrd_parameters_present_flag")
    brs, cps = field("bit_rate_scale"), field("cpb_size_scale")
    brv = field(r"bit_rate_value_minus1\[0\]")
    cpv = field(r"cpb_size_value_minus1\[0\]")
    if nal and None not in (brs, cps, brv, cpv):
        return (brv + 1) << (6 + brs), (cpv + 1) << (4 + cps), level
    return None, None, level


class TimeBase:
    """Byte arrival time from the PCR, interpolated per 13818-1 2.4.2.2."""

    def __init__(self, samples):
        # samples: (byte offset of the PCR's last byte, unwrapped 27 MHz ticks)
        self.b = [b for b, _ in samples]
        self.t = [t / TICKS for _, t in samples]

    def at(self, byte):
        b, t = self.b, self.t
        k = max(0, bisect.bisect_right(b, byte) - 1)
        if k >= len(b) - 1:
            k = len(b) - 2
        rate = (t[k + 1] - t[k]) / (b[k + 1] - b[k])
        return t[k] + (byte - b[k]) * rate


def read_packets(path):
    with open(path, "rb") as f:
        data = f.read()
    n = len(data) // PKT
    return data, n


def offset_sweep(decoders, offsets_ms):
    """Per decoder buffer, whether any constant PCR offset makes it legal."""
    rows = []
    for d in decoders.values():
        for ms in offsets_ms:
            r = d.shifted(ms / 1000.0).report()
            ok = not (r["underflows"] or r["overflow_arrivals"] or r["residence_over_limit"])
            rows.append({"buffer": d.name, "offset_ms": ms, "legal": ok, "underflows": r["underflows"],
                         "overflow_arrivals": r["overflow_arrivals"], "peak_bytes": r["peak_bytes"],
                         "residence_over_limit": r["residence_over_limit"],
                         "margin_min_ms": r["margin_min_ms"]})
    return rows


def offset_scan(decoders, lo_ms, hi_ms, step_ms):
    """The constant PCR offsets at which each decoder buffer, and all of them together, are legal.

    One PCR serves every PID, so a correction that fixes video and breaks audio is no
    correction: the joint set is the answer.
    """
    grid = list(range(lo_ms, hi_ms + 1, step_ms))
    per = {}
    for d in decoders.values():
        legal = []
        for ms in grid:
            r = d.shifted(ms / 1000.0).report()
            if not (r["underflows"] or r["overflow_arrivals"] or r["residence_over_limit"]):
                legal.append(ms)
        per[d.name] = legal
    joint = sorted(set.intersection(*(set(v) for v in per.values()))) if per else []

    def intervals(xs):
        out = []
        for x in xs:
            if out and x - out[-1][1] == step_ms:
                out[-1][1] = x
            else:
                out.append([x, x])
        return out

    return {"grid_ms": [lo_ms, hi_ms, step_ms],
            "per_buffer": {k: intervals(v) for k, v in per.items()},
            "joint": intervals(joint)}


def window_scan(decoders, t0, t1, window_s):
    """Whether a constant PCR offset exists within each window of `window_s` seconds.

    A groomer that regenerates PCR can move the PCR-to-PTS relation slowly, and then no
    single offset serves a whole capture even when the lane delivered every unit in
    time. Within a short window that drift is negligible, so a window with no legal
    offset is a failure of the packet timing itself. The deficit is how far apart the
    earliest and latest legal decode times are, i.e. how much deeper the buffer would
    have had to be in time for the window to pass.
    """
    edges = []
    t = t0
    while t + window_s <= t1:
        edges.append((t, t + window_s))
        t += window_s
    per = {d.name: [] for d in decoders.values()}
    joint = []
    for lo, hi in edges:
        jl, jh, any_units = float("-inf"), float("inf"), False
        for d in decoders.values():
            low, high = d.legal_interval(lo, hi)
            if low == float("-inf") and high == float("inf"):
                continue
            any_units = True
            per[d.name].append(low - high)
            jl, jh = max(jl, low), min(jh, high)
        if any_units:
            joint.append(jl - jh)

    def summary(deficits):
        bad = sorted(x for x in deficits if x > EPS)
        return {"windows": len(deficits), "legal": len(deficits) - len(bad),
                "deficit_median_ms": round(bad[len(bad) // 2] * 1000, 1) if bad else None,
                "deficit_max_ms": round(bad[-1] * 1000, 1) if bad else None}

    return {"window_s": window_s, "per_buffer": {k: summary(v) for k, v in per.items()},
            "joint": summary(joint)}


def grade(path, rx_override, assume_si=True, offsets_ms=(), scan=None, skip_s=0.0, window_s=0.0):
    data, n = read_packets(path)
    mv = memoryview(data)
    # Pass 1: PSI, PCR samples, discontinuities.
    pmt_pids, pcr_pid, streams = {}, None, {}
    pcr_raw = []
    discont = 0
    for i in range(n):
        p = mv[i * PKT:(i + 1) * PKT]
        if p[0] != SYNC:
            continue
        pid = ((p[1] & 0x1F) << 8) | p[2]
        pusi = p[1] & 0x40
        if pusi and pid == 0 and not pmt_pids:
            sec = section_body(bytes(payload_of(p)))
            if sec and sec[0] == 0x00:
                pmt_pids = parse_pat(sec)
        elif pusi and pid in pmt_pids and not streams:
            sec = section_body(bytes(payload_of(p)))
            if sec and sec[0] == 0x02:
                pcr_pid, streams = parse_pmt(sec)
        if pcr_pid is not None and pid == pcr_pid:
            v = parse_pcr(p)
            if v is not None:
                if (p[3] >> 4) & 0x2 and p[4] and p[5] & 0x80:
                    discont += 1
                pcr_raw.append((i * PKT + 11, v))
    if not streams or len(pcr_raw) < 2:
        sys.exit(f"{path}: no PMT or fewer than two PCRs")
    samples = []
    off = 0
    prev = None
    for b, v in pcr_raw:
        if prev is not None and v + off < prev - PCR_MODULUS // 2:
            off += PCR_MODULUS
        samples.append((b, v + off))
        prev = v + off
    tb_clock = TimeBase(samples)
    gf = tb_clock.t[0] + skip_s  # every buffer is simulated from the start, graded from here

    # Buffers.
    buffers = {}
    decoders = {}
    kinds = {}
    calib = {}
    sysbuf = TransportBuffer("TBsys (PAT/PMT/CAT)", 512, 1_000_000, grade_from=gf)
    sysbuf.pids.update({0, 1, *pmt_pids})
    for pid in (0, 1, *pmt_pids):
        buffers[pid] = sysbuf
    for pid, (st, tags) in streams.items():
        kind = classify(st, tags)
        kinds[pid] = kind
        rx, size, dec_size, note = None, 512, None, ""
        if kind in ("avc", "hevc"):
            br, cpb, level = video_hrd(path, pid)
            if br:
                rx, dec_size = 1.2 * br, cpb / 8.0
                note = f"NAL HRD BitRate {br} b/s, CpbSize {cpb} bits"
            elif level in AVC_MAXBR:
                maxbr = AVC_MAXBR[level] * 1200
                rx, dec_size = 1.2 * maxbr, None
                note = f"no HRD; level {level} MaxBR x 1200 = {maxbr} b/s"
            if dec_size is not None:
                # MBn per 13818-1 2.14.3.1: BSmux + BSoh from max(1200 x MaxBR, 2e6).
                ref = max(AVC_MAXBR.get(level, 20000) * 1200, 2_000_000)
                dec_size += (0.004 * ref + ref / 750.0) / 8.0
        elif kind == "mpeg2v":
            rx = 1.2 * 15_000_000
            note = "assumed MP@ML Rmax 15 Mb/s; pass --rx for other profiles"
        elif kind in ("mpa", "ac3", "aac"):
            rx = 2_000_000
            dec_size = 5696 if kind == "ac3" else 3584
            note = "other audio, Rx 2 Mb/s"
        elif kind == "teletext":
            rx, size = 6_750_000, 480
            note = "EN 300 472"
        elif kind == "scte35":
            rx = 1_000_000
            note = "assumed systems-data TB"
        if pid in rx_override:
            rx = rx_override[pid]
            note += " (Rx overridden)"
        if rx is None:
            continue
        normative = kind not in ("scte35", "other")
        tb = TransportBuffer(f"TB {pid} ({kind})", size, rx, normative, grade_from=gf)
        tb.pids.add(pid)
        buffers[pid] = tb
        calib[pid] = {"kind": kind, "stream_type": st, "rx_bps": round(rx), "tb_bytes": size,
                      "decoder_bytes": round(dec_size) if dec_size else None, "note": note}
        if dec_size and kind in ("avc", "hevc", "mpeg2v", "mpa", "ac3"):
            video = kind in ("avc", "hevc", "mpeg2v")
            # 1 s for every stream except ISO/IEC 14496 and 23008-2, which get 10 s.
            max_delay = 10.0 if kind in ("avc", "hevc") else 1.0
            decoders[pid] = DecoderBuffer(f"{'EB' if video else 'B'} {pid} ({kind})", dec_size, max_delay, gf)
    if assume_si:
        for pid in (0x10, 0x11, 0x12, 0x14):
            if pid not in buffers:
                tb = TransportBuffer(f"TB {pid} (SI, assumed)", 512, 1_000_000, normative=False, grade_from=gf)
                tb.pids.add(pid)
                buffers[pid] = tb

    # Pass 2: arrival, buffers, access units.
    first_byte = samples[0][0] - 11
    pes = {}  # video pid -> [t_decode, es_bytes]
    audio = {pid: AudioStream(kinds[pid]) for pid in decoders if kinds[pid] in ("mpa", "ac3")}
    counted = 0
    for i in range(first_byte // PKT, n):
        p = mv[i * PKT:(i + 1) * PKT]
        if p[0] != SYNC:
            continue
        pid = ((p[1] & 0x1F) << 8) | p[2]
        buf = buffers.get(pid)
        if buf is None:
            continue
        t0 = tb_clock.at(i * PKT)
        t1 = tb_clock.at((i + 1) * PKT)
        buf.packet(t0, t1)
        counted += 1
        dec = decoders.get(pid)
        if dec is None:
            continue
        pl = bytes(payload_of(p))
        started = False
        if p[1] & 0x40 and len(pl) >= 9 and pl[:3] == b"\x00\x00\x01":
            flags = pl[7]
            ts = None
            if flags & 0x80 and len(pl) >= 14:
                ts = pes_ts(pl[9:14])
            if flags & 0x40 and len(pl) >= 19:
                ts = pes_ts(pl[14:19])  # DTS, when present, is the decode time
            t_dec = unwrap_to(ts * 300, t1 * TICKS) / TICKS if ts is not None else None
            es = pl[9 + pl[8]:]
            started = True
        else:
            es = pl
        if pid in audio:
            if started:
                audio[pid].pes_start(t_dec)
            if audio[pid].starts:
                audio[pid].feed(es)
                dec.bytes_in(t1, len(es))
            continue
        if started:
            cur = pes.pop(pid, None)
            if cur is not None and cur[0] is not None:
                dec.unit(cur[0], cur[1], dec.total)  # one video access unit per PES
            pes[pid] = [t_dec, dec.total]
        if pid in pes:
            dec.bytes_in(t1, len(es))
    for pid, st in audio.items():
        for t, start, end in st.units():
            decoders[pid].unit(t, start, end)

    span = tb_clock.t[-1] - tb_clock.t[0]
    return {
        "file": path,
        "packets": n,
        "graded_packets": counted,
        "skip_s": skip_s,
        "pcr_pid": pcr_pid,
        "pcr_span_s": round(span, 3),
        "mean_rate_bps": round((samples[-1][0] - samples[0][0]) * 8 / span) if span else None,
        "pcr_discontinuities": discont,
        "calibration": calib,
        "transport_buffers": [b.report() for b in dict.fromkeys(buffers.values())],
        "decoder_buffers": [d.report() for d in decoders.values()],
        "offset_sweep": offset_sweep(decoders, offsets_ms),
        "offset_scan": offset_scan(decoders, *scan) if scan else None,
        "window_scan": window_scan(decoders, gf, tb_clock.t[-1], window_s) if window_s else None,
    }


def pes_ts(b):
    return (((b[0] >> 1) & 0x07) << 30) | (b[1] << 22) | ((b[2] >> 1) << 15) | (b[3] << 7) | (b[4] >> 1)


def unwrap_to(ticks, ref):
    k = round((ref - ticks) / PCR_MODULUS)
    return ticks + k * PCR_MODULUS


class AudioStream:
    """An audio PID's elementary bytes, split into frames once the capture is read.

    The PES timestamp belongs to the first frame that *starts* in that PES; later
    frames in it follow at the frame duration (13818-1 2.4.3.7).
    """

    def __init__(self, kind):
        self.kind = kind
        self.es = bytearray()
        self.starts = []  # (offset into es, t_decode or None)

    def pes_start(self, t):
        self.starts.append((len(self.es), t))

    def feed(self, b):
        self.es += b

    def units(self):
        es, out = bytes(self.es), []
        offs = [o for o, _ in self.starts]
        j = offs[0] if offs else 0
        cur_pes, k = None, 0
        while j + 8 <= len(es):
            size, dur = frame_len(es, j, self.kind)
            if size is None:
                j += 1
                continue
            if j + size > len(es):
                break
            p = bisect.bisect_right(offs, j) - 1
            if p != cur_pes:
                cur_pes, k = p, 0
            t = self.starts[p][1]
            if t is not None:
                out.append((t + k * dur, j, j + size))
            k += 1
            j += size
        return out


def frame_len(b, j, kind):
    if kind == "mpa":
        if b[j] != 0xFF or (b[j + 1] & 0xE0) != 0xE0:
            return None, None
        layer = (b[j + 1] >> 1) & 0x3
        br_i, fs_i, pad = b[j + 2] >> 4, (b[j + 2] >> 2) & 0x3, (b[j + 2] >> 1) & 0x1
        if layer != 2 or not 0 < br_i < 15 or fs_i > 2:  # layer II only
            return None, None
        fs = MP1_FS[fs_i]
        return 144000 * MP1_L2_KBPS[br_i] // fs + pad, 1152 / fs
    if kind == "ac3":
        if b[j] != 0x0B or b[j + 1] != 0x77:
            return None, None
        fscod, code = b[j + 4] >> 6, b[j + 4] & 0x3F
        if fscod > 2 or code >> 1 >= len(AC3_KBPS):
            return None, None
        kbps = AC3_KBPS[code >> 1]
        fs = AC3_FS[fscod]
        if fs == 48000:
            words = kbps * 2
        elif fs == 32000:
            words = kbps * 3
        else:
            words = int(kbps * 1536 / 44.1 / 16) + (code & 1)
        return words * 2, 1536 / fs
    return None, None


# --- self-test -----------------------------------------------------------------


def selftest():
    """Analytical cases for both stages, checked before any file is graded."""
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = got == want
        ok &= good
        print(f"  {'ok ' if good else 'FAIL'} {name}: {got} (want {want})")

    pkt = PKT * 8 / 11_000_000  # one packet at 11 Mb/s
    # Bytes enter at their own arrival times, so a packet drains while it arrives.
    # 2 Mb/s leak: three back-to-back packets peak at 564 - 3 x 34.2 = 461.5 B, four
    # at 615.3 B, so the fourth overflows and the third does not.
    for burst, want in ((3, 0), (4, 1), (10, 7)):
        tb = TransportBuffer("t", 512, 2_000_000)
        for k in range(burst):
            tb.packet(k * pkt, (k + 1) * pkt)
        check(f"audio TB, {burst} back-to-back at 11 Mb/s", tb.over_packets, want)
    # The same PID spaced at its own 192 kb/s never builds past one packet.
    tb = TransportBuffer("t", 512, 2_000_000)
    gap = PKT * 8 / 192_000
    for k in range(2000):
        tb.packet(k * gap, k * gap + pkt)
    check("audio TB, 192 kb/s spaced", (tb.over_packets, tb.peak <= PKT), (0, True))
    # Rx above the carrier: a 10.56 Mb/s leak cannot fill from a 9.95 Mb/s carrier
    # however long the run. From 11 Mb/s each packet drains 180.4 B while it arrives
    # and so gains 7.57 B; 67 packets hold 507 B, the 68th overflows.
    for rate, want in ((9_945_951, 0), (11_000_000, 3)):
        tb = TransportBuffer("t", 512, 1.2 * 8_797_568)
        d = PKT * 8 / rate
        for k in range(70):
            tb.packet(k * d, (k + 1) * d)
        check(f"video TB, 70 back-to-back at {rate} b/s", tb.over_packets, want)
    # Decoder buffer: a unit due at 1.0 s whose last byte lands at 1.1 s underflows by
    # 100 ms; one due at 2.0 s with bytes at 1.5 s has 500 ms of margin.
    db = DecoderBuffer("d", 10_000, 1.0)
    db.bytes_in(0.9, 400)
    db.bytes_in(1.1, 600)
    db.bytes_in(1.5, 1000)
    db.unit(1.0, 0, 1000)
    db.unit(2.0, 1000, 2000)
    r = db.report()
    check("decoder underflows", r["underflows"], 1)
    check("decoder margin min (ms)", r["margin_min_ms"], -100.0)
    check("decoder residence within 1 s", r["residence_over_limit"], 0)
    db = DecoderBuffer("d", 1500, 1.0)
    db.bytes_in(0.0, 1000)
    db.bytes_in(0.1, 1000)
    db.unit(1.2, 0, 2000)
    r = db.report()
    check("decoder overflow arrivals", r["overflow_arrivals"], 1)
    # First byte at 0.0 s, decoded at 1.2 s: 1.2 s of residence against a 1 s limit.
    check("decoder residence over 1 s", (r["residence_max_s"], r["residence_over_limit"]), (1.2, 1))
    # A unit due at 1.0 s whose bytes land at 0.9 and 1.1 s is legal only with at least
    # 100 ms of added decoder delay, and only up to 900 ms before its first byte has
    # waited a second: the scan must find exactly [+100, +900].
    db = DecoderBuffer("d", 10_000, 1.0)
    db.bytes_in(0.9, 400)
    db.bytes_in(1.1, 600)
    db.unit(1.0, 0, 1000)
    check("offset scan interval", offset_scan({0: db}, -500, 1500, 100)["joint"], [[100, 900]])
    check("exact legal interval", tuple(round(x, 6) for x in db.legal_interval()), (0.1, 0.9))
    # 2000 B into a 1500 B buffer: the unit must leave the moment its last byte lands.
    db = DecoderBuffer("d", 1500, 1.0)
    db.bytes_in(0.0, 1000)
    db.bytes_in(0.1, 1000)
    db.unit(1.2, 0, 2000)
    check("exact interval under overflow", tuple(round(x, 6) for x in db.legal_interval()), (-1.1, -1.1))
    # Frame parsers: MP1 L2 192 kb/s 48 kHz is 576 B / 24 ms; AC-3 192 kb/s 48 kHz is
    # 768 B / 32 ms.
    check("MP2 frame", frame_len(bytes([0xFF, 0xFD, 0xA4, 0, 0, 0, 0, 0]), 0, "mpa"), (576, 0.024))
    check("AC-3 frame", frame_len(bytes([0x0B, 0x77, 0, 0, 0x14, 0, 0, 0]), 0, "ac3"), (768, 0.032))
    return 0 if ok else 1


def print_report(r):
    print(f"{r['file']}: {r['packets']:,} packets, PCR PID {r['pcr_pid']}, "
          f"{r['pcr_span_s']} s at {r['mean_rate_bps']:,} b/s, "
          f"{r['pcr_discontinuities']} PCR discontinuities")
    for pid, c in sorted(r["calibration"].items()):
        print(f"  calib PID {pid:>5} {c['kind']:<9} Rx {c['rx_bps']:>11,} b/s  TB {c['tb_bytes']} B"
              f"  decoder {c['decoder_bytes'] or '-'} B  {c['note']}")
    print("  transport buffers:")
    for b in r["transport_buffers"]:
        tag = "" if b["normative"] else "  [assumed]"
        print(f"    {b['buffer']:<26} pkts {b['packets']:>9,}  overflow pkts {b['overflow_packets']:>8,}"
              f"  events {b['overflow_events']:>7,}  peak {b['peak_bytes']:>9,.0f} B"
              f"  longest non-empty {b['longest_nonempty_s']:.3f} s{tag}")
    print("  decoder buffers:")
    for d in r["decoder_buffers"]:
        print(f"    {d['buffer']:<26} units {d['units']:>7,}  underflows {d['underflows']:>6,}"
              f"  margin min/p1/median {d['margin_min_ms']}/{d['margin_p01_ms']}/{d['margin_median_ms']} ms"
              f"  peak {d['peak_bytes']:,.0f} of {d['size_bytes']:,.0f} B  overflow arrivals {d['overflow_arrivals']:,}"
              f"  residence max {d['residence_max_s']} s"
              f" (limit {d['max_delay_limit_s']:g}, over {d['residence_over_limit']:,})")
    if r["offset_sweep"]:
        print("  constant PCR offset sweep (decoder delay added, no byte moved):")
        for s in r["offset_sweep"]:
            print(f"    {s['buffer']:<26} {s['offset_ms']:>+6} ms  {'LEGAL' if s['legal'] else 'illegal':<7}"
                  f"  underflows {s['underflows']:>6,}  overflow arrivals {s['overflow_arrivals']:>7,}"
                  f"  peak {s['peak_bytes']:>11,.0f} B  residence over {s['residence_over_limit']:>6,}"
                  f"  margin min {s['margin_min_ms']} ms")
    sc = r.get("offset_scan")
    if sc:
        lo, hi, step = sc["grid_ms"]
        print(f"  legal constant PCR offsets, scanned {lo:+} to {hi:+} ms in {step} ms steps:")
        for name, iv in sc["per_buffer"].items():
            print(f"    {name:<26} {', '.join(f'[{a:+}, {b:+}]' for a, b in iv) or 'none'}")
        print(f"    {'all buffers at once':<26} {', '.join(f'[{a:+}, {b:+}]' for a, b in sc['joint']) or 'none'}")
    ws = r.get("window_scan")
    if ws:
        print(f"  windows of {ws['window_s']:g} s with a legal constant PCR offset:")
        for name, s in list(ws["per_buffer"].items()) + [("all buffers at once", ws["joint"])]:
            tail = (f"  deficit median {s['deficit_median_ms']} ms, max {s['deficit_max_ms']} ms"
                    if s["deficit_max_ms"] is not None else "")
            print(f"    {name:<26} {s['legal']:>5,} of {s['windows']:>5,}{tail}")


def verdict(r):
    bad = any(b["normative"] and b["overflow_packets"] for b in r["transport_buffers"])
    bad |= any(d["underflows"] or d["overflow_arrivals"] or d["residence_over_limit"]
               for d in r["decoder_buffers"])
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ts", nargs="?")
    ap.add_argument("--json", help="write the full report here")
    ap.add_argument("--rx", action="append", default=[], metavar="PID=BPS",
                    help="override a PID's TB leak rate")
    ap.add_argument("--no-si", action="store_true", help="skip the assumed SI buffers")
    ap.add_argument("--offset-sweep", default="", metavar="MS,MS,...",
                    help="re-grade the decoder buffers with every decode time moved this much later")
    ap.add_argument("--skip", type=float, default=0.0, metavar="S",
                    help="simulate from the first PCR but count violations only after S seconds")
    ap.add_argument("--offset-scan", default="", metavar="LO,HI,STEP",
                    help="find the constant PCR offsets (ms) at which the decoder buffers are legal")
    ap.add_argument("--window", type=float, default=0.0, metavar="S",
                    help="also ask, per window of S seconds, whether any constant offset is legal")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.ts:
        ap.error("a capture is required unless --selftest")
    rx = {}
    for o in a.rx:
        pid, bps = o.split("=")
        rx[int(pid, 0)] = float(bps)
    offsets = [int(x) for x in a.offset_sweep.split(",") if x.strip()]
    scan = tuple(int(x) for x in a.offset_scan.split(",")) if a.offset_scan else None
    r = grade(a.ts, rx, assume_si=not a.no_si, offsets_ms=offsets, scan=scan, skip_s=a.skip,
              window_s=a.window)
    print_report(r)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(r, f, indent=1)
    return verdict(r)


if __name__ == "__main__":
    sys.exit(main())

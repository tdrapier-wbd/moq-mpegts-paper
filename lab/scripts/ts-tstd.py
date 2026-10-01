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

Two stages are modelled (clauses are Rec. ITU-T H.222.0 (10/2014)):

    TB      the transport buffer, complete 188-byte packets in, drained at Rx
            while non-empty (2.4.2.3). 512 bytes for every elementary stream and
            for system data; 480 bytes for DVB teletext (EN 300 472). It shall
            not overflow and shall empty at least once every second (2.4.2.6);
            a stretch is measured to the moment the bytes it holds would have
            drained, so a backlog at the end of the capture still counts.

    MB+EB / B  the decoder-side buffers. Each byte reaches them when it leaves
            TB at Rx, not when its packet arrives (2.4.2.3); duplicate packets
            occupy TB but are not delivered. Audio B holds the PES headers too,
            each removed with the access unit it precedes, and takes an access
            unit out at its PTS. AVC video runs the leak method of 2.14.3.1
            exactly: PES bytes into MB, payload on to EB at Rbx while EB is not
            full, PES headers discarded as the payload behind them moves, an
            access unit out of EB at its DTS. Overflow of B or MB, underflow of
            B or EB (a byte of the unit not in the buffer at its decode time),
            and STD delay over 1 s (10 s for AVC) are violations.

Calibration, per stream type (Rx is the TB leak rate):

    AVC video          Rx = 1.2 x BitRate[0] of the NAL HRD in the SPS, read with
                       ffmpeg's trace_headers; EBS = CpbSize[0]; MBS = BSmux +
                       BSoh + 1200 x MaxCPB[level] - EBS; Rbx = 1200 x MaxBR
                       (2.14.3.1). Without HRD parameters, BitRate is the
                       level's cpbBrNalFactor x MaxBR and EBS 1200 x MaxCPB.
    MPEG-1/2 audio,    Rx = 2 Mb/s; BSn = 3,584 bytes (2.4.2.3), 5,696 bytes for
    AC-3               AC-3 in DVB (A/52 Annex A 5.4).
    Teletext           TB 480 bytes, Rx = 6.75 Mb/s (EN 300 472 5).
    PAT/PMT/CAT        one TBsys, 512 bytes, Rxsys = 1 Mb/s.
    SI and SCTE-35     *assumed*: the standard defines no T-STD for them, so each
                       PID is graded against a systems-data TB (512 B, 1 Mb/s)
                       and reported separately from the normative buffers.

Refused, never passed: an audio or video stream this does not calibrate or
cannot time is listed under "refused" with the reason, and its unmodelled
buffers are not graded. That covers HEVC (its tier and level limits are not
tabulated here), MPEG-2 video and AAC decoder buffers (TB only), an AVC stream
with no SPS in its first 3 s or an unknown level, and AVC carrying an access
unit without a timestamp or several access units in one PES. The attribution
tools below (--offset-sweep, --offset-scan) re-run the exact models; --window
uses MB+EB as one buffer of MBS + EBS, which the leak can only make stricter.

Attribution. The one repair a groomer that does not reorder packets can make to
the decoder buffers is a constant PCR-to-PTS offset. --offset-scan finds the
offsets at which each buffer, and all of them at once, would be legal. A groomer
that regenerates PCR can also let that offset drift, so --window S asks the same
question of every S-second window, where drift is negligible: a window with no
legal offset is a failure of the packet timing itself, not of the PCR. --skip S
simulates from the first PCR but counts nothing before S seconds, so a start-up
transient is not graded as steady state. Transport-buffer overflow does not
depend on the offset at all.

Exit status is 0 when every normative buffer is graded and none is violated, 1
when one is violated, and 2 when none is violated but a stream was refused.
"""

import argparse
import array
import bisect
import collections
import copy
import json
import math
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
# Level -> MaxCPB in units of 1000 bits (H.264 Table A-1).
AVC_MAXCPB = {
    10: 175, 11: 500, 12: 1000, 13: 2000, 20: 2000, 21: 4000, 22: 4000, 30: 10000,
    31: 14000, 32: 20000, 40: 25000, 41: 62500, 42: 62500, 50: 135000, 51: 240000,
    52: 240000,
}
# profile_idc -> cpbBrNalFactor (H.264 Table A-2), for the default BitRate without HRD.
AVC_NAL_FACTOR = {100: 1500, 110: 3600, 122: 4800, 244: 4800}
TB_EMPTY_S = 1.0
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
        self.over_1s = 0  # stretches that did not empty within a second
        self._flagged = False
        self.first = {}  # the first violation of each kind

    def _stretch(self, until, now):
        """The current stretch has lasted, or will have when TB drains, until `until`."""
        if self.since is None or self.since < self.grade_from:
            return
        self.longest_nonempty = max(self.longest_nonempty, until - self.since)
        if until - self.since > TB_EMPTY_S + EPS and not self._flagged:
            self.over_1s += 1
            self._flagged = True
            self.first.setdefault("not_emptied_within_1s", {"t": now, "busy_since": self.since})

    def packet(self, t0, t1):
        """One packet whose first byte arrives at t0 and last at t1 (seconds).

        Returns (t0, occupancy at t0, seconds per arriving byte): the packet's q-th
        byte (1..188) leaves TB at t0 + max((occupancy + q) / Rx, q x that), the
        later of draining everything ahead of it and its own arrival.
        """
        if self.last is not None and t0 > self.last:
            gap = t0 - self.last
            if self.occ > EPS and self.rx * gap >= self.occ:
                self._stretch(self.last + self.occ / self.rx, t0)
                self.since, self._flagged = None, False
            self.occ = max(0.0, self.occ - self.rx * gap)
        if self.occ <= EPS:
            self.since, self._flagged = t0, False
        occ0 = self.occ
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
        self._stretch(t1 + self.occ / self.rx, t1)
        if self.occ <= EPS:
            self.since, self._flagged = None, False
        exit_params = (t0, occ0, (t1 - t0) / PKT)
        if not graded:
            return exit_params
        self.packets += 1
        self.peak = max(self.peak, peak)
        if peak > self.size + EPS:
            self.over_packets += 1
            self.first.setdefault("overflow", {"t": t0, "fill": round(peak, 1)})
            if not self._in_over:
                self.over_events += 1
            self._in_over = True
        else:
            self._in_over = False
        return exit_params

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
            "not_emptied_within_1s": self.over_1s,
            "first": self.first,
        }


class DecoderBuffer:
    """B: elementary bytes in as they leave TB, access units out at their decode time.

    Bytes come in batches, one per packet. A batch fed with its packet's TB exit
    parameters is timed byte by byte, so a unit ending inside a packet is complete
    when its own last byte has left TB, not the packet's (2.4.2.3); a batch fed
    with a bare time arrives all at once.
    """

    def __init__(self, name, size, max_delay, grade_from=float("-inf"), rx_bps=None):
        self.name, self.size, self.max_delay = name, float(size), max_delay
        self.grade_from = grade_from  # simulate throughout, count only from here
        self.rx = rx_bps / 8.0 if rx_bps else None
        self.total = 0  # elementary bytes received so far
        self.arr_t = array.array("d")  # when each batch's last byte has left TB
        self.cum = array.array("q")  # elementary bytes through the end of each batch
        # Batch k's j-th byte (1-based) leaves TB at t0 + max((c0 + j) / Rx, (h + j) x a)
        # and entered it at t0 + (h + j) x a; a < 0 marks a batch that arrives at t0.
        self.b_t0, self.b_c0, self.b_h, self.b_a = (array.array("d") for _ in range(4))
        self.headers = []  # (time in, ES offset of the byte it precedes, bytes)
        self.units = []  # (t_decode, start, end) as offsets in the elementary byte stream

    def bytes_in(self, t, n, tb=None, pos=0):
        """n elementary bytes, the last `pos` bytes into their packet, whose TB exit is `tb`."""
        if n <= 0:
            return
        if tb is None:
            t0, c0, h, a = t, 0.0, 0.0, -1.0
            t = t0
        else:
            t0, occ0, a = tb
            c0, h = occ0 + pos, float(pos)
            t = t0 + max((c0 + n) / self.rx, (h + n) * a)
        self.total += n
        self.arr_t.append(t)
        self.cum.append(self.total)
        self.b_t0.append(t0)
        self.b_c0.append(c0)
        self.b_h.append(h)
        self.b_a.append(a)

    def tb_exit(self, tb, q):
        """When byte q (1..188) of the packet with TB exit `tb` leaves TB."""
        t0, occ0, a = tb
        return t0 + max((occ0 + q) / self.rx, q * a)

    def header_in(self, t, offset, n):
        self.headers.append((t, offset, n))

    def unit(self, t_decode, start, end):
        self.units.append((t_decode, start, end))

    def _exit(self, k, j):
        a = self.b_a[k]
        if a < 0:
            return self.b_t0[k]
        return self.b_t0[k] + max((self.b_c0[k] + j) / self.rx, (self.b_h[k] + j) * a)

    def _base(self, k):
        return self.cum[k - 1] if k else 0

    def done_at(self, end):
        """When the byte ending at ES offset `end` has left TB, or None past the capture."""
        k = bisect.bisect_left(self.cum, end)
        return None if k >= len(self.cum) else self._exit(k, end - self._base(k))

    def first_at(self, start):
        """When the byte after ES offset `start` entered TB, t(i) of 2.4.2.6."""
        k = bisect.bisect_left(self.cum, start + 1)
        if k >= len(self.cum):
            return None
        return self.b_t0[k] + max(self.b_a[k], 0.0) * (self.b_h[k] + start + 1 - self._base(k))

    def exited_by(self, t):
        """The ES offset that has left TB by time t."""
        k = bisect.bisect_right(self.arr_t, t)
        base = self._base(k)
        if k >= len(self.cum) or self.b_a[k] < 0:
            return base
        dt, a = t - self.b_t0[k], self.b_a[k]
        j = self.rx * dt - self.b_c0[k]
        if a > 0:
            j = min(j, dt / a - self.b_h[k])
        return base + max(0, min(self.cum[k] - base, math.floor(j + 1e-9)))

    def shifted(self, offset):
        """The same arrivals with every decode time moved `offset` seconds later.

        Equivalent to lowering every PCR by `offset`: it adds that much decoder delay
        without moving a byte, which is the one correction a groomer that does not
        reorder packets can apply.
        """
        d = copy.copy(self)
        d.units = [(t + offset, s, e) for t, s, e in self.units]
        return d

    def legal_interval(self, lo=float("-inf"), hi=float("inf")):
        """The set of constant decode-time offsets (s) that are legal in [lo, hi).

        Every constraint is monotone in the offset: an underflow bounds it below, and
        a residence limit or an overflow bounds it above. Decode order is stream order,
        so unit end offsets are non-decreasing. Returns (low, high); empty if low > high.
        Overflow is tested at batch ends without PES headers, and a video MB+EB as one
        buffer of their summed size, so the interval can only be wider than the models'.
        """
        arr_t, cum = self.arr_t, self.cum
        low, high = float("-inf"), float("inf")
        ends = [e for _, _, e in self.units]
        for td, start, end in self.units:
            done = self.done_at(end)
            if done is None:
                break
            first = self.first_at(start)
            if not lo <= first < hi:
                continue
            low = max(low, done - td)
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

    def _occupancy(self):
        """(peak, overflowing batch ends, overflowing instants just before a removal).

        Fill only falls at removals, so testing every batch end and the instant
        before every removal finds every overflow. A PES header leaves with the
        first access unit that ends past the byte it precedes.
        """
        units = sorted(self.units)
        ends = [e for _, _, e in units]
        hdr = self.headers
        owner = [bisect.bisect_right(ends, o) for _, o, _ in hdr]
        held = [0] * (len(units) + 1)
        gf, size = self.grade_from, self.size + EPS
        peak, over, over_rm = 0.0, 0, 0
        removed = u = hp = hsum = 0
        self.first.pop("overflow", None)

        def headers_until(t):
            nonlocal hp, hsum
            while hp < len(hdr) and hdr[hp][0] <= t:
                if owner[hp] >= u:  # one arriving after its unit has gone is never held
                    held[owner[hp]] += hdr[hp][2]
                    hsum += hdr[hp][2]
                hp += 1

        for i in range(len(self.cum)):
            t = self.arr_t[i]
            while u < len(units) and units[u][0] <= t:
                td, _s, e = units[u]
                headers_until(td)
                occ = self.exited_by(td) - removed + hsum
                if td >= gf:
                    peak = max(peak, occ)
                    if occ > size:
                        over_rm += 1
                        self.first.setdefault("overflow", {"t": td, "fill": occ})
                removed = max(removed, e)
                hsum -= held[u]
                u += 1
            headers_until(t)
            occ = self.cum[i] - removed + hsum
            if t >= gf:
                peak = max(peak, occ)
                if occ > size:
                    over += 1
                    self.first.setdefault("overflow", {"t": t, "fill": occ})
        return peak, over, over_rm

    def report(self):
        # An access unit is complete when its last byte has left TB, and leaves the
        # buffer, with every byte before it, at its decode time. The delay of its first
        # byte through the T-STD is bounded by 2.4.2.6.
        margins = []
        delays = []
        under = 0
        late = 0
        self.first = {}
        for td, start, end in self.units:
            done = self.done_at(end)
            if done is None:
                break  # the capture ends before this unit is complete
            first = self.first_at(start)
            if first < self.grade_from:
                continue
            margins.append(td - done)
            if done > td + EPS:
                under += 1
                self.first.setdefault("underflow", {"unit_td": td, "complete": done, "first_byte": first,
                                                    "late_ms": round((done - td) * 1000, 3)})
            delays.append(td - first)
            if td - first > self.max_delay + EPS:
                late += 1
                self.first.setdefault("residence", {"unit_td": td, "first_byte": first,
                                                    "delay_s": round(td - first, 4)})
        peak, over, over_rm = self._occupancy()
        ms = sorted(margins)
        return {
            "buffer": self.name,
            "size_bytes": self.size,
            "units": len(margins),
            "underflows": under,
            "margin_min_ms": round(ms[0] * 1000, 1) if ms else None,
            "margin_p01_ms": round(ms[len(ms) // 100] * 1000, 1) if ms else None,
            "margin_median_ms": round(ms[len(ms) // 2] * 1000, 1) if ms else None,
            "peak_bytes": round(peak, 1),
            "overflow_arrivals": over,
            "overflow_before_removal": over_rm,
            "max_delay_limit_s": self.max_delay,
            "residence_max_s": round(max(delays), 3) if delays else None,
            "residence_over_limit": late,
            "first": self.first,
        }


class LeakBuffer(DecoderBuffer):
    """AVC MB and EB under the leak method of 2.14.3.1.

    MB takes each PES byte as it leaves TB and passes payload to EB at Rbx while EB
    is not full; a PES header in MB is discarded when the payload byte behind it
    moves. EB's input D is then the greediest curve that never exceeds MB's input A
    or EB's room W (removed offset + EBS) and never rises faster than Rbx:
    D(t) = min(A(t), W(t), inf over s <= t of [min(A(s), W(s)) + Rbx (t - s)]).
    A and W are piecewise linear between batch ends, batch starts and removals, so
    the infimum is taken at those points. MB fill A - D (+ headers) only rises
    within a batch, so its peak is at a batch end; EB fill only falls at removals.
    A unit underflows when D has not reached its end at its decode time.
    """

    def __init__(self, name, ebs, mbs, rbx_bps, max_delay, grade_from=float("-inf"), rx_bps=None):
        super().__init__(name, ebs + mbs, max_delay, grade_from, rx_bps)
        self.ebs, self.mbs, self.rbx = float(ebs), float(mbs), rbx_bps / 8.0
        self.mb_headers = []

    def header_in(self, t, offset, n):
        self.mb_headers.append((t, offset, n))

    def _leak(self):
        rbx, ebs, gf = self.rbx, self.ebs, self.grade_from
        cum, arr_t, hdr = self.cum, self.arr_t, self.mb_headers
        units = sorted(self.units)
        nb, nu = len(cum), len(units)
        inf_part = math.inf  # inf over folded points s of min(A(s), W(s)) - Rbx s
        out, room = 0, ebs
        under, over, mb_peak, eb_peak = 0, 0, 0.0, 0.0
        first = {}
        held = collections.deque()
        hp = hsum = 0
        i = u = 0
        at_start = True

        def fold(t, a):
            nonlocal inf_part
            inf_part = min(inf_part, min(a, room) - rbx * t)
            return min(a, room, inf_part + rbx * t)

        while i < nb or u < nu:
            tb = (self._exit(i, 1) if at_start else arr_t[i]) if i < nb else math.inf
            tr = units[u][0] if u < nu else math.inf
            if tb <= tr:
                if at_start:
                    fold(tb, self._base(i))
                    at_start = False
                    continue
                while hp < len(hdr) and hdr[hp][0] <= tb:
                    held.append(hdr[hp])
                    hsum += hdr[hp][2]
                    hp += 1
                d = fold(tb, cum[i])
                while held and held[0][1] < d:
                    hsum -= held.popleft()[2]
                if tb >= gf:
                    fill = cum[i] - d + hsum
                    mb_peak = max(mb_peak, fill)
                    if fill > self.mbs + 0.5:
                        over += 1
                        first.setdefault("overflow", {"t": tb, "fill": round(fill, 1)})
                i += 1
                at_start = True
            else:
                td, start, end = units[u]
                d = fold(td, self.exited_by(td))
                t_in = self.first_at(start)
                if t_in is not None and t_in >= gf:
                    eb_peak = max(eb_peak, d - out)
                    if self.done_at(end) is not None and end - d > 1e-3:
                        under += 1
                        first.setdefault("underflow", {"unit_td": td, "first_byte": t_in,
                                                       "missing_bytes": round(end - d, 1)})
                out = max(out, end)
                room = out + ebs
                u += 1
        return under, over, mb_peak, eb_peak, first

    def report(self):
        r = super().report()
        under, over, mb_peak, eb_peak, first = self._leak()
        first["residence"] = r["first"].get("residence")
        r.update({
            "first": {k: v for k, v in first.items() if v},
            "buffer": self.name.replace("EB ", "MB+EB "),
            "underflows": under,
            "overflow_arrivals": over,
            "overflow_before_removal": 0,  # EB cannot overflow: MB stops when it is full
            "mb_size_bytes": round(self.mbs),
            "eb_size_bytes": round(self.ebs),
            "rbx_bps": round(self.rbx * 8),
            "mb_peak_bytes": round(mb_peak, 1),
            "eb_peak_bytes": round(eb_peak, 1),
        })
        return r


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


def video_hrd(path, pid, profile=False):
    """(BitRate, CpbSize bits, level[, profile_idc]) from the SPS via ffmpeg, or Nones."""
    try:
        out = subprocess.run(
            ["ffmpeg", "-hide_banner", "-t", "3", "-i", path, "-map", f"i:{pid:#x}",
             "-c", "copy", "-bsf:v", "trace_headers", "-f", "null", "-"],
            capture_output=True, text=True, timeout=120,
        ).stderr
    except (OSError, subprocess.TimeoutExpired):
        return (None, None, None, None) if profile else (None, None, None)

    def field(name):
        m = re.search(rf"(?<!\w){name}(?!\w).*= (\d+)\s*$", out, re.M)
        return int(m.group(1)) if m else None

    level = field("level_idc") or field("general_level_idc")
    nal = field("nal_hrd_parameters_present_flag")
    brs, cps = field("bit_rate_scale"), field("cpb_size_scale")
    brv = field(r"bit_rate_value_minus1\[0\]")
    cpv = field(r"cpb_size_value_minus1\[0\]")
    hrd = (None, None)
    if nal and None not in (brs, cps, brv, cpv):
        hrd = ((brv + 1) << (6 + brs), (cpv + 1) << (4 + cps))
    return (*hrd, level, field("profile_idc")) if profile else (*hrd, level)


def avc_buffers(level, br, cpb, profile=None):
    """(Rx b/s, EBS bytes, MBS bytes, Rbx b/s, note) for AVC per 2.14.3.1.

    EBS = cpb_size; MBS = BSmux + BSoh + 1200 x MaxCPB[level] - cpb_size, with BSmux and
    BSoh 4 ms and 1/750 s of max(1200 x MaxBR[level], 2 Mb/s); Rbx = 1200 x MaxBR[level];
    Rx = 1.2 x BitRate. Without NAL HRD, BitRate is cpbBrNalFactor x MaxBR (H.264 E.2.2)
    and cpb_size 1200 x MaxCPB.
    """
    if br:
        note = f"NAL HRD BitRate {br} b/s, CpbSize {cpb} bits"
    else:
        br = AVC_NAL_FACTOR.get(profile, 1200) * AVC_MAXBR[level]
        cpb = 1200 * AVC_MAXCPB[level]
        note = f"no HRD; level {level} defaults BitRate {br} b/s, CpbSize {cpb} bits"
    rbx = 1200 * AVC_MAXBR[level]
    ref = max(rbx, 2_000_000)
    ebs = cpb / 8.0
    mbs = (0.004 * ref + ref / 750.0 + 1200 * AVC_MAXCPB[level]) / 8.0 - ebs
    return 1.2 * br, ebs, mbs, rbx, f"{note}; level {level}, MBS {mbs:.0f} B, Rbx {rbx} b/s"


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
            ok = not violated(r)
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
            if not violated(r):
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
    refused = {}
    for pid, (st, tags) in streams.items():
        kind = classify(st, tags)
        kinds[pid] = kind
        rx, size, model, note = None, 512, None, ""
        if kind == "avc":
            br, cpb, level, profile = video_hrd(path, pid, profile=True)
            if level not in AVC_MAXBR:
                refused[pid] = ("no SPS in the first 3 s" if level is None
                                else f"level_idc {level} is not tabulated")
            else:
                rx, ebs, mbs, rbx, note = avc_buffers(level, br, cpb, profile)
                model = ("leak", ebs, mbs, rbx)
        elif kind == "hevc":
            refused[pid] = "HEVC tier and level limits are not tabulated here"
        elif kind == "mpeg2v":
            rx = 1.2 * 15_000_000
            note = "assumed MP@ML Rmax 15 Mb/s; pass --rx for other profiles"
            refused[pid] = "MB and EB for MPEG-2 video are not modelled (TB graded)"
        elif kind in ("mpa", "ac3"):
            rx = 2_000_000
            model = ("b", 5696 if kind == "ac3" else 3584)
            note = "other audio, Rx 2 Mb/s"
        elif kind == "aac":
            rx = 2_000_000
            note = "other audio, Rx 2 Mb/s"
            refused[pid] = "B for AAC is not modelled (TB graded)"
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
        dec_bytes = None
        if model and model[0] == "leak":
            _, ebs, mbs, rbx = model
            dec_bytes = ebs + mbs
            # 1 s for every stream except ISO/IEC 14496 and 23008-2, which get 10 s.
            decoders[pid] = LeakBuffer(f"EB {pid} ({kind})", ebs, mbs, rbx, 10.0, gf, rx)
        elif model:
            dec_bytes = model[1]
            decoders[pid] = DecoderBuffer(f"B {pid} ({kind})", dec_bytes, 1.0, gf, rx)
        calib[pid] = {"kind": kind, "stream_type": st, "rx_bps": round(rx), "tb_bytes": size,
                      "decoder_bytes": round(dec_bytes) if dec_bytes else None, "note": note}
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
    last = {}  # pid -> (continuity counter, payload) of its last packet with a payload
    dups = collections.Counter()
    auds = {pid: [0, b"", 0] for pid in decoders if kinds[pid] == "avc"}  # in this PES, tail, total
    several, untimed = set(), set()
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
        tb = buf.packet(t0, t1)
        counted += 1
        dec = decoders.get(pid)
        if dec is None:
            continue
        pl = bytes(payload_of(p))
        if (p[3] >> 4) & 0x1:
            # A duplicate (2.4.3.3) occupies TB but is not delivered (2.4.2.3).
            key = (p[3] & 0x0F, pl)
            if last.get(pid) == key:
                dups[pid] += 1
                continue
            last[pid] = key
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
        pos = PKT - len(es)  # bytes of the packet ahead of its elementary bytes
        if pid in audio:
            if started:
                audio[pid].pes_start(t_dec)
                dec.header_in(dec.tb_exit(tb, pos), dec.total, 9 + pl[8])
            if audio[pid].starts:
                audio[pid].feed(es)
                dec.bytes_in(None, len(es), tb, pos)
            continue
        if pid in auds:
            a = auds[pid]
            if started:
                if a[0] > 1:
                    several.add(pid)
                a[0], a[1] = 0, b""
            run = a[1] + es
            k = run.find(b"\x00\x00\x01")
            while 0 <= k < len(run) - 3:
                if run[k + 3] & 0x1F == 9:  # access unit delimiter
                    a[0] += 1
                    a[2] += 1
                k = run.find(b"\x00\x00\x01", k + 3)
            a[1] = run[-3:]
        if started:
            cur = pes.pop(pid, None)
            if cur is not None:
                if cur[0] is None:
                    untimed.add(pid)
                else:
                    dec.unit(cur[0], cur[1], dec.total)  # one video access unit per PES
            pes[pid] = [t_dec, dec.total]
            dec.header_in(dec.tb_exit(tb, pos), dec.total, 9 + pl[8])
        if pid in pes:
            dec.bytes_in(None, len(es), tb, pos)
    for pid, st in audio.items():
        for t, start, end in st.units():
            decoders[pid].unit(t, start, end)
    for pid, (count, _tail, total) in auds.items():
        if count > 1:
            several.add(pid)
        if not total:
            calib[pid]["note"] += "; no access unit delimiter, so one access unit per PES is assumed"
    for pid in several:
        refused[pid] = "a PES carries several access units, whose decode times are not derived"
    for pid in untimed:
        refused[pid] = "an access unit starts in a PES without a timestamp"
    for pid in refused:
        decoders.pop(pid, None)

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
        "refused": refused,
        "duplicates": dict(dups),
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
    # 2.4.2.3: bytes reach B as they leave TB. A packet arriving at 10 Mb/s into an empty
    # 2 Mb/s TB lets its 42nd byte out at 42 x 8 / 2e6 = 0.168 ms, so a unit ending on
    # that byte is complete for a decode at 0.3 ms and late for one at 0.15 ms. Delivering
    # the whole packet when its last byte leaves (0.752 ms) would call both late.
    tbuf = TransportBuffer("t", 512, 2_000_000)
    tb = tbuf.packet(0.0, PKT * 8 / 10_000_000)
    for td, want in ((0.0003, 0), (0.00015, 1)):
        db = DecoderBuffer("d", 3584, 1.0, rx_bps=2_000_000)
        db.bytes_in(None, 184, tb, 4)
        db.unit(td, 0, 38)
        check(f"unit ending on byte 42 of a packet, decoded at {td * 1e3:g} ms",
              (round(db.done_at(38) * 1e3, 3), db.report()["underflows"]), (0.168, want))
    # 2.4.2.6: TB shall empty once a second. Fed at 1.001 x Rx it never does; at 0.999 x Rx
    # it empties every packet. Neither overflows.
    for factor, want in ((1.001, 1), (0.999, 0)):
        tb = TransportBuffer("t", 512, 1_000_000)
        d = PKT * 8 / (1_000_000 * factor)
        for k in range(1000):
            tb.packet(k * d, (k + 1) * d)
        check(f"TB fed at {factor} x Rx for 1.5 s: stretches over 1 s, overflows",
              (tb.over_1s, tb.over_packets), (want, 0))
    # A backlog at the end of the capture counts to when it would drain: two packets at
    # 10 Mb/s leave 376 B, 1.07 s at 2.8 kb/s and 0.94 s at 3.2 kb/s.
    for rx_bps, want in ((2_800, 1), (3_200, 0)):
        tb = TransportBuffer("t", 512, rx_bps)
        for k in range(2):
            tb.packet(k * PKT * 8 / 10e6, (k + 1) * PKT * 8 / 10e6)
        check(f"376 B left in TB at the end, Rx {rx_bps} b/s: stretches over 1 s", tb.over_1s, want)
    # 2.4.2.3: an audio PES header is held in B with the unit behind it.
    for hdr, want in ((14, 1), (0, 0)):
        db = DecoderBuffer("d", 1000, 1.0)
        if hdr:
            db.header_in(0.0, 0, hdr)
        db.bytes_in(0.0, 990)
        db.unit(1.0, 0, 990)
        check(f"990 B behind a {hdr} B PES header in a 1,000 B B: overflows", db.report()["overflow_arrivals"], want)
    # 2.14.3.1 sizes: level 4.0 with CpbSize 8,797,568 bits gives EBS 1,099,696 B and MBS
    # (96,000 + 32,000 + 30,000,000) / 8 - EBS, so MB + EB = 3,766,000 B; Rbx 24 Mb/s.
    rx, ebs, mbs, rbx, _ = avc_buffers(40, 8_797_568, 8_797_568)
    check("AVC level 4.0 (Rx, EBS, MB + EB, Rbx)", (round(rx), ebs, ebs + mbs, rbx),
          (10_557_082, 1_099_696.0, 3_766_000.0, 24_000_000))
    # The leak: 160 B every 0.2 s into EBS 1,000 B, MBS 500 B, Rbx 1,000 B/s. MB passes
    # everything until EB fills, then holds the rest: 440 B after nine batches, 600 B
    # (over) after ten.
    for batches, want in ((9, (0, 440.0)), (10, (1, 600.0))):
        lb = LeakBuffer("l", 1000, 500, 8_000, 10.0)
        for k in range(batches):
            lb.bytes_in(0.2 * k, 160)
        lb.unit(5.0, 0, 1000)
        r = lb.report()
        check(f"leak, {batches} batches into a full EB: MB overflows, peak",
              (r["overflow_arrivals"], r["mb_peak_bytes"]), want)
    # 3,000 B at once leave MB at Rbx = 1,000 B/s, so the unit is in EB at 3 s: a decode
    # at 2 s underflows, one at 3.5 s does not, though every byte reached MB at 0.
    for td, want in ((2.0, 1), (3.5, 0)):
        lb = LeakBuffer("l", 10_000, 10_000, 8_000, 10.0)
        lb.bytes_in(0.0, 3000)
        lb.unit(td, 0, 3000)
        check(f"leak, 3,000 B through Rbx 1,000 B/s decoded at {td:g} s: EB underflows",
              lb.report()["underflows"], want)
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
              f"  longest non-empty {b['longest_nonempty_s']:.3f} s (over 1 s {b['not_emptied_within_1s']:,}){tag}")
    print("  decoder buffers:")
    for d in r["decoder_buffers"]:
        if "mb_size_bytes" in d:
            size = (f"MB peak {d['mb_peak_bytes']:,.0f} of {d['mb_size_bytes']:,} B, "
                    f"EB peak {d['eb_peak_bytes']:,.0f} of {d['eb_size_bytes']:,} B, MB overflows "
                    f"{d['overflow_arrivals']:,}")
        else:
            size = (f"peak {d['peak_bytes']:,.0f} of {d['size_bytes']:,.0f} B, overflows "
                    f"{d['overflow_arrivals']:,} + {d['overflow_before_removal']:,} before a removal")
        print(f"    {d['buffer']:<26} units {d['units']:>7,}  underflows {d['underflows']:>6,}"
              f"  margin min/p1/median {d['margin_min_ms']}/{d['margin_p01_ms']}/{d['margin_median_ms']} ms"
              f"  {size}  residence max {d['residence_max_s']} s"
              f" (limit {d['max_delay_limit_s']:g}, over {d['residence_over_limit']:,})")
    for pid, why in sorted(r["refused"].items()):
        print(f"  REFUSED PID {pid}: {why}")
    for pid, n in sorted(r["duplicates"].items()):
        print(f"  PID {pid}: {n:,} duplicate packets, held in TB and not delivered")
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


def violated(d):
    return bool(d["underflows"] or d["overflow_arrivals"] or d.get("overflow_before_removal")
                or d["residence_over_limit"])


def verdict(r):
    bad = any(b["normative"] and (b["overflow_packets"] or b["not_emptied_within_1s"])
              for b in r["transport_buffers"])
    bad |= any(violated(d) for d in r["decoder_buffers"])
    if bad:
        return 1
    return 2 if r["refused"] else 0


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

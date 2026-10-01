#!/usr/bin/env python3
"""Re-multiplex the media-aware lane's TS-out under the T-STD, in real time.

    ts-remux-live.py <-|stdout|ip:port> <rate_bps> --calib-from SOURCE.ts
                     [--rtp] [--ssrc N] [--sequence-seed N] [--latency-ms L]
                     [--warmup-ms W] [--pcr-ms MS] [--stats-ms MS] [--json PATH]
                     [--max-latency-ms N] [--stall-ms N] [--on-stall X] [--preserve]

The live counterpart of ts-remux-oracle.py. It reads `moq export ts` on stdin
and writes a constant-rate multiplex, with only what a subscriber has: each
PID's packets in order, when each arrived, and the timestamps they carry. The
scheduler is the oracle's: earliest deadline first, with each PID's transport
buffer and, where the T-STD sizes one, its decoder buffer asked before a packet
is sent, and an adaptation-only PCR packet whenever none has gone for --pcr-ms.

There is no source PCR on the lane, so the output clock is the decode timeline
itself. A slot's PCR is the system time clock at that slot and the PTS and DTS
pass through untouched, so the offset between PCR and decode is fixed by
construction instead of being set at start-up and left to drift. What remains
free is where that timeline sits against the wall clock. The first --warmup-ms
of input are observed and not sent: the latest any packet arrived against its
own decode time fixes the offset, and --latency-ms is added as the lead every
later packet has to beat. Output then starts, carrying nulls and PCR at once,
each PES stream from its next unit boundary and the video from its next random
access point. A packet that arrives later against its decode time than any in
the warm-up spends that lead, and past it is sent late and counted. The clock
does not move to absorb it. The output runs at the wall clock's rate; locking
it to a remote source's rate is not implemented, and on one host the two are
the same clock.

Continuity counters are rewritten, because the input's adaptation-only packets
are dropped and PCR packets of the tool's own are inserted. Input nulls are
dropped. Buffer parameters come from ts-tstd.py's calibration of --calib-from,
which must carry the same PIDs; the video's HRD is read from its SPS there.
Statistics go to stderr every --stats-ms and as JSON at exit. The pacer's
--max-latency-ms, --stall-ms, --on-stall and --preserve are accepted so that
t18-arm.sh can run this in the pacer's place, and ignored.
"""

import argparse
import collections
import importlib.util
import json
import os
import select
import signal
import socket
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


T = _load("tstd", "ts-tstd.py")
R = _load("oracle", "ts-remux-oracle.py")

PKT = T.PKT
NULL_PID = 0x1FFF
PTS_WRAP = (1 << 33) / 90_000.0
PER_DATAGRAM = 7
PES_KINDS = ("avc", "hevc", "mpeg2v", "mpa", "ac3", "aac", "teletext")
VIDEO = ("avc", "hevc", "mpeg2v")
HIST_MS = 5000


class Hist:
    """Millisecond histogram: medians and tails over millions of packets without keeping them."""

    def __init__(self):
        self.bins = [0] * (HIST_MS + 1)
        self.n, self.lo, self.hi = 0, float("inf"), float("-inf")

    def add(self, ms):
        self.bins[min(max(int(ms), 0), HIST_MS)] += 1
        self.n += 1
        self.lo, self.hi = min(self.lo, ms), max(self.hi, ms)

    def q(self, frac):
        if not self.n:
            return None
        want, acc = frac * (self.n - 1), 0
        for ms, c in enumerate(self.bins):
            acc += c
            if acc > want:
                return ms
        return HIST_MS

    def summary(self):
        if not self.n:
            return None
        return {"min": round(self.lo, 1), "median": self.q(0.5), "p99": self.q(0.99),
                "max": round(self.hi, 1)}


class Media:
    """One 33-bit timeline for every PID, unwrapped against the last value seen."""

    def __init__(self):
        self.ref = None

    def __call__(self, ts90):
        t = ts90 / 90_000.0
        if self.ref is not None:
            t += round((self.ref - t) / PTS_WRAP) * PTS_WRAP
        self.ref = t
        return t


class Entry:
    __slots__ = ("pkt", "arr", "dl", "early", "es_len")

    def __init__(self, pkt, arr, dl, early, es_len):
        self.pkt, self.arr, self.dl, self.early, self.es_len = pkt, arr, dl, early, es_len


class Pid:
    """One PID's queue, its buffers, and the unit boundaries its deadlines come from."""

    def __init__(self, pid, kind, calib, tb=None):
        self.pid, self.kind = pid, kind
        size, rx, self.dec, self.maxres = calib
        self.tb = tb or R.Leaky(size, rx)
        self.q = collections.deque()
        self.waiting = True
        self.in_pes = False
        self.es_total = 0
        self.unit_t = None  # decode time of the open video or teletext unit
        self.rm = collections.deque()  # (decode time, end offset), in decode order
        self.removed = self.cum = 0
        self.cc = None
        self.frames = collections.deque(maxlen=64)  # audio (t, start, end)
        self.marks = collections.deque()  # audio PES starts (offset, t) not yet reached
        self.mark_t = None
        self.k = 0
        self.last_frame = None
        self.abuf, self.aoff, self.skip = bytearray(), 0, 0
        self.in_cc = None
        self.st = {"packets": 0, "late": 0, "late_max_ms": 0.0, "cc_in_errors": 0}
        self.lead, self.hold = Hist(), Hist()
        self.lead_min_iv = float("inf")

    def audio_feed(self, es):
        """Split frames as bytes arrive; a frame is known from its header, before its end."""
        if self.skip:
            n = min(self.skip, len(es))
            es, self.skip = es[n:], self.skip - n
            if self.skip:
                return
        self.abuf += es
        while len(self.abuf) >= 8:
            size, dur = T.frame_len(self.abuf, 0, self.kind)
            if size is None:
                del self.abuf[0]
                self.aoff += 1
                continue
            start = self.aoff
            while self.marks and self.marks[0][0] <= start:
                self.mark_t, self.k = self.marks.popleft()[1], 0
            if self.mark_t is not None:
                t = self.mark_t + self.k * dur
            elif self.last_frame is not None:
                t = self.last_frame + dur
            else:
                t = None
            self.k += 1
            if t is not None:
                self.last_frame = t
                self.frames.append((t, start, start + size))
                self.rm.append((t, start + size))
            self.aoff += size
            if len(self.abuf) >= size:
                del self.abuf[:size]
            else:
                self.skip = size - len(self.abuf)
                self.abuf.clear()
                break

    def audio_times(self, off, n):
        """(decode time of the frame holding byte `off`, of the last frame starting before off+n)."""
        first = last = None
        for t, s, e in reversed(self.frames):
            if last is None and s < off + max(n, 1):
                last = t
            if s <= off:
                first = t if off < e else None
                break
        if first is None:
            first = last if last is not None else self.mark_t
        return first, last


def pes_header(pl):
    """(PES_packet_length, decode time in 90 kHz or None, header length) of a PES start."""
    if len(pl) < 9 or pl[:3] != b"\x00\x00\x01":
        return None
    flags, hl = pl[7], pl[8]
    ts = None
    if flags & 0x80 and len(pl) >= 14:
        ts = T.pes_ts(pl[9:14])
    if flags & 0x40 and len(pl) >= 19:
        ts = T.pes_ts(pl[14:19])
    return (pl[4] << 8) | pl[5], ts, 9 + hl


def random_access(p, es):
    """A PES start the video may begin at: the RAI flag, else an SPS or IDR NAL in the packet."""
    if (p[3] >> 4) & 0x2 and p[4] and p[5] & 0x40:
        return True
    j = 0
    while True:
        k = es.find(b"\x00\x00\x01", j)
        if k < 0 or k + 3 >= len(es):
            return False
        if es[k + 3] & 0x1F in (5, 7):
            return True
        j = k + 3


def calibrate_all(path):
    """Every elementary PID's buffers, before the loop starts: the video's needs ffmpeg."""
    with open(path, "rb") as f:
        data = f.read(PKT * 40_000)
    pmts, streams = {}, None
    for i in range(0, len(data) - PKT + 1, PKT):
        p = data[i:i + PKT]
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if not p[1] & 0x40 or (pid != 0 and pid not in pmts):
            continue
        sec = T.section_body(bytes(T.payload_of(p)))
        if not sec:
            continue
        if pid == 0 and sec[0] == 0x00:
            pmts = T.parse_pat(sec)
        elif pid in pmts and sec[0] == 0x02:
            _, streams = T.parse_pmt(sec)
            break
    if not streams:
        sys.exit(f"{path}: no PMT in its first {len(data) // PKT:,} packets")
    calib = {}
    for pid, (st, tags) in streams.items():
        c = R.calibrate(path, T.classify(st, tags), pid)
        if c is None:
            sys.exit(f"{path}: PID {pid:#x}: no buffer parameters")
        calib[pid] = c
    return calib


class Remux:
    def __init__(self, a):
        self.a = a
        self.rate = a.rate
        self.slot = PKT * 8.0 / a.rate
        self.lead_s = a.latency_ms / 1000.0
        self.media = Media()
        self.pmt_pids, self.pcr_pid, self.kinds = set(), None, {}
        self.calib = calibrate_all(a.calib_from)
        self.pids = {}
        self.psi_tb = R.Leaky(512, 1_000_000)
        self.state = "observe"
        self.first_media = None
        self.W = float("-inf")
        self.warm = {"packets": 0, "video": False, "audio": False}
        self.S0 = self.wall0 = None
        self.k = 0
        self.last_pcr = float("-inf")
        self.pcr_gap_max = 0.0
        self.c = collections.Counter()
        self.lag_max = 0.0
        self.iv = collections.Counter()
        self.seq = a.sequence_seed & 0xFFFF
        self.ssrc = a.ssrc & 0xFFFFFFFF
        self.trace = open(a.trace, "w") if a.trace else None
        self.real_offset = time.time() - time.monotonic()
        if self.trace:
            self.trace.write("arrival_s,arrival_unix_s,pid,kind,decode_s\n")
        self.out_sock = self.out_addr = None
        if a.dest not in ("-", "stdout"):
            host, _, port = a.dest.rpartition(":")
            self.out_addr = (host or "127.0.0.1", int(port))
            self.out_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.out_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)

    # --- structure -------------------------------------------------------------------------

    def kind_of(self, pid):
        if pid == 0 or pid in self.pmt_pids:
            return "psi"
        if pid in self.kinds:
            return self.kinds[pid]
        return "si" if pid in R.SI_PIDS else "other"

    def stream(self, pid):
        s = self.pids.get(pid)
        if s is None:
            kind = self.kind_of(pid)
            if kind == "psi":
                s = Pid(pid, kind, (512, 1_000_000, None, 1.0), tb=self.psi_tb)
            else:
                s = Pid(pid, kind, self.calib.get(pid, (512, 1_000_000, None, 1.0)))
            self.pids[pid] = s
        return s

    def learn(self, pid, p):
        if not p[1] & 0x40:
            return
        sec = T.section_body(bytes(T.payload_of(p)))
        if not sec:
            return
        if pid == 0 and sec[0] == 0x00:
            self.pmt_pids = set(T.parse_pat(sec))
        elif pid in self.pmt_pids and sec[0] == 0x02:
            self.pcr_pid, streams = T.parse_pmt(sec)
            for spid, (st, tags) in streams.items():
                kind = T.classify(st, tags)
                if self.kinds.get(spid) != kind:
                    self.kinds[spid] = kind
                    self.pids.pop(spid, None)

    # --- input -----------------------------------------------------------------------------

    def stc_of(self, wall):
        return self.S0 + (wall - self.wall0)

    def ingest(self, p, now):
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if pid == NULL_PID:
            self.c["in_null"] += 1
            return
        afc = (p[3] >> 4) & 0x3
        self.c["in_packets"] += 1
        if pid == 0 or pid in self.pmt_pids:
            self.learn(pid, p)
        if not self.kinds:
            return
        if not afc & 0x1:
            self.c["in_adaptation_only"] += 1
            return
        s = self.stream(pid)
        cc = p[3] & 0x0F
        if s.in_cc is not None and cc != (s.in_cc + 1) & 0x0F and cc != s.in_cc:
            s.st["cc_in_errors"] += 1
        s.in_cc = cc
        pl = bytes(T.payload_of(p))
        start = bool(p[1] & 0x40)
        es = b""
        dl = early = None
        if s.kind in PES_KINDS:
            hdr = pes_header(pl) if start else None
            if hdr is not None:
                es = pl[hdr[2]:]
                if s.waiting:
                    if s.kind in VIDEO and not random_access(p, pl):
                        return
                    if self.state == "run" and s.kind not in VIDEO and not self.video_started():
                        return
                    s.waiting = False
                t = self.media(hdr[1]) if hdr[1] is not None else None
                if self.trace and t is not None:
                    self.trace.write(f"{now:.6f},{now + self.real_offset:.6f},{pid},{s.kind},{t:.6f}\n")
                if s.kind in ("mpa", "ac3"):
                    s.marks.append((s.es_total, t))
                else:
                    if s.unit_t is not None and s.kind in VIDEO:
                        s.rm.append((s.unit_t, s.es_total))
                    if t is not None:
                        s.unit_t = t
                s.in_pes = True
            elif s.waiting or not s.in_pes:
                return
            else:
                es = pl
            off = s.es_total
            if s.kind in ("mpa", "ac3"):
                s.audio_feed(es)
                first, last = s.audio_times(off, len(es))
                if first is not None:
                    dl = first - R.GUARD
                    early = (last if last is not None else first) - s.maxres + R.GUARD
            elif s.unit_t is not None:
                dl = s.unit_t - R.GUARD
                early = s.unit_t - s.maxres + R.GUARD if s.kind in VIDEO else float("-inf")
            s.es_total += len(es)
        else:
            if s.waiting:
                if not start:
                    return
                s.waiting = False
        if self.state == "observe":
            self.observe(s, now, dl)
            return
        if dl is None:
            horizon = 0.3 if s.kind in ("scte35", "other") else 0.1
            dl, early = self.stc_of(now) + horizon, float("-inf")
        lead_ms = (dl - self.stc_of(now)) * 1000.0
        if s.kind in PES_KINDS:
            s.lead.add(lead_ms)
            s.lead_min_iv = min(s.lead_min_iv, lead_ms)
        s.q.append(Entry(bytearray(p), now, dl, early, len(es)))
        s.st["packets"] += 1

    def video_started(self):
        return any(not s.waiting for s in self.pids.values() if s.kind in VIDEO)

    def observe(self, s, now, dl):
        if dl is None or s.kind not in PES_KINDS:
            return
        if self.first_media is None:
            self.first_media = now
        self.W = max(self.W, now - dl)
        self.warm["packets"] += 1
        if s.kind in VIDEO:
            self.warm["video"] = True
        elif s.kind in ("mpa", "ac3", "aac"):
            self.warm["audio"] = True

    def ready(self, now):
        return (self.first_media is not None and self.warm["video"] and self.warm["audio"]
                and now - self.first_media >= self.a.warmup_ms / 1000.0)

    def start(self, now):
        """Fix the timeline against the wall clock and begin sending from the next boundaries."""
        self.wall0 = now
        self.S0 = now - self.W - self.lead_s
        self.base_ticks = round(self.S0 * T.TICKS)
        self.state = "run"
        self.pids = {}
        self.psi_tb.occ, self.psi_tb.last = 0.0, 0.0
        self.log(f"start: warm-up {self.warm['packets']:,} packets over "
                 f"{(now - self.first_media) * 1000:.0f} ms; latest arrival against decode "
                 f"{self.W * 1000:+.1f} ms, lead {self.a.latency_ms:g} ms")

    # --- output ----------------------------------------------------------------------------

    def ticks(self, k):
        return (self.base_ticks + (k * PKT + 11) * 8 * 27_000_000 // self.rate) % T.PCR_MODULUS

    def choose(self, ta, tb, wall_end):
        best, bdl = None, float("inf")
        for s in self.order:
            q = s.q
            if not q:
                continue
            e = q[0]
            if e.arr > wall_end or e.early > ta or not s.tb.room(ta, tb):
                continue
            if s.dec:
                rm = s.rm
                while rm and rm[0][0] <= tb:
                    s.removed = max(s.removed, rm.popleft()[1])
                removed = s.removed
                if s.kind in VIDEO and s.unit_t is not None and s.unit_t <= tb:
                    removed = max(removed, s.cum)
                if s.cum + e.es_len - removed > s.dec - R.EB_SLACK:
                    continue
            if e.dl < bdl:
                best, bdl = s, e.dl
        return best

    def fill(self, k):
        ta, tb = self.S0 + k * self.slot, self.S0 + (k + 1) * self.slot
        wall_end = self.wall0 + (k + 1) * self.slot
        pcr = self.pids.get(self.pcr_pid)
        if pcr is not None and ta - self.last_pcr >= self.a.pcr_ms / 1000.0 and pcr.tb.room(ta, tb):
            pcr.tb.send(ta, tb)
            if pcr.cc is None:
                pcr.cc = 15  # an adaptation-only packet repeats the counter the next payload increments
            self.note_pcr(ta)
            self.c["pcr_only"] += 1
            return R.pcr_packet(self.pcr_pid, pcr.cc, self.ticks(k))
        s = self.choose(ta, tb, wall_end)
        if s is None:
            self.c["nulls"] += 1
            self.iv["nulls"] += 1
            return R.NULL
        e = s.q.popleft()
        s.tb.send(ta, tb)
        s.cum += e.es_len
        p = e.pkt
        s.cc = 0 if s.cc is None else (s.cc + 1) & 0x0F
        p[3] = (p[3] & 0xF0) | s.cc
        if (p[3] >> 4) & 0x2 and p[4]:
            p[5] &= 0x7F  # the output timeline is continuous whatever the input's flags said
            if s.pid == self.pcr_pid and p[5] & 0x10:
                R.write_pcr(p, self.ticks(k))
                self.note_pcr(ta)
        hold_ms = (tb - self.stc_of(e.arr)) * 1000.0
        s.hold.add(hold_ms)
        if tb > e.dl:
            s.st["late"] += 1
            s.st["late_max_ms"] = max(s.st["late_max_ms"], (tb - e.dl) * 1000.0)
            self.iv["late"] += 1
        self.c["sent"] += 1
        return p

    def note_pcr(self, ta):
        if self.last_pcr > float("-inf"):
            self.pcr_gap_max = max(self.pcr_gap_max, ta - self.last_pcr)
        self.last_pcr = ta

    def emit(self, now):
        """Send every datagram whose last slot has ended."""
        while True:
            end = self.wall0 + (self.k + PER_DATAGRAM) * self.slot
            if end > now:
                return end
            self.lag_max = max(self.lag_max, now - end)
            self.order = [s for s in self.pids.values() if s.q]
            ts90 = (self.ticks(self.k) // 300) & 0xFFFFFFFF
            dg = bytearray()
            for i in range(PER_DATAGRAM):
                dg += self.fill(self.k + i)
            self.k += PER_DATAGRAM
            self.c["slots"] += PER_DATAGRAM
            self.iv["slots"] += PER_DATAGRAM
            if self.out_sock is None:
                view = memoryview(dg)
                while view:
                    view = view[os.write(1, view):]
                continue
            if self.a.rtp:
                dg[0:0] = struct.pack("!BBHII", 0x80, 33, self.seq, ts90, self.ssrc)
                self.seq = (self.seq + 1) & 0xFFFF
            try:
                self.out_sock.sendto(dg, self.out_addr)
            except OSError:
                self.c["send_errors"] += 1

    def queued(self):
        return sum(len(s.q) for s in self.pids.values())

    # --- reporting -------------------------------------------------------------------------

    def log(self, msg):
        print(f"remux: {msg}", file=sys.stderr, flush=True)

    def interval(self, now):
        slots = self.iv["slots"] or 1
        leads = {f"{s.pid:#x}": round(s.lead_min_iv, 1) for s in self.pids.values()
                 if s.kind in PES_KINDS and s.lead_min_iv < float("inf")}
        for s in self.pids.values():
            s.lead_min_iv = float("inf")
        self.log(f"t={now - self.wall0:7.1f}s queued {self.queued():>6} nulls "
                 f"{100.0 * self.iv['nulls'] / slots:5.1f}% late {self.iv['late']:>5} "
                 f"lag_max {self.lag_max * 1000:6.1f} ms lead_min_ms {leads}")
        self.iv.clear()

    def report(self):
        slots = self.c["slots"] or 1
        return {
            "rate": self.rate, "lead_ms": self.a.latency_ms, "warmup_ms": self.a.warmup_ms,
            "warmup_latest_arrival_vs_decode_ms": round(self.W * 1000, 2)
            if self.W > float("-inf") else None,
            "counters": dict(self.c), "null_share": round(self.c["nulls"] / slots, 4),
            "pcr_gap_max_ms": round(self.pcr_gap_max * 1000, 2),
            "loop_lag_max_ms": round(self.lag_max * 1000, 2),
            "late_total": sum(s.st["late"] for s in self.pids.values()),
            "unsent": self.queued(),
            "calibration": {f"{p:#06x}": list(c) for p, c in self.calib.items()},
            "pids": {f"{s.pid:#06x}": dict(s.st, kind=s.kind, lead_ms=s.lead.summary(),
                                           hold_ms=s.hold.summary())
                     for s in sorted(self.pids.values(), key=lambda s: s.pid)},
        }

    # --- loop ------------------------------------------------------------------------------

    def run(self):
        stop = []
        # The rig ends a run with SIGTERM to the pipeline, and the report is the run's record.
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, lambda *_: stop.append(1))
        fd = sys.stdin.fileno()
        os.set_blocking(fd, False)
        buf = bytearray()
        eof = False
        next_emit = None
        next_stats = None
        drain_until = None
        while not stop:
            now = time.monotonic()
            if self.state == "run":
                wait = max(0.0, next_emit - now) if next_emit is not None else 0.0
            else:
                wait = 0.05
            rd = [fd] if not eof else []
            try:
                if rd:
                    r, _, _ = select.select(rd, [], [], wait)
                else:
                    r = []
                    time.sleep(wait)
            except InterruptedError:
                continue
            now = time.monotonic()
            if r:
                try:
                    chunk = os.read(fd, 1 << 17)
                except BlockingIOError:
                    chunk = None
                if chunk == b"":
                    eof = True
                    drain_until = now + 5.0
                elif chunk:
                    buf += chunk
                    if buf[0] != 0x47:
                        i = buf.find(0x47)
                        self.c["resync_bytes"] += len(buf) if i < 0 else i
                        del buf[:len(buf) if i < 0 else i]
                    n = len(buf) - len(buf) % PKT
                    data = bytes(buf[:n])
                    del buf[:n]
                    for i in range(0, n, PKT):
                        if data[i] == 0x47:
                            self.ingest(data[i:i + PKT], now)
                        else:
                            self.c["bad_sync"] += 1
            if self.state == "observe":
                if self.ready(now):
                    self.start(now)
                    next_stats = now + self.a.stats_ms / 1000.0
                elif eof:
                    self.log("input ended before the warm-up completed")
                    break
                continue
            next_emit = self.emit(now)
            if now >= next_stats:
                self.interval(now)
                next_stats += self.a.stats_ms / 1000.0
            if eof and (self.queued() == 0 or now > drain_until):
                break
        rep = self.report()
        self.log(f"done: {rep['counters'].get('sent', 0):,} packets sent, late {rep['late_total']}, "
                 f"unsent {rep['unsent']}, nulls {100 * rep['null_share']:.1f}%, PCR gap max "
                 f"{rep['pcr_gap_max_ms']} ms, loop lag max {rep['loop_lag_max_ms']} ms")
        if self.a.json:
            with open(self.a.json, "w") as f:
                json.dump(rep, f, indent=1)
        if self.trace:
            self.trace.close()
        return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dest", help="- or stdout for a byte stream, else host:port for UDP")
    ap.add_argument("rate", type=int, help="output mux rate, b/s")
    ap.add_argument("--calib-from", required=True, metavar="SOURCE.ts",
                    help="a capture with the same PIDs, for ts-tstd.py's buffer calibration")
    ap.add_argument("--rtp", action="store_true")
    ap.add_argument("--ssrc", type=int, default=0x4D4F5100)
    ap.add_argument("--sequence-seed", type=int, default=0)
    ap.add_argument("--latency-ms", type=float, default=100.0,
                    help="lead added to the warm-up's latest arrival against decode time")
    ap.add_argument("--warmup-ms", type=float, default=5000.0)
    ap.add_argument("--pcr-ms", type=float, default=25.0)
    ap.add_argument("--stats-ms", type=float, default=10000.0)
    ap.add_argument("--json", metavar="PATH")
    ap.add_argument("--trace", metavar="PATH",
                    help="CSV of every PES start: arrival time (monotonic and Unix), PID, kind, decode time")
    for flag in ("--max-latency-ms", "--stall-ms", "--on-stall"):
        ap.add_argument(flag, help=argparse.SUPPRESS)
    ap.add_argument("--preserve", action="store_true", help=argparse.SUPPRESS)
    a = ap.parse_args()
    if not os.path.exists(a.calib_from):
        sys.exit(f"--calib-from {a.calib_from}: no such file")
    return Remux(a).run()


if __name__ == "__main__":
    sys.exit(main())

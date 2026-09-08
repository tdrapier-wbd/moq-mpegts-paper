#!/usr/bin/env python3
"""Watch a transport stream for per-elementary-stream access-unit liveness, live and streaming.

[T24](../test-24-partial-media-plane-stall.md) established that the whole of TR 101 290 P1 is
green over a service with no pictures in it, because PCR shares a PID with the video whose
absence it is being asked to report, and that **per-PID access-unit liveness** was the only
detector that caught every arm at its true length with nothing fired on the control. It
established that with an offline grader over a capture. That is not a detector an operator can
run: it needs the stream to have finished, it needs disk proportional to the observation, and it
was told which PIDs to look at.

This is the same measurement as a streaming process: constant memory, no disk, and configured
from the stream's own PMT rather than by an operator who has to know the mux layout in advance.

Three things separate it from the grader it comes from, and each is a correctness matter rather
than an ergonomic one.

**It is driven by the PMT, so it can see a stream that never starts.** A detector that watches
the PIDs it has observed cannot alarm on a PID it has never observed — the failure where an
encoder comes up with its video path already dead looks like a stream that simply has no video.
Taking the expected set from the PMT makes that case an alarm (`never started`) instead of a
silence. It also means a mux that gains a stream mid-run is followed.

**It runs on two clocks at once, and that is not redundancy.** Every gap is *measured* against
the stream's own PCR, so its length is a property of the stream and not of how fast the pipe was
drained — that is what makes a reading comparable with T24's. But a detector that only knows
media time goes blind exactly when the whole stream dies: if PCR stops, media time stops, and a
per-PID gap measured in media time never grows again. So wall clock runs alongside as a dead
man's handle on the clock itself, and `--pcr-timeout` is the one threshold deliberately not
learned.

**Thresholds are learned per PID, because a single threshold cannot work.** Access-unit spacing
across one broadcast mux spans orders of magnitude: 25 fps video emits one every 40 ms, an AC-3
stream one every 32 ms, a teletext stream can go a second between them, and an SCTE-35 PID can be
legitimately silent for hours. T24 measured the analogous problem for the stuffing ratio — a
threshold sensitive enough to catch a dead audio stream false-positives on healthy video — and
the same proportionality applies here. Each PID's threshold is derived from its own observed
spacing during a settle window. Streams that show no cadence in that window are declared
**unmonitorable** and reported as such rather than watched against an invented threshold, because
an alarm on a PID whose normal cadence was never observed is not evidence of anything.

An access unit is counted only where `payload_unit_start_indicator` is set, a payload is present,
and the payload begins with a PES start code. All three are required. T24's stimulus — and a real
encoder in the same state — emits adaptation-field-only packets carrying PCR on the video PID,
and a packet with no payload must not be read as a picture (ISO 13818-1 2.4.3.3). PSI PIDs are
watched on section starts instead, since they carry no PES.

Usage:
  ts-liveness.py [--jsonl] [--settle 10] [--factor 6] [--pcr-timeout 3] [stream.ts]
  ... | ts-liveness.py -              # reads stdin, which is the operational case

Exit status is 1 if any stream was ever declared dead, so it also serves as a test oracle.
"""

import argparse
import json
import os
import select
import stat
import sys
import time

TS = 188
SYNC = 0x47
PCR_MODULUS = (1 << 33) * 300
NULL_PID = 0x1FFF
PAT_PID = 0x0000
# Reserved PIDs that carry sections rather than PES, so liveness is a section start for them.
PSI_PIDS = {0x0000, 0x0001, 0x0010, 0x0011, 0x0012, 0x0013, 0x0014, 0x001E, 0x001F}

# Stream types with no intrinsic cadence: an absence of them is not evidence of a fault.
# SCTE-35 (0x86) is the one that matters in practice — a splice PID is silent between breaks.
NO_CADENCE = {0x05, 0x86}

STREAM_NAMES = {
    0x01: "mpeg1v", 0x02: "mpeg2v", 0x03: "mp1a", 0x04: "mp2a", 0x05: "sections",
    0x06: "pes-priv", 0x0F: "aac", 0x11: "latm", 0x1B: "avc", 0x24: "hevc",
    0x81: "ac3", 0x86: "scte35", 0x87: "eac3",
}

# DVB signals several unrelated stream kinds as private PES (0x06) and distinguishes them only
# by descriptor. That is not cosmetic here: AC-3 has a dense cadence and a subtitling stream may
# legitimately emit nothing for hours, so the two must not be watched on the same basis.
DVB_DESCRIPTORS = {0x6A: "ac3", 0x7A: "eac3", 0x7B: "dts", 0x56: "teletext", 0x59: "subtitle"}
# Refined types that carry no reliable cadence of their own.
NO_CADENCE_NAMES = {"subtitle"}


def stream_name(t):
    return STREAM_NAMES.get(t, f"type-0x{t:02x}") if t is not None else "unknown"


def refine(stype, tags):
    """The stream's real kind, from its descriptors where stream_type is ambiguous."""
    for tag in tags:
        if tag in DVB_DESCRIPTORS:
            return DVB_DESCRIPTORS[tag]
    return stream_name(stype)


def parse_pcr(p):
    """The 27 MHz PCR in this packet, if it carries one."""
    if not (p[3] >> 4) & 0x2 or p[4] < 7 or not p[5] & 0x10:
        return None
    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
    return base * 300 + (((p[10] & 0x01) << 8) | p[11])


def payload_offset(p):
    """Where this packet's payload begins, or None if it has none."""
    if not (p[3] >> 4) & 0x1:
        return None
    afc = (p[3] >> 4) & 0x3
    if afc == 1:
        return 4
    off = 5 + p[4]
    return off if off < TS else None


def is_access_unit(p, off):
    """True if this packet starts a PES packet, which is the unit of liveness.

    Requiring the start code as well as the unit-start indicator is what separates a picture
    from an adaptation-field-only packet that merely carries the clock.
    """
    if off is None or not (p[1] & 0x40) or off + 3 > TS:
        return False
    return p[off] == 0x00 and p[off + 1] == 0x00 and p[off + 2] == 0x01


class Stream:
    """One PID's liveness state. Fixed size: no history is kept beyond the extremes.

    `no_cadence` and `threshold is None` mean different things and conflating them is a defect.
    The first is permanent and comes from the stream's kind: an SCTE-35 or subtitling PID has no
    cadence to measure and is never watched. The second is temporary and means only that this
    stream has not yet been live long enough to have earned a threshold — which is the state a
    stream is in before it starts *and* after it recovers, so learning has to be able to run
    again mid-stream rather than only during start-up.
    """

    def __init__(self, pid, stype, name, no_cadence):
        self.pid = pid
        self.stype = stype
        self.name = name
        self.no_cadence = no_cadence
        self.units = 0
        self.first = None
        self.last = None
        self.learn_from = None
        self.worst_spacing = 0.0
        self.threshold = None
        self.dead = False
        self.outages = []

    def label(self):
        return self.name


class Watch:
    def __init__(self, warmup, learn, factor, floor, pcr_timeout, pcr_jump, overrides,
                 jsonl, out):
        self.warmup = warmup
        self.learn = learn
        self.overrides = overrides
        self.factor = factor
        self.floor = floor
        self.pcr_timeout = pcr_timeout
        self.jsonl = jsonl
        self.out = out
        self.streams = {}
        self.expected = {}          # pid -> stream_type, from the PMT
        self.kind = {}              # pid -> refined kind, from stream_type plus descriptors
        self.pmt_pids = set()
        self.pcr_jump = pcr_jump
        self.prev_pcr = None
        self.now = 0.0              # media seconds, accumulated rather than differenced from
                                    # the first PCR, so a discontinuity can be absorbed instead
                                    # of moving the whole timeline
        self.discontinuities = 0
        self.pcr_wall = None        # wall clock at the last PCR, for the dead man's handle
        self.clock_dead = False
        self.clock_outages = []
        self.packets = 0
        self.armed = False
        self.alarms = 0

    def preset(self, pid):
        """An operator-supplied threshold, which beats a learned one where it exists: a
        broadcaster knows the frame rate and the audio frame duration of what it is sending, and
        a threshold derived from the format is defensible in a way that one derived from a few
        seconds of observation is not."""
        return self.overrides.get(pid)

    def classify(self, pid, stype):
        """The stream's kind, and whether a liveness threshold can mean anything for it."""
        name = self.kind.get(pid) or stream_name(stype)
        return name, stype in NO_CADENCE or name in NO_CADENCE_NAMES

    # ---- reporting ------------------------------------------------------

    def emit(self, kind, **kw):
        if self.jsonl:
            self.out.write(json.dumps({"event": kind, "t": round(self.now, 3), **kw}) + "\n")
        else:
            pid = kw.pop("pid", None)
            head = f"{kind.upper():<6} t=+{self.now:8.3f}"
            if pid is not None:
                head += f" pid={pid:<5}"
            self.out.write(head + " " + " ".join(f"{k}={v}" for k, v in kw.items()) + "\n")
        self.out.flush()

    # ---- PSI ------------------------------------------------------------

    def section(self, pid, p, off):
        """Follow PAT and PMT so the expected stream set comes from the mux, not from a flag."""
        if not (p[1] & 0x40):
            return
        s = off + 1 + p[off]
        if s + 12 > TS:
            return
        if pid == PAT_PID:
            if p[s] != 0x00:
                return
            end = min(s + 3 + (((p[s + 1] & 0x0F) << 8) | p[s + 2]) - 4, TS)
            i = s + 8
            while i + 4 <= end:
                if ((p[i] << 8) | p[i + 1]) != 0:
                    self.pmt_pids.add(((p[i + 2] & 0x1F) << 8) | p[i + 3])
                i += 4
            return
        if p[s] != 0x02:
            return
        end = min(s + 3 + (((p[s + 1] & 0x0F) << 8) | p[s + 2]) - 4, TS)
        i = s + 12 + (((p[s + 10] & 0x0F) << 8) | p[s + 11])
        while i + 5 <= end:
            stype = p[i]
            epid = ((p[i + 1] & 0x1F) << 8) | p[i + 2]
            esinfo = (((p[i + 3] & 0x0F) << 8) | p[i + 4])
            tags, d = [], i + 5
            while d + 2 <= min(i + 5 + esinfo, end):
                tags.append(p[d])
                d += 2 + p[d + 1]
            if epid not in self.expected:
                self.expected[epid] = stype
                self.kind[epid] = refine(stype, tags)
                if self.armed:
                    self.emit("added", pid=epid, type=self.kind[epid])
            i += 5 + esinfo

    # ---- liveness -------------------------------------------------------

    def touch(self, pid, stype):
        st = self.streams.get(pid)
        if st is None:
            st = self.streams[pid] = Stream(pid, stype, *self.classify(pid, stype))
        if st.stype is None and stype is not None:
            st.stype = stype
            st.name, st.no_cadence = self.classify(pid, stype)
        st.units += 1
        if st.dead:
            outage = self.now - st.last
            st.dead = False
            st.outages.append(outage)
            self.emit("clear", pid=pid, type=st.label(), outage_s=round(outage, 3))
            # A recovered stream must be re-learned before it can be watched again: the outage
            # it has just come out of is not evidence of its cadence.
            st.threshold, st.worst_spacing, st.learn_from = None, 0.0, self.now
        elif st.first is None:
            st.learn_from = max(self.now, self.warmup)
        elif st.threshold is None and not st.no_cadence:
            if self.now < st.learn_from:
                st.last = self.now
                return
            preset = self.preset(pid)
            if preset is not None:
                st.threshold = preset
                if self.armed:
                    self.emit("watching", pid=pid, type=st.label(), threshold_s=preset,
                              source="preset")
            else:
                st.worst_spacing = max(st.worst_spacing, self.now - st.last)
                if self.now - st.learn_from >= self.learn and st.worst_spacing > 0:
                    st.threshold = max(self.floor, st.worst_spacing * self.factor)
                    if self.armed:
                        self.emit("watching", pid=pid, type=st.label(),
                                  threshold_s=round(st.threshold, 3), source="learned")
        if st.first is None:
            st.first = self.now
            st.learn_from = max(st.learn_from or 0.0, self.warmup)
        st.last = self.now

    def arm(self):
        """Fix every threshold from the spacing actually observed, then start alarming.

        Three outcomes per PID, and keeping them distinct is the point: a threshold, a
        declaration that the stream cannot be monitored, or an immediate alarm because the PMT
        promises a stream that has not appeared.
        """
        self.armed = True
        for pid, stype in sorted(self.expected.items()):
            if pid not in self.streams:
                self.streams[pid] = Stream(pid, stype, *self.classify(pid, stype))

        watched, sparse, absent = [], [], []
        for pid in sorted(self.streams):
            st = self.streams[pid]
            if st.units == 0:
                (sparse if st.no_cadence else absent).append(pid)
                continue
            if self.preset(pid) is not None:
                st.threshold = self.preset(pid)
                watched.append(pid)
                continue
            if st.no_cadence or st.worst_spacing <= 0:
                # Either a kind with no cadence, or one whose spacing was never observed twice.
                # Both are unmonitorable now, and saying so beats inventing a threshold; a
                # stream in the second state can still earn one later.
                sparse.append(pid)
                continue
            if st.threshold is None:
                st.threshold = max(self.floor, st.worst_spacing * self.factor)
            watched.append(pid)

        self.emit(
            "armed",
            watching=len(watched),
            thresholds_ms=";".join(f"{p}:{self.streams[p].threshold * 1000:.0f}" for p in watched),
            unmonitorable=";".join(f"{p}({self.streams[p].label()})" for p in sparse) or "none",
        )
        # A PID the PMT declares that emitted nothing at all during the settle window is the
        # encoder-came-up-with-a-dead-path case, and is the reading a detector watching only the
        # PIDs it has already seen structurally cannot produce.
        for pid in absent:
            st = self.streams[pid]
            st.dead = True
            st.last = self.now
            self.alarms += 1
            self.emit("alarm", pid=pid, type=st.label(), reason="never started")

    def sweep(self):
        """Alarm on any stream whose silence has exceeded its own threshold."""
        if not self.armed:
            return
        for pid in sorted(self.streams):
            st = self.streams[pid]
            if st.no_cadence or st.dead or st.threshold is None or st.last is None:
                continue
            gap = self.now - st.last
            if gap > st.threshold:
                st.dead = True
                self.alarms += 1
                self.emit("alarm", pid=pid, type=st.label(), reason="no access unit",
                          gap_s=round(gap, 3), threshold_s=round(st.threshold, 3))

    def check_clock(self, wall):
        """The dead man's handle. Media time cannot measure its own absence."""
        if self.pcr_wall is None or self.clock_dead:
            return
        stalled = wall - self.pcr_wall
        if stalled > self.pcr_timeout:
            self.clock_dead = True
            self.alarms += 1
            self.emit("alarm", reason="clock stopped", stalled_wall_s=round(stalled, 3))

    def clock_resumed(self, wall):
        """Called on a PCR arriving after a stall, and before `pcr_wall` is moved on — the
        length of the outage is the gap this PCR closes, so it has to be taken first."""
        outage = wall - self.pcr_wall
        self.clock_dead = False
        self.clock_outages.append(outage)
        self.emit("clear", reason="clock resumed", outage_wall_s=round(outage, 3))

    # ---- main loop ------------------------------------------------------

    def feed(self, p, wall):
        self.packets += 1
        pid = ((p[1] & 0x1F) << 8) | p[2]

        v = parse_pcr(p)
        if v is not None:
            if self.prev_pcr is not None:
                # One corrupt PCR must not be able to fabricate an outage. Taking media time as
                # the absolute distance from the first PCR means a single bad value moves the
                # whole timeline, and every stream then appears to have been silent for as long
                # as the error was large — a broken pipe produced a 94,847 s "outage" on this
                # detector before the guard existed. A step that is backwards, or further
                # forward than any plausible cadence, is a discontinuity (T23's territory): the
                # clock is re-anchored and media time does not advance across it.
                d = (v - self.prev_pcr) % PCR_MODULUS
                if d > PCR_MODULUS // 2 or d > self.pcr_jump * 27e6:
                    self.discontinuities += 1
                    self.emit("discontinuity", jump_s=round(
                        (d if d <= PCR_MODULUS // 2 else d - PCR_MODULUS) / 27e6, 3))
                else:
                    self.now += d / 27e6
            self.prev_pcr = v
            if self.clock_dead:
                self.clock_resumed(wall)
            self.pcr_wall = wall
            if not self.armed and self.now >= self.warmup + self.learn:
                self.arm()
            self.sweep()

        if pid == NULL_PID:
            return
        off = payload_offset(p)
        if pid == PAT_PID or pid in self.pmt_pids:
            if off is not None:
                self.section(pid, p, off)
        if pid in PSI_PIDS or pid in self.pmt_pids:
            if off is not None and (p[1] & 0x40):
                self.touch(pid, 0x05)
            return
        if is_access_unit(p, off):
            self.touch(pid, self.expected.get(pid))

    def summary(self):
        w = self.out
        w.write(f"\npackets        {self.packets:,}\n")
        w.write(f"media span     {self.now:.3f} s\n")
        w.write(f"alarms         {self.alarms}\n")
        w.write(f"discontinuities {self.discontinuities}\n\n")
        w.write(f"  {'pid':>6} {'type':>9} {'units':>10} {'thresh':>9} {'outages':>8} "
                f"{'worst':>9}  state\n")
        for pid in sorted(self.streams):
            st = self.streams[pid]
            th = ("no cadence" if st.no_cadence else
                  "learning" if st.threshold is None else f"{st.threshold * 1000:.0f} ms")
            worst = max(st.outages, default=0.0)
            if st.dead and st.last is not None:
                worst = max(worst, self.now - st.last)
            state = "DEAD" if st.dead else ("live" if st.units else "silent")
            w.write(f"  {pid:>6} {st.label():>9} {st.units:>10,} {th:>9} "
                    f"{len(st.outages) + (1 if st.dead else 0):>8} {worst:>8.2f}s  {state}\n")
        if self.clock_outages or self.clock_dead:
            w.write(f"\n  clock: {len(self.clock_outages) + (1 if self.clock_dead else 0)} "
                    f"stall(s), worst {max(self.clock_outages, default=0.0):.2f} s wall\n")
        w.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream", nargs="?", default="-", help="TS file, or - for stdin")
    ap.add_argument("--warmup", type=float, default=5.0,
                    help="media seconds discarded before learning starts, so the lane's own "
                         "start-up transient is not absorbed into every threshold")
    ap.add_argument("--learn", type=float, default=20.0,
                    help="media seconds of spacing observation used to set each threshold")
    ap.add_argument("--gap", default="",
                    help="explicit thresholds as pid:ms[,pid:ms...], which skip learning")
    ap.add_argument("--factor", type=float, default=6.0,
                    help="threshold as a multiple of each PID's own worst observed spacing")
    ap.add_argument("--floor", type=float, default=1.0, help="no threshold below this, seconds")
    ap.add_argument("--pcr-timeout", type=float, default=3.0,
                    help="wall seconds without a PCR before the clock itself is declared stopped")
    ap.add_argument("--pcr-jump", type=float, default=5.0,
                    help="a forward PCR step beyond this many seconds is treated as a "
                         "discontinuity rather than as elapsed media time")
    ap.add_argument("--jsonl", action="store_true", help="one JSON object per event")
    ap.add_argument("--quiet", action="store_true", help="events only, no closing summary")
    a = ap.parse_args()

    overrides = {}
    for item in filter(None, a.gap.split(",")):
        pid, _, ms = item.partition(":")
        overrides[int(pid)] = float(ms) / 1000.0

    f = sys.stdin.buffer if a.stream == "-" else open(a.stream, "rb")
    w = Watch(a.warmup, a.learn, a.factor, a.floor, a.pcr_timeout, a.pcr_jump, overrides,
              a.jsonl, sys.stdout)

    # A blocking read is fatal to the one check that matters when everything stops. If the
    # detector sits in `read()` waiting for a packet that will never come, its loop never runs,
    # and the total-outage case — the easiest failure in the set — is the one it misses. So a
    # pipe or socket is waited on with a timeout, and the timeout expiring is itself an
    # observation. A regular file needs none of this: it returns EOF instead of blocking.
    fd = f.fileno()
    live = not stat.S_ISREG(os.fstat(fd).st_mode)
    tick = min(0.25, a.pcr_timeout / 4)

    buf = b""
    try:
        while True:
            if live:
                if not select.select([fd], [], [], tick)[0]:
                    w.check_clock(time.monotonic())
                    continue
                chunk = os.read(fd, TS * 350)
            else:
                chunk = f.read(TS * 350)
            if not chunk:
                break
            buf += chunk
            wall = time.monotonic()
            n = len(buf) // TS * TS
            block, buf = buf[:n], buf[n:]
            for i in range(0, n, TS):
                p = block[i:i + TS]
                if p[0] == SYNC:
                    w.feed(p, wall)
            w.check_clock(wall)
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    finally:
        if f is not sys.stdin.buffer:
            f.close()

    try:
        if not a.quiet:
            w.summary()
    except BrokenPipeError:
        pass
    return 1 if w.alarms else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""A receiver's input switch that detects on the video PID and cuts at a random-access point (T80).

    t80-vswitch.py <input 0> <input 1> --events <events.txt> [--silence-ms 200] [--lookback-ms 0]

Reads two transport streams (files or FIFOs) as they arrive and writes one to stdout, starting on
input 0. When the serving input's video PID has carried no payload for --silence-ms while the
other's has, it cuts to the other, and never back on its own (non-revertive). A packet on the video
PID with no payload, such as a PCR alone, is not video. The cut writes the other input's latest PAT
and PMT, then that input from a video packet that starts a PES and sets random_access_indicator.
It repairs no continuity counter or table version.

--lookback-ms 0 (`rap`): each packet leaves as it arrives, and the cut starts the other input at
its next random-access point after the decision; the serving input runs on until then.

--lookback-ms L (`lookback`): each packet leaves L after it arrived, so the other input's last L
are still held at the decision. The cut starts it at its latest random-access point at least
MARGIN before the serving input's last video packet; the serving input ends at its own
random-access point within MATCH of that one by arrival (the same picture, from one source), else
at that instant's packet boundary. With none held that late, the other input's next one.

SIGUSR1 commands a cut to the other input (T83), planned as a fault's is, with the serving input's
last video packet as the instant it fell silent; it is ignored while a cut is planned or while the
other input carries no video.

Each decision appends `switch_<from>_<to> <unix seconds>` (a commanded one `cut_<from>_<to>`) to the
events file, as t58-event.sh does for tsswitch. The plan, each cut as written and, every 10 s, each
input's longest gap between video packets go to stderr.
"""
import argparse
import collections
import os
import queue
import signal
import sys
import threading
import time

PKT = 188
VIDEO_TYPES = {0x01, 0x02, 0x1B, 0x24}
MARGIN = 0.1
MATCH = 0.3
REPORT = 10.0


def log(msg):
    print(f"{time.time():.6f} {msg}", file=sys.stderr, flush=True)


class Input:
    """One input's parse state and the packets it holds, each (seq, arrival, packet, kind)."""

    def __init__(self, idx):
        self.idx = idx
        self.held = collections.deque()
        self.next_seq = 0
        self.pmt_pid = None
        self.video_pid = None
        self.pat = None
        self.pmt = None
        self.last_video = None
        self.gap = 0.0

    def take(self, t, p):
        kind = self.classify(p)
        if kind in ("v", "r"):
            if self.last_video is not None:
                self.gap = max(self.gap, t - self.last_video)
            self.last_video = t
        self.held.append((self.next_seq, t, p, kind))
        self.next_seq += 1

    def classify(self, p):
        """`r` a random-access video packet, `v` other video payload, `pat`, `pmt`, or ``."""
        pid = (p[1] & 0x1F) << 8 | p[2]
        afc = (p[3] >> 4) & 3
        off, rai = 4, False
        if afc & 2:
            alen = p[4]
            rai = alen > 0 and bool(p[5] & 0x40)
            off = 5 + alen
        if not afc & 1 or off >= PKT:
            return ""
        pusi = p[1] & 0x40
        if pid == self.video_pid:
            return "r" if rai and pusi else "v"
        if pid == 0 and pusi:
            s = off + 1 + p[off]
            if s + 8 <= PKT and p[s] == 0x00:
                slen = (p[s + 1] & 0x0F) << 8 | p[s + 2]
                for j in range(s + 8, min(s + 3 + slen - 4, PKT - 3), 4):
                    if p[j] << 8 | p[j + 1]:
                        self.pmt_pid = (p[j + 2] & 0x1F) << 8 | p[j + 3]
                        break
                self.pat = p
                return "pat"
        elif pid == self.pmt_pid and pusi:
            s = off + 1 + p[off]
            if s + 12 <= PKT and p[s] == 0x02:
                slen = (p[s + 1] & 0x0F) << 8 | p[s + 2]
                info = (p[s + 10] & 0x0F) << 8 | p[s + 11]
                j, end = s + 12 + info, min(s + 3 + slen - 4, PKT)
                while j + 5 <= end:
                    if p[j] in VIDEO_TYPES:
                        vpid = (p[j + 1] & 0x1F) << 8 | p[j + 2]
                        if vpid != self.video_pid:
                            log(f"input {self.idx}: video PID {vpid} (PMT PID {pid})")
                        self.video_pid = vpid
                        break
                    j += 5 + ((p[j + 3] & 0x0F) << 8 | p[j + 4])
                self.pmt = p
                return "pmt"
        return ""


def packets(buf):
    """The whole packets in buf, resynchronising on a sync byte the next packet confirms."""
    out, i, n = [], 0, len(buf)
    while n - i >= PKT:
        if buf[i] != 0x47 or (n - i >= 2 * PKT and buf[i + PKT] != 0x47):
            i += 1
            continue
        out.append(buf[i:i + PKT])
        i += PKT
    return out, buf[i:]


def reader(path, idx, q):
    fd = os.open(path, os.O_RDONLY)
    rest = b""
    while True:
        b = os.read(fd, 1 << 16)
        t = time.time()
        if not b:
            q.put((idx, t, None))
            return
        pkts, rest = packets(rest + b)
        if pkts:
            q.put((idx, t, pkts))


def write_all(data):
    view = memoryview(data)
    while view:
        view = view[os.write(1, view):]


class Switch:
    def __init__(self, a):
        self.lookback = a.lookback_ms / 1000
        self.silence = a.silence_ms / 1000
        self.events = a.events
        self.ins = [Input(0), Input(1)]
        self.serving = 0
        self.plan = None

    def stamp(self, name, t):
        with open(self.events, "a") as f:
            f.write(f"{name} {t:.6f}\n")

    def detect(self, now):
        s, o = self.ins[self.serving], self.ins[1 - self.serving]
        if s.last_video is None or o.last_video is None:
            return
        if now - s.last_video <= self.silence or now - o.last_video > self.silence:
            return
        self.decide(now, "switch", f"video silent {now - s.last_video:.3f} s")

    def command(self, now):
        s, o = self.ins[self.serving], self.ins[1 - self.serving]
        if self.plan is not None or s.last_video is None or o.last_video is None or now - o.last_video > self.silence:
            log("commanded cut ignored: a cut is planned or the other input carries no video")
            return
        self.decide(now, "cut", "commanded")

    def decide(self, now, event, why):
        s, o = self.ins[self.serving], self.ins[1 - self.serving]
        ta = s.last_video
        self.plan = {"to": o.idx, "ta": ta, "start": None, "stop": None, "after": max(now - self.lookback, ta - MARGIN)}
        self.stamp(f"{event}_{s.idx}_{o.idx}", now)
        log(f"decide {s.idx}->{o.idx}: {why}")
        if self.lookback > 0:
            held = [(seq, t) for seq, t, _, k in o.held if k == "r" and now - self.lookback < t <= ta - MARGIN]
            if held:
                self.plan_cut(held[-1], "held")

    def plan_cut(self, start, rule):
        s = self.ins[self.serving]
        trap = start[1]
        near = [(abs(t - trap), seq, t) for seq, t, _, k in s.held if k == "r" and abs(t - trap) <= MATCH]
        if near:
            _, stop, ts = min(near)
            how = f"at its random-access point {1000 * (ts - trap):+.0f} ms from the other's"
        else:
            stop = next((seq for seq, t, _, _ in s.held if t >= trap), s.next_seq)
            how = "at a packet boundary"
        self.plan["start"], self.plan["stop"] = start[0], stop
        log(f"plan {s.idx}->{self.plan['to']}: the other from its {rule} random-access point "
            f"{trap - self.plan['ta']:+.3f} s from the last video; this one ends {how}")

    def resolve(self):
        o = self.ins[self.plan["to"]]
        start = next(((seq, t) for seq, t, _, k in o.held if k == "r" and t > self.plan["after"]), None)
        if start:
            self.plan_cut(start, "next")

    def emit(self, now):
        due, buf = now - self.lookback, []
        while True:
            s, plan = self.ins[self.serving], self.plan
            cutting = plan is not None and plan["start"] is not None
            if cutting and (not s.held or s.held[0][0] >= plan["stop"]):
                o = self.ins[plan["to"]]
                while o.held and o.held[0][0] < plan["start"]:
                    o.held.popleft()
                if not o.held or o.held[0][1] > due:
                    break
                buf += [x for x in (o.pat, o.pmt) if x]
                log(f"cut {s.idx}->{o.idx} written, {now - plan['ta']:.3f} s after the last video")
                self.serving, self.plan = o.idx, None
                continue
            if s.held and s.held[0][1] <= due:
                buf.append(s.held.popleft()[2])
                continue
            break
        if buf:
            write_all(b"".join(buf))

    def trim(self, now):
        o = self.ins[1 - self.serving]
        keep = now - self.lookback - 0.2
        if self.plan is not None and self.plan["start"] is not None:
            return
        while o.held and o.held[0][1] < keep:
            o.held.popleft()

    def report(self, now):
        log("longest video gap: " + ", ".join(f"input {x.idx} {1000 * x.gap:.0f} ms" for x in self.ins)
            + f"; serving {self.serving}")
        for x in self.ins:
            x.gap = 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs=2)
    ap.add_argument("--events", required=True)
    ap.add_argument("--silence-ms", type=float, default=200)
    ap.add_argument("--lookback-ms", type=float, default=0)
    a = ap.parse_args()
    sw = Switch(a)
    q = queue.Queue()
    for i, path in enumerate(a.inputs):
        threading.Thread(target=reader, args=(path, i, q), daemon=True).start()
    commanded = []
    signal.signal(signal.SIGUSR1, lambda *_: commanded.append(True))
    log(f"silence {a.silence_ms:g} ms, lookback {a.lookback_ms:g} ms")
    ended, next_report = [False, False], time.time() + REPORT
    while not all(ended) or sw.ins[sw.serving].held:
        try:
            item = q.get(timeout=0.005)
        except queue.Empty:
            item = None
        while item is not None:
            i, t, pkts = item
            if pkts is None:
                ended[i] = True
            else:
                for p in pkts:
                    sw.ins[i].take(t, p)
            try:
                item = q.get_nowait()
            except queue.Empty:
                item = None
        now = time.time()
        if commanded:
            commanded.clear()
            sw.command(now)
        if sw.plan is None:
            sw.detect(now)
        if sw.plan is not None and sw.plan["start"] is None:
            sw.resolve()
        sw.emit(now if not all(ended) else float("inf"))
        sw.trim(now)
        if now >= next_report:
            sw.report(now)
            next_report = now + REPORT


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass

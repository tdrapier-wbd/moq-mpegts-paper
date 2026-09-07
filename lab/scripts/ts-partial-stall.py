#!/usr/bin/env python3
"""Suppress some elementary streams of a transport stream while its clock keeps running.

[T22](../test-22-silent-media-plane-failure.md) froze whole processes and found that the media
plane detects a stopped feed in about one cushion, with **PCR progression** the detector worth
building on because it needs nothing from MoQ, nothing from the groomer and no cooperation from
the sender. Its own limits section names what it did not test:

>   A real encoder that stalls may half-work — emitting some tracks and not others, or emitting
>   stale timestamps — and this experiment does not cover partial stalls. That is a materially
>   different failure and the detectors above are not obviously sufficient for it.

They are not obviously sufficient because in this clip, as in most, **PCR rides on the video
PID**. An encoder whose video path has died but whose mux and clock are still running therefore
emits exactly what this tool emits: adaptation-field-only packets carrying a perfectly healthy
PCR on the video PID, no video PES behind them, and every other stream untouched. Against that
stimulus PCR progression reads green, the carrier reads green, and a groomer watching content
liveness still sees audio arriving. The detector the architecture's observability case rests on
is defeated by the failure mode most likely to occur.

So the point of this is not to break the lane. It is to find out whether a *partial* failure is
observable at all, and whether the lane contains it or amplifies it into a total one — a mux
that stalls its whole output waiting for a track that will never arrive turns one dead
elementary stream into a dead service.

Modes, all of which keep the mux rate exact by substituting null packets:

  video   suppress the video PES, keep its PCR. The half-working encoder above.
  audio   suppress both audio streams, leave video and PCR. The inverse, and the case where
          per-track visibility should help if it helps anywhere.
  es      suppress every elementary stream, keep PCR and the PSI/SI tables. The extreme: a
          clock and a programme description with no programme.
  control pass through unchanged, so the graders have a null to fire against.

Two properties are preserved deliberately, because losing either would make the result a
measurement of this tool rather than of the lane:

- **Continuity counters stay legal across the suppression.** A counter that jumped would be
  caught by any TR 101 290 P1 check, which would make the failure trivially detectable and the
  experiment pointless. Each suppressed payload packet decrements a per-PID adjustment applied
  to everything subsequently emitted on that PID, so the surviving sequence is contiguous. The
  adjustment is applied *after* the decrement, which is what makes the adaptation-field-only
  PCR packets repeat the last payload counter rather than advance it — a packet with no payload
  must not increment (ISO 13818-1 2.4.3.3), and one that did would itself be the alarm.
- **The stream resumes on a PES boundary.** Suppression continues past the end of the window on
  each affected PID until its next `payload_unit_start_indicator`, so a decoder resumes at the
  start of an access unit instead of part-way through one. A real encoder coming back does the
  same thing.

The window is timed on the stream's **own PCR**, not on wall clock, so a run is deterministic
regardless of how fast the pipe is drained.

Usage:
  ts-partial-stall.py --mode video --at 30 --for 60 [clip.ts] > out.ts
  ts-partial-stall.py --verify out.ts

Reads stdin when no file is given, so it composes after `ts-continuous-source.py`.
"""

import argparse
import sys

TS = 188
SYNC = 0x47
PCR_MODULUS = (1 << 33) * 300
NULL_PID = 0x1FFF
PSI_PIDS = {0x0000, 0x0010, 0x0011, 0x0012, 0x0013, 0x0014, 0x001E, 0x001F}


def parse_pcr(p):
    if not (p[3] >> 4) & 0x2 or p[4] < 7 or not p[5] & 0x10:
        return None
    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
    return base * 300 + (((p[10] & 0x01) << 8) | p[11])


def null_packet():
    """A null packet, which carries no counter obligation at all (ISO 13818-1 2.4.3.2)."""
    p = bytearray(TS)
    p[0] = SYNC
    p[1] = 0x1F
    p[2] = 0xFF
    p[3] = 0x10
    for i in range(4, TS):
        p[i] = 0xFF
    return p


def strip_to_pcr(p):
    """Rebuild a packet as adaptation-field-only, keeping just its PCR.

    This is the shape a mux emits on the PCR PID when it has a clock and nothing to send: one
    packet, one adaptation field spanning the rest of it, the PCR flag and six bytes of PCR,
    the remainder stuffed. `adaptation_field_control` becomes 2 — adaptation field, no payload —
    which is what makes it counter-neutral.
    """
    out = bytearray(TS)
    out[0] = SYNC
    out[1] = p[1] & 0x1F  # keep PID, clear PUSI and transport_priority
    out[2] = p[2]
    out[3] = 0x20  # AF only, no payload; counter filled in by the caller
    out[4] = 183
    out[5] = 0x10  # PCR_flag
    out[6:12] = p[6:12]
    for i in range(12, TS):
        out[i] = 0xFF
    return out


def discover(src):
    """Find the PCR PID and classify the elementary streams, by observation not by PMT.

    Parsing the PMT would be the textbook route and is the wrong one here: the modes only need
    to know which PID carries PCR and which PIDs carry PES, and both are visible in the packets
    themselves, on a capture whose tables may be sparse as much as on a full one.
    """
    pcr_pid = None
    pes = set()
    seen = {}
    with open(src, "rb") as f:
        for _ in range(200_000):
            b = f.read(TS)
            if len(b) < TS or b[0] != SYNC:
                break
            pid = ((b[1] & 0x1F) << 8) | b[2]
            seen[pid] = seen.get(pid, 0) + 1
            if pcr_pid is None and parse_pcr(b) is not None:
                pcr_pid = pid
            if b[1] & 0x40 and pid not in PSI_PIDS and pid != NULL_PID:
                afc = (b[3] >> 4) & 0x3
                off = 4 if afc == 1 else (5 + b[4] if afc == 3 else None)
                if off is not None and off + 3 < TS:
                    if b[off] == 0 and b[off + 1] == 0 and b[off + 2] == 1:
                        pes.add(pid)
    return pcr_pid, pes, seen


def verify(path):
    """Grade a stimulus before it is trusted: counters legal, PCR monotone, rate preserved."""
    prev_cc = {}
    cc_errors = []
    prev_pcr = None
    backward = 0
    intervals = []
    packets = 0
    per_pid = {}
    with open(path, "rb") as f:
        while True:
            b = f.read(TS)
            if len(b) < TS or b[0] != SYNC:
                break
            packets += 1
            pid = ((b[1] & 0x1F) << 8) | b[2]
            per_pid[pid] = per_pid.get(pid, 0) + 1
            if pid != NULL_PID:
                cc = b[3] & 0x0F
                has_payload = bool((b[3] >> 4) & 0x1)
                if pid in prev_cc:
                    want = (prev_cc[pid] + 1) & 0x0F if has_payload else prev_cc[pid]
                    # A packet with no payload repeats the counter; one with payload advances
                    # it. A legal duplicate (2.4.3.3) repeats a payload packet's counter once,
                    # so a repeat of a payload packet is not counted as an error here.
                    if cc != want and not (has_payload and cc == prev_cc[pid]):
                        cc_errors.append((packets, pid, prev_cc[pid], cc, has_payload))
                prev_cc[pid] = cc
            v = parse_pcr(b)
            if v is not None:
                if prev_pcr is not None:
                    d = (v - prev_pcr) % PCR_MODULUS
                    if d > PCR_MODULUS // 2:
                        backward += 1
                    else:
                        intervals.append(d)
                prev_pcr = v
    worst = max(intervals) / 27e3 if intervals else 0
    print(f"packets            {packets:,}")
    print(f"continuity errors  {len(cc_errors)}   (required: 0)")
    for e in cc_errors[:8]:
        print(f"  pkt {e[0]:,} pid {e[1]} cc {e[2]}->{e[3]} payload={e[4]}")
    print(f"backward PCR steps {backward}   (required: 0)")
    print(f"PCRs               {len(intervals) + 1:,}")
    print(f"worst PCR interval {worst:.3f} ms   (required: < 40)")
    print("per-PID packet counts")
    for pid in sorted(per_pid):
        tag = " (null)" if pid == NULL_PID else ""
        print(f"  pid {pid:<5} {per_pid[pid]:>10,}{tag}")
    return 1 if (cc_errors or backward or worst >= 40) else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clip", nargs="?", help="input TS; stdin if omitted")
    ap.add_argument("--mode", choices=("control", "video", "audio", "es"), default="video")
    ap.add_argument("--at", type=float, default=30.0, help="seconds of PCR before suppressing")
    ap.add_argument("--for", dest="dur", type=float, default=60.0, help="suppression seconds")
    ap.add_argument("--video-pid", type=int, default=None, help="default: the PCR PID")
    ap.add_argument("--audio-pid", type=int, action="append", default=None)
    ap.add_argument("--pcr-pid", type=int, default=None, help="skip discovery, for stdin")
    ap.add_argument("--pes-pid", type=int, action="append", default=None)
    ap.add_argument("--verify", metavar="FILE", help="grade a stimulus and exit")
    a = ap.parse_args()

    if a.verify:
        return verify(a.verify)

    if a.clip:
        pcr_pid, pes, _ = discover(a.clip)
    else:
        # Discovery consumes packets, which cannot be given back to a pipe, so a stdin run
        # must be told what a file run would have found.
        pcr_pid, pes = a.pcr_pid, set(a.pes_pid or [])
        if pcr_pid is None:
            raise SystemExit("--pcr-pid is required when reading stdin")
    if pcr_pid is None:
        raise SystemExit("no PCR found in the first 200,000 packets")
    video_pid = a.video_pid if a.video_pid is not None else pcr_pid
    audio_pids = set(a.audio_pid) if a.audio_pid else (pes - {video_pid})

    if a.mode == "control":
        targets = set()
    elif a.mode == "video":
        targets = {video_pid}
    elif a.mode == "audio":
        targets = set(audio_pids)
    else:
        targets = {video_pid} | set(audio_pids)

    print(
        f"ts-partial-stall: mode={a.mode} pcr_pid={pcr_pid} video_pid={video_pid} "
        f"audio_pids={sorted(audio_pids)} suppressing={sorted(targets)} "
        f"window={a.at}s..{a.at + a.dur}s of PCR",
        file=sys.stderr,
    )

    at_ticks = int(a.at * 27e6)
    dur_ticks = int(a.dur * 27e6)
    cc_adj = dict.fromkeys(targets, 0)
    # Once the window closes, a PID stays suppressed until its next PES header, so that a
    # decoder resumes on an access unit rather than inside one.
    awaiting_pusi = dict.fromkeys(targets, False)
    first_pcr = None
    elapsed = 0
    suppressed = 0
    out = sys.stdout.buffer
    src = open(a.clip, "rb") if a.clip else sys.stdin.buffer
    try:
        while True:
            chunk = src.read(TS * 1024)
            if len(chunk) < TS:
                break
            buf = memoryview(bytearray(chunk))
            emit = bytearray()
            for i in range(0, len(buf) - TS + 1, TS):
                p = bytearray(buf[i : i + TS])
                if p[0] != SYNC:
                    continue
                pid = ((p[1] & 0x1F) << 8) | p[2]
                v = parse_pcr(p)
                if v is not None:
                    if first_pcr is None:
                        first_pcr = v
                    elapsed = (v - first_pcr) % PCR_MODULUS

                if pid not in targets:
                    emit += p
                    continue

                in_window = at_ticks <= elapsed < at_ticks + dur_ticks
                if in_window:
                    awaiting_pusi[pid] = True
                elif awaiting_pusi[pid] and p[1] & 0x40 and (p[3] >> 4) & 0x1:
                    # Window closed and this is a PES header: let the PID through again.
                    awaiting_pusi[pid] = False

                if not (in_window or awaiting_pusi[pid]):
                    p[3] = (p[3] & 0xF0) | ((p[3] + cc_adj[pid]) & 0x0F)
                    emit += p
                    continue

                # Suppressing. Anything whose payload is being removed decrements the
                # adjustment first, so what is emitted carries the counter of the last
                # payload packet that survived.
                if (p[3] >> 4) & 0x1:
                    cc_adj[pid] -= 1
                    suppressed += 1
                if v is not None:
                    q = strip_to_pcr(p)
                    q[3] = (q[3] & 0xF0) | ((p[3] + cc_adj[pid]) & 0x0F)
                    emit += q
                else:
                    emit += null_packet()
            out.write(emit)
        out.flush()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    print(f"ts-partial-stall: suppressed {suppressed:,} payload packets", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

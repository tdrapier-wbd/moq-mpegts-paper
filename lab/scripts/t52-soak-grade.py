#!/usr/bin/env python3
"""Grade a T52 soak (lab/test-52-cdn-relay-fanout.md).

    t52-soak-grade.py <subscriber run dir> <publisher run dir> [lane]

Against the soak's criteria: each subscriber's received bytes (its QUIC socket, summed over its
restarts) against the publisher's input, over the run and per hour; every exit, the publisher's and
the subscribers', with its cause, and each restarted subscriber's time to resubscribe and to report
output; the graded subscribers' monitor windows flagged for a continuity error, a PCR interval over
40 ms or a gap. A monitor's last window before an exit or the run's end is the event's, not graded.
Beside the verdict, ungraded: every span the exports logged as skipped upstream, common (at least
half the subscribers at one track and media time, lost at or before the relay) or not, outside the
JOIN_S seconds after each subscriber starts; evicted groups and dropped frames; the minutes in which
late frames were dropped, and those in which at least half the subscribers dropped them; the probe's
loss and RTT; the subscriber host's CPU.
"""

import bisect
import collections
import glob
import os
import re
import statistics
import sys
from datetime import datetime, timezone

JOIN_S = 15
ANSI = re.compile(r"\x1b\[[0-9;]*m")
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z\s+(\w+)\s+(.*)$")
SKIP = re.compile(r'media skipped upstream; resuming at the next group track="([^"]+)" at=([0-9.]+)s skipped=(\S+)')
EVICT = re.compile(r"current group evicted")
DEADLINE = re.compile(r"missed a decode deadline")
LATE = re.compile(r"frame missed its deadline; dropped")
RELEASE = re.compile(r"TS export release clock dropped=(\d+)")
MON = re.compile(r"t=(\d+) .*?gt40=(\d+) .*?cc=(\d+) .*?gap_ms=(\d+)")
PING = re.compile(r"^\[([0-9.]+)\] .* icmp_seq=(\d+) .* time=([0-9.]+) ms")


def epoch(stamp):
    return datetime.fromisoformat(stamp).replace(tzinfo=timezone.utc).timestamp()


def utc(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%m-%d %H:%M:%S.%f")[:-3]


def span_s(text):
    return float(text[:-2]) / 1000 if text.endswith("ms") else float(text[:-1])


def main():
    sub_dir, pub_dir = sys.argv[1], sys.argv[2]
    lane = sys.argv[3] if len(sys.argv) > 3 else "demux"
    s = lambda name: os.path.join(sub_dir, name)  # noqa: E731

    meta_text = open(s(f"meta-soak-{lane}.txt")).read()
    started = re.search(r"started=(\S+)Z", meta_text).group(1)
    finished = re.search(r"finished=(\S+)Z", meta_text).group(1)
    build = re.search(r"moq=(.*)", meta_text).group(1)
    t_start, t_end = epoch(started + ".0"), epoch(finished + ".0")
    print(f"soak {started}Z to {finished}Z, {(t_end - t_start) / 3600:.2f} h, {build}")

    # The publisher's input: rchar per process, summed over its restarts.
    pub, base, last, pid = [], 0, {}, None
    for line in open(os.path.join(pub_dir, f"pub-{lane}.io")):
        t, p, r = line.split()
        if p == "0":
            continue
        if p != pid:
            base += last.get(pid, 0)
            pid = p
        last[p] = int(r)
        pub.append((float(t), base + int(r)))
    pt = [x[0] for x in pub]

    def pub_at(t):
        return pub[max(bisect.bisect_right(pt, t) - 1, 0)][1]

    print(f"publisher: {pub[-1][1] * 8 / (pub[-1][0] - pub[0][0]) / 1e6:.4f} Mb/s over the run")
    for line in open(os.path.join(pub_dir, f"pub-{lane}.exits")):
        t = float(line.split()[0])
        print(f"  publisher exit {utc(t)} {line.split()[2]}")
    for t, level, msg in log_lines(os.path.join(pub_dir, f"pub-{lane}.log")):
        if level in ("WARN", "ERROR") and "TR 101 290" not in msg and ("session error" in msg):
            print(f"  publisher {utc(t)} {msg[:100]}")
    for raw in open(os.path.join(pub_dir, f"pub-{lane}.log"), errors="replace"):
        if raw.startswith("Error:"):
            print(f"  publisher {raw.strip()[:140]}")

    # Subscriber exits and restarts.
    exits = []
    for line in open(s(f"exits-{lane}.log")):
        f = line.split(" ", 4)
        exits.append((float(f[0]), int(f[1][2:]), f[2], f[4].split("last=", 1)[-1].strip()))
    starts = collections.defaultdict(lambda: [t_start])
    for t, i, _, _ in exits:
        starts[i].append(t + 1)
    print(f"\nsubscriber exits: {len(exits)}")
    events = []
    for t, i, _, why in sorted(exits):
        if events and t - events[-1][0] < 5:
            events[-1][1].add(i)
            events[-1][2][why] += 1
        else:
            events.append([t, {i}, collections.Counter({why: 1})])
    for t, subs, why in events:
        print(f"  {utc(t)}: {len(subs)} subscribers; {dict(why)}")

    # Per subscriber log: resubscription and first output report after each exit; skips, evictions,
    # deadline exits, dropped frames, the minutes in which late frames were dropped.
    skips = collections.defaultdict(list)
    evicts, deadlines, dropped, back = {}, {}, {}, []
    late = collections.defaultdict(set)
    paths = sorted(glob.glob(s(f"sub-{lane}.*.log")), key=lambda q: int(q.rsplit(".", 2)[-2]))
    for path in paths:
        i = int(path.rsplit(".", 2)[-2])
        mine = sorted(t for t, j, _, _ in exits if j == i)
        evicts[i] = deadlines[i] = 0
        drop_total, drop_last = 0, None
        pending = list(mine)
        resub = None
        for t, level, msg in log_lines(path):
            if pending and t > pending[0] + 0.5:
                if resub is None and "subscribe started" in msg and "catalog" in msg:
                    resub = t
                elif resub is not None and RELEASE.search(msg):
                    back.append((i, pending[0], resub - pending[0], t - pending[0]))
                    pending.pop(0)
                    resub = None
            if m := SKIP.search(msg):
                joining = any(0 <= t - st < JOIN_S for st in starts[i])
                skips[(m.group(1), round(float(m.group(2)), 1))].append((t, i, span_s(m.group(3)), joining))
            elif EVICT.search(msg):
                evicts[i] += 1
            elif DEADLINE.search(msg):
                deadlines[i] += 1
            elif LATE.search(msg):
                late[int(t // 60)].add(i)
            if m := RELEASE.search(msg):
                d = int(m.group(1))
                if drop_last is not None and d < drop_last:
                    drop_total += drop_last
                drop_last = d
        dropped[i] = drop_total + (drop_last or 0)
    if back:
        print(
            "  restarted subscribers: resubscribed after %.2f-%.2f s, output reported by %.2f-%.2f s"
            % (min(b[2] for b in back), max(b[2] for b in back), min(b[3] for b in back), max(b[3] for b in back))
        )

    # Received bytes against the publisher's input.
    rx = collections.defaultdict(list)
    for line in open(s(f"io-{lane}.log")):
        t, i, _, b, _ = line.split()
        rx[int(i)].append((float(t), int(b)))
    totals = {i: (v[-1][1] - v[0][1], pub_at(v[-1][0]) - pub_at(v[0][0])) for i, v in rx.items()}
    median = statistics.median(b for b, _ in totals.values())
    hourly = collections.defaultdict(lambda: [0, 0])
    t0 = min(v[0][0] for v in rx.values())
    for i, v in rx.items():
        for (ta, ba), (tb, bb) in zip(v, v[1:]):
            h = hourly[(i, int((ta - t0) // 3600))]
            h[0] += bb - ba
            h[1] += pub_at(tb) - pub_at(ta)
    worst = min((k for k, (b, p) in hourly.items() if p), key=lambda k: hourly[k][0] / hourly[k][1])
    print(
        "\nreceived at the socket, of the publisher's input: %.4f-%.4f over the run, at least %.4f in any hour"
        " (subscriber %d, the hour from %s); against the median subscriber %.5f-%.5f"
        % (
            min(b / p for b, p in totals.values()),
            max(b / p for b, p in totals.values()),
            hourly[worst][0] / hourly[worst][1],
            worst[0],
            utc(t0 + worst[1] * 3600)[:11],
            min(b for b, _ in totals.values()) / median,
            max(b for b, _ in totals.values()) / median,
        )
    )

    # Graded monitors.
    print("\nmonitors:")
    for path in sorted(glob.glob(s(f"mon-{lane}.*.log"))):
        i = path.rsplit(".", 2)[-2]
        rows = [MON.search(line) for line in open(path)]
        rows = [m for m in rows if m]
        ends = {k for k, (a, b) in enumerate(zip(rows, rows[1:])) if int(b.group(1)) < int(a.group(1))}
        ends.add(len(rows) - 1)
        flagged = [m.group(0) for k, m in enumerate(rows) if k not in ends and any(int(x) for x in m.groups()[1:])]
        at_events = [m.group(0) for k, m in enumerate(rows) if k in ends and any(int(x) for x in m.groups()[1:])]
        print(f"  sub{i}: {len(rows)} windows, {len(flagged)} flagged; at exits or the end: {at_events}")

    # Skips, beside the verdict.
    half = len(paths) / 2
    later = {k: v for k, v in skips.items() if not all(e[3] for e in v)}
    common = {k: v for k, v in later.items() if len(v) >= half}
    rest = {k: v for k, v in later.items() if len(v) < half}
    print(f"\nskipped upstream, after each start's first {JOIN_S} s (ungraded):")
    tracks = dict(collections.Counter(k[0] for k in common))
    print(f"  common to at least {half:.0f} subscribers: {len(common)}, by track {tracks}")
    for (track, at), v in sorted(common.items(), key=lambda kv: kv[1][0][0]):
        first, widest = min(e[0] for e in v), max(e[2] for e in v)
        print(f"    {utc(first)} {track} at {at} s, {len(v)} subscribers, {widest * 1000:.0f} ms")
    sizes = collections.Counter(len(v) for v in rest.values())
    print(
        f"  fewer: {len(rest)} spans, by how many subscribers {dict(sorted(sizes.items()))},"
        f" by track {dict(collections.Counter(k[0] for k in rest))}"
    )
    per_sub = collections.defaultdict(lambda: [0, 0.0])
    per_hour = collections.Counter()
    for (track, _), v in later.items():
        for t, i, span, joining in v:
            if joining:
                continue
            per_hour[int((t - t_start) // 3600)] += 1
            if track.endswith("avc3"):
                per_sub[i][0] += 1
                per_sub[i][1] += span
    print(
        "  per subscriber, video skips and video skipped: %d-%d, %.1f-%.1f s"
        % (
            min(v[0] for v in per_sub.values()),
            max(v[0] for v in per_sub.values()),
            min(v[1] for v in per_sub.values()),
            max(v[1] for v in per_sub.values()),
        )
    )
    print(
        "  all spans per hour: median %d, max %d (hour %d)"
        % (
            statistics.median(per_hour.get(h, 0) for h in range(int((t_end - t_start) // 3600))),
            max(per_hour.values()),
            max(per_hour, key=per_hour.get),
        )
    )
    print(
        f"  evicted groups per subscriber {min(evicts.values())}-{max(evicts.values())};"
        f" dropped frames {min(dropped.values())}-{max(dropped.values())};"
        f" deadline exits {sum(deadlines.values())}"
    )
    wide = sorted(m for m, who in late.items() if len(who) >= half)
    print(
        f"  minutes with late frames dropped: {len(late)}, by at least {half:.0f} subscribers {len(wide)}:"
        f" {', '.join(utc(m * 60)[:11] for m in wide)}"
    )

    # The probe and the host.
    rtts, summary = [], "no summary"
    for line in open(s(f"ping-{lane}.log")):
        if m := PING.match(line):
            rtts.append(float(m.group(3)))
        elif "packets transmitted" in line:
            summary = line.strip()
    rtts.sort()
    print(
        f"\nprobe: {summary}; RTT median {statistics.median(rtts):.1f} ms,"
        f" 99.9th {rtts[int(len(rtts) * 0.999)]:.1f}, max {rtts[-1]:.1f}; over 20 ms {sum(r > 20 for r in rtts)} s"
    )
    host = [tuple(map(float, line.split()[:3])) for line in open(s(f"host-{lane}.log")) if line.strip()]
    busy = [(b1 - b0) / max((b1 - b0) + (i1 - i0), 1) * 100 for (_, b0, i0), (_, b1, i1) in zip(host, host[1:])]
    print(f"host CPU over 10 s: mean {statistics.mean(busy):.1f} %, max {max(busy):.1f} %")


def log_lines(path):
    with open(path, errors="replace") as f:
        for raw in f:
            m = STAMP.match(ANSI.sub("", raw).strip())
            if m:
                yield epoch(m.group(1)), m.group(2), m.group(3)


if __name__ == "__main__":
    main()

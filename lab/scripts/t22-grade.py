#!/usr/bin/env python3
"""Read a T22 run and report, per detector, how long the failure went unnoticed.

    t22-grade.py <run-dir> [--tsv]

The run records three things against one wall clock: what was injected and when
(`events.log`), what the carrier and the programme clock were doing at 100 ms
(`wire.csv`), and what the groomer said about its own input (`pacer.log`). This
turns them into the only figures the experiment is about.

Detection latency is measured from the **last advancing media**, not from the
injection. Those differ by however much media was already buffered downstream of
the fault, and the difference is not an error -- it is the part of the outage the
buffer paid for, and it belongs to the result. Measuring from the injection would
credit the buffer's depth to the detector.

Detectors, in the order an operator would reach for them:

    session     the transport's own view: did anything close, error or reconnect
    carrier     bytes stopped arriving at the graded output
    pcr         no PCR advanced for longer than the P1 repetition limit
    groomer     the pacer's own content-liveness alarm (`SOURCE STALLED`)

`session` is the control. If it never fires while the others do, the failure is
silent to the transport, which is the claim the experiment exists to test.
"""

import argparse
import csv
import pathlib
import re
import sys

# The TR 101 290 P1 repetition limit. A PCR-progression alarm cannot fire faster
# than this without alarming on conformant streams, so it is the floor for that
# detector rather than a threshold chosen to flatter it.
P1_REPETITION_MS = 40.0


def read_events(path):
    events = []
    for line in path.read_text().splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            events.append((float(parts[0]), parts[1]))
    return events


def read_wire(path):
    rows = []
    with path.open() as handle:
        for row in csv.DictReader(handle):
            try:
                rows.append(
                    (
                        float(row["epoch"]),
                        int(row["bytes"]),
                        int(row["pcr_adv"]),
                        float(row["pcr_ms"]),
                    )
                )
            except (ValueError, KeyError):
                continue
    return rows


def first(events, needle):
    for at, what in events:
        if needle in what:
            return at, what
    return None, None


def grade(run):
    events = read_events(run / "events.log")
    wire = read_wire(run / "wire.csv")
    if not wire:
        raise SystemExit(f"{run}: no wire samples")

    meta = {}
    meta_path = run / "meta.txt"
    if meta_path.exists():
        for line in meta_path.read_text().split():
            if "=" in line:
                key, _, value = line.partition("=")
                meta.setdefault(key, value)

    stop_at, _ = first(events, "STOP ")
    cont_at, _ = first(events, "CONT ")
    if stop_at is None:
        stop_at, _ = first(events, "control: no injection")

    # The last tick in which the programme clock advanced before the outage the
    # injection caused. Everything is measured from here.
    #
    # It is *not* the tick nearest the injection. Media already downstream of the
    # fault keeps going to air after it, which is the whole reason the buffer is
    # there, so the clock carries on advancing for a while and then stops. Anchor
    # on the injection and both the buffer's contribution and the detectors that
    # fire after it are lost. So find the outage first -- the longest run of ticks
    # with no advance, after the injection -- and anchor on the tick before it.
    QUIET_TICKS = 10  # 1 s at the default tick, longer than any inter-PCR gap
    after_stop = [index for index, row in enumerate(wire) if stop_at is None or row[0] > stop_at]
    last_media = None
    if after_stop:
        start = after_stop[0]
        run_start = None
        best = None
        for index in range(start, len(wire)):
            if wire[index][2] == 0:
                if run_start is None:
                    run_start = index
            else:
                if run_start is not None and index - run_start >= QUIET_TICKS:
                    best = run_start
                    break
                run_start = None
        if best is None and run_start is not None and len(wire) - run_start >= QUIET_TICKS:
            best = run_start
        if best is not None:
            # The tick before the outage that last carried an advance.
            for index in range(best - 1, -1, -1):
                if wire[index][2] > 0:
                    last_media = wire[index][0]
                    break
    if last_media is None:
        # No outage found: the control arm, or a failure that did not stop media.
        for epoch, _bytes, adv, _pcr in wire:
            if adv > 0:
                last_media = epoch
        if last_media is None:
            last_media = wire[0][0]

    after = [row for row in wire if row[0] > last_media]

    # carrier: the first tick after the last advancing media with no bytes at all,
    # that is not immediately followed by bytes again (one empty tick is jitter).
    carrier_at = None
    for index, (epoch, byte_count, _adv, _pcr) in enumerate(after):
        if byte_count == 0 and all(row[1] == 0 for row in after[index : index + 3]):
            carrier_at = epoch
            break

    # pcr: the moment the silence since the last advance first exceeded the P1
    # repetition limit. This is what an external TS probe would alarm on and it is
    # the detector that does not need the groomer's cooperation.
    pcr_at = None
    for epoch, _bytes, adv, _pcr in after:
        if adv > 0:
            break
        if (epoch - last_media) * 1000.0 > P1_REPETITION_MS:
            pcr_at = epoch
            break

    # groomer: its own alarm. Emitted on stderr with no timestamp, so it is placed
    # by the sample line that follows it -- which bounds it above, never below, so
    # a groomer credited here is never credited with being faster than it was.
    groomer_at = None
    pacer_log = run / "pacer.log"
    if pacer_log.exists():
        text = pacer_log.read_text()
        if "SOURCE STALLED" in text:
            stalls = re.search(r"SOURCE STALLED \(stall #\d+, (\d+) ms without content\)", text)
            if stalls:
                groomer_at = last_media + float(stalls.group(1)) / 1000.0

    # session: what the transport said, and *when*. The control reading of the
    # whole experiment, so it is filtered rather than counted raw: every run opens
    # with `moq_native::reconnect connecting/connected`, and a detector credited
    # with those would be credited with noticing the failure before it happened.
    # Only lines after the injection count, and only lines that are not the
    # ordinary start-up chatter.
    benign = re.compile(r"moq_native::reconnect|connecting|connected\b", re.I)
    interesting = re.compile(r"error|closed|reconnect|disconnect|timeout|failed|reset|evicted|skipping", re.I)
    session_lines = []
    session_at = None
    timestamp = re.compile(r"(\d{4}-\d\d-\d\dT[\d:.]+)Z")
    for name in ("export.log", "pub.log", "relay.log"):
        path = run / name
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            plain = re.sub(r"\x1b\[[0-9;]*m", "", line).strip()
            if benign.search(plain) or not interesting.search(plain):
                continue
            when = timestamp.search(plain)
            at = None
            if when:
                try:
                    import datetime

                    at = (
                        datetime.datetime.fromisoformat(when.group(1)).replace(tzinfo=datetime.timezone.utc).timestamp()
                    )
                except ValueError:
                    at = None
            if at is not None and at < last_media:
                continue
            session_lines.append(f"{name}: {plain[:150]}")
            if at is not None and (session_at is None or at < session_at):
                session_at = at

    # Recovery, scored on media rather than on the session.
    media_back_at = None
    if cont_at:
        for epoch, _bytes, adv, _pcr in wire:
            if epoch > cont_at and adv > 0:
                media_back_at = epoch
                break
    stable_at = None
    if media_back_at:
        # Stable means the clock has advanced in every tick for two seconds, which
        # is the difference between "a packet arrived" and "the feed is back".
        run_len = 0
        for epoch, _bytes, adv, _pcr in wire:
            if epoch < media_back_at:
                continue
            run_len = run_len + 1 if adv > 0 else 0
            if run_len >= 20:
                stable_at = epoch - 2.0
                break

    # Programme lost: the media time the clock skipped against the wall time that
    # passed. A groomer that muted and resumed on the live edge shows the outage
    # here even though it emitted no bad packet.
    gap_ms = None
    if media_back_at:
        before = [row for row in wire if row[0] <= last_media and row[3] > 0]
        after_rows = [row for row in wire if row[0] >= media_back_at and row[3] > 0]
        if before and after_rows:
            gap_ms = after_rows[0][3] - before[-1][3]

    def since(at):
        return None if at is None else round(at - last_media, 3)

    return {
        "run": run.name,
        "arm": meta.get("arm", "?"),
        "policy": meta.get("policy", "?"),
        "stall_s": meta.get("stall_s", "?"),
        "detect_carrier_s": since(carrier_at),
        "detect_pcr_s": since(pcr_at),
        "detect_groomer_s": since(groomer_at),
        "session_events": len(session_lines),
        "session_sample": session_lines[:3],
        "buffer_paid_s": None if stop_at is None else round(last_media - stop_at, 3),
        "media_back_s": None if media_back_at is None or cont_at is None else round(media_back_at - cont_at, 3),
        "stable_s": None if stable_at is None or cont_at is None else round(stable_at - cont_at, 3),
        "programme_gap_ms": None if gap_ms is None else round(gap_ms, 1),
        "wall_gap_s": None if media_back_at is None else round(media_back_at - last_media, 3),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+", type=pathlib.Path)
    ap.add_argument("--tsv", action="store_true", help="one row per run, for a table")
    args = ap.parse_args()

    results = [grade(run) for run in args.runs]

    if args.tsv:
        columns = [
            "run",
            "arm",
            "policy",
            "buffer_paid_s",
            "detect_carrier_s",
            "detect_pcr_s",
            "detect_groomer_s",
            "session_events",
            "media_back_s",
            "stable_s",
            "wall_gap_s",
            "programme_gap_ms",
        ]
        print("\t".join(columns))
        for result in results:
            print("\t".join("" if result[c] is None else str(result[c]) for c in columns))
        return

    for result in results:
        print(f"=== {result['run']}  arm={result['arm']} policy={result['policy']} ===")
        print(f"  buffer absorbed          {result['buffer_paid_s']} s after the injection")
        print(f"  carrier stopped          {result['detect_carrier_s']} s after last advancing media")
        print(f"  PCR progression alarm    {result['detect_pcr_s']} s")
        print(f"  groomer content alarm    {result['detect_groomer_s']} s")
        print(f"  transport said            {result['session_events']} thing(s)")
        for line in result["session_sample"]:
            print(f"      {line}")
        print(f"  media returned           {result['media_back_s']} s after resume")
        print(f"  stable output            {result['stable_s']} s after resume")
        print(f"  off air                  {result['wall_gap_s']} s")
        print(f"  programme clock skipped  {result['programme_gap_ms']} ms")
        print()


if __name__ == "__main__":
    sys.exit(main())

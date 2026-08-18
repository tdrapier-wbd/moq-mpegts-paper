#!/usr/bin/env python3
"""T13 grading: what an IRD would make of a groomed transport stream.

Three modes:

    t13-grade.py rate <stream.ts>
    t13-grade.py grade <dir> [reference.ts]
    t13-grade.py gstbranches <stream.ts>

`rate` reports the content rate carried by a null-free stream, computed from its
own PCR timeline. That number is the input every candidate grooming chain needs,
because a MoQ egress carries no stuffing and so has no declared mux rate.

`grade` runs every `*.ts` in a directory through the oracle and tabulates the
result. The structural columns are relative to the first file in the directory,
so name the ungroomed egress so that it sorts first.

PCR accuracy is reported at both gates that matter: `--absolute --jitter-max 13`
(13 PCR units, about 481 ns, the TR 101 290 P2 limit) and the plain
`--jitter-max 500`, which TSDuck reads as 500 *micro*-seconds. Passing the second
says very little; only the first is the broadcast limit.

The units follow `--absolute`, which is easy to get wrong in either direction: with
it, `--jitter-max` counts 27 MHz PCR ticks (13 ticks = 481 ns, 500 ticks = 18 us);
without it, the same option is microseconds. Both gates here are as labelled.

`gstbranches` prints the `gst-launch-1.0` branch fragment for a GStreamer remux of
this stream, one token per line: `tsdemux` names its pads after the PID and
`mpegtsmux` takes the PID from its request pad name, so both ends can be pinned,
but only for the streams `tsdemux` exposes. SCTE-35 PIDs are reported on stderr
rather than branched, because `tsdemux` carries splice information as section
events and not as pads.
"""

from __future__ import annotations

import csv
import json
import os
import re
import subprocess
import sys
import tempfile

COMPLIANCE = os.path.expanduser("~/moq-dev/test/ts/compliance.py")


def sh(cmd: str) -> str:
    """Run a shell command, returning stdout and stderr together."""
    done = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return done.stdout + done.stderr


def counted(cmd: str) -> int:
    match = re.search(r"counted ([\d,]+) packets", sh(cmd))
    return int(match.group(1).replace(",", "")) if match else -1


def packets(path: str, extra: str = "") -> int:
    return counted(f'tsp -I file "{path}" {extra} -P count --total -O drop')


def pcr_timeline(path: str) -> list[tuple[int, int]]:
    """(packet index, PCR value) for every PCR in the stream."""
    with tempfile.NamedTemporaryFile(suffix=".csv") as tmp:
        sh(f'tsp -I file "{path}" -P pcrextract --pcr --csv -o {tmp.name} -O drop')
        with open(tmp.name) as fh:
            return [
                (int(row["Packet index in TS"]), int(row["Value"]))
                for row in csv.DictReader(fh)
                if row["Type"] == "PCR"
            ]


def content_rate(path: str) -> float:
    marks = pcr_timeline(path)
    if len(marks) < 2:
        raise SystemExit(f"{path}: fewer than two PCRs, cannot derive a rate")
    (first_index, first_pcr), (last_index, last_pcr) = marks[0], marks[-1]
    span_s = (last_pcr - first_pcr) / 27_000_000
    return (last_index - first_index) * 188 * 8 / span_s


def pcrverify(path: str, absolute: bool) -> int | None:
    gate = "--absolute --jitter-max 13" if absolute else "--jitter-max 500"
    match = re.search(
        r"([\d,]+) PCR OK, ([\d,]+) with jitter",
        sh(f'tsp -I file "{path}" -P pcrverify {gate} -O drop'),
    )
    return int(match.group(2).replace(",", "")) if match else None


def structure(path: str) -> dict[int, str]:
    """PID -> TSDuck's description of what it carries."""
    found = {}
    for line in sh(f'tsp -I file "{path}" -P analyze --normalized -O drop').splitlines():
        if not line.startswith("pid:"):
            continue
        fields = dict(f.split("=", 1) for f in line.split(":") if "=" in f)
        found[int(fields.get("pid", -1))] = fields.get("description", "?")
    return found


PARSERS = (
    ("AVC", "h264parse"),
    ("HEVC", "h265parse"),
    ("AC-3", "ac3parse"),
    ("AAC", "aacparse"),
    ("MPEG-1 Audio", "mpegaudioparse"),
    ("MPEG-2 Audio", "mpegaudioparse"),
)
QUEUE = ["queue", "max-size-buffers=0", "max-size-time=0", "max-size-bytes=134217728"]


def gst_branches(path: str) -> None:
    """Print a gst-launch branch fragment, one token per line."""
    for line in sh(f'tsp -I file "{path}" -P analyze --normalized -O drop').splitlines():
        if not line.startswith("pid:") or ":global:" in line:
            continue
        fields = line.split(":")
        table = dict(f.split("=", 1) for f in fields if "=" in f)
        pid = int(table.get("pid", -1))
        description = table.get("description", "")
        if "video" in fields:
            pad = f"video_0_{pid:04x}"
        elif "audio" in fields:
            pad = f"audio_0_{pid:04x}"
        elif "Teletext" in description:
            pad = f"private_0_{pid:04x}"
        else:
            print(f"not branched (tsdemux exposes no pad): PID {pid} {description}",
                  file=sys.stderr)
            continue
        parser = next((p for key, p in PARSERS if key in description), None)
        tokens = [f"d.{pad}", "!", *QUEUE, "!"]
        if parser:
            tokens += [parser, "!"]
        tokens.append(f"m.sink_{pid}")
        print("\n".join(tokens))


def compliance(path: str, reference: str | None) -> tuple[dict, dict]:
    report_path = path + ".json"
    argv = ["python3", COMPLIANCE, "--ts", path, "--report-json", report_path]
    if reference:
        argv += ["--reference", reference]
    subprocess.run(argv, capture_output=True, text=True)
    with open(report_path) as fh:
        report = json.load(fh)
    return report, {check["name"]: check for check in report["checks"]}


def grade(directory: str, reference: str | None) -> None:
    rows = []
    base = None
    for name in sorted(f for f in os.listdir(directory) if f.endswith(".ts")):
        path = os.path.join(directory, name)
        total = packets(path)
        nulls = packets(path, "-P filter --pid 8191")
        report, checks = compliance(path, reference)
        seen = structure(path)
        base = seen if base is None else base
        rows.append({
            "variant": name[:-3],
            "packets": total,
            "stuff": 100.0 * nulls / total if total > 0 else 0.0,
            "ns": pcrverify(path, True),
            "us": pcrverify(path, False),
            "cc": checks["continuity"]["metrics"].get("cc_errors"),
            "jitter": checks["pcr-jitter"]["metrics"].get("max_abs_us"),
            "rate": checks["bitrate-consistency"]["metrics"].get("nominal_bps"),
            "repetition": checks["pcr-repetition"]["metrics"].get("intervals_over_limit"),
            "duration": checks.get("duration-fidelity", {}).get("metrics", {}).get("ratio"),
            "lost": sorted(set(base) - set(seen)),
            "added": sorted(set(seen) - set(base)),
            "retyped": sorted(p for p in set(base) & set(seen) if base[p] != seen[p]),
            "failed": [c["name"] for c in report["checks"] if c["status"] == "FAIL"],
        })

    header = (f"{'variant':<24}{'packets':>10}{'stuff%':>8}{'Mb/s':>9}"
              f"{'PCR>481ns':>11}{'PCR>500us':>11}{'>40ms':>7}{'CC':>5}"
              f"{'jit us':>9}{'dur':>7}")
    print(header)
    print("-" * len(header))
    for row in rows:
        rate = f"{row['rate'] / 1e6:.3f}" if row["rate"] else "?"
        print(f"{row['variant']:<24}{row['packets']:>10,}{row['stuff']:>8.1f}{rate:>9}"
              f"{str(row['ns']):>11}{str(row['us']):>11}{str(row['repetition']):>7}"
              f"{str(row['cc']):>5}{str(row['jitter']):>9}{str(row['duration']):>7}")
    print()
    for row in rows:
        notes = []
        for label in ("lost", "added", "retyped"):
            if row[label]:
                notes.append(f"PIDs {label}: {row[label]}")
        if row["failed"]:
            notes.append(f"FAIL: {row['failed']}")
        print(f"{row['variant']:<24} {'; '.join(notes) if notes else 'structure preserved'}")


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    if sys.argv[1] == "rate":
        print(f"{content_rate(sys.argv[2]):.0f}")
    elif sys.argv[1] == "gstbranches":
        gst_branches(sys.argv[2])
    elif sys.argv[1] == "grade":
        grade(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()

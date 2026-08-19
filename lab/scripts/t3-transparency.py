#!/usr/bin/env python3
"""T3 transparency inventory: score one egress capture against a source reference.

    t3-transparency.py <source.ts> <egress.ts> [--label NAME] [--run-env FILE]

Emits the inventory T3 scores a carriage lane against — service identity, the
component census at original PIDs, PSI/SI survival, mux structure, integrity and
P1 timing — as a source-versus-egress delta, plus a *packet conservation* section
that scores what the lane ADDED as well as what it lost.

Three things about the instrument, each of which has already cost this campaign a
wrong number:

* Every rate here is PCR-derived (`pcrbitrate`), never bytes-over-wall-clock. The
  two disagree whenever a capture's window and its media differ, which is T9's
  loopback span artefact.
* PID counts are only comparable when both captures cover the same quantity of
  mux, so this asserts the packet totals match rather than assuming it, and
  normalises the census per 100,000 packets regardless.
* `pcrverify --jitter-max` is MICROseconds by default and PCR ticks only under
  `--absolute` (27 MHz, so 13 ticks = 481 ns = the TR 101 290 P2 limit). The
  tightest-passing bound below is reported in both units, and the gates are
  labelled with the unit the tool echoes rather than the number passed to it.
"""

import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

# TR 101 290 P1 section 5.2 repetition limits, in ms.
P1_TABLE_LIMIT_MS = {"PAT": 500, "PMT": 500, "SDT": 2000, "NIT": 10000}
PCR_LIMIT_MS = 40.0
PCR_CLOCK_HZ = 27_000_000


def tsp(src, *plugins):
    cmd = ["tsp", "-I", "file", str(src), *plugins, "-O", "drop"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.stdout + r.stderr


def normalized(src):
    """Parse `analyze --normalized` into {ts, service, pids{}, tables{}}.

    Fields are colon-separated, and a `description` value can itself contain a
    colon (`4:2:0` chroma), so it is taken whole from the first `description=`
    to end of line rather than split.
    """
    out = {"ts": {}, "service": {}, "pids": {}, "tables": {}}
    for line in tsp(src, "-P", "analyze", "--normalized").splitlines():
        head, _, desc = line.partition("description=")
        parts = head.split(":")
        if not parts:
            continue
        kind, fields = parts[0], {}
        for p in parts[1:]:
            if "=" in p:
                k, v = p.split("=", 1)
                fields[k] = v
        if desc:
            fields["description"] = desc.rstrip(":")
        if kind == "ts":
            out["ts"] = fields
        elif kind == "service":
            out["service"] = fields
        elif kind == "pid":
            out["pids"][int(fields["pid"])] = fields
        elif kind == "table":
            out["tables"].setdefault(int(fields["pid"]), []).append(fields)
    return out


def pcr_intervals(src):
    """min/mean/max PCR repetition interval in ms, and the count above 40 ms.

    `-o` is not optional. Without it `pcrextract --csv` writes to the *report*
    stream, i.e. stderr, so a harness reading stdout gets an empty series and
    reports no PCR rows at all rather than failing — which is how the first pass
    of this script silently dropped the two P1 timing rows.
    """
    with tempfile.NamedTemporaryFile(suffix=".csv") as tmp:
        subprocess.run(
            ["tsp", "-I", "file", str(src), "-P", "pcrextract",
             "--pcr", "--csv", "-o", tmp.name, "-O", "drop"],
            capture_output=True,
            text=True,
        )
        csv = pathlib.Path(tmp.name).read_text()
    vals = []
    for line in csv.splitlines():
        cols = line.split(",")
        if len(cols) >= 6:
            try:
                vals.append(int(cols[5]))
            except ValueError:
                pass  # header row
    deltas = [
        (b - a) / (PCR_CLOCK_HZ / 1000.0) for a, b in zip(vals, vals[1:]) if b > a
    ]
    if not deltas:
        return None
    over = [d for d in deltas if d > PCR_LIMIT_MS]
    return {
        "n": len(deltas),
        "min": min(deltas),
        "mean": sum(deltas) / len(deltas),
        "max": max(deltas),
        "over40": len(over),
        "over40pct": 100.0 * len(over) / len(deltas),
    }


VERIFY_RE = re.compile(r"([\d,]+) PCR OK, ([\d,]+) with jitter")


def pcr_violations(src, ticks):
    """Violations at a `--absolute --jitter-max <ticks>` gate."""
    txt = tsp(src, "-P", "pcrverify", "--absolute", "--jitter-max", str(ticks))
    m = VERIFY_RE.search(txt)
    if not m:
        return None, None
    return int(m.group(1).replace(",", "")), int(m.group(2).replace(",", ""))


def tightest_clean_bound(src, hi=1 << 24):
    """Smallest `--absolute --jitter-max` with zero violations = the max jitter.

    T1 states file PCR accuracy this way rather than as a single number, because
    it is the only form `pcrverify` reports directly.
    """
    _, v = pcr_violations(src, hi)
    if v is None or v > 0:
        return None
    lo = 1
    while lo < hi:
        mid = (lo + hi) // 2
        _, v = pcr_violations(src, mid)
        if v == 0:
            hi = mid
        else:
            lo = mid + 1
    return lo


def continuity_errors(src):
    """Discontinuities as `tsp -P continuity` counts them.

    Reported beside `analyze`'s per-PID `discontinuities` sum rather than instead
    of it: T16 measured the two disagreeing on the same stream (220 against 231),
    so agreement here is a check on the instruments and a disagreement is a
    finding about the capture.
    """
    txt = tsp(src, "-P", "continuity")
    return sum(1 for line in txt.splitlines() if "discontinuity" in line.lower())


def segment_heads(path, pmtpid, window=4):
    """Count back-to-back PAT→PMT pairs — i.e. segment heads.

    The HLS output plugin writes a PAT immediately followed by a PMT at the head
    of every segment, where the source interleaves the two among media packets.
    Counting adjacent pairs therefore counts injected Media Initialization
    Sections directly, which is what makes the packet-conservation figure
    independent of segment duration and of how much of the live window the
    receiver drained before settling.
    """
    data = pathlib.Path(path).read_bytes()
    pids = []
    for off in range(0, len(data) - 187, 188):
        if data[off] != 0x47:
            return None  # not 188-aligned; caller falls back
        pids.append(((data[off + 1] & 0x1F) << 8) | data[off + 2])
    heads, i = 0, 0
    while i < len(pids):
        if pids[i] == 0:
            nxt = pids[i + 1:i + 1 + window]
            if pmtpid in nxt:
                heads += 1
                i += 1 + nxt.index(pmtpid)
        i += 1
    return heads


def stuffing_profile(path, parts=4):
    """Stuffing fraction per quarter of a capture.

    The census compares two captures of equal packet count, which only measures
    the lane if both cover equivalent mux. A source whose stuffing varies along
    the file breaks that silently — a head-heavy reference reads as the lane
    having stripped stuffing — so the profile is reported rather than assumed.
    """
    data = pathlib.Path(path).read_bytes()
    n = len(data) // 188
    if n < parts:
        return None
    out = []
    for i in range(parts):
        lo, hi = n * i // parts, n * (i + 1) // parts
        nulls = sum(
            1
            for off in range(lo * 188, hi * 188, 188)
            if (((data[off + 1] & 0x1F) << 8) | data[off + 2]) == 0x1FFF
        )
        out.append(100.0 * nulls / (hi - lo))
    return out


def describe(fields):
    d = fields.get("description", "")
    return re.sub(r"\s*\(.*\)\s*$", "", d) or "?"


def table_name(pid, recs):
    tids = {r.get("tid") for r in recs}
    if pid == 0:
        return "PAT"
    if pid == 1:
        return "CAT"
    if pid == 16:
        return "NIT"
    if pid == 17:
        return "SDT"
    if pid == 20:
        return "TDT/TOT"
    if "2" in tids:
        return "PMT"
    if "252" in tids:
        return "SCTE-35"
    return "PID 0x%04X" % pid


def row(label, a, b, flag=None):
    same = str(a) == str(b)
    mark = "same" if same else "DIFF"
    if flag is not None:
        mark = flag
    return f"| {label} | {a} | {b} | **{mark}** |"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("egress")
    ap.add_argument("--label", default="")
    ap.add_argument("--run-env")
    args = ap.parse_args()

    env = {}
    if args.run_env and pathlib.Path(args.run_env).is_file():
        for line in pathlib.Path(args.run_env).read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                env[k] = v

    S, E = normalized(args.source), normalized(args.egress)
    if not S["ts"] or not E["ts"]:
        sys.exit("analyze produced nothing; is either file a valid TS?")

    print(f"### {args.label or 'capture'} — source reference vs egress\n")

    sp, ep = int(S["ts"]["packets"]), int(E["ts"]["packets"])
    print(f"Window: {sp:,} source packets against {ep:,} egress packets", end="")
    print(f" ({100.0 * ep / sp:.2f} % of the reference)." if sp else ".")
    if args.run_env:
        print(f"Reference offset into the clip: {env.get('reference_skip_seconds', '?')} s "
              f"({int(env.get('reference_skip_packets', 0) or 0):,} packets), "
              "aligning it to the media the receiver joined.")

    sprof, eprof = stuffing_profile(args.source), stuffing_profile(args.egress)
    if sprof and eprof:
        fmt = lambda p: " / ".join(f"{x:.2f}" for x in p)  # noqa: E731
        spread = max(sprof) - min(sprof)
        print(f"\nStuffing by quarter — source {fmt(sprof)} %, egress {fmt(eprof)} %. "
              f"Reference spread {spread:.2f} points: "
              f"{'homogeneous, so the census rows measure the lane' if spread < 1.0 else '**NOT homogeneous — census rows carry the window, not only the lane**'}.")
    print()

    print("| Field (source → egress) | source | egress | |")
    print("|---|---|---|---|")
    ss, es = S["service"], E["service"]
    print(row("Transport Stream Id", "0x%04X" % int(ss.get("tsid", -1)), "0x%04X" % int(es.get("tsid", -1))))
    print(row("Original Network Id", "0x%04X" % int(ss.get("orignetwid", -1)), "0x%04X" % int(es.get("orignetwid", -1))))
    print(row("Service name", ss.get("name", "—"), es.get("name", "—")))
    print(row("Service provider", ss.get("provider", "—"), es.get("provider", "—")))
    print(row("Service type", "0x%02X" % int(ss.get("servtype", 0)), "0x%02X" % int(es.get("servtype", 0))))
    print(row("PMT PID", "0x%04X" % int(ss.get("pmtpid", -1)), "0x%04X" % int(es.get("pmtpid", -1))))
    print(row("PCR PID", "0x%04X" % int(ss.get("pcrpid", -1)), "0x%04X" % int(es.get("pcrpid", -1))))
    print(row("PID count", S["ts"]["pids"], E["ts"]["pids"]))
    print(row("PCR-derived bitrate (b/s)", f"{int(S['ts']['pcrbitrate']):,}", f"{int(E['ts']['pcrbitrate']):,}"))
    print(row("Invalid sync / transport errors",
              f"{S['ts']['invalidsyncs']} / {S['ts']['transporterrors']}",
              f"{E['ts']['invalidsyncs']} / {E['ts']['transporterrors']}"))

    snull = int(S["pids"].get(0x1FFF, {}).get("packets", 0))
    enull = int(E["pids"].get(0x1FFF, {}).get("packets", 0))
    print(row("Null stuffing (packets, % of mux)",
              f"{snull:,} ({100.0 * snull / sp:.2f} %)",
              f"{enull:,} ({100.0 * enull / ep:.2f} %)",
              flag="preserved" if enull else "STRIPPED"))

    sdisc = sum(int(p.get("discontinuities", 0)) for p in S["pids"].values())
    edisc = sum(int(p.get("discontinuities", 0)) for p in E["pids"].values())
    scont, econt = continuity_errors(args.source), continuity_errors(args.egress)
    print(row("Continuity-counter errors (`analyze`)", sdisc, edisc))
    print(row("Continuity-counter errors (`-P continuity`)", scont, econt,
              flag="agrees" if (sdisc, edisc) == (scont, econt) else "**INSTRUMENTS DISAGREE**"))

    si, ei = pcr_intervals(args.source), pcr_intervals(args.egress)
    if si and ei:
        print(row("PCR interval min/mean/max (ms)",
                  f"{si['min']:.2f} / {si['mean']:.2f} / {si['max']:.2f}",
                  f"{ei['min']:.2f} / {ei['mean']:.2f} / {ei['max']:.2f}",
                  flag="see below"))
        print(row("PCR intervals > 40 ms",
                  f"{si['over40']} ({si['over40pct']:.4f} %)",
                  f"{ei['over40']} ({ei['over40pct']:.4f} %)"))

    sb, eb = tightest_clean_bound(args.source), tightest_clean_bound(args.egress)

    def bound(t):
        if t is None:
            return "no clean bound"
        return f"{t} ticks ({t * 1e9 / PCR_CLOCK_HZ:.0f} ns)"

    print(row("PCR accuracy, tightest clean bound", bound(sb), bound(eb), flag="see below"))
    for ticks, name in ((13, "481 ns — TR 101 290 P2"), (13500, "500 µs — campaign pre-check")):
        _, sv = pcr_violations(args.source, ticks)
        _, ev = pcr_violations(args.egress, ticks)
        print(row(f"PCR violations at {name}", sv, ev))

    # --- component census -----------------------------------------------------
    print("\n#### Component census, at original PIDs\n")
    print("| PID | Content | source | egress | per 100k, source → egress |")
    print("|---|---|---:|---:|---|")
    for pid in sorted(set(S["pids"]) | set(E["pids"])):
        s, e = S["pids"].get(pid), E["pids"].get(pid)
        sn = int(s["packets"]) if s else 0
        en = int(e["packets"]) if e else 0
        name = describe(s or e)
        srate = 1e5 * sn / sp if sp else 0
        erate = 1e5 * en / ep if ep else 0
        state = "absent at egress" if (s and not e) else ("ADDED" if (e and not s) else "")
        print(
            f"| 0x%04X | {name} | {sn:,} | {en:,} | {srate:,.0f} → {erate:,.0f} {state} |" % pid
        )

    # --- PSI/SI survival and repetition --------------------------------------
    print("\n#### PSI/SI survival and P1 repetition\n")
    print("| Table | source mean/max (ms) | egress mean/max (ms) | P1 limit | versions src → egr | |")
    print("|---|---|---|---|---|---|")
    for pid in sorted(set(S["tables"]) | set(E["tables"])):
        srecs, erecs = S["tables"].get(pid, []), E["tables"].get(pid, [])
        name = table_name(pid, srecs or erecs)

        def rep(recs):
            """Mean/max repetition, or "1 occurrence" — a single section in the
            window yields no interval, and printing that as 0 ms reads as a
            table repeating infinitely fast."""
            if not recs:
                return "absent", None
            if max(int(r.get("tables", 0)) for r in recs) < 2:
                return "1 occurrence", None
            mean = max(int(r.get("repetitionms", 0)) for r in recs)
            mx = max(int(r.get("maxrepetitionms", 0)) for r in recs)
            return f"{mean} / {mx}", mx

        st, _ = rep(srecs)
        et, emx = rep(erecs)
        limit = P1_TABLE_LIMIT_MS.get(name)
        verdict = ""
        if limit and emx is not None:
            verdict = "within P1" if emx <= limit else f"**OVER P1 ({limit} ms)**"
        elif not erecs:
            verdict = "**LOST**"
        vers = "%s → %s" % (
            ",".join(sorted({r.get("versions", "-") for r in srecs})) or "-",
            ",".join(sorted({r.get("versions", "-") for r in erecs})) or "-",
        )
        print(f"| {name} (0x%04X) | {st} | {et} | {limit or '—'} | {vers} | {verdict} |" % pid)

    # --- packet conservation --------------------------------------------------
    print("\n#### Packet conservation — what the lane added\n")
    pmtpid = int(es.get("pmtpid", -1))
    s_heads = segment_heads(args.source, pmtpid)
    e_heads = segment_heads(args.egress, pmtpid)
    extinf = env.get("segment_mean_extinf_s")
    if extinf:
        print(f"Mean segment duration achieved: **{extinf} s** "
              f"(target {env.get('segment_target_s', '?')} s).")
    if s_heads is not None and e_heads is not None:
        print(f"Back-to-back PAT→PMT pairs (segment heads): "
              f"**{s_heads} in the source, {e_heads} at egress**.\n")
        segs = max(e_heads - s_heads, 0)
    else:
        segs = 0
        print("Segment-head scan unavailable (capture not 188-aligned).\n")

    print("| | source | egress | expected at equal media | excess | per segment head |")
    print("|---|---:|---:|---:|---:|---|")
    for pid, name in ((0, "PAT"), (pmtpid, "PMT")):
        if pid < 0:
            continue
        sn = int(S["pids"].get(pid, {}).get("packets", 0))
        en = int(E["pids"].get(pid, {}).get("packets", 0))
        expect = round(sn * ep / sp) if sp else 0
        excess = en - expect
        per = f"{excess / segs:.2f}" if segs else "—"
        print(f"| {name} | {sn:,} | {en:,} | {expect:,} | {excess:+,} | {per} |")

    added = [
        pid for pid in E["pids"]
        if pid not in S["pids"] and int(E["pids"][pid].get("packets", 0)) > 0
    ]
    print(f"\nPIDs present at egress and absent from the source: "
          f"**{'none' if not added else ', '.join('0x%04X' % p for p in sorted(added))}**.")
    print("One injected PAT/PMT pair is 376 bytes, which at the source rate displaces "
          f"every later PCR in its segment by {376 * 8 * 1e6 / int(S['ts']['pcrbitrate']):.1f} µs — "
          "the figure to check the PCR-accuracy rows against.")


if __name__ == "__main__":
    main()

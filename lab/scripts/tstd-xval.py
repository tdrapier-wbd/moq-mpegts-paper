#!/usr/bin/env python3
"""Cross-validate ts-tstd.py against upstream's T-STD check on the same bytes.

    tstd-xval.py CAPTURE --upstream DIR [--skip S | --no-cut] [--json OUT] [--scratch DIR] [--label L]
    tstd-xval.py --table OUT.json [OUT.json ...]

Upstream moq-dev/moq's test/ts/compliance.py carries a full T-STD check
(check_tstd, PR #4643). It has no start-up skip, where ts-tstd.py simulates from
the first PCR and counts from --skip S. So the capture is cut at the first packet
carrying a PCR on the program's PCR PID at or after S seconds of that PCR, the
capture's first PAT and PMT packets are put in front of it (ts-tstd.py reads PCRs
only once it has a PMT), and both checks grade the cut file whole, at the stream's
own PCR. With S = 0 the cut is at the first PCR packet, so that neither check sees
packets ahead of the first PCR, which upstream times by extrapolation and ts-tstd.py
ignores. ts-tstd.py also grades the uncut file with --skip S, to show the cut does
not move its own verdict. --no-cut grades the file as it is, for a file whose only
SPS precedes its first PCR.

Neither check is modified. ts-tstd.py reports each buffer's first violation of each
condition itself; upstream's Grade.flag is wrapped to read the simulator's frame the
first time each violation is flagged. Times are seconds after the cut file's first
PCR, on its own clock.

Conditions compared per PID that both grade: TB overflow; TB not emptied within
1 s; video MB/EB overflow; audio B overflow; EB or B underflow; STD delay. A PID
only one check grades, or one either refuses, is a coverage difference.
"""

import argparse
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("tstd", os.path.join(HERE, "ts-tstd.py"))
T = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(T)

CONDITIONS = ("TB overflow", "TB not emptied within 1 s", "MB/EB overflow", "B overflow", "underflow",
              "STD delay")


def cut_point(path, skip_s):
    """(byte offset, first PCR s, PCR s at the cut, PAT + PMT packets) for the first PCR at or after skip_s.

    The PCR PID comes from the first PMT, but the first PCR is the first on that PID anywhere
    in the file, which upstream's scan sees whether or not a PMT has gone before it.
    """
    data, n = T.read_packets(path)
    pmts, pcr_pid, psi = {}, None, b""
    for i in range(n):
        p = data[i * T.PKT:(i + 1) * T.PKT]
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if p[0] != T.SYNC or not p[1] & 0x40:
            continue
        if pid == 0 and not pmts:
            sec = T.section_body(bytes(T.payload_of(p)))
            if sec and sec[0] == 0x00:
                pmts, psi = T.parse_pat(sec), bytes(p)
        elif pid in pmts:
            sec = T.section_body(bytes(T.payload_of(p)))
            if sec and sec[0] == 0x02:
                pcr_pid, _ = T.parse_pmt(sec)
                psi += bytes(p)
                break
    if pcr_pid is None:
        sys.exit(f"{path}: no PAT and PMT, each in one packet")
    first = prev = None
    off = 0
    for i in range(n):
        p = data[i * T.PKT:(i + 1) * T.PKT]
        if p[0] != T.SYNC or ((p[1] & 0x1F) << 8) | p[2] != pcr_pid:
            continue
        v = T.parse_pcr(p)
        if v is None:
            continue
        if prev is not None and v + off < prev - T.PCR_MODULUS // 2:
            off += T.PCR_MODULUS
        v += off
        prev = v
        if first is None:
            first = v
        if v - first >= skip_s * T.TICKS:
            return i * T.PKT, first / T.TICKS, v / T.TICKS, psi
    sys.exit(f"{path}: no PCR {skip_s} s after the first")


def run_upstream(path, updir):
    """Upstream check_tstd's metrics on `path`, with each stream's first flag of each violation."""
    sys.path.insert(0, updir)
    import compliance as C
    firsts = {}
    flag = C.Grade.flag

    def watched(self, name):
        mine = firsts.setdefault(self.pid, {})
        if name not in mine:
            f = sys._getframe(1).f_locals
            clock, unit = f.get("clock"), f.get("unit")
            rec = {}
            if "TB" in name:
                rec = {"t": f["start"], "packet": f["index"]}
                if "emptied" in name:
                    rec["busy_since"] = f["busy_since"]
            elif "advance" in name:
                rec = {"unit_first_packet": unit.first_packet, "stamp_s": f["stamped"]}
            elif unit is not None and f.get("kind") == 0:
                rec = {"unit_td": f["t"], "unit_first_packet": unit.first_packet,
                       "first_byte": clock.time_at(unit.first_packet)}
            else:
                rec = {"t": f.get("t")}
            mine[name] = rec
        flag(self, name)

    C.Grade.flag = watched
    try:
        check = C.check_tstd(path, 188, C.scan_packets(path, 188))
    finally:
        C.Grade.flag = flag
    return check, firsts


def upstream_condition(name, video):
    if name == "TB overflow":
        return "TB overflow"
    if name.startswith("TB not emptied"):
        return "TB not emptied within 1 s"
    if name in ("MB overflow", "EB overflow"):
        return "MB/EB overflow"
    if name == "B overflow":
        return "B overflow"
    if name.endswith("underflow"):
        return "underflow"
    if name.startswith("held over"):
        return "STD delay"
    return name


TIMES = ("t", "busy_since", "unit_td", "complete", "first_byte", "stamp_s")


def rel(rec, t0):
    out = {}
    for k, v in (rec or {}).items():
        out[k] = round(v - t0, 4) if k in TIMES and isinstance(v, float) else (
            round(v, 3) if isinstance(v, float) else v)
    return out


def tstd_firsts(b, d, video):
    """ts-tstd.py's first violation of each condition, from its own report."""
    out = {}
    if "overflow" in b["first"]:
        out["TB overflow"] = b["first"]["overflow"]
    if "not_emptied_within_1s" in b["first"]:
        out["TB not emptied within 1 s"] = b["first"]["not_emptied_within_1s"]
    if d:
        names = {"overflow": "MB/EB overflow" if video else "B overflow", "underflow": "underflow",
                 "residence": "STD delay"}
        out.update({names[k]: v for k, v in d["first"].items() if k in names})
    return out


def compare(r, check, ufirst, t0):
    tb = {}
    for b in r["transport_buffers"]:
        for pid in b["pids"]:
            tb[pid] = b
    streams = check.metrics.get("streams", {})
    rows = []
    both = []
    for pid_s, s in streams.items():
        pid = int(pid_s)
        if pid not in tb or pid in r["refused"]:
            continue
        both.append(pid)
        video = s["type"].startswith(("AVC", "HEVC"))
        ts_dec = next((x for x in r["decoder_buffers"] if int(x["buffer"].split()[1]) == pid), None)
        up = {}
        for name, count in s["violations"].items():
            c = upstream_condition(name, video)
            up[c] = up.get(c, 0) + count
        upf = {}
        for name, rec in ufirst.get(pid, {}).items():
            upf.setdefault(upstream_condition(name, video), rel(rec, t0))
        b = tb[pid]
        ts = {"TB overflow": b["overflow_packets"], "TB not emptied within 1 s": b["not_emptied_within_1s"]}
        if ts_dec:
            ts["MB/EB overflow" if video else "B overflow"] = (ts_dec["overflow_arrivals"]
                                                              + ts_dec["overflow_before_removal"])
            ts["underflow"] = ts_dec["underflows"]
            ts["STD delay"] = ts_dec["residence_over_limit"]
        tsf = {k: rel(v, t0) for k, v in tstd_firsts(b, ts_dec, video).items()}
        for cond in CONDITIONS:
            if cond == ("B overflow" if video else "MB/EB overflow"):
                continue
            tv, uv = ts.get(cond), up.get(cond, 0)
            if tv is None:
                continue
            rows.append({"pid": pid, "type": s["type"], "condition": cond, "tstd": tv, "upstream": uv,
                         "agree": bool(tv) == bool(uv), "tstd_first": tsf.get(cond),
                         "upstream_first": upf.get(cond),
                         "tstd_evidence": ({"longest_nonempty_s": b["longest_nonempty_s"]}
                                           if cond == "TB not emptied within 1 s" else None)})
        for name, count in up.items():
            if name not in CONDITIONS:
                rows.append({"pid": pid, "type": s["type"], "condition": name, "tstd": None, "upstream": count,
                             "agree": None, "tstd_first": None, "upstream_first": upf.get(name)})
    only = [b for b in r["transport_buffers"] if b["packets"] and not set(b["pids"]) & set(both)]
    coverage = {
        "tstd_only": [{"pid": b["pids"][0] if len(b["pids"]) == 1 else b["pids"], "buffer": b["buffer"],
                       "normative": b["normative"], "overflow_packets": b["overflow_packets"],
                       "longest_nonempty_s": b["longest_nonempty_s"]} for b in only],
        "tstd_refused": {str(k): v for k, v in r["refused"].items()},
        "upstream_refused": check.metrics.get("refused", {}),
        "upstream_not_elementary": check.metrics.get("not_elementary", []),
    }
    return rows, coverage


def grade_both(path, updir, skip_s, scratch, label, cut=True):
    """Both checks on the capture from its cut point, or on the file as it is.

    The cut file is the stream's first PAT and PMT packets followed by the capture from
    the cut PCR on. ts-tstd.py reads PCRs only once it has a PMT, so without the two
    tables ahead of the cut it would start at the first PCR after the next PMT, and
    upstream at the cut. Upstream times the two table packets by extrapolation and
    models no systems buffer, so neither check grades an elementary-stream byte the
    other does not.
    """
    off, first_s, cut_s, psi = cut_point(path, skip_s)
    target = path
    if cut:
        os.makedirs(scratch, exist_ok=True)
        target = os.path.join(scratch, f"{label}.cut.ts")
        with open(path, "rb") as src, open(target, "wb") as dst:
            dst.write(psi)
            src.seek(off)
            while True:
                chunk = src.read(1 << 24)
                if not chunk:
                    break
                dst.write(chunk)
    else:
        off, cut_s = None, first_s
    try:
        r = T.grade(target, {}, skip_s=0.0)
        check, ufirst = run_upstream(target, updir)
    finally:
        if target != path:
            os.remove(target)
    return off, first_s, cut_s, r, check, ufirst


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", nargs="?")
    ap.add_argument("--upstream", help="directory holding upstream's compliance.py")
    ap.add_argument("--skip", type=float, default=0.0, metavar="S")
    ap.add_argument("--json", metavar="OUT")
    ap.add_argument("--scratch", default="/tmp/tstd-xval")
    ap.add_argument("--label", default="capture")
    ap.add_argument("--no-cut", action="store_true",
                    help="grade the file as it is (a stream whose only SPS precedes its first PCR)")
    ap.add_argument("--table", nargs="+", metavar="OUT.json")
    a = ap.parse_args()
    if a.table:
        return table(a.table)
    if not a.capture or not a.upstream:
        ap.error("a capture and --upstream are required")
    off, first_s, cut_s, r, check, ufirst = grade_both(a.capture, a.upstream, a.skip, a.scratch, a.label,
                                                       cut=not a.no_cut)
    t0 = cut_s
    rows, coverage = compare(r, check, ufirst, t0)
    uncut = T.grade(a.capture, {}, skip_s=a.skip)
    out = {
        "label": a.label,
        "capture": os.path.basename(a.capture),
        "skip_s": a.skip,
        "cut_byte": off,
        "cut_after_first_pcr_s": round(cut_s - first_s, 4) if off is not None else None,
        "tstd": {"verdict": T.verdict(r), "pcr_span_s": r["pcr_span_s"],
                 "pcr_discontinuities": r["pcr_discontinuities"],
                 "transport_buffers": r["transport_buffers"], "decoder_buffers": r["decoder_buffers"],
                 "calibration": r["calibration"], "refused": r["refused"], "duplicates": r["duplicates"]},
        "tstd_uncut_skip": {"verdict": T.verdict(uncut), "transport_buffers": uncut["transport_buffers"],
                            "decoder_buffers": uncut["decoder_buffers"]},
        "upstream": {"status": check.status.value, "detail": check.detail, "metrics": check.metrics},
        "compare": rows,
        "coverage": coverage,
        "agree": all(x["agree"] for x in rows if x["agree"] is not None),
    }
    summary(out)
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(out, fh, indent=1)
    return 0


VERDICT = {0: "passes", 1: "fails", 2: "refuses a stream"}


def summary(o):
    bad = [x for x in o["compare"] if x["agree"] is False]
    print(f"== {o['label']}: cut at {o['cut_after_first_pcr_s']} s, ts-tstd.py "
          f"{VERDICT[o['tstd']['verdict']]} (uncut --skip {o['skip_s']:g}: "
          f"{VERDICT[o['tstd_uncut_skip']['verdict']]}), upstream {o['upstream']['status']}; "
          f"{'AGREE' if o['agree'] else 'DISAGREE'} on {len(o['compare']) - len(bad)} of "
          f"{len(o['compare'])} conditions")
    for x in o["compare"]:
        mark = "  " if x["agree"] else ("!!" if x["agree"] is False else "??")
        print(f"  {mark} PID {x['pid']:>5} {x['condition']:<26} ts-tstd.py {str(x['tstd']):>9}  upstream "
              f"{x['upstream']:>9}")
        if x["agree"] is False:
            print(f"       first: ts-tstd.py {x['tstd_first']}  upstream {x['upstream_first']}"
                  + (f"  evidence {x['tstd_evidence']}" if x.get("tstd_evidence") else ""))
    for c in o["coverage"]["tstd_only"]:
        print(f"     graded by ts-tstd.py only: {c['buffer']}, overflow packets "
              f"{c['overflow_packets']}{'' if c['normative'] else ' [assumed]'}")
    for pid, why in o["coverage"]["upstream_refused"].items():
        print(f"     PID {pid:>5} refused by upstream: {why}")
    for pid, why in o["coverage"].get("tstd_refused", {}).items():
        print(f"     PID {pid:>5} refused by ts-tstd.py: {why}")


def upstream_verdict(u):
    """Upstream reports violations and refusals alike as WARN; tell them apart."""
    if u["status"] == "PASS":
        return "pass"
    m = u.get("metrics", {})
    if any(s.get("violations") for s in m.get("streams", {}).values()) or not m.get("refused"):
        return "fail"
    return "refused"


def table(paths):
    rows = [json.load(open(p)) for p in paths]
    print("| Capture | Cut at | ts-tstd.py | upstream | Conditions agreeing | Disagreements |")
    print("|---|---|---|---|---|---|")
    for o in rows:
        bad = [x for x in o["compare"] if x["agree"] is False]
        dis = "; ".join(f"PID {x['pid']} {x['condition']} ({x['tstd']} vs {x['upstream']})" for x in bad) or "none"
        at = "uncut" if o["cut_after_first_pcr_s"] is None else f"{o['cut_after_first_pcr_s']:g} s"
        print(f"| {o['label']} | {at} | {['pass', 'fail', 'refused'][o['tstd']['verdict']]} | "
              f"{upstream_verdict(o['upstream'])} | {len(o['compare']) - len(bad)} of "
              f"{len(o['compare'])} | {dis} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())

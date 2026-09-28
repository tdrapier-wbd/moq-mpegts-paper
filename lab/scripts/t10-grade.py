#!/usr/bin/env python3
"""T10 per-programme grade: score an egress capture against a multi-programme source.

    t10-grade.py <source.ts> <egress.ts> [--label NAME] [--json FILE]

Every programme in the source's PAT is graded on its own, at P1 (file domain):

* PAT     - does the egress PAT list the same program_number against the same PMT PID?
* PMT     - are the sections on that PMT PID bit-identical to the source's? If not, the parsed
            structure is compared (program_number, PCR PID, every ES with stream_type and
            descriptors), and each source ES is traced to the egress programme that now lists it.
* SDT     - is the service's entry in SDT actual byte-identical (flags and descriptors)?
* EIT p/f - is the set of distinct present/following sections for the service identical?
* CC      - continuity events on the programme's PIDs, from `tsp -P continuity`, matched on
            the plugin's data (`PID: 0x...`), never on a word from its prose.
* PCR     - on the source's PCR PID: PCR count, max interval, share above 40 ms, and
            `pcrverify --pid <p> --absolute --jitter-max 13` (13 ticks of 27 MHz = 481 ns).
* ES      - packets on every source ES PID at egress, and its stream_type in the egress PMT.

Verdict per programme: CARRIED (own PAT entry, own PMT with every ES, own PCR), FLATTENED
(its ES arrive, but listed under another programme's PMT or without its own PCR), PARTIAL (some
ES missing), ABSENT (nothing of it arrives).

Sections are reassembled here rather than parsed from `tstables` text, because the question is
byte identity and the text form normalises exactly the fields that differ.
"""

import argparse
import collections
import json
import re
import subprocess
import sys

PCR_CLOCK_HZ = 27_000_000
PCR_LIMIT_MS = 40.0
SI_PIDS = {0x0000, 0x0010, 0x0011, 0x0012, 0x0014}


class Mux:
    """One pass over a TS file: sections on PSI/SI PIDs, packet counts, PCRs."""

    def __init__(self, path):
        self.path = path
        self.packets = 0
        self.per_pid = collections.Counter()
        self.pcr = collections.defaultdict(list)  # pid -> [(index, pcr_27mhz)]
        self.sections = collections.defaultdict(collections.Counter)  # pid -> {bytes: n}
        self._buf = {}
        self.pmt_pids = set()
        self._scan()
        self.pat = self._pat()
        self.pmts = {pid: self._pmt(pid) for pid in sorted(self.pmt_pids)}
        self.sdt = self._sdt()
        self.eit_pf = self._eit_pf()

    def _scan(self):
        with open(self.path, "rb") as f:
            data = f.read()
        n = len(data) // 188
        for i in range(n):
            p = data[i * 188:(i + 1) * 188]
            if p[0] != 0x47:
                continue
            self.packets += 1
            pid = ((p[1] & 0x1F) << 8) | p[2]
            self.per_pid[pid] += 1
            afc = (p[3] >> 4) & 3
            off = 4
            if afc & 2:
                alen = p[4]
                if alen >= 7 and (p[5] & 0x10):
                    b = p[6:12]
                    base = (b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)
                    ext = ((b[4] & 1) << 8) | b[5]
                    self.pcr[pid].append((i, base * 300 + ext))
                off = 5 + alen
            if not (afc & 1) or off >= 188:
                continue
            if pid in SI_PIDS or pid in self.pmt_pids:
                self._section_bytes(pid, p[off:], bool(p[1] & 0x40))
            if pid == 0 and self.sections[0]:
                for sec in self.sections[0]:
                    for prog, pmt in _pat_entries(sec):
                        if prog != 0:
                            self.pmt_pids.add(pmt)

    def _section_bytes(self, pid, payload, pusi):
        if pusi:
            ptr = payload[0]
            if pid in self._buf and self._buf[pid] is not None:
                self._buf[pid] += payload[1:1 + ptr]
                self._drain(pid, final=True)
            self._buf[pid] = bytearray(payload[1 + ptr:])
            self._drain(pid)
        elif self._buf.get(pid) is not None:
            self._buf[pid] += payload
            self._drain(pid)

    def _drain(self, pid, final=False):
        buf = self._buf[pid]
        while len(buf) >= 3:
            if buf[0] == 0xFF:
                self._buf[pid] = None
                return
            slen = ((buf[1] & 0x0F) << 8) | buf[2]
            if len(buf) < 3 + slen:
                if final:
                    self._buf[pid] = None
                return
            self.sections[pid][bytes(buf[:3 + slen])] += 1
            del buf[:3 + slen]
        if final:
            self._buf[pid] = None

    def _pat(self):
        out = {"versions": set(), "programs": {}, "tsid": None}
        for sec in self.sections[0]:
            if sec[0] != 0x00:
                continue
            out["tsid"] = (sec[3] << 8) | sec[4]
            out["versions"].add((sec[5] >> 1) & 0x1F)
            for prog, pmt in _pat_entries(sec):
                if prog:
                    out["programs"].setdefault(prog, set()).add(pmt)
        return out

    def _pmt(self, pid):
        tables = []
        for sec in self.sections[pid]:
            if sec[0] != 0x02:
                continue
            prog = (sec[3] << 8) | sec[4]
            pcr_pid = ((sec[8] & 0x1F) << 8) | sec[9]
            pil = ((sec[10] & 0x0F) << 8) | sec[11]
            pinfo = sec[12:12 + pil]
            es, j, end = [], 12 + pil, len(sec) - 4
            while j + 5 <= end:
                st = sec[j]
                epid = ((sec[j + 1] & 0x1F) << 8) | sec[j + 2]
                eil = ((sec[j + 3] & 0x0F) << 8) | sec[j + 4]
                es.append((epid, st, sec[j + 5:j + 5 + eil].hex()))
                j += 5 + eil
            tables.append({"program": prog, "pcr_pid": pcr_pid, "program_info": pinfo.hex(),
                           "es": sorted(es), "version": (sec[5] >> 1) & 0x1F})
        return tables

    def _sdt(self):
        out = {"services": collections.defaultdict(set), "ids": set(), "sections": set()}
        for sec in self.sections[0x11]:
            if sec[0] != 0x42:
                continue
            out["sections"].add(sec)
            out["ids"].add(((sec[3] << 8) | sec[4], (sec[8] << 8) | sec[9]))
            j, end = 11, len(sec) - 4
            while j + 5 <= end:
                sid = (sec[j] << 8) | sec[j + 1]
                dl = ((sec[j + 3] & 0x0F) << 8) | sec[j + 4]
                out["services"][sid].add(sec[j:j + 5 + dl].hex())
                j += 5 + dl
        return out

    def _eit_pf(self):
        out = collections.defaultdict(set)
        for sec in self.sections[0x12]:
            if sec[0] == 0x4E:
                out[(sec[3] << 8) | sec[4]].add(sec)
        return out

    def span_s(self):
        spans = [(v[-1][1] - v[0][1]) / PCR_CLOCK_HZ for v in self.pcr.values() if len(v) > 1]
        return max(spans) if spans else 0.0


def _pat_entries(sec):
    if sec[0] != 0x00:
        return []
    end = len(sec) - 4
    return [((sec[j] << 8) | sec[j + 1], ((sec[j + 2] & 0x1F) << 8) | sec[j + 3])
            for j in range(8, end, 4)]


def continuity(path):
    """Continuity events per PID from `tsp -P continuity`, keyed on the PID it prints."""
    r = subprocess.run(["tsp", "-I", "file", path, "-P", "continuity", "-O", "drop"],
                       capture_output=True, text=True)
    per = collections.Counter()
    for line in (r.stdout + r.stderr).splitlines():
        m = re.search(r"PID: 0x([0-9A-Fa-f]+) \(\d+\)", line)
        if m and "continuity" in line:
            per[int(m.group(1), 16)] += 1
    return per


def pcrverify(path, pid):
    r = subprocess.run(["tsp", "-I", "file", path, "-P", "pcrverify", "--pid", str(pid),
                        "--absolute", "--jitter-max", "13", "-O", "drop"],
                       capture_output=True, text=True)
    m = re.search(r"([\d,]+) PCR OK, ([\d,]+) with jitter", r.stdout + r.stderr)
    if not m:
        return None
    return int(m.group(1).replace(",", "")), int(m.group(2).replace(",", ""))


def pcr_intervals(points):
    if len(points) < 2:
        return {"count": len(points), "max_ms": None, "over40_pct": None}
    iv = [(b[1] - a[1]) / PCR_CLOCK_HZ * 1000 for a, b in zip(points, points[1:])]
    iv = [x for x in iv if x >= 0]
    over = sum(x > PCR_LIMIT_MS for x in iv)
    return {"count": len(points), "max_ms": round(max(iv), 2),
            "over40_pct": round(100.0 * over / len(iv), 3)}


def grade(src, egr):
    s, e = Mux(src), Mux(egr)
    cc_s, cc_e = continuity(src), continuity(egr)
    s_span, e_span = s.span_s(), e.span_s()

    # Where each ES PID lives in the egress: pid -> [(program, stream_type)]
    egress_home = collections.defaultdict(list)
    for tables in e.pmts.values():
        for t in tables:
            for epid, st, _ in t["es"]:
                egress_home[epid].append((t["program"], st))
    egress_home = {k: sorted(set(v)) for k, v in egress_home.items()}
    egress_pcr_pids = {t["pcr_pid"] for tables in e.pmts.values() for t in tables}

    progs = []
    for prog, pmt_set in sorted(s.pat["programs"].items()):
        pmt_pid = sorted(pmt_set)[0]
        spmt = s.pmts.get(pmt_pid, [])
        sp = spmt[-1] if spmt else None
        epmt = [t for t in e.pmts.get(pmt_pid, []) if t["program"] == prog]
        ep = epmt[-1] if epmt else None
        src_secs = {x for x in s.sections[pmt_pid] if x[0] == 0x02}
        egr_secs = {x for x in e.sections.get(pmt_pid, {}) if x[0] == 0x02}
        es_rows = []
        for epid, st, desc in (sp["es"] if sp else []):
            home = egress_home.get(epid, [])
            egr_st = [h[1] for h in home]
            egr_descs = [d for tables in e.pmts.values() for t in tables
                         for p_, _t, d in t["es"] if p_ == epid]
            es_rows.append({"pid": epid, "stream_type": st, "packets_src": s.per_pid[epid],
                            "packets_egr": e.per_pid.get(epid, 0),
                            "egress_programs": [h[0] for h in home],
                            "stream_type_ok": st in egr_st,
                            "descriptors_ok": bool(egr_descs) and all(d == desc for d in egr_descs)})
        pcr_pid = sp["pcr_pid"] if sp else None
        pcr_e = pcr_intervals(e.pcr.get(pcr_pid, [])) if pcr_pid is not None else None
        pcr_s = pcr_intervals(s.pcr.get(pcr_pid, [])) if pcr_pid is not None else None
        pv_e = pcrverify(egr, pcr_pid) if pcr_pid is not None and e.pcr.get(pcr_pid) else None
        pv_s = pcrverify(src, pcr_pid) if pcr_pid is not None else None
        pids = {pmt_pid} | {r["pid"] for r in es_rows}
        eit_s, eit_e = s.eit_pf.get(prog, set()), e.eit_pf.get(prog, set())

        present = [r for r in es_rows if r["packets_egr"] > 0]
        own_pat = pmt_pid in e.pat["programs"].get(prog, set())
        own_pcr = bool(ep) and ep["pcr_pid"] == pcr_pid and bool(e.pcr.get(pcr_pid))
        if not present:
            verdict = "ABSENT"
        elif len(present) < len(es_rows):
            verdict = "PARTIAL"
        elif own_pat and ep is not None and all(prog in r["egress_programs"] for r in es_rows) and own_pcr:
            verdict = "CARRIED"
        else:
            verdict = "FLATTENED"

        progs.append({
            "program": prog, "pmt_pid": pmt_pid, "verdict": verdict,
            "pat_entry": sorted(e.pat["programs"].get(prog, [])),
            "pmt_bit_identical": bool(src_secs) and src_secs == egr_secs,
            "pmt_egress": ep, "pmt_source": sp,
            "sdt_entry_identical": bool(s.sdt["services"].get(prog)) and
            s.sdt["services"].get(prog) == e.sdt["services"].get(prog),
            "sdt_entry_present": prog in e.sdt["services"],
            "eit_pf_sections_src": len(eit_s), "eit_pf_sections_egr": len(eit_e),
            "eit_pf_identical": bool(eit_s) and eit_s == eit_e,
            "eit_pf_missing": len(eit_s - eit_e), "eit_pf_added": len(eit_e - eit_s),
            "cc_events_src": sum(cc_s[p] for p in pids), "cc_events_egr": sum(cc_e[p] for p in pids),
            "pcr_pid": pcr_pid, "pcr_src": pcr_s, "pcr_egr": pcr_e,
            "pcrverify_src": pv_s, "pcrverify_egr": pv_e,
            "es": es_rows,
        })

    def rate(m, pid, span):
        return m.per_pid.get(pid, 0) / span if span else None

    eit_rs, eit_re = rate(s, 0x12, s_span), rate(e, 0x12, e_span)
    return {
        "source": src, "egress": egr,
        "packets": {"source": s.packets, "egress": e.packets},
        "pcr_span_s": {"source": round(s_span, 3), "egress": round(e_span, 3)},
        "pat": {"source_programs": {k: sorted(v) for k, v in s.pat["programs"].items()},
                "egress_programs": {k: sorted(v) for k, v in e.pat["programs"].items()},
                "tsid": [s.pat["tsid"], e.pat["tsid"]],
                "bit_identical": {x for x in s.sections[0] if x[0] == 0} ==
                {x for x in e.sections.get(0, {}) if x[0] == 0}},
        "egress_pmt_pids": sorted(e.pmt_pids),
        "egress_pcr_pids": sorted(egress_pcr_pids),
        "egress_pcr_bearing_pids": sorted(p for p, v in e.pcr.items() if v),
        "sdt": {"ids": [sorted(s.sdt["ids"]), sorted(e.sdt["ids"])],
                "services": [sorted(s.sdt["services"]), sorted(e.sdt["services"])],
                "sections_identical": s.sdt["sections"] == e.sdt["sections"] and bool(s.sdt["sections"])},
        "nit_identical": {x for x in s.sections[0x10]} == {x for x in e.sections.get(0x10, {})},
        "nit_present": [bool(s.sections[0x10]), bool(e.sections.get(0x10))],
        "tdt_packets": [s.per_pid.get(0x14, 0), e.per_pid.get(0x14, 0)],
        "eit_pid_rate_pkt_s": [round(eit_rs, 3) if eit_rs else None, round(eit_re, 3) if eit_re else None],
        "cc_events_total": [sum(cc_s.values()), sum(cc_e.values())],
        "egress_pids": sorted(e.per_pid),
        "programs": progs,
    }


def fmt_pcr(p):
    if not p:
        return "none"
    return f"{p['count']} PCR, max {p['max_ms']} ms, >40 ms {p['over40_pct']} %"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("egress")
    ap.add_argument("--label", default="")
    ap.add_argument("--json")
    a = ap.parse_args()
    g = grade(a.source, a.egress)

    print(f"== T10 grade {a.label}")
    print(f"packets src/egr {g['packets']['source']}/{g['packets']['egress']}; "
          f"PCR span {g['pcr_span_s']['source']}/{g['pcr_span_s']['egress']} s")
    print(f"PAT src {g['pat']['source_programs']} egr {g['pat']['egress_programs']} "
          f"tsid {g['pat']['tsid']} bit-identical={g['pat']['bit_identical']}")
    print(f"egress PMT PIDs {g['egress_pmt_pids']}, PMT PCR PIDs {g['egress_pcr_pids']}, "
          f"PCR-bearing PIDs {g['egress_pcr_bearing_pids']}")
    print(f"SDT ids {g['sdt']['ids']} services {g['sdt']['services']} "
          f"sections-identical={g['sdt']['sections_identical']}")
    print(f"NIT present {g['nit_present']} identical={g['nit_identical']}; TDT packets {g['tdt_packets']}; "
          f"EIT PID pkt/s {g['eit_pid_rate_pkt_s']}; CC events {g['cc_events_total']}")
    print(f"egress PIDs {g['egress_pids']}")
    for p in g["programs"]:
        print(f"-- programme {p['program']} (PMT {p['pmt_pid']}): {p['verdict']}")
        print(f"   PAT entry {p['pat_entry']}; PMT bit-identical={p['pmt_bit_identical']}; "
              f"SDT entry present={p['sdt_entry_present']} identical={p['sdt_entry_identical']}")
        ep = p["pmt_egress"]
        if ep:
            print(f"   egress PMT: program {ep['program']} PCR PID {ep['pcr_pid']} "
                  f"ES {[(x[0], hex(x[1])) for x in ep['es']]}")
        print(f"   EIT p/f sections src/egr {p['eit_pf_sections_src']}/{p['eit_pf_sections_egr']} "
              f"identical={p['eit_pf_identical']} missing={p['eit_pf_missing']} added={p['eit_pf_added']}")
        print(f"   CC events src/egr {p['cc_events_src']}/{p['cc_events_egr']}")
        print(f"   PCR PID {p['pcr_pid']}: src {fmt_pcr(p['pcr_src'])}; egr {fmt_pcr(p['pcr_egr'])}; "
              f"pcrverify(ok,fail) src {p['pcrverify_src']} egr {p['pcrverify_egr']}")
        for r in p["es"]:
            print(f"   ES {r['pid']} type {hex(r['stream_type'])}: pkts {r['packets_src']}->{r['packets_egr']} "
                  f"in egress programme(s) {r['egress_programs']} type_ok={r['stream_type_ok']} "
                  f"desc_ok={r['descriptors_ok']}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(g, f, indent=1, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())

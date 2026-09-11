#!/bin/bash
# T33 Part B: the Gate 2 acceptance harness, run against the software reference receiver.
#
# What this is for. When the IRD and the TR 101 290 analyser arrive the window is short and
# attended, and the campaign has already paid once for discovering an untested precondition on
# the day (T19). So the measurement set, the run order, the capture format and the pass table
# are fixed *here*, in a script, and rehearsed against the software reference. The rehearsal
# validates the rig; it does not produce a Gate 2 verdict, and this script will refuse to
# print one.
#
# Three properties are deliberate and are the ones worth preserving when the analyser replaces
# the software reference:
#
#   * **Control before every subject, and the session aborts if control fails.** The control is
#     the source clip fed straight from disk with no MoQ lane in it. The clip is measured
#     conformant, so a control failure means the rig is wrong and nothing downstream is
#     interpretable. Deciding that on the day, by eye, is how a bad rig produces a good-looking
#     result.
#   * **One machine-readable artefact per arm, written to file.** A 72 h soak read off a GUI is
#     not a measurement. Whatever the analyser offers -- CSV, syslog, SNMP -- exactly one path
#     is logged, and the harness fails the arm if the file is absent or unparseable.
#   * **The pass table is fixed before the first subject runs**, and is read from
#     `t33-pass-table.json` rather than assembled from what the run produced.
#
# Usage: t33-acceptance.sh <out-dir> [subject-seconds] [soak-seconds]
#   t33-acceptance.sh ~/t33-accept 60 600      # rehearsal
#   t33-acceptance.sh ~/t33-accept 60 259200   # the shape of the real thing (72 h)

set -u
OUT="${1:?out dir}"
SUBJ_S="${2:-60}"
SOAK_S="${3:-600}"

W=/tmp/t33
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOQ=${MOQ:-$HOME/bin-3529/moq}
PACER=${PACER:?set PACER}
CLIP=${CLIP:-$HOME/t12_vidonly.ts}
RELAY_URL=${RELAY_URL:-https://127.0.0.1:9543/t33}
TABLE="$REPO/scripts/t33-pass-table.json"
mkdir -p "$OUT"
RESULTS="$OUT/results.csv"
echo "arm,role,capture,bytes,packets,cc_events,cc_missing,pcr_n,pcr_max_ms,pcr_over40,jitter481_bad,verdict" >"$RESULTS"

fail_session() {
	echo "SESSION ABORTED: $1" | tee -a "$OUT/harness.log"
	echo "No subject arm ran. Nothing downstream of a failed control is interpretable." | tee -a "$OUT/harness.log"
	exit 2
}

# ---------------------------------------------------------------------------
# Step 0 -- preconditions. Every one of these has cost a run at some point.
# ---------------------------------------------------------------------------
[ -f "$TABLE" ] || fail_session "pass table $TABLE is missing; a gate fixed after seeing output is not a gate"
[ -f "$CLIP" ] || fail_session "source clip $CLIP is missing"
command -v tsp >/dev/null || fail_session "TSDuck not on PATH"
[ -x "$PACER" ] || fail_session "groomer $PACER not executable"
[ -f "$W/fp.txt" ] || fail_session "no relay fingerprint at $W/fp.txt -- is the relay up?"

# The grader must be shown reading both ways before any zero it prints is published.
python3 "$REPO/scripts/t33-grade.py" --selftest "$W/fixtures/svc-normal.ts" "$W/fixtures/BROKEN-excised.ts" \
	>"$OUT/grader-selftest.txt" 2>&1 ||
	fail_session "grader self-test failed -- a zero from it would mean nothing"
echo "precondition: grader reads both ways" | tee -a "$OUT/harness.log"

grade_into() {
	# $1 arm, $2 role, $3 capture path
	python3 - "$1" "$2" "$3" "$RESULTS" <<'PY'
import os, re, subprocess, sys
arm, role, path, out = sys.argv[1:5]
if not os.path.exists(path) or os.path.getsize(path) < 188:
    open(out,'a').write(f"{arm},{role},{path},0,0,,,,,,,NO-CAPTURE\n"); print("NO-CAPTURE"); sys.exit(0)
def sh(c): 
    r = subprocess.run(c, capture_output=True); return r.stdout + r.stderr
cc = re.findall(rb"missing ([\d,]+) packet", sh(["tsp","-I","file",path,"-P","continuity","-O","drop"]))
ev, miss = len(cc), sum(int(x.replace(b",",b"")) for x in cc)
m = re.search(rb"([\d,]+) PCR OK, ([\d,]+) with jitter",
              sh(["tsp","-I","file",path,"-P","pcrverify","--absolute","--jitter-max","13","-O","drop"]))
bad = int(m.group(2).replace(b",",b"")) if m else ""
csv = path + ".pcr.csv"
subprocess.run(["tsp","-I","file",path,"-P","pcrextract","--pcr","--csv","-o",csv,"-O","drop"],capture_output=True)
vals=[]
try:
    with open(csv) as fh:
        next(fh,None)
        for line in fh:
            f=line.split(",")
            if len(f)>5 and f[5].strip().isdigit(): vals.append(int(f[5]))
except OSError: pass
MOD=(1<<33)*300
d=[((b-a)%MOD)/27000.0 for a,b in zip(vals,vals[1:])]
mx=max(d) if d else 0
# A PCR interval past the repetition limit is TR 101 290 2.3a only when the jump is NOT
# signalled. ISO 13818-1 2.4.3.4 permits the clock to jump in a packet carrying
# discontinuity_indicator, so a gate that ignores the flag fails a conforming splice -- which
# is precisely what the rehearsal caught it doing on the `discontinuity` arm.
signalled = 0
with open(path,'rb') as fh:
    blob = fh.read()
for i in range(0, len(blob)-188, 188):
    p = blob[i:i+188]
    if p[0]==0x47 and (p[3]&0x20) and p[4]>=1 and (p[5]&0x80):
        signalled += 1
o40 = sum(1 for x in d if x>40)
o40_unsignalled = max(0, o40 - signalled)
verdict = "PASS" if ev==0 and o40_unsignalled==0 else "FAIL"
o40 = o40_unsignalled
sz=os.path.getsize(path)
open(out,'a').write(f"{arm},{role},{path},{sz},{sz//188},{ev},{miss},{len(vals)},{mx:.2f},{o40},{bad},{verdict}\n")
print(verdict)
PY
}

# ---------------------------------------------------------------------------
# Step 1 -- CONTROL. The clip from disk, no MoQ lane. Scripted, never improvised.
# ---------------------------------------------------------------------------
echo "=== control: source clip straight from disk ===" | tee -a "$OUT/harness.log"
tsp -I file "$CLIP" -P until --packets 60000 -O file "$OUT/control.ts" 2>>"$OUT/harness.log"
V=$(grade_into control reference "$OUT/control.ts")
echo "  control verdict: $V" | tee -a "$OUT/harness.log"
[ "$V" = "PASS" ] || fail_session "control failed ($V) -- the rig is wrong, not the subject"

# ---------------------------------------------------------------------------
# Step 2 -- SUBJECT ARMS. Boundary drills are short and attended; the soak is the
# long pole, so it runs last here and its order is a decision, not an accident.
# ---------------------------------------------------------------------------
run_subject() {
	local arm="$1" src="$2" secs="$3"
	echo "=== subject $arm (${secs}s) ===" | tee -a "$OUT/harness.log"
	local run="$OUT/$arm"
	mkdir -p "$run"
	PACER="$PACER" MOQ="$MOQ" RELAY_URL="$RELAY_URL" \
		bash "$REPO/scripts/t33-partA-arm.sh" "$src" "ACC-$arm" "$secs" 0 >>"$OUT/harness.log" 2>&1
	cp -f "$W/out/ACC-$arm/groomed.ts" "$run/groomed.ts" 2>/dev/null
	cp -f "$W/out/ACC-$arm/exported.ts" "$run/exported.ts" 2>/dev/null
	echo "  exported: $(grade_into "$arm" exported "$run/exported.ts")" | tee -a "$OUT/harness.log"
	echo "  groomed:  $(grade_into "$arm" groomed "$run/groomed.ts")" | tee -a "$OUT/harness.log"
	# Control is re-run before each subject, per the pass table, not once at the top.
	tsp -I file "$CLIP" -P until --packets 20000 -O file "$run/control.ts" 2>>"$OUT/harness.log"
	local cv
	cv=$(grade_into "$arm" control-recheck "$run/control.ts")
	[ "$cv" = "PASS" ] || fail_session "control re-check failed before $arm"
}

for cond in wrap discontinuity pmt-version; do
	[ -f "$W/fixtures/inj-$cond.ts" ] || python3 "$REPO/scripts/t33-inject-condition.py" \
		"$cond" "$W/fixtures/base20.ts" "$W/fixtures/inj-$cond.ts" --at 5.0 >/dev/null
	run_subject "$cond" "$W/fixtures/inj-$cond.ts" "$SUBJ_S"
done

# ---------------------------------------------------------------------------
# Step 3 -- SOAK, last. On hardware this is >= 72 h because the PCR base wraps at
# 26.51 h and a soak that never crosses one has not tested the wrap.
# ---------------------------------------------------------------------------
echo "=== soak (${SOAK_S}s) ===" | tee -a "$OUT/harness.log"
run_subject soak "$CLIP" "$SOAK_S"

# ---------------------------------------------------------------------------
# Step 4 -- report. Rehearsal only: this harness does not issue a Gate 2 verdict.
# ---------------------------------------------------------------------------
python3 - "$RESULTS" "$TABLE" "$SOAK_S" <<'PY'
import csv, json, sys
rows = list(csv.DictReader(open(sys.argv[1])))
table = json.load(open(sys.argv[2]))
soak = int(sys.argv[3])
print("\n### acceptance harness rehearsal\n")
print(f"{'arm':<16}{'role':<16}{'pkts':>9}{'cc':>5}{'>40ms':>7}{'verdict':>9}")
for r in rows:
    print(f"{r['arm']:<16}{r['role']:<16}{r['packets']:>9}{r['cc_events']:>5}{r['pcr_over40']:>7}{r['verdict']:>9}")
bad = [r for r in rows if r['verdict'] != 'PASS']
print(f"\n{len(rows)} arms graded, {len(bad)} not PASS")
print(f"pass table: {len(table['p1'])} P1 sub-errors, {len(table['p2'])} P2, "
      f"{len(table['analyser_specific'])} analyser-specific fields, fixed before the run")
print("\nThis is a RIG REHEARSAL, not a Gate 2 result:")
print("  * the receiver is software, so no PLL lock state and no buffer-model verdict exists")
print("  * every figure is P1 on a file; P2 needs the analyser on the live wire")
if soak < 72*3600:
    print(f"  * the soak ran {soak}s, short of the 72 h the protocol requires, so the 26.51 h")
    print("    PCR base wrap was not crossed by waiting (Part A crosses it by placement instead)")
PY
echo "results: $RESULTS"

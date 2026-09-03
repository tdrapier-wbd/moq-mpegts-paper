#!/usr/bin/env python3
"""Assert that ts-pcr-timing.py returns the right verdict on every PCR boundary condition.

    ts-pcr-selftest.py            # file-domain fixtures, instant
    ts-pcr-selftest.py --live     # also the paced arms, about a minute

This is the test of the tester. Every number the PCR campaign has published came out of
`ts-pcr-timing.py`, and review found six defects in it, four of which were the *analyser*
failing a conforming stream rather than the stream failing. A check that cannot be shown
reading both ways on demand is an assertion about an implementation, not a measurement, so
each fixture from `ts-pcr-fixtures.py` is paired here with the verdict it must produce and
the detail field that proves the condition was actually reached.

Two expectations are worth reading before changing them.

`discontinuity` must pass everything. ISO 13818-1 2.4.3.3 lets the counter jump in a packet
carrying discontinuity_indicator, and 2.4.3.4 lets the clock jump with it, so a signalled
splice is a conforming stream. It used to fail here twice over, and a soak that deliberately
exercises discontinuities would have reported those as defects in the stream.

`clustered` must pass the value check and only flag position. That pair is the whole reason
the campaign distinguishes the two domains: an exporter can put PCR values on a flawless grid
and still place the packets where no byte-only consumer can recover it.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TIMING = os.path.join(HERE, "ts-pcr-timing.py")
FIXTURES = os.path.join(HERE, "ts-pcr-fixtures.py")

PASS, FAIL = True, False

# fixture -> (what it proves, {check: expected ok}, {detail field: expected value})
# Checks not named are not asserted, so a fixture stays about one thing.
CASES = {
    "normal": (
        "a conformant grid passes every check, so a failure elsewhere means something",
        {"sync": PASS, "continuity": PASS, "pcr-value-interval": PASS, "pcr-position": PASS},
        {},
    ),
    "wrap": (
        "the 33-bit wrap is unwrapped, not read as a backwards clock",
        {"pcr-value-interval": PASS, "continuity": PASS},
        {"pcr-value-interval": {"wraps_unwrapped": 1, "non_positive": 0}},
    ),
    "duplicate": (
        "one legal duplicate packet is not a continuity error (ISO 13818-1 2.4.3.3)",
        {"continuity": PASS, "pcr-value-interval": PASS},
        {"pcr-value-interval": {"non_positive": 0}},
    ),
    "discontinuity": (
        "a signalled discontinuity is legal in both the counter and the clock",
        {"continuity": PASS, "pcr-value-interval": PASS},
        {"pcr-value-interval": {"signalled_discontinuities": 1}},
    ),
    "pid-change": (
        "the PCR moving PID mid-stream is caught, and caught by that check alone",
        {"pcr-single-pid": FAIL, "continuity": PASS, "pcr-value-interval": PASS},
        {},
    ),
    "loss-recovery": (
        "a visible loss is caught by the counter and sized by the clock, then recovers",
        {"continuity": FAIL, "pcr-value-interval": FAIL},
        {},
    ),
    "spacing": (
        "a stall past the repetition limit is caught while the counters stay legal",
        {"pcr-value-interval": FAIL, "continuity": PASS},
        {},
    ),
    "clustered": (
        "clock packets bunched on an exact value grid: position moves, values do not",
        {"pcr-value-interval": PASS, "continuity": PASS},
        {},
    ),
    "shortaf": (
        "PCR_flag on too short an adaptation field is skipped, not read out of stuffing",
        {"pcr-value-interval": PASS, "continuity": PASS},
        {},
    ),
    "backwards": (
        "a clock that genuinely moves backwards is a defect, and is not read as a wrap",
        {"pcr-value-interval": FAIL},
        {"pcr-value-interval": {"non_positive": 1, "wraps_unwrapped": 0}},
    ),
}


def report(argv, stdin=None):
    """Run the analyser and return ({check: (ok, detail)}, exit code).

    The exit code is asserted separately from the per-check booleans because they are not the
    same statement. A shape check reports `ok: false` and still exits 0, which is what makes
    it a shape check; only `--strict` lets it decide the run. A gate consumes the exit code,
    so that is the thing a test of the instrument has to pin down.
    """
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
        path = tmp.name
    try:
        proc = subprocess.run(
            [sys.executable, TIMING, *argv, "--report-json", path],
            stdin=stdin,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        with open(path) as f:
            data = json.load(f)
    finally:
        os.unlink(path)
    return {c["name"]: (c["ok"], c.get("detail") or {}) for c in data["checks"]}, proc.returncode


class Results:
    def __init__(self):
        self.failures = []
        self.checked = 0

    def expect(self, case, what, got, want):
        self.checked += 1
        if got != want:
            self.failures.append(f"{case}: {what}: expected {want!r}, got {got!r}")

    def done(self, label):
        print(f"\n{label}: {self.checked} assertions, {len(self.failures)} failed")
        for f in self.failures:
            print(f"  FAIL  {f}")
        return not self.failures


def run_file_cases(out):
    subprocess.run(
        [sys.executable, FIXTURES, out], stdout=subprocess.DEVNULL, check=True
    )
    r = Results()
    print("file-domain fixtures (values, positions, continuity)")
    for name, (why, checks, details) in CASES.items():
        got, _ = report([os.path.join(out, f"{name}.ts")])
        for check, want in checks.items():
            if check not in got:
                r.failures.append(f"{name}: no such check {check!r} in the report")
                r.checked += 1
                continue
            r.expect(name, check, got[check][0], want)
        for check, fields in details.items():
            for field, want in fields.items():
                r.expect(name, f"{check}.{field}", got[check][1].get(field), want)
        verdict = "ok" if not r.failures else "see below"
        print(f"  {name:16s} {verdict:9s} {why}")

    # The position check is a shape check by default, so on its own it can never fail a run.
    # Under --strict it has to, or the positional defect the campaign filed upstream would be
    # unreportable by the instrument that found it.
    lax, lax_code = report([os.path.join(out, "clustered.ts")])
    _, strict_code = report(["--strict", os.path.join(out, "clustered.ts")])
    _, clean_code = report(["--strict", os.path.join(out, "normal.ts")])
    r.expect("clustered", "pcr-position flags the clustering", lax["pcr-position"][0], False)
    r.expect("clustered", "shape check alone does not fail the run", lax_code, 0)
    r.expect("clustered", "--strict makes it fail the run", strict_code, 1)
    r.expect("normal", "--strict still passes a clean grid", clean_code, 0)
    print("  clustered        strict    position fails the run under --strict, clean grid still passes")
    return r


def run_live_cases():
    """The release and drift checks, which a file cannot exercise at all."""
    r = Results()
    print("\nlive fixtures (release timing, drift, truncation)")

    def paced(fixture, seconds, extra):
        proc = subprocess.Popen(
            [sys.executable, FIXTURES, "--pipe", fixture, "--seconds", str(seconds)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        try:
            return report(["--live", "--seconds", str(seconds), *extra], stdin=proc.stdout)
        finally:
            if proc.stdout:
                proc.stdout.close()
            proc.wait()

    # Released on its own grid: the check must not fire, and drift must stay near zero.
    #
    # The tolerance here is ±25 ms rather than the ±10 ms used against the real exporter,
    # because this generator paces with time.sleep on a general-purpose host and a single
    # scheduling hiccup puts one interval 17 ms out. That is the host, not the stream, and
    # asserting ±10 ms on it makes the self-test flaky, which is worse than useless. So this
    # arm establishes only that a correctly paced stream does not trip the check; the tight
    # bound belongs to the real pipeline, where the pacing is not Python's to do.
    got, _ = paced("steady", 8, ["--release-ms", "25", "--release-pct-max", "2"])
    r.expect("steady", "pcr-release-timing", got["pcr-release-timing"][0], PASS)
    r.expect(
        "steady",
        "drift stays near zero on a stream released on its grid",
        abs(got["pcr-release-timing"][1].get("total_drift_ms", 1e9)) < 50,
        True,
    )

    # Released 2 % slow. Per-interval error is 0.4 ms against a 10 ms tolerance, so no
    # percentage allowance can see it; only the accumulated bound can. The bound is lowered
    # here so the arm is seconds rather than half a minute; the point is that it fires.
    got, _ = paced("drift-slow", 8, ["--release-pct-max", "100", "--drift-ms", "40"])
    r.expect(
        "drift-slow", "pcr-release-timing (drift bound fires)", got["pcr-release-timing"][0], FAIL
    )
    detail = got["pcr-release-timing"][1]
    r.expect(
        "drift-slow",
        "drift exceeds the bound it was given",
        abs(detail.get("total_drift_ms", 0)) > 40,
        True,
    )

    # A capture that stops almost immediately must not pass. This is how a gate reports
    # success on a producer that died, and the exporter under test exits early routinely.
    got, code = paced("steady", 1, ["--seconds", "30"])
    r.expect("truncated", "pcr-release-timing", got["pcr-release-timing"][0], FAIL)
    r.expect("truncated", "truncation fails the run", code, 1)
    print("  steady/drift-slow/truncated  release passes, drift bound fires, truncation fails")
    return r


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--live", action="store_true", help="also run the paced arms (about a minute)")
    ap.add_argument("--keep", help="write the fixtures here instead of a temporary directory")
    args = ap.parse_args()

    out = args.keep or tempfile.mkdtemp(prefix="ts-pcr-fx-")
    files = run_file_cases(out)
    ok = files.done("file-domain")
    if args.live:
        ok = run_live_cases().done("live") and ok
    else:
        print("\nlive arms skipped; pass --live to grade release timing and drift")
    print("\nself-test passed" if ok else "\nself-test FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

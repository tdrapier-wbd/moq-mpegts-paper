#!/usr/bin/env bash
# What the verbatim HLS receiver itself costs, measured before any segmented latency arm is read
# through it.
#
# The receiver is a Python loop that spawns `curl` twice a reload cycle -- the playlist, then every
# fresh segment in one invocation -- so each cycle pays two connection setups, its reload period is
# half the target duration, and its `--timeout` truncates any one segment that takes longer. None
# of that is the segmented lane, and all of it lands in any latency or loss figure taken through it.
# Three questions, each answered by the cells named for it:
#
#   overhead   how long a cycle takes and how far each segment lags its file's creation, on an
#              unimpaired lane and at the netns rig's 100 ms RTT. The RTT cell reads the origin, not
#              the receiver, unless the h3 vhost sets `http3_stream_buffer_size` well above nginx's
#              64k default, which caps a stream at ~64 KB per round trip (t31-origin-window.sh)
#   budget     whether the fetch budget decides an impaired cell: the same shortfall at 4, 15 and
#              60 s, and at 15 s with a truncated segment recorded as a hole instead of ending the run
#   loss       the same, under sustained loss, where the exit-1 cells were
#
# Every cell is the T20 rig's h3 arm (`t20-h3-arm.sh`), loopback, the verbatim receiver, 2 s
# segments; per-segment timings come from its `_trace.csv`. Loopback netem shapes the origin->client
# direction only, so `delay 100ms` is a 100 ms RTT.
#
# Usage: t20-recv-timing.sh [outroot]        (~25 min; run with nothing else on the host)
set -uo pipefail

ROOT=${1:-$HOME/t20-recv-timing}
ARM_RIG=${ARM_RIG:-$HOME/t20-h3-arm.sh}
STREAM_MBIT=${STREAM_MBIT:-9.95}
mkdir -p "$ROOT"
rate_for() { awk -v s="$STREAM_MBIT" -v m="$1" 'BEGIN{printf "%.2fmbit", s*m}'; }

# label | window | env assignments, ';'-separated
cells() {
	cat <<-EOF
		overhead-rtt0|60|IMPAIR=delay 0ms
		overhead-rtt100|60|IMPAIR=delay 100ms
		budget-0.8x-t4|90|IMPAIR=rate 20mbit;RATE_BASE=20mbit;DIP_RATE=$(rate_for 0.8);DIP_S=perm;DIP_AT=20;RECV_TIMEOUT=4
		budget-0.8x-t15|90|IMPAIR=rate 20mbit;RATE_BASE=20mbit;DIP_RATE=$(rate_for 0.8);DIP_S=perm;DIP_AT=20;RECV_TIMEOUT=15
		budget-0.8x-t60|90|IMPAIR=rate 20mbit;RATE_BASE=20mbit;DIP_RATE=$(rate_for 0.8);DIP_S=perm;DIP_AT=20;RECV_TIMEOUT=60
		budget-0.8x-t15-hole|90|IMPAIR=rate 20mbit;RATE_BASE=20mbit;DIP_RATE=$(rate_for 0.8);DIP_S=perm;DIP_AT=20;RECV_TIMEOUT=15;RECV_TRUNCATED=hole
		loss10-t4|60|IMPAIR=loss 10%;RECV_TIMEOUT=4
		loss10-t15|60|IMPAIR=loss 10%;RECV_TIMEOUT=15
		loss10-t60|60|IMPAIR=loss 10%;RECV_TIMEOUT=60
		loss10-t15-hole|60|IMPAIR=loss 10%;RECV_TIMEOUT=15;RECV_TRUNCATED=hole
	EOF
}

while IFS='|' read -r cell window envs; do
	[ -z "$cell" ] && continue
	echo "########## $cell ##########"
	(
		IFS=';'
		for kv in $envs; do export "${kv?}"; done
		OUTDIR="$ROOT/$cell" timeout 400 bash "$ARM_RIG" "$cell" h3 "$window"
	) 2>&1 | tail -6
	sleep 3
done < <(cells)

echo
echo "== receiver timing =="
python3 - "$ROOT" <<-'PY'
	import csv, json, statistics, sys
	from pathlib import Path

	def q(xs, p):
	    xs = sorted(xs)
	    return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else float("nan")

	root = Path(sys.argv[1])
	print(f"{'cell':22s} {'segs':>4s} {'rc':>3s} {'holes':>5s} {'t/o':>3s} {'ratio':>6s}"
	      f" {'playlist p50/p95 ms':>20s} {'handshake p50/p95 ms':>21s} {'batch p50/p95 ms':>17s}"
	      f" {'lag p50/p95/max s':>19s}")
	for d in sorted(p for p in root.iterdir() if p.is_dir()):
	    rows = list(csv.DictReader(open(d / "h3_trace.csv"))) if (d / "h3_trace.csv").exists() else []
	    summ = json.load(open(d / "h3_recv.json")) if (d / "h3_recv.json").exists() else {}
	    res = (d / "h3.result").read_text() if (d / "h3.result").exists() else ""
	    kv = dict(tok.split("=", 1) for tok in res.split() if "=" in tok)
	    cycles = {}
	    for r in rows:
	        cycles.setdefault(r["cycle"], r)
	    pl = [float(r["playlist_s"]) * 1000 for r in cycles.values()]
	    bt = [float(r["batch_s"]) * 1000 for r in cycles.values()]
	    hs = [float(r["appconnect_s"]) * 1000 for r in rows if r["appconnect_s"]]
	    lag = [float(r["lag_s"]) for r in rows if r["lag_s"]]
	    print(f"{d.name:22s} {len(rows):4d} {kv.get('recv_rc', '?'):>3s} {len(summ.get('holes', [])):5d}"
	          f" {summ.get('batch_timeouts', 0):3d} {kv.get('delivered_ratio', '?'):>6s}"
	          f" {q(pl, .5):9.1f}/{q(pl, .95):9.1f} {q(hs, .5):10.1f}/{q(hs, .95):9.1f}"
	          f" {q(bt, .5):8.1f}/{q(bt, .95):8.1f} {q(lag, .5):6.2f}/{q(lag, .95):5.2f}/{max(lag, default=float('nan')):5.2f}")
PY

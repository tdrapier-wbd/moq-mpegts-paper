#!/usr/bin/env python3
"""P1-aq's rejoin grade: how a leg cut off its path comes back to its partner (lab/test-61-*.md).

  p1aq-rejoin.py RUN_DIR [--leg a] [--from cut-on] [--to cut-off] [--span A B] [--tail-s S]
  p1aq-rejoin.py --self-test

RUN_DIR holds t59-legs.sh's legs.pcap (leg a on port 5100, b on 5200, one clock), events.txt
("name epoch_ns", stamped on the receiver host, the recorder's clock) and the cut leg's fetcher log
(b8-<leg>.jsonl). The cut is the span between two events, or --span A B in seconds from the
capture's first datagram for a cell without them (the negative control). Reports, from the cut leg's
side:

  gap       its longest arrival silence over 1 s from the cut's start on, and the content time
            across it (the RTP timestamp's step: a stream-clocked groomer stamps the PCR, so a leg
            that resumes at the live edge steps by about the silence, one that resumes where it
            stopped by one datagram)
  rejoin    its first datagram after the gap identical to the partner's under the same 16-bit
            number within --pair-s, in seconds from the cut's end
  after     from the rejoin to the tail: its datagrams matched, mismatched and unpaired against the
            partner, the partner's it lacks, and the skew (partner's arrival less its own at equal
            numbers): median, 5th and 95th percentile, ms
  fetcher   the fetcher's exits and starts from the cut's start on
"""
import argparse
import hashlib
import json
import os
import struct
import sys
import tempfile

PORTS = {"a": 5100, "b": 5200}


def read(path):
	legs = {5100: [], 5200: []}
	with open(path, "rb") as f:
		if struct.unpack("<I", f.read(4))[0] != 0xA1B2C3D4:
			sys.exit("expected the rig's little-endian microsecond pcap")
		f.read(20)
		while hdr := f.read(16):
			sec, usec, n, _ = struct.unpack("<IIII", hdr)
			frame = f.read(n)
			port = struct.unpack("!H", frame[22:24])[0]
			if port in legs and len(frame) > 40:
				seq, ts = struct.unpack("!HI", frame[30:36])
				legs[port].append((sec + usec / 1e6, seq, hashlib.blake2b(frame[40:], digest_size=12).digest(), ts))
	return legs


def pct(xs, q):
	return xs[min(len(xs) - 1, int(q * len(xs)))]


def grade(legs, leg, cut, tail, pair_s, gap_s=1.0):
	x = legs[PORTS[leg]]
	y = legs[PORTS["b" if leg == "a" else "a"]]
	by_seq = {}
	for t, seq, d, _ in y:
		by_seq.setdefault(seq, []).append((t, d))
	t0 = min(x[0][0], y[0][0])
	c0, c1 = t0 + cut[0], t0 + cut[1]
	end = t0 + tail
	gap = None
	for p, q in zip(x, x[1:]):
		if q[0] >= c0 and q[0] - p[0] > gap_s and (gap is None or q[0] - p[0] > gap[1][0] - gap[0][0]):
			gap = (p, q)
	res = dict(leg=leg, cut_s=[round(cut[0], 3), round(cut[1], 3)], tail_s=tail)
	if gap is None:
		res["gap"] = None
		resume = c0
	else:
		p, q = gap
		res["gap"] = dict(last_s=round(p[0] - c0, 3), first_s=round(q[0] - c1, 3),
						  silence_s=round(q[0] - p[0], 3), content_s=round(((q[3] - p[3]) % (1 << 32)) / 90000, 3))
		resume = q[0]
	rejoin = None
	counts = dict(matched=0, mismatched=0, unpaired=0)
	skew = []
	seen = set()
	for t, seq, d, _ in x:
		if t < resume or t > end:
			continue
		near = [u for u in by_seq.get(seq, ()) if abs(u[0] - t) <= pair_s]
		if rejoin is None:
			if near and min(near, key=lambda u: abs(u[0] - t))[1] == d:
				rejoin = t
			else:
				continue
		if not near:
			counts["unpaired"] += 1
			continue
		u = min(near, key=lambda u: abs(u[0] - t))
		seen.add((seq, round(u[0], 6)))
		if u[1] == d:
			counts["matched"] += 1
			skew.append((u[0] - t) * 1000)
		else:
			counts["mismatched"] += 1
	res["rejoin_s"] = None if rejoin is None or gap is None else round(rejoin - c1, 3)
	if rejoin is not None:
		lacks = sum(1 for t, seq, *_ in y if rejoin + pair_s <= t <= end - pair_s and (seq, round(t, 6)) not in seen)
		skew.sort()
		res["after"] = dict(counts, partner_lacked=lacks,
							skew_ms=[round(pct(skew, q), 1) for q in (0.5, 0.05, 0.95)] if skew else None)
	return res


def fetcher(path, c0_epoch):
	out = []
	if os.path.exists(path):
		for line in open(path):
			r = json.loads(line)
			if r.get("ev") in ("fetcher-exit", "fetcher-start") and r["t"] >= c0_epoch:
				out.append({k: r[k] for k in r if k in ("ev", "status", "ran_s")} | {"at_s": round(r["t"] - c0_epoch, 2)})
	return out


def run(d, o):
	legs = read(os.path.join(d, "legs.pcap"))
	t0 = min(legs[5100][0][0], legs[5200][0][0])
	if o.span:
		cut = o.span
	else:
		ev = {}
		for line in open(os.path.join(d, "events.txt")):
			name, ns = line.split()
			ev[name] = int(ns) / 1e9
		cut = (ev[o.from_] - t0, ev[o.to] - t0)
	res = grade(legs, o.leg, cut, o.tail_s, o.pair_s)
	res["fetcher"] = fetcher(os.path.join(d, f"b8-{o.leg}.jsonl"), t0 + cut[0])
	return res


def self_test():
	"""Known answers on synthetic legs: 2,470 datagrams a second, B 40 ms behind A, A cut 120-150 s."""
	rate, secs = 2470, 200

	def pcap(path, a, b):
		with open(path, "wb") as f:
			f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 101))
			for t, port, seq, body, ts in sorted([(t, 5100, *r) for t, *r in a] + [(t, 5200, *r) for t, *r in b]):
				rtp = struct.pack("!BBHII", 0x80, 33, seq, ts, 538968071) + body
				frame = b"\x45" + bytes(19) + struct.pack("!HHHH", 40000, port, 8 + len(rtp), 0) + rtp
				f.write(struct.pack("<IIII", int(t), int(round((t % 1) * 1e6)), len(frame), len(frame)) + frame)

	def leg(start, off, keep=lambda i, t: True, body=lambda i: i.to_bytes(4, "big") * 4):
		return [(start + i / rate + off, i % 65536, body(i), round(i * 90000 / rate) % (1 << 32))
				for i in range(secs * rate) if keep(i, i / rate)]

	t0 = 1_700_000_000.0
	b = leg(t0, 0.040)
	cut = lambda i, t: not 120 <= t < 151
	# Each case: A, the rejoin (s after the restore; None, never), A's mismatches after it, the content step.
	cases = {
		# back at 151 s at the live edge, same numbers and bytes: rejoins 1 s after the restore
		"rejoin": (leg(t0, 0, cut), 1.0, 0, 31.0),
		# back at 151 s, wrong bytes for 2 s first: rejoins at 153 s, clean after
		"late-match": (leg(t0, 0, cut, lambda i: (b"x" if 151 <= i / rate < 153 else b"") + i.to_bytes(4, "big") * 4),
					   3.0, 0, 31.0),
		# back at 151 s, matched, then a second of wrong bytes at 170 s: mismatches after the rejoin
		"relapse": (leg(t0, 0, cut, lambda i: (b"x" if 170 <= i / rate < 171 else b"") + i.to_bytes(4, "big") * 4),
					1.0, rate, 31.0),
		# back at 151 s under numbers shifted by 1,000: never rejoins
		"renumbered": ([(t, (s + 1000) % 65536, p, ts) for t, s, p, ts in leg(t0, 0, cut)], None, None, 31.0),
		# back at 151 s where it stopped, 31 s behind its partner: never pairs, content steps one datagram
		"resumed-behind": ([(t + (31 if t - t0 >= 120 else 0), s, p, ts) for t, s, p, ts in leg(t0, 0, lambda i, t: t < 169)],
						   None, None, round(90000 / rate) / 90000),
		# never cut: the negative control
		"clean": (leg(t0, 0), None, None, None),
	}
	ok = True
	with tempfile.TemporaryDirectory() as tmp:
		for name, (a, want_rejoin, want_mis, want_step) in cases.items():
			path = os.path.join(tmp, "legs.pcap")
			pcap(path, a, b)
			r = grade(read(path), "a", (120, 150), 190, 5.0)
			gap = r["gap"]
			if want_step is None:
				good = gap is None and r["rejoin_s"] is None and r["after"]["mismatched"] == 0
			else:
				good = gap is not None and abs(gap["content_s"] - want_step) < 0.001
				if want_rejoin is None:
					good &= r["rejoin_s"] is None
				else:
					good &= (abs(r["rejoin_s"] - want_rejoin) < 0.01 and r["after"]["mismatched"] == want_mis
							 and r["after"]["unpaired"] == 0 and r["after"]["partner_lacked"] == 0
							 and abs(r["after"]["skew_ms"][0] - 40) < 1)
			ok &= good
			print(f"{'ok' if good else 'FAIL'} {name}: {json.dumps(r)}")
	return ok


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("dir", nargs="?")
	ap.add_argument("--leg", default="a", choices=("a", "b"))
	ap.add_argument("--from", dest="from_", default="cut-on")
	ap.add_argument("--to", default="cut-off")
	ap.add_argument("--span", nargs=2, type=float, metavar=("A", "B"))
	ap.add_argument("--tail-s", type=float, default=288.0, help="seconds from the capture's start (SECONDS - 12)")
	ap.add_argument("--pair-s", type=float, default=5.0)
	ap.add_argument("--self-test", action="store_true")
	o = ap.parse_args()
	if o.self_test:
		sys.exit(0 if self_test() else 1)
	if not o.dir:
		ap.error("RUN_DIR, or --self-test")
	print(json.dumps(run(o.dir, o)))


if __name__ == "__main__":
	main()

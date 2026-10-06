#!/usr/bin/env python3
"""Would two legs of one multiplex merge at the byte once each PID's continuity counter is rewritten?

ST 2022-7 merges whole packets, so a 1+1 pair is mergeable only if the two legs are byte-identical.
Two exporters that number continuity counters per process differ by a constant offset per PID even
when everything else agrees; a rewrite outside the exporter removes that offset. This tool measures
whether that rewrite would be *sufficient*: it aligns leg B inside leg A, takes each PID's offset as
the one most of its aligned packets carry, applies it to B, and then requires exact byte identity, packet by packet,
over the whole overlap. Anything left over is a real difference — reordering, a missing or extra
packet, or different payload — and is reported with its position. `transpose.py`-style
characterisation is the next step for a pair that fails here.

  ts-cc-merge.py <a.ts> <b.ts> [--rate BPS] [--needle-at SECONDS] [--needle N] [--show N]

Leg B is the one that joined later; the needle is taken from B at `--needle-at` seconds (default 2,
past B's own start-up) and found in A with the counters masked. The comparison then runs from the
start of B, so a leg whose first packets differ shows that as a leading run of mismatches.
"""
import argparse
import collections
import sys

TS = 188
SYNC = 0x47
NULL = 0x1FFF


def load(path):
	data = open(path, 'rb').read()
	off = next(i for i in range(TS) if all(data[i + k * TS] == SYNC for k in range(min(40, (len(data) - i) // TS))))
	n = (len(data) - off) // TS
	return [data[off + i * TS: off + (i + 1) * TS] for i in range(n)]


def pid(p):
	return ((p[1] & 0x1F) << 8) | p[2]


def masked(p):
	return p[0:3] + bytes([p[3] & 0xF0]) + p[4:]


def find(a, b, at, n):
	"""Index in A of B's packet `at`, matching n consecutive packets with counters masked."""
	k = at
	while k < len(b) and pid(b[k]) == NULL:
		k += 1
	needle = [masked(p) for p in b[k:k + n]]
	first = needle[0]
	for i, p in enumerate(a):
		if masked(p) == first and [masked(q) for q in a[i:i + n]] == needle:
			return i - (k - 0), k
	return None, k


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument('a')
	ap.add_argument('b')
	ap.add_argument('--rate', type=int, default=9945951)
	ap.add_argument('--needle-at', type=float, default=2.0)
	ap.add_argument('--needle', type=int, default=64)
	ap.add_argument('--show', type=int, default=8)
	args = ap.parse_args()

	pps = args.rate / 8 / TS
	a, b = load(args.a), load(args.b)
	shift, k = find(a, b, int(args.needle_at * pps), args.needle)
	if shift is None:
		print(f'no alignment: B\'s packets from {k} not found in A')
		return 2
	start_b = max(0, -shift)
	end_b = min(len(b), len(a) - shift)
	print(f'A {len(a):,} packets, B {len(b):,}; B[{k}] = A[{k + shift}], B starts {shift / pps:.3f} s into A')
	print(f'overlap: B[{start_b:,}:{end_b:,}] = {end_b - start_b:,} packets, {(end_b - start_b) / pps:.1f} s')

	# Each PID's offset is the one most of its aligned packets carry, so a leg's start-up or a
	# transposed block cannot set it; every packet of that PID must then carry that same offset.
	seen = {}
	for j in range(start_b, end_b):
		x, y = a[j + shift], b[j]
		if masked(x) == masked(y):
			c = seen.setdefault(pid(y), collections.Counter())
			c[((x[3] & 0x0F) - (y[3] & 0x0F)) & 0x0F] += 1
	offset = {p: c.most_common(1)[0][0] for p, c in seen.items()}
	exact = rewritten = 0
	bad = []
	for j in range(start_b, end_b):
		x, y = a[j + shift], b[j]
		p = pid(y)
		if x == y and offset.get(p, 0) == 0:
			exact += 1
			continue
		d = offset.get(p)
		if d is not None:
			z = y[0:3] + bytes([(y[3] & 0xF0) | (((y[3] & 0x0F) + d) & 0x0F)]) + y[4:]
			if z == x:
				rewritten += 1
				continue
		bad.append(j)
	total = end_b - start_b
	print(f'identical as captured: {exact:,} ({100 * exact / total:.3f} %)')
	print(f'identical after one constant counter offset per PID: {exact + rewritten:,} '
	      f'({100 * (exact + rewritten) / total:.3f} %)')
	print('per-PID offsets (A − B, mod 16): ' + ', '.join(f'0x{p:x}:{d}' for p, d in sorted(offset.items())))
	if not bad:
		print('MERGEABLE: every packet of the overlap is byte-identical once the counters are rewritten')
		return 0
	print(f'NOT MERGEABLE: {len(bad):,} packets differ after the rewrite, '
	      f'first at {(bad[0] - start_b) / pps:.3f} s, last at {(bad[-1] - start_b) / pps:.3f} s into the overlap')
	blocks = 1 + sum(1 for i in range(1, len(bad)) if bad[i] - bad[i - 1] > 1)
	bursts = []
	for j in bad:
		if bursts and j - bursts[-1][1] < pps:
			bursts[-1][1] = j
			bursts[-1][2] += 1
		else:
			bursts.append([j, j, 1])
	print(f'{blocks:,} contiguous blocks of differing packets, in {len(bursts)} bursts (gap < 1 s):')
	for s, e, n in bursts[:12]:
		print(f'  {(s - start_b) / pps:8.2f}–{(e - start_b) / pps:8.2f} s: {n:,} packets')
	clean_from = bad[-1] + 1
	print(f'identical from B[{clean_from:,}] ({(clean_from - start_b) / pps:.3f} s) to the end of the overlap')
	for j in bad[:args.show]:
		x, y = a[j + shift], b[j]
		print(f'  B[{j:,}] {(j - start_b) / pps:8.3f} s  A pid 0x{pid(x):x} cc {x[3] & 15:2d}   B pid 0x{pid(y):x} cc {y[3] & 15:2d}')
	return 1


if __name__ == '__main__':
	sys.exit(main())

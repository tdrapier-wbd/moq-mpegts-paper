#!/usr/bin/env python3
"""Arrival timing of transport streams on loopback UDP ports, as a receiving site's probe sees them.

usage: lane-arrival.py SECONDS PORT...

Per port: the rate over 100 ms windows, the largest 10 ms burst against the mean, the largest
inter-arrival gap, the null-packet share, continuity errors, and PCR jitter against arrival: each
PCR's value less its arrival time, a straight line (the two clocks' offset and drift) removed, as
peak-to-peak and 99th percentile of the absolute residual.
"""

import select
import socket
import sys
import time


def stats(arr, nbytes):
	t0, t1 = arr[0][0], arr[-1][0]
	span = t1 - t0
	win = {}
	burst = {}
	for t, n in zip((a[0] for a in arr), nbytes):
		win[int((t - t0) / 0.1)] = win.get(int((t - t0) / 0.1), 0) + n
		burst[int((t - t0) / 0.01)] = burst.get(int((t - t0) / 0.01), 0) + n
	full = [win[k] * 8 / 0.1 / 1e6 for k in range(1, int(span / 0.1) - 1) if k in win]
	mean10 = sum(nbytes) / (span / 0.01)
	gaps = max(b[0] - a[0] for a, b in zip(arr, arr[1:]))
	return span, min(full), max(full), max(burst.values()), mean10, gaps


def pcr_jitter(points):
	n = len(points)
	mx = sum(p[0] for p in points) / n
	my = sum(p[1] for p in points) / n
	sxx = sum((p[0] - mx) ** 2 for p in points)
	b = sum((p[0] - mx) * (p[1] - my) for p in points) / sxx
	res = sorted(abs(p[1] - my - b * (p[0] - mx)) for p in points)
	r = [p[1] - my - b * (p[0] - mx) for p in points]
	return (max(r) - min(r)) * 1000, res[int(0.99 * (n - 1))] * 1000, (b - 1) * 1e6


def main():
	secs = float(sys.argv[1])
	ports = [int(p) for p in sys.argv[2:]]
	socks = {}
	for p in ports:
		s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
		s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 << 20)
		s.bind(("127.0.0.1", p))
		socks[s] = p
	data = {p: [] for p in ports}
	end = time.monotonic() + secs
	while time.monotonic() < end:
		r, _, _ = select.select(list(socks), [], [], 0.5)
		for s in r:
			pkt = s.recv(65536)
			data[socks[s]].append((time.monotonic(), pkt))
	for p in ports:
		arr = data[p]
		if len(arr) < 2:
			print(f"port {p}: no input")
			continue
		nbytes = [len(d) for _, d in arr]
		span, rmin, rmax, bmax, bmean, gap = stats(arr, nbytes)
		cc, nulls, total, pcrs = {}, 0, 0, []
		errs = 0
		pcr_pid = None
		for t, d in arr:
			for i in range(0, len(d) - 187, 188):
				pk = d[i : i + 188]
				if pk[0] != 0x47:
					continue
				total += 1
				pid = ((pk[1] & 0x1F) << 8) | pk[2]
				if pid == 0x1FFF:
					nulls += 1
					continue
				afc = (pk[3] >> 4) & 3
				if afc & 1:
					c = pk[3] & 15
					if pid in cc and c != (cc[pid] + 1) & 15 and c != cc[pid]:
						errs += 1
					cc[pid] = c
				if afc & 2 and pk[4] >= 7 and pk[5] & 0x10:
					if pcr_pid is None:
						pcr_pid = pid
					if pid == pcr_pid:
						base = (pk[6] << 25) | (pk[7] << 17) | (pk[8] << 9) | (pk[9] << 1) | (pk[10] >> 7)
						ext = ((pk[10] & 1) << 8) | pk[11]
						pcrs.append((t, (base * 300 + ext) / 27e6))
		for k in range(1, len(pcrs)):
			while pcrs[k][1] < pcrs[k - 1][1] - 1000:
				pcrs[k] = (pcrs[k][0], pcrs[k][1] + 2**33 / 90000)
		pp, p99, ppm = pcr_jitter(pcrs) if len(pcrs) > 10 else (0, 0, 0)
		print(
			f"port {p}: {span:.1f} s, {sum(nbytes) * 8 / span / 1e6:.3f} Mb/s (100 ms: {rmin:.1f}-{rmax:.1f}), "
			f"burst10ms max {bmax} B ({bmax / bmean:.2f}x mean), max gap {gap * 1000:.1f} ms, "
			f"nulls {100 * nulls / max(total, 1):.1f} %, cc errors {errs}, PCRs {len(pcrs)} on PID {pcr_pid}, "
			f"PCR-arrival jitter p-p {pp:.2f} ms, p99 {p99:.2f} ms, drift {ppm:.1f} ppm"
		)


if __name__ == "__main__":
	main()

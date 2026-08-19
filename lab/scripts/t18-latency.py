#!/usr/bin/env python3
"""T18 delivery latency: how long a picture takes to cross a data plane.

    t18-latency.py tap <pid> <out.csv> [--pipe|--udp PORT] [--rtp] [--seconds N] [--chunk N]
                                       [--save <stream.ts>]
    t18-latency.py clock-server <port> [--seconds N]
    t18-latency.py clock-client <host> <port> [--samples N]
    t18-latency.py report <source.csv> <egress.csv> [--label L] [--clock-offset S] [--settle N]
                                                    [--kv <vars.sh>]

**The identifier is the presentation timestamp, and it survives every arm.** A
latency figure needs the *same* picture found twice, once leaving the source and
once arriving at the receiver, and the two ends cannot agree on byte position:
SRT, RIST and plain UDP carry the mux verbatim, but the media-aware MoQ lane
demultiplexes and remultiplexes, so its egress shares no TS packet with the
source, mints its own continuity counters, and is re-stamped again by the
groomer. What it does carry through is the PES presentation timestamp — measured
on this lane at exactly *source PTS − 1 tick*, on every picture, the whole way
through the pacer. So `report` recovers that constant per run rather than
assuming it, and the same instrument then grades a byte-transparent tunnel and a
remultiplexer without changing what it counts.

`tap` timestamps each PES header on one PID and passes the stream on unchanged,
so it can sit inline at the source (`--pipe`) or read a groomer's datagrams
(`--udp`, `--rtp` to skip the RTP header). Read size bounds the resolution and
must match on both ends, exactly as in `t13-cadence.py`: the default 1316 B is
one datagram, about a millisecond of a 10 Mb/s mux, against latencies measured
in hundreds of milliseconds.

`clock-server` / `clock-client` price the one thing a two-host measurement cannot
assume. Absolute latency compares a timestamp taken on the origin with one taken
on the receiver, so it inherits whatever those two clocks disagree by. The probe
exchanges four timestamps the way NTP does and reports the offset from the
lowest-delay sample together with its own uncertainty, so the latency figure can
carry a stated bound instead of a hope. Cross-*arm* differences need none of
this, provided the arms ran together and therefore share the error.

`report` joins the two logs on the recovered timestamp and summarises the
distribution. Quote the median with the spread: a transport's worst case is a
property of its burst structure, not noise, and it is the number a receiver's
buffer has to cover.
"""

from __future__ import annotations

import socket
import statistics as stats
import struct
import sys
import time

CHUNK = 1316
PKT = 188
RTP_HEADER = 12


def pts_at(buf: bytes, off: int) -> int:
	"""Decode a 33-bit MPEG timestamp from its five marker-interleaved bytes."""
	return (
		((buf[off] >> 1) & 0x07) << 30
		| buf[off + 1] << 22
		| ((buf[off + 2] >> 1) & 0x7F) << 15
		| buf[off + 3] << 7
		| (buf[off + 4] >> 1)
	)


def scan(block: bytes, pid: int, now: int, out) -> None:
	"""Record (wall clock, PTS) for every PES header on `pid` in one read."""
	for base in range(0, len(block) - PKT + 1, PKT):
		if block[base] != 0x47:
			return  # alignment lost; the caller resyncs on the next read
		if (((block[base + 1] & 0x1F) << 8) | block[base + 2]) != pid:
			continue
		if not block[base + 1] & 0x40:  # payload_unit_start_indicator
			continue
		off = base + 4
		if (block[base + 3] >> 4) & 0x2:  # adaptation field present
			off += 1 + block[base + 4]
		if off + 14 > base + PKT or block[off : off + 3] != b"\x00\x00\x01":
			continue
		if (block[off + 7] >> 6) & 0x2:  # PTS present
			out.write(f"{now},{pts_at(block, off + 9)}\n")
		# Flush per picture. Text output is buffered until close, so a tap that is
		# killed — or merely read before it exits — yields an *empty* file rather
		# than a short one, and the run reads as "the transport delivered nothing"
		# instead of as a teardown race. ~36 lines a second costs nothing.
		out.flush()


def align(buf: bytearray) -> bytearray:
	"""Drop leading bytes until the buffer starts on a TS sync byte."""
	i = buf.find(0x47)
	return bytearray() if i < 0 else buf[i:]


def tap(
	pid: int, path: str, mode: str, port: int, rtp: bool, seconds: float, chunk: int, save: str
) -> None:
	# Take the exclusive resource *before* touching the output files. A second tap on
	# a port that is already held used to open the log in write mode, truncating it,
	# and only then fail its bind — so a failing process destroyed a healthy one's
	# data and left the survivor flushing past a zero-filled hole.
	sock = None
	if mode == "udp":
		sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
		sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
		try:
			sock.bind(("127.0.0.1", port))
		except OSError as exc:
			sys.exit(f"tap: cannot bind 127.0.0.1:{port} ({exc}); another tap holds it")
		sock.settimeout(2.0)

	out = open(path, "w")
	out.write("t_ns,pts\n")
	# One pass has to answer both halves of the experiment, so the stream is kept as
	# well as timed: the conformance gate is applied to the same bytes whose latency
	# was measured, rather than to a second run that might have settled differently.
	keep = open(save, "wb") if save else None
	deadline = time.monotonic() + seconds if seconds else None
	n = 0

	if sock is not None:
		while deadline is None or time.monotonic() < deadline:
			try:
				data = sock.recv(65536)
			except socket.timeout:
				continue
			payload = data[RTP_HEADER:] if rtp else data
			scan(payload, pid, time.time_ns(), out)
			if keep:
				keep.write(payload)
			n += 1
	else:
		# Pass-through: this sits in the media path, so write on every read and
		# never accumulate, or the tap becomes part of what is being measured.
		buf = bytearray()
		while deadline is None or time.monotonic() < deadline:
			block = sys.stdin.buffer.read(chunk)
			if not block:
				break
			sys.stdout.buffer.write(block)
			sys.stdout.buffer.flush()
			now = time.time_ns()
			if keep:
				keep.write(block)
			buf += block
			if buf and buf[0] != 0x47:
				buf = align(buf)
			usable = len(buf) - (len(buf) % PKT)
			if usable:
				scan(bytes(buf[:usable]), pid, now, out)
				del buf[:usable]
			n += 1

	out.close()
	if keep:
		keep.close()
	print(f"tap: {n:,} reads, wrote {path}{' + ' + save if save else ''}", file=sys.stderr)


def clock_server(port: int, seconds: float) -> None:
	"""Stamp receive and transmit time into each probe and send it back."""
	sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	sock.bind(("0.0.0.0", port))
	sock.settimeout(1.0)
	deadline = time.monotonic() + seconds
	while time.monotonic() < deadline:
		try:
			data, peer = sock.recvfrom(64)
		except socket.timeout:
			continue
		t2 = time.time_ns()
		sock.sendto(data[:8] + struct.pack("!QQ", t2, time.time_ns()), peer)


def clock_client(host: str, port: int, samples: int) -> None:
	"""NTP's four timestamps: offset from the lowest-delay sample bounds itself."""
	sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	sock.settimeout(2.0)
	best = None
	for _ in range(samples):
		t1 = time.time_ns()
		sock.sendto(struct.pack("!Q", t1), (host, port))
		try:
			data, _ = sock.recvfrom(64)
		except socket.timeout:
			continue
		t4 = time.time_ns()
		t1e, t2, t3 = struct.unpack("!QQQ", data[:24])
		if t1e != t1:
			continue
		delay = (t4 - t1) - (t3 - t2)
		offset = ((t2 - t1) + (t3 - t4)) // 2
		if best is None or delay < best[0]:
			best = (delay, offset)
		time.sleep(0.05)

	if best is None:
		sys.exit("clock-client: no reply")
	delay, offset = best
	# The remote clock reads this much ahead of ours; halve the round trip for the
	# bound, since the probe cannot tell a slow outbound leg from a slow return.
	print(f"offset_s {offset / 1e9:.6f}")
	print(f"uncertainty_s {delay / 2e9:.6f}")
	print(f"rtt_ms {delay / 1e6:.3f}", file=sys.stderr)


def load(path: str) -> dict[int, int]:
	"""First sighting of each PTS: a retransmitted or repeated picture is not later."""
	seen: dict[int, int] = {}
	with open(path) as fh:
		next(fh, None)
		for line in fh:
			t, _, p = line.partition(",")
			if not p:
				continue
			pts = int(p)
			ns = int(t)
			if pts not in seen or ns < seen[pts]:
				seen[pts] = ns
	return seen


def report(
	src_path: str, eg_path: str, label: str, clock_offset: float, settle: float, kv: str
) -> None:
	src, eg = load(src_path), load(eg_path)
	if not src or not eg:
		sys.exit(f"report: empty log ({len(src)} source, {len(eg)} egress records)")

	# Recover the lane's PTS shift rather than assuming it: 0 for a byte-transparent
	# tunnel, -1 for the media-aware lane. Anything else means the two logs are not
	# the same programme, which must fail loudly rather than produce a plausible number.
	shift, hits = max(
		((k, sum(1 for p in eg if p + k in src)) for k in range(-4, 5)),
		key=lambda kv: kv[1],
	)
	if hits == 0:
		sys.exit("report: no egress PTS matches the source within ±4 ticks")

	# The receiver's clock reads `clock_offset` ahead of the origin's, so take it off
	# the arrival side before differencing.
	paired = [
		(eg[p], (eg[p] - src[p + shift]) / 1e6 - clock_offset * 1e3) for p in eg if p + shift in src
	]
	paired.sort()
	name = label or "arm"
	print(f"== {name}: {hits:,}/{len(eg):,} pictures matched ({100 * hits / len(eg):.1f}%), "
	      f"PTS shift {shift:+d}")

	# A groomer that starts behind spends the opening seconds draining, so quote the
	# steady state and print the whole series' trend beside it — a figure that is still
	# falling at the end of the window is a settling rig, not a transport's latency.
	t0 = paired[0][0]
	kept = [d for t, d in paired if (t - t0) / 1e9 >= settle]
	if len(kept) < 2:
		sys.exit(f"report: {len(kept)} pictures after a {settle:g}s settle; shorten it or run longer")
	deltas = sorted(kept)
	p95 = deltas[int(0.95 * (len(deltas) - 1))]
	print(
		f"   latency ms: min {deltas[0]:.1f}  median {stats.median(deltas):.1f}  "
		f"p95 {p95:.1f}  max {deltas[-1]:.1f}  spread {deltas[-1] - deltas[0]:.1f}"
	)
	# Spread is the jitter a receiver's buffer has to absorb; the minimum is the floor
	# the plane cannot beat, and the two together say more than the mean ever does.
	span = (paired[-1][0] - t0) / 1e9
	print(f"   over {len(kept):,} pictures after a {settle:g}s settle; window {span:.1f} s")
	third = max(len(paired) // 3, 1)
	head = stats.median([d for _, d in paired[:third]])
	tail = stats.median([d for _, d in paired[-third:]])
	print(f"   trend: first third {head:.1f} ms -> last third {tail:.1f} ms ({tail - head:+.1f})")

	if kv:
		# Shell-sourceable, so a sweep can build its table from the same numbers the
		# run printed rather than by parsing prose back out of a log.
		with open(kv, "w") as fh:
			fh.write(
				f"matched={hits}\nseen={len(eg)}\nshift={shift}\n"
				f"lat_min={deltas[0]:.1f}\nlat_median={stats.median(deltas):.1f}\n"
				f"lat_p95={p95:.1f}\nlat_max={deltas[-1]:.1f}\n"
				f"trend_head={head:.1f}\ntrend_tail={tail:.1f}\n"
				f"kept={len(kept)}\nwindow={span:.1f}\n"
			)


def main() -> None:
	args = sys.argv[1:]
	if not args:
		sys.exit(__doc__)
	cmd, rest = args[0], args[1:]

	def opt(flag, default=None, cast=str):
		return cast(rest[rest.index(flag) + 1]) if flag in rest else default

	if cmd == "tap":
		if len(rest) < 2:
			sys.exit(__doc__)
		mode = "udp" if "--udp" in rest else "pipe"
		tap(
			int(rest[0], 0),
			rest[1],
			mode,
			opt("--udp", 0, int),
			"--rtp" in rest,
			opt("--seconds", 0.0, float),
			opt("--chunk", CHUNK, int),
			opt("--save", ""),
		)
	elif cmd == "clock-server":
		clock_server(int(rest[0]), opt("--seconds", 120.0, float))
	elif cmd == "clock-client":
		clock_client(rest[0], int(rest[1]), opt("--samples", 40, int))
	elif cmd == "report":
		if len(rest) < 2:
			sys.exit(__doc__)
		report(
			rest[0],
			rest[1],
			opt("--label", ""),
			opt("--clock-offset", 0.0, float),
			opt("--settle", 0.0, float),
			opt("--kv", ""),
		)
	else:
		sys.exit(__doc__)


if __name__ == "__main__":
	main()

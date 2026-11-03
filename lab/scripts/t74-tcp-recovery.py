#!/usr/bin/env python3
"""T74 diagnostic: how each HTTP response on one TCP port recovered, from a header capture.

  t74-tcp-recovery.py <capture.pcap> [--port 18731] [--slow-ms 1000] [--json OUT]

Reads a classic pcap (Ethernet or Linux cooked, IPv4) taken at the server. Per connection, a response
runs from a request's arrival (a client segment with payload) to the client's cumulative ACK of every
byte the server sent before the next request. Per response: its bytes, its duration, the data
segments sent again (a sequence range already sent) with their times from the request, and the
longest silence in the server's sending. Responses slower than --slow-ms are listed in full.
"""
import argparse
import json
import struct
import sys


def packets(path):
	with open(path, "rb") as f:
		head = f.read(24)
		magic = struct.unpack("<I", head[:4])[0]
		if magic in (0xA1B2C3D4, 0xA1B23C4D):
			end = "<"
		elif magic in (0xD4C3B2A1, 0x4D3CB2A1):
			end = ">"
		else:
			sys.exit(f"{path}: not a classic pcap")
		nano = magic in (0xA1B23C4D, 0x4D3CB2A1)
		link = struct.unpack(end + "I", head[20:24])[0]
		while True:
			rec = f.read(16)
			if len(rec) < 16:
				return
			sec, frac, caplen, _ = struct.unpack(end + "IIII", rec)
			data = f.read(caplen)
			t = sec + frac / (1e9 if nano else 1e6)
			off = {1: 14, 113: 16}.get(link)
			if off is None:
				sys.exit(f"link type {link} not handled")
			eth = struct.unpack("!H", data[off - 2 : off])[0]
			if eth != 0x0800:
				continue
			ip = data[off:]
			ihl = (ip[0] & 15) * 4
			if ip[9] != 6:
				continue
			total = struct.unpack("!H", ip[2:4])[0]
			src, dst = ip[12:16], ip[16:20]
			tcp = ip[ihl:]
			sport, dport, seq, ack = struct.unpack("!HHII", tcp[:12])
			doff = (tcp[12] >> 4) * 4
			flags = tcp[13]
			plen = total - ihl - doff
			yield t, src, sport, dst, dport, seq, ack, flags, plen


def analyse(path, port):
	conns = {}
	for t, src, sport, dst, dport, seq, ack, flags, plen in packets(path):
		if sport == port:
			key, side = (dst, dport), "s"
		elif dport == port:
			key, side = (src, sport), "c"
		else:
			continue
		c = conns.setdefault(key, {"isn": None, "high": 0, "resp": [], "cur": None})
		if side == "s":
			if c["isn"] is None:
				c["isn"] = (seq - (1 if flags & 0x02 else 0)) & 0xFFFFFFFF
			rel = (seq - c["isn"]) & 0xFFFFFFFF
			if plen > 0 and c["cur"] is not None:
				r = c["cur"]
				if rel + plen <= c["high"] or rel < c["high"]:
					r["resent"].append((round((t - r["t0"]) * 1000, 1), rel, plen))
				if r["last_send"] is not None:
					r["gap_ms"] = max(r["gap_ms"], (t - r["last_send"]) * 1000)
				r["last_send"] = t
				r["end"] = max(r["end"], rel + plen)
			c["high"] = max(c["high"], rel + plen)
		else:
			if plen > 0:
				if c["cur"] is not None:
					c["resp"].append(c["cur"])
				c["cur"] = {"t0": t, "start": c["high"], "end": c["high"], "resent": [],
					"last_send": None, "gap_ms": 0.0, "acked_at": None}
			if flags & 0x10 and c["isn"] is not None and c["cur"] is not None:
				rel = (ack - c["isn"]) & 0xFFFFFFFF
				r = c["cur"]
				if r["end"] > r["start"] and rel >= r["end"]:
					r["acked_at"] = r["acked_at"] or t
	out = []
	for c in conns.values():
		if c["cur"] is not None:
			c["resp"].append(c["cur"])
		for r in c["resp"]:
			if r["end"] <= r["start"]:
				continue
			done = r["acked_at"]
			out.append({"t0": r["t0"], "bytes": r["end"] - r["start"],
				"ms": round((done - r["t0"]) * 1000, 1) if done else None,
				"resent": len(r["resent"]), "resent_at_ms": [x[0] for x in r["resent"]],
				"max_send_gap_ms": round(r["gap_ms"], 1)})
	out.sort(key=lambda x: x["t0"])
	return out


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("pcap")
	ap.add_argument("--port", type=int, default=18731)
	ap.add_argument("--slow-ms", type=float, default=1000)
	ap.add_argument("--json")
	a = ap.parse_args()
	rs = analyse(a.pcap, a.port)
	if not rs:
		sys.exit("no responses found")
	t0 = rs[0]["t0"]
	ms = sorted(r["ms"] for r in rs if r["ms"] is not None)
	print(f"{len(rs)} responses; median {ms[len(ms) // 2]} ms, max {ms[-1]} ms; "
		f"{sum(1 for r in rs if r['resent'])} with a resend")
	for r in rs:
		if r["ms"] is None or r["ms"] >= a.slow_ms:
			at = r["resent_at_ms"]
			shown = at if len(at) <= 12 else at[:6] + ["…"] + at[-6:]
			print(f"  at {r['t0'] - t0:7.2f} s: {r['bytes']} B in {r['ms']} ms, {r['resent']} resent "
				f"at {shown} ms, longest send gap {r['max_send_gap_ms']} ms")
	if a.json:
		with open(a.json, "w") as f:
			json.dump(rs, f, indent=1)


if __name__ == "__main__":
	main()

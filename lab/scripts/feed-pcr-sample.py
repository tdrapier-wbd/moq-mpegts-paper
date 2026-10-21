#!/usr/bin/env python3
# Join the local feed group and log, for every PCR on one PID: wall-clock arrival (ns), the PCR
# (27 MHz), a hash of the 188-byte packet, and the running packet index. Read-only.
# Usage: feed-pcr-sample.py <group> <port> <pid> <seconds> <out.csv>, on two hosts at once; join the
# two files on the PCR column to compare their packets and arrival times.
# Arrival is time.time_ns() after recv() returns, in the application: across hosts it carries each
# host's clock error and each reader's scheduling delay, neither calibrated, so it compares packets
# exactly and arrival only coarsely. It joins on the loopback interface, where the listener publishes.
import hashlib, socket, struct, sys, time

group, port, pid, secs, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3], 0), float(sys.argv[4]), sys.argv[5]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
s.bind((group, port))
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton(group) + socket.inet_aton("127.0.0.1"))
s.settimeout(1.0)
end = time.time() + secs
index = 0
with open(out, "w") as f:
	f.write("arrival_ns,pcr,hash,index\n")
	while time.time() < end:
		try:
			data = s.recv(65536)
		except socket.timeout:
			continue
		now = time.time_ns()
		for off in range(0, len(data) - 187, 188):
			p = data[off:off + 188]
			index += 1
			if p[0] != 0x47 or ((p[1] & 0x1F) << 8 | p[2]) != pid:
				continue
			if not (p[3] & 0x20) or p[4] < 7 or not (p[5] & 0x10):
				continue
			base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
			ext = ((p[10] & 1) << 8) | p[11]
			f.write(f"{now},{base * 300 + ext},{hashlib.sha1(p).hexdigest()[:12]},{index}\n")
print(f"packets {index}")

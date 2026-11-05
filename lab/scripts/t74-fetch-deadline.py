#!/usr/bin/env python3
"""b8-hls-recv.py with a deadline on each segment fetch, for T74's P1-ap arm.

    t74-fetch-deadline.py --fetch-deadline-ms MS URL OUT [b8-hls-recv.py's options]

b8-hls-recv.py's --timeout bounds each socket read, so a fetch that trickles in through a loss
recovery can take seconds without tripping it. This bounds the whole segment fetch, request to last
byte: at the deadline the socket is shut, the fetch fails as any other failure does, and the
receiver's retry asks again on a new connection. Playlist fetches keep the per-read bound only.
The receiver is loaded unchanged from beside this file.
"""

import importlib.util
import os
import socket
import sys
import threading
import time
import urllib.parse


def main():
	argv = sys.argv[1:]
	try:
		i = argv.index("--fetch-deadline-ms")
		deadline = float(argv[i + 1]) / 1000.0
		del argv[i:i + 2]
	except (ValueError, IndexError):
		sys.exit("usage: t74-fetch-deadline.py --fetch-deadline-ms MS URL OUT [b8-hls-recv.py's options]")
	path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "b8-hls-recv.py")
	spec = importlib.util.spec_from_file_location("b8_hls_recv", path)
	b8 = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(b8)
	plain_get = b8.Client.get

	def get(self, url, extra=None):
		if urllib.parse.urlsplit(url).path.endswith(".m3u8"):
			return plain_get(self, url, extra)
		lock, state = threading.Lock(), {"done": False, "fired": False}

		def expire():
			with lock:
				conn = self.conn
				if state["done"] or conn is None or conn.sock is None:
					return
				state["fired"] = True
				try:
					conn.sock.shutdown(socket.SHUT_RDWR)
				except OSError:
					pass

		timer = threading.Timer(deadline, expire)
		timer.daemon = True
		t0 = time.time()
		timer.start()
		try:
			return plain_get(self, url, extra)
		except Exception as e:
			if state["fired"]:
				ms = (time.time() - t0) * 1000
				raise TimeoutError(f"fetch deadline {deadline * 1000:.0f} ms at {ms:.0f} ms") from e
			raise
		finally:
			with lock:
				state["done"] = True
			timer.cancel()
			# A deadline that fired after the body was read leaves a shut socket behind.
			if state["fired"] and self.conn is not None:
				self.conn.close()
				self.conn = None

	b8.Client.get = get
	print(f"t74-fetch-deadline: {deadline * 1000:.0f} ms on each segment fetch", file=sys.stderr, flush=True)
	sys.argv = [path] + argv
	b8.main()


if __name__ == "__main__":
	main()

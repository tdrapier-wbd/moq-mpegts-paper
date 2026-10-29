#!/usr/bin/env python3
"""An origin's staleness guard (lab/test-61-*.md): withdraw a playlist that stops advancing.

A packager that freezes, or loses its input, leaves its last playlist on disk, and the origin goes
on answering 200 for it; a CDN cannot fail over from a 200. The guard renames the playlist away
once it is older than --stale seconds, so the origin answers 404 and the CDN's origin group fails
over. It is a separate process so that whatever stops the packager does not stop the guard; the
packager's next playlist replaces the file, so the guard never has to restore anything.

  t61-guard.py PLAYLIST [--stale 4] [--every 0.25]

One line per withdrawal on stderr: "<unix time> withdrawn age=S".
"""
import argparse
import os
import sys
import time


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("playlist")
	ap.add_argument("--stale", type=float, default=4.0, help="seconds without a new playlist")
	ap.add_argument("--every", type=float, default=0.25)
	args = ap.parse_args()
	while True:
		try:
			age = time.time() - os.stat(args.playlist).st_mtime
			if age > args.stale:
				os.replace(args.playlist, args.playlist + ".stale")
				print(f"{time.time():.3f} withdrawn age={age:.3f}", file=sys.stderr, flush=True)
		except FileNotFoundError:
			pass
		time.sleep(args.every)


if __name__ == "__main__":
	main()

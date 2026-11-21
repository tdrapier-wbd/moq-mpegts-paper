"""Job board for `t83d-bisect.sh`: GET serves the directory, PUT writes a file under `result/`.

    python3 t83d-jobsrv.py <dir> <port>

The orchestrator writes `<dir>/job` ("<label> <T0> <delays> <bursts,> <reps> <control>", or "done");
the receiver reads it and PUTs `result/<label>.txt` (the grade) and `result/<label>.tgz` (its logs).
Each upload lands whole: written beside, then renamed.
"""

import functools
import http.server
import os
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_PUT(self):
        name = self.path.lstrip("/").removeprefix("result/")
        if not self.path.startswith("/result/") or not name or "/" in name or name.startswith("."):
            self.send_error(403)
            return
        size = int(self.headers.get("Content-Length", "0"))
        path = os.path.join(self.directory, "result", name)
        with open(path + ".part", "wb") as f:
            left = size
            while left > 0:
                chunk = self.rfile.read(min(left, 1 << 16))
                if not chunk:
                    break
                f.write(chunk)
                left -= len(chunk)
        os.replace(path + ".part", path)
        self.send_response(201)
        self.end_headers()


def main():
    root, port = sys.argv[1], int(sys.argv[2])
    os.makedirs(os.path.join(root, "result"), exist_ok=True)
    handler = functools.partial(Handler, directory=root)
    http.server.ThreadingHTTPServer(("0.0.0.0", port), handler).serve_forever()


if __name__ == "__main__":
    main()

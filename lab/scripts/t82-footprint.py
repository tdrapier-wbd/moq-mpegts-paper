#!/usr/bin/env python3
"""T82: sample one process's physical footprint (macOS) every 0.5 s, as `t<TAB>MB`.

`ps` RSS leaves out compressed and swapped pages, so under memory pressure a relay's RSS can fall
below the size of its own cache. `ri_phys_footprint` (proc_pid_rusage, RUSAGE_INFO_V2) counts them,
which is the figure Activity Monitor calls Memory. Stops when the process exits.

usage: t82-footprint.py --pid N --t0 EPOCH --out fp.tsv
"""

import argparse
import ctypes
import time


class RusageInfoV2(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64)
        for name in (
            "ri_user_time",
            "ri_system_time",
            "ri_pkg_idle_wkups",
            "ri_interrupt_wkups",
            "ri_pageins",
            "ri_wired_size",
            "ri_resident_size",
            "ri_phys_footprint",
            "ri_proc_start_abstime",
            "ri_proc_exit_abstime",
            "ri_child_user_time",
            "ri_child_system_time",
            "ri_child_pkg_idle_wkups",
            "ri_child_interrupt_wkups",
            "ri_child_pageins",
            "ri_child_elapsed_abstime",
            "ri_diskio_bytesread",
            "ri_diskio_byteswritten",
        )
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--t0", type=float, required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    info = RusageInfoV2()
    with open(a.out, "w") as f:
        f.write("t\tfootprint_mb\trss_mb\n")
        while libproc.proc_pid_rusage(a.pid, 2, ctypes.byref(info)) == 0:
            t = time.time() - a.t0
            f.write(f"{t:.2f}\t{info.ri_phys_footprint / 1e6:.1f}\t{info.ri_resident_size / 1e6:.1f}\n")
            f.flush()
            time.sleep(0.5)


if __name__ == "__main__":
    main()

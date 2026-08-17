#!/usr/bin/env python3
"""Emit a TSDuck EPG for N services whose present event rolls every `step` seconds.

The companion to `make-mpts-si.py` for the half of the SI that actually changes. SDT and NIT are
static once acquired, so they cost the catalog nothing after the first publish; EIT present/
following turns over at every programme junction, and it is that turnover — not the size of the
table — that decides whether carried SI belongs in a whole-state document.

Every service rolls on the same boundary, which is not a pathological choice: broadcast schedules
align junctions on the hour and half-hour across most of a multiplex, so a simultaneous roll is
the ordinary case and the one worth pricing.

`step` is short here only so a junction fits inside a test clip. The cost being measured is per
junction, so the rate it is replayed at does not change the figure — read the result as "one
junction costs this", then apply a real schedule's junction rate.

Times are anchored to the reference clip's TDT epoch, which `eitinject` resynchronises to; the
first event starts one step early so it straddles that epoch and the p/f table is populated at
t=0 rather than empty.

Usage: make-mpts-epg.py <services> <step_seconds> <events> <out.xml>
"""

import datetime
import sys

# CNNiEMEA2.ts's own TDT epoch; change it with the source clip or the p/f table is empty at t=0.
EPOCH = datetime.datetime(2026, 6, 19, 7, 54, 42)


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    n, step, count, out = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    start = EPOCH - datetime.timedelta(seconds=step)
    duration = f"{step // 3600:02d}:{step % 3600 // 60:02d}:{step % 60:02d}"

    lines = ['<?xml version="1.0" encoding="UTF-8"?>', "<tsduck>"]
    for s in range(1, n + 1):
        lines.append(
            f'  <EIT type="pf" actual="true" version="1" current="true" '
            f'service_id="{s}" transport_stream_id="0" original_network_id="0">'
        )
        for e in range(count):
            t = start + datetime.timedelta(seconds=e * step)
            lines.append(
                f'    <event event_id="{s * 1000 + e}" start_time="{t:%Y-%m-%d %H:%M:%S}" '
                f'duration="{duration}" running_status="{"running" if e == 0 else "not-running"}" '
                f'CA_mode="false">'
            )
            lines.append('      <short_event_descriptor language_code="eng">')
            lines.append(f"        <event_name>Programme {e + 1:02d} on Channel {s:02d}</event_name>")
            lines.append(f"        <text>Synthetic programme {e + 1} used to roll present/following.</text>")
            lines.append("      </short_event_descriptor>")
            lines.append("    </event>")
        lines.append("  </EIT>")
    lines.append("</tsduck>")

    open(out, "w").write("\n".join(lines) + "\n")
    print(f"{out}: {n} services, {count} events every {step}s")


if __name__ == "__main__":
    main()

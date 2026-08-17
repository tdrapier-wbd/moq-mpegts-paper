#!/usr/bin/env python3
"""Emit DVB SDT actual and NIT actual for a multiplex of N services.

Every capture we hold is a single-service contribution feed, so the question
[#2882](https://github.com/moq-dev/moq/issues/2882) turns on — what carried SI costs the catalog
at realistic service counts — cannot be answered from them. This synthesises the SI half of a
distribution multiplex so the cost can be measured against N rather than estimated.

Note what is and is not synthetic. A real DVB SPTS carved out of a distribution multiplex carries
one programme's media alongside an SDT listing *every* service in that transport stream and a NIT
listing every transport in the network, because both tables are mandatory in full. So a fixture
whose media side is one service and whose SI side is a whole multiplex is not a contrivance: it is
the shape the lane actually meets.

Usage: make-mpts-si.py <services> [transports] <out-prefix>
  -> <out-prefix>.sdt.xml and <out-prefix>.nit.xml, for tstabcomp
"""

import sys

PROVIDER = "Example Broadcasting Group"


def sdt(n):
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<tsduck>",
        '  <SDT version="1" current="true" actual="true" transport_stream_id="0x0001" '
        'original_network_id="0x2000">',
    ]
    for i in range(1, n + 1):
        out.append(
            f'    <service service_id="{i}" EIT_schedule="true" EIT_present_following="true" '
            f'running_status="running" CA_mode="true">'
        )
        out.append(
            f'      <service_descriptor service_type="0x19" service_provider_name="{PROVIDER}" '
            f'service_name="Channel {i:02d} HD"/>'
        )
        out.append("    </service>")
    return out + ["  </SDT>", "</tsduck>"]


def nit(n, transports):
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<tsduck>",
        '  <NIT version="1" current="true" actual="true" network_id="0x2000">',
        '    <network_name_descriptor network_name="Example Network"/>',
    ]
    for t in range(transports):
        out.append(f'    <transport_stream transport_stream_id="{t + 1}" original_network_id="0x2000">')
        out.append("      <service_list_descriptor>")
        for i in range(1, n + 1):
            out.append(f'        <service service_id="{i}" service_type="0x19"/>')
        out.append("      </service_list_descriptor>")
        out.append(
            f'      <satellite_delivery_system_descriptor frequency="{11000 + t * 40},000,000" '
            f'orbital_position="19.2" west_east_flag="east" polarization="vertical" roll_off="0.35" '
            f'modulation_system="DVB-S2" modulation_type="8PSK" symbol_rate="27,500,000" FEC_inner="3/4"/>'
        )
        out.append("    </transport_stream>")
    return out + ["  </NIT>", "</tsduck>"]


def main():
    if not 3 <= len(sys.argv) <= 4:
        sys.exit(__doc__)
    n = int(sys.argv[1])
    transports = int(sys.argv[2]) if len(sys.argv) == 4 else 1
    out = sys.argv[-1]

    open(f"{out}.sdt.xml", "w").write("\n".join(sdt(n)) + "\n")
    open(f"{out}.nit.xml", "w").write("\n".join(nit(n, transports)) + "\n")
    print(f"{out}.sdt.xml, {out}.nit.xml: {n} services, {transports}-transport NIT")


if __name__ == "__main__":
    main()

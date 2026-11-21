#!/usr/bin/env python3
"""T86 P2-u: a userspace UDP shaper for one QUIC hop, where `tc netem` is out of reach (no root).

    t86-lossy-udp.py --listen 127.0.0.1:P --to 127.0.0.1:R [--loss PCT] [--delay-ms MS]
                     [--seed N] [--stats stats.json]

Clients send to --listen; each client address gets its own upstream socket to --to. Datagrams from
upstream back to a client (the payload direction) are dropped with probability PCT/100, each drawn
independently, and the rest are delayed by MS; the client-to-upstream direction passes unchanged.
Counters (passed and dropped each way) are written to --stats every second and on exit.
"""

import argparse
import asyncio
import json
import random
import signal


def addr(s):
    host, port = s.rsplit(":", 1)
    return host, int(port)


class Upstream(asyncio.DatagramProtocol):
    def __init__(self, shaper, client):
        self.shaper, self.client, self.transport, self.pending = shaper, client, None, []

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, _):
        self.shaper.down(data, self.client)


class Shaper(asyncio.DatagramProtocol):
    def __init__(self, a):
        self.a, self.rng, self.loop = a, random.Random(a.seed), asyncio.get_running_loop()
        self.p, self.delay = a.loss / 100.0, a.delay_ms / 1000.0
        self.clients, self.transport = {}, None
        self.n = {"up_passed": 0, "down_passed": 0, "down_dropped": 0, "clients": 0}

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, client):
        up = self.clients.get(client)
        if up is None:
            up = self.clients[client] = Upstream(self, client)
            up.pending.append(data)
            self.n["clients"] += 1
            self.loop.create_task(self.open(up))
            return
        if up.transport is None:
            up.pending.append(data)
            return
        up.transport.sendto(data)
        self.n["up_passed"] += 1

    async def open(self, up):
        await self.loop.create_datagram_endpoint(lambda: up, remote_addr=addr(self.a.to))
        for data in up.pending:
            up.transport.sendto(data)
            self.n["up_passed"] += 1
        up.pending = []

    def down(self, data, client):
        if self.rng.random() < self.p:
            self.n["down_dropped"] += 1
            return
        self.n["down_passed"] += 1
        if self.delay:
            self.loop.call_later(self.delay, self.transport.sendto, data, client)
        else:
            self.transport.sendto(data, client)

    def dump(self):
        if self.a.stats:
            d = dict(self.n, loss_commanded_pct=self.a.loss, delay_ms=self.a.delay_ms)
            total = self.n["down_passed"] + self.n["down_dropped"]
            d["loss_measured_pct"] = round(100.0 * self.n["down_dropped"] / total, 3) if total else 0.0
            with open(self.a.stats, "w") as f:
                json.dump(d, f)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True)
    ap.add_argument("--to", required=True)
    ap.add_argument("--loss", type=float, default=0.0)
    ap.add_argument("--delay-ms", type=float, default=0.0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--stats")
    a = ap.parse_args()
    loop = asyncio.get_running_loop()
    shaper = Shaper(a)
    await loop.create_datagram_endpoint(lambda: shaper, local_addr=addr(a.listen))
    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    while not stop.is_set():
        try:
            await asyncio.wait_for(stop.wait(), 1.0)
        except asyncio.TimeoutError:
            pass
        shaper.dump()
    shaper.dump()


if __name__ == "__main__":
    asyncio.run(main())

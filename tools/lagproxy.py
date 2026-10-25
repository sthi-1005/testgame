#!/usr/bin/env python3
"""UDP proxy that adds latency, jitter and packet loss, for testing the netcode on localhost.
   python3 tools/lagproxy.py --listen 24566 --target 24565 --delay 60 --jitter 15 --loss 0.03
Delay is one way (so 60 ms here is about 120 ms ping), applied in both directions."""
import argparse, asyncio, random

ap = argparse.ArgumentParser()
ap.add_argument("--listen", type=int, default=24566)
ap.add_argument("--target", type=int, default=24565)
ap.add_argument("--delay", type=float, default=60)
ap.add_argument("--jitter", type=float, default=15)
ap.add_argument("--loss", type=float, default=0.03)
a = ap.parse_args()
loop = None

def later(fn):
    if random.random() < a.loss:
        return
    loop.call_later(max(0.0, a.delay + random.uniform(-a.jitter, a.jitter)) / 1000, fn)

class Up(asyncio.DatagramProtocol):
    def __init__(self, front, client): self.front, self.client = front, client
    def connection_made(self, t): self.t = t
    def datagram_received(self, data, _): later(lambda: self.front.t.sendto(data, self.client))

class Front(asyncio.DatagramProtocol):
    def __init__(self): self.ups = {}
    def connection_made(self, t): self.t = t
    def datagram_received(self, data, client):
        later(lambda: asyncio.ensure_future(self.forward(data, client)))
    async def forward(self, data, client):
        if client not in self.ups:
            self.ups[client] = asyncio.ensure_future(loop.create_datagram_endpoint(lambda: Up(self, client), remote_addr=("127.0.0.1", a.target)))
        tr, _ = await self.ups[client]
        tr.sendto(data)

async def main():
    global loop
    loop = asyncio.get_running_loop()
    await loop.create_datagram_endpoint(Front, local_addr=("127.0.0.1", a.listen))
    print(f"lagproxy :{a.listen} -> :{a.target}  delay {a.delay}±{a.jitter} ms one way, loss {a.loss:.0%}", flush=True)
    await asyncio.Event().wait()

asyncio.run(main())

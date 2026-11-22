#!/usr/bin/env python3
import asyncio, signal, sys
BUFFER_SIZE = 65536
SSH_HOST = "127.0.0.1"
SSH_PORT = 22
R101 = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
R200 = b"HTTP/1.1 200 Connection established\r\n\r\n"
active = 0

async def pipe(r, w):
    try:
        while True:
            d = await r.read(BUFFER_SIZE)
            if not d: break
            w.write(d); await w.drain()
    except: pass
    finally:
        try: w.close()
        except: pass

async def handle(cr, cw):
    global active
    active += 1; sw = None
    try:
        try:
            p = await asyncio.wait_for(cr.read(BUFFER_SIZE), timeout=10)
        except asyncio.TimeoutError:
            cw.close(); active -= 1; return
        if not p:
            cw.close(); active -= 1; return
        req = p.decode("utf-8", errors="ignore").upper()
        cw.write(R101 if ("UPGRADE" in req or "WEBSOCKET" in req) else R200)
        await cw.drain()
        try:
            sr, sw = await asyncio.open_connection(SSH_HOST, SSH_PORT)
        except:
            cw.close(); active -= 1; return
        await asyncio.gather(pipe(cr, sw), pipe(sr, cw))
    except: pass
    finally:
        active -= 1
        try: cw.close()
        except: pass
        if sw:
            try: sw.close()
            except: pass

async def start(port):
    s = await asyncio.start_server(handle, "127.0.0.1", port)
    async with s: await s.serve_forever()

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 10015
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    for sig in (signal.SIGTERM, signal.SIGINT):
        try: loop.add_signal_handler(sig, lambda: loop.stop())
        except: pass
    loop.run_until_complete(start(port))

if __name__ == "__main__":
    main()

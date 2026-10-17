"""Wireless JIT for HuskDroid (and Husk): no cable, no lldb, no on-device VPN.

Reaches the iPhone's lockdownd by IP (HUSKDROID_PHONE_HOSTS, tried in order), opens the
iOS 17+ developer tunnel in userspace (no root), and drives debugserver over gdb-remote
the way Husk's husk-jit.js does under StikDebug:
  brk #0x69            -> x0 = 0xE0000069 (attach probe)
  brk #0xf00d, x16 = 1 -> allocate RX (_M), touch every 16 KiB page (M ..,1:69), x0 = addr
  brk #0xf00d, x16 = 0 -> detach

`grant()` is the whole job; the companion and the huskjit-net command both call it.
"""
import asyncio
import os
import plistlib
import re
import threading
import time
from pathlib import Path

import pymobiledevice3.remote.userspace_tunnel as ut
from pymobiledevice3.lockdown import create_using_tcp
from pymobiledevice3.pair_records import get_preferred_pair_record

def _config():
    """HUSKDROID_* from the environment, else ~/.config/huskdroid/config.env (install.sh copies
    config/local.env there)."""
    values = {}
    path = Path.home() / ".config" / "huskdroid" / "config.env"
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip()
    values.update({k: v for k, v in os.environ.items() if k.startswith("HUSKDROID_")})
    return values


_CONFIG = _config()
UDID = _CONFIG.get("HUSKDROID_UDID", "")
HOSTS = [h.strip() for h in _CONFIG.get("HUSKDROID_PHONE_HOSTS", "").split(",") if h.strip()]
PAIR_DIR = Path.home() / ".pymobiledevice3"
DEBUGPROXY = "com.apple.internal.dt.remote.debugproxy"
PAGE = 16384
BATCH = 512

# PyTCP's userspace stack is one per process: one JIT session at a time. A thread lock, because
# each caller (one per HTTP request in the companion) runs its own event loop.
_session_lock = threading.Lock()


class JitError(Exception):
    pass


class Gdb:
    """Minimal gdb-remote client (no-ack mode after the handshake)."""

    def __init__(self, conn):
        self.conn = conn
        self.buf = b""
        self.ack = True

    async def _read_packet(self):
        while True:
            start = self.buf.find(b"$")
            if start >= 0:
                end = self.buf.find(b"#", start)
                if end >= 0 and len(self.buf) >= end + 3:
                    body = self.buf[start + 1:end]
                    self.buf = self.buf[end + 3:]
                    if self.ack:
                        await self.conn.sendall(b"+")
                    return body.decode("latin-1")
            chunk = await self.conn.recv_any(65536)
            if not chunk:
                raise JitError("debugserver closed the connection")
            self.buf += chunk

    @staticmethod
    def frame(cmd):
        data = cmd.encode("latin-1")
        return b"$" + data + b"#" + f"{sum(data) & 0xFF:02x}".encode()

    async def send(self, cmd):
        await self.conn.sendall(self.frame(cmd))
        return await self._read_packet()

    async def send_many(self, cmds):
        await self.conn.sendall(b"".join(self.frame(c) for c in cmds))
        return [await self._read_packet() for _ in cmds]

    async def no_ack(self):
        r = await self.send("QStartNoAckMode")
        if r == "OK":
            self.ack = False
        return r


def _le_to_int(hexstr):
    return int.from_bytes(bytes.fromhex(hexstr), "little")


def _int_to_le(value):
    return value.to_bytes(8, "little").hex()


def _reg(reply, num):
    m = re.search(rf"(?:^|;){num:02x}:([0-9a-f]{{16}});", reply)
    return _le_to_int(m.group(1)) if m else None


async def _prepare_region(gdb, x0, x1, log):
    addr = x0
    if addr == 0:
        r = await gdb.send(f"_M{x1:x},rx")
        if not re.fullmatch(r"[0-9a-f]+", r or ""):
            raise JitError(f"RX allocation failed: {r!r}")
        addr = int(r, 16)
        log(f"allocated {x1 >> 20} MiB RX at {addr:#x}")
    pages = (x1 + PAGE - 1) // PAGE
    t0 = time.time()
    for first in range(0, pages, BATCH):
        cmds = [f"M{addr + i * PAGE:x},1:69" for i in range(first, min(first + BATCH, pages))]
        bad = [r for r in await gdb.send_many(cmds) if r != "OK"]
        if bad:
            raise JitError(f"page writes failed near page {first}: {bad[0]!r}")
    log(f"prepared {pages} pages in {time.time() - t0:.1f}s")
    return addr


async def _serve(gdb, name, log, request_timeout):
    r = await gdb.send("vAttachName;" + name.encode().hex())
    if not r.startswith("T"):
        raise JitError(f"could not attach to {name} ({r!r}); is it open?")
    log(f"attached to {name}; waiting for its JIT request")
    deadline = time.time() + request_timeout
    reply = await gdb.send("c")
    while True:
        if reply.startswith(("W", "X")):
            raise JitError(f"{name} exited ({reply})")
        if not reply.startswith("T"):
            log(f"unexpected stop reply {reply!r}; continuing")
            reply = await gdb.send("c")
            continue
        sig = int(reply[1:3], 16)
        tid_m = re.search(r"thread:([0-9a-f]+);", reply)
        pc, x16 = _reg(reply, 0x20), _reg(reply, 0x10)
        if tid_m is None or pc is None:
            reply = await gdb.send("c")
            continue
        tid = tid_m.group(1)
        instr = int.from_bytes(bytes.fromhex(await gdb.send(f"m{pc:x},4")), "little")
        if (instr & 0xFFE0001F) != 0xD4200000:
            log(f"signal {sig} at {pc:#x} (not a brk); passing it on")
            reply = await gdb.send(f"C{sig:02x}")
            continue
        imm = (instr >> 5) & 0xFFFF
        x0, x1 = _reg(reply, 0x00), _reg(reply, 0x01)
        await gdb.send(f"P20={_int_to_le(pc + 4)};thread:{tid};")
        if imm == 0x69:
            log("probe answered")
            await gdb.send(f"P0={_int_to_le(0xE0000069)};thread:{tid};")
        elif imm == 0xF00D and x16 == 1 and (x0 or x1):
            addr = await _prepare_region(gdb, x0, x1, log)
            await gdb.send(f"P0={_int_to_le(addr)};thread:{tid};")
        elif imm == 0xF00D and x16 == 0:
            log(f"detach: {await gdb.send('D')}")
            return
        else:
            log(f"unhandled brk #{imm:#x}, stepped over")
        if time.time() > deadline:
            raise JitError("timed out waiting for the app's JIT request")
        reply = await gdb.send("c")


async def reachable(host, port=62078, timeout=3):
    try:
        _, w = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
        w.close()
        return True
    except (OSError, asyncio.TimeoutError):
        return False


async def pick_host(hosts=HOSTS):
    for h in hosts:
        if await reachable(h):
            return h
    raise JitError(f"the phone is not reachable at {', '.join(hosts)} (other network, changed address, or the route is down?)")


async def pair_record(udid=UDID):
    PAIR_DIR.mkdir(mode=0o700, exist_ok=True)
    record = await get_preferred_pair_record(udid, PAIR_DIR)
    if record is None:
        raise JitError("no pair record; plug the phone into this Mac once")
    copy = PAIR_DIR / f"{udid}.plist"
    if not copy.exists():
        copy.write_bytes(plistlib.dumps(record))
        copy.chmod(0o600)
    return record


async def grant(name="HuskDroid", host=None, log=print, probe=False, request_timeout=120, udid=UDID):
    """Attach to `name` on the phone and service its JIT requests until it detaches."""
    if not _session_lock.acquire(timeout=1):
        raise JitError("another JIT session is already running")
    try:
        host = host or await pick_host()
        record = await pair_record(udid)

        async def tcp_lockdown(serial=None, autopair=True, **_):
            return await create_using_tcp(hostname=host, identifier=udid, pair_record=record, autopair=False)

        ut.create_using_usbmux = tcp_lockdown  # the userspace tunnel's only device lookup
        log(f"connecting to the phone at {host}")
        t0 = time.time()
        async with ut.UserspaceRsdTunnel(serial=udid) as rsd:
            conn = await rsd.create_service_connection(rsd.get_service_port(DEBUGPROXY))
            gdb = Gdb(conn)
            await gdb.no_ack()
            log(f"debugserver up in {time.time() - t0:.1f}s")
            if probe:
                log(f"qHostInfo: {(await gdb.send('qHostInfo'))[:80]}")
                return
            await _serve(gdb, name, log, request_timeout)
    finally:
        _session_lock.release()

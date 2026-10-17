"""HuskDroid companion: JIT on request, the app's live logs, and a command queue.

The phone opens every connection (home Wi-Fi or Tailscale), so nothing listens on it.

  app  -> POST /v1/hello              {device, app, state}          note who is connected
       -> POST /v1/jit                {name}                        streamed progress, last line OK/ERROR
       -> POST /v1/logs               text lines                    appended to the log
       -> GET  /v1/next?wait=25       a command (JSON) or 204       long-poll
       -> POST /v1/result/<id>        JSON, or a file (screenshot)  answers a command
       -> GET  /v1/files/<name>       a staged file (APK to install, file to push)
  huskctl (this Mac)
       -> GET  /v1/log?since=N&follow=1
       -> POST /v1/cmd?wait=S         {type, ...}                   queue a command, wait for its result
       -> POST /v1/stage?name=X       file body                     stage a file for the app to fetch
       -> GET  /v1/status
       -> POST /v1/jit                (same as the app's)

Every request carries `Authorization: Bearer <token>`; the token comes from the vault
(perlica-secret run huskdroid.token -- ...), as PERLICA_SECRET.
"""
import asyncio
import collections
import hmac
import itertools
import json
import os
import re
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import huskjit_core  # noqa: E402

PORT = int(os.environ.get("HUSKDROID_PORT", "8790"))
TOKEN = os.environ.get("PERLICA_SECRET", "")
DATA = Path.home() / "Library" / "Logs" / "HuskDroid"
STAGE = DATA / "staged"
SHOTS = DATA / "screenshots"
SAFE_NAME = re.compile(r"^[A-Za-z0-9._ ()+-]{1,200}$")


class Logs:
    """Ring buffer of numbered lines, mirrored to a daily file, with followers."""

    def __init__(self, keep=50000):
        self.lines = collections.deque(maxlen=keep)
        self.next_seq = 0
        self.cond = threading.Condition()

    def add(self, source, text):
        stamp = time.strftime("%H:%M:%S")
        new = [f"{stamp} [{source}] {line}" for line in text.splitlines() if line.strip()]
        if not new:
            return
        with self.cond:
            for line in new:
                self.lines.append((self.next_seq, line))
                self.next_seq += 1
            self.cond.notify_all()
        with open(DATA / time.strftime("huskdroid-%Y%m%d.log"), "a", encoding="utf-8") as f:
            f.write("\n".join(new) + "\n")

    def since(self, seq):
        with self.cond:
            return [(s, l) for s, l in self.lines if s >= seq], self.next_seq

    def wait(self, seq, timeout):
        with self.cond:
            self.cond.wait_for(lambda: self.next_seq > seq, timeout)


class Commands:
    """Commands for the app, and their results."""

    def __init__(self):
        self.queue = collections.deque()
        self.results = {}
        self.ids = itertools.count(1)
        self.cond = threading.Condition()

    def put(self, cmd):
        with self.cond:
            cmd["id"] = str(next(self.ids))
            self.results[cmd["id"]] = None
            self.queue.append(cmd)
            self.cond.notify_all()
            return cmd["id"]

    def take(self, timeout):
        with self.cond:
            self.cond.wait_for(lambda: self.queue, timeout)
            return self.queue.popleft() if self.queue else None

    def answer(self, cid, result):
        with self.cond:
            if cid in self.results:
                self.results[cid] = result
                self.cond.notify_all()
                return True
            return False

    def wait_result(self, cid, timeout):
        with self.cond:
            self.cond.wait_for(lambda: self.results.get(cid) is not None, timeout)
            result = self.results.pop(cid, None)
            # Not yet taken by the app: drop it, so a stale command does not run later.
            self.queue = collections.deque(c for c in self.queue if c["id"] != cid)
            return result


LOGS = Logs()
COMMANDS = Commands()
STATE = {"app": None, "last_seen": None, "address": None}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "HuskDroidCompanion/1"

    def log_message(self, fmt, *args):  # quiet; the useful log is LOGS
        pass

    # --- plumbing -------------------------------------------------------
    def _authorised(self):
        sent = self.headers.get("Authorization", "")
        ok = bool(TOKEN) and hmac.compare_digest(sent, f"Bearer {TOKEN}")
        if not ok:
            self._send(HTTPStatus.UNAUTHORIZED, b"unauthorised\n")
        return ok

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _send(self, status, body=b"", ctype="text/plain; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, obj, status=HTTPStatus.OK):
        self._send(status, json.dumps(obj).encode() + b"\n", "application/json")

    def _stream_start(self, ctype="text/plain; charset=utf-8"):
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", ctype)
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

    def _chunk(self, text):
        data = text.encode()
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()

    def _stream_end(self):
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def _seen(self):
        STATE["last_seen"] = time.time()
        STATE["address"] = self.client_address[0]

    # --- routes ---------------------------------------------------------
    def do_GET(self):
        if not self._authorised():
            return
        url = urlsplit(self.path)
        q = {k: v[-1] for k, v in parse_qs(url.query).items()}
        if url.path == "/v1/next":
            self._seen()
            cmd = COMMANDS.take(min(float(q.get("wait", 25)), 55))
            return self._json(cmd) if cmd else self._send(HTTPStatus.NO_CONTENT)
        if url.path.startswith("/v1/files/"):
            name = url.path.rsplit("/", 1)[1]
            path = STAGE / name
            if not SAFE_NAME.match(name) or not path.is_file():
                return self._send(HTTPStatus.NOT_FOUND, b"no such file\n")
            data = path.read_bytes()
            return self._send(HTTPStatus.OK, data, "application/octet-stream")
        if url.path == "/v1/status":
            age = time.time() - STATE["last_seen"] if STATE["last_seen"] else None
            return self._json({**STATE, "seconds_since_seen": age, "log_lines": LOGS.next_seq})
        if url.path == "/v1/log":
            return self._log(int(q.get("since", -200)), q.get("follow") == "1")
        self._send(HTTPStatus.NOT_FOUND, b"not found\n")

    def do_POST(self):
        if not self._authorised():
            return
        url = urlsplit(self.path)
        q = {k: v[-1] for k, v in parse_qs(url.query).items()}
        if url.path == "/v1/logs":
            self._seen()
            LOGS.add("app", self._body().decode("utf-8", "replace"))
            return self._send(HTTPStatus.NO_CONTENT)
        if url.path == "/v1/hello":
            self._seen()
            STATE["app"] = json.loads(self._body() or b"{}")
            LOGS.add("companion", f"app connected from {self.client_address[0]}: {STATE['app']}")
            return self._json({"companion": 1, "time": time.time()})
        if url.path == "/v1/jit":
            body = json.loads(self._body() or b"{}")
            return self._jit(body.get("name", "HuskDroid"))
        if url.path.startswith("/v1/result/"):
            self._seen()
            cid = url.path.rsplit("/", 1)[1]
            ctype = self.headers.get("Content-Type", "")
            body = self._body()
            if ctype.startswith("application/json"):
                result = json.loads(body or b"{}")
            else:
                SHOTS.mkdir(parents=True, exist_ok=True)
                path = SHOTS / time.strftime(f"%Y%m%d-%H%M%S-{cid}.png")
                path.write_bytes(body)
                result = {"ok": True, "file": str(path), "bytes": len(body)}
            known = COMMANDS.answer(cid, result)
            return self._send(HTTPStatus.NO_CONTENT if known else HTTPStatus.GONE)
        if url.path == "/v1/cmd":
            cmd = json.loads(self._body() or b"{}")
            if not isinstance(cmd, dict) or "type" not in cmd:
                return self._json({"ok": False, "error": "need {type: ...}"}, HTTPStatus.BAD_REQUEST)
            cid = COMMANDS.put(cmd)
            result = COMMANDS.wait_result(cid, float(q.get("wait", 60)))
            if result is None:
                return self._json({"ok": False, "error": "the app did not answer (is it open and linked?)"},
                                  HTTPStatus.GATEWAY_TIMEOUT)
            return self._json(result)
        if url.path == "/v1/stage":
            name = q.get("name", "")
            if not SAFE_NAME.match(name):
                return self._json({"ok": False, "error": "bad name"}, HTTPStatus.BAD_REQUEST)
            STAGE.mkdir(parents=True, exist_ok=True)
            (STAGE / name).write_bytes(self._body())
            return self._json({"ok": True, "name": name})
        self._send(HTTPStatus.NOT_FOUND, b"not found\n")

    def _log(self, since, follow):
        if since < 0:
            since = max(0, LOGS.next_seq + since)
        self._stream_start()
        try:
            while True:
                lines, nxt = LOGS.since(since)
                if lines:
                    self._chunk("".join(l + "\n" for _, l in lines))
                since = nxt
                if not follow:
                    break
                LOGS.wait(since, 15)
        except (BrokenPipeError, ConnectionResetError):
            return
        self._stream_end()

    def _jit(self, name):
        self._stream_start()

        def say(line):
            LOGS.add("jit", line)
            try:
                self._chunk(line + "\n")
            except (BrokenPipeError, ConnectionResetError):
                pass

        try:
            asyncio.run(huskjit_core.grant(name=name, log=say))
            say("OK")
        except huskjit_core.JitError as e:
            say(f"ERROR: {e}")
        except Exception as e:  # noqa: BLE001 -- anything else must still end the stream readably
            say(f"ERROR: {type(e).__name__}: {e}")
        try:
            self._stream_end()
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    if not TOKEN:
        sys.exit("no token: run under `perlica-secret run huskdroid.token -- ...`")
    DATA.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    LOGS.add("companion", f"listening on :{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()

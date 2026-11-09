#!/usr/bin/env python3
"""HA Failover Primary: tiny HTTPS API for the standby node.

GET  /v1/ping      -> "ok" (auth required, used for pairing checks)
GET  /v1/health    -> JSON from export.sh health
GET  /v1/snapshot  -> tar stream from export.sh export (one at a time)
POST /v1/notify-return-ok -> fixed push to the configured targets

Every request needs "Authorization: Bearer <token>" and a source address from allowed_sources.
No request parameter is ever passed to a shell: the three export.sh calls are fixed.
"""
import hmac
import ipaddress
import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ssl

OPTIONS = json.load(open("/data/options.json"))
TOKEN = open("/data/token").read().strip()
PORT = int(OPTIONS.get("port", 8765))
ALLOWED = []
for item in OPTIONS.get("allowed_sources", []):
    try:
        ALLOWED.append(ipaddress.ip_network(item.strip(), strict=False))
    except ValueError:
        print(f"ignoring invalid allowed_sources entry: {item!r}", flush=True)
EXPORT_LOCK = threading.Lock()
FAIL_DELAY = 1.0


def log(msg):
    print(time.strftime("[%Y-%m-%d %H:%M:%S] ") + msg, flush=True)


def source_allowed(addr):
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return any(ip in net for net in ALLOWED)


class Handler(BaseHTTPRequestHandler):
    server_version = "ha-failover-primary"
    sys_version = ""
    protocol_version = "HTTP/1.1"  # snapshot uses chunked encoding: a cut stream is an error for the client
    timeout = 60  # per socket operation

    def log_message(self, fmt, *args):  # quiet default access log, we log ourselves
        pass

    def reply(self, code, body=b"", ctype="text/plain; charset=utf-8"):
        self.close_connection = True
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def authorized(self):
        src = self.client_address[0]
        if not source_allowed(src):
            log(f"refused {self.command} {self.path} from {src}: source not allowed")
            time.sleep(FAIL_DELAY)
            self.reply(403, b"forbidden\n")
            return False
        auth = self.headers.get("Authorization", "")
        if not (auth.startswith("Bearer ") and hmac.compare_digest(auth[7:].strip().encode(), TOKEN.encode())):
            log(f"refused {self.command} {self.path} from {src}: bad token")
            time.sleep(FAIL_DELAY)
            self.reply(401, b"unauthorized\n")
            return False
        return True

    def run_export(self, request, timeout):
        return subprocess.run(["/export.sh", request], capture_output=True, timeout=timeout)

    def do_GET(self):
        if not self.authorized():
            return
        if self.path == "/v1/ping":
            self.reply(200, b"ok\n")
        elif self.path == "/v1/health":
            try:
                r = self.run_export("health", 90)
            except subprocess.TimeoutExpired:
                return self.reply(504, b"health timeout\n")
            self.reply(200 if r.returncode == 0 else 500, r.stdout or r.stderr[-400:], "application/json")
        elif self.path == "/v1/snapshot":
            self.snapshot()
        else:
            self.reply(404, b"not found\n")

    def do_POST(self):
        if not self.authorized():
            return
        if self.path == "/v1/notify-return-ok":
            try:
                r = self.run_export("notify-return-ok", 60)
            except subprocess.TimeoutExpired:
                return self.reply(504, b"notify timeout\n")
            log(f"notify-return-ok: {r.stdout.decode(errors='replace').strip()}")
            self.reply(200 if r.returncode == 0 else 500, r.stdout or r.stderr[-400:])
        else:
            self.reply(404, b"not found\n")

    def snapshot(self):
        if not EXPORT_LOCK.acquire(blocking=False):
            return self.reply(429, b"snapshot already running\n")
        started = time.time()
        proc = None
        try:
            proc = subprocess.Popen(["/export.sh", "export"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            first = proc.stdout.read(65536)
            if not first:  # export failed before producing data: report a real error, not an empty 200
                proc.wait(timeout=60)
                err = proc.stderr.read()[-400:]
                log(f"snapshot FAILED rc={proc.returncode}: {err.decode(errors='replace').strip()}")
                return self.reply(500, err or b"export failed\n")
            self.close_connection = True
            self.send_response(200)
            self.send_header("Content-Type", "application/x-tar")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            size = 0
            for chunk in iter_chunks(first, proc):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                size += len(chunk)
            rc = proc.wait(timeout=900)
            if rc == 0:
                self.wfile.write(b"0\r\n\r\n")  # only a complete export gets the final chunk
            else:  # no final chunk: the client sees a truncated transfer and fails
                err = proc.stderr.read()[-400:].decode(errors="replace").strip()
                log(f"snapshot FAILED after start rc={rc}: {err}")
            self.wfile.flush()
            log(f"snapshot to {self.client_address[0]}: {size // 1024} KiB in {time.time() - started:.0f}s, rc={rc}")
        except (BrokenPipeError, ConnectionResetError):
            log("snapshot: client went away")
        except subprocess.TimeoutExpired:
            log("snapshot: export timeout")
        finally:
            if proc and proc.poll() is None:
                proc.kill()
            EXPORT_LOCK.release()


def iter_chunks(first, proc):
    yield first
    yield from iter(lambda: proc.stdout.read(65536), b"")


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def verify_request(self, request, client_address):
        # refuse foreign sources before the TLS handshake (accept() does not handshake, see main)
        if source_allowed(client_address[0]):
            return True
        log(f"refused connection from {client_address[0]}: source not allowed")
        return False

    def handle_error(self, request, client_address):
        log(f"connection error from {client_address[0]}: {sys.exc_info()[1]!r}")


def main():
    if not ALLOWED:
        log("WARNING: allowed_sources is empty, every request will be refused")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain("/data/cert.pem", "/data/key.pem")
    srv = Server(("0.0.0.0", PORT), Handler)
    # handshake happens on the first read inside the request thread, so a slow client cannot block accept()
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
    log(f"listening on https port {PORT}, allowed sources: {', '.join(map(str, ALLOWED)) or 'none'}")
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Store an OpenRouter API key once, so no session ever asks again.

Default: OAuth PKCE. A server on 127.0.0.1:<free port> waits for the
callback, the browser opens https://openrouter.ai/auth, the code is
exchanged at /api/v1/auth/keys, the key is checked at /api/v1/key and
written through lib/keys.set. The same server serves a paste page for the
case where the callback cannot reach this machine (a Windows browser that
does not forward to WSL2, a remote box): GET /paste?t=<nonce> shows one
field, its POST goes through the same check-and-store path.

    --tty            read the key from a hidden prompt (or from a piped
                     stdin) instead of serving anything; for headless use
    --timeout N      seconds to wait for the callback or the paste (600)
    --no-browser     print the URLs, open nothing

stderr gets one JSON line with `url`, `paste_url` and `browser_opened` so
the person can open the link by hand. stdout gets one JSON line when it is
over: {"status": "stored"|"rejected"|"timed_out", ...}. The key itself is
never printed. Exit: 0 stored, 1 rejected, 2 timed out, 3 usage.
OPENROUTER_BASE_URL redirects both the auth page and the API (tests).
"""

import argparse
import base64
import getpass
import hashlib
import html
import json
import os
import secrets
import socketserver
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from lib import keys  # noqa: E402

KEY_NAME = "OPENROUTER_API_KEY"
KEY_LABEL = "clouter"
HTTP_TIMEOUT = 15.0

PAGE = """<!doctype html><meta charset="utf-8"><title>clouter · OpenRouter key</title>
<style>body{{font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem}}
input{{width:100%;padding:.5rem;font-size:1rem}}button{{padding:.5rem 1rem;font-size:1rem;margin-top:.75rem}}
code{{background:#eee;padding:0 .25rem}}</style>
<h1>{title}</h1>{body}"""


def base_url():
    return (os.environ.get("OPENROUTER_BASE_URL") or "https://openrouter.ai").rstrip("/")


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def api(method, path, key=None, body=None):
    """One call to OpenRouter. Returns (status, parsed JSON or text)."""
    headers = {"Accept": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    request = urllib.request.Request(base_url() + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    except (urllib.error.URLError, OSError) as e:
        return None, f"unreachable: {e.reason if hasattr(e, 'reason') else e}"
    try:
        return status, json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return status, raw.decode("utf-8", "replace")[:200]


def error_text(status, body):
    if status is None:
        return str(body)
    if isinstance(body, dict):
        error = body.get("error")
        if isinstance(error, dict) and error.get("message"):
            return f"{status}: {error['message']}"
    return f"{status}: {str(body)[:200]}"


def check_and_store(key):
    """Verify the key at GET /api/v1/key, then write it. Returns (ok, reason)."""
    key = key.strip()
    if not key:
        return False, "empty key"
    status, body = api("GET", "/api/v1/key", key=key)
    if status != 200:
        return False, "key check failed, " + error_text(status, body)
    path = keys.set(KEY_NAME, key)
    return True, path


def exchange(code, verifier):
    """Trade the callback code for a key. Returns (key or None, reason)."""
    status, body = api("POST", "/api/v1/auth/keys", body={
        "code": code, "code_verifier": verifier, "code_challenge_method": "S256"})
    if status != 200:
        return None, "exchange failed, " + error_text(status, body)
    if not isinstance(body, dict) or not isinstance(body.get("key"), str):
        return None, "exchange answered without a key"
    return body["key"], "ok"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def page(self, status, title, body):
        out = PAGE.format(title=html.escape(title), body=body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(out)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(out)

    def finish_with(self, ok, reason, via):
        if ok:
            self.server.result = {"status": "stored", "via": via, "path": reason}
            self.page(200, "Done", "<p>The key is stored. You can close this tab.</p>")
        else:
            self.server.result = {"status": "rejected", "via": via, "reason": reason}
            self.page(400, "Rejected", f"<p>{html.escape(reason)}</p>"
                      "<p>Close this tab and run the setup again.</p>")

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path == "/callback":
            code = (query.get("code") or [""])[0]
            if not code:
                self.finish_with(False, "callback without a code", "oauth")
                return
            key, reason = exchange(code, self.server.verifier)
            if key is None:
                self.finish_with(False, reason, "oauth")
                return
            self.finish_with(*check_and_store(key), "oauth")
        elif url.path == "/paste" and (query.get("t") or [""])[0] == self.server.nonce:
            self.page(200, "Paste your OpenRouter key", (
                '<form method="post" action="/paste">'
                f'<input type="hidden" name="t" value="{self.server.nonce}">'
                '<p><input type="password" name="key" autofocus autocomplete="off" '
                'placeholder="sk-or-v1-…"></p><button>Store</button></form>'
                '<p>Keys: <code>openrouter.ai/settings/keys</code></p>'))
        else:
            self.page(404, "Not here", "<p>Nothing at this address.</p>")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
        if self.path != "/paste" or (form.get("t") or [""])[0] != self.server.nonce:
            self.page(404, "Not here", "<p>Nothing at this address.</p>")
            return
        self.finish_with(*check_and_store((form.get("key") or [""])[0]), "paste")


def launch_browser(url):
    """webbrowser.open() with the browser's own stdout and stderr sent to
    /dev/null, so its log noise never lands next to our JSON lines."""
    saved = [os.dup(1), os.dup(2)]
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
        return bool(webbrowser.open(url))
    except Exception:
        return False
    finally:
        os.dup2(saved[0], 1)
        os.dup2(saved[1], 2)
        for fd in saved + [devnull]:
            os.close(fd)


class LocalServer(HTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind reverse-resolves the host (socket.getfqdn),
        # which takes ~35s on a Mac with slow DNS.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def serve(timeout, open_browser):
    verifier = b64url(secrets.token_bytes(32))
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    nonce = secrets.token_urlsafe(16)

    server = LocalServer(("127.0.0.1", 0), Handler)
    server.verifier, server.nonce, server.result = verifier, nonce, None
    server.timeout = 0.5
    port = server.server_port
    callback = f"http://127.0.0.1:{port}/callback"
    auth_url = base_url() + "/auth?" + urllib.parse.urlencode({
        "callback_url": callback,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "key_label": KEY_LABEL,
    })
    paste_url = f"http://127.0.0.1:{port}/paste?t={nonce}"

    opened = open_browser and launch_browser(auth_url)
    print(json.dumps({"url": auth_url, "paste_url": paste_url,
                      "browser_opened": opened, "port": port}), file=sys.stderr, flush=True)

    deadline = time.monotonic() + timeout
    try:
        while server.result is None and time.monotonic() < deadline:
            server.handle_request()
    finally:
        server.server_close()
    return server.result or {"status": "timed_out", "after": timeout}


def from_tty():
    if sys.stdin.isatty():
        key = getpass.getpass("OpenRouter API key (hidden): ")
    else:
        key = sys.stdin.readline()
    ok, reason = check_and_store(key)
    if ok:
        return {"status": "stored", "via": "tty", "path": reason}
    return {"status": "rejected", "via": "tty", "reason": reason}


def main(argv):
    parser = argparse.ArgumentParser(description="Store an OpenRouter API key once.")
    parser.add_argument("--tty", action="store_true", help="prompt instead of serving")
    parser.add_argument("--timeout", type=float, default=600.0, help="seconds to wait (600)")
    parser.add_argument("--no-browser", action="store_true", help="print the URLs, open nothing")
    args = parser.parse_args(argv[1:])
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    try:
        result = from_tty() if args.tty else serve(args.timeout, not args.no_browser)
    except keys.UnsafeFile as e:
        result = {"status": "rejected", "reason": str(e)}
    print(json.dumps(result), flush=True)
    return {"stored": 0, "rejected": 1, "timed_out": 2}[result["status"]]


if __name__ == "__main__":
    sys.exit(main(sys.argv))

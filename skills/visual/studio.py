#!/usr/bin/env python3
"""Clouter studio: a localhost page where the user steers each round.

    studio.py serve  --session <dir> [--no-open] [--idle-minutes 30]
    studio.py push   --session <dir> --file <path> --model <id> --cost <usd>
                     --brief-file <path> [--defects-file <json>] [--message-file <path>]
                     [--parent <n>] [--request-file <path>] [--modality <m>]
    studio.py wait   --session <dir> [--timeout <seconds>]
    studio.py stop   --session <dir>
    studio.py status --session <dir>

Claude drives the loop: `push` copies a generated file into the session
as the next round and makes sure a server is running; `wait` blocks
until the user sends feedback or accepts in the browser. --session
defaults to $CLOUTER_STUDIO_DIR; `push` without either creates
~/.cache/clouter/studio/<session-id>.

Session directory:

    <dir>/session.json   state, rewritten atomically (tmp file + os.replace)
    <dir>/server.json    {"port", "pid", "url"} while a server runs
    <dir>/rounds/round-<n>.<ext>   round media
    <dir>/uploads/<kind>-<uuid>.png  annotation layers and frame captures
    <dir>/server.log     stdout/stderr of a server started by `push`

Every read-modify-write of session.json holds <dir>/session.lock
(fcntl.flock; msvcrt.locking on Windows) so the server and a `wait` in another process never lose
each other's writes.

The server binds 127.0.0.1 on a free port (ThreadingHTTPServer) and
serves the page from studio/ next to this file (index.html at /, the
rest under /static/, whitelisted names only), GET /api/session,
GET /events (SSE: `event: session` with the full session on connect and
on every change of session.json, polled every 0.5 s; `: ping` every
15 s), GET /files/<relpath> (only under rounds/ or uploads/, anything
else 404), POST /api/upload?kind=annotation|frame (raw PNG, max 20 MB),
POST /api/feedback (accepts an optional "model" id for the next round),
POST /api/accept, POST /api/models {"round": n} (202, asks
critique.model_options in a background thread for alternative generator
models and stores them on the round; 409 while one is already pending)
and GET /api/catalogue (every catalogue model for the session's
modality, cached in memory for 10 minutes). JSON errors are
{"error": "..."} with a 4xx status. The server exits after
--idle-minutes without an SSE client, or 60 s after an accept, and
removes server.json on exit.

`serve` opens the page in a browser unless --no-open: on WSL (detected
via /proc/version) `wslview`, then `explorer.exe`, else the webbrowser
module; a failure to open never stops the server. `push` passes
--no-open through when CLOUTER_STUDIO_NO_OPEN=1.

`push` prints {"round": n, "url": "...", "session": "<dir>"}. `wait`
prints the oldest unconsumed feedback entry (marked consumed) with
annotation, markers[].frame and "round_file" as absolute paths. If
there is no unconsumed entry but the session state is "accepted" (the
accept was already consumed by an earlier `wait`), it reprints the
most recent accept entry instead of blocking, so a lost first result
doesn't hang a retry until --timeout. Exit codes of `wait`: 0
feedback, 10 accept, 20 timeout, 30 server gone (server.json missing
or its pid dead, and nothing pending). Every verb exits 2 on bad
arguments, errors on stderr. Stdlib only.
"""

import argparse
import contextlib
import datetime
import http.server
import json
import mimetypes
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
import webbrowser

try:
    import fcntl
except ImportError:  # Windows
    fcntl = None
    import msvcrt

# Popen kwargs that detach a child from this process's session/console.
DETACH = ({"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP}
          if os.name == "nt" else {"start_new_session": True})

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(HERE, "studio")
STATIC_FILES = ("index.html", "studio.css", "app.js", "editor.js", "timeline.js")
MODALITIES = ("raster_image", "vector_svg", "video", "speech")
UPLOAD_KINDS = ("annotation", "frame")
MAX_UPLOAD = 20 * 1024 * 1024
MAX_JSON = 1024 * 1024
CATALOGUE_TTL_SECONDS = 600
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
POLL_SECONDS = 0.5
PING_SECONDS = 15
ACCEPT_GRACE_SECONDS = 60
SERVER_START_SECONDS = 5

# media type -> extension of the copied round file
MEDIA_EXT = {
    "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp",
    "image/svg+xml": "svg", "video/mp4": "mp4", "video/webm": "webm",
    "audio/mpeg": "mp3", "audio/wav": "wav", "audio/ogg": "ogg",
}
EXT_MEDIA = {ext: media for media, ext in MEDIA_EXT.items()}
EXT_MEDIA.update({"jpeg": "image/jpeg", "oga": "audio/ogg"})
STATIC_TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
                ".js": "text/javascript; charset=utf-8"}


class UsageError(Exception):
    """Bad arguments or input files: exit 2."""


# --- session directory ------------------------------------------------------

def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def session_path(d):
    return os.path.join(d, "session.json")


def server_path(d):
    return os.path.join(d, "server.json")


_thread_lock = threading.Lock()


@contextlib.contextmanager
def locked(d):
    """Serialise read-modify-writes of session.json across threads and processes."""
    with _thread_lock:
        with open(os.path.join(d, "session.lock"), "a") as fh:
            _lock(fh)
            try:
                yield
            finally:
                _unlock(fh)


def _lock(fh):
    if fcntl:
        fcntl.flock(fh, fcntl.LOCK_EX)
        return
    fh.seek(0)
    while True:  # LK_LOCK gives up after ~10s; keep waiting, as flock does
        try:
            msvcrt.locking(fh.fileno(), msvcrt.LK_LOCK, 1)
            return
        except OSError:
            continue


def _unlock(fh):
    if fcntl:
        fcntl.flock(fh, fcntl.LOCK_UN)
        return
    fh.seek(0)
    msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)


def write_json_atomic(path, data):
    tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


def load_session(d):
    with open(session_path(d), encoding="utf-8") as fh:
        return json.load(fh)


def save_session(d, session):
    write_json_atomic(session_path(d), session)


def read_server(d):
    try:
        with open(server_path(d), encoding="utf-8") as fh:
            info = json.load(fh)
        return info if isinstance(info.get("pid"), int) else None
    except (OSError, ValueError, AttributeError):
        return None


def pid_alive(pid):
    if os.name == "nt":
        return _pid_alive_windows(pid)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A zombie child (only possible for our own children) counts as dead.
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as fh:
            return fh.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return True


def running_server(d):
    info = read_server(d)
    return info if info and pid_alive(info["pid"]) else None


def inside(path, root):
    """True when realpath(path) lies under realpath(root)."""
    real, base = os.path.realpath(path), os.path.realpath(root)
    return real != base and os.path.commonpath([real, base]) == base


def upload_ok(d, rel):
    """rel is an existing file under <d>/uploads, written as 'uploads/...'."""
    return (isinstance(rel, str) and rel.startswith("uploads/")
            and inside(os.path.join(d, rel), os.path.join(d, "uploads"))
            and os.path.isfile(os.path.join(d, rel)))


def guess_media_type(path):
    with open(path, "rb") as fh:
        head = fh.read(512)
    if head.startswith(PNG_SIGNATURE):
        return "image/png"
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    if head[:4] == b"RIFF" and head[8:12] == b"WAVE":
        return "audio/wav"
    if head.startswith(b"OggS"):
        return "audio/ogg"
    if head.startswith(b"\x1a\x45\xdf\xa3"):
        return "video/webm"
    if head[4:8] == b"ftyp":
        return "video/mp4"
    if head.startswith(b"ID3") or head[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2"):
        return "audio/mpeg"
    if b"<svg" in head:
        return "image/svg+xml"
    ext = os.path.splitext(path)[1].lower().lstrip(".")
    return EXT_MEDIA.get(ext)


def content_type(path):
    ext = os.path.splitext(path)[1].lower().lstrip(".")
    return EXT_MEDIA.get(ext) or mimetypes.guess_type(path)[0] or "application/octet-stream"


# --- lazy imports of critique.py/catalogue.py --------------------------------
# Deferred to the handlers that need them, so `push`/`wait`/`stop`/`status`
# stay fast and never need an API key.

def _import_critique():
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    import critique
    return critique


def _import_catalogue():
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    import catalogue
    return catalogue


# --- server -----------------------------------------------------------------

class Studio:
    """Shared server state: the session dir, change notification, liveness."""

    def __init__(self, d, idle_minutes):
        self.dir = d
        self.idle_seconds = idle_minutes * 60
        self.cond = threading.Condition()
        self.version = 0
        self.clients = 0
        self.last_client = time.monotonic()
        self.accepted_at = None
        self.stopping = threading.Event()
        self.mtime = self._mtime()
        self.catalogue_lock = threading.Lock()
        self.catalogue_cache = None  # (modality, expiry_monotonic, entries) or None

    def _mtime(self):
        try:
            return os.stat(session_path(self.dir)).st_mtime_ns
        except OSError:
            return None

    def changed(self):
        with self.cond:
            self.version += 1
            self.cond.notify_all()

    def client(self, delta):
        with self.cond:
            self.clients += delta
            self.last_client = time.monotonic()

    def watch(self, httpd):
        """Poll session.json for changes (from `wait`/`push` too) and decide when to exit."""
        while not self.stopping.wait(POLL_SECONDS):
            mtime = self._mtime()
            if mtime != self.mtime:
                self.mtime = mtime
                self.changed()
            try:
                state = load_session(self.dir).get("state")
            except (OSError, ValueError):
                state = None
            now = time.monotonic()
            if state == "accepted":
                self.accepted_at = self.accepted_at or now
            else:
                self.accepted_at = None
            with self.cond:
                idle = self.clients == 0 and now - self.last_client >= self.idle_seconds
            if idle or (self.accepted_at and now - self.accepted_at >= ACCEPT_GRACE_SECONDS):
                break
        self.stop(httpd)

    def stop(self, httpd):
        if not self.stopping.is_set():
            self.stopping.set()
        with self.cond:
            self.cond.notify_all()
        threading.Thread(target=httpd.shutdown, daemon=True).start()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "clouter-studio"
    studio = None  # set by serve()

    def log_message(self, fmt, *args):
        sys.stderr.write("studio: %s %s\n" % (self.address_string(), fmt % args))

    # -- responses

    def send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status, message):
        self.send_json({"error": message}, status)

    def send_file(self, path, ctype):
        size = os.path.getsize(path)
        start, end = 0, size - 1
        status = 200
        rng = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range", "").strip())
        if rng and size and (rng.group(1) or rng.group(2)):
            if rng.group(1):
                start = int(rng.group(1))
                end = min(int(rng.group(2)), size - 1) if rng.group(2) else size - 1
            else:
                start = max(0, size - int(rng.group(2)))
            if start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(end - start + 1 if size else 0))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(path, "rb") as fh:
            fh.seek(start)
            left = end - start + 1 if size else 0
            while left > 0:
                chunk = fh.read(min(65536, left))
                if not chunk:
                    break
                self.wfile.write(chunk)
                left -= len(chunk)

    # -- GET

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        path = url.path
        try:
            if path in ("/", "/index.html"):
                return self.get_static("index.html")
            if path.startswith("/static/"):
                return self.get_static(path[len("/static/"):])
            if path == "/api/session":
                return self.send_json(load_session(self.studio.dir))
            if path == "/api/catalogue":
                return self.get_catalogue()
            if path == "/events":
                return self.get_events()
            if path.startswith("/files/"):
                return self.get_file(urllib.parse.unquote(path[len("/files/"):]))
        except (BrokenPipeError, ConnectionResetError):
            return None
        except (OSError, ValueError) as e:
            return self.send_error_json(500, f"cannot read session: {e}")
        return self.send_error_json(404, "not found")

    def get_static(self, name):
        if name not in STATIC_FILES:
            return self.send_error_json(404, "not found")
        path = os.path.join(STATIC_DIR, name)
        if not os.path.isfile(path):
            return self.send_error_json(404, "not found")
        return self.send_file(path, STATIC_TYPES[os.path.splitext(name)[1]])

    def get_file(self, rel):
        d = self.studio.dir
        full = os.path.join(d, rel)
        ok = (rel and not os.path.isabs(rel) and "\x00" not in rel
              and (inside(full, os.path.join(d, "rounds")) or inside(full, os.path.join(d, "uploads")))
              and os.path.isfile(full))
        if not ok:
            return self.send_error_json(404, "not found")
        return self.send_file(os.path.realpath(full), content_type(full))

    def get_catalogue(self):
        studio = self.studio
        try:
            modality = load_session(studio.dir).get("modality")
        except (OSError, ValueError) as e:
            return self.send_error_json(500, f"cannot read session: {e}")
        with studio.catalogue_lock:
            cached = studio.catalogue_cache
            if cached and cached[0] == modality and time.monotonic() < cached[1]:
                return self.send_json({"models": cached[2]})
        catalogue = _import_catalogue()
        try:
            found = catalogue.models(modality)
        except catalogue.CatalogueError as e:
            return self.send_error_json(502, str(e))
        entries = sorted(
            ({"id": e["id"], "name": e["name"], "price": e["price"], "unit": e["unit"],
              "reference_supported": bool(e.get("reference_supported"))} for e in found),
            key=lambda e: (e["price"] is None, e["price"] if e["price"] is not None else 0.0))
        with studio.catalogue_lock:
            studio.catalogue_cache = (modality, time.monotonic() + CATALOGUE_TTL_SECONDS, entries)
        return self.send_json({"models": entries})

    def get_events(self):
        studio = self.studio
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        studio.client(+1)
        try:
            with studio.cond:
                seen = studio.version
            self.send_event()
            while not studio.stopping.is_set():
                with studio.cond:
                    studio.cond.wait_for(lambda: studio.version != seen or studio.stopping.is_set(),
                                         timeout=PING_SECONDS)
                    fresh = studio.version != seen
                    seen = studio.version
                if studio.stopping.is_set():
                    break
                if fresh:
                    self.send_event()
                else:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            studio.client(-1)
            self.close_connection = True

    def send_event(self):
        try:
            data = json.dumps(load_session(self.studio.dir))
        except (OSError, ValueError):
            return
        self.wfile.write(f"event: session\ndata: {data}\n\n".encode("utf-8"))
        self.wfile.flush()

    # -- POST

    def do_POST(self):
        url = urllib.parse.urlsplit(self.path)
        try:
            if url.path == "/api/upload":
                return self.post_upload(urllib.parse.parse_qs(url.query))
            if url.path == "/api/feedback":
                return self.post_entry("feedback")
            if url.path == "/api/accept":
                return self.post_entry("accept")
            if url.path == "/api/models":
                return self.post_models()
        except (BrokenPipeError, ConnectionResetError):
            return None
        return self.send_error_json(404, "not found")

    def content_length(self, limit):
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.send_error_json(411, "Content-Length required")
            return None
        if length < 0 or length > limit:
            self.close_connection = True
            self.send_error_json(413, f"body larger than {limit} bytes")
            return None
        return length

    def post_upload(self, query):
        kind = (query.get("kind") or [""])[0]
        if kind not in UPLOAD_KINDS:
            return self.send_error_json(400, "kind must be annotation or frame")
        length = self.content_length(MAX_UPLOAD)
        if length is None:
            return None
        body = self.rfile.read(length)
        if len(body) != length or not body.startswith(PNG_SIGNATURE):
            return self.send_error_json(400, "body is not a PNG")
        rel = f"uploads/{kind}-{uuid.uuid4().hex}.png"
        uploads = os.path.join(self.studio.dir, "uploads")
        os.makedirs(uploads, exist_ok=True)
        tmp = os.path.join(uploads, f".{uuid.uuid4().hex}.tmp")
        with open(tmp, "wb") as fh:
            fh.write(body)
        os.replace(tmp, os.path.join(self.studio.dir, rel))
        return self.send_json({"path": rel})

    def post_entry(self, action):
        length = self.content_length(MAX_JSON)
        if length is None:
            return None
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self.send_error_json(400, "body is not JSON")
        if not isinstance(body, dict):
            return self.send_error_json(400, "body must be a JSON object")
        d = self.studio.dir
        with self.studio.catalogue_lock:
            cached = self.studio.catalogue_cache
        catalogue_ids = {m["id"] for m in cached[2]} if cached else None
        with locked(d):
            session = load_session(d)
            try:
                entry = build_entry(d, session, action, body, catalogue_ids=catalogue_ids)
            except ValueError as e:
                return self.send_error_json(400, str(e))
            session.setdefault("feedback", []).append(entry)
            session["state"] = "feedback" if action == "feedback" else "accepted"
            save_session(d, session)
        self.studio.changed()
        return self.send_json({"id": entry["id"]})

    def post_models(self):
        length = self.content_length(MAX_JSON)
        if length is None:
            return None
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self.send_error_json(400, "body is not JSON")
        if not isinstance(body, dict):
            return self.send_error_json(400, "body must be a JSON object")
        d = self.studio.dir
        with locked(d):
            session = load_session(d)
            rounds = {r.get("n") for r in session.get("rounds", [])}
            n = body.get("round")
            if isinstance(n, bool) or not isinstance(n, int) or n not in rounds:
                return self.send_error_json(400, "round must be an existing round number")
            pending = session.get("models_request")
            if pending and pending.get("status") == "pending":
                return self.send_error_json(409, "a model suggestion request is already pending")
            session["models_request"] = {"round": n, "status": "pending"}
            save_session(d, session)
        self.studio.changed()
        threading.Thread(target=run_model_options, args=(d, self.studio, n), daemon=True).start()
        return self.send_json({"status": "pending"}, 202)


def run_model_options(d, studio, n):
    """Background thread body for POST /api/models: rank alternative generator
    models for round n and write them to session.json, notifying over SSE."""
    critique = _import_critique()
    try:
        with locked(d):
            session = load_session(d)
        round_ = next((r for r in session.get("rounds", []) if r.get("n") == n), {})
        exclude = {r.get("model") for r in session.get("rounds", []) if r.get("model")}
        key = critique.keys.get("OPENROUTER_API_KEY")  # raises MissingKey/UnsafeFile
        found = critique.model_options(
            session.get("modality"), round_.get("brief") or "", request=session.get("request"),
            defects=round_.get("defects"), exclude=exclude, key=key)
    except Exception as e:  # noqa: BLE001 - any failure is reported to the page, never crashes the thread
        error = str(e)
        if isinstance(e, critique.keys.UnsafeFile):
            error = ("The OpenRouter credentials file has unsafe permissions. "
                      "Run /clouter:visual setup in Claude Code to store the key again.")
        elif isinstance(e, critique.keys.MissingKey):
            error = ("No OpenRouter key stored. Run /clouter:visual setup in Claude Code, "
                      "then try again.")
        with locked(d):
            session = load_session(d)
            session["models_request"] = {"round": n, "status": "error", "error": error}
            save_session(d, session)
        studio.changed()
        return
    with locked(d):
        session = load_session(d)
        for r in session.get("rounds", []):
            if r.get("n") == n:
                r["models"] = found
                break
        session["models_request"] = {"round": n, "status": "done"}
        save_session(d, session)
    studio.changed()


def build_entry(d, session, action, body, catalogue_ids=None):
    """Validate a POSTed feedback/accept body into a feedback entry; ValueError on bad input."""
    rounds = {r.get("n") for r in session.get("rounds", [])}

    def round_ref(key, required):
        value = body.get(key)
        if value is None and not required:
            return None
        if isinstance(value, bool) or not isinstance(value, int) or value not in rounds:
            raise ValueError(f"{key} must be an existing round number")
        return value

    def upload_ref(value, what):
        if value is None:
            return None
        if not upload_ok(d, value):
            raise ValueError(f"{what} must be an uploaded file under uploads/")
        return value

    def number(value, what):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"{what} must be a number")
        return value

    text = body.get("text") or ""
    if not isinstance(text, str):
        raise ValueError("text must be a string")
    accepted = body.get("accepted_defects") or []
    if not isinstance(accepted, list) or not all(isinstance(x, str) for x in accepted):
        raise ValueError("accepted_defects must be a list of defect ids")
    notes = body.get("notes") or []
    if not isinstance(notes, list) or not all(isinstance(x, dict) for x in notes):
        raise ValueError("notes must be a list of objects")
    notes = [{"n": note.get("n", i + 1), "x": number(note.get("x"), "notes[].x"),
              "y": number(note.get("y"), "notes[].y"), "text": str(note.get("text") or "")}
             for i, note in enumerate(notes)]
    markers = body.get("markers") or []
    if not isinstance(markers, list) or not all(isinstance(x, dict) for x in markers):
        raise ValueError("markers must be a list of objects")
    markers = [{"t": number(m.get("t"), "markers[].t"), "text": str(m.get("text") or ""),
                "frame": upload_ref(m.get("frame"), "markers[].frame")} for m in markers]
    model = body.get("model")
    if model is not None:
        if not isinstance(model, str) or not (1 <= len(model) <= 200):
            raise ValueError("model must be a string of 1 to 200 characters")
        if catalogue_ids is not None and model not in catalogue_ids:
            raise ValueError("model must be a known catalogue model id")
    ids = [e.get("id", 0) for e in session.get("feedback", []) if isinstance(e.get("id"), int)]
    return {
        "id": max(ids, default=0) + 1,
        "round": round_ref("round", True),
        "action": action,
        "branch_from": round_ref("branch_from", False),
        "text": text,
        "accepted_defects": accepted,
        "notes": notes,
        "markers": markers,
        "annotation": upload_ref(body.get("annotation"), "annotation"),
        "model": model,
        "created": now_iso(),
        "consumed": False,
    }


def _pid_alive_windows(pid):
    """os.kill(pid, 0) on Windows sends CTRL_C_EVENT, so ask the kernel."""
    import ctypes
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return ctypes.get_last_error() == 5  # ERROR_ACCESS_DENIED: exists, not ours
    try:
        code = ctypes.c_ulong()
        return bool(kernel32.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259  # STILL_ACTIVE
    finally:
        kernel32.CloseHandle(handle)


def open_browser(url):
    """Best effort; never raises."""
    try:
        with open("/proc/version", encoding="utf-8") as fh:
            wsl = "microsoft" in fh.read().lower()
    except OSError:
        wsl = False
    if wsl:
        for cmd in (["wslview", url], ["explorer.exe", url]):
            try:
                subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **DETACH)
                return
            except OSError:
                continue
    try:
        webbrowser.open(url)
    except Exception as e:  # noqa: BLE001 - any browser failure is non-fatal
        print(f"studio: could not open a browser: {e}", file=sys.stderr)


def serve(d, no_open, idle_minutes):
    if not os.path.isfile(session_path(d)):
        raise UsageError(f"no session at {d}")
    studio = Studio(d, idle_minutes)
    handler = type("StudioHandler", (Handler,), {"studio": studio})
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    httpd.daemon_threads = True
    httpd.block_on_close = False
    port = httpd.server_address[1]
    url = f"http://127.0.0.1:{port}/"
    pid = os.getpid()
    write_json_atomic(server_path(d), {"port": port, "pid": pid, "url": url})

    def on_signal(signum, frame):
        studio.stop(httpd)
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    threading.Thread(target=studio.watch, args=(httpd,), daemon=True).start()
    print(f"studio: serving {d} at {url}", file=sys.stderr, flush=True)
    if not no_open:
        open_browser(url)
    try:
        httpd.serve_forever(poll_interval=0.25)
    finally:
        studio.stopping.set()
        httpd.server_close()
        info = read_server(d)
        if info and info.get("pid") == pid:
            with contextlib.suppress(OSError):
                os.remove(server_path(d))
    return 0


# --- CLI verbs --------------------------------------------------------------

def read_text(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError as e:
        raise UsageError(f"cannot read {what} {path}: {e.strerror}") from None


def start_server(d):
    """Start `serve` detached unless one is alive; return its url or None."""
    info = running_server(d)
    if info:
        return info.get("url")
    with contextlib.suppress(OSError):
        os.remove(server_path(d))
    cmd = [sys.executable, os.path.abspath(__file__), "serve", "--session", d]
    if os.environ.get("CLOUTER_STUDIO_NO_OPEN") == "1":
        cmd.append("--no-open")
    with open(os.path.join(d, "server.log"), "ab") as log:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=log, stderr=log, **DETACH)
    deadline = time.monotonic() + SERVER_START_SECONDS
    while time.monotonic() < deadline:
        info = read_server(d)
        if info and info.get("pid") == proc.pid:
            return info.get("url")
        if proc.poll() is not None:
            break
        time.sleep(0.05)
    return None


def push(args):
    d = os.path.abspath(args.session) if args.session else os.path.join(
        os.path.expanduser("~/.cache/clouter/studio"),
        datetime.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6])
    if not os.path.isfile(args.file):
        raise UsageError(f"no such file {args.file}")
    media_type = guess_media_type(args.file)
    if media_type not in MEDIA_EXT:
        raise UsageError(f"unsupported media type for {args.file}")
    brief = read_text(args.brief_file, "brief file")
    message = read_text(args.message_file, "message file") if args.message_file else None
    defects = []
    summary = model_trouble = models = models_error = None
    if args.defects_file:
        try:
            parsed = json.loads(read_text(args.defects_file, "defects file"))
        except ValueError:
            raise UsageError(f"defects file {args.defects_file} is not JSON") from None
        if isinstance(parsed, dict):  # critique.py --suggest writes {"defects": [...], "summary", ...}
            defects = parsed.get("defects")
            summary = parsed.get("summary")
            model_trouble = parsed.get("model_trouble")
            models = parsed.get("models")
            models_error = parsed.get("models_error")
        else:
            defects = parsed
        if not isinstance(defects, list):
            raise UsageError("defects file must hold a JSON list or {\"defects\": [...]}")
    request = read_text(args.request_file, "request file") if args.request_file else None

    os.makedirs(os.path.join(d, "rounds"), exist_ok=True)
    os.makedirs(os.path.join(d, "uploads"), exist_ok=True)
    with locked(d):
        if os.path.isfile(session_path(d)):
            session = load_session(d)
        else:
            if request is None or not args.modality:
                raise UsageError("a new session needs --request-file and --modality")
            session = {"version": 1, "request": request, "modality": args.modality,
                       "state": "waiting", "rounds": [], "feedback": []}
        rounds = session.setdefault("rounds", [])
        if args.parent is not None and args.parent not in {r.get("n") for r in rounds}:
            raise UsageError(f"--parent {args.parent} is not an existing round")
        n = max((r.get("n", 0) for r in rounds), default=0) + 1
        rel = f"rounds/round-{n}.{MEDIA_EXT[media_type]}"
        shutil.copyfile(args.file, os.path.join(d, rel))
        round_entry = {"n": n, "file": rel, "media_type": media_type, "model": args.model,
                       "cost": args.cost, "brief": brief, "parent": args.parent,
                       "defects": defects, "created": now_iso()}
        if message is not None:
            round_entry["message"] = message
        if summary is not None:
            round_entry["summary"] = summary
        if model_trouble is not None:
            round_entry["model_trouble"] = model_trouble
        if models is not None:
            round_entry["models"] = models
        if models_error is not None:
            round_entry["models_error"] = models_error
        rounds.append(round_entry)
        session["state"] = "waiting"
        save_session(d, session)
    url = start_server(d)
    print(json.dumps({"round": n, "url": url, "session": d}))
    if not url:
        print(f"studio: server did not start within {SERVER_START_SECONDS} s, see "
              f"{os.path.join(d, 'server.log')}", file=sys.stderr)
        return 1
    return 0


def resolved(d, session, entry):
    out = dict(entry)
    absolute = lambda rel: os.path.join(d, rel) if rel else rel  # noqa: E731
    out["annotation"] = absolute(entry.get("annotation"))
    out["markers"] = [dict(m, frame=absolute(m.get("frame"))) for m in entry.get("markers") or []]
    round_ = next((r for r in session.get("rounds", []) if r.get("n") == entry.get("round")), None)
    out["round_file"] = absolute(round_.get("file")) if round_ else None
    return out


def wait(args):
    d = require_session(args)
    deadline = time.monotonic() + args.timeout
    while True:
        with locked(d):
            session = load_session(d)
            pending = [e for e in session.get("feedback", []) if not e.get("consumed")]
            entry = min(pending, key=lambda e: e.get("id", 0)) if pending else None
            if entry:
                entry["consumed"] = True
                save_session(d, session)
                stale_accept = False
            elif session.get("state") == "accepted":
                accepts = [e for e in session.get("feedback", []) if e.get("action") == "accept"]
                entry = max(accepts, key=lambda e: e.get("id", 0)) if accepts else None
                stale_accept = True
            else:
                stale_accept = False
        if entry:
            print(json.dumps(resolved(d, session, entry)))
            if stale_accept or entry.get("action") == "accept":
                return 10
            return 0
        if not running_server(d):
            print("studio: server gone", file=sys.stderr)
            return 30
        if time.monotonic() >= deadline:
            return 20
        time.sleep(POLL_SECONDS)


def stop(args):
    d = require_session(args, need_file=False)
    info = read_server(d)
    if info and pid_alive(info["pid"]):
        with contextlib.suppress(OSError):  # ProcessLookupError; a plain OSError on Windows
            os.kill(info["pid"], signal.SIGTERM)
        deadline = time.monotonic() + 3
        while pid_alive(info["pid"]) and time.monotonic() < deadline:
            time.sleep(0.05)
        if pid_alive(info["pid"]):
            with contextlib.suppress(OSError):
                os.kill(info["pid"], getattr(signal, "SIGKILL", signal.SIGTERM))  # no SIGKILL on Windows
    with contextlib.suppress(OSError):
        os.remove(server_path(d))
    return 0


def status(args):
    d = require_session(args)
    session = load_session(d)
    info = running_server(d)
    print(json.dumps({"state": session.get("state"), "rounds": len(session.get("rounds", [])),
                      "url": info.get("url") if info else None}))
    return 0


def require_session(args, need_file=True):
    if not args.session:
        raise UsageError("--session is required (or set CLOUTER_STUDIO_DIR)")
    d = os.path.abspath(args.session)
    if need_file and not os.path.isfile(session_path(d)):
        raise UsageError(f"no session at {d}")
    return d


def main(argv):
    parser = argparse.ArgumentParser(description="Clouter studio: steer generation rounds in the browser.")
    sub = parser.add_subparsers(dest="verb", required=True)
    default = os.environ.get("CLOUTER_STUDIO_DIR") or None

    p = sub.add_parser("serve", help="run the server in the foreground")
    p.add_argument("--session", default=default)
    p.add_argument("--no-open", action="store_true")
    p.add_argument("--idle-minutes", type=float, default=30)

    p = sub.add_parser("push", help="add a round and make sure the server runs")
    p.add_argument("--session", default=default)
    p.add_argument("--file", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--cost", type=float, required=True)
    p.add_argument("--brief-file", required=True)
    p.add_argument("--defects-file")
    p.add_argument("--message-file")
    p.add_argument("--parent", type=int)
    p.add_argument("--request-file")
    p.add_argument("--modality", choices=MODALITIES)

    p = sub.add_parser("wait", help="block until feedback or accept")
    p.add_argument("--session", default=default)
    p.add_argument("--timeout", type=float, default=3600)

    for verb in ("stop", "status"):
        p = sub.add_parser(verb)
        p.add_argument("--session", default=default)

    args = parser.parse_args(argv[1:])
    try:
        if args.verb == "serve":
            return serve(require_session(args), args.no_open, args.idle_minutes)
        return {"push": push, "wait": wait, "stop": stop, "status": status}[args.verb](args)
    except UsageError as e:
        print(f"studio: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

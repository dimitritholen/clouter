"""Cross-platform smoke test: the parts that differ per OS, run with plain
Python so it works where the bash suite can't (native Windows in CI).

    python tests/smoke.py        # exit 0 when every check passes

Checks: every module imports, a stored key reads back, the hooks.json
command finds a Python and runs route.py (through bash, as Claude Code
runs hooks), and a studio session starts, serves, and stops. No network
beyond 127.0.0.1. Stdlib only.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VISUAL = os.path.join(ROOT, "skills", "visual")
sys.path[:0] = [ROOT, VISUAL]

failed = 0


def check(name, ok, detail=""):
    global failed
    print(f"{'ok  ' if ok else 'FAIL'} {name}" + ("" if ok else f": {detail}"))
    failed += not ok


work = tempfile.mkdtemp(prefix="clouter-smoke-")
os.environ["CLOUTER_CREDENTIALS"] = os.path.join(work, "credentials")
os.environ["CLOUTER_LEARNED"] = os.path.join(work, "learned.json")
os.environ["CLOUTER_PREFS"] = os.path.join(work, "prefs.json")
os.environ["CLOUTER_STUDIO_NO_OPEN"] = "1"
os.environ.pop("OPENROUTER_API_KEY", None)

# --- every module imports (fcntl, signal names, ... differ per OS) ------------
for name in ("lib.jev", "lib.keys", "lib.png", "catalogue", "ranking", "spec",
             "learned", "generate", "critique", "preview", "studio", "route", "interview"):
    try:
        __import__(name)
        check(f"import {name}", True)
    except Exception as e:  # noqa: BLE001
        check(f"import {name}", False, f"{type(e).__name__}: {e}")

# --- a stored key reads back (no POSIX mode check on Windows) -----------------
from lib import keys, png  # noqa: E402

keys.set("OPENROUTER_API_KEY", "smoke-key")
try:
    check("stored key reads back", keys.get("OPENROUTER_API_KEY") == "smoke-key")
except Exception as e:  # noqa: BLE001
    check("stored key reads back", False, f"{type(e).__name__}: {e}")
os.remove(os.environ["CLOUTER_CREDENTIALS"])

# --- the hook command, as Claude Code runs it: through bash -------------------
bash = shutil.which("bash")
if bash:
    with open(os.path.join(ROOT, "hooks", "hooks.json"), encoding="utf-8") as f:
        command = json.load(f)["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
    env = dict(os.environ, CLAUDE_PLUGIN_ROOT=ROOT.replace("\\", "/"))
    # No key stored: route.py answers a visual prompt with its setup note, no network.
    run = subprocess.run([bash, "-c", command], input='{"prompt": "draw an image of a fox"}',
                         capture_output=True, text=True, env=env, timeout=30)
    check("hook command: exit 0", run.returncode == 0, run.stderr)
    check("hook command: route.py answered", "[clouter visual]" in run.stdout, run.stdout + run.stderr)
    py = "python" if os.name == "nt" else "python3"
    check(f"hook command: tells Claude to run {py}", f"run {py} " in run.stdout, run.stdout)
else:
    print("skip hook command: no bash on PATH")

# --- a studio session starts, serves, and stops -------------------------------
import studio  # noqa: E402

image = os.path.join(work, "round.png")
with open(image, "wb") as f:
    f.write(png.encode(1, 1, [b"\xff\x00\x00\xff"]))
brief = os.path.join(work, "brief.txt")
with open(brief, "w", encoding="utf-8") as f:
    f.write("a red dot")
session = os.path.join(work, "session")
push = subprocess.run([sys.executable, os.path.join(VISUAL, "studio.py"), "push", "--session", session,
                       "--file", image, "--model", "acme/paint", "--cost", "0.01", "--brief-file", brief,
                       "--request-file", brief, "--modality", "raster_image"],
                      capture_output=True, text=True, timeout=60)
check("studio push: exit 0", push.returncode == 0, push.stderr)
url = json.loads(push.stdout or "{}").get("url")
info = studio.read_server(session) or {}
pid = info.get("pid")
check("studio server: running", bool(pid) and studio.pid_alive(pid), f"server.json {info}")
if url:
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/api/session", timeout=10) as r:
            rounds = json.load(r).get("rounds") or []
        check("studio server: serves the round", len(rounds) == 1, f"{len(rounds)} rounds")
    except Exception as e:  # noqa: BLE001
        check("studio server: serves the round", False, f"{type(e).__name__}: {e}")
stop = subprocess.run([sys.executable, os.path.join(VISUAL, "studio.py"), "stop", "--session", session],
                      capture_output=True, text=True, timeout=30)
check("studio stop: exit 0", stop.returncode == 0, stop.stderr)
if pid:
    deadline = time.monotonic() + 5
    while studio.pid_alive(pid) and time.monotonic() < deadline:
        time.sleep(0.1)
    check("studio stop: server gone", not studio.pid_alive(pid))
check("studio pid_alive: this process is alive", studio.pid_alive(os.getpid()))

shutil.rmtree(work, ignore_errors=True)
print(f"{'FAIL' if failed else 'ok  '} smoke: {failed} failed")
sys.exit(1 if failed else 0)

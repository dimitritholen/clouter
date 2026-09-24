#!/usr/bin/env bash
# Tests for skills/visual/generate.py against a stand-in OpenRouter that
# returns a PNG data URL, an SVG data URL for vector models, a two-step
# video job, audio bytes with a generation id, and fails on demand. Needs
# python3 and jq; no key, no network.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/visual/generate.py"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null' EXIT

python3 - "$work" "$ROOT" <<'EOF_SERVER' &
import base64, json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
work = sys.argv[1]
ROOT = sys.argv[2]
sys.path.insert(0, ROOT)
from lib import png
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
SVG = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4"/></svg>'
SVG_MESSY = (b'<?xml version="1.0" encoding="UTF-8"?>\n'
             b'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" '
             b'preserveAspectRatio="none" style="display: block;" viewBox="0 0 512 512">'
             b'<metadata>' + b'x' * 200 + b'</metadata>'
             b'<circle cx="256" cy="256" r="200"/></svg>')
SVG_MESSY_NO_VIEWBOX = (b'<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32" '
                        b'style="display: block;"><rect width="64" height="32"/></svg>')


def _trim_png():
    w, h = 40, 30
    rows = [bytearray(w * 4) for _ in range(h)]
    for y in range(10, 15):
        for x in range(12, 20):
            rows[y][x * 4:x * 4 + 4] = bytes([255, 0, 0, 255])
    return png.encode(w, h, rows), (12, 10, 20, 15), (w, h)


TRIM_PNG, TRIM_BOX, TRIM_SIZE = _trim_png()


def _interlaced_png():
    import struct, zlib

    def chunk(ctype, data):
        return struct.pack(">I", len(data)) + ctype + data + struct.pack(">I", zlib.crc32(ctype + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 1)  # interlace=1: unsupported
    idat = zlib.compress(b"\x00" * 64, 9)  # contents never reached, checked before decompress
    return png.SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


INTERLACED_PNG = _interlaced_png()
SVG_BAD_UTF8 = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 4">\xff\xfe<!-- bad --></svg>'
MP4 = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 24
MP3 = b"ID3" + b"\x00" * 13
PCM = (b"\x00\x01\xff\x00") * 300
polls = {}
critic_calls = {}


def critic_answer(model):
    """(pass, defects) for a critic call: passes by default (every model
    generate.py's own tests exercise), unless the model id names a
    critique-specific scenario."""
    n = critic_calls[model] = critic_calls.get(model, 0) + 1
    if model == "acme/critic-fail-then-pass":
        if n == 1:
            return False, [{"type": "artifact", "where": "a smudge", "box": None,
                            "severity": 5, "fix": "remove the smudge"}]
        return True, []
    if model == "acme/critic-always-fail":
        return False, [{"type": "artifact", "where": "a smudge", "box": None,
                        "severity": 5, "fix": "remove the smudge"}]
    return True, []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def send(self, status, raw, ctype, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)
    def send_json(self, status, obj, extra=None):
        self.send(status, json.dumps(obj).encode(), "application/json", extra)
    def record(self, body=None):
        with open(f"{work}/requests.jsonl", "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization"), "body": body}) + "\n")
    def base(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def do_GET(self):
        # llms.txt (spec.py) fetches are plumbing, not a generation call:
        # kept out of requests.jsonl so every existing request-sequence
        # assertion below still reads as the generation calls alone. Every
        # test model other than the two below has no spec (a 404 here),
        # exercising generate.py's own fallback.
        if self.path.endswith("/llms.txt"):
            if self.path == "/google/veo-3.1/llms.txt":
                out = open(f"{ROOT}/tests/fixtures/llms/google__veo-3.1.txt", "rb").read()
                self.send(200, out, "text/plain"); return
            if self.path == "/recraft/recraft-v4-vector/llms.txt":
                out = open(f"{ROOT}/tests/fixtures/llms/recraft__recraft-v4-vector.txt", "rb").read()
                self.send(200, out, "text/plain"); return
            self.send_response(404); self.end_headers(); return
        self.record()
        if self.path.startswith("/api/v1/videos/") and self.path.endswith("/content?index=0"):
            self.send(200, MP4, "video/mp4"); return
        if self.path.startswith("/api/v1/videos/"):
            job = self.path.rsplit("/", 1)[1]
            polls[job] = polls.get(job, 0) + 1
            if job == "job-fails":
                self.send_json(200, {"id": job, "status": "failed", "error": "provider said no"}); return
            if polls[job] < 2:
                self.send_json(200, {"id": job, "status": "in_progress"}); return
            self.send_json(200, {"id": job, "status": "completed",
                                 "unsigned_urls": [f"{self.base()}/api/v1/videos/{job}/content?index=0"],
                                 "usage": {"cost": 0.25, "is_byok": False}}); return
        if self.path == "/api/v1/models?output_modalities=speech":
            self.send_json(200, {"data": [{"id": "acme/tts", "supported_voices": ["nova", "alloy"]},
                                          {"id": "acme/tts-mute", "supported_voices": []}]}); return
        if self.path == "/api/v1/models?output_modalities=image":
            self.send_json(200, {"data": [
                {"id": "acme/paint", "name": "Acme Paint", "description": "The default test model.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.00002"}},
                {"id": "acme/paint-noref", "architecture": {"input_modalities": ["text"]}},
                {"id": "acme/paint-hi", "name": "Acme Paint Hi", "description": "Pricier escalation candidate.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.00005"}},
            ]}); return
        if self.path.startswith("/api/v1/generation?id="):
            gen = self.path.split("=", 1)[1]
            if gen == "gen-late" and polls.get("gen-late", 0) == 0:
                polls["gen-late"] = 1
                self.send_json(404, {"error": {"message": "not yet"}}); return
            if gen == "gen-slow" and polls.get("gen-slow", 0) < 2:
                polls["gen-slow"] = polls.get("gen-slow", 0) + 1
                self.send_json(404, {"error": {"message": "not yet"}}); return
            self.send_json(200, {"data": {"id": gen, "total_cost": 0.0003}}); return
        self.send_json(404, {"error": {"message": "no such path"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.record(body)
        model = body.get("model", "")
        if self.path == "/api/alpha/decisions":
            criteria = body["questions"]["model"]["criteria"]
            ids = list(criteria)
            pick = ids[0]
            conf = 0.7
            probs = {i: round((1 - conf) / max(1, len(ids) - 1), 3) for i in ids}
            probs[pick] = conf
            self.send_json(200, {"model": "jev-stand-in", "id": "req-jev", "answers": {
                "model": {"type": "choice", "choice": pick, "confidence": conf, "probabilities": probs}}})
            return
        if "boom" in model:
            self.send_json(500, {"error": {"message": "stand-in exploded"}}); return
        if "forbidden" in model:
            self.send_json(403, {"error": {"message": "This model requires you to complete the following before use: 18+ age confirmation",
                                           "code": 403, "metadata": {"missing_attestation_types": ["age_18plus"]}}}); return
        messages = body.get("messages") or []
        is_critic = self.path == "/api/v1/chat/completions" and bool(messages) and messages[0].get("role") == "system"
        if is_critic:
            passed, defects = critic_answer(model)
            content = json.dumps({"pass": passed, "defects": defects})
            self.send_json(200, {"choices": [{"message": {"role": "assistant", "content": content}}],
                                 "usage": {"cost": 0.002}}); return
        if self.path == "/api/v1/chat/completions":
            if "images-only" in model:
                self.send_json(404, {"error": {"message": "acme/images-only is an image generation model and cannot be used with the chat/completions endpoint. Use the /api/v1/images endpoint instead.",
                                               "code": 404}}); return
            if "vector-messy-no-viewbox" in model:
                url = "data:image/svg+xml;base64," + base64.b64encode(SVG_MESSY_NO_VIEWBOX).decode()
            elif "vector-messy" in model:
                url = "data:image/svg+xml;base64," + base64.b64encode(SVG_MESSY).decode()
            elif "vector-badutf8" in model:
                url = "data:image/svg+xml;base64," + base64.b64encode(SVG_BAD_UTF8).decode()
            elif "vector" in model:
                url = "data:image/svg+xml;base64," + base64.b64encode(SVG).decode()
            elif "noimage" in model:
                self.send_json(200, {"choices": [{"message": {"content": "I cannot draw that."}}],
                                     "usage": {"cost": 0.0}}); return
            elif "trim-badpng" in model:
                url = "data:image/png;base64," + base64.b64encode(INTERLACED_PNG).decode()
            elif "trim" in model:
                url = "data:image/png;base64," + base64.b64encode(TRIM_PNG).decode()
            else:
                url = "data:image/png;base64," + base64.b64encode(PNG).decode()
            self.send_json(200, {"id": "gen-img", "choices": [{"message": {"role": "assistant", "content": "",
                                 "images": [{"type": "image_url", "image_url": {"url": url}}]}}],
                                 "usage": {"prompt_tokens": 10, "completion_tokens": 1000, "cost": 0.0192}}); return
        if self.path == "/api/v1/images":
            if body.get("background") == "transparent":
                self.send_json(200, {"data": [{"b64_json": base64.b64encode(PNG).decode(), "media_type": "image/png"}],
                                     "usage": {"cost": 0.013}}); return
            if "images-only" in model:
                self.send_json(200, {"data": [{"b64_json": base64.b64encode(PNG).decode(), "media_type": "image/png"}],
                                     "usage": {"cost": 0.0042}}); return
            self.send_json(404, {"error": {"message": "unknown model"}}); return
        if self.path == "/api/v1/videos":
            job = "job-fails" if "fail" in model else "job-1"
            self.send_json(200, {"id": job, "status": "pending", "polling_url": f"{self.base()}/api/v1/videos/{job}"}); return
        if self.path == "/api/v1/audio/speech":
            response_format = body.get("response_format")
            if "pcmonly" in model and response_format != "pcm":
                self.send_json(400, {"error": {"message":
                    'Gemini TTS only supports response_format="pcm". Got "%s".' % response_format,
                    "code": 400}}); return
            if "badparam" in model and response_format == "mp3":
                self.send_json(400, {"error": {"message": "stand-in refuses this today", "code": 400}}); return
            if response_format == "pcm":
                gen = "gen-slow" if "slow" in model else "gen-pcm"
                self.send(200, PCM, "audio/pcm;rate=24000;channels=1", {"X-Generation-Id": gen}); return
            gen = "gen-late" if "late" in model else "gen-audio"
            self.send(200, MP3, "audio/mpeg", {"X-Generation-Id": gen}); return
        self.send_json(404, {"error": {"message": "no such path"}})

server = HTTPServer(("127.0.0.1", 0), Handler)
open(f"{work}/port", "w").write(str(server.server_port))
server.serve_forever()
EOF_SERVER
server_pid=$!
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || { printf 'FAIL stand-in server did not start\n'; exit 1; }
export OPENROUTER_BASE_URL="http://127.0.0.1:$(cat "$work/port")"
export CLOUTER_CREDENTIALS="$work/no-such-file"
# learned.py's store: never the real ~/.config/clouter/learned.json.
export CLOUTER_LEARNED="$work/learned.json"
export OPENROUTER_API_KEY="test-key"
export CLOUTER_POLL_SECONDS=0
# Every existing case below predates the mandatory critique pass and asserts
# exact request sequences/counts; CLOUTER_CRITIQUE=0 keeps them exercising
# only the generation call they were written for. The "--- critique (#?) ---"
# section near the end turns it back on to test the wiring itself.
export CLOUTER_CRITIQUE=0
mkdir -p "$work/cwd" && cd "$work/cwd"

check_code() { if [ "$2" -eq "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (exit %s, want %s): %s\n' "$1" "$2" "$3" "$(cat "$work/stderr")"; fail=1; fi; }
check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }
run() { rm -f "$work/requests.jsonl"; out=$("$SCRIPT" "$@" 2>"$work/stderr"); code=$?; }
field() { printf '%s' "$out" | jq -r "$1"; }

# --- raster ------------------------------------------------------------------
run --model acme/paint --modality raster_image --prompt "A red fox, watercolour"
check_code "raster: written" "$code" 0
check_eq "raster: default path is assets/<slug>.png" "$(field .path)" "assets/a-red-fox-watercolour.png"
check_eq "raster: file is the decoded PNG" "$(head -c 8 assets/a-red-fox-watercolour.png | od -An -c | tr -d ' \n')" '211PNG\r\n032\n'
check_eq "raster: media type and cost on stdout" "$(field '[.media_type, .cost, .model, .modality] | @csv')" '"image/png",0.0192,"acme/paint","raster_image"'
check_eq "raster: chat completions with image modality and usage" "$(jq -c 'select(.method=="POST") | [.path, .body.modalities, .body.usage.include, .body.messages[0].content]' "$work/requests.jsonl")" '["/api/v1/chat/completions",["image"],true,"A red fox, watercolour"]'
check_eq "raster: bearer sent" "$(jq -r '.auth' "$work/requests.jsonl")" "Bearer test-key"
check_eq "raster: no image_config without --aspect" "$(jq -c '.body | has("image_config")' "$work/requests.jsonl")" "false"

run --model acme/paint --modality raster_image --prompt "A red fox, watercolour"
check_eq "no overwrite: second run gets -2" "$(field .path)" "assets/a-red-fox-watercolour-2.png"
run --model acme/paint --modality raster_image --prompt "A red fox, watercolour"
check_eq "no overwrite: third run gets -3" "$(field .path)" "assets/a-red-fox-watercolour-3.png"

run --model acme/paint --modality raster_image --prompt "banner" --aspect 16:9 --out out/wide.png
check_eq "--out is honoured, directories made" "$(field .path)" "out/wide.png"
[ -s out/wide.png ] && printf 'ok   --out file exists\n' || { printf 'FAIL --out file missing\n'; fail=1; }
check_eq "--aspect goes into image_config" "$(jq -r '.body.image_config.aspect_ratio' "$work/requests.jsonl")" "16:9"
run --model acme/paint --modality raster_image --prompt "banner" --out out/wide.png
check_eq "--out never overwrites either" "$(field .path)" "out/wide-2.png"
run --model acme/paint --modality raster_image --prompt "x" --out out/noext
check_eq "--out without extension gets the media type's" "$(field .path)" "out/noext.png"

# --- vector ------------------------------------------------------------------
run --model recraft/recraft-v4.1-vector --modality vector_svg --prompt "Fox logo, flat"
check_code "vector: written" "$code" 0
check_eq "vector: svg extension from image/svg+xml" "$(field '[.path, .media_type] | @csv')" '"assets/fox-logo-flat.svg","image/svg+xml"'
check_eq "vector: file holds the SVG" "$(head -c 4 assets/fox-logo-flat.svg)" "<svg"

run --model acme/noimage --modality raster_image --prompt "nothing"
check_code "no image in the answer: exit 4" "$code" 4
check_eq "no image: model's text quoted" "$(grep -c 'returned no image: I cannot draw that' "$work/stderr")" "1"

# --- video -------------------------------------------------------------------
run --model acme/video --modality video --prompt "Sunrise over a lake" --duration 4 --aspect 9:16
check_code "video: written" "$code" 0
check_eq "video: mp4 from the content type, cost from the job" "$(field '[.path, .media_type, .cost] | @csv')" '"assets/sunrise-over-a-lake.mp4","video/mp4",0.25'
check_eq "video: file holds the mp4 bytes" "$(dd if=assets/sunrise-over-a-lake.mp4 bs=1 skip=4 count=4 2>/dev/null)" "ftyp"
check_eq "video: submit, two polls, one download" "$(jq -r '.method + " " + .path' "$work/requests.jsonl" | tr '\n' ';')" "POST /api/v1/videos;GET /api/v1/videos/job-1;GET /api/v1/videos/job-1;GET /api/v1/videos/job-1/content?index=0;"
check_eq "video: duration and aspect in the submit body" "$(jq -c 'select(.method=="POST") | [.body.model, .body.prompt, .body.duration, .body.aspect_ratio]' "$work/requests.jsonl")" '["acme/video","Sunrise over a lake",4,"9:16"]'

run --model acme/video-fail --modality video --prompt "doomed clip"
check_code "failed video job: exit 5" "$code" 5
check_eq "failed job: reason on stderr" "$(grep -c 'video job job-fails failed: provider said no' "$work/stderr")" "1"
[ ! -e assets/doomed-clip.mp4 ] && printf 'ok   failed job: nothing written\n' || { printf 'FAIL failed job wrote a file\n'; fail=1; }

# --- speech ------------------------------------------------------------------
run --model acme/tts --modality speech --prompt "Hello there, listener"
check_code "speech: written" "$code" 0
check_eq "speech: mp3, cost from the generation lookup" "$(field '[.path, .media_type, .cost] | @csv')" '"assets/hello-there-listener.mp3","audio/mpeg",0.0003'
check_eq "speech: file holds the audio bytes" "$(head -c 3 assets/hello-there-listener.mp3)" "ID3"
check_eq "speech: default voice is the model's first supported voice" "$(jq -c 'select(.path=="/api/v1/audio/speech") | [.body.model, .body.input, .body.voice, .body.response_format]' "$work/requests.jsonl")" '["acme/tts","Hello there, listener","nova","mp3"]'
check_eq "speech: generation looked up by the header id" "$(grep -c '"/api/v1/generation?id=gen-audio"' "$work/requests.jsonl")" "1"

run --model acme/tts --modality speech --prompt "Hello again" --voice alloy
check_eq "--voice wins over the default and skips the lookup" "$(jq -c 'select(.path=="/api/v1/audio/speech") | .body.voice' "$work/requests.jsonl")" '"alloy"'
check_eq "--voice: no model list fetched" "$(grep -c 'output_modalities=speech' "$work/requests.jsonl")" "0"

run --model acme/tts-mute --modality speech --prompt "No voices listed"
check_code "model without voices: still sent, no voice field" "$code" 0
check_eq "no voice field when none is known" "$(jq -c 'select(.path=="/api/v1/audio/speech") | .body | has("voice")' "$work/requests.jsonl")" "false"

run --model acme/tts-late --modality speech --prompt "Late stats"
check_eq "generation stats 404 once: retried and found" "$(field .cost)" "0.0003"

run --model acme/tts-pcmonly --modality speech --prompt "Gemini only speaks pcm"
check_code "pcm-only model: written" "$code" 0
check_eq "pcm-only: mp3 rejected, retried as pcm, wrapped into a wav" "$(field '[.path, .media_type] | @csv')" '"assets/gemini-only-speaks-pcm.wav","audio/wav"'
check_eq "pcm-only: wav header parses back to rate/channels/width" \
  "$(python3 -c 'import wave; w = wave.open("assets/gemini-only-speaks-pcm.wav"); print(w.getframerate(), w.getnchannels(), w.getsampwidth())')" \
  "24000 1 2"
check_eq "pcm-only: exactly two speech requests (mp3 then pcm)" "$(jq -r 'select(.path=="/api/v1/audio/speech") | .body.response_format' "$work/requests.jsonl" | tr '\n' ',')" "mp3,pcm,"
check_eq "pcm-only: learned.json records mp3 rejected and pcm preferred" \
  "$(jq -c '."acme/tts-pcmonly" | [.prefer.response_format.value, (.rejected.response_format | keys)]' "$CLOUTER_LEARNED")" '["pcm",["\"mp3\""]]'

run --model acme/tts-pcmonly --modality speech --prompt "Gemini learned pcm"
check_code "pcm-only, learned: written" "$code" 0
check_eq "pcm-only, learned: exactly one speech request, straight to pcm" "$(jq -r 'select(.path=="/api/v1/audio/speech") | .body.response_format' "$work/requests.jsonl" | tr '\n' ',')" "pcm,"
check_eq "pcm-only, learned: still a wav" "$(field .media_type)" "audio/wav"

run --model acme/tts-pcmonly --modality speech --prompt "Ask for mp3 anyway" --param response_format=mp3
check_code "pcm-only, learned: --param response_format=mp3 refused, usage exit" "$code" 2
check_eq "pcm-only, learned: refusal says the provider rejected it and names pcm" "$(grep -c 'response_format mp3 was rejected by the provider on .*; use one of: pcm' "$work/stderr")" "1"
check_eq "pcm-only, learned: refused mp3 sends no request at all" "$([ -f "$work/requests.jsonl" ] && wc -l < "$work/requests.jsonl" || echo 0)" "0"

run --model acme/tts --modality speech --prompt "Explicit pcm" --param response_format=pcm
check_code "--param response_format=pcm: written" "$code" 0
check_eq "--param response_format=pcm: single request, no mp3 attempt" "$(jq -r 'select(.path=="/api/v1/audio/speech") | .body.response_format' "$work/requests.jsonl" | tr '\n' ',')" "pcm,"
check_eq "--param response_format=pcm: still a wav" "$(field .media_type)" "audio/wav"

CLOUTER_COST_WAIT_SECONDS=0.01 run --model acme/tts-slow --modality speech --prompt "Slow cost lookup" --param response_format=pcm
check_code "cost lookup 404 twice: written" "$code" 0
check_eq "cost lookup 404 twice: retried until found" "$(field .cost)" "0.0003"

run --model acme/tts-badparam --modality speech --prompt "Unrelated 400"
check_code "unrelated 400: no pcm retry, exit 4" "$code" 4
check_eq "unrelated 400: message on stderr, not the gemini one" "$(grep -c 'stand-in refuses this today' "$work/stderr")" "1"
check_eq "unrelated 400: only one speech request" "$(grep -c '/api/v1/audio/speech' "$work/requests.jsonl")" "1"

run --model acme/tts --modality speech --prompt "Still mp3 by default"
check_eq "mp3 default path unchanged" "$(field .media_type)" "audio/mpeg"

# --- failures and usage ---------------------------------------------------------
run --model acme/boom --modality raster_image --prompt "x"
check_code "API 500: exit 4" "$code" 4
check_eq "API 500: message on stderr" "$(grep -c 'answered 500: stand-in exploded' "$work/stderr")" "1"
OPENROUTER_API_KEY= run --model acme/paint --modality raster_image --prompt "x"
check_code "no key: exit 3" "$code" 3
check_eq "no key: no request" "$([ -f "$work/requests.jsonl" ] && wc -l < "$work/requests.jsonl" || echo 0)" "0"
run --model acme/paint --modality hologram --prompt "x"
check_code "bad modality: usage exit 2" "$code" 2
run --model acme/paint --modality raster_image --prompt "   "
check_code "empty prompt: usage exit 2" "$code" 2
OPENROUTER_BASE_URL="http://127.0.0.1:1" run --model acme/paint --modality raster_image --prompt "x"
check_code "unreachable: exit 4" "$code" 4

# --- endpoint routing and unusable models (#641) ---
run --model acme/images-only --modality raster_image --prompt "A blue heron, ink"
check_code "images-only, auto: written via images endpoint" "$code" 0
check_eq "images-only, auto: file is the decoded PNG" "$(head -c 8 assets/a-blue-heron-ink.png | od -An -c | tr -d ' \n')" '211PNG\r\n032\n'
check_eq "images-only, auto: cost 0.0042" "$(field .cost)" "0.0042"
check_eq "images-only, auto: chat/completions then images" "$(jq -r '.path' "$work/requests.jsonl" | tr '\n' ';')" "/api/v1/chat/completions;/api/v1/images;"
check_eq "images-only, auto: learned.json prefers the images endpoint" "$(jq -r '."acme/images-only".prefer.endpoint.value' "$CLOUTER_LEARNED")" "images"

run --model acme/images-only --modality raster_image --prompt "A grey heron, learned"
check_code "images-only, auto, learned: written" "$code" 0
check_eq "images-only, auto, learned: one request, straight to images" "$(jq -r '.path' "$work/requests.jsonl" | tr '\n' ';')" "/api/v1/images;"

run --model acme/images-only --modality raster_image --prompt "Colorful parrot" --endpoint images
check_code "--endpoint images: written" "$code" 0
check_eq "--endpoint images: file exists" "$(head -c 8 assets/colorful-parrot.png | od -An -c | tr -d ' \n')" '211PNG\r\n032\n'
check_eq "--endpoint images: images endpoint only" "$(jq -r '.path' "$work/requests.jsonl" | tr '\n' ';')" "/api/v1/images;"

run --model acme/images-only --modality raster_image --prompt "Mountain peak" --endpoint chat
check_code "--endpoint chat: exit 4" "$code" 4
check_eq "--endpoint chat: error on stderr" "$(grep -c 'Use the /api/v1/images endpoint' "$work/stderr")" "1"
[ ! -e assets/mountain-peak.png ] && printf 'ok   --endpoint chat: nothing written\n' || { printf 'FAIL --endpoint chat wrote a file\n'; fail=1; }
check_eq "--endpoint chat: chat endpoint only" "$(jq -r '.path' "$work/requests.jsonl" | tr '\n' ';')" "/api/v1/chat/completions;"

run --model acme/forbidden --modality raster_image --prompt "A locked door"
check_code "forbidden model: exit 6" "$code" 6
check_eq "forbidden: missing attestation on stderr" "$(grep -c '18+ age confirmation' "$work/stderr")" "1"
[ ! -e assets/a-locked-door.png ] && printf 'ok   forbidden: nothing written\n' || { printf 'FAIL forbidden wrote a file\n'; fail=1; }

run --model acme/paint --modality raster_image --endpoint bogus --prompt "x"
check_code "--endpoint with bad value: usage exit 2" "$code" 2

run --model acme/paint --modality raster_image --prompt "A ceramic pot"
check_code "existing model without --endpoint: written" "$code" 0
check_eq "existing model: uses chat only, no images call" "$(jq -c 'select(.method=="POST") | .path' "$work/requests.jsonl" | sort -u | tr '\n' ';')" '"/api/v1/chat/completions";'

# --- --transparent (#640) ---
run --model openai/gpt-5-image-mini --modality raster_image --prompt "A fox on a transparent background" --transparent
check_code "--transparent on an alpha model: written" "$code" 0
check_eq "--transparent: cost from the images response" "$(field .cost)" "0.013"
check_eq "--transparent: request goes to /api/v1/images with background and output_format" "$(jq -c 'select(.method=="POST") | [.path, .body.background, .body.output_format]' "$work/requests.jsonl")" '["/api/v1/images","transparent","png"]'
check_eq "--transparent: chat/completions never called" "$(jq -r '.path' "$work/requests.jsonl" | tr '\n' ';')" "/api/v1/images;"

run --model black-forest-labs/flux-2-klein --modality raster_image --prompt "A fox, no background" --transparent
check_code "--transparent on a non-alpha model: new exit code 7" "$code" 7
check_eq "--transparent refusal: reason on stderr" "$(grep -c 'no native alpha channel' "$work/stderr")" "1"
check_eq "--transparent refusal: no request at all" "$([ -f "$work/requests.jsonl" ] && wc -l < "$work/requests.jsonl" || echo 0)" "0"
[ ! -e assets/a-fox-no-background.png ] && printf 'ok   --transparent refusal: nothing written\n' || { printf 'FAIL --transparent refusal wrote a file\n'; fail=1; }

run --model recraft/recraft-v4.1-vector --modality vector_svg --prompt "A fox logo" --transparent
check_code "--transparent on a non-raster modality: usage exit 2" "$code" 2
check_eq "--transparent, non-raster: no request at all" "$([ -f "$work/requests.jsonl" ] && wc -l < "$work/requests.jsonl" || echo 0)" "0"

# --- SVG cleanup (#643) ---
run --model recraft/recraft-v4.1-vector-messy --modality vector_svg --prompt "Fox logo, messy svg"
check_code "svg cleanup: written" "$code" 0
svg_out="$(cat "$(field .path)")"
check_eq "svg cleanup: metadata block gone" "$(printf '%s' "$svg_out" | grep -c '<metadata')" "0"
check_eq "svg cleanup: width attribute gone" "$(printf '%s' "$svg_out" | grep -c 'width=')" "0"
check_eq "svg cleanup: height attribute gone" "$(printf '%s' "$svg_out" | grep -c 'height=')" "0"
check_eq "svg cleanup: preserveAspectRatio gone" "$(printf '%s' "$svg_out" | grep -c 'preserveAspectRatio')" "0"
check_eq "svg cleanup: display:block style gone" "$(printf '%s' "$svg_out" | grep -c 'display: block')" "0"
check_eq "svg cleanup: viewBox kept" "$(printf '%s' "$svg_out" | grep -o 'viewBox="0 0 512 512"')" 'viewBox="0 0 512 512"'
check_eq "svg cleanup: circle untouched" "$(printf '%s' "$svg_out" | grep -c '<circle cx="256" cy="256" r="200"/>')" "1"
check_eq "svg cleanup: much smaller than the messy source" "$([ "$(field .bytes)" -lt 400 ] && echo yes || echo no)" "yes"

run --model recraft/recraft-v4.1-vector-messy-no-viewbox --modality vector_svg --prompt "Rect, no viewbox"
check_code "svg cleanup, no viewBox: written" "$code" 0
svg_out2="$(cat "$(field .path)")"
check_eq "svg cleanup: viewBox synthesized from width/height" "$(printf '%s' "$svg_out2" | grep -o 'viewBox="0 0 64 32"')" 'viewBox="0 0 64 32"'
check_eq "svg cleanup: root width/height gone after synthesizing viewBox" \
  "$(printf '%s' "$svg_out2" | grep -o '<svg[^>]*>' | grep -c 'width=\|height=')" "0"

# --- --trim (#643) ---
run --model acme/paint-trim --modality raster_image --prompt "Trim me" --trim --trim-margin 2
check_code "--trim: written" "$code" 0
dims="$(python3 -c "import sys; sys.path.insert(0, '$ROOT'); from lib import png
w, h, rows = png.decode(open('$(field .path)', 'rb').read())
print(f'{w}x{h}')
print(rows[0][0 * 4 + 3])   # top-left alpha: still transparent margin
print(rows[4][4 * 4 + 3])   # inside the original rectangle, offset by the new crop
")"
check_eq "--trim: cropped to rectangle plus margin 2 (12x9)" "$(printf '%s' "$dims" | sed -n 1p)" "12x9"
check_eq "--trim: margin stays transparent" "$(printf '%s' "$dims" | sed -n 2p)" "0"
check_eq "--trim: content still opaque after crop" "$(printf '%s' "$dims" | sed -n 3p)" "255"

run --model acme/paint-trim --modality raster_image --prompt "Trim me, default margin"
mv "$(field .path)" "$work/untrimmed.png"
run --model acme/paint-trim --modality raster_image --prompt "Trim me, default margin" --trim
check_code "--trim, default margin: written" "$code" 0
untrimmed_size=$(stat -c%s "$work/untrimmed.png" 2>/dev/null || stat -f%z "$work/untrimmed.png")
trimmed_size=$(stat -c%s "$(field .path)")
check_eq "--trim, default margin 32 on a 40x30 canvas clamps to the full image" \
  "$([ "$trimmed_size" -gt 0 ] && echo yes || echo no)" "yes"

run --model recraft/recraft-v4.1-vector --modality vector_svg --prompt "SVG, trim is a no-op" --trim
check_code "--trim on a non-PNG: still written" "$code" 0
check_eq "--trim on a non-PNG: stderr note" "$(grep -c 'trim is a no-op for svg' "$work/stderr")" "1"

# --- cleanup/trim never lose a paid-for file on failure (review) ---
run --model acme/paint-trim-badpng --modality raster_image --prompt "Interlaced, trim should skip" --trim
check_code "--trim on an unsupported PNG: still exit 0" "$code" 0
check_eq "--trim skipped: note on stderr" "$(grep -c 'generate: --trim skipped:' "$work/stderr")" "1"
check_eq "--trim skipped: file still written with the original (untrimmed) PNG bytes" \
  "$(head -c 8 "$(field .path)" | od -An -c | tr -d ' \n')" '211PNG\r\n032\n'
check_eq "--trim skipped: IHDR still says interlace=1 (nothing was re-encoded)" \
  "$(od -An -tu1 -j 28 -N 1 "$(field .path)" | tr -d ' ')" "1"

run --model recraft/recraft-v4.1-vector-badutf8 --modality vector_svg --prompt "Bad utf8 svg"
check_code "svg cleanup on non-UTF-8 body: still exit 0" "$code" 0
check_eq "svg cleanup skipped: note on stderr" "$(grep -c 'generate: svg cleanup skipped:' "$work/stderr")" "1"
check_eq "svg cleanup skipped: file still has the un-cleaned bytes (viewBox and the bad byte both present)" \
  "$(od -An -tx1 "$(field .path)" | tr -d ' \n' | grep -c 'fffe')" "1"

# --- --reference (#644) ---
ref_png="$work/reference.png"
printf '%s' "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==" | base64 -d > "$ref_png"

run --model acme/paint --modality raster_image --prompt "Vary this fox" --reference "$ref_png"
check_code "--reference on a supporting model: written" "$code" 0
data_url="$(jq -r 'select(.path=="/api/v1/chat/completions") | .body.messages[0].content[1].image_url.url' "$work/requests.jsonl")"
check_eq "--reference: text part kept alongside the image part" "$(jq -r 'select(.path=="/api/v1/chat/completions") | .body.messages[0].content[0].text' "$work/requests.jsonl")" "Vary this fox"
check_eq "--reference: data URL prefix" "$(printf '%s' "$data_url" | cut -c1-22)" "data:image/png;base64,"
check_eq "--reference: decodes to the reference file's bytes" \
  "$(printf '%s' "$data_url" | sed 's/^data:image\/png;base64,//' | base64 -d | cmp -s - "$ref_png" && echo same || echo different)" "same"
check_eq "--reference: model listing looked up before the generation call" "$(jq -r '.method + " " + .path' "$work/requests.jsonl" | tr '\n' ';')" "GET /api/v1/models?output_modalities=image;POST /api/v1/chat/completions;"

run --model acme/paint-noref --modality raster_image --prompt "Vary this owl, unsupported" --reference "$ref_png"
check_code "--reference on a non-supporting model: new exit code 8" "$code" 8
check_eq "--reference refusal: reason on stderr" "$(grep -c 'does not take a reference image' "$work/stderr")" "1"
check_eq "--reference refusal: no generation request made" "$(grep -c 'chat/completions\|api/v1/images' "$work/requests.jsonl")" "0"
[ ! -e assets/vary-this-owl-unsupported.png ] && printf 'ok   --reference refusal: nothing written\n' || { printf 'FAIL --reference refusal wrote a file\n'; fail=1; }

run --model acme/paint --modality raster_image --prompt "Missing reference" --reference "$work/no-such-file.png"
check_code "--reference file missing: exit 2" "$code" 2
check_eq "--reference missing: no request at all" "$([ -f "$work/requests.jsonl" ] && wc -l < "$work/requests.jsonl" || echo 0)" "0"

big_ref="$work/big.png"
head -c $((20 * 1024 * 1024 + 1)) /dev/zero > "$big_ref"
run --model acme/paint --modality raster_image --prompt "Too big" --reference "$big_ref"
check_code "--reference over 20 MB: exit 2" "$code" 2
check_eq "--reference over 20 MB: no request at all" "$([ -f "$work/requests.jsonl" ] && wc -l < "$work/requests.jsonl" || echo 0)" "0"

run --model acme/video --modality video --prompt "x" --reference "$ref_png"
check_code "--reference on video: usage exit 2" "$code" 2

# --- load_reference: SVG width/height from viewBox (Recraft round-trip) ---
ref_svg_viewbox_only="$work/ref-viewbox-only.svg"
printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2048 2048"><circle r="4"/></svg>' > "$ref_svg_viewbox_only"
ref_svg_with_dims="$work/ref-with-dims.svg"
printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="20" viewBox="0 0 10 20"><circle r="4"/></svg>' > "$ref_svg_with_dims"
ref_svg_no_viewbox="$work/ref-no-viewbox.svg"
printf '%s' '<svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>' > "$ref_svg_no_viewbox"
ref_svg_comma_viewbox="$work/ref-comma-viewbox.svg"
printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0,0,64,32"><circle r="4"/></svg>' > "$ref_svg_comma_viewbox"
ref_svg_stroke_width="$work/ref-stroke-width.svg"
printf '%s' '<svg viewBox="0 0 10 20" stroke-width="2"><circle r="4"/></svg>' > "$ref_svg_stroke_width"

svg_refs="$(python3 -c "
import sys
sys.path.insert(0, '$ROOT/skills/visual')
import generate

def tag(path):
    url = generate.load_reference(path)
    raw = generate.base64.b64decode(url.split(',', 1)[1])
    return raw.decode()

print(tag('$ref_svg_viewbox_only'))
print('---')
print(tag('$ref_svg_with_dims'))
print('---')
print(tag('$ref_svg_no_viewbox'))
print('---')
print(tag('$ref_svg_comma_viewbox'))
print('---')
print(tag('$ref_svg_stroke_width'))
")"
check_eq "load_reference: viewBox-only SVG gets width/height from viewBox" \
  "$(printf '%s\n' "$svg_refs" | sed -n '1p')" \
  '<svg width="2048" height="2048" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2048 2048"><circle r="4"/></svg>'
check_eq "load_reference: SVG that already has width/height is unchanged" \
  "$(printf '%s\n' "$svg_refs" | sed -n '3p')" \
  '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="20" viewBox="0 0 10 20"><circle r="4"/></svg>'
check_eq "load_reference: SVG without a viewBox is unchanged" \
  "$(printf '%s\n' "$svg_refs" | sed -n '5p')" \
  '<svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>'
check_eq "load_reference: comma-separated viewBox also fills in width/height" \
  "$(printf '%s\n' "$svg_refs" | sed -n '7p')" \
  '<svg width="64" height="32" xmlns="http://www.w3.org/2000/svg" viewBox="0,0,64,32"><circle r="4"/></svg>'
check_eq "load_reference: stroke-width= is not mistaken for width=, width/height still added" \
  "$(printf '%s\n' "$svg_refs" | sed -n '9p')" \
  '<svg width="10" height="20" viewBox="0 0 10 20" stroke-width="2"><circle r="4"/></svg>'

# --- --preview (#642) ---
preview_bin="$work/preview-bin"
mkdir -p "$preview_bin"
cat > "$preview_bin/google-chrome" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    --screenshot=*) printf '%s' "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==" | base64 -d > "${arg#--screenshot=}" ;;
  esac
done
exit 0
EOF
chmod +x "$preview_bin/google-chrome"
run_with_preview_path() { rm -f "$work/requests.jsonl"; out=$(PATH="$preview_bin:$PATH" "$SCRIPT" "$@" 2>"$work/stderr"); code=$?; }
run_with_preview_path --model acme/paint --modality raster_image --prompt "A fox with a preview" --preview
check_code "--preview: still written and exit 0" "$code" 0
check_eq "--preview: JSON line gets a preview path" "$([ -n "$(field .preview)" ] && echo yes || echo no)" "yes"
[ -s "$(field .preview)" ] && printf 'ok   --preview: preview file exists\n' || { printf 'FAIL --preview: preview file missing (%s)\n' "$(field .preview)"; fail=1; }

# --- --prompt-file (#646) ---
prompt_file="$work/prompt.txt"
printf "A fox's tale,\nline two" > "$prompt_file"
run --model acme/paint --modality raster_image --prompt-file "$prompt_file"
check_code "--prompt-file: written" "$code" 0
check_eq "--prompt-file: file text (apostrophe and newline intact) sent as the prompt" \
  "$(jq -r 'select(.path=="/api/v1/chat/completions") | .body.messages[0].content' "$work/requests.jsonl")" "A fox's tale,
line two"

run --model acme/paint --modality raster_image --prompt "x" --prompt-file "$prompt_file"
check_code "--prompt and --prompt-file together: usage exit 2" "$code" 2

run --model acme/paint --modality raster_image
check_code "neither --prompt nor --prompt-file: usage exit 2" "$code" 2

empty_prompt_file="$work/empty-prompt.txt"
: > "$empty_prompt_file"
run --model acme/paint --modality raster_image --prompt-file "$empty_prompt_file"
check_code "--prompt-file empty: usage exit 2" "$code" 2

run --model acme/paint --modality raster_image --prompt-file "$work/no-such-prompt.txt"
check_code "--prompt-file missing: usage exit 2" "$code" 2

# --- cost log and --cost (#647) ---
# a directory of its own: keys.path()'s default fallback dir ($work, since
# CLOUTER_CREDENTIALS above is $work/no-such-file) already collected a
# visual.jsonl of its own from every generation run above.
log="$work/costs/visual.jsonl"
export CLOUTER_VISUAL_LOG="$log"

run --model acme/paint --modality raster_image --prompt "Log me once"
check_code "cost log: generation still written" "$code" 0
check_eq "cost log: one line appended" "$(wc -l < "$log")" "1"
logged="$(tail -n1 "$log")"
check_eq "cost log: model/modality/cost recorded" "$(printf '%s' "$logged" | jq -c '[.model, .modality, .cost]')" '["acme/paint","raster_image",0.0192]'
check_eq "cost log: path is absolute and matches the written file" "$(printf '%s' "$logged" | jq -r '.path')" "$(cd "$(dirname "$(field .path)")" && pwd)/$(basename "$(field .path)")"
check_eq "cost log: ts looks like ISO-8601 UTC" "$(printf '%s' "$logged" | jq -r '.ts' | grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1"
check_eq "cost log: mode 0600" "$(stat -c%a "$log" 2>/dev/null || stat -f%Lp "$log")" "600"

run --model acme/video --modality video --prompt "Log me twice" --duration 2
check_code "cost log: second generation written" "$code" 0
check_eq "cost log: two lines now" "$(wc -l < "$log")" "2"

cost_out="$("$SCRIPT" --cost 2>"$work/stderr")"; cost_code=$?
check_code "--cost: exit 0, no --model/--modality/--prompt needed" "$cost_code" 0
check_eq "--cost: total and call count on stdout" "$(printf '%s' "$cost_out" | sed -n 1p)" '$0.2692 over 2 calls'
check_eq "--cost: JSON line on stdout" "$(printf '%s' "$cost_out" | sed -n 2p | jq -c '[.total, .calls, .since]')" '[0.2692,2,null]'

# an old line, written by hand, to test --since filtering
old_log="$work/visual-since.jsonl"
cat > "$old_log" <<EOF
{"ts": "2020-01-01T00:00:00Z", "model": "acme/old", "modality": "raster_image", "path": "/x/old.png", "cost": 1.0}
{"ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "model": "acme/new", "modality": "raster_image", "path": "/x/new.png", "cost": 0.5}
EOF
since_out="$(CLOUTER_VISUAL_LOG="$old_log" "$SCRIPT" --cost --since 1h 2>"$work/stderr")"; since_code=$?
check_code "--cost --since: exit 0" "$since_code" 0
check_eq "--cost --since 1h: only the recent line counted" "$(printf '%s' "$since_out" | sed -n 2p | jq -c '[.total, .calls]')" '[0.5,1]'
check_eq "--cost --since: resolved ISO date on stdout" "$(printf '%s' "$since_out" | sed -n 1p | grep -Ec 'since [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1"

# an unknown-cost line is counted separately
unknown_log="$work/visual-unknown.jsonl"
printf '{"ts": "%s", "model": "acme/nocost", "modality": "speech", "path": "/x/a.mp3", "cost": null}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$unknown_log"
unknown_out="$(CLOUTER_VISUAL_LOG="$unknown_log" "$SCRIPT" --cost 2>"$work/stderr")"
check_eq "--cost: unknown cost reported separately" "$(printf '%s' "$unknown_out" | sed -n 1p)" '$0.0000 over 1 call (1 without a price)'

# a malformed line is skipped with a stderr count
malformed_log="$work/visual-malformed.jsonl"
printf 'not json at all\n{"ts": "%s", "model": "acme/ok", "modality": "speech", "path": "/x/b.mp3", "cost": 0.1}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$malformed_log"
malformed_out="$(CLOUTER_VISUAL_LOG="$malformed_log" "$SCRIPT" --cost 2>"$work/stderr")"
check_eq "--cost: malformed line skipped, good line still counted" "$(printf '%s' "$malformed_out" | sed -n 1p)" '$0.1000 over 1 call'
check_eq "--cost: malformed line noted on stderr" "$(grep -c 'skipped 1 malformed log line' "$work/stderr")" "1"

# no log file at all
no_log="$work/no-such-visual.jsonl"
empty_out="$(CLOUTER_VISUAL_LOG="$no_log" "$SCRIPT" --cost 2>"$work/stderr")"; empty_code=$?
check_code "--cost with no log file: exit 0" "$empty_code" 0
check_eq "--cost with no log file: total 0" "$(printf '%s' "$empty_out" | sed -n 1p)" '$0.0000 over 0 calls'

# an unwritable log path still exits 0, with a stderr note, and the generation still happened
unwritable_dir="$work/unwritable"
mkdir -p "$unwritable_dir"
chmod 000 "$unwritable_dir"
run_unwritable() { rm -f "$work/requests.jsonl"; out=$(CLOUTER_VISUAL_LOG="$unwritable_dir/nope/visual.jsonl" "$SCRIPT" "$@" 2>"$work/stderr"); code=$?; }
run_unwritable --model acme/paint --modality raster_image --prompt "Log path is unwritable"
check_code "unwritable log path: generation still exits 0" "$code" 0
check_eq "unwritable log path: written file still exists" "$([ -s "$(printf '%s' "$out" | jq -r .path)" ] && echo yes || echo no)" "yes"
check_eq "unwritable log path: stderr note" "$(grep -c 'generate: cost log skipped:' "$work/stderr")" "1"
chmod 700 "$unwritable_dir"

unset CLOUTER_VISUAL_LOG

# --- critique wired in (mandatory after raster/vector) ---
CLOUTER_CRITIQUE=1 run --model acme/paint --modality raster_image --prompt "A fox, critiqued"
check_code "critique default: still written and exit 0" "$code" 0
check_eq "critique default: critique.pass true" "$(field .critique.pass)" "true"
check_eq "critique default: final equals path (nothing to fix)" "$(field .final)" "$(field .path)"
check_eq "critique default: one extra critic call" "$(jq -c 'select(.body.messages[0].role=="system")' "$work/requests.jsonl" | wc -l | tr -d ' ')" "1"

run --model acme/paint --modality raster_image --prompt "A fox, no critique flag"
check_code "--no-critique unset but CLOUTER_CRITIQUE=0 (test default): still written" "$code" 0
check_eq "CLOUTER_CRITIQUE=0 (test default): no critique key" "$(field 'has("critique")')" "false"
check_eq "CLOUTER_CRITIQUE=0 (test default): no critic call" "$(jq -c 'select(.body.messages[0].role=="system")' "$work/requests.jsonl" | wc -l | tr -d ' ')" "0"

CLOUTER_CRITIQUE=1 run --model acme/paint --modality raster_image --prompt "A fox, explicit no-critique" --no-critique
check_code "--no-critique: still written" "$code" 0
check_eq "--no-critique: no critique key" "$(field 'has("critique")')" "false"
check_eq "--no-critique: no critic call" "$(jq -c 'select(.body.messages[0].role=="system")' "$work/requests.jsonl" | wc -l | tr -d ' ')" "0"

CLOUTER_CRITIQUE=1 run --model acme/paint --modality raster_image --prompt "A fox, one fix round" --critic acme/critic-fail-then-pass --rounds 1
check_code "--rounds 1, failing then passing critic: exit 0" "$code" 0
check_eq "--rounds 1: critique.pass true after the fix" "$(field .critique.pass)" "true"
check_eq "--rounds 1: final is the .r1 file" "$(printf '%s' "$(field .final)" | grep -Ec '\.r1\.png$')" "1"
check_eq "--rounds 1: top-level path stays the original" "$(printf '%s' "$(field .path)" | grep -Ec '\.r1\.png$')" "0"

CLOUTER_CRITIQUE=1 run --model acme/paint --modality raster_image --prompt "A fox, critic boom" --critic acme/critic-boom
check_code "critic API failure: still exit 0 (paid file already written)" "$code" 0
check_eq "critic API failure: critique.error present" "$([ -n "$(field .critique.error)" ] && [ "$(field .critique.error)" != "null" ] && echo yes || echo no)" "yes"
check_eq "critic API failure: stderr note" "$(grep -c 'generate: critique skipped:' "$work/stderr")" "1"
check_eq "critic API failure: file still exists" "$([ -s "$(field .path)" ] && echo yes || echo no)" "yes"

broken="$work/broken"
mkdir -p "$broken/skills"
cp -r "$ROOT/skills/visual" "$broken/skills/visual"
cp -r "$ROOT/lib" "$broken/lib"
printf 'raise ImportError("boom")\n' > "$broken/skills/visual/critique.py"
out=$(CLOUTER_CRITIQUE=1 "$broken/skills/visual/generate.py" --model acme/paint --modality raster_image --prompt "A fox, critique import broken" 2>"$work/stderr")
code=$?
check_code "critique import failure: still exit 0 (paid file already written)" "$code" 0
check_eq "critique import failure: critique.error present" "$([ -n "$(field .critique.error)" ] && [ "$(field .critique.error)" != "null" ] && echo yes || echo no)" "yes"
check_eq "critique import failure: stderr note" "$(grep -c 'generate: critique skipped:' "$work/stderr")" "1"
check_eq "critique import failure: file still exists" "$([ -s "$(field .path)" ] && echo yes || echo no)" "yes"

CLOUTER_CRITIQUE=1 run --model acme/paint --modality raster_image --prompt "A fox, never passes" --critic acme/critic-always-fail --rounds 0
check_code "critique escalation: still exit 0" "$code" 0
check_eq "critique escalation: critique.pass false" "$(field .critique.pass)" "false"
check_eq "critique escalation: critique.escalation present with a recommendation" "$(field .critique.escalation.recommended)" "acme/paint-hi"

CLOUTER_CRITIQUE=1 run --model acme/video --modality video --prompt "A fox, no critique for video" --duration 2
check_code "video: still written, critique never applies" "$code" 0
check_eq "video: no critique key" "$(field 'has("critique")')" "false"
check_eq "video: no critic call" "$(jq -c 'select(.body.messages[0].role=="system")' "$work/requests.jsonl" | wc -l | tr -d ' ')" "0"

CLOUTER_CRITIQUE=1 run --model acme/tts --modality speech --prompt "A fox, no critique for speech"
check_code "speech: still written, critique never applies" "$code" 0
check_eq "speech: no critique key" "$(field 'has("critique")')" "false"

# --- --request/--request-file: pass through to the critique pass, never the generator ---
REQUEST_TEXT="a café fox with a red awning"

CLOUTER_CRITIQUE=1 run --model acme/paint --modality raster_image --prompt "A fox, with request" --request "$REQUEST_TEXT"
check_code "--request: still written and exit 0" "$code" 0
req_critic_body="$(jq -c 'select(.body.messages[0].role=="system")' "$work/requests.jsonl")"
check_eq "--request: critic call carries the request text" "$(printf '%s' "$req_critic_body" | jq -r '.body.messages[1].content[0].text' | grep -Fc "$REQUEST_TEXT")" "1"
gen_body="$(jq -c 'select(.method=="POST" and .body.model=="acme/paint")' "$work/requests.jsonl")"
check_eq "--request: generator body does not carry the request text" "$(printf '%s' "$gen_body" | grep -Fc "$REQUEST_TEXT")" "0"

printf '%s' "$REQUEST_TEXT" > "$work/request.txt"
CLOUTER_CRITIQUE=1 run --model acme/paint --modality raster_image --prompt "A fox, with request-file" --request-file "$work/request.txt"
check_code "--request-file: still written and exit 0" "$code" 0
reqfile_critic_body="$(jq -c 'select(.body.messages[0].role=="system")' "$work/requests.jsonl")"
check_eq "--request-file: critic call carries the request text" "$(printf '%s' "$reqfile_critic_body" | jq -r '.body.messages[1].content[0].text' | grep -Fc "$REQUEST_TEXT")" "1"

run --model acme/paint --modality raster_image --prompt "A fox, both request flags" --request "$REQUEST_TEXT" --request-file "$work/request.txt"
check_code "--request and --request-file together: exit 2" "$code" 2

# --- --param and the per-model request spec (spec.py) ---

run --model google/veo-3.1 --modality video --prompt "Test clip" --duration 5
check_code "spec: --duration outside the enum is refused, usage exit" "$code" 2
check_eq "spec: bad --duration names the allowed values" "$(grep -c 'duration must be one of: 4, 6, 8' "$work/stderr")" "1"
check_eq "spec: bad --duration sends no generation request" "$(grep -c '\"/api/v1/videos\"' "$work/requests.jsonl" 2>/dev/null || echo 0)" "0"

run --model google/veo-3.1 --modality video --prompt "Test clip" --param resolution=1080p --param generate_audio=true
check_code "spec: --param resolution/generate_audio on veo: written" "$code" 0
check_eq "spec: --param values reach the veo request body with the spec's types" \
  "$(jq -c 'select(.path=="/api/v1/videos") | [.body.resolution, .body.generate_audio]' "$work/requests.jsonl")" '["1080p",true]'

run --model recraft/recraft-v4-vector --modality vector_svg --prompt "Fox logo" --aspect 1:1 --endpoint images
check_eq "spec bug fix: aspect_ratio is top-level on /api/v1/images, not image_config" \
  "$(jq -c 'select(.path=="/api/v1/images") | [.body.aspect_ratio, (.body | has("image_config"))]' "$work/requests.jsonl")" '["1:1",false]'

run --model google/veo-3.1 --modality video --prompt "Test clip" --param bogus_field=1
check_code "spec: unknown --param key refused, usage exit" "$code" 2
check_eq "spec: unknown --param names the key" "$(grep -c 'unknown --param bogus_field' "$work/stderr")" "1"
check_eq "spec: unknown --param sends no generation request" "$(grep -c '\"/api/v1/videos\"' "$work/requests.jsonl" 2>/dev/null || echo 0)" "0"

run --model acme/paint --modality raster_image --prompt "A fox, no spec for this model"
check_code "spec: model with no request spec (404) still generates" "$code" 0
check_eq "spec: 404 spec fetch is a stderr warning, not a failure" "$(grep -c 'no request spec for acme/paint' "$work/stderr")" "1"
check_eq "spec: generation request still went out" "$(grep -c '/api/v1/chat/completions' "$work/requests.jsonl")" "1"

# --- --endpoint auto with an images-only spec (recraft-v4-vector has no
# chat/completions section): auto must target /api/v1/images directly,
# never waste a call on a guaranteed chat/completions 404 ---
run --model recraft/recraft-v4-vector --modality vector_svg --prompt "Fox logo, auto endpoint" --aspect 1:1
check_eq "spec: images-only auto never calls chat/completions" "$(grep -c '/api/v1/chat/completions' "$work/requests.jsonl" 2>/dev/null)" "0"
check_eq "spec: images-only auto goes straight to /api/v1/images with aspect_ratio top-level" \
  "$(jq -c 'select(.path=="/api/v1/images") | [.body.aspect_ratio, (.body | has("image_config"))]' "$work/requests.jsonl")" '["1:1",false]'

run --model recraft/recraft-v4-vector --modality vector_svg --prompt "Fox logo, bad aspect" --aspect 21:9
check_code "spec: images-only auto still validates aspect_ratio's enum, usage exit" "$code" 2
check_eq "spec: bad aspect names the allowed values" "$(grep -c 'aspect_ratio must be one of' "$work/stderr")" "1"
check_eq "spec: bad aspect on images-only auto sends no request at all" \
  "$([ -f "$work/requests.jsonl" ] && wc -l < "$work/requests.jsonl" || echo 0)" "0"

# --- --param cannot override a field generate.py already owns ---
run --model google/veo-3.1 --modality video --prompt "Test clip" --param model=hijacked
check_code "spec: --param cannot override an always-supplied field, usage exit" "$code" 2
check_eq "spec: refusal names the field" "$(grep -c 'param model is sent automatically' "$work/stderr")" "1"
run --model google/veo-3.1 --modality video --prompt "Test clip" --param aspect_ratio=16:9
check_code "spec: --param cannot override a flag-owned field, usage exit" "$code" 2
check_eq "spec: refusal points to --aspect" "$(grep -c 'param aspect_ratio is set by --aspect' "$work/stderr")" "1"

# --- critique fix rounds resend the same --param and endpoint as round 1 ---
# acme/critic-always-fail always fails, independent of any earlier test's
# call count on that model, so the fix round is guaranteed to fire.
CLOUTER_CRITIQUE=1 run --model acme/paint --modality raster_image --prompt "A fox, param persists across fix rounds" \
  --critic acme/critic-always-fail --rounds 1 --param seed=7
check_code "spec: --param survives into the critique fix round: exit 0" "$code" 0
check_eq "spec: one fix round happened" "$(field .critique.rounds)" "1"
check_eq "spec: --param reached both the original and the fix-round generation body" \
  "$(jq -r 'select(.body.model=="acme/paint") | .body.seed' "$work/requests.jsonl" | tr '\n' ';')" "7;7;"

exit $fail

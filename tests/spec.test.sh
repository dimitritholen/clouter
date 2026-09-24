#!/usr/bin/env bash
# Tests for skills/visual/spec.py: parse() against the four saved llms.txt
# fixtures under tests/fixtures/llms (real OpenRouter output, 2026-09-24),
# then the CLI against a stand-in HTTP server for the fetch/404/garbled
# paths. Needs python3 and jq; no key, no network.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/visual/spec.py"
FIXTURES="$ROOT/tests/fixtures/llms"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null' EXIT

check_code() { if [ "$2" -eq "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (exit %s, want %s): %s\n' "$1" "$2" "$3" "$(cat "$work/stderr" 2>/dev/null)"; fail=1; fi; }
check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }

parse_fixture() {
    # parse_fixture <fixture-file> <model-id> -> JSON on stdout
    python3 -c "
import sys
sys.path.insert(0, '$ROOT/skills/visual')
import json, spec
text = open('$1').read()
print(json.dumps(spec.parse(text, '$2')))
"
}

# --- recraft: vector image, single endpoint ---
out="$(parse_fixture "$FIXTURES/recraft__recraft-v4-vector.txt" recraft/recraft-v4-vector)"
check_eq "recraft: one endpoint" "$(printf '%s' "$out" | jq '.endpoints | length')" "1"
check_eq "recraft: images endpoint path" "$(printf '%s' "$out" | jq -r '.endpoints[0].path')" "/api/v1/images"
check_eq "recraft: aspect_ratio enum has 6 values" "$(printf '%s' "$out" | jq '.endpoints[0].fields.aspect_ratio.enum | length')" "6"
check_eq "recraft: output_format is svg" "$(printf '%s' "$out" | jq -c '.endpoints[0].fields.output_format.enum')" '["svg"]'
check_eq "recraft: n is an integer 1-6" "$(printf '%s' "$out" | jq -c '.endpoints[0].fields.n | [.type, .min, .max]')" '["integer",1,6]'
check_eq "recraft: model and prompt required" "$(printf '%s' "$out" | jq -c '[.endpoints[0].fields.model.required, .endpoints[0].fields.prompt.required]')" '[true,true]'
check_eq "recraft: aspect_ratio optional" "$(printf '%s' "$out" | jq '.endpoints[0].fields.aspect_ratio.required')" "false"

# --- veo: video, duration/size/resolution enums, conditional-required prompt ---
out="$(parse_fixture "$FIXTURES/google__veo-3.1.txt" google/veo-3.1)"
check_eq "veo: videos endpoint path" "$(printf '%s' "$out" | jq -r '.endpoints[0].path')" "/api/v1/videos"
check_eq "veo: duration is an integer enum 4,6,8" "$(printf '%s' "$out" | jq -c '.endpoints[0].fields.duration | [.type, .enum]')" '["integer",[4,6,8]]'
check_eq "veo: prompt not unconditionally required, condition kept" "$(printf '%s' "$out" | jq -r '.endpoints[0].fields.prompt | [.required, .description] | @json')" '[false,"optional when frame_images is set, otherwise required"]'
check_eq "veo: frame_images is an array" "$(printf '%s' "$out" | jq -r '.endpoints[0].fields.frame_images.type')" "array"
check_eq "veo: input_references is an array" "$(printf '%s' "$out" | jq -r '.endpoints[0].fields.input_references.type')" "array"
check_eq "veo: generate_audio is boolean" "$(printf '%s' "$out" | jq -r '.endpoints[0].fields.generate_audio.type')" "boolean"
check_eq "veo: no field silently dropped" "$(printf '%s' "$out" | jq '.endpoints[0].fields | keys | length')" "11"

# --- gemini image: two endpoint sections (chat/completions and images) ---
out="$(parse_fixture "$FIXTURES/google__gemini-3.1-flash-lite-image.txt" google/gemini-3.1-flash-lite-image)"
check_eq "gemini image: two endpoints" "$(printf '%s' "$out" | jq '.endpoints | length')" "2"
check_eq "gemini image: first is chat/completions" "$(printf '%s' "$out" | jq -r '.endpoints[0].path')" "/api/v1/chat/completions"
check_eq "gemini image: second is images" "$(printf '%s' "$out" | jq -r '.endpoints[1].path')" "/api/v1/images"
check_eq "gemini image: typeless passthrough field kept, not dropped" "$(printf '%s' "$out" | jq -c '.endpoints[0].fields.max_tokens | [.type, .required]')" '[null,false]'
check_eq "gemini image: input_references caps at 14" "$(printf '%s' "$out" | jq '.endpoints[1].fields.input_references.max')" "14"
check_eq "gemini image: n is 1-1" "$(printf '%s' "$out" | jq -c '.endpoints[1].fields.n | [.min, .max]')" '[1,1]'

# --- gemini tts: voice enum, response_format default ---
out="$(parse_fixture "$FIXTURES/google__gemini-3.8-flash-tts.txt" google/gemini-3.8-flash-tts)"
check_eq "tts: one endpoint, audio/speech" "$(printf '%s' "$out" | jq -r '.endpoints[0].path')" "/api/v1/audio/speech"
check_eq "tts: voice enum is non-empty" "$(printf '%s' "$out" | jq '.endpoints[0].fields.voice.enum | length > 0')" "true"
check_eq "tts: response_format includes mp3" "$(printf '%s' "$out" | jq '.endpoints[0].fields.response_format.enum | index("mp3") != null')" "true"
check_eq "tts: response_format defaults to pcm" "$(printf '%s' "$out" | jq -r '.endpoints[0].fields.response_format.default')" "pcm"

# --- CLI against a stand-in server ---
mkdir -p "$work/route"
cp "$FIXTURES/google__veo-3.1.txt" "$work/route/google__veo-3.1.txt"
python3 - "$work" <<'EOF_SERVER' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
work = sys.argv[1]
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        with open(f"{work}/requests.log", "a") as f:
            f.write(f"{self.path}\n")
        if self.path == "/google/veo-3.1/llms.txt":
            out = open(f"{work}/route/google__veo-3.1.txt", "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
        elif self.path == "/garbled/model/llms.txt":
            out = b"not a real llms.txt, no Request fields here at all"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
        else:
            self.send_response(404); self.end_headers()
server = HTTPServer(("127.0.0.1", 0), Handler)
open(f"{work}/port", "w").write(str(server.server_port))
server.serve_forever()
EOF_SERVER
server_pid=$!
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || { printf 'FAIL stand-in server did not start\n'; exit 1; }
export OPENROUTER_BASE_URL="http://127.0.0.1:$(cat "$work/port")"

run() { out=$("$SCRIPT" "$@" 2>"$work/stderr"); code=$?; }

run google/veo-3.1
check_code "CLI: veo-3.1 via stand-in server" "$code" 0
check_eq "CLI: prints the parsed spec" "$(printf '%s' "$out" | jq -r '.endpoints[0].path')" "/api/v1/videos"
check_eq "CLI: source is the fetched URL" "$(printf '%s' "$out" | jq -r '.source')" "$OPENROUTER_BASE_URL/google/veo-3.1/llms.txt"

run no/such-model
check_code "CLI: 404 exits 1" "$code" 1
check_eq "CLI: 404 explained, one line, no traceback" "$(wc -l < "$work/stderr" | tr -d ' ')" "1"
check_eq "CLI: 404 message names the status" "$(grep -c 'answered 404' "$work/stderr")" "1"

run garbled/model
check_code "CLI: garbled text exits 1" "$code" 1
check_eq "CLI: garbled text explained, one line, no traceback" "$(wc -l < "$work/stderr" | tr -d ' ')" "1"
check_eq "CLI: garbled text message names the model" "$(grep -c 'no Request fields' "$work/stderr")" "1"

run
check_code "CLI: no model-id, usage exit 2" "$code" 2

exit $fail

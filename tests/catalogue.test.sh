#!/usr/bin/env bash
# Tests for skills/visual/catalogue.py against fixture JSON shaped like the
# live OpenRouter lists of 2026-09-22: the price sort, the unit conversions
# and the vector flag on Recraft-shaped entries, for image, video and
# speech. Needs python3 and jq; no key, no network.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/visual/catalogue.py"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null' EXIT

cat > "$work/image.json" <<'EOF_JSON'
{"data": [
 {"id": "openai/gpt-image-1", "name": "OpenAI: GPT Image 1", "description": "Raster image model.",
  "pricing": {"prompt": "0.000005", "completion": "0", "image_output": "0.00004"}},
 {"id": "recraft/recraft-v4.1-vector", "name": "Recraft: Recraft V4.1 Vector",
  "description": "Recraft V4.1 Vector is the vector (SVG) variant of Recraft V4.1.",
  "pricing": {"prompt": "0", "completion": "0", "image_token": "0.0000191616766467066", "image_output": "0.0000191616766467066"}},
 {"id": "recraft/recraft-v4.1", "name": "Recraft: Recraft V4.1", "description": "Recraft V4.1 is an image generation model tuned for high aesthetics.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.00000838323353293413"}},
 {"id": "recraft/recraft-v4-styles-vector", "name": "Recraft: Recraft V4 Styles Vector",
  "description": "Recraft V4 Styles Vector is a style-consistent image generation model from Recraft. Every request requires at least one style reference.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.0000119760479041916"}},
 {"id": "acme/svg-maker", "name": "Acme SVG Maker", "description": "Draws things.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.00001"}},
 {"id": "openrouter/auto", "name": "Auto Router", "description": "Picks a model.", "pricing": {"prompt": "-1", "completion": "-1"}},
 {"id": "x-ai/grok-imagine-image-2.0", "name": "xAI: Grok Imagine", "description": "Image model with a per-input-image price too.",
  "pricing": {"prompt": "0", "completion": "0", "image": "0.01", "image_output": "0.00000958083832335329"}},
 {"id": "acme/alpha-native", "name": "Acme Alpha Native", "description": "Publishes background support.",
  "pricing": {"prompt": "-1", "completion": "-1"}, "supported_parameters": ["background", "seed"]},
 {"id": "openai/gpt-5-image-mini", "name": "OpenAI: GPT-5 Image Mini", "description": "Raster image model.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.00005"}, "supported_parameters": ["seed", "size"],
  "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["image"]}},
 {"id": "acme/text-only-input", "name": "Acme Text Only Input", "description": "Takes a prompt, no reference.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.00002"},
  "architecture": {"input_modalities": ["text"], "output_modalities": ["image"]}}
]}
EOF_JSON
cat > "$work/video.json" <<'EOF_JSON'
{"data": [
 {"id": "runway/gen-4.5", "name": "Runway: Gen-4.5", "description": "Video.", "pricing_skus": {"cents_per_second_output": "12"}},
 {"id": "alibaba/wan-3.0", "name": "Alibaba: Wan 3.0", "description": "Video.",
  "pricing_skus": {"duration_seconds_480p": "0.05", "duration_seconds_720p": "0.1", "duration_seconds_1080p": "0.2"}},
 {"id": "bytedance/seedance-2.0", "name": "ByteDance: Seedance 2.0", "description": "Video by the token.",
  "pricing_skus": {"video_tokens": "0.000007", "video_tokens_4k": "0.000004"}},
 {"id": "black-forest-labs/flux-video-upscale", "name": "FLUX Video Upscale", "description": "Upscaler.",
  "pricing_skus": {"cents_per_megapixel_second_precise": "7.5", "cents_per_megapixel_second_creative": "10.5"}},
 {"id": "x-ai/grok-imagine-video", "name": "xAI: Grok Imagine Video", "description": "Video.",
  "pricing_skus": {"cents_per_image_input": "0.2", "cents_per_video_output_second_480p": "5", "cents_per_video_output_second_720p": "7"}},
 {"id": "acme/unpriced-video", "name": "Unpriced", "description": "No SKUs yet.", "pricing_skus": {}}
]}
EOF_JSON
cat > "$work/speech.json" <<'EOF_JSON'
{"data": [
 {"id": "minimax/speech-2.8-hd", "name": "MiniMax: Speech 2.8 HD", "description": "TTS.", "pricing": {"prompt": "0.0001", "completion": "0"}},
 {"id": "deepgram/flux-tts:free", "name": "Deepgram: Flux TTS (free)", "description": "TTS.", "pricing": {"prompt": "0", "completion": "0"}},
 {"id": "hexgrad/kokoro-82m", "name": "Kokoro 82M", "description": "TTS.", "pricing": {"prompt": "0.000004", "completion": "0"}}
]}
EOF_JSON

python3 - "$work" <<'EOF_SERVER' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
work = sys.argv[1]
ROUTES = {"/api/v1/models?output_modalities=image": "image.json",
          "/api/v1/videos/models": "video.json",
          "/api/v1/models?output_modalities=speech": "speech.json"}
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        with open(f"{work}/requests.log", "a") as f:
            f.write(f"{self.path} {self.headers.get('Authorization')}\n")
        name = ROUTES.get(self.path)
        if name is None:
            self.send_response(404); self.end_headers(); return
        out = open(f"{work}/{name}", "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
server = HTTPServer(("127.0.0.1", 0), Handler)
open(f"{work}/port", "w").write(str(server.server_port))
server.serve_forever()
EOF_SERVER
server_pid=$!
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || { printf 'FAIL stand-in server did not start\n'; exit 1; }
export OPENROUTER_BASE_URL="http://127.0.0.1:$(cat "$work/port")"
export CLOUTER_CREDENTIALS="$work/no-such-file"
unset OPENROUTER_API_KEY

check_code() { if [ "$2" -eq "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (exit %s, want %s): %s\n' "$1" "$2" "$3" "$(cat "$work/stderr")"; fail=1; fi; }
check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }
run() { out=$("$SCRIPT" "$@" 2>"$work/stderr"); code=$?; }

run raster_image
check_code "raster_image: listed" "$code" 0
check_eq "raster sorted cheap to expensive, unpriced last" "$(printf '%s' "$out" | jq -c '[.[].id]')" '["recraft/recraft-v4.1","x-ai/grok-imagine-image-2.0","acme/text-only-input","openai/gpt-image-1","openai/gpt-5-image-mini","acme/alpha-native","openrouter/auto"]'
check_eq "raster price is image_output per image token (nano-USD)" "$(printf '%s' "$out" | jq -c '.[0] | [(.price*1e9|round), .unit, .vector]')" '[8383,"image token",false]'
check_eq "per-input-image price ignored" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="x-ai/grok-imagine-image-2.0") | (.price*1e9|round)')" "9581"
check_eq "negative price means unpriced" "$(printf '%s' "$out" | jq -c '.[] | select(.id=="openrouter/auto") | .price')" "null"
check_eq "no vector model in the raster list" "$(printf '%s' "$out" | jq '[.[] | select(.vector)] | length')" "0"
check_eq "alpha: openai id allowlist, declared supported_parameters, and the rest false" "$(printf '%s' "$out" | jq -c '[.[] | {id, alpha}]')" '[{"id":"recraft/recraft-v4.1","alpha":false},{"id":"x-ai/grok-imagine-image-2.0","alpha":false},{"id":"acme/text-only-input","alpha":false},{"id":"openai/gpt-image-1","alpha":true},{"id":"openai/gpt-5-image-mini","alpha":true},{"id":"acme/alpha-native","alpha":true},{"id":"openrouter/auto","alpha":false}]'
check_eq "alpha: allowlist wins even when supported_parameters lacks background" "$(printf '%s' "$out" | jq -c '.[] | select(.id=="openai/gpt-5-image-mini") | .alpha')" "true"
check_eq "reference_supported: true when architecture.input_modalities has image" "$(printf '%s' "$out" | jq -c '.[] | select(.id=="openai/gpt-5-image-mini") | .reference_supported')" "true"
check_eq "reference_supported: false when input_modalities is text only" "$(printf '%s' "$out" | jq -c '.[] | select(.id=="acme/text-only-input") | .reference_supported')" "false"
check_eq "reference_supported: false when no architecture field at all" "$(printf '%s' "$out" | jq -c '.[] | select(.id=="openai/gpt-image-1") | .reference_supported')" "false"

run vector_svg
check_code "vector_svg: listed" "$code" 0
check_eq "vector flag from id (recraft) and from name (svg)" "$(printf '%s' "$out" | jq -c '[.[].id]')" '["acme/svg-maker","recraft/recraft-v4-styles-vector","recraft/recraft-v4.1-vector"]'
check_eq "styles model flagged as needing a reference, plain vector not" "$(printf '%s' "$out" | jq -c '[.[] | select(.id | startswith("recraft/")) | .reference_required]')" '[true,false]'
check_eq "recraft vector keeps name, description and price" "$(printf '%s' "$out" | jq -c '.[2] | [.name, (.description | startswith("Recraft V4.1 Vector is the vector")), (.price*1e9|round), .unit, .vector]')" '["Recraft: Recraft V4.1 Vector",true,19162,"image token",true]'
check_eq "raster and vector split the image list" "$(grep -c 'output_modalities=image' "$work/requests.log")" "2"
check_eq "no key: no Authorization header" "$(grep -c ' None$' "$work/requests.log")" "2"

run video
check_code "video: listed" "$code" 0
check_eq "video sorted: seconds first cheap to expensive, then tokens, megapixels, unpriced" "$(printf '%s' "$out" | jq -c '[.[].id]')" '["alibaba/wan-3.0","x-ai/grok-imagine-video","runway/gen-4.5","bytedance/seedance-2.0","black-forest-labs/flux-video-upscale","acme/unpriced-video"]'
check_eq "duration_seconds: lowest resolution SKU in USD" "$(printf '%s' "$out" | jq -c '.[0] | [.price, .unit]')" '[0.05,"second"]'
check_eq "cents_per_second_output converted to USD" "$(printf '%s' "$out" | jq -c '.[] | select(.id=="runway/gen-4.5") | [.price, .unit]')" '[0.12,"second"]'
check_eq "cents_per_video_output_second: per-image-input SKU ignored" "$(printf '%s' "$out" | jq -c '.[] | select(.id=="x-ai/grok-imagine-video") | [.price, .unit]')" '[0.05,"second"]'
check_eq "video_tokens: lowest token SKU" "$(printf '%s' "$out" | jq -c '.[] | select(.id=="bytedance/seedance-2.0") | [(.price*1e9|round), .unit]')" '[4000,"video token"]'
check_eq "megapixel seconds converted from cents" "$(printf '%s' "$out" | jq -c '.[] | select(.id=="black-forest-labs/flux-video-upscale") | [.price, .unit]')" '[0.075,"megapixel second"]'
check_eq "empty SKUs: unpriced" "$(printf '%s' "$out" | jq -c '.[] | select(.id=="acme/unpriced-video") | .price')" "null"
check_eq "video list fetched from the videos endpoint" "$(grep -c '^/api/v1/videos/models' "$work/requests.log")" "1"

run speech
check_code "speech: listed" "$code" 0
check_eq "speech sorted, free first, price per character from prompt" "$(printf '%s' "$out" | jq -c '[.[] | [.id, (.price*1e9|round), .unit]]')" '[["deepgram/flux-tts:free",0,"character"],["hexgrad/kokoro-82m",4000,"character"],["minimax/speech-2.8-hd",100000,"character"]]'

run speech 1
check_eq "limit argument cuts the list" "$(printf '%s' "$out" | jq 'length')" "1"

OPENROUTER_API_KEY=k run speech
check_eq "key present: sent as bearer" "$(grep -c 'speech Bearer k$' "$work/requests.log")" "1"

run --reference-supported openai/gpt-5-image-mini
check_code "--reference-supported: known model, exit 0" "$code" 0
check_eq "--reference-supported: true for an image-input model" "$out" '{"model": "openai/gpt-5-image-mini", "reference_supported": true}'

run --reference-supported openai/gpt-image-1
check_code "--reference-supported: known model without image input, exit 0" "$code" 0
check_eq "--reference-supported: false for a text-only model" "$out" '{"model": "openai/gpt-image-1", "reference_supported": false}'

run --reference-supported no/such-model
check_code "--reference-supported: unknown model id, exit 2" "$code" 2

run nope
check_code "unknown modality: usage exit 2" "$code" 2
OPENROUTER_BASE_URL="http://127.0.0.1:1" run video
check_code "unreachable: exit 4" "$code" 4
check_eq "unreachable explained" "$(grep -c '^catalogue: GET /api/v1/videos/models failed' "$work/stderr")" "1"

exit $fail

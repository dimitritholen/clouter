#!/usr/bin/env bash
# Tests for skills/visual/route.py, the UserPromptSubmit visual router,
# against one stand-in that plays both Jev (the decisions endpoint) and
# OpenRouter's model lists. Needs python3 and jq; no key, no network.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/visual/route.py"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null' EXIT

# Stand-in: the modality answer follows words in the prompt ("unsure" gives
# low confidence, "boom" a 500, "split" vector_svg 0.55 / raster_image 0.42,
# "wordy" a text_or_code majority, "noprobs" no probabilities), the model answer prefers a Recraft id when
# one is offered. Model lists are small fixtures with the live shapes.
python3 - "$work" <<'EOF_SERVER' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
work = sys.argv[1]

IMAGE = {"data": [
 {"id": "openai/gpt-image-1", "name": "OpenAI: GPT Image 1", "description": "Raster images.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.00004"}},
 {"id": "recraft/recraft-v4.1-vector", "name": "Recraft: Recraft V4.1 Vector",
  "description": "Recraft V4.1 Vector is the vector (SVG) variant of Recraft V4.1, tuned for high aesthetics.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.0000191616766467066"}},
 {"id": "recraft/recraft-v4-styles-vector", "name": "Recraft: Recraft V4 Styles Vector",
  "description": "Style-consistent vector model. Every request requires at least one style reference.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.000001"}},
 {"id": "acme/svg-cheap", "name": "Acme SVG Cheap", "description": "Cheap svg drawings.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.000005"}},
 {"id": "acme/svg-mid", "name": "Acme SVG Mid", "description": "Mid svg drawings.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.00001"}},
 {"id": "acme/svg-dear", "name": "Acme SVG Dear", "description": "Dear svg drawings.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.00009"}},
 {"id": "acme/svg-unpriced", "name": "Acme SVG Unpriced", "description": "svg, no price.", "pricing": {"prompt": "0", "completion": "0"}},
 {"id": "recraft/recraft-v4.1", "name": "Recraft: Recraft V4.1", "description": "Raster.",
  "pricing": {"prompt": "0", "completion": "0", "image_output": "0.00000838323353293413"}}
]}
VIDEO = {"data": [
 {"id": "google/veo-3.1-lite", "name": "Google: Veo 3.1 Lite", "description": "Video.", "pricing_skus": {"duration_seconds_without_audio_720p": "0.03"}},
 {"id": "runway/gen-4.5", "name": "Runway: Gen-4.5", "description": "Video.", "pricing_skus": {"cents_per_second_output": "12"}}
]}
SPEECH = {"data": [
 {"id": "hexgrad/kokoro-82m", "name": "Kokoro 82M", "description": "TTS.", "pricing": {"prompt": "0.000004", "completion": "0"}}
]}

def modality_for(prompt):
    p = prompt.lower()
    if "svg" in p or "vector" in p: return "vector_svg"
    if "video" in p: return "video"
    if "voice" in p or "narrate" in p: return "speech"
    if "picture" in p or "logo" in p: return "raster_image"
    return "text_or_code"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, obj):
        out = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def record(self, body=None):
        with open(f"{work}/requests.jsonl", "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "body": body}) + "\n")
    def do_GET(self):
        self.record()
        fixture = {"/api/v1/models?output_modalities=image": IMAGE, "/api/v1/videos/models": VIDEO,
                   "/api/v1/models?output_modalities=speech": SPEECH}.get(self.path)
        if fixture is None:
            self.reply(404, {"error": {"message": "no"}}); return
        if "catalogue-down" in open(f"{work}/flags").read() if __import__("os").path.exists(f"{work}/flags") else False:
            self.reply(503, {"error": {"message": "down"}}); return
        self.reply(200, fixture)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.record(body)
        prompt = body["state"]["prompt"]
        if "boom" in prompt.lower():
            self.reply(500, {"error": {"message": "stand-in exploded"}}); return
        answers = {}
        if "modality" in body["questions"]:
            choice = modality_for(prompt)
            conf = 0.3 if "unsure" in prompt.lower() else 0.9
            probs = {k: 0.02 for k in body["questions"]["modality"]["criteria"]}
            probs[choice] = conf
            if "split" in prompt.lower():
                choice, conf = "vector_svg", 0.55
                probs = {"vector_svg": 0.55, "raster_image": 0.42, "text_or_code": 0.03, "video": 0.0, "speech": 0.0}
            if "wordy" in prompt.lower():
                choice, conf = "text_or_code", 0.7
                probs = {"text_or_code": 0.7, "raster_image": 0.2, "vector_svg": 0.1, "video": 0.0, "speech": 0.0}
            answers["modality"] = {"type": "choice", "choice": choice, "confidence": conf, "probabilities": probs}
            if "noprobs" in prompt.lower():
                del answers["modality"]["probabilities"]
        if "model" in body["questions"]:
            ids = list(body["questions"]["model"]["criteria"])
            pick = next((i for i in ids if i.startswith("recraft/")), ids[0])
            conf = 0.3 if "undecided" in prompt.lower() else 0.62
            probs = {i: round((1 - conf) / max(1, len(ids) - 1), 3) for i in ids}
            probs[pick] = conf
            answers["model"] = {"type": "choice", "choice": pick, "confidence": conf, "probabilities": probs}
        self.reply(200, {"model": "jev-stand-in", "id": "req-1", "answers": answers,
                         "usage": {"input_tokens": 1, "output_tokens": 1}})

server = HTTPServer(("127.0.0.1", 0), Handler)
open(f"{work}/port", "w").write(str(server.server_port))
server.serve_forever()
EOF_SERVER
server_pid=$!
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || { printf 'FAIL stand-in server did not start\n'; exit 1; }
export OPENROUTER_BASE_URL="http://127.0.0.1:$(cat "$work/port")"
export CLOUTER_CREDENTIALS="$work/no-such-file"
export OPENROUTER_API_KEY="test-key"
unset TYPESAFE_API_KEY CLOUTER_VISUAL CLOUTER_VISUAL_FLOOR

check_code() { if [ "$2" -eq "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (exit %s, want %s): %s\n' "$1" "$2" "$3" "$(cat "$work/stderr")"; fail=1; fi; }
check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }
run() { # prompt -> $out, $code, requests.jsonl reset
  rm -f "$work/requests.jsonl"
  out=$(jq -cn --arg p "$1" '{session_id: "s", transcript_path: "/t", cwd: "/c", hook_event_name: "UserPromptSubmit", prompt: $p}' | "$SCRIPT" 2>"$work/stderr"); code=$?
}
requests() { [ -f "$work/requests.jsonl" ] && wc -l < "$work/requests.jsonl" | tr -d " " || echo 0; }
ctx() { printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext'; }

run "Fix the failing test in auth.py and rename the helper"
check_code "coding prompt: exit 0" "$code" 0
check_eq "coding prompt: silent" "$out" ""
check_eq "coding prompt: no request at all" "$(requests)" "0"

run "make me a hero graphic for the landing page"
check_eq "prefilter: hero graphic hits" "$(requests)" "1"
run "an illustration of a fox in the woods"
check_eq "prefilter: illustration of hits" "$(requests)" "1"
run "I need a banner for the top of the page"
check_eq "prefilter: banner for hits" "$(requests)" "1"
run "ship an icon set for the toolbar"
check_eq "prefilter: icon set hits" "$(requests)" "1"
run "some artwork for the splash screen"
check_eq "prefilter: artwork hits" "$(requests)" "1"
run "a picture of a mountain at dawn"
check_eq "prefilter: picture of hits" "$(requests)" "3"
run "render a hero image for the homepage"
check_eq "prefilter: render a hits" "$(requests)" "1"
run "narrate this paragraph for me"
check_eq "prefilter: narrate hits" "$(requests)" "3"
run "record a voice-over for the intro"
check_eq "prefilter: voice-over hits" "$(requests)" "3"
run "make an audio clip of the jingle"
check_eq "prefilter: audio clip hits" "$(requests)" "1"
run "put together an animation for the loader"
check_eq "prefilter: animation hits" "$(requests)" "1"

run "fix the infinite React render loop in this component"
check_eq "prefilter: React render loop is not a hit" "$(requests)" "0"
run "update the favicon.ico path in the manifest"
check_eq "prefilter: favicon.ico is not a hit" "$(requests)" "0"
run "step back and look at the big picture here"
check_eq "prefilter: big picture is not a hit" "$(requests)" "0"

run "make me an SVG illustration of a fox"
check_code "svg prompt: exit 0" "$code" 0
check_eq "svg prompt: hook JSON for UserPromptSubmit" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "UserPromptSubmit"
check_eq "svg prompt: modality named" "$(ctx | grep -c 'asks for a vector svg')" "1"
check_eq "svg prompt: recraft vector first and Recommended" "$(ctx | grep -c '^1\. recraft/recraft-v4.1-vector (Recommended)')" "1"
check_eq "svg prompt: then cheap to expensive" "$(ctx | grep -o '^[23]\. [^ ]*' | tr '\n' ' ')" "2. acme/svg-cheap 3. acme/svg-mid "
check_eq "svg prompt: prices in the labels" "$(ctx | grep -c 'per 1K image tokens')" "3"
check_eq "svg prompt: Jev probabilities in the labels" "$(ctx | grep -c 'Jev 0\.[0-9][0-9]')" "3"
check_eq "svg prompt: stay-with-Claude option is fourth" "$(ctx | grep -c '^4\. Stay with Claude')" "1"
check_eq "svg prompt: asks with AskUserQuestion" "$(ctx | grep -c 'AskUserQuestion')" "1"
check_eq "svg prompt: names generate.py with modality" "$(ctx | grep -c 'generate.py" --model <chosen id> --modality vector_svg')" "1"
check_eq "svg prompt: generate.py runs with --no-critique" "$(ctx | grep -c -- '--no-critique')" "1"
check_eq "svg prompt: names studio.py push" "$(ctx | grep -c 'studio.py" push')" "1"
check_eq "svg prompt: names studio.py wait" "$(ctx | grep -c 'studio.py wait --session')" "1"
check_eq "svg prompt: suggests defects before pushing (vector)" "$(ctx | grep -c -- '--suggest --model <chosen id> --out <defects.json>')" "1"
check_eq "svg prompt: push carries --defects-file (vector)" "$(ctx | grep -c -- '--defects-file <defects.json> \[--message-file <note>\]')" "1"
check_eq "svg prompt: points at the Studio loop in SKILL.md" "$(ctx | grep -c 'Studio loop.*SKILL.md')" "1"
check_eq "svg prompt: command carries --request-file" "$(ctx | grep -c -- '--request-file')" "1"
req_file="$(ctx | grep -o -- '--request-file [^ ]*' | head -n1 | cut -d' ' -f2)"
check_eq "svg prompt: request file holds the prompt verbatim" "$(cat "$req_file")" "make me an SVG illustration of a fox"
check_eq "two Jev calls and one catalogue fetch" "$(jq -r '.method + " " + .path' "$work/requests.jsonl" | tr '\n' ';')" "POST /api/alpha/decisions;GET /api/v1/models?output_modalities=image;POST /api/alpha/decisions;"
check_eq "modality question offers the five labels" "$(jq -c 'select(.method=="POST" and .body.questions.modality) | .body.questions.modality.criteria | keys' "$work/requests.jsonl" | head -n 1)" '["raster_image","speech","text_or_code","vector_svg","video"]'
check_eq "model question: priced vector models only, no raster, no unpriced, no reference-only" "$(jq -c 'select(.body.questions.model) | .body.questions.model.criteria | keys' "$work/requests.jsonl")" '["acme/svg-cheap","acme/svg-dear","acme/svg-mid","recraft/recraft-v4.1-vector"]'
check_eq "model criteria carry description and price" "$(jq -r 'select(.body.questions.model) | .body.questions.model.criteria["recraft/recraft-v4.1-vector"]' "$work/requests.jsonl" | grep -c 'Recraft V4.1 Vector is the vector.*Price \$0.0192 per 1K image tokens')" "1"
check_eq "prompt goes to Jev as state" "$(jq -r 'select(.method=="POST") | .body.state.prompt' "$work/requests.jsonl" | sort -u)" "make me an SVG illustration of a fox"

run "Undecided: draw a vector fox"
check_code "low model confidence: exit 0" "$code" 0
check_eq "low model confidence: no Recommended, cheapest first" "$(ctx | grep -c 'Recommended')" "0"
check_eq "low model confidence: cheap to expensive" "$(ctx | grep -o '^[123]\. [^ ]*' | tr '\n' ' ')" "1. acme/svg-cheap 2. acme/svg-mid 3. recraft/recraft-v4.1-vector "

run "Make a short video of a sunrise"
check_eq "video prompt: per-second prices" "$(ctx | grep -c 'per second')" "2"
check_eq "video prompt: veo first (cheapest, no recraft to pick)" "$(ctx | grep -c '^1\. google/veo-3.1-lite (Recommended)')" "1"
check_eq "video prompt: names studio.py push" "$(ctx | grep -c 'studio.py" push')" "1"
check_eq "video prompt: names studio.py wait" "$(ctx | grep -c 'studio.py wait --session')" "1"
check_eq "video prompt: no --suggest (not raster/vector)" "$(ctx | grep -c -- '--suggest')" "0"
check_eq "video prompt: no --defects-file (not raster/vector)" "$(ctx | grep -c -- '--defects-file')" "0"

run "Narrate this paragraph with a warm voice"
check_eq "speech prompt: per-character price" "$(ctx | grep -c 'per 1K characters')" "1"
check_eq "speech prompt: names studio.py push" "$(ctx | grep -c 'studio.py" push')" "1"
check_eq "speech prompt: names studio.py wait" "$(ctx | grep -c 'studio.py wait --session')" "1"
check_eq "speech prompt: no --suggest (not raster/vector)" "$(ctx | grep -c -- '--suggest')" "0"

run "I like the image you painted with words, unsure though"
check_code "low modality confidence: exit 0" "$code" 0
check_eq "low modality confidence: silent" "$out" ""
check_eq "low modality confidence: no catalogue fetch, no second Jev call" "$(requests)" "1"

run "Explain how the image cache in this repo works"
check_eq "prefilter hit but Jev says text_or_code: silent" "$out" ""
check_eq "text_or_code: one Jev call only" "$(requests)" "1"
check_eq "text_or_code: no studio.py push" "$(ctx | grep -c 'studio.py" push')" "0"
check_eq "text_or_code: no studio.py wait" "$(ctx | grep -c 'studio.py wait')" "0"

run "Split: a logo as an SVG and a transparent PNG"
check_code "svg and png prompt: exit 0" "$code" 0
check_eq "svg and png prompt: one block naming both" "$(ctx | grep -c '^\[clouter visual\] This prompt asks for a vector svg and a raster image')" "1"
check_eq "svg and png prompt: one AskUserQuestion call, two questions" "$(ctx | grep -c 'one AskUserQuestion call holding 2 questions')" "1"
check_eq "svg and png prompt: headers differ, svg first" "$(ctx | grep -o '^Question with header "[^"]*"' | tr '\n' ';')" 'Question with header "SVG model";Question with header "Image model";'
check_eq "svg and png prompt: each question has Jev's pick first and Recommended" "$(ctx | grep '^1\. ' | tr '\n' ';' | grep -o '^1\. [^ ]* (Recommended)\|;1\. [^ ]* (Recommended)' | tr -d ';' | tr '\n' ' ')" "1. recraft/recraft-v4.1-vector (Recommended) 1. openai/gpt-image-1 (Recommended) "
check_eq "svg and png prompt: transparent drops the non-alpha raster model, one alpha model left" "$(ctx | grep -c 'recraft/recraft-v4\.1[^-]')" "0"
check_eq "svg and png prompt: Stay with Claude closes both questions" "$(ctx | grep -c '^4\. Stay with Claude\|^3\. Stay with Claude\|^2\. Stay with Claude')" "2"
check_eq "svg and png prompt: prices in every model label" "$(ctx | grep -c '^[123]\. .*per 1K image tokens')" "$(ctx | grep -c '^[123]\. [a-z]*/')"
check_eq "svg and png prompt: one generate.py run per format" "$(ctx | grep -c 'one run per format')" "1"
check_eq "svg and png prompt: raster run carries --transparent" "$(ctx | grep -c -- '--transparent on the raster_image run')" "1"
check_eq "svg and png prompt: names studio.py push" "$(ctx | grep -c 'studio.py" push')" "1"
check_eq "svg and png prompt: names studio.py wait" "$(ctx | grep -c 'studio.py wait --session')" "1"
check_eq "svg and png prompt: points at the Studio loop in SKILL.md" "$(ctx | grep -c 'Studio loop.*SKILL.md')" "1"
check_eq "svg and png prompt: one modality call, then two catalogue fetches and two model calls" "$(jq -r '.method + " " + (if .body.questions.model then "model" elif .body then "modality" else .path end)' "$work/requests.jsonl" | sort | tr '\n' ';')" "GET /api/v1/models?output_modalities=image;GET /api/v1/models?output_modalities=image;POST modality;POST model;POST model;"
check_eq "svg and png prompt: a model question per modality" "$(jq -r 'select(.body.questions.model) | .body.state.modality' "$work/requests.jsonl" | sort | tr '\n' ' ')" "raster_image vector_svg "

CLOUTER_VISUAL_MULTI=0.5 run "Split: a logo as an SVG and a transparent PNG"
check_eq "CLOUTER_VISUAL_MULTI=0.5: only the likeliest, single question" "$(ctx | grep -c 'asks for a vector svg, which\|header \"Model\"')" "1"
check_eq "CLOUTER_VISUAL_MULTI=0.5: one model call" "$(jq -c 'select(.body.questions.model)' "$work/requests.jsonl" | wc -l | tr -d ' ')" "1"

run "Give me a transparent PNG picture of a logo"
check_code "transparent PNG prompt: exit 0" "$code" 0
check_eq "transparent PNG prompt: single raster question" "$(ctx | grep -c 'asks for a raster image')" "1"
check_eq "transparent PNG prompt: only the alpha model listed" "$(ctx | grep -o '^[0-9]\. [a-z]*/[^ ]*' | tr '\n' ' ')" "1. openai/gpt-image-1 "
check_eq "transparent PNG prompt: command carries --transparent" "$(ctx | grep -c -- '--modality raster_image --prompt-file <path to the design brief> --transparent')" "1"
check_eq "transparent PNG prompt: names studio.py push" "$(ctx | grep -c 'studio.py" push')" "1"
check_eq "transparent PNG prompt: names studio.py wait" "$(ctx | grep -c 'studio.py wait --session')" "1"
check_eq "transparent PNG prompt: suggests defects before pushing (raster)" "$(ctx | grep -c -- '--suggest --model <chosen id> --out <defects.json>')" "1"

run "Wordy: explain which logo image format suits a letterhead"
check_code "text_or_code majority: exit 0" "$code" 0
check_eq "text_or_code majority: silent" "$out" ""
check_eq "text_or_code majority: one Jev call only" "$(requests)" "1"

run "Noprobs: an svg of a cat"
check_eq "no modality probabilities: falls back to the single choice" "$(ctx | grep -c 'asks for a vector svg')" "1"
run "Noprobs unsure: an svg of a cat"
check_eq "no modality probabilities, low confidence: silent" "$out" ""

run "Boom: an svg of a cat"
check_code "Jev 500: exit 0" "$code" 0
check_eq "Jev 500: silent" "$out" ""
check_eq "Jev 500: retried once then gave up" "$(requests)" "2"
check_eq "Jev 500: reason on stderr" "$(grep -c 'clouter visual: JevError' "$work/stderr")" "1"

printf 'catalogue-down' > "$work/flags"
run "an svg of a cat"
check_code "catalogue down: exit 0" "$code" 0
check_eq "catalogue down: silent" "$out" ""
rm -f "$work/flags"

CLOUTER_VISUAL=0 run "an svg of a cat"
check_eq "CLOUTER_VISUAL=0: silent" "$out" ""
check_eq "CLOUTER_VISUAL=0: no request" "$(requests)" "0"

OPENROUTER_API_KEY= run "an svg of a cat"
check_code "no key: exit 0" "$code" 0
check_eq "no key: context offers the setup once" "$(ctx | grep -c 'no OpenRouter key is stored.*setup-key.py')" "1"
check_eq "no key: declining is scoped to this session's ordinary prompts" "$(ctx | grep -c 'no nudge on ordinary prompts this session')" "1"
check_eq "no key: re-offers on an explicit request or exit 3" "$(ctx | grep -c 'explicitly asks to generate a file, or if generate.py or critique.py')" "1"
check_eq "no key: mentions exit 3" "$(ctx | grep -c 'exits 3')" "1"
check_eq "no key: background run showing both stderr links" "$(ctx | grep -c 'in the background and show the user both links')" "1"
check_eq "no key: names paste_url for a machine the browser can't reach" "$(ctx | grep -c 'paste_url for a machine the browser')" "1"
check_eq "no key: points at /clouter:visual setup for later" "$(ctx | grep -c '/clouter:visual setup')" "1"
check_eq "no key: no request" "$(requests)" "0"
OPENROUTER_API_KEY= run "fix the bug"
check_eq "no key and no prefilter hit: silent" "$out" ""

out=$(printf 'not json' | "$SCRIPT" 2>"$work/stderr"); code=$?
check_code "bad stdin: exit 0" "$code" 0
check_eq "bad stdin: silent" "$out" ""

run "<task-notification>agent finished making a video: sunrise.mp4</task-notification>"
check_code "task-notification prompt: exit 0" "$code" 0
check_eq "task-notification prompt: silent" "$out" ""
check_eq "task-notification prompt: no Jev call" "$(requests)" "0"

run "  <task-notification>agent finished making a video</task-notification>"
check_code "task-notification prompt with leading whitespace: exit 0" "$code" 0
check_eq "task-notification prompt with leading whitespace: silent" "$out" ""
check_eq "task-notification prompt with leading whitespace: no Jev call" "$(requests)" "0"

run "<system-reminder><task-notification>video render done</task-notification></system-reminder>"
check_code "task-notification wrapped in system-reminder: exit 0" "$code" 0
check_eq "task-notification wrapped in system-reminder: silent" "$out" ""
check_eq "task-notification wrapped in system-reminder: no Jev call" "$(requests)" "0"

run "Earlier a <task-notification> arrived, now please make a video of a sunrise"
check_eq "task-notification mentioned mid-prompt still routes: video prompt" "$(ctx | grep -c 'asks for a video')" "1"
check_eq "task-notification mentioned mid-prompt still routes: Jev called" "$(requests)" "3"

# --- hooks.json's command: finds python3, python or py (Windows has no python3) ---
hook_cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$ROOT/hooks/hooks.json")"
bash_bin="$(command -v bash)"
mkdir -p "$work/bin-python-only" "$work/bin-none"
cat > "$work/bin-python-only/python" <<EOF
#!$bash_bin
printf '%s\n' "\$@" >> "$work/python-calls"
exec "$(command -v python3)" "\$@"
EOF
chmod +x "$work/bin-python-only/python"
hook_out=$(printf '{"prompt":"hello"}' | CLOUTER_VISUAL=0 CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$work/bin-python-only" "$bash_bin" -c "$hook_cmd" 2>&1); hook_code=$?
check_code "hook command, only 'python' on PATH: exit 0" "$hook_code" 0
check_eq "hook command, only 'python' on PATH: route.py ran" "$(grep -c 'skills/visual/route.py$' "$work/python-calls")" "1"
hook_out=$(printf '{"prompt":"hello"}' | CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$work/bin-none" "$bash_bin" -c "$hook_cmd" 2>&1); hook_code=$?
check_code "hook command, no python at all: exit 0" "$hook_code" 0
check_eq "hook command, no python at all: silent" "$hook_out" ""

exit $fail

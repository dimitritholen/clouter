#!/usr/bin/env bash
# Tests for skills/visual/critique.py against a stand-in OpenRouter that
# plays both the critic (chat/completions with a system message) and the
# generator (chat/completions with modalities:["image"]) sides, plus a
# fake google-chrome for the SVG-rasterisation path. No key, no network.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/visual/critique.py"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null' EXIT

python3 - "$work" <<'EOF_SERVER' 2>"$work/server.err" &
import base64, json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
work = sys.argv[1]
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")

calls = {}


def bump(model):
    calls[model] = calls.get(model, 0) + 1
    return calls[model]


def critic_answer(model):
    """(pass, defects) for one critic call, by model id and call count."""
    n = bump(model)
    if model == "acme/critic-pass":
        return True, []
    if model == "acme/critic-fail-simple":
        return False, [{"type": "artifact", "where": "a smudge", "box": None, "severity": 5, "fix": "remove the smudge"}]
    if model in ("acme/critic-then-pass", "acme/critic-noref-then-pass"):
        if n == 1:
            return False, [{"type": "artifact", "where": "top edge", "box": None, "severity": 5, "fix": "remove the artifact"}]
        return True, []
    if model == "acme/critic-worsening":
        if n == 1:
            return False, [{"type": "other", "where": "a", "box": None, "severity": 3, "fix": "fix a"}]
        if n == 2:
            return False, [{"type": "other", "where": "b", "box": None, "severity": 5, "fix": "fix b"},
                            {"type": "other", "where": "c", "box": None, "severity": 5, "fix": "fix c"}]
        return False, [{"type": "other", "where": "d", "box": None, "severity": 4, "fix": "fix d"},
                        {"type": "other", "where": "e", "box": None, "severity": 2, "fix": "fix e"}]
    if model == "acme/critic-worse-each":
        # every round scores worse than the one before: 3, 4, 5, ...
        return False, [{"type": "other", "where": f"round {n}", "box": None, "severity": min(5, n + 2), "fix": f"fix {n}"}]
    if model == "acme/critic-equal":
        return False, [{"type": "other", "where": "same", "box": None, "severity": 3, "fix": "fix it"}]
    if model == "acme/critic-suggest":
        return False, [{"type": "text_content", "where": "title", "box": [0.1, 0.1, 0.5, 0.2], "severity": 4,
                        "fix": "spell the title right", "extra": "dropped"},
                       {"type": "spacing", "where": "icons", "box": None, "severity": 2, "fix": "even the gaps"}]
    if model == "acme/critic-suggest-trouble":
        return False, [{"type": "prompt_adherence", "where": "missing element", "box": None, "severity": 5,
                        "fix": "add the missing element"}]
    raise ValueError(f"stand-in: no script for critic model {model}")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def send_json(self, status, obj):
        raw = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def record(self, body=None):
        with open(f"{work}/requests.jsonl", "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization"), "body": body}) + "\n")

    def do_GET(self):
        self.record()
        if self.path == "/api/v1/models?output_modalities=image":
            # Escalation fixture: acme/gen is the "current" generator (price
            # .00003); acme/gen-cheap is cheaper (excluded by the price
            # floor), acme/gen-best/-better/-extra are pricier candidates
            # that take a reference image, acme/gen-noimage-hi is pricier
            # but takes no image input (excluded).
            self.send_json(200, {"data": [
                {"id": "acme/gen", "name": "Acme Gen", "description": "Current generator.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.00003"}},
                {"id": "acme/gen-noref", "architecture": {"input_modalities": ["text"]}},
                {"id": "acme/gen-cheap", "name": "Acme Cheap", "description": "Cheaper, excluded by price.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.00001"}},
                {"id": "acme/gen-best", "name": "Acme Best", "description": "Jev's recommended pick.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.00004"}},
                {"id": "acme/gen-better", "name": "Acme Better", "description": "Another candidate.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.00005"}},
                {"id": "acme/gen-extra", "name": "Acme Extra", "description": "Yet another candidate.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.00006"}},
                {"id": "acme/gen-noimage-hi", "name": "Acme No Image", "description": "No reference support, excluded.",
                 "architecture": {"input_modalities": ["text"]}, "pricing": {"image_output": "0.00009"}},
                {"id": "acme/gen-sort", "name": "Acme Sort", "description": "Current generator for the sort-order test.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.0000001"}},
                {"id": "acme/gen-sort-a", "name": "Acme Sort A", "description": "Cheapest sort candidate.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.000005"}},
                {"id": "acme/gen-sort-b", "name": "Acme Sort B", "description": "Second-cheapest sort candidate, highest probability.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.000006"}},
                {"id": "acme/gen-sort-c", "name": "Acme Sort C", "description": "Middle-priced sort candidate, zero probability.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.000007"}},
                {"id": "acme/gen-sort-d", "name": "Acme Sort D", "description": "Second-highest priced sort candidate, second-highest probability.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.000008"}},
                {"id": "acme/gen-sort-e", "name": "Acme Sort E", "description": "Priciest sort candidate, zero probability.",
                 "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.000009"}},
            ]}); return
        self.send_json(404, {"error": {"message": "no such path"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.record(body)
        model = body.get("model", "")
        messages = body.get("messages") or []
        is_critic = bool(messages) and messages[0].get("role") == "system"

        if self.path == "/api/alpha/decisions":
            state = body.get("state") or {}
            if state.get("current_model") == "acme/gen-jevboom":
                self.send_json(500, {"error": {"message": "stand-in exploded"}}); return
            criteria = body["questions"]["model"]["criteria"]
            ids = list(criteria)
            # Non-monotonic probabilities over price-ordered candidates, to prove
            # build_escalation sorts by probability rather than trusting the
            # cheapest-first order rank_models hands back.
            sort_probs = {"acme/gen-sort-a": 0.01, "acme/gen-sort-b": 0.66,
                          "acme/gen-sort-c": 0.0, "acme/gen-sort-d": 0.33, "acme/gen-sort-e": 0.0}
            if set(ids) == set(sort_probs):
                pick = "acme/gen-sort-b"
                conf = sort_probs[pick]
                probs = {i: sort_probs.get(i, 0.0) for i in ids}
                self.send_json(200, {"model": "jev-stand-in", "id": "req-jev", "answers": {
                    "model": {"type": "choice", "choice": pick, "confidence": conf, "probabilities": probs}}})
                return
            pick = next((i for i in ids if "best" in i), ids[0])
            conf = 0.7
            probs = {i: round((1 - conf) / max(1, len(ids) - 1), 3) for i in ids}
            probs[pick] = conf
            self.send_json(200, {"model": "jev-stand-in", "id": "req-jev", "answers": {
                "model": {"type": "choice", "choice": pick, "confidence": conf, "probabilities": probs}}})
            return

        if self.path != "/api/v1/chat/completions":
            self.send_json(404, {"error": {"message": "no such path"}}); return

        if is_critic:
            if model.startswith("acme/critic-badjson"):
                n = bump(model)
                if model == "acme/critic-badjson-always" or n == 1:
                    self.send_json(200, {"choices": [{"message": {"role": "assistant", "content": "sorry, I cannot help with that"}}],
                                         "usage": {"cost": 0.001}}); return
                content = json.dumps({"pass": True, "defects": []})
                self.send_json(200, {"choices": [{"message": {"role": "assistant", "content": content}}],
                                     "usage": {"cost": 0.001}}); return
            if model == "acme/critic-suggest-explicit-false":
                content = json.dumps({"pass": False, "summary": "The fox looks right overall.",
                                      "model_trouble": False,
                                      "defects": [{"type": "prompt_adherence", "where": "tail", "box": None,
                                                   "severity": 5, "fix": "add the tail"}]})
                self.send_json(200, {"choices": [{"message": {"role": "assistant", "content": content}}],
                                     "usage": {"cost": 0.002}}); return
            if model == "acme/critic-suggest-explicit-true":
                content = json.dumps({"pass": False, "summary": "Small spacing issue, otherwise fine.",
                                      "model_trouble": True,
                                      "defects": [{"type": "spacing", "where": "icons", "box": None,
                                                   "severity": 2, "fix": "even the gaps"}]})
                self.send_json(200, {"choices": [{"message": {"role": "assistant", "content": content}}],
                                     "usage": {"cost": 0.002}}); return
            if model == "acme/critic-translate":
                content = json.dumps({"instructions": [
                    {"where": "the sky", "box": [0, 0, 1, 0.3], "instruction": "make the sky darker", "source": "pen"},
                    {"where": "the dog", "box": None, "instruction": "remove the dog", "source": "note"}]})
                self.send_json(200, {"choices": [{"message": {"role": "assistant", "content": content}}],
                                     "usage": {"cost": 0.003}}); return
            passed, defects = critic_answer(model)
            content = json.dumps({"pass": passed, "defects": defects})
            self.send_json(200, {"choices": [{"message": {"role": "assistant", "content": content}}],
                                 "usage": {"cost": 0.002}}); return

        # generator side: fix-round image call
        url = "data:image/png;base64," + base64.b64encode(PNG).decode()
        self.send_json(200, {"choices": [{"message": {"role": "assistant", "content": "",
                             "images": [{"type": "image_url", "image_url": {"url": url}}]}}],
                             "usage": {"cost": 0.01}}); return


server = HTTPServer(("127.0.0.1", 0), Handler)
open(f"{work}/port", "w").write(str(server.server_port))
server.serve_forever()
EOF_SERVER
server_pid=$!
for _ in $(seq 300); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || { printf 'FAIL stand-in server did not start: %s\n' "$(tr "\n" " " < "$work/server.err" 2>/dev/null)"; exit 1; }
export OPENROUTER_BASE_URL="http://127.0.0.1:$(cat "$work/port")"
export CLOUTER_CREDENTIALS="$work/no-such-file"
export CLOUTER_LEARNED="$work/learned.json"
export OPENROUTER_API_KEY="test-key"
mkdir -p "$work/cwd" && cd "$work/cwd"

check_code() { if [ "$2" -eq "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (exit %s, want %s): %s\n' "$1" "$2" "$3" "$(cat "$work/stderr")"; fail=1; fi; }
check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }
run() { rm -f "$work/requests.jsonl"; out=$("$SCRIPT" "$@" 2>"$work/stderr"); code=$?; }
field() { printf '%s' "$out" | jq -r "$1"; }

TINY_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
printf '%s' "$TINY_PNG_B64" | base64 -d > original.png

# --- pass on the first judge ---------------------------------------------------
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-pass
check_code "pass first try: exit 0" "$code" 0
check_eq "pass first try: no rounds used" "$(field .rounds)" "0"
check_eq "pass first try: final is the original" "$(field .final)" "original.png"
check_eq "pass first try: pass true" "$(field .pass)" "true"
check_eq "pass first try: files has only the original" "$(field '.files | length')" "1"
check_eq "pass first try: critic id echoed" "$(field .critic)" "acme/critic-pass"
check_eq "pass first try: no generator request" "$(jq -c 'select(.body.model=="acme/gen")' "$work/requests.jsonl" | wc -l | tr -d ' ')" "0"
critic_body="$(jq -c 'select(.body.model=="acme/critic-pass")' "$work/requests.jsonl")"
check_eq "pass first try: critic request has temperature 0" "$(printf '%s' "$critic_body" | jq '.body.temperature')" "0"

# --- fail, then fix, then pass; reference sent on the fix round ----------------
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-then-pass
check_code "fail then fix then pass: exit 0" "$code" 0
check_eq "fail then fix then pass: pass true" "$(field .pass)" "true"
check_eq "fail then fix then pass: one round used" "$(field .rounds)" "1"
check_eq "fail then fix then pass: final is the .r1 file" "$(field .final)" "original.r1.png"
check_eq "fail then fix then pass: files lists original then .r1" "$(field '.files | join(",")')" "original.png,original.r1.png"
[ -s original.r1.png ] && printf 'ok   fail then fix then pass: .r1 file written\n' || { printf 'FAIL .r1 file missing\n'; fail=1; }
fix_body="$(jq -c 'select(.body.model=="acme/gen")' "$work/requests.jsonl")"
check_eq "fix round: prompt carries the fix instruction" "$(printf '%s' "$fix_body" | jq -r '.body.messages[0].content[0].text' | grep -c 'remove the artifact')" "1"
ref_url="$(printf '%s' "$fix_body" | jq -r '.body.messages[0].content[1].image_url.url')"
check_eq "fix round: reference sent as a second image_url part" "$(printf '%s' "$ref_url" | cut -c1-22)" "data:image/png;base64,"
check_eq "fix round: reference decodes to the original's bytes" \
  "$(printf '%s' "$ref_url" | sed 's/^data:image\/png;base64,//' | base64 -d | cmp -s - original.png && echo same || echo different)" "same"
check_eq "fix round: generator request has no temperature key" "$(printf '%s' "$fix_body" | jq 'has("body") and (.body | has("temperature"))')" "false"

# --- still failing after N rounds: lowest score wins, not the last ------------
run original.png --prompt "A blue jay" --model acme/gen --critic acme/critic-worsening --rounds 2
check_code "still failing after N rounds: exit 0 (not passing isn't an error)" "$code" 0
check_eq "still failing: pass false" "$(field .pass)" "false"
check_eq "still failing: both rounds used" "$(field .rounds)" "2"
check_eq "still failing: final is the original (lowest score 3), not the last (score 6)" "$(field .final)" "original.png"
check_eq "still failing: three files judged" "$(field '.files | length')" "3"

# --- --rounds 0: judge only -----------------------------------------------------
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-fail-simple --rounds 0
check_code "--rounds 0: exit 0" "$code" 0
check_eq "--rounds 0: rounds used is 0" "$(field .rounds)" "0"
check_eq "--rounds 0: final is the original" "$(field .final)" "original.png"
check_eq "--rounds 0: pass false" "$(field .pass)" "false"
check_eq "--rounds 0: no generator request" "$(jq -c 'select(.body.model=="acme/gen")' "$work/requests.jsonl" | wc -l | tr -d ' ')" "0"

# --- unparseable critic reply -----------------------------------------------------
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-badjson-always
check_code "unparseable twice: exit 9" "$code" 9
check_eq "unparseable twice: message on stderr" "$(grep -c 'did not answer with parseable JSON' "$work/stderr")" "1"

run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-badjson-once
check_code "unparseable once then valid: exit 0" "$code" 0
check_eq "unparseable once then valid: pass true" "$(field .pass)" "true"
check_eq "unparseable once then valid: no fix round needed" "$(field .rounds)" "0"

# --- model without image input: no reference sent -------------------------------
run original.png --prompt "An owl" --model acme/gen-noref --critic acme/critic-noref-then-pass
check_code "gen model without image input: exit 0" "$code" 0
check_eq "gen model without image input: still fixed and passed" "$(field .pass)" "true"
noref_body="$(jq -c 'select(.body.model=="acme/gen-noref")' "$work/requests.jsonl")"
check_eq "gen model without image input: plain string content, no reference" "$(printf '%s' "$noref_body" | jq -r '.body.messages[0].content | type')" "string"

# --- no key -----------------------------------------------------------------------
OPENROUTER_API_KEY= run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-pass
check_code "no key: exit 3" "$code" 3
check_eq "no key: no request made" "$([ -f "$work/requests.jsonl" ] && wc -l < "$work/requests.jsonl" | tr -d " " || echo 0)" "0"

# --- cost log ------------------------------------------------------------------
log="$work/costs/visual.jsonl"
export CLOUTER_VISUAL_LOG="$log"
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-then-pass
check_code "cost log: run still succeeds" "$code" 0
check_eq "cost log: total cost summed and non-null" "$([ "$(field .cost)" != "null" ] && echo yes || echo no)" "yes"
check_eq "cost log: at least one critique line logged" "$([ "$(grep -c '\"modality\": \"critique\"' "$log")" -ge 1 ] && echo yes || echo no)" "yes"
unset CLOUTER_VISUAL_LOG

# --- SVG input: rasterised when a browser is available, sent as text otherwise --
cat > shape.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 32"><rect width="64" height="32"/></svg>
EOF

mkdir -p "$work/bin-ok"
cat > "$work/bin-ok/google-chrome" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    --screenshot=*) printf '%s' "$TINY_PNG_B64" | base64 -d > "\${arg#--screenshot=}" ;;
  esac
done
exit 0
EOF
chmod +x "$work/bin-ok/google-chrome"
mkdir -p "$work/bin-empty"
# python3 alone on PATH: a real /usr/bin could hold rsvg-convert or sips.
mkdir -p "$work/bin-py" && ln -sf "$(command -v python3)" "$work/bin-py/python3"
py_dir="$work/bin-py"

run_with_path() { rm -f "$work/requests.jsonl"; out=$(PATH="$1" "$SCRIPT" "${@:2}" 2>"$work/stderr"); code=$?; }

run_with_path "$work/bin-ok:$PATH" shape.svg --prompt "A rectangle" --model acme/gen --critic acme/critic-pass
check_code "svg with chrome: exit 0" "$code" 0
svg_body="$(jq -c 'select(.body.model=="acme/critic-pass")' "$work/requests.jsonl")"
svg_content="$(printf '%s' "$svg_body" | jq -r '.body.messages[1].content')"
check_eq "svg with chrome: content is text+image_url (2 parts)" "$(printf '%s' "$svg_content" | jq 'length')" "2"
check_eq "svg with chrome: image part is a PNG data url" "$(printf '%s' "$svg_content" | jq -r '.[1].image_url.url' | cut -c1-22)" "data:image/png;base64,"

run_with_path "$work/bin-empty:$py_dir" shape.svg --prompt "A rectangle" --model acme/gen --critic acme/critic-pass
check_code "svg without chrome: exit 0" "$code" 0
svg_body2="$(jq -c 'select(.body.model=="acme/critic-pass")' "$work/requests.jsonl")"
svg_content2="$(printf '%s' "$svg_body2" | jq -r '.body.messages[1].content')"
check_eq "svg without chrome: content is text only (1 part)" "$(printf '%s' "$svg_content2" | jq 'length')" "1"
check_eq "svg without chrome: svg markup sent as text" "$(printf '%s' "$svg_content2" | jq -r '.[0].text' | grep -c '<svg')" "1"

mkdir -p "$work/bin-rsvg"
cat > "$work/bin-rsvg/rsvg-convert" <<EOF
#!$(command -v bash)
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && printf '%s' "$TINY_PNG_B64" | $(command -v base64) -d > "\$2"; shift; done
EOF
chmod +x "$work/bin-rsvg/rsvg-convert"
run_with_path "$work/bin-rsvg:$py_dir" shape.svg --prompt "A rectangle" --model acme/gen --critic acme/critic-pass
check_code "svg with rsvg-convert, no chrome: exit 0" "$code" 0
svg_content3="$(jq -c 'select(.body.model=="acme/critic-pass")' "$work/requests.jsonl" | jq -r '.body.messages[1].content')"
check_eq "svg with rsvg-convert: image part is a PNG data url" "$(printf '%s' "$svg_content3" | jq -r '.[1].image_url.url' | cut -c1-22)" "data:image/png;base64,"

{ printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 32">'; for i in $(seq 1 700); do printf '<path d="M 0 0 L 64 32 L 0 32 z"/>'; done; printf '</svg>'; } > big.svg
run_with_path "$work/bin-empty:$py_dir" big.svg --prompt "A rectangle" --model acme/gen --critic acme/critic-pass
check_code "big svg, nothing to rasterise: refused" "$code" 2
check_eq "big svg: nothing sent to the critic" "$([ -s "$work/requests.jsonl" ] && echo sent || echo none)" "none"

# --- SVG rasterisation window: sized from the SVG's own aspect ratio, not a fixed square ---
cat > wide.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 100"><rect width="400" height="100"/></svg>
EOF

mkdir -p "$work/bin-record"
cat > "$work/bin-record/google-chrome" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/chrome-args"
for arg in "\$@"; do
  case "\$arg" in
    --screenshot=*) printf '%s' "$TINY_PNG_B64" | base64 -d > "\${arg#--screenshot=}" ;;
  esac
done
exit 0
EOF
chmod +x "$work/bin-record/google-chrome"

run_with_path "$work/bin-record:$PATH" wide.svg --prompt "A wide banner" --model acme/gen --critic acme/critic-pass
check_code "wide svg: exit 0" "$code" 0
window_size="$(grep '^--window-size=' "$work/chrome-args")"
check_eq "wide svg: window-size argument present" "$([ -n "$window_size" ] && echo yes || echo no)" "yes"
win_w="$(printf '%s' "$window_size" | sed 's/^--window-size=//' | cut -d, -f1)"
win_h="$(printf '%s' "$window_size" | sed 's/^--window-size=//' | cut -d, -f2)"
check_eq "wide svg: window keeps the SVG's 4:1 aspect ratio" "$((win_w * 100 / win_h))" "400"

# --- escalation: fail after rounds offers priced, reference-taking, untried models ---
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-fail-simple --rounds 1
check_code "escalation: exit 0" "$code" 0
check_eq "escalation: still failing" "$(field .pass)" "false"
ids="$(field '.escalation.options | map(.id) | join(",")')"
check_eq "escalation: current model excluded" "$(printf '%s' ",$ids," | grep -c ',acme/gen,')" "0"
check_eq "escalation: cheaper model excluded" "$(printf '%s' "$ids" | grep -c 'acme/gen-cheap')" "0"
check_eq "escalation: model without image input excluded" "$(printf '%s' "$ids" | grep -c 'acme/gen-noimage-hi')" "0"
check_eq "escalation: pricier reference-taking candidates offered" "$ids" "acme/gen-best,acme/gen-better,acme/gen-extra"
check_eq "escalation: recommended is acme/gen-best" "$(field .escalation.recommended)" "acme/gen-best"
check_eq "escalation: recommended comes first" "$(field '.escalation.options[0].id')" "acme/gen-best"
command="$(field .escalation.command)"
check_eq "escalation: command carries the <MODEL> placeholder" "$(printf '%s' "$command" | grep -c -- '--model <MODEL>')" "1"
check_eq "escalation: command names --defects-file" "$(printf '%s' "$command" | grep -c -- '--defects-file')" "1"
check_eq "escalation: command names --tried with the current model" "$(printf '%s' "$command" | grep -c -- '--tried acme/gen')" "1"
check_eq "escalation: command carries --rounds 1 for a --rounds 1 run" "$(printf '%s' "$command" | grep -c -- '--rounds 1')" "1"
prompt_file="$(printf '%s' "$command" | grep -o -- '--prompt-file [^ ]*' | cut -d' ' -f2)"
defects_file="$(printf '%s' "$command" | grep -o -- '--defects-file [^ ]*' | cut -d' ' -f2)"
check_eq "escalation: prompt file holds the original prompt" "$(cat "$prompt_file")" "A red fox"
check_eq "escalation: defects file holds the final defects" "$(jq -r '.[0].fix' "$defects_file")" "remove the smudge"

# --- escalation: --rounds 0 (judge only) still yields a --rounds 1 command ---------
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-fail-simple --rounds 0
check_code "escalation, rounds 0: exit 0" "$code" 0
command0="$(field .escalation.command)"
check_eq "escalation, rounds 0: command uses --rounds 1, not --rounds 0" \
  "$(printf '%s' "$command0" | grep -o -- '--rounds [0-9]*')" "--rounds 1"

# --- escalation: --rounds 2 keeps --rounds 2 in the command -------------------------
run original.png --prompt "A blue jay" --model acme/gen --critic acme/critic-worsening --rounds 2
command2="$(field .escalation.command)"
check_eq "escalation, rounds 2: command keeps --rounds 2" \
  "$(printf '%s' "$command2" | grep -o -- '--rounds [0-9]*')" "--rounds 2"

# --- escalation: options cut to 3, ordered by Jev probability, not price -----------
run original.png --prompt "A red fox" --model acme/gen-sort --critic acme/critic-fail-simple --rounds 1 \
  --tried "acme/gen,acme/gen-best,acme/gen-better,acme/gen-extra,acme/gen-cheap"
check_code "escalation, sort order: exit 0" "$code" 0
check_eq "escalation, sort order: at most 3 options" "$(field '.escalation.options | length')" "3"
check_eq "escalation, sort order: recommended (highest probability) first" "$(field '.escalation.options[0].id')" "acme/gen-sort-b"
check_eq "escalation, sort order: options ordered by probability descending, not price" \
  "$(field '.escalation.options | map(.id) | join(",")')" "acme/gen-sort-b,acme/gen-sort-d,acme/gen-sort-a"
check_eq "escalation, sort order: recommended is the top-probability model" "$(field .escalation.recommended)" "acme/gen-sort-b"

# --- escalation: no key under pass, no escalation key at all -----------------------
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-pass
check_code "escalation, passing result: exit 0" "$code" 0
check_eq "escalation, passing result: no escalation key" "$(field 'has("escalation")')" "false"
check_eq "escalation, passing result: no escalation_error key" "$(field 'has("escalation_error")')" "false"

# --- escalation: Jev failure never fails the run ------------------------------------
run original.png --prompt "A red fox" --model acme/gen-jevboom --critic acme/critic-fail-simple --rounds 0
check_code "escalation, Jev failure: exit 0" "$code" 0
check_eq "escalation, Jev failure: no escalation key" "$(field 'has("escalation")')" "false"
check_eq "escalation, Jev failure: escalation_error reports the JevError" "$(field .escalation_error | grep -c 'JevError')" "1"

# --- escalation: no candidates left after --tried -----------------------------------
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-fail-simple --rounds 0 \
  --tried "acme/gen-cheap,acme/gen-best,acme/gen-better,acme/gen-extra,acme/gen-noimage-hi"
check_code "escalation, no candidates: exit 0" "$code" 0
check_eq "escalation, no candidates: no escalation key" "$(field 'has("escalation")')" "false"
check_eq "escalation, no candidates: escalation_error reports it" "$(field .escalation_error | grep -c 'no escalation candidates')" "1"

# --- escalation: --tried excludes those models from the next round -----------------
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-fail-simple --rounds 0 \
  --tried "acme/gen-best,acme/gen-better"
check_code "escalation, --tried narrows candidates: exit 0" "$code" 0
check_eq "escalation, --tried narrows candidates: only the untried one offered" \
  "$(field '.escalation.options | map(.id) | join(",")')" "acme/gen-extra"
check_eq "escalation, --tried narrows candidates: it is the recommendation" "$(field .escalation.recommended)" "acme/gen-extra"

# --- --defects-file: seeds the first result, no critic call before the fix round ----
cat > "$work/seed-defects.json" <<'EOF'
[{"type": "artifact", "where": "a smudge", "box": null, "severity": 5, "fix": "remove the smudge"}]
EOF
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-pass --defects-file "$work/seed-defects.json" --rounds 1
check_code "--defects-file: exit 0" "$code" 0
check_eq "--defects-file: eventually passes through the fix round" "$(field .pass)" "true"
chat_requests="$(jq -c 'select(.path=="/api/v1/chat/completions")' "$work/requests.jsonl")"
check_eq "--defects-file: first chat call is the generator, not the critic" \
  "$(printf '%s' "$chat_requests" | head -n1 | jq -r '.body.messages[0].role')" "user"
check_eq "--defects-file: exactly one critic call, after the fix round" \
  "$(printf '%s' "$chat_requests" | jq -r '.body.messages[0].role' | grep -c '^system$')" "1"
ref_url2="$(printf '%s' "$chat_requests" | head -n1 | jq -r '.body.messages[0].content[1].image_url.url')"
check_eq "--defects-file: fix round references the input file" \
  "$(printf '%s' "$ref_url2" | sed 's/^data:image\/png;base64,//' | base64 -d | cmp -s - original.png && echo same || echo different)" "same"

# --- naming: an escalated run on x.r1.png writes x.r2.png, not x.r1.r1.png ----------
cp original.png escnaming.r1.png
run escnaming.r1.png --prompt "A red fox" --model acme/gen --critic acme/critic-pass --defects-file "$work/seed-defects.json" --rounds 1
check_code "naming: exit 0" "$code" 0
check_eq "naming: continues the round count instead of restarting" "$(field .final)" "escnaming.r2.png"
[ -s escnaming.r2.png ] && printf 'ok   naming: escnaming.r2.png written\n' || { printf 'FAIL naming: escnaming.r2.png missing\n'; fail=1; }

# --- --request: a second, labelled input to the critic, and to any escalation ------
REQUEST_TEXT='make it café-style, with a "cozy" awning'

run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-pass --request "$REQUEST_TEXT"
check_code "--request: exit 0" "$code" 0
req_body="$(jq -c 'select(.body.model=="acme/critic-pass")' "$work/requests.jsonl")"
req_text="$(printf '%s' "$req_body" | jq -r '.body.messages[1].content[0].text')"
check_eq "--request: prompt part labelled and present" "$(printf '%s' "$req_text" | grep -c "The prompt sent to the image generator:")" "1"
check_eq "--request: request part labelled and holds the verbatim text" \
  "$(printf '%s' "$req_text" | grep -c "The user's original request, verbatim:")" "1"
check_eq "--request: the request text itself is present" "$(printf '%s' "$req_text" | grep -Fc "$REQUEST_TEXT")" "1"
check_eq "--request: system message mentions the user's request" \
  "$(printf '%s' "$req_body" | jq -r '.body.messages[0].content' | grep -c "user's original request")" "1"
check_eq "--request: system message excludes non-visual parts of the request" \
  "$(printf '%s' "$req_body" | jq -r '.body.messages[0].content' | grep -c "are ignored and never reported")" "1"

run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-pass
check_code "no --request: exit 0" "$code" 0
noreq_body="$(jq -c 'select(.body.model=="acme/critic-pass")' "$work/requests.jsonl")"
check_eq "no --request: content is unchanged (one text part, the plain template)" \
  "$(printf '%s' "$noreq_body" | jq -r '.body.messages[1].content[0].text')" \
  "The image below was generated from this prompt:

A red fox

Judge it against the prompt and the checklist in your instructions. Reply with the JSON object described there, and nothing else."
check_eq "no --request: system message is the built-in default, no request addendum" \
  "$(printf '%s' "$noreq_body" | jq -r '.body.messages[0].content' | grep -c "user's original request")" "0"

run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-fail-simple --rounds 0 --request "$REQUEST_TEXT"
check_code "--request escalation: exit 0" "$code" 0
req_command="$(field .escalation.command)"
check_eq "--request escalation: command carries --request-file" "$(printf '%s' "$req_command" | grep -c -- '--request-file')" "1"
req_file="$(printf '%s' "$req_command" | grep -o -- '--request-file [^ ]*' | cut -d' ' -f2)"
check_eq "--request escalation: request file holds the exact request text" "$(cat "$req_file")" "$REQUEST_TEXT"

printf '%s' "$REQUEST_TEXT" > "$work/request.txt"
run original.png --prompt "A red fox" --model acme/gen --critic acme/critic-pass --request "$REQUEST_TEXT" --request-file "$work/request.txt"
check_code "--request and --request-file together: exit 2" "$code" 2

# --- best round: every round worse than the last -> the original stays final -------
run original.png --prompt "A blue jay" --model acme/gen --critic acme/critic-worse-each --rounds 2
check_code "worse each round: exit 0" "$code" 0
check_eq "worse each round: both rounds used" "$(field .rounds)" "2"
check_eq "worse each round: final is the original" "$(field .final)" "original.png"
check_eq "worse each round: final defects are the original's" "$(field '.defects[0].where')" "round 1"
worse_command="$(field .escalation.command)"
check_eq "worse each round: escalation starts from the chosen final file" \
  "$(printf '%s' "$worse_command" | cut -d' ' -f3)" "original.png"

# --- best round: equal scores -> the earliest file wins ------------------------------
run original.png --prompt "A blue jay" --model acme/gen --critic acme/critic-equal --rounds 2
check_code "equal scores: exit 0" "$code" 0
check_eq "equal scores: three files judged" "$(field '.files | length')" "3"
check_eq "equal scores: final is the earliest (the original)" "$(field .final)" "original.png"
check_eq "equal scores: escalation starts from the original" \
  "$(field .escalation.command | cut -d' ' -f3)" "original.png"

# --- best round: a seeded first result competes too ---------------------------------
cat > "$work/seed-sev3.json" <<'EOF'
[{"type": "other", "where": "seeded", "box": null, "severity": 3, "fix": "fix it"}]
EOF
run original.png --prompt "A blue jay" --model acme/gen --critic acme/critic-equal --defects-file "$work/seed-sev3.json" --rounds 1
check_code "seeded tie: exit 0" "$code" 0
check_eq "seeded tie: the seeded original wins the tie" "$(field .final)" "original.png"
check_eq "seeded tie: final defects are the seeded ones" "$(field '.defects[0].where')" "seeded"

# --- --suggest: judge once, ids, no generator, no escalation ------------------------
run original.png --prompt "A red fox" --suggest --critic acme/critic-suggest --out "$work/suggest/defects.json"
check_code "--suggest: exit 0" "$code" 0
check_eq "--suggest: stdout names the out file" "$(field .out)" "$work/suggest/defects.json"
check_eq "--suggest: stdout carries the critic cost" "$(field .cost)" "0.002"
check_eq "--suggest: stdout names the critic" "$(field .critic)" "acme/critic-suggest"
check_eq "--suggest: ids d1, d2 in order" "$(jq -r '.defects | map(.id) | join(",")' "$work/suggest/defects.json")" "d1,d2"
check_eq "--suggest: fields kept" "$(jq -c '.defects[0]' "$work/suggest/defects.json")" \
  '{"id":"d1","type":"text_content","where":"title","box":[0.1,0.1,0.5,0.2],"severity":4,"fix":"spell the title right"}'
check_eq "--suggest: file holds defects, summary, model_trouble, no models (not in trouble)" \
  "$(jq -c 'keys' "$work/suggest/defects.json")" '["defects","model_trouble","summary"]'
check_eq "--suggest: summary empty when the critic didn't give one" "$(jq -r '.summary' "$work/suggest/defects.json")" ""
check_eq "--suggest: model_trouble false (no severe prompt_adherence defect)" \
  "$(jq -r '.model_trouble' "$work/suggest/defects.json")" "false"
check_eq "--suggest: exactly one request, the critic" "$(wc -l < "$work/requests.jsonl" | tr -d ' ')" "1"
check_eq "--suggest: no generator request" "$(jq -c 'select(.body.messages[0].role != "system")' "$work/requests.jsonl" | wc -l | tr -d ' ')" "0"
check_eq "--suggest: the critic call asks for summary and model_trouble" \
  "$(jq -c 'select(.body.model=="acme/critic-suggest")' "$work/requests.jsonl" | jq -r '.body.messages[0].content' | grep -c '"model_trouble"')" "1"

run original.png --prompt "A red fox" --suggest --critic acme/critic-suggest
check_code "--suggest without --out: exit 2" "$code" 2
run original.png --suggest --critic acme/critic-suggest --out "$work/x.json"
check_code "--suggest without a prompt: exit 2" "$code" 2
run original.png --prompt "A red fox" --critic acme/critic-pass
check_code "judge mode still requires --model: exit 2" "$code" 2

# --- --suggest: model_trouble derived from a severe prompt_adherence defect, models offered ---
run original.png --prompt "A red fox" --suggest --critic acme/critic-suggest-trouble --model acme/gen \
  --out "$work/suggest-trouble/defects.json"
check_code "--suggest, derived model_trouble: exit 0" "$code" 0
check_eq "--suggest, derived model_trouble: true" "$(jq -r '.model_trouble' "$work/suggest-trouble/defects.json")" "true"
check_eq "--suggest, derived model_trouble: models present" \
  "$(jq 'has("models")' "$work/suggest-trouble/defects.json")" "true"
check_eq "--suggest, derived model_trouble: at least one, at most 4 models" \
  "$(jq '.models | length >= 1 and length <= 4' "$work/suggest-trouble/defects.json")" "true"
check_eq "--suggest, derived model_trouble: --model excluded from the offered models" \
  "$(jq -r '.models | map(.id) | index("acme/gen")' "$work/suggest-trouble/defects.json")" "null"
check_eq "--suggest, derived model_trouble: recommended (Jev's pick) is first" \
  "$(jq -r '.models[0].id' "$work/suggest-trouble/defects.json")" "acme/gen-best"
check_eq "--suggest, derived model_trouble: each option carries reference_supported" \
  "$(jq -c '.models | map(has("reference_supported")) | unique' "$work/suggest-trouble/defects.json")" "[true]"

# --- --suggest: the critic's own explicit model_trouble overrides the derived one -----------
run original.png --prompt "A red fox" --suggest --critic acme/critic-suggest-explicit-false --model acme/gen \
  --out "$work/suggest-false/defects.json"
check_code "--suggest, explicit false overrides a severe defect: exit 0" "$code" 0
check_eq "--suggest, explicit false overrides a severe defect: model_trouble false" \
  "$(jq -r '.model_trouble' "$work/suggest-false/defects.json")" "false"
check_eq "--suggest, explicit false overrides a severe defect: summary carried through" \
  "$(jq -r '.summary' "$work/suggest-false/defects.json")" "The fox looks right overall."
check_eq "--suggest, explicit false overrides a severe defect: no models key" \
  "$(jq 'has("models")' "$work/suggest-false/defects.json")" "false"

run original.png --prompt "A red fox" --suggest --critic acme/critic-suggest-explicit-true --model acme/gen \
  --out "$work/suggest-true/defects.json"
check_code "--suggest, explicit true with mild defects: exit 0" "$code" 0
check_eq "--suggest, explicit true with mild defects: model_trouble true" \
  "$(jq -r '.model_trouble' "$work/suggest-true/defects.json")" "true"
check_eq "--suggest, explicit true with mild defects: summary carried through" \
  "$(jq -r '.summary' "$work/suggest-true/defects.json")" "Small spacing issue, otherwise fine."

# --- --suggest: a ranking failure (no candidates for this modality) sets models_error, exit 0 --
run shape.svg --prompt "A rectangle" --suggest --critic acme/critic-suggest-trouble --model acme/gen \
  --out "$work/suggest-error/defects.json"
check_code "--suggest, ranking failure: exit 0 (must not fail suggest)" "$code" 0
check_eq "--suggest, ranking failure: model_trouble still true" \
  "$(jq -r '.model_trouble' "$work/suggest-error/defects.json")" "true"
check_eq "--suggest, ranking failure: no models key" "$(jq 'has("models")' "$work/suggest-error/defects.json")" "false"
check_eq "--suggest, ranking failure: models_error present" \
  "$(jq 'has("models_error")' "$work/suggest-error/defects.json")" "true"
check_eq "--suggest, ranking failure: models_error names the ValueError" \
  "$(jq -r '.models_error' "$work/suggest-error/defects.json" | grep -c ValueError)" "1"

# --- --models: CLI-only ranking, honouring --exclude, no <file>, no critic call ------------
exclude_list="acme/gen,acme/gen-noref,acme/gen-better,acme/gen-extra,acme/gen-noimage-hi,acme/gen-sort,acme/gen-sort-a,acme/gen-sort-b,acme/gen-sort-c,acme/gen-sort-d,acme/gen-sort-e"
run --models --modality raster_image --prompt "A red fox" --exclude "$exclude_list" --out "$work/models-cli.json"
check_code "--models: exit 0" "$code" 0
check_eq "--models: stdout names the out file" "$(field .out)" "$work/models-cli.json"
check_eq "--models: stdout has no critic key" "$(field 'has("critic")')" "false"
check_eq "--models: file holds only models" "$(jq -c 'keys' "$work/models-cli.json")" '["models"]'
check_eq "--models: excluded ids left out" \
  "$(jq -r '.models | map(.id) | join(",")' "$work/models-cli.json" | grep -Ec 'acme/gen(,|$)|acme/gen-noref')" "0"
check_eq "--models: remaining two candidates offered, recommended (best) first" \
  "$(jq -r '.models | map(.id) | join(",")' "$work/models-cli.json")" "acme/gen-best,acme/gen-cheap"
check_eq "--models: no critic call, only the decisions call" \
  "$(jq -c 'select(.path=="/api/v1/chat/completions")' "$work/requests.jsonl" | wc -l | tr -d ' ')" "0"

run --models --prompt "A red fox" --out "$work/models-nomodality.json"
check_code "--models without --modality: exit 2" "$code" 2
run --models --modality raster_image --out "$work/models-noprompt.json"
check_code "--models without a prompt: exit 2" "$code" 2

# --- --translate: clean image + composite + notes + text -> instructions ------------
python3 - "$ROOT" <<'EOF_PNG'
import sys
sys.path.insert(0, sys.argv[1])
from lib import png
white = [bytearray(b"\xff\xff\xff\xff" * 4) for _ in range(4)]
open("clean.png", "wb").write(png.encode(4, 4, white))
layer = [bytearray(4 * 4) for _ in range(4)]
layer[1][4:8] = b"\xff\x00\x00\xff"
open("layer.png", "wb").write(png.encode(4, 4, layer))
small = [bytearray(2 * 4) for _ in range(2)]
small[0][0:4] = b"\x00\x00\xff\xff"
open("layer-small.png", "wb").write(png.encode(2, 2, small))
EOF_PNG
cat > "$work/notes.json" <<'EOF'
[{"n": 1, "x": 0.42, "y": 0.13, "text": "no dog here"}]
EOF
printf 'darker sky please' > "$work/text.txt"
run clean.png --translate --annotation layer.png --notes-file "$work/notes.json" --text-file "$work/text.txt" \
  --critic acme/critic-translate --out "$work/translate/instructions.json"
check_code "--translate: exit 0" "$code" 0
check_eq "--translate: stdout names the out file" "$(field .out)" "$work/translate/instructions.json"
check_eq "--translate: stdout carries the cost" "$(field .cost)" "0.003"
out_file="$work/translate/instructions.json"
check_eq "--translate: instructions parsed" "$(jq -r '.instructions | map(.source) | join(",")' "$out_file")" "pen,note"
check_eq "--translate: cost in the file" "$(jq -r '.cost' "$out_file")" "0.003"
tr_body="$(jq -c 'select(.body.model=="acme/critic-translate")' "$work/requests.jsonl")"
tr_content="$(printf '%s' "$tr_body" | jq -c '.body.messages[1].content')"
check_eq "--translate: text + two images sent" "$(printf '%s' "$tr_content" | jq -r 'map(.type) | join(",")')" "text,image_url,image_url"
printf '%s' "$tr_content" | jq -r '.[1].image_url.url' | sed 's/^data:image\/png;base64,//' | base64 -d > "$work/sent-clean.png"
printf '%s' "$tr_content" | jq -r '.[2].image_url.url' | sed 's/^data:image\/png;base64,//' | base64 -d > "$work/sent-composite.png"
check_eq "--translate: first image is the clean file" "$(cmp -s "$work/sent-clean.png" clean.png && echo same || echo different)" "same"
check_eq "--translate: second image is the composite (red where drawn, white elsewhere)" \
  "$(python3 -c "
import sys; sys.path.insert(0, '$ROOT')
from lib import png
w, h, rows = png.decode(open('$work/sent-composite.png', 'rb').read())
print(w, h, bytes(rows[1][4:8]).hex(), bytes(rows[0][0:4]).hex())")" "4 4 ff0000ff ffffffff"
tr_text="$(printf '%s' "$tr_content" | jq -r '.[0].text')"
check_eq "--translate: note pin with its fractions" "$(printf '%s' "$tr_text" | grep -Fc '1. at x=0.42, y=0.13: no dog here')" "1"
check_eq "--translate: user's text sent" "$(printf '%s' "$tr_text" | grep -Fc 'darker sky please')" "1"
check_eq "--translate: system asks for instructions JSON" \
  "$(printf '%s' "$tr_body" | jq -r '.body.messages[0].content' | grep -c '"instructions"')" "1"
check_eq "--translate: no generator request" "$(jq -c 'select(.body.messages[0].role != "system")' "$work/requests.jsonl" | wc -l | tr -d ' ')" "0"

# --- --translate: a smaller layer is scaled to the image before compositing ---------
run clean.png --translate --annotation layer-small.png --critic acme/critic-translate --out "$work/tr2.json"
check_code "--translate, scaled layer: exit 0" "$code" 0
jq -c 'select(.body.model=="acme/critic-translate")' "$work/requests.jsonl" | jq -r '.body.messages[1].content[2].image_url.url' \
  | sed 's/^data:image\/png;base64,//' | base64 -d > "$work/sent-scaled.png"
check_eq "--translate, scaled layer: top-left 2x2 block blue, rest white" \
  "$(python3 -c "
import sys; sys.path.insert(0, '$ROOT')
from lib import png
w, h, rows = png.decode(open('$work/sent-scaled.png', 'rb').read())
print(w, h, bytes(rows[1][4:8]).hex(), bytes(rows[2][8:12]).hex())")" "4 4 0000ffff ffffffff"

# --- --translate: a non-PNG clean image gets the layer sent separately --------------
printf '\xff\xd8\xff\xe0fakejpeg' > clean.jpg
run clean.jpg --translate --annotation layer.png --critic acme/critic-translate --out "$work/tr3.json"
check_code "--translate, jpeg: exit 0" "$code" 0
jpg_content="$(jq -c 'select(.body.model=="acme/critic-translate")' "$work/requests.jsonl" | jq -c '.body.messages[1].content')"
check_eq "--translate, jpeg: clean image sent as jpeg" "$(printf '%s' "$jpg_content" | jq -r '.[1].image_url.url' | cut -c1-23)" "data:image/jpeg;base64,"
printf '%s' "$jpg_content" | jq -r '.[2].image_url.url' | sed 's/^data:image\/png;base64,//' | base64 -d > "$work/sent-layer.png"
check_eq "--translate, jpeg: layer sent as-is" "$(cmp -s "$work/sent-layer.png" layer.png && echo same || echo different)" "same"
check_eq "--translate, jpeg: text says it is the layer alone" \
  "$(printf '%s' "$jpg_content" | jq -r '.[0].text' | grep -c "pen layer alone")" "1"

# --- --translate: video markers send their frames with timestamps -------------------
printf 'not really a video' > clip.mp4
cp layer.png frame1.png
cat > "$work/frames.json" <<EOF
[{"t": 18.2, "text": "the logo flickers", "frame": "frame1.png"}, {"t": 3, "text": "too loud", "frame": null}]
EOF
run clip.mp4 --translate --frames-file "$work/frames.json" --critic acme/critic-translate --out "$work/tr4.json"
check_code "--translate, video markers: exit 0" "$code" 0
vid_content="$(jq -c 'select(.body.model=="acme/critic-translate")' "$work/requests.jsonl" | jq -c '.body.messages[1].content')"
check_eq "--translate, video markers: only the captured frame is sent as an image" \
  "$(printf '%s' "$vid_content" | jq -r 'map(.type) | join(",")')" "text,image_url"
check_eq "--translate, video markers: timestamps in the text" \
  "$(printf '%s' "$vid_content" | jq -r '.[0].text' | grep -Ec 'at 18.2s: the logo flickers \(captured frame: image 1\)|at 3s: too loud')" "2"

run clean.png --translate --critic acme/critic-translate --out "$work/tr5.json"
check_code "--translate with nothing to translate: exit 2" "$code" 2
run clean.png --translate --annotation missing.png --critic acme/critic-translate --out "$work/tr6.json"
check_code "--translate with a missing layer: exit 2" "$code" 2

exit $fail

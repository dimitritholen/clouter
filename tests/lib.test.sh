#!/usr/bin/env bash
# Tests for lib/keys.py and lib/jev.py against a local stand-in for both Jev
# transports. The stand-in records every request (path, auth header, body)
# and fails on demand from words in the state, so each case is visible in
# its input. Needs python3 and jq; no key, no network.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null' EXIT

# Stand-in for /api/alpha/decisions and /v1/systemone: answers every
# question by its type, appends each request to requests.jsonl, returns 500
# while the state says "boom", and 500 once then 200 when it says "flaky".
python3 - "$work" <<'EOF_SERVER' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

work = sys.argv[1]
flaky_seen = set()

def answer(q):
    if q["type"] == "choice":
        first = sorted(q["criteria"])[0]
        return {"type": "choice", "choice": first, "confidence": 0.9,
                "probabilities": {k: (0.9 if k == first else 0.05) for k in q["criteria"]}}
    if q["type"] == "score":
        return {"type": "score", "score": 1.0, "confidence": 0.8,
                "legend": {str(i): c for i, c in enumerate(q["criteria"])}}
    return {"type": "noul", "noul": 0.5}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(f"{work}/requests.jsonl", "a") as f:
            f.write(json.dumps({"path": self.path,
                                "auth": self.headers.get("Authorization"),
                                "body": body}) + "\n")
        state = json.dumps(body["state"])
        if "boom" in state or ("flaky" in state and state not in flaky_seen):
            flaky_seen.add(state)
            out = b'{"error":{"message":"stand-in exploded"}}'
            self.send_response(500)
            self.send_header("x-request-id", "req-500")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        out = json.dumps({"model": body["model"], "id": "req-ok",
                          "answers": {k: answer(q) for k, q in body["questions"].items()},
                          "usage": {"input_tokens": 3, "output_tokens": 1}}).encode()
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
base="http://127.0.0.1:$(cat "$work/port")"

export CLOUTER_CREDENTIALS="$work/credentials"
export OPENROUTER_BASE_URL="$base" TYPESAFE_BASE_URL="$base"
unset OPENROUTER_API_KEY TYPESAFE_API_KEY TYPESAFE_DEFAULT_MODEL

py() { # python snippet with lib importable -> stdout in $out, exit in $code
  out=$(cd "$ROOT" && python3 -c "$1" 2>"$work/stderr"); code=$?
}
check_code() { if [ "$2" -eq "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (exit %s, want %s): %s\n' "$1" "$2" "$3" "$(cat "$work/stderr")"; fail=1; fi; }
check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }
last_request() { tail -n 1 "$work/requests.jsonl"; }
requests_count() { [ -f "$work/requests.jsonl" ] && wc -l < "$work/requests.jsonl" | tr -d " " || echo 0; }

# --- keys -----------------------------------------------------------------

py 'from lib import keys; print(keys.get("OPENROUTER_API_KEY"))'
check_code "missing key raises" "$code" 1
check_eq "missing key names the key and the file" "$(grep -c 'OPENROUTER_API_KEY is not set.*credentials' "$work/stderr")" "1"
check_eq "missing key is MissingKey" "$(grep -c '^lib.keys.MissingKey: ' "$work/stderr")" "1"

py 'from lib import keys; print(keys.set("OPENROUTER_API_KEY", "file-key"))'
check_code "set writes the file" "$code" 0
check_eq "file mode is 0600" "$(stat -c %a "$work/credentials" 2>/dev/null || stat -f %Lp "$work/credentials")" "600"
check_eq "file holds NAME=value" "$(cat "$work/credentials")" "OPENROUTER_API_KEY=file-key"

py 'from lib import keys; print(keys.get("OPENROUTER_API_KEY"))'
check_eq "file key read back" "$out" "file-key"

OPENROUTER_API_KEY=env-key py 'from lib import keys; print(keys.get("OPENROUTER_API_KEY"))'
check_eq "env beats file" "$out" "env-key"

EVAL_TYPESAFE_API_KEY=eval-key py 'from lib import keys; print(keys.get("TYPESAFE_API_KEY"))'
check_eq "EVAL_ prefixed variable falls back for eval cases" "$out" "eval-key"

TYPESAFE_API_KEY=plain-key EVAL_TYPESAFE_API_KEY=eval-key py 'from lib import keys; print(keys.get("TYPESAFE_API_KEY"))'
check_eq "plain env beats its EVAL_ fallback" "$out" "plain-key"

py 'from lib import keys; keys.set("OTHER", "x"); keys.set("OPENROUTER_API_KEY", "new-key")'
check_eq "set replaces its line and keeps the rest" "$(sort "$work/credentials" | tr '\n' ' ')" "OPENROUTER_API_KEY=new-key OTHER=x "
check_eq "set keeps mode 0600" "$(stat -c %a "$work/credentials" 2>/dev/null || stat -f %Lp "$work/credentials")" "600"

py 'from lib import keys; print(keys.find("NOPE"))'
check_eq "find returns None for an absent key" "$out" "None"

chmod 644 "$work/credentials"
py 'from lib import keys; print(keys.get("OPENROUTER_API_KEY"))'
check_code "0644 file refused" "$code" 1
check_eq "refusal names mode and fix" "$(grep -c 'mode 0644.*chmod 600' "$work/stderr")" "1"
OPENROUTER_API_KEY=env-key py 'from lib import keys; print(keys.get("OPENROUTER_API_KEY"))'
check_eq "env key skips the loose file" "$out" "env-key"
py 'from lib import keys; keys.os.name = "nt"; print(keys.get("OPENROUTER_API_KEY"))'
check_eq "Windows (os.name nt): no POSIX mode check, file key read" "$out" "new-key"
chmod 600 "$work/credentials"

# --- jev ------------------------------------------------------------------

ask='from lib import jev
import json, sys
r = jev.decide({"task": sys.argv[1]}, {
    "tier": jev.choice("Which tier?", {"haiku": "cheap", "sonnet": "mid"}),
    "urgent": jev.noul("Is it urgent?"),
    "mood": jev.score("How angry?", ["calm", "angry"])}, timeout=2)
print(json.dumps(r))'
ask_run() { out=$(cd "$ROOT" && python3 -c "$ask" "$1" 2>"$work/stderr"); code=$?; }

rm -f "$work/requests.jsonl"
ask_run "route this"
check_code "openrouter: decided" "$code" 0
check_eq "answers parsed" "$(printf '%s' "$out" | jq -r '.answers.tier.choice, .answers.urgent.noul, .answers.mood.score' | tr '\n' ' ')" "haiku 0.5 1.0 "
check_eq "usage and request id returned" "$(printf '%s' "$out" | jq -c '[.usage.input_tokens, .request_id, .transport]')" '[3,"req-ok","openrouter"]'
check_eq "openrouter path" "$(last_request | jq -r .path)" "/api/alpha/decisions"
check_eq "openrouter model" "$(last_request | jq -r .body.model)" "typesafe/jev-1.13"
check_eq "bearer from the file" "$(last_request | jq -r .auth)" "Bearer new-key"
check_eq "three typed questions sent" "$(last_request | jq -c '[.body.questions[].type]')" '["choice","noul","score"]'
openrouter_body="$(last_request | jq -c '.body | del(.model)')"

TYPESAFE_API_KEY=ts-key ask_run "route this"
check_code "typesafe: decided" "$code" 0
check_eq "typesafe path" "$(last_request | jq -r .path)" "/v1/systemone"
check_eq "typesafe model" "$(last_request | jq -r .body.model)" "jev-latest"
check_eq "typesafe bearer from env" "$(last_request | jq -r .auth)" "Bearer ts-key"
check_eq "typesafe transport reported" "$(printf '%s' "$out" | jq -r .transport)" "typesafe"
check_eq "same body on both transports" "$(last_request | jq -c '.body | del(.model)')" "$openrouter_body"

TYPESAFE_API_KEY=ts-key TYPESAFE_DEFAULT_MODEL=jev-1.12 ask_run "route this"
check_eq "typesafe model override" "$(last_request | jq -r .body.model)" "jev-1.12"

rm -f "$work/requests.jsonl"
start=$(date +%s%N)
ask_run "boom"
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
check_code "500 twice: raises" "$code" 1
check_eq "500 retried exactly once" "$(requests_count)" "2"
check_eq "error carries status and request id" "$(grep -c 'JevError.*status 500.*request req-500' "$work/stderr")" "1"
[ "$elapsed_ms" -lt 2500 ] && printf 'ok   retry waited at most a second (%sms)\n' "$elapsed_ms" || { printf 'FAIL retry took %sms\n' "$elapsed_ms"; fail=1; }

rm -f "$work/requests.jsonl"
ask_run "flaky"
check_code "500 then 200: decided" "$code" 0
check_eq "flaky took two requests" "$(requests_count)" "2"

rm -f "$work/requests.jsonl"
OPENROUTER_BASE_URL="http://127.0.0.1:1" ask_run "route this"
check_code "unreachable: raises" "$code" 1
check_eq "unreachable is a JevError" "$(grep -c 'JevError: Jev unreachable' "$work/stderr")" "1"

rm "$work/credentials"
ask_run "route this"
check_code "no key anywhere: MissingKey" "$code" 1
check_eq "no key names OPENROUTER_API_KEY" "$(grep -c 'MissingKey: OPENROUTER_API_KEY' "$work/stderr")" "1"
check_eq "no request sent without a key" "$(requests_count)" "0"

exit $fail

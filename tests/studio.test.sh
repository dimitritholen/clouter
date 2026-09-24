#!/usr/bin/env bash
# Tests for skills/visual/studio.py: push/serve/wait/stop against a real
# server bound to 127.0.0.1 (loopback only, no external network, no browser),
# plus POST /api/models and GET /api/catalogue against a stand-in OpenRouter
# (image-model listing and /api/alpha/decisions) so no external network is
# ever reached.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/visual/studio.py"
fail=0
work="$(mktemp -d)"
S="$work/session"
cleanup() {
  "$SCRIPT" stop --session "$S" >/dev/null 2>&1
  [ -n "${S2:-}" ] && "$SCRIPT" stop --session "$S2" >/dev/null 2>&1
  [ -n "${or_server_pid:-}" ] && kill "$or_server_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
export CLOUTER_STUDIO_NO_OPEN=1
unset CLOUTER_STUDIO_DIR

# --- stand-in OpenRouter: image-model catalogue + Jev /api/alpha/decisions --
python3 - "$work" <<'EOF_SERVER' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
work = sys.argv[1]

CATALOGUE = [
    {"id": "test/model", "name": "Test Model", "description": "already used in the session",
     "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.00003"}},
    {"id": "stub/alt-a", "name": "Stub Alt A", "description": "cheapest alternative",
     "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.00001"}},
    {"id": "stub/alt-b", "name": "Stub Alt B", "description": "mid-priced alternative",
     "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.00002"}},
    {"id": "stub/alt-best", "name": "Stub Alt Best", "description": "Jev's recommended pick",
     "architecture": {"input_modalities": ["text", "image"]}, "pricing": {"image_output": "0.00005"}},
]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, status, obj):
        raw = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/api/v1/models?output_modalities=image":
            self.send_json(200, {"data": CATALOGUE}); return
        self.send_json(404, {"error": {"message": "no such path"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/api/alpha/decisions":
            state = body.get("state") or {}
            if state.get("prompt") == "trigger jev failure":
                self.send_json(500, {"error": {"message": "stand-in exploded"}}); return
            if state.get("prompt") == "slow round":
                import time
                time.sleep(1.0)
            criteria = body["questions"]["model"]["criteria"]
            ids = list(criteria)
            pick = next((i for i in ids if "best" in i), ids[0])
            conf = 0.8
            probs = {i: round((1 - conf) / max(1, len(ids) - 1), 3) for i in ids}
            probs[pick] = conf
            self.send_json(200, {"model": "jev-stand-in", "id": "req-jev", "answers": {
                "model": {"type": "choice", "choice": pick, "confidence": conf, "probabilities": probs}}})
            return
        self.send_json(404, {"error": {"message": "no such path"}})


server = HTTPServer(("127.0.0.1", 0), Handler)
open(f"{work}/oport", "w").write(str(server.server_port))
server.serve_forever()
EOF_SERVER
or_server_pid=$!
for _ in $(seq 50); do [ -s "$work/oport" ] && break; sleep 0.1; done
[ -s "$work/oport" ] || { printf 'FAIL stand-in OpenRouter server did not start\n'; exit 1; }
export OPENROUTER_BASE_URL="http://127.0.0.1:$(cat "$work/oport")"
export CLOUTER_CREDENTIALS="$work/no-such-credentials-file"
export OPENROUTER_API_KEY="test-key"

check_code() { if [ "$2" -eq "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (exit %s, want %s): %s\n' "$1" "$2" "$3" "$(cat "$work/stderr" 2>/dev/null)"; fail=1; fi; }
check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }

# jget <json> <python expression over d>
jget() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

# http <method> <path> [body-file] [content-type] -> prints "<status> <body>"
http() {
  python3 - "$URL" "$@" <<'PY'
import sys, urllib.request, urllib.error
base, method, path = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(sys.argv[4], "rb").read() if len(sys.argv) > 4 else None
headers = {"Content-Type": sys.argv[5]} if len(sys.argv) > 5 else {}
req = urllib.request.Request(base.rstrip("/") + path, data=data, method=method, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        body = r.read()
        json_ = r.headers.get("Content-Type", "").startswith("application/json")
        print(r.status, body.decode("utf-8") if json_ else f"<{len(body)} bytes>")
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode("utf-8", "replace"))
PY
}

TINY_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
printf '%s' "$TINY_PNG_B64" | base64 -d > "$work/one.png"
printf 'not a png' > "$work/bad.bin"
printf 'a red fox, flat vector' > "$work/request.txt"
printf 'brief for round 1' > "$work/brief.txt"
printf '[{"id":"d1","type":"artifact","where":"left ear","box":[0.1,0.1,0.2,0.2],"severity":3,"fix":"clean"}]' > "$work/defects.json"

# --- push without request/modality on a new session -------------------------
"$SCRIPT" push --session "$S" --file "$work/one.png" --model m --cost 0.01 --brief-file "$work/brief.txt" >/dev/null 2>"$work/stderr"
check_code "push on a new session without --request-file: exit 2" "$?" 2

# --- push creates session + round 1 + server --------------------------------
out=$("$SCRIPT" push --session "$S" --file "$work/one.png" --model test/model --cost 0.03 \
  --brief-file "$work/brief.txt" --defects-file "$work/defects.json" \
  --request-file "$work/request.txt" --modality raster_image 2>"$work/stderr")
check_code "push: exit 0" "$?" 0
check_eq "push: round 1" "$(jget "$out" 'd["round"]')" "1"
URL=$(jget "$out" 'd["url"]')
case "$URL" in http://127.0.0.1:*/) printf 'ok   push: url on loopback\n' ;; *) printf 'FAIL push: url %s\n' "$URL"; fail=1 ;; esac
[ -f "$S/rounds/round-1.png" ] && printf 'ok   push: round file copied\n' || { printf 'FAIL push: round file missing\n'; fail=1; }
[ -f "$S/server.json" ] && printf 'ok   push: server.json written\n' || { printf 'FAIL push: server.json missing\n'; fail=1; }
session=$(cat "$S/session.json")
check_eq "session: state waiting" "$(jget "$session" 'd["state"]')" "waiting"
check_eq "session: media_type" "$(jget "$session" 'd["rounds"][0]["media_type"]')" "image/png"
check_eq "session: request verbatim" "$(jget "$session" 'd["request"]')" "a red fox, flat vector"

# --- GET /api/session, /files, traversal ------------------------------------
resp=$(http GET /api/session)
check_eq "GET /api/session: 200" "${resp%% *}" "200"
check_eq "GET /api/session: rounds" "$(jget "${resp#* }" 'len(d["rounds"])')" "1"
resp=$(http GET /files/rounds/round-1.png)
check_eq "GET /files/rounds/round-1.png: 200" "${resp%% *}" "200"
resp=$(http GET /files/rounds/../session.json)
check_eq "GET /files/rounds/../session.json: 404" "${resp%% *}" "404"
resp=$(http GET /files/rounds/%2e%2e/session.json)
check_eq "GET /files encoded traversal: 404" "${resp%% *}" "404"
resp=$(http GET /files/%2Fetc%2Fpasswd)
check_eq "GET /files absolute path: 404" "${resp%% *}" "404"
ln -s "$S/session.json" "$S/uploads/escape.json"
resp=$(http GET /files/uploads/escape.json)
check_eq "GET /files symlink escape: 404" "${resp%% *}" "404"
resp=$(http GET /static/secret.py)
check_eq "GET /static non-whitelisted: 404" "${resp%% *}" "404"

# --- upload -----------------------------------------------------------------
resp=$(http POST "/api/upload?kind=annotation" "$work/one.png" image/png)
check_eq "upload PNG: 200" "${resp%% *}" "200"
annot=$(jget "${resp#* }" 'd["path"]')
case "$annot" in uploads/annotation-*.png) printf 'ok   upload: path under uploads/\n' ;; *) printf 'FAIL upload path %s\n' "$annot"; fail=1 ;; esac
[ -f "$S/$annot" ] && printf 'ok   upload: file written\n' || { printf 'FAIL upload: file missing\n'; fail=1; }
resp=$(http POST "/api/upload?kind=annotation" "$work/bad.bin" image/png)
check_eq "upload non-PNG: 400" "${resp%% *}" "400"
resp=$(http POST "/api/upload?kind=other" "$work/one.png" image/png)
check_eq "upload bad kind: 400" "${resp%% *}" "400"

# --- feedback validation ----------------------------------------------------
printf '{"round": 9, "text": "x"}' > "$work/fb-bad.json"
resp=$(http POST /api/feedback "$work/fb-bad.json" application/json)
check_eq "feedback on unknown round: 400" "${resp%% *}" "400"
printf '{"round": 1, "annotation": "uploads/nope.png"}' > "$work/fb-bad2.json"
resp=$(http POST /api/feedback "$work/fb-bad2.json" application/json)
check_eq "feedback with missing upload: 400" "${resp%% *}" "400"

# --- SSE delivers an event after POST /api/feedback -------------------------
python3 - "$URL" > "$work/sse.out" 2>&1 <<'PY' &
import sys, urllib.request
r = urllib.request.urlopen(sys.argv[1] + "events", timeout=10)
events = 0
for line in r:
    line = line.decode()
    if line.startswith("event: session"):
        events += 1
    if line.startswith("data:") and events == 2:
        print(line.strip()); break
PY
sse_pid=$!
sleep 0.5
printf '{"round": 1, "text": "make it bluer", "accepted_defects": ["d1"], "notes": [{"n": 1, "x": 0.4, "y": 0.1, "text": "here"}], "annotation": "%s"}' "$annot" > "$work/fb.json"
resp=$(http POST /api/feedback "$work/fb.json" application/json)
check_eq "POST /api/feedback: 200" "${resp%% *}" "200"
check_eq "POST /api/feedback: id 1" "$(jget "${resp#* }" 'd["id"]')" "1"
for _ in $(seq 1 50); do kill -0 "$sse_pid" 2>/dev/null || break; sleep 0.1; done
kill "$sse_pid" 2>/dev/null
check_eq "SSE: second event carries state feedback" "$(grep -c '"state": "feedback"' "$work/sse.out")" "1"

# --- wait returns feedback --------------------------------------------------
out=$("$SCRIPT" wait --session "$S" --timeout 5 2>"$work/stderr")
check_code "wait on feedback: exit 0" "$?" 0
check_eq "wait: text" "$(jget "$out" 'd["text"]')" "make it bluer"
check_eq "wait: annotation absolute" "$(jget "$out" 'd["annotation"]')" "$S/$annot"
check_eq "wait: round_file absolute" "$(jget "$out" 'd["round_file"]')" "$S/rounds/round-1.png"
check_eq "wait: marked consumed" "$(jget "$(cat "$S/session.json")" 'd["feedback"][0]["consumed"]')" "True"

# --- timeout with nothing pending -------------------------------------------
"$SCRIPT" wait --session "$S" --timeout 1 >/dev/null 2>"$work/stderr"
check_code "wait with nothing pending: exit 20" "$?" 20

# --- second push reuses the server ------------------------------------------
out=$("$SCRIPT" push --session "$S" --file "$work/one.png" --model test/model --cost 0.02 --brief-file "$work/brief.txt" --parent 1 2>"$work/stderr")
check_code "second push: exit 0" "$?" 0
check_eq "second push: round 2" "$(jget "$out" 'd["round"]')" "2"
check_eq "second push: same url" "$(jget "$out" 'd["url"]')" "$URL"

# --- accept -----------------------------------------------------------------
printf '{"round": 2}' > "$work/acc.json"
resp=$(http POST /api/accept "$work/acc.json" application/json)
check_eq "POST /api/accept: 200" "${resp%% *}" "200"
out=$("$SCRIPT" wait --session "$S" --timeout 5 2>"$work/stderr")
check_code "wait on accept: exit 10" "$?" 10
check_eq "wait on accept: action" "$(jget "$out" 'd["action"]')" "accept"

# --- a lost accept result doesn't hang a retry until --timeout --------------
start=$(date +%s)
out=$("$SCRIPT" wait --session "$S" --timeout 5 2>"$work/stderr")
rc=$?
elapsed=$(( $(date +%s) - start ))
check_code "second wait on consumed accept: exit 10" "$rc" 10
check_eq "second wait on consumed accept: round" "$(jget "$out" 'd["round"]')" "2"
if [ "$elapsed" -le 2 ]; then printf 'ok   second wait on consumed accept: returns immediately\n'; else printf 'FAIL second wait on consumed accept: took %ss\n' "$elapsed"; fail=1; fi

out=$("$SCRIPT" status --session "$S" 2>"$work/stderr")
check_eq "status: state accepted" "$(jget "$out" 'd["state"]')" "accepted"
check_eq "status: 2 rounds" "$(jget "$out" 'd["rounds"]')" "2"

# --- push accepts defects file shaped {"defects": [...]} (critique.py --suggest) --
# and --message-file, and stores summary/model_trouble/models alongside it.
printf 'Claude'"'"'s note for round 3' > "$work/message.txt"
printf '{"defects": [{"id":"d2","type":"artifact","where":"tail","box":[0.3,0.3,0.1,0.1],"severity":2,"fix":"trim"}], "summary": "Mostly right, tail is off.", "model_trouble": true, "models": [{"id": "stub/alt-a", "name": "Stub Alt A", "price": 1e-05, "unit": "image token", "probability": 0.4, "reference_supported": true}]}' > "$work/defects-dict.json"
out=$("$SCRIPT" push --session "$S" --file "$work/one.png" --model test/model --cost 0.01 \
  --brief-file "$work/brief.txt" --defects-file "$work/defects-dict.json" --message-file "$work/message.txt" --parent 2 2>"$work/stderr")
check_code "push with dict-shaped defects file: exit 0" "$?" 0
check_eq "push: round 3" "$(jget "$out" 'd["round"]')" "3"
session=$(cat "$S/session.json")
check_eq "push: dict-shaped defects stored as list" "$(jget "$session" 'd["rounds"][2]["defects"][0]["id"]')" "d2"
check_eq "push: message stored" "$(jget "$session" 'd["rounds"][2]["message"]')" "Claude's note for round 3"
check_eq "push: summary stored" "$(jget "$session" 'd["rounds"][2]["summary"]')" "Mostly right, tail is off."
check_eq "push: model_trouble stored" "$(jget "$session" 'd["rounds"][2]["model_trouble"]')" "True"
check_eq "push: models stored" "$(jget "$session" 'd["rounds"][2]["models"][0]["id"]')" "stub/alt-a"

# --- push with a bare-list defects file still works, no message/summary/models -
out=$("$SCRIPT" push --session "$S" --file "$work/one.png" --model test/model --cost 0.01 \
  --brief-file "$work/brief.txt" --defects-file "$work/defects.json" --parent 3 2>"$work/stderr")
check_code "push with bare-list defects file: exit 0" "$?" 0
session=$(cat "$S/session.json")
check_eq "push: bare-list round has no message key" "$(jget "$session" '"message" in d["rounds"][3]')" "False"
check_eq "push: bare-list round has no summary key" "$(jget "$session" '"summary" in d["rounds"][3]')" "False"

# --- POST /api/models: 202, then models_request done and round.models populated --
printf '{"round": 1}' > "$work/round1-req.json"
resp=$(http POST /api/models "$work/round1-req.json" application/json)
check_eq "POST /api/models round 1: 202" "${resp%% *}" "202"
check_eq "POST /api/models round 1: status pending" "$(jget "${resp#* }" 'd["status"]')" "pending"
done=0
for _ in $(seq 1 50); do
  session=$(cat "$S/session.json")
  status=$(jget "$session" '(d.get("models_request") or {}).get("status")')
  [ "$status" = "done" ] && { done=1; break; }
  sleep 0.1
done
[ "$done" -eq 1 ] && printf 'ok   POST /api/models round 1: models_request reaches done\n' || { printf 'FAIL POST /api/models round 1: still %s\n' "$status"; fail=1; }
session=$(cat "$S/session.json")
check_eq "POST /api/models round 1: round.models excludes test/model" \
  "$(jget "$session" "\"test/model\" not in [m[\"id\"] for m in d[\"rounds\"][0][\"models\"]]")" "True"
check_eq "POST /api/models round 1: round.models non-empty" \
  "$(jget "$session" 'len(d["rounds"][0]["models"]) > 0')" "True"

# --- POST /api/models on an unknown round: 400 ------------------------------
printf '{"round": 999}' > "$work/round-bad.json"
resp=$(http POST /api/models "$work/round-bad.json" application/json)
check_eq "POST /api/models unknown round: 400" "${resp%% *}" "400"

# --- push a round with a distinct brief for the 409/error scenarios --------
printf 'slow round' > "$work/brief-slow.txt"
out=$("$SCRIPT" push --session "$S" --file "$work/one.png" --model test/model --cost 0.01 \
  --brief-file "$work/brief-slow.txt" --parent 4 2>"$work/stderr")
slow_round=$(jget "$out" 'd["round"]')
printf 'trigger jev failure' > "$work/brief-fail.txt"
out=$("$SCRIPT" push --session "$S" --file "$work/one.png" --model test/model --cost 0.01 \
  --brief-file "$work/brief-fail.txt" --parent "$slow_round" 2>"$work/stderr")
fail_round=$(jget "$out" 'd["round"]')

# --- POST /api/models twice while the first is still pending: 409 ----------
printf '{"round": %s}' "$slow_round" > "$work/round-slow.json"
resp=$(http POST /api/models "$work/round-slow.json" application/json)
check_eq "POST /api/models slow round: 202" "${resp%% *}" "202"
resp=$(http POST /api/models "$work/round-slow.json" application/json)
check_eq "POST /api/models while pending: 409" "${resp%% *}" "409"
done=0
for _ in $(seq 1 50); do
  status=$(jget "$(cat "$S/session.json")" '(d.get("models_request") or {}).get("status")')
  [ "$status" != "pending" ] && { done=1; break; }
  sleep 0.1
done
[ "$done" -eq 1 ] && printf 'ok   POST /api/models slow round: settles\n' || { printf 'FAIL POST /api/models slow round: still pending\n'; fail=1; }

# --- POST /api/models: a stub failure sets status error ---------------------
printf '{"round": %s}' "$fail_round" > "$work/round-fail.json"
resp=$(http POST /api/models "$work/round-fail.json" application/json)
check_eq "POST /api/models failing round: 202" "${resp%% *}" "202"
done=0
for _ in $(seq 1 50); do
  status=$(jget "$(cat "$S/session.json")" '(d.get("models_request") or {}).get("status")')
  [ "$status" = "error" ] && { done=1; break; }
  sleep 0.1
done
[ "$done" -eq 1 ] && printf 'ok   POST /api/models failing round: reaches error\n' || { printf 'FAIL POST /api/models failing round: still %s\n' "$status"; fail=1; }
session=$(cat "$S/session.json")
check_eq "POST /api/models failing round: error message present" \
  "$(jget "$session" 'bool((d.get("models_request") or {}).get("error"))')" "True"

# --- POST /api/models with no stored key: a plain setup message, not raw ---
# exception text. Its own server/env so it doesn't leak the OPENROUTER_API_KEY
# already exported above into this case.
S2="$work/session-nokey"
out=$(env -u OPENROUTER_API_KEY -u EVAL_OPENROUTER_API_KEY \
  CLOUTER_CREDENTIALS="$work/nokey-credentials-file" \
  "$SCRIPT" push --session "$S2" --file "$work/one.png" --model test/model --cost 0.01 \
  --brief-file "$work/brief.txt" --request-file "$work/request.txt" --modality raster_image 2>"$work/stderr")
check_code "push for no-key session: exit 0" "$?" 0
URL2=$(jget "$out" 'd["url"]')
printf '{"round": 1}' > "$work/round-nokey.json"
URL_MAIN="$URL"
URL="$URL2"
resp=$(http POST /api/models "$work/round-nokey.json" application/json)
URL="$URL_MAIN"
check_eq "POST /api/models no key: 202" "${resp%% *}" "202"
done=0
for _ in $(seq 1 50); do
  status=$(jget "$(cat "$S2/session.json")" '(d.get("models_request") or {}).get("status")')
  [ "$status" = "error" ] && { done=1; break; }
  sleep 0.1
done
[ "$done" -eq 1 ] && printf 'ok   POST /api/models no key: reaches error\n' || { printf 'FAIL POST /api/models no key: still %s\n' "$status"; fail=1; }
check_eq "POST /api/models no key: error message" \
  "$(jget "$(cat "$S2/session.json")" '(d.get("models_request") or {}).get("error")')" \
  "No OpenRouter key stored. Run /clouter:visual setup in Claude Code, then try again."
"$SCRIPT" stop --session "$S2" 2>"$work/stderr"

# --- GET /api/catalogue: the stubbed list, sorted by price ------------------
resp=$(http GET /api/catalogue)
check_eq "GET /api/catalogue: 200" "${resp%% *}" "200"
check_eq "GET /api/catalogue: 4 models" "$(jget "${resp#* }" 'len(d["models"])')" "4"
check_eq "GET /api/catalogue: sorted by price" \
  "$(jget "${resp#* }" '[m["id"] for m in d["models"]]')" \
  "['stub/alt-a', 'stub/alt-b', 'test/model', 'stub/alt-best']"

# --- feedback with only a model: valid, wait prints it as sent --------------
printf '{"round": 1, "model": "stub/alt-a"}' > "$work/fb-model.json"
resp=$(http POST /api/feedback "$work/fb-model.json" application/json)
check_eq "feedback with only model: 200" "${resp%% *}" "200"
out=$("$SCRIPT" wait --session "$S" --timeout 5 2>"$work/stderr")
check_code "wait on model-only feedback: exit 0" "$?" 0
check_eq "wait: model as sent" "$(jget "$out" 'd["model"]')" "stub/alt-a"

# --- feedback with an unknown model id: 400 once the catalogue is cached ----
printf '{"round": 1, "model": "unknown/nope"}' > "$work/fb-model-bad.json"
resp=$(http POST /api/feedback "$work/fb-model-bad.json" application/json)
check_eq "feedback with unknown model id: 400" "${resp%% *}" "400"

# --- stop, then wait reports server gone ------------------------------------
pid=$(jget "$(cat "$S/server.json")" 'd["pid"]')
"$SCRIPT" stop --session "$S" 2>"$work/stderr"
check_code "stop: exit 0" "$?" 0
if kill -0 "$pid" 2>/dev/null; then printf 'FAIL stop: server pid %s still alive\n' "$pid"; fail=1; else printf 'ok   stop: server pid gone\n'; fi
[ ! -f "$S/server.json" ] && printf 'ok   stop: server.json removed\n' || { printf 'FAIL stop: server.json still there\n'; fail=1; }
"$SCRIPT" wait --session "$S" --timeout 5 >/dev/null 2>"$work/stderr"
check_code "wait after stop: exit 30" "$?" 30

# --- bad arguments ----------------------------------------------------------
"$SCRIPT" wait --session "$work/nowhere" --timeout 1 >/dev/null 2>"$work/stderr"
check_code "wait on a missing session: exit 2" "$?" 2

exit $fail

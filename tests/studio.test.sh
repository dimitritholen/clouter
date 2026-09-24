#!/usr/bin/env bash
# Tests for skills/visual/studio.py: push/serve/wait/stop against a real
# server bound to 127.0.0.1 (loopback only, no external network, no browser).
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/visual/studio.py"
fail=0
work="$(mktemp -d)"
S="$work/session"
cleanup() {
  "$SCRIPT" stop --session "$S" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
export CLOUTER_STUDIO_NO_OPEN=1
unset CLOUTER_STUDIO_DIR

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
printf '{"defects": [{"id":"d2","type":"artifact","where":"tail","box":[0.3,0.3,0.1,0.1],"severity":2,"fix":"trim"}]}' > "$work/defects-dict.json"
out=$("$SCRIPT" push --session "$S" --file "$work/one.png" --model test/model --cost 0.01 \
  --brief-file "$work/brief.txt" --defects-file "$work/defects-dict.json" --parent 2 2>"$work/stderr")
check_code "push with dict-shaped defects file: exit 0" "$?" 0
check_eq "push: round 3" "$(jget "$out" 'd["round"]')" "3"
session=$(cat "$S/session.json")
check_eq "push: dict-shaped defects stored as list" "$(jget "$session" 'd["rounds"][2]["defects"][0]["id"]')" "d2"

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

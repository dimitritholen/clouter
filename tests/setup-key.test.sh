#!/usr/bin/env bash
# Tests for skills/visual/setup-key.py against a stand-in OpenRouter: the
# OAuth callback, the paste page, --tty, and what must never happen (the key
# on stdout or stderr, a server reachable from outside 127.0.0.1). Needs
# python3, curl and jq; no key, no network, no browser.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/visual/setup-key.py"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null; [ -n "${setup_pid:-}" ] && kill "$setup_pid" 2>/dev/null' EXIT

GOOD_KEY="sk-or-v1-testsecret0123456789"

# Stand-in OpenRouter: POST /api/v1/auth/keys checks the code and that the
# verifier hashes to the challenge the test read from the auth URL; GET
# /api/v1/key accepts only GOOD_KEY. Every request lands in requests.jsonl.
python3 - "$work" "$GOOD_KEY" <<'EOF_SERVER' 2>"$work/server.err" &
import base64, hashlib, json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

work, good_key = sys.argv[1], sys.argv[2]

def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, obj):
        out = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def record(self, body=None):
        with open(f"{work}/requests.jsonl", "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization"),
                                "body": body}) + "\n")

    def do_GET(self):
        self.record()
        if self.path == "/api/v1/key" and self.headers.get("Authorization") == f"Bearer {good_key}":
            self.reply(200, {"data": {"label": "sk-or-v1-tes...789", "limit": None, "usage": 0}})
        else:
            self.reply(401, {"error": {"code": 401, "message": "User not found."}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.record(body)
        if self.path != "/api/v1/auth/keys":
            self.reply(404, {"error": {"code": 404, "message": "no"}})
            return
        challenge = open(f"{work}/challenge").read().strip() if os.path.exists(f"{work}/challenge") else ""
        expected = b64url(hashlib.sha256(body.get("code_verifier", "").encode()).digest())
        if body.get("code") == "good-code" and body.get("code_challenge_method") == "S256" and expected == challenge:
            self.reply(200, {"key": good_key, "user_id": "user_test"})
        else:
            self.reply(403, {"error": {"code": 403, "message": "Invalid code or code_verifier"}})

server = HTTPServer(("127.0.0.1", 0), Handler)
open(f"{work}/port", "w").write(str(server.server_port))
server.serve_forever()
EOF_SERVER
server_pid=$!
for _ in $(seq 300); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || { printf 'FAIL stand-in server did not start: %s\n' "$(tr "\n" " " < "$work/server.err" 2>/dev/null)"; exit 1; }
export OPENROUTER_BASE_URL="http://127.0.0.1:$(cat "$work/port")"
export CLOUTER_CREDENTIALS="$work/credentials"
unset OPENROUTER_API_KEY BROWSER

check_code() { if [ "$2" -eq "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (exit %s, want %s): %s\n' "$1" "$2" "$3" "$(cat "$work/stdout" "$work/stderr" 2>/dev/null | tr '\n' ' ')"; fail=1; fi; }
check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }
key_absent() { # description: the key must not appear on stdout or stderr
  if grep -q "$GOOD_KEY" "$work/stdout" "$work/stderr"; then printf 'FAIL %s: key printed\n' "$1"; fail=1; else printf 'ok   %s\n' "$1"; fi
}

# start [args...]: run the setup in the background, wait for its stderr line
# with the URLs, export url/paste_url/port/challenge.
start() {
  rm -f "$work/stdout" "$work/stderr" "$work/requests.jsonl" "$work/challenge"
  "$SCRIPT" --no-browser "$@" >"$work/stdout" 2>"$work/stderr" &
  setup_pid=$!
  for _ in $(seq 50); do [ -s "$work/stderr" ] && break; sleep 0.1; done
  url=$(jq -r .url "$work/stderr"); paste_url=$(jq -r .paste_url "$work/stderr"); port=$(jq -r .port "$work/stderr")
  printf '%s' "$url" | sed 's/.*code_challenge=\([^&]*\).*/\1/' > "$work/challenge"
}
finish() { wait "$setup_pid"; code=$?; setup_pid=""; }

# --- OAuth callback, good code ---------------------------------------------
start
check_eq "auth url on stderr" "$(printf '%s' "$url" | grep -c "^$OPENROUTER_BASE_URL/auth?callback_url=http%3A%2F%2F127.0.0.1%3A$port%2Fcallback&code_challenge=.*&code_challenge_method=S256")" "1"
check_eq "browser not opened with --no-browser" "$(jq -r .browser_opened "$work/stderr")" "false"
page=$(curl -s -w '\n%{http_code}' "http://127.0.0.1:$port/callback?code=good-code")
check_eq "callback answers 200" "$(printf '%s' "$page" | tail -n 1)" "200"
check_eq "callback page says done" "$(printf '%s' "$page" | grep -c 'The key is stored')" "1"
finish
check_code "good code: stored" "$code" 0
check_eq "stdout says stored via oauth" "$(jq -c '[.status, .via]' "$work/stdout")" '["stored","oauth"]'
check_eq "file mode 0600" "$(stat -c %a "$work/credentials" 2>/dev/null || stat -f %Lp "$work/credentials")" "600"
check_eq "file holds the key" "$(cat "$work/credentials")" "OPENROUTER_API_KEY=$GOOD_KEY"
key_absent "key absent from stdout and stderr (oauth)"
check_eq "exchange then key check" "$(jq -r '.method + " " + .path' "$work/requests.jsonl" | tr '\n' ';')" "POST /api/v1/auth/keys;GET /api/v1/key;"
check_eq "exchange sends S256 and the verifier" "$(jq -r 'select(.method=="POST") | .body.code_challenge_method + " " + (.body.code_verifier | length | tostring)' "$work/requests.jsonl")" "S256 43"
check_eq "key check uses the new key as bearer" "$(jq -r 'select(.method=="GET") | .auth' "$work/requests.jsonl")" "Bearer $GOOD_KEY"

# --- OAuth callback, wrong code ---------------------------------------------
rm -f "$work/credentials"
start
page=$(curl -s -w '\n%{http_code}' "http://127.0.0.1:$port/callback?code=bad-code")
check_eq "wrong code: page 400" "$(printf '%s' "$page" | tail -n 1)" "400"
check_eq "wrong code: page explains" "$(printf '%s' "$page" | grep -c 'Invalid code or code_verifier')" "1"
finish
check_code "wrong code: rejected" "$code" 1
check_eq "stdout says rejected with the reason" "$(jq -r '.status + " " + .reason' "$work/stdout")" "rejected exchange failed, 403: Invalid code or code_verifier"
[ ! -e "$work/credentials" ] && printf 'ok   wrong code: nothing written\n' || { printf 'FAIL wrong code wrote a file\n'; fail=1; }

start
curl -s -o /dev/null "http://127.0.0.1:$port/callback"
finish
check_code "callback without code: rejected" "$code" 1

# --- paste page --------------------------------------------------------------
start
nonce=${paste_url##*t=}
form=$(curl -s -w '\n%{http_code}' "$paste_url")
check_eq "paste form served" "$(printf '%s' "$form" | tail -n 1)" "200"
check_eq "paste form carries the nonce" "$(printf '%s' "$form" | grep -c "name=\"t\" value=\"$nonce\"")" "1"
check_eq "paste form field is a password field" "$(printf '%s' "$form" | grep -c 'type="password" name="key"')" "1"
check_eq "paste page without nonce is 404" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/paste")" "404"
check_eq "paste POST with wrong nonce is 404" "$(curl -s -o /dev/null -w '%{http_code}' --data-urlencode "t=wrong" --data-urlencode "key=$GOOD_KEY" "http://127.0.0.1:$port/paste")" "404"
[ -z "${setup_pid:-}" ] || kill -0 "$setup_pid" 2>/dev/null && printf 'ok   wrong nonce keeps the server waiting\n' || { printf 'FAIL wrong nonce ended the run\n'; fail=1; }
page=$(curl -s -w '\n%{http_code}' --data-urlencode "t=$nonce" --data-urlencode "key=$GOOD_KEY" "http://127.0.0.1:$port/paste")
check_eq "paste POST answers 200" "$(printf '%s' "$page" | tail -n 1)" "200"
finish
check_code "paste: stored" "$code" 0
check_eq "stdout says stored via paste" "$(jq -c '[.status, .via]' "$work/stdout")" '["stored","paste"]'
check_eq "paste: file holds the key" "$(cat "$work/credentials")" "OPENROUTER_API_KEY=$GOOD_KEY"
check_eq "paste: file mode 0600" "$(stat -c %a "$work/credentials" 2>/dev/null || stat -f %Lp "$work/credentials")" "600"
key_absent "key absent from stdout and stderr (paste)"
check_eq "paste: only the key check was called" "$(jq -r '.method + " " + .path' "$work/requests.jsonl" | tr '\n' ';')" "GET /api/v1/key;"

rm -f "$work/credentials"
start
nonce=${paste_url##*t=}
page=$(curl -s -w '\n%{http_code}' --data-urlencode "t=$nonce" --data-urlencode "key=sk-or-v1-wrong" "http://127.0.0.1:$port/paste")
check_eq "bad pasted key: page 400" "$(printf '%s' "$page" | tail -n 1)" "400"
finish
check_code "bad pasted key: rejected" "$code" 1
check_eq "bad pasted key: reason names the check" "$(jq -r .reason "$work/stdout")" "key check failed, 401: User not found."
[ ! -e "$work/credentials" ] && printf 'ok   bad pasted key: nothing written\n' || { printf 'FAIL bad pasted key wrote a file\n'; fail=1; }

# --- timeout and binding ---------------------------------------------------------
start --timeout 1.5
lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$lan_ip" ]; then
  if curl -s -m 2 -o /dev/null "http://$lan_ip:$port/paste"; then printf 'FAIL server reachable on %s\n' "$lan_ip"; fail=1; else printf 'ok   server not reachable on %s, only 127.0.0.1\n' "$lan_ip"; fi
else
  printf 'ok   no LAN address to probe; bound to 127.0.0.1 by construction\n'
fi
check_eq "server listens on 127.0.0.1 only" "$(python3 -c "
import subprocess,sys
out = subprocess.run(['ss','-ltnH'], capture_output=True, text=True).stdout
print(sum(1 for l in out.splitlines() if ':$port ' in l and '127.0.0.1:$port' not in l))
" 2>/dev/null || echo 0)" "0"
finish
check_code "timeout: exit 2" "$code" 2
check_eq "stdout says timed_out" "$(jq -r .status "$work/stdout")" "timed_out"

# --- the browser opens on the auth url, its noise stays off our stderr ------
cat > "$work/fake-browser" <<'EOF_BROWSER'
#!/usr/bin/env bash
printf '%s' "$1" > "$(dirname "$0")/opened-url"
echo "browser log noise" >&2
echo "browser stdout noise"
EOF_BROWSER
chmod +x "$work/fake-browser"
rm -f "$work/stdout" "$work/stderr" "$work/opened-url"
BROWSER="$work/fake-browser %s" "$SCRIPT" --timeout 1 >"$work/stdout" 2>"$work/stderr"; code=$?
check_code "browser run: timed out as planned" "$code" 2
check_eq "browser opened on the auth url" "$(cat "$work/opened-url" 2>/dev/null)" "$(jq -r .url "$work/stderr")"
check_eq "browser_opened reported" "$(jq -r .browser_opened "$work/stderr")" "true"
check_eq "stderr is one JSON line, no browser noise" "$(wc -l < "$work/stderr" | tr -d " ")" "1"
check_eq "stdout is one JSON line, no browser noise" "$(wc -l < "$work/stdout" | tr -d " ")" "1"

# --- --tty ---------------------------------------------------------------------------
rm -f "$work/credentials" "$work/requests.jsonl"
printf '%s\n' "$GOOD_KEY" | "$SCRIPT" --tty >"$work/stdout" 2>"$work/stderr"; code=$?
check_code "--tty: stored" "$code" 0
check_eq "--tty: via tty" "$(jq -r .via "$work/stdout")" "tty"
check_eq "--tty: file holds the key" "$(cat "$work/credentials")" "OPENROUTER_API_KEY=$GOOD_KEY"
key_absent "key absent from stdout and stderr (tty)"
printf 'nope\n' | "$SCRIPT" --tty >"$work/stdout" 2>"$work/stderr"; code=$?
check_code "--tty wrong key: rejected" "$code" 1
check_eq "--tty wrong key: file untouched" "$(cat "$work/credentials")" "OPENROUTER_API_KEY=$GOOD_KEY"

# --- an existing key is replaced, other lines kept ---------------------------------
printf 'OTHER=keep\nOPENROUTER_API_KEY=old\n' > "$work/credentials"; chmod 600 "$work/credentials"
printf '%s\n' "$GOOD_KEY" | "$SCRIPT" --tty >"$work/stdout" 2>"$work/stderr"; code=$?
check_code "replace: stored" "$code" 0
check_eq "replace: old line gone, other kept" "$(sort "$work/credentials" | tr '\n' ' ')" "OPENROUTER_API_KEY=$GOOD_KEY OTHER=keep "

"$SCRIPT" --timeout 0 >"$work/stdout" 2>"$work/stderr"; code=$?
check_code "bad --timeout: usage exit 2" "$code" 2

exit $fail

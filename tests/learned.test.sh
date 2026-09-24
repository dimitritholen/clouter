#!/usr/bin/env bash
# Tests for skills/visual/learned.py: round trip, age cut-off, corrupt and
# unwritable files. Every case points CLOUTER_LEARNED at a temp file, so
# the real ~/.config/clouter/learned.json is never touched. Needs python3
# and jq; no key, no network.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export CLOUTER_LEARNED="$work/learned.json"

check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }

py() {
    # py <python statements> -> stdout; learned is importable as `learned`
    python3 -c "
import sys, json
sys.path.insert(0, '$ROOT/skills/visual')
import learned
$1
" 2>"$work/stderr"
}

# --- round trip ---
py 'learned.record_reject("acme/tts", "response_format", "mp3"); learned.record_prefer("acme/tts", "response_format", "pcm")'
check_eq "round trip: preferred value read back" "$(py 'print(learned.preferred("acme/tts", "response_format"))')" "pcm"
check_eq "round trip: rejected value decoded" "$(py 'print(list(learned.rejected("acme/tts", "response_format")))')" "['mp3']"
check_eq "round trip: rejected keeps its seen date" "$(py 'print(list(learned.rejected("acme/tts", "response_format").values())[0][:10])')" "$(date -u +%Y-%m-%d)"
check_eq "round trip: file shape" "$(jq -c '."acme/tts" | [.prefer.response_format.value, (.rejected.response_format | keys)]' "$CLOUTER_LEARNED")" '["pcm",["\"mp3\""]]'
check_eq "round trip: file mode 0600" "$(stat -c %a "$CLOUTER_LEARNED" 2>/dev/null || stat -f %Lp "$CLOUTER_LEARNED")" "600"
check_eq "round trip: unknown model reads None" "$(py 'print(learned.preferred("no/model", "response_format"))')" "None"
py 'learned.record_prefer("acme/int", "duration", 8)'
check_eq "round trip: non-string value survives" "$(py 'print(repr(learned.preferred("acme/int", "duration")))')" "8"

# --- directory is created 0700 ---
CLOUTER_LEARNED="$work/newdir/learned.json" py 'learned.record_prefer("acme/x", "endpoint", "images")'
check_eq "new directory created with mode 0700" "$(stat -c %a "$work/newdir" 2>/dev/null || stat -f %Lp "$work/newdir")" "700"

# --- 31-day-old entries ignored ---
old="$(date -u -d '31 days ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"acme/old": {"prefer": {"response_format": {"value": "pcm", "seen": "%s"}}, "rejected": {"response_format": {"\\"mp3\\"": "%s"}}}}\n' "$old" "$old" > "$CLOUTER_LEARNED"
check_eq "31 days old: preferred ignored" "$(py 'print(learned.preferred("acme/old", "response_format"))')" "None"
check_eq "31 days old: rejected ignored" "$(py 'print(learned.rejected("acme/old", "response_format"))')" "{}"
py 'learned.record_prefer("acme/new", "endpoint", "images")'
check_eq "31 days old: pruned on the next write" "$(jq -c 'keys' "$CLOUTER_LEARNED")" '["acme/new"]'

# --- corrupt file reads empty, never raises ---
printf 'not json {{{' > "$CLOUTER_LEARNED"
check_eq "corrupt file: preferred reads None" "$(py 'print(learned.preferred("acme/tts", "response_format"))')" "None"
check_eq "corrupt file: rejected reads empty" "$(py 'print(learned.rejected("acme/tts", "response_format"))')" "{}"
check_eq "corrupt file: no stderr" "$(wc -c < "$work/stderr" | tr -d ' ')" "0"
printf '[1, 2]' > "$CLOUTER_LEARNED"
check_eq "non-object JSON: reads None" "$(py 'print(learned.preferred("acme/tts", "response_format"))')" "None"

# --- unwritable path warns once, never raises ---
: > "$work/a-file"
out="$(CLOUTER_LEARNED="$work/a-file/learned.json" py 'learned.record_reject("acme/tts", "response_format", "mp3"); print("still running")')"
check_eq "unwritable path: does not raise" "$out" "still running"
check_eq "unwritable path: one stderr warning" "$(grep -c 'could not save what was learned' "$work/stderr")" "1"
check_eq "unwritable path: reads empty afterwards" "$(CLOUTER_LEARNED="$work/a-file/learned.json" py 'print(learned.preferred("acme/tts", "response_format"))')" "None"

exit $fail

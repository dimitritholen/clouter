#!/usr/bin/env bash
# Tests for skills/visual/preview.py: HTML contact sheet, rendered through a
# fake google-chrome on PATH. No network, no real browser.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/visual/preview.py"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

check_code() { if [ "$2" -eq "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (exit %s, want %s): %s\n' "$1" "$2" "$3" "$(cat "$work/stderr" 2>/dev/null)"; fail=1; fi; }
check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }
check_ge1() { if [ "$2" -ge 1 ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want >=1)\n' "$1" "$2"; fail=1; fi; }

TINY_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
printf '%s' "$TINY_PNG_B64" | base64 -d > "$work/one.png"
cat > "$work/one.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 32"><rect width="64" height="32"/></svg>
EOF

mkdir -p "$work/bin-ok"
cat > "$work/bin-ok/google-chrome" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/chrome-args"
for arg in "\$@"; do
  case "\$arg" in
    --screenshot=*) printf '%s' "$TINY_PNG_B64" | base64 -d > "\${arg#--screenshot=}" ;;
  esac
done
exit 0
EOF
chmod +x "$work/bin-ok/google-chrome"

mkdir -p "$work/bin-fail"
cat > "$work/bin-fail/google-chrome" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$work/bin-fail/google-chrome"

mkdir -p "$work/bin-empty"

# A PATH with python3 (wherever it lives) but none of this machine's real
# browsers, so "no browser" and "failing browser" below are not accidentally
# answered by a real google-chrome sitting on the normal PATH.
py_dir="$(dirname "$(command -v python3)")"

# --- a browser is on PATH and renders ----------------------------------------
out=$(PATH="$work/bin-ok:$PATH" "$SCRIPT" "$work/one.png" "$work/one.svg" --out "$work/sheet.png" 2>"$work/stderr")
code=$?
check_code "with a working browser: exit 0" "$code" 0
check_eq "with a working browser: prints the PNG path" "$out" "$work/sheet.png"
[ -s "$work/sheet.png" ] && printf 'ok   PNG was written\n' || { printf 'FAIL PNG missing\n'; fail=1; }
[ -s "$work/sheet.html" ] && printf 'ok   HTML written next to --out\n' || { printf 'FAIL HTML missing next to --out\n'; fail=1; }
check_eq "chrome got --headless=new" "$(grep -c -- '--headless=new' "$work/chrome-args")" "1"
check_eq "chrome got --screenshot" "$(grep -c -- '--screenshot=' "$work/chrome-args")" "1"
check_eq "chrome got --window-size" "$(grep -c -- '--window-size=' "$work/chrome-args")" "1"
check_ge1 "HTML mentions #0d1117" "$(grep -c '#0d1117' "$work/sheet.html")"
check_ge1 "HTML mentions #ffffff" "$(grep -c '#ffffff' "$work/sheet.html")"
check_eq "HTML has one data URL per input (times two panes)" "$(grep -o 'data:' "$work/sheet.html" | wc -l | tr -d " ")" "4"
check_ge1 "HTML names the PNG file" "$(grep -c 'one.png' "$work/sheet.html")"
check_ge1 "HTML names the SVG file" "$(grep -c 'one.svg' "$work/sheet.html")"
check_ge1 "HTML shows the SVG's viewBox dimensions" "$(grep -c '64.*32\|64.32' "$work/sheet.html")"

# --- no browser on PATH -------------------------------------------------------
out=$(PATH="$work/bin-empty:$py_dir" "$SCRIPT" "$work/one.png" --out "$work/sheet2.png" 2>"$work/stderr")
code=$?
check_code "no browser: exit 0" "$code" 0
check_eq "no browser: prints the HTML path" "$out" "$work/sheet2.html"
[ ! -e "$work/sheet2.png" ] && printf 'ok   no browser: no PNG written\n' || { printf 'FAIL no browser wrote a PNG anyway\n'; fail=1; }

# --- a browser that fails ------------------------------------------------------
out=$(PATH="$work/bin-fail:$py_dir" "$SCRIPT" "$work/one.png" --out "$work/sheet3.png" 2>"$work/stderr")
code=$?
check_code "failing browser: exit 0" "$code" 0
check_eq "failing browser: prints the HTML path" "$out" "$work/sheet3.html"
check_ge1 "failing browser: one stderr note" "$(wc -l < "$work/stderr" | tr -d " ")"
[ ! -e "$work/sheet3.png" ] && printf 'ok   failing browser: no PNG written\n' || { printf 'FAIL failing browser wrote a PNG anyway\n'; fail=1; }

# --- missing input -------------------------------------------------------------
out=$(PATH="$work/bin-ok:$PATH" "$SCRIPT" "$work/no-such-file.png" 2>"$work/stderr")
code=$?
check_code "missing input: exit 2" "$code" 2

# --- default output location (no --out) ----------------------------------------
out=$(PATH="$work/bin-ok:$PATH" "$SCRIPT" "$work/one.png" 2>"$work/stderr")
code=$?
check_code "no --out: exit 0" "$code" 0
case "$out" in
  */clouter-preview-*/preview.png) printf 'ok   no --out: PNG lands in a clouter-preview- temp dir\n' ;;
  *) printf 'FAIL no --out: unexpected path %s\n' "$out"; fail=1 ;;
esac
[ -s "$out" ] && printf 'ok   no --out: PNG exists\n' || { printf 'FAIL no --out: PNG missing (%s)\n' "$out"; fail=1; }
rm -rf "$(dirname "$out")"

exit $fail

#!/usr/bin/env bash
# Tests for skills/visual/interview.py: slot schema, gap analysis,
# remembered preferences and the compiled prompt. CLOUTER_PREFS points at
# a temp file, so the real ~/.config/clouter/prefs.json is never touched.
# Needs python3 and jq; no key, no network (rank is covered in
# visual-route.test.sh, against its stand-in).
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/visual/interview.py"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export CLOUTER_PREFS="$work/prefs.json"
project="$work/project"
mkdir -p "$project"

check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }
brief() { printf '%s' "$1" > "$work/brief.json"; }
gaps() { python3 "$SCRIPT" gaps --brief "$work/brief.json" --project "$project" "$@" 2>"$work/stderr"; }
compile() { python3 "$SCRIPT" compile --brief "$work/brief.json" --out "$work/prompt.txt" --project "$project" "$@" 2>"$work/stderr"; }

# --- slots ---
check_eq "slots: raster has background and quality" "$(python3 "$SCRIPT" slots raster_image | jq -r '[.[].name] | map(select(. == "background" or . == "quality")) | join(",")')" "background,quality"
check_eq "slots: every header fits AskUserQuestion's 12 characters" "$(for m in raster_image vector_svg video speech; do python3 "$SCRIPT" slots $m; done | jq -s '[.[][] | select((.header | length) > 12)] | length')" "0"
check_eq "slots: speech script is required" "$(python3 "$SCRIPT" slots speech | jq -r '.[] | select(.name == "script") | .required')" "true"

# --- gaps: a bare request asks, required and model-changing slots first, capped at 4 ---
brief '{"modality": "raster_image", "slots": {}}'
out="$(gaps)"
check_eq "bare request: four questions" "$(printf '%s' "$out" | jq '.ask | length')" "4"
check_eq "bare request: subject, then text and background (they change the model)" "$(printf '%s' "$out" | jq -r '[.ask[:3][].slot] | join(",")')" "subject,text,background"
check_eq "bare request: rerank_if_answered names the model-changing slots" "$(printf '%s' "$out" | jq -r '.rerank_if_answered | join(",")')" "text,background"
check_eq "--max 2 caps the questions" "$(gaps --max 2 | jq '.ask | length')" "2"

# --- gaps: a detailed request with safe guesses asks nothing ---
brief '{"modality": "raster_image", "slots": {
  "subject": "a fox reading a book under a lamp", "use": "GitHub README header",
  "palette": {"value": "#0d1117 and #58a6ff", "source": "given"},
  "text": {"value": "none", "source": "inferred"},
  "style": {"value": "flat illustration", "source": "inferred"},
  "background": {"value": "transparent", "source": "given"}}}'
check_eq "detailed request: no questions" "$(gaps | jq '.ask | length')" "0"

# --- gaps: a risky inferred value is confirmed, with the guess attached ---
brief '{"modality": "vector_svg", "slots": {
  "subject": "a pen nib", "use": "logo", "style": "line art",
  "palette": {"value": "#58a6ff", "source": "inferred"},
  "text": {"value": "clouter", "source": "inferred"}}}'
out="$(gaps)"
check_eq "risky inferred: text and palette confirmed" "$(printf '%s' "$out" | jq -r '[.ask[].slot] | sort | join(",")')" "palette,text"
check_eq "risky inferred: the guess travels along" "$(printf '%s' "$out" | jq -r '.ask[] | select(.slot == "text") | .inferred')" "clouter"

# --- errors ---
brief '{"modality": "raster_image", "slots": {"colour": "red"}}'
gaps >/dev/null; code=$?
check_eq "unknown slot: exit 2" "$code" "2"
check_eq "unknown slot: named on stderr" "$(grep -c "unknown slot 'colour'" "$work/stderr")" "1"
brief '{"modality": "hologram"}'
gaps >/dev/null; code=$?
check_eq "unknown modality: exit 2" "$code" "2"
brief '{"modality": "speech", "slots": {"voice": "calm"}}'
compile >/dev/null; code=$?
check_eq "compile without a script: exit 2" "$code" "2"
check_eq "compile without a script: no prompt file" "$([ -e "$work/prompt.txt" ] && echo yes || echo no)" "no"

# --- compile: picture ---
brief '{"modality": "raster_image", "slots": {
  "subject": "a fox reading a book", "style": "flat illustration", "palette": "#0d1117 and #58a6ff",
  "background": {"value": "Transparent", "source": "answered"}, "text": "Clouter",
  "aspect": "16:9", "quality": "High resolution", "use": "GitHub README header"}}'
out="$(compile --remember)"
check_eq "compile: prompt starts with the subject" "$(head -n 1 "$work/prompt.txt")" "a fox reading a book."
check_eq "compile: exact text quoted" "$(grep -c 'reads exactly "Clouter"' "$work/prompt.txt")" "1"
check_eq "compile: transparent background gives --transparent and the aspect" "$(printf '%s' "$out" | jq -r '.flags | join(" ")')" "--transparent --aspect 16:9"
check_eq "compile: quality becomes a spec hint" "$(printf '%s' "$out" | jq -r '.spec_hints["resolution/size"]')" "High resolution"
check_eq "compile --remember: palette and style stored" "$(printf '%s' "$out" | jq -r '.stored | sort | join(",")')" "palette,style"
check_eq "prefs file mode 0600" "$(stat -c %a "$CLOUTER_PREFS" 2>/dev/null || stat -f %Lp "$CLOUTER_PREFS")" "600"

brief '{"modality": "raster_image", "slots": {"subject": "a cat", "text": "none"}}'
compile >/dev/null
check_eq "compile: text none leaves no text line" "$(grep -c 'reads exactly' "$work/prompt.txt")" "0"

# --- remembered: next request in the same project asks less ---
brief '{"modality": "raster_image", "slots": {"subject": "an owl"}}'
out="$(gaps)"
check_eq "remembered: palette and style filled" "$(printf '%s' "$out" | jq -r '.remembered | keys | join(",")')" "palette,style"
check_eq "remembered: palette not asked" "$(printf '%s' "$out" | jq '[.ask[] | select(.slot == "palette")] | length')" "0"
check_eq "remembered: palette shared with vector" "$(printf '{"modality": "vector_svg", "slots": {"subject": "owl"}}' > "$work/brief.json"; gaps | jq -r '.remembered | keys | join(",")')" "palette"
mkdir -p "$work/other"
check_eq "remembered: other project starts empty" "$(python3 "$SCRIPT" gaps --brief "$work/brief.json" --project "$work/other" | jq -c '.remembered')" "{}"
brief '{"modality": "raster_image", "slots": {"subject": "a cat", "palette": {"value": "red", "source": "inferred"}}}'
compile --remember >/dev/null
check_eq "remember: an inferred value is not stored" "$(jq -r --arg p "$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$project")" '.[$p].palette.value' "$CLOUTER_PREFS")" "#0d1117 and #58a6ff"

# --- compile: video and speech ---
brief '{"modality": "video", "slots": {"subject": "a paper boat", "action": "drifts down a gutter",
  "camera": "slow push in", "duration": "6 seconds", "audio": "no sound"}}'
out="$(compile)"
check_eq "video: shot lines, colours from the remembered palette" "$(cut -d: -f1 "$work/prompt.txt" | tr "\\n" ";")" "Subject;Action;Camera;Colours;"
check_eq "video: duration flag" "$(printf '%s' "$out" | jq -r '.flags | join(" ")')" "--duration 6"
check_eq "video: no sound means generate_audio false" "$(printf '%s' "$out" | jq -r '.spec_hints.generate_audio')" "false"

brief '{"modality": "speech", "slots": {"script": "Welcome to clouter.", "voice": "calm male",
  "tone": "friendly", "pronunciation": "clouter rhymes with router"}}'
out="$(compile)"
check_eq "speech: prompt is the script alone" "$(cat "$work/prompt.txt")" "Welcome to clouter."
check_eq "speech: direction goes to instructions" "$(printf '%s' "$out" | jq -r '.spec_hints.instructions')" "Tone: friendly; Pronunciation: clouter rhymes with router"
check_eq "speech: no generate.py flags" "$(printf '%s' "$out" | jq -c '.flags')" "[]"

# --- unwritable prefs: warns, still compiles ---
: > "$work/a-file"
brief '{"modality": "raster_image", "slots": {"subject": "a cat", "style": "photo"}}'
CLOUTER_PREFS="$work/a-file/prefs.json" python3 "$SCRIPT" compile --brief "$work/brief.json" --out "$work/prompt.txt" --project "$project" --remember >/dev/null 2>"$work/stderr"; code=$?
check_eq "unwritable prefs: exit 0" "$code" "0"
check_eq "unwritable prefs: one warning" "$(grep -c 'could not save the remembered preferences' "$work/stderr")" "1"

exit $fail

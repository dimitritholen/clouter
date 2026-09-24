#!/usr/bin/env python3
"""Fetch and parse an OpenRouter model's request spec from its llms.txt.

    from skills.visual import spec   # or import spec next to it
    spec.load("google/veo-3.1")

Every model page at https://openrouter.ai/<model-id> publishes a
llms.txt companion (https://openrouter.ai/<model-id>/llms.txt) with one
"### Request fields (<model-id>)" bullet list per endpoint it serves
(chat/completions, /api/v1/images, /api/v1/videos or
/api/v1/audio/speech; an image-capable chat model such as
google/gemini-3.1-flash-lite-image publishes two). Each bullet reads

    field: TYPE (required|optional) — description

with TYPE one of string, boolean, integer, integer N-M, array, array of
up to N <things>, a `|`-separated list of quoted enum values, or a
`|`-separated list of bare integers (an integer enum, e.g. "4 | 6 | 8");
a field
can also skip the type entirely ("field: optional — description", seen
on chat/completions' passthrough parameters) or read only "optional"/
"required" once, never both. No field is ever dropped, typed or not.

load(model_id) fetches and parses in one call, returning:

    {"model": model_id, "source": <url fetched>,
     "endpoints": [{"method": "POST", "path": "/api/v1/images",
                    "fields": {"aspect_ratio": {"type": "string",
                               "required": False, "enum": ["1:1", ...],
                               "min": None, "max": None, "default": None,
                               "description": "aspect ratio of the ..."},
                               ...}},
                   ...]}

description is the field's first clause (the doc never ends one in a
period; a `;` before a nested aside such as frame_images' frame_type
enum is the natural cut, so that's what's kept short). default is only
set when the description says "defaults to X"; every other field key is
always present, null where it doesn't apply. Stdlib only.
OPENROUTER_BASE_URL redirects both the model-scoped llms.txt host and,
for tests, points at a stand-in server.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

REQUEST_FIELDS_RE = re.compile(r"### Request fields[^\n]*\n\n((?:- .+\n?)+)")
ENDPOINT_RE = re.compile(r"^(GET|POST|PUT|PATCH|DELETE) (https://\S+)$", re.MULTILINE)
FIELD_LINE_RE = re.compile(r"^- ([a-zA-Z_][a-zA-Z0-9_]*): (.*)$")
DEFAULT_RE = re.compile(r"defaults?\s+to\s+([^,.;]+)", re.IGNORECASE)
STATE_RE = re.compile(r"\(([^)]*)\)\s*$")
RANGE_RE = re.compile(r"(-?\d+)\s*-\s*(-?\d+)")
UP_TO_RE = re.compile(r"up to (\d+)")


class SpecError(Exception):
    pass


def _user_agent():
    """clouter/<plugin version> (+repo URL): openrouter.ai's WAF 403s the
    default Python-urllib/x.y User-Agent, but is fine with an honest,
    identifiable one (verified live 2026-09-24: 200, no curl impersonation
    needed)."""
    try:
        with open(os.path.join(ROOT, ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
            version = json.load(f).get("version", "0")
    except (OSError, ValueError):
        version = "0"
    return f"clouter/{version} (+https://github.com/dimitritholen/clouter)"


def fetch(model_id, timeout=10.0):
    """The raw llms.txt text for model_id. Raises SpecError."""
    base = (os.environ.get("OPENROUTER_BASE_URL") or "https://openrouter.ai").rstrip("/")
    url = f"{base}/{model_id}/llms.txt"
    request = urllib.request.Request(url, headers={"Accept": "text/plain", "User-Agent": _user_agent()})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read().decode("utf-8"), url
    except urllib.error.HTTPError as e:
        raise SpecError(f"GET {url} answered {e.code}") from e
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise SpecError(f"GET {url} failed: {e}") from e


def _range(type_str):
    m = RANGE_RE.search(type_str)
    if m:
        return int(m.group(1)), int(m.group(2))
    m = UP_TO_RE.search(type_str)
    if m:
        return None, int(m.group(1))
    return None, None


def _type_and_range(type_str):
    """(type, enum, min, max) from a bullet's TYPE segment (before the
    trailing "(required|optional)")."""
    type_str = type_str.strip()
    if type_str.startswith('"'):
        enum = [v.strip().strip('"') for v in type_str.split("|")]
        return "string", enum, None, None
    if re.fullmatch(r"-?\d+(\s*\|\s*-?\d+)+", type_str):  # e.g. "4 | 6 | 8"
        return "integer", [int(v) for v in type_str.split("|")], None, None
    if type_str.startswith("integer"):
        lo, hi = _range(type_str)
        return "integer", None, lo, hi
    if type_str.startswith("array"):
        lo, hi = _range(type_str)
        return "array", None, lo, hi
    if type_str in ("string", "boolean"):
        return type_str, None, None, None
    if type_str == "":
        return None, None, None, None
    return type_str, None, None, None  # unknown/odd: keep it, never drop


def _required(state):
    state_lower = (state or "").strip().lower()
    return state_lower == "required"


def _field(spec_text, description):
    """One field dict from its TYPE-and-state segment and its
    description (the text after the em dash)."""
    m = STATE_RE.search(spec_text)
    if m:
        state = m.group(1).strip()
        type_str = spec_text[: m.start()].strip()
    elif spec_text.strip().lower() in ("optional", "required"):
        state, type_str = spec_text.strip(), ""
    else:
        state, type_str = "", spec_text.strip()

    default = None
    m = DEFAULT_RE.search(description)
    if m:
        default = m.group(1).strip().strip("`\"'")

    state_lower = state.lower()
    if "required" in state_lower and "optional" in state_lower:
        # e.g. "optional when frame_images is set, otherwise required":
        # not unconditionally required; keep the condition, don't drop it.
        description = f"{state}; {description}".strip()

    type_, enum, lo, hi = _type_and_range(type_str)
    return {
        "type": type_,
        "required": _required(state),
        "enum": enum,
        "min": lo,
        "max": hi,
        "default": default,
        "description": description.split(";")[0].strip(),
    }


def _endpoint_fields(block):
    fields = {}
    for line in block.splitlines():
        m = FIELD_LINE_RE.match(line)
        if not m:
            continue  # never happens with a well-formed bullet list, but don't crash on one that isn't
        name, rest = m.group(1), m.group(2)
        spec_text, _, description = rest.partition(" — ")
        fields[name] = _field(spec_text, description.strip())
    return fields


def parse(text, model_id):
    """text -> the JSON-shaped dict described in the module docstring.
    Raises ValueError when no "### Request fields" section is found."""
    field_blocks = REQUEST_FIELDS_RE.findall(text)
    if not field_blocks:
        raise ValueError(f"no Request fields section found for {model_id}")
    endpoint_matches = list(ENDPOINT_RE.finditer(text))
    endpoints = []
    for i, block in enumerate(field_blocks):
        if i < len(endpoint_matches):
            method, url = endpoint_matches[i].group(1), endpoint_matches[i].group(2)
            path = re.sub(r"^https://[^/]+", "", url)
        else:
            method, path = None, None  # a Request fields section without its own endpoint line: keep it, don't drop it
        endpoints.append({"method": method, "path": path, "fields": _endpoint_fields(block)})
    return {"model": model_id, "source": None, "endpoints": endpoints}


def load(model_id, timeout=10.0):
    """fetch(model_id) then parse(...). Raises SpecError or ValueError."""
    text, url = fetch(model_id, timeout)
    result = parse(text, model_id)
    result["source"] = url
    return result


def main(argv):
    """`spec.py <model-id>` prints the parsed spec as JSON."""
    if len(argv) != 2:
        print("usage: spec.py <model-id>", file=sys.stderr)
        return 2
    try:
        result = load(argv[1])
    except (SpecError, ValueError) as e:
        print(f"spec: {e}", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout, indent=1)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

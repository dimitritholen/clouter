#!/usr/bin/env python3
"""Make an image, SVG, video or speech file through OpenRouter.

    generate.py --model <id> --modality raster_image|vector_svg|video|speech
                (--prompt <text> | --prompt-file <path>) [--out <path>]
                [--aspect 16:9] [--duration 8] [--voice alloy] [--transparent]
                [--reference <file>] [--preview]
                [--request <text> | --request-file <path>]

--prompt-file reads the prompt from a UTF-8 file instead of the command
line (trailing whitespace stripped), for a prompt too long or too full
of quoting to pass on the shell; exactly one of --prompt/--prompt-file
is required.

Raster and vector go through POST /api/v1/chat/completions with
modalities ["image"]; the first message.images entry is a data
URL whose media type names the extension (image/svg+xml gives .svg).
Video posts /api/v1/videos, polls the job every few seconds until it is
completed or failed, then downloads the first content URL. Speech posts
/api/v1/audio/speech (mp3) and writes the bytes; the voice is --voice,
else the model's first supported voice from the model list.

--transparent (raster only) posts background: "transparent" and
output_format: "png" to /api/v1/images, for models verified to give a
real alpha channel there (2026-09-22: openai/gpt-5-image-mini, a real
RGBA PNG). catalogue.has_alpha decides which models qualify; a model
without native alpha is refused before any request is sent, since a
diffusion model such as FLUX.2 Klein, Krea or Muse would only spend
credit on a fake checkerboard.

--reference <file> (raster or vector) sends an existing PNG, JPEG, WebP
or SVG (sniffed by extension or magic bytes) as a data URL alongside the
prompt, so the model edits or varies that image instead of starting from
nothing. On chat/completions it is a second image_url content part next
to the text part in the user message; on /api/v1/images (--transparent,
--endpoint images, or the auto fallback) it goes in the body's "image"
list, the way OpenRouter's images endpoint takes an edit source
(unverified against a live edit call: chat/completions is the one this
was tested against). A file over 20 MB, or missing/unreadable, is
refused before any request; catalogue.reference_supported is the one
source of truth for whether the model takes an image at all, and a
model it marks unsupported is refused the same way, before any spend.

An SVG output has the metadata Recraft embeds (a ~18 KB C2PA <metadata>
block), the root width/height, preserveAspectRatio="none" and
style="display: block;" stripped before it is written; the viewBox stays
(synthesized from width/height first if the root had none). Nothing else
in the SVG is touched.

--trim (raster PNG only) crops fully-transparent margins with
--trim-margin N pixels (default 32) left around the remaining content,
clamped to the image; a no-op with a stderr note for any other format.

--preview calls preview.py's make_preview() in-process on the written
file once it is on disk, and adds its result path ("preview" in the
stdout JSON) — the contact-sheet PNG when a headless browser rendered
one, else the HTML. Never fails generate.py: the paid file already
exists, so any exception is a stderr note only. With critique still
enabled, --preview previews the critique's final file instead.

Every raster or vector generation (not video, not speech) is followed by
a critique.py pass in-process: the written file is judged against the
prompt and, if it fails, fixed for up to --rounds tries (default 2,
--critic overrides the critic model). --request/--request-file (mutually
exclusive, never sent to the generator) pass the user's own verbatim
message through to critique.run(), so the critic sees it alongside the
generator prompt and weighs it higher where the two differ. --trim runs
before the critique, so the critic sees the trimmed file; a fix-round
output is not trimmed.
The stdout JSON gains a "critique" key (critique.run()'s result) and a
top-level "final" (the critique's final path); "path" and "cost" stay
the original generation's, so "cost" plus "critique.cost" is the total
spend. Opt out with --no-critique or CLOUTER_CRITIQUE=0. A critique
failure (no key, API error, ...) never fails the command: it is a
stderr note and a {"error": "..."} under "critique".

The file goes to --out, else assets/<slug of the prompt>.<ext> under the
current directory, never overwriting (a -2, -3 suffix instead). Stdout
is one JSON line: path, model, modality, media_type, cost (USD from the
API's usage, or null when it reports none). Exit: 0 written, 2 usage
(including --transparent on a non-raster modality, --reference on video
or speech, a --reference file over 20 MB, missing or unreadable), 3 no
key, 4 API failure, 5 the video job failed, 6 the model is unusable for
this account (upstream said why), 7 --transparent on a model with no
native alpha channel, 8 --reference on a model catalogue.reference_supported
marks as not taking an image input. OPENROUTER_BASE_URL redirects the API;
CLOUTER_POLL_SECONDS sets the poll interval (5).

Every successful generation appends one JSON line to a cost log:
{"ts", "model", "modality", "path" (absolute), "cost"}. The log path is
CLOUTER_VISUAL_LOG, else visual.jsonl next to the credentials file
(lib/keys.path()'s directory). A logging failure is a stderr note only,
the generation's exit code is never affected by it.

    generate.py --cost [--since 24h|7d|30m|<ISO date>]

prints the total spend and call count from that log (all time without
--since), e.g. `$0.2210 over 6 calls since 2026-09-22T02:00Z`, plus one
JSON line on stdout: {"total", "calls", "since"}. Calls with no known
cost are counted and reported as "N without a price". --cost needs
neither --model/--modality/--prompt nor a key or network; every other
flag above requires --model, --modality and one of --prompt/--prompt-file.
Stdlib only.
"""

import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, HERE)
from lib import keys, png  # noqa: E402
import catalogue  # noqa: E402
import preview  # noqa: E402
import spec  # noqa: E402

MODALITIES = ("raster_image", "vector_svg", "video", "speech")
EXTENSIONS = {
    "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif",
    "image/svg+xml": "svg", "image/avif": "avif",
    "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov",
    "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/wav": "wav", "audio/x-wav": "wav",
    "audio/ogg": "ogg", "audio/pcm": "pcm",
}
HTTP_TIMEOUT = 120.0
VIDEO_WAIT = 900.0
MAX_REFERENCE_BYTES = 20 * 1024 * 1024
REFERENCE_EXTENSIONS = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".webp": "image/webp", ".svg": "image/svg+xml",
}
# fields generate.py itself always sends on that endpoint, so a spec's
# "required" on one of these is never a missing-field error.
ALWAYS_SUPPLIED = {
    "/api/v1/images": {"model", "prompt"},
    "/api/v1/chat/completions": {"model", "messages"},
    "/api/v1/videos": {"model", "prompt"},
    "/api/v1/audio/speech": {"model", "input"},
}


class ApiError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


class JobFailed(Exception):
    pass


class ModelUnusable(Exception):
    """Upstream refused with 403: the account cannot use this model."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def base_url():
    return (os.environ.get("OPENROUTER_BASE_URL") or "https://openrouter.ai").rstrip("/")


def request(method, url, key, body=None, accept="application/json"):
    """One HTTP call. Returns (headers, raw bytes). Raises ApiError."""
    if url.startswith("/"):
        url = base_url() + url
    headers = {"Authorization": f"Bearer {key}", "Accept": accept}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as response:
            return response.headers, response.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        try:
            message = json.loads(detail).get("error", {}).get("message") or detail
        except (ValueError, AttributeError):
            message = detail
        if e.code == 403:
            raise ModelUnusable(e.code, str(message)) from e
        raise ApiError(f"{method} {url.replace(base_url(), '')} answered {e.code}: "
                       f"{str(message)[:300]}", status=e.code) from e
    except (urllib.error.URLError, OSError) as e:
        raise ApiError(f"{method} {url.replace(base_url(), '')} failed: {e}") from e


def request_json(method, url, key, body=None):
    headers, raw = request(method, url, key, body)
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        raise ApiError(f"{method} {url} answered with something that is not JSON") from e


def media_ext(media_type, fallback):
    media_type = (media_type or "").split(";")[0].strip().lower()
    return EXTENSIONS.get(media_type, fallback), media_type or None


def read_text_arg(path, parser, flag):
    """Read a UTF-8 file for a `--<flag>-file` argument, rstripped, erroring
    through `parser.error` (same message and exit code as the inline reads
    it replaces) on a missing or unreadable file."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().rstrip()
    except OSError as e:
        parser.error(f"cannot read --{flag} {path}: {e}")


def cost_of(usage):
    if isinstance(usage, dict) and isinstance(usage.get("cost"), (int, float)):
        return float(usage["cost"])
    return None


def sniff_media_type(path, data):
    """PNG/JPEG/WebP by magic bytes; SVG by a leading '<' plus the
    extension, since a text format has no magic bytes of its own. Falls
    back to the extension when the bytes don't match a known signature."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data.lstrip()[:1] == b"<" and (b"<svg" in data[:1024] or path.lower().endswith(".svg")):
        return "image/svg+xml"
    return REFERENCE_EXTENSIONS.get(os.path.splitext(path)[1].lower())


def svg_add_dimensions(raw):
    """Recraft's own SVG output (and so, in a critique fix round, our
    --reference back to it) carries a viewBox but no width/height on the
    root <svg>, which OpenRouter's validator then rejects as
    'cannot determine SVG dimensions'. Fill in whichever of width/height
    is missing from the viewBox's 3rd/4th numbers, on the opening <svg>
    tag only -- this is for the copy we send as a reference, never for
    the file on disk."""
    match = re.search(rb"<svg\b[^>]*>", raw)
    if not match:
        return raw
    tag = match.group(0)
    # a lookbehind for whitespace, not \b: "-" is a non-word character, so
    # \b still sits right before "width" in stroke-width= or data-width=.
    has_width = re.search(rb"(?<=\s)width\s*=", tag)
    has_height = re.search(rb"(?<=\s)height\s*=", tag)
    if has_width and has_height:
        return raw
    view_box = re.search(
        rb'viewBox\s*=\s*["\']\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)', tag)
    if not view_box:
        return raw
    width, height = view_box.group(1), view_box.group(2)
    addition = b""
    if not has_width:
        addition += b' width="%s"' % width
    if not has_height:
        addition += b' height="%s"' % height
    new_tag = tag[:4] + addition + tag[4:]  # "<svg" + attrs + the rest
    return raw[:match.start()] + new_tag + raw[match.end():]


def load_reference(path):
    """Read a --reference file: PNG, JPEG, WebP or SVG by extension or
    magic bytes, refused over MAX_REFERENCE_BYTES before any request.
    Returns a data: URL. Raises ValueError, meant for exit 2."""
    try:
        if os.path.getsize(path) > MAX_REFERENCE_BYTES:
            raise ValueError(f"{path} is over the {MAX_REFERENCE_BYTES // (1024 * 1024)} MB --reference limit")
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        raise ValueError(f"cannot read --reference {path}: {e}") from e
    media_type = sniff_media_type(path, raw)
    if not media_type:
        raise ValueError(f"--reference {path} is not a PNG, JPEG, WebP or SVG I can recognise")
    if media_type == "image/svg+xml":
        raw = svg_add_dimensions(raw)
    return f"data:{media_type};base64,{base64.b64encode(raw).decode()}"


# --- per-model request spec: --param validation, before any paid request --------

def target_endpoint_path(modality, endpoint, transparent):
    """The API path generate.py is about to call, so the matching section
    of the model's request spec can be picked (spec.py's endpoints are
    keyed by path)."""
    if modality == "video":
        return "/api/v1/videos"
    if modality == "speech":
        return "/api/v1/audio/speech"
    if transparent or endpoint == "images":
        return "/api/v1/images"
    return "/api/v1/chat/completions"  # endpoint auto/chat: make_image tries chat first


def load_spec(model):
    """spec.load(model), or None with a stderr warning on any failure.
    The spec must never block a generation (spec.py's docstring)."""
    try:
        return spec.load(model)
    except (spec.SpecError, ValueError) as e:
        print(f"clouter visual: no request spec for {model} ({e}); sending the generic request",
              file=sys.stderr)
        return None


def endpoint_fields(spec_result, path):
    """The fields dict of spec_result's endpoint matching path, or None
    when the spec didn't load or has no section for that path."""
    if spec_result is None:
        return None
    for endpoint in spec_result["endpoints"]:
        if endpoint["path"] == path:
            return endpoint["fields"]
    return None


def coerce_param(raw, field_type):
    """A --param's raw string value, coerced by the spec field's type.
    Raises ValueError or json.JSONDecodeError on a bad value."""
    if field_type == "integer":
        return int(raw)
    if field_type == "number":
        return float(raw)
    if field_type == "boolean":
        low = raw.strip().lower()
        if low in ("true", "false"):
            return low == "true"
        raise ValueError(f"boolean must be true or false, got {raw!r}")
    if field_type in ("array", "object"):
        return json.loads(raw)
    return raw  # string, or a typeless passthrough field (chat/completions' extras)


def validate_value(name, value, field):
    """enum/min/max errors for one already-coerced field value, as
    stderr-ready strings naming the allowed values."""
    errors = []
    if field["enum"] is not None and value not in field["enum"]:
        allowed = ", ".join(str(v) for v in field["enum"])
        errors.append(f"{name} must be one of: {allowed} (got {value!r})")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if field["min"] is not None and value < field["min"]:
            errors.append(f"{name} must be >= {field['min']} (got {value})")
        if field["max"] is not None and value > field["max"]:
            errors.append(f"{name} must be <= {field['max']} (got {value})")
    return errors


# fields --param must not touch: sent automatically (always_supplied) or
# owned by another flag, which would otherwise silently win or collide.
PARAM_OWNED_BY_FLAG = {
    "aspect_ratio": "--aspect", "duration": "--duration", "voice": "--voice",
    "background": "--transparent", "output_format": "--transparent",
}


def build_params(param_args, fields, derived, always_supplied):
    """--param key=value entries (repeatable) plus the values generate.py
    itself derives from --aspect/--duration/--voice/--transparent, checked
    against fields (the spec endpoint's field dict, or None when the spec
    didn't load -- then nothing is checked, per spec.py's contract that a
    missing spec never blocks a generation). Returns (extra, errors):
    extra is the --param fields, coerced and ready to merge top-level into
    the request body; errors is one line per bad or missing field, and a
    non-empty errors means extra must not be sent."""
    errors = []
    extra = {}
    for item in param_args:
        if "=" not in item:
            errors.append(f"--param must be key=value, got {item!r}")
            continue
        key, raw = item.split("=", 1)
        if key in always_supplied:
            errors.append(f"--param {key} is sent automatically by generate.py; it cannot be overridden")
            continue
        if key in PARAM_OWNED_BY_FLAG:
            errors.append(f"--param {key} is set by {PARAM_OWNED_BY_FLAG[key]}, not --param")
            continue
        if fields is not None:
            field = fields.get(key)
            if field is None:
                errors.append(f"unknown --param {key} (not in this model's request spec for this endpoint)")
                continue
            try:
                value = coerce_param(raw, field["type"])
            except (ValueError, json.JSONDecodeError) as e:
                errors.append(f"--param {key}: cannot read {raw!r} as {field['type']}: {e}")
                continue
            errors.extend(validate_value(key, value, field))
        else:
            try:
                value = json.loads(raw)
            except (ValueError, json.JSONDecodeError):
                value = raw
        extra[key] = value

    if fields is not None:
        for name, value in derived.items():
            field = fields.get(name)
            if field is not None:
                errors.extend(validate_value(name, value, field))
        supplied = set(extra) | set(derived) | always_supplied
        for name, field in fields.items():
            if field["required"] and name not in supplied:
                errors.append(f"missing required field {name}"
                              + (f": {field['description']}" if field["description"] else ""))
    return extra, errors


# --- the three producers: each returns (bytes, media_type, ext, cost) ---------

def make_image(model, prompt, aspect, key, endpoint, transparent=False, reference=None, params=None):
    if transparent:
        # alpha only exists on /api/v1/images; --endpoint chat/auto do not apply.
        return make_image_via_images(model, prompt, aspect, key, transparent=True, reference=reference, params=params)
    if endpoint == "images":
        return make_image_via_images(model, prompt, aspect, key, reference=reference, params=params)
    try:
        return make_image_via_chat(model, prompt, aspect, key, reference=reference, params=params)
    except ApiError as e:
        # auto falls back once: some models only exist behind /api/v1/images
        # and chat/completions says so in a 404.
        if endpoint == "auto" and e.status == 404 and "/api/v1/images" in str(e):
            return make_image_via_images(model, prompt, aspect, key, reference=reference, params=params)
        raise


def make_image_via_chat(model, prompt, aspect, key, reference=None, params=None):
    content = prompt
    if reference:
        # a reference image rides next to the text part, not instead of it.
        content = [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": reference}},
        ]
    body = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        # "image" alone: models such as Recraft vector output only images and
        # refuse a request that also asks for text.
        "modalities": ["image"],
        "usage": {"include": True},
    }
    if params:
        body.update(params)
    if aspect:
        # OpenRouter's chat/completions image convention: nested under
        # image_config. No real model spec lists aspect_ratio top-level on
        # chat/completions, so this is unconditional.
        body["image_config"] = {"aspect_ratio": aspect}
    answer = request_json("POST", "/api/v1/chat/completions", key, body)
    choices = answer.get("choices") or []
    images = (choices[0].get("message") or {}).get("images") if choices else None
    if not images:
        text = ((choices[0].get("message") or {}).get("content") if choices else "") or ""
        raise ApiError(f"{model} returned no image" + (f": {str(text)[:200]}" if text else ""))
    url = (images[0].get("image_url") or {}).get("url") or ""
    match = re.match(r"data:([^;,]+)(;base64)?,(.*)$", url, re.DOTALL)
    if match:
        media_type = match.group(1)
        payload = match.group(3)
        raw = base64.b64decode(payload) if match.group(2) else urllib.parse.unquote_to_bytes(payload)
    elif url.startswith("http"):
        headers, raw = request("GET", url, key, accept="*/*")
        media_type = headers.get("Content-Type")
    else:
        raise ApiError(f"{model} returned an image url I cannot read")
    ext, media_type = media_ext(media_type, "png")
    return raw, media_type, ext, cost_of(answer.get("usage"))


def make_image_via_images(model, prompt, aspect, key, transparent=False, reference=None, params=None):
    body = {"model": model, "prompt": prompt}
    if params:
        body.update(params)
    if aspect:
        # top-level, not nested under image_config: /api/v1/images' own
        # spec (e.g. recraft-v4-vector, gemini image's images section)
        # wants aspect_ratio as a plain request field.
        body["aspect_ratio"] = aspect
    if transparent:
        body["background"] = "transparent"
        body["output_format"] = "png"
    if reference:
        # OpenRouter's images endpoint takes an edit source as a list of
        # image data URLs under "image" (unverified against a live edit
        # call; chat/completions above is the one this was tested against).
        body["image"] = [reference]
    answer = request_json("POST", "/api/v1/images", key, body)
    data = ((answer.get("data") or [{}])[0])
    b64 = data.get("b64_json")
    if not b64:
        raise ApiError(f"{model} returned no image")
    raw = base64.b64decode(b64)
    ext, media_type = media_ext(data.get("media_type"), "png")
    return raw, media_type, ext, cost_of(answer.get("usage"))


def make_video(model, prompt, aspect, duration, key, params=None):
    body = {"model": model, "prompt": prompt}
    if params:
        body.update(params)
    if aspect:
        body["aspect_ratio"] = aspect
    if duration:
        body["duration"] = duration
    job = request_json("POST", "/api/v1/videos", key, body)
    job_id = job.get("id")
    if not job_id:
        raise ApiError("POST /api/v1/videos answered without a job id")
    poll_url = job.get("polling_url") or f"/api/v1/videos/{job_id}"
    interval = float(os.environ.get("CLOUTER_POLL_SECONDS", "5"))
    deadline = time.monotonic() + VIDEO_WAIT
    status = job.get("status")
    while status not in ("completed", "failed"):
        if time.monotonic() > deadline:
            raise ApiError(f"video job {job_id} still {status} after {int(VIDEO_WAIT)}s")
        time.sleep(interval)
        job = request_json("GET", poll_url, key)
        status = job.get("status")
    if status == "failed":
        raise JobFailed(f"video job {job_id} failed" + (f": {job['error']}" if job.get("error") else ""))
    urls = job.get("unsigned_urls") or []
    url = urls[0] if urls else f"/api/v1/videos/{job_id}/content?index=0"
    headers, raw = request("GET", url, key, accept="*/*")
    ext, media_type = media_ext(headers.get("Content-Type"), "mp4")
    return raw, media_type, ext, cost_of(job.get("usage"))


def default_voice(model, key):
    try:
        listing = request_json("GET", "/api/v1/models?output_modalities=speech", key)
    except ApiError:
        return None
    for entry in listing.get("data") or []:
        if entry.get("id") == model:
            voices = entry.get("supported_voices") or []
            return voices[0] if voices else None
    return None


def make_speech(model, prompt, voice, key, params=None):
    body = {"model": model, "input": prompt, "response_format": "mp3"}
    if params:
        body.update(params)
    voice = voice or default_voice(model, key)
    if voice:
        body["voice"] = voice
    headers, raw = request("POST", "/api/v1/audio/speech", key, body, accept="*/*")
    if not raw:
        raise ApiError(f"{model} returned no audio")
    ext, media_type = media_ext(headers.get("Content-Type"), "mp3")
    cost = None
    generation_id = headers.get("X-Generation-Id")
    if generation_id:
        for attempt in range(2):
            try:
                stats = request_json("GET", f"/api/v1/generation?id={urllib.parse.quote(generation_id)}", key)
                data = stats.get("data") or {}
                if isinstance(data.get("total_cost"), (int, float)):
                    cost = float(data["total_cost"])
                break
            except ApiError as e:
                if e.status == 404 and attempt == 0:
                    time.sleep(1)
                    continue
                break
    return raw, media_type, ext, cost


# --- SVG cleanup (Recraft adds a C2PA block, fixed width/height, ...) ------------

_ATTR = r"""\s+{name}\s*=\s*(?:"[^"]*"|'[^']*')"""


def _drop_attr(tag, name):
    return re.sub(_ATTR.format(name=name), "", tag)


def clean_svg(text):
    """Strip what Recraft adds to an SVG: the C2PA <metadata> block, the
    root width/height, preserveAspectRatio="none" and
    style="display: block;". The viewBox stays, synthesized from
    width/height first if the root had none. Nothing else is touched."""
    text = re.sub(r"<metadata\b[^>]*>.*?</metadata>\s*", "", text, flags=re.DOTALL)
    match = re.search(r"<svg\b[^>]*>", text)
    if not match:
        return text
    tag = match.group(0)

    def attr(name):
        m = re.search(_ATTR.format(name=name), tag)
        return m.group(0).split("=", 1)[1].strip(" \"'") if m else None

    if not attr("viewBox"):
        width, height = attr("width"), attr("height")
        w = re.match(r"[\d.]+", width) if width else None
        h = re.match(r"[\d.]+", height) if height else None
        if w and h:
            tag = re.sub(r"^<svg\b", f'<svg viewBox="0 0 {w.group(0)} {h.group(0)}"', tag, count=1)
    for name in ("width", "height"):
        tag = _drop_attr(tag, name)
    tag = re.sub(r"""\s+preserveAspectRatio\s*=\s*(?:"none"|'none')""", "", tag)
    tag = re.sub(r"""\s+style\s*=\s*(?:"display:\s*block;?"|'display:\s*block;?')""", "", tag)
    return text[:match.start()] + tag + text[match.end():]


# --- trim (crop transparent PNG margins, leaving a fixed margin) -----------------

def trim_png(raw, margin):
    """Crop fully-transparent margins from a PNG, leaving `margin` pixels
    of transparency around the remaining content, clamped to the image.
    Returns raw unchanged if the whole image is transparent."""
    width, height, rows = png.decode(raw)
    box = png.bbox(width, height, rows)
    if box is None:
        return raw
    x0, y0, x1, y1 = box
    x0 = max(0, x0 - margin)
    y0 = max(0, y0 - margin)
    x1 = min(width, x1 + margin)
    y1 = min(height, y1 + margin)
    cropped = [row[x0 * 4:x1 * 4] for row in rows[y0:y1]]
    return png.encode(x1 - x0, y1 - y0, cropped)


# --- where the file goes ---------------------------------------------------------

def slug(text, limit=60):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return (s[:limit].rstrip("-")) or "output"


def target_path(out, prompt, ext):
    if out:
        path = out
        if not os.path.splitext(path)[1]:
            path = f"{path}.{ext}"
    else:
        path = os.path.join("assets", f"{slug(prompt)}.{ext}")
    root, extension = os.path.splitext(path)
    candidate, n = path, 2
    while os.path.exists(candidate):
        candidate = f"{root}-{n}{extension}"
        n += 1
    return candidate


# --- cost log (--cost, and the line appended after every generation) ------------

def log_path():
    override = os.environ.get("CLOUTER_VISUAL_LOG")
    if override:
        return override
    return os.path.join(os.path.dirname(keys.path()), "visual.jsonl")


def log_generation(path, model, modality, cost):
    """Append one line to the cost log. Never raises: a logging failure is
    a stderr note, the generation the user already paid for stays exit 0."""
    try:
        file_path = log_path()
        directory = os.path.dirname(file_path)
        if directory:
            os.makedirs(directory, mode=0o700, exist_ok=True)
        entry = {
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "model": model,
            "modality": modality,
            "path": os.path.abspath(path),
            "cost": cost,
        }
        fd = os.open(file_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.chmod(file_path, 0o600)  # os.open's mode is masked by umask; pin it
            with os.fdopen(fd, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry) + "\n")
        except BaseException:
            os.close(fd)
            raise
    except Exception as e:  # noqa: BLE001 - logging must never cost the user their file
        print(f"generate: cost log skipped: {type(e).__name__}: {e}", file=sys.stderr)


def parse_since(value):
    """24h/7d/30m relative to now, or an ISO-8601 date. Raises ValueError."""
    match = re.match(r"^(\d+)([hdm])$", value)
    if match:
        amount, unit = int(match.group(1)), match.group(2)
        seconds = {"h": 3600, "d": 86400, "m": 60}[unit]
        return datetime.now(timezone.utc) - timedelta(seconds=amount * seconds)
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def cmd_cost(since):
    """--cost: total and count from the log, filtered by --since. No network."""
    since_dt = None
    if since:
        try:
            since_dt = parse_since(since)
        except ValueError:
            print(f"generate: cannot parse --since {since}", file=sys.stderr)
            return 2

    total, calls, unknown, malformed = 0.0, 0, 0, 0
    file_path = log_path()
    if os.path.isfile(file_path):
        with open(file_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    ts = datetime.fromisoformat(entry["ts"].replace("Z", "+00:00"))
                except (ValueError, KeyError, TypeError, AttributeError):
                    malformed += 1
                    continue
                if since_dt and ts < since_dt:
                    continue
                calls += 1
                cost = entry.get("cost")
                if isinstance(cost, (int, float)):
                    total += cost
                else:
                    unknown += 1
    if malformed:
        print(f"generate: skipped {malformed} malformed log line(s)", file=sys.stderr)

    since_label = since_dt.strftime("%Y-%m-%dT%H:%M:%SZ") if since_dt else None
    line = f"${total:.4f} over {calls} call{'s' if calls != 1 else ''}"
    if unknown:
        line += f" ({unknown} without a price)"
    if since_label:
        line += f" since {since_label}"
    print(line)
    print(json.dumps({"total": round(total, 4), "calls": calls, "since": since_label}))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="Make an image, SVG, video or speech file through OpenRouter.")
    parser.add_argument("--model")
    parser.add_argument("--modality", choices=MODALITIES)
    prompt_group = parser.add_mutually_exclusive_group()
    prompt_group.add_argument("--prompt", help="the prompt text")
    prompt_group.add_argument("--prompt-file", help="path to a file holding the prompt text")
    parser.add_argument("--cost", action="store_true",
                        help="print total spend and call count from the cost log, and exit")
    parser.add_argument("--since", help="with --cost: 24h, 7d, 30m, or an ISO date")
    parser.add_argument("--out", help="output path (default assets/<slug>.<ext>)")
    parser.add_argument("--aspect", help="aspect ratio such as 16:9 (image and video)")
    parser.add_argument("--duration", type=int, help="seconds (video)")
    parser.add_argument("--voice", help="voice id (speech)")
    parser.add_argument("--endpoint", choices=("auto", "chat", "images"), default="auto",
                        help="image endpoint to use (raster and vector only, default auto)")
    parser.add_argument("--transparent", action="store_true",
                        help="raster only: a real alpha channel through /api/v1/images")
    parser.add_argument("--trim", action="store_true",
                        help="PNG only: crop fully-transparent margins, keeping --trim-margin px")
    parser.add_argument("--trim-margin", type=int, default=32,
                        help="margin left around the content when --trim crops (default 32)")
    parser.add_argument("--reference", help="existing PNG/JPEG/WebP/SVG to edit or vary (raster and vector only)")
    parser.add_argument("--param", action="append", default=[], dest="params", metavar="KEY=VALUE",
                        help="extra request field for the model's spec (repeatable); "
                             "coerced and validated against the model's request spec")
    parser.add_argument("--preview", action="store_true",
                        help="also write a GitHub dark/light contact sheet through preview.py")
    parser.add_argument("--rounds", type=int, default=2,
                        help="max critique fix rounds (raster/vector only, default 2)")
    parser.add_argument("--critic", help="critique.py critic model id (default its own built-in default)")
    parser.add_argument("--no-critique", action="store_true",
                        help="skip the critique pass that otherwise always follows raster/vector generation")
    request_group = parser.add_mutually_exclusive_group()
    request_group.add_argument("--request", help="the user's original request, verbatim, "
                                "passed to the critique pass (never sent to the generator)")
    request_group.add_argument("--request-file", help="path to a file holding the user's "
                                "original request, verbatim")
    args = parser.parse_args(argv[1:])
    if args.rounds < 0:
        parser.error("--rounds must be >= 0")
    if args.cost:
        return cmd_cost(args.since)
    if not args.model:
        parser.error("--model is required")
    if not args.modality:
        parser.error("--modality is required")
    if not args.prompt and not args.prompt_file:
        parser.error("one of the arguments --prompt --prompt-file is required")
    if args.prompt_file:
        args.prompt = read_text_arg(args.prompt_file, parser, "prompt-file")
    if not args.prompt.strip():
        parser.error("--prompt must not be empty")
    if args.request_file:
        args.request = read_text_arg(args.request_file, parser, "request-file")
    if args.transparent and args.modality != "raster_image":
        parser.error("--transparent only applies to --modality raster_image")
    if args.transparent and not catalogue.has_alpha(args.model):
        print(f"generate: {args.model} has no native alpha channel; --transparent on it would "
              "only spend credit on a fake checkerboard", file=sys.stderr)
        return 7
    if args.reference and args.modality not in ("raster_image", "vector_svg"):
        parser.error("--reference only applies to --modality raster_image or vector_svg")

    reference = None
    if args.reference:
        try:
            reference = load_reference(args.reference)
        except ValueError as e:
            print(f"generate: {e}", file=sys.stderr)
            return 2
        try:
            supported = catalogue.reference_supported(args.model)
        except catalogue.CatalogueError as e:
            print(f"generate: {e}", file=sys.stderr)
            return 4
        if not supported:
            print(f"generate: {args.model} does not take a reference image "
                  "(architecture.input_modalities has no image)", file=sys.stderr)
            return 8

    # Pick the spec section for the endpoint generate.py is about to call,
    # and validate every --param plus what --aspect/--duration/--voice/
    # --transparent themselves send, before any paid request. A model with
    # no request spec (network down, 404, ...) skips validation entirely --
    # load_spec already warned on stderr, and the generic request goes out
    # exactly as before spec.py existed.
    endpoint_path = target_endpoint_path(args.modality, args.endpoint, args.transparent)
    spec_result = load_spec(args.model)
    effective_endpoint = args.endpoint
    if (args.modality in ("raster_image", "vector_svg") and not args.transparent
            and args.endpoint == "auto"
            and endpoint_fields(spec_result, "/api/v1/chat/completions") is None
            and endpoint_fields(spec_result, "/api/v1/images") is not None):
        # This model's spec only has an /api/v1/images section: auto's
        # chat/completions try would just spend a call on a guaranteed 404.
        # Target images directly, and validate against its section.
        endpoint_path = "/api/v1/images"
        effective_endpoint = "images"
    fields = endpoint_fields(spec_result, endpoint_path)

    derived = {}
    if args.aspect:
        derived["aspect_ratio"] = args.aspect
    if args.modality == "video" and args.duration:
        derived["duration"] = args.duration
    if args.modality == "speech" and args.voice:
        derived["voice"] = args.voice
    if endpoint_path == "/api/v1/images" and args.transparent:
        derived["background"] = "transparent"
        derived["output_format"] = "png"

    params, param_errors = build_params(args.params, fields, derived, ALWAYS_SUPPLIED.get(endpoint_path, set()))
    if param_errors:
        for message in param_errors:
            print(f"generate: {message}", file=sys.stderr)
        return 2

    try:
        key = keys.get("OPENROUTER_API_KEY")
    except (keys.MissingKey, keys.UnsafeFile) as e:
        print(f"generate: {e}", file=sys.stderr)
        return 3

    try:
        if args.modality in ("raster_image", "vector_svg"):
            raw, media_type, ext, cost = make_image(args.model, args.prompt, args.aspect, key,
                                                     effective_endpoint, args.transparent, reference,
                                                     params=params)
        elif args.modality == "video":
            raw, media_type, ext, cost = make_video(args.model, args.prompt, args.aspect, args.duration, key,
                                                     params=params)
        else:
            raw, media_type, ext, cost = make_speech(args.model, args.prompt, args.voice, key, params=params)
    except JobFailed as e:
        print(f"generate: {e}", file=sys.stderr)
        return 5
    except ModelUnusable as e:
        print(f"generate: {e.message}", file=sys.stderr)
        return 6
    except ApiError as e:
        print(f"generate: {e}", file=sys.stderr)
        return 4

    # Cleanup and --trim run after the paid request: a bug here must never
    # cost the user the file they already paid for, so each keeps the
    # original bytes and only notes the failure on stderr.
    if ext == "svg":
        try:
            raw = clean_svg(raw.decode("utf-8")).encode("utf-8")
        except Exception as e:  # noqa: BLE001 - a data-loss guard, must never lose the file
            print(f"generate: svg cleanup skipped: {type(e).__name__}: {e}", file=sys.stderr)
    if args.trim:
        if ext == "png":
            try:
                raw = trim_png(raw, args.trim_margin)
            except Exception as e:  # noqa: BLE001 - same guard: a truncated/odd PNG must still write
                print(f"generate: --trim skipped: {type(e).__name__}: {e}", file=sys.stderr)
        else:
            print(f"generate: --trim is a no-op for {ext}, PNG only", file=sys.stderr)

    path = target_path(args.out, args.prompt, ext)
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "wb") as f:
        f.write(raw)
    log_generation(path, args.model, args.modality, cost)

    result = {"path": path, "model": args.model, "modality": args.modality,
              "media_type": media_type, "bytes": len(raw), "cost": cost}

    critique_disabled = args.no_critique or os.environ.get("CLOUTER_CRITIQUE", "1").lower() in ("0", "off", "false")
    preview_target = [path]
    if args.modality in ("raster_image", "vector_svg") and not critique_disabled:
        try:
            # Imported lazily: critique.py imports this module, so a
            # top-level import here would be circular. Kept inside the
            # try so an import failure is also a stderr note, not a
            # non-zero exit -- the paid file is already written.
            import critique
            critique_result = critique.run(path, args.prompt, args.model, rounds=args.rounds,
                                            critic=args.critic, key=key, aspect=args.aspect,
                                            transparent=args.transparent, request=args.request,
                                            params=params, endpoint=effective_endpoint)
            result["critique"] = critique_result
            result["final"] = critique_result["final"]
            preview_target = critique_result["files"]
        except Exception as e:  # noqa: BLE001 - the paid file is already written, this must never cost it
            print(f"generate: critique skipped: {type(e).__name__}: {e}", file=sys.stderr)
            result["critique"] = {"error": f"{type(e).__name__}: {e}"}

    if args.preview:
        # The paid file is already on disk; a preview failure must never
        # take that away, so any exception here is a stderr note, not
        # a non-zero exit.
        try:
            preview_result = preview.make_preview(preview_target)
            result["preview"] = preview_result.get("png") or preview_result["html"]
        except Exception as e:  # noqa: BLE001 - same data-loss guard as svg cleanup/--trim above
            print(f"generate: --preview skipped: {type(e).__name__}: {e}", file=sys.stderr)

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

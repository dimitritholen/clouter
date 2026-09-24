#!/usr/bin/env python3
"""Judge a generated image against its prompt, then ask the generator to
fix what's wrong, for up to --rounds tries.

    critique.py <file> (--prompt <text> | --prompt-file <path>)
                --model <generator model id>
                [--rounds N] [--critic <model id>] [--aspect 16:9] [--transparent]
                [--defects-file <path>] [--tried <id,id,...>]
                [--request <text> | --request-file <path>]
    critique.py <file> (--prompt <text> | --prompt-file <path>) --suggest --out <defects.json>
                [--model <generator model id>] [--critic <model id>]
                [--request <text> | --request-file <path>]
    critique.py <file> --translate --out <instructions.json>
                [--annotation <layer.png>] [--notes-file <json>] [--text-file <path>]
                [--frames-file <json>] [--critic <model id>]
                [--request <text> | --request-file <path>]
    critique.py --models --modality <raster_image|vector_svg|video|speech>
                (--prompt <text> | --prompt-file <path>) [--request <text> | --request-file <path>]
                [--defects-file <path>] [--exclude id,id,...] --out <models.json>

<file> is the image or SVG generate.py already wrote (video and speech
files are refused: critique only judges images/svg). The critic (default
DEFAULT_CRITIC, overridable by --critic, then CLOUTER_CRITIC, then the
default) is sent the file as a data URL alongside the original prompt and
a fixed checklist, and answers strict JSON: pass, and a list of defects
each with a type, where, a normalised 0-1 bounding box or null, a 1-5
severity and an imperative fix instruction. An SVG file is rasterised to
PNG through preview.py's headless-Chrome machinery when a browser is on
PATH; without one, the SVG source goes as a text part instead, noted as
markup so the critic doesn't mistake it for prose.

--request/--request-file, when given, is the user's own message
verbatim, sent to the critic as a second, clearly labelled section
alongside the prompt: the critic judges prompt_adherence against both,
and where they differ the user's request wins, so a detail the user
asked for but Claude's generator prompt dropped still counts as a
defect. Without it, nothing changes.

pass is computed locally (no defect with severity >= 3), never trusted
from the model's own claim. While not pass and rounds used < --rounds,
the defects (severity >= 3 first) become a fix prompt appended to the
original ("Keep everything else identical. Fix these defects: ..."),
which drives one more generate.py-style image call — with the current
file as --reference when catalogue.reference_supported(--model) says the
model takes one, otherwise a plain regeneration from the fix prompt.
Each new file is written next to the original as <stem>.rN.<ext>, judged
in turn. Once a file passes, or --rounds is used up, the final file is
chosen from every judged file, the original (or its seeded result)
included: a passing file first, else the lowest score (sum of
severities; a fix can make things worse), ties going to the earliest
file. Any escalation command starts from that chosen file.

Also importable:

    from critique import run
    result = run(path, prompt, gen_model, rounds=2, critic=None,
                 key=None, aspect=None, transparent=False,
                 initial_defects=None, tried=None, request=None)

run() never calls sys.exit or print (generate.py calls it in-process);
only this file's CLI wrapper does. It returns:

    {"final": path, "pass": bool, "rounds": rounds_used,
     "files": [all paths judged, original first],
     "defects": [defects of the final file],
     "cost": total USD across every critic and generator call, or null
             when none of them reported a cost, "critic": model id,
     "escalation": {...} or absent, "escalation_error": "..." or absent}

initial_defects seeds the first judged result (skipping the first critic
call) for a run that continues an earlier critique with a new gen_model,
e.g. path already an .rN file from a prior escalation; tried lists model
ids already attempted, kept out of the next escalation's candidates.

When the final result still has pass false, run() also tries to build an
"escalation": up to 10 priced models (cheapest first, catalogue.models of
the same modality) that take a reference image, cost at least as much as
gen_model, and were not yet tried, ranked by Jev the way route.py ranks
its own choices (skills/visual/ranking.py, shared with it), plus a
ready-to-run "command" holding a literal `<MODEL>` placeholder: writes the
prompt, the final defects, and (when set) the request to a fresh temp dir
and calls this file again with --defects-file/--tried/--model <MODEL>
(plus --request-file when a request was given), so the caller need only
swap in a chosen model id. Any failure building it (no key, Jev,
catalogue, no candidates) is never raised: it sets "escalation_error"
instead, the same way a critic failure never fails generate.py.

--suggest (the studio's critic suggestions) judges <file> once, never
calls a generator and never builds an escalation, and writes
{"defects": [...], "summary": "...", "model_trouble": bool} to --out: each
defect keeps type/where/box/severity/fix and gains a stable id "d1", "d2",
... in the critic's order. summary and model_trouble come from the same
critic call as the defects (no extra request): summary is one to three
plain sentences (overall verdict, what works, what the model got wrong),
"" when the critic didn't give one; model_trouble is the critic's own
verdict when it gives a bool, else true when any defect is prompt_adherence
at severity >= 4. When model_trouble is true, "models" is also written:
up to 4 Jev-ranked alternative generator models (model_options() below),
excluding --model (the round's own generator, optional for --suggest; with
no --model, nothing is excluded). A ranking failure never fails --suggest:
"models" is omitted and "models_error": "<message>" is written instead.

model_options(modality, prompt, request=None, defects=None, exclude=(),
key=None, limit=4) ranks alternative generator models for modality against
the brief (prompt), the user's request and the current defects, the same
way build_escalation ranks its own candidates (catalogue.py's priced list,
Jev through ranking.py): [{"id", "name", "price", "unit", "probability",
"reference_supported"}], best first, excluding ids in exclude. Raises like
build_escalation (ValueError, keys.MissingKey/UnsafeFile,
generate.ApiError, catalogue.CatalogueError, lib.jev.JevError) instead of
ever setting an escalation_error itself; callers decide how to handle that.

--models is the CLI-only wrapper around model_options: no <file>, judging
or generator model.  --modality picks the catalogue; --defects-file and
--request/--request-file feed the same ranking question suggest's internal
call does; --exclude is a comma-separated list of model ids to leave out.
Writes {"models": [...]} to --out.

--translate (the studio's feedback) sends the vision critic the clean
<file>; the pen layer --annotation alpha-composited over it (through
lib/png.py, the layer scaled to the image when sizes differ), or sent as
a separate image when <file> isn't a PNG (JPEG, WebP, an SVG with no
browser to rasterise it; a rasterised SVG is composited like a PNG); the
note pins from --notes-file ([{n, x, y, text}], x/y 0-1 fractions, or
{"notes": [...]}); the user's text from --text-file; and for video or
audio the markers from --frames-file ([{t, text, frame}] with frame an
image path or null, or {"markers": [...]}), each captured frame sent as
an image. <file> may then be the video or audio itself: it is not sent,
only the frames are. At least one of the four inputs is required. The
critic answers {"instructions": [{"where", "box", "instruction",
"source": pen|note|text|marker}]}, written to --out plus "cost".

--suggest and --translate print {"out": path, "cost": USD or null,
"critic": model id} on stdout; --models prints {"out": path, "cost": null}
(no critic is called). Also importable: suggest(path, prompt, critic=None,
key=None, request=None, model=None) and translate_annotations(image_path,
annotation_png, notes, text, request=None, critic=None, key=None,
frames=None), each returning the written JSON plus "cost" and "critic".

Every critic call is logged through generate.log_generation with
modality "critique"; every fix generation is logged the same way
generate.py logs one, under "raster_image" or "vector_svg".

Exit: 0 done (pass true or false, not passing isn't an error), 2 bad
args / missing file / unsupported file type, 3 no key, 4 API or
catalogue failure, 9 the critic reply is still not parseable JSON after
one retry. Stdlib only.
"""

import argparse
import base64
import json
import os
import re
import shlex
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, HERE)
from lib import jev, keys, png  # noqa: E402
import catalogue  # noqa: E402
import generate  # noqa: E402
import preview  # noqa: E402
import ranking  # noqa: E402

DEFAULT_CRITIC = "google/gemini-3.1-pro-preview"  # verified live on openrouter.ai/api/v1/models, 2026-09-23

RASTER_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".avif"}
VECTOR_EXTENSIONS = {".svg"}
UNSUPPORTED_EXTENSIONS = {
    ".mp4": "video", ".webm": "video", ".mov": "video",
    ".mp3": "speech", ".wav": "speech", ".ogg": "speech", ".pcm": "speech",
}

DEFECT_TYPES = ("line_continuity", "text_containment", "text_content", "alignment",
                 "spacing", "prompt_adherence", "artifact", "other")

CRITIC_SYSTEM = f"""You are a strict visual QA critic for generated images and vector art.
Reply with JSON only, matching exactly this schema. No prose, no code fences:

{{"pass": bool, "defects": [{{"type": one of {list(DEFECT_TYPES)!r}, "where": "short description", "box": [x0, y0, x1, y1] normalised 0-1 or null, "severity": 1-5, "fix": "imperative instruction for the generator"}}]}}

Checklist, one defect entry per issue found:
- line_continuity: strokes or lines that should join but don't (or shouldn't but do)
- text_containment: text that overflows its container or sits outside where it belongs
- text_content: misspelled, garbled, or wrong text versus what the prompt asked for
- alignment: elements that should align with each other but don't
- spacing: elements that should be evenly spaced but aren't
- prompt_adherence: elements the prompt asked for that are missing, or extra ones it didn't
- artifact: generation artifacts (smudges, warped shapes, broken geometry, seams, ...)
- other: any other concrete defect that doesn't fit the above

box is the defect's bounding box normalised to 0-1 on both axes, or null when it can't be
localised. severity is 1 (cosmetic) to 5 (breaks the image). fix is one imperative sentence
telling the generator exactly what to change. Do not report taste or style preferences
("could be more vibrant", "I'd use a different palette") — only concrete defects. Set
pass true only when you find nothing you would rate severity 3 or higher."""

# --suggest asks the same critic the same question, but in one extra breath also wants a
# plain-language summary and a verdict on whether the model itself is the problem, so the
# studio doesn't need a second request for those. Built by inserting the two extra fields
# into CRITIC_SYSTEM's own schema line, so the checklist itself stays in one place.
SUGGEST_SYSTEM = CRITIC_SYSTEM.replace(
    '{"pass": bool, "defects":',
    '{"pass": bool, '
    '"summary": "one to three plain sentences: overall verdict, what works, what the model got wrong", '
    '"model_trouble": bool (true when the model itself is failing to follow the prompt, for instance '
    'any prompt_adherence defect at severity 4 or 5, false otherwise), '
    '"defects":',
    1,
)

CRITIC_USER_TEMPLATE = (
    "The image below was generated from this prompt:\n\n{prompt}\n\n"
    "Judge it against the prompt and the checklist in your instructions. "
    "Reply with the JSON object described there, and nothing else."
)

REQUEST_LABEL = "The user's original request, verbatim:"
PROMPT_LABEL = "The prompt sent to the image generator:"
REQUEST_USER_TEMPLATE = (
    f"{PROMPT_LABEL}\n\n{{prompt}}\n\n{REQUEST_LABEL}\n\n{{request}}\n\n"
    "Judge the image below against both and the checklist in your instructions. "
    "Where the request and the prompt differ, the request wins. "
    "Reply with the JSON object described there, and nothing else."
)
REQUEST_SYSTEM_ADDENDUM = (
    "\n\nYou are also given the user's original request, verbatim, alongside the prompt "
    "sent to the image generator. Judge prompt_adherence against both: where they differ, "
    "the user's request wins. A detail the user asked for that is missing is a "
    "prompt_adherence defect even if the generator prompt omitted it. Parts of the request "
    "that are not about the visual result itself — thanks, unrelated asks such as \"also fix "
    "the tests\", meta-commentary about the conversation — are ignored and never reported."
)

_FENCE = re.compile(r"^```(?:json)?\s*\n?(.*?)\n?```$", re.DOTALL)


class CritiqueParseError(Exception):
    pass


# --- parsing the critic's reply ---------------------------------------------------

def _strip_fences(text):
    text = text.strip()
    match = _FENCE.match(text)
    return match.group(1) if match else text


def parse_critic_json(text):
    """The first top-level {...} object in text, fences stripped. None if
    nothing balances or nothing parses."""
    text = _strip_fences(text)
    start = text.find("{")
    if start == -1:
        return None
    depth = 0
    in_string = False
    escape = False
    for i in range(start, len(text)):
        c = text[i]
        if in_string:
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == '"':
                in_string = False
            continue
        if c == '"':
            in_string = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                try:
                    parsed = json.loads(text[start:i + 1])
                except ValueError:
                    return None
                return parsed if isinstance(parsed, dict) else None
    return None


def score(result):
    return sum((d.get("severity") or 0) for d in result["defects"] if isinstance(d, dict))


# --- building what the critic sees ------------------------------------------------

def ext_kind(path):
    """'raster_image', 'vector_svg', or None for anything else."""
    ext = os.path.splitext(path)[1].lower()
    if ext in RASTER_EXTENSIONS:
        return "raster_image"
    if ext in VECTOR_EXTENSIONS:
        return "vector_svg"
    return None


RASTERIZE_LONG_EDGE = 1024


def rasterize_window(raw):
    """(width, height) for the headless-Chrome window: the SVG's own
    viewBox aspect ratio, long edge scaled to RASTERIZE_LONG_EDGE, or a
    square RASTERIZE_LONG_EDGE x RASTERIZE_LONG_EDGE when no dims are
    found in the SVG."""
    dims = preview.dims_svg(raw)
    if not dims or dims[0] <= 0 or dims[1] <= 0:
        return RASTERIZE_LONG_EDGE, RASTERIZE_LONG_EDGE
    w, h = dims
    scale = RASTERIZE_LONG_EDGE / max(w, h)
    return max(1, round(w * scale)), max(1, round(h * scale))


def rasterize_svg(svg_path):
    """PNG bytes of svg_path via preview.py's headless-Chrome machinery, or
    None when no browser is on PATH (or it fails). The window (and the
    <img> filling it) is sized from the SVG's own viewBox aspect ratio, so
    a non-square SVG isn't clipped or padded to a fixed 1024x1024."""
    tmp_dir = tempfile.mkdtemp(prefix="clouter-critique-")
    with open(svg_path, "rb") as f:
        raw = f.read()
    width, height = rasterize_window(raw)
    html_path = os.path.join(tmp_dir, "critique.html")
    png_path = os.path.join(tmp_dir, "critique.png")
    html_text = (
        '<!doctype html><html><body style="margin:0">'
        f'<img src="{preview.data_url(svg_path, raw)}" '
        f'style="display:block;width:{width}px;height:{height}px"></body></html>'
    )
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html_text)
    if preview.render(html_path, png_path, width, height):
        with open(png_path, "rb") as f:
            return f.read()
    return None


def build_content(path, prompt, request=None):
    """The user message content list: a text part plus either an image_url
    data URL (raster, or SVG rasterised when a browser is available) or,
    for an SVG with no browser, the SVG source as a second text part.
    request, when given, labels the prompt and the user's verbatim
    request as separate sections of that text part, kept apart so the
    critic can tell what Claude wrote from what the user actually said."""
    if request:
        text = REQUEST_USER_TEMPLATE.format(prompt=prompt, request=request)
    else:
        text = CRITIC_USER_TEMPLATE.format(prompt=prompt)
    content = [{"type": "text", "text": text}]
    raw, media_type, svg_text = image_for_critic(path)
    if raw is not None:
        content.append(image_part(raw, media_type))
    else:
        content[0]["text"] += (
            "\n\nNo headless browser was available to rasterise it, so here is the "
            "SVG source (markup, not prose) instead:\n\n" + svg_text
        )
    return content


def image_for_critic(path):
    """(raw, media_type, None) for what the critic should see of path: a
    raster file's own bytes, or an SVG rasterised to PNG. (None, None,
    svg_source) for an SVG when no browser is available to rasterise it."""
    if ext_kind(path) == "vector_svg":
        png_bytes = rasterize_svg(path)
        if png_bytes is not None:
            return png_bytes, "image/png", None
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return None, None, f.read()
    with open(path, "rb") as f:
        raw = f.read()
    return raw, generate.sniff_media_type(path, raw) or "image/png", None


def image_part(raw, media_type):
    url = f"data:{media_type};base64,{base64.b64encode(raw).decode()}"
    return {"type": "image_url", "image_url": {"url": url}}


# --- one critic call ---------------------------------------------------------------

def judge(path, prompt, critic, key, request=None):
    """One judged round: {"pass": bool, "defects": [...], "cost": float|None}.
    request, when given, is the user's verbatim message: the critic sees
    it alongside prompt and is told the request wins where they differ.
    Raises CritiqueParseError after a second unparseable reply."""
    system = CRITIC_SYSTEM + (REQUEST_SYSTEM_ADDENDUM if request else "")
    parsed, cost = ask_critic(critic, key, system, build_content(path, prompt, request), path)
    defects = [d for d in (parsed.get("defects") or []) if isinstance(d, dict)]
    passed = not any((d.get("severity") or 0) >= 3 for d in defects)
    return {"pass": passed, "defects": defects, "cost": cost}


def _model_trouble(defects, model_trouble):
    """The critic's own model_trouble verdict when it gave one; otherwise true when any
    defect is prompt_adherence at severity >= 4."""
    if isinstance(model_trouble, bool):
        return model_trouble
    return any(d.get("type") == "prompt_adherence" and (d.get("severity") or 0) >= 4 for d in defects)


def suggest_judge(path, prompt, critic, key, request=None):
    """One judged round for --suggest: like judge(), plus a plain-language summary and a
    model_trouble verdict, asked in the same critic call (SUGGEST_SYSTEM's extended schema).
    {"defects": [...], "summary": str, "model_trouble": bool, "cost": float|None}. summary is
    "" when the critic didn't give one. Raises CritiqueParseError like judge()."""
    system = SUGGEST_SYSTEM + (REQUEST_SYSTEM_ADDENDUM if request else "")
    parsed, cost = ask_critic(critic, key, system, build_content(path, prompt, request), path)
    defects = [d for d in (parsed.get("defects") or []) if isinstance(d, dict)]
    summary = parsed.get("summary")
    summary = summary.strip() if isinstance(summary, str) else ""
    return {"defects": defects, "summary": summary,
            "model_trouble": _model_trouble(defects, parsed.get("model_trouble")), "cost": cost}


def ask_critic(critic, key, system, content, log_path):
    """One strict-JSON chat call to the critic: (parsed dict, cost). The
    call is logged against log_path with modality "critique". Raises
    CritiqueParseError after a second unparseable reply."""
    body = {
        "model": critic,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": content},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0,
        "usage": {"include": True},
    }
    for attempt in range(2):
        answer = generate.request_json("POST", "/api/v1/chat/completions", key, body)
        choices = answer.get("choices") or []
        text = ((choices[0].get("message") or {}).get("content") if choices else "") or ""
        parsed = parse_critic_json(text)
        if parsed is not None:
            cost = generate.cost_of(answer.get("usage"))
            generate.log_generation(log_path, critic, "critique", cost)
            return parsed, cost
    raise CritiqueParseError(f"{critic} did not answer with parseable JSON, even after a retry")


# --- the fix loop --------------------------------------------------------------------

def build_fix_prompt(prompt, defects):
    high = [d for d in defects if (d.get("severity") or 0) >= 3]
    low = [d for d in defects if (d.get("severity") or 0) < 3]
    lines = [d.get("fix") or d.get("where") or "fix this defect" for d in high + low]
    numbered = "\n".join(f"{i + 1}. {line}" for i, line in enumerate(lines))
    return f"{prompt}\nKeep everything else identical. Fix these defects:\n{numbered}"


_ROUND_SUFFIX = re.compile(r"\.r(\d+)(?:-\d+)?$")


def next_round_path(original, n, ext):
    """<stem>.r<n>.<ext>, never <stem>.rM.rN.<ext>: an original that is
    already an .rM file (an escalated run continuing an earlier critique)
    has that suffix stripped and its number added to n, so numbering
    continues instead of restarting."""
    stem = os.path.splitext(original)[0]
    match = _ROUND_SUFFIX.search(stem)
    base = int(match.group(1)) if match else 0
    if match:
        stem = stem[:match.start()]
    candidate = f"{stem}.r{base + n}.{ext}"
    i = 2
    while os.path.exists(candidate):
        candidate = f"{stem}.r{base + n}-{i}.{ext}"
        i += 1
    return candidate


# --- escalation: candidate models to hand off to when the final result still fails --

ESCALATION_QUESTION = (
    "Which model is most likely to fix these defects in the image? Weigh capability for "
    "these defect types (text rendering, layout precision, prompt adherence) above price."
)
ESCALATION_CANDIDATES = 10
ESCALATION_TIMEOUT = 15.0


MODEL_OPTIONS_CANDIDATES = ESCALATION_CANDIDATES
MODEL_OPTIONS_QUESTION = (
    "Which model is the best alternative for this brief? Weigh capability for the modality "
    "and any known defects above price."
)


def _defect_state(defects):
    return [{"type": d.get("type"), "severity": d.get("severity"), "fix": d.get("fix")} for d in (defects or [])]


def _rank_entries(entries, prompt, modality, current_model, defects, question, floor, timeout, limit, request=None):
    """Jev-rank entries (catalogue.py entries: id/name/description/price/unit/...) against the
    brief, best `limit` first: the recommended pick (if any, its confidence >= floor) first,
    then the rest by probability descending, cheapest first on a tie. Shared by
    build_escalation and model_options so both rank through one implementation. Returns
    (ordered entries, recommended id or None). Raises lib.jev.JevError, keys.MissingKey/
    UnsafeFile."""
    state = {"prompt": prompt, "modality": modality, "current_model": current_model,
             "defects": _defect_state(defects)}
    if request:
        state["request"] = request
    ranked, recommended = ranking.rank_models(entries, state, question, floor, timeout)
    recommended_id = recommended["id"] if recommended else None
    ordered = sorted(ranked, key=lambda e: (e["id"] != recommended_id, -e["probability"], e["price"]))
    return ordered[:limit], recommended_id


def model_options(modality, prompt, request=None, defects=None, exclude=(), key=None, limit=4):
    """Jev-rank alternative generator models for `modality` given the brief (prompt), the
    user's request and the current defects. Returns
    [{"id","name","price","unit","probability","reference_supported"}], best first,
    excluding ids in `exclude`. Shares its ranking with build_escalation through
    _rank_entries: catalogue.py's priced list, ranked by ranking.py the way route.py ranks
    its own choices. key is accepted for interface symmetry with the rest of this module;
    catalogue.py and ranking.py find their own credentials through lib.keys. Raises
    ValueError (no candidates left after exclude), keys.MissingKey/UnsafeFile,
    generate.ApiError, catalogue.CatalogueError or lib.jev.JevError on a failed
    catalogue/ranking call."""
    floor = float(os.environ.get("CLOUTER_VISUAL_FLOOR", "0.5"))
    exclude_ids = set(exclude)
    all_entries = catalogue.models(modality, timeout=ESCALATION_TIMEOUT)
    entries = [e for e in all_entries if e["price"] is not None and e["id"] not in exclude_ids]
    entries = entries[:MODEL_OPTIONS_CANDIDATES]
    if not entries:
        raise ValueError("no candidate models")
    ordered, _recommended_id = _rank_entries(
        entries, prompt, modality, None, defects, MODEL_OPTIONS_QUESTION, floor, ESCALATION_TIMEOUT,
        limit, request=request)
    return [{"id": e["id"], "name": e["name"], "price": e["price"], "unit": e["unit"],
             "probability": e["probability"], "reference_supported": bool(e.get("reference_supported"))}
            for e in ordered]


def build_escalation(prompt, gen_model, modality, final_path, defects, tried, rounds,
                      critic, aspect, transparent, request=None):
    """Escalation options for a final result that still failed: up to
    ESCALATION_CANDIDATES priced, reference-taking models not yet tried,
    cheapest first, ranked by Jev (skills/visual/ranking.py, the helper
    route.py's own model ranking shares), plus a ready-to-run command with
    a literal <MODEL> placeholder. request, when given, is also written to
    the escalation's temp dir and cited with --request-file, so the retry
    keeps seeing the user's verbatim message. Raises on any failure (no
    key, Jev, catalogue, no candidates); run() catches it and sets
    escalation_error instead."""
    floor = float(os.environ.get("CLOUTER_VISUAL_FLOOR", "0.5"))
    all_entries = catalogue.models(modality, timeout=ESCALATION_TIMEOUT)
    by_id = {e["id"]: e for e in all_entries}
    current = by_id.get(gen_model)
    tried_ids = set(tried or []) | {gen_model}

    entries = [e for e in all_entries
               if e["reference_supported"] and e["price"] is not None and e["id"] not in tried_ids]
    if current is not None and current.get("price") is not None:
        entries = [e for e in entries if e["price"] >= current["price"]]
    if transparent and modality == "raster_image":
        alpha_entries = [e for e in entries if e.get("alpha")]
        if alpha_entries:  # keep the fake-checkerboard models out only if a real one remains
            entries = alpha_entries
    entries = entries[:ESCALATION_CANDIDATES]
    if not entries:
        raise ValueError("no escalation candidates")

    ordered, recommended_id = _rank_entries(
        entries, prompt, modality, gen_model, defects, ESCALATION_QUESTION, floor, ESCALATION_TIMEOUT, 3)
    options_list = [{"id": e["id"], "name": e["name"], "price": e["price"], "unit": e["unit"],
                      "probability": e["probability"]} for e in ordered]

    tmp_dir = tempfile.mkdtemp(prefix="clouter-critique-")
    prompt_path = os.path.join(tmp_dir, "prompt.txt")
    defects_path = os.path.join(tmp_dir, "defects.json")
    with open(prompt_path, "w", encoding="utf-8") as f:
        f.write(prompt)
    with open(defects_path, "w", encoding="utf-8") as f:
        json.dump(defects, f)

    parts = ["python3", shlex.quote(os.path.abspath(__file__)), shlex.quote(final_path),
             "--prompt-file", shlex.quote(prompt_path),
             "--defects-file", shlex.quote(defects_path),
             "--tried", shlex.quote(",".join(sorted(tried_ids))),
             "--rounds", str(max(rounds, 1)),
             "--model", "<MODEL>"]
    if aspect:
        parts += ["--aspect", shlex.quote(aspect)]
    if transparent:
        parts.append("--transparent")
    if critic:
        parts += ["--critic", shlex.quote(critic)]
    if request:
        request_path = os.path.join(tmp_dir, "request.txt")
        with open(request_path, "w", encoding="utf-8") as f:
            f.write(request)
        parts += ["--request-file", shlex.quote(request_path)]

    return {"options": options_list, "recommended": recommended_id, "command": " ".join(parts)}


def check_judgeable(path):
    """path's kind ('raster_image' or 'vector_svg'); raises ValueError for a
    missing file or one critique can't judge (video, speech, unknown)."""
    if not os.path.isfile(path):
        raise ValueError(f"{path} not found")
    kind = ext_kind(path)
    if kind is None:
        ext = os.path.splitext(path)[1].lower()
        if ext in UNSUPPORTED_EXTENSIONS:
            raise ValueError(f"critique only judges images and SVGs, not {UNSUPPORTED_EXTENSIONS[ext]} ({path})")
        raise ValueError(f"unrecognised file type for critique: {path}")
    return kind


SUGGESTION_FIELDS = ("type", "where", "box", "severity", "fix")


def suggest(path, prompt, critic=None, key=None, request=None, model=None):
    """Judge path once, for the studio's critic suggestions: never calls a
    generator and never builds an escalation. Returns {"defects": [...],
    "summary": str, "model_trouble": bool, "cost": float|None, "critic": id},
    each defect keeping only SUGGESTION_FIELDS plus a stable id "d1", "d2",
    ... in the critic's order. summary and model_trouble come from the same
    critic call as the defects (suggest_judge's extended schema). model is
    the round's own generator model id, when known: when model_trouble is
    true, "models" (model_options(), excluding model) is added too; a
    failed ranking never fails suggest() itself, setting "models_error"
    instead. Raises like run()."""
    kind = check_judgeable(path)
    critic = critic or os.environ.get("CLOUTER_CRITIC") or DEFAULT_CRITIC
    if key is None:
        key = keys.get("OPENROUTER_API_KEY")  # raises MissingKey/UnsafeFile
    result = suggest_judge(path, prompt, critic, key, request)
    defects = [dict({"id": f"d{i + 1}"}, **{k: d.get(k) for k in SUGGESTION_FIELDS})
               for i, d in enumerate(result["defects"])]
    out = {"defects": defects, "summary": result["summary"], "model_trouble": result["model_trouble"],
           "cost": result["cost"], "critic": critic}
    if result["model_trouble"]:
        try:
            out["models"] = model_options(kind, prompt, request=request, defects=defects,
                                          exclude={model} if model else (), key=key)
        except Exception as e:  # noqa: BLE001 - a failed ranking must never fail suggest()
            out["models_error"] = f"{type(e).__name__}: {e}"
    return out


# --- studio: translating the user's annotations into generator instructions --------

INSTRUCTION_SOURCES = ("pen", "note", "text", "marker")

TRANSLATE_SYSTEM = f"""You turn a user's feedback on a generated image, video or audio clip into precise edit
instructions for the generator. Reply with JSON only, matching exactly this schema. No prose, no code fences:

{{"instructions": [{{"where": "short description of the place", "box": [x0, y0, x1, y1] normalised 0-1 or null, "instruction": "imperative instruction for the generator", "source": one of {list(INSTRUCTION_SOURCES)!r}}}]}}

What you may be given:
- the clean image, as generated;
- the same image with the user's pen strokes drawn on top, or (when compositing wasn't possible) the pen
  layer alone on a transparent background, at the image's own proportions (source "pen");
- numbered note pins, each at an x/y position given as 0-1 fractions of the image (source "note");
- the user's free text (source "text");
- for video or audio, timestamped markers, with the captured video frame when there is one (source "marker").

Rules: one instruction per distinct change the user asks for. Read pen marks for what they point at —
a circle, a cross, an arrow, a scribble over something — and describe the target by what it depicts, never
as "the red circle": the strokes themselves are never part of the wanted result. box localises the change
on the clean image (for a marker, on its frame), or null when it can't be localised. For a marker, say its
timestamp in where. Each instruction must stand on its own, without the annotations. Do not invent changes
the user didn't ask for, and do not add taste or style preferences of your own."""


def _scaled_row(layer_rows, lw, lh, width, height, y):
    """Row y of the layer scaled (nearest neighbour) to width x height."""
    src = layer_rows[min(lh - 1, y * lh // height)]
    if lw == width:
        return src
    out = bytearray(width * 4)
    for x in range(width):
        sx = min(lw - 1, x * lw // width) * 4
        out[x * 4:x * 4 + 4] = src[sx:sx + 4]
    return out


def composite_png(base_raw, layer_raw):
    """PNG bytes of base_raw with layer_raw alpha-composited on top (source
    over), the layer scaled to the base's size when the two differ. Raises
    png.PngError when either can't be decoded."""
    width, height, rows = png.decode(base_raw)
    lw, lh, layer_rows = png.decode(layer_raw)
    out_rows = []
    for y in range(height):
        row = bytearray(rows[y])
        layer = _scaled_row(layer_rows, lw, lh, width, height, y)
        for i in range(3, width * 4, 4):
            la = layer[i]
            if la == 0:
                continue
            ba = row[i]
            out_a = la + ba * (255 - la) // 255
            for c in range(i - 3, i):
                row[c] = (layer[c] * la * 255 + row[c] * ba * (255 - la)) // (out_a * 255)
            row[i] = out_a
        out_rows.append(row)
    return png.encode(width, height, out_rows)


def _read_frame(frame_path):
    with open(frame_path, "rb") as f:
        raw = f.read()
    return image_part(raw, generate.sniff_media_type(frame_path, raw) or "image/png")


def translate_annotations(image_path, annotation_png, notes, text, request=None, critic=None,
                          key=None, frames=None):
    """Translate the studio's feedback on image_path into generator
    instructions through the vision critic. annotation_png is the pen
    layer (RGBA PNG path) or None; notes a list of {n, x, y, text} pins
    (x/y 0-1 fractions); text the user's free text; frames, for video or
    audio, a list of {t, text, frame} markers (frame an image path or
    None). request, when given, is the user's original request, verbatim.
    For a raster or SVG image_path the critic sees the clean image plus
    the pen layer composited on top of it, or the layer as a separate
    image when the clean image isn't a PNG (or compositing fails). Returns
    {"instructions": [...], "cost": float|None, "critic": id}. Raises
    ValueError for missing files, keys.MissingKey/UnsafeFile,
    generate.ApiError or CritiqueParseError like run()."""
    if not os.path.isfile(image_path):
        raise ValueError(f"{image_path} not found")
    if annotation_png and not os.path.isfile(annotation_png):
        raise ValueError(f"{annotation_png} not found")
    notes = [n for n in (notes or []) if isinstance(n, dict)]
    frames = [m for m in (frames or []) if isinstance(m, dict)]
    for m in frames:
        if m.get("frame") and not os.path.isfile(m["frame"]):
            raise ValueError(f"{m['frame']} not found")
    critic = critic or os.environ.get("CLOUTER_CRITIC") or DEFAULT_CRITIC
    if key is None:
        key = keys.get("OPENROUTER_API_KEY")  # raises MissingKey/UnsafeFile

    lines = []
    if request:
        lines += [REQUEST_LABEL, "", request, ""]
    images = []
    if ext_kind(image_path) is not None:
        raw, media_type, svg_text = image_for_critic(image_path)
        if raw is not None:
            lines.append("Image 1 is the clean image, as generated.")
            images.append(image_part(raw, media_type))
        else:
            lines += ["No headless browser was available to rasterise the clean image, so here is its "
                      "SVG source (markup, not prose):", "", svg_text, ""]
        if annotation_png:
            with open(annotation_png, "rb") as f:
                layer_raw = f.read()
            composite = None
            if media_type == "image/png":
                try:
                    composite = composite_png(raw, layer_raw)
                except ValueError:  # png.PngError: a PNG lib/png.py can't read
                    composite = None
            if composite is not None:
                lines.append(f"Image {len(images) + 1} is the same image with the user's pen strokes drawn on top.")
                images.append(image_part(composite, "image/png"))
            else:
                lines.append(f"Image {len(images) + 1} is the user's pen layer alone, on a transparent "
                             "background, to be laid over the clean image at the same proportions.")
                images.append(image_part(layer_raw, "image/png"))
    if notes:
        lines += ["", "Note pins (x/y are 0-1 fractions of the image width/height):"]
        for i, n in enumerate(notes):
            lines.append(f"{n.get('n', i + 1)}. at x={n.get('x')}, y={n.get('y')}: {n.get('text') or ''}")
    if frames:
        lines += ["", "Timeline markers:"]
        for m in frames:
            line = f"- at {m.get('t')}s: {m.get('text') or ''}"
            if m.get("frame"):
                images.append(_read_frame(m["frame"]))
                line += f" (captured frame: image {len(images)})"
            lines.append(line)
    lines += ["", "The user's text:", "", (text or "").strip() or "(none)", "",
              "Reply with the JSON object described in your instructions, and nothing else."]

    content = [{"type": "text", "text": "\n".join(lines)}] + images
    parsed, cost = ask_critic(critic, key, TRANSLATE_SYSTEM, content, image_path)
    instructions = [i for i in (parsed.get("instructions") or []) if isinstance(i, dict)]
    return {"instructions": instructions, "cost": cost, "critic": critic}


def run(path, prompt, gen_model, rounds=2, critic=None, key=None, aspect=None, transparent=False,
        initial_defects=None, tried=None, request=None, params=None, endpoint="auto"):
    """Judge path against prompt, fixing through gen_model for up to
    `rounds` tries. initial_defects seeds the first judged result instead
    of calling the critic (continuing an earlier critique with a new
    gen_model); tried lists model ids already attempted, excluded from a
    fresh escalation's candidates. request, when given, is the user's own
    verbatim message: every critic call sees it alongside prompt, told it
    wins where the two differ, and it is carried into any escalation
    command too. params and endpoint are generate.py's already-validated
    --param fields and the endpoint the first (paid-for) round used, so
    every fix round sends the same request shape, not a bare default.
    Never prints or exits: raises ValueError
    (bad args / missing file / unsupported type), keys.MissingKey/
    UnsafeFile (no key), generate.ApiError or catalogue.CatalogueError (API
    failure), or CritiqueParseError (unparseable critic reply)."""
    kind = check_judgeable(path)
    critic = critic or os.environ.get("CLOUTER_CRITIC") or DEFAULT_CRITIC
    if key is None:
        key = keys.get("OPENROUTER_API_KEY")  # raises MissingKey/UnsafeFile

    total_cost = 0.0
    any_cost = False

    def add_cost(c):
        nonlocal total_cost, any_cost
        if isinstance(c, (int, float)):
            total_cost += c
            any_cost = True

    files = [path]
    if initial_defects is not None:
        seeded_defects = [d for d in initial_defects if isinstance(d, dict)]
        first_result = {"pass": not any((d.get("severity") or 0) >= 3 for d in seeded_defects),
                        "defects": seeded_defects, "cost": None}
    else:
        first_result = judge(path, prompt, critic, key, request)
    judged = [(path, first_result)]
    add_cost(judged[0][1]["cost"])

    rounds_used = 0
    current_path, current_result = judged[0]
    while not current_result["pass"] and rounds_used < rounds:
        rounds_used += 1
        fix_prompt = build_fix_prompt(prompt, current_result["defects"])
        reference = None
        if catalogue.reference_supported(gen_model):
            reference = generate.load_reference(current_path)
        raw, media_type, ext, gen_cost = generate.make_image(
            gen_model, fix_prompt, aspect, key, endpoint, transparent, reference, params=params)
        add_cost(gen_cost)
        new_path = next_round_path(path, rounds_used, ext)
        directory = os.path.dirname(new_path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(new_path, "wb") as f:
            f.write(raw)
        modality = "vector_svg" if ext == "svg" else "raster_image"
        generate.log_generation(new_path, gen_model, modality, gen_cost)
        files.append(new_path)

        current_result = judge(new_path, prompt, critic, key, request)
        add_cost(current_result["cost"])
        current_path = new_path
        judged.append((current_path, current_result))

    # Every judged file competes, the original (or its seeded result)
    # included: a passing file beats any failing one, then the lowest score
    # wins, and a tie goes to the earliest file, since a fix round that
    # didn't improve anything shouldn't displace what came before it.
    best = min(range(len(judged)), key=lambda i: (not judged[i][1]["pass"], score(judged[i][1]), i))
    final_path, final_result = judged[best]

    result = {
        "final": final_path,
        "pass": final_result["pass"],
        "rounds": rounds_used,
        "files": files,
        "defects": final_result["defects"],
        "cost": round(total_cost, 6) if any_cost else None,
        "critic": critic,
    }
    if not result["pass"]:
        try:
            result["escalation"] = build_escalation(
                prompt, gen_model, kind, final_path, final_result["defects"],
                tried, rounds, critic, aspect, transparent, request)
        except Exception as e:  # noqa: BLE001 - escalation must never fail run()
            result["escalation_error"] = f"{type(e).__name__}: {e}"
    return result


def _read_json_arg(path, parser, flag, key):
    """A JSON list from a --<flag> file: the list itself, or the `key` list
    of an object holding one. Errors through parser.error."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            value = json.load(f)
    except (OSError, ValueError) as e:
        parser.error(f"cannot read --{flag} {path}: {e}")
    if isinstance(value, dict):
        value = value.get(key)
    if not isinstance(value, list):
        parser.error(f"--{flag} {path} must be a JSON list, or an object with a \"{key}\" list")
    return value


def _write_out(path, obj):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)


def main(argv):
    parser = argparse.ArgumentParser(
        description="Judge a generated image with a vision-model critic, and fix defects it finds.")
    parser.add_argument("file", nargs="?", help="the image or SVG to judge (not used with --models)")
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument("--suggest", action="store_true",
                            help="judge once and write the defects, with ids, to --out (no fix rounds)")
    mode_group.add_argument("--translate", action="store_true",
                            help="turn studio annotations on <file> into generator instructions in --out")
    mode_group.add_argument("--models", action="store_true",
                            help="rank alternative generator models for --modality into --out (no judging)")
    parser.add_argument("--out", help="--suggest/--translate/--models: path of the JSON file to write")
    prompt_group = parser.add_mutually_exclusive_group()
    prompt_group.add_argument("--prompt", help="the original generation prompt")
    prompt_group.add_argument("--prompt-file", help="path to a file holding the prompt text")
    parser.add_argument("--model", help="the generator model id (for fix rounds, required unless "
                        "--translate or --models; optional for --suggest, to exclude it from "
                        "\"models\" when model_trouble is true)")
    parser.add_argument("--modality", choices=catalogue.MODALITIES,
                        help="--models: the modality to rank alternatives for")
    parser.add_argument("--exclude", help="--models: comma-separated model ids to leave out")
    parser.add_argument("--rounds", type=int, default=2, help="max fix rounds (0: judge only, default 2)")
    parser.add_argument("--critic", help="critic model id (default CLOUTER_CRITIC, else the built-in default)")
    parser.add_argument("--aspect", help="aspect ratio such as 16:9, for a fix regeneration")
    parser.add_argument("--transparent", action="store_true", help="raster only: keep --transparent on fix rounds")
    parser.add_argument("--defects-file", help="JSON list of defects (or {\"defects\": [...]})"
                        " to seed the first judged result, skipping the first critic call")
    parser.add_argument("--tried", help="comma-separated model ids already tried, excluded from "
                        "a fresh escalation's candidates")
    parser.add_argument("--annotation", help="--translate: the pen layer, an RGBA PNG")
    parser.add_argument("--notes-file", help="--translate: JSON list of {n, x, y, text} note pins "
                        "(or {\"notes\": [...]})")
    parser.add_argument("--text-file", help="--translate: path to a file holding the user's free text")
    parser.add_argument("--frames-file", help="--translate: JSON list of {t, text, frame} markers "
                        "(or {\"markers\": [...]})")
    request_group = parser.add_mutually_exclusive_group()
    request_group.add_argument("--request", help="the user's original request, verbatim")
    request_group.add_argument("--request-file", help="path to a file holding the user's original "
                                "request, verbatim")
    args = parser.parse_args(argv[1:])
    if (args.suggest or args.translate or args.models) and not args.out:
        parser.error("--out is required with --suggest, --translate and --models")
    if not args.suggest and not args.translate and not args.models and not args.model:
        parser.error("the following arguments are required: --model")
    if not args.models and not args.file:
        parser.error("the following arguments are required: file")
    if args.request_file:
        args.request = generate.read_text_arg(args.request_file, parser, "request-file")

    if args.models:
        if not args.modality:
            parser.error("--modality is required with --models")
        exclude = [e.strip() for e in args.exclude.split(",") if e.strip()] if args.exclude else []
        defects = None
        if args.defects_file:
            defects = _read_json_arg(args.defects_file, parser, "defects-file", "defects")
        if not args.prompt and not args.prompt_file:
            parser.error("one of the arguments --prompt --prompt-file is required")
        if args.prompt_file:
            args.prompt = generate.read_text_arg(args.prompt_file, parser, "prompt-file")
        if not args.prompt.strip():
            parser.error("--prompt must not be empty")
        return _cli_call(lambda: {"models": model_options(
            args.modality, args.prompt, request=args.request, defects=defects, exclude=exclude)},
            args.out, ("models",))

    if args.translate:
        notes = _read_json_arg(args.notes_file, parser, "notes-file", "notes") if args.notes_file else []
        frames = _read_json_arg(args.frames_file, parser, "frames-file", "markers") if args.frames_file else []
        text = generate.read_text_arg(args.text_file, parser, "text-file") if args.text_file else ""
        if not (args.annotation or notes or frames or text.strip()):
            parser.error("--translate needs at least one of --annotation, --notes-file, "
                         "--frames-file or a non-empty --text-file")
        return _cli_call(lambda: translate_annotations(
            args.file, args.annotation, notes, text, request=args.request, critic=args.critic,
            frames=frames), args.out, ("instructions", "cost"))

    if not args.prompt and not args.prompt_file:
        parser.error("one of the arguments --prompt --prompt-file is required")
    if args.prompt_file:
        args.prompt = generate.read_text_arg(args.prompt_file, parser, "prompt-file")
    if not args.prompt.strip():
        parser.error("--prompt must not be empty")

    if args.suggest:
        return _cli_call(lambda: suggest(args.file, args.prompt, critic=args.critic,
                                         request=args.request, model=args.model), args.out,
                         ("defects", "summary", "model_trouble", "models", "models_error"))

    initial_defects = None
    if args.defects_file:
        initial_defects = _read_json_arg(args.defects_file, parser, "defects-file", "defects")
    tried = [t.strip() for t in args.tried.split(",") if t.strip()] if args.tried else None

    return _cli_call(lambda: run(args.file, args.prompt, args.model, rounds=args.rounds,
                                 critic=args.critic, aspect=args.aspect,
                                 transparent=args.transparent, initial_defects=initial_defects,
                                 tried=tried, request=args.request))


def _cli_call(call, out=None, out_keys=()):
    """Run call() and map its exceptions to exit codes. With out, the
    result's present out_keys are written there and stdout gets {"out",
    "cost", "critic"} (critic omitted when call() didn't return one, as
    --models doesn't); without, the whole result goes to stdout."""
    try:
        result = call()
    except ValueError as e:
        print(f"critique: {e}", file=sys.stderr)
        return 2
    except (keys.MissingKey, keys.UnsafeFile) as e:
        print(f"critique: {e}", file=sys.stderr)
        return 3
    except (generate.ApiError, catalogue.CatalogueError, jev.JevError) as e:
        print(f"critique: {e}", file=sys.stderr)
        return 4
    except CritiqueParseError as e:
        print(f"critique: {e}", file=sys.stderr)
        return 9

    if out is None:
        print(json.dumps(result))
        return 0
    try:
        _write_out(out, {k: result[k] for k in out_keys if k in result})
    except OSError as e:
        print(f"critique: cannot write --out {out}: {e}", file=sys.stderr)
        return 2
    printed = {"out": out, "cost": result.get("cost")}
    if "critic" in result:
        printed["critic"] = result["critic"]
    print(json.dumps(printed))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

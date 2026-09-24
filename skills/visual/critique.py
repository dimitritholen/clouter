#!/usr/bin/env python3
"""Judge a generated image against its prompt, then ask the generator to
fix what's wrong, for up to --rounds tries.

    critique.py <file> (--prompt <text> | --prompt-file <path>)
                --model <generator model id>
                [--rounds N] [--critic <model id>] [--aspect 16:9] [--transparent]
                [--defects-file <path>] [--tried <id,id,...>]
                [--request <text> | --request-file <path>]

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
the passing one, else the lowest-scored one seen (a fix can make things
worse); ties go to the later file.

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
from lib import keys  # noqa: E402
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
    if ext_kind(path) == "vector_svg":
        png_bytes = rasterize_svg(path)
        if png_bytes is not None:
            url = preview.data_url("critique.png", png_bytes)
            content.append({"type": "image_url", "image_url": {"url": url}})
        else:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                svg_text = f.read()
            content[0]["text"] += (
                "\n\nNo headless browser was available to rasterise it, so here is the "
                "SVG source (markup, not prose) instead:\n\n" + svg_text
            )
    else:
        with open(path, "rb") as f:
            raw = f.read()
        media_type = generate.sniff_media_type(path, raw) or "image/png"
        url = f"data:{media_type};base64,{base64.b64encode(raw).decode()}"
        content.append({"type": "image_url", "image_url": {"url": url}})
    return content


# --- one critic call ---------------------------------------------------------------

def judge(path, prompt, critic, key, request=None):
    """One judged round: {"pass": bool, "defects": [...], "cost": float|None}.
    request, when given, is the user's verbatim message: the critic sees
    it alongside prompt and is told the request wins where they differ.
    Raises CritiqueParseError after a second unparseable reply."""
    system = CRITIC_SYSTEM + (REQUEST_SYSTEM_ADDENDUM if request else "")
    body = {
        "model": critic,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": build_content(path, prompt, request)},
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
            defects = [d for d in (parsed.get("defects") or []) if isinstance(d, dict)]
            cost = generate.cost_of(answer.get("usage"))
            generate.log_generation(path, critic, "critique", cost)
            passed = not any((d.get("severity") or 0) >= 3 for d in defects)
            return {"pass": passed, "defects": defects, "cost": cost}
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


def _defect_state(defects):
    return [{"type": d.get("type"), "severity": d.get("severity"), "fix": d.get("fix")} for d in defects]


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

    ranked, recommended = ranking.rank_models(
        entries,
        {"prompt": prompt, "modality": modality, "current_model": gen_model,
         "defects": _defect_state(defects)},
        ESCALATION_QUESTION,
        floor,
        ESCALATION_TIMEOUT,
    )
    recommended_id = recommended["id"] if recommended else None
    by_probability = sorted(
        ranked,
        key=lambda e: (e["id"] != recommended_id, -e["probability"], e["price"]),
    )[:3]
    options_list = [{"id": e["id"], "name": e["name"], "price": e["price"], "unit": e["unit"],
                      "probability": e["probability"]} for e in by_probability]

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

    return {"options": options_list, "recommended": recommended["id"] if recommended else None,
            "command": " ".join(parts)}


def run(path, prompt, gen_model, rounds=2, critic=None, key=None, aspect=None, transparent=False,
        initial_defects=None, tried=None, request=None):
    """Judge path against prompt, fixing through gen_model for up to
    `rounds` tries. initial_defects seeds the first judged result instead
    of calling the critic (continuing an earlier critique with a new
    gen_model); tried lists model ids already attempted, excluded from a
    fresh escalation's candidates. request, when given, is the user's own
    verbatim message: every critic call sees it alongside prompt, told it
    wins where the two differ, and it is carried into any escalation
    command too. Never prints or exits: raises ValueError
    (bad args / missing file / unsupported type), keys.MissingKey/
    UnsafeFile (no key), generate.ApiError or catalogue.CatalogueError (API
    failure), or CritiqueParseError (unparseable critic reply)."""
    if not os.path.isfile(path):
        raise ValueError(f"{path} not found")
    kind = ext_kind(path)
    if kind is None:
        ext = os.path.splitext(path)[1].lower()
        if ext in UNSUPPORTED_EXTENSIONS:
            raise ValueError(f"critique only judges images and SVGs, not {UNSUPPORTED_EXTENSIONS[ext]} ({path})")
        raise ValueError(f"unrecognised file type for critique: {path}")

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
            gen_model, fix_prompt, aspect, key, "auto", transparent, reference)
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

    if current_result["pass"]:
        final_path, final_result = current_path, current_result
    else:
        final_path, final_result = judged[0]
        for candidate_path, candidate_result in judged[1:]:
            if score(candidate_result) <= score(final_result):
                final_path, final_result = candidate_path, candidate_result

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


def main(argv):
    parser = argparse.ArgumentParser(
        description="Judge a generated image with a vision-model critic, and fix defects it finds.")
    parser.add_argument("file")
    prompt_group = parser.add_mutually_exclusive_group()
    prompt_group.add_argument("--prompt", help="the original generation prompt")
    prompt_group.add_argument("--prompt-file", help="path to a file holding the prompt text")
    parser.add_argument("--model", required=True, help="the generator model id (for fix rounds)")
    parser.add_argument("--rounds", type=int, default=2, help="max fix rounds (0: judge only, default 2)")
    parser.add_argument("--critic", help="critic model id (default CLOUTER_CRITIC, else the built-in default)")
    parser.add_argument("--aspect", help="aspect ratio such as 16:9, for a fix regeneration")
    parser.add_argument("--transparent", action="store_true", help="raster only: keep --transparent on fix rounds")
    parser.add_argument("--defects-file", help="JSON list of defects (or {\"defects\": [...]})"
                        " to seed the first judged result, skipping the first critic call")
    parser.add_argument("--tried", help="comma-separated model ids already tried, excluded from "
                        "a fresh escalation's candidates")
    request_group = parser.add_mutually_exclusive_group()
    request_group.add_argument("--request", help="the user's original request, verbatim")
    request_group.add_argument("--request-file", help="path to a file holding the user's original "
                                "request, verbatim")
    args = parser.parse_args(argv[1:])
    if not args.prompt and not args.prompt_file:
        parser.error("one of the arguments --prompt --prompt-file is required")
    if args.prompt_file:
        args.prompt = generate.read_text_arg(args.prompt_file, parser, "prompt-file")
    if not args.prompt.strip():
        parser.error("--prompt must not be empty")
    if args.request_file:
        args.request = generate.read_text_arg(args.request_file, parser, "request-file")

    initial_defects = None
    if args.defects_file:
        try:
            with open(args.defects_file, "r", encoding="utf-8") as f:
                raw_defects = json.load(f)
        except (OSError, ValueError) as e:
            parser.error(f"cannot read --defects-file {args.defects_file}: {e}")
        if isinstance(raw_defects, dict):
            raw_defects = raw_defects.get("defects")
        if not isinstance(raw_defects, list):
            parser.error(f"--defects-file {args.defects_file} must be a JSON list, "
                         "or an object with a \"defects\" list")
        initial_defects = raw_defects
    tried = [t.strip() for t in args.tried.split(",") if t.strip()] if args.tried else None

    try:
        result = run(args.file, args.prompt, args.model, rounds=args.rounds, critic=args.critic,
                     aspect=args.aspect, transparent=args.transparent,
                     initial_defects=initial_defects, tried=tried, request=args.request)
    except ValueError as e:
        print(f"critique: {e}", file=sys.stderr)
        return 2
    except (keys.MissingKey, keys.UnsafeFile) as e:
        print(f"critique: {e}", file=sys.stderr)
        return 3
    except (generate.ApiError, catalogue.CatalogueError) as e:
        print(f"critique: {e}", file=sys.stderr)
        return 4
    except CritiqueParseError as e:
        print(f"critique: {e}", file=sys.stderr)
        return 9

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

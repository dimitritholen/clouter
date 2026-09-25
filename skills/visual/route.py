#!/usr/bin/env python3
"""UserPromptSubmit hook: route a visual request to an OpenRouter model.

Reads the hook payload on stdin and stays silent (exit 0, no output)
unless the prompt matches the word prefilter and an OpenRouter key is
stored. A prompt whose stripped text starts with <task-notification> or
<system-reminder> is a system event, not typed input, and is skipped
before the prefilter even runs. Then one Jev Choice says what the prompt asks for (text_or_code,
raster_image, vector_svg, video, speech). The floor applies to the summed
probability of the visual modalities, so a prompt split between SVG and
PNG is not read as doubt; under it means silence. A prompt can carry more
than one modality: every visual one at or above the multi threshold
counts, the likeliest always. Without per-option probabilities the old
rule holds: Jev's pick, its confidence over the floor. Per requested
modality the six cheapest catalogue entries go into one more Choice,
all modalities concurrently: Jev's pick is the recommendation, the
probabilities are the ranking. The output is hook JSON with
additionalContext telling Claude to ask every question in the studio
page (studio.py ask, then wait; AskUserQuestion only when the studio
cannot start), to run interview.py's gaps check on a brief first (and ask what it lists, re-ranking through interview.py rank
when an answer changes what the model must do), then to ask one
question set, one question per modality (Jev's pick first and
marked Recommended, then cheap to expensive, a price in every label,
plus a stay-with-Claude option) and then run generate.py once per chosen
model. A prompt that says transparent, transparency, alpha or "dark and
light" prefers catalogue.py's alpha-capable raster models (dropping the
rest when at least one alpha model remains) and adds --transparent to
the raster generate.py command. The raw user prompt is also written
verbatim to a temp file and every suggested command carries
--request-file <path>, so the critic sees it even when the design
brief Claude writes drops a detail; a write failure drops the flag
silently, never the hook.

Budget: the hook runs under a 10-second timeout, so every network call
gets what is left of an internal 9-second deadline, at most 2.5 seconds
each. Any failure exits 0 silently: a routing miss costs nothing, a
blocked prompt would.

CLOUTER_VISUAL=0 disables the hook. CLOUTER_VISUAL_FLOOR moves
the confidence floor (0.5), CLOUTER_VISUAL_MULTI the probability from
which a further modality counts as requested (0.3). Stdlib only, through
lib/ and catalogue.py.
"""

import concurrent.futures
import json
import os
import re
import shlex
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# The interpreter name the injected commands use: a standard Windows
# install has python and py, no python3.
PY = "python" if os.name == "nt" else "python3"
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, HERE)
from lib import jev, keys  # noqa: E402
import catalogue  # noqa: E402
import ranking  # noqa: E402

PREFILTER = re.compile(
    r"\b(image|images|pictures|illustration|illustrations|logo|logos|icon|icons|"
    r"svg|vector|banner|banners|poster|posters|video|videos|clip|clips|"
    r"animation|animations|voice|voices|speech|narrate|narration|tts|audio|"
    r"artwork|graphic|graphics)\b"
    # phrase-restricted: bare "picture"/"render" alone are too common outside
    # visual requests ("the big picture", "React render loop"), so these two
    # only count with the words that actually ask for a new file.
    r"|\bpictures?\s+of\b"
    r"|\brender(?:ing)?\s+(?:a|an|me|us|this)\b",
    re.IGNORECASE,
)
SYSTEM_EVENT = re.compile(r"^\s*<(task-notification|system-reminder)\b")
# A prompt that asks for a real alpha channel: prefer catalogue.has_alpha
# raster models over ones that only paint a fake checkerboard, and tell
# Claude to run generate.py with --transparent.
TRANSPARENT = re.compile(r"\btransparen(t|cy)\b|\balpha\b|dark and light", re.IGNORECASE)
MODALITIES = {
    "text_or_code": "Prose, code, data, a diagram in text, or anything Claude writes itself; "
                    "also questions about images or videos that need no new file made.",
    "raster_image": "A new picture as pixels: photo, painting, render, banner, poster, "
                    "icon or logo as PNG or JPEG.",
    "vector_svg": "A new drawing as vectors: an SVG, a scalable logo or icon, a vector "
                  "illustration, line art meant to scale.",
    "video": "A new video or animated clip.",
    "speech": "Spoken audio from text: narration, a voice-over, text-to-speech.",
}
VISUAL = [m for m in MODALITIES if m != "text_or_code"]
HEADERS = {"raster_image": "Image model", "vector_svg": "SVG model",
           "video": "Video model", "speech": "Speech model"}  # AskUserQuestion caps at 12
DEADLINE = 9.0
CALL_TIMEOUT = 2.5
CANDIDATES = 6
SHOWN = 3


def budget(started):
    return min(CALL_TIMEOUT, DEADLINE - (time.monotonic() - started))


def options(ranked, recommended):
    lines = []
    for i, entry in enumerate(ranked, 1):
        tag = " (Recommended)" if entry is recommended else ""
        lines.append(
            f"{i}. {entry['id']}{tag} — {entry['name']}, {ranking.price_label(entry)}, "
            f"Jev {entry['probability']:.2f}"
        )
    lines.append(f"{len(ranked) + 1}. Stay with Claude — no OpenRouter call, Claude writes or "
                 "describes it by hand.")
    return lines


def write_request_file(prompt):
    """The raw user prompt written verbatim to a fresh temp file, so a
    suggested generate.py command can carry --request-file. None on any
    write failure: the flag is then dropped silently, never blocking the
    hook."""
    try:
        tmp_dir = tempfile.mkdtemp(prefix="clouter-request-")
        path = os.path.join(tmp_dir, "request.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(prompt)
        return path
    except OSError:
        return None


def context(prompt, picks, transparent=False, request_path=None):
    """picks: [(modality, ranked, recommended)], likeliest modality first."""
    generate = os.path.join(HERE, "generate.py")
    critique = os.path.join(HERE, "critique.py")
    studio = os.path.join(HERE, "studio.py")
    request_flag = f" --request-file {shlex.quote(request_path)}" if request_path else ""

    def command(modality):
        extra = " --transparent" if transparent and modality == "raster_image" else ""
        return (f"{PY} \"{generate}\" --model <chosen id> --modality {modality} "
                f"--prompt-file <path to the design brief>{extra}{request_flag} --no-critique "
                "[--out <path named in the prompt>]")

    def studio_steps(modality):
        """The push+wait tail after generate.py: judge-only suggest for raster/vector,
        then push the round into the studio and wait for the user, in the background.
        The loop itself (feedback vs accept vs timeout vs server gone) lives in SKILL.md,
        not here."""
        visual = modality in ("raster_image", "vector_svg")
        suggest = (f"; {PY} \"{critique}\" <file> --prompt-file <path to the design brief> "
                   "--suggest --model <chosen id> --out <defects.json>") if visual else ""
        defects = " --defects-file <defects.json>" if visual else ""
        push = (f"{PY} \"{studio}\" push --session <dir> --file <file> --model <chosen id> --cost <cost> "
                f"--brief-file <path to the design brief> --request-file <path> "
                f"--modality {modality}{defects} [--message-file <note>]")
        return (f"{suggest}; then {push}; then `studio.py wait --session <dir>` in the "
                "background and follow the \"Studio loop\" section of SKILL.md")

    def studio_steps_generic():
        """Same tail as studio_steps(), worded for the multi-format block where the
        modality varies per question rather than being known up front."""
        return (f"; for raster_image/vector_svg formats also run {PY} \"{critique}\" "
                "<file> --prompt-file <brief> --suggest --model <chosen id> --out <defects.json>; then run "
                f"{PY} \"{studio}\" push --session <dir> --file <file> --model <chosen id> --cost <cost> "
                "--brief-file <brief> --request-file <path> --modality <its --modality> "
                "(--defects-file <defects.json> for raster/vector) [--message-file <note>]; then run `studio.py wait "
                "--session <dir>` per push in the background and follow the \"Studio loop\" "
                "section of SKILL.md")

    interview = os.path.join(HERE, "interview.py")
    ask_note = (f"Ask every question in the studio page, not the terminal (\"Asking the user\" in "
                f"SKILL.md): write it as AskUserQuestion-shaped JSON, run {PY} \"{studio}\" ask "
                f"--questions-file <q.json>{request_flag} --modality <modality> (later calls add "
                "--session <dir> instead, and so does every push), tell the user the url once, "
                f"then `studio.py wait --session <dir>` in the background for the answers. Only "
                "when ask exits non-zero, ask with AskUserQuestion in the terminal.")

    def interview_instruction(modality):
        return (f"Before anything else, run the interview (\"Interview\" in SKILL.md): fill a "
                f"brief JSON for {modality} from the request and the repo, keeping the user's own "
                f"words (slots: {PY} \"{interview}\" slots {modality}), run {PY} "
                f"\"{interview}\" gaps --brief <brief.json>, and ask every question it lists in "
                "one question set, your inferred value first and marked Recommended; "
                "none listed means no interview. If an answer lands on a slot in its "
                f"rerank_if_answered, run {PY} \"{interview}\" rank --brief <brief.json> and "
                "offer its options in place of the list below.")

    brief_instruction = (
        f"compile the brief: {PY} \"{interview}\" compile --brief <brief.json> --out "
        "<path to the design brief> --remember, and add the flags it prints to the command."
    )

    if len(picks) == 1:
        modality, ranked, recommended = picks[0]
        lines = [
            f"[clouter visual] This prompt asks for a {modality.replace('_', ' ')}, which an "
            f"OpenRouter model can make for a few cents. {ask_note} "
            f"{interview_instruction(modality)} Then ask (one question, header \"Model\") "
            "which model should make it, options in exactly this order and wording:",
        ]
        lines += options(ranked, recommended)
        lines.append(
            f"On a model choice, {brief_instruction} Then: run {command(modality)}"
            f"{studio_steps(modality)}. On \"Stay with Claude\" carry on as usual. "
            "Do not ask twice for the same prompt."
        )
        return "\n".join(lines)
    names = " and a ".join(m.replace("_", " ") for m, _, _ in picks)
    lines = [
        f"[clouter visual] This prompt asks for a {names}, which OpenRouter models can make for "
        f"a few cents each. {ask_note} "
        f"{interview_instruction('each format, one brief per format')} Keep "
        "the interview to one question set of at most 4 questions in all (gaps --max splits "
        f"them). Then ask with one question set holding {len(picks)} questions, one per "
        "format, which model should make each, options in exactly this order and wording:",
    ]
    for modality, ranked, recommended in picks:
        lines.append(f"Question with header \"{HEADERS[modality]}\" (--modality {modality}):")
        lines += options(ranked, recommended)
    raster_hint = (" (--transparent on the raster_image run)"
                   if transparent and any(m == "raster_image" for m, _, _ in picks) else "")
    lines.append(
        f"For every question answered with a model, {brief_instruction} Then, per format: run "
        f"{command('<its --modality>')}{raster_hint}, one run per format, each with its own "
        f"--out when the prompt names paths{studio_steps_generic()}. A question answered "
        "\"Stay with Claude\" means Claude makes that format by hand. "
        "Do not ask twice for the same prompt."
    )
    return "\n".join(lines)


def emit(text):
    json.dump({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                      "additionalContext": text}}, sys.stdout)
    print()


def requested(answer, floor, multi):
    """The visual modalities the prompt asks for, likeliest first; [] means silence."""
    probabilities = answer.get("probabilities")
    if isinstance(probabilities, dict) and any(m in probabilities for m in VISUAL):
        p = {m: float(probabilities.get(m) or 0.0) for m in VISUAL}
        if sum(p.values()) < floor:
            return []
        ranked = sorted(VISUAL, key=lambda m: -p[m])
        return [ranked[0]] + [m for m in ranked[1:] if p[m] >= multi]
    modality = answer.get("choice")  # no per-option probabilities: the single-choice rule
    if modality not in VISUAL or float(answer.get("confidence") or 0.0) < floor:
        return []
    return [modality]


def pick_models(prompt, modality, floor, started, transparent=False):
    """(modality, ranked, recommended) for one modality, or None without candidates."""
    entries = [e for e in catalogue.models(modality, timeout=budget(started))
               if e["price"] is not None and not e["reference_required"]]
    if transparent and modality == "raster_image":
        alpha_entries = [e for e in entries if e.get("alpha")]
        if alpha_entries:  # keep the fake-checkerboard models out only if a real one remains
            entries = alpha_entries
    entries = entries[:CANDIDATES]
    if not entries:
        return None
    ranked, recommended = ranking.rank_models(
        entries,
        {"prompt": prompt, "modality": modality},
        "Which model should make what the prompt asks for? Weigh fit to the prompt "
        "against price; the cheapest model that can do it well wins.",
        floor,
        budget(started),
    )
    return modality, ranked[:SHOWN], recommended


def route(prompt, started):
    floor = float(os.environ.get("CLOUTER_VISUAL_FLOOR", "0.5"))
    multi = float(os.environ.get("CLOUTER_VISUAL_MULTI", "0.3"))
    answer = jev.decide(
        {"prompt": prompt},
        {"modality": jev.choice(
            "What does the user ask to be produced? Pick text_or_code unless the prompt "
            "clearly asks for a new image, drawing, video or spoken audio file.",
            MODALITIES)},
        timeout=budget(started),
    )["answers"]["modality"]
    modalities = requested(answer, floor, multi)
    if not modalities:
        return None
    transparent = bool(TRANSPARENT.search(prompt))

    # One thread per modality, each call still capped by budget(); a modality
    # whose catalogue or Jev call fails drops out, the others still get asked.
    picks = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(modalities)) as pool:
        futures = [pool.submit(pick_models, prompt, m, floor, started, transparent) for m in modalities]
        for modality, future in zip(modalities, futures):
            try:
                pick = future.result()
            except Exception as e:
                print(f"clouter visual: {modality}: {type(e).__name__}: {e}", file=sys.stderr)
                continue
            if pick:
                picks.append(pick)
    if not picks:
        return None
    return context(prompt, picks, transparent, write_request_file(prompt))


def main():
    if os.environ.get("CLOUTER_VISUAL", "1").lower() in ("0", "off", "false"):
        return 0
    started = time.monotonic()
    try:
        payload = json.load(sys.stdin)
        prompt = payload.get("prompt") if isinstance(payload, dict) else None
    except ValueError:
        return 0
    if not isinstance(prompt, str) or SYSTEM_EVENT.match(prompt):
        return 0
    if not PREFILTER.search(prompt):
        return 0
    try:
        if not keys.find("OPENROUTER_API_KEY"):
            emit("[clouter visual] This prompt may ask for an image, video or speech file, which "
                 "an OpenRouter model could make, but no OpenRouter key is stored. Ask once with "
                 "AskUserQuestion whether to store one now or carry on without; \"without\" only "
                 "means no nudge on ordinary prompts this session — offer again once if the user "
                 "later explicitly asks to generate a file, or if generate.py or critique.py "
                 "exits 3. To store one, run " + PY + " \"" + os.path.join(HERE, "setup-key.py") +
                 "\" in the background and show the user both links from its stderr JSON line: "
                 "the url to open, and the paste_url for a machine the browser can't reach "
                 "(WSL2, remote). /clouter:visual setup does the same later.")
            return 0
        text = route(prompt, started)
        if text:
            emit(text)
    except Exception as e:  # a routing miss must never block a prompt
        print(f"clouter visual: {type(e).__name__}: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

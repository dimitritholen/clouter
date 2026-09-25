#!/usr/bin/env python3
"""The interview before a generation: which details a request still lacks.

    $ interview.py slots <modality>                    # the slot schema, JSON
    $ interview.py gaps --brief brief.json [--max 4]    # what to ask, JSON
    $ interview.py compile --brief brief.json --out prompt.txt [--remember]
    $ interview.py rank --brief brief.json              # re-rank models on the brief

A brief is a JSON file Claude writes from the user's request:

    {"modality": "raster_image",
     "slots": {"subject": {"value": "a fox reading a book", "source": "given"},
               "palette": {"value": "#0d1117, #58a6ff", "source": "inferred"}}}

A slot's source is given (the user said it), inferred (Claude guessed it
from the request or the repo), answered (the user picked it in the
interview) or remembered (from an earlier request in this project). A
plain string stands for {"value": <string>, "source": "given"}.

gaps merges remembered values into empty slots, then lists what to ask:
empty slots that carry weight, and inferred values that are risky to get
wrong (colours, text in the picture; an inferred "none" is not), slots that change the model choice
first, at most --max (4, AskUserQuestion's own cap). An empty list means
no interview: the request already says enough.

compile turns the filled slots into the prompt text generate.py sends,
shaped per modality (a design brief for pictures, a shot description for
video, the script alone for speech), and prints the generate.py flags and
the spec fields the slots settle. --remember stores the durable slots the
user gave or answered (palette, style, voice) for the project, so the next
request in it asks less. The store is prefs.json next to the credentials,
or CLOUTER_PREFS (a full file path).

rank re-ranks the catalogue on the compiled brief instead of the raw
prompt, through route.py's own ranking, for when an answer changed what
the model has to be able to do. Stdlib only, through lib/ and the files
next to it.
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, HERE)
from lib import keys  # noqa: E402
import learned  # noqa: E402

MODALITIES = ("raster_image", "vector_svg", "video", "speech")
SOURCES = ("given", "inferred", "answered", "remembered")
MAX_QUESTIONS = 4


def slot(name, header, question, weight="low", options=(), required=False, risky=False,
         rank=False, cost=False, durable=None):
    """durable: None, "shared" (one value across modalities, like a brand
    palette) or "modality" (one value per modality, like a style)."""
    return {"name": name, "header": header, "question": question, "weight": weight,
            "options": list(options), "required": required, "risky": risky, "rank": rank,
            "cost": cost, "durable": durable}


PICTURE_COMMON = [
    slot("subject", "Subject", "What should it show?", "high", required=True),
    slot("use", "Used for", "Where will it be used?", "high",
         ["GitHub README header", "App or favicon icon", "Social card", "Slide or document"]),
    slot("palette", "Colours", "Which colours?", "high",
         ["Brand colours from the repo", "Monochrome", "Vivid", "Muted pastel"],
         risky=True, durable="shared"),
    slot("text", "Text", "Should any text appear in it, and exactly which?", "high",
         ["No text", "Only the project name"], risky=True, rank=True),
    slot("composition", "Layout", "What is the focal point, and how is it framed?"),
]
SLOTS = {
    "raster_image": PICTURE_COMMON + [
        slot("style", "Style", "Which visual style?", "high",
             ["Flat illustration", "Photo-realistic", "3D render", "Hand-drawn"],
             durable="modality"),
        slot("background", "Background", "What sits behind the subject?", "high",
             ["Transparent", "Solid colour", "Full scene"], rank=True),
        slot("aspect", "Aspect", "Which aspect ratio?", options=["1:1", "16:9", "4:3", "9:16"]),
        slot("quality", "Quality", "Standard or high resolution (costs more)?",
             options=["Standard", "High resolution"], cost=True),
    ],
    "vector_svg": PICTURE_COMMON + [
        slot("style", "Style", "Which vector style?", "high",
             ["Flat shapes", "Line art", "Outline icon", "Geometric"], durable="modality"),
        slot("detail", "Detail", "How much detail?", options=["Minimal", "Moderate", "Detailed"]),
        slot("aspect", "Aspect", "Which aspect ratio?", options=["1:1", "16:9", "4:3"]),
    ],
    "video": [
        slot("subject", "Subject", "Who or what is in the shot?", "high", required=True),
        slot("action", "Action", "What happens during the clip?", "high"),
        slot("camera", "Camera", "How does the camera move?", "high",
             ["Static", "Slow push in", "Pan", "Handheld"]),
        slot("setting", "Setting", "Where is it, and what is the light like?", "high"),
        slot("style", "Style", "Which look?", options=["Cinematic", "Animated", "Documentary"],
             durable="modality"),
        slot("palette", "Colours", "Which colours?", risky=True, durable="shared"),
        slot("duration", "Duration", "How many seconds (billed per second)?", "high",
             ["4", "6", "8"], cost=True),
        slot("audio", "Audio", "Should it have sound, and which (costs more)?",
             options=["No sound", "Ambient sound", "Music"], cost=True),
        slot("aspect", "Aspect", "Which aspect ratio?", options=["16:9", "9:16", "1:1"]),
    ],
    "speech": [
        slot("script", "Script", "What exactly should be said?", "high", required=True, risky=True),
        slot("voice", "Voice", "Which kind of voice?", "high",
             ["Warm female", "Calm male", "Neutral"], durable="modality"),
        slot("tone", "Tone", "Which tone?", "high",
             ["Friendly", "Energetic", "Calm and serious"], durable="modality"),
        slot("pace", "Pace", "How fast?", options=["Slow", "Normal", "Brisk"]),
        slot("pronunciation", "Pronounce", "Any names or acronyms with a set pronunciation?",
             risky=True),
    ],
}
EMPTY = {"", "none", "no", "n/a", "no text", "no sound", "nothing"}


class BriefError(ValueError):
    pass


def schema(modality):
    return {s["name"]: s for s in SLOTS[modality]}


def load_brief(path):
    """{"modality", "slots": {name: {"value", "source"}}}, normalised; BriefError on a bad file."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise BriefError(f"cannot read brief {path}: {e}") from e
    modality = data.get("modality") if isinstance(data, dict) else None
    if modality not in MODALITIES:
        raise BriefError(f"brief needs a modality, one of {', '.join(MODALITIES)}")
    known = schema(modality)
    slots = {}
    for name, entry in (data.get("slots") or {}).items():
        if name not in known:
            raise BriefError(f"unknown slot {name!r} for {modality}; known: {', '.join(known)}")
        if not isinstance(entry, dict):
            entry = {"value": entry, "source": "given"}
        source = entry.get("source", "given")
        if source not in SOURCES:
            raise BriefError(f"slot {name!r}: source must be one of {', '.join(SOURCES)}")
        value = entry.get("value")
        slots[name] = {"value": "" if value is None else str(value).strip(), "source": source}
    return {"modality": modality, "slots": slots}


def filled(brief, name):
    entry = brief["slots"].get(name)
    return bool(entry and entry["value"])


def meaningful(brief, name):
    """The slot's value, or "" when empty or a spelled-out nothing ("none", "no text")."""
    entry = brief["slots"].get(name)
    value = entry["value"] if entry else ""
    return "" if value.lower() in EMPTY else value


# --- remembered preferences ---

def prefs_path():
    return os.path.expanduser(keys.env("CLOUTER_PREFS")
                              or os.path.join(os.path.dirname(keys.path()), "prefs.json"))


def _prefs_read():
    try:
        with open(prefs_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _pref_key(modality, s):
    return s["name"] if s["durable"] == "shared" else f"{modality}.{s['name']}"


def remembered(modality, project):
    """{slot name: value} stored for this project and modality."""
    entry = _prefs_read().get(project)
    if not isinstance(entry, dict):
        return {}
    out = {}
    for s in SLOTS[modality]:
        if s["durable"]:
            pick = entry.get(_pref_key(modality, s))
            if isinstance(pick, dict) and pick.get("value"):
                out[s["name"]] = str(pick["value"])
    return out


def merge_remembered(brief, project):
    """Fill empty durable slots from the store; returns the names filled."""
    used = []
    for name, value in remembered(brief["modality"], project).items():
        if not filled(brief, name):
            brief["slots"][name] = {"value": value, "source": "remembered"}
            used.append(name)
    return used


def remember(brief, project):
    """Store the durable slots the user gave or answered. Never raises."""
    data = _prefs_read()
    entry = data.get(project) if isinstance(data.get(project), dict) else {}
    seen = datetime.now(timezone.utc).strftime(learned.TS_FORMAT)
    stored = []
    for s in SLOTS[brief["modality"]]:
        slot_entry = brief["slots"].get(s["name"])
        if s["durable"] and slot_entry and slot_entry["value"] \
                and slot_entry["source"] in ("given", "answered"):
            entry[_pref_key(brief["modality"], s)] = {"value": slot_entry["value"], "seen": seen}
            stored.append(s["name"])
    if stored:
        data[project] = entry
        learned._write(data, prefs_path(), "the remembered preferences")
    return stored


# --- gaps ---

def gaps(brief, limit=MAX_QUESTIONS):
    """The questions to ask, slots that change the model choice first."""
    asks = []
    for s in SLOTS[brief["modality"]]:
        entry = brief["slots"].get(s["name"])
        if not filled(brief, s["name"]):
            if s["weight"] == "high":
                asks.append((s, None))
        elif entry["source"] == "inferred" and s["risky"] and meaningful(brief, s["name"]):
            asks.append((s, entry["value"]))  # an inferred "none" needs no confirming
    order = {"required": 0, "rank": 1, "missing": 2, "confirm": 3}

    def priority(item):
        s, inferred = item
        if s["required"]:
            return order["required"]
        if s["rank"]:
            return order["rank"]
        return order["confirm"] if inferred is not None else order["missing"]

    asks.sort(key=priority)  # stable: schema order within a group
    return [{"slot": s["name"], "header": s["header"], "question": s["question"],
             "options": s["options"], "inferred": inferred, "rank": s["rank"], "cost": s["cost"]}
            for s, inferred in asks[:max(0, limit)]]


# --- compile ---

def sentence(text):
    text = text.strip()
    return text if not text or text[-1] in ".!?" else text + "."


def picture_prompt(brief):
    v = lambda name: meaningful(brief, name)  # noqa: E731
    parts = [sentence(v("subject"))]
    if v("composition"):
        parts.append(sentence(v("composition")))
    if v("detail"):
        parts.append(sentence(f"Level of detail: {v('detail')}"))
    if v("style"):
        parts.append(sentence(f"Style: {v('style')}"))
    if v("palette"):
        parts.append(sentence(f"Colours: {v('palette')}"))
    if v("background"):
        parts.append(sentence(f"Background: {v('background')}"))
    if v("text"):
        parts.append(f"The only text in the image reads exactly \"{v('text').strip(chr(34))}\", "
                     "spelled as given.")
    if v("use"):
        parts.append(sentence(f"Made for: {v('use')}"))
    return "\n".join(parts)


def video_prompt(brief):
    v = lambda name: meaningful(brief, name)  # noqa: E731
    lines = [f"{label}: {v(name)}" for label, name in (
        ("Subject", "subject"), ("Action", "action"), ("Camera", "camera"),
        ("Setting and lighting", "setting"), ("Style", "style"), ("Colours", "palette"),
        ("Sound", "audio")) if v(name)]
    return "\n".join(lines)


def compile_brief(brief):
    """(prompt text, generate.py flags, spec hints) from the filled slots."""
    modality = brief["modality"]
    v = lambda name: meaningful(brief, name)  # noqa: E731
    flags, hints = [], {}
    if modality in ("raster_image", "vector_svg"):
        prompt = picture_prompt(brief)
        if modality == "raster_image" and re.search(r"transparen", v("background"), re.I):
            flags.append("--transparent")
        if v("quality"):
            hints["resolution/size"] = v("quality")
    elif modality == "video":
        prompt = video_prompt(brief)
        seconds = re.search(r"\d+", v("duration"))
        if seconds:
            flags += ["--duration", seconds.group()]
        if filled(brief, "audio"):
            hints["generate_audio"] = bool(v("audio"))
    else:
        prompt = v("script")
        if v("voice"):
            hints["voice"] = f"pick the spec's voice closest to: {v('voice')}"
        direction = "; ".join(f"{label}: {v(name)}" for label, name in (
            ("Tone", "tone"), ("Pace", "pace"), ("Pronunciation", "pronunciation")) if v(name))
        if direction:
            hints["instructions"] = direction
    if v("aspect") and modality != "speech":
        flags += ["--aspect", v("aspect")]
    return prompt, flags, hints


def missing_required(brief):
    return [s["name"] for s in SLOTS[brief["modality"]] if s["required"] and not meaningful(brief, s["name"])]


# --- commands ---

def cmd_slots(args):
    print(json.dumps(SLOTS[args.modality], indent=1))
    return 0


def cmd_gaps(args):
    brief = load_brief(args.brief)
    used = merge_remembered(brief, args.project)
    asks = gaps(brief, args.max)
    print(json.dumps({"ask": asks, "remembered": {n: brief["slots"][n]["value"] for n in used},
                      "rerank_if_answered": [a["slot"] for a in asks if a["rank"]]}))
    return 0


def cmd_compile(args):
    brief = load_brief(args.brief)
    used = merge_remembered(brief, args.project)
    missing = missing_required(brief)
    if missing:
        print(f"interview: required slot empty: {', '.join(missing)}", file=sys.stderr)
        return 2
    prompt, flags, hints = compile_brief(brief)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(prompt + "\n")
    stored = remember(brief, args.project) if args.remember else []
    print(json.dumps({"prompt_file": args.out, "flags": flags, "spec_hints": hints,
                      "remembered": used, "stored": stored}))
    return 0


def cmd_rank(args):
    import route  # the hook's own ranking, run on the brief instead of the raw prompt
    brief = load_brief(args.brief)
    merge_remembered(brief, args.project)
    prompt, flags, _ = compile_brief(brief)
    floor = float(os.environ.get("CLOUTER_VISUAL_FLOOR", "0.5"))
    try:
        pick = route.pick_models(prompt, brief["modality"], floor, time.monotonic(),
                                 "--transparent" in flags)
    except Exception as e:  # noqa: BLE001 - the hook's list still stands
        print(f"interview: ranking failed, keep the hook's list: {type(e).__name__}: {e}",
              file=sys.stderr)
        return 1
    if not pick:
        print("interview: no priced candidates, keep the hook's list", file=sys.stderr)
        return 1
    modality, ranked, recommended = pick
    print(json.dumps({"modality": modality, "options": route.options(ranked, recommended),
                      "recommended": recommended["id"] if recommended else None}))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="The interview before a generation.")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("slots")
    p.add_argument("modality", choices=MODALITIES)
    for name in ("gaps", "compile", "rank"):
        p = sub.add_parser(name)
        p.add_argument("--brief", required=True)
        p.add_argument("--project", default=os.getcwd(),
                       help="project directory the remembered preferences belong to (default cwd)")
        if name == "gaps":
            p.add_argument("--max", type=int, default=MAX_QUESTIONS)
        if name == "compile":
            p.add_argument("--out", required=True)
            p.add_argument("--remember", action="store_true")
    args = parser.parse_args(argv[1:])
    if getattr(args, "project", None):
        args.project = os.path.realpath(args.project)
    try:
        return {"slots": cmd_slots, "gaps": cmd_gaps, "compile": cmd_compile,
                "rank": cmd_rank}[args.command](args)
    except BriefError as e:
        print(f"interview: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

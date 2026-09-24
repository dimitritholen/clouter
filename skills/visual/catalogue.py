#!/usr/bin/env python3
"""OpenRouter's generation models per modality, with one price each.

    from skills.visual import catalogue   # or import catalogue next to it
    for m in catalogue.models("vector_svg"):
        m["id"], m["name"], m["description"], m["price"], m["unit"], m["vector"],
        m["reference_required"],  # needs a reference image, useless for a bare prompt
        m["alpha"],   # raster only: --transparent gives a real alpha channel on this model
        m["reference_supported"]  # raster/vector: --reference works on this model

Modalities: raster_image, vector_svg (both from GET /api/v1/models
?output_modalities=image, split on the vector flag), video (GET
/api/v1/videos/models) and speech (?output_modalities=speech). Live on
every call: a routed prompt is rare and a live list never shows stale
prices. Sorted cheap to expensive within a unit; unpriced entries last.

Price units, as OpenRouter bills them (docs/guides/community/for-providers,
models.mdx): image models charge per image output token (`image_output`,
USD; a picture is on the order of a thousand to four thousand tokens,
model-dependent), speech models per input character (`prompt`), video
models per output second (`duration_seconds*`, `cents_per_second*` in
cents) or, for a few, per video token (`video_tokens*`). For a video model
with several SKUs the lowest one is taken, as OpenRouter's own cookbook
does. Stdlib only. OPENROUTER_BASE_URL redirects the API.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from lib import keys  # noqa: E402

MODALITIES = ("raster_image", "vector_svg", "video", "speech")
VECTOR = re.compile(r"\b(vector|svg)\b", re.IGNORECASE)
# Models that cannot work from a bare prompt (Recraft "Styles" need a style
# reference image on every request); the router skips them.
REFERENCE_REQUIRED = re.compile(r"requires at least one (style|reference)", re.IGNORECASE)
# Models that accept /api/v1/images' background: "transparent" and return a
# real alpha channel. OpenRouter's own listing wins when a model publishes
# "background" in supported_parameters; most raster models don't publish
# that field yet, so an explicit allowlist backs the ones verified live
# (2026-09-22: openai/gpt-5-image-mini gave a real RGBA PNG). Diffusion
# models such as FLUX.2 Klein, Krea and Muse only paint a fake checkerboard
# and are deliberately left out.
ALPHA_ALLOWLIST = re.compile(r"^openai/gpt-.*image", re.IGNORECASE)


def has_alpha(model_id, supported_parameters=None):
    """Whether a raster model's images endpoint gives a real alpha channel.

    supported_parameters naming "background" is a positive signal, never a
    negative one: most models don't publish it yet, so its absence must not
    override a model the allowlist already verified live."""
    if isinstance(supported_parameters, list) and "background" in supported_parameters:
        return True
    return bool(ALPHA_ALLOWLIST.search(model_id or ""))


def _input_modalities(model):
    return (model.get("architecture") or {}).get("input_modalities") or []


def reference_supported(model_id, input_modalities=None):
    """Whether model_id takes a reference image alongside the prompt:
    "image" in its architecture.input_modalities from /api/v1/models.

    Pass input_modalities when already known, as _image_entry does for the
    per-entry field below; called with just a model id (generate.py's
    --reference guard, before any spend) it fetches that live listing
    itself and looks the model up there. False for a model not in that
    listing. Raises CatalogueError only when it must fetch and the fetch
    fails."""
    if input_modalities is None:
        for model in _get("/api/v1/models?output_modalities=image", 10.0):
            if model.get("id") == model_id:
                input_modalities = _input_modalities(model)
                break
        else:
            return False
    return "image" in input_modalities


class CatalogueError(Exception):
    pass


def _get(path, timeout):
    headers = {"Accept": "application/json"}
    key = keys.find("OPENROUTER_API_KEY")
    if key:
        headers["Authorization"] = f"Bearer {key}"
    base = (os.environ.get("OPENROUTER_BASE_URL") or "https://openrouter.ai").rstrip("/")
    request = urllib.request.Request(base + path, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise CatalogueError(f"GET {path} answered {e.code}") from e
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise CatalogueError(f"GET {path} failed: {e}") from e
    data = body.get("data") if isinstance(body, dict) else None
    if not isinstance(data, list):
        raise CatalogueError(f"GET {path} answered without a data list")
    return data


def _number(value):
    try:
        n = float(value)
    except (TypeError, ValueError):
        return None
    return n if n >= 0 else None


def _entry(model, price, unit, alpha=None, reference_supported=None):
    text = f"{model.get('id', '')} {model.get('name', '')} {model.get('description', '')}"
    return {
        "id": model.get("id"),
        "name": model.get("name") or model.get("id"),
        "description": (model.get("description") or "").strip(),
        "price": price,
        "unit": unit,
        "vector": bool(VECTOR.search(text)),
        "reference_required": bool(REFERENCE_REQUIRED.search(model.get("description") or "")),
        **({"alpha": alpha} if alpha is not None else {}),
        **({"reference_supported": reference_supported} if reference_supported is not None else {}),
    }


def _image_entry(model):
    pricing = model.get("pricing") or {}
    alpha = has_alpha(model.get("id"), model.get("supported_parameters"))
    ref = reference_supported(model.get("id"), _input_modalities(model))
    return _entry(model, _number(pricing.get("image_output")), "image token", alpha=alpha, reference_supported=ref)


def _speech_entry(model):
    pricing = model.get("pricing") or {}
    return _entry(model, _number(pricing.get("prompt")), "character")


def _video_entry(model):
    """The lowest per-second SKU in USD; per video token when that is all
    the model publishes; megapixel-seconds for upscalers."""
    skus = model.get("pricing_skus") or {}
    per_second, per_token, per_mp_second = [], [], []
    for name, raw in skus.items():
        value = _number(raw)
        if value is None:
            continue
        if "megapixel" in name:
            per_mp_second.append(value / 100 if name.startswith("cents") else value)
        elif "second" in name:
            per_second.append(value / 100 if name.startswith("cents") else value)
        elif name.startswith("video_tokens"):
            per_token.append(value)
    if per_second:
        return _entry(model, min(per_second), "second")
    if per_token:
        return _entry(model, min(per_token), "video token")
    if per_mp_second:
        return _entry(model, min(per_mp_second), "megapixel second")
    return _entry(model, None, "second")


UNIT_RANK = {"image token": 0, "character": 0, "second": 0, "video token": 1, "megapixel second": 2}


def _sorted(entries):
    return sorted(entries, key=lambda e: (e["price"] is None, UNIT_RANK.get(e["unit"], 9),
                                          e["price"] if e["price"] is not None else 0.0, e["id"] or ""))


def models(modality, timeout=10.0):
    """The models of one modality, cheapest first. Raises CatalogueError."""
    if modality not in MODALITIES:
        raise ValueError(f"modality must be one of {MODALITIES}, not {modality!r}")
    if modality in ("raster_image", "vector_svg"):
        want_vector = modality == "vector_svg"
        entries = [_image_entry(m) for m in _get("/api/v1/models?output_modalities=image", timeout)]
        return _sorted([e for e in entries if e["vector"] == want_vector])
    if modality == "video":
        return _sorted([_video_entry(m) for m in _get("/api/v1/videos/models", timeout)])
    return _sorted([_speech_entry(m) for m in _get("/api/v1/models?output_modalities=speech", timeout)])


def main(argv):
    """`catalogue.py <modality> [limit]` prints the list as JSON, for a look."""
    if len(argv) < 2 or argv[1] not in MODALITIES:
        print(f"usage: catalogue.py {{{'|'.join(MODALITIES)}}} [limit]", file=sys.stderr)
        return 2
    limit = int(argv[2]) if len(argv) > 2 else None
    try:
        found = models(argv[1])
    except CatalogueError as e:
        print(f"catalogue: {e}", file=sys.stderr)
        return 4
    json.dump(found[:limit], sys.stdout, indent=1)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

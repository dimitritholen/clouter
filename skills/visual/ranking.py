#!/usr/bin/env python3
"""Shared Jev-ranking helpers for route.py and critique.py: turn a list of
catalogue entries into a Jev Choice question, and read back a ranked list
with per-entry probabilities and an optional recommended pick.

    from ranking import price_label, criterion, rank_models
    ranked, recommended = rank_models(entries, state, question, floor, timeout)

entries must be catalogue.py entries (at least id, name, description, price,
unit); each gets a "probability" field set from Jev's answer. recommended is
the entry Jev picked, or None when its own confidence is under floor (ranked
then keeps the original, cheapest-first order). Stdlib only, through
lib/jev.py.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))
from lib import jev  # noqa: E402


def price_label(entry):
    price, unit = entry["price"], entry["unit"]
    if unit in ("image token", "character", "video token"):
        return f"${price * 1000:.4f} per 1K {unit}s"
    return f"${price:.3f} per {unit}"


def criterion(entry):
    description = re.sub(r"\s+", " ", entry["description"])[:240]
    return f"{entry['name']}: {description} Price {price_label(entry)}."


def rank_models(entries, state, question, floor, timeout):
    """Ask Jev one Choice question over entries (each needs an 'id').
    Returns (ranked, recommended): every entry in ranked also carries the
    'probability' Jev gave it. Raises jev.JevError, keys.MissingKey/
    UnsafeFile."""
    by_id = {e["id"]: e for e in entries}
    answer = jev.decide(
        state,
        {"model": jev.choice(question, {e["id"]: criterion(e) for e in entries})},
        timeout=timeout,
    )["answers"]["model"]
    probabilities = answer.get("probabilities") or {}
    for e in entries:
        e["probability"] = float(probabilities.get(e["id"], 0.0))
    recommended = by_id.get(answer.get("choice"))
    if recommended is None or float(answer.get("confidence") or 0.0) < floor:
        recommended = None
    ranked = ([recommended] if recommended else []) + [e for e in entries if e is not recommended]
    return ranked, recommended

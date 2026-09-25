#!/usr/bin/env python3
"""What a provider proved live about a model, remembered across runs.

    import learned
    learned.preferred("google/gemini-3.8-flash-tts", "response_format")  # "pcm" or None
    learned.rejected("google/gemini-3.8-flash-tts", "response_format")   # {"mp3": "2026-09-24T..."}
    learned.record_prefer(model, "response_format", "pcm")
    learned.record_reject(model, "response_format", "mp3")

A model's llms.txt can be wrong (gemini-3.8-flash-tts lists mp3, the
provider 400s on it). generate.py records only what its own fallbacks
prove against the live API -- the mp3 -> pcm speech retry and the image
chat/completions 404 -> /api/v1/images fallback -- never rules parsed out
of arbitrary error text. The next request then goes right the first time,
and spec.load() drops rejected values from a field's enum.

The file is ~/.config/clouter/learned.json next to the credentials
(lib/keys.path()'s directory), or CLOUTER_LEARNED (a full file path):

    {"<model>": {"prefer": {"<field>": {"value": <v>, "seen": "<iso8601 UTC>"}},
                 "rejected": {"<field>": {"<json-encoded value>": "<iso8601 UTC>"}}}}

Entries older than MAX_AGE_DAYS are ignored on read and pruned on write,
so a provider that fixes itself is retried within a month. A missing,
unreadable or corrupt file reads as empty; a failed write is one stderr
warning. Learning never raises: it must never break a generation.
Stdlib only.
"""

import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)
from lib import keys  # noqa: E402

MAX_AGE_DAYS = 30
TS_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


def path():
    return os.path.expanduser(keys.env("CLOUTER_LEARNED")
                              or os.path.join(os.path.dirname(keys.path()), "learned.json"))


def _now():
    return datetime.now(timezone.utc)


def _fresh(seen):
    """True when seen is an ISO-8601 timestamp within MAX_AGE_DAYS."""
    try:
        ts = datetime.fromisoformat(str(seen).replace("Z", "+00:00"))
    except ValueError:
        return False
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return _now() - ts <= timedelta(days=MAX_AGE_DAYS)


def _read():
    """The whole file as a dict, or {} when missing, unreadable or corrupt."""
    try:
        with open(path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _entry(data, model):
    entry = data.get(model)
    return entry if isinstance(entry, dict) else {}


def preferred(model, field):
    """The value that worked for model's field, or None."""
    pick = _entry(_read(), model).get("prefer", {})
    pick = pick.get(field) if isinstance(pick, dict) else None
    if isinstance(pick, dict) and "value" in pick and _fresh(pick.get("seen")):
        return pick["value"]
    return None


def rejected(model, field):
    """{value: seen_iso} the provider refused for model's field (values decoded)."""
    table = _entry(_read(), model).get("rejected", {})
    table = table.get(field) if isinstance(table, dict) else None
    out = {}
    if not isinstance(table, dict):
        return out
    for encoded, seen in table.items():
        if not _fresh(seen):
            continue
        try:
            value = json.loads(encoded)
        except ValueError:
            continue
        if isinstance(value, (dict, list)):
            continue  # unhashable; generate.py only ever records scalars
        out[value] = seen
    return out


def _prune(data):
    """Drop stale or malformed entries, and models left with nothing."""
    clean = {}
    for model, entry in data.items():
        if not isinstance(entry, dict):
            continue
        prefer = {f: p for f, p in (entry.get("prefer") or {}).items()
                  if isinstance(p, dict) and "value" in p and _fresh(p.get("seen"))} \
            if isinstance(entry.get("prefer"), dict) else {}
        reject = {}
        if isinstance(entry.get("rejected"), dict):
            for f, table in entry["rejected"].items():
                if isinstance(table, dict):
                    kept = {v: s for v, s in table.items() if _fresh(s)}
                    if kept:
                        reject[f] = kept
        if prefer or reject:
            clean[model] = {"prefer": prefer, "rejected": reject}
    return clean


def _write(data, file_path=None, what="what was learned"):
    """Atomic replace of the file (path() unless given), mode 0600, dir
    0700. Never raises; a failure is one stderr warning naming what."""
    file_path = file_path or path()
    try:
        directory = os.path.dirname(file_path) or "."
        os.makedirs(directory, mode=0o700, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".learned-", suffix=".tmp", dir=directory)
        try:
            os.chmod(tmp, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=1, sort_keys=True)
                f.write("\n")
            os.replace(tmp, file_path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except Exception as e:  # noqa: BLE001 - learning must never break a generation
        print(f"clouter visual: could not save {what} to {file_path}: "
              f"{type(e).__name__}: {e}", file=sys.stderr)


def record_prefer(model, field, value):
    """value worked for model's field; also clears a rejection of that value."""
    data = _prune(_read())
    entry = data.setdefault(model, {"prefer": {}, "rejected": {}})
    entry["prefer"][field] = {"value": value, "seen": _now().strftime(TS_FORMAT)}
    entry["rejected"].get(field, {}).pop(json.dumps(value), None)
    if not entry["rejected"].get(field, True):
        del entry["rejected"][field]
    _write(data)


def record_reject(model, field, value):
    """The provider refused value for model's field; also clears a preference for it."""
    data = _prune(_read())
    entry = data.setdefault(model, {"prefer": {}, "rejected": {}})
    entry["rejected"].setdefault(field, {})[json.dumps(value)] = _now().strftime(TS_FORMAT)
    if entry["prefer"].get(field, {}).get("value") == value:
        del entry["prefer"][field]
    _write(data)

"""Ask Jev, TypeSafe's decision model, over plain HTTP.

    from lib import jev
    result = jev.decide(state, {"tier": jev.choice("Which tier?", CRITERIA)},
                        timeout=4)
    result["answers"]["tier"]["choice"]     # "sonnet"
    result["answers"]["tier"]["confidence"] # 0.71
    result["usage"], result["model"], result["request_id"]

Transport: TypeSafe direct (POST {TYPESAFE_BASE_URL}/v1/systemone) when a
TYPESAFE_API_KEY exists, else OpenRouter's decisions endpoint
(POST {OPENROUTER_BASE_URL}/api/alpha/decisions, model typesafe/jev-1.13)
with OPENROUTER_API_KEY. Keys come from lib.keys. Both take the same body:
{"model", "state", "questions"}.

One retry on 408, 429 and 5xx after at most one second, so a hook caller
with a 10-second budget is never blown by the helper; the caller's timeout
bounds each attempt. Every failure is one JevError carrying the HTTP status
and request id. Stdlib only.
"""

import json
import os
import socket
import time
import urllib.error
import urllib.request

from . import keys

OPENROUTER_URL = "https://openrouter.ai"
OPENROUTER_MODEL = "typesafe/jev-1.13"
TYPESAFE_URL = "https://api.typesafe.ai"
TYPESAFE_MODEL = "jev-latest"

RETRY_STATUSES = {408, 429}
MAX_RETRY_WAIT = 1.0


class JevError(Exception):
    def __init__(self, message, status=None, request_id=None, body=None):
        super().__init__(message)
        self.status = status
        self.request_id = request_id
        self.body = body

    def __str__(self):
        parts = [super().__str__()]
        if self.status is not None:
            parts.append(f"status {self.status}")
        if self.request_id:
            parts.append(f"request {self.request_id}")
        return " (".join(parts) + (")" if len(parts) > 1 else "")


def choice(instructions, criteria):
    """A Choice question: criteria maps each label to its description."""
    return {"type": "choice", "instructions": instructions, "criteria": dict(criteria)}


def noul(instructions):
    """A Noul question: answered with a probability that it holds."""
    return {"type": "noul", "instructions": instructions}


def score(instructions, criteria):
    """A Score question: criteria is an ordered list from low to high."""
    return {"type": "score", "instructions": instructions, "criteria": list(criteria)}


def transport():
    """(url, model, key) for the route in use. TypeSafe direct wins, so a
    stray TypeSafe key never leaves decisions on OpenRouter by accident."""
    key = keys.find("TYPESAFE_API_KEY")
    if key:
        base = keys.env("TYPESAFE_BASE_URL") or TYPESAFE_URL
        model = keys.env("TYPESAFE_DEFAULT_MODEL") or TYPESAFE_MODEL
        return base.rstrip("/") + "/v1/systemone", model, key
    key = keys.get("OPENROUTER_API_KEY")
    base = keys.env("OPENROUTER_BASE_URL") or OPENROUTER_URL
    return base.rstrip("/") + "/api/alpha/decisions", OPENROUTER_MODEL, key


def _request_id(headers, body):
    for name in ("x-typesafe-request-id", "x-request-id"):
        if headers.get(name):
            return headers[name]
    return body.get("id") if isinstance(body, dict) else None


def _retry_wait(headers):
    try:
        return min(MAX_RETRY_WAIT, float(headers.get("Retry-After", MAX_RETRY_WAIT)))
    except ValueError:
        return MAX_RETRY_WAIT


def _post(url, key, payload, timeout):
    """One attempt. Returns (status, headers, parsed body or text)."""
    request = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status, headers, raw = response.status, response.headers, response.read()
    except urllib.error.HTTPError as e:
        status, headers, raw = e.code, e.headers, e.read()
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        raise JevError(f"Jev unreachable at {url}: {e}") from e
    try:
        body = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        body = raw.decode("utf-8", "replace")
    return status, headers, body


def decide(state, questions, timeout=10.0):
    """Ask every question about the state. Returns the API's answer dict with
    `request_id` and `transport` added. Raises JevError or keys.MissingKey."""
    if not questions:
        raise ValueError("decide() needs at least one question")
    url, model, key = transport()
    payload = json.dumps({"model": model, "state": state, "questions": questions}).encode()

    status, headers, body = _post(url, key, payload, timeout)
    if status in RETRY_STATUSES or status >= 500:
        time.sleep(_retry_wait(headers))
        status, headers, body = _post(url, key, payload, timeout)

    request_id = _request_id(headers, body)
    if status >= 400:
        detail = body if isinstance(body, str) else json.dumps(body)
        raise JevError(
            f"Jev call failed: {detail[:300]}", status=status,
            request_id=request_id, body=body,
        )
    if not isinstance(body, dict) or not isinstance(body.get("answers"), dict):
        raise JevError("Jev answered without an answers object", status=status,
                       request_id=request_id, body=body)
    missing = [k for k in questions if k not in body["answers"]]
    if missing:
        raise JevError(f"Jev did not answer: {', '.join(missing)}", status=status,
                       request_id=request_id, body=body)
    body["request_id"] = request_id
    body["transport"] = "typesafe" if url.endswith("/v1/systemone") else "openrouter"
    return body

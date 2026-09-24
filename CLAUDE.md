# clouter

Notes for agents working in this repo. See README.md for what the plugin
does and how to install it.

## Layout

- `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` — plugin
  and marketplace manifests.
- `hooks/hooks.json` — plugin hooks schema with top-level description and
  hooks object. Contains one `UserPromptSubmit` hook running
  `skills/visual/route.py` (timeout 10s).
- `skills/visual/` — the `visual` skill: `SKILL.md`, `route.py` (the hook),
  `catalogue.py` (live OpenRouter model list), `ranking.py` (Jev calls),
  `spec.py` (fetches and parses a model's request spec from its
  `llms.txt`), `learned.py` (remembers per model what the provider
  rejected and what worked, `learned.json`), `generate.py` (writes the
  file, logs cost), `critique.py`
  (vision-model critic and fix rounds), `preview.py` (light/dark contact
  sheet), `setup-key.py` (one-time OAuth key setup).
- `lib/` — shared helpers: `jev.py` (HTTP client for Jev/TypeSafe),
  `keys.py` (credentials file read/write), `png.py` (PNG decode/encode,
  bbox trim).
- `tests/` — `*.test.sh` cases plus `tests/run-all.sh`; `tests/fixtures/llms/`
  — sample `llms.txt` fixtures for `spec.py`'s tests.

## Running tests

```bash
bash tests/run-all.sh
```

## Stdlib only

`lib/` and `skills/visual/` are stdlib-only Python: every module's own
docstring says so, and none of them import anything outside the standard
library or each other (`lib.jev`, `lib.keys`, `lib.png`, and the
intra-package imports between the `skills/visual/*.py` files). Keep new
code in these directories dependency-free; do not add a `requirements.txt`
or reach for a package that isn't in the stdlib.

## No network in tests

The test suite does not talk to the network. Stub or fake anything that
would otherwise call OpenRouter or Jev.

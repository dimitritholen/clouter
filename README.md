# clouter

A standalone Claude Code plugin that routes prompts for images, SVGs, video
and speech to a priced, Jev-ranked list of OpenRouter models, extracted from
1337-claude's visual router.

## What it does

Ask for a logo, an SVG illustration, a picture, a short clip or a
voice-over and a `UserPromptSubmit` hook (`skills/visual/route.py`) steps in
before Claude starts describing the thing in words instead of making it. It
asks [Jev](https://typesafe.ai), TypeSafe's decision model, what the prompt
wants (text or code, raster image, vector SVG, video, speech), pulls
OpenRouter's live model catalogue for that kind, and has Jev rank the six
cheapest. It injects one instruction block that asks with `AskUserQuestion`:
Jev's pick first and marked Recommended, then cheap to expensive, a price in
every label, "Stay with Claude" last. On a choice, `skills/visual/generate.py`
writes the file (never overwriting an existing one) and prints its path and
the real cost. Before the paid request, `skills/visual/spec.py` fetches the
picked model's own `llms.txt` so the request stays valid and uses that
model's own fields (resolution, seed, generate_audio, ...) rather than a
generic guess; those go through generate.py's repeatable `--param
key=value`, validated against the model's spec before anything is sent. A
raster or vector generation is also judged by a vision-model critic and, if
it finds defects, fixed for a few rounds before that report.

## Install

Install from the marketplace:

```bash
claude plugin marketplace add dimitritholen/clouter
claude plugin install clouter@clouter
```

For development, install from your local clone:

```bash
claude plugin marketplace add ~/dev/clouter
claude plugin install clouter@clouter
```

Or run a one-off development session without installing:

```bash
claude --plugin-dir ~/dev/clouter
```

## Key setup

Run once, in a session:

```
/clouter:visual setup
```

This runs `skills/visual/setup-key.py`, which opens an OAuth flow in the
browser, takes the callback on `127.0.0.1`, checks the key and stores it in
`~/.config/clouter/credentials` (mode 0600). If the browser cannot reach the
machine, the same run serves a paste page whose URL is printed on stderr;
`--tty` reads a hidden prompt instead. Nothing prints the key. An
`OPENROUTER_API_KEY` in the environment wins over the stored file.

## Configuration

| Variable | Default | What it does |
|---|---|---|
| `CLOUTER_VISUAL` | `1` | Set to `0`, `off` or `false` to keep the hook silent entirely. |
| `CLOUTER_VISUAL_FLOOR` | `0.5` | Summed visual probability under which the hook stays silent, and the model-confidence floor under which it drops the recommendation. |
| `CLOUTER_VISUAL_MULTI` | `0.3` | Probability from which a further visual modality in the same prompt counts as requested too. |
| `CLOUTER_VISUAL_LOG` | `visual.jsonl` next to the credentials file | Cost log path override. |
| `CLOUTER_POLL_SECONDS` | `5` | Poll interval, in seconds, while waiting on a video generation job. |
| `CLOUTER_COST_WAIT_SECONDS` | unset (steps up to 8s, ~23s total) | Caps each step of the backoff while polling a speech generation's cost lookup (5 retries on 404). Mainly for tests. |
| `CLOUTER_CRITIQUE` | `1` | Set to `0`, `off` or `false` to skip the post-generation critique pass (same as `--no-critique`). Video and speech are never critiqued. |
| `CLOUTER_CRITIC` | built-in default model | Overrides the vision model used for critique; `--critic` on the command line wins over it. |
| `CLOUTER_CREDENTIALS` | `~/.config/clouter/credentials` | Overrides the credentials file path, mainly for tests. |

## Running tests

```bash
bash tests/run-all.sh
```

## License

MIT license. See LICENSE for details.

## If you also run 1337-claude

1337-claude carries its own visual router with the same hook shape. With
both plugins installed, set `CLAUDE_1337_VISUAL=0` so only clouter's hook
fires on a prompt.

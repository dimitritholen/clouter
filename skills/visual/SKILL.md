---
name: visual
description: Make image, SVG, video or speech files through an OpenRouter model picked from a Jev-ranked, priced list, and store the OpenRouter key once. Use on /clouter:visual, "/clouter:visual setup", when the user asks to generate, draw, render or narrate something as a file, when a prompt carries a "[clouter visual]" context block from the hook, or when a Jev-backed script reports a missing key.
---

You turn a request for a picture, a vector drawing, a video clip or spoken
audio into a file on disk, made by the cheapest OpenRouter model that fits,
chosen by the user from a short priced list. You never spend credit without
that choice.

The commands below say `python3`. Where that name doesn't exist (a
standard Windows install), run the same command with `python`, or `py`.

# The flow

1. **The hook asks.** A UserPromptSubmit hook (`skills/visual/route.py`)
   watches every prompt. When the prompt hits a word prefilter (image, logo,
   svg, video, voice, ...) and an OpenRouter key is stored, it asks Jev,
   TypeSafe's decision model, what the prompt wants (text or code, raster
   image, vector SVG, video, speech) and, for a visual answer, ranks the six
   cheapest models of that kind. A prompt can carry more than one modality
   ("an SVG and a transparent PNG"): every visual modality Jev gives 0.3 or
   more counts, and each gets its own ranking. A prompt that says
   transparent, transparency, alpha or "dark and light" ranks only the
   raster models `catalogue.py` marks `alpha: true` when at least one such
   model exists, and adds `--transparent` to the raster `generate.py`
   command. It injects one `[clouter visual]` block.
2. **The user picks.** On that block, before anything else, ask with
   `AskUserQuestion` exactly as the block says: header "Model" (or one
   question per modality in a single call, headers "SVG model", "Image
   model", ...), Jev's pick first and marked Recommended, then cheap to
   expensive, a price in every label, "Stay with Claude" last. Never twice
   for one prompt.
3. **You check the model's own fields.** Before generate.py, run:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/skills/visual/spec.py" <chosen id>
   ```

   It prints the model's request fields for each endpoint it serves, parsed
   from its `llms.txt`. Read the fields for the endpoint generate.py is
   about to call and pick values for the optional ones that actually serve
   this request: `resolution`/`size` for the quality asked, `generate_audio`
   when the user wants sound, `seed` when they need a reproducible result,
   `frame_images`/`input_references` when they supplied images,
   `output_format`/`n` when relevant. Weigh cost before reaching for
   resolution or duration — both bill more — and say so when you choose a
   higher one. Don't set a field the request gives no reason to touch. Pass
   these as `--param key=value` (repeatable); use `--aspect`, `--duration`,
   `--voice` and `--reference` instead for the fields that have their own
   flag, and never `--param` for `model`, `prompt`, `messages` or `input` —
   generate.py owns those. If generate.py refuses a `--param` value (exit 2,
   listing the allowed values on stderr), pick again from that list rather
   than retrying blindly. If spec.py fails, carry on without it — the
   generic request still goes out. spec.py's output already leaves out
   values the provider rejected before (listed under `"rejected"`), so an
   enum it prints is the real set of options.

4. **You generate, then hand the round to the studio.** On a model choice,
   first turn the request into a design brief: subject, hierarchy, style,
   colours, background, what to leave out. Keep the user's own words for
   subject and style — "give me 2 versions: 1 svg and 1 png, should look
   good on dark and light GitHub" is instructions to Claude, not a picture
   description, so it needs turning into an actual brief before it becomes a
   prompt. Write the brief to a file in the scratchpad or a temp directory,
   then run the command the block gives, once per format chosen. The default
   is `--no-critique` here, so the round goes to the studio (below) instead
   of generate.py's own auto-critique; the block already says so, see
   "Studio loop" for everything that happens from `push` onward.

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/skills/visual/generate.py" \
     --model <chosen id> --modality raster_image|vector_svg|video|speech \
     --prompt-file <path to the design brief> [--out <path>] \
     [--endpoint auto|chat|images] [--aspect 16:9] [--duration 8] [--voice alloy] \
     [--transparent] [--trim [--trim-margin 32]] [--reference <file>] [--preview] \
     [--param key=value ...] \
     [--rounds 2] [--critic <model id>] [--no-critique] \
     [--request-file <path to the user's own message, verbatim>]
   ```

   Print the brief in the report too, so the user can correct it.

   Everything from here through "you check the model's own fields" above
   still applies whether or not the studio is in play. What follows
   (auto-critique, fix rounds, escalation) is generate.py's own behaviour
   when `--no-critique` is **not** passed — a one-off file made outside the
   studio loop, not the default path. Skip straight to "Studio loop" below
   for the default: `--no-critique`, then `push`, then `wait`.

   Without `--no-critique`, a raster or vector generation is judged by a
   vision-model critic and, if it finds defects, fixed for up to `--rounds`
   tries (default 2, `--critic` picks the model), which can take several
   minutes — run it with a Bash timeout of 600000 ms. The JSON line gains a
   `critique` object
   (`pass`, `rounds`, `files`, `defects`, `cost`, `critic`) and a top-level
   `final` (the file that ended up best); `path` and `cost` stay the
   original generation's — report the `final` file, whether it `pass`ed,
   any remaining `defects`, and the cost as `cost` plus `critique.cost`.
   Opt out with `--no-critique` or `CLOUTER_CRITIQUE=0` (video and
   speech never get critiqued). A critique failure (no key, API error, an
   unparseable critic reply) never fails the generation: `critique` holds
   `{"error": ...}` instead, on stderr too, and the paid file is still
   there. `--trim` runs before the critique, so the critic sees the
   trimmed file; a fix round's own output is not trimmed.

   The hook's own command already carries `--request-file`, written from
   the user's raw prompt. On a direct `/clouter:visual <request>` (no hook
   block), write the user's message verbatim to a temp file yourself and
   pass it the same way — never paraphrase it into the brief only. The
   critic then sees both: where the request and the brief-derived prompt
   disagree, the request wins, so a detail you dropped while writing the
   brief still gets caught as a defect.

   When `critique.pass` is still false after the fix rounds and
   `critique.escalation` is present, ask ONE more `AskUserQuestion`
   (header "Model", showing the remaining `defects` in the question text):
   `escalation.recommended` first labelled "(Recommended)", up to two more
   of `escalation.options`, each with its price and unit in the label, and
   "Keep current result" last. On a model pick, run
   `escalation.command` with `<MODEL>` replaced by the chosen id, again
   with a Bash timeout of 600000 ms; the result has the same `critique`
   shape, so repeat this same question while the user keeps escalating. On
   "Keep current result" report the `final` file and its `defects` as
   usual. When `critique.escalation_error` is present instead (no
   candidates, no key, a Jev or catalogue failure), report the remaining
   `defects` and that reason in one line — never a blocker, the paid file
   is already there.

   `--trim` (raster PNG only) crops fully-transparent margins, leaving
   `--trim-margin` pixels (default 32); pairs well with `--transparent`.

   `--preview` also writes a contact sheet showing the file on GitHub dark
   and on white, side by side, through `skills/visual/preview.py` — the
   quick way to check how a logo or icon reads on both. It adds a
   `preview` path to the JSON line: a PNG when a headless Chrome or
   Chromium is on PATH, else the HTML page itself. Run `preview.py
   <file>...` by hand the same way on a file made earlier, or on more than
   one file at once, when the user asks how something looks on light and
   dark rather than asking for a new generation.

   When the user asks to edit or vary a previous output rather than start
   over, pass `--reference <that path>` (raster or vector only). It only
   works on a model `catalogue.py` marks `reference_supported: true`.

   It prints one JSON line with `path`, `media_type`, `bytes`, `cost`, and
   (raster/vector, only without `--no-critique`) `critique` and `final` as
   above; with `--no-critique` (the studio default) it's just those first
   five keys — see "Studio loop" for what to report and when. On "Stay with
   Claude" carry on as usual and do not mention the models again.
   A stderr note "asked for --aspect X, the model returned WxH" means the
   model ignored the ratio: tell the user, and for the next round try
   `--endpoint images` (whose `aspect_ratio` field spec.py lists) or crop.
   `--endpoint auto` (default) posts to chat/completions and retries
   against /api/v1/images on a 404.

Without the hook block (a direct `/clouter:visual <request>`), do the same by
hand: run `skills/visual/catalogue.py <modality> 6` for the list, ask the
question, then generate — with `--request-file` pointing at the user's own
message, written verbatim to a temp file, as described above.

# Studio loop

The default after a model choice, for raster_image, vector_svg, video and
speech: every round goes into `skills/visual/studio.py`'s localhost page
(spec: `skills/visual/studio.py`'s own docstring and `session.json` shape)
instead of Claude judging or reporting a single file. Keep a running total
of `cost` from every `generate.py` and `critique.py` call as you go — the
studio's own `session.json` never sums it for you.

**Push the first round.**

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/visual/generate.py" \
  --model <chosen id> --modality <modality> --prompt-file <brief> \
  --no-critique [--transparent] --request-file <path> [--out <path>]
```

Read its `path` and `cost` off the printed JSON line and keep them (round
number → original `path`, `cost`) — `push` copies the file into the session
as `rounds/round-N.<ext>`, so that copy is not the path to report later.
For raster_image/vector_svg only, also run:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/visual/critique.py" <path> \
  --prompt-file <brief> --suggest --model <generator id> --out <defects.json>
```

This writes `defects`, `summary`, `model_trouble`, and (when model_trouble is
true) a Jev-ranked `models` list to the defects file, excluding the current
generator.

Then push and wait, in the background:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/visual/studio.py" push \
  --file <path> --model <chosen id> --cost <cost> --brief-file <brief> \
  --request-file <path to the user's request> --modality <modality> \
  [--defects-file <defects.json>] [--message-file <note.txt>]
# prints {"round", "url", "session"} — tell the user the url once
python3 "${CLAUDE_PLUGIN_ROOT}/skills/visual/studio.py" wait --session <session dir>
```

`--message-file <path>` is an optional Claude note for this round (plain text),
shown in the page as a "Claude" message to explain what changed since the last
round.

`--cost` here is that round's `generate.py` cost only — a `critique.py
--translate` or `--suggest` call has its own `cost` and does not go into
`push --cost`, but it still belongs in the running total you keep and
report at accept.

Run `wait` with a long Bash timeout (it defaults to a 3600 s poll and only
returns on feedback, accept, its own timeout or a dead server) and handle
its exit code:

- **0, feedback.** Its JSON (`annotation`, `notes`, `markers[].frame`,
  `text`, `accepted_defects`, `branch_from`, `round`, `round_file`, `model`)
  is one feedback entry. `model` (when present) is the model id the user
  picked in the page — use it for the next round without asking; still run
  the spec check and `catalogue.py --reference-supported <id>` as usual.
  When `annotation`, `notes` or any `markers[].frame` is present, translate
  them first — write `notes`/`markers`/`text` each to their own temp file
  and run:

  ```bash
  python3 "${CLAUDE_PLUGIN_ROOT}/skills/visual/critique.py" <round_file> \
    --translate --out instructions.json \
    --prompt-file <that round's brief> --request-file <path to the user's request> \
    [--annotation <annotation>] [--notes-file <notes.json>] \
    [--text-file <text.txt>] [--frames-file <markers.json>]
  ```

  `--prompt-file`/`--request-file` ground a vague pointer ("the purple
  icon") in what was actually asked for; skipping them leaves the
  translator guessing at the picture.

  Then rewrite the brief yourself, in the user's own words, from three
  things: `text` as given, the defects in that round's `defects` list (in
  `session.json`, via `studio.py status` or the round data `wait` already
  gave you) whose `id` is in `accepted_defects`, and `instructions.json`'s
  `instructions` list when you ran `--translate`. Do not paraphrase away
  what the user actually typed.

  Image models do not understand negation: a fix that says what to remove
  states it, and the model paints it anyway ("a pen nib, not an anchor"
  plus "leave out: anchors" produced a logo full of anchors, live). State
  every fix positively — what should be there — and never name the
  unwanted object, in the brief text or in a "leave out" list. A critic's
  "fix" text and a translated instruction often name the unwanted thing
  themselves ("remove the anchor", "no more anchor points") — rephrase
  those positively before they go into the brief, and scrub earlier
  wording that already invites it (drop "anchor points" from "pen nib
  with anchor points" too, not just the new fix).

  The base round is `branch_from` when set, else `round` — that round's
  `round_file` is the one to regenerate from. Regenerate with the same
  model unless the user's `text` names another — then use that model
  without asking again (naming it in the feedback is the choice); still
  spec-check it (step 3, "You check the model's own fields") and run the
  reference check below against it. Only ask again (a fresh
  `AskUserQuestion`) when `text` asks for "a different model" without
  naming one. For raster_image/vector_svg, pass `--reference <base
  round_file>` only when the model in play — the one just picked, or the
  round's own model when it wasn't switched — takes an image input: run

  ```bash
  python3 "${CLAUDE_PLUGIN_ROOT}/skills/visual/catalogue.py" --reference-supported <model id>
  ```

  which prints `{"model", "reference_supported"}` (exit 2 on an unknown
  id) — the same check generate.py's own `--reference` guard, exit 8,
  makes, and the same field `catalogue.models()`/`catalogue.py <modality>
  6` already prints per entry. Otherwise regenerate from the rewritten
  brief alone. Never pass the annotation layer itself as `--reference` —
  it is feedback, not source material. Video and speech never take
  `--suggest` or `--reference`: a marker's `text` becomes a timestamped
  instruction in the new prompt instead ("at 0:03, ...").

  Instructions about tooling in the feedback — switch model, use a round
  as reference, try again cheaper — are acted on directly, never written
  into the brief; the brief only ever describes the picture or sound
  itself.

  Push the new round the same way as the first, adding `--session
  <session dir>` (the one the first `push` printed; without it `push`
  starts a new session and refuses `--parent`), `--parent <base round>`
  and `--defects-file` again for raster/vector, then `wait` again.
- **10, accept.** Report the accepted round's original output path (the
  `path` you kept from that round's `generate.py` call, not the copy under
  `rounds/`) and the running cost total across every round. Then run
  `studio.py stop --session <session dir>`. `wait` returns 10 immediately
  on a session that is already accepted, so re-running it after a lost
  result — a dropped connection, a restart — is always safe, never a
  double accept.
- **20, timeout.** The user may still be looking at the page; run `wait`
  again with the same session.
- **30, server gone.** The server process died (idle timeout, crash).
  Restart it — `studio.py serve --session <session dir> --no-open` in the
  background, or push the same round again, either starts a fresh one —
  tell the user the URL again, then `wait` again.

# Where the file goes

`--out` wins. Else `assets/<slug of the prompt>.<ext>` under the current
directory. Nothing is ever overwritten: a second file gets `-2`. The
extension follows what the model returned: Recraft vector models return a
real SVG, raster models PNG or JPEG, video MP4, speech MP3.

# Setup, once

`/clouter:visual setup` runs:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/visual/setup-key.py"
```

It opens the browser on OpenRouter's OAuth page, takes the callback on
127.0.0.1, checks the key and stores it in `~/.config/clouter/credentials`
(mode 0600). Run it in the background and show the user both links from its
stderr JSON line: `url` (open in a browser) and `paste_url` (the fallback
when the browser can't reach this machine — a Windows browser outside WSL,
a remote box; the same run serves a paste page at that URL). Use `--tty`
instead when there is no browser to open at all (a headless box, an SSH
session) — it reads a hidden prompt. Nothing prints the key. After that no
session asks again: the tier router, the visual hook and the generator all
read the same file, and `OPENROUTER_API_KEY` in the environment wins over
it — set that instead of running setup on a machine where storing a file
is unwelcome.

When a prompt looks visual and no key is stored, the hook injects a short
note instead of a list. Ask once with `AskUserQuestion` whether to store a
key now or carry on without. "Without" only silences the hook's own nudge
on ordinary prompts, for this session; if the user later explicitly asks to
generate a file, or a generate.py/critique.py run exits 3 (see "Errors"),
offer the setup again — once per such request, with `/clouter:visual
setup` as the thing to run.

# Errors

Exit 3 (no OpenRouter key found, or the credentials file has an unsafe mode)
from generate.py or critique.py means nothing was sent yet. Offer
`/clouter:visual setup` with `AskUserQuestion` (see "Setup, once"); on
"without" carry on unable to make that file, and don't ask again for this
same request. `OPENROUTER_API_KEY` in the environment is the alternative to
running setup at all.

Exit 6 from generate.py (model unusable: HTTP 403 upstream, e.g. an 18+
attestation the account lacks) prints the upstream message to the user in one
line, drops that model from the ranked choice, and asks once more with the
remaining models; if none remain, say so and stop. This is the one exception
to "do not ask twice for the same prompt", because the first answer turned
out impossible, not declined.

Exit 7 (`--transparent` on a model without a real alpha channel) refuses
before any request is sent — most diffusion models only paint a fake
checkerboard for "transparent". Never pass `--transparent` for a model
`catalogue.py` did not mark `alpha: true`.

Exit 8 (`--reference` on a model whose `architecture.input_modalities` has
no `image`) also refuses before any request is sent. Never pass
`--reference` for a model `catalogue.py` did not mark
`reference_supported: true`.

# Prices

Labels show what OpenRouter bills: image models per 1K image output tokens
(a picture is roughly 1K to 4K tokens, so multiply by two to four for a
per-picture guess), video per second, speech per 1K characters. The
generator reports the real cost after the fact. Models that need a
reference image on every request (Recraft "Styles") are never offered.
Every generation is logged; `generate.py --cost --since 24h` for a spend
summary.

# Knobs

- `CLOUTER_VISUAL=0` — the hook stays silent.
- `CLOUTER_VISUAL_FLOOR` — summed visual probability under which the
  hook stays silent, and model confidence under which it drops the
  recommendation (0.5).
- `CLOUTER_VISUAL_MULTI` — probability from which a further visual
  modality counts as requested too (0.3).
- `OPENROUTER_BASE_URL`, `CLOUTER_CREDENTIALS` — API and key file
  overrides, for tests.
- `CLOUTER_POLL_SECONDS` — video job poll interval (5).
- `CLOUTER_COST_WAIT_SECONDS` — caps each step of the backoff while
  polling a speech generation's cost lookup (unset: 1, 2, 4, 8, 8s).
- `CLOUTER_VISUAL_LOG` — cost log path override (default
  `visual.jsonl` next to the credentials file).
- `CLOUTER_LEARNED` — path of the store of values a provider rejected
  and what worked instead (default `learned.json` next to the
  credentials file, 30 days).

Rules: never call generate.py before the user chose; never print or echo a
key; a hook or API failure means silence and the normal reply, not an
apology.

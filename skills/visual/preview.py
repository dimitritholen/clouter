#!/usr/bin/env python3
"""Contact sheet: how a file looks on GitHub dark and on white.

    preview.py <file>... [--out path.png]

Writes a self-contained HTML page showing each file twice, side by
side: once on #0d1117 (GitHub dark) and once on #ffffff (white), with
the file name and, when known, its dimensions (PNG via lib/png.py's
decode(), SVG via its viewBox). Every file is embedded as a data URL,
so the HTML needs nothing next to it.

The HTML is then rendered through headless Chrome/Chromium, whichever
is first on PATH out of google-chrome, google-chrome-stable, chromium,
chromium-browser:

    <browser> --headless=new --screenshot=<png> --window-size=<w>,<h>
              --allow-file-access-from-files --hide-scrollbars
              --default-background-color=00000000 file://<html>

into one contact-sheet PNG, 30 s timeout. Default output is a temp
directory (tempfile.mkdtemp, prefix clouter-preview-); --out names the
PNG and the HTML goes next to it (same name, .html). Prints the PNG
path. Without a browser on PATH, or one that exits non-zero or writes
no PNG, prints the HTML path instead (one stderr note in the failure
case) and still exits 0 — the caller has a preview either way. Exit 2:
a file argument that does not exist. Stdlib only.
"""

import argparse
import base64
import html
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))
from lib import png  # noqa: E402

BROWSERS = ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser")
BROWSER_TIMEOUT = 30
PANE_SIZE = 320  # max width/height of one embedded image, px
ROW_HEIGHT = 420  # px reserved per file (both panes plus caption)
SHEET_WIDTH = 820


def _dims_png(raw):
    try:
        width, height, _ = png.decode(raw)
        return width, height
    except png.PngError:
        return None


def dims_svg(raw):
    match = re.search(
        rb'viewBox\s*=\s*["\']\s*[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+([\d.]+)', raw)
    if not match:
        return None

    def num(b):
        f = float(b)
        return int(f) if f.is_integer() else f
    return num(match.group(1)), num(match.group(2))


def describe(path, raw):
    """Return (dims_text_or_None) for a file: 'WxH' for a PNG or SVG
    whose size can be read, None for anything else (JPEG, WebP, ...
    dimensions unknown without a fuller decoder)."""
    ext = os.path.splitext(path)[1].lower()
    dims = None
    if ext == ".png":
        dims = _dims_png(raw)
    elif ext == ".svg":
        dims = dims_svg(raw)
    return f"{dims[0]}×{dims[1]}" if dims else None


def data_url(path, raw):
    media_type = mimetypes.guess_type(path)[0] or "application/octet-stream"
    return f"data:{media_type};base64,{base64.b64encode(raw).decode()}"


def _pane(url, bg):
    return (f'<div class="pane" style="background:{bg}">'
            f'<img src="{url}" alt="">' '</div>')


def build_html(paths):
    """Read every path, return (html_text, width, height) for the
    Chrome --window-size that follows. Raises FileNotFoundError for a
    missing path (caller turns that into exit 2)."""
    rows = []
    for path in paths:
        if not os.path.isfile(path):
            raise FileNotFoundError(path)
        with open(path, "rb") as f:
            raw = f.read()
        url = data_url(path, raw)
        dims = describe(path, raw)
        caption = html.escape(os.path.basename(path))
        if dims:
            caption += f" &mdash; {dims}"
        rows.append(
            '<section class="row">'
            f'<h2>{caption}</h2>'
            '<div class="panes">'
            f'{_pane(url, "#0d1117")}'
            f'{_pane(url, "#ffffff")}'
            '</div>'
            '</section>'
        )
    body = "\n".join(rows)
    width = SHEET_WIDTH
    height = ROW_HEIGHT * len(paths) + 40
    text = f"""<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
  body {{ margin: 0; padding: 20px; background: #f6f8fa;
         font: 14px -apple-system, sans-serif; color: #24292f; }}
  .row {{ margin-bottom: 20px; }}
  h2 {{ font-size: 14px; margin: 0 0 8px; }}
  .panes {{ display: flex; gap: 12px; }}
  .pane {{ flex: 1; display: flex; align-items: center; justify-content: center;
           height: {PANE_SIZE}px; border-radius: 6px; overflow: hidden; }}
  .pane img {{ max-width: {PANE_SIZE}px; max-height: {PANE_SIZE}px; }}
</style>
</head>
<body>
{body}
</body>
</html>
"""
    return text, width, height


def render(html_path, png_path, width, height):
    """Try each known headless browser in turn. Returns True on a PNG
    actually written, False otherwise (no browser, non-zero exit,
    nothing written) — the caller falls back to the HTML path either
    way, so this never raises for that."""
    browser = None
    for name in BROWSERS:
        found = shutil.which(name)
        if found:
            browser = found
            break
    if not browser:
        return False
    command = [
        browser, "--headless=new", f"--screenshot={png_path}",
        f"--window-size={width},{height}",
        "--allow-file-access-from-files", "--hide-scrollbars",
        "--default-background-color=00000000",
        f"file://{html_path}",
    ]
    try:
        result = subprocess.run(command, capture_output=True, timeout=BROWSER_TIMEOUT)
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"preview: {browser} failed: {e}", file=sys.stderr)
        return False
    if result.returncode != 0 or not os.path.isfile(png_path) or os.path.getsize(png_path) == 0:
        detail = (result.stderr or b"").decode("utf-8", "replace").strip()
        print(f"preview: {browser} exited {result.returncode}"
              + (f": {detail[:300]}" if detail else ""), file=sys.stderr)
        return False
    return True


def make_preview(paths, out=None):
    """Write the contact-sheet HTML for `paths` and, when a headless
    browser is on PATH and renders it, the PNG too. Returns
    {"html": path} or {"html": path, "png": path}. Raises
    FileNotFoundError for a missing input path."""
    text, width, height = build_html(paths)
    if out:
        png_path = out if out.lower().endswith(".png") else out + ".png"
        html_path = os.path.splitext(png_path)[0] + ".html"
        directory = os.path.dirname(png_path)
        if directory:
            os.makedirs(directory, exist_ok=True)
    else:
        directory = tempfile.mkdtemp(prefix="clouter-preview-")
        html_path = os.path.join(directory, "preview.html")
        png_path = os.path.join(directory, "preview.png")
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(text)
    if render(html_path, png_path, width, height):
        return {"html": html_path, "png": png_path}
    return {"html": html_path}


def main(argv):
    parser = argparse.ArgumentParser(
        description="Contact sheet of files on GitHub dark and white, rendered to PNG when a browser is on PATH.")
    parser.add_argument("files", nargs="+")
    parser.add_argument("--out", help="PNG output path (default a temp directory)")
    args = parser.parse_args(argv[1:])
    try:
        result = make_preview(args.files, args.out)
    except FileNotFoundError as e:
        print(f"preview: {e} not found", file=sys.stderr)
        return 2
    print(result.get("png") or result["html"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

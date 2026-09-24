#!/usr/bin/env bash
# Tests for lib/png.py: decode/encode round-trip, one decode per filter
# type, the adaptive encoder beating an all-None-filter encode on a
# gradient, and the bbox trim helper. Needs python3; no key, no network.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

py() { out=$(cd "$ROOT" && python3 -c "$1" 2>"$work/stderr"); code=$?; }
check_code() { if [ "$2" -eq "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (exit %s, want %s): %s\n' "$1" "$2" "$3" "$(cat "$work/stderr")"; fail=1; fi; }
check_eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=1; fi; }

# --- round trip through a gradient (hits every filter type on the encode side) ---
py '
from lib import png
w, h = 40, 30
rows = []
for y in range(h):
    row = bytearray(w * 4)
    for x in range(w):
        d = x * 4
        row[d] = (x * 5) % 256
        row[d + 1] = (y * 7) % 256
        row[d + 2] = (x + y) % 256
        row[d + 3] = 255 if (x + y) % 3 else 0
    rows.append(row)
raw = png.encode(w, h, rows)
w2, h2, rows2 = png.decode(raw)
assert (w2, h2) == (w, h), (w2, h2)
assert [bytes(r) for r in rows2] == [bytes(r) for r in rows], "pixels differ after round trip"
print("ok")
'
check_code "round trip: decode ok" "$code" 0
check_eq "round trip: pixels identical" "$out" "ok"

# --- decode one PNG per filter type, hand-crafted rows -------------------------
py '
import struct, zlib
from lib import png

def chunk(ctype, data):
    return struct.pack(">I", len(data)) + ctype + data + struct.pack(">I", zlib.crc32(ctype + data) & 0xFFFFFFFF)

def make_png(ftype):
    w = h = 3
    # solid-ish RGBA so every unfilter path (None/Sub/Up/Average/Paeth) is exercised
    pixel_rows = [bytes(b for x in range(w) for b in (10 + 3 * y + x, 20, 30, 255)) for y in range(h)]
    stream = bytearray()
    prev = bytearray(w * 4)
    for row in pixel_rows:
        row = bytearray(row)
        out = bytearray(w * 4)
        bpp = 4
        for i in range(w * 4):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ftype == 0:
                out[i] = row[i]
            elif ftype == 1:
                out[i] = (row[i] - a) & 0xFF
            elif ftype == 2:
                out[i] = (row[i] - b) & 0xFF
            elif ftype == 3:
                out[i] = (row[i] - (a + b) // 2) & 0xFF
            elif ftype == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                out[i] = (row[i] - pred) & 0xFF
        stream.append(ftype)
        stream += out
        prev = row
    idat = zlib.compress(bytes(stream), 9)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    return png.SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")

for ftype in range(5):
    raw = make_png(ftype)
    w, h, rows = png.decode(raw)
    assert (w, h) == (3, 3)
    for y in range(3):
        for x in range(3):
            d = x * 4
            expected = (10 + 3 * y + x, 20, 30, 255)
            got = tuple(rows[y][d:d + 4])
            assert got == expected, f"filter {ftype} row {y} col {x}: got {got}, want {expected}"
print("ok")
'
check_code "per-filter decode: exit 0" "$code" 0
check_eq "per-filter decode: pixels correct for all 5 filter types" "$out" "ok"

# --- adaptive encode beats an all-None-filter encode on a gradient -------------
py '
from lib import png
w, h = 64, 48
rows = []
for y in range(h):
    row = bytearray(w * 4)
    for x in range(w):
        d = x * 4
        row[d] = (x * 4) % 256
        row[d + 1] = (y * 4) % 256
        row[d + 2] = (x * 2 + y * 2) % 256
        row[d + 3] = 255
    rows.append(row)
adaptive = png.encode(w, h, rows)

import zlib
stream = bytearray()
for row in rows:
    stream.append(0)
    stream += row
none_filtered = png.SIGNATURE  # placeholder, real comparison below
import struct
def chunk(ctype, data):
    return struct.pack(">I", len(data)) + ctype + data + struct.pack(">I", zlib.crc32(ctype + data) & 0xFFFFFFFF)
ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
none_png = png.SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(stream), 9)) + chunk(b"IEND", b"")

print(f"{len(adaptive)} {len(none_png)}")
assert len(adaptive) < len(none_png), (len(adaptive), len(none_png))
'
check_code "adaptive vs none-filter: exit 0" "$code" 0
adaptive_size="$(printf '%s' "$out" | awk "{print \$1}")"
none_size="$(printf '%s' "$out" | awk "{print \$2}")"
[ -n "$adaptive_size" ] && [ -n "$none_size" ] && [ "$adaptive_size" -lt "$none_size" ] \
  && printf 'ok   adaptive encode smaller than all-None (%s < %s bytes)\n' "$adaptive_size" "$none_size" \
  || { printf 'FAIL adaptive encode not smaller (%s vs %s bytes)\n' "$adaptive_size" "$none_size"; fail=1; }

# --- bbox: a known opaque rectangle inside a transparent canvas ----------------
py '
from lib import png
w, h = 20, 16
rows = [bytearray(w * 4) for _ in range(h)]
# opaque rectangle x in [5,10), y in [3,7)
for y in range(3, 7):
    for x in range(5, 10):
        d = x * 4
        rows[y][d:d + 4] = bytes([255, 0, 0, 255])
box = png.bbox(w, h, rows)
print(box)
assert box == (5, 3, 10, 7), box
'
check_code "bbox: exit 0" "$code" 0
check_eq "bbox: matches the known rectangle" "$out" "(5, 3, 10, 7)"

py '
from lib import png
w, h = 5, 5
rows = [bytearray(w * 4) for _ in range(h)]
print(png.bbox(w, h, rows))
'
check_code "bbox: fully transparent, exit 0" "$code" 0
check_eq "bbox: fully transparent gives None" "$out" "None"

exit $fail

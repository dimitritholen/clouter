"""Minimal PNG decode/encode, stdlib only.

    from lib import png
    width, height, rows = png.decode(raw)   # rows: width*4 RGBA bytes each
    raw = png.encode(width, height, rows)   # adaptive filtering, zlib level 9
    box = png.bbox(width, height, rows)     # (x0, y0, x1, y1) of non-transparent
                                             # pixels, or None if fully transparent

decode() reads 8-bit, non-interlaced PNGs of colour type 0 (grayscale), 2
(RGB), 3 (palette, PLTE plus optional tRNS), 4 (grey+alpha) or 6 (RGBA);
every type is expanded to RGBA rows. Not supported, and raising PngError:
16-bit depth, depth below 8, interlacing (Adlam-7), and any other colour
type value. encode() only ever writes colour type 6 (RGBA), 8-bit.

Rationale for adaptive filtering over encode()'s alternative, an unfiltered
zlib-9 pass: on a real generated image the unfiltered encode was 3.1 MB
where Chrome's re-encode of the same pixels (which also picks a filter per
row) was 1.0 MB. Filtering runs of similar neighbouring pixels through Sub,
Up, Average or Paeth gives zlib far more redundancy to compress than the
raw bytes do.
"""

import struct
import zlib

SIGNATURE = b"\x89PNG\r\n\x1a\n"


class PngError(ValueError):
    """Not a PNG this module can read, or a feature it does not support."""


def _chunks(data):
    if data[:8] != SIGNATURE:
        raise PngError("not a PNG (bad signature)")
    pos = 8
    while pos < len(data):
        if pos + 8 > len(data):
            raise PngError("truncated chunk header")
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        start = pos + 8
        chunk_data = data[start:start + length]
        if len(chunk_data) != length:
            raise PngError(f"truncated {ctype!r} chunk")
        pos = start + length + 4  # skip the CRC
        yield ctype, chunk_data


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter(stream, width, height, bpp):
    stride = width * bpp
    rows = []
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        if pos >= len(stream):
            raise PngError("image data ends before the last scanline")
        ftype = stream[pos]
        row = bytearray(stream[pos + 1:pos + 1 + stride])
        if len(row) != stride:
            raise PngError("scanline shorter than the header promises")
        pos += 1 + stride
        if ftype == 0:
            pass
        elif ftype == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + (a + prev[i]) // 2) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + _paeth(a, prev[i], c)) & 0xFF
        else:
            raise PngError(f"unknown filter type {ftype}")
        rows.append(row)
        prev = row
    return rows


_BPP = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}  # 8-bit only


def decode(data):
    """Decode an 8-bit, non-interlaced PNG. Returns (width, height, rows);
    rows is a list of `height` bytearrays, each `width * 4` RGBA bytes."""
    ihdr = None
    idat = bytearray()
    palette = None
    trans = None
    for ctype, cdata in _chunks(data):
        if ctype == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", cdata)
        elif ctype == b"IDAT":
            idat += cdata
        elif ctype == b"PLTE":
            palette = cdata
        elif ctype == b"tRNS":
            trans = cdata
        elif ctype == b"IEND":
            break
    if ihdr is None:
        raise PngError("no IHDR chunk")
    width, height, depth, colour, compression, filt, interlace = ihdr
    if depth != 8:
        raise PngError(f"only 8-bit depth is supported, got {depth}")
    if interlace != 0:
        raise PngError("interlaced PNGs are not supported")
    if compression != 0 or filt != 0:
        raise PngError("unknown compression or filter method")
    if colour not in _BPP:
        raise PngError(f"unsupported colour type {colour}")
    if colour == 3 and palette is None:
        raise PngError("palette colour type without a PLTE chunk")
    bpp = _BPP[colour]
    stream = zlib.decompress(bytes(idat))
    raw_rows = _unfilter(stream, width, height, bpp)

    rows = []
    for raw in raw_rows:
        rgba = bytearray(width * 4)
        if colour == 6:
            rgba[:] = raw
        elif colour == 2:
            for x in range(width):
                s, d = x * 3, x * 4
                rgba[d:d + 3] = raw[s:s + 3]
                rgba[d + 3] = 255
        elif colour == 0:
            for x in range(width):
                g, d = raw[x], x * 4
                rgba[d] = rgba[d + 1] = rgba[d + 2] = g
                rgba[d + 3] = 255
        elif colour == 4:
            for x in range(width):
                s, d = x * 2, x * 4
                g, a = raw[s], raw[s + 1]
                rgba[d] = rgba[d + 1] = rgba[d + 2] = g
                rgba[d + 3] = a
        elif colour == 3:
            for x in range(width):
                idx, d = raw[x], x * 4
                p = idx * 3
                if p + 3 > len(palette):
                    raise PngError("palette index out of range")
                rgba[d:d + 3] = palette[p:p + 3]
                rgba[d + 3] = trans[idx] if trans and idx < len(trans) else 255
        rows.append(rgba)
    return width, height, rows


# --- encode (always RGBA, 8-bit, colour type 6) -----------------------------

def _filtered(ftype, row, prev, bpp):
    stride = len(row)
    out = bytearray(stride)
    if ftype == 0:
        out[:] = row
    elif ftype == 1:
        for i in range(stride):
            a = row[i - bpp] if i >= bpp else 0
            out[i] = (row[i] - a) & 0xFF
    elif ftype == 2:
        for i in range(stride):
            out[i] = (row[i] - prev[i]) & 0xFF
    elif ftype == 3:
        for i in range(stride):
            a = row[i - bpp] if i >= bpp else 0
            out[i] = (row[i] - (a + prev[i]) // 2) & 0xFF
    elif ftype == 4:
        for i in range(stride):
            a = row[i - bpp] if i >= bpp else 0
            c = prev[i - bpp] if i >= bpp else 0
            out[i] = (row[i] - _paeth(a, prev[i], c)) & 0xFF
    return out


def _signed_abs_sum(row):
    total = 0
    for b in row:
        total += b if b < 128 else 256 - b
    return total


def _crc_chunk(ctype, cdata):
    body = ctype + cdata
    return struct.pack(">I", len(cdata)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def encode(width, height, rows):
    """Encode RGBA rows (each `width * 4` bytes) to a PNG, colour type 6,
    8-bit, adaptive per-row filtering (least signed-byte-sum of the five
    PNG filter types), zlib level 9."""
    bpp = 4
    prev = bytearray(width * bpp)
    stream = bytearray()
    for row in rows:
        row = bytes(row)
        if len(row) != width * bpp:
            raise PngError("row length does not match width * 4")
        best_type, best_out, best_sum = 0, row, None
        for ftype in range(5):
            candidate = _filtered(ftype, row, prev, bpp)
            total = _signed_abs_sum(candidate)
            if best_sum is None or total < best_sum:
                best_type, best_out, best_sum = ftype, candidate, total
        stream.append(best_type)
        stream += best_out
        prev = bytearray(row)

    compressed = zlib.compress(bytes(stream), 9)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    out = bytearray(SIGNATURE)
    out += _crc_chunk(b"IHDR", ihdr)
    out += _crc_chunk(b"IDAT", compressed)
    out += _crc_chunk(b"IEND", b"")
    return bytes(out)


def bbox(width, height, rows):
    """(x0, y0, x1, y1) bounding box (x1/y1 exclusive) of pixels whose alpha
    is non-zero, or None if every pixel is fully transparent."""
    x0 = y0 = None
    x1 = y1 = 0
    for y, row in enumerate(rows):
        for x in range(width):
            if row[x * 4 + 3] != 0:
                if x0 is None or x < x0:
                    x0 = x
                if y0 is None or y < y0:
                    y0 = y
                if x + 1 > x1:
                    x1 = x + 1
                if y + 1 > y1:
                    y1 = y + 1
    if x0 is None:
        return None
    return x0, y0, x1, y1

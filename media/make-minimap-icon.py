#!/usr/bin/env python3
"""Regenerate the minimap button's art.

PORTED FROM AEGIS: PATHFINDER's Tools/make_assets.py, which is the sibling
addon's asset pipeline and is already proven to look right on a 1.12 client.
Where this differs from it, the difference is noted and has a reason -- these
two should not drift, the same way the two CLAUDE.md files do not.

    pip install Pillow && python3 media/make-minimap-icon.py

Nothing in the addon runs this. It exists because an icon nobody can rebuild
is an icon nobody can adjust.

WHAT PATHFINDER GETS RIGHT, AND WHY EACH PART MATTERS

  * 64x64 output, drawn at 32. Not "match the texture to the draw size" --
    that was my own inference and it was worse. Pathfinder ships 64 and reads
    cleanly, so 64 it is.

  * HALVED STEP BY STEP, never one big jump. A single 1024 -> 64 LANCZOS
    reduction aliases: fine detail (runes, wing feathers, lettering) lands
    between output pixels and turns to noise, which is exactly what "looks
    pixelated" was. Repeated halving averages each level into the next, which
    is what a mipmap chain does and why this reads as detail rather than
    grain.

  * RLE truecolor (TGA type 10), 32-bit, bottom-left origin, powers of two.
    Matches every texture Pathfinder ships. Courier's own ResizeGrip.tga is
    uncompressed (type 2) and also loads fine; both work, and matching the
    sibling is worth more than matching our own older file.

  * THE LOGO NEEDS NO BORDER OF OURS. It is a disc with its own gold and red
    rune ring, so Blizzard's MiniMap-TrackingBorder would be a second ring
    drawn around the first. The button draws the icon at full size and skips
    it, exactly as Pathfinder does.

THE ONE REAL DIFFERENCE. Pathfinder's source art is a disc on transparency,
so it needs no mask. Ours is a JPEG with hard black square corners, which
would draw as a black box behind the emblem -- so a circular alpha mask is
applied here. Supersampled, or the circle's edge is a staircase.
"""

import os
import struct
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "minimap-source.jpg")
SS = 8                    # supersample factor for generated shapes
WHITE = (255, 255, 255)


# --------------------------------------------------------------------------
# TGA writing -- a verbatim port of Pathfinder's Tools/make_assets.py
# --------------------------------------------------------------------------

def _rle_scanline(pixels):
    """Encode one scanline as TGA RLE packets (max 128 pixels per packet)."""
    out = bytearray()
    i, n = 0, len(pixels)
    while i < n:
        run = 1
        while run < 128 and i + run < n and pixels[i + run] == pixels[i]:
            run += 1
        if run > 1:
            out.append(0x80 | (run - 1))
            b, g, r, a = pixels[i][2], pixels[i][1], pixels[i][0], pixels[i][3]
            out += bytes((b, g, r, a))
            i += run
            continue
        start = i
        while (i < n and i - start < 128 and
               not (i + 1 < n and pixels[i] == pixels[i + 1])):
            i += 1
        chunk = pixels[start:i]
        out.append(len(chunk) - 1)
        for r, g, b, a in chunk:
            out += bytes((b, g, r, a))
    return out


def write_tga(img, path):
    """Write an RGBA image as a 32-bit RLE TGA, bottom-left origin."""
    img = img.convert("RGBA")
    w, h = img.size
    for label, value in (("width", w), ("height", h)):
        if value == 0 or value & (value - 1):
            raise ValueError("%s: %s %d is not a power of two" % (path, label, value))
    header = struct.pack(
        "<BBBHHBHHHHBB",
        0,        # ID length
        0,        # no colour map
        10,       # RLE truecolor
        0, 0, 0,  # colour map spec
        0, 0,     # x/y origin
        w, h,
        32,       # bits per pixel
        0x08,     # 8 alpha bits, bottom-left origin
    )
    px = img.load()
    body = bytearray()
    for y in range(h - 1, -1, -1):        # bottom-left origin: last row first
        body += _rle_scanline([px[x, y] for x in range(w)])
    with open(path, "wb") as fh:
        fh.write(header)
        fh.write(body)
    return os.path.getsize(path)


# --------------------------------------------------------------------------
# The two textures
# --------------------------------------------------------------------------

def minimap_logo(size=64):
    """The button face: the full-colour logo, a disc with its own ring.

    Halved step by step rather than in one go, so the fine detail -- the
    runes, the wing feathers -- averages out instead of aliasing.
    """
    img = Image.open(SOURCE).convert("RGBA")
    side = min(img.size)
    img = img.crop(((img.size[0] - side) // 2, (img.size[1] - side) // 2,
                    (img.size[0] + side) // 2, (img.size[1] + side) // 2))
    while img.size[0] >= size * 4:
        img = img.resize((img.size[0] // 2, img.size[1] // 2), Image.LANCZOS)
    img = img.resize((size, size), Image.LANCZOS)

    # Ours only: the source is a JPEG on hard black, so without this the
    # emblem draws inside a black square. Built at the pre-halved size and
    # brought down with the art, so its edge is as smooth as the art's.
    mask = Image.new("L", (size * SS, size * SS), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size * SS - 1, size * SS - 1), fill=255)
    img.putalpha(mask.resize((size, size), Image.LANCZOS))
    return write_tga(img, os.path.join(HERE, "minimap.tga"))


def minimap_ring(size=32, width=2, pad=1):
    """Hover ring, sitting just outside the logo's own.

    A WHITE MASK, tinted in Lua with SetVertexColor -- Pathfinder's whole
    media folder works this way, and it means the accent colour lives in one
    place in the code rather than baked into a file nobody can see.
    """
    img = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    p = pad * SS
    d.ellipse([p, p, size * SS - 1 - p, size * SS - 1 - p],
              outline=WHITE + (255,), width=width * SS)
    img = img.resize((size, size), Image.LANCZOS)
    return write_tga(img, os.path.join(HERE, "minimap-ring.tga"))


if __name__ == "__main__":
    print("minimap.tga      %6d bytes" % minimap_logo())
    print("minimap-ring.tga %6d bytes" % minimap_ring())

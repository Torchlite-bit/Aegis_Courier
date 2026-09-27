#!/usr/bin/env python3
"""Regenerate media/minimap.tga from media/minimap-source.jpg.

Kept in the repo because an icon nobody can rebuild is an icon nobody can
adjust. Needs Pillow; nothing in the addon runs it.

THREE THINGS MATTER HERE, and the first version got two of them wrong.

1. THE CROP. The button draws the icon at TWENTY PIXELS. The full logo is a
   rune ring, an inner gold ring, a shield, wings, an envelope and the word
   AEGIS -- and all of it has to land inside those twenty pixels, where the
   ring and the lettering turn to noise and crowd out the part you would
   actually recognise. So the source is cropped to the shield and wings and
   the outer rings are dropped. The minimap border draws its own ring anyway.

2. THE TEXTURE SIZE. A .tga carries no mipmaps -- only .blp does -- so the
   client is minifying a single image straight down to display size, and the
   further that has to travel the more it shimmers. 32x32 against a ~20px
   draw is a mild reduction; 64x64 is three times over and reads as noise.
   Still a power of two, which 1.12 requires either way.

3. SHARPENING AFTER THE DOWNSCALE. A large LANCZOS reduction always softens.
   At this size soft reads as blurry, so a modest unsharp pass goes back over
   it -- modest, because overdoing it puts halos on the gold edges.

Output format matches media/ResizeGrip.tga, which is already proven on the
1.12 client: uncompressed true-colour, 32-bit, bottom-up, BGRA.
"""

import os
import struct
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "minimap-source.jpg")
DST = os.path.join(HERE, "minimap.tga")

SIZE = 32                 # see note 2
CENTRE = (512, 470)       # the winged envelope sits a little above centre
RADIUS = 320              # inside the rings -- see note 1
SS = 8                    # supersample factor for the circular mask


def build_icon():
    src = Image.open(SRC).convert("RGB")
    cx, cy = CENTRE
    im = src.crop((cx - RADIUS, cy - RADIUS, cx + RADIUS, cy + RADIUS))

    big = im.resize((SIZE * SS, SIZE * SS), Image.LANCZOS)
    icon = big.resize((SIZE, SIZE), Image.LANCZOS)
    icon = icon.filter(ImageFilter.UnsharpMask(radius=1.0, percent=90,
                                               threshold=2))

    mask = Image.new("L", (SIZE * SS, SIZE * SS), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, SIZE * SS - 1, SIZE * SS - 1), fill=255)
    icon = icon.convert("RGBA")
    icon.putalpha(mask.resize((SIZE, SIZE), Image.LANCZOS))
    return icon


def write_tga(path, im):
    w, h = im.size
    assert w & (w - 1) == 0 and h & (h - 1) == 0, "1.12 needs powers of two"
    px = im.load()
    hdr = struct.pack("<BBBHHBHHHHBB",
                      0,        # no id field
                      0,        # no colour map
                      2,        # uncompressed true-colour
                      0, 0, 0,  # colour map spec
                      0, 0,     # x/y origin
                      w, h,
                      32,       # bits per pixel
                      8)        # 8 alpha bits, origin bottom-left
    body = bytearray()
    for y in range(h - 1, -1, -1):        # bottom row first
        for x in range(w):
            r, g, b, a = px[x, y]
            body += bytes((b, g, r, a))   # TGA is BGRA
    with open(path, "wb") as f:
        f.write(hdr + bytes(body))
    return len(hdr) + len(body)


if __name__ == "__main__":
    n = write_tga(DST, build_icon())
    print("wrote %s -- %dx%d, %d bytes" % (DST, SIZE, SIZE, n))

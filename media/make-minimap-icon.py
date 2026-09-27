#!/usr/bin/env python3
"""Regenerate media/minimap.tga from media/minimap-source.jpg.

Kept in the repo because an icon nobody can rebuild is an icon nobody can
adjust. Needs Pillow; nothing in the addon runs it.

THE WHOLE PROBLEM IS THAT THE DESTINATION IS TINY. The source art is 1024 x
1024 and perfectly clean -- a 20px minimap icon is 400 pixels, which is 0.04%
of it. No amount of source quality survives that reduction, so the only real
lever is giving the logo MORE PIXELS to land in.

So the button does not use Blizzard's MiniMap-TrackingBorder. That ring is
drawn around a 20px icon inside a 31px button, and this logo already has a
gold ring of its own -- it is shaped like a minimap button already. Dropping
the border lets the emblem have the whole button instead of the middle of it:
30px instead of 20px, which is two and a quarter times the pixels.

TEXTURE SIZE IS MATCHED TO THE DRAW SIZE, not maximised. A .tga carries no
mipmaps where a .blp does, so the client minifies one image straight down to
whatever size it is drawn at, and the further that has to travel the more it
shimmers -- the first version was 64px crushed into 20 and read as mush.
32px against a 30px draw is as close to 1:1 as a power of two gets. If it ever
looks SOFT rather than noisy, the answer is to raise SIZE, not lower it.

A modest unsharp pass goes back over it because a large LANCZOS reduction
always softens; modest, because overdoing it puts halos on the gold edges.

Output format matches media/ResizeGrip.tga, which is already proven on the
1.12 client: uncompressed true-colour, 32-bit, bottom-up, BGRA.
"""

import os
import struct
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "minimap-source.jpg")
DST = os.path.join(HERE, "minimap.tga")

SIZE = 32                 # matched to the ~30px the button draws it at
# The WHOLE logo, rings and all. Cropping in buys legibility at 20px, but at
# 30px there is room for the emblem as drawn, and the rings are what make it
# read as this addon rather than as a generic envelope.
CENTRE = (512, 512)
RADIUS = 500              # just inside the edge, so the circle does not clip flat
SS = 8                    # supersample factor for the circular mask


def build_icon():
    src = Image.open(SRC).convert("RGB")
    cx, cy = CENTRE
    im = src.crop((cx - RADIUS, cy - RADIUS, cx + RADIUS, cy + RADIUS))

    big = im.resize((SIZE * SS, SIZE * SS), Image.LANCZOS)
    icon = big.resize((SIZE, SIZE), Image.LANCZOS)
    icon = icon.filter(ImageFilter.UnsharpMask(radius=0.8, percent=70,
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

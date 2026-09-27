# media/

`minimap.tga` and `minimap-ring.tga` are **generated**. Do not edit them by
hand — change `make-minimap-icon.py` and re-run it:

```sh
pip install Pillow
python3 media/make-minimap-icon.py
```

The pipeline is a port of **Aegis: Pathfinder**'s `Tools/make_assets.py`. The
two addons ship buttons on the same minimap, so they are built the same way
and should not be allowed to drift.

## Format

| Property | Value |
|---|---|
| Type | 10 — RLE-compressed truecolor |
| Depth | 32-bit |
| Origin | bottom-left (descriptor byte `0x08`, 8 alpha bits) |
| Colour map | none |
| ID field | none |
| Dimensions | powers of two |

`tests/harness.lua` checks the header of `minimap.tga` on every run, so a
texture that would not load is caught before it is committed. The older
`ResizeGrip.tga` is type 2 (uncompressed) and loads just as well — both are
fine on 1.12; new art follows Pathfinder.

Textures are referenced **without a file extension**
(`Interface\AddOns\Aegis_Courier\media\minimap`); the client appends `.blp` or
`.tga` itself. A texture is not a `.toc` line, so adding one costs no client
restart.

## Contents

| File | Size | Purpose |
|---|---|---|
| `minimap.tga` | 64×64 | The minimap button's face: the Aegis: Courier logo, full colour, from `minimap-source.jpg` |
| `minimap-ring.tga` | 32×32 | Hover ring, a **white mask** tinted gold in Lua with `SetVertexColor` |
| `ResizeGrip.tga` | 16×16 | The window's bottom-right resize grip |
| `minimap-source.jpg` | 1024×1024 | The logo art the icon is built from |

Screenshots and `aegis-courier-logo.jpg` are documentation, not used at
runtime.

## Two things worth knowing before changing the icon

**The destination is tiny and that is the whole problem.** A 20px minimap icon
is 400 pixels — 0.04% of a 1024² source. No source resolution survives that,
so the levers are giving the art more pixels and putting less in them, never a
bigger source file.

**Reduce by halving, not in one jump.** `minimap_logo()` halves the source
repeatedly before its final resize, because a single 1024 → 64 reduction
aliases: fine detail lands between output pixels and turns to grain, which is
exactly what reads as "pixelated". Repeated halving averages each level into
the next — the same thing a mipmap chain does, which a `.tga` does not carry.

## Why there is no border texture

The logo is already a disc with a gold and red rune ring, so the button draws
it at full size and skips Blizzard's `MiniMap-TrackingBorder` entirely.
Drawing that would be a second ring around the first, with the emblem squeezed
into the middle of its own button at 20px instead of 32. Pathfinder's button
does the same for the same reason.

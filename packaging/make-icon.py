#!/usr/bin/env python3
"""Generate the Decarta app icon: a pixel-font `d` on a white rounded square.

The letter is a 5x7 bitmap drawn as literal filled squares, so its pixels stay hard-edged
at every size — that is the whole point of the look. Only the rounded-square background is
supersampled, because a stair-stepped corner would just look like a bug.

    packaging/make-icon.py            # writes packaging/Decarta.icns + a preview PNG

Run it only when the design changes; packaging/build-app.sh just copies the .icns.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

CANVAS = 1024          # macOS icon canvas
BODY = 824             # the rounded square inside it (Apple's grid)
RADIUS = 185
CELL = 84              # size of one bitmap pixel in the glyph

# A lowercase `d`: stem down the right, bowl at the bottom left.
GLYPH = [
    "....#",
    "....#",
    "....#",
    ".####",
    "#...#",
    "#...#",
    ".####",
]

INK = (0, 0, 0, 255)
PAPER = (255, 255, 255, 255)

# Pillow moved the resampling constants; this works on both spellings.
RESAMPLE = getattr(Image, "Resampling", Image).LANCZOS

ICONSET = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def render() -> Image.Image:
    # Background first, at 4x, so the rounded corners are smooth.
    supersample = 4
    big = Image.new("RGBA", (CANVAS * supersample, CANVAS * supersample), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    ImageDraw.Draw(big).rounded_rectangle(
        [offset * supersample, offset * supersample,
         (offset + BODY) * supersample, (offset + BODY) * supersample],
        radius=RADIUS * supersample, fill=PAPER,
    )
    icon = big.resize((CANVAS, CANVAS), RESAMPLE)

    # Glyph second, at 1x and with no antialiasing, so the pixels stay square.
    draw = ImageDraw.Draw(icon)
    glyph_w = max(len(row) for row in GLYPH) * CELL
    glyph_h = len(GLYPH) * CELL
    x0 = (CANVAS - glyph_w) // 2
    y0 = (CANVAS - glyph_h) // 2
    for row, line in enumerate(GLYPH):
        for col, cell in enumerate(line):
            if cell != "#":
                continue
            x = x0 + col * CELL
            y = y0 + row * CELL
            draw.rectangle([x, y, x + CELL - 1, y + CELL - 1], fill=INK)
    return icon


def main() -> int:
    root = Path(__file__).resolve().parent
    master = render()
    # The 1024 master is a byproduct of the .icns; keep it out of the repo.
    master_png = Path("/tmp/decarta-icon-1024.png")
    master.save(master_png)

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "Decarta.iconset"
        iconset.mkdir()
        for name, size in ICONSET:
            master.resize((size, size), RESAMPLE).save(iconset / name)
        out = root / "Decarta.icns"
        result = subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)],
                                capture_output=True, text=True)
        if result.returncode != 0:
            print(f"iconutil failed: {result.stderr.strip()}", file=sys.stderr)
            return 1

    preview = Path("/tmp/icon_preview.png")
    master.resize((512, 512), RESAMPLE).save(preview)

    print("glyph:")
    for line in GLYPH:
        print("   " + line.replace("#", "█").replace(".", "·"))
    print()
    print(f"  {out}  ({out.stat().st_size // 1024} KB)")
    print(f"  {master_png}  (master, {CANVAS}x{CANVAS})")
    print(f"  {preview}  (preview)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
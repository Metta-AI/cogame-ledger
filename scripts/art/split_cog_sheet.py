#!/usr/bin/env python3
"""Turn the nano-banana cog sheet into Ledger's four sprite kits.

`source/cogs_sheet.png` is one render of four Softmax cogs on a flat chroma
backdrop (see `gen_cog_sheet.py`). Gemini does not return alpha, and the
"pure green" you asked for comes back as *some* green with a tinted edge, so:

  1. take the backdrop colour as the MEDIAN of the border pixels (a corner
     sometimes carries a smudge, the median does not care);
  2. flood-fill transparency inward FROM the border, so green accents inside
     a character survive;
  3. shave the one-pixel chroma fringe the fill leaves behind;
  4. split the row on empty columns, crop, pad to a square, and resize with
     NEAREST so the pixel art stays pixel art.

This script OWNS these files and they are not hand-edited:

    data/soldier_red_front.png     the ledger-book cog
    data/soldier_blue_front.png    the coin-sack cog
    data/soldier_green_front.png   the balance-scale cog
    data/soldier_yellow_front.png  the parchment-and-quill cog

The names are babel's, kept on purpose: `client/renderer.js`,
`tools/build_replay_viewer.sh` and the server's `/client/assets` route all
refer to them. The other assets in `data/` (arena_floor.png, font.ttf) are
still coworld-ctf's and this script does not own them.

    python3 -m pip install --user pillow
    python3 scripts/art/split_cog_sheet.py
"""

import pathlib
import sys
from collections import deque

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHEET = ROOT / "scripts" / "art" / "source" / "cogs_sheet.png"
OUT_DIR = ROOT / "data"

# Left to right on the sheet.
KITS = ["red", "blue", "green", "yellow"]
SIZE = 128
# Squared-distance thresholds in RGB. The backdrop is a light green and the
# green cog's plating is far darker, so a generous fill threshold is still
# nowhere near it.
FILL_TOLERANCE = 70 ** 2
FRINGE_TOLERANCE = 95 ** 2
MIN_COLUMN_PIXELS = 2


def squared(a, b):
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2


def border_median(image):
    width, height = image.size
    pixels = image.load()
    reds, greens, blues = [], [], []
    for x in range(width):
        for y in (0, height - 1):
            r, g, b = pixels[x, y][:3]
            reds.append(r)
            greens.append(g)
            blues.append(b)
    for y in range(height):
        for x in (0, width - 1):
            r, g, b = pixels[x, y][:3]
            reds.append(r)
            greens.append(g)
            blues.append(b)
    reds.sort()
    greens.sort()
    blues.sort()
    middle = len(reds) // 2
    return (reds[middle], greens[middle], blues[middle])


def key_out(image, backdrop):
    """Flood-fill alpha 0 inward from every border pixel that is backdrop."""
    width, height = image.size
    pixels = image.load()
    seen = bytearray(width * height)
    queue = deque()

    def push(x, y):
        if 0 <= x < width and 0 <= y < height and not seen[y * width + x]:
            seen[y * width + x] = 1
            if squared(pixels[x, y], backdrop) <= FILL_TOLERANCE:
                pixels[x, y] = (0, 0, 0, 0)
                queue.append((x, y))

    for x in range(width):
        push(x, 0)
        push(x, height - 1)
    for y in range(height):
        push(0, y)
        push(width - 1, y)
    while queue:
        x, y = queue.popleft()
        push(x + 1, y)
        push(x - 1, y)
        push(x, y + 1)
        push(x, y - 1)

    # Shave the fringe: an opaque pixel that is still nearly the backdrop and
    # touches transparency is the anti-aliased edge, not the character.
    fringe = []
    for y in range(height):
        for x in range(width):
            if pixels[x, y][3] == 0:
                continue
            if squared(pixels[x, y], backdrop) > FRINGE_TOLERANCE:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height and \
                        pixels[nx, ny][3] == 0:
                    fringe.append((x, y))
                    break
    for x, y in fringe:
        pixels[x, y] = (0, 0, 0, 0)
    return image


def column_runs(image):
    """The x ranges that hold anything, merged across small gaps."""
    width, height = image.size
    pixels = image.load()
    filled = []
    for x in range(width):
        count = 0
        for y in range(height):
            if pixels[x, y][3] > 0:
                count += 1
                if count >= MIN_COLUMN_PIXELS:
                    break
        filled.append(count >= MIN_COLUMN_PIXELS)
    runs = []
    start = None
    for x, on in enumerate(filled):
        if on and start is None:
            start = x
        elif not on and start is not None:
            runs.append((start, x))
            start = None
    if start is not None:
        runs.append((start, width))
    # Keep the widest `len(KITS)` runs, then put them back in x order: a
    # stray keyed speck must not become a sprite.
    runs.sort(key=lambda run: run[1] - run[0], reverse=True)
    runs = sorted(runs[:len(KITS)])
    return runs


def square(image):
    box = image.getbbox()
    if box is None:
        raise SystemExit("a split produced an empty sprite")
    cropped = image.crop(box)
    side = max(cropped.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(cropped, ((side - cropped.width) // 2,
                           side - cropped.height))
    return canvas.resize((SIZE, SIZE), Image.NEAREST)


def main() -> int:
    if not SHEET.exists():
        print(f"missing {SHEET}; run gen_cog_sheet.py first", file=sys.stderr)
        return 2
    sheet = Image.open(SHEET).convert("RGBA")
    backdrop = border_median(sheet)
    print(f"backdrop {backdrop}")
    keyed = key_out(sheet, backdrop)
    runs = column_runs(keyed)
    if len(runs) != len(KITS):
        print(f"expected {len(KITS)} cogs, found {len(runs)}: {runs}",
              file=sys.stderr)
        return 1
    for kit, (left, right) in zip(KITS, runs):
        strip = keyed.crop((left, 0, right, keyed.height))
        out = OUT_DIR / f"soldier_{kit}_front.png"
        square(strip).save(out)
        print(f"wrote {out} from x {left}..{right}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Generate Ledger's cog sheet with nano-banana (Gemini image generation).

One sheet, four cogs, one render: a single call keeps the style consistent
across the four sprite kits in a way four separate calls never do. The sheet
is committed under `source/` and `split_cog_sheet.py` turns it into the four
`data/soldier_<colour>_front.png` sprites the viewer draws — Ledger keeps
babel's file names because `client/renderer.js`, `tools/build_replay_viewer.sh`
and the server's asset route all refer to them.

The key is NEVER printed, written to a file, or passed as a URL parameter: it
travels as the `x-goog-api-key` header and nowhere else.

    GEMINI_API_KEY=... python3 scripts/art/gen_cog_sheet.py
"""

import base64
import json
import os
import pathlib
import sys
import urllib.request

MODEL = "gemini-2.5-flash-image"
ENDPOINT = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    f"{MODEL}:generateContent"
)

ROOT = pathlib.Path(__file__).resolve().parents[2]
# The canonical Softmax cog, as this repo already ships it: wheeled robot,
# screen face, riveted shoulders.
REFERENCE = ROOT / "data" / "soldier_red_front.png"
OUT = ROOT / "scripts" / "art" / "source" / "cogs_sheet.png"

PROMPT = """Using this robot character ("cog") as the exact character design
reference, draw FOUR of these cogs side by side in one row, evenly spaced,
same size, full body, front-facing, standing on their wheels, same clean
cartoon rendering with the same chunky outlines and the same glowing
twin-dot screen face.

Background: perfectly flat, solid, uniform pure bright green (#00FF00), no
shadows, no gradients, no floor line, no vignette - it will be chroma-keyed
out. Leave a clear vertical gap of flat green between the cogs.

Each cog is one seat at a table of eight in a game about reputation, so each
one must be recognisable at thumbnail size by its COLOUR and by ONE large,
high-contrast prop with a distinct silhouette:

1. LEFT - RED cog (#e0523a plating): holds up a big open LEDGER BOOK against
   its chest, thick pages, dark cover, clearly a book.
2. SECOND - BLUE cog (#3f7cc4 plating): holds a fat round COIN SACK in one
   arm, tied at the neck, with two or three gold coins spilling over the top.
3. THIRD - GREEN cog (#45a85e plating): holds up a two-pan BALANCE SCALE, the
   beam horizontal and both pans clearly visible.
4. RIGHT - YELLOW cog (#ddc531 plating): holds a large rolled PARCHMENT NOTE
   in one hand and a tall white QUILL in the other.

No text, no letters, no numbers, no labels, no speech bubbles anywhere."""


def main() -> int:
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        print("GEMINI_API_KEY is not set", file=sys.stderr)
        return 2
    reference = base64.b64encode(REFERENCE.read_bytes()).decode()
    body = {
        "contents": [
            {
                "parts": [
                    {"inline_data": {"mime_type": "image/png",
                                     "data": reference}},
                    {"text": PROMPT},
                ]
            }
        ],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={"x-goog-api-key": key, "content-type": "application/json"},
    )
    try:
        response = json.load(urllib.request.urlopen(request, timeout=180))
    except urllib.error.HTTPError as error:
        # A 429 is quota (wait a minute); a 400 SAFETY / IMAGE_OTHER means
        # re-word the prompt rather than retry it.
        print(f"HTTP {error.code}: {error.read()[:800]!r}", file=sys.stderr)
        return 1
    parts = response["candidates"][0]["content"]["parts"]
    image = next(p for p in parts if "inlineData" in p)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(base64.b64decode(image["inlineData"]["data"]))
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

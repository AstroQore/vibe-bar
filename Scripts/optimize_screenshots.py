#!/usr/bin/env python3
"""Shrink README screenshots without visibly changing them.

`screencapture` writes 32-bit RGBA PNGs; a Vibe Bar surface over a flat
backdrop uses a few hundred distinct colours. Flattening to RGB and
quantising to a 256-colour palette (median cut, no dither — dither would
put noise into flat fills and text edges) cuts each file to roughly a third
with no difference at 1:1. Needs Pillow; `capture_demo_screenshots.sh`
calls this when it is importable and keeps the originals when it is not.

    ./Scripts/optimize_screenshots.py docs/screenshots/*.png
"""

from __future__ import annotations

import os
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover - exercised only on a machine without Pillow
    print("optimize: Pillow is not installed; leaving the PNGs as captured", file=sys.stderr)
    sys.exit(0)


def optimize(path: str) -> tuple[int, int]:
    before = os.path.getsize(path)
    image = Image.open(path).convert("RGB")
    palette = image.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    palette.save(path, optimize=True)
    return before, os.path.getsize(path)


def main(paths: list[str]) -> int:
    total_before = total_after = 0
    for path in paths:
        before, after = optimize(path)
        total_before += before
        total_after += after
        print(f"optimize: {os.path.basename(path)}  {before // 1024}KB → {after // 1024}KB")
    if paths:
        print(f"optimize: {len(paths)} files  {total_before // 1024}KB → {total_after // 1024}KB")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

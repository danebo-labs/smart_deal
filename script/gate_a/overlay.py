"""Draws each derived T1 edge on top of the rendered page so the polyline can be
checked against the drawing by eye.

    python3 script/gate_a/overlay.py 3 22 39 ...
"""
import json
import sys

from PIL import Image, ImageDraw

DATA = json.load(open("tmp/gate_a_measurement.json"))
PAGES = {p["page"]: p for p in DATA["pages"]}
MEDIA_W, MEDIA_H = 960.0, 540.0


def to_px(pt, w, h):
    x, y = pt
    return (x / MEDIA_W * w, (1.0 - y / MEDIA_H) * h)


for n in (int(a) for a in sys.argv[1:]):
    src = f"tmp/gate_a_png/p-{n:02d}.png"
    im = Image.open(src).convert("RGB")
    w, h = im.size
    d = ImageDraw.Draw(im)

    for edge in PAGES[n]["edges"]:
        chain = [to_px(v, w, h) for v in edge["chain"]]
        d.line(chain, fill=(255, 0, 255), width=9)
        for x, y in (chain[0], chain[-1]):
            d.ellipse([x - 16, y - 16, x + 16, y + 16], outline=(255, 0, 255), width=7)
        d.text((chain[0][0] + 20, chain[0][1] + 20), f'{edge["from"]} <-> {edge["to"]}',
               fill=(255, 0, 255))

    out = f"tmp/gate_a_png/overlay-{n:02d}.png"
    im.save(out)
    print(out)

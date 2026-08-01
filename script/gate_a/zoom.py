"""Gate A-bis helper: side-by-side zoom of ONE derived edge.

overlay.py draws every edge of a page at once, in magenta — which is also the
colour of several real cables in this document. To judge an edge you need to
see what is drawn *without* the overlay next to the single polyline the
deriver claims, in a colour the document does not use. This crops the clean
render to the chain's bounding box and pairs it with the same crop carrying
just that one chain, drawn yellow-on-black.

    python3 script/gate_a/zoom.py 3          # every edge of page 3
    python3 script/gate_a/zoom.py 3 22 39    # several pages

Output: tmp/gate_a_png/zoom-NN-K.png (K = index of the edge on that page).
Expects tmp/gate_a_png/p-NN.png (`pdftoppm -r 150 -png`).
"""
import json
import re
import sys

from PIL import Image, ImageDraw

DATA = json.load(open("tmp/gate_a_measurement.json"))
PAGES = {p["page"]: p for p in DATA["pages"]}
MEDIA_W, MEDIA_H = 960.0, 540.0
PAD_PT = 60.0

# `evidence` is the only place the two cited label bboxes are written down:
#   "... une FINALES (x 395-428, y 98-106) con CONECTOR AI (x 316-382, y 231-240)"
EVIDENCE_BBOX = re.compile(r"\(x ([\d.]+)-([\d.]+), y ([\d.]+)-([\d.]+)\)")


def label_boxes(edge):
    return [tuple(float(v) for v in m) for m in EVIDENCE_BBOX.findall(edge["evidence"])]


def box_px(chain, w, h):
    xs = [v[0] for v in chain]
    ys = [v[1] for v in chain]
    x0 = max(0.0, min(xs) - PAD_PT) / MEDIA_W * w
    x1 = min(MEDIA_W, max(xs) + PAD_PT) / MEDIA_W * w
    y0 = (1.0 - min(MEDIA_H, max(ys) + PAD_PT) / MEDIA_H) * h
    y1 = (1.0 - max(0.0, min(ys) - PAD_PT) / MEDIA_H) * h
    return (int(x0), int(y0), int(x1), int(y1))


def to_px(pt, w, h):
    x, y = pt
    return (x / MEDIA_W * w, (1.0 - y / MEDIA_H) * h)


for n in (int(a) for a in sys.argv[1:]):
    clean = Image.open(f"tmp/gate_a_png/p-{n:02d}.png").convert("RGB")
    w, h = clean.size

    for k, edge in enumerate(PAGES[n]["edges"]):
        over = clean.copy()
        d = ImageDraw.Draw(over)
        chain = [to_px(v, w, h) for v in edge["chain"]]
        d.line(chain, fill=(0, 0, 0), width=13)
        d.line(chain, fill=(255, 255, 0), width=5)
        for x, y in (chain[0], chain[-1]):
            d.ellipse([x - 20, y - 20, x + 20, y + 20], outline=(0, 0, 0), width=9)
            d.ellipse([x - 20, y - 20, x + 20, y + 20], outline=(255, 255, 0), width=4)

        corners = []
        for x0, x1, y0, y1 in label_boxes(edge):
            a0 = to_px((x0, y1), w, h)
            a1 = to_px((x1, y0), w, h)
            d.rectangle([a0, a1], outline=(0, 200, 255), width=6)
            corners += [(x0, y0), (x1, y1)]

        box = box_px(edge["chain"] + corners, w, h)
        a, b = clean.crop(box), over.crop(box)
        cw, ch = a.size
        canvas = Image.new("RGB", (cw * 2 + 12, ch), (255, 255, 255))
        canvas.paste(a, (0, 0))
        canvas.paste(b, (cw + 12, 0))
        out = f"tmp/gate_a_png/zoom-{n:02d}-{k}.png"
        canvas.save(out)
        print(f'{out}  {edge["from"]} <-> {edge["to"]}')

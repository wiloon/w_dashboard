#!/usr/bin/env python3
"""Generate WDashboard.icns — a dashboard 2x2 tile grid on a blue squircle,
one tile amber to nod to the pomodoro feature."""
import os, subprocess, tempfile
from PIL import Image, ImageDraw

SS = 4                       # supersampling factor
BASE = 1024
S = BASE * SS
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources")

def lerp(a, b, t): return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

# ---- diagonal background gradient ------------------------------------------
TOP_LEFT  = (110, 168, 254)   # #6EA8FE
BOT_RIGHT = (37, 84, 199)     # #2554C7
grad = Image.new("RGB", (S, S))
gp = grad.load()
for y in range(S):
    for x in range(S):
        t = (x + y) / (2 * (S - 1))
        gp[x, y] = lerp(TOP_LEFT, BOT_RIGHT, t)

# ---- squircle-ish rounded-rect mask (Apple content box: 824/1024) ----------
margin = round(S * 100 / 1024)
box = [margin, margin, S - margin, S - margin]
radius = round(S * 185 / 1024)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)

icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
icon.paste(grad, (0, 0), mask)

# ---- subtle top sheen -----------------------------------------------------
sheen = Image.new("L", (S, S), 0)
for y in range(S):
    a = max(0, int(70 * (1 - y / (S * 0.55))))
    ImageDraw.Draw(sheen).line([(0, y), (S, y)], fill=a)
sheen_mask = Image.composite(sheen, Image.new("L", (S, S), 0), mask)
icon = Image.alpha_composite(icon, Image.merge("RGBA", (
    Image.new("L", (S, S), 255), Image.new("L", (S, S), 255),
    Image.new("L", (S, S), 255), sheen_mask)))

# ---- 2x2 tile grid ------------------------------------------------------------
d = ImageDraw.Draw(icon)
area = round(S * 512 / 1024)
gap = round(S * 46 / 1024)
tile = (area - gap) // 2
trad = round(tile * 0.22)
ox = (S - area) // 2
oy = (S - area) // 2
AMBER = (245, 166, 35)        # #F5A623
WHITE = (255, 255, 255)
cells = [(0, 0), (1, 0), (0, 1), (1, 1)]
amber_cell = (1, 1)
for cx, cy in cells:
    x0 = ox + cx * (tile + gap)
    y0 = oy + cy * (tile + gap)
    rect = [x0, y0, x0 + tile, y0 + tile]
    if (cx, cy) == amber_cell:
        d.rounded_rectangle(rect, radius=trad, fill=AMBER + (255,))
    else:
        d.rounded_rectangle(rect, radius=trad, fill=WHITE + (235,))

# ---- downsample & write .icns into Resources/ ------------------------------
icon = icon.resize((BASE, BASE), Image.LANCZOS)
specs = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
icns = os.path.abspath(os.path.join(OUT, "WDashboard.icns"))
with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "WDashboard.iconset")
    os.makedirs(iconset)
    for size, scale in specs:
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
print("wrote", icns)

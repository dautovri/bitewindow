"""BiteCurve iPhone screenshots (shotkit.py), English.

Inputs: real simulator captures in RAW named en-{detail,forecast,outlook,map,log}.png
(Debug build, sample spots, Central time). Teal canvas, white headline at the
top, the real screen in an iPhone frame running off the bottom edge.
No prices and no "free"/"Pro" wording.

Usage: python3 compose.py RAW OUT
"""
import os, sys
from PIL import Image
from shotkit import Slide

RAW, OUT = sys.argv[1], sys.argv[2]
TEAL, GLOW = (0, 137, 150), (48, 190, 201)

SLIDES = [
    # (capture, eyebrow, headline, phone options)
    ("detail",   "Weather, sun, moon and tide",   "Know the best hours\nto fish today",     {}),
    ("forecast", "Every spot you fish",           "One bite index\nfor each spot",          {}),
    ("outlook",  "The days ahead",                "Pick your day\nbefore you drive",        {}),
    ("map",      "Your own spots",                "Drop a pin\nwhere you fish",             {"top": 800}),
    ("log",      "Blank trips count too",         "A log that learns\nyour water",          {}),
]

os.makedirs(OUT, exist_ok=True)
for i, (name, eyebrow, headline, opts) in enumerate(SLIDES, 1):
    s = Slide(color=TEAL, glow=GLOW, ink=(255, 255, 255))
    s.text(eyebrow, headline)
    s.phone(Image.open(f"{RAW}/en-{name}.png"), **opts)
    s.save(f"{OUT}/{i:02d}.png")
print(len(SLIDES), "slides in", OUT)

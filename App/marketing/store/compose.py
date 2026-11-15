"""BiteCurve iPhone screenshots (shotkit.py), ten slides in every App Store language.

Inputs: real simulator captures in RAW named <locale>-<screen>.png, taken on a
simulator set to that language (Debug build, sample spots plus Tampa Bay), and
captions.json (locale -> ten [eyebrow, headline] pairs, in slide order).
Teal canvas, white headline at the top, the real screen in an iPhone frame
running off the bottom edge. No prices and no "free"/"Pro" wording.

Usage: python3 compose.py RAW OUT [locale ...]
"""
import json, os, sys
from PIL import Image, ImageFont
import shotkit
from shotkit import Slide

RAW, OUT, ONLY = sys.argv[1], sys.argv[2], sys.argv[3:]
TEAL, GLOW = (0, 137, 150), (48, 190, 201)

# Screens in slide order; captions.json follows the same order.
SCREENS = ["detail", "forecast", "planner", "factors", "fishmap", "tide", "widgets", "search", "log", "check"]

# SF Pro has no CJK glyphs: (file, index) for the headline and the eyebrow.
HIRAGINO = "/System/Library/Fonts/ヒラギノ角ゴシック W{}.ttc"
CJK = {
    "ja": ((HIRAGINO.format(8), 0), (HIRAGINO.format(6), 0)),
    "ko": (("/System/Library/Fonts/AppleSDGothicNeo.ttc", 6), ("/System/Library/Fonts/AppleSDGothicNeo.ttc", 4)),
    "zh-Hans": (("/System/Library/Fonts/Hiragino Sans GB.ttc", 2), ("/System/Library/Fonts/Hiragino Sans GB.ttc", 2)),
}
sf_font = shotkit.font

captions = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "captions.json")))
for locale, slides in captions.items():
    if ONLY and locale not in ONLY:
        continue
    if locale in CJK:
        heavy, semi = CJK[locale]
        shotkit.font = lambda weight, size, h=heavy, e=semi: ImageFont.truetype((h if weight == "Heavy" else e)[0], size, index=(h if weight == "Heavy" else e)[1])
    else:
        shotkit.font = sf_font
    os.makedirs(f"{OUT}/{locale}", exist_ok=True)
    for i, (name, (eyebrow, headline)) in enumerate(zip(SCREENS, slides), 1):
        s = Slide(color=TEAL, glow=GLOW, ink=(255, 255, 255))
        s.text(eyebrow, headline)
        s.phone(Image.open(f"{RAW}/{locale}-{name}.png"))
        s.save(f"{OUT}/{locale}/{i:02d}.png")
    print(locale, len(slides), "slides")

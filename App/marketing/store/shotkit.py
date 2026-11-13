"""Shared App Store screenshot layout (iPhone 6.9", 1320x2868), app-agnostic.

Rules come from a coded study of the 70 non-game apps in the US top-free and
top-grossing charts (2026-11, portfolio-metrics/research/2026-11-screenshot-
benchmark): the caption sits at the top (67/70) and should be large, since
caption size drove thumbnail readability most; the phone is framed and runs
off the bottom edge (36/70), because a whole phone kept inside the slide read
worst. Background is the app's own colour, or light/dark; there is no single
convention. The eyebrow line above the headline is optional (12/70).

Every slide shows a real, unedited capture; zoom only enlarges real pixels.
No prices or "free" wording in captions; that is the caller's job.

    from shotkit import Slide
    s = Slide(color=(255, 196, 0), glow=(255, 214, 77))
    s.text(None, "Your next train,\\nlive")
    s.phone(Image.open("board.png"))
    s.save("01.png")
"""
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1320, 2868
MARGIN = 96
FONTS = "/Library/Fonts/SF-Pro-Display-{}.otf"

# Phone geometry: screen 1068 wide, bezel 34 around it.
SCREEN_W = 1068
BEZEL = 34
PHONE_W = SCREEN_W + 2 * BEZEL          # 1136, 86% of the canvas
TOP_Y = 668                              # phone top on normal slides
FLIP_BOTTOM = 2088                       # phone bottom on flipped slides


def font(weight, size):
    return ImageFont.truetype(FONTS.format(weight), size)


def _fit(draw, text, weight, size, min_size, width):
    f = font(weight, size)
    while max(draw.textlength(line, font=f) for line in text.split("\n")) > width and size > min_size:
        size -= 4
        f = font(weight, size)
    return f


class Slide:
    def __init__(self, color, glow=None, ink=(11, 12, 14), sub_ink=None):
        """color: the canvas colour; glow: an optional lighter colour bloomed
        in behind the caption; ink: headline colour (dark on light/brand
        colours, white on dark)."""
        self.ink = ink
        self.sub_ink = sub_ink or tuple(int(c * 0.72 + b * 0.28) for c, b in zip(ink, color))
        self.img = Image.new("RGB", (W, H), color)
        if glow:
            m = Image.new("L", (W, H), 0)
            ImageDraw.Draw(m).ellipse((-500, -720, W + 500, 1480), fill=255)
            m = m.filter(ImageFilter.GaussianBlur(320))
            self.img.paste(Image.new("RGB", (W, H), glow), (0, 0), m.point(lambda v: int(v * 0.8)))

    # Text block: optional eyebrow (one line) above the headline (1–3 lines).
    def text(self, eyebrow, headline, top=150, flipped=False):
        d = ImageDraw.Draw(self.img)
        ef = _fit(d, eyebrow, "Semibold", 50, 36, W - 2 * MARGIN) if eyebrow else None
        hf = _fit(d, headline, "Heavy", 128, 88, W - 2 * MARGIN)
        lines = headline.split("\n")
        lead = int(hf.size * 1.06)
        block = (ef.size + 30 if ef else 0) + lead * len(lines)
        y = top if not flipped else FLIP_BOTTOM + (H - FLIP_BOTTOM - block) // 2
        if ef:
            d.text(((W - d.textlength(eyebrow, font=ef)) / 2, y), eyebrow, font=ef, fill=self.sub_ink)
            y += ef.size + 30
        for line in lines:
            d.text(((W - d.textlength(line, font=hf)) / 2, y), line, font=hf, fill=self.ink)
            y += lead
        return y

    def icon(self, icon, name, top=118, size=236):
        """App icon with its name, for slide 1."""
        ic = icon.convert("RGBA").resize((size, size), Image.LANCZOS)
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * 0.225), fill=255)
        shadow = Image.new("RGBA", (size + 160, size + 160), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle((80, 104, size + 80, size + 104), radius=int(size * 0.225), fill=(20, 24, 40, 70))
        shadow = shadow.filter(ImageFilter.GaussianBlur(30))
        x = (W - size) // 2
        self.img.paste(shadow, (x - 80, top - 80), shadow)
        self.img.paste(ic, (x, top), mask)
        d = ImageDraw.Draw(self.img)
        f = font("Semibold", 54)
        d.text(((W - d.textlength(name, font=f)) / 2, top + size + 26), name, font=f, fill=(30, 32, 38))
        return top + size + 26 + 54

    def phone(self, shot, top=TOP_Y, flipped=False, zoom=1.0, focus_y=0.0):
        """A real capture in an iPhone frame that runs off the canvas edge.

        zoom > 1 enlarges the capture inside the screen around focus_y
        (0 = top of the capture, 1 = bottom); it never adds content.
        """
        sh = shot.convert("RGB")
        screen_h = int(sh.height * SCREEN_W / sh.width)
        if zoom > 1.0:
            cw, ch = int(sh.width / zoom), int(sh.height / zoom)
            cx = (sh.width - cw) // 2
            cy = int(max(0, min(sh.height - ch, focus_y * sh.height - ch * focus_y)))
            sh = sh.crop((cx, cy, cx + cw, cy + ch))
        sh = sh.resize((SCREEN_W, screen_h), Image.LANCZOS)
        ph = screen_h + 2 * BEZEL
        layer = Image.new("RGBA", (PHONE_W, ph), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        d.rounded_rectangle((0, 0, PHONE_W - 1, ph - 1), radius=150, fill=(120, 122, 128, 255))   # titanium rim
        d.rounded_rectangle((6, 6, PHONE_W - 7, ph - 7), radius=144, fill=(18, 19, 22, 255))      # black bezel
        mask = Image.new("L", (SCREEN_W, screen_h), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, SCREEN_W - 1, screen_h - 1), radius=116, fill=255)
        layer.paste(sh, (BEZEL, BEZEL), mask)
        y = top if not flipped else FLIP_BOTTOM - ph
        x = (W - PHONE_W) // 2
        shadow = Image.new("RGBA", (PHONE_W + 240, ph + 240), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle((120, 144, PHONE_W + 120, ph + 144), radius=150, fill=(10, 14, 26, 70))
        shadow = shadow.filter(ImageFilter.GaussianBlur(55))
        self.img.paste(shadow, (x - 120, y - 120), shadow)
        self.img.paste(layer, (x, y), layer)

    def save(self, path):
        self.img.save(path)

"""Compose the BiteCurve App Store preview (iPhone 6.9", 886x1920, 30 fps).

Inputs: raw/<lang>.mp4 and raw/<lang>.marks from record.sh, a continuous
Simulator take of the real Debug app (iOS 27, iPhone 17 Pro Max) with the
three -BCSeedSpots sample spots and the live forecast for today. Captions
are the screenshot captions (../captions.json), teal canvas, white ink.
Cuts are calibrated on the first tap (the push to the spot detail).
App Review 2.3.4 (Random Walk, 2026-11-28): no
framing around the capture and no device frame, so the take fills the whole
886x1920 frame and the caption is a translucent panel laid over it (textual
overlays are allowed). Silent stereo AAC track, as App Store Connect expects.

Usage: python3 compose.py en de
"""
import os, subprocess, sys, tempfile
from PIL import Image, ImageChops, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import json
import shotkit
from shotkit import Slide

W, H, FPS = 886, 1920, 30
CAP_Y = 150  # default caption panel top (below the status bar); segments set their own
# y so the panel sits over the least important part of each screen
FADE = 0.35
YELLOW, GLOW = (0, 137, 150), (48, 190, 201)
INK, SUB = (255, 255, 255), None

_CAP = json.load(open(os.path.join(HERE, "..", "captions.json")))
# slide order in captions.json: detail, forecast, planner, factors, fishmap, tide, widgets, search, log, check
_IDX = {"list": 1, "detail": 0, "factors": 3, "planner": 2, "map": 7, "log": 8}
CAPTIONS = {lang: {k: tuple(_CAP[loc][i]) for k, i in _IDX.items()} for lang, loc in (("en", "en-US"), ("de", "de-DE"))}

OFFSET = 0.0  # set per take by calibrate()
APP_SHOWN = 0.0  # first new frame after the static Home Screen (app launch)


def calibrate(video, tap_mark):
    """Seconds to add to a mark to get video time: the first big frame change
    is the push animation that starts right after the first tap."""
    d = subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-vf", "fps=10,scale=8:16",
                        "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True, check=True).stdout
    n = 8 * 16
    frames = [d[i:i + n] for i in range(0, len(d) - n + 1, n)]
    for i in range(1, len(frames)):
        if sum(abs(x - y) for x, y in zip(frames[i], frames[i - 1])) / n > 4:
            return i / 10 - tap_mark - 0.1
    raise SystemExit("first tap not found")


def cfr(src, dst, end):
    """simctl recordVideo only writes a frame when the screen changes, so a
    static Home or Lock Screen is one long-held frame that -ss would skip.
    Re-time to constant 30 fps and hold the last frame to the take's end."""
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-fps_mode", "cfr", "-r", str(FPS),
                    "-an", "-c:v", "libx264", "-crf", "12", "-preset", "veryfast", dst], check=True)


def segments(marks, results=None):
    """(start in the take, seconds shown, caption key[, caption panel top y])."""
    o = OFFSET
    return [
        (max(0.0, o + marks["list"] + 0.5), 4.0, "list", 1480),
        (o + marks["detail"] + 1.0, 5.0, "detail", 1480),
        (o + marks["factors"] + 1.3, 4.0, "factors", 1480),
        (o + marks["planner"] + 1.0, 4.5, "planner", 1480),
        (o + marks["map"] + 1.5, 4.0, "map", 1100),
        (o + marks["log"] + 0.8, 4.0, "log", 1480),
    ]


def caption(eyebrow, headline, path, y=None):
    """Transparent full-frame overlay: the screenshot-style caption on a
    rounded brand-colour panel (98% opaque), cropped to the text."""
    y = CAP_Y if y is None else y
    blank = Slide(color=YELLOW, glow=GLOW, ink=INK, sub_ink=SUB).img.resize((W, H), Image.LANCZOS)
    s = Slide(color=YELLOW, glow=GLOW, ink=INK, sub_ink=SUB)
    s.text(eyebrow, headline, top=130)
    full = s.img.resize((W, H), Image.LANCZOS)
    x0, y0, x1, y1 = ImageChops.difference(full, blank).convert("L").point(lambda v: 255 if v > 24 else 0).getbbox()
    pad = 30
    box = (max(0, x0 - pad), max(0, y0 - pad), min(W, x1 + pad), min(H, y1 + pad))
    panel = full.crop(box).convert("RGBA")
    m = Image.new("L", panel.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, panel.width - 1, panel.height - 1), radius=40, fill=250)
    panel.putalpha(m)
    ov = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ov.paste(panel, ((W - panel.width) // 2, y), panel)
    ov.save(path)


def render(lang, tmp):
    marks = {}
    for line in open(os.path.join(HERE, "raw", f"{lang}.marks")):
        parts = line.split()
        if len(parts) == 2:
            try: marks[parts[0]] = float(parts[1])
            except ValueError: pass
    video = f"{tmp}/{lang}-cfr.mp4"
    cfr(os.path.join(HERE, "raw", f"{lang}.mp4"), video, marks["end"])
    global OFFSET
    OFFSET = calibrate(video, marks["detail"])
    print(lang, "offset", round(OFFSET, 2))
    segs = segments(marks)
    inputs, chains = [], []
    for i, (ss, secs, key, *cy) in enumerate(segs):
        ov = f"{tmp}/{lang}-{i}.png"
        caption(*CAPTIONS[lang][key], ov, cy[0] if cy else None)
        inputs += ["-ss", f"{ss:.3f}", "-t", str(secs + 1), "-i", video, "-loop", "1", "-t", str(secs), "-i", ov]
        v, o = 2 * i, 2 * i + 1
        # Fill the frame (cover) and centre-crop the few pixels the aspect differs by.
        chains.append(
            f"[{v}:v]fps={FPS},scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},"
            f"tpad=stop_mode=clone:stop_duration={secs},trim=duration={secs},setpts=PTS-STARTPTS[v{i}];"
            f"[{o}:v]fps={FPS},format=rgba,trim=duration={secs},setpts=PTS-STARTPTS[o{i}];"
            f"[v{i}][o{i}]overlay=0:0:shortest=1,format=yuv420p[s{i}]")
    graph = ";".join(chains)
    prev, offset = "s0", 0.0
    for i in range(1, len(segs)):
        offset += segs[i - 1][1] - FADE
        graph += f";[{prev}][s{i}]xfade=transition=fade:duration={FADE}:offset={offset:.3f}[x{i}]"
        prev = f"x{i}"
    total = sum(s[1] for s in segs) - FADE * (len(segs) - 1)
    out = os.path.join(HERE, "out", f"{lang}.mp4")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", *inputs,
                    "-f", "lavfi", "-t", f"{total:.3f}", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                    "-filter_complex", graph, "-map", f"[{prev}]", "-map", f"{2 * len(segs)}:a",
                    "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-r", str(FPS),
                    "-b:v", "10M", "-maxrate", "12M", "-bufsize", "20M",
                    "-c:a", "aac", "-b:a", "256k", "-t", f"{total:.3f}", "-movflags", "+faststart", out], check=True)
    print(lang, f"{total:.1f}s", out)


with tempfile.TemporaryDirectory() as tmp:
    for lang in sys.argv[1:]:
        render(lang, tmp)

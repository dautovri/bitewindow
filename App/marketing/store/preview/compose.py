"""Compose the BiteCurve App Store preview (iPhone 6.9", 886x1920, 30 fps).

Inputs: raw/<lang>.mp4 and raw/<lang>.marks from record.sh, a continuous
Simulator take of the real Debug app (iOS 27, iPhone 17 Pro Max) with the
three -BCSeedSpots sample spots and the live forecast for today. Captions
are the screenshot captions (../captions.json), teal canvas, white ink.
Cuts are calibrated on the first tap (the push to the spot detail).
Silent stereo AAC track, as App Store Connect expects.

Usage: python3 compose.py en de
"""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import json
import shotkit
from shotkit import Slide

W, H, FPS = 886, 1920, 30
APP_W = 640
APP_H = round(APP_W * 2868 / 1320 / 2) * 2
APP_X, APP_Y = (W - APP_W) // 2, 440
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
    """(start in the take, seconds shown, caption key)."""
    o = OFFSET
    return [
        (max(0.0, o + marks["list"] + 0.5), 4.0, "list"),
        (o + marks["detail"] + 1.0, 5.0, "detail"),
        (o + marks["factors"] + 1.3, 4.0, "factors"),
        (o + marks["planner"] + 1.0, 4.5, "planner"),
        (o + marks["map"] + 1.5, 4.0, "map"),
        (o + marks["log"] + 0.8, 4.0, "log"),
    ]


def card(eyebrow, headline, path):
    s = Slide(color=YELLOW, glow=GLOW, ink=INK, sub_ink=SUB)
    s.text(eyebrow, headline, top=130)
    s.img.resize((W, H), Image.LANCZOS).save(path)


def mask(path):
    m = Image.new("L", (APP_W, APP_H), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, APP_W - 1, APP_H - 1), radius=58, fill=255)
    m.save(path)


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
    m = f"{tmp}/mask.png"; mask(m)
    inputs, chains = [], []
    for i, (ss, secs, key) in enumerate(segs):
        bg = f"{tmp}/{lang}-{key}.png"
        if not os.path.exists(bg): card(*CAPTIONS[lang][key], bg)
        inputs += ["-loop", "1", "-t", str(secs), "-i", bg, "-ss", f"{ss:.3f}", "-t", str(secs + 1), "-i", video, "-loop", "1", "-i", m]
        b, v, k = 3 * i, 3 * i + 1, 3 * i + 2
        chains.append(
            f"[{v}:v]fps={FPS},scale={APP_W}:{APP_H},tpad=stop_mode=clone:stop_duration={secs},"
            f"trim=duration={secs},setpts=PTS-STARTPTS,format=rgba[v{i}];"
            f"[{k}:v]format=gray,trim=duration={secs}[m{i}];[v{i}][m{i}]alphamerge[a{i}];"
            f"[{b}:v]fps={FPS},format=rgba,trim=duration={secs},setpts=PTS-STARTPTS[b{i}];"
            f"[b{i}][a{i}]overlay={APP_X}:{APP_Y}:shortest=1,format=yuv420p[s{i}]")
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
                    "-filter_complex", graph, "-map", f"[{prev}]", "-map", f"{3 * len(segs)}:a",
                    "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-r", str(FPS),
                    "-b:v", "10M", "-maxrate", "12M", "-bufsize", "20M",
                    "-c:a", "aac", "-b:a", "256k", "-t", f"{total:.3f}", "-movflags", "+faststart", out], check=True)
    print(lang, f"{total:.1f}s", out)


with tempfile.TemporaryDirectory() as tmp:
    for lang in sys.argv[1:]:
        render(lang, tmp)

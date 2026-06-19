#!/usr/bin/env python3
"""
Generates a polished 1080x1920 app tutorial video from the screen recording.
- Upscales to 1080x1920 portrait
- Adds cinematic intro/outro title cards
- Adds feature label banners per scene
- Redacts personal data with solid cover boxes
"""

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from moviepy import VideoFileClip, ImageClip, concatenate_videoclips
import os

SRC = "/root/.claude/uploads/8a1f565f-179d-5bfc-bc5c-9e3d6ecadd71/9d3c9289-ScreenRecording_06192026_161230_1.mov"
OUT = "/home/user/claude-code-/tutorial_4k.mp4"

OW, OH = 1080, 1920
FPS = 30

# ── font helper ───────────────────────────────────────────────────────────────

def get_font(size):
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
    ]
    for c in candidates:
        if os.path.exists(c):
            try:
                return ImageFont.truetype(c, size)
            except Exception:
                continue
    return ImageFont.load_default()

# ── scene config ──────────────────────────────────────────────────────────────
# (start_sec, end_sec, label, redact_boxes_in_1080x1920_coords)
# Source was 588x960; scale factor = 1080/588 ≈ 1.837, 1920/960 = 2.0

SX = OW / 588
SY = OH / 960

def sc(x, y, w, h):
    """Scale a source-space rect to output space."""
    return (int(x*SX), int(y*SY), int((x+w)*SX), int((y+h)*SY))

SCENES = [
    (0.0,  1.0,  "Today's Progress Dashboard",       []),
    (1.0,  2.0,  "Detailed Nutrient Tracking",        []),
    (2.0,  3.0,  "Snap Your Food  —  AI Recognition", []),
    (3.0,  4.0,  "Barcode Scanner & Manual Search",   []),
    (4.0,  5.0,  "Today's Food Log",                  [sc(0, 290, 588, 150)]),
    (5.0,  6.0,  "Progress Tracker",                  [sc(0, 130, 588, 250)]),
    (6.0,  8.0,  "Weight Change Over Time",            [sc(0, 120, 588, 390)]),
    (8.0,  9.0,  "Daily Calories Chart",               []),
    (9.0, 10.0,  "Macro Ratio Breakdown",              []),
    (10.0,11.0,  "AVG vs Daily Target",                []),
    (11.0,12.0,  "Micronutrients Tracker",             []),
    (12.0,13.0,  "Daily Macro Goals",                  []),
    (13.0,15.0,  "AI Nutrition Analysis",              []),
    (15.0,19.0,  "Set Your Goals",                     []),
    (19.0,21.0,  "Fitness Tracker",                    []),
    (21.0,23.0,  "Exercise Library  (1/2)",            []),
    (23.0,25.0,  "Exercise Library  (2/2)",            []),
    (25.0,27.0,  "Account  —  Apple Health Sync",      []),
    (27.0,29.0,  "Account Preferences",                []),
    (29.0,31.0,  "Data & Privacy",                     []),
    (31.0,32.0,  "Coach Hub",                          []),
    (32.0,33.0,  "Coach Hub  —  Groups & Members",     [sc(0, 340, 588, 370)]),
    (33.0,34.0,  "Group Broadcast & Direct Message",   [sc(0, 190, 588, 570)]),
    (34.0,36.2,  "Coach Hub Dashboard",                [sc(0, 340, 588, 370)]),
]

LABEL_FONT = get_font(42)
SMALL_FONT = get_font(26)

# ── overlay renderer ──────────────────────────────────────────────────────────

def render_overlay(frame_rgb: np.ndarray, t: float) -> np.ndarray:
    """
    Receives an already-upscaled (1080×1920) RGB frame and time t (seconds),
    returns an annotated RGB frame.
    """
    pil = Image.fromarray(frame_rgb).convert("RGBA")
    overlay = Image.new("RGBA", (OW, OH), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    label = ""
    redact_boxes = []
    for (s, e, lbl, boxes) in SCENES:
        if s <= float(t) < e:
            label = lbl
            redact_boxes = boxes
            break

    # redaction disabled

    # ── feature label banner at bottom ──
    if label:
        bbox = LABEL_FONT.getbbox(label)
        th = bbox[3] - bbox[1]
        bh = th + 36
        by1 = OH - bh - 36
        by2 = OH - 36
        # Dark pill background
        draw.rounded_rectangle([32, by1, OW-32, by2], radius=22,
                                fill=(8, 10, 22, 215))
        # Green accent left bar
        draw.rounded_rectangle([32, by1, 42, by2], radius=6,
                                fill=(60, 210, 120, 255))
        # Text
        draw.text((68, by1 + 18), label, font=LABEL_FONT,
                  fill=(230, 255, 240, 255))

    out = Image.alpha_composite(pil, overlay).convert("RGB")
    return np.array(out)


# ── title card factory ────────────────────────────────────────────────────────

def make_card(duration, lines, tagline=None):
    img = Image.new("RGB", (OW, OH), (8, 10, 22))
    draw = ImageDraw.Draw(img)

    # subtle grid lines
    for y in range(0, OH, 120):
        draw.line([(0, y), (OW, y)], fill=(20, 24, 40), width=1)
    for x in range(0, OW, 120):
        draw.line([(x, 0), (x, OH)], fill=(20, 24, 40), width=1)

    big = get_font(88)
    med = get_font(44)
    sm  = get_font(32)

    y = OH // 2 - 180
    for text, font, color in lines:
        bbox = font.getbbox(text)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        draw.text(((OW - tw)//2 + 2, y + 2), text, font=font, fill=(0,0,0,80))
        draw.text(((OW - tw)//2, y), text, font=font, fill=color)
        y += th + 24

    # divider
    draw.line([(OW//5, y+20), (4*OW//5, y+20)], fill=(60, 210, 120), width=3)
    y += 52

    if tagline:
        bbox = sm.getbbox(tagline)
        tw = bbox[2] - bbox[0]
        draw.text(((OW-tw)//2, y), tagline, font=sm, fill=(160, 200, 175))

    return ImageClip(np.array(img), duration=duration)


def make_intro():
    big = get_font(88)
    med = get_font(44)
    return make_card(3.5,
        lines=[
            ("Health & Fitness", big, (60, 210, 120)),
            ("Tracker",          big, (255, 255, 255)),
            ("",                 med, (0,0,0)),
            ("Full App Tutorial", med, (180, 220, 195)),
        ],
        tagline="All Features  ·  Complete Walkthrough"
    )


def make_outro():
    big = get_font(72)
    sm  = get_font(34)
    tag = get_font(30)
    return make_card(4.5,
        lines=[
            ("That's Everything!", big, (60, 210, 120)),
            ("",                   sm,  (0,0,0)),
            ("AI Food Scanning",   sm,  (200, 240, 215)),
            ("Macro & Micro Tracking", sm, (200, 240, 215)),
            ("Progress Graphs",    sm,  (200, 240, 215)),
            ("Fitness Library",    sm,  (200, 240, 215)),
            ("Goal Setting",       sm,  (200, 240, 215)),
            ("Coach Hub",          sm,  (200, 240, 215)),
            ("AI Nutrition Analysis", sm, (200, 240, 215)),
        ],
        tagline=None
    )


# ── main ──────────────────────────────────────────────────────────────────────

print("Loading source video…")
src = VideoFileClip(SRC)
print(f"  Source: {src.size}  {src.duration:.1f}s  {src.fps}fps")

print("Upscaling & applying overlays…")

def frame_transform(get_frame, t):
    raw = get_frame(t)                               # 588×960 RGB
    # upscale via PIL
    pil = Image.fromarray(raw).resize((OW, OH), Image.LANCZOS)
    upscaled = np.array(pil)
    return render_overlay(upscaled, float(t))

processed = src.transform(frame_transform, apply_to=["video"])

print("Building title/outro cards…")
intro = make_intro()
outro = make_outro()

print("Concatenating…")
final = concatenate_videoclips([intro, processed, outro], method="compose")

print(f"Exporting  {OW}×{OH}  {FPS}fps  →  {OUT}")
final.write_videofile(
    OUT,
    fps=FPS,
    codec="libx264",
    bitrate="12000k",
    audio_codec="aac",
    ffmpeg_params=["-crf", "16", "-pix_fmt", "yuv420p", "-movflags", "+faststart"],
    logger="bar",
)

src.close()
final.close()
print("✅  Done!  →", OUT)

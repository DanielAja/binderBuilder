#!/usr/bin/env python3
"""
Compose marketing-framed App Store screenshots for Binder Builder.

Reads raw device captures from scratchpad/raw/{iphone,ipad}/*.png and produces
composited App Store screenshots (gradient background, headline caption, gold
accent underline, rounded+shadowed device capture) at the exact target canvas
sizes required by App Store Connect.

Usage: python3 compose_screenshots.py
"""

import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont, ImageFilter
except ImportError:
    sys.stderr.write(
        "Pillow not installed. Run:\n"
        "  python3 -m venv venv && venv/bin/pip install pillow && venv/bin/python3 compose_screenshots.py\n"
    )
    raise

SCRATCH = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(SCRATCH, "raw")
OUT_ROOT = "/Users/daniel/Desktop/BinderBuilder-AppStore-Screenshots"

# ---------------------------------------------------------------------------
# Config per device
# ---------------------------------------------------------------------------

DEVICES = {
    "iphone": {
        "raw_dir": os.path.join(RAW_DIR, "iphone"),
        "out_dir": os.path.join(OUT_ROOT, "iPhone-6.9"),
        "canvas": (1320, 2868),
        "font_size": 86,
        "min_font_size": 46,
        "corner_radius": 60,
        "device_width_frac": 0.82,
        "device_top_frac": 0.14,
        "caption_top_frac": 0.07,
        "underline_gap": 28,      # px between caption baseline area and gold bar
        "underline_width": 220,
        "underline_height": 6,
        "shadow_blur": 40,
        "shadow_offset": (0, 26),
        "shadow_opacity": 150,
    },
    "ipad": {
        "raw_dir": os.path.join(RAW_DIR, "ipad"),
        "out_dir": os.path.join(OUT_ROOT, "iPad-13"),
        "canvas": (2064, 2752),
        "font_size": 110,
        "min_font_size": 58,
        "corner_radius": 48,
        "device_width_frac": 0.82,
        "device_top_frac": 0.14,
        "caption_top_frac": 0.07,
        "underline_gap": 34,
        "underline_width": 260,
        "underline_height": 6,
        "shadow_blur": 48,
        "shadow_offset": (0, 30),
        "shadow_opacity": 150,
    },
}

CAPTIONS = {
    "01-binder": "Your collection, in 3D",
    "02-floating": "Pull any card off the page",
    "03-fastscan": "Scan a card. See its price.",
    "04-home": "Watch your collection grow",
    "05-collection": "Every card, organized",
    "06-sets": "Complete every set",
    "07-trade": "Trade with confidence",
    "08-carddetail": "Live market prices",
}

SHOT_ORDER = [
    "01-binder", "02-floating", "03-fastscan", "04-home",
    "05-collection", "06-sets", "07-trade", "08-carddetail",
]

GRAD_TOP = (0x14, 0x1B, 0x2E)     # deep navy #141B2E
GRAD_BOTTOM = (0x3A, 0x2E, 0x1A)  # warm dark brown-gold #3A2E1A
GOLD = (0xE8, 0xB2, 0x3A)         # #E8B23A
WHITE = (255, 255, 255)

FONT_CANDIDATES = [
    ("/System/Library/Fonts/SFNS.ttf", "Bold"),
    ("/System/Library/Fonts/Helvetica.ttc", None),
    ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", None),
]


def load_bold_font(size):
    """Try candidate fonts in order; return a PIL ImageFont at `size`."""
    for path, variation in FONT_CANDIDATES:
        if not os.path.exists(path):
            continue
        try:
            font = ImageFont.truetype(path, size)
            if variation:
                try:
                    font.set_variation_by_name(variation)
                except Exception:
                    pass
            return font
        except Exception:
            continue
    # Last resort: PIL default (not ideal, but keeps script from crashing)
    return ImageFont.load_default()


def make_gradient(size, top_color, bottom_color):
    """Vertical linear gradient, top_color -> bottom_color, as an RGB Image."""
    w, h = size
    base = Image.new("RGB", (1, h), color=0)
    px = base.load()
    for y in range(h):
        t = y / max(1, h - 1)
        r = round(top_color[0] + (bottom_color[0] - top_color[0]) * t)
        g = round(top_color[1] + (bottom_color[1] - top_color[1]) * t)
        b = round(top_color[2] + (bottom_color[2] - top_color[2]) * t)
        px[0, y] = (r, g, b)
    return base.resize((w, h), Image.Resampling.NEAREST)


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return mask


def fit_font_for_width(text, max_width, start_size, min_size, weight="Bold"):
    """Shrink-to-fit: return (font, text_width) so text fits within max_width."""
    size = start_size
    while size >= min_size:
        font = load_bold_font(size)
        bbox = font.getbbox(text)
        w = bbox[2] - bbox[0]
        if w <= max_width:
            return font, w
        size -= 2
    font = load_bold_font(min_size)
    bbox = font.getbbox(text)
    return font, bbox[2] - bbox[0]


def compose_shot(name, raw_path, cfg, canvas_size):
    caption = CAPTIONS[name]
    W, H = canvas_size

    # 1. Background gradient
    canvas = make_gradient((W, H), GRAD_TOP, GRAD_BOTTOM)
    draw = ImageDraw.Draw(canvas)

    # 2. Caption (shrink-to-fit within ~90% of canvas width)
    max_text_width = int(W * 0.90)
    font, text_w = fit_font_for_width(
        caption, max_text_width, cfg["font_size"], cfg["min_font_size"]
    )
    bbox = font.getbbox(caption)
    text_h = bbox[3] - bbox[1]
    caption_top = int(H * cfg["caption_top_frac"])
    text_x = (W - text_w) // 2 - bbox[0]
    text_y = caption_top - bbox[1]
    draw.text((text_x, text_y), caption, font=font, fill=WHITE)

    # 3. Gold accent underline, centered under caption
    bar_w = cfg["underline_width"]
    bar_h = cfg["underline_height"]
    bar_y = caption_top + text_h + cfg["underline_gap"]
    bar_x = (W - bar_w) // 2
    draw.rounded_rectangle(
        [bar_x, bar_y, bar_x + bar_w, bar_y + bar_h],
        radius=bar_h // 2,
        fill=GOLD,
    )

    # 4. Load + scale raw capture
    raw = Image.open(raw_path).convert("RGB")
    raw_w, raw_h = raw.size
    dev_w = int(W * cfg["device_width_frac"])
    dev_h = int(round(dev_w * raw_h / raw_w))
    device_img = raw.resize((dev_w, dev_h), Image.Resampling.LANCZOS)

    # 5. Round corners on the device image
    mask = rounded_mask((dev_w, dev_h), cfg["corner_radius"])

    # 6. Position: top edge below caption; bottom may run off-canvas
    dev_x = (W - dev_w) // 2
    dev_y = int(H * cfg["device_top_frac"])

    # 7. Drop shadow: soft blurred black rounded-rect behind device position
    shadow_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow_shape = Image.new("L", (dev_w, dev_h), 0)
    sdraw = ImageDraw.Draw(shadow_shape)
    sdraw.rounded_rectangle(
        [0, 0, dev_w - 1, dev_h - 1], radius=cfg["corner_radius"], fill=cfg["shadow_opacity"]
    )
    off_x, off_y = cfg["shadow_offset"]
    shadow_layer.paste(
        (0, 0, 0, 255), (dev_x + off_x, dev_y + off_y), shadow_shape
    )
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(cfg["shadow_blur"]))

    canvas_rgba = canvas.convert("RGBA")
    canvas_rgba = Image.alpha_composite(canvas_rgba, shadow_layer)

    # 8. Paste device capture (with rounded mask) on top of shadow
    canvas_rgba.paste(device_img, (dev_x, dev_y), mask)

    # 9. Flatten to RGB (no alpha) at exact target size
    final = canvas_rgba.convert("RGB")
    assert final.size == (W, H), f"{name}: size mismatch {final.size} != {(W, H)}"
    assert final.mode == "RGB", f"{name}: mode mismatch {final.mode} != RGB"
    return final


def main():
    for device_key, cfg in DEVICES.items():
        os.makedirs(cfg["out_dir"], exist_ok=True)
        for name in SHOT_ORDER:
            raw_path = os.path.join(cfg["raw_dir"], f"{name}.png")
            if not os.path.exists(raw_path):
                print(f"SKIP missing raw: {raw_path}")
                continue
            out_path = os.path.join(cfg["out_dir"], f"{name}.png")
            final = compose_shot(name, raw_path, cfg, cfg["canvas"])
            final.save(out_path, "PNG")
            assert final.size == tuple(cfg["canvas"])
            assert final.mode == "RGB"
            print(f"wrote {out_path}  size={final.size}  mode={final.mode}")


if __name__ == "__main__":
    main()

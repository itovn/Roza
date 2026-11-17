"""Biểu tượng và ảnh khởi động của Roza: logo anh thiết kế (tools/icon/roza-logo-1024.png); không có thì tự vẽ. Không dùng ảnh / logo của Zalo.

Biểu tượng: nền hồng đỏ loang (Roza ≈ hoa hồng), bong bóng chat trắng có bông hồng cách điệu. iOS 5 / 6 tự bo góc biểu tượng;
Info.plist có UIPrerenderedIcon nên SpringBoard không phủ vệt bóng.
    python tools/icon/make_icons.py            → app/Resources/*.png
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "app", "Resources")

ROSE_TOP = (244, 92, 120)
ROSE_BOTTOM = (196, 30, 72)
BLUE_TOP = (52, 168, 230)
BLUE_BOTTOM = (18, 115, 189)


def gradient(size, top, bottom, radial=False):
    w, h = size
    img = Image.new("RGB", size, top)
    px = img.load()
    cx, cy = w / 2, h * 0.38
    rmax = math.hypot(max(cx, w - cx), max(cy, h - cy))
    for y in range(h):
        for x in range(w) if radial else [0]:
            t = (math.hypot(x - cx, y - cy) / rmax) if radial else y / max(1, h - 1)
            c = tuple(int(top[i] + (bottom[i] - top[i]) * min(1, t)) for i in range(3))
            if radial:
                px[x, y] = c
            else:
                for xx in range(w):
                    px[xx, y] = c
    return img


def rose(draw, cx, cy, r, color):
    """Bông hồng cách điệu: các cánh là cung tròn xoáy vào tâm."""
    width = max(2, int(r * 0.16))
    for i, k in enumerate([1.0, 0.72, 0.46, 0.22]):
        rr = r * k
        start = (i * 75) % 360
        draw.arc([cx - rr, cy - rr, cx + rr, cy + rr], start=start, end=start + 290, fill=color, width=width)
    draw.ellipse([cx - r * 0.09, cy - r * 0.09, cx + r * 0.09, cy + r * 0.09], fill=color)


def bubble(draw, box, fill):
    x0, y0, x1, y1 = box
    rad = (y1 - y0) * 0.45
    draw.rounded_rectangle(box, radius=rad, fill=fill)
    # đuôi dưới trái
    w = x1 - x0
    h = y1 - y0
    draw.polygon([(x0 + w * 0.18, y1 - h * 0.12), (x0 + w * 0.06, y1 + h * 0.26), (x0 + w * 0.42, y1 - h * 0.06)], fill=fill)


def icon(size=1024):
    img = gradient((size, size), ROSE_TOP, ROSE_BOTTOM, radial=True)
    d = ImageDraw.Draw(img)
    # vệt sáng nhẹ phía trên
    hl = Image.new("L", (size, size), 0)
    ImageDraw.Draw(hl).ellipse([-size * 0.3, -size * 0.75, size * 1.3, size * 0.42], fill=40)
    img = Image.composite(Image.new("RGB", (size, size), (255, 255, 255)), img, hl.filter(ImageFilter.GaussianBlur(size * 0.04)))
    d = ImageDraw.Draw(img)
    # bóng đổ của bong bóng
    sh = Image.new("L", (size, size), 0)
    box = (size * 0.16, size * 0.2, size * 0.84, size * 0.72)
    bubble(ImageDraw.Draw(sh), (box[0], box[1] + size * 0.02, box[2], box[3] + size * 0.02), 90)
    img = Image.composite(Image.new("RGB", (size, size), (120, 10, 40)), img, sh.filter(ImageFilter.GaussianBlur(size * 0.02)))
    d = ImageDraw.Draw(img)
    bubble(d, box, (255, 255, 255))
    rose(d, size * 0.5, size * 0.46, size * 0.17, ROSE_BOTTOM)
    return img


def launch(w, h, scale):
    logo = load_logo()
    if logo:
        # Nền tím hồng sẫm hợp tông biểu tượng kính mờ hồng, loang sáng nhẹ ở giữa
        img = gradient((w, h), (92, 34, 66), (28, 16, 32), radial=True)
    else:
        img = gradient((w, h), BLUE_TOP, BLUE_BOTTOM, radial=True)
    d = ImageDraw.Draw(img)
    s = int(min(w, h) * 0.28)
    cy = int(h * 0.42)
    if logo:
        ic = logo.resize((s, s), Image.LANCZOS)
        img.paste(ic, ((w - s) // 2, cy - s // 2), ic.split()[-1])
    else:
        ic = icon(512).resize((s, s), Image.LANCZOS)
        mask = Image.new("L", (s, s), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=s * 0.18, fill=255)
        img.paste(ic, ((w - s) // 2, cy - s // 2), mask)
    font = None
    for f in ["C:/Windows/Fonts/segoeuib.ttf", "C:/Windows/Fonts/arialbd.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]:
        if os.path.exists(f):
            font = ImageFont.truetype(f, int(22 * scale * 1.6))
            break
    if font:
        t = "Roza"
        tw = d.textlength(t, font=font)
        d.text(((w - tw) / 2, cy + s // 2 + 14 * scale), t, font=font, fill=(255, 255, 255))
    return img


# Biểu tượng chính thức: kính mờ hồng (anh chọn 17/11/2026 trong 4 bản ở so-sanh-icon.png — make_glass_icon.py)
LOGO = os.path.join(ROOT, "tools", "icon", "roza-glass-rose-1024.png")


def load_logo():
    """Biểu tượng chính thức (kính mờ hồng, góc ngoài trong suốt). Có thì dùng thay biểu tượng tự vẽ."""
    return Image.open(LOGO).convert("RGBA") if os.path.exists(LOGO) else None


def main():
    os.makedirs(OUT, exist_ok=True)
    big = load_logo() or icon(1024)
    for name, px in [("Icon.png", 57), ("Icon@2x.png", 114), ("Icon-72.png", 72), ("Icon-72@2x.png", 144), ("Icon-Small.png", 29),
                     ("Icon-Small@2x.png", 58), ("Icon-Small-50.png", 50), ("Icon-Small-50@2x.png", 100)]:
        big.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
    big.resize((512, 512), Image.LANCZOS).save(os.path.join(ROOT, "tools", "icon", "icon-512.png"))
    for name, (w, h, sc) in {
        "Default.png": (320, 480, 1), "Default@2x.png": (640, 960, 2), "Default-568h@2x.png": (640, 1136, 2),
        "Default-Portrait~ipad.png": (768, 1004, 1), "Default-Landscape~ipad.png": (1024, 748, 1),
    }.items():
        launch(w, h, sc).save(os.path.join(OUT, name))
    print("ok:", OUT)


if __name__ == "__main__":
    sys.exit(main())

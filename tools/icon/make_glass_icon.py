"""Các phiên bản biểu tượng Roza kiểu «kính mờ 3D» (cảm hứng Liquid Glass của macOS Tahoe), vẽ lại bằng Pillow, và ảnh so sánh:

- xanh: theo bố cục logo anh gửi (khung bo tròn, bong bóng chat, chữ Roza);
- hồng: theo biểu tượng cũ của Roza (nền hồng đỏ, bong bóng chat trắng, bông hồng cách điệu — tools/icon/make_icons.py).

    python tools/icon/make_glass_icon.py
      → tools/icon/roza-glass-1024.png (xanh), roza-glass-rose-1024.png (hồng), so-sanh-icon.png (4 bản cạnh nhau)
"""
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
S = 1024

THEMES = {
    "blue": {
        "bg": ((58, 140, 245), (10, 52, 150)),
        "blobs": [((-180, -160, 520, 480), (120, 200, 255, 170)), ((560, 520, 1180, 1140), (40, 90, 230, 190)),
                  ((620, -120, 1100, 330), (90, 120, 255, 120)), ((-100, 650, 360, 1110), (20, 160, 230, 150))],
        "shadow": (6, 24, 80), "inner": (30, 70, 160),
        "mark": ((26, 92, 214), (8, 44, 140)), "mark_shadow": (0, 20, 70),
    },
    "rose": {
        "bg": ((252, 118, 150), (172, 22, 64)),
        "blobs": [((-180, -160, 520, 480), (255, 178, 196, 170)), ((560, 520, 1180, 1140), (140, 16, 86, 190)),
                  ((620, -120, 1100, 330), (255, 120, 200, 120)), ((-100, 650, 360, 1110), (232, 60, 92, 150))],
        "shadow": (90, 8, 40), "inner": (170, 40, 86),
        "mark": ((232, 58, 104), (150, 14, 58)), "mark_shadow": (80, 0, 30),
    },
}


def font(size):
    for f in ["C:/Windows/Fonts/ARLRDBD.TTF", "C:/Windows/Fonts/seguibl.ttf", "C:/Windows/Fonts/segoeuib.ttf", "C:/Windows/Fonts/arialbd.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def ui_font(size, bold=False):
    for f in (["C:/Windows/Fonts/segoeuib.ttf"] if bold else ["C:/Windows/Fonts/segoeui.ttf"]) + ["C:/Windows/Fonts/arial.ttf"]:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def vgrad(size, top, bottom):
    w, h = size
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))


def rounded_mask(size, box, radius, scale=4):
    w, h = size
    m = Image.new("L", (w * scale, h * scale), 0)
    ImageDraw.Draw(m).rounded_rectangle([c * scale for c in box], radius=radius * scale, fill=255)
    return m.resize((w, h), Image.LANCZOS)


def bubble_mask(scale=4):
    """Bong bóng chat: hình chữ nhật bo tròn + đuôi dưới trái."""
    m = Image.new("L", (S * scale, S * scale), 0)
    d = ImageDraw.Draw(m)
    k = scale
    d.rounded_rectangle([150 * k, 170 * k, 880 * k, 750 * k], radius=250 * k, fill=255)
    d.polygon([(230 * k, 640 * k), (175 * k, 860 * k), (430 * k, 720 * k)], fill=255)
    m = m.filter(ImageFilter.GaussianBlur(10 * k)).point(lambda v: 255 if v > 128 else 0)
    return m.resize((S, S), Image.LANCZOS)


def text_mark():
    """Chữ «Roza» giữa bong bóng → (mặt nạ, đáy vùng sáng)."""
    f = font(272)
    tm = Image.new("L", (S, S), 0)
    td = ImageDraw.Draw(tm)
    l, t, r, b = td.textbbox((0, 0), "Roza", font=f)
    tx, ty = (S - (r - l)) // 2 - l, 470 - (b - t) // 2 - t
    td.text((tx, ty), "Roza", font=f, fill=255)
    return tm, ty + t + (b - t) * 0.48


def rose_mark(scale=4):
    """Bông hồng cách điệu như biểu tượng cũ: các cung tròn xoáy vào tâm + nhuỵ."""
    k = scale
    m = Image.new("L", (S * k, S * k), 0)
    d = ImageDraw.Draw(m)
    cx, cy, r = 512 * k, 455 * k, 190 * k
    width = int(r * 0.17)
    for i, f in enumerate([1.0, 0.72, 0.46, 0.22]):
        rr = r * f
        start = (i * 75) % 360
        d.arc([cx - rr, cy - rr, cx + rr, cy + rr], start=start, end=start + 290, fill=255, width=width)
    d.ellipse([cx - r * 0.1, cy - r * 0.1, cx + r * 0.1, cy + r * 0.1], fill=255)
    return m.resize((S, S), Image.LANCZOS), 455


def glass_icon(theme="blue"):
    th = THEMES[theme]
    # 1. Nền loang + các mảng màu mờ (để lớp kính có thứ «nhoè» phía sau)
    bg = vgrad((S, S), *th["bg"]).convert("RGBA")
    blobs = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(blobs)
    for box, col in th["blobs"]:
        bd.ellipse(box, fill=col)
    bg = Image.alpha_composite(bg, blobs.filter(ImageFilter.GaussianBlur(90)))

    # 2. Bóng đổ của bong bóng (chiều sâu 3D)
    bm = bubble_mask()
    shadow = Image.new("RGBA", (S, S), th["shadow"] + (0,))
    shadow.putalpha(ImageChops.offset(bm, 0, 34).point(lambda v: v * 0.55).filter(ImageFilter.GaussianBlur(34)))
    img = Image.alpha_composite(bg, shadow)

    # 3. Kính mờ: nền phía sau nhoè mạnh + phủ trắng, đậm dần lên trên
    frosted = img.filter(ImageFilter.GaussianBlur(42))
    white = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    col = Image.new("L", (1, S))
    for y in range(S):
        t = min(1, max(0, (y - 150) / 650))
        col.putpixel((0, y), int(238 - 70 * t))
    white.putalpha(col.resize((S, S)))
    img.paste(Image.alpha_composite(frosted, white), (0, 0), bm)

    # 4. Viền kính của bong bóng: sáng ở cạnh trên trái, mờ dần về dưới phải; bóng trong ở cạnh dưới
    edge = ImageChops.subtract(bm, bm.filter(ImageFilter.MinFilter(13)))
    lg = Image.linear_gradient("L").rotate(45, expand=False).resize((S, S))
    rim = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    rim.putalpha(ImageChops.multiply(edge, ImageChops.invert(lg).point(lambda v: min(255, 60 + v))))
    img = Image.alpha_composite(img, rim)
    inner = ImageChops.subtract(bm, ImageChops.offset(bm, -10, -14))
    inner_sh = Image.new("RGBA", (S, S), th["inner"] + (0,))
    inner_sh.putalpha(inner.point(lambda v: v * 0.35).filter(ImageFilter.GaussianBlur(6)))
    img = Image.alpha_composite(img, inner_sh)

    # 5. Dấu giữa bong bóng: chữ «Roza» (xanh) / bông hồng (hồng) — màu đậm, vệt sáng nửa trên, bóng nhẹ
    mark, hi_bottom = text_mark() if theme == "blue" else rose_mark()
    msh = Image.new("RGBA", (S, S), th["mark_shadow"] + (0,))
    msh.putalpha(ImageChops.offset(mark, 0, 10).point(lambda v: v * 0.45).filter(ImageFilter.GaussianBlur(8)))
    img = Image.alpha_composite(img, msh)
    fill = vgrad((S, S), *th["mark"]).convert("RGBA")
    fill.putalpha(mark)
    img = Image.alpha_composite(img, fill)
    top_half = Image.new("L", (S, S), 0)
    ImageDraw.Draw(top_half).rectangle([0, 0, S, hi_bottom], fill=255)
    hi = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    hi.putalpha(ImageChops.multiply(mark, top_half).point(lambda v: v * 0.2))
    img = Image.alpha_composite(img, hi)

    # 6. Lớp bóng loáng phía trên + viền kính của khung, bo 4 góc
    sheen = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sheen).ellipse([-260, -760, S + 260, 330], fill=46)
    sh = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    sh.putalpha(sheen.filter(ImageFilter.GaussianBlur(40)))
    img = Image.alpha_composite(img, sh)
    frame = rounded_mask((S, S), [0, 0, S - 1, S - 1], 225)
    ring = ImageChops.subtract(frame, rounded_mask((S, S), [9, 9, S - 10, S - 10], 216))
    ring_l = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    ring_l.putalpha(ring.point(lambda v: v * 0.55))
    img = Image.alpha_composite(img, ring_l)
    img.putalpha(frame)
    return img


def old_rose_icon():
    """Biểu tượng hồng cũ (make_icons.icon), bo góc như SpringBoard để so cho công bằng."""
    import make_icons

    img = make_icons.icon(1024).convert("RGBA")
    img.putalpha(rounded_mask((S, S), [0, 0, S - 1, S - 1], 180))
    return img


def compare(items):
    n = len(items)
    col = 460
    W, H = col * n, 900
    sheet = vgrad((W, H), (34, 44, 66), (18, 22, 34)).convert("RGBA")
    d = ImageDraw.Draw(sheet)
    d.text((W // 2, 34), "Biểu tượng Roza — so sánh", font=ui_font(44, True), fill=(235, 240, 248), anchor="ma")
    for i, (img, label, sub) in enumerate(items):
        cx = col // 2 + i * col
        sheet.alpha_composite(img.resize((360, 360), Image.LANCZOS), (cx - 180, 120))
        d.text((cx, 510), label, font=ui_font(30, True), fill=(235, 240, 248), anchor="ma")
        d.text((cx, 552), sub, font=ui_font(22), fill=(160, 172, 190), anchor="ma")
        # Cỡ thật trên màn iPhone: 114 px (Retina) và 57 px
        for j, px in enumerate([114, 57]):
            x = cx - 75 + j * 150
            sheet.alpha_composite(img.resize((px, px), Image.LANCZOS), (x - px // 2, 640 + (114 - px)))
            d.text((x, 768), f"{px} px", font=ui_font(22), fill=(150, 160, 178), anchor="ma")
        if i:
            d.line([(i * col, 120), (i * col, 820)], fill=(70, 82, 104), width=2)
    return sheet


def main():
    blue = glass_icon("blue")
    rose = glass_icon("rose")
    blue.save(os.path.join(HERE, "roza-glass-1024.png"))
    rose.save(os.path.join(HERE, "roza-glass-rose-1024.png"))
    logo_path = os.path.join(HERE, "roza-logo-1024.png")
    logo = Image.open(logo_path).convert("RGBA") if os.path.exists(logo_path) else blue
    items = [
        (old_rose_icon(), "Biểu tượng hồng cũ", "đang hiện trên màn hình chính"),
        (rose, "Kính mờ — hồng", "từ biểu tượng hồng cũ"),
        (logo, "Logo anh gửi", "đang cài trong app"),
        (blue, "Kính mờ — xanh", "từ logo anh gửi"),
    ]
    compare(items).convert("RGB").save(os.path.join(HERE, "so-sanh-icon.png"))
    print("ok")


if __name__ == "__main__":
    main()

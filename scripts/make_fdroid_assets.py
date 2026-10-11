"""生成 F-Droid 列表要用的图（图标 + 特色横幅），并复制截图。

F-Droid 的列表文字从 `app/fastlane/metadata/android/<locale>/` 读，
**图片只能从这里出**——不放在源仓库里，列表就没有图标和截图。

    python scripts/make_fdroid_assets.py

图标和横幅都复用 `make_app_icon.py` 里的几何与配色，
和 App 里的图标是同一套代码画出来的，不会出现「商店图标和应用图标不一样」。
"""

import pathlib
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import make_app_icon as icon  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
FASTLANE = ROOT / "app" / "fastlane" / "metadata" / "android"

ICON_PX = 512
BANNER_W, BANNER_H = 1024, 500

DIM = (139, 148, 184)
WHITE = (255, 255, 255)
ACCENT = (57, 135, 229)

FONT_REG = "C:/Windows/Fonts/msyh.ttc"
FONT_BOLD = "C:/Windows/Fonts/msyhbd.ttc"

LOCALES = {
    "en-US": {
        "tagline": "Record the night. Classify on-device.",
        "badges": "On-device · No account · No server",
        "shots": ROOT / "docs" / "en" / "screenshots",
    },
    "zh-CN": {
        "tagline": "整夜录音 · 声音不出手机",
        "badges": "端侧推理 · 无账号 · 无服务器",
        "shots": ROOT / "docs" / "screenshots",
    },
}


def gradient(w, h, top, bottom):
    strip = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        strip.putpixel((0, y), tuple(
            round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return strip.resize((w, h))


def mark_layer(size):
    """把弯月 + 声波柱抠成透明底的图，并按实际外接框裁掉空白。

    直接缩放整张 1024² 画布的话，图形外面的留白会一起缩放，
    摆位时算不准（看起来像浮在半空）。
    """
    m = icon.draw_mark(size)
    box = m.getbbox()
    return m.crop(box)


def fit_font(draw, text, font_path, size, max_width, min_size=16):
    """把字号缩到文字能塞进 max_width 为止。

    ⚠️ 不做这件事的话，en-US 的标题和中文的标语都会从右边被裁掉——
    而裁掉的是后半句，读起来像另一句话。宁可小一号，也不能截断。
    """
    while size > min_size:
        f = ImageFont.truetype(font_path, size)
        if draw.textlength(text, font=f) <= max_width:
            return f
        size -= 2
    return ImageFont.truetype(font_path, min_size)


def banner(tagline: str, badges: str, out: pathlib.Path):
    img = gradient(BANNER_W, BANNER_H, icon.BG_TOP, icon.BG_BOTTOM).convert("RGBA")

    # 月亮背后的辉光：和图标里同一个做法，只是画在横幅坐标上
    glow = Image.new("L", (BANNER_W, BANNER_H), 0)
    ImageDraw.Draw(glow).ellipse([40, 60, 480, 460], fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(150))
    glow = glow.point(lambda v: int(v * 0.42))
    gl = Image.new("RGBA", (BANNER_W, BANNER_H), icon.GLOW + (0,))
    gl.putalpha(glow)
    img.alpha_composite(gl)

    # ---- 左侧：图形 ----
    mark = mark_layer(icon.MASTER)
    target_h = 300
    mark = mark.resize(
        (round(mark.width * target_h / mark.height), target_h), Image.LANCZOS)
    img.alpha_composite(mark, (110, (BANNER_H - target_h) // 2))

    # ---- 右侧：文字 ----
    d = ImageDraw.Draw(img)
    x = 110 + mark.width + 80
    avail = BANNER_W - x - 60  # 右边留出 60px 边距

    f_title = fit_font(d, "Sleep Secret", FONT_BOLD, 62, avail)
    f_tag = fit_font(d, tagline, FONT_REG, 30, avail)
    f_small = fit_font(d, badges, FONT_REG, 26, avail)

    d.text((x, 165), "Sleep Secret", font=f_title, fill=WHITE)
    d.text((x, 165 + f_title.size + 26), tagline, font=f_tag, fill=DIM)
    d.text((x, 165 + f_title.size + 26 + f_tag.size + 34),
           badges, font=f_small, fill=ACCENT)

    img.convert("RGB").save(out, "PNG", optimize=True)
    return out


def copy_shots(src_dir: pathlib.Path, dst_dir: pathlib.Path):
    """截图按 F-Droid 要求命名成 1.png / 2.png …（顺序即展示顺序）。"""
    shots = sorted(src_dir.glob("[0-9]*.png"))
    dst_dir.mkdir(parents=True, exist_ok=True)
    names = []
    for i, p in enumerate(shots, 1):
        dst = dst_dir / f"{i}.png"
        dst.write_bytes(p.read_bytes())
        names.append(dst.name)
    return names


def main():
    # 图标：和 App 里的传统图标同一套几何（带背景、放大过的版本）
    ico = icon.legacy_icon().resize((ICON_PX, ICON_PX), Image.LANCZOS)

    for locale, cfg in LOCALES.items():
        base = FASTLANE / locale
        (base / "images").mkdir(parents=True, exist_ok=True)

        ico.save(base / "images" / "icon.png", "PNG", optimize=True)
        banner(cfg["tagline"], cfg["badges"], base / "images" / "featureGraphic.png")
        shots = copy_shots(cfg["shots"], base / "images" / "phoneScreenshots")

        print(f"{locale}:")
        print(f"  icon.png            {ICON_PX}×{ICON_PX}")
        print(f"  featureGraphic.png  {BANNER_W}×{BANNER_H}")
        print(f"  phoneScreenshots/   {len(shots)} 张 {shots}")


if __name__ == "__main__":
    main()

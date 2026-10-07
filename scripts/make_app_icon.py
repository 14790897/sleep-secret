"""生成应用图标（Android mipmap / adaptive icon / Windows .ico）。

    python scripts/make_app_icon.py

图标是**代码画出来的**，不是某个二进制源文件导出的——改配色、改大小、
重新生成都不用开设计软件，也不会有「源文件丢了」这种事。

## 构图

弯月 + 声波。弯月是「睡眠」，声波是「音频事件识别」，
合起来就是这个 App 干的事。

月亮和 5 根声波柱都画在画布正中的 66.7% 之内——
那正好是 Android adaptive icon 的**安全区**（108dp 里永远可见的 72dp），
所以同一套几何能同时给普通图标和 adaptive icon 用。
"""

import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

MASTER = 1024

# 取自 lib/ui/core/theme.dart
BG_TOP = (26, 41, 88)        # midnight 提亮一点，做渐变用
BG_BOTTOM = (9, 13, 30)      # 再压暗，衬得月亮出来
GLOW = (57, 135, 229)        # AppColors.accent
MOON_HI = (208, 226, 255)
MOON_LO = (72, 148, 240)
BAR_HI = (130, 186, 255)
BAR_LO = (57, 135, 229)


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", (1, size), top)
    for y in range(size):
        t = y / max(size - 1, 1)
        img.putpixel((0, y), tuple(
            round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img.resize((size, size))


def radial_mask(size, cx, cy, radius, softness=1.0):
    """中心亮、边缘渐隐的圆。用来做月亮背后的辉光。"""
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius], fill=255)
    return m.filter(ImageFilter.GaussianBlur(radius * 0.55 * softness))


def crescent_mask(size, cx, cy, outer_r, bite_dx, bite_dy, bite_r):
    """弯月 = 大圆挖掉一个偏移的小圆。

    用 'L' 图上的 fill=0 直接「擦」，比算两段圆弧的交点稳得多。
    """
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.ellipse([cx - outer_r, cy - outer_r, cx + outer_r, cy + outer_r], fill=255)
    d.ellipse([cx + bite_dx - bite_r, cy + bite_dy - bite_r,
               cx + bite_dx + bite_r, cy + bite_dy + bite_r], fill=0)
    return m


def bars_mask(size, x0, center_y, bar_w, gap, heights, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    for i, h in enumerate(heights):
        x = x0 + i * (bar_w + gap)
        top = center_y - h / 2
        d.rounded_rectangle([x, top, x + bar_w, top + h],
                            radius=radius, fill=255)
    # 柱子宽度可能小于 2*radius，先夹一下再画第二遍（PIL 会自己处理，这里只是保险）
    return m


def tinted(size, top, bottom, mask):
    layer = vertical_gradient(size, top, bottom).convert("RGBA")
    layer.putalpha(mask)
    return layer


def build_art(with_background):
    """返回一张 RGBA。with_background=False 时只有图形本身（adaptive 前景用）。"""
    base = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))

    if with_background:
        base.alpha_composite(
            vertical_gradient(MASTER, BG_TOP, BG_BOTTOM).convert("RGBA"))

    # 月亮背后的辉光：只加在背景上，前景不带（前景会被系统单独缩放）
    if with_background:
        glow = radial_mask(MASTER, 400, 520, 380, softness=1.15)
        glow = glow.point(lambda v: int(v * 0.30))
        glow_layer = Image.new("RGBA", (MASTER, MASTER), GLOW + (0,))
        glow_layer.putalpha(glow)
        base.alpha_composite(glow_layer)

    return base


def draw_mark(canvas_size):
    """把弯月 + 声波柱画成一张透明底的图。几何是按 108dp 的安全区定的。

    ⚠️ 安全区是给 **adaptive icon** 的约束，不是给传统图标的。
    传统图标（API < 26、Windows、商店列表）是整张方图直接显示，
    图形只占中间 2/3 的话，在任务栏里会比旁边的图标小一圈。
    所以 [legacy_icon] 会把这张图放大一点再用，[adaptive_foreground] 不会。
    """
    art = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))

    # ---- 弯月 ----
    moon = crescent_mask(canvas_size, cx=424, cy=512, outer_r=180,
                         bite_dx=82, bite_dy=-13, bite_r=155)
    art.alpha_composite(tinted(canvas_size, MOON_HI, MOON_LO, moon))

    # ---- 声波柱 ----
    # 4 根而不是 5 根：48px 下 5 根会糊成一团。间距比柱宽还大，
    # 让缩到最小尺寸时中间那点缝还在。
    #
    # x0 是贴着月亮的角定的——两个元素离远了会像两个不相干的图标，
    # 而不是一个标记。月亮右侧的角大概到 x≈539，这里留 24px 的缝。
    bars = bars_mask(canvas_size, x0=563, center_y=512, bar_w=30, gap=30,
                     heights=[128, 236, 236, 128], radius=15)
    art.alpha_composite(tinted(canvas_size, BAR_HI, BAR_LO, bars))

    return art


# 传统图标把图形放大这么多。1.28 之后图形大约占画布的 16%~83%，
# 是这类图标常见的留白量。
LEGACY_ZOOM = 1.28


def legacy_icon():
    """给 API < 26、Windows 和商店列表用的：背景 + 放大的图形，整块方形。"""
    base = build_art(with_background=True)
    mark = draw_mark(MASTER)
    if LEGACY_ZOOM != 1.0:
        side = round(MASTER * LEGACY_ZOOM)
        big = mark.resize((side, side), Image.LANCZOS)
        off = (MASTER - side) // 2
        mark = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
        mark.alpha_composite(big, (off, off))
    base.alpha_composite(mark)
    return base


def adaptive_foreground():
    """adaptive icon 的前景层：只有图形，透明背景，**保持安全区内的原始大小**。

    ⚠️ 不能跟着 [LEGACY_ZOOM] 放大——安全区是系统保证可见的范围，
    放出去的部分会被厂商的蒙版裁掉。test/assets/app_icon_test.dart
    里有一条测试盯着这件事。

    ⚠️ 也不能带背景——背景是单独一层，两层会一起被缩放和裁剪，
    前景自带背景的话会看到一圈对不齐的边。
    """
    return draw_mark(MASTER)


def save_png(img, size, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path, "PNG", optimize=True)
    return path


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."

    # Android 传统图标（API < 26 用），各密度
    legacy = legacy_icon()
    for folder, px in [
        ("mipmap-mdpi", 48),
        ("mipmap-hdpi", 72),
        ("mipmap-xhdpi", 96),
        ("mipmap-xxhdpi", 144),
        ("mipmap-xxxhdpi", 192),
    ]:
        save_png(legacy, px,
                 f"{root}/android/app/src/main/res/{folder}/ic_launcher.png")

    # adaptive icon 的前景。
    # ⚠️ 放 `drawable-xxxhdpi` 而不放 `drawable-nodpi`——`nodpi` 是「不缩放」，
    # 系统会按物理像素画，密度一变尺寸就错。108dp × 4x = 432px。
    save_png(adaptive_foreground(), 432,
             f"{root}/android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png")

    # Windows：多尺寸 ICO，标题栏和任务栏都会挑合适的那张
    ico = legacy
    ico.save(f"{root}/windows/runner/resources/app_icon.ico",
             sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64),
                    (128, 128), (256, 256)])

    # 预览图，方便肉眼确认（不进版本库）。
    # 带一排小尺寸——图标只要在小尺寸下糊成一团，大图再好看也没用。
    strip = Image.new("RGBA", (512 + 48 + 96 + 192 + 40, 512), (0, 0, 0, 0))
    strip.alpha_composite(legacy.resize((512, 512), Image.LANCZOS), (0, 0))
    x = 532
    for px in (48, 96, 192):
        strip.alpha_composite(legacy.resize((px, px), Image.LANCZOS), (x, 16))
        x += px + 12
    os.makedirs(f"{root}/../screenshots", exist_ok=True)
    strip.save(f"{root}/../screenshots/icon_preview.png")
    print("图标已生成")


if __name__ == "__main__":
    main()

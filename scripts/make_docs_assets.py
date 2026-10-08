"""生成文档站用的图标（favicon + 页眉 logo）。

    python scripts/make_docs_assets.py

复用 `make_app_icon.py` 里那套几何——图标是代码画出来的，这里不重画一遍，
否则 App 图标改了配色、文档站还挂着旧的，而且没人会发现。

两处取法不同，不是重复：
- **favicon** 用带背景的整张方图。浏览器页签里就 16px，透明底的弯月到那个
  尺寸只剩一根线；带底的方块反而更清楚，也和应用图标长得一样。
- **页眉 logo** 用透明底的图形本身，并**裁到内容边界**。Material 顶栏给 logo
  的高度只有 1.6rem 上下，不裁的话四周那圈 adaptive icon 的安全区留白会把
  图形进一步压小（安全区是给系统蒙版的约束，这里用不上）。
"""

import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import make_app_icon as icon

OUT_DIR = "docs/assets/images"

# 页眉 logo 的输出高度。Material 按高度放，宽度自适应——
# 图形是横向的（弯月 + 声波），所以比高度多一点点余量更稳。
LOGO_HEIGHT = 128


def build_favicon():
    return icon.legacy_icon().resize((64, 64), Image.LANCZOS)


def build_logo():
    mark = icon.draw_mark(icon.MASTER)
    box = mark.getbbox()
    if box is None:  # 理论上到不了：图形是画上去的
        raise SystemExit("画出来的图形是空的，检查 make_app_icon.draw_mark")
    pad = round((box[2] - box[0]) * 0.06)
    box = (
        max(box[0] - pad, 0),
        max(box[1] - pad, 0),
        min(box[2] + pad, icon.MASTER),
        min(box[3] + pad, icon.MASTER),
    )
    mark = mark.crop(box)
    width = round(mark.width * LOGO_HEIGHT / mark.height)
    return mark.resize((width, LOGO_HEIGHT), Image.LANCZOS)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    out = os.path.join(root, OUT_DIR)
    os.makedirs(out, exist_ok=True)

    favicon = build_favicon()
    favicon.save(os.path.join(out, "favicon.png"), "PNG", optimize=True)

    logo = build_logo()
    logo.save(os.path.join(out, "logo.png"), "PNG", optimize=True)

    print(f"favicon {favicon.width}x{favicon.height}  logo {logo.width}x{logo.height}")
    print(f"→ {out}")


if __name__ == "__main__":
    main()

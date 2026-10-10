"""为宣传视频生成卡片和字幕条（PIL 渲染成 PNG）。

## 为什么不用 ffmpeg 的 drawtext

这台机器上的 ffmpeg 没有 fontconfig，`drawtext` 直接段错误。而截图、缩放、
叠加、拼接这些**不带文字**的操作用 ffmpeg 完全没问题。

所以分工：**文字全在 Python 里渲成 PNG，ffmpeg 只做视频处理。**

    python scripts/make_promo_cards.py [输出目录，默认 build/promo]
"""

import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

W, H = 720, 1560
BG = (11, 16, 38)          # AppColors.midnight
ACCENT = (57, 135, 229)    # AppColors.accent
DIM = (139, 148, 184)      # AppColors.textDim
WHITE = (255, 255, 255)

REG = "C:/Windows/Fonts/msyh.ttc"
BOLD = "C:/Windows/Fonts/msyhbd.ttc"


def font(path: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, size)


def centered(draw, text, f, y, fill=WHITE, width=W):
    w = draw.textlength(text, font=f)
    draw.text(((width - w) / 2, y), text, font=f, fill=fill)


def title_card(out: pathlib.Path, logo: pathlib.Path):
    """标题卡：图标 + 名字 + 一句话。"""
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    if logo.exists():
        lg = Image.open(logo).convert("RGBA")
        lg = lg.resize((300, int(lg.height * 300 / lg.width)), Image.LANCZOS)
        img.paste(lg, ((W - lg.width) // 2, 430), lg)

    centered(d, "Sleep Secret", font(BOLD, 66), 800)
    centered(d, "整夜录音 · 声音不出手机", font(REG, 36), 900, DIM)

    # 底部一行小字：三个硬指标
    centered(d, "端侧推理 · 无账号 · 无服务器", font(REG, 28), 1420, ACCENT)
    img.save(out)


def end_card(out: pathlib.Path):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    centered(d, "Sleep Secret", font(BOLD, 56), 560)
    for i, line in enumerate([
        "GPL-3.0 开源",
        "分析全部在手机上完成",
        "音频默认不出设备",
    ]):
        centered(d, line, font(REG, 34), 700 + i * 66, DIM)

    centered(d, "github.com/14790897/sleep-secret", font(REG, 26), 1250, ACCENT)
    img.save(out)


def caption_bar(out: pathlib.Path, text: str, y: int = 1290, max_width: int = 660):
    """字幕条：透明底 + 圆角胶囊 + 一行字，叠加到画面上用。

    位置压在底部：睡眠页和报告页的下半部分都是空白或图表，不会挡住
    时间、评分、波形这些真正要看的元素。

    ⚠️ **字号会自动缩**：字幕比画面宽的话会被裁掉，而被裁掉的是后半句——
    读起来像另一句话。宁可小一号，也不能截断。
    """
    pad_x, pad_y = 34, 20
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))

    size = 34
    while size > 20:
        f = font(BOLD, size)
        tw = probe.textlength(text, font=f)
        if tw + pad_x * 2 <= max_width:
            break
        size -= 2
    f = font(BOLD, size)
    tw = probe.textlength(text, font=f)

    bw, bh = int(tw + pad_x * 2), int(size + pad_y * 2)
    img = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, bw - 1, bh - 1], radius=bh // 2,
                        fill=(11, 16, 38, 230), outline=ACCENT + (170,), width=2)
    d.text((pad_x, pad_y - 4), text, font=f, fill=WHITE)
    img.save(out)


CAPTIONS = {
    "cap_sleep": "睡前点一下就开始，屏幕可以关",
    "cap_morning": "早上给你一份报告",
    "cap_score": "睡眠声音评分：只看声音有多吵",
    "cap_breakdown": "100 分逐项扣得出来",
    "cap_signals": "只报模型真认出来的那几声",
    "cap_events": "每个事件都有时间 · 类别 · 置信度 · 分贝",
    "cap_detailed": "连模型的原话都能查：527 个标签逐条列",
    "cap_player": "鼾声整段留档：183 秒 → 3:05",
}


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "build/promo")
    root.mkdir(parents=True, exist_ok=True)

    title_card(root / "card_title.png",
               pathlib.Path("docs/assets/images/logo.png"))
    end_card(root / "card_end.png")
    for name, text in CAPTIONS.items():
        caption_bar(root / f"{name}.png", text)

    print(f"生成完毕 → {root}")
    for p in sorted(root.glob("card_*.png")) + sorted(root.glob("cap_*.png")):
        print("  ", p.name, Image.open(p).size)


if __name__ == "__main__":
    main()

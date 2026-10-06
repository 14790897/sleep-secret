"""生成阶段 2 验收用的测试夹具。

PC 端和 Android 端必须对同一段音频给出同样的 7 大类概率，
所以固定一份音频 + 一份 PC 端期望输出。
"""
import json
import pathlib

import numpy as np
import soundfile as sf

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTDATA = ROOT / "testdata"
TESTDATA.mkdir(exist_ok=True)
SR = 16000


def gen_clip(kind: str, seconds: float = 5.0, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = int(SR * seconds)
    t = np.arange(n) / SR

    if kind == "quiet":
        # 安静房间底噪
        x = rng.standard_normal(n) * 0.002
    elif kind == "noise":
        # 宽带噪声（应被判为环境噪音/白噪音一类）
        x = rng.standard_normal(n) * 0.15
    elif kind == "tone":
        # 纯音（AudioSet 里没有对应类，用于观察模型在分布外输入上的行为）
        x = 0.3 * np.sin(2 * np.pi * 440 * t)
    elif kind == "pulse":
        # 周期性宽带脉冲（模拟体动/敲击）
        x = rng.standard_normal(n) * 0.02
        for k in range(int(seconds * 2)):
            i = int(k * 0.5 * SR)
            x[i:i + 800] += rng.standard_normal(800) * 0.5
    else:
        raise ValueError(kind)

    return x.astype(np.float32)


def main():
    clips = {}
    for kind in ("quiet", "noise", "tone", "pulse"):
        x = gen_clip(kind)
        p = TESTDATA / f"{kind}.wav"
        sf.write(str(p), x, SR, subtype="PCM_16")
        clips[kind] = p
        print(f"写入 {p.name}  {len(x) / SR:.1f}s  rms={np.sqrt(np.mean(x ** 2)):.4f}")

    # ---- 用端侧模型算出期望输出 ----
    print("\n=== 用 ced-tiny.onnx 计算期望输出 ===", flush=True)
    import sys
    sys.path.insert(0, str(ROOT))
    from ml.infer import SleepSoundClassifier, CATEGORY_ORDER

    clf = SleepSoundClassifier()
    expected = {}
    for kind, p in clips.items():
        x, sr = sf.read(str(p), dtype="float32")
        assert sr == SR
        r = clf.predict(x)
        logits = clf.logits(x)
        expected[kind] = {
            "duration_sec": len(x) / SR,
            "categories": {c: round(r["categories"][c], 6) for c in CATEGORY_ORDER},
            "dominant": r["dominant"],
            "top3": [[name, round(v, 6)] for name, v in r["top3"]],
            "rms": round(float(np.sqrt(np.mean(x.astype(np.float64) ** 2))), 6),
            # 完整 527 维 logits：合成音频下概率接近均匀，比对单一标签不可靠，
            # 必须比 logits 向量本身（容差 1e-3）
            "logits": [round(float(v), 5) for v in logits],
        }
        print(f"  {kind:6s} dominant={r['dominant']:8s} "
              f"top3={[(n, round(v, 4)) for n, v in r['top3']]} "
              f"logits范围[{logits.min():.2f},{logits.max():.2f}]")

    out = TESTDATA / "expected.json"
    out.write_text(json.dumps({
        "model": "ced-tiny.onnx",
        "sample_rate": SR,
        "category_order": CATEGORY_ORDER,
        "tolerance": 1e-3,
        "note": ("Flutter 端对同一 wav 的 527 维输出应与这里逐元素一致（容差 1e-3）。"
                 "注意输出是**多标签 sigmoid 概率**，不要做 softmax。"
                 "这些片段是合成音频，dominant 标签只反映链路是否通，"
                 "不代表真实场景的识别效果。"),
        "clips": expected,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n已写入 {out}  ({out.stat().st_size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()

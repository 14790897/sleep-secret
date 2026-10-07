"""睡眠声音识别的 PC 端参考实现：波形 -> 527 维概率 -> 大类 -> 事件时间线。

⚠️ **这里不是"定义算法"的地方，App 才是。** 这个文件的作用是**第二实现**：
两端对同一段音频给出同样的输出，才能互相印证；只留一份实现的话，
写错了也没有第二双眼睛。

所以：**改动 App 的判定逻辑时，这个文件要跟着改**。已经有过一次教训——
AudioSet 的输出明明是 sigmoid，两端**都**做了 softmax，于是「两端逐元素一致」
双双通过，**一致性验证掩盖了双方都错**。一致性只能证明"两边一样"，
不能证明"两边对"。

## 和 App 的已知差异（有意的，不是漏改）

| 项 | App | 这里 | 为什么 |
|---|---|---|---|
| 能量门控阈值 | 随房间噪声底自适应 | 可关、可设固定值 | App 要在线判定，这里是离线批处理，算法本来就不该一样 |
| 高危信号事件 | `SoundEvent.signal` 单独成事件、豁免最短时长 | **不建模** | 那是 App 的呈现功能，由 App 自己的集成测试盯着；这里只负责标签分布 |

除此之外的判定逻辑（窗口栅格、大类取组内最大、无置信度门控、事件合并）
**必须一致**，不一致就是 bug。

    python ml/infer.py                      # 合成一夜，跑通整条链路
    python ml/infer.py a.wav [b.wav ...]    # 跑真实素材，打印「详细视图」那张表
"""
import json
import pathlib
import sys

import numpy as np
import onnxruntime as ort

ROOT = pathlib.Path(__file__).resolve().parent.parent
# ⚠️ 读** App 真正用的那一份**（`app/assets/models/`），不要另存一份。
# 这个仓库里曾经有过两份映射表，`models/` 那份停在 7 大类 31 个标签，
# 而 App 用的是 9 大类 47 个——PC 端一直照着旧的算，没人发现。
MODELS = ROOT / "app" / "assets" / "models"

SR = 16000

# 大类顺序。**键是枚举名（英文），不是中文展示名。**
#
# 曾经这里是 ["鼾声", "呼吸声", ...]，而 App 那边也一度拿中文当数据键——
# 后果是改一次界面文案就会让整张映射表读不出来。现在两边都用 `.name`，
# 中文只活在 App 的 `app_zh.arb` 里。
CATEGORY_ORDER = [
    "snore", "breathing", "cough", "sneeze", "vocal",
    "movement", "ambient", "deviceNoise", "silence",
]


class SleepSoundClassifier:
    """端侧 ONNX 分类器封装。输入波形，输出大类概率 + 原始标签。"""

    def __init__(self, model_path=None, map_path=None, threads=2):
        self.model_path = pathlib.Path(model_path or MODELS / "ced-tiny.onnx")
        map_path = pathlib.Path(map_path or MODELS / "sleep_class_map.json")

        opts = ort.SessionOptions()
        opts.intra_op_num_threads = threads
        opts.inter_op_num_threads = 1
        self.sess = ort.InferenceSession(str(self.model_path), opts,
                                         providers=["CPUExecutionProvider"])

        m = json.loads(map_path.read_text(encoding="utf-8"))
        self.categories = m["categories"]
        self.id2label = m["id2label"]
        self.core_snore = m["core_snore"]

        if set(self.categories) != set(CATEGORY_ORDER):
            raise ValueError(
                f"映射表的大类和 CATEGORY_ORDER 对不上："
                f"{sorted(set(self.categories) ^ set(CATEGORY_ORDER))}")

        # 预计算聚合索引：527 维 -> 9 维
        self._idx = {c: np.array(v, dtype=np.int64) for c, v in self.categories.items()}

    def logits(self, waveform: np.ndarray) -> np.ndarray:
        """waveform: float32 [N] 或 [1, N] -> [527]

        方法名沿用 ONNX 的输出名，实际内容是**多标签 sigmoid 概率**。

        ⚠️ 输入长度落在 17 万~25 万采样点区间时，上游模型会抛
        `BroadcastIterator::Init axis == 1 || axis == largest was false`。
        调用方要自己截断（App 那边是 `_maxInputSamples`）。
        """
        x = np.asarray(waveform, dtype=np.float32)
        if x.ndim == 1:
            x = x[None, :]
        elif x.ndim != 2:
            raise ValueError(f"期望 1D 或 2D，收到 {x.ndim}D")
        return self.sess.run(["logits"], {"waveform": x})[0][0]

    def predict(self, waveform: np.ndarray) -> dict:
        """返回大类得分 + 原始 top 标签。

        ⚠️ 模型的 527 维输出**已经是 sigmoid 概率**，不是 logits，不要做 softmax。

        AudioSet 是多标签数据集，各类别互相独立（猫叫和狗叫可以同时成立）。
        做 softmax 会除以 527 个值的大和，把 Snoring=0.96 压成 0.004——
        信号彻底丢失，后面任何阈值都过不了。

        判据：真实鼾声样本上输出向量之和约 2.7（不是 1.0），且有 3 个类别 >0.5。

        大类得分取组内**最大值**而非求和：求和同样会溢出 1，
        而且"鼾声"组里只要 Snoring 或 Snort 有一个高就说明是鼾声。

        ⚠️ **大类的稳定 ≠ 模型确信。** 原始标签跑偏到一个不属于任何大类的
        标签（比如 `Moo`）时，它不进任何一组的分数，最高的大类照样赢——
        实测一段做残的鼾声里，10/10 的窗口大类都是 snore，而其中 3 个窗口的
        原始标签是 `Moo` / `Cattle, bovinae` / `Vehicle`，鼾声分只有 0.10~0.26。
        **要看模型的原话，就得看 `raw` 和 `top`，不能看 `dominant`。**
        """
        scores = self.logits(waveform)
        agg = {c: float(scores[i].max()) for c, i in self._idx.items()}
        ranked = np.argsort(scores)[::-1]
        top = [(self.id2label[str(int(i))], float(scores[i])) for i in ranked[:5]]
        return {
            "categories": agg,
            "snore": float(scores[self.core_snore].max()),
            "top": top,
            # 这一窗模型"说的是什么"——527 维里得票最高的那个标签
            "raw": top[0][0],
            "confidence": top[0][1],
            "dominant": max(agg, key=agg.get),
        }


# ------------------------------------------------------------------ 事件判定

def analyze_session(waveform: np.ndarray, sr: int = SR, clf: SleepSoundClassifier = None,
                    window_sec: float = 3.0, hop_sec: float = 3.0,
                    vad_rms: float = None,
                    low_confidence_threshold: float = 0.25,
                    min_event_sec: float = 6.0, merge_gap_sec: float = 9.0) -> dict:
    """把整夜音频切成窗口，逐窗分类，再把同类相邻窗口合并成事件。

    ## 只有一道闸门：能量

    `vad_rms` 给了才生效（**默认 None = 不过滤**，和 App 的
    `AnalysisConfig.vadEnabled = false` 一致）。

    ⚠️ 这里**曾经**还有第二道「置信度门控」（`min_confidence`），
    已经在 App 上实测掉并删除了：它在真实音频上拦下的窗口数是 **0**——
    雨声、公鸡叫、真实鼾声、白噪声四份素材上都是 0，真实房间底噪上也是 0
    （底噪被稳定认成「环境噪音 0.359」，而那个归类**本来就是对的**）。

    它最初的依据是一个拿**合成白噪声**做的实验；合成白噪声和真实房间底噪的
    行为完全不同，那批假事件是合成信号的产物。**别把它加回来。**

    `low_confidence_threshold` 仍然留着，但**只是标记**：低于它的窗口照常
    产生事件，只是统计里记一笔。标定依据是**鼾声那一维**，而实际比的是
    各大类最大值——依据和用法对不上，所以这个数本身也还没有可靠依据。

    返回: {windows, events, stats, raw_label_counts}
    """
    clf = clf or SleepSoundClassifier()
    win = int(window_sec * sr)
    hop = int(hop_sec * sr)

    windows = []
    skipped = 0
    low_conf = 0
    raw_label_counts = {}
    pos = 0
    while pos + win <= len(waveform):
        seg = waveform[pos:pos + win]
        rms = float(np.sqrt(np.mean(seg.astype(np.float64) ** 2)))

        if vad_rms is not None and rms < vad_rms:
            skipped += 1
            windows.append({"t": pos / sr, "dominant": "silence", "raw": None,
                            "snore": 0.0, "rms": rms, "confidence": 1.0,
                            "inferred": False,
                            "categories": {c: 0.0 for c in CATEGORY_ORDER}})
            pos += hop
            continue

        r = clf.predict(seg)
        if r["confidence"] < low_confidence_threshold:
            low_conf += 1
        label = r["dominant"] if r["dominant"] != "silence" else None
        windows.append({"t": pos / sr, "dominant": label, "raw": r["raw"],
                        "snore": r["snore"], "rms": rms,
                        "confidence": r["confidence"], "inferred": True,
                        "categories": r["categories"]})
        # 原始标签按**窗口**计数，不按事件——同类相邻窗口会合并成一个大事件，
        # 记在事件上等于把罕见标签丢了（App 那边同理，见 SessionStats.rawLabelCounts）
        raw_label_counts[r["raw"]] = raw_label_counts.get(r["raw"], 0) + 1
        pos += hop

    # 相邻同标签窗口合并为事件
    events = []
    for w in windows:
        if w["dominant"] is None:
            continue
        if events and events[-1]["label"] == w["dominant"] and \
                w["t"] - (events[-1]["start"] + events[-1]["duration"]) <= merge_gap_sec:
            e = events[-1]
            e["duration"] = w["t"] + window_sec - e["start"]
            e["windows"].append(w)
            e["snore"] = max(e["snore"], w["snore"])
            e["confidence"] = max(e["confidence"], w["confidence"])
        else:
            events.append({"label": w["dominant"], "start": w["t"],
                           "duration": window_sec, "snore": w["snore"],
                           "confidence": w["confidence"], "windows": [w]})

    events = [e for e in events if e["duration"] >= min_event_sec]

    inferred = [w for w in windows if w["inferred"]]
    analyzed = len(windows) * window_sec
    snore_events = [e for e in events if e["label"] == "snore"]
    snore_time = sum(e["duration"] for e in snore_events)

    return {
        "windows": windows,
        "events": events,
        "raw_label_counts": raw_label_counts,
        "stats": {
            "analyzed_sec": analyzed,
            "windows_total": len(windows),
            "windows_inferred": len(inferred),
            "windows_vad_skipped": skipped,
            "windows_low_confidence": low_conf,
            "inference_ratio": round(len(inferred) / len(windows), 4) if windows else 0.0,
            "event_count": len(events),
            "snore_event_count": len(snore_events),
            "snore_seconds": snore_time,
            # 鼾声指数：鼾声时长占分析时长的百分比，用于跨夜比较
            "snore_index": round(snore_time / analyzed * 100, 2) if analyzed else 0.0,
            "category_distribution": {
                c: round(sum(w["categories"][c] for w in inferred) / len(inferred), 4)
                if inferred else 0.0 for c in CATEGORY_ORDER
            },
        },
    }


# ------------------------------------------------------------------ 详细视图

def print_label_table(counts: dict, title: str, categories: dict,
                      id2label: dict) -> None:
    """打印 App 报告页那张「详细视图」——按窗口数排的原始 AudioSet 标签。

    这个表是**核查用**的：上面每张表说的都是大类（我们拼出来的），
    这张说的才是模型的**原话**。报告哪里看着不对时，先看它，
    能立刻分清是模型说错了还是映射错了。

    ⚠️ **「未映射」那一列最该看。** 527 个标签里只映射了 47 个；
    没被映射的标签当冠军时，那一窗在 App 里**不产生任何事件**——
    它在报告的别的任何地方都不会出现，只在这里露一面。
    """
    label_cat = {id2label[str(i)]: c for c, idx in categories.items() for i in idx}
    total = sum(counts.values())
    rows = sorted(counts.items(), key=lambda e: -e[1])
    unmapped = [k for k, _ in rows if k not in label_cat]

    print(f"\n┌ {title} " + "─" * max(0, 54 - len(title)))
    print(f"│ 共 {len(rows)} 种标签 · {total} 个分析窗口")
    print("│ 一个计数 = 一个分析窗口（3 秒）")
    if unmapped:
        print(f"│ ⚠ 其中 {len(unmapped)} 种没有归进任何大类："
              f"{'、'.join(unmapped[:6])}" + ("…" if len(unmapped) > 6 else ""))
    print("│")
    for k, v in rows:
        cat = label_cat.get(k, "未映射")
        print(f"│ {v:6d}   {k:34} {cat:11} {v / total * 100:5.1f}%")
    print("└" + "─" * 58)


def _label_view(paths):
    """跑真实素材，逐段打印「详细视图」。"""
    clf = SleepSoundClassifier()
    print(f"模型 {clf.model_path.name}  大类 {len(CATEGORY_ORDER)} 个  "
          f"标签 {len(clf.id2label)} 个（映射了 "
          f"{sum(len(v) for v in clf.categories.values())} 个）")

    combined = {}
    for p in paths:
        import soundfile as sf
        x, sr = sf.read(str(p), dtype="float32")
        if x.ndim > 1:
            x = x.mean(axis=1)
        if sr != SR:
            raise SystemExit(f"{p}: 采样率 {sr}，需要 {SR}（这个脚本不做重采样）")

        # ⚠️ **一个文件一个文件地跑**，不要把几段拼起来再算。
        # 拼接之后按整窗推进会让窗口横跨两段素材，标签就张冠李戴了——
        # 第一版就是这么错的，把一段做残的鼾声读成了「牛叫」。
        res = analyze_session(x, clf=clf)
        n = len(res["windows"])
        print(f"\n=== {p}  {len(x) / SR:.1f}s  {n} 个窗口 ===")
        print(f"  大类分布："
              + "  ".join(f"{c}={v:.2f}" for c, v in
                          sorted(res["stats"]["category_distribution"].items(),
                                 key=lambda e: -e[1]) if v > 0.01))
        for lab, cnt in sorted(res["raw_label_counts"].items(), key=lambda e: -e[1]):
            print(f"    {cnt:5d}× {lab}")
        for k, v in res["raw_label_counts"].items():
            combined[k] = combined.get(k, 0) + v

    print_label_table(combined, "详细视图·全部素材合计", clf.categories, clf.id2label)


# ------------------------------------------------------------------ 演示

def _demo():
    """合成一夜音频（含周期性鼾声段），跑通整条分析链路。"""
    import time

    print("=== 加载端侧模型 ===", flush=True)
    t0 = time.time()
    clf = SleepSoundClassifier()
    print(f"加载耗时 {(time.time() - t0) * 1000:.0f}ms  ({clf.model_path.name})")

    print("\n=== 合成一夜音频（12 分钟，含 3 段鼾声）===", flush=True)
    rng = np.random.default_rng(1)
    minutes = 12
    audio = (rng.standard_normal(SR * 60 * minutes) * 0.002).astype(np.float32)  # 安静底噪
    # 3 段"鼾声"：约 60Hz 的周期性低频调制（仅用于验证链路，不代表真实鼾声检测效果）
    for start_min in (2, 5, 9):
        a = start_min * 60 * SR
        b = a + 90 * SR
        n = b - a
        t = np.arange(n) / SR
        env = 0.5 + 0.5 * np.sin(2 * np.pi * 0.35 * t)          # 约 21 秒一个呼吸周期
        audio[a:b] += (0.25 * env * np.sin(2 * np.pi * 62 * t)).astype(np.float32)
    print(f"音频长度 {len(audio) / SR / 60:.1f} 分钟")

    print("\n=== 分析 ===", flush=True)
    t0 = time.time()
    res = analyze_session(audio, clf=clf, window_sec=3.0, hop_sec=3.0)
    elapsed = time.time() - t0
    s = res["stats"]
    print(f"分析耗时 {elapsed:.1f}s  ({len(res['windows'])} 个窗口, "
          f"平均 {elapsed / max(1, len(res['windows'])) * 1000:.0f}ms/窗口)")

    print("\n--- 统计 ---")
    for k in ("analyzed_sec", "windows_total", "windows_inferred",
              "windows_vad_skipped", "windows_low_confidence", "inference_ratio",
              "event_count", "snore_event_count", "snore_seconds", "snore_index"):
        print(f"  {k}: {s[k]}")
    print("  类别分布 (仅统计实际推理的窗口):")
    for c, v in s["category_distribution"].items():
        bar = "█" * int(v * 40)
        print(f"    {c:12s} {v:.4f} {bar}")

    print("\n--- 检出事件 ---")
    for e in res["events"]:
        mm, ss = divmod(int(e["start"]), 60)
        print(f"  [{mm:02d}:{ss:02d}] {e['label']:10s} 时长 {e['duration']:.0f}s  "
              f"鼾声概率峰值 {e['snore']:.3f}")

    print_label_table(res["raw_label_counts"], "详细视图", clf.categories, clf.id2label)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if args:
        _label_view([pathlib.Path(a) for a in args])
    else:
        _demo()

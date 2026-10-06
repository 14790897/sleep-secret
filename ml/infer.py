"""睡眠声音识别参考实现：波形 -> 527 logits -> 7 大类 -> 事件时间线。

Flutter 端要照着这个逻辑实现，因此这里把算法定义清楚、可测。
"""
import json
import pathlib

import numpy as np
import onnxruntime as ort

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODELS = ROOT / "models"

SR = 16000
CATEGORY_ORDER = ["鼾声", "呼吸声", "咳嗽清嗓", "人声梦话", "体动床响", "环境噪音", "静音"]


class SleepSoundClassifier:
    """端侧 ONNX 分类器封装。输入波形，输出 7 大类概率。"""

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

        # 预计算聚合索引：527 维 -> 7 维
        self._idx = {c: np.array(v, dtype=np.int64) for c, v in self.categories.items()}

    def logits(self, waveform: np.ndarray) -> np.ndarray:
        """waveform: float32 [N] 或 [1, N] -> [527]

        方法名沿用 ONNX 的输出名，实际内容是**多标签 sigmoid 概率**。
        """
        x = np.asarray(waveform, dtype=np.float32)
        if x.ndim == 1:
            x = x[None, :]
        elif x.ndim != 2:
            raise ValueError(f"期望 1D 或 2D，收到 {x.ndim}D")
        # 动态长度：模型自己处理，但过短会没有帧
        return self.sess.run(["logits"], {"waveform": x})[0][0]

    def predict(self, waveform: np.ndarray) -> dict:
        """返回 7 大类得分 + 原始 top 标签。

        ⚠️ 模型的 527 维输出**已经是 sigmoid 概率**，不是 logits，不要做 softmax。

        AudioSet 是多标签数据集，各类别互相独立（猫叫和狗叫可以同时成立）。
        做 softmax 会除以 527 个值的大和，把 Snoring=0.96 压成 0.004——
        信号彻底丢失，置信度门控也就永远过不了。

        判据：真实鼾声样本上输出向量之和约 2.7（不是 1.0），且有 3 个类别 >0.5。

        大类得分取组内**最大值**而非求和：求和同样会溢出 1，
        而且"鼾声"组里只要 Snoring 或 Snort 有一个高就说明是鼾声。
        """
        scores = self.logits(waveform)
        agg = {c: float(scores[i].max()) for c, i in self._idx.items()}
        top = np.argsort(scores)[::-1][:3]
        return {
            "categories": agg,
            "snore": float(scores[self.core_snore].max()),
            "top3": [(self.id2label[str(int(i))], float(scores[i])) for i in top],
            "dominant": max(agg, key=agg.get),
        }


# ------------------------------------------------------------------ 事件判定

def analyze_session(waveform: np.ndarray, sr: int = SR, clf: SleepSoundClassifier = None,
                    window_sec: float = 3.0, hop_sec: float = 3.0,
                    vad_rms: float = 0.01,
                    min_confidence: float = 0.15,
                    snore_threshold: float = 0.35,
                    min_event_sec: float = 6.0, merge_gap_sec: float = 9.0) -> dict:
    """把整夜音频切成窗口，逐窗分类，再把同类的相邻窗口合并成事件。

    两道闸门（缺一不可，否则底噪会被强行归类成"环境噪音"）：
      1. 能量门控 vad_rms  —— 窗口 RMS 低于阈值直接判静音，**不做推理**，省算力
      2. 置信度门控 min_confidence —— top1 概率太低的窗口判为"未识别"，不产生事件

    返回: {windows: [...], events: [...], stats: {...}}
    """
    clf = clf or SleepSoundClassifier()
    win = int(window_sec * sr)
    hop = int(hop_sec * sr)

    windows = []
    skipped = 0
    low_conf = 0
    pos = 0
    while pos + win <= len(waveform):
        seg = waveform[pos:pos + win]
        rms = float(np.sqrt(np.mean(seg.astype(np.float64) ** 2)))

        if rms < vad_rms:
            skipped += 1
            windows.append({"t": pos / sr, "dominant": "静音", "snore": 0.0,
                            "rms": rms, "confidence": 1.0, "inferred": False,
                            "categories": {c: 0.0 for c in CATEGORY_ORDER}})
            pos += hop
            continue

        r = clf.predict(seg)
        conf = r["top3"][0][1]
        if conf < min_confidence:
            low_conf += 1
            windows.append({"t": pos / sr, "dominant": "静音", "snore": r["snore"],
                            "rms": rms, "confidence": conf, "inferred": True,
                            "categories": r["categories"]})
        else:
            windows.append({"t": pos / sr, "dominant": r["dominant"], "snore": r["snore"],
                            "rms": rms, "confidence": conf, "inferred": True,
                            "categories": r["categories"]})
        pos += hop

    # 相邻同标签窗口合并为事件
    events = []
    for w in windows:
        if w["dominant"] == "静音":
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
    snore_events = [e for e in events if e["label"] == "鼾声"]
    snore_time = sum(e["duration"] for e in snore_events)

    return {
        "windows": windows,
        "events": events,
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
        print(f"    {c:6s} {v:.4f} {bar}")

    print("\n--- 检出事件 ---")
    for e in res["events"]:
        mm, ss = divmod(int(e["start"]), 60)
        print(f"  [{mm:02d}:{ss:02d}] {e['label']:8s} 时长 {e['duration']:.0f}s  "
              f"鼾声概率峰值 {e['snore']:.3f}")


if __name__ == "__main__":
    _demo()

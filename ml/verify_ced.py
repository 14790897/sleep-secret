"""验证 CED-tiny 上游 ONNX 是否可信，并生成睡眠类别映射。

上游 ONNX 已是「原始波形 -> 527 logits」，无需自己导出，只需确认它与 HF 官方实现一致。
"""
import json
import pathlib

import numpy as np
import onnx
import torch

# 上游模型（要自己下载的那个）放这儿
MODELS = pathlib.Path(__file__).resolve().parent.parent / "models"
# 而**产物要写到 App 真正读的地方**，见 sleep_classes.py 里的说明
APP_MODELS = pathlib.Path(__file__).resolve().parent.parent / "app" / "assets" / "models"
CED_TINY = "mispeech/ced-tiny"


def main():
    # 这个目录只放**要自己下载的上游模型**，不进版本库。
    # 它曾经还存着 app/assets/models/ 的两份副本（模型 + 映射表），
    # 而那份映射表悄悄停在了 7 大类 31 个标签——PC 端一直照着旧的算。
    # 现在只剩这一个用途，缺文件时给一句能照着做的提示，别只抛 No such file。
    upstream = MODELS / "ced-tiny.upstream.onnx"
    if not upstream.exists():
        raise SystemExit(
            f"缺少上游模型 {upstream}\n"
            f"先下载：从 https://huggingface.co/{CED_TINY} 取 onnx 文件存成这个路径。\n"
            f"（App 实际用的模型在 app/assets/models/ced-tiny.onnx，"
            f"那个不用动。）")

    print("=== 1. 上游 ONNX 结构 ===", flush=True)
    m = onnx.load(str(upstream))
    g = m.graph

    from collections import Counter
    dtypes = Counter(onnx.TensorProto.DataType.Name(i.data_type) for i in g.initializer)
    print("初始化器类型分布:", dict(dtypes))
    # 量化模型会有 QuantizeLinear / DequantizeLinear 节点
    ops = Counter(n.op_type for n in g.node)
    quant_ops = {k: v for k, v in ops.items() if 'Quant' in k}
    print("量化相关算子:", quant_ops if quant_ops else "无（纯浮点模型）")
    print("算子总种类:", len(ops))

    print("\n=== 2. 与 HF 官方实现对比 ===", flush=True)
    from transformers import AutoFeatureExtractor, AutoModelForAudioClassification

    fe = AutoFeatureExtractor.from_pretrained(CED_TINY, trust_remote_code=True)
    model = AutoModelForAudioClassification.from_pretrained(
        CED_TINY, trust_remote_code=True).eval()
    print("官方实现加载成功，类别数:", model.config.num_labels)

    rng = np.random.default_rng(0)

    import onnxruntime as ort
    sess = ort.InferenceSession(str(MODELS / "ced-tiny.upstream.onnx"),
                                providers=["CPUExecutionProvider"])

    print("\n--- 多种输入长度下的对齐 ---")
    for n_sec in (1, 5, 10):
        wav = (rng.standard_normal(16000 * n_sec) * 0.05).astype(np.float32)

        with torch.no_grad():
            feat = fe(wav, sampling_rate=16000, return_tensors="pt")
            ref = model(**feat).logits.numpy()[0]

        o = sess.run(["logits"], {"waveform": wav[None, :]})[0][0]

        cos = float(np.dot(ref, o) / (np.linalg.norm(ref) * np.linalg.norm(o)))
        md = float(np.abs(ref - o).max())
        print(f"  {n_sec:2d}s  余弦 {cos:.6f}  最大差 {md:.4f}  "
              f"{'✅' if cos > 0.999 else '❌'}")

    # ---- 3. 睡眠类别映射（用 CED 自己的标签名）----
    print("\n=== 3. 生成睡眠类别映射 ===", flush=True)
    id2label = model.config.id2label
    print("标签总数:", len(id2label))

    # CED 的标签名与 AST 略有不同（如 "Male speech" vs "Male speech, man speaking"）
    SLEEP_MAP = {
        "鼾声":     ["Snoring", "Snort"],
        "呼吸声":   ["Breathing", "Wheeze", "Gasp", "Sigh"],
        "咳嗽清嗓": ["Cough", "Throat clearing", "Sneeze", "Sniff"],
        "人声梦话": ["Speech", "Male speech, man speaking", "Female speech, woman speaking",
                     "Child speech, kid speaking", "Whispering", "Laughter", "Crying, sobbing",
                     "Groan"],
        "体动床响": ["Rustle", "Rustling leaves", "Tap", "Clicking"],
        "环境噪音": ["Noise", "Environmental noise", "White noise",
                     "Traffic noise, roadway noise", "Wind", "Rain", "Door", "Music"],
        "静音":     ["Silence"],
    }

    name2idx = {v: int(k) for k, v in id2label.items()}
    mapping, missing = {}, []
    for cat, names in SLEEP_MAP.items():
        idxs = []
        for n in names:
            if n in name2idx:
                idxs.append(name2idx[n])
            else:
                missing.append(n)
        mapping[cat] = idxs

    for cat, idxs in mapping.items():
        print(f"  {cat}: {idxs}")
    if missing:
        print("\n⚠️ 未匹配到的标签名（需按 CED 实际命名修正）:")
        for n in missing:
            print("   ", n, "-> 候选:", [v for v in id2label.values()
                                          if n.split()[0].lower() in v.lower()][:4])

    (APP_MODELS / "sleep_class_map.json").write_text(
        json.dumps({"model": CED_TINY, "categories": mapping,
                    "id2label": id2label}, ensure_ascii=False, indent=2),
        encoding="utf-8")
    print(f"\n已写入 {APP_MODELS / 'sleep_class_map.json'}")


if __name__ == "__main__":
    main()

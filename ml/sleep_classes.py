"""生成 AudioSet 527 类 -> 睡眠大类 的映射表。

CED 与 AST 用的是同一套 AudioSet 527 类标签，因此映射表通用。
标签名从模型 config 的 id2label 读取，避免手写错名。
"""
import json
import pathlib

MODELS = pathlib.Path(__file__).resolve().parent.parent / "models"

# 标签名必须与 AudioSet id2label 完全一致（注意逗号后的完整描述）
SLEEP_MAP = {
    "snore":     ["Snoring", "Snort"],
    "breathing":   ["Breathing", "Wheeze", "Gasp", "Sigh"],
    "cough": ["Cough", "Throat clearing", "Sneeze", "Sniff"],
    "vocal": ["Speech", "Male speech, man speaking", "Female speech, woman speaking",
                 "Child speech, kid speaking", "Whispering", "Laughter", "Crying, sobbing",
                 "Groan"],
    "movement": ["Rustle", "Rustling leaves", "Tap", "Clicking"],
    "ambient": ["Noise", "Environmental noise", "White noise",
                 "Traffic noise, roadway noise", "Wind", "Rain", "Door", "Music"],
    "silence":     ["Silence"],
}

# 判定"这是鼾声事件"时使用的核心类别（用于鼾声指数）
CORE_SNORE = ["Snoring"]


def build(id2label: dict) -> dict:
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
    return {"categories": mapping, "missing": missing, "id2label": id2label}


def main():
    from transformers import AutoConfig

    cfg = AutoConfig.from_pretrained("mispeech/ced-tiny", trust_remote_code=True)
    # config 里 id2label 的 key 可能是 int 也可能是 str，统一成 str
    id2label = {str(k): v for k, v in cfg.id2label.items()}
    print(f"标签总数 {len(id2label)}")

    res = build(id2label)
    for cat, idxs in res["categories"].items():
        names = [id2label[str(i)] for i in idxs]
        print(f"  {cat}: {idxs}  {names}")
    if res["missing"]:
        print("\n⚠️ 未匹配的标签名:", res["missing"])
    else:
        print("\n✅ 全部标签名匹配成功")

    # 反向索引：527 维 logits -> 大类概率（求和聚合）
    out = {
        "model": "mispeech/ced-tiny",
        "num_classes": len(id2label),
        "categories": res["categories"],
        "aggregation": "sum",       # 大类概率 = 该类下所有标签概率之和
        "core_snore": [int(k) for k, v in id2label.items() if v in CORE_SNORE],
        "id2label": id2label,
    }
    p = MODELS / "sleep_class_map.json"
    p.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n已写入 {p}")


if __name__ == "__main__":
    main()

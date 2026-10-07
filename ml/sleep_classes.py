"""生成 AudioSet 527 类 -> 睡眠大类 的映射表。

CED 与 AST 用的是同一套 AudioSet 527 类标签，因此映射表通用。
标签名从模型 config 的 id2label 读取，避免手写错名。
"""
import json
import pathlib

# ⚠️ **产物目录必须是 App 真正读的那个。**
#
# 原来这里是 `<仓库根>/models/`，而 App 读 `app/assets/models/`——
# 于是这个脚本一直把映射表写在**没人读的地方**，而跑的人会以为更新生效了。
# 结果就是仓库里有**两份分叉的映射表**：`models/` 那份停在 7 大类 31 个标签，
# 而 App 用的是 9 大类 47 个。**「跑了但没生效」比报错难发现得多。**
MODELS = pathlib.Path(__file__).resolve().parent.parent / "app" / "assets" / "models"

# 标签名必须与 AudioSet id2label 完全一致（注意逗号后的完整描述）
SLEEP_MAP = {
    # Sniff 放这儿而不是咳嗽组：吸鼻子和喷鼻息（Snort）一样是**吸气相**的气道声，
    # 鼻塞越重吸得越用力。放在一起，「这一夜鼻子不通」才看得出来。
    "snore":     ["Snoring", "Snort", "Sniff"],
    "breathing":   ["Breathing", "Wheeze", "Gasp", "Sigh",
                    "Pant"],
    "cough": ["Cough", "Throat clearing"],
    # 喷嚏单独一类：它是爆发性的鼻腔冲气，和咳嗽（喉部）声学上不是一回事，
    # 而且夜间喷嚏往往意味着过敏，和咳嗽指向的原因不同。
    "sneeze": ["Sneeze"],
    "vocal": ["Speech", "Male speech, man speaking", "Female speech, woman speaking",
                 "Child speech, kid speaking", "Whispering", "Laughter", "Crying, sobbing",
                 "Groan", "Wail, moan", "Babbling", "Grunt",
                 "Baby cry, infant cry"],
    "movement": ["Rustle", "Rustling leaves", "Tap", "Clicking",
                 "Thump, thud"],
    "ambient": ["Noise", "Environmental noise", "White noise",
                 "Traffic noise, roadway noise", "Wind", "Rain", "Door", "Music",
                 "Purr"],
    # 这几个是 2026-10-07 逐行读完整张表补的。原来只用正则挑，
    # 漏掉了「moan」「babbling」这类名字里不带关键词但明显相关的。
    "silence":     ["Silence"],
    # 机器声和麦克风自身的噪声。**单独分出来是因为它们是打鼾检测最大的误报源**——
    # 风扇和空调的低频嗡鸣在频谱上极像鼾声。分出来之后界面才能说
    # 「那是风扇，不是鼾声」，而不是笼统地叫「环境噪音」。
    #
    # 「Wind noise (microphone)」不是机器，是手机麦克风被被子/呼吸吹到，
    # 但它同样表现为持续的低频噪声，归到一类里最好用。
    "deviceNoise": ["Wind noise (microphone)", "Mechanical fan", "Air conditioning",
                    "Vacuum cleaner", "Hair dryer", "Electric shaver, electric razor",
                    "Whir", "Hum", "Mains hum"],
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
        # 大类分数取组内**最大值**，不是求和。求和会溢出 1，
        # 而且「鼾声」组里只要 Snoring 或 Snort 有一个高就说明是鼾声。
        # 端侧实现在 `app/lib/data/repositories/sleep_analysis_repository.dart`。
        "aggregation": "max",
        "core_snore": [int(k) for k, v in id2label.items() if v in CORE_SNORE],
        "id2label": id2label,
    }
    p = MODELS / "sleep_class_map.json"
    p.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n已写入 {p}")


if __name__ == "__main__":
    main()

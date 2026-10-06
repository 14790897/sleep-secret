# 第三方内容声明

本仓库包含第三方素材。以下是来源与许可，使用前请自行核对原始许可条款
（这不是法律意见）。

## 一、音频素材 —— ESC-50（⚠️ 禁止商用）

- **来源**：ESC-50: Dataset for Environmental Sound Classification
  （<https://github.com/karolpiczak/ESC-50>），本仓库经由 HuggingFace 数据集
  `ashraq/esc50` 获取
- **许可**：**CC BY-NC 3.0**（署名 — **非商业性使用**）
- **本仓库中的位置**：
  - `testdata/snore_esc50/*.wav`、`testdata/control_esc50/*.wav`（原始片段）
  - `app/assets/testdata/real/*.wav`（供 App 内测试使用，与上面同源）
  - `app/assets/testdata/real/mic_farfield_snore.wav` —— **派生作品**：
    把上表的鼾声经扬声器播放、再由麦克风采回的录音。
    同样受 CC BY-NC 约束。
- **用途**：仅用于验证「模型认不认得出真实鼾声」。
- **下载脚本**：`scripts/fetch_real_snore.py`

> ⚠️ **CC BY-NC 禁止商业使用。** 如果你打算把这个应用商业化，
> 必须先移除或替换掉上述所有 ESC-50 派生素材（包括 `mic_farfield_snore.wav`）。
> 它们只在测试里用到，删掉不影响应用本身的功能。

## 二、模型 —— CED-tiny

- **来源**：<https://huggingface.co/mispeech/ced-tiny>
- **许可**：**Apache-2.0**（允许商用，需保留署名）
- **本仓库中的位置**：`app/assets/models/ced-tiny.onnx`、`models/ced-tiny.onnx`
- **引用**：CED: Consistent Ensemble Distillation for Audio Tagging
  （arXiv:2308.11957）
- **说明**：模型在 AudioSet 上训练。AudioSet 的类别体系见
  `models/sleep_class_map.json` 里的 527→7 映射。

## 三、运行时依赖

Flutter / Dart 包的许可见 `app/pubspec.lock`；
Android 侧依赖的许可见 Gradle 依赖树（`flutter build apk` 会汇总）。
其中 ONNX Runtime 为 MIT 许可。

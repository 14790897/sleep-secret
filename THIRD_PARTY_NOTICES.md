# 第三方内容声明

本仓库包含第三方素材。以下是来源与许可，使用前请自行核对原始许可条款
（这不是法律意见）。

## 一、音频素材 —— CC0（公共领域）

- **来源**：Freesound，经 [Openverse](https://openverse.org) 检索。
  **每个文件的作者、原始链接、许可和模型得分都记在
  [`scripts/test_audio_sources.json`](scripts/test_audio_sources.json)**
- **许可**：**CC0 1.0**（公共领域奉献）——没有署名义务，也没有非商业限制
- **本仓库中的位置**：`app/assets/testdata/real/*.wav`
- **用途**：测试「模型认不认识真实鼾声」，以及两个对照组（雨声、鸡叫）
- **抓取脚本**：[`scripts/fetch_test_audio.py`](scripts/fetch_test_audio.py)
  ——可以重跑，它按模型打分挑文件（见下）

### 为什么不用 ESC-50

这 6 个文件原来**全部来自 ESC-50**（CC BY-NC，署名-非商业），而且因为写在
`pubspec.yaml` 的 assets 里，**2.3 MB 全打进了 release APK**。

两个问题：非商业限制跟「这是个给用户用的 App」有张力；而且它让 App
不能进 F-Droid（只收自由许可的内容）。2026-10-07 全部换成了 CC0。

### 挑法：不靠标题，靠模型打分

`fetch_test_audio.py` 会把每个候选**先喂给 App 用的那个模型**，
只留模型确实判成鼾声的（对照组反过来，只留没判成鼾声的）。
20 个候选里只有 12 个合格——"Dog Snores" 这种按名字看完全正常的，
模型给 0.593，照样不能用。

当前几个文件的核心鼾声得分：`snore_01/02/05` = 0.910 / 0.965 / 0.816，
`rain` 和 `rooster` = 0.000，`bandlimited_snore` = 0.871。

### `bandlimited_snore.wav` 是派生作品

它由上面某一段 CC0 鼾声**加工**而来：削掉 320Hz 以下、再压上房间噪声，
用来模拟「手机没放在枕边」的情形。所以它仍然只受 CC0 约束。

### 已淘汰的脚本

`scripts/fetch_real_snore.py`（那个下载 ESC-50 的脚本）**已删除**——
留着迟早有人（包括写它的人）再把非自由内容引回来。

## 二、模型 —— CED-tiny

- **来源**：<https://huggingface.co/mispeech/ced-tiny>
- **许可**：**Apache-2.0**（允许商用，需保留署名）
- **本仓库中的位置**：`app/assets/models/ced-tiny.onnx`
- **引用**：CED: Consistent Ensemble Distillation for Audio Tagging
  （arXiv:2308.11957）
- **说明**：模型在 AudioSet 上训练。527→7 的大类映射见
  `app/assets/models/sleep_class_map.json`，生成脚本是 `ml/sleep_classes.py`。

## 三、运行时依赖

Flutter / Dart 包的许可见 `app/pubspec.lock`；
Android 侧依赖的许可见 Gradle 依赖树（`flutter build apk` 会汇总）。
其中 ONNX Runtime 为 MIT 许可。

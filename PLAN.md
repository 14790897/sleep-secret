# 睡眠录音分析 App（类蜗牛睡眠）— 实施计划

> 更新于 2026-10-06。模型已从 AST 切换为 **CED-tiny**（用户决定），延迟风险因此消除。

## Context

做一个 Android 睡眠监测 App：整夜后台录音，用音频 Transformer 对睡眠声音做多类别识别，并可视化分析。

**核心决策（已确认）**：
- **不做训练**。直接用 `mispeech/ced-tiny` 预训练权重（AudioSet 527 类），把输出聚合映射成 7 个睡眠大类。
- **App 用 Flutter**。
- 推理放端侧（隐私优先，睡眠录音不上传）。

---

## 一、阶段 1 已完成：模型管线跑通 ✅

阶段 1 在本次会话中**已经做完并验证**，代码在 `ml/`，产物在 `models/`。

### 为什么换成 CED-tiny

原计划用 AST（86.6M 参数）。实测后发现 CED-tiny 全面更优：

| | AST | **CED-tiny** |
|---|---|---|
| 参数量 | 86.6M | **5.5M** |
| INT8 体积 | 87 MB | **6.3 MB** |
| PC CPU 延迟 / 10s 窗口 | 594 ms | **30 ms** |
| 输入长度 | 固定 164080 点（必须补零） | **动态，任意长度** |
| 特征提取 | Kaldi fbank（复刻麻烦） | torchaudio MelSpectrogram（简单） |
| 与官方实现一致性 | 余弦 1.000000 | 余弦 1.000000 |
| 类别空间 | AudioSet 527 类 | AudioSet 527 类（**同一套，映射表通用**） |

**延迟风险因此消失**：原本担心的「整夜分析要几十分钟」不再存在。

### 已验证的事实（全部实测，非推测）

**模型规格**：16kHz 单声道，mel 64 bins，n_fft 512 / win 512 / hop 160，center=True，f_min=0，f_max=8000，`AmplitudeToDB(top_db=120)`。

**导出与校验**（`ml/export_ced.py`）：
- 把特征提取烘进 ONNX 图 → 输入是**原始 PCM 波形**，输出 527 logits
- mel 特征最大误差 **0.00000**；端到端 logits 余弦 **1.000000**（最大差 0.00000）
- 动态长度 1s / 3s / 5s / 10s **全部余弦 1.000000**
- INT8 量化后余弦 **0.999998**，体积 **6.3 MB**（单文件）

**坑（都记在 `ml/export_ced.py` 注释里）**：
- 必须用 `dynamo=True` 导出器；legacy torchscript 不支持 STFT/rfft
- 导出前必须 `requires_grad_(False)`，否则 5.5M 权重被当作图输入
- 不要指定低 opset（dynamo 的图带 axes-as-input，降版本会失败）
- 量化前需清空 `graph.value_info`，否则 `onnx.shape_inference` 报形状冲突

**上游自带的 `model.onnx` 不可用**：`mispeech/ced-tiny` 仓库里那个 6.37MB 的 `model.onnx` 实测与官方 HF 实现余弦只有 **0.08~0.17**（等于随机）。它的权重是 INT8 存储但没有量化算子。**必须用我们自己导出的版本。**

### 睡眠类别映射（`ml/sleep_classes.py` → `models/sleep_class_map.json`）

527 类按组求和聚合成 7 大类，28 个标签名全部精确匹配：

| 睡眠大类 | AST/CED 原生类别（索引） |
|---|---|
| 鼾声 | Snoring (43)、Snort (46) |
| 呼吸声 | Breathing (41)、Wheeze (42)、Gasp (44)、Sigh (26) |
| 咳嗽清嗓 | Cough (47)、Throat clearing (48)、Sneeze (49)、Sniff (50) |
| 人声梦话 | Speech (0–3)、Whispering (15)、Laughter (16)、Crying, sobbing (22)、Groan (38) |
| 体动床响 | Rustle (487)、Rustling leaves (284)、Tap (360)、Clicking (491) |
| 环境噪音 | Noise (513)、Environmental Noise (514)、White noise (520)、Traffic (327)、Wind (283)、Rain (289)、Door (354)、Music (137) |
| 静音 | Silence (500) |

### 分析算法（`ml/infer.py`，Flutter 端照此实现）

**两道闸门缺一不可**——端到端实测发现，只用 softmax 会把底噪强行归类（softmax 永远归一化到 1，必有某个类"最高"）：

1. **能量门控 VAD**：窗口 RMS < 阈值 → 直接判静音，**不做推理**（省算力）
2. **置信度门控**：top-1 概率 < 阈值 → 判"未识别"，不产生事件

实测效果（12 分钟合成音频，240 个 3s 窗口）：

| 指标 | 加闸前 | 加闸后 |
|---|---|---|
| 假事件 | 39 个 | **0 个** |
| 实际推理窗口 | 240 (100%) | **90 (37.5%)** |
| 速度 | — | **4 ms/窗口** |

**事件合并**：相邻同标签窗口合并（间隔 ≤ merge_gap），过滤掉时长 < min_event 的碎片。

**鼾声指数**：`鼾声时长 / 分析时长 × 100%`，用于跨夜比较。

**⚠️ 诚实说明**：以上用的是**合成音频**（低频周期信号模拟鼾声），模型正确拒绝了它（鼾声概率 0.0035）。这证明链路正确、模型不轻易给鼾声标签，但**不能证明真实鼾声的检出率**——那需要真实鼾声录音。

---

## 二、本机环境

| 项 | 状态 |
|---|---|
| Python | 3.12.10；transformers 5.1.0、onnx 1.23.2、onnxscript 0.7.2、**onnxruntime 1.30.0**、onnxconverter-common |
| torch | 2.11.0 **CPU 版**（无 CUDA）。本方案不需要 GPU |
| Android | Android Studio（自带 **JBR 21**）、SDK 34/35/36.1、emulator、已有 `Pixel_Tablet` AVD |
| Flutter | ❌ 未安装（要用官方 3.47.6 stable zip 装） |
| 参考模板 | `C:\git-program\emotion-detect-android`（AGP 9.2.0 + Kotlin 2.2.10 + Gradle 9.4.1 + JDK 25，**本机验证可构建**，已集成 `onnxruntime-android`） |

**环境副作用**：升级 onnxruntime 到 1.30.0 时 pip 报 `magika` 要求 `onnxruntime<=1.20.1` 的冲突警告。magika 多半仍可用，出问题则是这次升级所致。

---

## 三、Flutter 技术栈

| 用途 | 选型 | 版本 |
|---|---|---|
| 后台录音 | `record` + `flutter_foreground_task` | 7.1.1 / 11.0.3 |
| 音频焦点 | `audio_session` | 0.2.4 |
| 端侧 ONNX | `flutter_onnxruntime`（masic.ai，内置 ORT 1.23.0，支持 x86_64 模拟器） | 1.8.5 |
| 图表 | `fl_chart`（柱/饼/折线）+ `graphic`（时间线甘特/热力图） | 1.2.0 / 2.7.0 |

**Android 14+ 后台录音硬性要求**：
- Manifest 声明 `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MICROPHONE` + `RECORD_AUDIO`（运行时申请）
- Service 声明 `android:foregroundServiceType="microphone"`
- 麦克风型前台服务**无超时限制**（超时只针对 dataSync/mediaProcessing）
- 不能在后台/开机广播里启动麦克风服务

**Flutter 官方 Claude Code 资源**（本机未装）：
- `flutter/agent-plugins` → `claude plugin marketplace add flutter/agent-plugins` 后装 `dart-flutter`，含 10 个 `flutter-*` skill
- Dart 官方 MCP server：`{"dart": {"command": "dart", "args": ["mcp-server"]}}`
- Anthropic 官方市场里**没有** Flutter/Dart 专用插件（只有通用的 `kotlin-lsp`、`feature-dev`、`frontend-design`）

---

## 四、架构

```
┌─ Flutter App ────────────────────────────────────────────┐
│  录音层   record + flutter_foreground_task (前台服务)     │
│           16kHz 单声道 PCM，滚动缓冲                       │
│             ↓                                            │
│  闸门 1   能量 VAD：RMS < 阈值 → 丢弃，不推理              │
│             ↓                                            │
│  推理层   flutter_onnxruntime → ced-tiny-int8.onnx       │
│           输入 float32[1, N] 任意长度 → 输出 [1, 527]     │
│             ↓                                            │
│  闸门 2   置信度：top1 < 阈值 → 判未识别，不产生事件        │
│             ↓                                            │
│  聚合层   527 → 7 大类求和 + 事件合并（去抖/最短时长）       │
│             ↓                                            │
│  存储     SQLite（会话表 + 事件表 + 事件音频片段路径）      │
│             ↓                                            │
│  展示     时间线 / 统计图表 / 事件回放                     │
└──────────────────────────────────────────────────────────┘
```

**整夜数据量**：8 小时 16kHz 单声道 16bit ≈ 920MB。**不能全存**。策略：
- VAD 命中才保留片段（实测命中率约 37%）
- 事件音频只留关键片段，带时间戳
- 原始 PCM 滚动丢弃

**整夜算力估算**：8 小时 = 9600 个 3s 窗口 → VAD 后约 3600 次推理。PC 端 30ms/次，手机按 3 倍慢算约 90ms → 合计约 **5.4 分钟**。完全可接受（原 AST 方案是 20–40 分钟）。

---

## 五、剩余实施阶段

### 阶段 2 已完成：Flutter 工程 + 端侧推理打通 ✅

代码在 `app/`，工程结构按 Flutter 官方 `flutter-apply-architecture-best-practices` skill 分层：

```
app/lib/
├── domain/            领域层（不依赖任何框架）
│   ├── models/        sleep_category.dart, sleep_prediction.dart
│   └── repositories/  sleep_analyzer.dart（抽象契约）
├── data/              数据层
│   ├── models/        sleep_class_map.dart（527→7 映射表）
│   ├── services/      onnx_classifier_service.dart, wav_decoder_service.dart,
│   │                  diagnostic_fixtures.dart
│   └── repositories/  sleep_analysis_repository.dart
└── ui/features/diagnostic/
    ├── view_models/   diagnostic_view_model.dart（ChangeNotifier）
    └── views/         diagnostic_view.dart
```

**验收结果**：

| 验证项 | 结果 |
|---|---|
| `flutter analyze` | 干净（仅 4 条 info 级样式提示） |
| 单元 + widget 测试 | **21 个全过** |
| **integration test（Windows 真机）** | **5 个全过** |
| ├ 模型加载 | ✅ |
| ├ 输出 527 维 | ✅ |
| ├ **与 PC 端逐元素一致（容差 1e-3）** | ✅ **核心验收项** |
| ├ 重复推理稳定性 | ✅ |
| └ 动态长度输入（0.5s/1s/5s） | ✅ |

**环境补齐**（阶段 2 期间安装）：
- Flutter 3.47.6 → `C:\Users\13963\flutter`（已加用户级 PATH）
- `flutter config --jdk-dir` → Android Studio JBR 21
- Android **cmdline-tools 16111833**（sha1 校验通过）
- Android **NDK 28.2.13676358**（Flutter 模板默认要求）
- Flutter 官方插件 `dart-flutter@dart-flutter` v1.0.6（25 个 skill）

**踩坑记录**（都已在代码注释里）：
- `flutter_onnxruntime` 的 `OrtValue.asList()` 返回**按 shape 嵌套**的结构，取 [1,527] 输出要逐个剥；必须用 `asFlattenedList()`
- Flutter 测试的 **FakeAsync 时区不推进真实 I/O**：ViewModel 里 `await rootBundle.loadString` 会让 `pumpAndSettle` 永不收敛。修法是把夹具读取抽成 `DiagnosticFixtures` 抽象注入，而不是在测试里绕
- ViewModel 直接依赖具体 Repository 会导致无法注入假实现 → 抽出 `SleepAnalyzer` 接口

**下一步（阶段 3）**：整夜录音。接入 `record` + `flutter_foreground_task`，实现能量 VAD + 滚动缓冲，SQLite 存会话与事件。

**当前 APK 只有诊断页**——还没有录音功能，装到手机上只能看到模型加载与推理验证界面。

**APK 体积实测**：

| 构建 | 体积 | 说明 |
|---|---|---|
| debug（全 ABI） | 233 MB | 含调试符号 + 3 份 ABI 原生库 |
| **release arm64-v8a** | **48.3 MB** | 现代真机用这个 |
| release armeabi-v7a | 37.7 MB | 老设备 |
| release x86_64 | 55.3 MB | 模拟器 |

体积大头是 **ONNX Runtime 原生库（约 30MB/ABI）**，模型本身只占 6.3MB。若要进一步瘦身，可考虑换成 LiteRT/TFLite 或做 ABI 拆分的 App Bundle。

**遗留小问题**：`assets/testdata/`（4 个 wav + expected.json，约 0.7MB）是诊断用的测试夹具，目前也会打进 release 包。体积可忽略，且让 App 能在真机上自检，暂留。若要去掉，只需从 `pubspec.yaml` 的 assets 里移除并删掉诊断页。

### 阶段 3 已完成：整夜录音（真机行为待验）

代码在 `app/lib/`，**113 个单元/widget 测试全过**，`flutter analyze` 干净。但必须说清楚：**这些验证都在 PC 上，真机行为完全未知**。

**新增的算法层**（`domain/analysis/`，纯 Dart 无插件依赖，因此可完整测试）：
| 文件 | 职责 |
|---|---|
| `analysis_config.dart` | 参数集中管理，默认值与 PC 端 `ml/infer.py` 一致 |
| `energy_vad.dart` | PCM16→float 转换 + RMS 能量门控 |
| `pcm_window_buffer.dart` | 把不定长 PCM 流切成定长窗口，尾部残料也分析 |
| `event_accumulator.dart` | 事件合并 + 统计累积（与 `ml/infer.py` 规则一致） |
| `night_analysis_engine.dart` | 串起缓冲 → 门控 → 推理 → 累积 |

**新增的数据层**：
- `audio_capture_service.dart` — 包 `record`，16kHz 单声道 PCM16
- `session_database.dart` — sqflite 存会话与事件（**不存原始音频**，8 小时约 920MB）
- `foreground_service_controller.dart` — 包 `flutter_foreground_task`，麦克风型前台服务
- `recording_repository.dart` — 编排层
- `recording_repository` 里有一条**串行化闸门**：PCM 块持续到达而推理是异步的，若两次处理重叠窗口会乱序。用 Future 链保证顺序，并记录 `maxBacklog` 以便发现设备跑不动的情况。

**Android 配置**（`AndroidManifest.xml`）：
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
<service android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
         android:foregroundServiceType="microphone" android:exported="false" />
```

**界面**：录音页（开始/停止、计时、实时统计含推理比例、历史记录列表与删除）+ 诊断页（验证端侧推理）。

### ⚠️ 阶段 3 尚未验证的部分

| 未验证项 | 为什么重要 |
|---|---|
| **前台服务能否整夜保活** | 核心功能。国产 ROM 清理后台是已知风险，必须真机测 |
| **端侧推理在手机上多快** | PC 端 30ms/窗口，手机可能慢数倍。若跟不上采集速度，`maxBacklog` 会持续增长 |
| **整夜耗电** | 麦克风 + 持续推理，用户能否接受 |
| **真实鼾声检出率** | 依然只用合成音频验证过链路，没验证过准确性 |
| **VAD 阈值是否合适** | `vadRms=0.01` 直接搬自 PC 端合成音频实验，真实卧室底噪可能不同 |

**模拟器已解决**：换成 `google_apis` 镜像（无 Play Store）+ `pixel_5` 档案 + 720×1560 分辨率，启动从「几分钟无响应」降到 **52 秒**，`adb shell` 从超时降到 0.1 秒。integration test 在其上全过。

### 阶段 4 已完成：可视化分析 ✅

界面按蜗牛睡眠的风格重做，**但只用我们真实算得出来的指标**——没有睡眠分期（需要加速度计/PPG），就不编造「睡眠得分」。

**新增的图表**（`lib/ui/core/widgets/charts.dart` + `lib/domain/analysis/session_insights.dart`）：

| 图表 | 回答的问题 | 形式 |
|---|---|---|
| 整夜声音时间线 | 什么时候发生了什么 | 密集柱状，3 色分类 + 柱高区分细类 |
| 每小时分布 | 我几点打鼾最多 | 堆叠柱（鼾声贴基线，其他声音摞上方） |
| 鼾声段时长 | 一次持续多久 | 6 档直方图，单色 |
| 跨晚趋势 | 我在变好吗 | 折线 + 本人平均值参考线 |
| 类别分布 | 各类声音占多少 | 排序水平条，逐行直接标注 |
| 端侧分析 | 为什么整夜录音不费电 | 指标块 + 推理占比条 |

**配色是算出来的，不是挑出来的：**

先用直觉挑了 7 个类别色，跑 dataviz skill 的验证器**五项检查全部不通过**——
红绿色盲下「体动(绿)↔人声(黄)」ΔE 仅 **5.5**，正常视力下「人声(黄)↔咳嗽(橙)」ΔE **14.8**。

关键约束：声音时间线上任意两类都可能相邻，适用**全配对**判据。逐步测试发现
**全配对下最多只能有 3 个颜色**（第 4 色即掉到 ΔE 4.8，而 skill 规定这种 hard fail
不能用辅助编码豁免）。蜗牛睡眠自己的时间线也只用 3 色，是同一个约束逼出来的。

最终：**3 色大类 + 柱高作为第二编码通道**。精确类别由事件列表和点按查看给出。

配色验证命令（换主题色后必须重跑）：
```bash
node <dataviz-skill>/scripts/validate_palette.js \
  "#d95926,#3987e5,#199e70" --mode dark --surface "#161D38" --pairs all
```

**测试**：153 个单元/widget 测试全过，`flutter analyze` 干净。

**尚未做**：~~事件音频回放~~ → 已完成，见下。

---

## ⚠️ 重大更正：识别功能此前从未真正工作过（2026-10-06）

由「能不能用系统麦克风模拟」这个问题追查出来，是本项目最重要的一次纠错。

### 两个叠加的错误

**1. 模型来源错了。** 一直用「HF transformers + trust_remote_code → 自己导出 ONNX」这条路，
而**它产出的是垃圾**（公鸡→Music 0.815，真实鼾声→Speech 0.812），
怀疑是 transformers 5.1.0 与 CED 那份为 4.x 写的 remote code 不兼容。

同一个仓库里自带的 `model.onnx` 才是好的：吃原始波形，输出正确。

**2. 后处理错了。** 对模型输出做了 **softmax**，但 AudioSet 是**多标签**数据集，
输出**已经是各类别的 sigmoid 概率**。softmax 除以 527 个值的大和，把 `Snoring=0.96`
压成 `0.004` —— 置信度门控（当时是 0.15）因此**永远过不了**，事件永远是 0。

### 为什么一直没发现

当时的验证方式是 **ONNX 输出 vs PyTorch 输出，余弦相似度 1.000000**，还在诊断页做了个绿色对勾。
但那两个**是同一个坏模型**——一致性验证只能证明"迁移没引入偏差"，
**证明不了模型本身可用**。这个绿灯把我自己骗了很久。

### 修正后的实测结果

用 ESC-50 的**真实鼾声**样本（CC BY-NC）验证：

| | 修正前 | 修正后 |
|---|---|---|
| 6 段真实鼾声 | 全部输出接近均匀（0.003） | **5 段 top-1 = Snoring（0.74–0.96）** |
| 6 个对照声音 | 全部接近均匀 | **Snoring 全是 0.000**（零误报） |
| 纯音 440Hz | 均匀噪声 | **Sine wave 0.947** |
| 端侧（Android 真机） | — | **7/7 通过**（`integration_test/real_audio_detection_test.dart`） |

### 顺带发现并修掉的两个问题

- **采样率没校验**。`WavDecoderService` 保留文件原始采样率，而 `classifySamples` 直接当 16kHz 喂。
  App 自己的录音固定 16kHz 所以没暴露，但外部音频进去会时间轴错 2.75 倍。
  现在非 16kHz 直接明确拒绝。
- **上游模型在 17 万~25 万采样点会崩**（形状广播失败，实测）。现在输入钳到 10 秒上限。

### 留下的教训

一致性验证不能替代**带已知答案的真实样本对照**。
以后任何模型/管线改动，都要跑一遍 `integration_test/real_audio_detection_test.dart`。


### 事件音频回放 ✅

**核心难点是"回溯确认"**：一个鼾声段要连续 6 秒同类才算成立，等确认时那段音频早就流过去了。
所以必须维护一个**环形缓冲**（默认 60 秒），事件定案时回头把片段切出来。

新增组件：
| 文件 | 职责 |
|---|---|
| `domain/analysis/pcm_ring_buffer.dart` | 定长环形缓冲，按**绝对采样序号**取片段 |
| `data/services/wav_encoder.dart` | 浮点采样点 → 16-bit 单声道 WAV |
| `data/services/file_audio_clip_store.dart` | 片段落盘/解析/删除，存应用私有目录 |
| `data/services/event_player.dart` | `just_audio` 封装 |

**几个关键决策**：

1. **只留鼾声。** 梦话和咳嗽的隐私含义与鼾声不同，先不做。
2. **从事件末尾往前切**，不是从起点。超长鼾声段（连续几分钟）从头切的话音频早被缓冲挤掉了；
   从末尾推既保证在缓冲里，取的又是最靠近确认时刻、最典型的一段。
3. **起点取不到就整段放弃，终点取不到就少听半秒。** 缺开头会让片段从声音正中开始（误导），
   缺结尾只是短一点（可接受）。事件往往在最后一段音频结束时定案，尾部余量天然不存在。
4. **存相对路径**，不存绝对路径——应用沙盒目录在重装或系统迁移后会变。
5. **删会话时先删文件再删数据库行**。反过来的话记录没了就再也定位不到那次片段目录，文件永久残留。
6. **开关可运行时切换**，默认开着（否则这功能等于不存在），但界面上显眼可关。

**存储实测**：16 段鼾声（鼾声指数 5.94% 的一晚）共 **10MB**。鼾声重的夜晚会更多。

**数据库迁移 v1 → v2**：`events` 加 `clip_path`，新建 `settings` 表。老用户的库平滑升级，
老记录保留为"无片段"。迁移有独立测试覆盖（构造 v1 库 → 用新代码打开 → 校验数据不丢）。

**踩过的坑**：

- **环形缓冲的"批量写入"分支是错的**。当初为了省开销，给"块比容量还长"加了个只留末尾的
  快捷路径，但它按 0 起放下标，破坏了"绝对序号 n 落在 n % capacity"这个对应关系，
  环绕后的切片整体错位。删掉该分支用通用循环即可——省下的开销不值得冒险。
- **`just_audio` 的 `play()` 返回的 Future 要等播放结束才 resolve**，不是一调用就返回。
  `await` 它会让"正在播放"这个状态在整个片段期间都设不上，界面一直转圈。
  这个 bug 是靠**看模拟器截图**发现的——单测没抓到，因为假播放器当时是立刻返回的。
  修完顺手把假播放器改成同样阻塞，并补了防回归的断言。

**测试**：212 个单元/widget 测试全过，`flutter analyze` 干净。

---

- 整夜声音时间线（按类别着色）
- 鼾声指数趋势、每小时事件直方图、类别分布饼图
- 事件列表 + 点击回放该片段
- **验收**：用真实录制的数据出一份完整报告页

---

## 六、目录结构

```
sleep-secret/
├── ml/                          # Python 模型管线（阶段 1 已完成）
│   ├── export_ced.py            # CED-tiny → ONNX（含特征提取），带逐位校验
│   ├── sleep_classes.py         # 527 → 7 大类映射生成
│   ├── infer.py                 # 参考推理 + 事件分析（Flutter 端照此实现）
│   └── verify_ced.py            # 上游 ONNX 对比（结论：不可用）
├── models/                      # 交付产物
│   ├── ced-tiny-int8.onnx       # 6.3MB ← App 用这个
│   ├── ced-tiny-clean.onnx      # 23MB FP32 参考
│   └── sleep_class_map.json
├── spike/                       # AST 阶段的验证记录（保留备查）
└── PLAN.md
```

---

## 七、风险

| 风险 | 影响 | 缓解 / 验证 |
|---|---|---|
| ~~端侧推理延迟~~ | ~~整夜分析数十分钟~~ | **已消除**：CED-tiny 30ms/窗口，估整夜约 5 分钟 |
| **真实鼾声检出率未知** | 核心功能效果不确定 | 只能用合成音频验证链路（已验证）。**需要你录几晚真实音频做人工核对** |
| ~~AST 未针对鼾声微调~~ | — | 同样适用于 CED；不达标再考虑微调（当前不做） |
| VAD 阈值需实调 | 漏检轻声鼾 vs 误报底噪 | `ml/infer.py` 的 `vad_rms`、`min_confidence` 是参数；用真实录音调 |
| 国产 ROM 杀后台 | 整夜录音中断 | 引导用户加电池白名单/自启动；阶段 3 长时实测 |
| Flutter + JDK 25 | 官方未验证该组合 | 用 `flutter config --jdk-dir` 指向 JBR 21 |
| 模拟器麦克风 | 重启后设置失效 | `emulator -allow-host-audio`；关键测试靠真机 |

---

## 八、需要你提供的

1. **安卓真机** — 阶段 3 之后的保活与性能验证必须真机
2. **真实鼾声录音**（哪怕就几晚）— 用来核对检出率、调 VAD 和置信度阈值。这是目前最大的未知数

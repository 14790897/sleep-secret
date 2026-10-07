/// 整夜分析的参数。
///
/// 默认值与 PC 端参考实现 `ml/infer.py` 的 `analyze_session` 保持一致，
/// 这样两端的行为可以互相印证。用真实录音核对检出率时，主要调
/// [vadRms] 这个门限和 [lowConfidenceThreshold] 这条参考线。
///
/// ⚠️ **「一致」不等于「处处一样」**：`ml/infer.py` 顶上那张表列着两处
/// 有意为之的差异（能量门控阈值它不随房间自适应、高危信号事件它不建模）。
/// 除此之外不一致就是 bug。
///
/// ⚠️ 而且**一致性只能证明两边一样，不能证明两边对**：这个项目栽过一次，
/// 两端**都**对 sigmoid 输出做了 softmax，「两端逐元素一致」双双通过，
/// 把 Snoring=0.96 压成了 0.004。第二实现的价值在于有人会去问「这个数对吗」，
/// 不在于它能对上。
library;

import '../models/sound_event.dart';

class AnalysisConfig {
  const AnalysisConfig({
    this.sampleRate = 16000,
    this.windowSeconds = 3.0,
    this.hopSeconds = 3.0,
    this.vadEnabled = false,
    this.vadRms = 0.01,
    this.vadAdaptive = true,
    this.vadNoisePercentile = 0.2,
    this.vadNoiseMultiplier = 3.0,
    this.vadHistoryWindows = 400,
    this.vadMinSamples = 60,
    this.lowConfidenceThreshold = 0.25,
    this.minEventSeconds = 6.0,
    this.mergeGapSeconds = 9.0,
    this.recordClips = true,
    this.clipPaddingSeconds = 1.0,
    this.maxClipSeconds = 20.0,
    this.clipBufferSeconds = 60.0,
  });

  /// 采样率。与 CED-tiny 要求的 16kHz 一致。
  final int sampleRate;

  /// 每次推理的窗口长度（秒）。
  final double windowSeconds;

  /// 窗口滑动步长（秒）。等于 [windowSeconds] 即不重叠。
  final double hopSeconds;

  /// 能量门控（VAD）是否启用。**默认关闭。**
  ///
  /// ## 为什么默认关
  ///
  /// 它做的事只有一件：**跳过安静段，不做推理**（省算力）。实测它并没有在
  /// 挡住误报——关掉之后雨声、公鸡叫、白噪声照样 0 个鼾声段，那些是模型
  /// 自己在做。它唯一可观察到的行为差异是「纯静音素材从 0 个事件变成
  /// 1 个环境噪音事件」，而那是个**呈现**问题，不是判定问题。
  ///
  /// 也就是说：一道阈值 + 一套自适应估计 + 上下界 + 测试，换来的只是算力，
  /// 而算力账是「整夜 8 小时里省约 11 分钟 CPU」。复杂度不划算。
  ///
  /// ## 但为什么没有直接删掉
  ///
  /// 那个算力账是**按 PC 速度估算的**，手机上慢多少没有实测过。
  ///
  /// **2026-10-07 夜量到了**：Redmi K80 上息屏整夜录 6.5 小时、耗电 9%
  /// （默认设置，也就是这个开关关着）。十小时约 14%——**不改也活得下来**。
  ///
  /// ⚠️ 但那个数**答不了这个问题**：9% 里混着麦克风、CPU 和息屏待机，
  /// 分不出推理占多少。所以「该开还是该删」**还是没到能决定的时候**。
  ///
  /// 要决定它，缺的是**推理耗时的占比**——不是整晚电量，是
  /// `windowsInferred / windowsTotal` 配上单次推理的毫秒数。
  ///
  /// ⚠️ **别让它一直是个永远为 false 的开关。** 这个项目最贵的几次教训
  /// 都是「代码路径从没被执行过」。要么用数据证明该开，要么删干净。
  ///
  /// ## 关掉会失去什么
  ///
  /// 1. 「整晚几乎没有触发分析 → 手机可能被挡住」这条诊断失效
  ///    （判据是跳过窗口数，没有 VAD 就恒为 0）
  /// 2. 录音页电平条上的识别门槛线没有意义了
  /// 3. 报告会变成整晚一条「环境噪音」事件（房间底噪被判成环境噪音 0.287）
  final bool vadEnabled;

  /// 能量门控阈值：窗口 RMS 低于它就判静音，**不做推理**。
  ///
  /// 只在 [vadEnabled] 为 true 时生效。
  ///
  /// ⚠️ [vadAdaptive] 打开时，这个值不再直接生效，而是变成自适应的**基准**：
  /// 实际阈值在 `vadRms/4` 到 `vadRms*2` 之间按房间的噪声底浮动。
  /// 它仍然是那个"我们相信的量级"，只是不再假设房间长什么样。
  final double vadRms;

  /// 能量门控阈值是否随房间的噪声底自适应。
  ///
  /// 关掉就退回固定阈值——出问题时可以一键还原到已验证的行为。
  final bool vadAdaptive;

  /// 拿哪个分位数当噪声底。见 [AdaptiveNoiseFloor] 里对分位数的讨论。
  final double vadNoisePercentile;

  /// 噪声底乘多少倍才算"有声音"。
  final double vadNoiseMultiplier;

  /// 用多少个窗口的 RMS 估计噪声底。3 秒窗口下 400 个约 20 分钟。
  final int vadHistoryWindows;

  /// 至少积累多少个窗口才开始自适应，不够时用 [vadRms]。
  ///
  /// 60 个窗口（3 秒窗口约 3 分钟）：太短会把刚躺下时的翻身、说话声
  /// 当成噪声底；太长则前半夜用的还是那个没根据的固定值。
  final int vadMinSamples;

  /// 自适应阈值的下界——最多比 [vadRms] 放宽 4 倍。
  ///
  /// 上下界的存在是为了限定这次改动的口径：**原来那个值可能不对，
  /// 但不会错到 4 倍以上**。没有边界的话，一个整晚打鼾的录音会把噪声底
  /// 估成鼾声电平，阈值被推到很高，越打鼾越检测不到——那种失效很难看出来。
  double get vadLowerBound => vadRms / 4;

  /// 自适应阈值的上界——最多比 [vadRms] 收紧 2 倍。
  double get vadUpperBound => vadRms * 2;

  /// 低于它就认为**把握不大**——仍然产生事件，只是界面上会标出来。
  ///
  /// ⚠️ 这**不是门槛**，曾经是：低于它就判「未识别」、不产生事件。
  /// 去掉了，因为实测它没在做它声称的事（见 [NightAnalysisEngine] 里那段说明）。
  ///
  /// 数值仍然留着当"把握不大"的参考线，但要清楚它原本是按**鼾声那一维**
  /// 标定的，而实际比的是**七大类得分的最大值**——标定的依据和用法对不上，
  /// 所以这个数本身也还没有可靠依据。拿真实整夜数据再定。
  ///
  /// ⚠️ 当初标定用的是 ESC-50 那批样本，**那批已经换掉了**（CC BY-NC，不能
  /// 留在仓库里，见 `scripts/fetch_test_audio.py`）。所以连"当时那几个数"
  /// 也没法复现了——更说明这条线该拿真实整夜数据重新定。
  final double lowConfidenceThreshold;

  /// 事件最短时长：短于此的碎片会被丢弃。
  ///
  /// ⚠️ 它和 [windowSeconds] 一起决定了**实际能检出的最短声音**。
  ///
  /// 窗口是固定栅格，一段声音占几个窗口取决于它落在栅格的什么位置。
  /// 实测：5 秒的真实鼾声，有时横跨两个窗口（合并成 6 秒事件，能留下），
  /// 有时只落在一个窗口里（3 秒，低于 6 秒被丢弃）——同样的声音，结果不同。
  ///
  /// 也就是说这条阈值不是精确的"6 秒"，而是"能对齐出 6 秒以上窗口的声音"。
  /// 真实鼾声通常持续几十秒，影响不大；但要清楚短促的打鼾可能被漏掉。
  final double minEventSeconds;

  /// 间隔小于此值的同类相邻窗口会合并成一个事件。
  final double mergeGapSeconds;

  // ---------------------------------------------------------------- 音频片段

  /// 这个事件会不会被保留到报告里。
  ///
  /// 高危信号（倒吸气、喷鼻息…）**豁免** [minEventSeconds]：一声倒吸气只有
  /// 一两秒，按普通事件走会被当碎片丢掉——而它恰恰是这份报告里最该留下的
  /// 东西，丢掉的同时连回放也没了。见 [SoundEvent.signal]。
  bool keepsEvent(SoundEvent e) =>
      e.isSignal || e.durationSeconds >= minEventSeconds;

  /// 是否为事件保存音频片段。
  ///
  /// 关掉之后 App 完全不落任何原始音频，只留事件的时间点和类别。
  /// 这一项在界面上给用户开关。
  final bool recordClips;

  /// 片段前后各留多少秒。
  ///
  /// 不留余量的话，片段会从声音正中开始、在正中结束，听起来很突兀，
  /// 也判断不出这段鼾声的起止。
  final double clipPaddingSeconds;

  /// 单个片段的最长秒数。超长鼾声段只截取最有代表性的一段，
  /// 否则一条 5 分钟的鼾声会写出一个几 MB 的文件。
  final double maxClipSeconds;

  /// 环形缓冲保留多少秒的音频。
  ///
  /// 必须 >= [maxClipSeconds] + 2 * [clipPaddingSeconds]，
  /// 否则切片段时会发现音频已经被覆盖。构造时会校验。
  final double clipBufferSeconds;

  /// 事件 [startSeconds, endSeconds] 对应的音频切片范围（秒）。
  ///
  /// 从**末尾往前推**而不是从起点开始切：超长事件（比如连续 5 分钟的鼾声）
  /// 从头切的话，那段音频早被环形缓冲挤掉了。从末尾推既保证一定在缓冲里，
  /// 取到的又是最靠近确认时刻、最有代表性的一段。
  ({double start, double end}) clipRangeFor(
    double startSeconds,
    double endSeconds,
  ) {
    final end = endSeconds + clipPaddingSeconds;
    final desiredStart = startSeconds - clipPaddingSeconds;
    final earliest = end - maxClipSeconds;
    final start = desiredStart > earliest ? desiredStart : earliest;
    return (start: start < 0 ? 0.0 : start, end: end);
  }

  /// 缓冲是否够放一个完整的最长片段。不够的话切片段时会被覆盖掉。
  bool get clipBufferIsAdequate =>
      clipBufferSeconds >= maxClipSeconds + 2 * clipPaddingSeconds;

  int get windowSamples => (windowSeconds * sampleRate).round();
  int get hopSamples => (hopSeconds * sampleRate).round();
  int get clipBufferSamples => (clipBufferSeconds * sampleRate).round();

  AnalysisConfig copyWith({
    bool? vadEnabled,
    double? vadRms,
    bool? vadAdaptive,
    double? vadNoisePercentile,
    double? vadNoiseMultiplier,
    int? vadHistoryWindows,
    int? vadMinSamples,
    double? lowConfidenceThreshold,
    double? minEventSeconds,
    double? mergeGapSeconds,
    bool? recordClips,
  }) =>
      AnalysisConfig(
        sampleRate: sampleRate,
        windowSeconds: windowSeconds,
        hopSeconds: hopSeconds,
        vadEnabled: vadEnabled ?? this.vadEnabled,
        vadRms: vadRms ?? this.vadRms,
        vadAdaptive: vadAdaptive ?? this.vadAdaptive,
        vadNoisePercentile: vadNoisePercentile ?? this.vadNoisePercentile,
        vadNoiseMultiplier: vadNoiseMultiplier ?? this.vadNoiseMultiplier,
        vadHistoryWindows: vadHistoryWindows ?? this.vadHistoryWindows,
        vadMinSamples: vadMinSamples ?? this.vadMinSamples,
        lowConfidenceThreshold:
            lowConfidenceThreshold ?? this.lowConfidenceThreshold,
        minEventSeconds: minEventSeconds ?? this.minEventSeconds,
        mergeGapSeconds: mergeGapSeconds ?? this.mergeGapSeconds,
        recordClips: recordClips ?? this.recordClips,
        clipPaddingSeconds: clipPaddingSeconds,
        maxClipSeconds: maxClipSeconds,
        clipBufferSeconds: clipBufferSeconds,
      );
}

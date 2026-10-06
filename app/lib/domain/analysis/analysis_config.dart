/// 整夜分析的参数。
///
/// 默认值与 PC 端参考实现 `ml/infer.py` 的 `analyze_session` 保持一致，
/// 这样两端的行为可以互相印证。用真实录音核对检出率时，主要调
/// [vadRms] 和 [minConfidence] 这两个门限。
class AnalysisConfig {
  const AnalysisConfig({
    this.sampleRate = 16000,
    this.windowSeconds = 3.0,
    this.hopSeconds = 3.0,
    this.vadRms = 0.01,
    this.minConfidence = 0.25,
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

  /// 能量门控阈值：窗口 RMS 低于它就判静音，**不做推理**。
  ///
  /// 这是省算力的关键——实测能跳过约 60% 的窗口。
  final double vadRms;

  /// 置信度门控：主导大类的得分低于它就判「未识别」，不产生事件。
  ///
  /// 没有这道闸，底噪会被强行归类——模型总要有输出，必有某个类"最高"。
  ///
  /// 0.25 是按**真实鼾声样本**校准的：6 段 ESC-50 真实鼾声里
  /// 5 段的 Snoring 得分在 0.74–0.96，第 6 段是 0.22（勉强算近失）；
  /// 6 个对照声音（钟声/拍手/狗叫/雨/公鸡/婴儿哭）的 Snoring 全是 0.000。
  /// 真实整夜录音的底噪分布可能不同，上线后应按实际数据再调。
  final double minConfidence;

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
    double? vadRms,
    double? minConfidence,
    double? minEventSeconds,
    double? mergeGapSeconds,
    bool? recordClips,
  }) =>
      AnalysisConfig(
        sampleRate: sampleRate,
        windowSeconds: windowSeconds,
        hopSeconds: hopSeconds,
        vadRms: vadRms ?? this.vadRms,
        minConfidence: minConfidence ?? this.minConfidence,
        minEventSeconds: minEventSeconds ?? this.minEventSeconds,
        mergeGapSeconds: mergeGapSeconds ?? this.mergeGapSeconds,
        recordClips: recordClips ?? this.recordClips,
        clipPaddingSeconds: clipPaddingSeconds,
        maxClipSeconds: maxClipSeconds,
        clipBufferSeconds: clipBufferSeconds,
      );
}

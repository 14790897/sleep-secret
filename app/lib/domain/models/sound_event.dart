import 'sleep_category.dart';

/// 一次检出的声音事件。
///
/// 由若干相邻的同类窗口合并而成，是 UI 时间线上的基本单元，
/// 也是「回放这段声音」的锚点。
class SoundEvent {
  const SoundEvent({
    required this.label,
    required this.startSeconds,
    required this.durationSeconds,
    required this.confidence,
    required this.snoreProbability,
    required this.windowCount,
    this.clipPath,
    this.peakRms,
  });

  final SleepCategory label;
  final double startSeconds;
  final double durationSeconds;

  /// 合并的各窗口中最高的一次置信度。
  final double confidence;

  /// 合并的各窗口中最高的一次鼾声概率。
  ///
  /// 即使 [label] 不是鼾声也可能非零——用于观察「疑似打鼾」。
  final double snoreProbability;

  /// 合并了多少个分析窗口。窗口多说明事件持续得久。
  final int windowCount;

  /// 该事件音频片段的**相对路径**，没有留片段时为 null。
  ///
  /// 存相对路径而不是绝对路径：应用沙盒目录在重装或系统迁移后会变，
  /// 存绝对路径的话历史记录里的片段会全部指向不存在的文件。
  final String? clipPath;

  /// 这个事件里**最响的那一个窗口**的 RMS。
  ///
  /// ## 为什么存 RMS 而不是分贝
  ///
  /// 分贝要挑一个参考值，而那个参考值是个**假设**——
  /// 见 `domain/analysis/decibel.dart` 里对 `kFullScaleDbSpl` 的说明。
  /// 假设将来可能改（换设备、或者用户自己校准过），
  /// **存原始量的话改参考值不用动数据库，也不用重算历史**。
  ///
  /// 老数据没有这一项（null）——那时候的引擎不记电平。
  final double? peakRms;

  /// 有没有电平数据。老记录没有，界面上要能区分「没记」和「很安静」。
  bool get hasLevel => peakRms != null;

  double get endSeconds => startSeconds + durationSeconds;

  bool get isSnore => label == SleepCategory.snore;

  bool get hasClip => clipPath != null && clipPath!.isNotEmpty;

  /// 补上片段路径。片段是在事件定案后才写盘的，所以事件本身先于片段存在。
  SoundEvent withClip(String? path) => SoundEvent(
        label: label,
        startSeconds: startSeconds,
        durationSeconds: durationSeconds,
        confidence: confidence,
        snoreProbability: snoreProbability,
        windowCount: windowCount,
        clipPath: path,
        peakRms: peakRms,
      );

  SoundEvent mergedWith(SoundEvent other) {
    assert(label == other.label, '只能合并同类事件');
    final start = startSeconds < other.startSeconds ? startSeconds : other.startSeconds;
    final end = endSeconds > other.endSeconds ? endSeconds : other.endSeconds;
    return SoundEvent(
      label: label,
      startSeconds: start,
      durationSeconds: end - start,
      confidence: confidence > other.confidence ? confidence : other.confidence,
      snoreProbability: snoreProbability > other.snoreProbability
          ? snoreProbability
          : other.snoreProbability,
      windowCount: windowCount + other.windowCount,
      // 合并保留已有的片段路径；通常此处两个都还没有（片段要等定案才写）。
      clipPath: clipPath ?? other.clipPath,
      // 峰值取大的。两边都可能是 null（老数据），这时仍然是 null——
      // 不能拿 0 当"没有"，那会在界面上显示成静音。
      peakRms: _maxOrNull(peakRms, other.peakRms),
    );
  }

  /// 取两者中较大的，**null 表示没有数据**，不参与比较。
  static double? _maxOrNull(double? a, double? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }

  @override
  String toString() => 'SoundEvent(${label.name} @${startSeconds.toStringAsFixed(1)}s '
      '${durationSeconds.toStringAsFixed(1)}s conf=${confidence.toStringAsFixed(3)})';
}

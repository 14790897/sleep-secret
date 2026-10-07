import 'sleep_category.dart';
import 'sound_event.dart';

/// 一次分析的汇总统计。字段与 PC 端 `ml/infer.py` 的 stats 一一对应。
class SessionStats {
  const SessionStats({
    required this.analyzedSeconds,
    required this.windowsTotal,
    required this.windowsInferred,
    required this.windowsVadSkipped,
    required this.windowsLowConfidence,
    required this.eventCount,
    required this.snoreEventCount,
    required this.snoreSeconds,
    required this.categoryDistribution,
    this.signalsCollected = false,
    this.rawLabelCounts = const {},
  });

  const SessionStats.empty()
      : analyzedSeconds = 0,
        windowsTotal = 0,
        windowsInferred = 0,
        windowsVadSkipped = 0,
        windowsLowConfidence = 0,
        eventCount = 0,
        snoreEventCount = 0,
        snoreSeconds = 0,
        categoryDistribution = const {},
        signalsCollected = false,
        rawLabelCounts = const {};

  /// 已分析的音频总时长。
  final double analyzedSeconds;

  final int windowsTotal;

  /// 实际送进模型的窗口数。
  final int windowsInferred;

  /// 被能量门控跳过（判为静音）的窗口数。
  final int windowsVadSkipped;

  /// 送进模型但置信度不足、未产生事件的窗口数。
  final int windowsLowConfidence;

  final int eventCount;
  final int snoreEventCount;
  final double snoreSeconds;

  /// 平均类别分布（仅统计实际推理的窗口）。
  final Map<SleepCategory, double> categoryDistribution;

  /// 这次分析有没有收集**高危信号**（见 `domain/analysis/apnea_signals.dart`）。
  ///
  /// 新录音恒为 true——引擎一直在收。它存在的唯一理由是**老记录读回来是
  /// false**：那时的事件里 `signal` 全是 null，而「没数据」和「一个都没认出来」
  /// 在界面上必须分得开，否则用户会拿一份空数据的旧报告当作「我一切正常」。
  final bool signalsCollected;

  /// 整夜里每个 **AudioSet 原始标签**当了多少次窗口的冠军。
  ///
  /// ## 为什么按整夜计数，不记在事件上
  ///
  /// 大类会把原始标签盖掉：`Gasp`（倒吸气）归在「呼吸」里，而同类相邻窗口
  /// **会合并成一个事件**——一夜的呼吸常常就是一个大事件，中间那几次倒吸气
  /// 在事件层面根本不存在。要核查「模型到底点过哪些名、各多少次」，
  /// 只能按窗口计。
  ///
  /// ## 键是标签名（英文），不是索引
  ///
  /// 和 `events.label` 存枚举名同一个道理：名字是 AudioSet 给出的标识，
  /// 换个模型重编索引不会让历史数据读错。而且 527 个标签里我们只映射了 47 个，
  /// **剩下 480 个没有中文名**——原样显示英文反而是对的，那才是模型说的话。
  ///
  /// 老记录没有这一项（空表）——那时候的引擎不收集它。
  final Map<String, int> rawLabelCounts;

  /// 某个 AudioSet 标签当冠军的次数。没出现过就是 0。
  int rawLabelCount(String label) => rawLabelCounts[label] ?? 0;

  /// 一共出现过多少种原始标签。
  int get rawLabelKindCount => rawLabelCounts.length;

  /// 实际推理比例。这个数直接决定耗电与耗时。
  double get inferenceRatio =>
      windowsTotal == 0 ? 0.0 : windowsInferred / windowsTotal;

  /// 鼾声指数 = 鼾声时长 / 分析时长 × 100%，用于跨夜比较。
  double get snoreIndex =>
      analyzedSeconds <= 0 ? 0.0 : snoreSeconds / analyzedSeconds * 100;

  SessionStats copyWith({
    double? analyzedSeconds,
    int? windowsTotal,
    int? windowsInferred,
    int? windowsVadSkipped,
    int? windowsLowConfidence,
    int? eventCount,
    int? snoreEventCount,
    double? snoreSeconds,
    Map<SleepCategory, double>? categoryDistribution,
    bool? signalsCollected,
    Map<String, int>? rawLabelCounts,
  }) =>
      SessionStats(
        analyzedSeconds: analyzedSeconds ?? this.analyzedSeconds,
        windowsTotal: windowsTotal ?? this.windowsTotal,
        windowsInferred: windowsInferred ?? this.windowsInferred,
        windowsVadSkipped: windowsVadSkipped ?? this.windowsVadSkipped,
        windowsLowConfidence: windowsLowConfidence ?? this.windowsLowConfidence,
        eventCount: eventCount ?? this.eventCount,
        snoreEventCount: snoreEventCount ?? this.snoreEventCount,
        snoreSeconds: snoreSeconds ?? this.snoreSeconds,
        categoryDistribution: categoryDistribution ?? this.categoryDistribution,
        signalsCollected: signalsCollected ?? this.signalsCollected,
        rawLabelCounts: rawLabelCounts ?? this.rawLabelCounts,
      );
}

/// 一整晚的录音会话。
class RecordingSession {
  const RecordingSession({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.events,
    required this.stats,
  });

  /// 会话 id。未落库前为 null。
  final int? id;

  final DateTime startedAt;
  final DateTime? endedAt;
  final List<SoundEvent> events;
  final SessionStats stats;

  Duration get duration => (endedAt ?? startedAt).difference(startedAt);

  bool get isFinished => endedAt != null;

  List<SoundEvent> get snoreEvents => events.where((e) => e.isSnore).toList();

  RecordingSession copyWith({
    int? id,
    DateTime? endedAt,
    List<SoundEvent>? events,
    SessionStats? stats,
  }) =>
      RecordingSession(
        id: id ?? this.id,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        events: events ?? this.events,
        stats: stats ?? this.stats,
      );
}

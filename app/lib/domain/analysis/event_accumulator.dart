import '../models/recording_session.dart';
import '../models/sleep_category.dart';
import '../models/sound_event.dart';
import 'analysis_config.dart';

/// 一个窗口经过两道闸门后的观察结果。
class WindowObservation {
  const WindowObservation({
    required this.startSeconds,
    required this.durationSeconds,
    required this.label,
    required this.confidence,
    required this.snoreProbability,
    required this.categories,
    required this.wasInferred,
  });

  final double startSeconds;
  final double durationSeconds;

  /// 该窗口的类别。null 只出现在被能量门控跳过的窗口上——
  /// 送进模型的窗口一定会有类别（不再按置信度丢弃）。
  final SleepCategory? label;

  final double confidence;
  final double snoreProbability;
  final Map<SleepCategory, double> categories;

  /// 是否真的送进了模型（false = 被能量门控跳过）。
  final bool wasInferred;

  double get endSeconds => startSeconds + durationSeconds;
}

/// 分析结果。
class AnalysisOutcome {
  const AnalysisOutcome({required this.events, required this.stats});

  final List<SoundEvent> events;
  final SessionStats stats;
}

/// 把逐窗口的观察结果累积成事件时间线和统计。
///
/// 纯同步、无插件依赖，可直接单测。事件合并规则与 PC 端
/// `ml/infer.py` 的 `analyze_session` 一致。
class EventAccumulator {
  EventAccumulator({this.config = const AnalysisConfig(), this.onEventClosed});

  final AnalysisConfig config;

  /// 事件**定案**时的回调（被下一个事件顶掉，或收尾时）。
  ///
  /// 定案才知道事件的最终起止，也才能去环形缓冲里切音频片段。
  /// 回调带下标，便于异步写完片段后回填路径。
  ///
  /// 可变：持有方（分析引擎）在构造之后才接得上，因为回调需要引用引擎自身。
  void Function(int index, SoundEvent event)? onEventClosed;

  final List<WindowObservation> _observations = [];
  final List<SoundEvent> _events = [];

  /// 已经通知过定案的事件下标。build() 可能被调用多次，
  /// 没有这个集合会把同一个事件重复报出去。
  final Set<int> _closed = {};

  int get windowCount => _observations.length;
  List<SoundEvent> get eventsSoFar => List.unmodifiable(_events);

  void add(WindowObservation obs) {
    _observations.add(obs);
    final label = obs.label;

    if (label == null) {
      // 没有分类结果的窗口（判为静音、或被能量门控跳过）自己不产生事件，
      // 但它**能结束**上一个事件。
      //
      // ⚠️ 这里原本是直接 return，不关事件。后果很隐蔽：
      // 一段鼾声后面接着安静时，那个鼾声事件会一直"开着"，
      // 直到下一个**有类别**的窗口到来才定案——可能是几分钟以后。
      // 而片段是从 60 秒的环形缓冲里回溯切的，定案时音频早被覆盖了，
      // 于是那段鼾声**没法回放**。
      //
      // 真实整夜数据上就是这样：9 段鼾声只有 3 段能播。
      // 补上这道检查之后，事件在安静超过 mergeGap 时立刻定案，
      // 音频还在缓冲里。
      _closeIfStale(obs.startSeconds);
      return;
    }

    // 与上一个事件同类、且间隔不超过 mergeGap 就并进去；否则新开一个。
    if (_events.isNotEmpty && _events.last.label == label) {
      final last = _events.last;
      if (obs.startSeconds - last.endSeconds <= config.mergeGapSeconds) {
        _events[_events.length - 1] = last.mergedWith(SoundEvent(
          label: label,
          startSeconds: obs.startSeconds,
          durationSeconds: obs.durationSeconds,
          confidence: obs.confidence,
          snoreProbability: obs.snoreProbability,
          windowCount: 1,
        ));
        return;
      }
    }

    // 能走到这里，说明上一个事件不会再长大了——它已经定案。
    _closeLast();

    _events.add(SoundEvent(
      label: label,
      startSeconds: obs.startSeconds,
      durationSeconds: obs.durationSeconds,
      confidence: obs.confidence,
      snoreProbability: obs.snoreProbability,
      windowCount: 1,
    ));
  }

  /// 距离上个事件已经超过 [AnalysisConfig.mergeGapSeconds] 没声音了，
  /// 那就把它定案——**越早定案，片段越可能还在环形缓冲里**。
  ///
  /// 阈值和合并用的是同一个：不超过它说明后面可能还有同类的窗口要并进来，
  /// 那就先不关。
  void _closeIfStale(double nextStartSeconds) {
    if (_events.isEmpty) return;
    if (nextStartSeconds - _events.last.endSeconds > config.mergeGapSeconds) {
      _closeLast();
    }
  }

  void _closeLast() {
    final index = _events.length - 1;
    if (index < 0 || _closed.contains(index)) return;
    _closed.add(index);
    onEventClosed?.call(index, _events[index]);
  }

  /// 片段写盘完成后回填路径。
  void attachClip(int index, String? path) {
    if (index < 0 || index >= _events.length) return;
    _events[index] = _events[index].withClip(path);
  }

  /// 收尾：丢弃过短碎片，算出统计。
  AnalysisOutcome build() {
    // 最后一个事件也要定案，否则它的片段不会被写出来。
    _closeLast();

    final kept = _events
        .where((e) => e.durationSeconds >= config.minEventSeconds)
        .toList(growable: false);

    final inferred =
        _observations.where((o) => o.wasInferred).toList(growable: false);
    final analyzed = _observations.fold<double>(
      0.0,
      (sum, o) => sum + o.durationSeconds,
    );

    final snoreEvents = kept.where((e) => e.isSnore);
    final snoreSeconds =
        snoreEvents.fold<double>(0.0, (sum, e) => sum + e.durationSeconds);

    // 类别分布只统计真正推理过的窗口——被 VAD 跳过的窗口压根没分类结果。
    final distribution = <SleepCategory, double>{};
    if (inferred.isNotEmpty) {
      for (final category in SleepCategory.values) {
        var sum = 0.0;
        for (final o in inferred) {
          sum += o.categories[category] ?? 0.0;
        }
        distribution[category] = sum / inferred.length;
      }
    }

    return AnalysisOutcome(
      events: kept,
      stats: SessionStats(
        analyzedSeconds: analyzed,
        windowsTotal: _observations.length,
        windowsInferred: inferred.length,
        windowsVadSkipped:
            _observations.where((o) => !o.wasInferred).length,
        // 含义变了：以前是「被判为未识别、不产生事件的窗口数」，
        // 现在是「把握不大的窗口数」——它们照常产生事件，只是会被标出来。
        // 这个名字在数据库列里已经固定，就没再改。
        windowsLowConfidence: inferred
            .where((o) => o.confidence < config.lowConfidenceThreshold)
            .length,
        eventCount: kept.length,
        snoreEventCount: snoreEvents.length,
        snoreSeconds: snoreSeconds,
        categoryDistribution: distribution,
      ),
    );
  }

  void reset() {
    _observations.clear();
    _events.clear();
    _closed.clear();
  }
}

import '../models/recording_session.dart';
import '../models/sleep_category.dart';
import '../models/sound_event.dart';

/// 按「鼾声展示门槛」筛出用于**显示**的会话（兼容旧调用）。
RecordingSession applySnoreThreshold(RecordingSession session, int percent) =>
    applyDisplayFilters(session, snorePercent: percent);

/// 按展示门槛筛出用于**显示**的会话。
///
/// - [snorePercent]：鼾声置信度低于它的不显示（用户撤销过的始终显示）；
/// - [ambientPercent]：环境噪音置信度低于它的不显示。
///
/// 只影响显示和派生的展示统计；录音、分析、导出都不经过这里。
/// 详情页和报告列表共用它：同一晚在两处必须是同一个数。
RecordingSession applyDisplayFilters(
  RecordingSession session, {
  int snorePercent = 0,
  int ambientPercent = 0,
}) {
  final hasUserLabels =
      session.events.any((e) => e.userLabel != null);
  // 没有门槛、也没用户标注：和以前一样原样返回，不重算统计。
  if (snorePercent <= 0 && ambientPercent <= 0 && !hasUserLabels) {
    return session;
  }

  final kept = [
    for (final e in session.events)
      if ((!e.isSnore ||
              e.isUserRejectedSnore ||
              snorePercent <= 0 ||
              e.confidence * 100 >= snorePercent) &&
          (e.label != SleepCategory.ambient ||
              ambientPercent <= 0 ||
              e.confidence * 100 >= ambientPercent))
        e,
  ];
  return session.copyWith(
    events: kept,
    stats: statsForEvents(session.stats, kept),
  );
}

/// 按事件重算**事件派生**的那几个统计。
///
/// 鼾声计数用 [SoundEvent.countsAsSnore]，用户标注「不是鼾声」的段会被排除。
/// 其余字段（窗口数、分析时长、低置信度窗口数、原始标签计数、类别均值）
/// 是**录音侧的事实**，不是从事件推出来的，一个都不能动——
/// 改了就是在编造"这一夜录到了什么"。
SessionStats statsForEvents(SessionStats stats, List<SoundEvent> events) {
  var snoreSeconds = 0.0;
  var snoreCount = 0;
  for (final event in events) {
    if (event.countsAsSnore) {
      // 用实际有声时长，不用含合并间隔的跨度——筛选后的统计和未筛时
      // 必须是同一个口径。
      snoreSeconds += event.activeSeconds;
      snoreCount++;
    }
  }
  return stats.copyWith(
    eventCount: events.length,
    snoreEventCount: snoreCount,
    snoreSeconds: snoreSeconds,
  );
}

import '../models/recording_session.dart';
import '../models/sound_event.dart';

/// 按「鼾声展示门槛」筛出用于**显示**的会话。
///
/// 只筛鼾声：别的类别不会因为这个门槛消失。门槛 <= 0 时保留全部事件，
/// 但仍会按用户标注重算统计（「这不是鼾声」的段不计入鼾声）。
///
/// 详情页和报告列表共用它：同一晚在两处必须是同一个数，否则用户会把
/// 两个数字当成 bug（原来列表读存库统计、详情重算，就对不上）。
RecordingSession applySnoreThreshold(RecordingSession session, int percent) {
  final hasUserLabels =
      session.events.any((e) => e.userLabel != null);
  // 没门槛、也没用户标注：和以前一样原样返回，不重算统计。
  // 用户标注过的会话必须重算，否则「不是鼾声」不计入评分这条不生效。
  if (percent <= 0 && !hasUserLabels) return session;

  final kept = [
    for (final e in session.events)
      // 用户撤销过的鼾声始终保留可见，门槛不再把它藏起来；
      // 它只是不再计入鼾声统计。
      if (!e.isSnore ||
          e.isUserRejectedSnore ||
          percent <= 0 ||
          e.confidence * 100 >= percent)
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

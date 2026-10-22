import '../models/recording_session.dart';
import '../models/sound_event.dart';

/// 按「鼾声展示门槛」筛出用于**显示**的会话。
///
/// 只筛鼾声：别的类别不会因为这个门槛消失。门槛 <= 0 时原样返回
/// （默认就是不筛）。录音、分析、导出都不经过这里——只影响界面。
///
/// 详情页和报告列表共用它：同一晚在两处必须是同一个数，否则用户会把
/// 两个数字当成 bug（原来列表读存库统计、详情重算，就对不上）。
RecordingSession applySnoreThreshold(RecordingSession session, int percent) {
  if (percent <= 0) return session;
  final kept = [
    for (final e in session.events)
      if (!e.isSnore || e.confidence * 100 >= percent) e,
  ];
  if (kept.length == session.events.length) return session;
  return session.copyWith(events: kept, stats: _statsFor(session.stats, kept));
}

/// 按筛后的事件重算**事件派生**的那几个统计。
///
/// 其余字段（窗口数、分析时长、低置信度窗口数、原始标签计数、类别均值）
/// 是**录音侧的事实**，不是从事件推出来的，一个都不能动——
/// 改了就是在编造"这一夜录到了什么"。
SessionStats _statsFor(SessionStats stats, List<SoundEvent> events) {
  var snoreSeconds = 0.0;
  var snoreCount = 0;
  for (final event in events) {
    if (event.isSnore) {
      snoreSeconds += event.durationSeconds;
      snoreCount++;
    }
  }
  return stats.copyWith(
    eventCount: events.length,
    snoreEventCount: snoreCount,
    snoreSeconds: snoreSeconds,
  );
}

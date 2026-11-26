import '../models/recording_session.dart';
import '../models/sound_event.dart';

/// 同一晚中间停止再开始的那段空档（醒来查看报告、去洗手间等）。
class SessionGap {
  const SessionGap({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);
}

/// 两段录音的间隔不超过这个值，就算同一晚（中间醒过）。
///
/// 2 小时是从实际使用场景取的：用户半夜醒来点「结束」看一眼报告、
/// 再点「开始」继续睡，中间通常只有几分钟。间隔太长（比如先睡一觉、
/// 晚上又睡一觉）应该算两晚，不能硬合并。
const Duration kMaxAwakeGap = Duration(hours: 2);

/// 「一晚」：一段或多段录音。
///
/// **只用于展示**。数据库里仍然是一段一条记录——录音的事实不该被合并掉；
/// 报告列表和报告页把它们按时间拼成一夜看。
class SleepNight {
  SleepNight(List<RecordingSession> segments)
      : assert(segments.isNotEmpty),
        segments = List.unmodifiable(segments);

  /// 按开始时间升序。
  final List<RecordingSession> segments;

  bool get isMerged => segments.length > 1;

  DateTime get startedAt => segments.first.startedAt;

  DateTime? get endedAt => segments.last.endedAt;

  List<int> get ids => [
        for (final s in segments)
          if (s.id != null) s.id!,
      ];

  /// 相邻两段之间的空档。
  List<SessionGap> get gaps => [
        for (var i = 1; i < segments.length; i++)
          SessionGap(
            start: segments[i - 1].endedAt ?? segments[i - 1].startedAt,
            end: segments[i].startedAt,
          ),
      ];

  /// 中间醒着的总时长。
  Duration get awakeDuration =>
      gaps.fold(Duration.zero, (sum, gap) => sum + gap.duration);

  RecordingSession? _merged;

  /// 拼成一晚之后的数据。片段在时间轴上自然留出空档。
  RecordingSession get merged => _merged ??= _merge();

  RecordingSession _merge() {
    if (segments.length == 1) return segments.single;

    // ⚠️ 事件时间**相对于各自那一段的开始**。合并后必须平移到整夜时间轴，
    // 否则第二段的事件会跑到夜里开头，时间线全错。
    final nightStart = startedAt;
    final events = [
      for (final segment in segments)
        for (final event in segment.events)
          _shift(
            event,
            segment.startedAt.difference(nightStart).inMilliseconds / 1000.0,
          ),
    ];

    var analyzed = 0.0;
    var windowsTotal = 0;
    var windowsInferred = 0;
    var windowsVadSkipped = 0;
    var windowsLowConfidence = 0;
    var signalsCollected = false;
    final rawLabelCounts = <String, int>{};

    for (final s in segments) {
      analyzed += s.stats.analyzedSeconds;
      windowsTotal += s.stats.windowsTotal;
      windowsInferred += s.stats.windowsInferred;
      windowsVadSkipped += s.stats.windowsVadSkipped;
      windowsLowConfidence += s.stats.windowsLowConfidence;
      signalsCollected = signalsCollected || s.stats.signalsCollected;
      s.stats.rawLabelCounts.forEach(
        (label, count) => rawLabelCounts[label] =
            (rawLabelCounts[label] ?? 0) + count,
      );
    }

    // 事件派生的统计以事件为准——和 SessionDatabase 读取时的口径一致。
    var snoreCount = 0;
    var snoreSeconds = 0.0;
    for (final event in events) {
      if (event.countsAsSnore) {
        snoreCount++;
        snoreSeconds += event.activeSeconds;
      }
    }

    return RecordingSession(
      id: segments.first.id,
      startedAt: startedAt,
      endedAt: endedAt,
      events: events,
      stats: SessionStats(
        analyzedSeconds: analyzed,
        windowsTotal: windowsTotal,
        windowsInferred: windowsInferred,
        windowsVadSkipped: windowsVadSkipped,
        windowsLowConfidence: windowsLowConfidence,
        eventCount: events.length,
        snoreEventCount: snoreCount,
        snoreSeconds: snoreSeconds,
        // 类别分布不落库，报告从事件现算；这里保持空表
        categoryDistribution: const {},
        signalsCollected: signalsCollected,
        rawLabelCounts: Map.unmodifiable(rawLabelCounts),
      ),
    );
  }
}

/// 把会话按夜合并。返回按开始时间升序的夜。
///
/// 规则：相邻两段录音的间隔 <= [kMaxAwakeGap] 就归为同一晚。
/// 时间上有重叠（异常数据）也归为同一晚。
List<SleepNight> groupSessionsIntoNights(
  List<RecordingSession> sessions, {
  Duration maxGap = kMaxAwakeGap,
}) {  final sorted = [...sessions]
    ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  final groups = <List<RecordingSession>>[];

  for (final session in sorted) {
    if (groups.isNotEmpty) {
      final previous = groups.last.last;
      final previousEnd = previous.endedAt ?? previous.startedAt;
      final gap = session.startedAt.difference(previousEnd);
      if (gap <= maxGap) {
        groups.last.add(session);
        continue;
      }
    }
    groups.add([session]);
  }

  return [for (final group in groups) SleepNight(group)];
}

/// 把事件的开始时间从「相对本段」平移到「相对整夜」。
SoundEvent _shift(SoundEvent event, double seconds) => SoundEvent(
      label: event.label,
      startSeconds: event.startSeconds + seconds,
      durationSeconds: event.durationSeconds,
      activeSeconds: event.activeSeconds,
      confidence: event.confidence,
      snoreProbability: event.snoreProbability,
      windowCount: event.windowCount,
      clipPath: event.clipPath,
      peakRms: event.peakRms,
      signal: event.signal,
    );

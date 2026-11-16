import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/night_grouping.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';

SoundEvent snore({
  required double start,
  double duration = 12,
  double? active,
  String? clip,
}) =>
    SoundEvent(
      label: SleepCategory.snore,
      startSeconds: start,
      durationSeconds: duration,
      activeSeconds: active,
      confidence: 0.9,
      snoreProbability: 0.9,
      windowCount: (duration / 3).round(),
      clipPath: clip,
    );

RecordingSession session({
  required int id,
  required DateTime start,
  required Duration duration,
  List<SoundEvent> events = const [],
  double analyzedSeconds = 0,
  Map<String, int> rawLabels = const {},
  bool signalsCollected = false,
}) {
  final snoreEvents = events.where((e) => e.isSnore);
  return RecordingSession(
    id: id,
    startedAt: start,
    endedAt: start.add(duration),
    events: events,
    stats: SessionStats(
      analyzedSeconds: analyzedSeconds,
      windowsTotal: (analyzedSeconds / 3).round(),
      windowsInferred: (analyzedSeconds / 3).round(),
      windowsVadSkipped: 0,
      windowsLowConfidence: 0,
      eventCount: events.length,
      snoreEventCount: snoreEvents.length,
      snoreSeconds:
          snoreEvents.fold<double>(0, (sum, e) => sum + e.activeSeconds),
      categoryDistribution: const {},
      signalsCollected: signalsCollected,
      rawLabelCounts: rawLabels,
    ),
  );
}

void main() {
  group('按夜合并', () {
    test('中间停止再开始（间隔 10 分钟）合并成一晚，并记下空档', () {
      final first = session(
        id: 1,
        start: DateTime(2026, 11, 12, 23),
        duration: const Duration(hours: 2),
      );
      final second = session(
        id: 2,
        start: DateTime(2026, 11, 13, 1, 10),
        duration: const Duration(hours: 6),
      );

      final nights = groupSessionsIntoNights([first, second]);

      expect(nights, hasLength(1));
      final night = nights.single;
      expect(night.isMerged, isTrue);
      expect(night.gaps, hasLength(1));
      expect(night.gaps.single.duration, const Duration(minutes: 10));
      expect(night.awakeDuration, const Duration(minutes: 10));
      expect(night.startedAt, first.startedAt);
      expect(night.endedAt, second.endedAt);
      expect(night.ids, [1, 2]);
    });

    test('间隔超过 2 小时分成两晚', () {
      final first = session(
        id: 1,
        start: DateTime(2026, 11, 12, 23),
        duration: const Duration(hours: 2),
      );
      final second = session(
        id: 2,
        start: DateTime(2026, 11, 13, 4),
        duration: const Duration(hours: 3),
      );

      final nights = groupSessionsIntoNights([first, second]);

      expect(nights, hasLength(2));
      expect(nights.every((n) => !n.isMerged), isTrue);
    });

    test('输入乱序也按时间排，返回的夜按升序', () {
      final late = session(
        id: 3,
        start: DateTime(2026, 11, 13, 23),
        duration: const Duration(hours: 7),
      );
      final early = session(
        id: 1,
        start: DateTime(2026, 11, 11, 23),
        duration: const Duration(hours: 7),
      );

      final nights = groupSessionsIntoNights([late, early]);

      expect(nights.map((n) => n.ids.single), [1, 3]);
    });

    test('时间重叠也算同一晚，不产生负的空档', () {
      final a = session(
        id: 1,
        start: DateTime(2026, 11, 12, 23),
        duration: const Duration(hours: 4),
      );
      final b = session(
        id: 2,
        start: DateTime(2026, 11, 13, 1),
        duration: const Duration(hours: 4),
      );

      final nights = groupSessionsIntoNights([a, b]);

      expect(nights, hasLength(1));
      expect(nights.single.gaps.single.duration.isNegative, isTrue);
    });
  });

  group('合并后的统计', () {
    test('分析时长、事件、鼾声都以各段为准，原始标签相加', () {
      final first = session(
        id: 1,
        start: DateTime(2026, 11, 12, 23),
        duration: const Duration(hours: 2),
        analyzedSeconds: 3600,
        events: [snore(start: 100, duration: 30, active: 30)],
        rawLabels: {'Snoring': 10, 'Breathing': 3},
      );
      final second = session(
        id: 2,
        start: DateTime(2026, 11, 13, 1, 10),
        duration: const Duration(hours: 6),
        analyzedSeconds: 1800,
        events: [snore(start: 50, duration: 60, active: 60)],
        rawLabels: {'Snoring': 5},
        signalsCollected: true,
      );

      final merged = SleepNight([first, second]).merged;

      expect(merged.stats.analyzedSeconds, 5400,
          reason: '中间醒着的 10 分钟不算分析时长');
      expect(merged.stats.windowsTotal, 1800);
      expect(merged.stats.eventCount, 2);
      expect(merged.stats.snoreEventCount, 2);
      expect(merged.stats.snoreSeconds, 90);
      expect(merged.stats.rawLabelCounts, {'Snoring': 15, 'Breathing': 3});
      expect(merged.stats.signalsCollected, isTrue);
      // 第二段从 01:10 开始（相对整夜 +2h10m = 7800s），事件在段内 50s，
      // 合并后应当是 7850s——不平移的话会跑到夜里开头。
      expect(merged.events.map((e) => e.startSeconds), [100, 7850]);
    });

    test('单段录音就是它自己，没有空档', () {
      final only = session(
        id: 1,
        start: DateTime(2026, 11, 12, 23),
        duration: const Duration(hours: 7),
      );

      final night = SleepNight([only]);

      expect(night.isMerged, isFalse);
      expect(night.gaps, isEmpty);
      expect(identical(night.merged, only), isTrue);
    });
  });
}

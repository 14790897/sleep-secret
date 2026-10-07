import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/session_insights.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';

SoundEvent ev({
  required SleepCategory label,
  required double start,
  required double duration,
}) =>
    SoundEvent(
      label: label,
      startSeconds: start,
      durationSeconds: duration,
      confidence: 0.7,
      snoreProbability: label == SleepCategory.snore ? 0.8 : 0.0,
      windowCount: (duration / 3).round(),
    );

RecordingSession sess({
  required DateTime startedAt,
  List<SoundEvent> events = const [],
  double analyzedSeconds = 28800,
  double snoreSeconds = 0,
  int snoreEventCount = 0,
}) =>
    RecordingSession(
      id: 1,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(hours: 8)),
      events: events,
      stats: SessionStats(
        analyzedSeconds: analyzedSeconds,
        windowsTotal: 9600,
        windowsInferred: 3200,
        windowsVadSkipped: 6400,
        windowsLowConfidence: 0,
        eventCount: events.length,
        snoreEventCount: snoreEventCount,
        snoreSeconds: snoreSeconds,
        categoryDistribution: const {},
      ),
    );

void main() {
  group('hourlyBreakdown', () {
    test('按事件的墙上钟点归组，而不是会话内偏移', () {
      // 23:30 开始 -> 3600s 后是 00:30
      final s = sess(
        startedAt: DateTime(2026, 10, 6, 23, 30),
        events: [
          ev(label: SleepCategory.snore, start: 600, duration: 60), // 23:40
          ev(label: SleepCategory.snore, start: 3600, duration: 90), // 00:30
        ],
      );

      final buckets = hourlyBreakdown(s);

      expect(buckets.map((b) => b.hour), [23, 0]);
      expect(buckets[0].snoreSeconds, 60);
      expect(buckets[1].snoreSeconds, 90);
    });

    test('鼾声与其他声音分开累计', () {
      final s = sess(
        startedAt: DateTime(2026, 10, 6, 23, 0),
        events: [
          ev(label: SleepCategory.snore, start: 60, duration: 30),
          ev(label: SleepCategory.cough, start: 120, duration: 10),
          ev(label: SleepCategory.vocal, start: 200, duration: 20),
        ],
      );

      final bucket = hourlyBreakdown(s).single;

      expect(bucket.hour, 23);
      expect(bucket.snoreSeconds, 30);
      expect(bucket.otherSeconds, 30);
      expect(bucket.totalSeconds, 60);
    });

    test('静音不计入（它是背景不是事件）', () {
      final s = sess(
        startedAt: DateTime(2026, 10, 6, 23, 0),
        events: [
          ev(label: SleepCategory.snore, start: 60, duration: 30),
          ev(label: SleepCategory.silence, start: 300, duration: 600),
        ],
      );

      final buckets = hourlyBreakdown(s);

      expect(buckets.length, 1);
      expect(buckets.single.totalSeconds, 30);
    });

    test('只返回出现过事件的钟点，且按钟点升序', () {
      final s = sess(
        startedAt: DateTime(2026, 10, 6, 23, 0),
        events: [
          ev(label: SleepCategory.snore, start: 3600 * 3, duration: 30), // 02:00
          ev(label: SleepCategory.snore, start: 60, duration: 30), // 23:01
        ],
      );

      final buckets = hourlyBreakdown(s);

      expect(buckets.map((b) => b.hour), [23, 2]);
    });

    test('没有事件时返回空列表', () {
      expect(hourlyBreakdown(sess(startedAt: DateTime(2026, 10, 6, 23))), isEmpty);
    });
  });

  group('snoreDurationHistogram', () {
    test('按分箱边界归类', () {
      final bins = snoreDurationHistogram([
        ev(label: SleepCategory.snore, start: 0, duration: 10), // <15s
        ev(label: SleepCategory.snore, start: 100, duration: 20), // 15-30
        ev(label: SleepCategory.snore, start: 200, duration: 45), // 30-60
        ev(label: SleepCategory.snore, start: 300, duration: 90), // 1-2分
        ev(label: SleepCategory.snore, start: 500, duration: 200), // 2-5分
        ev(label: SleepCategory.snore, start: 900, duration: 400), // >5分
      ]);

      expect(bins.map((b) => b.count), [1, 1, 1, 1, 1, 1]);
    });

    test('边界值归入上一档（左闭右开）', () {
      final bins = snoreDurationHistogram([
        ev(label: SleepCategory.snore, start: 0, duration: 15), // 应落入 15-30
        ev(label: SleepCategory.snore, start: 100, duration: 30), // 应落入 30-60
      ]);

      expect(bins.firstWhere((b) => b.kind == DurationBinKind.under15s).count, 0);
      expect(bins.firstWhere((b) => b.kind == DurationBinKind.s15to30).count, 1);
      expect(bins.firstWhere((b) => b.kind == DurationBinKind.s30to60).count, 1);
    });

    test('非鼾声事件不计入', () {
      final bins = snoreDurationHistogram([
        ev(label: SleepCategory.cough, start: 0, duration: 10),
        ev(label: SleepCategory.vocal, start: 100, duration: 200),
      ]);

      expect(bins.every((b) => b.count == 0), isTrue);
    });

    test('空输入返回全零的完整分箱', () {
      final bins = snoreDurationHistogram(const []);

      expect(bins.length, 6);
      expect(bins.every((b) => b.count == 0), isTrue);
      // 最后一箱没有上界
      expect(bins.last.maxSeconds, isNull);
    });
  });

  group('buildTrend', () {
    test('按时间从旧到新排序', () {
      final trend = buildTrend([
        sess(startedAt: DateTime(2026, 10, 6, 23)),
        sess(startedAt: DateTime(2026, 10, 3, 23)),
        sess(startedAt: DateTime(2026, 10, 1, 23)),
      ]);

      expect(trend.map((p) => p.night.day), [1, 3, 6]);
    });

    test('跳过没有分析数据的会话', () {
      // analyzedSeconds 为 0 时鼾声指数是 0/0，画上去是个假的"零鼾声"点
      final trend = buildTrend([
        sess(startedAt: DateTime(2026, 10, 1, 23), analyzedSeconds: 0),
        sess(startedAt: DateTime(2026, 10, 2, 23), analyzedSeconds: 28800),
      ]);

      expect(trend.length, 1);
      expect(trend.single.night.day, 2);
    });

    test('超过上限时只保留最近的若干晚', () {
      final sessions = [
        for (var i = 0; i < 20; i++)
          sess(startedAt: DateTime(2026, 9, 1 + i, 23)),
      ];

      final trend = buildTrend(sessions, maxNights: 5);

      expect(trend.length, 5);
      // 保留的是最后 5 晚
      expect(trend.first.night.day, 16);
      expect(trend.last.night.day, 20);
    });

    test('空输入返回空序列', () {
      expect(buildTrend(const []), isEmpty);
    });

    test('鼾声指数取自会话统计', () {
      final trend = buildTrend([
        sess(
          startedAt: DateTime(2026, 10, 6, 23),
          analyzedSeconds: 36000,
          snoreSeconds: 3600,
        ),
      ]);

      expect(trend.single.snoreIndex, closeTo(10.0, 1e-9));
    });
  });

  group('summarizeTrend', () {
    List<TrendPoint> points(List<double> indices) => [
          for (var i = 0; i < indices.length; i++)
            TrendPoint(
              night: DateTime(2026, 10, 1 + i, 23),
              snoreIndex: indices[i],
              snoreSeconds: indices[i] * 288,
              snoreEventCount: 1,
              analyzedSeconds: 28800,
            ),
        ];

    test('空序列返回 null', () {
      expect(summarizeTrend(const []), isNull);
    });

    test('均值与极值正确', () {
      final s = summarizeTrend(points([5, 15, 10]))!;

      expect(s.averageIndex, closeTo(10, 1e-9));
      expect(s.bestIndex, 5);
      expect(s.worstIndex, 15);
      expect(s.nights, 3);
    });

    test('识别改善', () {
      final s = summarizeTrend(points([20, 15, 8]))!;

      expect(s.changeFromFirst, closeTo(-12, 1e-9));
      expect(s.improving, isTrue);
      expect(s.worsening, isFalse);
    });

    test('识别变差', () {
      final s = summarizeTrend(points([5, 10, 18]))!;

      expect(s.worsening, isTrue);
      expect(s.improving, isFalse);
    });

    test('小幅波动不算改善也不算变差', () {
      final s = summarizeTrend(points([10, 10.2]))!;

      expect(s.improving, isFalse);
      expect(s.worsening, isFalse);
    });

    test('单晚既不改善也不变差', () {
      final s = summarizeTrend(points([12]))!;

      expect(s.changeFromFirst, 0);
      expect(s.improving, isFalse);
      expect(s.worsening, isFalse);
    });
  });

  group('categoriesPresent', () {
    test('按总时长降序，只列出现过的大类', () {
      final s = sess(
        startedAt: DateTime(2026, 10, 6, 23),
        events: [
          ev(label: SleepCategory.cough, start: 0, duration: 10),
          ev(label: SleepCategory.snore, start: 100, duration: 300),
          ev(label: SleepCategory.snore, start: 500, duration: 100),
        ],
      );

      expect(categoriesPresent(s),
          [SleepCategory.snore, SleepCategory.cough]);
    });

    test('没有事件时返回空', () {
      expect(categoriesPresent(sess(startedAt: DateTime(2026, 10, 6, 23))),
          isEmpty);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/snore_display_filter.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';

void main() {
  SoundEvent ev(
    SleepCategory label,
    double confidence, {
    EventUserLabel? userLabel,
    double duration = 30,
  }) =>
      SoundEvent(
        label: label,
        startSeconds: 0,
        durationSeconds: duration,
        confidence: confidence,
        snoreProbability: label == SleepCategory.snore ? confidence : 0,
        windowCount: 1,
        userLabel: userLabel,
      );

  RecordingSession sessionOf(List<SoundEvent> events) => RecordingSession(
        id: 1,
        startedAt: DateTime(2026, 11, 27, 23),
        endedAt: DateTime(2026, 11, 28, 7),
        events: events,
        stats: SessionStats(
          analyzedSeconds: 28800,
          windowsTotal: 9600,
          windowsInferred: 3200,
          windowsVadSkipped: 6000,
          windowsLowConfidence: 2900,
          eventCount: events.length,
          snoreEventCount: events.where((e) => e.isSnore).length,
          snoreSeconds: 0,
          categoryDistribution: const {},
        ),
      );

  group('环境声展示门槛', () {
    RecordingSession night() => sessionOf([
          ev(SleepCategory.ambient, 0.72),
          ev(SleepCategory.ambient, 0.31),
          ev(SleepCategory.snore, 0.40),
          ev(SleepCategory.cough, 0.25),
        ]);

    test('门槛 0 完全不动：数据和统计原样返回', () {
      final session = night();
      expect(identical(applyDisplayFilters(session), session), isTrue);
      expect(
        identical(applyDisplayFilters(session, ambientPercent: 0), session),
        isTrue,
      );
    });

    test('只筛低把握的环境声，别的类别一个不少', () {
      final filtered = applyDisplayFilters(night(), ambientPercent: 50);

      final labels = filtered.events.map((e) => e.label).toList();
      expect(labels.where((l) => l == SleepCategory.ambient).length, 1,
          reason: '0.72 那条保留，0.31 那条被筛掉');
      expect(labels, contains(SleepCategory.snore),
          reason: '环境声门槛不该影响鼾声——哪怕它只有 0.40');
      expect(labels, contains(SleepCategory.cough));
      expect(filtered.stats.eventCount, 3);
    });

    test('录音侧的事实不动，只有事件派生的统计重算', () {
      final filtered = applyDisplayFilters(night(), ambientPercent: 50);
      expect(filtered.stats.analyzedSeconds, 28800);
      expect(filtered.stats.windowsTotal, 9600);
      expect(filtered.stats.windowsInferred, 3200);
      expect(filtered.stats.windowsVadSkipped, 6000);
      expect(filtered.stats.windowsLowConfidence, 2900);
    });

    test('鼾声门槛也不影响环境声', () {
      final filtered = applyDisplayFilters(night(), snorePercent: 80);
      final ambientCount =
          filtered.events.where((e) => e.label == SleepCategory.ambient).length;
      expect(ambientCount, 2, reason: '环境声一个都不该被鼾声门槛带走');
      expect(filtered.events.where((e) => e.isSnore), isEmpty);
    });

    test('两个门槛同时生效，各管各的', () {
      final filtered = applyDisplayFilters(
        night(),
        snorePercent: 50,
        ambientPercent: 50,
      );
      expect(filtered.events.length, 2);
      final labels = filtered.events.map((e) => e.label).toSet();
      expect(labels, {SleepCategory.ambient, SleepCategory.cough},
          reason: '0.40 的鼾声和 0.31 的环境声都该消失');
    });

    test('用户撤销过的鼾声即使低于鼾声门槛也显示', () {
      final session = sessionOf([
        ev(SleepCategory.snore, 0.10, userLabel: EventUserLabel.notSnore),
      ]);
      final filtered = applyDisplayFilters(session, snorePercent: 80);
      expect(filtered.events, hasLength(1),
          reason: '用户已经亲耳判定过，展示门槛不该替他把这条藏起来');
      expect(filtered.stats.snoreEventCount, 0,
          reason: '显示归显示，撤销过的鼾声不计入统计');
    });
  });
}

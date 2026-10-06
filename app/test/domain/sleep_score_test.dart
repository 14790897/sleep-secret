import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/sleep_score.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';

SoundEvent ev(SleepCategory label, double start, double duration) => SoundEvent(
      label: label,
      startSeconds: start,
      durationSeconds: duration,
      confidence: 0.7,
      snoreProbability: label == SleepCategory.snore ? 0.8 : 0.0,
      windowCount: (duration / 3).round(),
    );

/// 构造一晚：事件列表 + 分析时长，鼾声时长从事件里算出来。
RecordingSession night(List<SoundEvent> events, {double hours = 8}) {
  final analyzed = hours * 3600;
  final snoreSeconds = events
      .where((e) => e.isSnore)
      .fold<double>(0, (s, e) => s + e.durationSeconds);
  final snoreCount = events.where((e) => e.isSnore).length;
  return RecordingSession(
    id: 1,
    startedAt: DateTime(2026, 10, 6, 23),
    endedAt: DateTime(2026, 10, 7, 23).add(Duration(seconds: analyzed.round())),
    events: events,
    stats: SessionStats(
      analyzedSeconds: analyzed,
      windowsTotal: (analyzed / 3).round(),
      windowsInferred: 0,
      windowsVadSkipped: 0,
      windowsLowConfidence: 0,
      eventCount: events.length,
      snoreEventCount: snoreCount,
      snoreSeconds: snoreSeconds,
      categoryDistribution: const {},
    ),
  );
}

ScoreDeduction pick(SleepScore s, String label) =>
    s.deductions.firstWhere((d) => d.label == label);

void main() {
  group('评分门槛', () {
    test('分析时长不足时不给分', () {
      expect(scoreSession(night(const [], hours: 0.5)), isNull,
          reason: '半小时录音算出来的"一夜评分"没有意义，不如不显示');
    });

    test('刚好达到最小时长就给分', () {
      expect(scoreSession(night(const [], hours: 1.5)), isNotNull);
    });

    test('整夜无声是满分', () {
      final s = scoreSession(night(const []))!;

      expect(s.total, 100);
      expect(s.grade, '很安静');
    });
  });

  group('鼾声占比', () {
    test('鼾声越多分越低', () {
      final light = scoreSession(night([ev(SleepCategory.snore, 100, 1800)]))!;
      final heavy = scoreSession(night([ev(SleepCategory.snore, 100, 7200)]))!;

      expect(light.total, greaterThan(heavy.total));
    });

    test('鼾声占到 25% 时扣满该项', () {
      final s = scoreSession(night([ev(SleepCategory.snore, 100, 7200)]))!;
      final d = pick(s, '鼾声占比');

      expect(d.points, closeTo(d.maxPoints, 1e-9));
      expect(d.detail, contains('25.0%'));
    });

    test('超出标尺上限也不会扣成负分', () {
      final s = scoreSession(night([ev(SleepCategory.snore, 0, 20000)]))!;

      expect(s.total, greaterThanOrEqualTo(0));
      expect(pick(s, '鼾声占比').points, closeTo(60, 1e-9));
    });

    test('重度打鼾不会因为"没有别的噪音"而被托底', () {
      // 只打鼾、没有咳嗽没有环境噪音。加权平均模型下这种夜晚会托底到 40 分，
      // 扣分制不会。
      final s = scoreSession(night([ev(SleepCategory.snore, 0, 20000)]))!;

      expect(s.total, lessThan(35),
          reason: '69% 的时间在打鼾，不该被评为"鼾声明显"以上');
      expect(s.grade, '鼾声很重');
    });
  });

  group('鼾声连续性', () {
    test('连续长鼾声比同样时长的碎鼾声扣分更多', () {
      final fragmented = night([
        for (var i = 0; i < 20; i++) ev(SleepCategory.snore, i * 200.0, 90),
      ]);
      final continuous = night([
        ev(SleepCategory.snore, 0, 900),
        ev(SleepCategory.snore, 2000, 900),
      ]);

      final a = pick(scoreSession(fragmented)!, '鼾声连续性');
      final b = pick(scoreSession(continuous)!, '鼾声连续性');

      expect(b.points, greaterThan(a.points));
    });

    test('全是长段时该项扣满', () {
      final s = scoreSession(night([ev(SleepCategory.snore, 0, 3600)]))!;
      final d = pick(s, '鼾声连续性');

      expect(d.points, closeTo(d.maxPoints, 1e-9));
    });

    test('没有鼾声时不扣这项', () {
      final s = scoreSession(night([ev(SleepCategory.cough, 100, 60)]))!;
      final d = pick(s, '鼾声连续性');

      expect(d.points, 0);
      expect(d.detail, '没有检出鼾声');
    });
  });

  group('干扰频次', () {
    test('每小时 20 次以上扣满', () {
      final s = scoreSession(night([
        for (var i = 0; i < 170; i++) ev(SleepCategory.cough, i * 150.0, 18),
      ]))!;
      final d = pick(s, '干扰频次');

      expect(d.points, closeTo(d.maxPoints, 1e-9));
    });

    test('没有干扰事件时不扣这项', () {
      final s = scoreSession(night(const []))!;
      expect(pick(s, '干扰频次').points, 0);
    });
  });

  group('环境噪音', () {
    test('环境噪音占到 40% 时扣满', () {
      final s = scoreSession(night([ev(SleepCategory.ambient, 0, 11520)]))!;
      final d = pick(s, '环境噪音');

      expect(d.points, closeTo(d.maxPoints, 1e-9));
    });

    test('环境噪音越多总分越低', () {
      final quiet = scoreSession(night(const []))!;
      final noisy = scoreSession(night([ev(SleepCategory.ambient, 0, 8000)]))!;

      expect(noisy.total, lessThan(quiet.total));
    });
  });

  group('总分结构', () {
    test('各项扣分上限合计 100 —— 全部拉满正好归零', () {
      final s = scoreSession(night(const []))!;
      final sum = s.deductions.fold<double>(0, (a, d) => a + d.maxPoints);

      expect(sum, closeTo(100, 1e-9));
    });

    test('总分 = 100 减去各项扣分', () {
      final s = scoreSession(night([
        ev(SleepCategory.snore, 100, 1800),
        ev(SleepCategory.cough, 5000, 60),
        ev(SleepCategory.ambient, 9000, 3000),
      ]))!;
      final sum = s.deductions.fold<double>(0, (a, d) => a + d.points);

      expect(s.total, (100 - sum).round());
    });

    test('总分始终落在 0..100', () {
      final worst = scoreSession(night([
        for (var i = 0; i < 200; i++) ev(SleepCategory.cough, i * 100.0, 100),
        ev(SleepCategory.snore, 0, 20000),
        ev(SleepCategory.ambient, 0, 25000),
      ]))!;
      expect(worst.total, inInclusiveRange(0, 100));

      expect(scoreSession(night(const []))!.total, 100);
    });

    test('每一项都给出可读的原始数值', () {
      final s = scoreSession(night([ev(SleepCategory.snore, 100, 1800)]))!;

      for (final d in s.deductions) {
        expect(d.detail, isNotEmpty,
            reason: '${d.label} 缺说明，用户验算不了分数怎么来的');
        expect(d.points, inInclusiveRange(0.0, d.maxPoints));
      }
    });
  });

  group('档位', () {
    test('按分数给不同描述', () {
      expect(scoreSession(night(const []))!.grade, '很安静');
      expect(
        scoreSession(night([ev(SleepCategory.snore, 0, 20000)]))!.grade,
        '鼾声很重',
      );
    });
  });

  group('免责说明', () {
    test('始终附上"这不是睡眠质量"的说明', () {
      final s = scoreSession(night(const []))!;

      expect(s.caveat, contains('不反映你的睡眠分期'));
      expect(s.caveat, contains('整夜安静但没睡好的人'));
    });
  });
}

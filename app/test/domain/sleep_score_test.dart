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

/// 按**是哪一项**取，不按它的显示名取。
///
/// 加多语言之后 `ScoreDeduction` 不再自带名字和说明——那是界面层按语言
/// 渲染的（见 `lib/ui/core/l10n/domain_text.dart`）。所以这里按 kind 取。
ScoreDeduction pick(SleepScore s, DeductionKind kind) =>
    s.deductions.firstWhere((d) => d.kind == kind);

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
      expect(s.grade, ScoreGrade.quiet);
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
      final d = pick(s, DeductionKind.snoreRatio);

      expect(d.points, closeTo(d.maxPoints, 1e-9));
      // 数值在 params 里，句子在 ARB 里。断言数值 —— 那才是这条测试该管的。
      expect(d.params['ratio'], closeTo(25.0, 0.05));
    });

    test('超出标尺上限也不会扣成负分', () {
      final s = scoreSession(night([ev(SleepCategory.snore, 0, 20000)]))!;

      expect(s.total, greaterThanOrEqualTo(0));
      expect(pick(s, DeductionKind.snoreRatio).points, closeTo(60, 1e-9));
    });

    test('重度打鼾不会因为"没有别的噪音"而被托底', () {
      // 只打鼾、没有咳嗽没有环境噪音。加权平均模型下这种夜晚会托底到 40 分，
      // 扣分制不会。
      final s = scoreSession(night([ev(SleepCategory.snore, 0, 20000)]))!;

      expect(s.total, lessThan(35),
          reason: '69% 的时间在打鼾，不该被评为"鼾声明显"以上');
      expect(s.grade, ScoreGrade.heavy);
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

      final a = pick(scoreSession(fragmented)!, DeductionKind.snoreContinuity);
      final b = pick(scoreSession(continuous)!, DeductionKind.snoreContinuity);

      expect(b.points, greaterThan(a.points));
    });

    test('全是长段时该项扣满', () {
      final s = scoreSession(night([ev(SleepCategory.snore, 0, 3600)]))!;
      final d = pick(s, DeductionKind.snoreContinuity);

      expect(d.points, closeTo(d.maxPoints, 1e-9));
    });

    test('没有鼾声时不扣这项', () {
      final s = scoreSession(night([ev(SleepCategory.cough, 100, 60)]))!;
      final d = pick(s, DeductionKind.snoreContinuity);

      expect(d.points, 0);
      expect(d.params['hasSnore'], isFalse);
    });
  });

  group('干扰频次', () {
    test('每小时 20 次以上扣满', () {
      final s = scoreSession(night([
        for (var i = 0; i < 170; i++) ev(SleepCategory.cough, i * 150.0, 18),
      ]))!;
      final d = pick(s, DeductionKind.disturbances);

      expect(d.points, closeTo(d.maxPoints, 1e-9));
    });

    test('没有干扰事件时不扣这项', () {
      final s = scoreSession(night(const []))!;
      expect(pick(s, DeductionKind.disturbances).points, 0);
    });
  });

  group('什么才算干扰', () {
    // 这些用例来自真实整夜数据。那一晚 81 个事件里绝大多数是低置信度的
    // 环境噪音碎片，而当时的实现是「非鼾声、非静音」全都算干扰，
    // 于是「9.4 次/小时」直接扣掉 7 分——**那一晚其实几乎没被打断过**。
    //
    // 界面上那行字一直写着「咳嗽、梦话、翻身等」，文案本来就对，
    // 是实现在扣不该扣的分。
    test('一堆环境噪音碎片不算干扰', () {
      final s = scoreSession(night([
        for (var i = 0; i < 80; i++) ev(SleepCategory.ambient, i * 350.0, 15),
      ]))!;

      expect(pick(s, DeductionKind.disturbances).points, 0,
          reason: '环境噪音是背景不是事件——它已经在「环境噪音占比」'
              '那一项里扣过分了，不该在这里再扣一次');
    });

    test('呼吸声不算干扰', () {
      final s = scoreSession(night([
        for (var i = 0; i < 80; i++) ev(SleepCategory.breathing, i * 350.0, 15),
      ]))!;

      expect(pick(s, DeductionKind.disturbances).points, 0,
          reason: '呼吸是睡眠本来的样子，不是打断');
    });

    test('咳嗽、梦话、翻身才算', () {
      for (final c in [
        SleepCategory.cough,
        SleepCategory.vocal,
        SleepCategory.movement,
      ]) {
        final s = scoreSession(night([
          for (var i = 0; i < 120; i++) ev(c, i * 200.0, 15),
        ]))!;

        expect(pick(s, DeductionKind.disturbances).points, greaterThan(0),
            reason: '${c.name} 是可能打断睡眠的声音，应当扣分');
      }
    });
  });

  group('环境噪音', () {
    test('环境噪音占到 40% 时扣满', () {
      final s = scoreSession(night([ev(SleepCategory.ambient, 0, 11520)]))!;
      final d = pick(s, DeductionKind.ambient);

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
        // 原先断言的是"每项都有一句说明，用户能验算分数怎么来的"。
        // 说明现在在 ARB 里，领域层这边该保证的是**数值都在**——
        // 少了参数，界面那边渲染出来就是一句缺数的空话。
        expect(d.params, isNotEmpty,
            reason: '${d.kind.name} 没有给出数值，界面渲染出来会缺数');
        expect(d.points, inInclusiveRange(0.0, d.maxPoints));
      }
    });
  });

  group('档位', () {
    test('按分数给不同档', () {
      // 断言的是**档位**不是那句话。档位是数据，措辞在 ARB 里
      // （`gradeQuiet` / `gradeHeavy` …），由 `domain_text.dart` 渲染。
      expect(scoreSession(night(const []))!.grade, ScoreGrade.quiet);
      expect(
        scoreSession(night([ev(SleepCategory.snore, 0, 20000)]))!.grade,
        ScoreGrade.heavy,
      );
    });
  });

  // 原先这里还有一组「免责说明」，断言那段"这不是睡眠质量"的文案写了什么。
  // 那段说明现在是 ARB 里的 `scoreCaveat`——一个跟分数无关的常量，
  // 挂在每个实例上只是让每个实例都背一遍同样的话。
  // 渲染出来对不对由 `report_view_test` 的「原样展示…」那条守着。
}

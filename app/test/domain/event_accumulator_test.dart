import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/analysis_config.dart';
import 'package:sleep_secret/domain/analysis/event_accumulator.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';

WindowObservation obs({
  required double start,
  SleepCategory? label,
  double duration = 3.0,
  double confidence = 0.8,
  double snore = 0.0,
  bool inferred = true,
}) =>
    WindowObservation(
      startSeconds: start,
      durationSeconds: duration,
      label: label,
      confidence: confidence,
      snoreProbability: snore,
      categories: {
        for (final c in SleepCategory.values)
          c: c == label ? confidence : 0.0,
      },
      wasInferred: inferred,
    );

void main() {
  group('EventAccumulator 事件合并', () {
    test('相邻同类窗口合并成一个事件', () {
      final acc = EventAccumulator();
      acc.add(obs(start: 0, label: SleepCategory.snore));
      acc.add(obs(start: 3, label: SleepCategory.snore));
      acc.add(obs(start: 6, label: SleepCategory.snore));

      final outcome = acc.build();

      expect(outcome.events.length, 1);
      expect(outcome.events.first.label, SleepCategory.snore);
      expect(outcome.events.first.startSeconds, 0);
      expect(outcome.events.first.durationSeconds, 9);
      expect(outcome.events.first.windowCount, 3);
    });

    test('间隔超过 mergeGap 的同类窗口拆成两个事件', () {
      final acc = EventAccumulator(
        config: const AnalysisConfig(mergeGapSeconds: 5, minEventSeconds: 3),
      );
      acc.add(obs(start: 0, label: SleepCategory.snore));
      // 上一个事件结束于 3，这里从 20 开始，间隔 17 > 5
      acc.add(obs(start: 20, label: SleepCategory.snore));

      final outcome = acc.build();

      expect(outcome.events.length, 2);
    });

    test('间隔在 mergeGap 之内的同类窗口仍合并', () {
      final acc = EventAccumulator(
        config: const AnalysisConfig(mergeGapSeconds: 5),
      );
      acc.add(obs(start: 0, label: SleepCategory.snore));
      // 上一个结束于 3，这里从 8 开始，间隔 5 <= 5
      acc.add(obs(start: 8, label: SleepCategory.snore));

      expect(acc.build().events.length, 1);
    });

    test('不同类别不会合并', () {
      final acc = EventAccumulator(
        config: const AnalysisConfig(minEventSeconds: 3),
      );
      acc.add(obs(start: 0, label: SleepCategory.snore));
      acc.add(obs(start: 3, label: SleepCategory.cough));

      final outcome = acc.build();

      expect(outcome.events.length, 2);
      expect(outcome.events[0].label, SleepCategory.snore);
      expect(outcome.events[1].label, SleepCategory.cough);
    });

    test('静音窗口不产生事件', () {
      final acc = EventAccumulator(
        config: const AnalysisConfig(minEventSeconds: 3),
      );
      acc.add(obs(start: 0, label: null, inferred: false));
      acc.add(obs(start: 3, label: null, inferred: true));

      final outcome = acc.build();

      expect(outcome.events, isEmpty);
      expect(outcome.stats.windowsVadSkipped, 1);
      expect(outcome.stats.windowsLowConfidence, 1);
    });

    test('静音只让合并的间隔变大，间隔够小仍会跨越静音合并', () {
      // 这是有意的平滑：与 PC 端 ml/infer.py 行为一致。
      // 0-3s 鼾声 + 3-6s 静音 + 6-9s 鼾声，间隔 3s < mergeGap(9s)
      final acc = EventAccumulator(
        config: const AnalysisConfig(minEventSeconds: 3),
      );
      acc.add(obs(start: 0, label: SleepCategory.snore));
      acc.add(obs(start: 3, label: null, inferred: false));
      acc.add(obs(start: 6, label: SleepCategory.snore));

      final outcome = acc.build();

      expect(outcome.events.length, 1);
      expect(outcome.events.single.startSeconds, 0);
      expect(outcome.events.single.durationSeconds, 9);
    });

    test('静音间隔超过 mergeGap 时鼾声段不再合并', () {
      final acc = EventAccumulator(
        config: const AnalysisConfig(minEventSeconds: 3, mergeGapSeconds: 2),
      );
      acc.add(obs(start: 0, label: SleepCategory.snore));
      acc.add(obs(start: 3, label: null, inferred: false));
      // 上一事件结束于 3，这里从 10 开始，间隔 7 > mergeGap(2)
      acc.add(obs(start: 10, label: SleepCategory.snore));

      final outcome = acc.build();

      expect(outcome.events.length, 2);
    });

    test('合并时取置信度与鼾声概率的较大值', () {
      final acc = EventAccumulator();
      acc.add(obs(start: 0, label: SleepCategory.snore, confidence: 0.5, snore: 0.3));
      acc.add(obs(start: 3, label: SleepCategory.snore, confidence: 0.9, snore: 0.7));

      final event = acc.build().events.single;

      expect(event.confidence, 0.9);
      expect(event.snoreProbability, 0.7);
    });
  });

  group('EventAccumulator 事件过滤', () {
    test('短于 minEventSeconds 的碎片被丢弃', () {
      final acc = EventAccumulator(
        config: const AnalysisConfig(minEventSeconds: 6),
      );
      acc.add(obs(start: 0, label: SleepCategory.cough, duration: 3));

      expect(acc.build().events, isEmpty);
    });

    test('恰好等于 minEventSeconds 的事件保留（边界含等号）', () {
      final acc = EventAccumulator(
        config: const AnalysisConfig(minEventSeconds: 3),
      );
      acc.add(obs(start: 0, label: SleepCategory.cough, duration: 3));

      expect(acc.build().events.length, 1);
    });
  });

  group('EventAccumulator 统计', () {
    test('统计各类窗口数', () {
      final acc = EventAccumulator();
      acc.add(obs(start: 0, label: SleepCategory.snore));
      acc.add(obs(start: 3, label: null, inferred: true)); // 低置信度
      acc.add(obs(start: 6, label: null, inferred: false)); // 被 VAD 跳过

      final stats = acc.build().stats;

      expect(stats.windowsTotal, 3);
      expect(stats.windowsInferred, 2);
      expect(stats.windowsVadSkipped, 1);
      expect(stats.windowsLowConfidence, 1);
    });

    test('推理比例正确', () {
      final acc = EventAccumulator();
      acc.add(obs(start: 0, label: null, inferred: false));
      acc.add(obs(start: 3, label: null, inferred: false));
      acc.add(obs(start: 6, label: SleepCategory.snore, inferred: true));
      acc.add(obs(start: 9, label: SleepCategory.snore, inferred: true));

      expect(acc.build().stats.inferenceRatio, closeTo(0.5, 1e-9));
    });

    test('鼾声指数 = 鼾声时长 / 分析时长', () {
      final acc = EventAccumulator();
      // 4 个窗口共 12s 分析时长，其中 6s 是鼾声事件
      acc.add(obs(start: 0, label: SleepCategory.snore));
      acc.add(obs(start: 3, label: SleepCategory.snore));
      acc.add(obs(start: 6, label: SleepCategory.ambient));
      acc.add(obs(start: 9, label: SleepCategory.ambient));

      final stats = acc.build().stats;

      expect(stats.analyzedSeconds, 12);
      expect(stats.snoreSeconds, 6);
      expect(stats.snoreIndex, closeTo(50.0, 1e-9));
    });

    test('类别分布只统计真正推理过的窗口', () {
      final acc = EventAccumulator();
      acc.add(obs(start: 0, label: SleepCategory.snore, inferred: true));
      acc.add(obs(start: 3, label: null, inferred: false)); // 不参与分布

      final dist = acc.build().stats.categoryDistribution;

      expect(dist[SleepCategory.snore], closeTo(0.8, 1e-9));
      expect(dist[SleepCategory.ambient], closeTo(0.0, 1e-9));
    });

    test('没有任何窗口时统计为零且不除零', () {
      final stats = EventAccumulator().build().stats;

      expect(stats.windowsTotal, 0);
      expect(stats.inferenceRatio, 0.0);
      expect(stats.snoreIndex, 0.0);
      expect(stats.categoryDistribution, isEmpty);
    });

    test('全是静音时鼾声相关统计为零', () {
      final acc = EventAccumulator();
      acc.add(obs(start: 0, label: null, inferred: false));
      acc.add(obs(start: 3, label: null, inferred: false));

      final stats = acc.build().stats;

      expect(stats.eventCount, 0);
      expect(stats.snoreSeconds, 0);
      expect(stats.snoreIndex, 0.0);
    });
  });

  group('EventAccumulator 生命周期', () {
    test('eventsSoFar 在 build 前就能看到已合并的事件', () {
      final acc = EventAccumulator();
      acc.add(obs(start: 0, label: SleepCategory.snore));
      acc.add(obs(start: 3, label: SleepCategory.snore));

      expect(acc.eventsSoFar.length, 1);
      expect(acc.windowCount, 2);
    });

    test('reset 清空全部状态', () {
      final acc = EventAccumulator();
      acc.add(obs(start: 0, label: SleepCategory.snore));
      acc.reset();

      expect(acc.windowCount, 0);
      expect(acc.eventsSoFar, isEmpty);
      expect(acc.build().events, isEmpty);
    });
  });
}

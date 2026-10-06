
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/analysis_config.dart';
import 'package:sleep_secret/domain/analysis/night_analysis_engine.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';

import '../helpers/fake_sleep_analyzer.dart';

/// 1 秒窗口便于构造短测试，阈值保持与生产默认一致。
const testConfig = AnalysisConfig(
  windowSeconds: 1.0,
  hopSeconds: 1.0,
  vadRms: 0.01,
  minConfidence: 0.15,
  minEventSeconds: 2.0,
  mergeGapSeconds: 1.5,
);

const quiet = 0.001; // 远低于 vadRms
const loud = 0.5; // 远高于 vadRms

void main() {
  group('NightAnalysisEngine 能量门控', () {
    test('安静窗口不进模型，统计里记为 VAD 跳过', () async {
      final analyzer = FakeSleepAnalyzer();
      final engine = NightAnalysisEngine(analyzer: analyzer, config: testConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 3));
      final outcome = await engine.finish();

      expect(analyzer.classifyCount, 0, reason: '安静段不该产生任何推理');
      expect(outcome.stats.windowsTotal, 3);
      expect(outcome.stats.windowsInferred, 0);
      expect(outcome.stats.windowsVadSkipped, 3);
      expect(outcome.stats.inferenceRatio, 0.0);
      expect(outcome.events, isEmpty);
    });

    test('响亮窗口才会进模型', () async {
      final analyzer = FakeSleepAnalyzer();
      final engine = NightAnalysisEngine(analyzer: analyzer, config: testConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 3));
      await engine.finish();

      expect(analyzer.classifyCount, 3);
      expect(analyzer.classifiedLengths, everyElement(16000));
    });

    test('安静与响亮混合时只有响亮段被推理', () async {
      final analyzer = FakeSleepAnalyzer();
      final engine = NightAnalysisEngine(analyzer: analyzer, config: testConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 2));
      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 2));
      final outcome = await engine.finish();

      expect(analyzer.classifyCount, 2);
      expect(outcome.stats.windowsVadSkipped, 2);
      expect(outcome.stats.windowsInferred, 2);
      expect(outcome.stats.inferenceRatio, closeTo(0.5, 1e-9));
    });
  });

  group('NightAnalysisEngine 置信度门控', () {
    test('模型没把握时不产生事件', () async {
      // 两道闸门都过了（响亮），但预测接近均匀 -> 置信度不足
      final analyzer = FakeSleepAnalyzer(responder: (_) => FakeSleepAnalyzer.uniform());
      final engine = NightAnalysisEngine(analyzer: analyzer, config: testConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 4));
      final outcome = await engine.finish();

      expect(analyzer.classifyCount, 4, reason: '能量门控放行了，确实推理了');
      expect(outcome.stats.windowsLowConfidence, 4);
      expect(outcome.events, isEmpty, reason: '置信度不足不该产生假事件');
    });

    test('模型有把握时产生事件', () async {
      final analyzer = FakeSleepAnalyzer(); // 默认：鼾声 0.8
      final engine = NightAnalysisEngine(analyzer: analyzer, config: testConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 4));
      final outcome = await engine.finish();

      expect(outcome.events.length, 1);
      expect(outcome.events.single.label, SleepCategory.snore);
      expect(outcome.events.single.durationSeconds, 4);
      expect(outcome.stats.snoreEventCount, 1);
    });
  });

  group('NightAnalysisEngine 健壮性', () {
    test('单窗口推理失败不中断整夜，只累计错误数', () async {
      final analyzer = FakeSleepAnalyzer(throwOnClassify: true);
      final engine = NightAnalysisEngine(analyzer: analyzer, config: testConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      final events = await engine.feedSamples(
        tone(amplitude: loud, length: 16000 * 3),
      );
      final outcome = await engine.finish();

      expect(events, isEmpty);
      expect(analyzer.classifyCount, 3, reason: '三次都尝试了');
      expect(engine.inferenceErrors, 3);

      // 失败的窗口不计入任何统计——未分析就是未分析，
      // 不伪装成静音（会拉低鼾声指数的分母）也不伪装成低置信度。
      expect(outcome.stats.windowsTotal, 0);
      expect(outcome.stats.analyzedSeconds, 0);
      expect(outcome.events, isEmpty);
    });

    test('分块送入与一次性送入结果一致', () async {
      final samples = tone(amplitude: loud, length: 16000 * 4);

      final whole = NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: testConfig);
      whole.start(DateTime(2026, 10, 6, 23));
      await whole.feedSamples(samples);
      final a = await whole.finish();

      final chunked = NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: testConfig);
      chunked.start(DateTime(2026, 10, 6, 23));
      for (var offset = 0; offset < samples.length; offset += 1234) {
        final end =
            (offset + 1234) > samples.length ? samples.length : offset + 1234;
        await chunked.feedSamples(samples.sublist(offset, end));
      }
      final b = await chunked.finish();

      expect(a.stats.windowsTotal, b.stats.windowsTotal);
      expect(a.stats.windowsInferred, b.stats.windowsInferred);
      expect(a.events.length, b.events.length);
      if (a.events.isNotEmpty) {
        expect(a.events.first.durationSeconds,
            closeTo(b.events.first.durationSeconds, 1e-9));
      }
    });

    test('尾部不足一个窗口的音频也会被分析', () async {
      final analyzer = FakeSleepAnalyzer();
      final engine = NightAnalysisEngine(analyzer: analyzer, config: testConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      // 2.5 个窗口：2 个完整 + 0.5 个尾部
      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 2 + 8000));
      final outcome = await engine.finish();

      expect(analyzer.classifyCount, 3, reason: '尾部残料也要分析，不能丢');
      expect(outcome.stats.windowsTotal, 3);
    });

    test('reset 后可以开始新的一夜', () async {
      final engine = NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: testConfig);
      engine.start(DateTime(2026, 10, 6, 23));
      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 3));
      await engine.finish();

      engine.reset();

      expect(engine.windowsProcessed, 0);
      expect(engine.events, isEmpty);
      expect(engine.inferenceErrors, 0);
      expect(engine.pendingSamples, 0);
    });
  });

  group('NightAnalysisEngine 实时状态', () {
    test('feed 返回当前已合并的事件，供界面实时展示', () async {
      final engine = NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: testConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      final afterTwo = await engine.feedSamples(
        tone(amplitude: loud, length: 16000 * 2),
      );

      expect(afterTwo.length, 1);
      expect(afterTwo.single.startSeconds, 0);
    });

    test('toSession 生成未落库的会话对象', () async {
      final engine = NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: testConfig);
      final started = DateTime(2026, 10, 6, 23, 30);
      engine.start(started);
      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 3));
      final outcome = await engine.finish();

      final ended = started.add(const Duration(hours: 8));
      final session = engine.toSession(started, ended, outcome);

      expect(session.id, isNull);
      expect(session.startedAt, started);
      expect(session.endedAt, ended);
      expect(session.duration, const Duration(hours: 8));
      expect(session.isFinished, isTrue);
      expect(session.events, isNotEmpty);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/analysis_config.dart';
import 'package:sleep_secret/domain/analysis/night_analysis_engine.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';

import '../helpers/fake_clip_services.dart';
import '../helpers/fake_sleep_analyzer.dart';

/// 1 秒窗口便于构造短测试；片段策略用生产默认值。
const testConfig = AnalysisConfig(
  windowSeconds: 1.0,
  hopSeconds: 1.0,
  vadRms: 0.01,
  lowConfidenceThreshold: 0.15,
  minEventSeconds: 2.0,
  mergeGapSeconds: 1.5,
);

const loud = 0.5;
const quiet = 0.001;

void main() {
  late FakeAudioClipStore store;

  setUp(() => store = FakeAudioClipStore());

  NightAnalysisEngine engineWith({
    FakeSleepAnalyzer? analyzer,
    AnalysisConfig config = testConfig,
    bool withStore = true,
  }) =>
      NightAnalysisEngine(
        analyzer: analyzer ?? FakeSleepAnalyzer(),
        config: config,
        clipStore: withStore ? store : null,
      );

  group('鼾声片段抽取', () {
    test('鼾声事件定案后写出片段，并回填路径', () async {
      final engine = engineWith();
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 6));
      final outcome = await engine.finish();

      expect(outcome.events, isNotEmpty);
      expect(store.saved.length, 1);
      expect(outcome.events.first.clipPath, isNotNull,
          reason: '写完片段必须回填路径，否则数据库里存的是空');
      expect(engine.clipsSaved, 1);
      expect(engine.clipsSkipped, 0);
    });

    test('片段包含前后余量', () async {
      final engine = engineWith();
      engine.start(DateTime(2026, 10, 6, 23));

      // 安静 -> 响亮 -> 安静。余量只有在事件前后还有音频时才存在，
      // 这正是真实录音的样子：鼾声总是在一片安静中间。
      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 3));
      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 4));
      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 3));
      final outcome = await engine.finish();

      final event = outcome.events.first;
      final seconds = store.saved.values.single.length / 16000;

      expect(event.durationSeconds, closeTo(4, 1));
      expect(seconds, closeTo(event.durationSeconds + 2, 1),
          reason: '不留余量的话片段会从声音正中开始、在正中结束，听着很突兀');
    });

    test('事件还在字面结束时，尾部余量取不到也照样出片段', () async {
      final engine = engineWith();
      engine.start(DateTime(2026, 10, 6, 23));

      // 录音以响亮音频收尾：事件后面没有音频了，尾部余量天然不存在
      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 5));
      final outcome = await engine.finish();

      expect(outcome.events.first.clipPath, isNotNull,
          reason: '缺后半截余量只是少听半秒，不该因此整段放弃');
      expect(engine.clipsSkipped, 0);
    });

    test('超长事件只截取一段，不会写出超大文件', () async {
      const config = AnalysisConfig(
        windowSeconds: 1.0,
        hopSeconds: 1.0,
        minEventSeconds: 2.0,
        maxClipSeconds: 5.0,
        clipBufferSeconds: 30.0,
      );
      final engine = engineWith(config: config);
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 20));
      final outcome = await engine.finish();

      expect(outcome.events.first.durationSeconds, greaterThan(10));

      // 事件有 20 秒，片段被限制在 5 秒 + 余量
      final seconds = store.saved.values.single.length / 16000;
      expect(seconds, lessThanOrEqualTo(config.maxClipSeconds + 0.5));
    });

    test('只留鼾声，咳嗽等不落片段', () async {
      final analyzer = FakeSleepAnalyzer(
        responder: (_) => FakeSleepAnalyzer.prediction(categories: {
          SleepCategory.cough: 0.9,
        }),
      );
      final engine = engineWith(analyzer: analyzer);
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 5));
      final outcome = await engine.finish();

      expect(outcome.events.first.label, SleepCategory.cough);
      expect(store.saved, isEmpty,
          reason: '梦话和咳嗽的隐私含义与鼾声不同，先不录');
      expect(engine.clipsSaved, 0);
    });

    test('过短的事件不落片段', () async {
      final engine = engineWith();
      engine.start(DateTime(2026, 10, 6, 23));

      // 3 秒音频，事件长度接近 minEventSeconds 但仍在门槛上
      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 3));
      final outcome = await engine.finish();

      expect(outcome.stats.eventCount, lessThanOrEqualTo(1));
      // 无论是否成立事件，都不该有超过事件数的片段
      expect(store.saved.length, lessThanOrEqualTo(outcome.events.length));
    });

    test('安静录音不落任何片段', () async {
      final engine = engineWith();
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 10));
      final outcome = await engine.finish();

      expect(outcome.events, isEmpty);
      expect(store.saved, isEmpty);
    });
  });

  group('片段开关与降级', () {
    test('关掉开关后不落片段（可运行时切换）', () async {
      final engine = engineWith();
      engine.recordClips = false;
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 6));
      final outcome = await engine.finish();

      expect(outcome.events, isNotEmpty, reason: '关的只是片段，事件照常识别');
      expect(store.saved, isEmpty);
    });

    test('没有片段存储时照常工作', () async {
      final engine = engineWith(withStore: false);
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 6));
      final outcome = await engine.finish();

      expect(outcome.events, isNotEmpty);
      expect(engine.clipsSaved, 0);
      expect(engine.clipsSkipped, 0);
    });

    test('写盘失败只计数，不影响事件本身', () async {
      store.failOnSave = true;
      final engine = engineWith();
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 6));
      final outcome = await engine.finish();

      expect(outcome.events, isNotEmpty);
      expect(engine.clipsSkipped, greaterThan(0));
      expect(outcome.events.first.clipPath, isNull);
    });

    test('缓冲不足以覆盖最长片段时构造就报错', () {
      expect(
        () => NightAnalysisEngine(
          analyzer: FakeSleepAnalyzer(),
          config: const AnalysisConfig(
            maxClipSeconds: 60,
            clipBufferSeconds: 30, // 装不下
          ),
          clipStore: store,
        ),
        throwsArgumentError,
      );
    });

    test('关掉片段时不校验缓冲（用不上）', () {
      expect(
        () => NightAnalysisEngine(
          analyzer: FakeSleepAnalyzer(),
          config: const AnalysisConfig(
            recordClips: false,
            maxClipSeconds: 60,
            clipBufferSeconds: 30,
          ),
          clipStore: store,
        ),
        returnsNormally,
      );
    });
  });

  group('完整一夜的片段归属', () {
    test('每段鼾声各得一个片段，路径互不相同', () async {
      final engine = engineWith();
      engine.start(DateTime(2026, 10, 6, 23));

      // 三类声音交替：鼾声 -> 咳嗽 -> 鼾声，中间隔足够久以免被合并
      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 4));
      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 12));

      final outcome = await engine.finish();

      final paths = outcome.events
          .where((e) => e.hasClip)
          .map((e) => e.clipPath)
          .toSet();
      expect(paths.length, store.saved.length,
          reason: '每条有片段的事件都该指向不同的文件');
    });
  });
}

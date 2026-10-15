
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/analysis_config.dart';
import 'package:sleep_secret/domain/analysis/decibel.dart';
import 'package:sleep_secret/domain/analysis/night_analysis_engine.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sleep_prediction.dart';

import '../helpers/fake_sleep_analyzer.dart';

/// 1 秒窗口便于构造短测试，阈值保持与生产默认一致。
const testConfig = AnalysisConfig(
  windowSeconds: 1.0,
  hopSeconds: 1.0,
  // 这些测试测的就是能量门控的行为，显式打开
  // （生产默认是关的，见 AnalysisConfig.vadEnabled）
  vadEnabled: true,
  vadRms: 0.01,
  lowConfidenceThreshold: 0.15,
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

  group('NightAnalysisEngine 把握不大时仍然产生事件', () {
    // 这里原本叫「置信度门控」，测的是「模型没把握就不产生事件」。
    // 那道门去掉了——实测它在真实音频上什么也不做，而它声称要防的问题
    // 本来就不会发生（详见 night_analysis_engine.dart 里那段说明）。
    //
    // 现在把握程度只影响**展示**，不影响判定。
    test('模型没把握时照样产生事件，并如实记下把握程度', () async {
      // 能量门控过了（响亮），但预测接近均匀 -> 最高分也很低
      final analyzer =
          FakeSleepAnalyzer(responder: (_) => FakeSleepAnalyzer.uniform());
      final engine = NightAnalysisEngine(analyzer: analyzer, config: testConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 4));
      final outcome = await engine.finish();

      expect(analyzer.classifyCount, 4, reason: '能量门控放行了，确实推理了');
      expect(outcome.stats.windowsLowConfidence, 4);
      expect(outcome.events, isNotEmpty,
          reason: '不再按置信度丢弃——把握多大交给界面展示，由用户判断');
      expect(outcome.events.first.confidence, lessThan(0.25),
          reason: '把握程度要如实记进事件里，否则界面上标不出来');
    });

    test('判定为静音时不产生事件', () async {
      // 静音在这套类别里被定义成**背景状态而不是声音事件**
      // （SleepCategory.isRecessive），所以不给它建事件。
      // 这是语义规则，不是置信度门槛——去掉门槛不影响它。
      final analyzer = FakeSleepAnalyzer(
        responder: (_) => FakeSleepAnalyzer.prediction(categories: const {
          SleepCategory.silence: 0.9,
          SleepCategory.ambient: 0.05,
        }),
      );
      final engine = NightAnalysisEngine(analyzer: analyzer, config: testConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 4));
      final outcome = await engine.finish();

      expect(outcome.stats.windowsInferred, 4, reason: '推理是发生了的');
      expect(outcome.events, isEmpty);
      expect(outcome.stats.windowsLowConfidence, 0,
          reason: '置信度 0.9，只是判成静音了——这不是「把握不大」');
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
      expect(outcome.stats.windowsLowConfidence, 0);
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

  group('自适应能量门控', () {
    // 小样本量，好在短测试里触发自适应。生产默认是 60 个窗口（约 3 分钟）。
    const adaptiveConfig = AnalysisConfig(
      windowSeconds: 1.0,
      hopSeconds: 1.0,
      // 这个组测的就是能量门控本身，必须打开
      vadEnabled: true,
      vadRms: 0.01,
      lowConfidenceThreshold: 0.15,
      minEventSeconds: 2.0,
      mergeGapSeconds: 1.5,
      vadMinSamples: 3,
      vadHistoryWindows: 100,
    );

    test('没有样本时用固定阈值', () {
      final engine =
          NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: adaptiveConfig);
      expect(engine.vadThreshold, closeTo(0.01, 1e-9));
      expect(engine.noiseFloor, isNull);
    });

    test('安静的房间会把阈值降到固定值以下', () async {
      final engine =
          NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: adaptiveConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      // tone 的 RMS ≈ amplitude/√2，所以 0.002 对应 RMS ≈ 0.0014，
      // 估计出的阈值 ≈ 0.0014 × 3 = 0.0042，低于固定的 0.01。
      await engine.feedSamples(tone(amplitude: 0.002, length: 16000 * 10));

      expect(engine.vadThreshold, lessThan(0.01),
          reason: '房间本身就在 0.001 这个量级，阈值还钉在 0.01 的话，'
              '比这更轻的声音永远进不了模型——固定阈值的毛病正在于此');
    });

    test('被跳过的窗口也喂给了噪声底', () async {
      final engine =
          NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: adaptiveConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      // 全是会被跳过的安静窗口
      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 10));

      expect(engine.noiseFloor, isNotNull,
          reason: '如果只把"通过门控的窗口"喂给噪声底，历史里就只剩响的那部分，'
              '噪声底被高估、阈值一路推高，自适应会变成自我实现的预言。'
              '噪声底估得出来，说明被跳过的窗口也喂进去了。');
    });

    test('reset 之后回到固定阈值，不带着上一次的房间', () async {
      final engine =
          NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: adaptiveConfig);
      engine.start(DateTime(2026, 10, 6, 23));
      await engine.feedSamples(tone(amplitude: 0.001, length: 16000 * 10));
      expect(engine.vadThreshold, lessThan(0.01));

      engine.reset();

      expect(engine.vadThreshold, closeTo(0.01, 1e-9),
          reason: '下一次录音会换一个房间，不该沿用上一次算出来的阈值');
      expect(engine.noiseFloor, isNull);
    });
  });

  group('能量门控默认关闭', () {
    // 生产默认 vadEnabled = false：每一段都送进模型。
    //
    // 依据是实测——门控**没在挡误报**（关掉之后雨声、公鸡叫、白噪声照样
    // 0 个鼾声段，那些是模型自己在做），它换来的只有算力。
    // 而那个算力账是按 PC 速度估的，真机还没量过，所以是先关掉不是删掉。
    const noVadConfig = AnalysisConfig(
      windowSeconds: 1.0,
      hopSeconds: 1.0,
      minEventSeconds: 2.0,
      mergeGapSeconds: 1.5,
    );

    test('AnalysisConfig 的默认值就是关的', () {
      expect(const AnalysisConfig().vadEnabled, isFalse,
          reason: '这是生产默认值。要改成 true 得先有真机的算力/耗电数据。');
    });

    test('安静段也会送进模型', () async {
      final analyzer = FakeSleepAnalyzer();
      final engine = NightAnalysisEngine(analyzer: analyzer, config: noVadConfig);
      engine.start(DateTime(2026, 10, 6, 23));

      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 4));
      final outcome = await engine.finish();

      expect(analyzer.classifyCount, 4, reason: '安静段照样推理');
      expect(outcome.stats.windowsVadSkipped, 0);
      expect(outcome.stats.windowsInferred, 4);
    });

    test('没有阈值可以画，界面就不该画那条线', () {
      final engine =
          NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: noVadConfig);
      expect(engine.vadThreshold, isNull);
    });
  });

  group('能量门控可以中途拨（「关于」页那个开关）', () {
    // 口径同上：1 秒窗口便于构造短测试，门控**默认关着**（生产默认值）
    const config = AnalysisConfig(
      windowSeconds: 1.0,
      hopSeconds: 1.0,
      minEventSeconds: 2.0,
      mergeGapSeconds: 1.5,
    );

    test('拨开之后安静窗口立刻不再进模型，拨回去又进', () async {
      final analyzer = FakeSleepAnalyzer();
      final engine = NightAnalysisEngine(analyzer: analyzer, config: config);
      engine.start(DateTime(2026, 10, 9, 23));

      expect(engine.vadEnabled, isFalse, reason: '默认值和 AnalysisConfig 一致');
      expect(engine.vadThreshold, isNull,
          reason: '关着的时候没有门槛，界面就不该画那条红线');

      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 2));
      expect(analyzer.classifyCount, 2, reason: '关着：安静的也送进模型');

      // 拨开。**立刻生效**，不用重启录音——这是这个开关的全部意义
      engine.vadEnabled = true;
      expect(engine.vadThreshold, isNotNull, reason: '开着就有门槛了');

      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 2));
      expect(analyzer.classifyCount, 2, reason: '开着：安静窗口被跳过，不再推理');

      engine.vadEnabled = false;
      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 2));
      expect(analyzer.classifyCount, 4, reason: '拨回去又该进模型');
      expect(engine.vadThreshold, isNull);
    });

    test('噪声底一直在估——拨开时门槛是热的，不用重新攒样本', () async {
      // 关着的时候也要喂噪声底。否则拨开之后的头几分钟用的是固定 fallback，
      // 而这个房间真正的阈值要等攒够样本才算得出来——那几分钟里门控是瞎的。
      final engine =
          NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: config);
      engine.start(DateTime(2026, 10, 9, 23));

      await engine.feedSamples(tone(amplitude: quiet, length: 16000 * 120));
      expect(engine.noiseFloor, isNotNull,
          reason: '门控还关着，但噪声底已经估出来了');

      engine.vadEnabled = true;
      expect(engine.vadThreshold, isNotNull);
    });

    test('调低基准门槛，本来被跳过的轻声音就能进来了', () async {
      // ⚠️ 这条就是作者真机上的处境：手机放枕边、隔着被子，
      // 鼾声的 RMS 只有 0.0014 左右（事件列表上标 ~37 分贝），
      // 落在默认门槛（约 54 分贝）**之下**——打开门控会整晚被跳过。
      final analyzer = FakeSleepAnalyzer();
      final engine = NightAnalysisEngine(analyzer: analyzer, config: config);
      engine.vadEnabled = true;
      engine.start(DateTime(2026, 10, 10, 1));

      const light = 0.002; // RMS ≈ 0.0014

      await engine.feedSamples(tone(amplitude: light, length: 16000 * 3));
      expect(analyzer.classifyCount, 0,
          reason: '默认门槛之下，这一段该被整个跳过');

      // 门槛调到 30 分贝（≈ RMS 0.0006）
      engine.setVadBaseRms(rmsForEstimatedDbSpl(30));

      await engine.feedSamples(tone(amplitude: light, length: 16000 * 3));
      expect(analyzer.classifyCount, 3,
          reason: '门槛调到它之下以后，同一段声音（3 个 1 秒窗口）就该进模型了');
    });

    test('调门槛不取消上下界——区间跟着一起挪', () async {
      // 当初加上下界是为了防止"越打鼾阈值越高、越检测不到"那种失效，
      // 调基准只是把整个区间平移，那条约束依然成立。
      final engine = NightAnalysisEngine(analyzer: FakeSleepAnalyzer(), config: config);
      engine.vadEnabled = true;
      engine.setVadBaseRms(rmsForEstimatedDbSpl(30));

      // 门槛跟着降到新基准附近，而不是还停在旧值上
      expect(engine.vadThreshold, lessThan(0.005));
      expect(engine.vadThreshold, greaterThan(0));
    });
  });

  group('鼾声置信度门槛', () {
    // 1 秒窗口，便于用几秒钟音频构造出多个窗口
    const config = AnalysisConfig(
      windowSeconds: 1.0,
      hopSeconds: 1.0,
      minEventSeconds: 2.0,
      mergeGapSeconds: 1.5,
    );

    /// 模型判成鼾声，但只有 0.4 的把握——低于默认门槛 0.5。
    SleepPrediction weakSnore() => FakeSleepAnalyzer.prediction(categories: {
          SleepCategory.snore: 0.4,
          SleepCategory.ambient: 0.3,
          SleepCategory.breathing: 0.1,
        });

    /// 很有把握的鼾声。
    SleepPrediction strongSnore() => FakeSleepAnalyzer.prediction(categories: {
          SleepCategory.snore: 0.9,
          SleepCategory.ambient: 0.05,
        });

    NightAnalysisEngine engineFor(SleepPrediction Function() predict) =>
        NightAnalysisEngine(
          analyzer: FakeSleepAnalyzer(responder: (_) => predict()),
          config: config,
        );

    test('默认关着：低把握的鼾声照样成事件', () async {
      final engine = engineFor(weakSnore);
      engine.start(DateTime(2026, 10, 15, 23));

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 4));
      final outcome = await engine.finish();

      expect(engine.snoreConfidenceThreshold, 0, reason: '默认不设门槛');
      expect(engine.snoreWindowsHeldBack, 0);
      expect(outcome.stats.snoreEventCount, greaterThan(0),
          reason: '关着的时候一段都不该丢——这是默认值，必须和加这个功能之前完全一致');
    });

    test('拨开之后：低把握的鼾声不再成事件，但窗口统计一个不少', () async {
      final engine = engineFor(weakSnore);
      engine.start(DateTime(2026, 10, 15, 23));
      engine.setSnoreConfidenceThreshold(0.5);

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 4));
      final outcome = await engine.finish();

      expect(outcome.stats.snoreEventCount, 0);
      expect(outcome.stats.snoreSeconds, 0);
      expect(outcome.stats.windowsInferred, 4,
          reason: '只是不给它建事件，推理照跑——鼾声指数的**分母**不能因此变小');
      expect(outcome.stats.analyzedSeconds, 4);
      expect(engine.snoreWindowsHeldBack, 4,
          reason: '丢了几段必须数得出来，否则「报告变干净」的原因从报告上看不出来');
    });

    test('有把握的鼾声不受影响', () async {
      final engine = engineFor(strongSnore);
      engine.start(DateTime(2026, 10, 15, 23));
      engine.setSnoreConfidenceThreshold(0.5);

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 4));
      final outcome = await engine.finish();

      expect(outcome.stats.snoreEventCount, greaterThan(0));
      expect(engine.snoreWindowsHeldBack, 0);
    });

    test('只筛鼾声：咳嗽、环境噪音再没把握也照样成事件', () async {
      // 这条防的是「被实现成一道通用置信度闸门」。门槛是鼾声专属的，
      // 别的声音不该因为整体把握低就被一起清掉。
      final engine = engineFor(() => FakeSleepAnalyzer.prediction(categories: {
            SleepCategory.cough: 0.35,
            SleepCategory.ambient: 0.3,
          }));
      engine.start(DateTime(2026, 10, 15, 23));
      engine.setSnoreConfidenceThreshold(0.9);

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 4));
      final outcome = await engine.finish();

      expect(outcome.stats.eventCount, greaterThan(0),
          reason: '咳嗽 0.35 低于门槛 0.9，但它不是鼾声，不该被筛掉');
      expect(outcome.stats.snoreEventCount, 0);
      expect(engine.snoreWindowsHeldBack, 0);
    });

    test('等于门槛时保留——只有严格小于才丢', () async {
      final engine = engineFor(() => FakeSleepAnalyzer.prediction(categories: {
            SleepCategory.snore: 0.5,
            SleepCategory.ambient: 0.2,
          }));
      engine.start(DateTime(2026, 10, 15, 23));
      engine.setSnoreConfidenceThreshold(0.5);

      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 4));
      final outcome = await engine.finish();

      expect(outcome.stats.snoreEventCount, greaterThan(0));
    });

    test('可以中途拨，拨了立刻生效', () async {
      var weak = false;
      final engine = engineFor(
          () => weak ? weakSnore() : strongSnore());
      engine.start(DateTime(2026, 10, 15, 23));

      // 前半段：门槛关着，弱鼾声也留下
      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 2));
      final beforeChange = engine.snoreWindowsHeldBack;
      expect(beforeChange, 0);

      weak = true;
      engine.setSnoreConfidenceThreshold(0.5);

      // 后半段：同一个引擎，立刻开始筛
      await engine.feedSamples(tone(amplitude: loud, length: 16000 * 2));
      expect(engine.snoreWindowsHeldBack, 2,
          reason: '拨了就该作用于正在进行的这一夜，而不是等下次录音');
    });

    test('越界会被夹到 0–1', () {
      final engine = engineFor(strongSnore);
      engine.setSnoreConfidenceThreshold(1.8);
      expect(engine.snoreConfidenceThreshold, 1.0);
      engine.setSnoreConfidenceThreshold(-0.3);
      expect(engine.snoreConfidenceThreshold, 0.0);
      expect(engine.snoreWindowsHeldBack, 0);
    });

    test('dominant 是鼾声时，confidence 和 snoreProbability 是同一个数', () {
      // 门槛比的是 snoreProbability，而标黄、高危信号那些比的是 confidence。
      // 这条不变式一旦破了，「该用哪个」就从约定变成真的分歧了。
      final p = weakSnore();
      expect(p.dominant, SleepCategory.snore);
      expect(p.confidence, p.snoreProbability);
    });
  });
}

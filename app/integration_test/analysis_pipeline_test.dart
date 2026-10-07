import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sleep_secret/data/repositories/sleep_analysis_repository.dart';
import 'package:sleep_secret/data/services/onnx_classifier_service.dart';
import 'package:sleep_secret/data/services/wav_decoder_service.dart';
import 'package:sleep_secret/domain/analysis/analysis_config.dart';
import 'package:sleep_secret/domain/analysis/night_analysis_engine.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';

/// App **实际分析管线**的端到端验证。
///
///   flutter test integration_test/analysis_pipeline_test.dart -d <设备>
///
/// 走的是和录音时完全一样的代码：能量门控 → 真实模型推理 → 置信度门控 →
/// 事件合并。只有麦克风那一段是绕过的（直接喂波形），因为模拟器和测试环境
/// 都拿不到有意义的麦克风输入。
///
/// **这条测试能抓住那类致命 bug**：模型坏了、后处理做错 softmax、
/// 置信度阈值定得过高——任何一个都会让事件数变成 0，
/// 而界面上看不出任何异常。之前正是这样一路漏到交付的。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late OnnxClassifierService classifier;
  late SleepAnalysisRepository repository;

  setUpAll(() {
    classifier = OnnxClassifierService(assetKey: 'assets/models/ced-tiny.onnx');
    repository = SleepAnalysisRepository(classifier: classifier);
  });

  tearDownAll(() => classifier.dispose());

  Future<Float32List> loadWave(String asset) async {
    final bytes = await rootBundle.load(asset);
    return const WavDecoderService().decode(bytes.buffer.asUint8List()).samples;
  }

  /// 把素材重复到指定时长。
  ///
  /// 素材只有 5 秒，而分析用 3 秒窗口、最小事件时长 6 秒——
  /// 5 秒的鼾声对不齐窗口栅格，很可能只占一个窗口、凑不满一个事件。
  /// 真实鼾声通常持续几十秒，这里重复拼接更接近实际。
  Float32List stretch(Float32List src, int seconds) {
    final want = 16000 * seconds;
    final out = Float32List(want);
    for (var i = 0; i < want; i++) {
      out[i] = src[i % src.length];
    }
    return out;
  }

  /// 拼一段"一夜"：安静打底，中间插几段真实鼾声。
  ///
  /// 真实录音就是这个样子——鼾声夹在安静中间，所以事件定案时
  /// 前后都有音频可供切片段。
  Float32List buildNight(
    Float32List snore, {
    int quietBefore = 16000 * 6,
    int quietBetween = 16000 * 15,
    int quietAfter = 16000 * 6,
    int episodes = 3,
    double quietAmplitude = 0.0015,
    double snoreGain = 1.0,
  }) {
    final parts = <Float32List>[];
    // 用固定种子的伪随机噪声当底噪，避免每次跑不一致
    var seed = 12345;
    Float32List quiet(int n) {
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        out[i] = ((seed % 2000) / 1000.0 - 1.0) * quietAmplitude;
      }
      return out;
    }

    parts.add(quiet(quietBefore));
    for (var i = 0; i < episodes; i++) {
      for (var j = 0; j < snore.length; j++) {
        snore[j] = (snore[j] * snoreGain).clamp(-1.0, 1.0);
      }
      parts.add(snore);
      parts.add(quiet(quietBetween));
    }
    parts.add(quiet(quietAfter));

    final total = parts.fold<int>(0, (a, p) => a + p.length);
    final out = Float32List(total);
    var at = 0;
    for (final p in parts) {
      out.setRange(at, at + p.length, p);
      at += p.length;
    }
    return out;
  }

  Future<({List<dynamic> events, dynamic stats, NightAnalysisEngine engine})>
      runPipeline(Float32List audio) async {
    await repository.initialize();
    final engine = NightAnalysisEngine(
      analyzer: repository,
      config: const AnalysisConfig(),
    );
    engine.start(DateTime(2026, 10, 6, 23));

    // 按 1 秒一块喂进去，模拟真实录音的分块到达
    const chunk = 16000;
    for (var at = 0; at < audio.length; at += chunk) {
      final end = (at + chunk) > audio.length ? audio.length : at + chunk;
      await engine.feedSamples(Float32List.sublistView(audio, at, end));
    }

    final outcome = await engine.finish();
    return (events: outcome.events, stats: outcome.stats, engine: engine);
  }

  testWidgets('真实鼾声喂进实际管线，应当产出鼾声事件', (tester) async {
    final snore = stretch(
        await loadWave('assets/testdata/real/snore_01.wav'), 15);
    final audio = buildNight(snore);

    final r = await runPipeline(audio);

    expect(r.events, isNotEmpty,
        reason: '整条管线的意义就是产出事件。事件数为 0 说明模型坏了、'
            '后处理做错了、或者置信度阈值过高——而界面上看不出任何异常。');

    final snoreEvents =
        r.events.where((e) => e.label == SleepCategory.snore).toList();
    expect(snoreEvents, isNotEmpty, reason: '三段真实鼾声至少应当被检出若干段');

    // 三段鼾声各成一段（中间隔 15 秒安静，超过 mergeGapSeconds=9）
    expect(snoreEvents.length, greaterThanOrEqualTo(2),
        reason: '检出 ${snoreEvents.length} 段，三段鼾声不该只剩一段');

    for (final e in snoreEvents) {
      expect(e.snoreProbability, greaterThan(0.5),
          reason: '检出的鼾声事件应当有明确把握');
    }
  });

  testWidgets('整段安静不产生事件', (tester) async {
    final audio = buildNight(
      Float32List(16000 * 5), // 空的"鼾声"，实际全是 0
      episodes: 0,
    );

    final r = await runPipeline(audio);

    expect(r.events, isEmpty, reason: '整段安静不该产生任何事件');

    // ⚠️ 能量门控**默认关着**，所以安静段也会送进模型。
    // 不给它建事件靠的是**模型的判断**（判成「静音」时不给它建事件），
    // 不是靠门控拦下来。这条要验的正是模型真的会判静音——
    // 如果它把数字静音判成了别的类别，这里就会冒出事件。
    expect(r.stats.windowsInferred, greaterThan(0),
        reason: '门控关着，安静段也应当送进模型');
    expect(r.stats.windowsVadSkipped, 0);
  });

  testWidgets('能量门控默认关着——每一段都送进模型', (tester) async {
    final snore = stretch(
        await loadWave('assets/testdata/real/snore_02.wav'), 15);
    final audio = buildNight(snore);

    final r = await runPipeline(audio);

    expect(r.stats.inferenceRatio, 1.0,
        reason: '门控关着就应当全部送进模型，实际 ${r.stats.inferenceRatio}');
    expect(r.stats.windowsVadSkipped, 0);

    // 门控关掉不等于失去检出能力——鼾声段照样要出事件
    expect(
      r.events.where((e) => e.label == SleepCategory.snore),
      isNotEmpty,
      reason: '关掉门控的代价不能是漏掉鼾声',
    );
  });

  testWidgets('对照声音（公鸡叫）不会被当成鼾声事件', (tester) async {
    final rooster = stretch(
        await loadWave('assets/testdata/real/rooster.wav'), 15);
    final audio = buildNight(rooster, episodes: 3);

    final r = await runPipeline(audio);

    final snoreEvents =
        r.events.where((e) => e.label == SleepCategory.snore).toList();
    expect(snoreEvents, isEmpty,
        reason: '误报比漏报更伤信任——用户听到一段不是鼾声的音频会认为应用坏了');
  });

  testWidgets('白噪音不会被误判成鼾声', (tester) async {
    // 把底噪调到明显高于 vadRms=0.01，让它确实过能量门控、
    // 确实被送进模型。要验证的是：模型不会把宽带噪声认成鼾声。
    final audio = buildNight(
      Float32List(16000 * 5),
      episodes: 0,
      quietAmplitude: 0.05,
    );

    final r = await runPipeline(audio);

    expect(r.stats.windowsInferred, greaterThan(0),
        reason: '底噪够响，能量门控应当放行');

    // 噪声可能被识别成"环境噪音"之类的非鼾声类别，那是对的；
    // 但绝不能变成鼾声事件——那是最伤信任的误报。
    final snoreEvents =
        r.events.where((e) => e.label == SleepCategory.snore).toList();
    expect(snoreEvents, isEmpty,
        reason: '白噪音被识别成鼾声会让用户完全失去对应用的信任');
  });

  testWidgets('间隔较短的同类鼾声会被合并成一段', (tester) async {
    // mergeGapSeconds = 9：间隔小于它的同类事件会合并。
    // 这是有意的平滑——真实的鼾声是断续的，逐段列出来会碎成几十条。
    final snore = stretch(
        await loadWave('assets/testdata/real/snore_01.wav'), 15);
    final audio = buildNight(snore, quietBetween: 16000 * 5, episodes: 3);

    final r = await runPipeline(audio);

    final snoreEvents =
        r.events.where((e) => e.label == SleepCategory.snore).toList();
    expect(snoreEvents.length, 1,
        reason: '间隔 5 秒 < 合并阈值 9 秒，三段应当并成一段');
    expect(snoreEvents.single.durationSeconds, greaterThan(20),
        reason: '合并后应当是覆盖三段的总跨度，而不是只剩一段的时长');
  });

}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sleep_secret/data/repositories/sleep_analysis_repository.dart';
import 'package:sleep_secret/data/services/onnx_classifier_service.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';

/// 端到端验证：Flutter 端跑 ONNX 推理，结果必须与 PC 端（ml/make_testdata.py）一致。
///
/// 这个测试必须跑在真实平台（windows / android）上——`flutter test` 的
/// 宿主环境没有原生插件，ONNX Runtime 无法初始化。
///
///   flutter test integration_test -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late OnnxClassifierService classifier;
  late SleepAnalysisRepository repository;

  setUpAll(() {
    classifier = OnnxClassifierService(
      assetKey: 'assets/models/ced-tiny.onnx',
    );
    repository = SleepAnalysisRepository(classifier: classifier);
  });

  tearDownAll(() async => classifier.dispose());

  testWidgets('模型与类别映射表能加载', (tester) async {
    await repository.initialize();

    expect(classifier.isReady, isTrue);
    final map = repository.classMap!;
    expect(map.numClasses, 527);
    expect(map.labels.length, 527);
    expect(classifier.assetKey, endsWith('ced-tiny.onnx'));
  });

  testWidgets('单段音频推理输出 527 维 logits', (tester) async {
    await repository.initialize();

    final prediction = await repository.classifyAsset('assets/testdata/quiet.wav');

    expect(prediction.logits.length, 527);
    // 大类数量按枚举走，不写死数字——不然每加一个大类这条就得跟着改。
    expect(prediction.probabilities.length, SleepCategory.values.length);

    // ⚠️ **大类得分之间没有「和为 1」的关系**，别在这里断言 Σ≤1。
    //
    // 模型的输出是 527 维 **sigmoid**（多标签），每个大类取组内最大值，
    // 所以几个大类同时很高是正常的——真实鼾声样本上就有 3 个标签 >0.5。
    // 原来这里写着「softmax 后之和应为 1」，在安静样本上碰巧过得了，
    // 换成有内容的音频就会红，而那是**测试写错了**，不是模型错了。
    for (final entry in prediction.probabilities.entries) {
      expect(
        entry.value,
        inInclusiveRange(0.0, 1.0),
        reason: '${entry.key.name} 的概率必须落在 [0,1]',
      );
    }
    expect(prediction.topLabels.length, 5);
  });

  testWidgets('端侧结果与 PC 端逐元素一致（容差 5e-3）', (tester) async {
    await repository.initialize();

    final raw = await rootBundle.loadString('assets/testdata/expected.json');
    final expected = (jsonDecode(raw) as Map<String, dynamic>)['clips']
        as Map<String, dynamic>;

    const clips = ['quiet', 'noise', 'tone', 'pulse'];
    var checked = 0;

    for (final name in clips) {
      final fixture = expected[name] as Map<String, dynamic>?;
      expect(fixture, isNotNull, reason: 'expected.json 缺少 $name');

      final expectedLogits = (fixture!['logits'] as List)
          .map((e) => (e as num).toDouble())
          .toList(growable: false);

      final prediction =
          await repository.classifyAsset('assets/testdata/$name.wav');
      expect(
        prediction.logits.length,
        expectedLogits.length,
        reason: '$name 的 logits 维度与 PC 端不一致',
      );

      var maxDiff = 0.0;
      var maxAt = 0;
      for (var i = 0; i < expectedLogits.length; i++) {
        final d = (expectedLogits[i] - prediction.logits[i]).abs();
        if (d > maxDiff) {
          maxDiff = d;
          maxAt = i;
        }
      }

      // 容差取 5e-3，不是拍脑袋定的：
      //
      // PC 端用 ONNX Runtime 1.30.0，Android 用 1.23.0，CPU 指令路径也不同，
      // 同一个模型在两边本来就会有 1e-3 量级的浮点差。实测 `noise` 那段
      // 最大差 1.391e-3（索引 0，PC=0.03874，端侧=0.04013）——
      // 原来的 1e-3 卡在这条线上，纯粹是在跟浮点噪声较劲。
      //
      // 这条测试要抓的是**移植错误**：预处理做错、归一化漏了、通道顺序反了
      // 这类问题会产生 0.1~1.0 量级的差异。5e-3 离那个量级还有 20 倍以上余量，
      // 既不会误报，也不至于放过真问题。
      expect(
        maxDiff,
        lessThan(5e-3),
        reason: '$name 与 PC 端不一致：最大差 ${maxDiff.toStringAsExponential(3)} '
            '(索引 $maxAt, PC=${expectedLogits[maxAt]}, 端侧=${prediction.logits[maxAt]})',
      );
      checked++;
    }

    expect(checked, clips.length);
  });

  testWidgets('重复推理结果稳定（无状态泄漏）', (tester) async {
    await repository.initialize();

    final first = await repository.classifyAsset('assets/testdata/pulse.wav');
    final second = await repository.classifyAsset('assets/testdata/pulse.wav');

    expect(first.logits.length, second.logits.length);
    for (var i = 0; i < first.logits.length; i++) {
      expect(second.logits[i], closeTo(first.logits[i], 1e-6));
    }
  });

  testWidgets('不同长度输入都能推理（模型支持动态长度）', (tester) async {
    await repository.initialize();

    for (final length in [8000, 16000, 80000]) {
      final samples = Float32List(length);
      for (var i = 0; i < length; i++) {
        samples[i] = 0.02 * (i % 100 - 50) / 50.0;
      }
      final prediction = await repository.classifySamples(samples);
      expect(prediction.logits.length, 527, reason: '长度 $length 推理失败');
    }
  });
}

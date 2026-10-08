import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sleep_secret/data/models/sleep_class_map.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sleep_prediction.dart';
import 'package:sleep_secret/domain/repositories/sleep_analyzer.dart';

/// 可编程的假分析器，供各类测试注入。
///
/// 默认返回一个「鼾声占主导」的预测；用 [responder] 可以按输入内容
/// 定制返回，用来构造 VAD / 置信度门控的各种分支。
class FakeSleepAnalyzer implements SleepAnalyzer {
  FakeSleepAnalyzer({
    this.responder,
    this.failOnInitialize = false,
    this.throwOnClassify = false,
  });

  /// 根据输入样本返回预测；为 null 时用默认预测。
  final SleepPrediction Function(Float32List samples)? responder;

  final bool failOnInitialize;

  /// 每次推理都抛异常，用来验证引擎不会因此中断。
  final bool throwOnClassify;

  int initializeCount = 0;
  int classifyCount = 0;
  final List<int> classifiedLengths = [];

  @override
  SleepClassMap? classMap = stubClassMap();

  @override
  bool isReady = false;

    // 报告页只要映射表就能工作，所以它和模型分开加载。

  @override

  Future<void> loadClassMap() => initialize();
@override
  Future<void> initialize() async {
    initializeCount++;
    if (failOnInitialize) throw StateError('模拟的加载失败');
    isReady = true;
  }

  @override
  Future<SleepPrediction> classifyAsset(String assetKey) async =>
      classifySamples(Float32List(0));

  @override
  Future<SleepPrediction> classifySamples(Float32List samples) async {
    classifyCount++;
    classifiedLengths.add(samples.length);
    if (throwOnClassify) throw StateError('模拟的推理失败');
    return responder?.call(samples) ?? snoreDominated();
  }

  /// 鼾声 0.8 / 环境噪音 0.1 / 其余 0.1，置信度 0.8，稳过两道闸门。
  static SleepPrediction snoreDominated() => prediction(
        categories: {
          SleepCategory.snore: 0.8,
          SleepCategory.ambient: 0.1,
          SleepCategory.breathing: 0.05,
        },
      );

  /// 最接近均匀分布的预测，置信度极低，应被置信度门控挡掉。
  static SleepPrediction uniform() => prediction(
        categories: {
          for (final c in SleepCategory.values) c: 1.0 / SleepCategory.values.length,
        },
      );

  static SleepPrediction prediction({
    required Map<SleepCategory, double> categories,
    List<double>? logits,
  }) {
    final full = {
      for (final c in SleepCategory.values) c: categories[c] ?? 0.0,
    };
    return SleepPrediction(
      probabilities: full,
      logits: Float32List.fromList(logits ?? List<double>.filled(527, 0.0)),
      topLabels: const [(label: 'Snoring', probability: 0.8)],
    );
  }

  static SleepClassMap stubClassMap() => SleepClassMap(
        modelName: 'fake-model',
        numClasses: 527,
        labels: List<String>.filled(527, 'x', growable: false),
        categoryIndices: {
          for (final c in SleepCategory.values) c: const [0],
        },
        snoreIndices: const [0],
      );
}

/// 生成一段指定振幅的正弦波，用于触发或不触发 VAD。
Float32List tone({
  required double amplitude,
  required int length,
  double frequencyHz = 100,
  int sampleRate = 16000,
}) {
  final out = Float32List(length);
  for (var i = 0; i < length; i++) {
    out[i] =
        amplitude * math.sin(2 * math.pi * frequencyHz * i / sampleRate);
  }
  return out;
}

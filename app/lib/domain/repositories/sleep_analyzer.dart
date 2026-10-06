import 'dart:typed_data';

import '../models/sleep_prediction.dart';
import '../../data/models/sleep_class_map.dart';

/// 睡眠音频分析的契约。
///
/// 放在 domain 层：ViewModel 依赖这个抽象而不是具体的 Repository 实现，
/// 这样测试可以注入假实现，不需要真实的 ONNX 运行时。
abstract interface class SleepAnalyzer {
  /// 加载模型与类别映射表。幂等。
  Future<void> initialize();

  /// 模型与类别映射表是否已就绪。
  bool get isReady;

  /// 类别映射表，未 [initialize] 时为 null。
  SleepClassMap? get classMap;

  /// 对一段单声道波形分类。
  Future<SleepPrediction> classifySamples(Float32List samples);

  /// 对 asset 里的音频文件分类。
  Future<SleepPrediction> classifyAsset(String assetKey);
}

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

  /// 只加载类别映射表（不加载模型）。
  ///
  /// 报告页要它把原始 AudioSet 标签对照到大类，而这件事**不该等模型**——
  /// 模型 6.6MB、映射表 15KB，分开加载能让报告页一打开就有那一列。
  Future<void> loadClassMap();

  /// 模型与类别映射表是否已就绪。
  bool get isReady;

  /// 类别映射表，未 [initialize] 时为 null。
  SleepClassMap? get classMap;

  /// 对一段单声道波形分类。
  Future<SleepPrediction> classifySamples(Float32List samples);

  /// 对 asset 里的音频文件分类。
  Future<SleepPrediction> classifyAsset(String assetKey);
}

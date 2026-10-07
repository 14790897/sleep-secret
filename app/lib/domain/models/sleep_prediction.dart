import 'sleep_category.dart';

/// 单个音频窗口的分类结果（领域模型）。
///
/// 这是 Data 层把 ONNX 原始 527 维 logits 转换后的干净表示，
/// ViewModel 只认它，不接触 ONNX 细节。
class SleepPrediction {
  const SleepPrediction({
    required this.probabilities,
    required this.logits,
    required this.topLabels,
  });

  /// 7 大类概率，键为类别，值为该类下所有 AudioSet 标签概率之和。
  final Map<SleepCategory, double> probabilities;

  /// 原始 527 维 logits，用于跨端数值校验。
  final List<double> logits;

  /// AudioSet 原始标签的前 N 名，形如 `[(标签名, 概率), ...]`。
  final List<({String label, double probability})> topLabels;

  /// 概率最高的大类。合成音频下各类概率可能接近均匀，因此它不等于"有事件"，
  /// 是否算事件还要看 [confidence] 是否过闸。
  SleepCategory get dominant {
    var best = SleepCategory.silence;
    var bestValue = -1.0;
    for (final entry in probabilities.entries) {
      if (entry.value > bestValue) {
        bestValue = entry.value;
        best = entry.key;
      }
    }
    return best;
  }

  /// 置信度 = 最高一类的概率。
  double get confidence => probabilities[dominant] ?? 0.0;

  /// 鼾声概率，单独的便捷访问器。
  double get snoreProbability => probabilities[SleepCategory.snore] ?? 0.0;

  @override
  String toString() =>
      'SleepPrediction(dominant: ${dominant.name}, '
      'confidence: ${confidence.toStringAsFixed(4)})';
}

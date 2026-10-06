import 'package:flutter/foundation.dart';

import '../../../../data/services/diagnostic_fixtures.dart';
import '../../../../domain/models/sleep_prediction.dart';
import '../../../../domain/repositories/sleep_analyzer.dart';

/// 诊断页加载状态。
enum DiagnosticStatus { idle, loading, ready, failed }

/// 单段测试音频的分析结果。
class ClipResult {
  const ClipResult({
    required this.name,
    required this.prediction,
    required this.expectedLogits,
    required this.durationSeconds,
  });

  final String name;
  final SleepPrediction prediction;

  /// PC 端（`ml/make_testdata.py`）跑出的 527 维期望 logits。
  /// 为 null 表示这份夹具没有期望值。
  final List<double>? expectedLogits;

  final double durationSeconds;

  /// 与 PC 端逐元素最大绝对差。没有期望值时为 null。
  double? get maxAbsDiff {
    final expected = expectedLogits;
    if (expected == null || expected.length != prediction.logits.length) {
      return null;
    }
    var maxDiff = 0.0;
    for (var i = 0; i < expected.length; i++) {
      final d = (expected[i] - prediction.logits[i]).abs();
      if (d > maxDiff) maxDiff = d;
    }
    return maxDiff;
  }

  /// 与 PC 端结果是否一致（容差 1e-3）。
  ///
  /// 合成音频下各类概率接近均匀，比对单一标签不可靠，必须比 logits 本身。
  bool get matchesPC {
    final d = maxAbsDiff;
    return d != null && d < 1e-3;
  }
}

/// 诊断页的 ViewModel。
///
/// 职责：加载模型、对夹具音频逐段推理、并与 PC 端期望值比对，
/// 用来验证「端侧推理结果与 PC 端一致」这一阶段目标。
class DiagnosticViewModel extends ChangeNotifier {
  DiagnosticViewModel({
    required this._analyzer,
    required this._fixtures,
  });

  static const List<String> _clipAssets = [
    'assets/testdata/quiet.wav',
    'assets/testdata/noise.wav',
    'assets/testdata/tone.wav',
    'assets/testdata/pulse.wav',
  ];

  final SleepAnalyzer _analyzer;
  final DiagnosticFixtures _fixtures;

  DiagnosticStatus _status = DiagnosticStatus.idle;
  DiagnosticStatus get status => _status;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String _modelName = '';
  String get modelName => _modelName;

  int _classCount = 0;
  int get classCount => _classCount;

  List<ClipResult> _results = const [];
  List<ClipResult> get results => _results;

  bool get allMatchPc =>
      _results.isNotEmpty && _results.every((r) => r.matchesPC);

  /// 加载模型并对全部夹具音频跑一遍。可重复调用。
  Future<void> run() async {
    _status = DiagnosticStatus.loading;
    _errorMessage = null;
    notifyListeners();

    try {
      await _analyzer.initialize();

      final map = _analyzer.classMap!;
      _modelName = map.modelName;
      _classCount = map.numClasses;

      final expected = await _fixtures.loadExpectedClips();

      final results = <ClipResult>[];
      for (final asset in _clipAssets) {
        final name = asset.split('/').last.replaceAll('.wav', '');
        final prediction = await _analyzer.classifyAsset(asset);
        final fixture = expected[asset];
        results.add(ClipResult(
          name: name,
          prediction: prediction,
          expectedLogits: fixture?.logits,
          durationSeconds: fixture?.durationSeconds ?? 0,
        ));
      }

      _results = results;
      _status = DiagnosticStatus.ready;
    } catch (e, st) {
      _errorMessage = '$e';
      _status = DiagnosticStatus.failed;
      debugPrint('诊断失败: $e\n$st');
    }
    notifyListeners();
  }
}

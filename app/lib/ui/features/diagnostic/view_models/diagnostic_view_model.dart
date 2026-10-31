import 'dart:math';

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

/// 一次推理基准的结果。
///
/// 纯数据 + 纯计算，方便单测——耗时本身在测试里不可控，但「怎么从
/// 一堆样本得到中位/最快/最慢」是可以单独验的。
class InferenceBenchmark {
  const InferenceBenchmark({
    required this.runs,
    required this.windowSeconds,
    required this.medianMs,
    required this.minMs,
    required this.maxMs,
  });

  /// 从每次的毫秒耗时构造；空列表返回 null。
  static InferenceBenchmark? fromSamples(
    List<double> samples, {
    required int windowSeconds,
  }) {
    if (samples.isEmpty) return null;
    final sorted = [...samples]..sort();
    return InferenceBenchmark(
      runs: sorted.length,
      windowSeconds: windowSeconds,
      medianMs: sorted[sorted.length ~/ 2],
      minMs: sorted.first,
      maxMs: sorted.last,
    );
  }

  final int runs;
  final int windowSeconds;
  final double medianMs;
  final double minMs;
  final double maxMs;
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

  /// 基准用的窗口长度，和 [AnalysisConfig.windowSeconds] 保持一致（3 秒）。
  static const int benchmarkWindowSeconds = 3;

  /// 预热次数：第一次推理会包含惰性分配和缓存填充，不该算进基准。
  static const int _benchmarkWarmupRuns = 2;

  /// 正式采样次数。10 次足够看出中位，又不会让用户等太久。
  static const int _benchmarkRuns = 10;

  bool _benchmarking = false;
  bool get benchmarking => _benchmarking;

  InferenceBenchmark? _benchmark;
  InferenceBenchmark? get benchmark => _benchmark;

  String? _benchmarkError;
  String? get benchmarkError => _benchmarkError;

  /// 在设备 CPU 上测「一段 3 秒窗口要处理多久」。
  ///
  /// 走的是和录音时完全相同的 [SleepAnalyzer.classifySamples]——
  /// 包括预处理、推理和结果组装，所以这个数就是每个窗口的真实成本。
  Future<void> runBenchmark() async {
    if (_benchmarking) return;
    _benchmarking = true;
    _benchmarkError = null;
    notifyListeners();

    try {
      await _analyzer.initialize();

      // 固定种子的低幅噪声：模型耗时不取决于输入内容，固定下来结果才可比。
      final rng = Random(7);
      final samples = Float32List(16000 * benchmarkWindowSeconds);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = (rng.nextDouble() * 2 - 1) * 0.05;
      }

      for (var i = 0; i < _benchmarkWarmupRuns; i++) {
        await _analyzer.classifySamples(samples);
      }

      final timings = <double>[];
      for (var i = 0; i < _benchmarkRuns; i++) {
        final watch = Stopwatch()..start();
        await _analyzer.classifySamples(samples);
        watch.stop();
        timings.add(watch.elapsedMicroseconds / 1000);
      }

      _benchmark = InferenceBenchmark.fromSamples(
        timings,
        windowSeconds: benchmarkWindowSeconds,
      );
    } catch (e, st) {
      _benchmarkError = '$e';
      debugPrint('推理基准失败: $e\n$st');
    } finally {
      _benchmarking = false;
      notifyListeners();
    }
  }

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

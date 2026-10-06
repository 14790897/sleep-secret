import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// 模型 I/O 名称，与 `ml/export_ced.py` 导出时设定的一致。
/// 不一致会在加载时报错，不会静默产出错误结果。
const String kModelInputName = 'waveform';
const String kModelOutputName = 'logits';

/// 端侧 ONNX 分类器的薄封装。
///
/// 只负责「喂波形、拿 527 维 logits」，不做任何语义解释——
/// 类别聚合属于 Repository 的职责（见 SleepAnalysisRepository）。
class OnnxClassifierService {
  OnnxClassifierService({
    required this.assetKey,
    OnnxRuntime? runtime,
    this.intraOpThreads = 2,
  }) : _runtime = runtime ?? OnnxRuntime();

  final String assetKey;
  final OnnxRuntime _runtime;
  final int intraOpThreads;

  OrtSession? _session;

  bool get isReady => _session != null;

  Future<void> load() async {
    if (_session != null) return;

    final options = OrtSessionOptions(intraOpNumThreads: intraOpThreads);
    _session = await _runtime.createSessionFromAsset(assetKey, options: options);

    // 提前校验 I/O 名称，避免推理时才发现对不上。
    final inputNames = _session!.inputNames;
    final outputNames = _session!.outputNames;
    if (!inputNames.contains(kModelInputName)) {
      throw StateError(
        '模型输入名不匹配：期望 "$kModelInputName"，实际 $inputNames',
      );
    }
    if (!outputNames.contains(kModelOutputName)) {
      throw StateError(
        '模型输出名不匹配：期望 "$kModelOutputName"，实际 $outputNames',
      );
    }
  }

  /// 对一段单声道波形做推理，返回 527 维**多标签 sigmoid 概率**。
  ///
  /// 不是 logits，不要再做 softmax——AudioSet 各类别互相独立，
  /// 输出向量之和远大于 1。
  ///
  /// 模型支持动态长度，但过短的输入（不足一帧）会产生无意义的输出，
  /// 因此这里做了下限保护。
  Future<Float32List> infer(Float32List waveform) async {
    final session = _session;
    if (session == null) {
      throw StateError('模型尚未加载，请先调用 load()');
    }
    if (waveform.length < 400) {
      throw ArgumentError('输入过短：${waveform.length} 个采样点，至少需要 400');
    }

    final input = await OrtValue.fromList(waveform, [1, waveform.length]);
    final outputs = await session.run({kModelInputName: input});
    await input.dispose();

    final logits = outputs[kModelOutputName];
    if (logits == null) {
      throw StateError('推理结果里没有 "$kModelOutputName"');
    }

    try {
      // 注意要用 asFlattenedList 而不是 asList：后者会按 shape 返回嵌套数组
      // （输出是 [1, 527]，asList 得到的是 [[...]]，逐个取会拿到 Float32List）。
      final raw = await logits.asFlattenedList();
      return Float32List.fromList(
        raw.map((e) => (e as num).toDouble()).toList(growable: false),
      );
    } finally {
      await logits.dispose();
    }
  }

  Future<void> dispose() async {
    await _session?.close();
    _session = null;
  }
}

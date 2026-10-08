import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../../domain/models/sleep_category.dart';
import '../../domain/models/sleep_prediction.dart';
import '../../domain/repositories/sleep_analyzer.dart';
import '../models/sleep_class_map.dart';
import '../services/onnx_classifier_service.dart';
import '../services/wav_decoder_service.dart';

/// 睡眠音频分析的唯一入口。
///
/// 负责把 Service 层拿到的原始 527 维 logits 转换成领域模型
/// [SleepPrediction]，ViewModel 只认领域模型。
class SleepAnalysisRepository implements SleepAnalyzer {
  SleepAnalysisRepository({
    required this._classifier,
    this._decoder = const WavDecoderService(),
  });

  static const String classMapAsset = 'assets/models/sleep_class_map.json';

  /// 模型要求的采样率，见 [classifyWav]。
  static const int _sampleRate = 16000;

  /// 单次推理的输入上限。
  ///
  /// 上游模型在 17 万~25 万采样点这个区间会因形状广播失败而抛异常（实测）。
  /// 10 秒（16 万点）是安全的上界，且远超实际使用的最长窗口（3 秒）。
  static const int _maxInputSamples = 16000 * 10;

  final OnnxClassifierService _classifier;
  final WavDecoderService _decoder;

  SleepClassMap? _classMap;

  @override
  SleepClassMap? get classMap => _classMap;

  @override
  bool get isReady => _classMap != null && _classifier.isReady;

  /// 只加载类别映射表。重复调用是幂等的。
  ///
  /// **和模型分开**是有意的：映射表 15KB，模型 6.6MB。
  /// 报告页要用映射表把原始标签对照到大类，而**没录过音的用户也该看得到那一列**——
  /// 第一版把两者捆在一起，于是刚装好的 App 打开历史报告时，
  /// 那一列会全部显示成「未映射」（映射表还是 null），而那是个假消息。
  @override
  Future<void> loadClassMap() async {
    if (_classMap != null) return;
    final raw = await rootBundle.loadString(classMapAsset);
    _classMap = await decodeSleepClassMap(raw);
  }

  /// 加载模型与类别映射表。重复调用是幂等的。
  @override
  Future<void> initialize() async {
    if (isReady) return;
    await loadClassMap();
    await _classifier.load();
  }

  /// 从 asset 里读一个 wav 并分类。
  @override
  Future<SleepPrediction> classifyAsset(String assetKey) async {
    final bytes = await rootBundle.load(assetKey);
    return classifyWav(bytes.buffer.asUint8List());
  }

  /// 解码 wav 并分类。
  ///
  /// **采样率必须是 16kHz**。模型是按 16kHz 训练的，把 44.1kHz 的采样点直接
  /// 喂进去不只是"音调变高"——时间轴会错 2.75 倍，而且某些长度会让模型
  /// 内部的形状广播直接崩掉（实测 17 万~25 万采样点必崩）。
  /// App 自己的录音固定 16kHz，这里是防止外部音频混进来。
  Future<SleepPrediction> classifyWav(Uint8List wavBytes) async {
    final audio = _decoder.decode(wavBytes);
    if (audio.sampleRate != _sampleRate) {
      throw ArgumentError(
        '音频采样率是 ${audio.sampleRate}Hz，模型只接受 ${_sampleRate}Hz。'
        '请先重采样，不要直接喂——时间轴会错，而且某些长度会让推理崩溃。',
      );
    }
    return classifySamples(audio.samples);
  }

  /// 对一段单声道波形分类。
  @override
  Future<SleepPrediction> classifySamples(Float32List samples) async {
    final map = _classMap;
    if (map == null) {
      throw StateError('尚未初始化');
    }

    // 上游模型在 17 万~25 万采样点这个区间形状广播会崩（实测）。
    // 截断到安全长度：对分类来说前 10 秒足够代表这一段，比崩掉强。
    final clipped = samples.length > _maxInputSamples
        ? Float32List.sublistView(samples, 0, _maxInputSamples)
        : samples;

    final scores = await _classifier.infer(clipped);

    // ⚠️ 模型的 527 维输出**已经是 sigmoid 概率**，不是 logits，**不要做 softmax**。
    //
    // AudioSet 是多标签数据集，各类别互相独立：猫叫和狗叫可以同时成立。
    // 对它做 softmax 会除以 527 个值的大和，把 Snoring=0.96 压成 0.004，
    // 信号彻底丢失——置信度门控也就永远过不了。
    //
    // 判据：真实鼾声样本上输出向量之和约 2.7（不是 1.0），且有 3 个类别 >0.5。
    //
    // 大类得分取组内**最大值**而不是求和：求和同样会溢出 1，
    // 而且"鼾声"组里只要 Snoring 或 Snort 有一个高就说明是鼾声。
    final categories = <SleepCategory, double>{};
    for (final entry in map.categoryIndices.entries) {
      var best = 0.0;
      for (final idx in entry.value) {
        if (idx >= 0 && idx < scores.length && scores[idx] > best) {
          best = scores[idx];
        }
      }
      categories[entry.key] = best;
    }

    // 原始 top-N 标签，便于诊断页核对。
    final ranked = List<int>.generate(scores.length, (i) => i)
      ..sort((a, b) => scores[b].compareTo(scores[a]));
    final top = [
      for (final idx in ranked.take(5))
        (label: map.labelOf(idx), probability: scores[idx]),
    ];

    return SleepPrediction(
      probabilities: categories,
      logits: scores,
      topLabels: top,
    );
  }
}

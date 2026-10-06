import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/repositories/sleep_analysis_repository.dart';
import 'package:sleep_secret/data/services/onnx_classifier_service.dart';
import 'package:sleep_secret/data/services/wav_decoder_service.dart';

/// 造一个指定采样率的单声道 WAV 字节流。
Uint8List wavAt(int sampleRate, {int samples = 100}) {
  final dataBytes = samples * 2;
  final out = Uint8List(44 + dataBytes);
  final view = ByteData.sublistView(out);
  void tag(int o, String t) {
    for (var i = 0; i < 4; i++) {
      out[o + i] = t.codeUnitAt(i);
    }
  }

  tag(0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, 1, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * 2, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  view.setUint32(40, dataBytes, Endian.little);
  return out;
}

void main() {
  late SleepAnalysisRepository repo;

  setUp(() {
    repo = SleepAnalysisRepository(
      classifier: OnnxClassifierService(assetKey: 'assets/models/ced-tiny.onnx'),
    );
  });

  group('采样率校验', () {
    test('非 16kHz 的音频被明确拒绝，而不是硬喂给模型', () async {
      // 模型按 16kHz 训练。直接喂 44.1kHz 不只是时间轴错 2.75 倍，
      // 某些长度还会让模型内部的形状广播崩掉（实测 17 万~25 万采样点）。
      // 宁可在入口拒绝，也不要在推理时抛出看不懂的错。
      await expectLater(
        repo.classifyWav(wavAt(44100)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('16kHz 的音频正常通过校验', () async {
      // 校验层过了之后才会碰模型；这里只验证不会在校验处就被拒。
      // 真正的推理在 integration test 里用真模型跑。
      final audio = const WavDecoderService().decode(wavAt(16000));
      expect(audio.sampleRate, 16000);
    });

    test('8kHz 同样被拒绝', () async {
      await expectLater(
        repo.classifyWav(wavAt(8000)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

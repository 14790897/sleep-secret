import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/services/wav_decoder_service.dart';
import 'package:sleep_secret/data/services/wav_encoder.dart';

void main() {
  group('encodeWavPcm16 文件头', () {
    test('RIFF/WAVE 标记与长度字段正确', () {
      final wav = encodeWavPcm16(Float32List(100), sampleRate: 16000);
      final view = ByteData.sublistView(wav);

      String tag(int o) => String.fromCharCodes(wav, o, o + 4);

      expect(tag(0), 'RIFF');
      expect(tag(8), 'WAVE');
      expect(tag(12), 'fmt ');
      expect(tag(36), 'data');

      expect(wav.length, wavHeaderBytes + 200);
      // RIFF 长度 = 文件总长 - 8
      expect(view.getUint32(4, Endian.little), wav.length - 8);
      expect(view.getUint32(16, Endian.little), 16); // fmt 块长度
      expect(view.getUint16(20, Endian.little), 1); // PCM
      expect(view.getUint16(22, Endian.little), 1); // 单声道
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint32(28, Endian.little), 32000); // 字节率
      expect(view.getUint16(32, Endian.little), 2); // 块对齐
      expect(view.getUint16(34, Endian.little), 16); // 位深
      expect(view.getUint32(40, Endian.little), 200); // data 长度
    });

    test('空输入也产出合法的头', () {
      final wav = encodeWavPcm16(Float32List(0), sampleRate: 16000);
      expect(wav.length, wavHeaderBytes);
      expect(ByteData.sublistView(wav).getUint32(40, Endian.little), 0);
    });
  });

  group('encodeWavPcm16 数值', () {
    test('满幅与静音映射到正确的整数', () {
      final wav = encodeWavPcm16(
        Float32List.fromList([0.0, 1.0, -1.0, 0.5]),
        sampleRate: 16000,
      );
      final view = ByteData.sublistView(wav);

      expect(view.getInt16(wavHeaderBytes, Endian.little), 0);
      expect(view.getInt16(wavHeaderBytes + 2, Endian.little), 32767);
      expect(view.getInt16(wavHeaderBytes + 4, Endian.little), -32767);
      expect(view.getInt16(wavHeaderBytes + 6, Endian.little), 16384);
    });

    test('越界值被夹住而不是绕回成爆音', () {
      final wav = encodeWavPcm16(
        Float32List.fromList([2.5, -3.0]),
        sampleRate: 16000,
      );
      final view = ByteData.sublistView(wav);

      // 不夹的话 2.5 * 32767 = 81917，截成 int16 会变成负数，
      // 在听感上就是一声爆响
      expect(view.getInt16(wavHeaderBytes, Endian.little), 32767);
      expect(view.getInt16(wavHeaderBytes + 2, Endian.little), -32767);
    });
  });

  group('编码解码往返', () {
    test('编码后再解码，采样点基本一致', () {
      final original = Float32List.fromList(
        List.generate(1000, (i) => 0.8 * math.sin(i * 0.05)),
      );

      final wav = encodeWavPcm16(original, sampleRate: 16000);
      final decoded = const WavDecoderService().decode(wav);

      expect(decoded.sampleRate, 16000);
      expect(decoded.samples.length, original.length);

      // 16-bit 量化误差约 1/32768，留一点余量
      var maxDiff = 0.0;
      for (var i = 0; i < original.length; i++) {
        final d = (decoded.samples[i] - original[i]).abs();
        if (d > maxDiff) maxDiff = d;
      }
      expect(maxDiff, lessThan(1e-4));
    });

    test('时长换算正确', () {
      final wav = encodeWavPcm16(Float32List(16000), sampleRate: 16000);
      expect(const WavDecoderService().decode(wav).durationSeconds,
          closeTo(1.0, 1e-9));
    });
  });
}

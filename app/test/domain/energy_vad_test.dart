import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/energy_vad.dart';

void main() {
  group('pcm16ToFloat32', () {
    test('按小端解析并归一化', () {
      final bytes = Uint8List(6);
      final view = ByteData.sublistView(bytes);
      view.setInt16(0, 0, Endian.little);
      view.setInt16(2, 32767, Endian.little);
      view.setInt16(4, -32768, Endian.little);

      final out = pcm16ToFloat32(bytes);

      expect(out.length, 3);
      expect(out[0], closeTo(0.0, 1e-6));
      expect(out[1], closeTo(1.0, 1e-4));
      expect(out[2], closeTo(-1.0, 1e-6));
    });

    test('奇数长度时丢弃最后一个不完整采样点而不是越界', () {
      final out = pcm16ToFloat32(Uint8List(5));
      expect(out.length, 2);
    });

    test('空输入返回空数组', () {
      expect(pcm16ToFloat32(Uint8List(0)), isEmpty);
    });
  });

  group('EnergyVad', () {
    test('RMS 计算正确', () {
      // 全 0.5 的信号，RMS 就是 0.5
      final samples = Float32List.fromList(List.filled(100, 0.5));
      expect(EnergyVad.rms(samples), closeTo(0.5, 1e-6));
    });

    test('正负交替的满幅信号 RMS 为 1', () {
      final samples = Float32List.fromList(
        List.generate(100, (i) => i.isEven ? 1.0 : -1.0),
      );
      expect(EnergyVad.rms(samples), closeTo(1.0, 1e-6));
    });

    test('空输入 RMS 为 0', () {
      expect(EnergyVad.rms(Float32List(0)), 0.0);
    });

    test('低于阈值放行静音、高于阈值才推理', () {
      const vad = EnergyVad(rmsThreshold: 0.01);

      final quiet = Float32List.fromList(List.filled(100, 0.001));
      final loud = Float32List.fromList(List.filled(100, 0.2));

      expect(vad.shouldInfer(quiet), isFalse);
      expect(vad.shouldInfer(loud), isTrue);
    });

    test('恰好等于阈值算通过（边界含等号）', () {
      const vad = EnergyVad(rmsThreshold: 0.5);
      final exact = Float32List.fromList(List.filled(10, 0.5));
      expect(vad.shouldInfer(exact), isTrue);
    });
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/services/wav_decoder_service.dart';

/// 在内存里拼一个最小合法 WAV，避免测试依赖二进制夹具。
Uint8List buildWav({
  required List<int> samples,
  int sampleRate = 16000,
  int channels = 1,
  int bitsPerSample = 16,
  int format = 1,
  bool omitDataChunk = false,
}) {
  final bytesPerSample = bitsPerSample ~/ 8;
  final dataBytes = samples.length * bytesPerSample;
  final fmtSize = 16;
  final dataChunkSize = omitDataChunk ? 0 : 8 + dataBytes;
  final riffSize = 4 + (8 + fmtSize) + dataChunkSize;

  final buffer = BytesBuilder();
  final header = ByteData(12 + 8 + fmtSize + dataChunkSize);

  void writeTag(int offset, String tag) {
    for (var i = 0; i < 4; i++) {
      header.setUint8(offset + i, tag.codeUnitAt(i));
    }
  }

  writeTag(0, 'RIFF');
  header.setUint32(4, riffSize, Endian.little);
  writeTag(8, 'WAVE');

  writeTag(12, 'fmt ');
  header.setUint32(16, fmtSize, Endian.little);
  header.setUint16(20, format, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * channels * bytesPerSample, Endian.little); // byte rate
  header.setUint16(32, channels * bytesPerSample, Endian.little); // block align
  header.setUint16(34, bitsPerSample, Endian.little);

  if (!omitDataChunk) {
    writeTag(36, 'data');
    header.setUint32(40, dataBytes, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      header.setInt16(44 + i * 2, samples[i], Endian.little);
    }
  }

  buffer.add(header.buffer.asUint8List());
  return buffer.toBytes();
}

void main() {
  const decoder = WavDecoderService();

  group('WavDecoderService', () {
    test('解码 16-bit 单声道并归一化到 [-1, 1]', () {
      final wav = buildWav(samples: [0, 32767, -32768, 16384]);
      final audio = decoder.decode(wav);

      expect(audio.sampleRate, 16000);
      expect(audio.samples.length, 4);
      expect(audio.samples[0], closeTo(0.0, 1e-6));
      expect(audio.samples[1], closeTo(1.0, 1e-4));
      expect(audio.samples[2], closeTo(-1.0, 1e-6));
      expect(audio.samples[3], closeTo(0.5, 1e-4));
    });

    test('立体声会混成单声道（取平均）', () {
      // 左右声道分别 +1.0 与 -1.0，混音后应为 0
      final wav = buildWav(
        samples: [32767, -32768, 32767, -32768],
        channels: 2,
      );
      final audio = decoder.decode(wav);

      expect(audio.samples.length, 2);
      expect(audio.samples[0], closeTo(0.0, 1e-4));
      expect(audio.samples[1], closeTo(0.0, 1e-4));
    });

    test('时长按采样率换算', () {
      final wav = buildWav(
        samples: List<int>.filled(16000, 0),
        sampleRate: 16000,
      );
      expect(decoder.decode(wav).durationSeconds, closeTo(1.0, 1e-9));
    });

    test('缺少 RIFF 标记时抛异常', () {
      final bad = Uint8List.fromList(List<int>.filled(64, 0));
      expect(() => decoder.decode(bad), throwsFormatException);
    });

    test('缺少 data chunk 时抛异常', () {
      final wav = buildWav(samples: [1, 2, 3], omitDataChunk: true);
      expect(() => decoder.decode(wav), throwsFormatException);
    });

    test('不支持的编码格式抛异常而不是静默出错', () {
      // format 3 是 float，这里声明成 16-bit 但格式标为 7（μ-law）
      final wav = buildWav(samples: [0, 0], format: 7);
      expect(() => decoder.decode(wav), throwsFormatException);
    });

    test('32-bit float 也能解码', () {
      final buffer = BytesBuilder();
      final header = ByteData(44 + 8);
      void writeTag(int offset, String tag) {
        for (var i = 0; i < 4; i++) {
          header.setUint8(offset + i, tag.codeUnitAt(i));
        }
      }

      writeTag(0, 'RIFF');
      header.setUint32(4, 4 + 24 + 8 + 8, Endian.little);
      writeTag(8, 'WAVE');
      writeTag(12, 'fmt ');
      header.setUint32(16, 16, Endian.little);
      header.setUint16(20, 3, Endian.little); // IEEE float
      header.setUint16(22, 1, Endian.little);
      header.setUint32(24, 16000, Endian.little);
      header.setUint32(28, 64000, Endian.little);
      header.setUint16(32, 4, Endian.little);
      header.setUint16(34, 32, Endian.little);
      writeTag(36, 'data');
      header.setUint32(40, 8, Endian.little);
      header.setFloat32(44, 0.25, Endian.little);
      header.setFloat32(48, -0.5, Endian.little);

      buffer.add(header.buffer.asUint8List());
      final audio = decoder.decode(buffer.toBytes());

      expect(audio.samples[0], closeTo(0.25, 1e-6));
      expect(audio.samples[1], closeTo(-0.5, 1e-6));
    });
  });
}

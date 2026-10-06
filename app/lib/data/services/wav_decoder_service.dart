import 'dart:typed_data';

/// 解码后的单声道音频。
class DecodedAudio {
  const DecodedAudio({required this.samples, required this.sampleRate});

  /// 归一化到 [-1, 1] 的浮点采样点。
  final Float32List samples;
  final int sampleRate;

  double get durationSeconds => samples.length / sampleRate;
}

/// 极简 WAV 解码器：只处理 App 自己会遇到的格式。
///
/// 支持 PCM 16-bit / 32-bit float，单声道或立体声（自动混为单声道）。
/// 不处理压缩格式（ADPCM、μ-law 等）——遇到就抛异常，不静默出错。
class WavDecoderService {
  const WavDecoderService();

  static const int _fmtPcm = 1;
  static const int _fmtFloat = 3;

  DecodedAudio decode(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);

    if (_readTag(bytes, 0) != 'RIFF' || _readTag(bytes, 8) != 'WAVE') {
      throw const FormatException('不是合法的 WAV 文件（缺少 RIFF/WAVE 标记）');
    }

    int? format;
    int? channels;
    int? sampleRate;
    int? bitsPerSample;
    int? dataOffset;
    int? dataLength;

    // 顺序遍历 chunk，直到拿齐 fmt 和 data。
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final tag = _readTag(bytes, offset);
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;

      if (tag == 'fmt ') {
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bitsPerSample = data.getUint16(body + 14, Endian.little);
      } else if (tag == 'data') {
        dataOffset = body;
        dataLength = size;
      }

      // chunk 按偶数字节对齐
      offset = body + size + (size.isOdd ? 1 : 0);
    }

    if (format == null || channels == null || sampleRate == null || dataOffset == null) {
      throw const FormatException('WAV 缺少 fmt 或 data chunk');
    }
    if (format != _fmtPcm && format != _fmtFloat) {
      throw FormatException('不支持的 WAV 编码格式: $format（仅支持 PCM 与 float）');
    }

    final available = bytes.length - dataOffset;
    final effectiveLength = (dataLength ?? available).clamp(0, available);
    final mono = _toMono(bytes, dataOffset, effectiveLength,
        format: format, channels: channels, bits: bitsPerSample ?? 16);

    return DecodedAudio(samples: mono, sampleRate: sampleRate);
  }

  Float32List _toMono(
    Uint8List bytes,
    int offset,
    int length, {
    required int format,
    required int channels,
    required int bits,
  }) {
    final bytesPerSample = bits ~/ 8;
    final frameSize = bytesPerSample * channels;
    if (frameSize == 0) {
      throw const FormatException('WAV 位深为 0');
    }
    final frameCount = length ~/ frameSize;
    final out = Float32List(frameCount);
    final data = ByteData.sublistView(bytes);

    for (var frame = 0; frame < frameCount; frame++) {
      var sum = 0.0;
      for (var ch = 0; ch < channels; ch++) {
        final p = offset + frame * frameSize + ch * bytesPerSample;
        sum += _readSample(data, p, format, bits);
      }
      out[frame] = sum / channels;
    }
    return out;
  }

  double _readSample(ByteData data, int offset, int format, int bits) {
    if (format == _fmtFloat) {
      return bits == 64
          ? data.getFloat64(offset, Endian.little)
          : data.getFloat32(offset, Endian.little);
    }
    return switch (bits) {
      8 => (data.getUint8(offset) - 128) / 128.0,
      16 => data.getInt16(offset, Endian.little) / 32768.0,
      24 => _readInt24(data, offset) / 8388608.0,
      32 => data.getInt32(offset, Endian.little) / 2147483648.0,
      _ => throw FormatException('不支持的位深: $bits'),
    };
  }

  int _readInt24(ByteData data, int offset) {
    final lo = data.getUint8(offset);
    final mid = data.getUint8(offset + 1);
    final hi = data.getInt8(offset + 2); // 最高字节带符号
    return (hi << 16) | (mid << 8) | lo;
  }

  String _readTag(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return '';
    return String.fromCharCodes(bytes, offset, offset + 4);
  }
}

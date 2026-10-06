import 'dart:typed_data';

/// 把浮点采样点编码成 16-bit 单声道 WAV。
///
/// 选 WAV 不选 AAC：片段只有几秒到几十秒，编码器带来的体积收益有限，
/// 却要引入原生编解码依赖。WAV 交给任何播放器都能直接播，也方便导出。
Uint8List encodeWavPcm16(Float32List samples, {required int sampleRate}) {
  const channels = 1;
  const bitsPerSample = 16;
  const headerSize = 44;

  final dataBytes = samples.length * 2;
  final out = Uint8List(headerSize + dataBytes);
  final view = ByteData.sublistView(out);

  void writeTag(int offset, String tag) {
    for (var i = 0; i < 4; i++) {
      out[offset + i] = tag.codeUnitAt(i);
    }
  }

  writeTag(0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, Endian.little); // 除前 8 字节外的总长
  writeTag(8, 'WAVE');

  writeTag(12, 'fmt ');
  view.setUint32(16, 16, Endian.little); // fmt chunk 长度
  view.setUint16(20, 1, Endian.little); // 1 = PCM
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * channels * bitsPerSample ~/ 8, Endian.little);
  view.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);

  writeTag(36, 'data');
  view.setUint32(40, dataBytes, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    // 先夹到 [-1, 1] 再缩放。越界值直接乘会绕回成反向的爆音，
    // 而余量不足的片段很容易出现轻微越界。
    final clamped = samples[i].clamp(-1.0, 1.0);
    view.setInt16(headerSize + i * 2, (clamped * 32767).round(), Endian.little);
  }

  return out;
}

/// WAV 头部长度，测试与校验用。
const int wavHeaderBytes = 44;

import 'dart:typed_data';

/// WAV 头部长度，测试与校验用。
const int wavHeaderBytes = 44;

/// 把浮点采样点编码成 16-bit 小端 PCM 字节（**不含** WAV 头）。
///
/// 先夹到 [-1, 1] 再缩放。越界值直接乘会绕回成反向的爆音，
/// 而余量不足的片段很容易出现轻微越界。
Uint8List encodePcm16(Float32List samples) {
  final out = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    view.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
  }
  return out;
}

/// 44 字节的 WAV 头。`dataBytes` 是**已知**的数据长度。
///
/// 流式写盘时先拿一个 `dataBytes = 0` 的头占位，收尾再回填——
/// 录的时候还不知道会录多长。
Uint8List wavHeader(int sampleRate, int dataBytes) {
  const channels = 1;
  const bitsPerSample = 16;
  final out = Uint8List(wavHeaderBytes);
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
  return out;
}

/// 把浮点采样点编码成 16-bit 单声道 WAV。
///
/// 选 WAV 不选 AAC：片段只有几秒到几十秒，编码器带来的体积收益有限，
/// 却要引入原生编解码依赖。WAV 交给任何播放器都能直接播，也方便导出。
Uint8List encodeWavPcm16(Float32List samples, {required int sampleRate}) {
  final pcm = encodePcm16(samples);
  final out = Uint8List(wavHeaderBytes + pcm.length);
  out.setRange(0, wavHeaderBytes, wavHeader(sampleRate, pcm.length));
  out.setRange(wavHeaderBytes, out.length, pcm);
  return out;
}

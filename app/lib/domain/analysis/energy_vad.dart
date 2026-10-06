import 'dart:math' as math;
import 'dart:typed_data';

/// PCM 16-bit 小端字节流转成 [-1, 1] 的浮点采样点。
///
/// `record` 插件给的就是这个格式。
Float32List pcm16ToFloat32(Uint8List bytes) {
  // 奇数长度说明数据被截断，丢掉最后一个不完整的采样点而不是越界读。
  final count = bytes.length ~/ 2;
  final out = Float32List(count);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < count; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// 能量门控（VAD）。
///
/// 只做一件事：判断一段音频够不够"响"。够响才值得送进模型——
/// 安静段推理纯属浪费算力，且 softmax 会强行给出一个类别。
class EnergyVad {
  const EnergyVad({required this.rmsThreshold});

  final double rmsThreshold;

  /// 均方根。用 double 累加避免 float32 在长窗口上丢精度。
  static double rms(Float32List samples) {
    if (samples.isEmpty) return 0.0;
    var sum = 0.0;
    for (final s in samples) {
      sum += s * s;
    }
    return math.sqrt(sum / samples.length);
  }

  /// 返回该窗口是否应送进模型。
  bool shouldInfer(Float32List samples) => rms(samples) >= rmsThreshold;
}

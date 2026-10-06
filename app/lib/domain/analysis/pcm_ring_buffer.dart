import 'dart:math' as math;
import 'dart:typed_data';

/// 定长环形缓冲，保存最近的 PCM 采样点。
///
/// 录音时事件是**回溯确认**的：一个鼾声段要连续若干个窗口同类才成立，
/// 等确认时那段音频早就流过去了。所以必须留一份最近的音频，
/// 事件定案时再回头把片段切出来。
///
/// 位置用**绝对采样序号**表示（从录音开始算），跟 [AudioWindow.startSample]
/// 同一套坐标系，这样事件的时间戳能直接换算成缓冲里的切片范围。
class PcmRingBuffer {
  PcmRingBuffer({required this.capacitySamples})
      : assert(capacitySamples > 0),
        _data = Float32List(capacitySamples);

  /// 容量（采样点数）。按 16kHz 算，96000 点 = 6 秒，
  /// 实际取值要覆盖「最长片段 + 前后余量」。
  final int capacitySamples;

  final Float32List _data;

  /// 下一个写入位置。
  int _cursor = 0;

  /// 累计写入过的采样点总数，也是"最新位置"（不含）。
  int _written = 0;

  /// 缓冲里最旧的采样点绝对序号。更早的已经被覆盖。
  int get oldestSample => math.max(0, _written - capacitySamples);

  /// 最新采样点的绝对序号（不含）。等于累计写入量。
  int get newestSample => _written;

  /// 当前存了多少采样点。
  int get length => math.min(_written, capacitySamples);

  bool get isEmpty => _written == 0;

  void clear() {
    _cursor = 0;
    _written = 0;
  }

  /// 写入一块采样点。
  void write(Float32List samples) {
    if (samples.isEmpty) return;

    // 逐点写入，绝对序号 n 落在下标 n % capacity 上——取值时用的也是这个
    // 对应关系，两边必须一致。
    //
    // 曾经这里有个"块比容量还长就只留末尾"的分支，但它按 0 起放下标，
    // 破坏了上面这个对应关系，导致环绕后的切片整体错位。省下的那点开销
    // 不值得冒这个险。
    for (final s in samples) {
      _data[_cursor] = s;
      _cursor = (_cursor + 1) % capacitySamples;
    }
    _written += samples.length;
  }

  /// 取出 [startSample, endSample) 这一段。
  ///
  /// 起点已经被覆盖时返回 null——**宁可不给片段，也不给一段被截断的音频**。
  /// 截断的片段听起来像是事件刚开始就结束了，比没有更误导。
  Float32List? slice(int startSample, int endSample) {
    if (endSample <= startSample) return null;
    if (startSample < oldestSample) return null;
    if (endSample > _written) return null;

    final length = endSample - startSample;
    final out = Float32List(length);

    // 绝对序号 -> 环形下标
    for (var i = 0; i < length; i++) {
      out[i] = _data[(startSample + i) % capacitySamples];
    }
    return out;
  }
}

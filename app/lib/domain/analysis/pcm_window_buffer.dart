import 'dart:typed_data';

/// 一个待分析的音频窗口。
class AudioWindow {
  const AudioWindow({
    required this.startSample,
    required this.samples,
    required this.sampleRate,
  });

  /// 在整个会话中的起始采样点位置（不是窗口内的偏移）。
  final int startSample;
  final Float32List samples;
  final int sampleRate;

  double get startSeconds => startSample / sampleRate;
  double get durationSeconds => samples.length / sampleRate;
  double get endSeconds => startSeconds + durationSeconds;
}

/// 把连续的 PCM 流切成固定长度的分析窗口。
///
/// 录音是流式的、块大小不定（`record` 给什么就是什么），
/// 而模型要的是定长窗口，这个类负责缓冲和对齐。
///
/// 纯 Dart，不依赖任何插件，可直接单测。
class PcmWindowBuffer {
  PcmWindowBuffer({
    required this.windowSamples,
    required this.hopSamples,
    required this.sampleRate,
  }) {
    if (windowSamples <= 0 || hopSamples <= 0) {
      throw ArgumentError('窗口长度与步长必须为正');
    }
    if (hopSamples > windowSamples) {
      throw ArgumentError('步长不能大于窗口长度，否则会漏掉音频');
    }
  }

  final int windowSamples;
  final int hopSamples;
  final int sampleRate;

  final List<double> _pending = [];
  int _totalReceived = 0;

  /// 当前缓冲里还差多少样本才能凑满一个窗口。
  int get pendingSamples => _pending.length;

  /// 累计收到的样本总数。
  int get totalReceived => _totalReceived;

  /// 送入一块新数据，返回所有因此凑满的窗口（可能 0 个或多个）。
  List<AudioWindow> add(Float32List chunk) {
    if (chunk.isEmpty) return const [];
    _pending.addAll(chunk);
    _totalReceived += chunk.length;

    final out = <AudioWindow>[];
    while (_pending.length >= windowSamples) {
      final start = _totalReceived - _pending.length;
      out.add(AudioWindow(
        startSample: start,
        samples: Float32List.fromList(_pending.sublist(0, windowSamples)),
        sampleRate: sampleRate,
      ));
      _pending.removeRange(0, hopSamples);
    }
    return out;
  }

  /// 结束录音时取出最后那段不足一个窗口的音频。
  ///
  /// 模型支持动态长度，所以尾部残料不该直接丢掉——否则每次录音
  /// 都会漏掉最后几秒。短于 [minTailSamples] 的残料视为噪声丢弃。
  AudioWindow? flush({int minTailSamples = 1600}) {
    if (_pending.length < minTailSamples) {
      _pending.clear();
      return null;
    }
    final start = _totalReceived - _pending.length;
    final window = AudioWindow(
      startSample: start,
      samples: Float32List.fromList(_pending),
      sampleRate: sampleRate,
    );
    _pending.clear();
    return window;
  }

  void reset() {
    _pending.clear();
    _totalReceived = 0;
  }
}

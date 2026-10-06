import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sleep_secret/data/services/audio_capture_service.dart';

/// 用一段**已经录好的音频**冒充麦克风的采集器。
///
/// 存在的理由：`RecordAudioCapture` 是整个 App 里唯一测不到的一段——
/// 它只是 `record` 插件的一层胶水（申请权限 / startStream / stop），
/// 本身没有判断逻辑，而 CI 和模拟器都拿不到有意义的麦克风输入。
/// 把它换掉之后，它之上的每一层——Repository 的分块队列与积压处理、
/// 会话生命周期、分析引擎、数据库、报告界面——都能用**真实字节**驱动。
///
/// 喂进来的应该是从真实采集接口 dump 出来的字节，不是合成信号。
/// 合成信号只能证明「链路通」，证明不了真实录音会怎样。
///
/// 一个实例只能跑一次：`start()` 之后再 `start()` 会抛异常，
/// 免得静默地推出空数据、让测试看起来通过了其实什么都没跑。
class WavReplayAudioCapture implements AudioCapture {
  WavReplayAudioCapture({
    required this.samples,
    this.sampleRate = 16000,
    this.chunkSamples = 2048,
    this.realTime = false,
    this.permissionGranted = true,
  }) : assert(chunkSamples > 0, 'chunkSamples 必须为正');

  /// 要回放的波形，取值范围 [-1, 1]。
  final Float32List samples;

  final int sampleRate;

  /// 每块多少采样点。默认 2048——`record` 在真机上差不多就是这个量级。
  final int chunkSamples;

  /// true 按墙钟节奏推送，模拟真实采集的到达节奏（慢，但能压出积压问题）；
  /// false 尽快送完（快，适合跑功能验证）。
  final bool realTime;

  bool permissionGranted;

  StreamController<Uint8List>? _active;
  Timer? _timer;
  var _started = false;

  final _finished = Completer<void>();

  /// 全部数据推送完毕。
  ///
  /// 调用方**必须等它之后**再 stop()：录音仓库在收尾时会先取消订阅、
  /// 再等队列排空，订阅一取消，还缓冲在流里的块就丢了，
  /// 结果就是「明明喂了 30 秒却什么都没分析出来」。
  Future<void> get finished => _finished.future;

  /// 已推送的采样点数。用来核对确实喂完了。
  int get pushedSamples => _pushedSamples;
  var _pushedSamples = 0;

  @override
  Future<bool> hasPermission({bool request = true}) async => permissionGranted;

  @override
  Future<Stream<Uint8List>> start() async {
    if (_started) {
      throw StateError('WavReplayAudioCapture 只能跑一次，请重新构造一个实例');
    }
    _started = true;

    final controller = StreamController<Uint8List>();
    _active = controller;

    if (realTime) {
      final periodMs = (chunkSamples * 1000 / sampleRate).round();
      var at = 0;
      _timer = Timer.periodic(Duration(milliseconds: math.max(1, periodMs)), (t) {
        if (_active == null || controller.isClosed) {
          t.cancel();
          return;
        }
        if (at >= samples.length) {
          t.cancel();
          _complete();
          return;
        }
        _push(controller, at, math.min(at + chunkSamples, samples.length));
        at += chunkSamples;
      });
    } else {
      // 放到微任务里，让 start() 先把 stream 交给调用方
      scheduleMicrotask(() {
        if (_active == null || controller.isClosed) return;
        for (var at = 0; at < samples.length; at += chunkSamples) {
          if (_active == null || controller.isClosed) break;
          _push(controller, at, math.min(at + chunkSamples, samples.length));
        }
        _complete();
      });
    }

    return controller.stream;
  }

  void _push(StreamController<Uint8List> controller, int start, int end) {
    controller.add(_encodePcm16(start, end));
    _pushedSamples += end - start;
  }

  void _complete() {
    final c = _active;
    _active = null;
    if (c != null && !c.isClosed) c.close();
    if (!_finished.isCompleted) _finished.complete();
  }

  /// 把 [start, end) 这一段编码成 16-bit 小端单声道 PCM——
  /// 也就是 `RecordAudioCapture` 会交给上层的格式。
  Uint8List _encodePcm16(int start, int end) {
    final out = Uint8List((end - start) * 2);
    final view = ByteData.sublistView(out);
    for (var i = start; i < end; i++) {
      // 先夹到 [-1, 1] 再缩放：越界值直接乘会绕回成反向的爆音
      final v = samples[i].clamp(-1.0, 1.0);
      view.setInt16((i - start) * 2, (v * 32767).round(), Endian.little);
    }
    return out;
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final c = _active;
    _active = null;
    if (c != null && !c.isClosed) await c.close();
    if (!_finished.isCompleted) _finished.complete();
  }

  @override
  Future<void> dispose() => stop();
}

import 'dart:typed_data';

import 'package:record/record.dart';

/// 麦克风采集的契约。
///
/// 抽成接口是为了让上层（录音 Repository）能在测试里注入假实现——
/// 真机上才有的麦克风不该成为单元测试的前置条件。
abstract interface class AudioCapture {
  /// 是否已获得录音权限。`request` 为 true 时会弹系统授权框。
  Future<bool> hasPermission({bool request = true});

  /// 开始采集，返回 PCM 数据流。
  ///
  /// 格式固定为 16kHz / 单声道 / 16-bit 小端——与 CED-tiny 的要求一致，
  /// 中途不做重采样。
  Future<Stream<Uint8List>> start();

  /// 停止采集。重复调用应当安全。
  Future<void> stop();

  Future<void> dispose();
}

/// 基于 `record` 插件的实现。
class RecordAudioCapture implements AudioCapture {
  RecordAudioCapture({
    AudioRecorder? recorder,
    this.sampleRate = 16000,
  }) : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  final int sampleRate;

  /// 采集参数。
  ///
  /// 关掉 autoGain 和 noiseSuppress：整夜录音要的是原始声音，
  /// 自动增益会把安静段的底噪也拉上来，破坏能量门控的判据。
  RecordConfig get _config => RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      );

  @override
  Future<bool> hasPermission({bool request = true}) =>
      _recorder.hasPermission(request: request);

  @override
  Future<Stream<Uint8List>> start() async {
    await stop();
    return _recorder.startStream(_config);
  }

  @override
  Future<void> stop() async {
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
  }
}

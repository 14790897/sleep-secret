import 'package:flutter/foundation.dart';
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
  ///
  /// `audioInterruption: none` 不是随手写的默认值：插件默认是 `pause`，
  /// 一旦别的应用抢走音频焦点（用户放助眠音乐 / 播客），录音会被**静默
  /// 暂停且不会自动恢复**，界面计时器却照常走。整夜下来只有放音乐前那
  /// 十几秒进了库，报告看起来像「一夜没声音」。整夜录音必须优先保证
  /// 采集不被打断。
  ///
  /// 抽成静态方法是为了让测试能在不构造 [AudioRecorder]（会碰平台通道）
  /// 的情况下核对参数。
  @visibleForTesting
  static RecordConfig buildConfig({int sampleRate = 16000}) => RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        audioInterruption: AudioInterruptionMode.none,
      );

  RecordConfig get _config => buildConfig(sampleRate: sampleRate);

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

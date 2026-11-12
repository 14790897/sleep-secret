import 'dart:typed_data';

import 'package:record/record.dart';

/// 采集器当前的运行状态。
///
/// 这是 App 自己的状态而不是 [RecordState]，因为采集器是抽象接口，
/// 不该让上层依赖某个插件实现的数据类型。
enum AudioCaptureState {
  /// 正在采集。
  recording,

  /// 被系统或其它应用临时暂停（比如 `record` 在 `AudioInterruptionMode.pause`
  /// 下的焦点丢失）。**暂停期间不产生任何 PCM 数据。**
  paused,

  /// 已停止。
  stopped,
}

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

  /// 采集器状态的广播流。
  ///
  /// 上层靠它**如实**知道采集有没有被暂停——暂停时 PCM 流是安静的，
  /// 但「安静」分两种：真安静（收音正常）和被暂停（什么都没录到）。
  /// 二者混在一起，UI 就分不清麦克风坏了还是系统插了一脚。
  ///
  /// 订阅要在 [start] 之前完成，以免错过首个 `recording` 事件。
  Stream<AudioCaptureState> onStateChanged();

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

  /// 从插件发来的状态流再播一遍。`record` 的 [AudioRecorder.onStateChanged]
  /// 是单例懒建的广播流，包一层是为了把 RecordState 收敛成接口自己的
  /// [AudioCaptureState]，上层拿不到插件类型。
  @override
  Stream<AudioCaptureState> onStateChanged() async* {
    yield* _recorder.onStateChanged().map(_toAppState);
  }

  static AudioCaptureState _toAppState(RecordState state) => switch (state) {
        RecordState.pause => AudioCaptureState.paused,
        RecordState.record => AudioCaptureState.recording,
        RecordState.stop => AudioCaptureState.stopped,
      };

  /// 采集参数。
  ///
  /// 关掉 autoGain 和 noiseSuppress：整夜录音要的是原始声音，
  /// 自动增益会把安静段的底噪也拉上来，破坏能量门控的判据。
  ///
  /// **`audioInterruption` 用 `none`**：默认的 `pause` 模式在焦点被抢走
  /// （比如用户用另一个 App 播放助眠音乐）时会**静默暂停录制**，而且
  /// 不会自动恢复——一夜过去以为录了整晚，实际只录到焦点被抢之前。
  /// 对整夜录音来说，保持采集不被打断并且如实告诉用户"当前这几分钟
  /// 没采到"（电平持续为 0），比录一半悄悄停掉强得多。
  RecordConfig get _config => RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        audioInterruption: AudioInterruptionMode.none,
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

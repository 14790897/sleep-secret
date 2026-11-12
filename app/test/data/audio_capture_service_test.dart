import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:sleep_secret/data/services/audio_capture_service.dart';

void main() {
  test('录音不因其它应用抢占音频焦点而暂停', () {
    // 插件默认是 AudioInterruptionMode.pause：用户放助眠音乐时焦点被抢，
    // 录音会被静默暂停且不自动恢复，整夜只录到播放前十几秒。
    // 这个断言把「必须用 none」钉住，防止有人把参数删掉。
    final config = RecordAudioCapture.buildConfig(sampleRate: 16000);

    expect(
      config.audioInterruption,
      AudioInterruptionMode.none,
      reason: '整夜录音必须优先保证采集不被打断',
    );
  });

  test('采集格式保持 16k 单声道 PCM，不做自动增益/降噪', () {
    final config = RecordAudioCapture.buildConfig(sampleRate: 16000);

    expect(config.encoder, AudioEncoder.pcm16bits);
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
    expect(config.autoGain, isFalse);
    expect(config.echoCancel, isFalse);
    expect(config.noiseSuppress, isFalse);
  });
}

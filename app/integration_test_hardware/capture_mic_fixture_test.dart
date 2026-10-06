import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sleep_secret/data/services/audio_capture_service.dart';
import 'package:sleep_secret/data/services/wav_encoder.dart';
import 'package:sleep_secret/domain/analysis/energy_vad.dart';

/// 从**真实麦克风**录一段，存成 WAV，作为回放 fixture 的素材。
///
///   flutter test integration_test_hardware/capture_mic_fixture_test.dart -d windows \
///     --dart-define=OUT=C:/.../assets/testdata/real/mic_x.wav \
///     --dart-define=SECONDS=30
///
/// ⚠️ 这个目录**不在 CI 里跑**。它需要真实麦克风，CI 的模拟器拿不到。
///
/// ⚠️ 它录的是**麦克风听到的东西**——要录到鼾声就得有东西在放鼾声，
/// 也就是会**外放声音**。跑之前先确认这不打扰用户，或者换用耳机/虚拟声卡。
///
/// 这是「录一次、回放无数次」里的**录那一次**。它需要真实硬件，
/// 所以不进 CI；进 CI 的是它产出的文件，由 `WavReplayAudioCapture` 回放。
///
/// 之所以不随手用 Audacity 之类录：**这里走的是 App 自己的采集路径**
/// （`RecordAudioCapture` → `record` 插件 → 平台音频栈）。
/// 别处录出来的文件格式、电平、噪声特征都可能不一样，
/// 那就不是在测这条路径了。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const outPath = String.fromEnvironment('OUT');
  const seconds = int.fromEnvironment('SECONDS', defaultValue: 30);

  testWidgets('录制一段真实麦克风音频', (tester) async {
    if (outPath.isEmpty) {
      fail('必须用 --dart-define=OUT=<输出 wav 路径> 指定存到哪里');
    }

    final capture = RecordAudioCapture();
    addTearDown(capture.dispose);

    if (!await capture.hasPermission()) {
      fail('没有录音权限，无法录制 fixture');
    }

    final chunks = <Uint8List>[];
    final stream = await capture.start();
    final sub = stream.listen(chunks.add);

    await Future<void>.delayed(Duration(seconds: seconds));

    await sub.cancel();
    await capture.stop();

    final bytes = chunks.fold<int>(0, (a, c) => a + c.length);
    if (bytes == 0) fail('${seconds}s 内没有收到任何 PCM 数据，采集链路不通');

    final all = Uint8List(bytes);
    var at = 0;
    for (final c in chunks) {
      all.setRange(at, at + c.length, c);
      at += c.length;
    }

    final samples = pcm16ToFloat32(all);
    final rms = EnergyVad.rms(samples);
    var peak = 0.0;
    for (final s in samples) {
      final a = s.abs();
      if (a > peak) peak = a;
    }

    final file = File(outPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      encodeWavPcm16(samples, sampleRate: 16000),
      flush: true,
    );

    // ignore: avoid_print
    print('[fixture] 已写出 $outPath');
    // ignore: avoid_print
    print('[fixture] ${samples.length} 采样点 / '
        '${(samples.length / 16000).toStringAsFixed(1)}s，'
        'RMS = ${rms.toStringAsFixed(5)}，峰值 = ${peak.toStringAsFixed(5)}');

    expect(samples.length, greaterThan(0));
  });
}

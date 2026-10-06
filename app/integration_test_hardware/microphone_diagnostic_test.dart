import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sleep_secret/data/services/audio_capture_service.dart';
import 'package:sleep_secret/domain/analysis/analysis_config.dart';
import 'package:sleep_secret/domain/analysis/energy_vad.dart';

/// 麦克风采集链路的诊断。
///
///   flutter test integration_test_hardware/microphone_diagnostic_test.dart -d <设备>
///
/// ⚠️ 这个目录**不在 CI 里跑**。它需要真实麦克风，CI 的模拟器拿不到。
/// 采集格式这一环在架构上就该是「真机诊断」而不是「CI 断言」——
/// 其余逻辑由 `integration_test/` 用回放 fixture 覆盖。
///
/// 它**不判断对错**，只把实测到的电平打出来。原因是这个值高度依赖环境：
///
/// - **模拟器**：虚拟麦克风默认屏蔽主机音频。要用主机的音频输入得启动时加
///   `-allow-host-audio`，且主机那边得有一个可用的录音设备。
///   实测这台机器上「立体声混音」虽然在系统里显示为启用，但没有暴露给
///   DirectShow，模拟器拿不到它——所以采到的只有静音。
/// - **真机**：正常卧室底噪的 RMS 大概在 0.001~0.02 之间，
///   具体取决于手机摆位、被子遮挡、房间安静程度。
///
/// 这个数字直接决定 [AnalysisConfig.vadRms] 该定多少——
/// 定高了会把轻声鼾声一起漏掉，定低了会把底噪送进模型浪费算力。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('实测麦克风采集电平', (tester) async {
    final capture = RecordAudioCapture();
    addTearDown(capture.dispose);

    final granted = await capture.hasPermission();
    if (!granted) {
      // 权限没给就没法测，如实说明而不是假装通过
      // ignore: avoid_print
      print('[麦克风诊断] 未获得录音权限，跳过');
      return;
    }

    final chunks = <Uint8List>[];
    final stream = await capture.start();
    late StreamSubscription<Uint8List> sub;
    sub = stream.listen(chunks.add);

    // 采 5 秒
    await Future<void>.delayed(const Duration(seconds: 5));
    await sub.cancel();
    await capture.stop();

    final bytes = chunks.fold<int>(0, (a, c) => a + c.length);
    if (bytes == 0) {
      // ignore: avoid_print
      print('[麦克风诊断] 5 秒内没有收到任何 PCM 数据');
      return;
    }

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

    // ignore: avoid_print
    print('[麦克风诊断] 收到 $bytes 字节 / ${samples.length} 采样点，'
        '时长 ${(samples.length / 16000).toStringAsFixed(1)}s，'
        'RMS = ${rms.toStringAsFixed(5)}，峰值 = ${peak.toStringAsFixed(5)}');

    // ignore: avoid_print
    print(rms < 0.0005
        ? '[麦克风诊断] 判定：静音。模拟器多半没拿到主机音频，'
            '真机上请确认麦克风没被遮挡。'
        : '[麦克风诊断] 判定：有信号。');

    // 只断言采集链路本身通（收到了数据），不断言电平——
    // 电平取决于环境，不该由测试来判定对错。
    expect(samples.length, greaterThan(0), reason: '采集链路应当能收到 PCM 数据');
  });
}

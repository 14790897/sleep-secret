import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sleep_secret/data/services/audio_capture_service.dart';

/// 真机 E2E：别的应用抢走音频焦点时，整夜录音不能被静默暂停。
///
///   flutter test integration_test_hardware/audio_focus_test.dart -d <设备>
///
/// ## 为什么必须在真机上跑
///
/// 这个问题出在 `record` 插件的 Android 实现里：`AudioInterruptionPolicy`
/// 在焦点丢失且 `AudioInterruptionMode != NONE` 时暂停采集。模拟器 /
/// Windows 桌面都走不到这条路径。
///
/// ## 它怎么模拟"另一个应用"
///
/// 用 `audio_session` 在本进程里请求一个音乐会话的音频焦点。对系统而言，
/// 这和另一个 App 播放助眠音乐没有区别——焦点会被这个会话拿走。
///
/// - 修复前：录音自己持有焦点，被抢后插件暂停采集 → PCM 断流，断言失败
/// - 修复后：录音用 `AudioInterruptionMode.none`，不参与焦点争夺 → PCM 持续
///
/// ## 隐私
///
/// 这个测试会真实打开麦克风约 6 秒，但**不写任何音频文件**（流只用来数
/// 数据块）。请在没有别人的环境里跑。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('其它应用抢走音频焦点时录音仍在继续', (tester) async {
    final capture = RecordAudioCapture();
    addTearDown(capture.dispose);

    expect(
      await capture.hasPermission(request: true),
      isTrue,
      reason: '真机测试需要麦克风权限；先在系统里给它',
    );

    final stream = await capture.start();
    final chunks = <DateTime>[];
    final sub = stream.listen((_) => chunks.add(DateTime.now()));
    addTearDown(sub.cancel);

    // ---- 基线：没有别的应用抢焦点，先稳定录 3 秒 ----
    await Future<void>.delayed(const Duration(seconds: 3));
    final before = chunks.length;
    expect(before, greaterThan(0), reason: '开始录音后就该有 PCM 数据块');

    // ---- 模拟助眠音乐：请求音乐会话的音频焦点 ----
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    final gotFocus = await session.setActive(true);
    expect(gotFocus, isTrue,
        reason: 'record 不应该再持有焦点；音乐会话应当直接拿到');

    // ---- 焦点被占用的 3 秒里，PCM 必须继续进来 ----
    final duringStart = chunks.length;
    await Future<void>.delayed(const Duration(seconds: 3));
    final during = chunks.length - duringStart;

    expect(
      during,
      greaterThan(before ~/ 2),
      reason: '焦点被抢占后 PCM 断流了——录音被静默暂停'
          '（AudioInterruptionMode 没有生效）',
    );

    await session.setActive(false);
    await capture.stop();
  });
}

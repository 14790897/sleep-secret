import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sleep_secret/main.dart';

import 'package:sleep_secret/ui/features/recording/views/recording_view.dart';

/// 用**真实麦克风**走一遍「点开始 → 录音中 → 点停止 → 回到待机态」。
///
///   flutter test integration_test_hardware/real_recorder_flow_test.dart -d <设备>
///
/// ⚠️ 这个目录**不在 CI 里跑**，因为它需要一个 CI 给不了的东西：
/// **已经授予的录音权限**。
///
/// `flutter test` 每跑完一个测试文件就卸载一次应用，权限跟着被清空，
/// 而 `pm grant` 又插不进手——安装发生在 `flutter test` 内部。
/// 实测在同一个目录里跑多个文件时，第一个文件能过、第二个文件必然卡住：
/// 点「开始」弹的是 Android 系统权限对话框，它在 Flutter 视图之外，
/// 测试点不到，于是既进不了录音态也拿不到「没权限」的提示。
///
/// 所以这条和 `microphone_diagnostic_test.dart` 归一类：需要真实硬件
/// 和真实授权的东西，在架构上就该是「真机手动跑」而不是「CI 断言」。
///
/// **CI 并没有丢掉这块覆盖**：`integration_test/recording_to_report_test.dart`
/// 用注入的采集器，确定性地验证了「点开始 → 喂数据 → 点停止 → 落库 →
/// 报告页显示」整条链路。这里验的是剩下那一截——真实的 `record` 插件
/// 在这台设备上起不起得来、停不停得掉。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, [int ms = 600]) async {
    await tester.pump();
    await Future<void>.delayed(Duration(milliseconds: ms));
    await tester.pump();
  }

  /// 轮询等条件成立，而不是死等固定时长——模型加载时长随机器负载变化。
  Future<bool> waitUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return true;
      await settle(tester, 200);
    }
    return condition();
  }

  testWidgets('真实麦克风：开始 → 录音中 → 停止 → 待机', (tester) async {
    // 钉死语言：CI 的模拟器是 en_US，而这里的断言是按中文写的
    await tester.pumpWidget(const SleepSecretApp(localeOverride: Locale('zh')));
    await settle(tester, 1500);

    // 底部导航的「睡眠」tab 选中图标也是 Icons.mic，必须限定范围，
    // 否则 tap 会因为找到两个 widget 而报歧义。
    // 开始和结束是**同一个按钮**（那颗月亮），所以两个 finder 一样。
    final heroButton = find.byKey(RecordingKeys.heroButton);
    final micButton = heroButton;
    final stopButton = heroButton;

    bool recordingNow() => find.text('录音中').evaluate().isNotEmpty;
    bool deniedNow() =>
        find.textContaining('未获得麦克风权限').evaluate().isNotEmpty;

    await tester.tap(micButton);
    await waitUntil(tester, () => recordingNow() || deniedNow());

    expect(deniedNow(), isFalse,
        reason: '这台设备上没有授予录音权限。先手动授一次：\n'
            '  1. flutter install -d <设备>   （或先跑一次测试让包装上）\n'
            '  2. adb shell pm grant com.sleepsecret.sleep_secret '
            'android.permission.RECORD_AUDIO\n'
            '或者在手机的「设置 → 应用 → 权限」里手动打开麦克风。');

    expect(recordingNow(), isTrue, reason: '有权限就该进录音态');

    // 录音中：计时与实时统计要出现
    expect(find.text('实时分析'), findsOneWidget);

    // 这里**不能**用 pumpAndSettle——录音时外圈是无限循环动画，永远等不到静止
    await settle(tester, 2000);
    expect(find.text('录音中'), findsOneWidget,
        reason: '过了两秒还应当在录，不该自己停掉');

    await tester.tap(stopButton);
    // 停止要走完 finish()（处理尾部残料、等片段落盘）再落库
    await waitUntil(tester, () => find.text('点一下开始').evaluate().isNotEmpty);

    expect(find.text('点一下开始'), findsOneWidget, reason: '停止后要回到待机态');
  });
}
